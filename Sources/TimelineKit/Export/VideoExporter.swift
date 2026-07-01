#if canImport(UIKit)
import AVFoundation
import Photos
import UIKit
import CoreImage
import CoreMedia

/// Exports an EditorTimeline to an MP4 file and saves it to the Photos library,
/// reporting progress for a progress UI.
@MainActor @Observable
public final class VideoExporter {

    public var isExporting = false
    public var progress: Double = 0       // 0…1
    public var isCompleted = false
    public var errorMessage: String?
    public var coverImage: UIImage?
    public var savedVideoURL: URL?

    private let builder = CompositionBuilder()
    @ObservationIgnored private var activeExportToken: ExportCancellationToken?

    public init() {}

    // MARK: - Public

    public func export(timeline: EditorTimeline) async {
        activeExportToken?.cancel()
        let cancellationToken = ExportCancellationToken()
        activeExportToken = cancellationToken

        isExporting  = true
        progress     = 0
        isCompleted  = false
        errorMessage = nil
        coverImage   = nil
        savedVideoURL = nil

        do {
            let rawConfig = timeline.effectiveExportConfig
            let hasHDR    = await timelineHasHDRSource(timeline)
            let cfg       = downgradeIfNeeded(rawConfig, hasHDRSource: hasHDR)

            // V6 P3: all visual timelines (image/video/mixed) use TimelineRenderer
            // for video frames, bypassing AVVideoCompositing entirely. Audio still
            // flows through builder.build() → AVAssetReader.
            if hasVisualTimeline(timeline) {
                let renderSize = computeRenderSize(
                    configResolution: cfg.resolution.size,
                    canvas:          timeline.canvas
                )
                // Export uses its own deterministic provider. It must not reuse
                // the realtime preview provider, whose caches and display timing
                // are optimized for live playback/seek/replay.
                let exportFrameProvider = ExportFrameProvider()
                exportFrameProvider.setCanvasSize(renderSize)
                cancellationToken.addCancelHandler {
                    exportFrameProvider.invalidate()
                }
                let textFrameProvider = TextFrameProvider()
                textFrameProvider.update(timeline: timeline, renderSize: renderSize)
                cancellationToken.addCancelHandler {
                    textFrameProvider.invalidate()
                }
                VideoLayerComposer.frameProvider = exportFrameProvider
                TextLayerComposer.frameProvider = textFrameProvider
                defer {
                    exportFrameProvider.invalidate()
                    textFrameProvider.invalidate()
                    VideoLayerComposer.frameProvider = nil
                    TextLayerComposer.frameProvider = nil
                }

                self.coverImage = await generateCoverFromRenderer(
                    timeline:   timeline,
                    renderSize: renderSize
                )
                let exportURL = try await exportVisualToFile(
                    timeline:   timeline,
                    config:     cfg,
                    renderSize: renderSize,
                    cancellationToken: cancellationToken
                )
                savedVideoURL = exportURL
                isCompleted   = true
            } else {
                let result = try await builder.build(
                    from:            timeline,
                    renderSubtitles: true,
                    renderSize:      cfg.resolution.size,
                    fps:             cfg.fps.value
                )

                let coverImage = await generateCover(
                    from: result.composition,
                    videoComposition: result.videoComposition
                )
                self.coverImage = coverImage
                let exportURL = try await exportToFile(result, config: cfg)
                savedVideoURL = exportURL
                isCompleted   = true
            }
        } catch {
            if !cancellationToken.isCancelled {
                errorMessage = error.localizedDescription
            }
        }

        if activeExportToken === cancellationToken {
            activeExportToken = nil
            isExporting = false
        }
    }

    // MARK: - V5 HDR downgrade (render-pipeline-unification-spec §5)

    /// 级联降级策略：
    /// 1. 用户未开 HDR → 不降（已是 SDR）
    /// 2. 源素材全为 SDR → 强制降级（强加 HDR 色彩空间会导致严重偏红）
    /// 3. 设备不支持 HDR 编码 → 降级
    private func downgradeIfNeeded(_ config: ExportConfig, hasHDRSource: Bool) -> ExportConfig {
        guard config.hdrEnabled else { return config }

        guard hasHDRSource else {
            var d = config
            d.hdrEnabled = false
            return d
        }

        guard ExportEncodingProfile.canEncodeHDR() else {
            var d = config
            d.hdrEnabled = false
            return d
        }
        return config
    }

    // MARK: - HDR source detection

    /// 检查 timeline 中所有视频素材是否包含 HDR 内容。
    /// 任一视频素材为 HDR 即返回 true；全部 SDR 或无视频素材返回 false。
    private func timelineHasHDRSource(_ timeline: EditorTimeline) async -> Bool {
        let videoMaterials = timeline.materials.all.filter { material in
            timeline.mainTrack?.segments.contains(where: { $0.materialID == material.id }) ?? false
        }
        for material in videoMaterials {
            guard let url = material.bestURL else { continue }
            let asset = AVURLAsset(url: url)
            let videoTracks = (try? await asset.loadTracks(withMediaType: AVMediaType.video)) ?? []
            for track in videoTracks {
                if track.hasMediaCharacteristic(AVMediaCharacteristic.containsHDRVideo) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Cover image

    private func generateCover(
        from composition: AVComposition,
        videoComposition: AVVideoComposition?
    ) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: composition)
        generator.videoComposition = videoComposition
        generator.appliesPreferredTrackTransform = true
        if let renderSize = videoComposition?.renderSize {
            // 按实际渲染尺寸等比缩放到短边 ≤ 540，兼顾清晰度和内存。
            let short = min(renderSize.width, renderSize.height)
            let scale = short > 0 ? min(540.0 / short, 1.0) : 1.0
            generator.maximumSize = CGSize(
                width:  renderSize.width  * scale,
                height: renderSize.height * scale
            )
        }

        let time = CMTime(seconds: 0, preferredTimescale: 600)
        do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    // MARK: - Stage 3: Image-only helpers

    /// Collect subtitle and text segments from non-hidden tracks.
    private func collectOverlaySegments(timeline: EditorTimeline) -> [EditorSegment] {
        timeline.tracks.filter { !$0.isHidden }.flatMap(\.segments).filter {
            switch $0.content {
            case .subtitle, .text: return true
            default:               return false
            }
        }
    }

    /// True when the main track has any visual segment (image or video).
    private func hasVisualTimeline(_ timeline: EditorTimeline) -> Bool {
        timeline.tracks.contains { track in
            guard !track.isHidden else { return false }
            return track.segments.contains {
                switch $0.content {
                case .image, .video, .text, .subtitle:
                    return true
                default:
                    return false
                }
            }
        }
    }

    /// Derive render size from config resolution scaled to canvas aspect ratio.
    /// Mirrors `CompositionBuilder.build()`'s `actualRenderSize` computation.
    private func computeRenderSize(configResolution: CGSize, canvas: EditorCanvas) -> CGSize {
        let shortSide       = min(configResolution.width, configResolution.height)
        let canvasShortSide = CGFloat(min(canvas.width, canvas.height))
        let scale           = canvasShortSide > 0 ? shortSide / canvasShortSide : 1
        return CGSize(
            width:  CGFloat(canvas.width)  * scale,
            height: CGFloat(canvas.height) * scale
        )
    }

    /// Generate a cover image using `TimelineRenderer` at t=0 for visual timelines.
    private func generateCoverFromRenderer(
        timeline:   EditorTimeline,
        renderSize: CGSize
    ) async -> UIImage? {
        let renderer = TimelineRenderer()
        renderer.update(timeline: timeline, canvasSize: renderSize)
        guard let pb = renderer.renderFrame(at: 0) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext()
        guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Export to file (V5 render-pipeline-unification-spec §4)

    /// V5：用 `AVAssetWriter + AVAssetReader` 替换 `AVAssetExportSession`。
    /// 理由：AVAssetExportSession 架构上无法控制码率/HDR/色彩空间；要实现 V5
    /// §1.4 三档码率 + §1.5 HDR 开关，**没有第二条路**。
    ///
    /// 模式参考既有先例 `StaticImageRenderer.exportToFile`（已用 AVAssetWriter
    /// 手写编码），公共 API `export(timeline:)` 签名不变。
    private func exportToFile(_ result: CompositionResult, config: ExportConfig) async throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineExport_\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: outURL)

        // 1. AVAssetWriter (mp4 容器)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        } catch {
            throw NSError(domain: "VideoExporter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 AVAssetWriter: \(error.localizedDescription)"])
        }
        writer.shouldOptimizeForNetworkUse = true

        // 2. Video Input：按 ExportConfig 配置编码器 / 码率 / 色彩空间。
        // renderSize 必须用 videoComposition 的实际尺寸（已按 canvas 方向缩放），
        // 不能直接用 config.resolution.size（始终 16:9 横屏）。
        let videoSettings = ExportEncodingProfile.videoOutputSettings(
            for: config,
            renderSize: result.videoComposition.renderSize
        )
        let videoInput    = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "VideoExporter", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter 不支持当前视频参数（codec/bitrate/colorSpace 组合）"])
        }
        writer.add(videoInput)

        // 3. Audio Input：AAC 128k 固定（沿用 V4）
        let audioSettings = ExportEncodingProfile.audioOutputSettings()
        let audioInput    = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        let hasAudio = writer.canAdd(audioInput)
        if hasAudio { writer.add(audioInput) }

        // 4. AVAssetReader：从 composition 读取帧序列（视频帧经 videoComposition 渲染）
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: result.composition)
        } catch {
            throw NSError(domain: "VideoExporter", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 AVAssetReader: \(error.localizedDescription)"])
        }

        // 4a. Video output（带 videoComposition → 应用所有 v1/v2/v3/v4 渲染效果 + V5 烘焙字幕）
        let videoTracks = try await result.composition.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw NSError(domain: "VideoExporter", code: -8,
                          userInfo: [NSLocalizedDescriptionKey: "composition 无视频轨道"])
        }
        let videoReaderOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        videoReaderOutput.videoComposition = result.videoComposition
        videoReaderOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoReaderOutput) else {
            throw NSError(domain: "VideoExporter", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetReader 不支持视频输出"])
        }
        reader.add(videoReaderOutput)

        // 4b. Audio output（带 audioMix）
        let audioTracks = try await result.composition.loadTracks(withMediaType: .audio)
        let audioReaderOutput: AVAssetReaderAudioMixOutput?
        if hasAudio && !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: nil   // nil = decompressed PCM；writer 端再压缩为 AAC
            )
            output.audioMix = result.audioMix
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioReaderOutput = output
            } else {
                audioReaderOutput = nil
                audioInput.markAsFinished()
            }
        } else {
            audioReaderOutput = nil
            if hasAudio { audioInput.markAsFinished() }
        }

        // 5. 启动 writer + reader
        guard writer.startWriting() else {
            throw NSError(domain: "VideoExporter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter 启动失败: \(writer.error?.localizedDescription ?? "unknown")"])
        }
        writer.startSession(atSourceTime: .zero)

        guard reader.startReading() else {
            writer.cancelWriting()
            throw NSError(domain: "VideoExporter", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetReader 启动失败: \(reader.error?.localizedDescription ?? "unknown")"])
        }

        // 6. 帧搬运：video + audio 并发拷贝
        //
        // Swift 6 concurrency 处理：copySamples 闭包不能捕获 self（@MainActor），
        // 否则跨 actor 边界触发 sending closure 警告。用 `ProgressBox`（@unchecked
        // Sendable 引用类型）跨线程共享 PTS；MainActor 上独立 polling task 把
        // box.pts 同步到 self.progress（100ms 节奏）。
        let totalSeconds = result.composition.duration.seconds
        let box = ProgressBox()
        let progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let pts = box.pts
                self?.progress = totalSeconds > 0 ? min(1.0, pts / totalSeconds) : 0
                try? await Task.sleep(nanoseconds: 100_000_000)   // 100ms
            }
        }

        // AVAssetReaderOutput / AVAssetWriterInput 不是 Sendable；用 @unchecked
        // Sendable 引用 wrapper 包一下才能跨 TaskGroup 闭包传递。
        let videoOutBox = AVRefBox(videoReaderOutput)
        let videoInBox  = AVRefBox(videoInput)
        let audioPair: (out: AVRefBox<AVAssetReaderAudioMixOutput>, inp: AVRefBox<AVAssetWriterInput>)? = {
            guard let aout = audioReaderOutput, hasAudio else { return nil }
            return (AVRefBox(aout), AVRefBox(audioInput))
        }()

        let videoFrameDuration = CMTime(seconds: 1.0 / config.fps.value, preferredTimescale: 600)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Self.copySamples(
                        from: videoOutBox.value,
                        to: videoInBox.value,
                        targetFrameDuration: videoFrameDuration,
                        progressHandler: { pts in box.update(pts) }
                    )
                }
                if let pair = audioPair {
                    group.addTask {
                        try await Self.copySamples(
                            from: pair.out.value,
                            to: pair.inp.value,
                            targetFrameDuration: nil,
                            progressHandler: nil
                        )
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            progressTask.cancel()
            writer.cancelWriting()
            throw error
        }
        progressTask.cancel()

        // 7. Finish
        videoInput.markAsFinished()
        if hasAudio { audioInput.markAsFinished() }
        await writer.finishWriting()

        if writer.status != .completed {
            let underlying = writer.error?.localizedDescription ?? "未知错误"
            throw NSError(domain: "VideoExporter", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "导出未完成 (status: \(writer.status.rawValue)) \(underlying)"])
        }
        if reader.status == .failed {
            let underlying = reader.error?.localizedDescription ?? "未知错误"
            throw NSError(domain: "VideoExporter", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "读取失败: \(underlying)"])
        }

        await MainActor.run { self.progress = 1.0 }
        return outURL
    }

    /// 把 AVAssetReader 的样本拷贝到 AVAssetWriterInput。
    ///
    /// 先读后写：`copyNextSampleBuffer()` 前置，reader 耗尽时立即 `markAsFinished()`
    /// 并返回。这样即使 writer 因内部缓冲满把 `isReadyForMoreMediaData` 置为 false，
    /// 也不会死锁——writer 收到 `markAsFinished()` 后会排空缓冲并结束。
    ///
    /// `targetFrameDuration`：非 nil 时重写每个 sample 的 duration 为该值，
    /// **保留原始 PTS**（保持音画同步）。仅修正 duration 可消除源素材帧率抖动
    /// 导致的 VFR 输出（如源 26.33fps → 30fps 导出），同时不改变视频轨道总时长。
    ///
    /// 注意：不能用帧序号递推 PTS——compositor 的输出帧数可能与 target FPS 不同
    /// （如 30fps 素材导出 120fps 时 compositor 不一定产出 4× 帧数），硬推 PTS
    /// 会导致视频时长缩短 → 音画不同步。
    ///
    /// `progressHandler` 在每一帧 append 后被调用，参数是 PTS 秒数。
    nonisolated private static func copySamples(
        from output: AVAssetReaderOutput,
        to input: AVAssetWriterInput,
        targetFrameDuration: CMTime?,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        while true {
            guard let sample = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                return
            }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)   // 5ms
            }

            let outSample: CMSampleBuffer
            if let dur = targetFrameDuration {
                var timing = CMSampleTimingInfo()
                CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
                timing.duration = dur           // 归一化帧间隔，消除 VFR 抖动
                // 保留 timing.presentationTimeStamp — 维护音画同步与总时长
                var newSample: CMSampleBuffer?
                CMSampleBufferCreateCopyWithNewTiming(
                    allocator: kCFAllocatorDefault,
                    sampleBuffer: sample,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: &timing,
                    sampleBufferOut: &newSample
                )
                guard let copy = newSample else {
                    throw NSError(domain: "VideoExporter", code: -4,
                                  userInfo: [NSLocalizedDescriptionKey: "无法重建样本时序"])
                }
                outSample = copy
            } else {
                outSample = sample
            }

            let ok = input.append(outSample)
            if !ok {
                throw NSError(domain: "VideoExporter", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: "样本写入失败"])
            }
            if let handler = progressHandler {
                let pts = CMSampleBufferGetPresentationTimeStamp(outSample).seconds
                if pts.isFinite { handler(pts) }
            }
        }
    }

    /// Render visual timeline frames via TimelineRenderer logic inline.
    ///
    /// Each iteration calls `LayerResolver.resolve` → layer compositing (ImageLayerComposer
    /// or VideoLayerComposer) → CIImage compositing → `CIContext.render` → adaptor.append,
    /// exactly mirroring `TimelineRenderer.renderFrame(at:)` but runnable from a nonisolated
    /// (background) context so it never blocks the main actor.
    ///
    /// `progressHandler` is called with the current frame's PTS after each append.
    nonisolated private static func writeImageFrames(
        timeline:       EditorTimeline,
        canvasSize:     CGSize,
        subtitleFrames: [SubtitleRenderFrame],
        to adaptorBox:  AVRefBox<AVAssetWriterInputPixelBufferAdaptor>,
        videoInputBox:  AVRefBox<AVAssetWriterInput>,
        frameCount:     Int,
        fps:            Double,
        cancellationToken: ExportCancellationToken,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        let adaptor   = adaptorBox.value
        let videoIn   = videoInputBox.value
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let pixelBufferPool = adaptor.pixelBufferPool

        let ciContext: CIContext = {
            if let device = MTLCreateSystemDefaultDevice() {
                return CIContext(mtlDevice: device, options: [
                    .workingColorSpace: NSNull(),
                    .outputColorSpace:  NSNull()
                ])
            }
            return CIContext(options: [
                .workingColorSpace: NSNull(),
                .outputColorSpace:  NSNull()
            ])
        }()

        for i in 0..<frameCount {
            try Task.checkCancellation()
            if cancellationToken.isCancelled {
                throw CancellationError()
            }

            try autoreleasepool {
                let compositionTime = Double(i) / fps
                let cmTime = CMTime(seconds: compositionTime, preferredTimescale: 600)
                let presentationTime = CMTime(value: Int64(i), timescale: CMTimeScale(fps))

                // ── Resolve frame (same as TimelineRenderer.renderFrame) ──
                let frame = LayerResolver.resolve(
                    timeline: timeline,
                    at: compositionTime,
                    canvasSize: canvasSize
                )

                var composite: CIImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
                    .cropped(to: canvasRect)

                for layer in frame.layers {
                    if cancellationToken.isCancelled {
                        throw CancellationError()
                    }

                    let layerImg: CIImage?
                    var segmentTimeRange: CMTimeRange = .invalid
                    switch layer.content {
                    case .image(let spec):
                        layerImg = ImageLayerComposer.evaluate(spec: spec, at: cmTime)?
                            .cropped(to: canvasRect)
                        segmentTimeRange = spec.timeRange
                    case .video(let spec):
#if DEBUG
                        logExportVideoBoundaryIfNeeded(
                            spec: spec,
                            compositionTime: compositionTime,
                            path: "export"
                        )
#endif
                        layerImg = VideoLayerComposer.evaluate(spec: spec, at: cmTime)?
                            .cropped(to: canvasRect)
                        segmentTimeRange = spec.timeRange
#if DEBUG
                        if layerImg == nil {
                            logExportVideoLayerNil(
                                spec: spec,
                                compositionTime: compositionTime,
                                path: "export"
                            )
                        }
#endif
                    case .text(let spec):
                        layerImg = TextLayerComposer.evaluate(spec: spec, at: cmTime)?
                            .cropped(to: canvasRect)
                        segmentTimeRange = spec.timeRange
                    }
                    guard var li = layerImg else { continue }
                    // V7: apply clip animation — same path as TimelineRenderer
                    if !layer.animations.isEmpty && segmentTimeRange != .invalid {
                        li = AnimationComposer.apply(
                            to:               li,
                            animations:       layer.animations,
                            compositionTime:  compositionTime,
                            segmentTimeRange: segmentTimeRange,
                            extent:           canvasRect,
                            context:          ciContext
                        )
                    }
                    composite = li.composited(over: composite)
                }

                if let trans = frame.transition,
                   let mainVisual = TransitionComposer.render(trans, at: cmTime,
                                                               canvasSize: canvasSize,
                                                               context: ciContext) {
                    composite = mainVisual.composited(over: composite)
                }

                // ── Composite subtitle/text overlays ─────────────────────────────
                let activeSubtitles = subtitleFrames.filter {
                    compositionTime >= $0.startTime && compositionTime < $0.endTime
                }
                for frame in activeSubtitles {
                    let opacity = CGFloat(subtitleOpacity(frame: frame, at: compositionTime))
                    let overlay: CIImage
                    if opacity >= 1 {
                        overlay = frame.ciImage
                    } else {
                        overlay = frame.ciImage.applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: opacity, y: 0,       z: 0,       w: 0),
                            "inputGVector": CIVector(x: 0,       y: opacity, z: 0,       w: 0),
                            "inputBVector": CIVector(x: 0,       y: 0,       z: opacity, w: 0),
                            "inputAVector": CIVector(x: 0,       y: 0,       z: 0,       w: opacity),
                        ])
                    }
                    composite = overlay.composited(over: composite)
                }

                // ── Render to pixel buffer ──
                var pb: CVPixelBuffer?
                if let pixelBufferPool {
                    CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pb)
                } else {
                    CVPixelBufferCreate(
                        nil, Int(canvasSize.width), Int(canvasSize.height),
                        kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                        &pb
                    )
                }
                guard let pixelBuffer = pb else {
                    throw NSError(domain: "VideoExporter", code: -4,
                                  userInfo: [NSLocalizedDescriptionKey: "创建 pixel buffer 失败"])
                }

                ciContext.render(composite, to: pixelBuffer,
                                 bounds: canvasRect,
                                 colorSpace: CGColorSpaceCreateDeviceRGB())

                while !videoIn.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    if cancellationToken.isCancelled {
                        throw CancellationError()
                    }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    throw NSError(domain: "VideoExporter", code: -4,
                                  userInfo: [NSLocalizedDescriptionKey: "写入帧失败 at frame \(i)"])
                }
                if let handler = progressHandler {
                    handler(compositionTime)
                }
            }
        }

        videoIn.markAsFinished()
    }

#if DEBUG
    nonisolated private static func logExportVideoBoundaryIfNeeded(
        spec: VideoLayerSpec,
        compositionTime: Double,
        path: String
    ) {
        let segmentStart = spec.timeRange.start.seconds
        let segmentEnd = spec.timeRange.end.seconds
        let nearStart = abs(compositionTime - segmentStart) < 0.12
        let nearEnd = abs(segmentEnd - compositionTime) < 0.12
        guard nearStart || nearEnd else { return }

        let localTime = compositionTime - segmentStart
        let sourceTime = spec.sourceStartTime + localTime
        print(
            "[VideoBoundary] " +
            "path=\(path) " +
            "asset=\(spec.assetURL.lastPathComponent) " +
            "compositionTime=\(formatDebugSeconds(compositionTime)) " +
            "localTime=\(formatDebugSeconds(localTime)) " +
            "sourceTime=\(formatDebugSeconds(sourceTime)) " +
            "segmentStart=\(formatDebugSeconds(segmentStart)) " +
            "segmentEnd=\(formatDebugSeconds(segmentEnd)) " +
            "sourceStart=\(formatDebugSeconds(spec.sourceStartTime)) " +
            "sourceEnd=\(formatDebugSeconds(spec.sourceStartTime + spec.timeRange.duration.seconds)) " +
            "nearStart=\(nearStart) " +
            "nearEnd=\(nearEnd)"
        )
    }

    nonisolated private static func logExportVideoLayerNil(
        spec: VideoLayerSpec,
        compositionTime: Double,
        path: String
    ) {
        let segmentStart = spec.timeRange.start.seconds
        let segmentEnd = spec.timeRange.end.seconds
        let localTime = compositionTime - segmentStart
        let sourceTime = spec.sourceStartTime + localTime
        let nearStart = abs(compositionTime - segmentStart) < 0.12
        let nearEnd = abs(segmentEnd - compositionTime) < 0.12
        print(
            "[ExportVideoFrame] " +
            "path=\(path) " +
            "asset=\(spec.assetURL.lastPathComponent) " +
            "compositionTime=\(formatDebugSeconds(compositionTime)) " +
            "localTime=\(formatDebugSeconds(localTime)) " +
            "sourceTime=\(formatDebugSeconds(sourceTime)) " +
            "segmentStart=\(formatDebugSeconds(segmentStart)) " +
            "segmentEnd=\(formatDebugSeconds(segmentEnd)) " +
            "sourceStart=\(formatDebugSeconds(spec.sourceStartTime)) " +
            "sourceEnd=\(formatDebugSeconds(spec.sourceStartTime + spec.timeRange.duration.seconds)) " +
            "nearStart=\(nearStart) " +
            "nearEnd=\(nearEnd) " +
            "layerNil=true"
        )
    }

    nonisolated private static func formatDebugSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return String(describing: seconds) }
        return String(format: "%.4f", seconds)
    }
#endif

    /// Replicates `UnifiedCompositor.subtitleOpacity` for subtitle fade-in/out.
    nonisolated private static func subtitleOpacity(frame: SubtitleRenderFrame, at t: Double) -> Double {
        let fadeIn  = max(frame.fadeInDuration,  0.001)
        let fadeOut = max(frame.fadeOutDuration, 0.001)
        if t < frame.startTime + frame.fadeInDuration  { return max(0, min(1, (t - frame.startTime) / fadeIn)) }
        if t > frame.endTime   - frame.fadeOutDuration { return max(0, min(1, (frame.endTime - t)   / fadeOut)) }
        return 1
    }

// MARK: - Stage 3: Visual export (TimelineRenderer → AVAssetWriter)

    /// Export a visual timeline (image/video/mixed): render each frame via TimelineRenderer logic
    /// inline (nonisolated), stream audio via AVAssetReader, write to AVAssetWriter.
    private func exportVisualToFile(
        timeline:   EditorTimeline,
        config:     ExportConfig,
        renderSize: CGSize,
        cancellationToken: ExportCancellationToken
    ) async throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineExport_\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: outURL)

        // Build audio composition. TimelineRenderer handles ALL visual layers,
        // so skip image overlays in UnifiedCompositor to avoid double-rendering.
        let result = try await builder.build(
            from:             timeline,
            renderSubtitles:  false,
            renderSize:       renderSize,
            fps:              config.fps.value,
            skipImageOverlays: true
        )

        let fps = config.fps.value
        let totalSeconds = max(timeline.duration, 0.1)
        let frameCount = Int(totalSeconds * fps)

        // Text/subtitle now flow through LayerResolver -> TextLayerComposer.
        let subtitleFrames: [SubtitleRenderFrame] = []

        // 1. AVAssetWriter
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        } catch {
            throw NSError(domain: "VideoExporter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 AVAssetWriter: \(error.localizedDescription)"])
        }
        writer.shouldOptimizeForNetworkUse = true
        cancellationToken.addCancelHandler {
            writer.cancelWriting()
        }

        // 2. Video input
        let videoSettings = ExportEncodingProfile.videoOutputSettings(
            for: config, renderSize: renderSize
        )
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "VideoExporter", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter 不支持当前视频参数"])
        }
        writer.add(videoInput)

        // 3. Audio input
        let audioSettings = ExportEncodingProfile.audioOutputSettings()
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        let audioTracks = (try? await result.composition.loadTracks(withMediaType: .audio)) ?? []
        let hasAudio = writer.canAdd(audioInput) && !audioTracks.isEmpty
        if hasAudio { writer.add(audioInput) }

        // 4. AVAssetReader (audio only)
        let audioReader: AVAssetReader?
        let audioReaderOutput: AVAssetReaderAudioMixOutput?
        if hasAudio {
            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: result.composition)
            } catch {
                throw NSError(domain: "VideoExporter", code: -5,
                              userInfo: [NSLocalizedDescriptionKey: "无法创建 AVAssetReader: \(error.localizedDescription)"])
            }
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks, audioSettings: nil
            )
            output.audioMix = result.audioMix
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw NSError(domain: "VideoExporter", code: -5,
                              userInfo: [NSLocalizedDescriptionKey: "AVAssetReader 不支持音频输出"])
            }
            reader.add(output)
            audioReader = reader
            audioReaderOutput = output
            cancellationToken.addCancelHandler {
                reader.cancelReading()
            }
        } else {
            audioReader = nil
            audioReaderOutput = nil
            if writer.canAdd(audioInput) { audioInput.markAsFinished() }
        }

        // 5. Pixel buffer adaptor for video frames
        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey            as String: Int(renderSize.width),
            kCVPixelBufferHeightKey           as String: Int(renderSize.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: adaptorAttrs
        )

        // 6. Start writing
        guard writer.startWriting() else {
            throw NSError(domain: "VideoExporter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter 启动失败: \(writer.error?.localizedDescription ?? "unknown")"])
        }
        writer.startSession(atSourceTime: .zero)

        if let ar = audioReader, !ar.startReading() {
            writer.cancelWriting()
            throw NSError(domain: "VideoExporter", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetReader 启动失败: \(ar.error?.localizedDescription ?? "unknown")"])
        }

        // 7. Progress tracking
        let box = ProgressBox()
        let progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let pts = box.pts
                self?.progress = totalSeconds > 0 ? min(1.0, pts / totalSeconds) : 0
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        let adaptorBox  = AVRefBox(adaptor)
        let videoInBox  = AVRefBox(videoInput)
        let audioPair: (out: AVRefBox<AVAssetReaderAudioMixOutput>, inp: AVRefBox<AVAssetWriterInput>)? = {
            guard let aout = audioReaderOutput, hasAudio else { return nil }
            return (AVRefBox(aout), AVRefBox(audioInput))
        }()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Self.writeImageFrames(
                        timeline:       timeline,
                        canvasSize:     renderSize,
                        subtitleFrames: subtitleFrames,
                        to:             adaptorBox,
                        videoInputBox:  videoInBox,
                        frameCount:     frameCount,
                        fps:            fps,
                        cancellationToken: cancellationToken,
                        progressHandler: { pts in box.update(pts) }
                    )
                }
                if let pair = audioPair {
                    group.addTask {
                        try await Self.copySamples(
                            from: pair.out.value,
                            to: pair.inp.value,
                            targetFrameDuration: nil,
                            progressHandler: nil
                        )
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            progressTask.cancel()
            writer.cancelWriting()
            throw error
        }
        progressTask.cancel()

        // 8. Finish
        await writer.finishWriting()

        if writer.status != .completed {
            let underlying = writer.error?.localizedDescription ?? "未知错误"
            throw NSError(domain: "VideoExporter", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "导出未完成 (status: \(writer.status.rawValue)) \(underlying)"])
        }
        if let ar = audioReader, ar.status == .failed {
            let underlying = ar.error?.localizedDescription ?? "未知错误"
            throw NSError(domain: "VideoExporter", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "读取失败: \(underlying)"])
        }

        await MainActor.run { self.progress = 1.0 }
        return outURL
    }

    // MARK: - Save to Photos

    func saveToPhotoLibrary(url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "VideoExporter", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "没有相册访问权限"])
        }

        // Verify the file is a valid video before passing it to Photos.
        let asset = AVURLAsset(url: url)
        let videoTrack = (try await asset.loadTracks(withMediaType: .video)).first
        guard videoTrack != nil else {
            // Clean up the junk file so we don't litter Documents.
            try? FileManager.default.removeItem(at: url)
            throw NSError(domain: "VideoExporter", code: -7,
                          userInfo: [NSLocalizedDescriptionKey: "导出文件中无有效视频轨道"])
        }
        
        // VideoExporter 整体是 @MainActor。withCheckedThrowingContinuation 会挂起 Task、逻辑上让出主线程，但 Swift 并发运行时在某些 iOS 版本里不会立刻物理释放主线程的"所有权"。PHPhotoLibrary.performChanges 内部会往主队列回调做权限检查，与挂起的 continuation 争抢主线程，触发 reentrancy 崩溃（这就是日志里 "Enqueued from com.apple.main-thread" 的来源）。
        // performChanges MUST be dispatched from a non-MainActor context.
        //
        // Calling it from @MainActor via withCheckedThrowingContinuation can trigger
        // a reentrancy crash on some iOS versions because PHPhotoLibrary internally
        // dispatches back to the main queue for authorization checks, and the Swift
        // concurrency runtime may have already "loaned" the main thread to the suspended
        // continuation — leading to the "Enqueued from com.apple.main-thread" crash.
        //
        // Fix: kick the call onto a background queue first; the completion handler runs
        // on PHPhotoLibrary's own internal queue, so continuation.resume is always off-main.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } completionHandler: { success, error in
                    // Clean up the exported file regardless of outcome.
//                    try? FileManager.default.removeItem(at: url)
                    // 不清除图片，已经保存的是临时文件，这样导出的url可以被临时访问

                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error ?? NSError(
                            domain: "VideoExporter", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "保存到相册失败"]))
                    }
                }
            }
        }
    }
}

// MARK: - V5 progress sharing (concurrency-safe, no self capture)

/// V5：跨 actor 共享导出 PTS 进度的简易引用容器。
/// 用 NSLock 保护单个 Double 字段，避免在 TaskGroup 闭包内捕获 @MainActor self。
/// `@unchecked Sendable`：手动用锁保证并发安全。
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _pts: Double = 0

    /// 当前已写入的最大 PTS（秒）。单调非降。
    var pts: Double {
        lock.lock(); defer { lock.unlock() }
        return _pts
    }

    /// 由 copySamples 闭包写入。只接受递增更新。
    func update(_ newPTS: Double) {
        lock.lock(); defer { lock.unlock() }
        if newPTS > _pts { _pts = newPTS }
    }
}

// MARK: - Export cancellation

private final class ExportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func addCancelHandler(_ handler: @escaping () -> Void) {
        var shouldRunNow = false
        lock.lock()
        if cancelled {
            shouldRunNow = true
        } else {
            handlers.append(handler)
        }
        lock.unlock()

        if shouldRunNow {
            handler()
        }
    }

    func cancel() {
        let handlersToRun: [() -> Void]
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        handlersToRun = handlers
        handlers.removeAll()
        lock.unlock()

        for handler in handlersToRun {
            handler()
        }
    }
}

// MARK: - V5 Sendable wrapper (bypasses AVFoundation non-Sendable types in TaskGroup)

/// 将 non-Sendable 的 AVFoundation 对象（AVAssetReaderOutput / AVAssetWriterInput）
/// 包装为 `@unchecked Sendable`，使其可以跨 TaskGroup 闭包传递。
/// 调用方保证：仅访问引用，不修改内部状态（AVFoundation 对象自身线程安全）。
private final class AVRefBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

#endif

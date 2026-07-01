#if canImport(UIKit)
import AVFoundation
import UIKit
import CoreImage
import CoreMedia

/// V5 fullscreen-preview-spec §3：同源全屏预览的播放控制器。
///
/// 持有独立的 `AVPlayer + CompositionResult`，**不复用** `CompositionCoordinator.player`：
/// - 后者绑定编辑用播放（无字幕烘焙 + debounce 300ms 重建），与"打开瞬间即最终态"语义不符
/// - 独立 player 避免污染编辑画布的播放状态（播放头、缓冲）
///
/// V6 P3: 当 timeline 包含视觉片段时使用 TimelineRuntime 渲染（与编辑画布一致），
/// AVPlayer 仅提供音频 + 时间源，AVPlayerLayer 不再是最终画面。
@MainActor @Observable
final class FullScreenPreviewController {

    // MARK: - Public state (Observable)

    private(set) var isReady: Bool = false
    private(set) var firstFrameImage: UIImage?      // loading 占位首帧
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var isPlaying: Bool = false
    private(set) var errorMessage: String?
    /// True when TimelineRuntime is rendering visual output (hides AVPlayerLayer).
    private(set) var usesTimelineRuntime: Bool = false

    /// 退出全屏时被记录；上层取后回写编辑画布播放头。
    private(set) var exitPlayheadTime: CMTime = .zero

    let player = AVPlayer()
    /// UIView that displays TimelineRuntime frames (shown when usesTimelineRuntime is true).
    let timelinePreviewView = TimelinePreviewView()

    // MARK: - Internal

    private let builder = CompositionBuilder()
    @ObservationIgnored private var compositionResult: CompositionResult?
    // nonisolated(unsafe) so deinit (nonisolated) can read+remove them safely;
    // 与 CompositionCoordinator 同样模式。
    @ObservationIgnored nonisolated(unsafe) private var timeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var endObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var foregroundObserver: Any?

    // V6 P4: TimelineRuntime preview provider (nil when using AVPlayer/AVVideoCompositing path).
    private let videoFrameProvider = PreviewFrameProvider()
    private var previousFrameProvider: VideoFrameProviderProtocol?
    private var timelineRenderer: TimelineRenderer?
    private var timelineClock: TimelineClock?
    private var isRenderingFrame: Bool = false
    private var lastRenderTime: CMTime?
    private var lastEnqueuedTime: CMTime?
    private var pendingDeferredSeekRender: DispatchWorkItem?
    private var pendingDeferredSeekRenderTime: CMTime?
    private var lastPreparedSeekTime: CMTime?
    /// Cache the last-built timeline so prepare-seek can resolve active video
    /// specs without going back to the parent store.
    private var lastBuiltTimeline: EditorTimeline?
    private var lastBuiltCanvasSize: CGSize = .zero

    // MARK: - Lifecycle

    init() {
        player.actionAtItemEnd = .pause
        setupForegroundObserver()
    }

    deinit {
        if let obs = timeObserver { player.removeTimeObserver(obs) }
        if let obs = endObserver  { NotificationCenter.default.removeObserver(obs) }
        if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Build

    /// 构建烘焙 composition（renderSubtitles: true）；与 VideoExporter 同源。
    ///
    /// V6 P3: 当 timeline 包含视觉片段时，启用 TimelineRuntime 渲染——
    /// VideoLayerComposer/ImageLayerComposer 统一输出，与编辑画布一致。
    func build(timeline: EditorTimeline) async {
        do {
            // Reset the provider *before* `timelineRenderer.update` runs so any
            // in-flight preload (`loadValuesAsynchronously`) from a previous
            // build can finish or be discarded cleanly. The original ordering
            // (invalidate AFTER update) killed the preload we had just kicked
            // off — every hidden `AVPlayerItem` stayed in `.unknown` status and
            // the source's first segment-entry produced 30-50 nilFrames waiting
            // for the asset to lazy-load. Mirrors the editor's
            // `CompositionCoordinator.rebuild` order.
            videoFrameProvider.invalidate()

            let mainSegs = timeline.mainTrack?.segments ?? []
            let hasAnyVisual = !mainSegs.isEmpty && mainSegs.contains {
                switch $0.content { case .image, .video: return true; default: return false }
            }

            let result = try await builder.build(
                from: timeline,
                renderSubtitles: true,
                skipImageOverlays: hasAnyVisual
            )
            self.compositionResult = result
            self.duration = result.composition.duration.seconds

            if hasAnyVisual {
                let canvasSize = CGSize(
                    width:  CGFloat(timeline.canvas.width),
                    height: CGFloat(timeline.canvas.height)
                )
                videoFrameProvider.setCanvasSize(canvasSize)
                videoFrameProvider.onSourcePreloadComplete = { [weak self] in
                    self?.renderFrameAndFlush(force: true)
                }
                previousFrameProvider = VideoLayerComposer.frameProvider
                VideoLayerComposer.frameProvider = videoFrameProvider

                if timelineRenderer == nil {
                    timelineRenderer = TimelineRenderer()
                }
                timelineRenderer?.update(timeline: timeline, canvasSize: canvasSize)
                lastBuiltTimeline = timeline
                lastBuiltCanvasSize = canvasSize

                self.firstFrameImage = await generateCoverFromRenderer(
                    timeline: timeline, canvasSize: canvasSize
                )
            } else {
                self.firstFrameImage = await generateFirstFrame(result: result)
            }

            let item = AVPlayerItem(asset: result.composition)
            if !result.composition.tracks(withMediaType: .video).isEmpty {
                item.videoComposition = result.videoComposition
            }
            item.audioMix = result.audioMix
            player.replaceCurrentItem(with: item)

            setupTimeObserver()
            setupEndObserver(item: item)

            if hasAnyVisual {
                usesTimelineRuntime = true
                if timelineClock == nil {
                    let clock = TimelineClock()
                    clock.onTick = { [weak self] in self?.onRenderTick() }
                    timelineClock = clock
                }
                timelineClock?.start()
                flushTimelineRuntimeDisplay()
                renderFrameAndFlush()
            } else {
                usesTimelineRuntime = false
                videoFrameProvider.onSourcePreloadComplete = nil
                videoFrameProvider.invalidate()
            }

            isReady = true
        } catch {
            errorMessage = error.localizedDescription
            isReady = false
        }
    }

    // MARK: - Control

    func play() {
        videoFrameProvider.setPlaybackActive(true)
        // 播放完毕后再次点击播放：先 seek 到 0 再开始。
        if let item = player.currentItem,
           player.currentTime() >= item.duration,
           item.duration.seconds > 0 {
            prepareTimelineRuntimeForSeek(to: .zero)
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.renderFrameAndFlush()
                }
            }
        }
        player.play()
        isPlaying = true
        if usesTimelineRuntime {
            timelineClock?.start()
        }
    }
    func pause() {
        player.pause()
        isPlaying = false
        videoFrameProvider.setPlaybackActive(false)
    }

    /// 帧级精度 seek（toleranceBefore/After: .zero）——与剪映/CapCut/FCP 一致。
    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        if usesTimelineRuntime {
            videoFrameProvider.setPlaybackActive(isPlaying)
            prepareTimelineRuntimeForSeek(to: time)
        }
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.renderFrameAndFlush()
            }
        }
    }

    func recordExitPlayhead() {
        exitPlayheadTime = player.currentTime()
    }

    /// 退出全屏时调用：暂停播放并释放 AVPlayerItem（避免后台解码）。
    func teardown() {
        player.pause()
        isPlaying = false
        timelineClock?.stop()
        player.replaceCurrentItem(with: nil)
        if let obs = timeObserver { player.removeTimeObserver(obs); timeObserver = nil }
        if let obs = endObserver  { NotificationCenter.default.removeObserver(obs); endObserver = nil }
        compositionResult = nil
        VideoLayerComposer.frameProvider = previousFrameProvider
        previousFrameProvider = nil
        videoFrameProvider.onSourcePreloadComplete = nil
        videoFrameProvider.invalidate()
        lastBuiltTimeline = nil
        lastBuiltCanvasSize = .zero
    }

    // MARK: - Private

    private func generateFirstFrame(result: CompositionResult) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: result.composition)
        generator.videoComposition = result.videoComposition
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        return await Task.detached {
            (try? generator.copyCGImage(at: time, actualTime: nil)).map(UIImage.init(cgImage:))
        }.value
    }

    /// Generate a cover image using `TimelineRenderer` at t=0.
    private func generateCoverFromRenderer(
        timeline: EditorTimeline,
        canvasSize: CGSize
    ) async -> UIImage? {
        guard let renderer = timelineRenderer else { return nil }
        guard let pb = renderer.renderFrame(at: 0) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext()
        guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Timeline Runtime

    /// Called by `TimelineClock` on every display-link fire (main thread, ~60 fps).
    private func onRenderTick() {
        guard !isRenderingFrame,
              let renderer = timelineRenderer,
              isPlaying else { return }
        videoFrameProvider.setPlaybackActive(true)

        let compositionTime = player.currentTime().seconds
        guard compositionTime >= 0 else { return }
        let cmTime = CMTime(seconds: compositionTime, preferredTimescale: 600)
        guard shouldRenderTick(at: cmTime) else { return }

        isRenderingFrame = true
        if let pixelBuffer = renderer.renderFrame(at: compositionTime) {
            enqueueTimelineRuntimeFrame(pixelBuffer, presentationTime: cmTime)
        }
        isRenderingFrame = false
    }

    /// Render + display one frame at the current player time.
    private func renderFrameAndFlush() {
        renderFrameAndFlush(force: false)
    }

    private func renderFrameAndFlush(force: Bool, retryCount: Int = 6) {
        guard let renderer = timelineRenderer else { return }
        videoFrameProvider.setPlaybackActive(isPlaying || player.rate != 0)
        let compositionTime = player.currentTime().seconds
        guard compositionTime >= 0 else { return }

        let cmTime = CMTime(seconds: compositionTime, preferredTimescale: 600)
        if !force && isDuplicateFlushRender(at: cmTime) {
            return
        }
        if let pixelBuffer = renderer.renderFrame(at: compositionTime) {
            replaceTimelineRuntimeFrame(pixelBuffer, presentationTime: cmTime)
        } else {
            scheduleDeferredSeekRender(at: cmTime, retryCount: retryCount)
        }
    }

    private func handleAppDidBecomeActive() {
        guard usesTimelineRuntime else { return }
        renderFrameAndFlush(force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.renderFrameAndFlush(force: true)
        }
    }

    private func scheduleDeferredSeekRender(at time: CMTime, retryCount: Int) {
        guard retryCount > 0 else { return }
        if let pendingTime = pendingDeferredSeekRenderTime,
           pendingTime.isValid,
           time.isValid,
           abs(pendingTime.seconds - time.seconds) < 0.001 {
            return
        }

        pendingDeferredSeekRender?.cancel()
        pendingDeferredSeekRenderTime = time
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingDeferredSeekRender = nil
            self?.pendingDeferredSeekRenderTime = nil
            self?.renderFrameAndFlush(force: false, retryCount: retryCount - 1)
        }
        pendingDeferredSeekRender = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func flushTimelineRuntimeDisplay() {
        cancelDeferredSeekRender()
        timelinePreviewView.flush()
        lastRenderTime = nil
        lastEnqueuedTime = nil
        lastPreparedSeekTime = nil
    }

    private func replaceTimelineRuntimeFrame(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime
    ) {
        cancelDeferredSeekRender()
        timelinePreviewView.replace(with: pixelBuffer, presentationTime: presentationTime)
        lastRenderTime = presentationTime
        lastEnqueuedTime = presentationTime
    }

    private func isDuplicateFlushRender(at time: CMTime) -> Bool {
        guard let lastEnqueuedTime,
              lastEnqueuedTime.isValid,
              time.isValid
        else { return false }
        return abs(lastEnqueuedTime.seconds - time.seconds) < 0.001
    }

    private func cancelDeferredSeekRender() {
        pendingDeferredSeekRender?.cancel()
        pendingDeferredSeekRender = nil
        pendingDeferredSeekRenderTime = nil
    }

    private func prepareTimelineRuntimeForSeek(to time: CMTime) {
        if isDuplicatePreparedSeek(to: time) {
            return
        }
        lastPreparedSeekTime = time
        cancelDeferredSeekRender()
        let playbackActive = isPlaying || player.rate != 0
        let activeSpecs = activeVideoSpecs(at: time)
        videoFrameProvider.seek(to: time, activeSpecs: activeSpecs, playbackActive: playbackActive)
        lastRenderTime = nil
        lastEnqueuedTime = nil
    }

    private func activeVideoSpecs(at time: CMTime) -> [VideoLayerSpec] {
        guard let timeline = lastBuiltTimeline,
              time.isValid, time.seconds >= 0,
              lastBuiltCanvasSize.width > 0, lastBuiltCanvasSize.height > 0
        else { return [] }
        let specs = LayerResolver.videoSpecs(timeline: timeline, canvasSize: lastBuiltCanvasSize)
        return specs.filter { time >= $0.timeRange.start && time < $0.timeRange.end }
    }

    private func isDuplicatePreparedSeek(to time: CMTime) -> Bool {
        guard let lastPreparedSeekTime,
              lastPreparedSeekTime.isValid,
              time.isValid
        else { return false }
        return abs(lastPreparedSeekTime.seconds - time.seconds) < 0.001
    }

    private func setupForegroundObserver() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppDidBecomeActive()
            }
        }
    }

    private func shouldRenderTick(at time: CMTime) -> Bool {
        guard let lastRenderTime,
              lastRenderTime.isValid,
              time.isValid
        else {
            lastRenderTime = time
            return true
        }

        guard abs(time.seconds - lastRenderTime.seconds) > 0.001 else {
            return false
        }
        self.lastRenderTime = time
        return true
    }

    private func enqueueTimelineRuntimeFrame(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime
    ) {
        if let lastEnqueuedTime,
           presentationTime.isValid,
           lastEnqueuedTime.isValid,
           presentationTime <= lastEnqueuedTime {
            return
        }
        timelinePreviewView.enqueue(pixelBuffer, presentationTime: presentationTime)
        lastEnqueuedTime = presentationTime
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)   // 50ms 更新频率
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }
    }

    private func setupEndObserver(item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
    }
}
#endif

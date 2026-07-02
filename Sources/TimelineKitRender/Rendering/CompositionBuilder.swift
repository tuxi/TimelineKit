import TimelineKitCore
#if canImport(UIKit)
import AVFoundation
import CoreMedia
import CoreText
import UIKit

// MARK: - CompositionResult

// AVFoundation mutable types are not Sendable; we own them exclusively across the transfer.
public struct CompositionResult: @unchecked Sendable {
    public let composition:      AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let audioMix:         AVMutableAudioMix
    public let totalDuration:    CMTime
    /// Maps EditorTrack.id → CMPersistentTrackID of the corresponding audio composition track.
    /// Used by applyAudioMixOnly to rebuild the mix without touching the composition.
    public let audioTrackMap:    [UUID: CMPersistentTrackID]
}

// MARK: - CompositionBuilder

/// Converts an EditorTimeline to AVFoundation composition objects.
///
/// Runs entirely on its own actor (background thread).
/// All CALayer construction is dispatched to MainActor internally.
///
/// Support matrix:
///   ✅ Main video track  — cover-fit + per-segment transform + opacity
///   ✅ Subtitle track    — CATextLayer via AVVideoCompositionCoreAnimationTool
///   ✅ Text track        — CATextLayer via AVVideoCompositionCoreAnimationTool
///   ✅ Audio track       — AVMutableAudioMix with per-track volume; per-segment speed (v3 P0)
///   ✅ Transitions       — ping-pong dual-track + easeInOut opacity ramp (v2)
///   ⬜ Overlay tracks    — skipped (future)
///   ⬜ Speed < > 1.0     — applied to .audio segments only; video native audio + .video segments still treated as 1.0 (future)
public actor CompositionBuilder {

    enum BuildError: Error {
        case cannotCreateVideoTrack
        case noVideoTracks
    }
    
    public init() {
        
    }

    // V6: StaticImageRenderer removed — images rendered via ImageLayerComposer.
    // Property kept as comment for historical reference.

    // MARK: - Public

    /// - Parameters:
    ///   - timeline: 工程数据
    ///   - renderSubtitles: When `true`, subtitle and text segments are baked
    ///     into the video composition (used for export). When `false` (default, used for
    ///     live preview), the subtitle/text tracks are omitted so the SwiftUI overlay
    ///     views (`TextOverlayView`, `SubtitleStackView`) remain the sole source of truth
    ///     and stay interactive / editable.
    ///   - renderSize: V5 新增。override `timeline.canvas` 的渲染尺寸。
    ///     nil 时按 canvas 原值（向后兼容 V4 调用点）。供 VideoExporter 透传
    ///     `ExportConfig.resolution.size` 实现导出参数化。
    ///   - fps: V5 新增。override `timeline.canvas.fps`。nil 时按 canvas 原值。
    ///     供 VideoExporter 透传 `ExportConfig.fps.value` 实现导出帧率参数化。
   public func build(
        from timeline: EditorTimeline,
        renderSubtitles: Bool = false,
        renderSize: CGSize? = nil,
        fps: Double? = nil,
        skipImageOverlays: Bool = false
    ) async throws -> CompositionResult {
        let composition = AVMutableComposition()
        // V5：renderSize/fps 可由调用方 override（导出时透传 ExportConfig）；
        // nil 时严格沿用 V4 行为（按 canvas）。
        let actualRenderSize: CGSize
        if let renderSize {
            // renderSize 给出的是 16:9 参考尺寸（短边目标），需按 canvas 宽高比
            // 缩放以匹配实际画布方向。否则竖屏画布也会被渲染为横屏。
            let shortSide = min(renderSize.width, renderSize.height)
            let canvasShortSide = CGFloat(min(timeline.canvas.width, timeline.canvas.height))
            let scale = canvasShortSide > 0 ? shortSide / canvasShortSide : 1
            actualRenderSize = CGSize(
                width:  CGFloat(timeline.canvas.width)  * scale,
                height: CGFloat(timeline.canvas.height) * scale
            )
        } else {
            actualRenderSize = CGSize(
                width:  CGFloat(timeline.canvas.width),
                height: CGFloat(timeline.canvas.height)
            )
        }
        let actualFPS = fps ?? Double(timeline.canvas.fps > 0 ? timeline.canvas.fps : 30)
        let totalDuration = CMTime(seconds: max(timeline.duration, 0.1), preferredTimescale: 600)

        // V5：导出分辨率可能与 canvas 不同，字幕/文字的所有 point 值需等比缩放。
        // 剪映等竞品文字大小不受导出分辨率影响——本质是用「参考画布」定义字体，
        // 导出时按 fontScale 映射到实际像素。fontScale = 1.0 时（预览/同分辨率导出）
        // 行为与 V4 完全一致。
        let canvasShortSide  = CGFloat(min(timeline.canvas.width, timeline.canvas.height))
        let renderShortSide  = min(actualRenderSize.width, actualRenderSize.height)
        let fontScale        = canvasShortSide > 0 ? renderShortSide / canvasShortSide : 1.0

        // ── 1. Main video track ──────────────────────────────────────────────
        // Phase 1b: unified compositor handles color + transitions together.
        // Single-pass (no custom compositor) preserved for zero-effects case.

        // V5.1 增补 B：收集 .overlay 轨道段落作为背景层（剪映模型——zPosition=-1
        // 的「背景」轨道在主轨道之下持续渲染）。
        // overlay 渲染只在 single-pass 路径处理：unified 路径添加额外 video track 会
        // 让 AVFoundation 静默拒绝 customVideoCompositorClass（startRequest 永不调用→全黑）；
        // 因此 hasEffects 不再纳入 hasBackgroundOverlays。带转场/调色 + overlay 的组合
        // 当前 overlay 不可见，属已知遗留项，留待后续版本统一改造 unified compositor。
        let backgroundOverlaySegs = timeline.tracks(ofKind: .overlay)
            .filter { !$0.isHidden }
            .flatMap { $0.segments }
            .sorted { $0.targetRange.start < $1.targetRange.start }

        // ── 2. Subtitle / Text overlay ──────────────────────────────────────
        // Only bake subtitles for export (renderSubtitles = true).
        // During live preview the SwiftUI layers (TextOverlayView / SubtitleStackView)
        // are the sole source of truth; baking them here would produce duplicate text.
        let overlaySegs = renderSubtitles ? collectOverlaySegments(timeline: timeline) : []

        // V5.1 增补修复（2026-05-19）：renderSubtitles=true 且有字幕段时必须强制走
        // unified 路径。原因：single-pass 用 `AVVideoCompositionCoreAnimationTool`
        // 烘焙字幕，但该 API 只能用于 `AVAssetExportSession` 离线导出，挂到
        // `AVPlayerItem` 会立即崩溃（FullScreenPreview 走 AVPlayerItem 路径）。
        // unified 路径用 customVideoCompositor 烘焙字幕到 CIImage，AVPlayerItem 支持。
        // V6: Image segments force unified path — single-pass has no image rendering path.
        let timelineHasImages = timeline.tracks.flatMap({ $0.segments }).contains { seg in
            if case .image = seg.content { return true }
            return false
        }

        let hasEffects = needsColorAdjustment(timeline: timeline)
            || hasMainTransitions(timeline: timeline)
            || !overlaySegs.isEmpty
            || timelineHasImages

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize    = actualRenderSize
        videoComposition.frameDuration = CMTime(seconds: 1.0 / actualFPS, preferredTimescale: 600)

        // V5.1 BUG 1 / 增补 A：主视频轨结束时间必须取 `max(targetRange.end)`，不能取
        // `segments.last`——segments 数组顺序可能因用户重排不再按时间单调（reorder 后
        // last 不一定是时间上最晚的一段），用 max 才能在 image_motion / image_3d /
        // 视频 / 图片混排时统一覆盖到「全品类视觉素材最晚结束点」。
        let mainSegments = timeline.mainTrack?.segments ?? []
        let mainVideoEndCM: CMTime = {
            let endSec = mainSegments.map { $0.targetRange.end }.max() ?? 0
            return CMTime(seconds: endSec, preferredTimescale: 600)
        }()

        if hasEffects {
            let unified = try await buildVideoTrackUnified(
                timeline:          timeline,
                composition:       composition,
                renderSize:        actualRenderSize,
                totalDuration:     totalDuration,
                mainVideoEnd:      mainVideoEndCM,
                fps:               actualFPS,
                skipImageOverlays: skipImageOverlays
            )

            // Unified compositor path: animationTool is forbidden (mutual exclusion).
            // Pre-render each subtitle/text segment to a CIImage on MainActor, then
            // attach to each instruction whose time range overlaps the segment.
            if !overlaySegs.isEmpty {
                let frames = await MainActor.run {
                    SubtitleFrameBuilder.build(
                        segments:      overlaySegs,
                        renderSize:    actualRenderSize,
                        totalDuration: totalDuration.seconds,
                        fontScale:     fontScale
                    )
                }
                for instr in unified {
                    let s = instr.timeRange.start.seconds
                    let e = s + instr.timeRange.duration.seconds
                    instr.subtitleFrames = frames.filter { $0.startTime < e && $0.endTime > s }
                }
            }

            videoComposition.customVideoCompositorClass = UnifiedCompositor.self
            videoComposition.instructions = unified
        } else {
            let videoInstructions = try await buildVideoTrackSinglePass(
                timeline:              timeline,
                composition:           composition,
                renderSize:            actualRenderSize,
                totalDuration:         totalDuration,
                mainVideoEnd:          mainVideoEndCM,
                backgroundOverlaySegs: backgroundOverlaySegs,
                fps:                   actualFPS
            )
            videoComposition.instructions = videoInstructions

            // Single-pass path: use animationTool (CALayer compositing).
            // customVideoCompositorClass is nil here, so animationTool is safe to set.
            if !overlaySegs.isEmpty {
                videoComposition.animationTool = await MainActor.run {
                    SubtitleLayerBuilder.build(
                        segments:      overlaySegs,
                        renderSize:    actualRenderSize,
                        totalDuration: totalDuration.seconds,
                        fontScale:     fontScale
                    )
                }
            }
        }

        // ── 3. Audio ─────────────────────────────────────────────────────────
        let (audioMix, audioTrackMap) = try await buildAudio(
            timeline:      timeline,
            composition:   composition,
            totalDuration: totalDuration
        )

        return CompositionResult(
            composition:      composition,
            videoComposition: videoComposition,
            audioMix:         audioMix,
            totalDuration:    totalDuration,
            audioTrackMap:    audioTrackMap
        )
    }

    // MARK: - Overlay segment collection

    /// Returns all subtitle and text segments from non-hidden tracks.
    /// v4 (audio-track-controls-spec §3.6): hidden tracks are skipped during export.
    private func collectOverlaySegments(timeline: EditorTimeline) -> [EditorSegment] {
        timeline.tracks.filter { !$0.isHidden }.flatMap(\.segments).filter {
            switch $0.content {
            case .subtitle, .text: return true
            default:               return false
            }
        }
    }

    // MARK: - Effect predicates

    private func needsColorAdjustment(timeline: EditorTimeline) -> Bool {
        timeline.mainTrack?.segments.contains(where: { !$0.adjustment.isIdentity }) ?? false
    }

    private func hasMainTransitions(timeline: EditorTimeline) -> Bool {
        guard !timeline.transitions.isEmpty else { return false }
        let mainIDs = Set((timeline.mainTrack?.segments ?? []).map(\.id))
        return timeline.transitions.contains {
            mainIDs.contains($0.leadingSegmentID) && mainIDs.contains($0.trailingSegmentID)
        }
    }

    /// V6 P2 Stage 4: true when the main track exists and every segment is `.image`.
    private func isImageOnlyMainTrack(_ timeline: EditorTimeline) -> Bool {
        let mainSegs = timeline.mainTrack?.segments ?? []
        return !mainSegs.isEmpty && mainSegs.allSatisfy {
            if case .image = $0.content { return true }
            return false
        }
    }

    // MARK: - Unified video track (Phase 1b)

    /// Builds one or two composition tracks + a contiguous [UnifiedCompositorInstruction] array.
    /// Handles all combinations of color adjustments × transitions.
    private func buildVideoTrackUnified(
        timeline:          EditorTimeline,
        composition:       AVMutableComposition,
        renderSize:        CGSize,
        totalDuration:     CMTime,
        mainVideoEnd:      CMTime,
        fps:               Double,
        skipImageOverlays: Bool = false
    ) async throws -> [UnifiedCompositorInstruction] {

        let segments    = timeline.mainTrack?.segments ?? []
        let sortedSegs  = segments.sorted { $0.targetRange.start < $1.targetRange.start }

        // Only keep transitions that connect adjacent main-track segments
        let mainIDs     = Set(sortedSegs.map(\.id))
        let transitions = timeline.transitions.filter {
            mainIDs.contains($0.leadingSegmentID) && mainIDs.contains($0.trailingSegmentID)
        }
        let outgoing    = Dictionary(uniqueKeysWithValues: transitions.map { ($0.leadingSegmentID,  $0) })
        let incoming    = Dictionary(uniqueKeysWithValues: transitions.map { ($0.trailingSegmentID, $0) })

        // Create trackA (always); trackB only when transitions exist
        guard let trackA = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw BuildError.cannotCreateVideoTrack }
        let trackAID = trackA.trackID

        // V5.1: 保留 mutable trackB 引用——`composition.track(withTrackID:)` 返回的是
        // `AVCompositionTrack?`（immutable），赋给 `[AVMutableCompositionTrack?]` 后
        // `insertTimeRange(_:of:at:)` 调用静默失败 → 转场播放卡在前一片段尾帧。
        var trackB:   AVMutableCompositionTrack? = nil
        var trackBID: CMPersistentTrackID?       = nil
        if !transitions.isEmpty {
            guard let tb = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw BuildError.cannotCreateVideoTrack }
            trackBID = tb.trackID
            trackB   = tb
        }

        // ── Compute insertion times (V7: no timeline compression) ────────────
        // Transitions are render-only visual blends; composition time == visual
        // timeline time.  Each segment starts immediately after the previous one.
        var insertionTimes = [Double](repeating: 0, count: sortedSegs.count)
        var cursor = 0.0
        for (i, seg) in sortedSegs.enumerated() {
            insertionTimes[i] = cursor
            cursor += seg.targetRange.duration
        }

#if DEBUG
        print("[CompositionBuilder] unified segs=\(sortedSegs.count) trans=\(transitions.count)")
#endif

        // ── Insert media into tracks ─────────────────────────────────────────
        // 直接用 line 270 保存的 mutable trackB 引用——不通过 composition.track(withTrackID:)
        // 重新查询（那会返回 immutable AVCompositionTrack，insertTimeRange 静默失败）。
        let compTracks: [AVMutableCompositionTrack?] = [trackA, trackB]

        // V6: Image segments insert a 1×1 transparent sentinel frame so the
        // composition track has media at every time point. Without it AVFoundation
        // may skip calling the custom compositor during continuous playback (the
        // track would be empty at image segment times — seek forces a render, so
        // it works, but play does not).
        var imageLayerMap: [UUID: ImageLayerSpec] = [:]

        // Load the sentinel once — a tiny 1×1 transparent MP4 cached to disk.
        let sentinelURL    = try? await SentinelAsset.url()
        let sentinelAsset  = sentinelURL.map { AVURLAsset(url: $0) }
        let sentinelTrack  = try? await sentinelAsset?.loadTracks(withMediaType: .video).first
        let sentinelSrcDur: CMTime = (try? await sentinelTrack?.load(.timeRange).duration)
            ?? CMTime(seconds: 1, preferredTimescale: 600)

        for (i, seg) in sortedSegs.enumerated() {
            let isEven  = (i % 2 == 0)
            let track   = (isEven || trackBID == nil) ? compTracks[0]! : compTracks[1]!
            let startCM = CMTime(seconds: insertionTimes[i], preferredTimescale: 600)

            if case .image(let imgContent) = seg.content {
                guard let imgURL = timeline.materials[seg.materialID]?.bestURL else { continue }
                // V6: Expand motionPreset/depthEffect → KeyframeSet when no explicit
                // keyframes exist (legacy drafts + AI imports that only specify type).
                let resolvedKeyframes: KeyframeSet? = {
                    if let kf = imgContent.keyframes { return kf }
                    let expanded = AnimationMacro.expand(
                        motionPreset: imgContent.motionPreset,
                        depthEffect: imgContent.depthEffect,
                        duration: seg.targetRange.duration
                    )
                    return expanded.isEmpty ? nil : expanded
                }()
                #if DEBUG
                print("[CB] type=image z=\(seg.sourceZIndex) keyframes=\(String(describing: resolvedKeyframes))")
                #endif
                imageLayerMap[seg.id] = ImageLayerSpec(
                    imageURL:    imgURL,
                    renderSize:  renderSize,
                    contentMode: imgContent.fit,
                    timeRange:   CMTimeRange(
                        start:    startCM,
                        duration: CMTime(seconds: seg.targetRange.duration, preferredTimescale: 600)
                    ),
                    keyframes:   resolvedKeyframes,
                    zPosition:   0,
                    baseOpacity: Float(seg.transform.opacity)
                )
#if DEBUG
                print("[CompositionBuilder] unified 🖼 resolvedKeyframes] ", resolvedKeyframes)
#endif
                // V6 Fix G: Insert 1×1 transparent sentinel frame so the track has media
                // at this time range, forcing AVFoundation to call startRequest during
                // continuous playback (not just seek). Without it the track is empty at
                // image segment times and the compositor may never fire.
                if let st = sentinelTrack, sentinelSrcDur.seconds > 0 {
                    let sr = CMTimeRange(start: .zero, duration: sentinelSrcDur)
                    try? track.insertTimeRange(sr, of: st, at: startCM)
                    let insertedRange = CMTimeRange(start: startCM, duration: sentinelSrcDur)
                    track.scaleTimeRange(insertedRange,
                                         toDuration: CMTime(seconds: seg.targetRange.duration,
                                                            preferredTimescale: 600))
                }
                continue
            }

            guard let url = await resolveSegmentURL(seg: seg, timeline: timeline,
                                                    renderSize: renderSize, fps: fps)
            else { continue }

            let avAsset = AssetCache.shared.asset(for: url)
            guard let assetTrack = try? await avAsset.loadTracks(withMediaType: .video).first
            else { continue }

            let (srcStart, srcDur) = srcRange(for: seg)
            // Clamp source duration to the actual asset track duration to prevent
            // insertTimeRange from failing silently when the rendered file is a tick
            // shorter than requested due to timescale rounding (try? swallows the error).
            let assetTrackDur = (try? await assetTrack.load(.timeRange).duration.seconds) ?? srcDur
            let clampedSrcDur = min(srcDur, assetTrackDur)
            let sr = CMTimeRange(
                start:    CMTime(seconds: srcStart,       preferredTimescale: 600),
                duration: CMTime(seconds: clampedSrcDur,  preferredTimescale: 600)
            )
            try? track.insertTimeRange(sr, of: assetTrack, at: startCM)

#if DEBUG
            print("[CompositionBuilder] unified ✅ seg[\(i)] track\(isEven || trackBID == nil ? "A" : "B") t=\(String(format:"%.2f",insertionTimes[i]))s")
#endif
        }

        // ── Build per-segment instructions ───────────────────────────────────

        // V6 Fix D: timeline → composition time mapping for overlay segments.
        // Main-track segments live at `insertionTimes[i]` (transition-compressed)
        // while overlay segments use raw `seg.targetRange.start` (timeline time).
        // Without remapping, scene_2's overlay (timeline t=5.0) never satisfies
        // ImageLayerComposer.evaluate's `compositionTime >= start` guard once
        // transitions shift the composition cursor (e.g. 4.7 at scene_2 start).
        //
        // For each scene we record (compStart, timelineStart) from the main-track
        // segment carrying that sourceSceneID; overlay segments inherit the same
        // shift so they share a clock with the main content.
        var sceneTiming: [String: (compStart: Double, timelineStart: Double)] = [:]
        for (i, seg) in sortedSegs.enumerated() {
            if let sceneID = seg.sourceSceneID {
                sceneTiming[sceneID] = (insertionTimes[i], seg.targetRange.start)
            }
        }

        func compStart(for seg: EditorSegment) -> Double {
            if let sceneID = seg.sourceSceneID, let t = sceneTiming[sceneID] {
                return t.compStart + (seg.targetRange.start - t.timelineStart)
            }
            return seg.targetRange.start
        }

        // V6: Collect overlay-track image segments as background layers (zPosition = -1).
        // They are composited behind the main content in every instruction they overlap.
        let overlayImageSpecs: [ImageLayerSpec] = timeline.tracks(ofKind: .overlay)
            .filter { !$0.isHidden }
            .flatMap { $0.segments }
            .compactMap { seg -> ImageLayerSpec? in
                guard case .image(let imgContent) = seg.content,
                      let imgURL = timeline.materials[seg.materialID]?.bestURL
                else { return nil }
                // V6 Fix D: Restore keyframe animation on overlay layers. The
                // previous "always static" strip was a guard against pan-induced
                // canvas drift before V6 Fix B introduced safeScale. With safeScale
                // in place, position / scale keyframes can no longer reveal the
                // canvas background, so background image_motion / image_3d
                // animations now play just like main-track image layers.
                let resolvedKeyframes: KeyframeSet? = {
                    if let kf = imgContent.keyframes { return kf }
                    let expanded = AnimationMacro.expand(
                        motionPreset: imgContent.motionPreset,
                        depthEffect:  imgContent.depthEffect,
                        duration:     seg.targetRange.duration
                    )
                    return expanded.isEmpty ? nil : expanded
                }()
                return ImageLayerSpec(
                    imageURL:    imgURL,
                    renderSize:  renderSize,
                    contentMode: imgContent.fit,
                    timeRange:   CMTimeRange(
                        start:    CMTime(seconds: compStart(for: seg), preferredTimescale: 600),
                        duration: CMTime(seconds: seg.targetRange.duration, preferredTimescale: 600)
                    ),
                    keyframes:   resolvedKeyframes,
                    zPosition:   -1,
                    baseOpacity: Float(seg.transform.opacity)
                )
            }

        var instructions: [UnifiedCompositorInstruction] = []

        for (i, seg) in sortedSegs.enumerated() {
            let isEven          = (i % 2 == 0)
            let segTrackID      = (isEven || trackBID == nil) ? trackAID : trackBID!
            let compStart       = insertionTimes[i]
            let outgoingTrans   = outgoing[seg.id]

            // V7: body spans the full segment — transition blending is render-only.
            // Timeline Runtime (TransitionComposer) handles blending; AVPlayer path
            // shows a hard cut at the boundary (acceptable for the legacy path).
            let bodyStart = compStart
            let bodyEnd   = compStart + seg.targetRange.duration

            if bodyStart < bodyEnd {
                // V6: Attach image layer payload when this segment is an image.
                var imageLayers: [ImageLayerSpec] = []
                if !skipImageOverlays {
                    if case .image = seg.content, let spec = imageLayerMap[seg.id] {
                        imageLayers.append(spec)
                    }
                    // Prepend overlay images that overlap this instruction's time range.
                    let instrEnd = bodyEnd
                    for overlay in overlayImageSpecs {
                        let os = overlay.timeRange.start.seconds
                        let oe = os + overlay.timeRange.duration.seconds
                        if os < instrEnd && oe > bodyStart {
                            imageLayers.append(overlay)
                        }
                    }
                    imageLayers.sort { $0.zPosition < $1.zPosition }
                }
                instructions.append(UnifiedCompositorInstruction(
                    timeRange:            cmRange(bodyStart, bodyEnd),
                    foregroundTrackID:    segTrackID,
                    foregroundAdjustment: seg.adjustment,
                    imageLayers:          imageLayers
                ))
            }

            // Transition to next segment (legacy AVPlayer path — best-effort only).
            // The Timeline Runtime handles actual transition blending; these instructions
            // define the time range for the AVFoundation compositor fallback.
            guard let trans = outgoingTrans, i + 1 < sortedSegs.count else { continue }
            let nextSeg     = sortedSegs[i + 1]
            let boundary    = insertionTimes[i + 1]           // segment boundary
            let clampedDur  = min(trans.duration,
                                  min(seg.targetRange.duration,
                                      nextSeg.targetRange.duration) * 0.5)
            let transStart  = boundary - clampedDur / 2
            let transEnd    = boundary + clampedDur / 2

            // Foreground = trackA throughout; opacity direction depends on which track is outgoing
            // Even i → A is outgoing (fades 1→0) ; Odd i → A is incoming (fades 0→1)
            let (fgAdj, bgAdj): (SegmentAdjustment, SegmentAdjustment)
            if isEven {
                fgAdj = seg.adjustment        // outgoing on trackA
                bgAdj = nextSeg.adjustment    // incoming on trackB
            } else {
                fgAdj = nextSeg.adjustment    // incoming on trackA
                bgAdj = seg.adjustment        // outgoing on trackB
            }

            // V6: Include overlay images overlapping the transition time range.
            var transImageLayers: [ImageLayerSpec] = []
            if !skipImageOverlays {
                for overlay in overlayImageSpecs {
                    let os = overlay.timeRange.start.seconds
                    let oe = os + overlay.timeRange.duration.seconds
                    if os < transEnd && oe > transStart {
                        transImageLayers.append(overlay)
                    }
                }
            }

            // Stage 0 Fix: For image→image transitions, populate the dedicated
            // transitionFg/BgImageSpec slots so the compositor can dissolve them
            // instead of rendering a black frame.
            //
            // fgSeg = the segment whose image is on the foreground track (trackA):
            //   • isEven → seg is outgoing (trackA); nextSeg is incoming (trackB)
            //   • !isEven → nextSeg is incoming (trackA); seg is outgoing (trackB)
            // This mirrors the fgAdj / bgAdj assignment above.
            let fgSegForTrans = isEven ? seg : nextSeg
            let bgSegForTrans = isEven ? nextSeg : seg
            var transFgImageSpec: ImageLayerSpec? = nil
            var transBgImageSpec: ImageLayerSpec? = nil
            if !skipImageOverlays {
                if case .image = fgSegForTrans.content,
                   let spec = imageLayerMap[fgSegForTrans.id] {
                    transFgImageSpec = spec
                }
                if case .image = bgSegForTrans.content,
                   let spec = imageLayerMap[bgSegForTrans.id] {
                    transBgImageSpec = spec
                }
            }

            instructions.append(UnifiedCompositorInstruction(
                timeRange:             cmRange(transStart, transEnd),
                foregroundTrackID:     trackAID,
                foregroundAdjustment:  fgAdj,
                backgroundTrackID:     trackBID!,
                backgroundAdjustment:  bgAdj,
                fgOpacityStart:        isEven ? 1 : 0,
                fgOpacityEnd:          isEven ? 0 : 1,
                easing:                trans.easing,
                imageLayers:           transImageLayers,
                transitionFgImageSpec: transFgImageSpec,
                transitionBgImageSpec: transBgImageSpec
            ))
        }

        return coverGapsUnified(
            instructions,
            trackID:            trackAID,
            totalDuration:      totalDuration,
            mainVideoEnd:       mainVideoEnd,
            overlayImageSpecs:  skipImageOverlays ? [] : overlayImageSpecs
        )
    }

    /// V5.1 BUG 1: 超过 `mainVideoEnd` 的尾段改用 `isBlackOut` 指令，渲染纯黑画面。
    /// V6: overlay image layers are included in non-blackout filler instructions so
    /// background images remain visible during gaps before `mainVideoEnd`.
    private func coverGapsUnified(
        _ instructions: [UnifiedCompositorInstruction],
        trackID:            CMPersistentTrackID,
        totalDuration:      CMTime,
        mainVideoEnd:       CMTime,
        overlayImageSpecs:  [ImageLayerSpec] = []
    ) -> [UnifiedCompositorInstruction] {
        // Minimum gap threshold: 1 frame @ 600 timescale (≈ 1.67ms).
        // Smaller gaps are swallowed into the adjacent instruction to avoid
        // zero-duration instructions that confuse AVFoundation.
        let minGap = CMTime(value: 1, timescale: 600)

        func makeFiller(start: CMTime, duration: CMTime) -> UnifiedCompositorInstruction {
            let isBlack = (start >= mainVideoEnd)
            // V6: Include overlapping overlay images in non-blackout fillers.
            let overlays: [ImageLayerSpec]
            if !isBlack && !overlayImageSpecs.isEmpty {
                let s = start.seconds
                let e = s + duration.seconds
                overlays = overlayImageSpecs.filter {
                    let os = $0.timeRange.start.seconds
                    let oe = os + $0.timeRange.duration.seconds
                    return os < e && oe > s
                }
            } else {
                overlays = []
            }
            return UnifiedCompositorInstruction(
                timeRange:         CMTimeRange(start: start, duration: duration),
                foregroundTrackID: trackID,
                isBlackOut:        isBlack,
                imageLayers:       overlays
            )
        }

        guard !instructions.isEmpty else {
            let filler = makeFiller(start: .zero, duration: totalDuration)
            return filler.timeRange.duration >= minGap ? [filler] : []
        }
        var result: [UnifiedCompositorInstruction] = []
        var cursor = CMTime.zero
        for instr in instructions.sorted(by: { $0.timeRange.start < $1.timeRange.start }) {
            let gapDur = CMTimeSubtract(instr.timeRange.start, cursor)
            if gapDur >= minGap {
                result.append(makeFiller(start: cursor, duration: gapDur))
            }
            result.append(instr)
            cursor = CMTimeAdd(instr.timeRange.start, instr.timeRange.duration)
        }
        let tailDur = CMTimeSubtract(totalDuration, cursor)
        if tailDur >= minGap {
            result.append(makeFiller(start: cursor, duration: tailDur))
        }
        return result
    }

    private func cmRange(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start:    CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: end - start, preferredTimescale: 600))
    }

    // MARK: Single-pass (no transitions)

    /// V5.1 增补修复（2026-05-19）：彻底重构尾部 / overlay 渲染——
    ///
    /// 旧方案（已废弃）使用 `setOpacity(0, at: mainVideoEnd)` 让主层在尾段透明，依赖
    /// `backgroundColor` 透出黑屏。该方案对 image_motion / image_3d 的 MP4 不可靠：
    /// AVFoundation 对带 sentinel 帧的图片轨会「冻结最后一帧」，setOpacity 改不掉已
    /// 栅格化的尾帧（表现为主轨结束后看到上一片段尾帧不消失）。
    ///
    /// 新方案：按 `mainVideoEnd` 切分成两个 AVMutableVideoCompositionInstruction，
    /// 不同时段挂不同的 layerInstructions：
    ///   1. `[0, mainVideoEnd]`     — 包含主层（+ overlay 层在底）
    ///   2. `[mainVideoEnd, total]` — 只挂 overlay 层（若有），否则 layerInstructions=[]
    ///      让 `instruction.backgroundColor = black` 唯一输出，AVFoundation 无 layer 可
    ///      冻结 → 强制黑屏。
    ///
    /// overlay 段（kind=.overlay）走独立的 composition video track，作为永久背景层
    /// 出现在主层下方。删除主轨道尾段不再黑屏 —— overlay 自动透出。
    private func buildVideoTrackSinglePass(
        timeline:              EditorTimeline,
        composition:           AVMutableComposition,
        renderSize:            CGSize,
        totalDuration:         CMTime,
        mainVideoEnd:          CMTime,
        backgroundOverlaySegs: [EditorSegment],
        fps:                   Double
    ) async throws -> [AVMutableVideoCompositionInstruction] {

        // ── 1) Main video track（按 main 段构建）────────────────────────────
        guard let mainTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw BuildError.cannotCreateVideoTrack }

        let mainLayerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: mainTrack)
        let mainSegs = timeline.mainTrack?.segments ?? []
        var mainInsertedAny = false

        for seg in mainSegs {
            let inserted = await insertSegment(
                seg: seg,
                into: mainTrack,
                timeline: timeline,
                renderSize: renderSize,
                fps: fps,
                layerInstruction: mainLayerInstruction,
                applyTransform: true
            )
            if inserted { mainInsertedAny = true }
        }

        // ── 2) Overlay video track（仅当 overlay 段非空时创建）──────────────
        var overlayLayerInstruction: AVMutableVideoCompositionLayerInstruction? = nil
        var overlayMaxEnd: Double = 0
        if !backgroundOverlaySegs.isEmpty {
            if let overlayTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: overlayTrack)
                for seg in backgroundOverlaySegs {
                    let inserted = await insertSegment(
                        seg: seg,
                        into: overlayTrack,
                        timeline: timeline,
                        renderSize: renderSize,
                        fps: fps,
                        layerInstruction: li,
                        applyTransform: false   // overlay 段使用 identity；与 v3/v4 行为一致
                    )
                    if inserted {
                        overlayMaxEnd = max(overlayMaxEnd, seg.targetRange.end)
                    }
                }
                overlayLayerInstruction = li
            }
        }

        // ── 3) Instruction 切分（按 mainVideoEnd 一刀切）────────────────────
        // 不再使用 setOpacity(0, at: mainVideoEnd) 技巧——直接用 timeRange 边界，
        // AVFoundation 在 tailInstr 时段没有主层可冻结。
        let minDur = CMTime(value: 1, timescale: 600)
        let zeroToMain = CMTimeRange(start: .zero, duration: mainVideoEnd)
        let mainToTotal = CMTimeRange(
            start:    mainVideoEnd,
            duration: CMTimeSubtract(totalDuration, mainVideoEnd)
        )

        var result: [AVMutableVideoCompositionInstruction] = []

        // 3a) 主段区间 [0, mainVideoEnd]
        if mainInsertedAny && zeroToMain.duration >= minDur {
            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange       = zeroToMain
            inst.backgroundColor = UIColor.black.cgColor
            // overlay 在下，main 在上（layerInstructions 数组顺序：先=底，后=顶）
            var layers: [AVMutableVideoCompositionLayerInstruction] = []
            if let overlay = overlayLayerInstruction { layers.append(overlay) }
            layers.append(mainLayerInstruction)
            inst.layerInstructions = layers
            result.append(inst)
        }

        // 3b) 尾段区间 [mainVideoEnd, totalDuration]
        if mainToTotal.duration >= minDur {
            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange       = mainToTotal
            inst.backgroundColor = UIColor.black.cgColor
            // 只挂 overlay 层；若 overlay 已不覆盖该范围，AVFoundation 用 backgroundColor 黑屏
            if let overlay = overlayLayerInstruction,
               overlayMaxEnd > mainVideoEnd.seconds {
                inst.layerInstructions = [overlay]
            } else {
                inst.layerInstructions = []
            }
            result.append(inst)
        }

        // 3c) 边界情况：主轨完全空 + 没有 overlay → 兜底全段黑屏 instruction
        if result.isEmpty {
            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange       = CMTimeRange(start: .zero, duration: totalDuration)
            inst.backgroundColor = UIColor.black.cgColor
            inst.layerInstructions = []
            result.append(inst)
        }

#if DEBUG
        print("[CompositionBuilder] single-pass V5.1: mainEnd=\(String(format:"%.2f",mainVideoEnd.seconds))s total=\(String(format:"%.2f",totalDuration.seconds))s mainSegs=\(mainSegs.count) overlaySegs=\(backgroundOverlaySegs.count) overlayMaxEnd=\(String(format:"%.2f",overlayMaxEnd))s instr=\(result.count)")
#endif

        return result
    }

    /// 把一个 EditorSegment 插入到指定 composition video track，并按需设置 layerInstruction
    /// 的 transform / opacity 关键帧。返回是否成功插入（用于上层 insertedAny 统计）。
    /// V5.1: 抽出 main / overlay 两个轨道的共享插入逻辑。
    private func insertSegment(
        seg:              EditorSegment,
        into track:       AVMutableCompositionTrack,
        timeline:         EditorTimeline,
        renderSize:       CGSize,
        fps:              Double,
        layerInstruction: AVMutableVideoCompositionLayerInstruction,
        applyTransform:   Bool
    ) async -> Bool {
        // V6: Image segments not supported in single-pass path (unified path only).
        if case .image = seg.content { return false }

        guard let url = await resolveSegmentURL(
            seg: seg, timeline: timeline, renderSize: renderSize, fps: fps
        ) else {
#if DEBUG
            print("[CompositionBuilder] single-pass: no URL for seg \(seg.id)")
#endif
            return false
        }

        let avAsset = AssetCache.shared.asset(for: url)
        guard let assetTrack = try? await avAsset.loadTracks(withMediaType: .video).first
        else {
#if DEBUG
            print("[CompositionBuilder] single-pass: no video track in asset \(url.lastPathComponent)")
#endif
            return false
        }

        let (sourceStart, sourceDuration) = srcRange(for: seg)
        let assetTrackDur = (try? await assetTrack.load(.timeRange).duration.seconds) ?? sourceDuration
        let clampedSrcDur = min(sourceDuration, assetTrackDur)
        let srcTimeRange = CMTimeRange(
            start:    CMTime(seconds: sourceStart,   preferredTimescale: 600),
            duration: CMTime(seconds: clampedSrcDur, preferredTimescale: 600)
        )
        let targetAt = CMTime(seconds: seg.targetRange.start, preferredTimescale: 600)

        do {
            try track.insertTimeRange(srcTimeRange, of: assetTrack, at: targetAt)
            // 图片段被拉伸时把媒体 scale 到 targetRange 全程
            if case .image = seg.content, clampedSrcDur < sourceDuration {
                let insertedRange  = CMTimeRange(start: targetAt, duration: srcTimeRange.duration)
                let scaledDuration = CMTime(seconds: sourceDuration, preferredTimescale: 600)
                try? track.scaleTimeRange(insertedRange, toDuration: scaledDuration)
            }
        } catch {
#if DEBUG
            print("[CompositionBuilder] single-pass: insertTimeRange failed seg=\(seg.id): \(error)")
#endif
            return false
        }

        if applyTransform {
            let segTransform: CGAffineTransform
            if case .image = seg.content {
                segTransform = .identity
            } else {
                do {
                    segTransform = try await coverFitTransform(
                        assetTrack: assetTrack, renderSize: renderSize, segmentTransform: seg.transform
                    )
                } catch {
                    segTransform = .identity
                }
            }
            let keyTime = CMTime(seconds: seg.targetRange.start, preferredTimescale: 600)
            layerInstruction.setTransform(segTransform, at: keyTime)
            layerInstruction.setOpacity(Float(seg.transform.opacity), at: keyTime)
        }

        return true
    }

    // MARK: - Helpers

    /// Resolves the source URL for a segment (renders static images to video on demand).
    private func resolveSegmentURL(
        seg:        EditorSegment,
        timeline:   EditorTimeline,
        renderSize: CGSize,
        fps:        Double
    ) async -> URL? {
        switch seg.content {
        case .video:
            return timeline.materials[seg.materialID]?.bestURL
        case .image:
            // V6: Images rendered via ImageLayerComposer in UnifiedCompositor — no prebake.
            return nil
        default:
            return nil
        }
    }

    /// Returns (sourceStart, sourceDuration) for a segment.
    private func srcRange(for seg: EditorSegment) -> (start: Double, duration: Double) {
        if case .image = seg.content {
            return (0, seg.targetRange.duration)
        }
        // Always use targetRange.duration: sourceRange.duration is frozen at replacement time
        // and becomes stale after the user trims/extends the segment.
        return (seg.sourceRange?.start ?? 0, seg.targetRange.duration)
    }

    // MARK: - Cover-Fit Transform

    private func coverFitTransform(
        assetTrack:       AVAssetTrack,
        renderSize:       CGSize,
        segmentTransform: SegmentTransform
    ) async throws -> CGAffineTransform {

        let naturalSize        = try await assetTrack.load(.naturalSize)
        let preferredTransform = try await assetTrack.load(.preferredTransform)

        // Display size after applying preferredTransform (accounts for rotation/flip)
        let displaySize = naturalSize.applying(preferredTransform)
        let dw = abs(displaySize.width)
        let dh = abs(displaySize.height)
        guard dw > 0, dh > 0 else { return .identity }

        // Cover scale × segment-level scale
        let coverScale = max(renderSize.width / dw, renderSize.height / dh)
        let s          = coverScale * max(segmentTransform.scale, 0.01)

        // Center offset + position nudge (normalized 0..1 → pixels)
        let txCenter = (renderSize.width  - dw * s) / 2
        let tyCenter = (renderSize.height - dh * s) / 2
        let txNudge  = (segmentTransform.position.x - 0.5) * renderSize.width
        let tyNudge  = (segmentTransform.position.y - 0.5) * renderSize.height
        let tx = txCenter + txNudge
        let ty = tyCenter + tyNudge

        // Compose: scale the preferredTransform matrix, then add translation
        var t = CGAffineTransform(
            a:  preferredTransform.a * s,
            b:  preferredTransform.b * s,
            c:  preferredTransform.c * s,
            d:  preferredTransform.d * s,
            tx: preferredTransform.tx * s + tx,
            ty: preferredTransform.ty * s + ty
        )

        // Rotation (around canvas center)
        if segmentTransform.rotation != 0 {
            let cx = renderSize.width  / 2
            let cy = renderSize.height / 2
            t = t
                .translatedBy(x: cx, y: cy)
                .rotated(by: CGFloat(segmentTransform.rotation))
                .translatedBy(x: -cx, y: -cy)
        }

        return t
    }

    // MARK: - Audio

    private func buildAudio(
        timeline:      EditorTimeline,
        composition:   AVMutableComposition,
        totalDuration: CMTime
    ) async throws -> (AVMutableAudioMix, [UUID: CMPersistentTrackID]) {

        let audioMix   = AVMutableAudioMix()
        var parameters = [AVMutableAudioMixInputParameters]()
        var trackMap   = [UUID: CMPersistentTrackID]()   // EditorTrack.id → comp track ID

        let totalSecs = totalDuration.seconds

        // Dedicated audio tracks (BGM, voice-over)
        // v4: skip hidden audio tracks entirely (剪映 semantics).
        for track in timeline.tracks where track.kind == .audio && !track.isHidden {
            guard let compAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            trackMap[track.id] = compAudioTrack.trackID

            for seg in track.segments {
                guard let asset = timeline.materials[seg.materialID],
                      let url   = asset.bestURL else { continue }

                let avAsset     = AssetCache.shared.asset(for: url)
                let audioTracks = try await avAsset.loadTracks(withMediaType: .audio)
                guard let srcTrack = audioTracks.first else { continue }

                // v3 P0 (audio-feature-spec §8): apply EditorSegment.speed to .audio segments.
                // target duration = source duration / speed → source duration = target * speed.
                // After insertTimeRange we scaleTimeRange the inserted block back to target duration.
                let speed     = min(max(seg.speed, 0.3), 3.0)
                let srcStart  = seg.sourceRange?.start ?? 0
                let targetDur = seg.targetRange.duration
                let srcDur    = targetDur * speed

                let isLooping: Bool
                if case .audio(let c) = seg.content { isLooping = c.isLooping } else { isLooping = false }

                if isLooping {
                    // Repeat the source clip until it fills totalDuration. Speed is applied
                    // to each loop chunk individually so the effective clock-time per loop
                    // matches `targetDur`.
                    var insertedEnd = seg.targetRange.start
                    while insertedEnd < totalSecs {
                        let remaining       = totalSecs - insertedEnd
                        let chunkTargetDur  = min(targetDur, remaining)
                        let chunkSrcSlice   = chunkTargetDur * speed
                        let chunkRange = CMTimeRange(
                            start:    CMTime(seconds: srcStart, preferredTimescale: 600),
                            duration: CMTime(seconds: chunkSrcSlice, preferredTimescale: 600)
                        )
                        let targetAt = CMTime(seconds: insertedEnd, preferredTimescale: 600)
                        try? compAudioTrack.insertTimeRange(chunkRange, of: srcTrack, at: targetAt)
                        if abs(speed - 1.0) > 1e-3 {
                            let insertedRange = CMTimeRange(
                                start:    targetAt,
                                duration: CMTime(seconds: chunkSrcSlice, preferredTimescale: 600)
                            )
                            compAudioTrack.scaleTimeRange(
                                insertedRange,
                                toDuration: CMTime(seconds: chunkTargetDur, preferredTimescale: 600)
                            )
                        }
                        insertedEnd += chunkTargetDur
                    }
                } else {
                    let srcRange = CMTimeRange(
                        start:    CMTime(seconds: srcStart, preferredTimescale: 600),
                        duration: CMTime(seconds: srcDur,   preferredTimescale: 600)
                    )
                    let targetAt = CMTime(seconds: seg.targetRange.start, preferredTimescale: 600)
                    try? compAudioTrack.insertTimeRange(srcRange, of: srcTrack, at: targetAt)
                    if abs(speed - 1.0) > 1e-3 {
                        let insertedRange = CMTimeRange(
                            start:    targetAt,
                            duration: CMTime(seconds: srcDur, preferredTimescale: 600)
                        )
                        compAudioTrack.scaleTimeRange(
                            insertedRange,
                            toDuration: CMTime(seconds: targetDur, preferredTimescale: 600)
                        )
                    }
                }
            }

            // v3 P3 (audio-feature-spec §10.4): per-segment volume via setVolume(_:at:)
            // keyframes so multiple segments on the same track each render at their own
            // volume (the legacy "first segment wins" rule silently dropped later segments'
            // settings).
            let p = AVMutableAudioMixInputParameters(track: compAudioTrack)
            Self.applyPerSegmentVolume(track: track, on: p)
            parameters.append(p)
        }

        // Video track native audio (un-muted video segments)
        for track in timeline.tracks where track.isMainTrack {
            let audioSegs = track.segments.filter {
                if case .video(let c) = $0.content { return !c.isMuted }
                return false
            }
            guard !audioSegs.isEmpty else { continue }
            guard let compAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            trackMap[track.id] = compAudioTrack.trackID

            for seg in audioSegs {
                guard let asset = timeline.materials[seg.materialID],
                      let url   = asset.bestURL else { continue }

                let avAsset     = AssetCache.shared.asset(for: url)
                let audioTracks = try await avAsset.loadTracks(withMediaType: .audio)
                guard let srcTrack = audioTracks.first else { continue }

                let srcStart    = seg.sourceRange?.start ?? 0
                let srcDuration = seg.targetRange.duration
                let srcRange    = CMTimeRange(
                    start:    CMTime(seconds: srcStart,    preferredTimescale: 600),
                    duration: CMTime(seconds: srcDuration, preferredTimescale: 600)
                )
                let targetAt = CMTime(seconds: seg.targetRange.start, preferredTimescale: 600)
                try? compAudioTrack.insertTimeRange(srcRange, of: srcTrack, at: targetAt)
            }

            let nativeVolume: Float = track.isMuted ? 0 : 1.0
            let p = AVMutableAudioMixInputParameters(track: compAudioTrack)
            p.setVolume(nativeVolume, at: .zero)
            parameters.append(p)
        }

        // Duration anchor for timelines whose tail is not backed by real media.
        // Rationale: AVPlayer needs REAL decodable media (audio or video samples) to
        // advance currentTime(). buildVideoTrackUnified inserts only a 1×1 transparent
        // sentinel into the video track for image segments — that occupies a track
        // slot but doesn't reliably drive the player clock during continuous playback.
        // Mixed video→image tails are the important case: the composition contains
        // real video earlier, but AVPlayer's clock still stops at the final real
        // sample unless a decodable track spans the image-only tail.
        if needsSilentDurationAnchor(timeline: timeline, totalDuration: totalDuration) {
            await insertSilentAnchorTrack(
                composition:   composition,
                totalDuration: totalDuration,
                parameters:    &parameters
            )
        }

        audioMix.inputParameters = parameters
        return (audioMix, trackMap)
    }

    private func needsSilentDurationAnchor(
        timeline: EditorTimeline,
        totalDuration: CMTime
    ) -> Bool {
        let totalSeconds = totalDuration.seconds
        guard totalSeconds.isFinite, totalSeconds > 0 else { return false }

        var clockEnd = 0.0

        // Real video samples on the main track can drive AVPlayer's clock.
        for seg in timeline.mainTrack?.segments ?? [] {
            if case .video = seg.content {
                clockEnd = max(clockEnd, seg.targetRange.end)
            }
        }

        // Dedicated audio tracks also drive the clock.
        for track in timeline.tracks where track.kind == .audio && !track.isHidden {
            for seg in track.segments {
                clockEnd = max(clockEnd, seg.targetRange.end)
            }
        }

        // Unmuted native video audio can drive the clock too. Muted video still
        // counts above as real video, so this mainly covers audio-only source edge
        // cases consistently with buildAudio's native-audio insertion.
        for track in timeline.tracks where track.isMainTrack {
            for seg in track.segments {
                if case .video(let content) = seg.content, !content.isMuted {
                    clockEnd = max(clockEnd, seg.targetRange.end)
                }
            }
        }

        let needsAnchor = clockEnd < totalSeconds - 0.001
#if DEBUG
        if needsAnchor {
            print("[CompositionBuilder] silent anchor needed: clockEnd=\(String(format: "%.4f", clockEnd)) total=\(String(format: "%.4f", totalSeconds))")
        }
#endif
        return needsAnchor
    }

    /// Generates (or returns the cached) 1-second silent PCM audio file in the
    /// system temp directory. Used as the duration anchor for image-only / text-only
    /// timelines that have no real audio content, so AVPlayer gets a decodable audio
    /// stream and player.currentTime() advances properly during playback.
    private static func silentAudioFileURL() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("timelinekit_silence_anchor.caf")
        if FileManager.default.fileExists(atPath: url.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 0 { return url }
            try? FileManager.default.removeItem(at: url)
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)
        else { return nil }
        buffer.frameLength = 44100  // 1 second of silence (floats are zero by default)

        do {
            // AVAudioFile flushes & closes when it goes out of scope. Wrap in a
            // do-block so the file is released before we return the URL.
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            return url
        } catch {
#if DEBUG
            print("[CompositionBuilder] silentAudioFileURL write failed: \(error)")
#endif
            return nil
        }
    }

    /// Build the silent audio anchor track and append its audioMix parameters.
    /// Uses loop-insert of a 1-second clip (no scaleTimeRange) because stretching
    /// a 1s PCM clip 15× with scaleTimeRange leaves AVPlayerItem.duration == 0
    /// in practice — AVPlayer can't derive a playback clock from such a track.
    /// Instance method (not static) so the non-Sendable AVMutableComposition stays
    /// inside the CompositionBuilder actor's isolation domain.
    private func insertSilentAnchorTrack(
        composition:   AVMutableComposition,
        totalDuration: CMTime,
        parameters:    inout [AVMutableAudioMixInputParameters]
    ) async {
        guard let silenceURL = CompositionBuilder.silentAudioFileURL() else {
#if DEBUG
            print("[CompositionBuilder] silent anchor: silentAudioFileURL returned nil")
#endif
            return
        }
#if DEBUG
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: silenceURL.path)[.size] as? Int) ?? 0
        print("[CompositionBuilder] silent anchor: file=\(silenceURL.lastPathComponent) size=\(fileSize)")
#endif
        let silenceAsset = AVURLAsset(url: silenceURL)
        guard let silenceTrack = try? await silenceAsset.loadTracks(withMediaType: .audio).first else {
#if DEBUG
            print("[CompositionBuilder] silent anchor: loadTracks failed")
#endif
            return
        }
        let silenceSrcDur = (try? await silenceTrack.load(.timeRange).duration)
            ?? CMTime(seconds: 1.0, preferredTimescale: 600)
        guard let anchor = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
#if DEBUG
            print("[CompositionBuilder] silent anchor: addMutableTrack failed")
#endif
            return
        }

        let totalSecs = totalDuration.seconds
        let chunkSecs = silenceSrcDur.seconds > 0 ? silenceSrcDur.seconds : 1.0
        var cursor: Double = 0
        var insertCount = 0
        while cursor < totalSecs {
            let remaining = totalSecs - cursor
            let chunkDur  = min(chunkSecs, remaining)
            let srcRange = CMTimeRange(
                start:    .zero,
                duration: CMTime(seconds: chunkDur, preferredTimescale: 600)
            )
            let at = CMTime(seconds: cursor, preferredTimescale: 600)
            do {
                try anchor.insertTimeRange(srcRange, of: silenceTrack, at: at)
                insertCount += 1
            } catch {
#if DEBUG
                print("[CompositionBuilder] silent anchor: insertTimeRange failed at \(cursor)s: \(error)")
#endif
                break
            }
            cursor += chunkDur
        }

        let p = AVMutableAudioMixInputParameters(track: anchor)
        p.setVolume(0, at: .zero)
        parameters.append(p)
#if DEBUG
        print("[CompositionBuilder] silent anchor: inserted \(insertCount) chunks, anchor.duration=\(anchor.timeRange.duration.seconds)s, composition.duration=\(composition.duration.seconds)s")
#endif
    }

    /// v3 P3 (audio-feature-spec §10.4): bake per-segment volume into the audio
    /// mix parameters via `setVolume(_:at:)` keyframes. Each segment's
    /// `AudioContent.volume` (or 0 when isMuted) takes effect at its
    /// `targetRange.start`; the value persists until the next keyframe.
    /// Track-level mute or hide zeroes everything regardless of per-segment values.
    ///
    /// v4 (audio-track-controls-spec §2.3): fade-in/out via `setVolumeRamp` with a
    /// mid-plateau `setVolume`. Ramp and instant keyframes are written in order so
    /// the mid-plateau setVolume overrides the ramp tail, and fade-out ramp overrides
    /// the plateau at segment end.
    ///
    /// Shared by both `buildAudio` (actor) and `buildAudioMixOnly`
    /// (nonisolated) so preview and export behave identically.
    public nonisolated static func applyPerSegmentVolume(
        track: EditorTrack,
        on parameters: AVMutableAudioMixInputParameters
    ) {
        // v4: isHidden also silences the track (剪映 semantics).
        if track.isMuted || track.isHidden {
            parameters.setVolume(0, at: .zero)
            return
        }
        parameters.setVolume(0, at: .zero)
        let sorted = track.segments.sorted { $0.targetRange.start < $1.targetRange.start }
        for seg in sorted {
            guard case .audio(let c) = seg.content else { continue }
            if c.isMuted {
                parameters.setVolume(0, at: CMTime(seconds: seg.targetRange.start, preferredTimescale: 600))
                continue
            }
            let vol: Float = Float(c.volume)
            let segStart   = seg.targetRange.start
            let segEnd     = seg.targetRange.end
            let segDur     = seg.targetRange.duration
            let fadeIn     = min(c.fadeInDuration, segDur / 2)
            let fadeOut    = min(c.fadeOutDuration, segDur - fadeIn)

            // Fade-in ramp: 0 → vol
            if fadeIn > 0 {
                parameters.setVolumeRamp(
                    fromStartVolume: 0,
                    toEndVolume:     vol,
                    timeRange: CMTimeRange(
                        start:    CMTime(seconds: segStart, preferredTimescale: 600),
                        duration: CMTime(seconds: fadeIn,  preferredTimescale: 600)
                    )
                )
            } else {
                parameters.setVolume(vol, at: CMTime(seconds: segStart, preferredTimescale: 600))
            }

            // Mid plateau (instant set to ensure clean level between ramps).
            let plateauStart = segStart + fadeIn
            let plateauEnd   = segEnd - fadeOut
            if plateauEnd > plateauStart {
                parameters.setVolume(vol, at: CMTime(seconds: plateauStart, preferredTimescale: 600))
            }

            // Fade-out ramp: vol → 0
            if fadeOut > 0 {
                parameters.setVolumeRamp(
                    fromStartVolume: vol,
                    toEndVolume:     0,
                    timeRange: CMTimeRange(
                        start:    CMTime(seconds: plateauEnd, preferredTimescale: 600),
                        duration: CMTime(seconds: fadeOut,    preferredTimescale: 600)
                    )
                )
            }
        }
    }

    /// Rebuild only the AVMutableAudioMix for an existing composition.
    /// Used by CompositionCoordinator.applyAudioMixOnly to handle mute/volume
    /// changes without replacing the AVPlayerItem.
    public nonisolated func buildAudioMixOnly(
        timeline:      EditorTimeline,
        composition:   AVMutableComposition,
        audioTrackMap: [UUID: CMPersistentTrackID],
        totalDuration: CMTime
    ) -> AVMutableAudioMix {
        let audioMix   = AVMutableAudioMix()
        var parameters = [AVMutableAudioMixInputParameters]()

        // Dedicated audio tracks — per-segment keyframe (mirrors build path, v3 P3).
        // v4: skip hidden audio tracks.
        for track in timeline.tracks where track.kind == .audio && !track.isHidden {
            guard let compTrackID = audioTrackMap[track.id],
                  let compTrack   = composition.track(withTrackID: compTrackID) else { continue }

            let p = AVMutableAudioMixInputParameters(track: compTrack)
            Self.applyPerSegmentVolume(track: track, on: p)
            parameters.append(p)
        }

        // Video native audio
        for track in timeline.tracks where track.isMainTrack {
            guard let compTrackID = audioTrackMap[track.id],
                  let compTrack   = composition.track(withTrackID: compTrackID) else { continue }

            let p = AVMutableAudioMixInputParameters(track: compTrack)
            p.setVolume(track.isMuted ? 0 : 1.0, at: .zero)
            parameters.append(p)
        }

        audioMix.inputParameters = parameters
        return audioMix
    }
}

// MARK: - SubtitleLayerBuilder (MainActor)

/// Builds the CALayer tree for subtitle + text tracks.
/// Must run on MainActor — CALayer is not thread-safe.
@MainActor
enum SubtitleLayerBuilder {

    static func build(
        segments:      [EditorSegment],
        renderSize:    CGSize,
        totalDuration: Double,
        fontScale:     CGFloat = 1.0
    ) -> AVVideoCompositionCoreAnimationTool? {
        guard !segments.isEmpty, totalDuration > 0 else { return nil }

        let parentLayer = CALayer()
        parentLayer.frame            = CGRect(origin: .zero, size: renderSize)
        parentLayer.isGeometryFlipped = true  // CoreVideo coordinate system

        let videoLayer  = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        // Build a time-overlap map for stacking offset (spec §5.1).
        // For each subtitle segment, count how many earlier segments overlap with it.
        let subtitleSegs = segments.filter {
            if case .subtitle = $0.content { return true }; return false
        }.sorted { $0.targetRange.start < $1.targetRange.start }

        var stackIndex: [UUID: Int] = [:]
        for (i, seg) in subtitleSegs.enumerated() {
            var depth = 0
            for earlier in subtitleSegs.prefix(i) {
                if earlier.targetRange.end > seg.targetRange.start { depth += 1 }
            }
            stackIndex[seg.id] = depth
        }

        // v4 (text-typography-spec §5.2): composite zPosition = (userZOrder ?? stackDepth, time, id).
        var segmentZPosition: [UUID: CGFloat] = [:]
        for seg in segments {
            guard seg.isSubtitle || seg.isText else { continue }
            let baseZ = CGFloat(seg.userZOrder ?? (stackIndex[seg.id] ?? 0))
            let tiebreak = CGFloat(seg.targetRange.start / max(totalDuration, 0.001)) * 0.001
            segmentZPosition[seg.id] = baseZ + tiebreak
        }

        for seg in segments {
            let zPos = segmentZPosition[seg.id]
            switch seg.content {
            case .subtitle(let c):
                addSubtitleLayer(c, segment: seg, parent: parentLayer,
                                 renderSize: renderSize, totalDuration: totalDuration,
                                 stackDepth: stackIndex[seg.id] ?? 0, zPosition: zPos,
                                 fontScale: fontScale)
            case .text(let c):
                addTextLayer(c, segment: seg, parent: parentLayer,
                             renderSize: renderSize, totalDuration: totalDuration,
                             zPosition: zPos, fontScale: fontScale)
            default:
                break
            }
        }

        return AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
    }

    // MARK: - Subtitle (v4: full 12-field consumption via NSAttributedString)

    private static func addSubtitleLayer(
        _ content: SegmentContent.SubtitleContent,
        segment:      EditorSegment,
        parent:       CALayer,
        renderSize:   CGSize,
        totalDuration: Double,
        stackDepth:   Int = 0,
        zPosition:    CGFloat? = nil,
        fontScale:    CGFloat = 1.0
    ) {
        let style    = content.style
        let padH     = CGFloat(style.paddingH > 0 ? style.paddingH : 20) * fontScale
        let padV     = CGFloat(style.paddingV > 0 ? style.paddingV : 10) * fontScale
        let bgRadius = CGFloat(style.backgroundRadius > 0 ? style.backgroundRadius : 4) * fontScale
        // Subtitle preserves v3 dark-pill default when user hasn't set a bg.
        let bgHex    = style.backgroundColor ?? "#00000000"

        // Build attributed string with full 12-field attrs (mirrors export-side
        // renderSubtitle / renderText logic).
        let attributed = buildAttributedString(text: content.text, style: style, fontScale: fontScale)

        // Measure with CoreText to honor wrapping, kerning, italic, stroke.
        let maxWidth = renderSize.width - 120 * fontScale
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let (textSize, _) = SubtitleFrameBuilder.measureTextLayout(
            framesetter: framesetter, constraintWidth: maxWidth)
        guard textSize.width > 0, textSize.height > 0 else { return }

        // Pill size + stacking
        let stackGap: CGFloat = 8 * fontScale
        let bgW = min(textSize.width + padH * 2, renderSize.width - 40 * fontScale)
        let bgH = textSize.height + padV * 2

        let centreY: CGFloat = content.positionY.map {
            renderSize.height * CGFloat($0)
        } ?? (renderSize.height - bgH / 2 - 60 * fontScale)
        let bgY = centreY - bgH / 2 - CGFloat(stackDepth) * (bgH + stackGap)
        let bgX = (renderSize.width - bgW) / 2

        // Build the container + sublayers and attach to parent.
        let container = makeTextContainerLayer(
            frame:      CGRect(x: bgX, y: bgY, width: bgW, height: bgH),
            attributed: attributed,
            textSize:   textSize,
            padH:       padH,
            padV:       padV,
            bgHex:      bgHex,
            bgRadius:   bgRadius,
            style:      style,
            fontScale:  fontScale
        )
        if let zPos = zPosition { container.zPosition = zPos }
        parent.addSublayer(container)
        applyVisibility(to: container,
                        start: segment.targetRange.start,
                        end:   segment.targetRange.end,
                        totalDuration: totalDuration)
    }

    // MARK: - Text (v4: full 12-field consumption via NSAttributedString)

    private static func addTextLayer(
        _ content: SegmentContent.TextContent,
        segment:      EditorSegment,
        parent:       CALayer,
        renderSize:   CGSize,
        totalDuration: Double,
        zPosition:    CGFloat? = nil,
        fontScale:    CGFloat = 1.0
    ) {
        let style    = content.style
        let padH     = CGFloat(style.paddingH) * fontScale
        let padV     = CGFloat(style.paddingV) * fontScale
        let bgRadius = CGFloat(style.backgroundRadius) * fontScale

        let attributed = buildAttributedString(text: content.text, style: style, fontScale: fontScale)

        let maxWidth = renderSize.width - 120 * fontScale
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let (textSize, _) = SubtitleFrameBuilder.measureTextLayout(
            framesetter: framesetter, constraintWidth: maxWidth)
        guard textSize.width > 0, textSize.height > 0 else { return }

        let bgW = min(textSize.width + padH * 2, renderSize.width - 40 * fontScale)
        let bgH = textSize.height + padV * 2
        let cx  = renderSize.width  * CGFloat(content.position.x)
        let cy  = renderSize.height * CGFloat(content.position.y)

        // Match export-side anchor semantics (renderText §1197-1205). v4 P0
        // doesn't surface anchor in UI but the field is in the data model.
        let bgX: CGFloat
        let bgY: CGFloat
        switch content.anchor {
        case .center:       bgX = cx - bgW / 2; bgY = cy - bgH / 2
        case .topCenter:    bgX = cx - bgW / 2; bgY = cy
        case .bottomCenter: bgX = cx - bgW / 2; bgY = cy - bgH
        case .topLeft:      bgX = cx;           bgY = cy
        case .topRight:     bgX = cx - bgW;     bgY = cy
        case .bottomLeft:   bgX = cx;           bgY = cy - bgH
        case .bottomRight:  bgX = cx - bgW;     bgY = cy - bgH
        }

        let container = makeTextContainerLayer(
            frame:      CGRect(x: bgX, y: bgY, width: bgW, height: bgH),
            attributed: attributed,
            textSize:   textSize,
            padH:       padH,
            padV:       padV,
            bgHex:      style.backgroundColor,   // nil = no bg pill (text segments only)
            bgRadius:   bgRadius,
            style:      style,
            fontScale:  fontScale
        )
        if let zPos = zPosition { container.zPosition = zPos }
        parent.addSublayer(container)
        applyVisibility(to: container,
                        start: segment.targetRange.start,
                        end:   segment.targetRange.end,
                        totalDuration: totalDuration)
    }

    // MARK: - Shared layer assembly (v4 text-style-fidelity-spec §4)

    /// Build a container CALayer holding:
    ///   - optional background sublayer (rounded rect, no shadow)
    ///   - text sublayer (CATextLayer with NSAttributedString) with shadow
    ///     applied at the layer level (CATextLayer ignores NSAttributedString
    ///     shadow attribute; layer-shadow is the only way to render it).
    /// The container itself is opacity-animated for visibility.
    private static func makeTextContainerLayer(
        frame:      CGRect,
        attributed: NSAttributedString,
        textSize:   CGSize,
        padH:       CGFloat,
        padV:       CGFloat,
        bgHex:      String?,
        bgRadius:   CGFloat,
        style:      TextStyle,
        fontScale:  CGFloat = 1.0
    ) -> CALayer {
        let container = CALayer()
        container.frame   = frame
        container.opacity = 0   // applyVisibility manages this
        container.isGeometryFlipped = false

        // Background pill (only when bgHex is set).
        if let bgHex,
           let bgCGColor = SubtitleFrameBuilder.parseHexColor(bgHex) {
            let bgLayer = CALayer()
            bgLayer.frame           = container.bounds
            bgLayer.backgroundColor = bgCGColor
            bgLayer.cornerRadius    = bgRadius
            bgLayer.masksToBounds   = true
            container.addSublayer(bgLayer)
        }

        // Text sublayer
        let textLayer = CATextLayer()
        textLayer.frame         = CGRect(x: padH, y: padV,
                                         width: textSize.width, height: textSize.height)
        textLayer.contentsScale = UIScreen.main.scale
        textLayer.isWrapped     = true
        textLayer.truncationMode = .none
        // alignmentMode is overridden by NSParagraphStyle inside the attributed
        // string, but we set it as defensive default.
        textLayer.alignmentMode = .center
        textLayer.string        = attributed
        textLayer.masksToBounds = false

        // Layer-level shadow (matches export-side ctx.setShadow scope: text only).
        if let shadowHex = style.shadowColor,
           style.shadowRadius > 0 || style.shadowOffsetX != 0 || style.shadowOffsetY != 0,
           let shadowCG = SubtitleFrameBuilder.parseHexColor(shadowHex) {
            textLayer.shadowColor   = shadowCG
            textLayer.shadowOffset  = CGSize(width: CGFloat(style.shadowOffsetX) * fontScale,
                                             height: CGFloat(style.shadowOffsetY) * fontScale)
            textLayer.shadowRadius  = CGFloat(style.shadowRadius) * fontScale
            textLayer.shadowOpacity = Float(shadowCG.alpha)
        }

        container.addSublayer(textLayer)
        return container
    }

    /// Build NSAttributedString covering all 12 TextStyle fields. Mirrors the
    /// export-side renderText attribute construction (CompositionBuilder.swift
    /// §1130-1173). Shadow is NOT applied here — see makeTextContainerLayer.
    private static func buildAttributedString(
        text:  String,
        style: TextStyle,
        fontScale: CGFloat = 1.0
    ) -> NSAttributedString {
        let fontSize  = CGFloat(style.fontSize) * fontScale
        let weight    = style.fontWeight.rawValue
        let textColor = SubtitleFrameBuilder.parseHexColor(style.color)
                     ?? CGColor(gray: 1, alpha: 1)

        // Paragraph style: lineSpacing + alignment (v4 text-typography-spec §2).
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.alignment     = style.alignment.nsTextAlignment
        paraStyle.lineBreakMode = .byWordWrapping
        paraStyle.lineSpacing   = CGFloat(style.lineSpacing) * fontScale

        // v4 (text-style-fidelity-spec §4): resolveCTFont handles both true
        // italic variants AND the matrix-shear fallback for CJK fonts.
        let ctFont = SubtitleFrameBuilder.resolveCTFont(
            fontSize: fontSize, weight: weight,
            fontName: style.fontName, italic: style.isItalic)

        let ctColorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        var attrs: [NSAttributedString.Key: Any] = [
            .font:           ctFont,
            ctColorKey:      textColor,
            .paragraphStyle: paraStyle,
        ]
        if style.kerning != 0 {
            attrs[.kern] = CGFloat(style.kerning) * fontScale
        }
        // Stroke: kCTStrokeWidth is a % of font size. Negative ⇒ fill + stroke
        // (what users want).
        if style.strokeWidth > 0,
           let strokeHex = style.strokeColor,
           let strokeCG  = SubtitleFrameBuilder.parseHexColor(strokeHex) {
            attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = strokeCG
            attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] =
                -(CGFloat(style.strokeWidth) * fontScale / fontSize) * 100
        }
        return NSAttributedString(string: text, attributes: attrs)
    }

    // MARK: - Visibility keyframe animation

    /// Shows the layer for [start, end] seconds within a composition of totalDuration.
    /// Uses a CAKeyframeAnimation on "opacity" so the layer is invisible outside its range.
    private static func applyVisibility(
        to layer: CALayer,
        start: Double,
        end:   Double,
        totalDuration: Double
    ) {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        // Fade duration = 0.08s ≈ 2 frames @30fps (spec S-02 / §4.1)
        let fade: Double = 0.08
        let t0 = max(0, (start - fade) / totalDuration)
        let t1 = start / totalDuration
        let t2 = end   / totalDuration
        let t3 = min(1, (end + fade) / totalDuration)

        anim.keyTimes        = [t0, t1, t2, t3].map { NSNumber(value: $0) }
        anim.values          = [0.0, 1.0, 1.0, 0.0]
        anim.calculationMode = .linear
        anim.duration        = totalDuration
        anim.beginTime       = AVCoreAnimationBeginTimeAtZero
        anim.fillMode        = .both
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "visibility")
    }

    // v4 (text-style-fidelity-spec §4): the legacy `uiColor` helper was removed
    // after the NSAttributedString refactor — color parsing now goes through
    // SubtitleFrameBuilder.parseHexColor (CGColor) shared with the export path.
}

// MARK: - SubtitleFrameBuilder (MainActor)

/// Pre-renders subtitle / text segments as full-canvas CIImages for attachment to
/// UnifiedCompositorInstruction.subtitleFrames.
///
/// Must run on MainActor — UIGraphicsImageRenderer uses UIKit APIs.
///
/// Rendering pipeline (matches TimelineCompositionPlayer quality):
///   1. Build NSAttributedString with PingFangSC font + per-segment colour/weight
///   2. Measure text via CTFramesetter (accurate CJK line-wrap)
///   3. Compute background rect that wraps the measured text + padding
///   4. Draw background + CTFrameDraw into full-canvas transparent CIImage
@MainActor
public enum SubtitleFrameBuilder {

    private static let fadeDuration: Double = 0.08   // ≈ 2 frames @30 fps

    // Default subtitle padding (pixels)
    private static let subPadH: CGFloat = 20
    private static let subPadV: CGFloat = 10

    // MARK: - Public entry point

    public static func build(
        segments:      [EditorSegment],
        renderSize:    CGSize,
        totalDuration: Double,
        fontScale:     CGFloat = 1.0
    ) -> [SubtitleRenderFrame] {
        guard !segments.isEmpty, totalDuration > 0 else { return [] }

        // Compute subtitle stack-depth (mirrors SubtitleLayerBuilder).
        let subtitleSegs = segments.filter {
            if case .subtitle = $0.content { return true }; return false
        }.sorted { $0.targetRange.start < $1.targetRange.start }

        var stackIndex: [UUID: Int] = [:]
        for (i, seg) in subtitleSegs.enumerated() {
            var depth = 0
            for earlier in subtitleSegs.prefix(i) {
                if earlier.targetRange.end > seg.targetRange.start { depth += 1 }
            }
            stackIndex[seg.id] = depth
        }

        var frames: [SubtitleRenderFrame] = []
        for seg in segments {
            let ciImage: CIImage?
            let fadeIn: Double
            let fadeOut: Double
            switch seg.content {
            case .subtitle(let c):
                ciImage = renderSubtitle(c, renderSize: renderSize,
                                          stackDepth: stackIndex[seg.id] ?? 0,
                                          fontScale: fontScale)
                fadeIn  = fadeDuration
                fadeOut = fadeDuration
            case .text(let c):
                ciImage = renderText(c, renderSize: renderSize,
                                     fontScale: fontScale)
                fadeIn  = fadeDurationFor(c.enterAnimation)
                fadeOut = fadeDurationFor(c.exitAnimation)
            default:
                continue
            }
            guard let ci = ciImage else { continue }
            frames.append(SubtitleRenderFrame(
                segmentID:       seg.id,
                ciImage:         ci,
                startTime:       seg.targetRange.start,
                endTime:         seg.targetRange.end,
                fadeInDuration:  fadeIn,
                fadeOutDuration: fadeOut
            ))
        }
        return frames
    }

    // MARK: - Animation fade duration

    /// Maps a TextAnimation to the fade duration used during export.
    /// slide/scale/typewriter cannot be reproduced with opacity alone, so they use 0 (instant).
    private static func fadeDurationFor(_ anim: TextAnimation?) -> Double {
        guard let anim, anim.type != .none else { return 0 }
        switch anim.type {
        case .fadeIn, .fadeOut: return anim.duration
        default:                return 0
        }
    }

    // MARK: - Subtitle

    private static func renderSubtitle(
        _ content:  SegmentContent.SubtitleContent,
        renderSize: CGSize,
        stackDepth: Int,
        fontScale:  CGFloat = 1.0
    ) -> CIImage? {
        let style     = content.style
        let fontSize  = CGFloat(style.fontSize) * fontScale
        let weight    = style.fontWeight.rawValue
        let textColor = parseHexColor(style.color) ?? CGColor(gray: 1, alpha: 1)
        // v4 (text-style-fidelity-spec §4): subtitle preserves the v3 dark-pill
        // default when user hasn't set a bg, but honors paddingH/V and
        // backgroundRadius from TextStyle when set.
        let bgCGColor = parseHexColor(style.backgroundColor ?? "#00000000")
                     ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)
        let padH:     CGFloat = (style.paddingH > 0          ? CGFloat(style.paddingH)          : subPadH) * fontScale
        let padV:     CGFloat = (style.paddingV > 0          ? CGFloat(style.paddingV)          : subPadV) * fontScale
        let bgRadius: CGFloat = (style.backgroundRadius > 0  ? CGFloat(style.backgroundRadius)  : 4) * fontScale

        // v4: italic via resolveCTFont — true variant or matrix-shear fallback
        // so CJK fonts (PingFangSC etc.) get a visible slant.
        let ctFont = resolveCTFont(
            fontSize: fontSize, weight: weight,
            fontName: style.fontName, italic: style.isItalic)

        // ── Build attributed string (supports per-segment colour/weight) ──────
        let paraStyle           = NSMutableParagraphStyle()
        paraStyle.alignment     = style.alignment.nsTextAlignment
        paraStyle.lineBreakMode = .byWordWrapping
        paraStyle.lineSpacing   = CGFloat(style.lineSpacing) * fontScale
        let ctColorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

        // v4: build a base attribute dict honoring kerning + stroke. Per-segment
        // overrides apply only to color/weight (matching v3 segments semantics).
        var baseAttrs: [NSAttributedString.Key: Any] = [
            .font:           ctFont,
            ctColorKey:      textColor,
            .paragraphStyle: paraStyle,
        ]
        if style.kerning != 0 {
            baseAttrs[.kern] = CGFloat(style.kerning) * fontScale
        }
        if style.strokeWidth > 0,
           let strokeHex = style.strokeColor,
           let strokeCG  = parseHexColor(strokeHex) {
            baseAttrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = strokeCG
            // Negative ⇒ fill + stroke. % of font size. 分子分母同时 × fontScale 消掉。
            baseAttrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] =
                -(CGFloat(style.strokeWidth) * fontScale / fontSize) * 100
        }

        // v4 fix (字幕双份存在的根因 — export path mirror of SubtitleStackView):
        // Use `segments` only when its concatenation still matches the
        // canonical `content.text`. Otherwise the user has edited the text
        // via TextEditPanel and the highlight segments are stale — render
        // the new `text` with the global style so export matches preview.
        let attributed: NSAttributedString
        if let segs = content.segments, !segs.isEmpty,
           segs.map(\.text).joined() == content.text {
            let ms = NSMutableAttributedString()
            for seg in segs {
                var segAttrs = baseAttrs
                if let segHex = seg.color, let segCG = parseHexColor(segHex) {
                    segAttrs[ctColorKey] = segCG
                }
                if let segWeight = seg.fontWeight?.rawValue {
                    segAttrs[.font] = resolveCTFont(
                        fontSize: fontSize, weight: segWeight,
                        fontName: style.fontName, italic: style.isItalic)
                }
                ms.append(NSAttributedString(string: seg.text, attributes: segAttrs))
            }
            attributed = ms
        } else {
            attributed = NSAttributedString(string: content.text, attributes: baseAttrs)
        }

        // ── Measure text with CoreText (accurate CJK wrapping) ───────────────
        let sideMargin = 120 * fontScale
        let maxWidth  = renderSize.width - sideMargin
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let (textSize, _) = measureTextLayout(framesetter: framesetter, constraintWidth: maxWidth)
        guard textSize.width > 0, textSize.height > 0 else { return nil }

        // ── Compute background rect (adaptive width, centred) ─────────────────
        let stackGap: CGFloat = 8 * fontScale
        let bgW = min(textSize.width + padH * 2, renderSize.width - sideMargin)
        let bgH = textSize.height + padV * 2

        // positionY: fraction from top in UIKit Y-down (matches SubtitleLayerBuilder)
        let defaultBottomMargin = 60 * fontScale
        let centreY: CGFloat = content.positionY.map {
            renderSize.height * CGFloat($0)
        } ?? (renderSize.height - bgH / 2 - defaultBottomMargin)
        let bgY = centreY - bgH / 2 - CGFloat(stackDepth) * (bgH + stackGap)
        let bgX = (renderSize.width - bgW) / 2
        let bgRect  = CGRect(x: bgX, y: bgY, width: bgW, height: bgH)
        let textRect = CGRect(x: bgX + padH, y: bgY + padV,
                              width: textSize.width, height: textSize.height)

        // v4: shadow scoped to text draw (same approach as renderText).
        let shadowCGColor = style.shadowColor.flatMap { parseHexColor($0) }

        return drawFullCanvas(renderSize: renderSize) { ctx in
            // Background pill (no shadow — matches preview layer split).
            ctx.setFillColor(bgCGColor)
            ctx.addPath(UIBezierPath(roundedRect: bgRect, cornerRadius: bgRadius).cgPath)
            ctx.fillPath()

            // Text via CoreText with optional shadow (scoped via save/restore).
            ctx.setFillColor(textColor)
            ctx.saveGState()
            if let shadowCGColor {
                ctx.setShadow(
                    offset: CGSize(width: CGFloat(style.shadowOffsetX) * fontScale,
                                   height: -CGFloat(style.shadowOffsetY) * fontScale),
                    blur:   CGFloat(style.shadowRadius) * fontScale,
                    color:  shadowCGColor
                )
            }
            drawCTText(attributed: attributed, in: textRect, context: ctx)
            ctx.restoreGState()
        }
    }

    // MARK: - Text

    private static func renderText(
        _ content:  SegmentContent.TextContent,
        renderSize: CGSize,
        fontScale:  CGFloat = 1.0
    ) -> CIImage? {
        let style     = content.style
        let fontSize  = CGFloat(style.fontSize) * fontScale
        let weight    = style.fontWeight.rawValue
        let textColor = parseHexColor(style.color) ?? CGColor(gray: 1, alpha: 1)
        let padH      = CGFloat(style.paddingH) * fontScale
        let padV      = CGFloat(style.paddingV) * fontScale
        let bgRadius  = CGFloat(style.backgroundRadius) * fontScale
        let bgCGColor = style.backgroundColor.flatMap { parseHexColor($0) }

        // ── Attributed string ─────────────────────────────────────────────────
        let paraStyle           = NSMutableParagraphStyle()
        paraStyle.alignment     = style.alignment.nsTextAlignment
        paraStyle.lineBreakMode = .byWordWrapping
        // v3 P4 (text-entry-spec §11.3.2): paragraph-level line spacing.
        paraStyle.lineSpacing   = CGFloat(style.lineSpacing) * fontScale

        let ctColorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        // v4 (text-style-fidelity-spec §4): resolveCTFont returns either the
        // true italic variant or a matrix-shear fake (for CJK fonts that lack
        // a real italic). Replaces the v3 "silent upright fallback" behavior.
        let ctFont = resolveCTFont(
            fontSize: fontSize, weight: weight,
            fontName: style.fontName, italic: style.isItalic)

        // v3 P4: build attribute dict — stroke / kern conditionally added.
        var attrs: [NSAttributedString.Key: Any] = [
            .font:           ctFont,
            ctColorKey:      textColor,
            .paragraphStyle: paraStyle
        ]
        // Kerning (positive = wider, negative = tighter). 0 = system default.
        if style.kerning != 0 {
            attrs[.kern] = CGFloat(style.kerning) * fontScale
        }
        // Stroke: CoreText's stroke width is a percentage of font size. Negative
        // value = fill + stroke (what users actually want). Skip when width == 0
        // or color is nil.
        if style.strokeWidth > 0, let strokeColorHex = style.strokeColor,
           let strokeCGColor = parseHexColor(strokeColorHex) {
            attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = strokeCGColor
            // Negative ⇒ stroked + filled. CoreText interprets value as percent of font size.
            attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] =
                -(CGFloat(style.strokeWidth) * fontScale / fontSize) * 100
        }
        let attributed = NSAttributedString(string: content.text, attributes: attrs)

        // ── Measure ───────────────────────────────────────────────────────────
        let maxWidth    = renderSize.width - 120 * fontScale
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let (textSize, _) = measureTextLayout(framesetter: framesetter, constraintWidth: maxWidth)
        guard textSize.width > 0, textSize.height > 0 else { return nil }

        // ── Background rect with anchor ───────────────────────────────────────
        let bgW = min(textSize.width + padH * 2, renderSize.width - 40 * fontScale)
        let bgH = textSize.height + padV * 2
        let cx  = renderSize.width  * CGFloat(content.position.x)
        let cy  = renderSize.height * CGFloat(content.position.y)

        let bgX: CGFloat
        let bgY: CGFloat
        switch content.anchor {
        case .center:                        bgX = cx - bgW / 2; bgY = cy - bgH / 2
        case .topCenter:                     bgX = cx - bgW / 2; bgY = cy
        case .bottomCenter:                  bgX = cx - bgW / 2; bgY = cy - bgH
        case .topLeft:                       bgX = cx;           bgY = cy
        case .topRight:                      bgX = cx - bgW;     bgY = cy
        case .bottomLeft:                    bgX = cx;           bgY = cy - bgH
        case .bottomRight:                   bgX = cx - bgW;     bgY = cy - bgH
        }

        let bgRect   = CGRect(x: bgX, y: bgY, width: bgW, height: bgH)
        let textRect = CGRect(x: bgX + padH, y: bgY + padV,
                              width: textSize.width, height: textSize.height)

        // v3 P4 (text-entry-spec §11.3.2): shadow is applied to the TEXT only via
        // CGContext.setShadow, scoped between save/restore so it doesn't bleed
        // onto the background pill. CoreGraphics flips Y compared to UIKit, so
        // negate offsetY to keep "positive Y = downward" matching the preview.
        let shadowCGColor = style.shadowColor.flatMap { parseHexColor($0) }

        let result = drawFullCanvas(renderSize: renderSize) { ctx in
            // Optional background
            if let bg = bgCGColor {
                ctx.setFillColor(bg)
                ctx.addPath(UIBezierPath(roundedRect: bgRect, cornerRadius: bgRadius).cgPath)
                ctx.fillPath()
                ctx.setFillColor(textColor)
            }
            // Scope shadow to text draw only.
            ctx.saveGState()
            if let shadowCGColor {
                ctx.setShadow(
                    offset: CGSize(width: CGFloat(style.shadowOffsetX) * fontScale,
                                   height: -CGFloat(style.shadowOffsetY) * fontScale),
                    blur: CGFloat(style.shadowRadius) * fontScale,
                    color: shadowCGColor
                )
            }
            drawCTText(attributed: attributed, in: textRect, context: ctx)
            ctx.restoreGState()
        }
        return result
    }

    // MARK: - CoreText rendering helpers

    /// Draw attributed text into `rect` within a UIKit (Y-down) CGContext.
    ///
    /// UIKit contexts have a flipped CTM so that Y increases downward.  CTFrameDraw
    /// expects Y increasing upward (standard CG/CoreText convention).  We apply a
    /// local flip around `rect` so CTFrameDraw draws correctly without disturbing
    /// the rest of the canvas.
    private static func drawCTText(
        attributed: NSAttributedString,
        in rect:    CGRect,
        context:    CGContext
    ) {
        context.saveGState()
        // Translate to the bottom-left of rect in UIKit-flipped space, then flip Y.
        // After this transform, (0,0) maps to the CG bottom-left of rect,
        // and (0, rect.height) maps to the CG top-left — exactly what CTFrameDraw needs.
        context.translateBy(x: rect.minX, y: rect.minY + rect.height)
        context.scaleBy(x: 1, y: -1)

        // Use a slightly wider/taller path than textRect to avoid floating-point
        // truncation when contentW ≈ frame width (which causes CTFrameDraw to drop
        // lines that don't fit, leaving only the background visible).
        let pathRect   = CGRect(origin: .zero,
                                size: CGSize(width: rect.width + 2, height: rect.height + 2))
        let path       = CGPath(rect: pathRect, transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame      = CTFramesetterCreateFrame(framesetter,
                                                  CFRange(location: 0, length: 0), path, nil)

        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// Measure actual rendered text dimensions using a CTFrame.
    /// More reliable than `CTFramesetterSuggestFrameSizeWithConstraints` for CJK + word-wrap.
    /// Direct port of `TimelineCompositionPlayer.measureTextLayout`.
    // v4 (text-style-fidelity-spec §4): exposed to SubtitleLayerBuilder so the
    // preview layer constructs the same attributed-string + measurement as the
    // export frame builder. Same module so default visibility is `internal`.
   public static func measureTextLayout(
        framesetter:     CTFramesetter,
        constraintWidth: CGFloat
    ) -> (size: CGSize, contentWidth: CGFloat) {
        let path  = CGPath(rect: CGRect(x: 0, y: 0, width: constraintWidth, height: 10_000),
                           transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter,
                                             CFRange(location: 0, length: 0), path, nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else {
            return (.zero, 0)
        }

        let contentWidth = lines
            .map { CTLineGetTypographicBounds($0, nil, nil, nil) }
            .max() ?? constraintWidth

        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var fAscent: CGFloat = 0, fDescent: CGFloat = 0, fLeading: CGFloat = 0
        CTLineGetTypographicBounds(lines.first!, &fAscent, &fDescent, &fLeading)
        var lAscent: CGFloat = 0, lDescent: CGFloat = 0, lLeading: CGFloat = 0
        CTLineGetTypographicBounds(lines.last!, &lAscent, &lDescent, &lLeading)

        let top    = origins[0].y            + fAscent  + fLeading
        let bottom = origins[lines.count - 1].y - lDescent - lLeading
        let height = top - bottom

        return (CGSize(width: contentWidth, height: ceil(height)), contentWidth)
    }

    /// Create a CTFont for a given size and weight string (mirrors TimelineCompositionPlayer).
    /// - Parameter fontName: Optional UIFont family name from `TextStyle.fontName`
    ///   (v3 P1, text-entry-spec §9). When non-nil and resolvable via `SystemFontCatalog`,
    ///   selects that family's PostScript variant for the requested weight. Falls back to
    ///   PingFang SC otherwise (subtitle path always passes nil to preserve legacy behavior).
    // v4 (text-style-fidelity-spec §4): shared resolver that returns a CTFont
    // honoring fontName + weight + italic. When the chosen font has no real
    // italic variant (PingFangSC and most CJK fonts), falls back to a matrix
    // shear (~11°) so isItalic toggles produce a visible slant — matching the
    // CapCut / 剪映 behavior. Used by SubtitleLayerBuilder + renderSubtitle /
    // renderText.
    public static func resolveCTFont(
        fontSize: CGFloat,
        weight:   String,
        fontName: String?,
        italic:   Bool
    ) -> CTFont {
        let baseFont = makeCTFont(fontSize: fontSize, weight: weight, fontName: fontName)
        guard italic else { return baseFont }
        if let trueItalic = CTFontCreateCopyWithSymbolicTraits(
            baseFont, fontSize, nil, .traitItalic, .traitItalic) {
            return trueItalic
        }
        // Fake italic via shear matrix (c=0.2 ≈ 11°).
        var matrix = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        let descriptor = CTFontCopyFontDescriptor(baseFont)
        return CTFontCreateWithFontDescriptor(descriptor, fontSize, &matrix)
    }

    // v4 (text-style-fidelity-spec §4): shared with SubtitleLayerBuilder.
    public static func makeCTFont(fontSize: CGFloat, weight: String, fontName: String? = nil) -> CTFont {
        let mappedWeight: FontWeight = FontWeight(rawValue: weight) ?? .regular
        let postScript = SystemFontCatalog.resolvePostScript(
            fontName: fontName,
            weight:   mappedWeight
        )
        return CTFontCreateWithName(postScript as CFString, fontSize, nil)
    }

    /// Parse "#RRGGBB" or "#RRGGBBAA" hex string to CGColor.
    // v4 (text-style-fidelity-spec §4): shared with SubtitleLayerBuilder.
    public static func parseHexColor(_ hex: String) -> CGColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var rgb: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&rgb) else { return nil }
        if s.count == 8 {
            return CGColor(srgbRed:   CGFloat((rgb >> 24) & 0xFF) / 255,
                           green:     CGFloat((rgb >> 16) & 0xFF) / 255,
                           blue:      CGFloat((rgb >>  8) & 0xFF) / 255,
                           alpha:     CGFloat( rgb        & 0xFF) / 255)
        } else {
            return CGColor(srgbRed:   CGFloat((rgb >> 16) & 0xFF) / 255,
                           green:     CGFloat((rgb >>  8) & 0xFF) / 255,
                           blue:      CGFloat( rgb        & 0xFF) / 255,
                           alpha:     1)
        }
    }

    // MARK: - Canvas helper

    /// Subtitle / text supersample factor. Used by `drawFullCanvas` so the
    /// rasterized glyphs stay sharp when the canvas (renderSize) is small
    /// (e.g. 480×854) and the user picks a large font size. Higher = sharper
    /// but uses more memory per subtitle frame:
    ///   1× → no supersample (blurry text at fontSize > ~24 on 480-wide canvas)
    ///   2× → 4× pixels, good antialiasing — sweet spot
    ///   3× → 9× pixels, marginal improvement on most devices
    private static let subtitleSupersampleScale: CGFloat = 2.0

    /// Render drawing commands into a full-canvas transparent CIImage that
    /// composites 1:1 with the video frame.
    ///
    /// Background: `videoComposition.renderSize` is set in **points** (the
    /// canvas dimensions, e.g. 480×854 for the 22oz product timeline). The
    /// video frame's CIImage has `extent` = renderSize. Subtitle CIImages
    /// must therefore also have `extent` == renderSize.
    ///
    /// Trick: rasterize the text at a higher pixel density via
    /// `UIGraphicsImageRendererFormat.scale = supersample`, which produces a
    /// CGImage with pixel dimensions = renderSize × supersample. Glyph edges
    /// are sharper because they have more pixels to anti-alias against. Then
    /// we apply a 1/supersample affine transform on the CIImage so its
    /// `extent` collapses back to renderSize (points). CoreImage handles the
    /// downsample during composition for free.
    ///
    /// Without the back-transform, the CIImage would composite 3× the
    /// intended size and visibly shift down-right — the symptom the caller
    /// reported when raising scale to UIScreen.main.scale.
    private static func drawFullCanvas(
        renderSize: CGSize,
        drawing:    (CGContext) -> Void
    ) -> CIImage? {
        let supersample = Self.subtitleSupersampleScale

        let format    = UIGraphicsImageRendererFormat()
        format.scale  = supersample
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        let uiImage  = renderer.image { ctx in drawing(ctx.cgContext) }
        guard let cgImage = uiImage.cgImage else { return nil }

        // Both CIImage(cgImage:) and CIImage(cvPixelBuffer:) map display-top to
        // CIImage Y = height-1, so no additional flip is needed when compositing.
        let raw = CIImage(cgImage: cgImage)
        guard supersample != 1 else { return raw }
        // CGImage pixels = renderSize × supersample → raw.extent is in pixels.
        // Scale CIImage down so its extent equals renderSize (points), matching
        // the video frame's coordinate space.
        return raw.transformed(
            by: CGAffineTransform(scaleX: 1.0 / supersample,
                                  y:      1.0 / supersample)
        )
    }
}

// MARK: - UIColor hex init

private extension UIColor {
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard h.count == 6 || h.count == 8 else { return nil }
        if h.count == 6 { h += "FF" }
        var int: UInt64 = 0
        guard Scanner(string: h).scanHexInt64(&int) else { return nil }
        self.init(
            red:   CGFloat((int >> 24) & 0xFF) / 255,
            green: CGFloat((int >> 16) & 0xFF) / 255,
            blue:  CGFloat((int >>  8) & 0xFF) / 255,
            alpha: CGFloat( int        & 0xFF) / 255
        )
    }
}
#endif

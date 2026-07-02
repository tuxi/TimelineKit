import TimelineKitCore
#if canImport(UIKit)
import AVFoundation
import CoreImage
import CoreMedia

// MARK: - SubtitleRenderFrame

/// A pre-rendered subtitle or text overlay sized to the full render canvas (transparent
/// background).  Created once on MainActor at build time; immutable after creation.
/// Thread-safe: CIImage is itself immutable and Sendable.
public struct SubtitleRenderFrame: @unchecked Sendable {
    public let segmentID:       UUID
    public let ciImage:         CIImage   // full-canvas transparent image with text drawn in
    public let startTime:       Double    // seconds
    public  let endTime:         Double    // seconds
    public let fadeInDuration:  Double    // enter fade (0 = instant)
    public let fadeOutDuration: Double    // exit fade  (0 = instant)
    
    public init(segmentID: UUID, ciImage: CIImage, startTime: Double, endTime: Double, fadeInDuration: Double, fadeOutDuration: Double) {
        self.segmentID = segmentID
        self.ciImage = ciImage
        self.startTime = startTime
        self.endTime = endTime
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
    }
}

// MARK: - UnifiedCompositorInstruction

/// Single instruction type for all rendering scenarios:
///   • Steady-state segment  — one track, optional color adjustment
///   • Crossfade transition  — two tracks, per-segment color, smooth opacity ramp
///
/// `fgOpacity` interpolates from `fgOpacityStart` to `fgOpacityEnd` over `timeRange`
/// using the specified easing curve.  Outside a transition keep both equal to 1.0 and
/// omit `backgroundTrackID`.
final class UnifiedCompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol {

    var timeRange:            CMTimeRange
    var enablePostProcessing: Bool
    var containsTweening:     Bool = false
    var requiredSourceTrackIDs: [NSValue]?
    var requiredSourceSampleDataTrackIDs: [CMPersistentTrackID] { [] }
    var passthroughTrackID: CMPersistentTrackID { kCMPersistentTrackID_Invalid }

    // Foreground (top) track — always present
    let foregroundTrackID:   CMPersistentTrackID
    let foregroundAdjustment: SegmentAdjustment

    // Background (bottom) track — non-nil only during transitions
    let backgroundTrackID:   CMPersistentTrackID?
    let backgroundAdjustment: SegmentAdjustment

    // Foreground opacity at start/end of this instruction's timeRange
    let fgOpacityStart: Float
    let fgOpacityEnd:   Float
    let easing:         EditorTransition.Easing

    /// V5.1 BUG 1: 主视频轨尾端黑屏指令。true 时 UnifiedCompositor 跳过取帧、
    /// 直接渲染纯黑画面，让超出主视频轨结束点的音频继续播放但画面归零。
    let isBlackOut: Bool

    /// V6: Image layers without AVAssetTrack sources. When non-empty the compositor
    /// synthesises CIImage frames from `ImageLayerComposer` instead of calling
    /// `request.sourceFrame(byTrackID:)`. Mutually exclusive with foregroundTrackID.
    var imageLayers: [ImageLayerSpec] = []

    /// Stage 0 Fix: Image layer specs for the foreground/background roles in a
    /// crossfade transition between two image segments. These mirror `foregroundTrackID`
    /// and `backgroundTrackID` but carry CIImage source (URL-loaded) rather than a
    /// pixel buffer from an AVAssetTrack.
    ///
    /// • `transitionFgImageSpec` — image on the **foreground** track (outgoing when
    ///   isEven, incoming when !isEven — mirrors `foregroundAdjustment` semantics).
    /// • `transitionBgImageSpec` — image on the **background** track (incoming when
    ///   isEven, outgoing when !isEven — mirrors `backgroundAdjustment` semantics).
    ///
    /// When both are set the compositor dissolves them with `CIDissolveTransition`
    /// using the per-frame `fgOpacity`, exactly mirroring the video track blend.
    var transitionFgImageSpec: ImageLayerSpec?
    var transitionBgImageSpec: ImageLayerSpec?

    /// Subtitle / text frames whose time range overlaps this instruction.
    /// Populated by CompositionBuilder after the instruction array is built.
    var subtitleFrames: [SubtitleRenderFrame] = []

    init(
        timeRange:             CMTimeRange,
        foregroundTrackID:     CMPersistentTrackID,
        foregroundAdjustment:  SegmentAdjustment    = .identity,
        backgroundTrackID:     CMPersistentTrackID? = nil,
        backgroundAdjustment:  SegmentAdjustment    = .identity,
        fgOpacityStart:        Float                = 1,
        fgOpacityEnd:          Float                = 1,
        easing:                EditorTransition.Easing = .easeInOut,
        isBlackOut:            Bool                 = false,
        imageLayers:           [ImageLayerSpec]      = [],
        transitionFgImageSpec: ImageLayerSpec?       = nil,
        transitionBgImageSpec: ImageLayerSpec?       = nil
    ) {
        self.timeRange             = timeRange
        self.foregroundTrackID     = foregroundTrackID
        self.foregroundAdjustment  = foregroundAdjustment
        self.backgroundTrackID     = backgroundTrackID
        self.backgroundAdjustment  = backgroundAdjustment
        self.fgOpacityStart        = fgOpacityStart
        self.fgOpacityEnd          = fgOpacityEnd
        self.easing                = easing
        self.isBlackOut            = isBlackOut
        self.imageLayers           = imageLayers
        self.transitionFgImageSpec = transitionFgImageSpec
        self.transitionBgImageSpec = transitionBgImageSpec

        let isTransition   = backgroundTrackID != nil
        let hasColor       = !foregroundAdjustment.isIdentity || !backgroundAdjustment.isIdentity
        // hasImageLayers: regular overlay/body image layers OR transition image specs
        let hasImageLayers = !imageLayers.isEmpty
            || transitionFgImageSpec != nil
            || transitionBgImageSpec != nil

        // Stage 0 Fix 1 – enablePostProcessing
        // Image layers are generated procedurally by ImageLayerComposer; there is no
        // AVAssetTrack source. AVFoundation must invoke the compositor every frame —
        // never use a passthrough path — so enablePostProcessing must be true.
        self.enablePostProcessing = isTransition || hasColor || hasImageLayers

        // Stage 0 Fix 2 – containsTweening
        // Each compositionTime yields a distinct animated frame. containsTweening=false
        // allows the playback path to cache/reuse the previous compositor output (seek
        // still works because it always forces a single-frame render — that was the
        // seek-OK/play-broken split the user observed). Must be true for image layers.
        let hasTween = fgOpacityStart != fgOpacityEnd
        self.containsTweening = hasTween || hasImageLayers

        // Stage 0 Fix 3 – requiredSourceTrackIDs
        //
        // Pure image instructions do not need AVAssetTrack sources; ImageLayerComposer
        // renders every frame directly from URL. Setting requiredSourceTrackIDs=[] with
        // containsTweening=true is safe: AVFoundation still calls startRequest per-frame.
        //
        //  • Body (non-transition) image instructions → []
        //  • Image-only transitions (BOTH fg AND bg are image specs) → []
        //    No sentinel frames are needed; CIDissolveTransition handles the blend.
        //  • Mixed transitions (one video, one image) → keep track IDs so AVFoundation
        //    delivers the video source frame for the video side.
        //  • BlackOut / pure video → keep track IDs.
        let isPureImageBody       = hasImageLayers && !isTransition && !isBlackOut
        let isPureImageTransition = isTransition && !isBlackOut
            && transitionFgImageSpec != nil && transitionBgImageSpec != nil

        if isPureImageBody || isPureImageTransition {
            self.requiredSourceTrackIDs = []
        } else {
            var ids: [NSValue] = [NSNumber(value: foregroundTrackID)]
            if let bgID = backgroundTrackID { ids.append(NSNumber(value: bgID)) }
            self.requiredSourceTrackIDs = ids
        }
    }
}

// MARK: - UnifiedCompositor

/// Custom AVVideoCompositing that handles both color grading and crossfade transitions.
///
/// Rendering rules:
///   1. Steady-state  — apply color adjustment to foreground; identity → passthrough.
///   2. Transition    — per-frame eased blend: fgOpacity·fg + (1−fgOpacity)·bg, after
///                      applying each segment's color adjustment independently.
final class UnifiedCompositor: NSObject, AVVideoCompositing {

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    // V6: Output buffer pool for recycling pixel buffers across frames.
    // Recreated when render size changes (renderContextChanged).
    private var outputPool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private let poolLock = NSLock()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        let newSize = newRenderContext.size
        // Recreate the pool only when size actually changes.
        guard newSize != poolSize else { return }
        poolSize = newSize
        outputPool = nil
        guard newSize.width > 0, newSize.height > 0 else { return }
        var pool: CVPixelBufferPool?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey            as String: Int(newSize.width),
            kCVPixelBufferHeightKey           as String: Int(newSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        outputPool = pool
    }
    func cancelAllPendingVideoCompositionRequests() {}

    // MARK: - startRequest

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instr = request.videoCompositionInstruction as? UnifiedCompositorInstruction else {
            request.finish(with: Err.badInstruction); return
        }

        let renderSize  = request.renderContext.size
        let canvasRect  = CGRect(origin: .zero, size: renderSize)
        let t           = request.compositionTime.seconds
        let activeSubtitles = instr.subtitleFrames.filter { t >= $0.startTime && t < $0.endTime }
        
#if DEBUG
print("[UC] t=\(t) imageLayers=\(instr.imageLayers.map { "z=\($0.zPosition) range=\($0.timeRange.start.seconds)-\($0.timeRange.end.seconds)" })")
        print("[UC startRequest] t=\(request.compositionTime.seconds)")
#endif

        // V5.1 BUG 1 / V6 Fix C: BlackOut 指令直接写一帧黑画面 + 字幕，跳过所有源帧逻辑。
        // 用于主视频轨结束后、音频仍在播放的尾段，避免最后一帧被冻结显示。
        // 注意：requiredSourceTrackIDs 仍保留 foregroundTrackID，保证 AVPlayer 实时
        // 播放路径继续调用此方法；这里手动忽略源帧、输出纯黑画面。
        if instr.isBlackOut {
            let black = CIImage(color: .black).cropped(to: canvasRect)
            renderAndFinish(black, subtitles: activeSubtitles, at: t, request: request)
            return
        }

        // ── V6 Fix A: 每层独立 cover 到 canvasRect ────────────────────────────
        // 规则：background image layers / main source frame / foreground image
        // layers 各自单独 cover-fit + crop 到 canvasRect，再按 z-order 叠加。
        // 这样背景层不会通过 composited(over:) 的 union extent 污染主轨视频的
        // cover transform —— 不论是否存在背景层，主轨视频永远铺满画布。
        let bgLayerSpecs = instr.imageLayers.filter { $0.zPosition < 0 }
            .sorted { $0.zPosition < $1.zPosition }
        let fgLayerSpecs = instr.imageLayers.filter { $0.zPosition >= 0 }
            .sorted { $0.zPosition < $1.zPosition }

        // Image layers come out of ImageLayerComposer with extent ≈ canvasRect, but
        // motion transforms (pan / scale) may overshoot — clamp to canvasRect so
        // each layer occupies exactly the canvas bounds before compositing.
        func compositeLayers(_ specs: [ImageLayerSpec]) -> CIImage? {
            let images: [CIImage] = specs.compactMap {
                ImageLayerComposer.evaluate(spec: $0, at: request.compositionTime)?
                    .cropped(to: canvasRect)
            }
            guard let first = images.first else { return nil }
            var result = first
            for i in 1..<images.count {
                result = images[i].composited(over: result)
            }
            return result
        }

        let bgImageLayers = compositeLayers(bgLayerSpecs)
        let fgImageLayers = compositeLayers(fgLayerSpecs)

        // ── Source frame rendering (independently cover-fit to canvasRect) ──
        let fgOpacity = resolvedOpacity(instr: instr, at: request.compositionTime)
        // V6 Fix G: Filter out small sentinel frames inserted to keep AVFoundation
        // calling startRequest during playback. Sentinel is intentionally tiny
        // (16×16) and never represents real user media.
        // NOTE: for pure-image instructions requiredSourceTrackIDs=[], so fgBuf/bgBuf
        // are nil from the start — no sentinel frames are even requested.
        let fgBuf = request.sourceFrame(byTrackID: instr.foregroundTrackID)
            .flatMap { isSentinelFrame($0) ? nil : $0 }
        let bgBuf = instr.backgroundTrackID
            .flatMap { request.sourceFrame(byTrackID: $0) }
            .flatMap { isSentinelFrame($0) ? nil : $0 }

        // Resolves a transition-role image spec to a canvas-cropped CIImage.
        func evalTransSpec(_ spec: ImageLayerSpec?) -> CIImage? {
            spec.flatMap {
                ImageLayerComposer.evaluate(spec: $0, at: request.compositionTime)?
                    .cropped(to: canvasRect)
            }
        }

        // ── Build sourceImage: handles all 4 track-role combinations ────────
        // 1. video → video   (existing dissolve path)
        // 2. video → image   (video fades into image layer)
        // 3. image → video   (image layer fades into video)
        // 4. image → image   (both pure image specs; pure-image transition)
        var sourceImage: CIImage?
        if let fg = fgBuf {
            var fgImg = coverFitToCanvas(CIImage(cvPixelBuffer: fg), canvasRect: canvasRect)
            if !instr.foregroundAdjustment.isIdentity {
                fgImg = applyAdjustments(instr.foregroundAdjustment, to: fgImg)
            }
            if let bg = bgBuf, fgOpacity < 1, fgOpacity > 0 {
                // Case 1 – video → video transition blend.
                var bgImg = coverFitToCanvas(CIImage(cvPixelBuffer: bg), canvasRect: canvasRect)
                if !instr.backgroundAdjustment.isIdentity {
                    bgImg = applyAdjustments(instr.backgroundAdjustment, to: bgImg)
                }
                sourceImage = fgImg.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: bgImg,
                    kCIInputTimeKey:        1.0 - fgOpacity
                ])
            } else if let bgCIImg = evalTransSpec(instr.transitionBgImageSpec) {
                // Case 2 – video → image transition blend.
                // Note: no fgOpacity guard — CIDissolveTransition handles all values:
                //   time=0 (fgOpacity=1) → fully shows fgImg; time=1 → fully shows bgCIImg.
                sourceImage = fgImg.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: bgCIImg,
                    kCIInputTimeKey:        1.0 - fgOpacity
                ])
            } else {
                // Steady-state video frame (no active transition blend).
                sourceImage = fgImg
            }
        } else if let bg = bgBuf {
            var bgImg = coverFitToCanvas(CIImage(cvPixelBuffer: bg), canvasRect: canvasRect)
            if !instr.backgroundAdjustment.isIdentity {
                bgImg = applyAdjustments(instr.backgroundAdjustment, to: bgImg)
            }
            if let fgCIImg = evalTransSpec(instr.transitionFgImageSpec) {
                // Case 3 – image → video transition blend.
                // Note: no fgOpacity guard — CIDissolveTransition handles all values:
                //   time=0 (fgOpacity=1) → fully shows fgCIImg (image); time=1 → bgImg.
                sourceImage = fgCIImg.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: bgImg,
                    kCIInputTimeKey:        1.0 - fgOpacity
                ])
            } else {
                // Only the background video track is live (fg is nil/sentinel).
                sourceImage = bgImg
            }
        } else if instr.transitionFgImageSpec != nil || instr.transitionBgImageSpec != nil {
            // Case 4 – image → image (or single-sided image) transition.
            // requiredSourceTrackIDs=[] so no pixel buffers are delivered; both sides
            // come from ImageLayerComposer. Apply CIDissolveTransition just like video.
            let fgCIImg = evalTransSpec(instr.transitionFgImageSpec)
            let bgCIImg = evalTransSpec(instr.transitionBgImageSpec)
#if DEBUG
            print("[UC] Case4 img→img t=\(String(format:"%.3f",t)) fgOpacity=\(String(format:"%.2f",fgOpacity)) hasFg=\(fgCIImg != nil) hasBg=\(bgCIImg != nil)")
#endif
            if let fgI = fgCIImg, let bgI = bgCIImg {
                sourceImage = fgI.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: bgI,
                    kCIInputTimeKey:        1.0 - fgOpacity
                ])
            } else {
                sourceImage = fgCIImg ?? bgCIImg
            }
        } else {
            sourceImage = nil
        }

        // ── Composite: bg layers → source → fg layers ───────────────────────
        // After Fix A every layer's extent is exactly canvasRect, so the
        // composited base.extent is canvasRect and renderAndFinish no longer
        // needs cover-fit fallback.
        var base: CIImage
        if let bg = bgImageLayers {
            base = bg
            if let src = sourceImage {
                base = src.composited(over: base)
            }
        } else if let src = sourceImage {
            base = src
        } else if let fg = fgImageLayers {
            base = fg
        } else {
            let black = CIImage(color: .black).cropped(to: canvasRect)
            renderAndFinish(black, subtitles: activeSubtitles, at: t, request: request)
            return
        }

        if let fg = fgImageLayers {
            base = fg.composited(over: base)
        }

        // Fast passthrough: source already matches canvas size, no color adjustment,
        // no subtitles, no image layers, no transition blend.
        if fgImageLayers == nil, bgImageLayers == nil,
           sourceImage != nil, activeSubtitles.isEmpty,
           let buf = fgBuf ?? bgBuf,
           ((fgBuf != nil) ? instr.foregroundAdjustment : instr.backgroundAdjustment).isIdentity,
           bgBuf == nil || fgOpacity >= 1 {
            let bufW = CVPixelBufferGetWidth(buf)
            let bufH = CVPixelBufferGetHeight(buf)
            if CGFloat(bufW) == renderSize.width, CGFloat(bufH) == renderSize.height {
                request.finish(withComposedVideoFrame: buf)
                return
            }
        }

        renderAndFinish(base, subtitles: activeSubtitles, at: t, request: request)
    }

    // MARK: - Per-layer cover-fit

    /// V6 Fix A: Cover-fit a CIImage to `canvasRect` and crop to its bounds.
    /// Every layer (bg image / main source frame / fg image) is normalised to
    /// the canvas independently before compositing, so a background layer can
    /// never alter the main video's render rect.
    private func coverFitToCanvas(_ image: CIImage, canvasRect: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let s = max(canvasRect.width / e.width, canvasRect.height / e.height)
        // After scaling, translate so the scaled image is centred in canvasRect.
        let tx = canvasRect.midX - (e.midX * s)
        let ty = canvasRect.midY - (e.midY * s)
        let scaled = image.transformed(by:
            CGAffineTransform(scaleX: s, y: s).concatenating(
                CGAffineTransform(translationX: tx, y: ty)
            ))
        // Crop excess outside the canvas so the layer extent is exactly canvasRect.
        return scaled.cropped(to: canvasRect)
    }

    /// V6 Fix G: Detect tiny sentinel frames inserted by CompositionBuilder
    /// at image segment positions. These exist only to prevent the composition track from
    /// being empty (which would cause AVFoundation to skip compositor calls during playback).
    private func isSentinelFrame(_ buf: CVPixelBuffer) -> Bool {
        CVPixelBufferGetWidth(buf) <= 16 && CVPixelBufferGetHeight(buf) <= 16
    }

    // MARK: - Composite + Finish

    /// Composites any active subtitle overlays on top of `base`, renders to a new pixel
    /// buffer, and finishes the request.
    ///
    /// V6 Fix A: `base` is already cover-fit + cropped to `canvasRect` by `startRequest`
    /// (every layer normalises to canvasRect independently before compositing). This
    /// method no longer performs cover-fit fallback — its sole responsibility is
    /// subtitle overlay + final render.
    private func renderAndFinish(
        _ base:     CIImage,
        subtitles:  [SubtitleRenderFrame],
        at t:       Double,
        request:    AVAsynchronousVideoCompositionRequest
    ) {
        let renderSize   = request.renderContext.size
        let outputExtent = CGRect(origin: .zero, size: renderSize)

        var finalCI = base
        for frame in subtitles {
            let opacity = CGFloat(subtitleOpacity(frame: frame, at: t))
            let overlay: CIImage
            if opacity >= 1 {
                overlay = frame.ciImage
            } else {
                // Scale all channels (incl. alpha) — correct for premultiplied alpha
                overlay = frame.ciImage.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: opacity, y: 0,       z: 0,       w: 0),
                    "inputGVector": CIVector(x: 0,       y: opacity, z: 0,       w: 0),
                    "inputBVector": CIVector(x: 0,       y: 0,       z: opacity, w: 0),
                    "inputAVector": CIVector(x: 0,       y: 0,       z: 0,       w: opacity),
                ])
            }
            finalCI = overlay.composited(over: finalCI)
        }

        // V6: Use the pooled output buffer when available, falling back to renderContext.
        poolLock.lock()
        let out: CVPixelBuffer? = {
            if let pool = outputPool {
                var buf: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buf)
                return buf ?? request.renderContext.newPixelBuffer()
            }
            return request.renderContext.newPixelBuffer()
        }()
        poolLock.unlock()
        guard let out else {
            request.finish(with: Err.noOutputBuffer); return
        }
        ciContext.render(finalCI, to: out, bounds: outputExtent, colorSpace: nil)
        request.finish(withComposedVideoFrame: out)
    }

    // MARK: - Opacity for subtitle fade-in / fade-out

    private func subtitleOpacity(frame: SubtitleRenderFrame, at t: Double) -> Double {
        let fadeIn  = max(frame.fadeInDuration,  0.001)
        let fadeOut = max(frame.fadeOutDuration, 0.001)
        if t < frame.startTime + frame.fadeInDuration  { return max(0, min(1, (t - frame.startTime) / fadeIn)) }
        if t > frame.endTime   - frame.fadeOutDuration { return max(0, min(1, (frame.endTime - t)   / fadeOut)) }
        return 1
    }

    /// Interpolate foreground opacity at `compositionTime` within the instruction's timeRange.
    private func resolvedOpacity(
        instr: UnifiedCompositorInstruction,
        at time: CMTime
    ) -> Float {
        guard instr.fgOpacityStart != instr.fgOpacityEnd,
              instr.timeRange.duration.seconds > 0 else {
            return instr.fgOpacityStart
        }
        let elapsed = CMTimeSubtract(time, instr.timeRange.start).seconds
        let total   = instr.timeRange.duration.seconds
        let t       = Float(max(0, min(1, elapsed / total)))
        let easedT  = eased(t, curve: instr.easing)
        return instr.fgOpacityStart + (instr.fgOpacityEnd - instr.fgOpacityStart) * easedT
    }

    // MARK: - Easing

    private func eased(_ t: Float, curve: EditorTransition.Easing) -> Float {
        switch curve {
        case .linear:   return t
        case .easeIn:   return t * t * t
        case .easeOut:  let u = 1 - t; return 1 - u * u * u
        case .easeInOut:
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        }
    }

    // MARK: - CIFilter chain (shared with ColorAdjustmentCompositor)

    private func applyAdjustments(_ adj: SegmentAdjustment, to image: CIImage) -> CIImage {
        var result = image

        if adj.brightness != 0 || adj.contrast != 1.0 || adj.saturation != 1.0 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: adj.brightness,
                kCIInputContrastKey:   adj.contrast,
                kCIInputSaturationKey: adj.saturation
            ])
        }

        if adj.temperature != 6500 || adj.tint != 0 {
            result = result.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral":       CIVector(x: CGFloat(adj.temperature), y: CGFloat(adj.tint)),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        }

        if adj.highlights != 0 || adj.shadows != 0 {
            result = result.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1.0 - adj.highlights,
                "inputShadowAmount":    adj.shadows
            ])
        }

        if let preset = adj.filterName {
            let filtered = result.applyingFilter(preset.ciFilterName)
            if adj.filterIntensity >= 1.0 {
                result = filtered
            } else if adj.filterIntensity > 0 {
                result = filtered.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: result,
                    kCIInputTimeKey:        1.0 - adj.filterIntensity
                ])
            }
        }

        return result
    }

    private enum Err: Error {
        case badInstruction, missingFrame, noOutputBuffer
    }
}
#endif

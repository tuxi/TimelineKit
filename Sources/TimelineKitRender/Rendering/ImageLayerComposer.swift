import TimelineKitCore
import Foundation
import CoreImage
import CoreMedia
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ImageLayerSpec

/// A self-contained description of one image layer on the timeline.
/// Carries everything the compositor needs to render a CIImage for a given
/// composition time — without requiring an AVAssetTrack source.
public struct ImageLayerSpec: Sendable, Codable {
    /// Image source file URL.
    public var imageURL: URL
    /// Render canvas dimensions (used for fit calculation).
    public var renderSize: CGSize
    /// Content fit mode (cover / contain / fill).
    public var contentMode: ContentFit
    /// Absolute time range on the composition timeline.
    public var timeRange: CMTimeRange
    /// Keyframe animation tracks (nil = static image).
    public var keyframes: KeyframeSet?
    /// Layer stacking order (higher = on top).
    public var zPosition: Int32
    /// Base opacity (0–1), multiplied with keyframe opacity when present.
    public var baseOpacity: Float

    public init(
        imageURL: URL,
        renderSize: CGSize,
        contentMode: ContentFit = .cover,
        timeRange: CMTimeRange,
        keyframes: KeyframeSet? = nil,
        zPosition: Int32 = 0,
        baseOpacity: Float = 1.0
    ) {
        self.imageURL    = imageURL
        self.renderSize  = renderSize
        self.contentMode = contentMode
        self.timeRange   = timeRange
        self.keyframes   = keyframes
        self.zPosition   = zPosition
        self.baseOpacity = baseOpacity
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case imageURL, renderSize, contentMode
        case timeRangeStart, timeRangeDuration
        case keyframes, zPosition, baseOpacity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.imageURL    = try c.decode(URL.self,       forKey: .imageURL)
        self.renderSize  = try c.decode(CGSize.self,    forKey: .renderSize)
        self.contentMode = try c.decode(ContentFit.self, forKey: .contentMode)
        let startSec    = try c.decode(Double.self, forKey: .timeRangeStart)
        let durationSec = try c.decode(Double.self, forKey: .timeRangeDuration)
        self.timeRange   = CMTimeRange(start: CMTime(seconds: startSec, preferredTimescale: 600),
                                        duration: CMTime(seconds: durationSec, preferredTimescale: 600))
        self.keyframes   = try c.decodeIfPresent(KeyframeSet?.self, forKey: .keyframes) ?? nil
        self.zPosition   = try c.decodeIfPresent(Int32.self,     forKey: .zPosition)   ?? 0
        self.baseOpacity = try c.decodeIfPresent(Float.self,     forKey: .baseOpacity) ?? 1.0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(imageURL,                   forKey: .imageURL)
        try c.encode(renderSize,                 forKey: .renderSize)
        try c.encode(contentMode,                forKey: .contentMode)
        try c.encode(timeRange.start.seconds,    forKey: .timeRangeStart)
        try c.encode(timeRange.duration.seconds, forKey: .timeRangeDuration)
        try c.encodeIfPresent(keyframes,   forKey: .keyframes)
        try c.encode(zPosition,            forKey: .zPosition)
        try c.encode(baseOpacity,          forKey: .baseOpacity)
    }
}

// MARK: - ImageLayerComposer

/// Stateless evaluator that produces a CIImage for an `ImageLayerSpec` at a
/// given composition time. Does not require an AVAssetTrack.
///
/// Used by `UnifiedCompositor.startRequest` when an instruction carries
/// `imageLayers` payloads.
public enum ImageLayerComposer {

    /// V6: Lightweight CIImage cache replacing the legacy StaticImageRenderer MP4 cache.
    /// Keyed by URL — CIImage is immutable and cheap to retain. Count limit of 12
    /// keeps memory bounded (~100 MB for 4K 32BGRA images).
    private nonisolated(unsafe) static let imageCache: NSCache<NSURL, CIImage> = {
        let c = NSCache<NSURL, CIImage>()
        c.countLimit = 12
        return c
    }()

    /// Returns a CIImage for the layer at the given composition time, or nil if
    /// `compositionTime` falls outside the layer's time range.
    public static func evaluate(
        spec: ImageLayerSpec,
        at compositionTime: CMTime
    ) -> CIImage? {
        let start = spec.timeRange.start
        let end   = spec.timeRange.end

        guard compositionTime >= start, compositionTime < end else {
            return nil
        }
        

        let rawImage: CIImage
        if let cached = imageCache.object(forKey: spec.imageURL as NSURL) {
            rawImage = cached
        } else if let loaded = CIImage(contentsOf: spec.imageURL) {
            imageCache.setObject(loaded, forKey: spec.imageURL as NSURL)
            rawImage = loaded
        } else {
            return nil
        }

        // V6: Normalize extent origin to (0,0). CIImage(contentsOf:) may return
        // non-zero origin for some image formats (e.g. CGImage-backed sources).
        // fitTransform only uses width/height — a non-zero origin shifts the
        // centering calculation, producing an upward offset + bottom black bar.
        let ciImage: CIImage = {
            let o = rawImage.extent.origin
            if o != .zero {
                return rawImage.transformed(by: CGAffineTransform(translationX: -o.x, y: -o.y))
            }
            return rawImage
        }()

        let imageExtent = ciImage.extent
        // V6 Fix B: safeMargin guarantees motion (pan/scale-down) never reveals
        // canvas background. Images with keyframes inflate baseScale beyond the
        // cover scale so the worst-case motion offset still keeps pixels covering
        // the full canvas. Static images use 0 margin to match V5 framing.
        let safeMargin = motionSafetyMargin(for: spec.keyframes)
        let baseTransform = fitTransform(
            mode: spec.contentMode,
            imageExtent: imageExtent,
            canvasSize: spec.renderSize,
            safeMargin: safeMargin
        )

        // V6 Fix E: Pass localTime in seconds directly. KeyframeEvaluator
        // compares against Keyframe.time (also seconds) without rescaling, so
        // partial animations (keyframes that don't span full segment) hold
        // correctly past their last keyframe instead of being stretched.
        let totalDuration = spec.timeRange.duration.seconds
        let elapsed       = compositionTime.seconds - start.seconds
        let localTime     = max(0.0, min(elapsed, totalDuration))

        let (motion, opacity) = KeyframeEvaluator.evaluate(
            keyframes: spec.keyframes,
            at: localTime,
            canvasSize: spec.renderSize
        )
        let combined = baseTransform.concatenating(motion)
//        #if DEBUG
//        // image_3d / image_motion black-edge diagnostic log — remove after root cause confirmed.
//        if spec.keyframes != nil {
//            print("[ILC] rawExtentOrigin=\(rawImage.extent.origin) imageExtent=\(imageExtent) canvas=\(spec.renderSize)")
//            print("[ILC] safeMargin=\(safeMargin) baseScale=\(baseTransform.a) baseTransform=\(baseTransform)")
//            print("[ILC] localTime=\(localTime) motion=\(motion)")
//            print("[ILC] combined=\(combined)")
//        }
//        #endif
        let result = ciImage.transformed(by: combined)
//        #if DEBUG
//        if spec.keyframes != nil {
//            print("[ILC] resultExtent=\(result.extent)")
//
//            // A/B test: motion first vs baseTransform first
//            let altCombined = motion.concatenating(baseTransform)
//            let altResult = ciImage.transformed(by: altCombined)
//            print("[ILC] AB-altCombined=\(altCombined) altExtent=\(altResult.extent)")
//        }
//        #endif

        // Apply opacity via CIFilter when < 1.0
        let finalOpacity = Double(spec.baseOpacity) * opacity
        if finalOpacity < 1.0 {
            return result.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(finalOpacity))
            ])
        }
        return result
    }

    // MARK: - Fit transform

    /// Compute the base scale + center-offset to fit the image into the canvas
    /// using the specified content mode. Mirrors StaticImageRenderer's logic.
    ///
    /// V6 Fix B: `safeMargin` inflates the cover scale so that motion (pan / fade
    /// scale-down) cannot reveal the underlying canvas. Static images pass 0.
    /// The formula matches StaticImageRenderer.swift:144-151:
    ///     safeScale = max(baseScale,
    ///         (W + 2·W·margin) / imgW,
    ///         (H + 2·H·margin) / imgH)
    public static func fitTransform(
        mode: ContentFit,
        imageExtent: CGRect,
        canvasSize: CGSize,
        safeMargin: CGFloat = 0
    ) -> CGAffineTransform {
        let imgW = imageExtent.width
        let imgH = imageExtent.height
        guard imgW > 0, imgH > 0, canvasSize.width > 0, canvasSize.height > 0 else {
            return .identity
        }

        let scaleX = canvasSize.width  / imgW
        let scaleY = canvasSize.height / imgH

        let baseScale: CGFloat
        switch mode {
        case .cover:   baseScale = max(scaleX, scaleY)
        case .contain: baseScale = min(scaleX, scaleY)
        case .fill:    baseScale = 1.0  // no uniform scaling; image may distort
        }

        // Cover mode is the only mode where motion safety applies — `contain`
        // is meant to show the full image with letterboxing, and `fill` distorts.
        let scale: CGFloat
        if mode == .cover, safeMargin > 0 {
            let safe = max(baseScale,
                (canvasSize.width  + 2 * canvasSize.width  * safeMargin) / imgW,
                (canvasSize.height + 2 * canvasSize.height * safeMargin) / imgH)
            scale = safe
        } else {
            scale = baseScale
        }

        let dx = (canvasSize.width  - imgW * scale) * 0.5
        let dy = (canvasSize.height - imgH * scale) * 0.5
        return CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: dx / scale, y: dy / scale)
    }

    // MARK: - Motion safety margin

    /// V6 P5: derives the safe-scale margin from a keyframe set, accounting for
    /// `anchor`, `position`, AND `scale` extremes. Returns 0 for static / nil
    /// keyframes.
    ///
    /// Geometry: `KeyframeEvaluator` builds the transform as
    ///     result = s · (p − anchor·canvas) + pos·canvas
    /// so an image input range [0, W] maps to canvas-x range
    ///     [(pos.x − s·anchor.x)·W,  (pos.x + s·(1−anchor.x))·W]
    /// For the canvas [0, W] to stay covered, both endpoints must overshoot:
    ///     left  excess = pos.x / s − anchor.x         ≤ margin
    ///     right excess = (1 − pos.x) / s − (1 − anchor.x) ≤ margin
    /// We evaluate this at the worst-case combination of position and scale
    /// extremes (min-scale × max-displacement). This catches the image_3d case
    /// where anchor is off-center: at scale = 1.04 with anchor.x = 0.42 and
    /// pos = (0.5, 0.5), the LEFT edge sits at canvas-x = 0.063·W (a 6% black
    /// bar) unless we add margin.
    ///
    /// V6 Fix B (legacy comment): previously the formula only considered
    /// `|p − 0.5|` and `(1 − minScale)/2`, which assumed anchor = (0.5, 0.5)
    /// and therefore missed the off-center-anchor case entirely.
    public static func motionSafetyMargin(for keyframes: KeyframeSet?) -> CGFloat {
        guard let kf = keyframes, !kf.isEmpty else { return 0 }

        // ── Anchor range (constant in our presets, but support keyframed) ───
        // Defaults to (0.5, 0.5) when no anchor track — matches KeyframeEvaluator.
        var aXmin = 0.5, aXmax = 0.5
        var aYmin = 0.5, aYmax = 0.5
        if !kf.anchor.isEmpty {
            aXmin = kf.anchor.map(\.value.x).min() ?? 0.5
            aXmax = kf.anchor.map(\.value.x).max() ?? 0.5
            aYmin = kf.anchor.map(\.value.y).min() ?? 0.5
            aYmax = kf.anchor.map(\.value.y).max() ?? 0.5
        }

        // ── Position range ──────────────────────────────────────────────────
        // When no position track, pos is implicitly (0.5, 0.5) per
        // `KeyframeEvaluator` (see `?? .center`), NOT anchor — so default here
        // must match the evaluator exactly.
        var pXmin = 0.5, pXmax = 0.5
        var pYmin = 0.5, pYmax = 0.5
        if !kf.position.isEmpty {
            pXmin = kf.position.map(\.value.x).min() ?? 0.5
            pXmax = kf.position.map(\.value.x).max() ?? 0.5
            pYmin = kf.position.map(\.value.y).min() ?? 0.5
            pYmax = kf.position.map(\.value.y).max() ?? 0.5
        }

        // ── Scale range (clamp away from zero) ──────────────────────────────
        // Worst case for overscan is at the MIN scale (smallest coverage).
        let sMin = max(0.01, kf.scale.map(\.value).min() ?? 1.0)

        // Worst-case left / right excess per axis. Conservative — assumes the
        // pessimistic combination of pos extreme × min scale × anchor extreme.
        func axisMargin(pMin: Double, pMax: Double, aMin: Double, aMax: Double, s: Double) -> CGFloat {
            let mLeft  = pMax / s - aMin
            let mRight = (1 - pMin) / s - (1 - aMax)
            return CGFloat(max(0, max(mLeft, mRight)))
        }
        let mX = axisMargin(pMin: pXmin, pMax: pXmax, aMin: aXmin, aMax: aXmax, s: sMin)
        let mY = axisMargin(pMin: pYmin, pMax: pYmax, aMin: aYmin, aMax: aYmax, s: sMin)

        let margin = max(mX, mY)
        // 0.04 safety floor whenever we need any margin — guards against
        // floating-point slop during high-frame-rate interpolation.
        // Also apply the floor when anchor is meaningfully off-center even
        // though the formula computes margin=0: the natural overscan at
        // scale=1.04 with anchor near (0.20, 0.50) is only ~1% — too tight
        // to survive rounding during preview/export. The +0.04 inflation has
        // no visible cost (already inside cover scale) and removes the risk.
        let anchorOffCenter =
            abs(aXmin - 0.5) > 0.01 || abs(aXmax - 0.5) > 0.01 ||
            abs(aYmin - 0.5) > 0.01 || abs(aYmax - 0.5) > 0.01
        if margin > 0 { return margin + 0.04 }
        if anchorOffCenter { return 0.04 }
        return 0
    }
}

import TimelineKitCore
import Foundation
import CoreImage
import CoreMedia

// MARK: - VideoLayerSpec

/// A self-contained description of one video layer on the timeline.
/// Carries everything needed to render a CIImage for a given composition time
/// from the source video asset via AVAssetImageGenerator.
public struct VideoLayerSpec: Sendable, Codable {
    /// Source video file URL.
    public var assetURL: URL
    /// Render canvas dimensions (used for fit calculation).
    public var renderSize: CGSize
    /// Content fit mode (cover / contain / fill).
    public var contentMode: ContentFit
    /// Offset into the source asset (from `seg.sourceRange?.start ?? 0`).
    public var sourceStartTime: Double
    /// Absolute time range on the composition timeline.
    public var timeRange: CMTimeRange
    /// Segment-level compositing transform.
    public var transform: SegmentTransform
    /// Color / tone adjustments.
    public var adjustment: SegmentAdjustment
    /// Layer stacking order (higher = on top).
    public var zPosition: Int32
    /// Base opacity (0–1).
    public var baseOpacity: Float

    public init(
        assetURL: URL,
        renderSize: CGSize,
        contentMode: ContentFit = .cover,
        sourceStartTime: Double = 0,
        timeRange: CMTimeRange,
        transform: SegmentTransform = .identity,
        adjustment: SegmentAdjustment = .identity,
        zPosition: Int32 = 0,
        baseOpacity: Float = 1.0
    ) {
        self.assetURL        = assetURL
        self.renderSize      = renderSize
        self.contentMode     = contentMode
        self.sourceStartTime = sourceStartTime
        self.timeRange       = timeRange
        self.transform       = transform
        self.adjustment      = adjustment
        self.zPosition       = zPosition
        self.baseOpacity     = baseOpacity
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case assetURL, renderSize, contentMode, sourceStartTime
        case timeRangeStart, timeRangeDuration
        case transform, adjustment, zPosition, baseOpacity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.assetURL        = try c.decode(URL.self,         forKey: .assetURL)
        self.renderSize      = try c.decode(CGSize.self,      forKey: .renderSize)
        self.contentMode     = try c.decode(ContentFit.self,  forKey: .contentMode)
        self.sourceStartTime = try c.decode(Double.self,      forKey: .sourceStartTime)
        let startSec    = try c.decode(Double.self, forKey: .timeRangeStart)
        let durationSec = try c.decode(Double.self, forKey: .timeRangeDuration)
        self.timeRange   = CMTimeRange(start: CMTime(seconds: startSec, preferredTimescale: 600),
                                        duration: CMTime(seconds: durationSec, preferredTimescale: 600))
        self.transform   = try c.decodeIfPresent(SegmentTransform.self,  forKey: .transform)  ?? .identity
        self.adjustment  = try c.decodeIfPresent(SegmentAdjustment.self, forKey: .adjustment) ?? .identity
        self.zPosition   = try c.decodeIfPresent(Int32.self, forKey: .zPosition)   ?? 0
        self.baseOpacity = try c.decodeIfPresent(Float.self,  forKey: .baseOpacity) ?? 1.0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(assetURL,        forKey: .assetURL)
        try c.encode(renderSize,      forKey: .renderSize)
        try c.encode(contentMode,     forKey: .contentMode)
        try c.encode(sourceStartTime, forKey: .sourceStartTime)
        try c.encode(timeRange.start.seconds,    forKey: .timeRangeStart)
        try c.encode(timeRange.duration.seconds, forKey: .timeRangeDuration)
        try c.encodeIfPresent(transform,  forKey: .transform)
        try c.encodeIfPresent(adjustment, forKey: .adjustment)
        try c.encode(zPosition,    forKey: .zPosition)
        try c.encode(baseOpacity,  forKey: .baseOpacity)
    }
}

// MARK: - VideoLayerComposer

/// Stateless evaluator that produces a CIImage for a `VideoLayerSpec` at a given
/// composition time. Sources frames from `VideoFrameProviderProtocol`.
///
/// Pipeline:
///   - legacy/export fallback: source CGImage → CIImage → fit/transform/adjust/opacity
///   - realtime preview: CVPixelBuffer → CIImage(cvPixelBuffer:) → canvas crop
public enum VideoLayerComposer {

    /// Set by CompositionCoordinator when TimelineRuntime is active.
    /// Holds the active preview/export video frame source.
    nonisolated(unsafe) static public var frameProvider: VideoFrameProviderProtocol?

    /// Returns a CIImage for the video layer at the given composition time, or nil
    /// if the time falls outside the layer's time range or frame extraction fails.
    public static func evaluate(
        spec: VideoLayerSpec,
        at compositionTime: CMTime
    ) -> CIImage? {
        let start = spec.timeRange.start
        let end   = spec.timeRange.end

        guard compositionTime >= start, compositionTime < end else { return nil }
        guard let provider = frameProvider else { return nil }

        guard let frame = provider.frame(for: spec, at: compositionTime) else {
            return nil
        }

        if frame.isCanvasFrame {
            return frame.image.cropped(to: CGRect(origin: .zero, size: spec.renderSize))
        }

        let ciImage = frame.image
        let imageExtent = ciImage.extent
        guard imageExtent.width > 0, imageExtent.height > 0 else { return nil }

        // 1. Cover/contain/fill fit (reuses ImageLayerComposer's fitTransform).
        let fitT = ImageLayerComposer.fitTransform(
            mode:        spec.contentMode,
            imageExtent: imageExtent,
            canvasSize:  spec.renderSize,
            safeMargin:  0  // video has no keyframe animation
        )
        var result = ciImage.transformed(by: fitT)
            .cropped(to: CGRect(origin: .zero, size: spec.renderSize))

        // 2. Segment transform (position/scale/rotation).
        let segT = segmentTransformMatrix(spec: spec)
        result = result.transformed(by: segT)
            .cropped(to: CGRect(origin: .zero, size: spec.renderSize))

        // 3. Color adjustments.
        if !spec.adjustment.isIdentity {
            result = applyAdjustments(spec.adjustment, to: result)
        }

        // 4. Opacity.
        let finalOpacity = Double(spec.baseOpacity)
        if finalOpacity < 1.0 {
            result = result.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(finalOpacity))
            ])
        }

        return result
    }

    // MARK: - Segment transform

    /// Build a CGAffineTransform that applies position/scale/rotation matching
    /// `CompositionBuilder.coverFitTransform` semantics.
    private static func segmentTransformMatrix(spec: VideoLayerSpec) -> CGAffineTransform {
        let rw = spec.renderSize.width
        let rh = spec.renderSize.height
        guard rw > 0, rh > 0 else { return .identity }

        let s = max(spec.transform.scale, 0.01)
        let txCenter = (rw - rw * s) / 2
        let tyCenter = (rh - rh * s) / 2
        let txNudge = (spec.transform.position.x - 0.5) * rw
        let tyNudge = (spec.transform.position.y - 0.5) * rh
        let tx = txCenter + txNudge
        let ty = tyCenter + tyNudge

        var t = CGAffineTransform(scaleX: s, y: s)
            .translatedBy(x: tx / s, y: ty / s)

        if spec.transform.rotation != 0 {
            let cx = rw / 2
            let cy = rh / 2
            t = t
                .translatedBy(x: cx, y: cy)
                .rotated(by: CGFloat(spec.transform.rotation))
                .translatedBy(x: -cx, y: -cy)
        }

        return t
    }

    // MARK: - Color adjustments

    /// Replicates `UnifiedCompositor.applyAdjustments` CIFilter chain.
    private static func applyAdjustments(_ adj: SegmentAdjustment, to image: CIImage) -> CIImage {
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
}

#if canImport(UIKit)
import CoreImage
import CoreMedia
import os.log

private let composerLogger = Logger(subsystem: "TimelineKit", category: "AnimationComposer")

// MARK: - AnimationComposer

/// The SINGLE entry point for all clip animation rendering.
///
/// Called by TimelineRenderer and ExportFrameProvider after each layer's base CIImage
/// is evaluated (post KeyframeEvaluator / ImageLayerComposer / VideoLayerComposer),
/// and before UnifiedCompositor stacking.
///
/// Pipeline position:
///   ImageLayerComposer / VideoLayerComposer → [AnimationComposer.apply] → UnifiedCompositor
///
/// Constraints:
/// - NEVER modifies segment.targetRange (animation is render-only)
/// - NEVER applies animation to text/subtitle layers (Phase 1)
/// - Preview and Export share this exact function — no duplication
public enum AnimationComposer {

    /// Apply the active clip animation to a fully-rendered frame.
    ///
    /// Returns `image` unchanged if:
    /// - `animations` is empty
    /// - composition time is outside all animation windows
    ///
    /// - Parameters:
    ///   - image:             Rendered base frame (after KeyframeEvaluator).
    ///   - animations:        Clip-level animations from `ResolvedLayer.animations`.
    ///   - compositionTime:   Current timeline position in seconds.
    ///   - segmentTimeRange:  Absolute time range of the segment on the composition timeline.
    ///   - extent:            Canvas bounds.
    ///   - context:           Shared CIContext.
    public static func apply(
        to image: CIImage,
        animations: [ClipAnimation],
        compositionTime: Double,
        segmentTimeRange: CMTimeRange,
        extent: CGRect,
        context: CIContext
    ) -> CIImage {
        guard !animations.isEmpty else { return image }

        let segStart = segmentTimeRange.start.seconds
        let segEnd   = segStart + segmentTimeRange.duration.seconds
        let segDur   = segmentTimeRange.duration.seconds
        guard segDur > 1e-6 else { return image }

        // Combo animation takes precedence over in/out.
        if let combo = animations.first(where: { $0.timing == .combo }) {
            let progress = Float((compositionTime - segStart) / segDur)
            return applyPreset(
                id:      combo.semantic.resolvedPresetID(timing: .combo),
                to:      image,
                progress: clamp01(progress),
                extent:  extent,
                context: context
            )
        }

        // In animation: active from [segStart, segStart + effectiveDuration)
        if let inAnim = animations.first(where: { $0.timing == .in }) {
            let inDur = inAnim.effectiveDuration(segmentDuration: segDur)
            if compositionTime < segStart + inDur {
                let progress = Float((compositionTime - segStart) / inDur)
                return applyPreset(
                    id:       inAnim.semantic.resolvedPresetID(timing: .in),
                    to:       image,
                    progress: clamp01(progress),
                    extent:   extent,
                    context:  context
                )
            }
        }

        // Out animation: active from [segEnd - effectiveDuration, segEnd)
        if let outAnim = animations.first(where: { $0.timing == .out }) {
            let outDur   = outAnim.effectiveDuration(segmentDuration: segDur)
            let outStart = segEnd - outDur
            if compositionTime >= outStart {
                let progress = Float((compositionTime - outStart) / outDur)
                return applyPreset(
                    id:       outAnim.semantic.resolvedPresetID(timing: .out),
                    to:       image,
                    progress: clamp01(progress),
                    extent:   extent,
                    context:  context
                )
            }
        }

        return image  // no animation window active at this time
    }

    // MARK: - Private

    private static func applyPreset(
        id: String, to image: CIImage,
        progress: Float, extent: CGRect, context: CIContext
    ) -> CIImage {
        guard let preset = AnimationPresetRegistry.preset(for: id) else {
            composerLogger.warning("[AnimationComposer] preset '\(id, privacy: .public)' not found")
            return image
        }
        return preset.apply(to: image, progress: progress, extent: extent, context: context)
    }

    private static func clamp01(_ v: Float) -> Float { max(0, min(1, v)) }
}
#endif

import Foundation

/// Expands `ImageMotionPreset` and `DepthEffect` presets into concrete `KeyframeSet`
/// keyframe arrays at composition time. Presets are syntax sugar — the render path
/// only consumes `KeyframeSet`.
///
/// Called by `CompositionBuilder` when constructing `ImageLayerSpec` for segments
/// that carry a preset but no explicit `keyframes` (legacy drafts + AI imports
/// that only specify `type`).
enum AnimationMacro {

    /// Expand a motion preset + optional depth effect into a `KeyframeSet`.
    /// Returns an empty (identity) set when there is nothing to expand.
    static func expand(
        motionPreset: ImageMotionPreset?,
        depthEffect: SegmentContent.DepthEffect?,
        duration: Double
    ) -> KeyframeSet {
        var kf = KeyframeSet()

        if let preset = motionPreset {
            applyMotionPreset(preset, duration: duration, to: &kf)
        }

        if let depth = depthEffect {
            applyDepthEffect(depth, duration: duration, to: &kf)
        }

        return kf
    }

    // MARK: - Motion presets (Ken Burns family)

    private static func applyMotionPreset(
        _ preset: ImageMotionPreset,
        duration: Double,
        to kf: inout KeyframeSet
    ) {
        // V6 Fix B: Pan presets must combine translation + zoom (Ken Burns) so
        // the image always covers the canvas — pure translation reveals the
        // black background at the trailing edge. Pan offset 6% canvas + base
        // zoom 1.06 → 1.0 (matches CapCut / 剪映 pan-and-zoom feel).
        // safeMargin in ImageLayerComposer.fitTransform then inflates baseScale
        // by max(|position − 0.5|, (1 − scale)/2) + 0.04 to guarantee no reveal.
        let ease = Easing.easeOut
        let centre = NormalizedPoint(x: 0.5, y: 0.5)
        let panOffset = 0.06

        switch preset {
        case .zoomIn:
            kf.scale = [
                Keyframe(time: 0, value: 1.04),
                Keyframe(time: duration, value: 1.19, easing: ease)
            ]
        case .zoomInSlow:
            // Stronger, perceptible push-in. easeOut so motion is most visible
            // at the start and settles toward the end — matches 剪映 "轻微推进".
            kf.scale = [
                Keyframe(time: 0, value: 1.04),
                Keyframe(time: duration, value: 1.14, easing: ease)
            ]
        case .zoomOut:
            kf.scale = [
                Keyframe(time: 0, value: 1.16),
                Keyframe(time: duration, value: 1.04, easing: ease)
            ]
        case .panLeft:
            // Subject pans LEFT — position x decreases. Aligns with
            // TimelineImporter.buildImage3DKeyframes (pan_left → x: 0.5 - panOffset).
            kf.position = [
                Keyframe<NormalizedPoint>(time: 0, value: centre),
                Keyframe<NormalizedPoint>(time: duration,
                    value: NormalizedPoint(x: 0.5 - panOffset, y: 0.5), easing: ease)
            ]
            kf.scale = [
                Keyframe(time: 0, value: 1.06),
                Keyframe(time: duration, value: 1.0, easing: ease)
            ]
        case .panRight:
            // Subject pans RIGHT — position x increases.
            kf.position = [
                Keyframe<NormalizedPoint>(time: 0, value: centre),
                Keyframe<NormalizedPoint>(time: duration,
                    value: NormalizedPoint(x: 0.5 + panOffset, y: 0.5), easing: ease)
            ]
            kf.scale = [
                Keyframe(time: 0, value: 1.06),
                Keyframe(time: duration, value: 1.0, easing: ease)
            ]
        case .panUp:
            kf.position = [
                Keyframe<NormalizedPoint>(time: 0, value: centre),
                Keyframe<NormalizedPoint>(time: duration,
                    value: NormalizedPoint(x: 0.5, y: 0.5 - panOffset), easing: ease)
            ]
            kf.scale = [
                Keyframe(time: 0, value: 1.06),
                Keyframe(time: duration, value: 1.0, easing: ease)
            ]
        case .panDown:
            kf.position = [
                Keyframe<NormalizedPoint>(time: 0, value: centre),
                Keyframe<NormalizedPoint>(time: duration,
                    value: NormalizedPoint(x: 0.5, y: 0.5 + panOffset), easing: ease)
            ]
            kf.scale = [
                Keyframe(time: 0, value: 1.06),
                Keyframe(time: duration, value: 1.0, easing: ease)
            ]
        case .fade:
            kf.opacity = [
                Keyframe(time: 0, value: 0.0),
                Keyframe(time: min(0.5, duration * 0.3), value: 1.0, easing: .easeInOut)
            ]
        case .still:
            break
        }
    }

    // MARK: - Depth effect (2.5D camera parallax)

    private static func applyDepthEffect(
        _ depth: SegmentContent.DepthEffect,
        duration: Double,
        to kf: inout KeyframeSet
    ) {
        let animDuration = min(depth.duration, duration)
        guard animDuration > 0 else { return }

        let intensity = depth.intensity
        // V6 Fix F: Match V5 StaticImageRenderer intensity semantics.
        // zoom: 1.0 → 1.0 + intensity (direct, no damping coefficient).
        // pan:  translate = intensity × canvasSize — pair with counter-zoom
        // so the image keeps covering the canvas.
        let panOffset  = intensity
        let zoomOffset = intensity
        let startPoint = NormalizedPoint(x: 0.5, y: 0.5)

        let endPoint: NormalizedPoint
        switch depth.moveDirection {
        // Subject moves in named direction (matches buildImage3DKeyframes).
        case "pan_left", "left":  endPoint = NormalizedPoint(x: 0.5 - panOffset, y: 0.5)
        case "pan_right", "right": endPoint = NormalizedPoint(x: 0.5 + panOffset, y: 0.5)
        case "pan_up":    endPoint = NormalizedPoint(x: 0.5, y: 0.5 - panOffset)
        case "pan_down":  endPoint = NormalizedPoint(x: 0.5, y: 0.5 + panOffset)
        case "zoom_in", "forward":
            kf.scale = [
                Keyframe(time: 0, value: 1.0),
                Keyframe(time: animDuration, value: 1.0 + zoomOffset, easing: .easeOut)
            ]
            return
        case "zoom_out", "backward":
            kf.scale = [
                Keyframe(time: 0, value: 1.0 + zoomOffset),
                Keyframe(time: animDuration, value: 1.0, easing: .easeOut)
            ]
            return
        default:
            return
        }

        // Pair pan with subtle counter-zoom so cover holds throughout.
        kf.position = [
            Keyframe<NormalizedPoint>(time: 0, value: startPoint),
            Keyframe<NormalizedPoint>(time: animDuration, value: endPoint, easing: .easeOut)
        ]
        kf.scale = [
            Keyframe(time: 0, value: 1.0 + panOffset * 0.5),
            Keyframe(time: animDuration, value: 1.0, easing: .easeOut)
        ]
    }
}

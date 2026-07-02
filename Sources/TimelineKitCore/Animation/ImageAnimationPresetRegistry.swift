import Foundation

// MARK: - ImageAnimationPreset

/// Client-side animation template identifier. Written to `ImageContent.animationPresetID`
/// for UI display; the actual animation is driven by `ImageContent.keyframes`.
public enum ImageAnimationPreset: String, CaseIterable, Sendable, Hashable {

    // MARK: image_motion tab (Ken Burns family)
    case none            = "none"
    case slowZoomIn      = "slow_zoom_in"
    case slowZoomOut     = "slow_zoom_out"
    case panLeft         = "pan_left"
    case panRight        = "pan_right"
    case panUp           = "pan_up"
    case panDown         = "pan_down"
    case gentlePush      = "gentle_push"
    case gentlePullBack  = "gentle_pull_back"

    // MARK: image_3d tab (depth simulation — single-layer Ken Burns, V1)
    case depthPush       = "depth_push"
    case depthPull       = "depth_pull"
    case depthPanLeft    = "depth_pan_left"
    case depthPanRight   = "depth_pan_right"
    case depthPanUp      = "depth_pan_up"
    case depthPanDown    = "depth_pan_down"
    case depthOrbitLeft  = "depth_orbit_left"
    case depthOrbitRight = "depth_orbit_right"

    public var displayName: String {
        switch self {
        case .none:           return "无动画"
        case .slowZoomIn:     return "缓慢放大"
        case .slowZoomOut:    return "缓慢缩小"
        case .panLeft:        return "向左平移"
        case .panRight:       return "向右平移"
        case .panUp:          return "向上平移"
        case .panDown:        return "向下平移"
        case .gentlePush:     return "轻微推进"
        case .gentlePullBack: return "轻微后退"
        case .depthPush:      return "景深推进"
        case .depthPull:      return "景深后退"
        case .depthPanLeft:   return "景深左移"
        case .depthPanRight:  return "景深右移"
        case .depthPanUp:     return "景深上移"
        case .depthPanDown:   return "景深下移"
        case .depthOrbitLeft:  return "轻微环绕左"
        case .depthOrbitRight: return "轻微环绕右"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .none:            return "circle.slash"
        case .slowZoomIn:      return "arrow.up.left.and.arrow.down.right"
        case .slowZoomOut:     return "arrow.down.right.and.arrow.up.left"
        case .panLeft:         return "arrow.left"
        case .panRight:        return "arrow.right"
        case .panUp:           return "arrow.up"
        case .panDown:         return "arrow.down"
        case .gentlePush:      return "plus.circle"
        case .gentlePullBack:  return "minus.circle"
        case .depthPush:       return "circle.bottomhalf.filled"
        case .depthPull:       return "circle.tophalf.filled"
        case .depthPanLeft:    return "arrow.left.circle"
        case .depthPanRight:   return "arrow.right.circle"
        case .depthPanUp:      return "arrow.up.circle"
        case .depthPanDown:    return "arrow.down.circle"
        case .depthOrbitLeft:  return "arrow.counterclockwise"
        case .depthOrbitRight: return "arrow.clockwise"
        }
    }

    /// Presets shown in the "基础动画" tab.
    public static let motionPresets: [ImageAnimationPreset] = [
        .none, .slowZoomIn, .slowZoomOut, .panLeft, .panRight, .panUp, .panDown,
        .gentlePush, .gentlePullBack
    ]

    /// Presets shown in the "景深动画" tab.
    public static let depthPresets: [ImageAnimationPreset] = [
        .depthPush, .depthPull, .depthPanLeft, .depthPanRight,
        .depthPanUp, .depthPanDown, .depthOrbitLeft, .depthOrbitRight
    ]
}

// MARK: - ImageAnimationPresetRegistry

/// Client-side standard keyframe template library.
/// Each preset outputs a concrete `KeyframeSet` using local-time coordinates
/// (0 = segment start, duration = segment end), matching `KeyframeEvaluator`'s
/// contract. Returns nil for `.none` (static image, no keyframes).
///
/// This registry is the source of truth for animation values. Server-side
/// animation parameters should be aligned to these semantics, not the reverse.
public enum ImageAnimationPresetRegistry {

    /// Build a `KeyframeSet` for the given preset, or nil for `.none`.
    /// - Parameters:
    ///   - preset: the template to expand
    ///   - duration: segment duration in seconds (local-time end point for keyframes)
    public static func keyframes(
        for preset: ImageAnimationPreset,
        duration: Double
    ) -> KeyframeSet? {
        guard duration > 1e-6 else { return nil }
        switch preset {
        case .none:           return nil
        case .slowZoomIn:     return motionZoomIn(duration: duration)
        case .slowZoomOut:    return motionZoomOut(duration: duration)
        case .panLeft:        return motionPan(dx: -0.06, dy: 0, duration: duration)
        case .panRight:       return motionPan(dx: +0.06, dy: 0, duration: duration)
        case .panUp:          return motionPan(dx: 0, dy: -0.06, duration: duration)
        case .panDown:        return motionPan(dx: 0, dy: +0.06, duration: duration)
        case .gentlePush:     return motionGentlePush(duration: duration)
        case .gentlePullBack: return motionGentlePullBack(duration: duration)
        case .depthPush:      return depthPush(duration: duration)
        case .depthPull:      return depthPull(duration: duration)
        case .depthPanLeft:   return depthPan(dx: -0.08, dy: 0, duration: duration)
        case .depthPanRight:  return depthPan(dx: +0.08, dy: 0, duration: duration)
        case .depthPanUp:     return depthPan(dx: 0, dy: -0.08, duration: duration)
        case .depthPanDown:   return depthPan(dx: 0, dy: +0.08, duration: duration)
        case .depthOrbitLeft:  return depthOrbit(dx: -0.06, duration: duration)
        case .depthOrbitRight: return depthOrbit(dx: +0.06, duration: duration)
        }
    }

    // MARK: - image_motion (Ken Burns)

    private static func motionZoomIn(duration: Double) -> KeyframeSet {
        KeyframeSet(scale: [
            Keyframe(time: 0,        value: 1.0),
            Keyframe(time: duration, value: 1.15, easing: .easeOut)
        ])
    }

    private static func motionZoomOut(duration: Double) -> KeyframeSet {
        KeyframeSet(scale: [
            Keyframe(time: 0,        value: 1.12),
            Keyframe(time: duration, value: 1.0, easing: .easeOut)
        ])
    }

    private static func motionPan(dx: Double, dy: Double, duration: Double) -> KeyframeSet {
        let centre = NormalizedPoint(x: 0.5, y: 0.5)
        let end    = NormalizedPoint(x: 0.5 + dx, y: 0.5 + dy)
        return KeyframeSet(
            position: [
                Keyframe(time: 0,        value: centre),
                Keyframe(time: duration, value: end, easing: .easeOut)
            ],
            scale: [
                Keyframe(time: 0,        value: 1.06),
                Keyframe(time: duration, value: 1.0, easing: .easeOut)
            ]
        )
    }

    private static func motionGentlePush(duration: Double) -> KeyframeSet {
        KeyframeSet(scale: [
            Keyframe(time: 0,        value: 1.0),
            Keyframe(time: duration, value: 1.10, easing: .easeOut)
        ])
    }

    private static func motionGentlePullBack(duration: Double) -> KeyframeSet {
        KeyframeSet(scale: [
            Keyframe(time: 0,        value: 1.08),
            Keyframe(time: duration, value: 1.0, easing: .easeOut)
        ])
    }

    // MARK: - image_3d (depth simulation, single-layer Ken Burns V1)

    private static func depthPush(duration: Double) -> KeyframeSet {
        // Stronger push-in than motionGentlePush — simulates camera moving forward.
        KeyframeSet(scale: [
            Keyframe(time: 0,        value: 1.0),
            Keyframe(time: duration, value: 1.22, easing: .easeOut)
        ])
    }

    private static func depthPull(duration: Double) -> KeyframeSet {
        KeyframeSet(scale: [
            Keyframe(time: 0,        value: 1.22),
            Keyframe(time: duration, value: 1.0, easing: .easeOut)
        ])
    }

    private static func depthPan(dx: Double, dy: Double, duration: Double) -> KeyframeSet {
        // Deeper pan offset + stronger counter-zoom for depth cue.
        let centre = NormalizedPoint(x: 0.5, y: 0.5)
        let end    = NormalizedPoint(x: 0.5 + dx, y: 0.5 + dy)
        return KeyframeSet(
            position: [
                Keyframe(time: 0,        value: centre),
                Keyframe(time: duration, value: end, easing: .easeOut)
            ],
            scale: [
                Keyframe(time: 0,        value: 1.15),
                Keyframe(time: duration, value: 1.0, easing: .easeOut)
            ]
        )
    }

    private static func depthOrbit(dx: Double, duration: Double) -> KeyframeSet {
        // Pan in given direction while zooming IN — "orbiting" parallax feel.
        let centre = NormalizedPoint(x: 0.5, y: 0.5)
        let end    = NormalizedPoint(x: 0.5 + dx, y: 0.5)
        return KeyframeSet(
            position: [
                Keyframe(time: 0,        value: centre),
                Keyframe(time: duration, value: end, easing: .easeOut)
            ],
            scale: [
                Keyframe(time: 0,        value: 1.0),
                Keyframe(time: duration, value: 1.12, easing: .easeOut)
            ]
        )
    }
}

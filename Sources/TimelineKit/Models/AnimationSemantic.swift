import Foundation
import os.log

// MARK: - AnimationSemantic

/// Stable, intent-level description of a clip animation effect.
///
/// Three-layer architecture (parallel to TransitionSemantic):
/// ```
/// server JSON field (raw, may change over time)
///         ↓  AnimationSemantic.from(serverType:timing:direction:)
/// AnimationSemantic (stable — captures visual intent, never the implementation)
///         ↓  AnimationSemantic.resolvedPresetID(timing:)
/// runtime presetID (client-internal, free to refactor)
/// ```
public enum AnimationSemantic: String, Sendable, Hashable, Codable, CaseIterable {

    // MARK: Entrance (入场)
    case fadeIn        = "fade_in"
    case slideInLeft   = "slide_in_left"
    case slideInRight  = "slide_in_right"
    case slideInUp     = "slide_in_up"
    case slideInDown   = "slide_in_down"
    case zoomIn        = "zoom_in"

    // MARK: Exit (出场)
    case fadeOut       = "fade_out"
    case slideOutLeft  = "slide_out_left"
    case slideOutRight = "slide_out_right"
    case zoomOut       = "zoom_out"

    // MARK: Combo (组合，全程时长) — Ken Burns 基础动画
    case slowZoom      = "slow_zoom"       // 缓慢放大 (zoom in)
    case slowZoomOut   = "slow_zoom_out"   // 缓慢缩小 (zoom out)
    case panLeft       = "pan_left"        // 向左平移
    case panRight      = "pan_right"       // 向右平移
    case drift         = "drift"           // 漂移 (gentle right drift)
    case float         = "float"           // 漂浮 (sinusoidal bob)

    // MARK: Combo — 景深动画 (migrated from ImageAnimationPreset)
    case depthPush       = "depth_push"        // 景深推进
    case depthPull       = "depth_pull"        // 景深后退
    case depthPanLeft    = "depth_pan_left"    // 景深左移
    case depthPanRight   = "depth_pan_right"   // 景深右移
    case depthOrbitLeft  = "depth_orbit_left"  // 环绕左
    case depthOrbitRight = "depth_orbit_right" // 环绕右

    // MARK: Fallback
    /// Unknown intent — falls back to fadeIn / fadeOut / slowZoom by timing.
    case unknown = "unknown"
}

// MARK: - Server → Semantic

private let animationLogger = Logger(subsystem: "TimelineKit", category: "AnimationSemantic")

extension AnimationSemantic {

    /// Parse a raw server animation type string into a stable semantic intent.
    ///
    /// - Parameters:
    ///   - serverType: The `type` field from `SAnimation` (arbitrary server string).
    ///   - timing:     The animation phase (in / out / combo). Used for directional defaults.
    ///   - direction:  Optional directional qualifier ("left", "right", "up", "down").
    /// - Returns: The best-matching `AnimationSemantic`, or `.unknown` with a log entry.
    public static func from(
        serverType: String,
        timing: AnimationTiming = .in,
        direction: String? = nil
    ) -> AnimationSemantic {
        let type = serverType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dir  = direction?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch type {

        // ── Fade family ───────────────────────────────────────────────────────
        case "fade", "alpha", "opacity":
            return timing == .out ? .fadeOut : .fadeIn
        case "fade_in",  "fadein",  "alpha_in":   return .fadeIn
        case "fade_out", "fadeout", "alpha_out":  return .fadeOut

        // ── Slide-in family ───────────────────────────────────────────────────
        case "slide", "slide_in":
            switch dir {
            case "right": return .slideInRight
            case "up":    return .slideInUp
            case "down":  return .slideInDown
            default:      return .slideInLeft
            }
        case "slide_in_left":   return .slideInLeft
        case "slide_in_right":  return .slideInRight
        case "slide_in_up":     return .slideInUp
        case "slide_in_down":   return .slideInDown

        // ── Slide-out family ──────────────────────────────────────────────────
        case "slide_out", "slide_out_left":   return .slideOutLeft
        case "slide_out_right":               return .slideOutRight

        // ── Zoom family ───────────────────────────────────────────────────────
        case "zoom", "scale":
            return timing == .out ? .zoomOut : .zoomIn
        case "zoom_in",  "zoomin",  "scale_in":  return .zoomIn
        case "zoom_out", "zoomout", "scale_out": return .zoomOut

        // ── Combo / Ken Burns family ──────────────────────────────────────────
        case "slow_zoom", "slowzoom", "ken_burns", "zoom_loop", "slow_zoom_in":
            return .slowZoom
        case "slow_zoom_out", "slowzoomout", "zoom_out_loop":
            return .slowZoomOut
        case "pan_left",  "panleft":  return .panLeft
        case "pan_right", "panright": return .panRight
        case "drift", "pan", "pan_loop": return .drift
        case "float", "breath", "breathe", "pulse", "breathing": return .float

        // ── Depth family ──────────────────────────────────────────────────────
        case "depth_push", "image_3d_push", "forward": return .depthPush
        case "depth_pull", "image_3d_pull", "backward": return .depthPull
        case "depth_pan_left",  "image_3d_pan_left":  return .depthPanLeft
        case "depth_pan_right", "image_3d_pan_right": return .depthPanRight
        case "depth_orbit_left",  "orbit_left":  return .depthOrbitLeft
        case "depth_orbit_right", "orbit_right": return .depthOrbitRight

        // ── Unrecognized ──────────────────────────────────────────────────────
        default:
            animationLogger.warning(
                "[AnimationSemantic] '\(type, privacy: .public)': unrecognized type, using unknown"
            )
            return .unknown
        }
    }
}

// MARK: - Semantic → Runtime presetID

extension AnimationSemantic {

    /// Resolve to a registered client presetID.
    ///
    /// This is the ONLY place in the codebase where AnimationSemantic → presetID
    /// mapping lives. All other code uses either AnimationSemantic or presetID, never both.
    ///
    /// Falls back to safe defaults if the preset is not yet registered.
    public func resolvedPresetID(timing: AnimationTiming) -> String {
        let target: String
        switch self {
        case .fadeIn:        target = "fadeIn"
        case .slideInLeft:   target = "slideInLeft"
        case .slideInRight:  target = "slideInRight"
        case .slideInUp:     target = "slideInUp"
        case .slideInDown:   target = "slideInDown"
        case .zoomIn:        target = "zoomIn"
        case .fadeOut:       target = "fadeOut"
        case .slideOutLeft:  target = "slideOutLeft"
        case .slideOutRight: target = "slideOutRight"
        case .zoomOut:       target = "zoomOut"
        case .slowZoom:        target = "slowZoom"
        case .slowZoomOut:     target = "slowZoomOut"
        case .panLeft:         target = "panLeft"
        case .panRight:        target = "panRight"
        case .drift:           target = "drift"
        case .float:           target = "float"
        case .depthPush:       target = "depthPush"
        case .depthPull:       target = "depthPull"
        case .depthPanLeft:    target = "depthPanLeft"
        case .depthPanRight:   target = "depthPanRight"
        case .depthOrbitLeft:  target = "depthOrbitLeft"
        case .depthOrbitRight: target = "depthOrbitRight"
        case .unknown:
            let fallback = defaultPresetID(timing: timing)
            animationLogger.debug(
                "[AnimationSemantic] unknown semantic, fallback to \(fallback, privacy: .public)"
            )
            return fallback
        }

        if AnimationPresetRegistry.preset(for: target) != nil {
            return target
        }
        let fallback = defaultPresetID(timing: timing)
        animationLogger.debug(
            "[AnimationSemantic] preset '\(target, privacy: .public)' not registered, fallback to \(fallback, privacy: .public)"
        )
        return fallback
    }

    private func defaultPresetID(timing: AnimationTiming) -> String {
        switch timing {
        case .out:   return "fadeOut"
        case .combo: return "slowZoom"
        case .in:    return "fadeIn"
        }
    }
}

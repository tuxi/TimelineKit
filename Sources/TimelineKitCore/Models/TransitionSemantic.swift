import Foundation
import os.log

// MARK: - TransitionSemantic

/// Stable, intent-level description of a transition effect.
///
/// Three-layer architecture:
/// ```
/// server JSON field (raw, may change over time)
///         ↓
/// TransitionSemantic (stable — captures visual intent, never the implementation)
///         ↓
/// runtime presetID (client-internal, free to refactor)
/// ```
///
/// Adding a new server transition type only requires updating `from(server:)`.
/// Renaming / replacing a client preset only requires updating `resolvedPresetID`.
/// Neither change affects the other layer.
public enum TransitionSemantic: String, Sendable, Hashable, Codable, CaseIterable {
    /// Standard cross-dissolve (opacity blend). Default fallback for unknown types.
    case crossFade          = "cross_fade"
    /// Fade to black, then fade in incoming.
    case fadeThroughBlack   = "fade_through_black"
    /// Outgoing slides left, incoming enters from right.
    case slideLeft          = "slide_left"
    /// Outgoing slides right, incoming enters from left.
    case slideRight         = "slide_right"
    /// Both frames push together leftward (abutting, no gap).
    case pushLeft           = "push_left"
    /// Both frames push together rightward.
    case pushRight          = "push_right"
    /// Outgoing zooms/fades out; incoming appears.
    case zoomIn             = "zoom_in"
    /// Outgoing blurs out while incoming fades in.
    case blurFade           = "blur_fade"
    /// Intent not recognized — always maps to crossFade at runtime.
    case unknown            = "unknown"
}

// MARK: - Server → Semantic

private let semanticLogger = Logger(subsystem: "TimelineKit", category: "TransitionSemantic")

extension TransitionSemantic {

    /// Parse a raw server transition into a stable semantic intent.
    ///
    /// - Parameters:
    ///   - serverType: The `type` field from `STransition` (arbitrary server string).
    ///   - direction:  Optional directional qualifier ("left", "right", "up", "down").
    ///   - style:      Optional style qualifier (currently unused, reserved).
    /// - Returns: The best-matching `TransitionSemantic`, or `.unknown` with a log entry
    ///            if the type string is not recognized.
    public static func from(
        serverType: String,
        direction: String? = nil,
        style: String? = nil
    ) -> TransitionSemantic {
        let type = serverType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dir  = direction?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch type {

        // ── Dissolve family ───────────────────────────────────────────────────
        case "fade", "dissolve", "cross_fade", "crossfade", "alpha", "alpha_fade",
             "opacity", "default":
            return .crossFade

        // ── Black-dip family ─────────────────────────────────────────────────
        case "fade_through_black", "fadethroughblack", "dip_black", "dipblack",
             "flash_black", "flashblack", "black_fade":
            return .fadeThroughBlack

        // ── Slide family ─────────────────────────────────────────────────────
        case "slide", "slide_left":
            return dir == "right" ? .slideRight : .slideLeft
        case "slide_right":
            return .slideRight
        case "slide_up", "slide_down":
            // No vertical preset yet → fallback to crossFade
            logUnknown(type: serverType, reason: "no vertical slide preset, using crossFade")
            return .crossFade

        // ── Push family ──────────────────────────────────────────────────────
        case "push", "push_left", "cinematic_push", "cinematicpush":
            return dir == "right" ? .pushRight : .pushLeft
        case "push_right":
            return .pushRight

        // ── Zoom family ──────────────────────────────────────────────────────
        case "zoom", "zoom_in", "zoomin", "scale_in", "scalein":
            return .zoomIn

        // ── Blur family ──────────────────────────────────────────────────────
        case "blur", "blur_fade", "blurfade", "gaussian_blur":
            return .blurFade

        // ── Unrecognized ─────────────────────────────────────────────────────
        default:
            logUnknown(type: serverType, reason: "unrecognized server type, defaulting to crossFade")
            return .unknown
        }
    }

    private static func logUnknown(type: String, reason: String) {
        semanticLogger.warning(
            "[TransitionSemantic] '\(type, privacy: .public)': \(reason, privacy: .public)"
        )
    }
}

// MARK: - Semantic → Runtime presetID

extension TransitionSemantic {

    /// Resolve to a registered client presetID.
    ///
    /// If the target preset is not yet registered (e.g. a future M6 preset),
    /// falls back to "crossFade" and logs a debug note.
    ///
    /// This is the ONLY place in the codebase where semantic → presetID mapping lives.
    /// All other code uses either `TransitionSemantic` or `presetID`, never both.
    public var resolvedPresetID: String {
        let target: String
        switch self {
        case .crossFade:        target = "crossFade"
        case .fadeThroughBlack: target = "fadeThroughBlack"
        case .slideLeft:        target = "slideLeft"
        case .slideRight:       target = "slideRight"
        case .pushLeft:         target = "pushLeft"
        case .pushRight:        target = "pushRight"
        case .zoomIn:           target = "zoomIn"
        case .blurFade:         target = "blurFade"
        case .unknown:          target = "crossFade"
        }
        // Graceful degradation: if the preset hasn't been registered yet (e.g. M6 presets
        // on an older build), fall back to crossFade so nothing crashes or goes black.
        if TransitionPresetRegistry.preset(for: target) != nil {
            return target
        }
        semanticLogger.debug(
            "[TransitionSemantic] preset '\(target, privacy: .public)' not registered, using crossFade"
        )
        return "crossFade"
    }
}

// MARK: - EditorTransition.TransitionType bridge (backward compat)

extension TransitionSemantic {

    /// Convert a legacy `EditorTransition.TransitionType` to its semantic equivalent.
    /// Used when loading old drafts that only have `type` and no `presetID`.
    public static func from(legacyType: EditorTransition.TransitionType) -> TransitionSemantic {
        switch legacyType {
        case .fade, .dissolve, .crossFade:    return .crossFade
        case .fadeThroughBlack:               return .fadeThroughBlack
        case .slideLeft:                      return .slideLeft
        case .slideRight:                     return .slideRight
        case .pushLeft:                       return .pushLeft
        case .pushRight:                      return .pushRight
        case .zoom, .zoomIn:                  return .zoomIn
        case .blurFade:                       return .blurFade
        case .slideUp, .slideDown, .wipe:     return .crossFade  // no vertical preset yet
        }
    }
}

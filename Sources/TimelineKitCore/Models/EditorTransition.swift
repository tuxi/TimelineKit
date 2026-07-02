import Foundation

/// A transition between two adjacent segments.
/// Stored independently from segments — not attached to either clip —
/// so reordering or deleting segments does not silently orphan transitions.
public struct EditorTransition: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var type: TransitionType
    public var duration: Double
    public var easing: Easing
    /// The segment that plays before the transition.
    public var leadingSegmentID: UUID
    /// The segment that plays after the transition.
    public var trailingSegmentID: UUID

    // V7: preset-based fields — all Optional so old drafts decode safely.
    /// Canonical preset identifier (e.g. "crossFade", "slideLeft"). Nil → falls back to `type`.
    public var presetID: String?
    /// Direction hint for directional presets (slide/push). Nil → preset default.
    public var direction: Direction?
    /// Filter-specific intensity weight (0…1). Nil → preset default (1.0).
    public var intensity: Float?

    public init(
        id: UUID = UUID(),
        type: TransitionType,
        duration: Double,
        easing: Easing = .easeInOut,
        leadingSegmentID: UUID,
        trailingSegmentID: UUID,
        presetID: String? = nil,
        direction: Direction? = nil,
        intensity: Float? = nil
    ) {
        self.id                = id
        self.type              = type
        self.duration          = duration
        self.easing            = easing
        self.leadingSegmentID  = leadingSegmentID
        self.trailingSegmentID = trailingSegmentID
        self.presetID          = presetID
        self.direction         = direction
        self.intensity         = intensity
    }

    public enum Direction: String, Sendable, Hashable, Codable {
        case left, right, up, down
    }

    public enum TransitionType: String, Sendable, Hashable, Codable, CaseIterable {
        // V2 legacy types (kept for backward compat; mapped to presetID via registry)
        case fade
        case slideLeft   = "slide_left"
        case slideRight  = "slide_right"
        case slideUp     = "slide_up"
        case slideDown   = "slide_down"
        case zoom
        case dissolve
        case wipe
        // V7 canonical types (align 1:1 with presetID)
        case crossFade        = "cross_fade"
        case fadeThroughBlack = "fade_through_black"
        case pushLeft         = "push_left"
        case pushRight        = "push_right"
        case zoomIn           = "zoom_in"
        case blurFade         = "blur_fade"
    }

    public enum Easing: String, Sendable, Hashable, Codable, CaseIterable {
        case linear
        case easeIn    = "ease_in"
        case easeOut   = "ease_out"
        case easeInOut = "ease_in_out"
    }
}

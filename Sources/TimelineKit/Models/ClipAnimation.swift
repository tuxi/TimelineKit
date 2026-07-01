import Foundation

// MARK: - AnimationTiming

/// Which phase of a clip this animation applies to.
public enum AnimationTiming: String, Sendable, Hashable, Codable, CaseIterable {
    /// Entrance: applies from clip start to clip start + duration.
    case `in`  = "in"
    /// Exit: applies from clip end - duration to clip end.
    case out   = "out"
    /// Combo (full-duration): applies across the entire clip. Mutually exclusive with in/out.
    case combo = "combo"
}

// MARK: - AnimationDirection

public enum AnimationDirection: String, Sendable, Hashable, Codable, CaseIterable {
    case left, right, up, down
}

// MARK: - ClipAnimation

/// A single clip-level animation (entrance / exit / combo).
///
/// Stored as `EditorSegment.animations`. Does NOT modify `targetRange`.
/// Saved as semantic + duration — never as baked keyframes.
public struct ClipAnimation: Identifiable, Sendable, Hashable, Codable {

    public let id: UUID

    /// Stable semantic intent (server-facing). Written by server or user selection.
    public var semantic: AnimationSemantic

    /// Which phase of the clip this animation applies to.
    public var timing: AnimationTiming

    /// Duration in seconds. For combo animations this equals the segment duration.
    /// Clamped at render time to [0.1, min(2.0, segDuration * 0.5)] for in/out.
    public var duration: Double

    /// Optional directional qualifier for slide-family animations.
    public var direction: AnimationDirection?

    /// Effect intensity 0.0–1.0. Nil = preset default.
    public var intensity: Float?

    public init(
        id: UUID = UUID(),
        semantic: AnimationSemantic,
        timing: AnimationTiming,
        duration: Double,
        direction: AnimationDirection? = nil,
        intensity: Float? = nil
    ) {
        self.id        = id
        self.semantic  = semantic
        self.timing    = timing
        self.duration  = duration
        self.direction = direction
        self.intensity = intensity
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, semantic, timing, duration, direction, intensity
    }

    public init(from decoder: Decoder) throws {
        let c         = try decoder.container(keyedBy: CodingKeys.self)
        self.id        = try c.decode(UUID.self,               forKey: .id)
        self.semantic  = try c.decode(AnimationSemantic.self,  forKey: .semantic)
        self.timing    = try c.decode(AnimationTiming.self,    forKey: .timing)
        self.duration  = try c.decode(Double.self,             forKey: .duration)
        self.direction = try c.decodeIfPresent(AnimationDirection.self, forKey: .direction)
        self.intensity = try c.decodeIfPresent(Float.self,              forKey: .intensity)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,        forKey: .id)
        try c.encode(semantic,  forKey: .semantic)
        try c.encode(timing,    forKey: .timing)
        try c.encode(duration,  forKey: .duration)
        try c.encodeIfPresent(direction, forKey: .direction)
        try c.encodeIfPresent(intensity, forKey: .intensity)
    }
}

// MARK: - Effective duration

extension ClipAnimation {
    /// Duration clamped to segment constraints.
    /// - For combo animations: returns segmentDuration (combo covers the full clip).
    /// - For in/out: clamps to [0.1, min(2.0, segmentDuration * 0.5)].
    public func effectiveDuration(segmentDuration: Double) -> Double {
        if timing == .combo { return segmentDuration }
        let maxHalf = segmentDuration * 0.5
        return max(0.1, min(duration, min(2.0, maxHalf)))
    }
}

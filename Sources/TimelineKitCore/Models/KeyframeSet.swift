import Foundation

// MARK: - KeyframeEasing

/// Easing curve for a keyframe segment. Module-level so it is not parameterised by
/// the keyframe value type — `Easing` works uniformly for `Keyframe<Double>`,
/// `Keyframe<NormalizedPoint>`, and any future value types.
public enum Easing: String, Sendable, Hashable, Codable, CaseIterable {
    case linear
    case easeIn    = "ease_in"
    case easeOut   = "ease_out"
    case easeInOut = "ease_in_out"
    /// V6: Parameterised cubic-bezier with four control-point ordinates (0…1).
    case cubicBezier

    /// Convert to the standalone EasingKind used by the animation LUT layer.
    var easingKind: EasingKind {
        switch self {
        case .linear:      return .linear
        case .easeIn:      return .easeIn
        case .easeOut:     return .easeOut
        case .easeInOut:   return .easeInOut
        case .cubicBezier: return .cubicBezier(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
        }
    }
}

// MARK: - KeyframeSet

/// All keyframe tracks for a single segment.
/// Keyframe times are absolute (seconds from timeline origin), same coordinate system as TimeRange.
public struct KeyframeSet: Sendable, Hashable, Codable {
    public var opacity:  [Keyframe<Double>]
    public var position: [Keyframe<NormalizedPoint>]
    public var scale:    [Keyframe<Double>]
    public var rotation: [Keyframe<Double>]   // radians
    /// v6: Anchor point (0…1, 0…1) for scale/rotation center. Default (0.5, 0.5) = center.
    public var anchor:   [Keyframe<NormalizedPoint>]

    public static let empty = KeyframeSet(opacity: [], position: [], scale: [], rotation: [], anchor: [])

    public var isEmpty: Bool {
        opacity.isEmpty && position.isEmpty && scale.isEmpty && rotation.isEmpty && anchor.isEmpty
    }

    public init(
        opacity:  [Keyframe<Double>]          = [],
        position: [Keyframe<NormalizedPoint>] = [],
        scale:    [Keyframe<Double>]          = [],
        rotation: [Keyframe<Double>]          = [],
        anchor:   [Keyframe<NormalizedPoint>] = []
    ) {
        self.opacity  = opacity
        self.position = position
        self.scale    = scale
        self.rotation = rotation
        self.anchor   = anchor
    }

    // MARK: Codable (v6 backward compat: anchor is new)

    private enum CodingKeys: String, CodingKey {
        case opacity, position, scale, rotation, anchor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.opacity  = try c.decodeIfPresent([Keyframe<Double>].self,          forKey: .opacity)  ?? []
        self.position = try c.decodeIfPresent([Keyframe<NormalizedPoint>].self, forKey: .position) ?? []
        self.scale    = try c.decodeIfPresent([Keyframe<Double>].self,          forKey: .scale)    ?? []
        self.rotation = try c.decodeIfPresent([Keyframe<Double>].self,          forKey: .rotation) ?? []
        self.anchor   = try c.decodeIfPresent([Keyframe<NormalizedPoint>].self, forKey: .anchor)   ?? []
    }
}

public struct Keyframe<Value: Sendable & Hashable & Codable>: Sendable, Hashable {
    public var time: Double   // absolute seconds
    public var value: Value
    public var easing: Easing

    public init(time: Double, value: Value, easing: Easing = .easeInOut) {
        self.time   = time
        self.value  = value
        self.easing = easing
    }
}

extension Keyframe: Codable where Value: Codable {}

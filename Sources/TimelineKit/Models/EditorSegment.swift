import Foundation

/// A single clip placed on a track. The core editing unit.
///
/// Two time ranges:
/// - `sourceRange`: which portion of the source asset to use (nil = full asset). Enables non-destructive trimming.
/// - `targetRange`: where this clip lives on the timeline (always absolute seconds from origin).
public struct EditorSegment: Identifiable, Sendable, Hashable, Codable {

    // MARK: - Codable (custom for v4 backward compat)

    private enum CodingKeys: String, CodingKey {
        case id, materialID, sourceRange, targetRange, speed, transform
        case blendMode, keyframes, content
        case leadingTransitionID, trailingTransitionID
        case adjustment, sourceSceneID, sourceZIndex
        case userZOrder
        case animations  // V7: clip-level animation (in / out / combo)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                    = try c.decode(UUID.self,             forKey: .id)
        self.materialID            = try c.decode(UUID.self,             forKey: .materialID)
        self.sourceRange           = try c.decodeIfPresent(TimeRange.self, forKey: .sourceRange)
        self.targetRange           = try c.decode(TimeRange.self,         forKey: .targetRange)
        self.speed                 = try c.decode(Double.self,            forKey: .speed)
        self.transform             = try c.decode(SegmentTransform.self,  forKey: .transform)
        self.blendMode             = try c.decode(BlendMode.self,         forKey: .blendMode)
        self.keyframes             = try c.decode(KeyframeSet.self,       forKey: .keyframes)
        self.content               = try c.decode(SegmentContent.self,    forKey: .content)
        self.leadingTransitionID   = try c.decodeIfPresent(UUID.self,     forKey: .leadingTransitionID)
        self.trailingTransitionID  = try c.decodeIfPresent(UUID.self,     forKey: .trailingTransitionID)
        self.adjustment            = try c.decode(SegmentAdjustment.self, forKey: .adjustment)
        self.sourceSceneID         = try c.decodeIfPresent(String.self,   forKey: .sourceSceneID)
        self.sourceZIndex          = try c.decodeIfPresent(Int.self,      forKey: .sourceZIndex)
        self.userZOrder            = try c.decodeIfPresent(Int.self,      forKey: .userZOrder)
        self.animations            = try c.decodeIfPresent([ClipAnimation].self, forKey: .animations) ?? []
    }
    public let id: UUID
    public var materialID: UUID

    public var sourceRange: TimeRange?  // nil = use full asset
    public var targetRange: TimeRange   // absolute timeline position

    public var speed: Double            // 1.0 = normal, 0.5 = half speed
    public var transform: SegmentTransform
    public var blendMode: BlendMode
    public var keyframes: KeyframeSet
    public var content: SegmentContent

    public var leadingTransitionID: UUID?
    public var trailingTransitionID: UUID?

    /// Per-segment color and tone adjustments. Identity = no effect.
    public var adjustment: SegmentAdjustment

    // Round-trip metadata for VideoTimeline export
    public var sourceSceneID: String?
    public var sourceZIndex: Int?
    /// v4: explicit user-controlled layer order. Higher = front. nil = auto
    /// (legacy time-overlap stackDepth algorithm). Default nil for v1/v2/v3 compat.
    public var userZOrder: Int?

    /// V7: clip-level animations (in / out / combo). Empty = no animations.
    /// Saved as semantic + duration — never as baked keyframes.
    public var animations: [ClipAnimation]

    public init(
        id: UUID = UUID(),
        materialID: UUID,
        sourceRange: TimeRange? = nil,
        targetRange: TimeRange,
        speed: Double = 1.0,
        transform: SegmentTransform = .identity,
        blendMode: BlendMode = .normal,
        keyframes: KeyframeSet = .empty,
        content: SegmentContent,
        leadingTransitionID: UUID? = nil,
        trailingTransitionID: UUID? = nil,
        adjustment: SegmentAdjustment = .identity,
        sourceSceneID: String? = nil,
        sourceZIndex: Int? = nil,
        userZOrder: Int? = nil,
        animations: [ClipAnimation] = []
    ) {
        self.id                   = id
        self.materialID           = materialID
        self.sourceRange          = sourceRange
        self.targetRange          = targetRange
        self.speed                = speed
        self.transform            = transform
        self.blendMode            = blendMode
        self.keyframes            = keyframes
        self.content              = content
        self.leadingTransitionID  = leadingTransitionID
        self.trailingTransitionID = trailingTransitionID
        self.adjustment           = adjustment
        self.sourceSceneID        = sourceSceneID
        self.sourceZIndex         = sourceZIndex
        self.userZOrder           = userZOrder
        self.animations           = animations
    }
}

// MARK: - EditorSegment helpers

extension EditorSegment {
    public var isSubtitle: Bool {
        if case .subtitle = content { return true }
        return false
    }
    public var isText: Bool {
        if case .text = content { return true }
        return false
    }
    public var isAudio: Bool {
        if case .audio = content { return true }
        return false
    }
}

// MARK: - Animation accessors (V7)

extension EditorSegment {

    public var inAnimation: ClipAnimation?    { animations.first { $0.timing == .in } }
    public var outAnimation: ClipAnimation?   { animations.first { $0.timing == .out } }
    public var comboAnimation: ClipAnimation? { animations.first { $0.timing == .combo } }

    /// Set or replace a clip animation.
    /// Setting a combo animation clears any existing in/out animations (mutually exclusive).
    /// Setting in/out clears any existing combo and any prior animation of the same timing.
    public mutating func setAnimation(_ anim: ClipAnimation) {
        if anim.timing == .combo {
            animations = [anim]
        } else {
            animations.removeAll { $0.timing == anim.timing || $0.timing == .combo }
            animations.append(anim)
        }
    }

    /// Remove the animation for the given timing, if any.
    public mutating func removeAnimation(timing: AnimationTiming) {
        animations.removeAll { $0.timing == timing }
    }
}

public enum BlendMode: String, Sendable, Hashable, Codable, CaseIterable {
    case normal
    case multiply, screen, overlay
    case hardLight = "hard_light"
    case softLight = "soft_light"
    case difference, exclusion
}

import Foundation

/// A single track lane containing an ordered list of non-overlapping segments.
/// Tracks are layered by `zPosition` (higher = rendered on top).
public struct EditorTrack: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var kind: Kind
    public var label: String
    public var isMuted: Bool
    public var isLocked: Bool
    public var isHidden: Bool
    /// Compositing order: higher zPosition renders above lower tracks.
    public var zPosition: Int
    /// Segments sorted by targetRange.start. Caller is responsible for maintaining sort order.
    public var segments: [EditorSegment]
    /// Whether this track is the timeline backbone.
    /// Exactly one track per EditorTimeline should have this set to true.
    /// Main-track segments are packed end-to-end; their total duration defines the project length.
    public var isMainTrack: Bool
    /// v3: marks a track explicitly created by the user via the "+" button while still empty.
    /// EditorStore schedules a 30-second auto-recycle task on these; once a segment is added
    /// the flag is cleared and the timer cancelled.
    public var pendingUserCreated: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind,
        label: String = "",
        isMuted: Bool = false,
        isLocked: Bool = false,
        isHidden: Bool = false,
        zPosition: Int = 0,
        segments: [EditorSegment] = [],
        isMainTrack: Bool = false,
        pendingUserCreated: Bool = false
    ) {
        self.id                 = id
        self.kind               = kind
        self.label              = label
        self.isMuted            = isMuted
        self.isLocked           = isLocked
        self.isHidden           = isHidden
        self.zPosition          = zPosition
        self.segments           = segments
        self.isMainTrack        = isMainTrack
        self.pendingUserCreated = pendingUserCreated
    }

    // MARK: - Codable (custom for backward compatibility with v1/v2 drafts)

    private enum CodingKeys: String, CodingKey {
        case id, kind, label, isMuted, isLocked, isHidden
        case zPosition, segments, isMainTrack, pendingUserCreated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                 = try c.decode(UUID.self,             forKey: .id)
        self.kind               = try c.decode(Kind.self,             forKey: .kind)
        self.label              = try c.decode(String.self,           forKey: .label)
        self.isMuted            = try c.decode(Bool.self,             forKey: .isMuted)
        self.isLocked           = try c.decode(Bool.self,             forKey: .isLocked)
        self.isHidden           = try c.decode(Bool.self,             forKey: .isHidden)
        self.zPosition          = try c.decode(Int.self,              forKey: .zPosition)
        self.segments           = try c.decode([EditorSegment].self,  forKey: .segments)
        self.isMainTrack        = try c.decode(Bool.self,             forKey: .isMainTrack)
        // v3 field — missing in v1/v2 drafts; default to false.
        self.pendingUserCreated = try c.decodeIfPresent(Bool.self, forKey: .pendingUserCreated) ?? false
    }

    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case video       // primary video / image content
        case overlay     // background effects, picture-in-picture
        case text        // text overlays
        case subtitle    // caption rendering (separate from text overlays)
        case audio       // bgm, voiceover, sfx
        case adjustment  // color grade / filter (affects all layers below)
    }
}

// MARK: - Convenience

extension EditorTrack {
    public func segment(at time: Double) -> EditorSegment? {
        segments.first { $0.targetRange.contains(time) }
    }

    public func segment(id: UUID) -> EditorSegment? {
        segments.first { $0.id == id }
    }

    public var timelineDuration: Double {
        segments.map { $0.targetRange.end }.max() ?? 0
    }

    /// Inserts segment maintaining sort order by targetRange.start.
    public mutating func insert(_ segment: EditorSegment) {
        let idx = segments.firstIndex { $0.targetRange.start > segment.targetRange.start } ?? segments.endIndex
        segments.insert(segment, at: idx)
    }

    public mutating func removeSegment(id: UUID) {
        segments.removeAll { $0.id == id }
    }
}

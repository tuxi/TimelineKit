import Foundation

// MARK: - Custom Codable implementations for types that cannot use synthesis.
//
// Types whose synthesis IS declared in their own files (just Codable added to
// the struct/enum declaration):
//   SegmentAdjustment, PresetFilter, KeyframeSet, EditorSegment, EditorTrack,
//   EditorTransition, EditorMetadata, EditorTimeline, EditorAsset,
//   SegmentContent sub-structs, SegmentContent sub-types.
//
// Types that need manual Codable because they are enums with associated values
// or wrap private storage:
//   SegmentContent, MaterialsPool

// ── SegmentContent (enum with associated values) ────────────────────────────

extension SegmentContent: Codable {
    private enum CodingKeys: String, CodingKey { case type, payload }
    private enum Tag: String, Codable { case video, image, text, subtitle, audio }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .video(let v):
            try c.encode(Tag.video, forKey: .type)
            try c.encode(v, forKey: .payload)
        case .image(let v):
            try c.encode(Tag.image, forKey: .type)
            try c.encode(v, forKey: .payload)
        case .text(let v):
            try c.encode(Tag.text, forKey: .type)
            try c.encode(v, forKey: .payload)
        case .subtitle(let v):
            try c.encode(Tag.subtitle, forKey: .type)
            try c.encode(v, forKey: .payload)
        case .audio(let v):
            try c.encode(Tag.audio, forKey: .type)
            try c.encode(v, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let c   = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .video:    self = .video(try c.decode(SegmentContent.VideoContent.self,    forKey: .payload))
        case .image:    self = .image(try c.decode(SegmentContent.ImageContent.self,    forKey: .payload))
        case .text:     self = .text(try c.decode(SegmentContent.TextContent.self,      forKey: .payload))
        case .subtitle: self = .subtitle(try c.decode(SegmentContent.SubtitleContent.self, forKey: .payload))
        case .audio:    self = .audio(try c.decode(SegmentContent.AudioContent.self,    forKey: .payload))
        }
    }
}

// ── MaterialsPool (wraps private [UUID: EditorAsset]) ───────────────────────

extension MaterialsPool: Codable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        for asset in all { try c.encode(asset) }
    }

    public init(from decoder: Decoder) throws {
        self.init()
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd { add(try c.decode(EditorAsset.self)) }
    }
}

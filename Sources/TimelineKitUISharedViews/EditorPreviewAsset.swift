import Foundation

/// A browser-selected asset shown in the canvas without moving the timeline
/// playhead.
public struct EditorPreviewAsset: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case image
        case video
        case audio
    }

    public let id: UUID
    public let url: URL
    public let kind: Kind
    public let title: String
    public let duration: Double?

    public init(
        id: UUID,
        url: URL,
        kind: Kind,
        title: String,
        duration: Double? = nil
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.title = title
        self.duration = duration
    }
}

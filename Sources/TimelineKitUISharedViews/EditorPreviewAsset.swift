import Foundation
import CoreGraphics

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
    public let naturalSize: CGSize?
    public let frameRate: Double?
    public let fileSize: Int64?
    public let audioChannels: Int?

    public init(
        id: UUID,
        url: URL,
        kind: Kind,
        title: String,
        duration: Double? = nil,
        naturalSize: CGSize? = nil,
        frameRate: Double? = nil,
        fileSize: Int64? = nil,
        audioChannels: Int? = nil
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.title = title
        self.duration = duration
        self.naturalSize = naturalSize
        self.frameRate = frameRate
        self.fileSize = fileSize
        self.audioChannels = audioChannels
    }
}

import Foundation

/// A media asset in the materials pool. Segments reference assets by ID.
/// Separating assets from their timeline placement allows the same asset to appear
/// multiple times and enables replace-asset operations without touching track data.
public struct EditorAsset: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var type: AssetType
    public var localURL: URL?
    public var remoteURL: URL?
    /// Native playback duration for video/audio assets (seconds).
    public var nativeDuration: Double?
    public var naturalWidth: Int?
    public var naturalHeight: Int?

    public init(
        id: UUID = UUID(),
        type: AssetType,
        localURL: URL? = nil,
        remoteURL: URL? = nil,
        nativeDuration: Double? = nil,
        naturalWidth: Int? = nil,
        naturalHeight: Int? = nil
    ) {
        self.id              = id
        self.type            = type
        self.localURL        = localURL
        self.remoteURL       = remoteURL
        self.nativeDuration  = nativeDuration
        self.naturalWidth    = naturalWidth
        self.naturalHeight   = naturalHeight
    }

    public var bestURL: URL? { localURL ?? remoteURL }

    public enum AssetType: Sendable, Hashable {
        case image
        case video
        case generatedVideo(provider: String, model: String)
        case audio
        case voiceOver
        /// Asset pending AI generation; no URL yet.
        case placeholder
    }
}

// MARK: - Materials Pool

/// Thread-safe dictionary of EditorAsset, keyed by UUID.
public struct MaterialsPool: Sendable, Hashable {
    private var items: [UUID: EditorAsset] = [:]

    public init() {}

    public subscript(id: UUID) -> EditorAsset? {
        get { items[id] }
        set { items[id] = newValue }
    }

    public mutating func add(_ asset: EditorAsset) {
        items[asset.id] = asset
    }

    public mutating func remove(id: UUID) {
        items.removeValue(forKey: id)
    }

    public var all: [EditorAsset] { Array(items.values) }
    public var count: Int { items.count }
}

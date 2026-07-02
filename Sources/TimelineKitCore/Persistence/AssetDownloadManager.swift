import Foundation

// MARK: - AssetDownloadManager

/// Singleton download + persistent disk-cache layer for remote EditorAsset files.
///
/// ## Cache layout
///
/// ```
/// ApplicationSupport/TimelineKit/
///   Drafts/{timelineID}.json          ← DraftStore (existing)
///   Assets/{timelineID}/{assetID}.ext ← AssetDownloadManager (this file)
///   Assets/_shared/{urlhash}.ext      ← URL-only callers (WaveformProvider etc.)
/// ```
///
/// Assets and their draft JSON live under the same parent so they can be
/// purged together when a draft is deleted.
///
/// ## Concurrency
///
/// Concurrent downloads for the same destination are automatically coalesced —
/// only one `URLSession` task runs; all other callers `await` that single task.
public actor AssetDownloadManager {

    public static let shared = AssetDownloadManager()

    /// In-flight downloads keyed by their destination path.
    private var inFlight: [URL: Task<URL, any Error>] = [:]

    // MARK: - Public API

    /// Returns a local file URL for `remoteURL`, tied to a specific asset + timeline.
    ///
    /// - If the file is already cached the cached copy is returned immediately.
    /// - Concurrent calls with the same `assetID` + `timelineID` are coalesced.
    /// - After return the caller should update `EditorAsset.localURL` via
    ///   `EditorStore.updateAssetLocalURL(assetID:url:)` so the mapping is persisted.
    public func localURL(
        for remoteURL: URL,
        assetID: UUID,
        timelineID: UUID
    ) async throws -> URL {
        guard !remoteURL.isFileURL else { return remoteURL }
        let dest = assetPath(assetID: assetID, remoteURL: remoteURL, timelineID: timelineID)
        return try await download(from: remoteURL, to: dest)
    }

    /// URL-only variant for callers that lack asset/timeline context
    /// (e.g. `WaveformProvider`, `StaticImageRenderer`).
    ///
    /// Files are stored in `Assets/_shared/` and are not tied to any timeline.
    public func localURL(for remoteURL: URL) async throws -> URL {
        guard !remoteURL.isFileURL else { return remoteURL }
        let dest = sharedPath(for: remoteURL)
        return try await download(from: remoteURL, to: dest)
    }

    /// Returns the cached path if it already exists on disk (no download).
    public func cachedLocalURL(
        assetID: UUID,
        remoteURL: URL,
        timelineID: UUID
    ) -> URL? {
        let path = assetPath(assetID: assetID, remoteURL: remoteURL, timelineID: timelineID)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Reserve a destination URL inside the per-timeline asset cache for files
    /// generated client-side (audio extraction, TTS, etc.). Creates parent dirs.
    /// Used by V3 audio / TTS pipelines instead of `localURL(for:)` (which downloads).
    public nonisolated func reserveLocalURL(
        assetID: UUID,
        extension ext: String,
        timelineID: UUID
    ) throws -> URL {
        let dir = Self.rootDirectory.appendingPathComponent(timelineID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(assetID.uuidString).\(ext)")
    }

    /// Reserve a destination URL in the cross-timeline shared TTS cache, keyed by
    /// a stable content hash (sha1(text + voice + rate)). Hits across timelines so
    /// "同样的文案 + 同样的声线 + 同样的语速" only synthesizes once.
    /// Path: `Assets/_shared/tts/{key}.m4a`
    public nonisolated func reserveSharedTTSURL(
        key: String,
        extension ext: String = "m4a"
    ) throws -> URL {
        let dir = Self.rootDirectory
            .appendingPathComponent("_shared", isDirectory: true)
            .appendingPathComponent("tts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(key).\(ext)")
    }

    /// Delete all cached asset files for a timeline. Call when deleting a draft.
    /// `nonisolated` — only touches the filesystem, no actor-isolated state.
    public nonisolated func purge(timelineID: UUID) {
        let dir = Self.rootDirectory.appendingPathComponent(timelineID.uuidString)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Delete the shared URL cache. Use sparingly (evicts all cross-timeline caches).
    public nonisolated func purgeShared() {
        let dir = Self.rootDirectory.appendingPathComponent("_shared")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Paths

    public static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TimelineKit/Assets", isDirectory: true)
    }

    private func assetsDirectory(for timelineID: UUID) -> URL {
        Self.rootDirectory.appendingPathComponent(timelineID.uuidString, isDirectory: true)
    }

    private func assetPath(assetID: UUID, remoteURL: URL, timelineID: UUID) -> URL {
        let ext = remoteURL.pathExtension
        let name = ext.isEmpty ? assetID.uuidString : "\(assetID.uuidString).\(ext)"
        return assetsDirectory(for: timelineID).appendingPathComponent(name)
    }

    private func sharedPath(for remoteURL: URL) -> URL {
        // Use a stable hash of the full URL as the filename key.
        // This is a best-effort — collisions are astronomically unlikely for media CDN URLs.
        var hasher = Hasher()
        hasher.combine(remoteURL.absoluteString)
        let hash = abs(hasher.finalize())
        let ext = remoteURL.pathExtension
        let name = ext.isEmpty ? "\(hash)" : "\(hash).\(ext)"
        return Self.rootDirectory
            .appendingPathComponent("_shared")
            .appendingPathComponent(name)
    }

    // MARK: - Core download (coalesced)

    private func download(from remoteURL: URL, to dest: URL) async throws -> URL {
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        if let running = inFlight[dest] { return try await running.value }

        let task = Task<URL, any Error> {
            let dir = dest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let (tmp, _) = try await URLSession.shared.download(from: remoteURL)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        }
        inFlight[dest] = task
        defer { inFlight.removeValue(forKey: dest) }
        return try await task.value
    }
}

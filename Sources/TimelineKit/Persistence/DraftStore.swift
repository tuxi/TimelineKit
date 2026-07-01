import Foundation

// MARK: - DraftStore

/// Manages local draft persistence for EditorTimeline.
///
/// Usage:
///   - Call `bind(to:)` once after creating the EditorStore to start auto-save.
///   - Call `restore(into:)` on launch to reload the last saved draft.
///   - Drafts are keyed by `timeline.id`.
@MainActor
public final class DraftStore: @unchecked Sendable {

    // MARK: - Public

    /// Load a previously saved draft. Returns nil if no matching draft exists.
    public static func load(draftID: UUID) -> EditorTimeline? {
        let url = draftURL(for: draftID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let timeline = try? JSONDecoder().decode(EditorTimeline.self, from: data) else { return nil }
        return restorePortableAssetURLs(in: timeline)
    }

    /// Backward-compatible alias for callers that still name the ID as timelineID.
    public static func load(timelineID: UUID) -> EditorTimeline? {
        load(draftID: timelineID)
    }

    /// Restore the most-recently modified draft (across all draft IDs).
    public static func loadMostRecent() -> EditorTimeline? {
        let dir = draftsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        let sorted = files
            .filter { $0.pathExtension == "json" }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }

        guard let newest = sorted.first,
              let data = try? Data(contentsOf: newest) else { return nil }
        guard let timeline = try? JSONDecoder().decode(EditorTimeline.self, from: data) else { return nil }
        return restorePortableAssetURLs(in: timeline)
    }

    /// Immediately save a timeline to disk.
    @discardableResult
    public static func save(_ timeline: EditorTimeline) -> UUID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let persistedTimeline = relativizeAssetURLsForPersistence(in: timeline)
        guard let data = try? encoder.encode(persistedTimeline) else { return timeline.id }
        let url = draftURL(for: timeline.id)
        try? FileManager.default.createDirectory(at: draftsDirectory,
                                                  withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        return timeline.id
    }

    /// Delete the draft for a given timeline ID, and purge its cached asset files.
    public static func delete(draftID: UUID) {
        try? FileManager.default.removeItem(at: draftURL(for: draftID))
        AssetDownloadManager.shared.purge(timelineID: draftID)
    }

    /// Backward-compatible alias for callers that still name the ID as timelineID.
    public static func delete(timelineID: UUID) {
        delete(draftID: timelineID)
    }

    /// All saved drafts, sorted newest-first.
    public static func allDrafts() -> [EditorTimeline] {
        let dir = draftsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }
            .compactMap { url -> EditorTimeline? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard let timeline = try? JSONDecoder().decode(EditorTimeline.self, from: data) else { return nil }
                return restorePortableAssetURLs(in: timeline)
            }
    }

    // MARK: - Auto-save binding

    private var autosaveTask: Task<Void, Never>?
    private var lastSavedVersion: Int = -1

    /// Bind auto-save to an EditorStore. Polls `compositionVersion` every 5 seconds.
    /// Saves whenever the version changes (i.e. the timeline was mutated).
    public func bind(to store: EditorStore) {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self, weak store] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5s interval
                guard !Task.isCancelled, let self, let store else { break }
                await self.saveIfChanged(store: store)
            }
        }
    }

    public func unbind() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    @MainActor
    private func saveIfChanged(store: EditorStore) {
        let v = store.compositionVersion
        guard v != lastSavedVersion else { return }
        lastSavedVersion = v
        DraftStore.save(store.timeline)
    }

    // MARK: - Paths

    private static var draftsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TimelineKit/Drafts", isDirectory: true)
    }

    private static func draftURL(for id: UUID) -> URL {
        draftsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Portable Asset URLs

    private static let portableContainerScheme = "timelinekit-container"

    private static var appContainerDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    private static func relativizeAssetURLsForPersistence(in timeline: EditorTimeline) -> EditorTimeline {
        transformAssetURLs(in: timeline) { url in
            guard url.isFileURL,
                  let relativePath = containerRelativePath(for: url) else {
                return url
            }
            return portableContainerURL(relativePath: relativePath) ?? url
        }
    }

    private static func restorePortableAssetURLs(in timeline: EditorTimeline) -> EditorTimeline {
        transformAssetURLs(in: timeline) { url in
            if url.scheme == portableContainerScheme,
               let relativePath = portableRelativePath(from: url) {
                return appContainerDirectory.appendingPathComponent(relativePath)
            }
            guard url.isFileURL,
                  !FileManager.default.fileExists(atPath: url.path),
                  let relativePath = legacyContainerRelativePath(from: url) else {
                return url
            }
            return appContainerDirectory.appendingPathComponent(relativePath)
        }
    }

    private static func transformAssetURLs(
        in timeline: EditorTimeline,
        transform: (URL) -> URL
    ) -> EditorTimeline {
        var timeline = timeline
        for asset in timeline.materials.all {
            var updated = asset
            if let localURL = asset.localURL {
                updated.localURL = transform(localURL)
            }
            if let remoteURL = asset.remoteURL {
                updated.remoteURL = transform(remoteURL)
            }
            timeline.materials[asset.id] = updated
        }
        return timeline
    }

    private static func containerRelativePath(for url: URL) -> String? {
        let basePath = appContainerDirectory.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath + "/") else { return nil }
        return String(path.dropFirst(basePath.count + 1))
    }

    private static func portableContainerURL(relativePath: String) -> URL? {
        var components = URLComponents()
        components.scheme = portableContainerScheme
        components.path = "/" + relativePath
        return components.url
    }

    private static func portableRelativePath(from url: URL) -> String? {
        guard url.scheme == portableContainerScheme else { return nil }
        return String(url.path.drop { $0 == "/" })
    }

    private static func legacyContainerRelativePath(from url: URL) -> String? {
        let path = url.standardizedFileURL.path
        for marker in ["/Library/", "/tmp/"] {
            guard let range = path.range(of: marker) else { continue }
            return String(path[range.lowerBound...].dropFirst())
        }
        return nil
    }
}

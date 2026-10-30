import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import TimelineKitCore

/// 库内一个已导入媒体的清单条目（供 Browser 媒体面板按日期分组展示）。
///
/// 库导入把源文件复制为 `Media/<assetID>.<ext>`，源文件名与拍摄日期复制时丢失，
/// 故在导入时提取并持久化到 `Media/Manifest.json`，使分组与 FCP 一致
/// （按媒体自身拍摄日期），且库可整体迁移（manifest 跟随库包）。
public struct LibraryMediaEntry: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID            // == assetID，也是库内文件名（去扩展名）
    public let fileName: String    // 库内文件名（含扩展名）
    public let originalFileName: String
    public let captureDate: Date   // 拍摄/创建日期（分组依据）
    public let kind: MediaKind
    public let duration: Double?   // 视频/音频时长（秒），图片 nil

    public enum MediaKind: String, Codable, Sendable {
        case image, video, audio, other
    }

    public init(id: UUID, fileName: String, originalFileName: String,
                captureDate: Date, kind: MediaKind, duration: Double?) {
        self.id = id
        self.fileName = fileName
        self.originalFileName = originalFileName
        self.captureDate = captureDate
        self.kind = kind
        self.duration = duration
    }
}

/// 库内一个项目（= 一个 timeline）。持久化到 `Projects/<id>.tlkproj`。
///
/// 项目 = 名称 + 一个 EditorTimeline（项目即一条时间线）。含名称以便在
/// Browser 左栏项目列表展示；旧 `.tlkproj` 只有 EditorTimeline（无名称）时
/// 读取回退用文件名。
public struct LibraryProject: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var createdAt: Date
    public var timeline: EditorTimeline
    /// 置顶标记（项目列表排序：置顶优先）。旧 .tlkproj 无此字段 → 解码默认 false。
    public var isPinned: Bool

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), timeline: EditorTimeline, isPinned: Bool = false) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.timeline = timeline
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, timeline, isPinned
    }

    /// 旧 .tlkproj 缺少 isPinned（甚至整个 LibraryProject 包装）时的兼容解码。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self, forKey: .id)
        name      = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        timeline  = try c.decode(EditorTimeline.self, forKey: .timeline)
        isPinned  = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

// MARK: - Project cover thumbnail source

/// Identifies the frame a project cover thumbnail should show: the earliest
/// visual (image/video) main-track segment that has a resolvable asset URL.
///
/// Value-semantic and `Hashable`, so it can serve as a stable request identity
/// for async loading — it changes only when the cover source actually changes,
/// not on renames, pins, or unrelated timeline edits.
public struct ProjectThumbnailSource: Sendable, Hashable {
    public let url: URL
    /// true → still image asset; false → video asset.
    public let isImage: Bool
    /// Source timestamp (seconds) for video extraction: the start of the
    /// segment's `sourceRange` (0 when the segment uses the full asset).
    /// Always 0 for image assets.
    public let time: Double

    public init(url: URL, isImage: Bool, time: Double) {
        self.url = url
        self.isImage = isImage
        self.time = time
    }
}

extension LibraryProject {
    /// The cover frame for this project, or nil when no main track has a
    /// visual (image/video) segment with a usable asset URL.
    ///
    /// All tracks marked `isMainTrack` are considered, not just the first one:
    /// persisted drafts can contain several backbone-flagged tracks (e.g. an
    /// empty leading one), and `timeline.mainTrack` would then hide the real
    /// picture. Overlay/text/subtitle/audio segments never become the cover.
    /// Candidates are scanned by GLOBAL ascending `targetRange.start` across
    /// those tracks; the sort is stable, so equal starts resolve by track and
    /// segment array order — deterministic across calls and launches, keeping
    /// the request identity free of jitter.
    public var thumbnailSource: ProjectThumbnailSource? {
        var candidates: [EditorSegment] = []
        for track in timeline.tracks where track.isMainTrack {
            candidates.append(contentsOf: track.segments)
        }
        // Swift's `sorted` is stable: ties keep (track order, segment order).
        let segments = candidates.sorted { $0.targetRange.start < $1.targetRange.start }
        for segment in segments {
            switch segment.content {
            case .image, .video: break          // visual content — candidate cover
            default: continue
            }
            guard let asset = timeline.materials[segment.materialID] else { continue }
            let isImage: Bool
            switch asset.type {
            case .image: isImage = true
            case .video, .generatedVideo: isImage = false
            case .audio, .voiceOver, .placeholder: continue
            }
            guard let url = asset.bestURL else { continue }
            let time = isImage ? 0 : max(0, segment.sourceRange?.start ?? 0)
            return ProjectThumbnailSource(url: url, isImage: isImage, time: time)
        }
        return nil
    }
}

/// TimelineKit 资源库（Library）—— 自研 `.tlkbundle` 目录包。
///
/// FCP 资源库心智模型（对照 `.fcpbundle`）：库 = 媒体库 + 项目。
/// 结构（与用户手建的 timeline.fcpbundle 对齐，但用 JSON 而非私有二进制）：
///
/// ```
/// mylibrary.tlkbundle/
/// ├── CurrentVersion.json        # 库元数据（名称/创建时间/格式版本）
/// ├── Media/                     # 导入媒体的副本（按 assetID 命名，唯一副本）
/// │   ├── <assetID>.<ext>
/// │   └── Manifest.json          # 媒体清单（每条含原始文件名/拍摄日期/类型/时长）
/// ├── Projects/
/// │   └── <projectID>.tlkproj    # 项目（EditorTimeline JSON 持久化）
/// └── Events/
///     └── <eventID>.tlkevent     # 事件元数据（媒体分组，预留）
/// ```
///
/// 关键：媒体文件复制进 `Media/`，时间线素材的 URL 指向库内文件。这样
/// 原始文件不受影响、库可整体迁移、媒体不会因 temporaryDirectory 清理丢失。
public struct TimelineLibrary: Sendable {
    /// 库包目录 URL（.tlkbundle）。
    public let packageURL: URL
    /// 库显示名称。
    public var name: String
    /// 格式版本。
    public let formatVersion: String
    /// 创建时间。
    public let createdAt: Date

    /// 库名（默认取包文件名）。
    public static let defaultFormatVersion = "1.0"

    // MARK: - Key paths

    public var mediaDirectory: URL { packageURL.appendingPathComponent("Media", isDirectory: true) }
    public var projectsDirectory: URL { packageURL.appendingPathComponent("Projects", isDirectory: true) }
    public var eventsDirectory: URL { packageURL.appendingPathComponent("Events", isDirectory: true) }
    public var metadataURL: URL { packageURL.appendingPathComponent("CurrentVersion.json") }
    public var mediaManifestURL: URL { mediaDirectory.appendingPathComponent("Manifest.json") }

    /// 库内某个媒体条目的文件 URL（`Media/<assetID>.<ext>`）。
    public func mediaFileURL(for entry: LibraryMediaEntry) -> URL {
        mediaDirectory.appendingPathComponent(entry.fileName)
    }

    // MARK: - Create / open

    /// 在指定位置创建一个空资源库包（目录 + Media/Projects/Events + 元数据）。
    /// - Parameter at: 用户选择的包目录（例如 file:///Users/xx/Movies/mylibrary.tlkbundle）
    public static func create(at packageURL: URL, name: String? = nil) throws -> TimelineLibrary {
        let fm = FileManager.default
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let libraryName = name ?? packageURL.deletingPathExtension().lastPathComponent
        let lib = TimelineLibrary(
            packageURL: packageURL,
            name: libraryName,
            formatVersion: defaultFormatVersion,
            createdAt: Date()
        )

        try fm.createDirectory(at: lib.mediaDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: lib.projectsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: lib.eventsDirectory, withIntermediateDirectories: true)
        try lib.saveMetadata()
        return lib
    }

    /// 打开一个已存在的资源库包（校验包结构存在）。
    public static func open(at packageURL: URL) throws -> TimelineLibrary {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: packageURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw TimelineLibraryError.notABundle(packageURL)
        }

        // 校验是 .tlkbundle 目录包（而非任意文件夹）：包内须有 Media/ 或元数据。
        let hasMediaDir = fm.fileExists(
            atPath: packageURL.appendingPathComponent("Media", isDirectory: true).path,
            isDirectory: &isDir
        ) && isDir.boolValue
        let hasMetadata = fm.fileExists(atPath: packageURL.appendingPathComponent("CurrentVersion.json").path)
        guard hasMediaDir || hasMetadata else {
            throw TimelineLibraryError.notABundle(packageURL)
        }

        // 读元数据（若缺失则按包名初始化）。
        let name = packageURL.deletingPathExtension().lastPathComponent
        var lib = TimelineLibrary(
            packageURL: packageURL,
            name: name,
            formatVersion: defaultFormatVersion,
            createdAt: Date()
        )
        try lib.loadMetadataIfPresent()
        return lib
    }

    // MARK: - Media import

    /// 把外部媒体复制进库 `Media/` 并登记到 Manifest，返回库内 URL。
    ///
    /// - Parameter sourceURL: 外部（可能安全作用域）媒体 URL；函数内持作用域复制，
    ///   复制完成即释放。原始文件不改动。
    /// - Returns: 库内 `Media/<assetID>.<ext>` URL。
    @discardableResult
    public func importMedia(from sourceURL: URL, assetID: UUID = UUID()) async throws -> URL {
        let entry = try await importMediaEntry(from: sourceURL, assetID: assetID)
        return mediaFileURL(for: entry)
    }

    /// 同 `importMedia`，但返回完整条目（含拍摄日期/类型/时长），用于注册到 Manifest。
    @discardableResult
    public func importMediaEntry(from sourceURL: URL, assetID: UUID = UUID()) async throws -> LibraryMediaEntry {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw TimelineLibraryError.sourceMissing
        }
        let ext = sourceURL.pathExtension.isEmpty ? "media" : sourceURL.pathExtension
        let fileName = assetID.uuidString + "." + ext
        let dest = mediaDirectory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: sourceURL, to: dest)

        // 提取拍摄日期（供分组）与时长（供展示）。
        let kind = Self.mediaKind(for: sourceURL, extension: ext)
        let duration = await Self.duration(of: sourceURL, kind: kind)
        let captureDate = await Self.captureDate(of: sourceURL) ?? srcFileCreationDate(sourceURL) ?? Date()

        let entry = LibraryMediaEntry(
            id: assetID,
            fileName: fileName,
            originalFileName: sourceURL.lastPathComponent,
            captureDate: captureDate,
            kind: kind,
            duration: duration
        )
        try appendManifest(entry)
        return entry
    }

    private func appendManifest(_ entry: LibraryMediaEntry) throws {
        var entries = listMediaManifest()
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(entries).write(to: mediaManifestURL, options: .atomic)
    }

    /// 库内媒体清单（含拍摄日期/类型/时长），按拍摄日期升序。
    public func listMediaManifest() -> [LibraryMediaEntry] {
        guard let data = try? Data(contentsOf: mediaManifestURL),
              let entries = try? JSONDecoder().decode([LibraryMediaEntry].self, from: data) else {
            return []
        }
        return entries.sorted { $0.captureDate < $1.captureDate }
    }

    /// 枚举库内已导入的媒体文件。
    public func listMediaAssets() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: mediaDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent != "Manifest.json" }) ?? []
    }

    // MARK: - Media metadata helpers

    private func srcFileCreationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// 推断媒体类型（按扩展名 / UTType）。
    private static func mediaKind(for url: URL, extension ext: String) -> LibraryMediaEntry.MediaKind {
        let ext = ext.lowercased()
        if ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp"].contains(ext) { return .image }
        if ["mp4", "mov", "m4v", "avi", "mpeg", "mpg", "mkv"].contains(ext) { return .video }
        if ["mp3", "m4a", "wav", "aac", "caf", "flac", "aiff"].contains(ext) { return .audio }
        return .other
    }

    /// 提取媒体拍摄/创建日期：图片读 EXIF DateTimeOriginal，视频读 AVAsset creationDate，
    /// 音频/其它回退文件系统 creationDate。
    private static func captureDate(of url: URL) async -> Date? {
        // 图片：EXIF DateTimeOriginal
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dt = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = fmt.date(from: dt) { return d }
        }
        // 视频：AVAsset creationDate
        let asset = AVURLAsset(url: url)
        if let meta = try? await asset.load(.metadata),
           let item = meta.first(where: { $0.commonKey == .commonKeyCreationDate }),
           let str = try? await item.load(.stringValue),
           let d = DateFormatter().date(from: str) {
            return d
        }
        // 兜底：文件系统 creationDate
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// 媒体时长（视频/音频），图片返回 nil。
    private static func duration(of url: URL, kind: LibraryMediaEntry.MediaKind) async -> Double? {
        guard kind == .video || kind == .audio else { return nil }
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration), dur.isNumeric, dur.seconds > 0 else { return nil }
        return dur.seconds
    }

    // MARK: - Project persistence

    /// 把 timeline 保存为库内项目（`Projects/<projectID>.tlkproj`）。
    /// 项目封装为 `LibraryProject`（含名称 + timeline）。
    ///
    /// 持久化前把库内资产的 `localURL` 相对化为 `tlkbundle://` scheme——
    /// 沙盒 App 重启后容器 UUID 会变，绝对路径失效；相对路径让库包整体
    /// 迁移（改名/移动/跨设备拷贝）也能工作。
    @discardableResult
    public func saveProject(_ project: LibraryProject) throws -> UUID {
        var persisted = project
        persisted.timeline = Self.relativizeAssetURLsForPersistence(in: project.timeline, packageURL: packageURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(persisted)
        let url = projectsDirectory
            .appendingPathComponent(project.id.uuidString)
            .appendingPathExtension("tlkproj")
        try data.write(to: url, options: .atomic)
        return project.id
    }

    /// 把 timeline 保存为库内项目（无名称包装；保留旧签名兼容）。
    @discardableResult
    public func saveProject(_ timeline: EditorTimeline, projectID: UUID = UUID()) throws -> UUID {
        try saveProject(LibraryProject(id: projectID, name: "未命名项目", timeline: timeline))
    }

    /// 加载库内某项目（兼容旧 `.tlkproj`：纯 EditorTimeline 时回退名称）。
    ///
    /// 加载后把 `tlkbundle://` 相对 URL 还原为当前包的绝对路径；并对旧格式
    /// （存了沙盒绝对路径）自愈——文件不存在但包内 Media/ 有同名文件时重定向。
    public func loadProject(projectID: UUID) throws -> LibraryProject {
        let url = projectsDirectory
            .appendingPathComponent(projectID.uuidString)
            .appendingPathExtension("tlkproj")
        let data = try Data(contentsOf: url)
        // 先尝试新的 LibraryProject 格式，失败则回退纯 EditorTimeline。
        var project: LibraryProject
        if let decoded = try? JSONDecoder().decode(LibraryProject.self, from: data) {
            project = decoded
        } else if let timeline = try? JSONDecoder().decode(EditorTimeline.self, from: data) {
            let name = projectID.uuidString  // 旧文件无名称，用项目 ID 作名称
            project = LibraryProject(id: projectID, name: name, timeline: timeline)
        } else {
            throw TimelineLibraryError.corruptProject(projectID)
        }
        project.timeline = Self.resolveAssetURLsForLoading(in: project.timeline, packageURL: packageURL)
        return project
    }

    // MARK: - Portable asset URLs (library-package relative)

    static let portableBundleScheme = "tlkbundle"

    /// 把库内资产 URL 相对化为 `tlkbundle://<relative-path>`（相对包根）。
    /// 包外 URL（防御）原样保留。
    static func relativizeAssetURLsForPersistence(in timeline: EditorTimeline, packageURL: URL) -> EditorTimeline {
        transformAssetURLs(in: timeline) { url in
            guard url.isFileURL,
                  let relativePath = bundleRelativePath(for: url, packageURL: packageURL) else {
                return url
            }
            return portableBundleURL(relativePath: relativePath) ?? url
        }
    }

    /// 把 `tlkbundle://` 相对 URL 还原为当前包的绝对路径。
    /// 自愈：旧格式存了沙盒绝对路径且文件已不存在，但包内 Media/ 有同名文件
    /// 时，重定向到当前包（修复阶段 1 的 .tlkproj）。
    static func resolveAssetURLsForLoading(in timeline: EditorTimeline, packageURL: URL) -> EditorTimeline {
        transformAssetURLs(in: timeline) { url in
            if url.scheme == portableBundleScheme,
               let relativePath = bundleRelativePath(fromPortable: url) {
                return packageURL.appendingPathComponent(relativePath)
            }
            guard url.isFileURL,
                  !FileManager.default.fileExists(atPath: url.path),
                  let relativePath = bundleRelativePath(fromLegacyAbsolute: url) else {
                return url
            }
            let candidate = packageURL.appendingPathComponent(relativePath)
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : url
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
            timeline.materials[asset.id] = updated
        }
        return timeline
    }

    /// 绝对路径 → 包内相对路径（如 `Media/<uuid>.jpeg`）；不在包内返回 nil。
    private static func bundleRelativePath(for url: URL, packageURL: URL) -> String? {
        let basePath = packageURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath + "/") else { return nil }
        return String(path.dropFirst(basePath.count + 1))
    }

    private static func portableBundleURL(relativePath: String) -> URL? {
        // 三斜杠（空 authority）：`//` 后的段会被解析为 host 而非 path，
        // 导致还原时丢失首段目录（Media/）。path 必须以 / 开头。
        URL(string: portableBundleScheme + ":///" + relativePath)
    }

    private static func bundleRelativePath(fromPortable url: URL) -> String? {
        guard url.scheme == portableBundleScheme else { return nil }
        return String(url.path.drop { $0 == "/" })
    }

    /// 旧格式自愈：从沙盒绝对路径中提取 `/Media/` 之后的部分。
    private static func bundleRelativePath(fromLegacyAbsolute url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard let range = path.range(of: "/Media/") else { return nil }
        return String(path[range.lowerBound...].dropFirst())
    }

    /// 枚举库内所有项目。
    public func listProjects() -> [LibraryProject] {
        (try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            return try? loadProject(projectID: id)
        }) ?? []
    }

    /// 枚举库内项目 ID。
    public func listProjectIDs() -> [UUID] {
        listProjects().map(\.id)
    }

    // MARK: - Project management (rename / duplicate / delete / pin)

    /// 项目文件 URL。
    private func projectURL(id: UUID) -> URL {
        projectsDirectory
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("tlkproj")
    }

    /// 重命名项目。
    public func renameProject(id: UUID, newName: String) throws {
        var project = try loadProject(projectID: id)
        project.name = newName
        try saveProject(project)
    }

    /// 复制项目（新 id，名称"xxx 副本"，createdAt=now）。timeline 深拷贝。
    @discardableResult
    public func duplicateProject(id: UUID) throws -> LibraryProject {
        let source = try loadProject(projectID: id)
        var copy = source
        copy = LibraryProject(
            id: UUID(),
            name: source.name + " 副本",
            createdAt: Date(),
            timeline: source.timeline,
            isPinned: false
        )
        try saveProject(copy)
        return copy
    }

    /// 删除项目（直接删除 .tlkproj 文件，不可恢复；调用方负责确认）。
    public func deleteProject(id: UUID) throws {
        try FileManager.default.removeItem(at: projectURL(id: id))
    }

    /// 设置/取消置顶。
    public func setPinned(id: UUID, isPinned: Bool) throws {
        var project = try loadProject(projectID: id)
        project.isPinned = isPinned
        try saveProject(project)
    }

    /// 项目列表排序：置顶优先，再按 createdAt 倒序。
    public static func sortedProjects(_ projects: [LibraryProject]) -> [LibraryProject] {
        projects.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.createdAt > $1.createdAt
        }
    }

    // MARK: - Metadata

    private func saveMetadata() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let doc = Metadata(name: name, formatVersion: formatVersion, createdAt: createdAt)
        try encoder.encode(doc).write(to: metadataURL, options: .atomic)
    }

    private mutating func loadMetadataIfPresent() throws {
        guard let data = try? Data(contentsOf: metadataURL) else { return }
        if let doc = try? JSONDecoder().decode(Metadata.self, from: data) {
            self.name = doc.name
        }
    }

    private struct Metadata: Codable {
        let name: String
        let formatVersion: String
        let createdAt: Date
    }
}

// MARK: - Errors

public enum TimelineLibraryError: Error, LocalizedError {
    case notABundle(URL)
    case sourceMissing
    case corruptProject(UUID)

    public var errorDescription: String? {
        switch self {
        case .notABundle(let url): return "\(url.lastPathComponent) 不是有效的资源库"
        case .sourceMissing: return "源素材不存在"
        case .corruptProject(let id): return "项目 \(id) 无法解析"
        }
    }
}

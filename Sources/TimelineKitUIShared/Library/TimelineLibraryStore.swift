import Foundation
import Observation
import TimelineKitCore

/// 当前打开的 `.tlkbundle` 资源库状态容器。
///
/// 职责：持有当前库、库内媒体清单，提供创建/打开库、导入媒体进库、
/// 项目保存。是对 `TimelineLibrary` 的 @Observable 包装，供 UI（Browser 面板）
/// 订阅变化。
@MainActor @Observable
public final class TimelineLibraryStore {

    /// 当前打开的库；nil = 未打开（空态显示"创建资源库"）。
    public private(set) var library: TimelineLibrary?
    /// 当前库内媒体清单（含拍摄日期/类型/时长），从 manifest 读取。
    public private(set) var mediaEntries: [LibraryMediaEntry] = []
    /// 当前库内媒体文件清单（刷新后更新，兼容旧消费者）。
    public private(set) var mediaURLs: [URL] = []
    /// 最近一次操作的错误信息（用于弹窗）。
    public var errorMessage: String?

    /// macOS 沙盒：为当前库包持有 security scope（NSSavePanel/NSOpenPanel 返回的
    /// URL 必须 startAccessingSecurityScopedResource 才能读写）；换库时停止旧的。
    @ObservationIgnored private var scopedForPackage: URL?
    @ObservationIgnored private var isAccessingScope = false

    public init() {}

    /// 是否已打开库。
    public var hasLibrary: Bool { library != nil }

    // MARK: - Create / open

    /// 在指定位置创建库并设为当前库。
    public func createLibrary(at packageURL: URL, name: String? = nil) throws {
        let lib = try TimelineLibrary.create(at: packageURL, name: name)
        activateScope(for: packageURL)
        self.library = lib
        refreshMedia()
        refreshProjects()
    }

    /// 打开现有库。
    public func openLibrary(at packageURL: URL) throws {
        let lib = try TimelineLibrary.open(at: packageURL)
        activateScope(for: packageURL)
        self.library = lib
        refreshMedia()
        refreshProjects()
    }

    private func activateScope(for packageURL: URL) {
        if isAccessingScope, let old = scopedForPackage {
            old.stopAccessingSecurityScopedResource()
        }
        scopedForPackage = packageURL
        isAccessingScope = packageURL.startAccessingSecurityScopedResource()
    }

    deinit {
        if isAccessingScope, let scoped = scopedForPackage {
            scoped.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Media

    /// 把外部媒体导入当前库（复制进 `Media/`）+ 更新 manifest，刷新媒体清单。
    /// - Returns: 库内媒体 URL；无库或复制失败返回空并设 errorMessage。
    @discardableResult
    public func addMedia(urls: [URL]) async -> [URL] {
        guard let library else {
            errorMessage = "请先创建或打开资源库"
            return []
        }
        var imported: [URL] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let entry = try await library.importMediaEntry(from: url)
                imported.append(library.mediaFileURL(for: entry))
            } catch {
                errorMessage = "导入失败：\(url.lastPathComponent) — \(error.localizedDescription)"
            }
        }
        if !imported.isEmpty { refreshMedia() }
        return imported
    }

    /// 重新枚举库内媒体（从 manifest）。
    public func refreshMedia() {
        mediaEntries = library?.listMediaManifest() ?? []
        // 兼容旧的 mediaURLs 消费者。
        mediaURLs = mediaEntries.map { library!.mediaFileURL(for: $0) }
    }

    /// 按拍摄日期分组（倒序，最新在前）。每个分组含日期与条目。
    public var groupedMedia: [(date: Date, items: [LibraryMediaEntry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: mediaEntries) { entry in
            cal.startOfDay(for: entry.captureDate)
        }
        return groups.sorted { $0.key > $1.key }.map { (date: $0.key, items: $0.value.sorted { $0.captureDate < $1.captureDate }) }
    }

    // MARK: - Project

    /// 项目列表缓存（可观察；操作后 refreshProjects 刷新）。
    /// 类本身 @Observable，属性自动被追踪。`projects` computed 返回 cache，
    /// 保持既有调用点不变。
    public private(set) var projectsCache: [LibraryProject] = []

    /// 当前库内所有项目（缓存）。
    public var projects: [LibraryProject] { projectsCache }

    /// 重新读取库内项目列表（置顶优先，createdAt 倒序）。
    public func refreshProjects() {
        projectsCache = TimelineLibrary.sortedProjects(library?.listProjects() ?? [])
    }

    /// 把项目保存为库内项目。
    @discardableResult
    public func saveProject(_ project: LibraryProject) throws -> UUID {
        guard let library else { throw TimelineLibraryError.notABundle(URL(fileURLWithPath: "")) }
        let id = try library.saveProject(project)
        refreshProjects()
        return id
    }

    /// 把 timeline 保存为库内项目（无名称包装；保留旧签名兼容）。
    @discardableResult
    public func saveProject(_ timeline: EditorTimeline) throws -> UUID {
        guard let library else { throw TimelineLibraryError.notABundle(URL(fileURLWithPath: "")) }
        let id = try library.saveProject(timeline)
        refreshProjects()
        return id
    }

    /// 加载库内项目。
    public func loadProject(projectID: UUID) throws -> LibraryProject {
        guard let library else { throw TimelineLibraryError.notABundle(URL(fileURLWithPath: "")) }
        return try library.loadProject(projectID: projectID)
    }

    /// 创建一个新项目（空 timeline + 主轨骨架），落库并返回。
    public func createProject(name: String, canvas: EditorCanvas? = nil) throws -> LibraryProject {
        guard let library else { throw TimelineLibraryError.notABundle(URL(fileURLWithPath: "")) }
        var timeline = EditorTimeline(
            canvas: canvas ?? EditorCanvas(width: 1920, height: 1080, fps: 30),
            metadata: EditorMetadata(canvasSizingMode: canvas == nil ? .automatic : .fixed)
        )
        if !timeline.tracks.contains(where: { $0.isMainTrack }) {
            timeline.tracks.append(EditorTrack(id: UUID(), kind: .video, label: "视频", zPosition: 0, segments: [], isMainTrack: true))
        }
        let project = LibraryProject(name: name, timeline: timeline)
        try library.saveProject(project)
        refreshProjects()
        return project
    }

    /// Media-first creation. Canceling the picker never calls this API; no
    /// project is saved if every selected file fails to import/read.
    public func createProject(name: String, mediaURLs: [URL], canvas: EditorCanvas? = nil) async throws -> LibraryProject {
        guard let library else { throw TimelineLibraryError.notABundle(URL(fileURLWithPath: "")) }
        let imported = await addMedia(urls: mediaURLs)
        let timeline = try await TimelineImporter.importingMedia(
            from: imported, canvas: canvas, productName: name
        )
        guard self.library?.packageURL == library.packageURL else { throw CocoaError(.userCancelled) }
        let project = LibraryProject(name: name, timeline: timeline)
        try library.saveProject(project)
        refreshProjects()
        return project
    }

    // MARK: - Project management (rename / duplicate / delete / pin)

    /// 重命名项目。
    public func renameProject(id: UUID, newName: String) throws {
        guard let library else { throw TimelineLibraryError.notABundle(URL(fileURLWithPath: "")) }
        try library.renameProject(id: id, newName: newName)
        refreshProjects()
    }

    /// 复制项目。
    @discardableResult
    public func duplicateProject(id: UUID) throws -> LibraryProject {
        guard let library else { throw TimelineLibraryError.notABundle(URL(fileURLWithPath: "")) }
        let copy = try library.duplicateProject(id: id)
        refreshProjects()
        return copy
    }

    /// 删除项目（直接删除，不可恢复；调用方负责确认）。
    public func deleteProject(id: UUID) throws {
        guard let library else { throw TimelineLibraryError.notABundle(URL(fileURLWithPath: "")) }
        try library.deleteProject(id: id)
        refreshProjects()
    }

    /// 设置/取消置顶。
    public func setPinned(id: UUID, isPinned: Bool) throws {
        guard let library else { throw TimelineLibraryError.notABundle(URL(fileURLWithPath: "")) }
        try library.setPinned(id: id, isPinned: isPinned)
        refreshProjects()
    }

    /// 当前库内所有项目 ID。
    public func projectIDs() -> [UUID] {
        projects.map(\.id)
    }
}

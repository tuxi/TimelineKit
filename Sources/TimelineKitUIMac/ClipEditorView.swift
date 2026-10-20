#if canImport(AppKit)
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
import TimelineKitUISharedViews

/// Public entry point for the macOS clip editor (FCP-style four-zone layout).
///
/// Layout:
///   - Top: system unified toolbar — title + import/export (host sets the style;
///     buttons live in `.toolbar` below)
///   - Vertical split: top area (Browser | Viewer | Inspector) over Timeline
///   - Viewer reuses the shared SwiftUI preview + playback controls
///   - Timeline uses the AppKit track canvas (scroll/select/scrub/zoom)
///
/// Media import: the系统 fileImporter lives here (SwiftUI) — the toolbar's
/// "导入素材" button opens it; selected files are added to the timeline via
/// EditorStore (video/image/audio auto-routed to the right track).
public struct ClipEditorView: View {
    @State private var store: EditorStore
    @State private var coordinator = CompositionCoordinator()
    @State private var draftStore  = DraftStore()
    @State private var libraryStore = TimelineLibraryStore()
    private let onDraftSave: ((UUID, EditorTimeline) -> Void)?
    @State private var showAddMediaPicker = false
    @State private var showCreateOrOpenLibrary = false
    @State private var showCreateProject = false
    @State private var newProjectName = ""
    @State private var errorMessage: String?
    @State private var isImporting = false
    @State private var activeProjectID: UUID?
    
    /// 自包含工作台：不接收外部 EditorStore，内部创建空 timeline 作为初始状态。
    /// 用户打开的库、创建/切换的项目均在本视图内部管理。
    public init(
        onDraftSave: ((UUID, EditorTimeline) -> Void)? = nil
    ) {
        self.onDraftSave = onDraftSave
        // 初始 timeline：含主轨骨架的空项目。
        let canvas = EditorCanvas(width: 1920, height: 1080, fps: 30)
        var timeline = EditorTimeline(canvas: canvas)
        if !timeline.tracks.contains(where: { $0.isMainTrack }) {
            timeline.tracks.append(EditorTrack(id: UUID(), kind: .video, label: "视频", zPosition: 0, segments: [], isMainTrack: true))
        }
        _store = State(initialValue: EditorStore(timeline: timeline))
    }
    
    /// Compatibility for embedders that already own an `EditorStore` and a
    /// preloaded timeline. The timeline is mirrored into a stable single-project
    /// `.tlkbundle` so the library-driven shell can open it.
    @available(*, deprecated, message: "Use the library-driven initializer.")
    public init(
        store: EditorStore,
        onDraftSave: ((UUID, EditorTimeline) -> Void)? = nil,
        onExport: ((Data, URL, NSImage) -> Void)? = nil
    ) {
        self.onDraftSave = onDraftSave
        _store = State(initialValue: store)
        if let embedded = try? TimelineEmbeddedLibrary.openOrCreate(for: store.timeline) {
            _libraryStore = State(initialValue: embedded.store)
            _activeProjectID = State(initialValue: embedded.project.id)
        }
    }

    public var body: some View {
        MacEditorShellRepresentable(
            store: store,
            libraryStore: libraryStore,
            timeline: store.document.timeline,
            selection: store.document.selection,
            compositionPlayer: coordinator.player,
            timelinePreviewView: coordinator.timelinePreviewView,
            onImportMedia: { showAddMediaPicker = true },
            onCreateOrOpenLibrary: { showCreateOrOpenLibrary = true },
            onCreateProject: { showCreateProject = true },
            onSelectProject: { id in switchToProject(byID: id) },
            activeProjectID: activeProjectID
        )
        // NSView default intrinsicContentSize is noIntrinsicMetric; SwiftUI would
        // otherwise size the AppKit shell to 0 height. Force it to fill.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
        // Set the window title to "TimelineKit" so the unified titlebar shows a
        // single title (not the Xcode target's window name). .toolbar(.principal)
        // merely overlays a view and would duplicate the system title.
        .navigationTitle("TimelineKit")
        .toolbar {
//            // Import — opens the fileImporter (host may also trigger via callback).
//            ToolbarItem(placement: .primaryAction) {
//                Button {
//                    showAddMediaPicker = true
//                } label: {
//                    Label("导入素材", systemImage: "square.and.arrow.down")
//                }
//                .disabled(isImporting)
//            }
            // Export — placeholder until the export pipeline lands.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Placeholder.
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .disabled(true)
            }
        }
        .onAppear {
            coordinator.attach(to: store)
            store.coordinatorPlayer = coordinator.player
            store.coordinator       = coordinator
            coordinator.scheduleRebuild(timeline: store.timeline, immediate: true)
            draftStore.bind(to: store)
        }
        .onChange(of: store.compositionVersion) { _, _ in
            coordinator.scheduleRebuild(timeline: store.timeline)
        }
        .onDisappear {
            saveDraftAndNotify()
        }
        .fileImporter(
            isPresented: $showAddMediaPicker,
            allowedContentTypes: [.movie, .image, .audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await addMedia(urls: urls) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("导入失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("资源库", isPresented: $showCreateOrOpenLibrary, titleVisibility: .visible) {
            Button("创建资源库…") {
                presentCreateLibraryPanel()
            }
            Button("打开已有资源库…") {
                presentOpenLibraryPanel()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("资源库存放媒体与项目，可选择任意可访问位置保存。")
        }
        // 创建项目（项目 = 一个 timeline）。
        .alert("创建项目", isPresented: $showCreateProject) {
            TextField("项目名称", text: $newProjectName, prompt: Text("未命名项目"))
            Button("创建") {
                createProject()
            }
            Button("取消", role: .cancel) {
                newProjectName = ""
            }
        } message: {
            Text("项目是一条时间线，你可以在其中排列和编辑媒体。")
        }
    }
    
    // MARK: - Project
    
    private func createProject() {
        let name = newProjectName.isEmpty ? "未命名项目" : newProjectName
        newProjectName = ""
        do {
            let project = try libraryStore.createProject(name: name)
            switchTo(project: project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    /// 切换到某项目：用其 timeline 新建 EditorStore 并重新接线 coordinator。
    private func switchTo(project: LibraryProject) {
        let newStore = EditorStore(timeline: project.timeline)
        store = newStore
        activeProjectID = project.id
        coordinator.attach(to: store)
        store.coordinatorPlayer = coordinator.player
        store.coordinator = coordinator
        coordinator.scheduleRebuild(timeline: store.timeline, immediate: true)
        draftStore.bind(to: store)
    }
    
    /// 按项目 ID 切换活动项目（从库加载项目）。
    private func switchToProject(byID id: UUID) {
        do {
            let project = try libraryStore.loadProject(projectID: id)
            switchTo(project: project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    // MARK: - Library panels (AppKit)
    
    /// NSSavePanel: pick a location + name for a new .tlkbundle, then create it.
    private func presentCreateLibraryPanel() {
        let panel = NSSavePanel()
        panel.title = "创建资源库"
        // FCP 一致：默认名带 .tlkbundle 后缀，默认目录为影片。
        panel.nameFieldStringValue = "未命名.tlkbundle"
        if let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
            panel.directoryURL = movies
        }
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.folder]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // 直接用 panel.url（已含 .tlkbundle 后缀且被 savePanel 授权）。
            // 不要在此改后缀——改后缀会让写入落在未授权的路径上。
            do {
                try self.libraryStore.createLibrary(at: url)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
    
    /// NSOpenPanel: pick an existing .tlkbundle and open it.
    /// `.tlkbundle` is a directory package not registered with the system, so
    /// NSOpenPanel sees it as a folder — allow directory selection here.
    private func presentOpenLibraryPanel() {
        let panel = NSOpenPanel()
        panel.title = "打开资源库"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder]
        // 只允许 .tlkbundle 项可选（目录包未注册为系统类型，用 delegate 过滤）。
        panel.delegate = libraryPanelDelegate
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.openLibrary(at: url)
        }
    }
    
    private func openLibrary(at url: URL) {
        do {
            try libraryStore.openLibrary(at: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    // MARK: - Library open-panel filtering
    
    /// Retained so the panel's delegate stays alive during the sheet session.
    private let libraryPanelDelegate = MacLibraryOpenPanelDelegate()
    
    // MARK: - Add Media
    
    /// Import URLs into the current library only — media does NOT enter any
    /// project/timeline here. Media reaches a timeline later when the user
    /// drags a media item from the Browser into the timeline (or taps it while
    /// a project is active).
    private func addMedia(urls: [URL]) async {
        await MainActor.run { isImporting = true }
        defer {
            Task { @MainActor in isImporting = false }
        }
        
        // Import into the library (copies files to Media/<assetID>.<ext>).
        _ = await libraryStore.addMedia(urls: urls)
        if let msg = libraryStore.errorMessage { errorMessage = msg }
    }
    
    /// Add a single library media entry into the current project's timeline,
    /// auto-routing by kind. No-op if no active project.
    private func addToCurrentProject(entry: LibraryMediaEntry) {
        guard let library = libraryStore.library else { return }
        let url = library.mediaFileURL(for: entry)
        switch entry.kind {
        case .video, .image:
            let native = entry.kind == .video ? entry.duration : nil
            _ = store.addVisualSegment(localURL: url, nativeDuration: native)
        case .audio:
            _ = store.addAudioSegment(localURL: url, nativeDuration: entry.duration ?? 0)
        case .other:
            break
        }
    }
    
    private func avDuration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration),
              dur.isNumeric, dur.seconds > 0 else { return nil }
        return dur.seconds
    }
    
    // MARK: - Draft persistence
    
    private func saveDraftAndNotify() {
        let draftID = store.document.id
        let timeline = store.timeline
        _ = DraftStore.save(timeline)
        persistActiveProject()
        onDraftSave?(draftID, timeline)
    }

    /// Compatibility bridge only: keep the embedded single-project bundle in sync
    /// with the host-owned EditorStore. The final library-driven shell removes this
    /// double write and makes .tlkproj the sole timeline source.
    private func persistActiveProject() {
        guard let id = activeProjectID, libraryStore.library != nil else { return }
        var project = LibraryProject(id: id, name: "Embedded Project", timeline: store.timeline)
        if let existing = libraryStore.projects.first(where: { $0.id == id }) {
            project.name = existing.name
        }
        _ = try? libraryStore.saveProject(project)
    }
}

// MARK: - SwiftUI bridge

/// Embeds the AppKit editor shell (NSSplitView four-zone layout) into SwiftUI.
///
/// `timeline`/`selection` are Equatable inputs: SwiftUI re-invokes `updateNSView`
/// whenever they change, letting the AppKit canvas refresh. The shell itself is
/// built once in `makeNSView` from the real `store` (so interactions stay wired),
/// and its timeline/selection are kept in sync here.
struct MacEditorShellRepresentable: NSViewRepresentable {
    let store: EditorStore
    let libraryStore: TimelineLibraryStore
    let timeline: EditorTimeline
    let selection: SelectionState
    let compositionPlayer: AVPlayer?
    let timelinePreviewView: TimelinePreviewView?
    var onImportMedia: (() -> Void)?
    var onCreateOrOpenLibrary: (() -> Void)?
    var onCreateProject: (() -> Void)?
    var onSelectProject: ((UUID) -> Void)?
    var activeProjectID: UUID?
    
    func makeNSView(context: Context) -> MacEditorShellView {
        MacEditorShellView(
            store: store,
            libraryStore: libraryStore,
            compositionPlayer: compositionPlayer,
            timelinePreviewView: timelinePreviewView,
            onImportMedia: onImportMedia,
            onCreateOrOpenLibrary: onCreateOrOpenLibrary,
            onCreateProject: onCreateProject,
            onSelectProject: onSelectProject,
            activeProjectID: activeProjectID
        )
    }
    
    func updateNSView(_ nsView: MacEditorShellView, context: Context) {
        // Sync the backing store (active project may have switched to a NEW
        // EditorStore) so drag/drop and click handlers mutate the CURRENT
        // project's timeline, not the one from makeNSView.
        nsView.updateStore(store)
        nsView.apply(timeline: timeline, selection: selection)
        nsView.updateActiveProject(id: activeProjectID)
    }
}

#endif

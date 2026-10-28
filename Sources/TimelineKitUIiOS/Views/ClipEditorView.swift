#if canImport(UIKit)
import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
import TimelineKitUISharedViews

/// Public entry point for the clip editor.
/// Three-layer architecture (locked):
///   Layer 1 — Preview  : EditorPreviewView (top, proportional height)
///   Layer 2 — Tracks   : EditorControlBar + TrackEditorRepresentable (middle, flexible)
///   Layer 3 — Toolbar  : EditorSecondaryToolPanel + EditorBottomToolbar (bottom, fixed)
///
/// Tapping a segment ONLY selects it.  Edit panels are opened via the bottom toolbar.
public struct ClipEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.editorLayoutMode) private var layoutMode
    @FocusState private var editorHasFocus: Bool
    @State private var store: EditorStore
    @State private var libraryStore = TimelineLibraryStore()
    @State private var activeProjectID: UUID?
    @State private var activeToolCategory: EditorToolCategory? = nil
    @State private var coordinator = CompositionCoordinator()
    @State private var draftStore  = DraftStore()
    @State private var lastSavedProjectVersion: String?
    private let onExport: ((Data, URL, UIImage) -> Void)?
    private let onDraftSave: ((UUID, EditorTimeline) -> Void)?
    private let onProjectSave: ((LibraryProject) -> Void)?
    private let onPersistenceError: ((Error) -> Void)?
    private let persistence: EditorPersistenceMode
    private let editorAccessory: ((EditorStore) -> AnyView)?
    private let projectName: String

    private var transitionEditContext: TransitionEditContext? { store.selection.editingTransitionContext }

    /// 编辑页（由项目页驱动）：接收已打开的资源库与目标项目。
    /// 项目页负责库/项目管理（新建/重命名/删除等）；本页专注编辑当前项目，
    /// 退出时把 timeline 回库（persistActiveProject）。
    ///
    /// `editorStore` is optional for host-owned Agent integration. When supplied,
    /// the view renders, plays, saves, and undoes on this exact instance; it is
    /// never copied or recreated.
    ///
    /// `editorAccessory` is rendered as a trailing toolbar item and receives the
    /// same `EditorStore`. The host can return a button that presents its own
    /// Agent sheet; the editor does not wrap the host in another navigation stack.
    public init(
        libraryStore: TimelineLibraryStore,
        project: LibraryProject,
        editorStore: EditorStore? = nil,
        persistence: EditorPersistenceMode = .draftStore,
        editorAccessory: ((EditorStore) -> AnyView)? = nil,
        onProjectSave: ((LibraryProject) -> Void)? = nil,
        onPersistenceError: ((Error) -> Void)? = nil,
        onDraftSave: ((UUID, EditorTimeline) -> Void)? = nil,
        onExport: ((Data, URL, UIImage) -> Void)? = nil
    ) {
        self.onDraftSave = onDraftSave
        self.onExport = onExport
        self.onProjectSave = onProjectSave
        self.onPersistenceError = onPersistenceError
        self.persistence = persistence
        self.editorAccessory = editorAccessory
        self.projectName = project.name
        let resolvedStore = editorStore ?? EditorStore(timeline: project.timeline)
        _store = State(initialValue: resolvedStore)
        _libraryStore = State(initialValue: libraryStore)
        _activeProjectID = State(initialValue: project.id)
        _lastSavedProjectVersion = State(initialValue: AgentEditPlan.timelineVersion(for: resolvedStore.timeline))
    }

    /// Compatibility for embedders that already own an `EditorStore` and a
    /// preloaded timeline. The timeline is mirrored into a stable single-project
    /// `.tlkbundle` so media import and project persistence keep working.
    @available(*, deprecated, message: "Pass a TimelineLibraryStore and LibraryProject instead.")
    public init(
        store: EditorStore,
        onDraftSave: ((UUID, EditorTimeline) -> Void)? = nil,
        onExport: ((Data, URL, UIImage) -> Void)? = nil
    ) {
        self.onDraftSave = onDraftSave
        self.onExport = onExport
        self.onProjectSave = nil
        self.onPersistenceError = nil
        self.persistence = .draftStore
        self.editorAccessory = nil
        self.projectName = "Embedded Project"
        _store = State(initialValue: store)
        _lastSavedProjectVersion = State(initialValue: AgentEditPlan.timelineVersion(for: store.timeline))
        if let embedded = try? TimelineEmbeddedLibrary.openOrCreate(for: store.timeline) {
            _libraryStore = State(initialValue: embedded.store)
            _activeProjectID = State(initialValue: embedded.project.id)
        } else {
            _libraryStore = State(initialValue: TimelineLibraryStore())
            _activeProjectID = State(initialValue: nil)
        }
    }

    private let controlBarHeight: CGFloat  = 52
    private let trackMinHeight: CGFloat    = 140

    @State private var showAddMediaPicker = false
    @State private var showFileImporter = false
    @State private var isMediaDropTargeted = false
    @State private var showInspector = false
    @State private var isWorkspaceInspectorCollapsed = false
    @State private var isMediaPanelCollapsed = false
    @State private var workspaceTopHeightOverride: CGFloat?
    @State private var workspaceForm: EditorLayoutForm = .phone
    @State private var addMediaItems: [PhotosPickerItem] = []
    @State private var pendingVisualTrackID: UUID?
    @State private var pendingAudioTrackID: UUID?
    @State private var showExport = false

    // V5 export-config-panel-spec §5.1：规格按钮唤起 ExportConfigSheet
    @State private var showExportConfig = false
    // V5 fullscreen-preview-spec §3：全屏预览 fullScreenCover
    @State private var showFullScreenPreview = false

    /// Forces the UIKit track canvas to re-apply an externally replaced timeline.
    @State private var trackRefreshToken = 0

    public var body: some View {
        editorSheets(editorObservers(editorContent))
    }

    // MARK: - Editor Content (three-layer layout)

    private var editorContent: some View {
        GeometryReader { geo in
            let decision = adaptiveLayout(for: geo)
            let form = decision?.form ?? .phone
            let usesWorkspace = form == .mediumWorkspace || form == .wideWorkspace
            let usesFolded = form == .foldedWorkspace

            ZStack(alignment: .bottom) {
                if let decision, usesFolded {
                    foldedContent(decision: decision)
                } else if let decision, usesWorkspace {
                    workspaceContent(decision: decision)
                } else {
                    stackedContent(
                        geo: geo,
                        previewHeight: decision?.previewSize.height ?? legacyPreviewHeight(for: geo)
                    )
                }
            }
            .animation(.spring(duration: 0.25), value: activeToolCategory)
            .onChange(of: decision?.form, initial: true) { _, newForm in
                let resolved = newForm ?? .phone
                if resolved == .mediumWorkspace || resolved == .wideWorkspace {
                    if workspaceForm != resolved {
                        isWorkspaceInspectorCollapsed = false
                    }
                } else {
                    isWorkspaceInspectorCollapsed = false
                }
                workspaceTopHeightOverride = nil
                workspaceForm = resolved
            }
            .overlay {
                #if DEBUG
                EditorLayoutDebugOverlay(
                    fixedChromeHeight: controlBarHeight + EditorBottomToolbar.height,
                    minTimelineHeight: trackMinHeight
                )
                #endif
            }
        }
        .focusable()
        .focused($editorHasFocus)
        .onAppear { editorHasFocus = true }
        .onChange(of: store.selection.editingSegmentID) { _, newValue in
            if newValue == nil {
                editorHasFocus = true
            }
        }
        .onKeyPress { press in
            guard press.modifiers.isEmpty else { return .ignored }

            if press.key == .space {
                store.togglePlayback()
                return .handled
            }
            if press.key == .leftArrow {
                stepFrame(-1)
                return .handled
            }
            if press.key == .rightArrow {
                stepFrame(1)
                return .handled
            }
            if press.key == .delete {
                deleteSelectedSegment()
                return .handled
            }
            return .ignored
        }
    }

    private func stepFrame(_ direction: Int) {
        let fps = max(store.timeline.canvas.fps, 1)
        let step = 1.0 / Double(fps)
        store.seek(to: store.selection.playheadTime + (direction > 0 ? step : -step))
    }

    private func deleteSelectedSegment() {
        guard let segmentID = store.selection.singleSelectedID else { return }
        store.deleteSegment(id: segmentID)
    }

    // MARK: - Stacked (phone) layout

    private func stackedContent(geo: GeometryProxy, previewHeight: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                EditorPreviewView(
                    store: store,
                    compositionPlayer: coordinator.player,
                    timelinePreviewView: coordinator.timelinePreviewView
                )
                .frame(height: previewHeight)

                Divider().background(Color.white.opacity(0.08))

                editorControlBar
                trackPane

                EditorBottomToolbar(activeCategory: $activeToolCategory)
            }

            // Edit panels cover the bottom toolbar when active.
            panelOverlay(geo: geo)
        }
    }

    // MARK: - Regular width workspace

    private func workspaceContent(
        decision: EditorLayoutDecision
    ) -> some View {
        let bottomChrome = controlBarHeight
            + (decision.form == .mediumWorkspace ? EditorBottomToolbar.height : 0)
            + trackMinHeight
            + 12
        let minTop: CGFloat = 240
        let maxTop = max(minTop, decision.contentSize.height - bottomChrome)
        let topHeight = min(
            max(workspaceTopHeightOverride ?? decision.previewSize.height, minTop),
            maxTop
        )

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                if decision.form == .wideWorkspace {
                    EditorToolRail(
                        activeCategory: $activeToolCategory,
                        topInset: decision.topControlInset
                    )
                    Divider().background(Color.white.opacity(0.08))

                    if decision.contentSize.width >= 1000 {
                        EditorMediaPanel(
                            isCollapsed: $isMediaPanelCollapsed,
                            onPhotos: {
                                pendingVisualTrackID = nil
                                showAddMediaPicker = true
                            },
                            onFiles: {
                                pendingVisualTrackID = nil
                                showFileImporter = true
                            },
                            onDropURLs: { urls in
                                Task { await loadDroppedMediaURLs(urls) }
                            }
                        )
                        Divider().background(Color.white.opacity(0.08))
                    }
                }

                EditorPreviewView(
                    store: store,
                    compositionPlayer: coordinator.player,
                    timelinePreviewView: coordinator.timelinePreviewView
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().background(Color.white.opacity(0.08))

                EditorWorkspaceInspector(
                    route: toolPanelRoute,
                    store: store,
                    isCollapsed: $isWorkspaceInspectorCollapsed,
                    width: decision.auxiliaryPanelWidth,
                    topInset: decision.topControlInset,
                    onDismiss: dismissToolPanel,
                    onAudioTargetConsumed: { pendingAudioTrackID = nil }
                )
            }
            .frame(height: topHeight)
            .background(Color.black)

            EditorWorkspaceDivider(
                topHeight: Binding(
                    get: { topHeight },
                    set: { workspaceTopHeightOverride = $0 }
                ),
                range: minTop...maxTop
            )

            editorControlBar
            trackPane

            if decision.form == .mediumWorkspace {
                EditorBottomToolbar(activeCategory: $activeToolCategory)
            }
        }
    }

    // MARK: - Folded layout

    @ViewBuilder
    private func foldedContent(decision: EditorLayoutDecision) -> some View {
        switch decision.foldAxis {
        case .vertical:
            HStack(spacing: 0) {
                previewPane
                    .frame(
                        width: max(decision.previewSize.width, 1),
                        height: max(decision.contentSize.height, 1)
                    )

                foldGap(
                    width: max(
                        decision.contentSize.width
                            - decision.previewSize.width
                            - decision.timelineSize.width,
                        1
                    )
                )

                verticalTimelineColumn(decision: decision)
                    .frame(
                        width: max(decision.timelineSize.width, 1),
                        height: max(decision.contentSize.height, 1)
                    )
            }

        case .horizontal:
            VStack(spacing: 0) {
                previewPane
                    .frame(
                        width: max(decision.contentSize.width, 1),
                        height: max(decision.previewSize.height, 1)
                    )

                foldGap(
                    height: max(
                        decision.contentSize.height
                            - decision.previewSize.height
                            - decision.timelineSize.height,
                        1
                    )
                )

                horizontalTimelineColumn
                    .frame(
                        width: max(decision.contentSize.width, 1),
                        height: max(decision.timelineSize.height, 1)
                    )
            }

        case .none:
            EmptyView()
        }
    }

    private var previewPane: some View {
        EditorPreviewView(
            store: store,
            compositionPlayer: coordinator.player,
            timelinePreviewView: coordinator.timelinePreviewView
        )
    }

    private func verticalTimelineColumn(decision: EditorLayoutDecision) -> some View {
        VStack(spacing: 0) {
            if decision.topControlInset > 0 {
                Color.clear
                    .frame(height: decision.topControlInset)
            }

            editorControlBar
            trackPane
            EditorBottomToolbar(activeCategory: $activeToolCategory)
        }
    }

    private var horizontalTimelineColumn: some View {
        VStack(spacing: 0) {
            editorControlBar
            trackPane
            EditorBottomToolbar(activeCategory: $activeToolCategory)
        }
    }

    private func foldGap(width: CGFloat) -> some View {
        Color.black
            .frame(width: max(width, 1))
            .allowsHitTesting(false)
    }

    private func foldGap(height: CGFloat) -> some View {
        Color.black
            .frame(height: max(height, 1))
            .allowsHitTesting(false)
    }

    private var editorControlBar: some View {
        EditorControlBar(
            store: store,
            onRequestFullScreenPreview: { showFullScreenPreview = true }
        )
        .frame(height: controlBarHeight)
        .padding(.horizontal, 12)
    }

    private var trackPane: some View {
        ZStack(alignment: .topTrailing) {
            TrackEditorRepresentable(
                store: store,
                timeline: store.timeline,
                refreshToken: trackRefreshToken,
                onEmptyTrackAdd: handleEmptyTrackAdd
            )
            .frame(minHeight: trackMinHeight, maxHeight: .infinity)

            // Fixed "+" button aligned with the main track row (below ruler).
            addSegmentButton
                .padding(.top, TrackCanvasView.rulerHeight + TrackCanvasView.SegmentVisuals.blockVPadding)
                .padding(.trailing, 8)
        }
        .overlay {
            if isMediaDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.yellow, lineWidth: 2)
                        .padding(3)

                    Text("拖入以添加到时间线")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.yellow, in: Capsule())
                }
                .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            pendingVisualTrackID = nil
            Task { await loadDroppedMediaURLs(urls) }
            return true
        } isTargeted: { isTargeted in
            isMediaDropTargeted = isTargeted
        }
    }

    // MARK: - Adaptive layout

    /// Returns a policy decision when the adaptive mode is enabled.
    private func adaptiveLayout(for geo: GeometryProxy) -> EditorLayoutDecision? {
        guard layoutMode == .adaptive else { return nil }
        return EditorLayoutPolicy.decide(layoutInput(for: geo))
    }

    private func layoutInput(for geo: GeometryProxy) -> EditorLayoutInput {
        var metrics = EditorLayoutMetrics()
        metrics.minTimelineHeight = trackMinHeight
        metrics.foldTimelineMinHeight = trackMinHeight + controlBarHeight + EditorBottomToolbar.height

        let chromeHeight = controlBarHeight + EditorBottomToolbar.height

        #if DEBUG
        let debugRegions = EditorLayoutDebugRegions.synthetic(for: geo.size)
        #else
        let debugRegions: [EditorReservedRegion] = []
        #endif

        // The editor's GeometryReader already sits inside the navigation
        // content, so its size is the layout bounds; applying safe-area insets
        // again would double-count them.
        if #available(iOS 27.1, *) {
            let regions = EditorLayoutAdapter.regions(
                division: geo.reservedRegions(
                    kind: .division,
                    options: .includeInactive
                ),
                occlusion: geo.reservedRegions(
                    kind: .occlusion,
                    options: .includeInactive
                )
            )

            return EditorLayoutInput(
                horizontalSizeClass: horizontalSizeClass == .regular ? .regular : .compact,
                verticalSizeClass: verticalSizeClass == .regular ? .regular : .compact,
                containerSize: geo.size,
                safeAreaInsets: .zero,
                fixedChromeHeight: chromeHeight,
                reservedRegions: regions + debugRegions,
                metrics: metrics
            )
        }

        return EditorLayoutInput(
            horizontalSizeClass: horizontalSizeClass == .regular ? .regular : .compact,
            verticalSizeClass: verticalSizeClass == .regular ? .regular : .compact,
            containerSize: geo.size,
            safeAreaInsets: .zero,
            fixedChromeHeight: chromeHeight,
            reservedRegions: debugRegions,
            metrics: metrics
        )
    }

    private func legacyPreviewHeight(for geo: GeometryProxy) -> CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad
            ? geo.size.height * 0.62
            : geo.size.height * 0.53
    }

    // MARK: - Sheets & Presentation Modifiers

    func editorSheets(_ base: some View) -> some View {
        base
        .background(Color(white: 0.08).ignoresSafeArea())
        .background(
            NavigationLink(
                destination: ExportResultView(store: store, onExport: onExport),
                isActive: $showExport,
                label: { EmptyView() }
            )
        )
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(
            get: { transitionEditContext != nil },
            set: { if !$0 { store.selection.editingTransitionContext = nil } }
        )) {
            if let ctx = transitionEditContext {
                TransitionEditSheet(context: ctx, store: store)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: Binding(
            get: { store.ttsConfigSheetTargets != nil },
            set: { if !$0 { store.ttsConfigSheetTargets = nil } }
        )) {
            if let targets = store.ttsConfigSheetTargets {
                TTSConfigSheet(
                    store: store,
                    targetSegmentIDs: targets,
                    onDismiss: { store.ttsConfigSheetTargets = nil }
                )
            }
        }
        // M1c: the inspector reuses the same panel content as the bottom overlay.
        .sheet(isPresented: $showInspector) {
            EditorInspectorSheet(
                route: toolPanelRoute,
                store: store,
                onAudioTargetConsumed: { pendingAudioTrackID = nil }
            )
        }
        // V5 export-config-panel-spec §5.3：规格按钮 → ExportConfigSheet
        .sheet(isPresented: $showExportConfig) {
            ExportConfigSheet(store: store) {
                showExportConfig = false
            }
        }
        // V5 fullscreen-preview-spec §3.2：全屏预览
        .fullScreenCover(isPresented: $showFullScreenPreview) {
            FullScreenPreviewView(timeline: store.timeline) { exitTime in
                showFullScreenPreview = false
                // 回写编辑画布播放头（与编辑画布连续）
                let exitSeconds = exitTime.seconds
                if exitSeconds.isFinite, exitSeconds >= 0 {
                    store.seek(to: exitSeconds)
                }
            }
        }
        // Fullscreen preview takes over the global `VideoLayerComposer.frameProvider`.
        // Pausing + suspending the editor's TimelineRuntime first prevents the
        // editor render loop from pulling empty frames through the in-progress
        // fullscreen provider, which manifested as a freeze right when the user
        // tapped fullscreen during active playback.
        .onChange(of: showFullScreenPreview) { _, isPresented in
            if isPresented {
                if store.isPlaying { store.pause() }
                coordinator.suspendTimelineRuntime()
            } else {
                coordinator.resumeTimelineRuntime()
            }
        }
        .photosPicker(
            isPresented: $showAddMediaPicker,
            selection: $addMediaItems,
            maxSelectionCount: 8,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        )
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie, .image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await loadDroppedMediaURLs(urls) }
            case .failure(let error):
                onPersistenceError?(error)
            }
        }
    }

    // MARK: - Observers & Toolbar

    func editorObservers(_ base: some View) -> some View {
        base
        .onChange(of: addMediaItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadAddMedias(items: items) }
        }
        .onAppear {
            coordinator.attach(to: store)
            store.coordinatorPlayer = coordinator.player
            store.coordinator       = coordinator
            coordinator.scheduleRebuild(timeline: store.timeline, immediate: true)
            if persistence == .draftStore {
                draftStore.bind(to: store)
            }
            // V5.1: 修正 TimelineImporter 把 audio.duration 设为 schema.duration
            // 的设计问题——异步加载真实音频文件时长并 cap 超出的 audio segment。
            Task { await store.normalizeAudioDurations() }
          
        }
        .onDisappear {
            saveDraftAndNotify()
            if persistence == .draftStore {
                draftStore.unbind()
            }
        }
        .onChange(of: store.compositionVersion) { _, _ in
            // Only fires when video/audio/structure changes — subtitle mutations excluded (S-04).
            coordinator.scheduleRebuild(timeline: store.timeline)
            // Force the UIKit track canvas to re-apply the new timeline even when
            // the change came from an external editor (Agent apply).
            trackRefreshToken &+= 1
        }
        .onChange(of: store.selection.singleSelectedID) { _, newID in
            // v3 text-entry-spec §3.5: selecting a segment auto-switches the bottom toolbar
            // category. The actual panel rendered above is driven by segment content too —
            // this only updates the highlight on the bottom toolbar.
            guard let id = newID,
                  let seg = store.timeline.segment(id: id) else { return }
            switch seg.content {
            case .text, .subtitle:  activeToolCategory = .text
            case .audio:            activeToolCategory = .audio
            case .video, .image:    activeToolCategory = .clip
            }
        }
        // v4 fix (空字幕/文本片段自动回收):
        // 当 TextEditPanel 收起时（editingSegmentID 从非 nil 变 nil），如果刚
        // 才编辑的字幕/文本片段内容为空（仅含空白），自动从轨道上删除该片段，
        // 避免遗留 0 内容的空 block。删除走标准 deleteSegment 路径，所以：
        //   - 是 undo-tracked（用户可 undo 恢复）
        //   - 自动回收同轨空轨道（v3 multi-track §2.4）
        //   - 触发 AVComposition 重建
        .onChange(of: store.selection.editingSegmentID) { oldValue, newValue in
            guard newValue == nil,
                  let oldID = oldValue,
                  let seg = store.timeline.segment(id: oldID) else { return }
            let textToCheck: String
            switch seg.content {
            case .text(let c):      textToCheck = c.text
            case .subtitle(let c):  textToCheck = c.text
            default: return        // only applies to text-bearing segments
            }
            if textToCheck.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.deleteSegment(id: oldID)
            }
        }
        // v3 P3 fix (problem #1 from in-device test): the .text / .audio edit panels
        // are dispatched purely from `selection.singleSelectedID`, so once a segment
        // was selected, tapping a different category in the bottom toolbar couldn't
        // swap the panel out. Detect "user-driven category change that no longer
        // matches the current selection" and clear the selection so the dispatch
        // chain falls through to the chosen category's default panel.
        .onChange(of: activeToolCategory) { _, newCategory in
            if newCategory != .audio {
                pendingAudioTrackID = nil
            }
            guard let newCategory,
                  let segID = store.selection.singleSelectedID,
                  let seg = store.timeline.segment(id: segID),
                  !categoryMatchesSelection(newCategory, segment: seg) else { return }
            store.selection.deselect()
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                    saveDraftAndNotify()
                    if persistence == .draftStore {
                        draftStore.unbind()
                    }
                } label: {
                    Label("关闭", systemImage: "xmark")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        pendingVisualTrackID = nil
                        showAddMediaPicker = true
                    } label: {
                        Label("照片与视频", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        pendingVisualTrackID = nil
                        showFileImporter = true
                    } label: {
                        Label("文件", systemImage: "folder")
                    }
                } label: {
                    Label("导入", systemImage: "plus.rectangle.on.rectangle")
                }

                Button {
                    store.undo()
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                }
                .disabled(!store.canUndo)
                .keyboardShortcut("z", modifiers: .command)

                Button {
                    store.redo()
                } label: {
                    Label("重做", systemImage: "arrow.uturn.forward")
                }
                .disabled(!store.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])

                Button {
                    if workspaceForm == .mediumWorkspace || workspaceForm == .wideWorkspace {
                        isWorkspaceInspectorCollapsed.toggle()
                    } else {
                        showInspector = true
                    }
                } label: {
                    Label("检查器", systemImage: "slider.horizontal.3")
                }
            }
            // Separate trailing items so the system can overflow each action
            // individually on compact widths and Duo vertical bars.
            if let editorAccessory {
                ToolbarItem(placement: .topBarTrailing) {
                    editorAccessory(store)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                specButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                exportButton
            }
            ToolbarItem(placement: .title) {
                Text(store.timeline.metadata.productName ?? "剪辑")
                    .foregroundColor(.white)
            }
        }
    }

    // MARK: - Toolbar Items

    private var addSegmentButton: some View {
        Button {
            pendingVisualTrackID = nil
            showAddMediaPicker = true
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 40, height: TrackCanvasView.trackHeight - TrackCanvasView.SegmentVisuals.blockVPadding * 2)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private func handleEmptyTrackAdd(trackID: UUID, kind: EditorTrack.Kind) {
        store.selection.deselect()
        switch kind {
        case .overlay:
            pendingVisualTrackID = trackID
            showAddMediaPicker = true
        case .audio:
            pendingAudioTrackID = trackID
            activeToolCategory = .audio
        case .text:
            _ = store.createNewTextSegment(targetTrackID: trackID)
            activeToolCategory = .text
        case .subtitle:
            _ = store.createNewSubtitleSegment(targetTrackID: trackID)
            activeToolCategory = .text
        case .video:
            pendingVisualTrackID = nil
            showAddMediaPicker = true
        case .adjustment:
            activeToolCategory = .adjust
        }
    }

    private func saveDraftAndNotify() {
        switch persistence {
        case .draftStore:
            let draftID = DraftStore.save(store.timeline)
            onDraftSave?(draftID, store.timeline)
            do {
                _ = try persistActiveProject()
            } catch {
                onPersistenceError?(error)
            }
        case .library:
            // .tlkproj is the only timeline source in library mode.
            do {
                if let project = try persistActiveProject() {
                    onProjectSave?(project)
                }
            } catch {
                onPersistenceError?(error)
            }
        }
    }

    /// 把当前 timeline 写回活动项目（LibraryProject 落库）。
    /// `.library` 模式要求错误向上传播；`.draftStore` 兼容路径也通过回调报告。
    @discardableResult
    private func persistActiveProject() throws -> LibraryProject? {
        guard let id = activeProjectID else { return nil }
        let version = AgentEditPlan.timelineVersion(for: store.timeline)
        guard version != lastSavedProjectVersion else { return nil }
        var project = LibraryProject(id: id, name: projectName, timeline: store.timeline)
        if let existing = libraryStore.projects.first(where: { $0.id == id }) {
            project.name = existing.name
        }
        _ = try libraryStore.saveProject(project)
        lastSavedProjectVersion = version
        return project
    }

    // MARK: - Panel Overlay

    /// Edit panels overlay on top of EditorBottomToolbar, giving each panel more
    /// vertical space while keeping the preview and tracks fully visible.
    /// Panel overlay dispatch (V4 unified interaction spec):
    ///   Priority 1 — `editingSegmentID` triggers: full edit panels for text / subtitle / audio.
    ///     Set by preview tap (`selectOnly`) or explicit "edit" button; cleared on track tap.
    ///   Priority 2 — `activeToolCategory` + `singleSelectedID`: segment shortcut panels.
    ///   Priority 3 — `activeToolCategory` alone: category default panels.
    @ViewBuilder
    private func panelOverlay(geo: GeometryProxy) -> some View {
        let route = toolPanelRoute

        if !route.isEmpty {
            EditorToolPanelContent(
                route: route,
                store: store,
                onDismiss: dismissToolPanel,
                onAudioTargetConsumed: { pendingAudioTrackID = nil }
            )
            .frame(maxHeight: route.maxHeightFraction.map { geo.size.height * $0 })
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Presentation-independent panel route. The bottom overlay and the
    /// inspector sheet both render this route, so edit behavior is shared.
    private var toolPanelRoute: EditorToolPanelRoute {
        // Priority 1: full segment editing.
        if let segmentID = store.selection.editingSegmentID,
           let segment = store.timeline.segment(id: segmentID) {
            if segment.isText || segment.isSubtitle {
                return .textEdit(segmentID: segmentID)
            }
            if segment.isAudio {
                return .audioEdit(segmentID: segmentID)
            }
        }

        // Priority 2: segment shortcut panels.
        if let category = activeToolCategory,
           let segmentID = store.selection.singleSelectedID,
           let segment = store.timeline.segment(id: segmentID) {
            switch category {
            case .text where segment.isText || segment.isSubtitle:
                return .textActions(segmentID: segmentID)
            case .clip where store.timeline.mainTrack?.segment(id: segmentID) != nil:
                return .clipActions(segmentID: segmentID)
            case .adjust where store.timeline.mainTrack?.segment(id: segmentID) != nil:
                return .adjust(segmentID: segmentID)
            case .animation where store.timeline.mainTrack?.segment(id: segmentID) != nil:
                return .animation(segmentID: segmentID)
            case .audio where segment.isAudio:
                return .audioActions(segmentID: segmentID)
            default:
                break
            }
        }

        // Priority 3: category defaults.
        if activeToolCategory == .audio {
            return .audioDefault(targetTrackID: pendingAudioTrackID)
        }
        if let category = activeToolCategory {
            return .category(category)
        }
        return .empty
    }

    private func dismissToolPanel() {
        activeToolCategory = nil
        pendingAudioTrackID = nil
    }

    // MARK: - Tool Category Dispatch

    /// 判断工具类目切换后是否与当前选中片段的内容匹配（匹配则保留选中，
    /// 不匹配则由调用方清除选中，让面板派发链落到新类目的默认面板）。
    private func categoryMatchesSelection(
        _ category: EditorToolCategory,
        segment: EditorSegment
    ) -> Bool {
        switch (category, segment.content) {
        case (.text, .text), (.text, .subtitle):           return true
        case (.audio, .audio):                             return true
        case (.clip, .video), (.clip, .image):             return true
        case (.adjust, .video), (.adjust, .image):         return true
        case (.animation, .video), (.animation, .image):   return true
        default:                                           return false
        }
    }

    // MARK: - Add Media

    /// 多选导入：解码 → 批量落库（一次 IO）→ 按选择顺序逐个加时间线。
    /// 单个 item 失败跳过不中断整批；所有片段一次 MainActor 批量插入。
    private func loadAddMedias(items: [PhotosPickerItem]) async {
        let targetTrackID = await MainActor.run { pendingVisualTrackID }
        defer {
            Task { @MainActor in
                addMediaItems = []
                pendingVisualTrackID = nil
            }
        }

        let selection = await EditorMediaSelection.load(items)
        defer { selection.removeTemporaryCopies() }
        guard !selection.urls.isEmpty else { return }
        await addLibraryMedia(urls: selection.urls, targetTrackID: targetTrackID)
    }

    /// Imports dropped or picked file URLs into the library, then appends the
    /// resulting media to the timeline.
    private func loadDroppedMediaURLs(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }

        let targetTrackID = await MainActor.run { pendingVisualTrackID }
        let scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            for url in scopedURLs {
                url.stopAccessingSecurityScopedResource()
            }
            Task { @MainActor in pendingVisualTrackID = nil }
        }

        await addLibraryMedia(urls: urls, targetTrackID: targetTrackID)
    }

    private func addLibraryMedia(urls: [URL], targetTrackID: UUID?) async {
        // One bulk copy into .tlkbundle Media/ keeps the original order.
        let libraryURLs = await libraryStore.addMedia(urls: urls)
        guard !libraryURLs.isEmpty else { return }

        var segments: [(url: URL, native: Double?)] = []
        for libraryURL in libraryURLs {
            let type = try? libraryURL.resourceValues(forKeys: [.contentTypeKey]).contentType
            let isVideo = type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
            let native = isVideo ? await avDuration(of: libraryURL) : nil
            segments.append((libraryURL, native))
        }

        await MainActor.run {
            for (url, native) in segments {
                store.addVisualSegment(
                    localURL: url,
                    nativeDuration: native,
                    targetTrackID: targetTrackID
                )
            }
        }
        await store.waitForAutomaticCanvasResolution()
    }

    private func avDuration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration),
              dur.isNumeric, dur.seconds > 0 else { return nil }
        return dur.seconds
    }

    private var exportButton: some View {
        Button {
            store.pause()
            showExport = true
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        .foregroundStyle(.white)
    }

    /// V5 export-config-panel-spec §5.1：规格按钮。常态显示当前生效分辨率。
    /// 文案跟随 `store.timeline.effectiveExportConfig.resolution.label`：
    /// 新工程/旧草稿按 canvas 派生（4 种默认 canvas 预设 → "720P"），
    /// 用户改过则跟用户最后一次选择。
    private var specButton: some View {
        Button {
            showExportConfig = true
        } label: {
            Text(store.timeline.effectiveExportConfig.resolution.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.15))
                .cornerRadius(6)
        }
        .accessibilityLabel("导出规格：\(store.timeline.effectiveExportConfig.resolution.label)")
    }
}

// MARK: - UIKit Bridge

/// Embeds ClipEditorViewController (UIKit) into SwiftUI.
struct TrackEditorRepresentable: UIViewControllerRepresentable {
    var store: EditorStore
    /// Passed by value so SwiftUI observes external timeline replacements
    /// (for example an Agent batch) and calls updateUIViewController.
    var timeline: EditorTimeline
    /// Changes on every compositionVersion bump, guaranteeing updateUIViewController
    /// runs for external timeline replacements.
    var refreshToken: Int
    var onEmptyTrackAdd: ((UUID, EditorTrack.Kind) -> Void)?

    func makeUIViewController(context: Context) -> ClipEditorViewController {
        let vc = ClipEditorViewController(store: store)
        vc.onEmptyTrackAdd = onEmptyTrackAdd
        return vc
    }

    func updateUIViewController(_ vc: ClipEditorViewController, context: Context) {
        vc.onEmptyTrackAdd = onEmptyTrackAdd
        vc.apply(timeline: timeline, selection: store.selection)
    }
}
#endif

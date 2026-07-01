#if canImport(UIKit)
import SwiftUI
import PhotosUI
import AVFoundation

/// Public entry point for the clip editor.
/// Three-layer architecture (locked):
///   Layer 1 — Preview  : EditorPreviewView (top, proportional height)
///   Layer 2 — Tracks   : EditorControlBar + TrackEditorRepresentable (middle, flexible)
///   Layer 3 — Toolbar  : EditorSecondaryToolPanel + EditorBottomToolbar (bottom, fixed)
///
/// Tapping a segment ONLY selects it.  Edit panels are opened via the bottom toolbar.
public struct ClipEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store: EditorStore
    @State private var activeToolCategory: EditorToolCategory? = nil
    @State private var coordinator = CompositionCoordinator()
    @State private var draftStore  = DraftStore()
    private let onExport: ((Data, URL, UIImage) -> Void)?
    private let onDraftSave: ((UUID, EditorTimeline) -> Void)?

    private var transitionEditContext: TransitionEditContext? { store.selection.editingTransitionContext }

    public init(
        store: EditorStore,
        onDraftSave: ((UUID, EditorTimeline) -> Void)? = nil,
        onExport: ((Data, URL, UIImage) -> Void)? = nil
    ) {
        _store = State(initialValue: store)
        self.onDraftSave = onDraftSave
        self.onExport = onExport
    }

    private let controlBarHeight: CGFloat  = 52
    private let trackMinHeight: CGFloat    = 140

    @State private var showAddMediaPicker = false
    @State private var addMediaItem: PhotosPickerItem?
    @State private var pendingVisualTrackID: UUID?
    @State private var pendingAudioTrackID: UUID?
    @State private var showExport = false

    // V5 export-config-panel-spec §5.1：规格按钮唤起 ExportConfigSheet
    @State private var showExportConfig = false
    // V5 fullscreen-preview-spec §3：全屏预览 fullScreenCover
    @State private var showFullScreenPreview = false

    public var body: some View {
        GeometryReader { geo in
            let previewHeight = UIDevice.current.userInterfaceIdiom == .pad ? geo.size.height * 0.62 : geo.size.height * 0.53

            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {

                    // ── Layer 1: Preview ─────────────────────────────────────────
                    EditorPreviewView(store: store, compositionPlayer: coordinator.player)
                        .frame(height: previewHeight)

                    Divider().background(Color.white.opacity(0.08))

                    // ── Layer 2: Tracks ──────────────────────────────────────────
                    EditorControlBar(
                        store: store,
                        onRequestFullScreenPreview: { showFullScreenPreview = true }
                    )
                        .frame(height: controlBarHeight)
                        .padding(.horizontal, 12)
                        .overlay(alignment: .trailing) {
                            undoRedoButtons
                                .padding(.trailing, 55)
                        }

                    ZStack(alignment: .topTrailing) {
                        TrackEditorRepresentable(store: store, onEmptyTrackAdd: handleEmptyTrackAdd)
                            .frame(minHeight: trackMinHeight, maxHeight: .infinity)

                        // Fixed "+" button aligned with the main track row (below ruler).
                        addSegmentButton
                            .padding(.top, TrackCanvasView.rulerHeight + TrackCanvasView.SegmentVisuals.blockVPadding)
                            .padding(.trailing, 8)
                    }

                    // ── Layer 3: Bottom Toolbar ──────────────────────────────────
                    EditorBottomToolbar(activeCategory: $activeToolCategory)
                }

                // ── Overlay: Edit panels cover the bottom toolbar when active ──
                panelOverlay(geo: geo)
            }
            .animation(.spring(duration: 0.25), value: activeToolCategory)
        }
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
                    .presentationDetents([.height(310)])
                    .presentationDragIndicator(.hidden)
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
            selection: $addMediaItem,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        )
        .onChange(of: addMediaItem) { _, item in
            guard let item else { return }
            Task { await loadAddMedia(item: item) }
        }
        .onAppear {
            coordinator.attach(to: store)
            store.coordinatorPlayer = coordinator.player
            store.coordinator       = coordinator
            coordinator.scheduleRebuild(timeline: store.timeline, immediate: true)
            draftStore.bind(to: store)
            // V5.1: 修正 TimelineImporter 把 audio.duration 设为 schema.duration
            // 的设计问题——异步加载真实音频文件时长并 cap 超出的 audio segment。
            Task { await store.normalizeAudioDurations() }
          
        }
        .onDisappear {
            saveDraftAndNotify()
            draftStore.unbind()
        }
        .onChange(of: store.compositionVersion) { _, _ in
            // Only fires when video/audio/structure changes — subtitle mutations excluded (S-04).
            coordinator.scheduleRebuild(timeline: store.timeline)
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
                  let seg = store.timeline.segment(id: segID) else { return }
            let matches: Bool
            switch (newCategory, seg.content) {
            case (.text, .text), (.text, .subtitle):       matches = true
            case (.audio, .audio):                         matches = true
            case (.clip, .video), (.clip, .image):         matches = true
            case (.adjust, .video), (.adjust, .image):     matches = true
            case (.animation, .video), (.animation, .image): matches = true
            default:                                       matches = false
            }
            if !matches { store.selection.deselect() }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                    saveDraftAndNotify()
                    draftStore.unbind()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                }

            }
            // V5 export-config-panel-spec §5.1：规格按钮在导出按钮**左侧**。
            // 用单 ToolbarItem + HStack 保证 [规格][导出] 视觉顺序在任何 iOS 版本下一致
            // （多 ToolbarItem 在同 placement 的排序行为版本间有差异，单 HStack 可预测）。
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    specButton
                    exportButton
                }
            }
            ToolbarItem(placement: .title) {
                Text(store.timeline.metadata.productName ?? "剪辑")
                    .foregroundColor(.white)
            }
        }
    }

    // MARK: - Toolbar Items

    private var undoRedoButtons: some View {
        HStack(spacing: 4) {
            Button(action: { store.undo() }) {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!store.canUndo)

            Button(action: { store.redo() }) {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!store.canRedo)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

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
        let draftID = DraftStore.save(store.timeline)
        onDraftSave?(draftID, store.timeline)
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
        // ── Priority 1: Full edit panels ───────────────────────────────────
        if let segID = store.selection.editingSegmentID,
           let seg = store.timeline.segment(id: segID),
           (seg.isText || seg.isSubtitle) {
            TextEditPanel(segmentID: segID, store: store)
                .frame(maxHeight: geo.size.height * 0.45)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let segID = store.selection.editingSegmentID,
                  store.timeline.segment(id: segID)?.isAudio == true {
            AudioEditPanel(segmentID: segID, store: store)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        // ── Priority 2: Segment shortcut panels ────────────────────────────
        else if activeToolCategory == .text,
                let segID = store.selection.singleSelectedID,
                let seg = store.timeline.segment(id: segID),
                (seg.isText || seg.isSubtitle) {
            TextSegmentActionPanel(segmentID: segID, store: store, onDismiss: { activeToolCategory = nil })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if activeToolCategory == .clip,
                let segID = store.selection.singleSelectedID,
                store.timeline.mainTrack?.segment(id: segID) != nil {
            SegmentReplacePanel(segmentID: segID, store: store, onDismiss: { activeToolCategory = nil })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if activeToolCategory == .adjust,
                  let segID = store.selection.singleSelectedID,
                  store.timeline.mainTrack?.segment(id: segID) != nil {
            ColorAdjustmentPanel(segmentID: segID, store: store, onDismiss: { activeToolCategory = nil })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if activeToolCategory == .animation,
                  let segID = store.selection.singleSelectedID,
                  store.timeline.mainTrack?.segment(id: segID) != nil {
            AnimationPickerSheet(segmentID: segID, store: store, onDismiss: { activeToolCategory = nil })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if activeToolCategory == .audio,
                  let segID = store.selection.singleSelectedID,
                  store.timeline.segment(id: segID)?.isAudio == true {
            AudioSegmentActionPanel(segmentID: segID, store: store, onDismiss: { activeToolCategory = nil })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        // ── Priority 3: Category default panels ────────────────────────────
        else if activeToolCategory == .audio {
            AudioSecondaryPanel(
                store: store,
                targetTrackID: pendingAudioTrackID,
                onTargetConsumed: {
                    pendingAudioTrackID = nil
                },
                onDismiss: {
                    activeToolCategory = nil
                    pendingAudioTrackID = nil
                }
            )
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let category = activeToolCategory {
            EditorSecondaryToolPanel(category: category, store: store, onDismiss: { activeToolCategory = nil })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Add Media

    private func loadAddMedia(item: PhotosPickerItem) async {
        let targetTrackID = await MainActor.run { pendingVisualTrackID }
        defer {
            Task { @MainActor in
                addMediaItem = nil
                pendingVisualTrackID = nil
            }
        }
        // Try video first.
        if let movie = try? await item.loadTransferable(type: VideoTransferable.self) {
            let native = await avDuration(of: movie.url) ?? 0
            await MainActor.run {
                store.addVisualSegment(
                    localURL: movie.url,
                    nativeDuration: native,
                    targetTrackID: targetTrackID
                )
            }
            return
        }
        // Fallback: image.
        if let data = try? await item.loadTransferable(type: Data.self) {
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try? data.write(to: dest)
            await MainActor.run {
                store.addVisualSegment(
                    localURL: dest,
                    nativeDuration: nil,
                    targetTrackID: targetTrackID
                )
            }
        }
    }

    private func avDuration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration),
              dur.isNumeric, dur.seconds > 0 else { return nil }
        return dur.seconds
    }

    private var exportButton: some View {
        Button("导出") {
            store.pause()
            showExport = true
        }
        .foregroundStyle(.white)
        .fontWeight(.medium)
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
    var onEmptyTrackAdd: ((UUID, EditorTrack.Kind) -> Void)?

    func makeUIViewController(context: Context) -> ClipEditorViewController {
        let vc = ClipEditorViewController(store: store)
        vc.onEmptyTrackAdd = onEmptyTrackAdd
        return vc
    }

    func updateUIViewController(_ vc: ClipEditorViewController, context: Context) {
        vc.onEmptyTrackAdd = onEmptyTrackAdd
        vc.apply(timeline: store.timeline, selection: store.selection)
    }
}
#endif

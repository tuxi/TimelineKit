import CoreGraphics

#if canImport(UIKit)
import SwiftUI
import PhotosUI
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared

/// iOS 项目列表页（对齐剪映项目页）：
/// 真实封面缩略图 + 名称/创建时间/时长 + 新建按钮 + 长按上下文菜单
/// （重命名 / 复制 / 置顶 / 删除）与独立 ⋯ 操作菜单。窄宽度用单列横向行，
/// 宽宽度用居中自适应卡片网格。点击条目 push 该项目的编辑页。
public struct ProjectBrowserView: View {
    @Bindable var libraryStore: TimelineLibraryStore
    @State private var showCreateProject = false
    @State private var newProjectName = ""
    @State private var showMediaPicker = false
    @State private var selectedMedia: [PhotosPickerItem] = []
    @State private var isCreatingProject = false
    @State private var createdProject: LibraryProject?
    @State private var renameTarget: LibraryProject?
    @State private var renameText = ""
    @State private var deleteTarget: LibraryProject?
    @State private var errorMessage: String?

    public init(libraryStore: TimelineLibraryStore) {
        self.libraryStore = libraryStore
    }

    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                if libraryStore.projects.isEmpty {
                    emptyState
                } else {
                    Group {
                        switch ProjectBrowserLayoutPolicy.style(for: proxy.size.width) {
                        case .list:
                            projectList
                        case .grid:
                            projectGrid
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
        }
        .navigationTitle("项目")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showMediaPicker = true
                } label: {
                    Label("新建项目", systemImage: "plus")
                }
                .accessibilityIdentifier("TimelineKit.NewProject")

                Menu {
                    Button {
                        showCreateProject = true
                    } label: {
                        Label("创建空白项目", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Label("更多创建方式", systemImage: "ellipsis.circle")
                }
            }
        }
        .navigationDestination(for: UUID.self) { projectID in
            editorDestination(projectID: projectID)
        }
        .navigationDestination(isPresented: Binding(
            get: { createdProject != nil },
            set: { if !$0 { createdProject = nil } }
        )) {
            if let project = createdProject {
                ClipEditorView(libraryStore: libraryStore, project: project, persistence: .library)
            }
        }
        .photosPicker(
            isPresented: $showMediaPicker,
            selection: $selectedMedia,
            maxSelectionCount: 8,
            selectionBehavior: .ordered,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        )
        .onChange(of: selectedMedia) { _, items in
            guard !items.isEmpty else { return }
            Task { await createProject(from: items) }
        }
        .disabled(isCreatingProject)
        .overlay {
            if isCreatingProject {
                ZStack {
                    Color.black.opacity(0.65)
                    ProgressView("正在创建项目…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
        }
        // 新建项目：命名弹窗。
        .alert("创建空白项目", isPresented: $showCreateProject) {
            TextField("项目名称", text: $newProjectName, prompt: Text("未命名项目"))
            Button("创建") { createProject() }
            Button("取消", role: .cancel) { newProjectName = "" }
        } message: {
            Text("添加首个视频或照片后，自动设置画布比例。")
        }
        // 重命名弹窗。
        .alert("重命名项目", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("项目名称", text: $renameText)
            Button("确定") { commitRename() }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        // 删除确认。
        .confirmationDialog(
            "删除项目",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { commitDelete() }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("「\(deleteTarget?.name ?? "")」将被删除，此操作不可恢复。")
        }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            // 返回列表时刷新（编辑页内可能已修改项目内容）。
            libraryStore.refreshProjects()
        }
    }

    // MARK: - Layout

    /// Narrow widths: one-column horizontal rows — fixed-ratio cover thumbnail,
    /// flexible/truncating metadata, independent ellipsis action menu.
    private var projectList: some View {
        LazyVStack(spacing: 10) {
            ForEach(libraryStore.projects) { project in
                projectRow(project)
            }
        }
        .frame(maxWidth: ProjectBrowserLayoutPolicy.listContentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    /// Wider widths: centered adaptive cards. `.adaptive` with a bounded
    /// min/max keeps cards from stretching to fill arbitrary column widths,
    /// and the content cap keeps lines from running too long on iPad.
    private var projectGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 14) {
            ForEach(libraryStore.projects) { project in
                projectCard(project)
            }
        }
        .frame(maxWidth: ProjectBrowserLayoutPolicy.gridContentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private var gridColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: ProjectBrowserLayoutPolicy.gridMinCardWidth,
                      maximum: ProjectBrowserLayoutPolicy.gridMaxCardWidth),
            spacing: 14
        )]
    }

    // MARK: - Item views

    private func projectRow(_ project: LibraryProject) -> some View {
        HStack(spacing: 10) {
            NavigationLink(value: project.id) {
                HStack(spacing: 10) {
                    ProjectThumbnailView(
                        project: project,
                        designWidthPoints: ProjectBrowserLayoutPolicy.rowThumbnailWidth
                    )
                    .frame(width: ProjectBrowserLayoutPolicy.rowThumbnailWidth)
                    .aspectRatio(ProjectBrowserLayoutPolicy.thumbnailAspectRatio,
                                 contentMode: .fit)

                    Spacer(minLength: 10)

                    VStack(alignment: .leading, spacing: 4) {
                        projectTitle(project)
                        projectSubtitle(project)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)

            projectActionMenu(project)
        }
        .padding(8)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contextMenu { projectActionButtons(project) }
        .hoverEffect(.highlight)
    }

    private func projectCard(_ project: LibraryProject) -> some View {
        ZStack(alignment: .topTrailing) {
            NavigationLink(value: project.id) {
                VStack(alignment: .leading, spacing: 6) {
                    ProjectThumbnailView(
                        project: project,
                        designWidthPoints: ProjectBrowserLayoutPolicy.cardThumbnailDesignWidth
                    )
                    .aspectRatio(ProjectBrowserLayoutPolicy.thumbnailAspectRatio,
                                 contentMode: .fit)
                    projectTitle(project)
                    projectSubtitle(project)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.11))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            projectActionMenu(project)
                .padding(6)
        }
        .contextMenu { projectActionButtons(project) }
        .hoverEffect(.highlight)
    }

    private func projectTitle(_ project: LibraryProject) -> some View {
        Text(project.name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func projectSubtitle(_ project: LibraryProject) -> some View {
        HStack(spacing: 6) {
            Text(Self.dateFormatter.string(from: project.createdAt))
            Text("·")
            Text(Self.durationString(seconds: project.timeline.duration))
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.5))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Independent ellipsis action menu. Placed outside the NavigationLink so
    /// opening it never triggers navigation; mirrors the context-menu actions.
    private func projectActionMenu(_ project: LibraryProject) -> some View {
        Menu {
            projectActionButtons(project)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .contentShape(Circle())
        }
        .accessibilityLabel("项目操作")
    }

    @ViewBuilder
    private func projectActionButtons(_ project: LibraryProject) -> some View {
        Button {
            renameTarget = project
            renameText = project.name
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button {
            duplicate(project)
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        Button {
            togglePin(project)
        } label: {
            Label(project.isPinned ? "取消置顶" : "置顶",
                  systemImage: project.isPinned ? "pin.slash" : "pin")
        }
        Button(role: .destructive) {
            deleteTarget = project
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/M/d HH:mm"
        return f
    }()

    private static func durationString(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.white.opacity(0.35))
            Text("还没有项目")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
            Text("选择视频或照片，自动设置画布比例")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.45))
            Button("选择素材新建项目") { showMediaPicker = true }
                .buttonStyle(.borderedProminent)
            Button("创建空白项目") { showCreateProject = true }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 160)
    }

    // MARK: - Navigation

    @ViewBuilder
    private func editorDestination(projectID: UUID) -> some View {
        if let project = libraryStore.projects.first(where: { $0.id == projectID }) {
            ClipEditorView(
                libraryStore: libraryStore,
                project: project,
                persistence: .library
            )
        } else {
            Text("项目不存在")
                .foregroundStyle(.white)
        }
    }

    // MARK: - Actions

    private func createProject() {
        let name = newProjectName.isEmpty ? "未命名项目" : newProjectName
        newProjectName = ""
        do {
            createdProject = try libraryStore.createProject(name: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createProject(from items: [PhotosPickerItem]) async {
        guard !isCreatingProject else { return }
        isCreatingProject = true
        defer {
            isCreatingProject = false
            selectedMedia = []
        }
        let selection = await EditorMediaSelection.load(items)
        defer { selection.removeTemporaryCopies() }
        guard !selection.urls.isEmpty else {
            errorMessage = "无法读取所选素材，请重新选择视频或照片。"
            return
        }
        do {
            createdProject = try await libraryStore.createProject(
                name: "未命名项目", mediaURLs: selection.urls
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        renameTarget = nil
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != target.name else { return }
        do {
            try libraryStore.renameProject(id: target.id, newName: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func duplicate(_ project: LibraryProject) {
        do {
            _ = try libraryStore.duplicateProject(id: project.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func togglePin(_ project: LibraryProject) {
        do {
            try libraryStore.setPinned(id: project.id, isPinned: !project.isPinned)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitDelete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        do {
            try libraryStore.deleteProject(id: target.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - ProjectThumbnailView

/// 项目封面缩略图：主轨最早视觉帧，16:9 aspect-fill，固定像素桶。
/// 加载态 / 无封面 / 失败态使用可区分的占位视图。
private struct ProjectThumbnailView: View {
    let project: LibraryProject
    /// 展示宽度（pt）。像素尺寸吸附到固定桶，布局小幅变化不会触发重新生成。
    let designWidthPoints: CGFloat

    enum Phase: Equatable {
        case loading
        case ready(UIImage)
        case noThumbnail
        case failed
    }

    @State private var phase: Phase = .loading
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            Color(white: 0.16)
            switch phase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.6))
            case .ready(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            case .noThumbnail:
                placeholder(systemName: project.isPinned ? "pin.fill" : "film")
            case .failed:
                placeholder(systemName: "photo.badge.exclamationmark")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            if project.isPinned, case .ready = phase {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .padding(4)
            }
        }
        .task(id: requestIdentity) {
            await load()
        }
    }

    private func placeholder(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 22))
            .foregroundStyle(.white.opacity(0.3))
    }

    /// Stable Hashable identity: changes only when the cover source or the
    /// pixel bucket changes. `.task(id:)` cancels + restarts on change, so the
    /// load resets per identity and stale completions are dropped.
    private var requestIdentity: ProjectThumbnailRequestIdentity? {
        guard let source = project.thumbnailSource else { return nil }
        let size = ThumbnailPixelBucket.size(forDisplayWidth: designWidthPoints,
                                             scale: displayScale)
        return ProjectThumbnailRequestIdentity(
            projectID: project.id,
            url: source.url,
            isImage: source.isImage,
            time: source.time,
            bucketWidth: Int(size.width),
            bucketHeight: Int(size.height)
        )
    }

    @MainActor
    private func load() async {
        guard let identity = requestIdentity else {
            phase = .noThumbnail
            return
        }
        phase = .loading
        let image = await ThumbnailProvider.shared.thumbnail(
            for: identity.url,
            isImage: identity.isImage,
            at: identity.time,
            size: CGSize(width: identity.bucketWidth, height: identity.bucketHeight),
            aspectFill: true
        )
        // `.task(id:)` cancels this task when the identity changed; a stale
        // completion must never overwrite a newer project/asset state.
        if Task.isCancelled { return }
        guard requestIdentity == identity else { return }
        if let image {
            phase = .ready(UIImage(cgImage: image))
        } else {
            phase = .failed
        }
    }
}

/// 封面请求的稳定身份：项目 + 素材 URL + 取帧时间 + 像素桶。
private struct ProjectThumbnailRequestIdentity: Hashable {
    let projectID: UUID
    let url: URL
    let isImage: Bool
    let time: Double
    let bucketWidth: Int
    let bucketHeight: Int
}

#endif

// MARK: - Layout policy (platform-neutral, unit-testable)

/// Browser layout form chosen from the actual container width.
public enum ProjectBrowserLayoutStyle: String, Equatable, Sendable {
    /// Narrow widths: one-column horizontal rows.
    case list
    /// Wider widths: centered adaptive card grid.
    case grid
}

/// Pure width → layout decision for `ProjectBrowserView`.
///
/// Reads the actual container width (not device idiom), so iPhone portrait,
/// iPhone landscape, and iPad full/split widths all resolve correctly:
/// - iPhone portrait (320–430) and iPad 1/2–1/3 split (≈320–540) → rows.
/// - iPhone landscape (667–932) and iPad full (834–1366) → cards.
public enum ProjectBrowserLayoutPolicy {
    /// Widths below this use the one-column row layout.
    public static let listStyleMaxWidth: CGFloat = 600
    /// Row content is capped (and centered) instead of stretching edge-to-edge.
    public static let listContentMaxWidth: CGFloat = 720
    /// Card grid content cap.
    public static let gridContentMaxWidth: CGFloat = 980
    /// Adaptive card width bounds — cards never stretch beyond these.
    public static let gridMinCardWidth: CGFloat = 160
    public static let gridMaxCardWidth: CGFloat = 220
    /// Row cover thumbnail width (pt); height derives from the 16:9 ratio.
    public static let rowThumbnailWidth: CGFloat = 120
    /// Design width used to pick the pixel bucket for grid cards (the max
    /// card width, so the image is never under-resolved at card sizes).
    public static let cardThumbnailDesignWidth: CGFloat = 220
    public static let thumbnailAspectRatio: CGFloat = 16.0 / 9.0

    public static func style(for width: CGFloat) -> ProjectBrowserLayoutStyle {
        width < listStyleMaxWidth ? .list : .grid
    }
}

#if canImport(UIKit)
import SwiftUI
import PhotosUI
import TimelineKitCore
import TimelineKitUIShared

/// iOS 项目列表页（对齐剪映项目页）：
/// 网格卡片（占位缩略图 + 名称/创建时间/时长）+ 新建按钮 + 长按上下文菜单
/// （重命名 / 复制 / 置顶 / 删除）。点击卡片 push 该项目的编辑页。
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
                    LazyVGrid(columns: columns(for: proxy.size.width), spacing: 14) {
                        ForEach(libraryStore.projects) { project in
                            NavigationLink(value: project.id) {
                                ProjectCardView(project: project)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
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

    /// Even column counts keep the grid compatible with a fold and avoid
    /// awkward half-card splits as the window resizes.
    private func columns(for width: CGFloat) -> [GridItem] {
        let availableWidth = max(0, width - 32)
        let rawCount = max(2, Int(availableWidth / 160))
        let evenCount = min(6, rawCount - (rawCount % 2))
        return Array(
            repeating: GridItem(.flexible(), spacing: 12),
            count: max(2, evenCount)
        )
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

// MARK: - ProjectCardView

/// 项目卡片：占位缩略图 + 名称 / 创建时间 / 时长。
private struct ProjectCardView: View {
    let project: LibraryProject

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 占位色块缩略图（真实缩略图后置）。
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.16))
                Image(systemName: project.isPinned ? "pin.fill" : "film")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .frame(height: 92)

            Text(project.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            Text(Self.dateFormatter.string(from: project.createdAt))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))

            Text(Self.durationString(seconds: project.timeline.duration))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(8)
        .background(Color(white: 0.11))
        .cornerRadius(10)
        .hoverEffect(.highlight)
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
}

#endif

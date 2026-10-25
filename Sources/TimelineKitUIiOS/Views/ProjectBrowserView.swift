#if canImport(UIKit)
import SwiftUI
import TimelineKitCore
import TimelineKitUIShared

/// iOS 项目列表页（对齐剪映项目页）：
/// 网格卡片（占位缩略图 + 名称/创建时间/时长）+ 新建按钮 + 长按上下文菜单
/// （重命名 / 复制 / 置顶 / 删除）。点击卡片 push 该项目的编辑页。
public struct ProjectBrowserView: View {
    @Bindable var libraryStore: TimelineLibraryStore
    @State private var showCreateProject = false
    @State private var newProjectName = ""
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreateProject = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(for: UUID.self) { projectID in
            editorDestination(projectID: projectID)
        }
        // 新建项目：命名弹窗。
        .alert("新建项目", isPresented: $showCreateProject) {
            TextField("项目名称", text: $newProjectName, prompt: Text("未命名项目"))
            Button("创建") { createProject() }
            Button("取消", role: .cancel) { newProjectName = "" }
        } message: {
            Text("项目是一条时间线，你可以在其中排列和编辑媒体。")
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
            Text("点击右上角 + 创建一个新项目")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.45))
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
                project: project
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
            _ = try libraryStore.createProject(name: name)
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

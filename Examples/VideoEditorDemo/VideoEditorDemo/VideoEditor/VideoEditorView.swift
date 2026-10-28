//
//  VideoEditorView.swift
//  VideoEditorDemo
//
//  Created by xiaoyuan on 2026/7/1.
//

#if os(iOS)
import SwiftUI
import TimelineKitUIShared
import TimelineKitUIiOS

/// iOS Demo 入口：项目列表页为根（对齐剪映项目页）。
/// 打开/创建默认资源库（Documents/默认资源库.tlkbundle）后进入项目管理；
/// 点击项目卡片 push 编辑页。
struct VideoEditorView: View {
    @State private var libraryStore = TimelineLibraryStore()
    @State private var showOpenLibrayError: Bool = false
    @State private var openLibrayError: Error?
    @State private var layoutMode: EditorLayoutMode = ProcessInfo.processInfo.arguments
        .contains("-TimelineKitAdaptiveLayout") ? .adaptive : .legacy
    @State private var inspectorMode: EditorInspectorMode = ProcessInfo.processInfo.arguments
        .contains("-TimelineKitTabbedInspector") ? .tabbed : .legacy
    @State private var navigationPath: [UUID] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ProjectBrowserView(libraryStore: libraryStore)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("布局模式", selection: $layoutMode) {
                                Text("经典布局").tag(EditorLayoutMode.legacy)
                                Text("自适应布局").tag(EditorLayoutMode.adaptive)
                            }

                            Divider()

                            Picker("检查器模式", selection: $inspectorMode) {
                                Text("旧版工具条").tag(EditorInspectorMode.legacy)
                                Text("新版检查器").tag(EditorInspectorMode.tabbed)
                            }
                        } label: {
                            Label("布局模式", systemImage: "rectangle.3.group")
                        }
                        .accessibilityLabel("布局模式")
                    }
                }
                .task {
                    openLibray()
                    openSampleProjectIfRequested()
                }
                .alert("打开资源库失败", isPresented: $showOpenLibrayError, actions: {
                    Button {
                        let defaultLibraryURL = self.defaultLibraryURL
                        try? FileManager.default.removeItem(at: defaultLibraryURL)
                        try? libraryStore.createLibrary(at: defaultLibraryURL)
                    } label: {
                        Text("好的")
                    }
                    Button {
                        
                    } label: {
                        Text("好的")
                    }
                }, message: {
                    Text("资源库可能已经损坏，是否删除后重新创建")
                })


        }
        .environment(\.editorLayoutMode, layoutMode)
        .environment(\.editorInspectorMode, inspectorMode)
    }

    /// Debug-only entry for device automation: seeds a project and opens the
    /// editor with `-TimelineKitOpenSampleProject`.
    private func openSampleProjectIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-TimelineKitOpenSampleProject") else {
            return
        }
        if libraryStore.projects.isEmpty {
            _ = try? libraryStore.createProject(name: "Layout Test")
        }
        if navigationPath.isEmpty, let project = libraryStore.projects.first {
            navigationPath = [project.id]
        }
        #endif
    }

    func openLibray() {
        // 打开或创建默认资源库（iOS 沙盒 Documents，持久、随 App 备份）。
        let defaultLibraryURL = self.defaultLibraryURL
        do {
            if FileManager.default.fileExists(atPath: defaultLibraryURL.path) {
                try libraryStore.openLibrary(at: defaultLibraryURL)
            } else {
                try libraryStore.createLibrary(at: defaultLibraryURL)
            }
            
        } catch {
            openLibrayError = error
            showOpenLibrayError = true
        }
    }
    
    var defaultLibraryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let defaultLibraryURL = docs.appendingPathComponent("默认资源库.tlkbundle")
        return defaultLibraryURL
    }
}

#endif

#Preview {
    if #available(iOS 18.0, *) {
        VideoEditorView()
    } else {
        Text("Requires iOS 18")
    }
}

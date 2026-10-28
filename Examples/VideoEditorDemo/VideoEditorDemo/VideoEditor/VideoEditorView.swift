//
//  VideoEditorView.swift
//  VideoEditorDemo
//
//  Created by xiaoyuan on 2026/7/1.
//

#if os(iOS)
import SwiftUI
import UIKit
import AVFoundation
import TimelineKitCore
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
                    await openInspectorFixtureIfRequested()
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

    /// Debug-only inspector fixture. Creates a project with two image clips, a
    /// text clip, an audio clip, and a transition, then opens it directly.
    @MainActor
    private func openInspectorFixtureIfRequested() async {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments
            .contains("-TimelineKitOpenInspectorFixture") else {
            return
        }

        if let existing = libraryStore.projects.first(where: {
            $0.name == "Inspector Fixture"
        }) {
            navigationPath = [existing.id]
            return
        }

        guard let imageURL = makeInspectorFixtureImage(),
              let audioURL = makeInspectorFixtureAudio() else {
            return
        }

        defer {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: audioURL)
        }

        do {
            let project = try libraryStore.createProject(
                name: "Inspector Fixture"
            )
            guard let mainTrackID = project.timeline.tracks
                .first(where: { $0.isMainTrack })?.id else {
                return
            }

            let store = EditorStore(timeline: project.timeline)
            let importedImages = await libraryStore.addMedia(urls: [imageURL])
            let importedAudio = await libraryStore.addMedia(urls: [audioURL])

            guard let imageLibraryURL = importedImages.first else { return }

            _ = store.addVisualSegment(
                localURL: imageLibraryURL,
                nativeDuration: nil,
                targetTrackID: mainTrackID
            )
            _ = store.addVisualSegment(
                localURL: imageLibraryURL,
                nativeDuration: nil,
                targetTrackID: mainTrackID
            )
            _ = store.createNewTextSegment(
                defaultText: "Inspector Fixture",
                defaultDuration: 2.5
            )

            if let audioLibraryURL = importedAudio.first {
                _ = store.addAudioSegment(
                    localURL: audioLibraryURL,
                    nativeDuration: 2.0
                )
            }

            if let segments = store.timeline.mainTrack?.segments,
               segments.count >= 2 {
                _ = store.addTransition(
                    between: segments[0].id,
                    and: segments[1].id,
                    type: .fade,
                    duration: 0.5
                )
            }

            var updated = project
            updated.timeline = store.timeline
            try libraryStore.saveProject(updated)

            if let fixture = libraryStore.projects.first(where: {
                $0.name == "Inspector Fixture"
            }) {
                navigationPath = [fixture.id]
            }
        } catch {
            openLibrayError = error
            showOpenLibrayError = true
        }
        #endif
    }

    private func makeInspectorFixtureImage() -> URL? {
        let size = CGSize(width: 1280, height: 720)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let colors = [
                UIColor.systemBlue.cgColor,
                UIColor.systemPurple.cgColor
            ] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) else { return }

            context.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )

            ("Inspector Fixture" as NSString).draw(
                at: CGPoint(x: 80, y: 80),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 64, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
            )
        }

        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-fixture-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func makeInspectorFixtureAudio() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-fixture-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        ) else {
            return nil
        }

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings
            )
            let frameCount = AVAudioFrameCount(format.sampleRate * 2)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            ) else {
                return nil
            }
            buffer.frameLength = frameCount

            if let samples = buffer.floatChannelData?[0] {
                let sampleRate: Double = format.sampleRate
                let frequency: Double = 440
                let amplitude: Double = 0.1

                for index in 0..<Int(frameCount) {
                    let time: Double = Double(index) / sampleRate
                    let phase: Double = 2 * Double.pi * frequency * time
                    samples[index] = Float(sin(phase) * amplitude)
                }
            }

            try file.write(from: buffer)
            return url
        } catch {
            return nil
        }
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

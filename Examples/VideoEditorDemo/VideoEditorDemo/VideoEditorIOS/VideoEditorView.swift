//
//  VideoEditorView.swift
//  VideoEditorDemo
//
//  Created by xiaoyuan on 2026/7/1.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import TimelineKitCore
import TimelineKitUIShared
import TimelineKitUIiOS

struct VideoEditorView: View {
    @State private var editorStore: EditorStore?
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isShowingPicker = false
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "film.stack")
                .font(.system(size: 54, weight: .regular))
                .foregroundStyle(.blue)

            Text("TimelineKit Demo")
                .font(.title2.bold())

            Text("Choose photos or videos from your library to create an editable timeline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button {
                isShowingPicker = true
            } label: {
                Label(isImporting ? "Importing..." : "Choose Media", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isImporting)
            .padding(.horizontal, 32)

            if isImporting {
                ProgressView()
                    .controlSize(.large)
            }

            Spacer()
        }
        .photosPicker(
            isPresented: $isShowingPicker,
            selection: $selectedItems,
            maxSelectionCount: 20,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        )
        .onChange(of: selectedItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await openEditor(with: items) }
        }
        .fullScreenCover(item: $editorStore) { es in
            NavigationStack {
                ClipEditorView(
                    store: es,
                    onDraftSave: { draftID, timeline in
                        _ = DraftStore.save(timeline)
                    },
                    onExport: { exportedJSON, url, image in
                        print("Exported timeline JSON bytes:", exportedJSON.count)
                        print("Exported video:", url)
                    }
                )
            }
        }
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            presenting: errorMessage
        ) { _ in
            Button("OK") { errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private func openEditor(with items: [PhotosPickerItem]) async {
        await MainActor.run {
            isImporting = true
            errorMessage = nil
        }
        defer {
            Task { @MainActor in
                isImporting = false
                selectedItems = []
            }
        }

        do {
            let urls = try await loadMediaURLs(from: items)
            let timeline = try await TimelineImporter.importingMedia(
                from: urls,
                canvas: EditorCanvas(width: 720, height: 1280, fps: 30),
                imageDuration: 3,
                productName: "VideoEditorDemo"
            )
            await MainActor.run {
                editorStore = EditorStore(timeline: timeline, videoURL: nil)
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadMediaURLs(from items: [PhotosPickerItem]) async throws -> [URL] {
        var urls: [URL] = []

        for item in items {
            if let movie = try? await item.loadTransferable(type: DemoMovie.self) {
                urls.append(movie.url)
                continue
            }

            if let data = try? await item.loadTransferable(type: Data.self) {
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let url = try writeTemporaryMedia(data: data, preferredExtension: ext)
                urls.append(url)
            }
        }

        guard !urls.isEmpty else {
            throw DemoImportError.noSupportedMedia
        }
        return urls
    }

    private func writeTemporaryMedia(data: Data, preferredExtension ext: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoEditorDemoImports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try data.write(to: url, options: .atomic)
        return url
    }
}

private struct DemoMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VideoEditorDemoImports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: received.file, to: destination)
            return DemoMovie(url: destination)
        }
    }
}

private enum DemoImportError: LocalizedError {
    case noSupportedMedia

    var errorDescription: String? {
        switch self {
        case .noSupportedMedia:
            "Please choose at least one supported photo or video."
        }
    }
}

#Preview {
    if #available(iOS 18.0, *) {
        VideoEditorView()
    } else {
        Text("Requires iOS 18")
    }
}

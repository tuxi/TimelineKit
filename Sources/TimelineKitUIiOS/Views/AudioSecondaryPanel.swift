#if canImport(UIKit)
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import TimelineKitUIShared
import TimelineKitCore

/// V3 audio-feature-spec §2.1: secondary panel for the `.audio` bottom toolbar
/// category. Hosts three stubs (提取音频 / 本地音乐 / 音效) and owns the picker
/// presentation + async pipeline for the first two.
///
/// Composition:
/// - 「提取音频」 → SwiftUI `.photosPicker(matching: .videos)` → AudioExtractor → addAudioSegment
/// - 「本地音乐」 → SwiftUI `.fileImporter([.audio])` → AudioImporter → addAudioSegment
/// - 「音效」 → disabled (素材库 v3 不做)
///
/// v3 P3 (audio-feature-spec §10.3): when a `.audio` segment is selected, the
/// dispatch in ClipEditorView routes to `AudioEditPanel` directly — this panel
/// only ever shows the import buttons. (P0 used to host a temporary speed
/// slider here; that's been removed now that AudioEditPanel owns it.)
struct AudioSecondaryPanel: View {

    let store: EditorStore
    var targetTrackID: UUID? = nil
    var onTargetConsumed: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var showVideoPicker = false
    @State private var videoPickerItem: PhotosPickerItem?
    @State private var showAudioImporter = false
    @State private var task: TaskState = .idle
    @State private var errorMessage: String?

    static let height: CGFloat = 88

    enum TaskState: Equatable {
        case idle
        case processing(String)
    }

    var body: some View {
        Group {
            importButtonsContent
        }
        .frame(height: Self.height)
        .background(Color(white: 0.13))
        .overlay(alignment: .top) {
            Divider().background(Color.white.opacity(0.08))
        }
        .photosPicker(
            isPresented: $showVideoPicker,
            selection: $videoPickerItem,
            matching: .videos,
            photoLibrary: .shared()
        )
        .onChange(of: videoPickerItem) { _, item in
            guard let item else { return }
            Task { await handleVideoExtraction(item: item) }
        }
        .fileImporter(
            isPresented: $showAudioImporter,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let pickedURL = urls.first else { return }
                Task { await handleAudioImport(pickedURL: pickedURL) }
            case .failure(let err):
                errorMessage = err.localizedDescription
            }
        }
        .alert(
            "音频处理失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            presenting: errorMessage
        ) { _ in
            Button("确定") { errorMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Content branches

    @ViewBuilder
    private var importButtonsContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                toolButton(
                    "提取音频",
                    icon: "waveform.path.badge.minus",
                    enabled: task == .idle
                ) { showVideoPicker = true }

                toolButton(
                    "本地音乐",
                    icon: "music.note.list",
                    enabled: task == .idle
                ) { showAudioImporter = true }

                toolButton(
                    "音效",
                    icon: "speaker.wave.2.bubble",
                    enabled: false
                ) {}

                if case .processing(let msg) = task {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text(msg)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.75))
                    }
                    .padding(.leading, 8)
                }

                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Pipelines

    private func handleVideoExtraction(item: PhotosPickerItem) async {
        defer { Task { @MainActor in videoPickerItem = nil } }
        await MainActor.run { task = .processing("提取音频中…") }

        guard let movie = try? await item.loadTransferable(type: VideoTransferable.self) else {
            await MainActor.run {
                task = .idle
                errorMessage = "无法读取视频文件"
            }
            return
        }

        let timelineID = await MainActor.run { store.timeline.id }
        let assetID = UUID()
        let outputURL: URL
        do {
            outputURL = try AssetDownloadManager.shared.reserveLocalURL(
                assetID: assetID,
                extension: "m4a",
                timelineID: timelineID
            )
        } catch {
            await MainActor.run {
                task = .idle
                errorMessage = "无法分配输出路径：\(error.localizedDescription)"
            }
            return
        }

        do {
            let duration = try await AudioExtractor.shared.extract(
                from: movie.url,
                to: outputURL
            )
            await MainActor.run {
                _ = store.addAudioSegment(
                    localURL: outputURL,
                    nativeDuration: duration,
                    targetTrackID: targetTrackID
                )
                if targetTrackID != nil {
                    onTargetConsumed?()
                }
                task = .idle
            }
        } catch let err as AudioExtractor.Failure {
            await MainActor.run {
                task = .idle
                errorMessage = err.errorDescription ?? "提取失败"
            }
        } catch {
            await MainActor.run {
                task = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleAudioImport(pickedURL: URL) async {
        await MainActor.run { task = .processing("导入音乐中…") }

        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        let timelineID = await MainActor.run { store.timeline.id }
        let assetID = UUID()
        let ext = pickedURL.pathExtension.isEmpty ? "m4a" : pickedURL.pathExtension
        let outputURL: URL
        do {
            outputURL = try AssetDownloadManager.shared.reserveLocalURL(
                assetID: assetID,
                extension: ext,
                timelineID: timelineID
            )
        } catch {
            await MainActor.run {
                task = .idle
                errorMessage = "无法分配输出路径：\(error.localizedDescription)"
            }
            return
        }

        do {
            let duration = try await AudioImporter.shared.import(
                from: pickedURL,
                to: outputURL
            )
            await MainActor.run {
                _ = store.addAudioSegment(
                    localURL: outputURL,
                    nativeDuration: duration,
                    targetTrackID: targetTrackID
                )
                if targetTrackID != nil {
                    onTargetConsumed?()
                }
                task = .idle
            }
        } catch let err as AudioImporter.Failure {
            await MainActor.run {
                task = .idle
                errorMessage = err.errorDescription ?? "导入失败"
            }
        } catch {
            await MainActor.run {
                task = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Button

    private func toolButton(
        _ label: String,
        icon: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .frame(width: 44, height: 36)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(label)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            .foregroundStyle(enabled ? Color.white.opacity(0.85) : Color.white.opacity(0.35))
            .frame(width: 60)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
#endif

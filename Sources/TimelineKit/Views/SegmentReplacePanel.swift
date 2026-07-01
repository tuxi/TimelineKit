#if canImport(UIKit)
import SwiftUI
import PhotosUI
import AVFoundation

// MARK: - SegmentReplacePanel

/// Secondary panel shown under the `.clip` toolbar category when a main-track
/// segment is selected.  Currently exposes "分割" (stub) and "替换素材".
struct SegmentReplacePanel: View {

    let segmentID: UUID
    @Bindable var store: EditorStore
    var onDismiss: (() -> Void)? = nil

    @State private var showPicker = false
    @State private var selectedItem: PhotosPickerItem?
    @State private var pendingVideoReplace: PendingVideo?
    @State private var showInsufficientDurationAlert = false
    // v3 P2 (audio-feature-spec §9): detach-audio state machine.
    @State private var isDetachingAudio = false
    @State private var detachErrorMessage: String?

    /// True when the selected segment is an image (not a video).
    /// True when the source video segment has its original audio muted — which is
    /// also the "已分离过" signal (we set isMuted on detach). Drives the disabled
    /// state of the "分离音视频" button per §9.2.
    private var isVideoAudioMuted: Bool {
        guard let seg = store.timeline.segment(id: segmentID),
              case .video(let c) = seg.content else { return false }
        return c.isMuted
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                // 分割
                panelItem("分割", icon: "scissors.badge.ellipsis") {
                    store.splitSegment(id: segmentID, at: store.selection.playheadTime)
                }

                // 删除
                panelItem("删除", icon: "trash") {
                    store.deleteSegment(id: segmentID)
                }

                // 替换素材
                panelItem("替换素材", icon: "arrow.triangle.2.circlepath") {
                    showPicker = true
                }

                // v3 P2 (audio-feature-spec §9): detach audio.
                panelItem(
                    "分离音视频",
                    icon: "waveform.path.badge.minus",
                    enabled: !isVideoAudioMuted && !isDetachingAudio
                ) {
                    Task { await runDetachAudio() }
                }

                // v3 P3 (audio-feature-spec §11): toggle the segment's native audio.
                // Icon flips on/off; tap immediately commits via setVideoMuted.
                panelItem(
                    isVideoAudioMuted ? "原音 关" : "原音 开",
                    icon: isVideoAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                ) {
                    store.setVideoMuted(segmentID: segmentID, isMuted: !isVideoAudioMuted)
                }

                if isDetachingAudio {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("分离中…")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.75))
                    }
                    .padding(.leading, 4)
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
        .frame(height: EditorSecondaryToolPanel.height)
        .background(Color(white: 0.13))
        .overlay(alignment: .top) {
            Divider().background(Color.white.opacity(0.08))
        }
        .alert(
            "分离音视频失败",
            isPresented: Binding(
                get: { detachErrorMessage != nil },
                set: { if !$0 { detachErrorMessage = nil } }
            ),
            presenting: detachErrorMessage
        ) { _ in
            Button("确定") { detachErrorMessage = nil }
        } message: { msg in
            Text(msg)
        }
        .photosPicker(
            isPresented: $showPicker,
            selection: $selectedItem,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        )
        .onChange(of: selectedItem) { _, item in
            guard let item else { return }
            Task { await loadAndReplace(item: item) }
        }
        .fullScreenCover(item: $pendingVideoReplace) { pending in
            VideoTrimSelectorSheet(
                videoURL: pending.url,
                nativeDuration: pending.nativeDuration,
                targetDuration: pending.targetDuration
            ) { clipInTime in
                store.replaceSegmentMaterial(
                    segmentID:      segmentID,
                    localURL:       pending.url,
                    nativeDuration: pending.nativeDuration,
                    clipInTime:     clipInTime
                )
            }
        }
        .alert("素材时长不足", isPresented: $showInsufficientDurationAlert) {
            Button("好") { }
        } message: {
            Text("请选择更长的视频素材")
        }
    }

    // MARK: - Private

    private func panelItem(
        _ label: String,
        icon: String,
        enabled: Bool = true,
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

    /// v3 P2 (audio-feature-spec §9.5): drives the async detach pipeline and
    /// surfaces user-facing errors. Skipped re-entrancy via `isDetachingAudio`
    /// (the button is also disabled while it's true).
    private func runDetachAudio() async {
        await MainActor.run { isDetachingAudio = true }
        defer { Task { @MainActor in isDetachingAudio = false } }
        do {
            _ = try await store.detachAudio(fromVideoSegmentID: segmentID)
        } catch let err as AudioExtractor.Failure {
            await MainActor.run { detachErrorMessage = err.errorDescription ?? "提取失败" }
        } catch let err as EditorStore.DetachAudioError {
            await MainActor.run { detachErrorMessage = err.errorDescription ?? "分离失败" }
        } catch {
            await MainActor.run { detachErrorMessage = error.localizedDescription }
        }
    }

    /// Load media from PhotosPicker item, apply duration-based routing, then replace.
    private func loadAndReplace(item: PhotosPickerItem) async {
        // Try video first (returns a file URL for video content).
        if let movie = try? await item.loadTransferable(type: VideoTransferable.self) {
            let native = await avDuration(of: movie.url)

            guard let native else {
                // Duration unreadable — fall back to direct replace.
                await MainActor.run {
                    store.replaceSegmentMaterial(
                        segmentID: segmentID, localURL: movie.url, nativeDuration: nil
                    )
                }
                return
            }

            let targetDuration = await MainActor.run {
                store.timeline.segment(id: segmentID)?.targetRange.duration ?? 0
            }

            if native < targetDuration - 0.01 {
                // New video is shorter than the slot — reject.
                await MainActor.run { showInsufficientDurationAlert = true }
                return
            }

            if native > targetDuration + 0.01 {
                // New video is longer — present trim selector so user picks in-point.
                await MainActor.run {
                    pendingVideoReplace = PendingVideo(
                        url: movie.url,
                        nativeDuration: native,
                        targetDuration: targetDuration
                    )
                }
                return
            }

            // Durations match — direct replace, sourceRange stays nil (full asset).
            await MainActor.run {
                store.replaceSegmentMaterial(
                    segmentID: segmentID, localURL: movie.url, nativeDuration: native
                )
            }
            return
        }

        // Fallback: image — save to temp file so AVComposition can read it.
        if let data = try? await item.loadTransferable(type: Data.self) {
            let ext  = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try? data.write(to: dest)
            await MainActor.run {
                store.replaceSegmentMaterial(
                    segmentID:      segmentID,
                    localURL:       dest,
                    nativeDuration: nil       // static image: no duration cap
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
}

// MARK: - PendingVideo

private struct PendingVideo: Identifiable {
    let id = UUID()
    let url: URL
    let nativeDuration: Double
    let targetDuration: Double
}

// MARK: - Transferable helpers

/// Wraps a video URL obtained from PhotosPicker transferable load.
struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoTransferable(url: dest)
        }
    }
}
#endif

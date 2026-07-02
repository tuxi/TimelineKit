#if canImport(UIKit)
import SwiftUI
import UIKit
import TimelineKitCore
import TimelineKitUIShared

/// Full-screen export progress / result page.
/// Pushed onto the existing NavigationStack from ClipEditorView.
public struct ExportResultView: View {
    @State private var exporter = VideoExporter()
    let store: EditorStore
    let onDismiss: (() -> Void)?
    /// Called once after the video has been saved to the photo library.
    /// Receives the `ServerTimelineSchema` JSON of the current editor timeline
    /// so the caller can persist the edit state and update the preview.
    let onExport: ((Data, URL, UIImage) -> Void)?

    @Environment(\.dismiss) private var dismiss
    
    @State var showPlayer = false

    public init(store: EditorStore, onDismiss: (() -> Void)? = nil, onExport: ((Data, URL, UIImage) -> Void)? = nil) {
        self.store = store
        self.onDismiss = onDismiss
        self.onExport = onExport
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                if exporter.isCompleted {
                    completedContent
                } else {
                    exportingContent
                }

                Spacer()

                // Bottom buttons
                bottomArea
            }
            .padding(.horizontal, 24)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task {
            do {
                await exporter.export(timeline: store.timeline)
                // After a successful save-to-library, fire the callback with the current
                // editor timeline serialised as ServerTimelineSchema JSON.
                // DreamStudioView uses this to update its in-memory VideoTimeline and
                // persist the user-edit flag so bootstrapFromAPI won't overwrite it.
                if exporter.isCompleted,
                   let exportURL = exporter.savedVideoURL,
                    let cover = exporter.coverImage {
                    let jsonData = try TimelineExporter.exportJSON(store.timeline)
                    try await exporter.saveToPhotoLibrary(url: exportURL)
                    onExport?(jsonData, exportURL, cover)
//                    showPlayer = true
                }
            } catch {
                print("ExportResultView.task导出视频失败:", error.localizedDescription)
            }
        }
//        .fullScreenCover(isPresented: $showPlayer) {
//            
//            FullScreenVideoPlayer(url: exporter.savedVideoURL!, title: "")
//        }
    }

    // MARK: - Exporting state

    @ViewBuilder
    private var exportingContent: some View {
        VStack(spacing: 24) {
            Text("努力导出中")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
            
            Text("请保持屏幕一直亮起，不要锁屏或切换 APP")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.82))

            // Cover image — placeholder and real image share the same frame so the
            // layout doesn't jump when the first-frame thumbnail arrives.
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.08))

                if let img = exporter.coverImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
//            .aspectRatio( 9.0 / 16.0, contentMode: .fit)
            .frame(maxHeight: 260)

            // Progress percentage
            Text(String(format: "%.1f%%", exporter.progress * 100))
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
    }

    // MARK: - Completed state

    @ViewBuilder
    private var completedContent: some View {
        VStack(spacing: 20) {
            if let img = exporter.coverImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxHeight: 260)
            }

            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.green)

                Text("已保存到相册")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
    }

    // MARK: - Bottom

    @ViewBuilder
    private var bottomArea: some View {
        VStack(spacing: 12) {
            if exporter.isCompleted {
                Button {
                    if let url = URL(string: "photos-redirect://") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("点击查看")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.red)
                        )
                }
                .buttonStyle(.plain)
            }

            Button {
                onDismiss?() ?? dismiss()
            } label: {
                Text("再剪一个")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 32)
    }
}
#endif

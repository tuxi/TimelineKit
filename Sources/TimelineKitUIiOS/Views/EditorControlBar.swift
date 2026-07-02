#if canImport(UIKit)
import SwiftUI
import TimelineKitUIShared

/// Playback controls and tool mode switcher shown between preview and track area.
struct EditorControlBar: View {
    var store: EditorStore

    /// V5 fullscreen-preview-spec §3.4：全屏预览按钮触发回调。由 ClipEditorView
    /// 拥有 `@State showFullScreenPreview` 并通过 `.fullScreenCover` 呈现
    /// `FullScreenPreviewView`。本视图仅负责发起请求。
    var onRequestFullScreenPreview: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            Spacer()

            // Previous segment
            controlButton(icon: "backward.end.fill") {
                seekToPreviousSegment()
            }

            // Play / Pause — enlarged for primary action prominence and reliable touch.
            controlButton(
                icon: store.isPlaying ? "pause.fill" : "play.fill",
                iconSize: 22,
                width: 60,
                height: 52
            ) {
                store.togglePlayback()
            }

            // Next segment
            controlButton(icon: "forward.end.fill") {
                seekToNextSegment()
            }

            Spacer()

            // V5 fullscreen-preview-spec §3.4: 全屏预览入口
            // 始终可见；空 timeline 时按钮禁用。与同栏其他按钮共享 controlButton 样式。
            controlButton(
                icon: "arrow.up.left.and.arrow.down.right",
                iconSize: 16
            ) {
                onRequestFullScreenPreview()
            }
            .disabled(isTimelineEmpty)
            .opacity(isTimelineEmpty ? 0.4 : 1.0)
            .accessibilityLabel("全屏预览")
        }
    }

    /// 用于禁用全屏按钮：timeline 没有任何段时无内容可预览。
    private var isTimelineEmpty: Bool {
        store.timeline.tracks.allSatisfy { $0.segments.isEmpty }
    }

    // MARK: - Private

    private func controlButton(
        icon: String,
        iconSize: CGFloat = 18,
        width: CGFloat = 44,
        height: CGFloat = 44,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func seekToPreviousSegment() {
        let t = store.selection.playheadTime
        let starts = store.timeline.tracks
            .filter { $0.kind == .video }
            .flatMap { $0.segments.map { $0.targetRange.start } }
            .sorted()
        let prev = starts.last(where: { $0 < t - 0.1 }) ?? 0
        store.seek(to: prev)
    }

    private func seekToNextSegment() {
        let t = store.selection.playheadTime
        let starts = store.timeline.tracks
            .filter { $0.kind == .video }
            .flatMap { $0.segments.map { $0.targetRange.start } }
            .sorted()
        if let next = starts.first(where: { $0 > t + 0.01 }) {
            store.seek(to: next)
        }
    }
}
#endif

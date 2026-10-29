import SwiftUI
import TimelineKitUIShared

/// Playback controls and tool mode switcher shown between preview and track area.
public struct EditorControlBar: View {
    var store: EditorStore

    /// V5 fullscreen-preview-spec §3.4：全屏预览按钮触发回调。由 ClipEditorView
    /// 拥有 `@State showFullScreenPreview` 并通过 `.fullScreenCover` 呈现
    /// `FullScreenPreviewView`。本视图仅负责发起请求。
    var onRequestFullScreenPreview: () -> Void = {}
    /// When set, the bar controls the browser asset preview instead of the timeline.
    var browserPlayback: BrowserAssetPlaybackController?

    public init(
        store: EditorStore,
        onRequestFullScreenPreview: @escaping () -> Void = {},
        browserPlayback: BrowserAssetPlaybackController? = nil
    ) {
        self.store = store
        self.onRequestFullScreenPreview = onRequestFullScreenPreview
        self.browserPlayback = browserPlayback
    }

    public var body: some View {
        Group {
            if let browserPlayback {
                browserControls(browserPlayback)
            } else {
                timelineControls
            }
        }
    }

    private var timelineControls: some View {
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

    private func browserControls(
        _ playback: BrowserAssetPlaybackController
    ) -> some View {
        HStack(spacing: 10) {
            controlButton(
                icon: playback.isPlaying ? "pause.fill" : "play.fill",
                iconSize: 20,
                width: 52,
                height: 44
            ) {
                playback.togglePlayback()
            }
            .disabled(playback.duration <= 0 || playback.playItem == nil)
            .opacity(
                playback.duration <= 0 || playback.playItem == nil
                ? 0.4
                : 1
            )

            if playback.duration > 0 {
                Text(timeString(playback.currentTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 38, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { min(playback.currentTime, playback.duration) },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(playback.duration, 0.01)
                )
                .tint(.white)
                .accessibilityLabel("素材预览进度")

                Text(timeString(playback.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 38, alignment: .leading)
            } else {
                Text("图片素材")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
            }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
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

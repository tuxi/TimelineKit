#if canImport(UIKit)
import SwiftUI

// MARK: - AudioSegmentActionPanel

/// V4 unified interaction spec: quick-action bar shown when an audio segment is
/// selected via track tap. Keeps剪辑 operations accessible without blocking the
/// timeline. The full AudioEditPanel is opened by tapping "编辑音频".
struct AudioSegmentActionPanel: View {

    let segmentID: UUID
    @Bindable var store: EditorStore
    var onDismiss: (() -> Void)? = nil

    private var audioContent: SegmentContent.AudioContent? {
        guard let seg = store.timeline.segment(id: segmentID),
              case .audio(let c) = seg.content else { return nil }
        return c
    }

    private var isMuted: Bool { audioContent?.isMuted ?? false }

    /// v4 (audio-track-controls-spec §3.4): destructive buttons disabled on locked tracks.
    private var trackIsLocked: Bool {
        store.timeline.track(containing: segmentID)?.isLocked ?? false
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                // 编辑音频 → opens full AudioEditPanel
                panelItem("编辑音频", icon: "waveform", enabled: true) {
                    store.selection.editingSegmentID = segmentID
                }

                // 分割
                panelItem("分割", icon: "scissors.badge.ellipsis", enabled: !trackIsLocked) {
                    store.splitSegment(id: segmentID, at: store.selection.playheadTime)
                }

                // 删除
                panelItem("删除", icon: "trash", enabled: !trackIsLocked) {
                    store.deleteSegment(id: segmentID)
                }

                // 静音 / 取消静音
                panelItem(
                    isMuted ? "取消静音" : "静音",
                    icon: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    enabled: true
                ) {
                    store.muteAudioSegment(id: segmentID, isMuted: !isMuted)
                }

                // 调速
                panelItem("调速", icon: "gauge.with.needle", enabled: false) {}

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
    }

    // MARK: - Button

    private func panelItem(
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

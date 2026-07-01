#if canImport(UIKit)
import SwiftUI

// MARK: - TextSegmentActionPanel

/// V4 unified interaction spec: quick-action bar shown when a text or subtitle
/// segment is selected via track tap. The full TextEditPanel is opened by
/// tapping "样式".
struct TextSegmentActionPanel: View {

    let segmentID: UUID
    @Bindable var store: EditorStore
    var onDismiss: (() -> Void)? = nil

    @State private var showBulkConfirm = false

    private var isSubtitle: Bool {
        store.timeline.segment(id: segmentID)?.isSubtitle ?? false
    }

    private var isTextOrSubtitle: Bool {
        guard let seg = store.timeline.segment(id: segmentID) else { return false }
        return seg.isSubtitle || seg.isText
    }

    /// v4 (audio-track-controls-spec §3.4): destructive buttons disabled on locked tracks.
    private var trackIsLocked: Bool {
        store.timeline.track(containing: segmentID)?.isLocked ?? false
    }

    /// v4 (bulk-style-apply-spec §4.1): count of OTHER same-kind segments on
    /// the same track. The bulk button is disabled when this is 0.
    private var bulkTargetCount: Int {
        guard let track = store.timeline.track(containing: segmentID) else { return 0 }
        let isSub = isSubtitle
        return track.segments.reduce(0) { acc, seg in
            guard seg.id != segmentID else { return acc }
            switch seg.content {
            case .subtitle where isSub: return acc + 1
            case .text     where !isSub: return acc + 1
            default: return acc
            }
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                // 样式 → opens full TextEditPanel
                panelItem("样式", icon: "textformat", enabled: true) {
                    store.selection.editingSegmentID = segmentID
                }

                // v4 (text-typography-spec §4.3): copy/paste style
                panelItem("复制样式", icon: "doc.on.clipboard", enabled: isTextOrSubtitle) {
                    store.copyStyle(segmentID: segmentID)
                    ToastContext.shared.show("已复制样式", icon: "doc.on.clipboard",
                        style: .success, duration: 1.5, position: .top)
                }

                panelItem("粘贴样式", icon: "arrow.turn.down.right", enabled: store.canPasteStyle(toSegmentID: segmentID)) {
                    store.pasteStyle(segmentID: segmentID)
                    ToastContext.shared.show("已粘贴样式", icon: "arrow.turn.down.right",
                        style: .success, duration: 1.5, position: .top)
                }

                // v4 (bulk-style-apply-spec §4.1): 应用到本轨同类
                panelItem(
                    "应用到本轨同类",
                    icon: "doc.on.doc",
                    enabled: bulkTargetCount > 0 && !trackIsLocked
                ) {
                    showBulkConfirm = true
                }

                // 文本朗读 → only for subtitle segments
                panelItem("文本朗读", icon: "speaker.wave.2", enabled: isSubtitle) {
                    store.ttsConfigSheetTargets = [segmentID]
                }

                // 分割
                panelItem("分割", icon: "scissors.badge.ellipsis", enabled: !trackIsLocked) {
                    store.splitSegment(id: segmentID, at: store.selection.playheadTime)
                }

                // 删除
                panelItem("删除", icon: "trash", enabled: !trackIsLocked) {
                    store.deleteSegment(id: segmentID)
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
        // v4 (bulk-style-apply-spec §2.5): two-step confirmation.
        .alert("应用到本轨同类", isPresented: $showBulkConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认应用") { performBulkApply() }
        } message: {
            Text("将当前样式应用到本条轨道的其他 \(bulkTargetCount) 个同类片段。此操作可撤销。")
        }
    }

    private func performBulkApply() {
        guard let track = store.timeline.track(containing: segmentID) else { return }
        let count = store.applyStyleToTrackSegmentsOfKind(
            trackID:               track.id,
            sourceSegmentID:       segmentID,
            includePositionFields: false
        )
        if count > 0 {
            ToastContext.shared.show(
                "已应用到 \(count) 个片段",
                icon: "checkmark.circle",
                style: .success,
                duration: 2.0,
                position: .top
            )
        }
    }

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

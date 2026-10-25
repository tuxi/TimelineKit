#if canImport(UIKit)
import SwiftUI
import TimelineKitCore
import TimelineKitUIShared

/// Presentation-independent route for the editor's tool panels.
///
/// The same route can be rendered in the phone's bottom overlay or in the
/// larger workspace inspector. The route mirrors the existing priority order:
/// full segment editing, segment shortcuts, then category defaults.
enum EditorToolPanelRoute {
    case empty
    case textEdit(segmentID: UUID)
    case audioEdit(segmentID: UUID)
    case textActions(segmentID: UUID)
    case clipActions(segmentID: UUID)
    case adjust(segmentID: UUID)
    case animation(segmentID: UUID)
    case audioActions(segmentID: UUID)
    case audioDefault(targetTrackID: UUID?)
    case category(EditorToolCategory)

    var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }

    /// The text editor needs a height cap in the bottom overlay; other panels
    /// size themselves.
    var maxHeightFraction: CGFloat? {
        if case .textEdit = self { return 0.45 }
        return nil
    }
}

/// Shared tool panel content used by the bottom overlay and the inspector.
struct EditorToolPanelContent: View {
    let route: EditorToolPanelRoute
    let store: EditorStore
    var onDismiss: () -> Void = {}
    var onAudioTargetConsumed: () -> Void = {}

    var body: some View {
        switch route {
        case .empty:
            emptyState

        case .textEdit(let segmentID):
            TextEditPanel(segmentID: segmentID, store: store)

        case .audioEdit(let segmentID):
            AudioEditPanel(segmentID: segmentID, store: store)

        case .textActions(let segmentID):
            TextSegmentActionPanel(
                segmentID: segmentID,
                store: store,
                onDismiss: onDismiss
            )

        case .clipActions(let segmentID):
            SegmentReplacePanel(
                segmentID: segmentID,
                store: store,
                onDismiss: onDismiss
            )

        case .adjust(let segmentID):
            ColorAdjustmentPanel(
                segmentID: segmentID,
                store: store,
                onDismiss: onDismiss
            )

        case .animation(let segmentID):
            AnimationPickerSheet(
                segmentID: segmentID,
                store: store,
                onDismiss: onDismiss
            )

        case .audioActions(let segmentID):
            AudioSegmentActionPanel(
                segmentID: segmentID,
                store: store,
                onDismiss: onDismiss
            )

        case .audioDefault(let targetTrackID):
            AudioSecondaryPanel(
                store: store,
                targetTrackID: targetTrackID,
                onTargetConsumed: onAudioTargetConsumed,
                onDismiss: onDismiss
            )

        case .category(let category):
            EditorSecondaryToolPanel(
                category: category,
                store: store,
                onDismiss: onDismiss
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.35))
            Text("选择片段或工具后显示属性")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

/// Inspector presentation for compact widths. The content is the same
/// `EditorToolPanelContent` used by the bottom overlay; a later milestone can
/// swap this sheet for an inline column without touching panel behavior.
struct EditorInspectorSheet: View {
    let route: EditorToolPanelRoute
    let store: EditorStore
    var onAudioTargetConsumed: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                EditorToolPanelContent(
                    route: route,
                    store: store,
                    onDismiss: { dismiss() },
                    onAudioTargetConsumed: onAudioTargetConsumed
                )
                .padding(.vertical, 8)
            }
            .background(Color(white: 0.08))
            .navigationTitle("检查器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
#endif

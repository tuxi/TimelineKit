#if canImport(UIKit)
import SwiftUI
import TimelineKitUIShared

/// Inline inspector column for the regular-width workspace.
///
/// The panel body is the same `EditorToolPanelContent` used by the compact
/// bottom overlay and inspector sheet.
struct EditorWorkspaceInspector: View {
    let route: EditorToolPanelRoute
    let store: EditorStore
    @Binding var isCollapsed: Bool
    let width: CGFloat
    var onDismiss: () -> Void = {}
    var onAudioTargetConsumed: () -> Void = {}

    var body: some View {
        Group {
            if isCollapsed {
                collapsedRail
            } else {
                expanded
            }
        }
        .background(Color(white: 0.10))
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("检查器")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))

                Spacer(minLength: 8)

                Button {
                    withAnimation(.spring(duration: 0.25)) {
                        isCollapsed = true
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起检查器")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                EditorToolPanelContent(
                    route: route,
                    store: store,
                    onDismiss: onDismiss,
                    onAudioTargetConsumed: onAudioTargetConsumed
                )
                .padding(.vertical, 8)
            }
        }
        .frame(width: width)
    }

    private var collapsedRail: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.spring(duration: 0.25)) {
                    isCollapsed = false
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("展开检查器")

            Text("检查器")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .frame(width: 14, height: 56)

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .frame(width: 44)
    }
}
#endif

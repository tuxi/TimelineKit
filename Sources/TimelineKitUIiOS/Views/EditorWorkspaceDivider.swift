#if canImport(UIKit)
import SwiftUI

/// Draggable divider between the workspace preview row and the timeline row.
struct EditorWorkspaceDivider: View {
    @Binding var topHeight: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var dragStartHeight: CGFloat?

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
                .frame(height: 1)

            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 36, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartHeight == nil {
                        dragStartHeight = topHeight
                    }
                    let start = dragStartHeight ?? topHeight
                    topHeight = min(
                        max(start + value.translation.height, range.lowerBound),
                        range.upperBound
                    )
                }
                .onEnded { _ in
                    dragStartHeight = nil
                }
        )
        .hoverEffect(.highlight)
        .accessibilityLabel("调整预览与时间线高度")
    }
}
#endif

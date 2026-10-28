#if canImport(UIKit)
import SwiftUI

/// Compact landscape tool strip. Lives at the bottom of the timeline column and
/// toggles the inline tool panel, matching the portrait bottom toolbar.
struct EditorLandscapeToolStrip: View {
    @Binding var activeCategory: EditorToolCategory?

    static let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditorToolCategory.allCases.filter(\.isEnabled)) { category in
                let isActive = activeCategory == category

                Button {
                    withAnimation(.spring(duration: 0.25)) {
                        activeCategory = isActive ? nil : category
                    }
                } label: {
                    Image(systemName: category.icon)
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(
                            isActive
                            ? Color.yellow
                            : Color.white.opacity(0.8)
                        )
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(
                                    isActive
                                    ? Color.white.opacity(0.10)
                                    : Color.clear
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel(category.rawValue)
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .background(Color(white: 0.11))
        .overlay(alignment: .top) {
            Divider().background(Color.white.opacity(0.08))
        }
    }
}
#endif

#if canImport(UIKit)
import SwiftUI

/// Compact landscape tool strip. Lives at the bottom of the timeline column and
/// only opens the tool sheet when the user explicitly selects a category.
struct EditorLandscapeToolStrip: View {
    @Binding var activeCategory: EditorToolCategory?
    var onSelect: (EditorToolCategory) -> Void

    static let height: CGFloat = 48

    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditorToolCategory.allCases.filter(\.isEnabled)) { category in
                let isActive = activeCategory == category

                Button {
                    activeCategory = category
                    onSelect(category)
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

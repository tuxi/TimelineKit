#if canImport(UIKit)
import SwiftUI

/// Vertical category rail for the regular-width workspace.
struct EditorToolRail: View {
    @Binding var activeCategory: EditorToolCategory?
    var width: CGFloat = 76

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(EditorToolCategory.allCases.filter(\.isEnabled)) { category in
                    let isActive = activeCategory == category

                    Button {
                        withAnimation(.spring(duration: 0.25)) {
                            activeCategory = isActive ? nil : category
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: category.icon)
                                .font(.system(size: 18, weight: .regular))
                            Text(category.rawValue)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(isActive ? Color.yellow : Color.white.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isActive ? Color.yellow.opacity(0.14) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.rawValue)
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                }
            }
            .padding(6)
        }
        .frame(width: width)
        .background(Color(white: 0.10))
    }
}
#endif

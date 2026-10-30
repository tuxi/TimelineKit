#if canImport(UIKit)
import SwiftUI
import TimelineKitCore
import TimelineKitUIShared
import TimelineKitUISharedViews

/// FCP-style insertable text items: titles, lower thirds and caption styles,
/// with a most-recently-used row on top.
///
/// Each card previews the template with its real `TextStyle`, so the choice is
/// made on the look rather than on the name.
struct TextTemplatePicker: View {
    let store: EditorStore
    var onInsert: (TextTemplate) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var recents = RecentTextTemplates()
    @State private var recentTemplates: [TextTemplate] = []

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !recentTemplates.isEmpty {
                        section(title: "最近使用", templates: recentTemplates)
                    }
                    ForEach(TextTemplate.Group.allCases, id: \.self) { group in
                        let templates = TextTemplateCatalog.templates(in: group)
                        if !templates.isEmpty {
                            section(title: group.displayName, templates: templates)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(white: 0.08))
            .navigationTitle("文字模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onAppear { recentTemplates = recents.templates() }
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(title: String, templates: [TextTemplate]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(templates) { template in
                    card(template)
                }
            }
        }
    }

    private func card(_ template: TextTemplate) -> some View {
        Button {
            insert(template)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(white: 0.16))
                    previewText(template)
                }
                .frame(height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Text(template.name)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(template.name)
        .accessibilityHint("插入到播放头位置")
    }

    // MARK: - Preview

    /// Renders the template's style at a size that fits the card. Sizes and
    /// offsets are scaled rather than used verbatim, since the card is roughly a
    /// third of a phone-width canvas.
    private func previewText(_ template: TextTemplate) -> some View {
        let style = template.style
        // Explicit types keep the SwiftUI modifier chain cheap to type-check.
        let size: CGFloat = min(26, max(11, CGFloat(style.fontSize) * 0.40))
        let weight: Font.Weight = style.fontWeight.swiftUI
        let color: Color = Color(hex: style.color) ?? Color.white
        let shadowColor: Color = Color(hex: style.shadowColor ?? "") ?? Color.clear
        let alignment: SwiftUI.TextAlignment = style.alignment.textAlignment
        let kern: CGFloat = CGFloat(style.kerning) * 0.4
        let lineSpacing: CGFloat = CGFloat(style.lineSpacing) * 0.4
        let padH: CGFloat = CGFloat(style.paddingH) * 0.4
        let padV: CGFloat = CGFloat(style.paddingV) * 0.4
        let shadowRadius: CGFloat = CGFloat(style.shadowRadius) * 0.4
        let shadowX: CGFloat = CGFloat(style.shadowOffsetX) * 0.4
        let shadowY: CGFloat = CGFloat(style.shadowOffsetY) * 0.4

        return Text(template.defaultText)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .kerning(kern)
            .lineSpacing(lineSpacing)
            .multilineTextAlignment(alignment)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, padH)
            .padding(.vertical, padV)
            .background { previewBackground(style) }
            .shadow(color: shadowColor, radius: shadowRadius, x: shadowX, y: shadowY)
            .padding(10)
    }

    @ViewBuilder
    private func previewBackground(_ style: TextStyle) -> some View {
        if let hex = style.backgroundColor, let color = Color(hex: hex) {
            RoundedRectangle(cornerRadius: max(2, style.backgroundRadius * 0.5))
                .fill(color)
        }
    }

    // MARK: - Insert

    private func insert(_ template: TextTemplate) {
        store.insertTextTemplate(template, recents: recents)
        recentTemplates = recents.templates()
        onInsert(template)
        dismiss()
    }
}

// MARK: - Style mapping

private extension FontWeight {
    var swiftUI: Font.Weight {
        switch self {
        case .thin:     return .thin
        case .light:    return .light
        case .regular:  return .regular
        case .medium:   return .medium
        case .semibold: return .semibold
        case .bold:     return .bold
        case .heavy:    return .heavy
        case .black:    return .black
        }
    }
}

/// `TextAlignment` exists in both TimelineKitCore and SwiftUI; qualify it so the
/// editor's alignment enum is the one being extended.
private extension TimelineKitCore.TextAlignment {
    var textAlignment: SwiftUI.TextAlignment {
        switch self {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }
}
#endif

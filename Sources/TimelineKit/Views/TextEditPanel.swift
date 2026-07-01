#if canImport(UIKit)
import SwiftUI

// MARK: - TextEditPanel

/// CapCut-style text editing panel.
///
/// Layout (top → bottom):
///   ┌──────────────────────────────────┐
///   │ [text input field...........][✓] │  ← always visible above keyboard
///   ├──────────────────────────────────┤
///   │ [字体] [样式] [花字] [文字模板] [动画] │  ← tab bar, always visible
///   ├──────────────────────────────────┤
///   │         tab content              │  ← gets covered by keyboard when typing
///   └──────────────────────────────────┘
///
/// When keyboard appears the content area is naturally covered; the text input
/// and tab bar remain visible just above the keyboard.
struct TextEditPanel: View {

    let segmentID: UUID
    let store: EditorStore

    @State private var selectedTab: PanelTab = .style
    @State private var localFontSize: Double = 34
    @State private var isDraggingFontSlider = false
    @State private var styleSubTab: StyleSubTab = .text
    // v3 P1 (text-entry-spec §10): numeric font-size input state.
    @State private var isEditingFontSize = false
    @State private var fontSizeText: String = "34"
    @FocusState private var fontSizeFieldFocused: Bool

    // MARK: - Tabs

    enum PanelTab: CaseIterable {
        case font, style, fancy, template, animation, position
        var title: String {
            switch self {
            case .font:      return "字体"
            case .style:     return "样式"
            case .fancy:     return "花字"
            case .template:  return "文字模板"
            case .animation: return "动画"
            case .position:  return "位置"
            }
        }
    }

    enum StyleSubTab: CaseIterable {
        case text, stroke, background, shadow
        var title: String {
            switch self {
            case .text:       return "文本"
            case .stroke:     return "描边"
            case .background: return "背景"
            case .shadow:     return "阴影"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            textInputBar
            tabBar
            tabDivider
            tabContent
        }
        .background(Color(white: 0.13))
        .environment(\.colorScheme, .dark)
        .onAppear { localFontSize = content?.style.fontSize ?? 34 }
        .onChange(of: content?.style.fontSize) { _, v in
            if !isDraggingFontSlider { localFontSize = v ?? 34 }
        }
    }

    // MARK: - Text Input Bar

    private var textInputBar: some View {
        HStack(spacing: 4) {
            // Text field
            let binding = Binding<String>(
                get: { content?.text ?? "" },
                set: { updateText($0) }
            )
            TextField("输入文字…", text: binding)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))

            Spacer()
            // Expand button (placeholder — full-screen editing future feature)
//            Button {} label: {
//                Image(systemName: "arrow.up.left.and.arrow.down.right")
//                    .font(.system(size: 13))
//                    .foregroundStyle(Color.white.opacity(0.45))
//                    .frame(width: 40, height: 40)
//            }
//            .buttonStyle(.plain)

            // v3 tts-spec §3.2: 朗读 entry from TextEditPanel — only for subtitle segments.
            if content?.isSubtitle == true {
            Button {
                store.ttsConfigSheetTargets = [segmentID]
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .disabled((content?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Confirm / dismiss
            Button { store.selection.deselect() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(white: 0.13))
    }

    // MARK: - Tab Bar

    private var visibleTabs: [PanelTab] { PanelTab.allCases }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(visibleTabs, id: \.self) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 44)
        .background(Color(white: 0.13))
    }

    private func tabButton(_ tab: PanelTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { selectedTab = tab }
        } label: {
            VStack(spacing: 0) {
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : Color.white.opacity(0.45))
                    .frame(height: 40)

                Rectangle()
                    .fill(isSelected ? Color.white : Color.clear)
                    .frame(height: 2)
            }
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
    }

    private var tabDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .font:      fontTabContent
        case .style:     styleTabContent
        case .fancy:     placeholderContent(icon: "sparkles",          title: "花字效果")
        case .template:  placeholderContent(icon: "doc.richtext.fill",  title: "文字模板")
        case .animation: placeholderContent(icon: "play.rectangle.fill", title: "文字动画")
        case .position:  positionTabContent
        }
    }

    // MARK: - Font Tab

    /// v3 P1 (text-entry-spec §9 + §10): font family selector and font-size control
    /// in one tab — both belong to the "字体" mental model so the size control is
    /// also exposed here (it remains in 样式→文本 sub-tab as well; both share the
    /// same `mutateTextStyle` channel).
    private var fontTabContent: some View {
        let currentFontName = content?.style.fontName
        let currentWeight   = content?.style.fontWeight ?? .regular
        return ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                fontSizeRow

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 0.5)
                    .padding(.vertical, 4)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 10
                ) {
                    ForEach(SystemFontCatalog.all, id: \.family) { entry in
                        let isSelected = (currentFontName == entry.family)
                                      || (currentFontName == nil && entry.family == SystemFontCatalog.pingFang.family)
                        fontCard(entry: entry, weight: currentWeight, isSelected: isSelected) {
                            mutateStyle(label: "切换字体") {
                                $0.fontName = entry.family
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func fontCard(
        entry: SystemFontFamily,
        weight: FontWeight,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.white.opacity(0.15) : Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.white.opacity(0.6) : Color.clear, lineWidth: 1.5)
                    )

                VStack(spacing: 4) {
                    Text("永")
                        .font(.custom(
                            SystemFontCatalog.resolvePostScript(
                                fontName: entry.family,
                                weight:   weight
                            ),
                            size: 26
                        ))
                        .foregroundStyle(.white)
                    Text(entry.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .padding(.vertical, 10)
            }
            .frame(height: 72)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Style Tab

    /// P4 fix (in-device feedback): wrap the entire style tab in a single
    /// ScrollView so long sub-tabs (e.g. 文本 with 6 rows, 阴影 with 4 rows)
    /// stay reachable even when the keyboard partially covers the panel. Each
    /// `styleSubContent` branch is a plain VStack — no inner ScrollViews — so
    /// the outer ScrollView owns all vertical scrolling. The `.id(styleSubTab)`
    /// anchor still resets state cleanly on sub-tab swap.
    private var styleTabContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                stylePresetsRow

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)

                alignmentRow

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)

                styleSubTabBar

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)

                styleSubContent
                    .id(styleSubTab)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var stylePresetsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // "None" preset — resets color to white + clears shadow.
                Button {
                    store.applyStylePreset(segmentID: segmentID, preset: nil)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(0.4), lineWidth: 1.5, antialiased: true)
                            .frame(width: 48, height: 48)
                        Image(systemName: "circle.slash")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }
                .buttonStyle(.plain)

                ForEach(stylePresets, id: \.color) { preset in
                    Button {
                        store.applyStylePreset(
                            segmentID: segmentID,
                            preset: .init(color: preset.color, shadowColor: preset.shadow)
                        )
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(white: 0.2))
                                .frame(width: 48, height: 48)
                            Text("T")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(Color(hex: preset.color) ?? .white)
                                .shadow(color: (Color(hex: preset.shadow) ?? .clear).opacity(0.8), radius: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 66)
    }

    // MARK: - v4 Alignment Row (text-typography-spec §2.4)

    private var alignmentRow: some View {
        HStack(spacing: 0) {
            alignmentButton(.leading,  icon: "text.alignleft")
            alignmentButton(.center,   icon: "text.aligncenter")
            alignmentButton(.trailing, icon: "text.alignright")
        }
        .frame(height: 40)
        .padding(.horizontal, 14)
    }

    private func alignmentButton(_ alignment: TextAlignment, icon: String) -> some View {
        let isSelected = content?.style.alignment == alignment
        return Button {
            store.setTextAlignment(segmentID: segmentID, alignment: alignment)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? .white : Color.white.opacity(0.45))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.white.opacity(0.12) : .clear)
                )
        }
        .buttonStyle(.plain)
    }

    private var styleSubTabBar: some View {
        HStack(spacing: 0) {
            ForEach(StyleSubTab.allCases, id: \.self) { sub in
                let isSelected = styleSubTab == sub
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) { styleSubTab = sub }
                } label: {
                    Text(sub.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : Color.white.opacity(0.45))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(isSelected ? Color.white : Color.clear)
                                .frame(height: 2)
                        }
                        // P4 fix: .buttonStyle(.plain) restricts hit-testing to the
                        // Text glyphs by default; expand to the full row so the entire
                        // tab area is tappable.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var styleSubContent: some View {
        switch styleSubTab {
        case .text:       textStyleContent
        case .stroke:     strokeStyleContent
        case .background: backgroundStyleContent
        case .shadow:     shadowStyleContent
        }
    }

    private var textStyleContent: some View {
        VStack(spacing: 0) {
            colorPaletteRow
            styleDivider
            fontSizeRow
            styleDivider
            fontWeightRow
            // v3 P4 (text-entry-spec §11.4): 行/字/斜体 in the same sub-tab.
            styleDivider
            lineSpacingRow
            styleDivider
            kerningRow
            styleDivider
            italicRow
        }
        .padding(.vertical, 8)
    }

    private var styleDivider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5).padding(.vertical, 4)
    }

    private var colorPaletteRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("颜色")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.4))
                .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Custom color button
                    ZStack {
                        Circle()
                            .fill(AngularGradient(
                                colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                center: .center
                            ))
                            .frame(width: 34, height: 34)
                        Image(systemName: "eyedropper")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    ForEach(colorPalette, id: \.self) { hex in
                        let isSelected = content?.style.color == hex
                        Button {
                            mutateStyle() { $0.color = hex }
                        } label: {
                            Circle()
                                .fill(Color(hex: hex) ?? .white)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    Circle().strokeBorder(
                                        isSelected ? Color.white : Color.white.opacity(hex == "#FFFFFF" ? 0.3 : 0),
                                        lineWidth: isSelected ? 2.5 : 1
                                    )
                                }
                                .scaleEffect(isSelected ? 1.15 : 1)
                                .animation(.spring(duration: 0.2), value: isSelected)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 8)
    }

    private var fontSizeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("字号")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
                Spacer()
                fontSizeValueControl
            }
            .padding(.horizontal, 14)

            Slider(
                value: $localFontSize,
                in: 12...120,
                step: 1,
                onEditingChanged: { editing in
                    isDraggingFontSlider = editing
                    if !editing {
                        mutateStyle(label: "调整字号") {
                            $0.fontSize = localFontSize
                        }
                    }
                }
            )
            .tint(Color(hex: "#FF3B30") ?? .red)
            .padding(.horizontal, 14)
            .onChange(of: localFontSize) { _, v in
                if isDraggingFontSlider, content?.isSubtitle == false {
                    store.previewFontSize(segmentID: segmentID, fontSize: v)
                } else if isDraggingFontSlider {
                    mutateStyle { $0.fontSize = v }
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// v3 P1 (text-entry-spec §10): clickable numeric input. Tapping the "N pt" label
    /// flips to a TextField with a numberPad keyboard. Commit on Done / focus loss
    /// clamps to 12...120 and reuses `mutateTextStyle` (shared with slider commit).
    @ViewBuilder
    private var fontSizeValueControl: some View {
        if isEditingFontSize {
            HStack(spacing: 4) {
                TextField("", text: $fontSizeText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white)
                    .focused($fontSizeFieldFocused)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("完成") { commitFontSizeText() }
                        }
                    }
                    .onChange(of: fontSizeFieldFocused) { _, focused in
                        if !focused { commitFontSizeText() }
                    }
                Text("pt")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        } else {
            Button {
                fontSizeText = "\(Int(localFontSize))"
                isEditingFontSize = true
                // Defer focus so SwiftUI installs the TextField first.
                DispatchQueue.main.async { fontSizeFieldFocused = true }
            } label: {
                Text("\(Int(localFontSize)) pt")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .underline(true, color: Color.white.opacity(0.25))
            }
            .buttonStyle(.plain)
        }
    }

    private func commitFontSizeText() {
        defer { isEditingFontSize = false; fontSizeFieldFocused = false }
        let parsed = Double(fontSizeText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? localFontSize
        let clamped = min(max(parsed, 12), 120)
        localFontSize = clamped
        mutateStyle(label: "调整字号") {
            $0.fontSize = clamped
        }
    }

    private var fontWeightRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("字重")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.4))
                .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(weightOptions, id: \.0) { (weight, label) in
                        let isSelected = content?.style.fontWeight == weight
                        Button {
                            mutateStyle(label: "调整字重") {
                                $0.fontWeight = weight
                            }
                        } label: {
                            Text(label)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .black : Color.white.opacity(0.8))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(isSelected ? Color.white : Color.white.opacity(0.1))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - v3 P4 (text-entry-spec §11) — paragraph & emphasis rows

    private var lineSpacingRow: some View {
        styleSliderRow(
            title: "行间距",
            value: content?.style.lineSpacing ?? 0,
            range: 0...30,
            step: 1,
            unit: "pt",
            preview: { v, _ in
                mutateStyle() { $0.lineSpacing = v }
            },
            commit: { v in
                mutateStyle(label: "调整行间距") { $0.lineSpacing = v }
            }
        )
    }

    private var kerningRow: some View {
        styleSliderRow(
            title: "字间距",
            value: content?.style.kerning ?? 0,
            range: -5...20,
            step: 0.5,
            unit: "pt",
            preview: { v, _ in
                mutateStyle() { $0.kerning = v }
            },
            commit: { v in
                mutateStyle(label: "调整字间距") { $0.kerning = v }
            }
        )
    }

    private var italicRow: some View {
        let on = content?.style.isItalic ?? false
        return HStack {
            Text("斜体")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.4))
            Spacer()
            Toggle("", isOn: Binding(
                get: { on },
                set: { newVal in
                    mutateStyle(label: "切换斜体") { $0.isItalic = newVal }
                }
            ))
            .labelsHidden()
            .tint(Color.white.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - v3 P4 (text-entry-spec §11.4) — Stroke sub-tab

    private var strokeStyleContent: some View {
        VStack(spacing: 0) {
            styleColorRow(
                title: "描边颜色",
                selected: content?.style.strokeColor,
                allowNone: true,
                onSelect: { hex in
                    mutateStyle(label: "切换描边颜色") {
                        $0.strokeColor = hex
                    }
                }
            )
            styleDivider
            styleSliderRow(
                title: "宽度",
                value: content?.style.strokeWidth ?? 0,
                range: 0...10,
                step: 0.5,
                unit: "pt",
                preview: { v, _ in
                    mutateStyle() { $0.strokeWidth = v }
                },
                commit: { v in
                    mutateStyle(label: "调整描边宽度") { $0.strokeWidth = v }
                }
            )
        }
        .padding(.vertical, 8)
    }

    // MARK: - v3 P4 — Background sub-tab

    private var backgroundStyleContent: some View {
        VStack(spacing: 0) {
            styleColorRow(
                title: "底色",
                selected: content?.style.backgroundColor,
                allowNone: true,
                onSelect: { hex in
                    mutateStyle(label: "切换底色") {
                        $0.backgroundColor = hex
                    }
                }
            )
            styleDivider
            styleSliderRow(
                title: "圆角",
                value: content?.style.backgroundRadius ?? 0,
                range: 0...30,
                step: 1,
                unit: "pt",
                preview: { v, _ in
                    mutateStyle() { $0.backgroundRadius = v }
                },
                commit: { v in
                    mutateStyle(label: "调整圆角") { $0.backgroundRadius = v }
                }
            )
            styleDivider
            styleSliderRow(
                title: "横向间距",
                value: content?.style.paddingH ?? 0,
                range: 0...20,
                step: 1,
                unit: "pt",
                preview: { v, _ in
                    mutateStyle() { $0.paddingH = v }
                },
                commit: { v in
                    mutateStyle(label: "调整横向间距") { $0.paddingH = v }
                }
            )
            styleDivider
            styleSliderRow(
                title: "纵向间距",
                value: content?.style.paddingV ?? 0,
                range: 0...20,
                step: 1,
                unit: "pt",
                preview: { v, _ in
                    mutateStyle() { $0.paddingV = v }
                },
                commit: { v in
                    mutateStyle(label: "调整纵向间距") { $0.paddingV = v }
                }
            )
        }
        .padding(.vertical, 8)
    }

    // MARK: - v3 P4 — Shadow sub-tab

    private var shadowStyleContent: some View {
        VStack(spacing: 0) {
            styleColorRow(
                title: "阴影颜色",
                selected: content?.style.shadowColor,
                allowNone: true,
                onSelect: { hex in
                    mutateStyle(label: "切换阴影颜色") {
                        $0.shadowColor = hex
                    }
                }
            )
            styleDivider
            styleSliderRow(
                title: "横向偏移",
                value: content?.style.shadowOffsetX ?? 0,
                range: -10...10,
                step: 0.5,
                unit: "pt",
                preview: { v, _ in
                    mutateStyle() { $0.shadowOffsetX = v }
                },
                commit: { v in
                    mutateStyle(label: "调整阴影 X") { $0.shadowOffsetX = v }
                }
            )
            styleDivider
            styleSliderRow(
                title: "纵向偏移",
                value: content?.style.shadowOffsetY ?? 0,
                range: -10...10,
                step: 0.5,
                unit: "pt",
                preview: { v, _ in
                    mutateStyle() { $0.shadowOffsetY = v }
                },
                commit: { v in
                    mutateStyle(label: "调整阴影 Y") { $0.shadowOffsetY = v }
                }
            )
            styleDivider
            styleSliderRow(
                title: "模糊",
                value: content?.style.shadowRadius ?? 0,
                range: 0...20,
                step: 0.5,
                unit: "pt",
                preview: { v, _ in
                    mutateStyle() { $0.shadowRadius = v }
                },
                commit: { v in
                    mutateStyle(label: "调整阴影模糊") { $0.shadowRadius = v }
                }
            )
        }
        .padding(.vertical, 8)
    }

    // MARK: - v3 P4 — reusable controls

    /// Generic labelled slider row. `preview` fires continuously while dragging
    /// (no undo entry), `commit` fires once on release (records undo).
    private func styleSliderRow(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        unit: String,
        preview: @escaping (Double, Bool) -> Void,
        commit: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
                Spacer()
                Text(String(format: "%g \(unit)", value))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(.horizontal, 14)

            Slider(
                value: Binding(
                    get: { value },
                    set: { preview($0, true) }
                ),
                in: range,
                step: step,
                onEditingChanged: { editing in
                    if !editing { commit(value) }
                }
            )
            .tint(Color(hex: "#FF3B30") ?? .red)
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
    }

    /// Reusable color palette row. When `allowNone` is true, a leading "无" button
    /// resets the binding to nil (no color).
    private func styleColorRow(
        title: String,
        selected: String?,
        allowNone: Bool,
        onSelect: @escaping (String?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.4))
                .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if allowNone {
                        let isSelected = (selected == nil)
                        Button { onSelect("#00000000") } label: {
                            ZStack {
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.4), lineWidth: 1.5)
                                    .frame(width: 34, height: 34)
                                Image(systemName: "circle.slash")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.white.opacity(0.55))
                            }
                            .overlay {
                                Circle().strokeBorder(
                                    isSelected ? Color.white : Color.clear,
                                    lineWidth: isSelected ? 2.5 : 0
                                )
                                .scaleEffect(isSelected ? 1.15 : 1)
                            }
                            .animation(.spring(duration: 0.2), value: isSelected)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(colorPalette, id: \.self) { hex in
                        let isSelected = (selected == hex)
                        Button { onSelect(hex) } label: {
                            Circle()
                                .fill(Color(hex: hex) ?? .white)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    Circle().strokeBorder(
                                        isSelected ? Color.white : Color.white.opacity(hex == "#FFFFFF" ? 0.3 : 0),
                                        lineWidth: isSelected ? 2.5 : 1
                                    )
                                }
                                .scaleEffect(isSelected ? 1.15 : 1)
                                .animation(.spring(duration: 0.2), value: isSelected)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Position Tab

    private var positionTabContent: some View {
        VStack(spacing: 0) {
            if content?.isSubtitle == true {
                subtitlePositionYRow
                styleDivider
                maxCharsPerLineRow
            } else {
                textPositionXRow
                styleDivider
                textPositionYRow
            }
            styleDivider
            layerOrderRow
        }
        .padding(.vertical, 8)
    }

    // MARK: - v4 Layer Order (text-typography-spec §5.4)

    private var layerOrderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("层级")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.4))
                .padding(.horizontal, 14)
            HStack(spacing: 8) {
                layerOrderButton("置顶",   icon: "arrow.up.to.line.compact") { store.bringSegmentToFront(segmentID: segmentID) }
                layerOrderButton("置底",   icon: "arrow.down.to.line.compact") { store.sendSegmentToBack(segmentID: segmentID) }
                layerOrderButton("上移",   icon: "arrow.up") { store.bringSegmentForward(segmentID: segmentID) }
                layerOrderButton("下移",   icon: "arrow.down") { store.sendSegmentBackward(segmentID: segmentID) }
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
    }

    private func layerOrderButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(label)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: Text Position (decorative text)

    private var textPositionXRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("水平位置")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
                Spacer()
                Text(String(format: "%.0f%%", (content?.textPosX ?? 0.5) * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(.horizontal, 14)

            Slider(
                value: Binding(
                    get: { content?.textPosX ?? 0.5 },
                    set: { newVal in
                        store.mutateTextContent(segmentID: segmentID) {
                            $0.position.x = newVal
                        }
                    }
                ),
                in: 0...1,
                step: 0.01
            )
            .tint(Color(hex: "#FF3B30") ?? .red)
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
    }

    private var textPositionYRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("垂直位置")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
                Spacer()
                Text(String(format: "%.0f%%", (content?.textPosY ?? 0.5) * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(.horizontal, 14)

            Slider(
                value: Binding(
                    get: { content?.textPosY ?? 0.5 },
                    set: { newVal in
                        store.mutateTextContent(segmentID: segmentID) {
                            $0.position.y = newVal
                        }
                    }
                ),
                in: 0...1,
                step: 0.01
            )
            .tint(Color(hex: "#FF3B30") ?? .red)
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
    }

    // MARK: Subtitle Position

    private var subtitlePositionYRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("垂直位置")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
                Spacer()
                Text(String(format: "%.0f%%", (content?.subtitlePositionY ?? 0.85) * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(.horizontal, 14)

            Slider(
                value: Binding(
                    get: { content?.subtitlePositionY ?? 0.85 },
                    set: { newVal in
                        store.mutateSubtitleContent(segmentID: segmentID) {
                            $0.positionY = newVal
                        }
                    }
                ),
                in: 0...1,
                step: 0.01
            )
            .tint(Color(hex: "#FF3B30") ?? .red)
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
    }

    private var maxCharsPerLineRow: some View {
        HStack {
            Text("单行最大字数")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.4))
            Spacer()
            HStack(spacing: 4) {
                Button {
                    let current = content?.maxCharsPerLine ?? 30
                    store.mutateSubtitleContent(segmentID: segmentID) {
                        $0.maxCharsPerLine = max(10, current - 1)
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .buttonStyle(.plain)

                Text("\(content?.maxCharsPerLine ?? 30)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(minWidth: 28)

                Button {
                    let current = content?.maxCharsPerLine ?? 30
                    store.mutateSubtitleContent(segmentID: segmentID) {
                        $0.maxCharsPerLine = min(60, current + 1)
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Placeholder

    private func placeholderContent(icon: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(Color.white.opacity(0.2))
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    /// Common editable fields shared by `.text` and `.subtitle` segments.
    private struct TextEditContent {
        let text: String
        let style: TextStyle
        let isSubtitle: Bool
        /// Subtitle vertical position (0=top, 1=bottom).
        let subtitlePositionY: Double?
        let maxCharsPerLine: Int?
        /// Text segment X/Y position (0–1 normalised).
        let textPosX: Double?
        let textPosY: Double?
    }

    private var content: TextEditContent? {
        guard let seg = store.timeline.segment(id: segmentID) else { return nil }
        switch seg.content {
        case .text(let c):
            return TextEditContent(text: c.text, style: c.style, isSubtitle: false,
                                   subtitlePositionY: nil, maxCharsPerLine: nil,
                                   textPosX: c.position.x, textPosY: c.position.y)
        case .subtitle(let c):
            return TextEditContent(text: c.text, style: c.style, isSubtitle: true,
                                   subtitlePositionY: c.positionY, maxCharsPerLine: c.maxCharsPerLine,
                                   textPosX: nil, textPosY: nil)
        default:
            return nil
        }
    }

    private func updateText(_ text: String) {
        if content?.isSubtitle == true {
            store.mutateSubtitleContent(segmentID: segmentID) { $0.text = text }
        } else {
            store.updateTextContent(segmentID: segmentID, text: text)
        }
    }

    private func mutateStyle(label: String = "修改样式", _ modify: @escaping (inout TextStyle) -> Void) {
        if content?.isSubtitle == true {
            store.mutateSubtitleStyle(segmentID: segmentID, label: label, modify)
        } else {
            store.mutateTextStyle(segmentID: segmentID, label: label, modify)
        }
    }

    private let colorPalette = [
        "#FFFFFF", "#000000", "#FF3B30", "#FF9500",
        "#FFCC00", "#34C759", "#007AFF", "#AF52DE", "#FF2D55"
    ]

    private let weightOptions: [(FontWeight, String)] = [
        (.thin, "极细"), (.light, "细体"), (.regular, "常规"),
        (.medium, "中等"), (.semibold, "半粗"), (.bold, "粗体"), (.black, "超黑")
    ]

    private let stylePresets: [(color: String, shadow: String)] = [
        ("#FFFFFF", "#00000000"), ("#FFFF00", "#FF000080"),
        ("#FF6B6B", "#00000080"), ("#4ECDC4", "#00000080"),
        ("#FFE66D", "#FF6B6B80"), ("#A8E6CF", "#00000080")
    ]
}
#endif

#if canImport(UIKit)
import SwiftUI
import Foundation
import TimelineKitCore
import TimelineKitUIShared
import TimelineKitUISharedViews

/// P0 inspector skeleton.
///
/// This view is intentionally not wired into `ClipEditorView` yet. It establishes
/// the tabbed property surface and the video-clip content that the P1 workspace
/// layout will host. Commands stay outside the inspector.
struct EditorInspectorView: View {
    let context: EditorInspectorContext
    let store: EditorStore
    let segmentID: UUID?
    var selectionCount: Int = 1
    var projectName: String? = nil
    var transitionID: UUID? = nil
    var cutContext: TransitionEditContext? = nil
    var browserAsset: EditorPreviewAsset? = nil
    @Binding var activeTab: EditorInspectorTab
    var onCollapse: (() -> Void)? = nil

    private var segment: EditorSegment? {
        segmentID.flatMap { store.timeline.segment(id: $0) }
    }

    private var transition: EditorTransition? {
        transitionID.flatMap { id in
            store.timeline.transitions.first { $0.id == id }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabStrip
            Divider().background(Color.white.opacity(0.08))
            ScrollView {
                content
                    .padding(12)
            }
        }
        .background(Color(white: 0.10))
        .environment(\.colorScheme, .dark)
        .onAppear { normalizeTab() }
        .onChange(of: context) { _, _ in normalizeTab() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("检查器")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))

            if let subtitle = browserAsset?.title
                ?? segmentName
                ?? (transition != nil ? "转场" : (cutContext != nil ? "添加转场" : projectName)) {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("收起检查器")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    // MARK: - Tabs

    @ViewBuilder
    private var tabStrip: some View {
        if context.availableTabs.count == 1,
           let onlyTab = context.availableTabs.first {
            Text(onlyTab.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        } else if context.availableTabs.count <= 5 {
            HStack(spacing: 4) {
                ForEach(context.availableTabs) { tab in
                    tabButton(tab, fillWidth: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(context.availableTabs) { tab in
                        tabButton(tab, fillWidth: false)
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 8)
        }
    }

    private func tabButton(
        _ tab: EditorInspectorTab,
        fillWidth: Bool
    ) -> some View {
        let isSelected = activeTab == tab

        return Button {
            activeTab = tab
        } label: {
            Text(tab.title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(
                    isSelected
                    ? Color.black
                    : Color.white.opacity(0.72)
                )
                .frame(maxWidth: fillWidth ? .infinity : nil)
                .padding(.horizontal, fillWidth ? 4 : 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isSelected
                            ? Color.white
                            : Color.white.opacity(0.08)
                        )
                )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch activeTab {
        case .video:
            if let segment {
                EditorInspectorVideoContent(segment: segment, store: store)
            } else {
                missingSelection
            }

        case .audio:
            if let segment {
                switch segment.content {
                case .audio:
                    EditorInspectorAudioContent(segment: segment, store: store)
                case .video:
                    EditorInspectorVideoAudioContent(segment: segment, store: store)
                default:
                    placeholder(
                        "音频属性",
                        "选择音频或视频片段后显示音频属性。"
                    )
                }
            } else {
                placeholder(
                    "音频属性",
                    "选择音频片段后显示音量、淡入淡出和速度。"
                )
            }

        case .color:
            if let segment {
                EditorInspectorColorContent(segment: segment, store: store)
            } else {
                missingSelection
            }

        case .animation:
            if let segment {
                EditorInspectorAnimationContent(segment: segment, store: store)
            } else {
                missingSelection
            }

        case .text, .layout:
            if let segment, segment.isText || segment.isSubtitle {
                EditorInspectorTextContent(segment: segment, store: store, tab: activeTab)
            } else {
                placeholder(
                    "文字属性",
                    "选择文字或字幕片段后显示内容、样式和布局。"
                )
            }

        case .info:
            if let browserAsset {
                EditorInspectorBrowserAssetInfoContent(asset: browserAsset)
            } else if let segment {
                EditorInspectorInfoContent(segment: segment, store: store)
            } else if let transition {
                EditorInspectorTransitionInfoContent(transition: transition)
            } else if let cutContext {
                EditorInspectorTransitionCutInfoContent(context: cutContext)
            } else {
                placeholder("片段信息", "选择片段后显示来源、时长和时间位置。")
            }

        case .project:
            EditorInspectorProjectContent(
                store: store,
                projectName: projectName
            )

        case .multiSelection:
            EditorInspectorMultiSelectionContent(count: selectionCount)

        case .transition:
            if let transition {
                EditorInspectorTransitionContent(
                    transition: transition,
                    store: store
                )
            } else if let cutContext {
                EditorInspectorTransitionDraftContent(
                    context: cutContext,
                    store: store
                )
            } else {
                placeholder("转场", "在时间线切点选择一个转场。")
            }

        case .effects:
            placeholder(
                activeTab.title,
                "该属性页将在后续接入。"
            )
        }
    }

    private var missingSelection: some View {
        VStack(spacing: 8) {
            Image(systemName: "cursorarrow.click")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.3))
            Text("选择一个片段以编辑属性")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private func placeholder(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private var segmentName: String? {
        guard let segment else { return nil }

        switch segment.content {
        case .text(let content):
            return content.text.isEmpty ? "文字片段" : content.text
        case .subtitle(let content):
            return content.text.isEmpty ? "字幕片段" : content.text
        case .audio:
            return materialName(for: segment) ?? "音频片段"
        case .video:
            return materialName(for: segment) ?? "视频片段"
        case .image:
            return materialName(for: segment) ?? "图片片段"
        }
    }

    private func materialName(for segment: EditorSegment) -> String? {
        guard let material = store.timeline.materials[segment.materialID],
              let url = material.localURL ?? material.remoteURL else {
            return nil
        }
        return url.lastPathComponent
    }

    private func normalizeTab() {
        activeTab = context.resolvedTab(preferred: activeTab)
    }
}

// MARK: - Selection mapping

extension EditorInspectorContentKind {
    init(segment: EditorSegment) {
        switch segment.content {
        case .video:    self = .video
        case .image:    self = .image
        case .text:     self = .text
        case .subtitle: self = .subtitle
        case .audio:    self = .audio
        }
    }
}

extension EditorInspectorContext {
    /// Builds the inspector context from the current selection. Multi-selection
    /// stays in a summary state until the later multi-edit pass.
    static func make(segment: EditorSegment?, selectionCount: Int) -> EditorInspectorContext {
        if selectionCount > 1 {
            return EditorInspectorContext(kind: .multiple)
        }
        guard let segment else {
            return EditorInspectorContext(kind: .none)
        }
        return EditorInspectorContext(
            kind: EditorInspectorContentKind(segment: segment)
        )
    }
}

// MARK: - Video

private struct EditorInspectorVideoContent: View {
    let segment: EditorSegment
    @Bindable var store: EditorStore

    @State private var transformEditBase: SegmentTransform?

    var body: some View {
        VStack(spacing: 10) {
            InspectorSection("变换") {
                InspectorSliderRow(
                    label: "水平位置",
                    value: segment.transform.position.x,
                    range: 0...1,
                    step: 0.01,
                    format: { String(format: "%.2f", $0) },
                    onPreview: preview { updated(positionX: $0) },
                    onEnd: commit { updated(positionX: $0) }
                )

                InspectorSliderRow(
                    label: "垂直位置",
                    value: segment.transform.position.y,
                    range: 0...1,
                    step: 0.01,
                    format: { String(format: "%.2f", $0) },
                    onPreview: preview { updated(positionY: $0) },
                    onEnd: commit { updated(positionY: $0) }
                )

                InspectorSliderRow(
                    label: "缩放",
                    value: segment.transform.scale,
                    range: 0.1...4,
                    step: 0.01,
                    format: { String(format: "%.0f%%", $0 * 100) },
                    onPreview: preview { updated(scale: $0) },
                    onEnd: commit { updated(scale: $0) }
                )

                InspectorSliderRow(
                    label: "旋转",
                    value: segment.transform.rotation * 180 / .pi,
                    range: -180...180,
                    step: 1,
                    format: { String(format: "%.0f°", $0) },
                    onPreview: preview { updated(rotationDegrees: $0) },
                    onEnd: commit { updated(rotationDegrees: $0) }
                )

                InspectorSliderRow(
                    label: "不透明度",
                    value: segment.transform.opacity,
                    range: 0...1,
                    step: 0.01,
                    format: { String(format: "%.0f%%", $0 * 100) },
                    onPreview: preview { updated(opacity: $0) },
                    onEnd: commit { updated(opacity: $0) }
                )

                Button("重置变换") {
                    store.setTransform(segmentID: segment.id, transform: .identity)
                }
                .buttonStyle(.bordered)
            }

            InspectorSection("速度") {
                InspectorRow("倍率", String(format: "%.2fx", segment.speed))
                Text("视频速度渲染将在后续接入")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
            }

            if case .video(let content) = segment.content {
                InspectorSection("内容") {
                    InspectorRow("填充", content.fit.rawValue)
                    Toggle(
                        "静音原音",
                        isOn: Binding(
                            get: { content.isMuted },
                            set: {
                                store.setVideoMuted(
                                    segmentID: segment.id,
                                    isMuted: $0
                                )
                            }
                        )
                    )
                    .font(.system(size: 12))
                    .tint(.white.opacity(0.8))
                }
            }
        }
    }

    private func preview(_ transform: @escaping (Double) -> SegmentTransform) -> (Double) -> Void {
        { value in
            if transformEditBase == nil {
                transformEditBase = segment.transform
            }
            store.previewTransform(
                segmentID: segment.id,
                transform: transform(value)
            )
        }
    }

    private func commit(_ transform: @escaping (Double) -> SegmentTransform) -> (Double) -> Void {
        { value in
            store.setTransform(
                segmentID: segment.id,
                transform: transform(value),
                undoBase: transformEditBase
            )
            transformEditBase = nil
        }
    }

    private func updated(
        positionX: Double? = nil,
        positionY: Double? = nil,
        scale: Double? = nil,
        rotationDegrees: Double? = nil,
        opacity: Double? = nil
    ) -> SegmentTransform {
        var transform = segment.transform
        if let positionX { transform.position.x = positionX }
        if let positionY { transform.position.y = positionY }
        if let scale { transform.scale = scale }
        if let rotationDegrees {
            transform.rotation = rotationDegrees * .pi / 180
        }
        if let opacity { transform.opacity = opacity }
        return transform
    }
}

// MARK: - Audio

private struct EditorInspectorAudioContent: View {
    let segment: EditorSegment
    @Bindable var store: EditorStore

    @State private var volumeEditBase: Double?

    private var maxFade: Double {
        max(0.01, min(2.0, segment.targetRange.duration / 2))
    }

    var body: some View {
        if case .audio(let content) = segment.content {
            VStack(spacing: 10) {
                InspectorSection("音量") {
                    InspectorSliderRow(
                        label: "音量",
                        value: content.volume,
                        range: 0...2,
                        step: 0.05,
                        format: { String(format: "%.0f%%", $0 * 100) },
                        onPreview: {
                            if volumeEditBase == nil {
                                volumeEditBase = content.volume
                            }
                            store.previewAudioVolume(
                                segmentID: segment.id,
                                volume: $0
                            )
                        },
                        onEnd: {
                            store.setAudioVolume(
                                segmentID: segment.id,
                                volume: $0,
                                undoBase: volumeEditBase
                            )
                            volumeEditBase = nil
                        }
                    )

                    Toggle(
                        "静音",
                        isOn: Binding(
                            get: { content.isMuted },
                            set: {
                                store.muteAudioSegment(
                                    id: segment.id,
                                    isMuted: $0
                                )
                            }
                        )
                    )
                    .font(.system(size: 12))
                    .tint(.white.opacity(0.8))

                    InspectorRow("循环", content.isLooping ? "是" : "否")
                }

                InspectorSection("淡化") {
                    InspectorSliderRow(
                        label: "淡入",
                        value: content.fadeInDuration,
                        range: 0...maxFade,
                        step: 0.01,
                        format: { String(format: "%.2fs", $0) },
                        onPreview: { _ in },
                        onEnd: {
                            store.mutateAudioFade(
                                segmentID: segment.id,
                                fadeIn: $0,
                                fadeOut: content.fadeOutDuration
                            )
                        }
                    )

                    InspectorSliderRow(
                        label: "淡出",
                        value: content.fadeOutDuration,
                        range: 0...maxFade,
                        step: 0.01,
                        format: { String(format: "%.2fs", $0) },
                        onPreview: { _ in },
                        onEnd: {
                            store.mutateAudioFade(
                                segmentID: segment.id,
                                fadeIn: content.fadeInDuration,
                                fadeOut: $0
                            )
                        }
                    )
                }

                InspectorSection("速度") {
                    InspectorSliderRow(
                        label: "倍率",
                        value: segment.speed,
                        range: EditorStore.audioSpeedRange,
                        step: 0.1,
                        format: { String(format: "%.1fx", $0) },
                        onPreview: { _ in },
                        onEnd: {
                            store.setAudioSpeed(
                                segmentID: segment.id,
                                speed: $0
                            )
                        }
                    )
                }
            }
        }
    }
}

private struct EditorInspectorVideoAudioContent: View {
    let segment: EditorSegment
    @Bindable var store: EditorStore

    var body: some View {
        if case .video(let content) = segment.content {
            VStack(spacing: 10) {
                InspectorSection("原音") {
                    Toggle(
                        "静音原音",
                        isOn: Binding(
                            get: { content.isMuted },
                            set: {
                                store.setVideoMuted(
                                    segmentID: segment.id,
                                    isMuted: $0
                                )
                            }
                        )
                    )
                    .font(.system(size: 12))
                    .tint(.white.opacity(0.8))

                    Text("视频音量混合将在后续接入")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
    }
}

// MARK: - Color

private struct EditorInspectorColorContent: View {
    let segment: EditorSegment
    @Bindable var store: EditorStore

    @State private var adjustmentEditBase: SegmentAdjustment?

    private var adjustment: SegmentAdjustment {
        segment.adjustment
    }

    var body: some View {
        VStack(spacing: 10) {
            InspectorSection("基础") {
                slider("亮度", value: adjustment.brightness, range: -1...1) {
                    adjusted(brightness: $0)
                }
                slider(
                    "对比度",
                    value: adjustment.contrast - 1,
                    range: -0.5...0.5
                ) {
                    adjusted(contrast: $0 + 1)
                }
                slider(
                    "饱和度",
                    value: adjustment.saturation - 1,
                    range: -1...1
                ) {
                    adjusted(saturation: $0 + 1)
                }
            }

            InspectorSection("色温") {
                slider(
                    "色温",
                    value: adjustment.temperature,
                    range: 2000...9000,
                    step: 10,
                    format: { String(format: "%.0f K", $0) }
                ) {
                    adjusted(temperature: $0)
                }
                slider(
                    "色调",
                    value: adjustment.tint,
                    range: -150...150,
                    step: 1,
                    format: { String(format: "%+.0f", $0) }
                ) {
                    adjusted(tint: $0)
                }
            }

            InspectorSection("明暗") {
                slider("高光", value: adjustment.highlights, range: -1...1) {
                    adjusted(highlights: $0)
                }
                slider("阴影", value: adjustment.shadows, range: -1...1) {
                    adjusted(shadows: $0)
                }
            }

            InspectorSection("滤镜") {
                Menu {
                    Button("无") {
                        setFilter(nil)
                    }
                    ForEach(PresetFilter.allCases, id: \.self) { preset in
                        Button(preset.displayName) {
                            setFilter(preset)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("滤镜")
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Text(adjustment.filterName?.displayName ?? "无")
                            .foregroundStyle(.white.opacity(0.85))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)

                if adjustment.filterName != nil {
                    slider(
                        "强度",
                        value: adjustment.filterIntensity,
                        range: 0...1,
                        format: { String(format: "%.0f%%", $0 * 100) }
                    ) {
                        adjustedFilter(adjustment.filterName, intensity: $0)
                    }
                }
            }

            Button("重置调色") {
                store.setAdjustment(segmentID: segment.id, adjustment: .identity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func slider(
        _ label: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double = 0.01,
        format: @escaping (Double) -> String = { String(format: "%+.2f", $0) },
        _ make: @escaping (Double) -> SegmentAdjustment
    ) -> some View {
        InspectorSliderRow(
            label: label,
            value: value,
            range: range,
            step: step,
            format: format,
            onPreview: {
                if adjustmentEditBase == nil {
                    adjustmentEditBase = adjustment
                }
                store.previewAdjustment(
                    segmentID: segment.id,
                    adjustment: make($0)
                )
            },
            onEnd: {
                store.setAdjustment(
                    segmentID: segment.id,
                    adjustment: make($0),
                    undoBase: adjustmentEditBase
                )
                adjustmentEditBase = nil
            }
        )
    }

    private func setFilter(_ name: PresetFilter?) {
        store.setAdjustment(
            segmentID: segment.id,
            adjustment: adjustedFilter(name)
        )
    }

    private func adjusted(
        brightness: Double? = nil,
        contrast: Double? = nil,
        saturation: Double? = nil,
        temperature: Double? = nil,
        tint: Double? = nil,
        highlights: Double? = nil,
        shadows: Double? = nil
    ) -> SegmentAdjustment {
        var value = adjustment
        if let brightness { value.brightness = brightness }
        if let contrast { value.contrast = contrast }
        if let saturation { value.saturation = saturation }
        if let temperature { value.temperature = temperature }
        if let tint { value.tint = tint }
        if let highlights { value.highlights = highlights }
        if let shadows { value.shadows = shadows }
        return value
    }

    private func adjustedFilter(
        _ name: PresetFilter?,
        intensity: Double? = nil
    ) -> SegmentAdjustment {
        var value = adjustment
        value.filterName = name
        if let intensity { value.filterIntensity = intensity }
        return value
    }
}

// MARK: - Animation

private struct EditorInspectorAnimationContent: View {
    let segment: EditorSegment
    @Bindable var store: EditorStore

    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 10) {
            InspectorSection("已添加动画") {
                if segment.animations.isEmpty {
                    Text("尚未添加动画")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    ForEach(segment.animations) { animation in
                        InspectorRow(
                            animation.semantic.rawValue,
                            String(format: "%.2fs", animation.duration)
                        )
                    }
                }
            }

            Button("选择动画") {
                showPicker = true
            }
            .buttonStyle(.bordered)
        }
        .sheet(isPresented: $showPicker) {
            AnimationPickerSheet(segmentID: segment.id, store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Text

private struct EditorInspectorTextContent: View {
    let segment: EditorSegment
    @Bindable var store: EditorStore
    let tab: EditorInspectorTab

    @State private var showEditor = false

    var body: some View {
        VStack(spacing: 10) {
            if case .text(let content) = segment.content {
                if tab == .text {
                    InspectorSection("内容") {
                        InspectorRow("文本", content.text)
                    }

                    InspectorSection("样式") {
                        InspectorRow("字号", String(format: "%.0f", content.style.fontSize))
                        InspectorRow("字体", content.style.fontName ?? "默认")
                        InspectorRow("颜色", content.style.color)
                        InspectorRow("对齐", String(describing: content.style.alignment))
                    }
                } else {
                    InspectorSection("布局") {
                        InspectorRow("位置", String(
                            format: "%.2f, %.2f",
                            content.position.x,
                            content.position.y
                        ))
                        InspectorRow("锚点", String(describing: content.anchor))
                    }
                }
            } else if case .subtitle(let content) = segment.content {
                if tab == .text {
                    InspectorSection("内容") {
                        InspectorRow("文本", content.text)
                    }

                    InspectorSection("样式") {
                        InspectorRow("字号", String(format: "%.0f", content.style.fontSize))
                        InspectorRow("字体", content.style.fontName ?? "默认")
                        InspectorRow("颜色", content.style.color)
                        InspectorRow("对齐", String(describing: content.style.alignment))
                    }
                } else {
                    InspectorSection("布局") {
                        InspectorRow(
                            "垂直位置",
                            content.positionY.map { String(format: "%.2f", $0) } ?? "默认"
                        )
                        InspectorRow(
                            "每行字数",
                            content.maxCharsPerLine.map { "\($0)" } ?? "默认"
                        )
                    }
                }
            }

            Button("编辑文本") {
                showEditor = true
            }
            .buttonStyle(.bordered)
        }
        .sheet(isPresented: $showEditor) {
            TextEditPanel(segmentID: segment.id, store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Info

private struct EditorInspectorInfoContent: View {
    let segment: EditorSegment
    let store: EditorStore

    var body: some View {
        VStack(spacing: 10) {
            InspectorSection("片段") {
                InspectorRow("标识", String(segment.id.uuidString.prefix(8)))
                InspectorRow("时长", String(format: "%.2fs", segment.targetRange.duration))
                InspectorRow("开始", String(format: "%.2fs", segment.targetRange.start))
                InspectorRow("速度", String(format: "%.2fx", segment.speed))
            }

            InspectorSection("来源") {
                InspectorRow("素材", materialName)
                InspectorRow("填充", String(describing: contentKind))
            }
        }
    }

    private var materialName: String {
        guard let material = store.timeline.materials[segment.materialID],
              let url = material.localURL ?? material.remoteURL else {
            return "未知素材"
        }
        return url.lastPathComponent
    }

    private var contentKind: EditorInspectorContentKind {
        EditorInspectorContentKind(segment: segment)
    }
}

// MARK: - Transition

private struct EditorInspectorTransitionContent: View {
    let transition: EditorTransition
    @Bindable var store: EditorStore

    private var maxDuration: Double {
        let leading = store.timeline
            .segment(id: transition.leadingSegmentID)?
            .targetRange.duration ?? 3
        let trailing = store.timeline
            .segment(id: transition.trailingSegmentID)?
            .targetRange.duration ?? 3
        return max(0.2, min(3.0, min(leading, trailing)))
    }

    var body: some View {
        VStack(spacing: 10) {
            InspectorSection("转场") {
                Menu {
                    ForEach(
                        EditorTransition.TransitionType.allCases,
                        id: \.self
                    ) { type in
                        Button(transitionTypeTitle(type)) {
                            store.updateTransitionType(
                                id: transition.id,
                                type: type
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("类型")
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Text(transitionTypeTitle(transition.type))
                            .foregroundStyle(.white.opacity(0.85))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)

                InspectorSliderRow(
                    label: "时长",
                    value: transition.duration,
                    range: 0.2...maxDuration,
                    step: 0.1,
                    format: { String(format: "%.1fs", $0) },
                    onPreview: { _ in },
                    onEnd: {
                        store.updateTransitionDuration(
                            id: transition.id,
                            duration: $0
                        )
                    }
                )

                InspectorRow("缓动", transition.easing.rawValue)
            }

            Button("删除转场", role: .destructive) {
                store.removeTransition(id: transition.id)
                store.selection.deselect()
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct EditorInspectorTransitionInfoContent: View {
    let transition: EditorTransition

    var body: some View {
        VStack(spacing: 10) {
            InspectorSection("转场信息") {
                InspectorRow("类型", transitionTypeTitle(transition.type))
                InspectorRow("时长", String(format: "%.2fs", transition.duration))
                InspectorRow("缓动", transition.easing.rawValue)
                InspectorRow("预设", transition.presetID ?? "默认")
            }

            InspectorSection("连接") {
                InspectorRow(
                    "前片段",
                    String(transition.leadingSegmentID.uuidString.prefix(8))
                )
                InspectorRow(
                    "后片段",
                    String(transition.trailingSegmentID.uuidString.prefix(8))
                )
            }
        }
    }
}

private struct EditorInspectorBrowserAssetInfoContent: View {
    let asset: EditorPreviewAsset

    var body: some View {
        InspectorSection("素材信息") {
            InspectorRow("名称", asset.title)
            InspectorRow("类型", typeTitle)
            if let duration = asset.duration {
                InspectorRow("时长", String(format: "%.2fs", duration))
            }
            InspectorRow("来源", asset.url.lastPathComponent)
        }
    }

    private var typeTitle: String {
        switch asset.kind {
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "音频"
        }
    }
}

private struct EditorInspectorTransitionDraftContent: View {
    let context: TransitionEditContext
    @Bindable var store: EditorStore

    @State private var selectedType: EditorTransition.TransitionType = .crossFade
    @State private var duration: Double = 0.5

    private var maxDuration: Double {
        let leading = store.timeline
            .segment(id: context.leadingID)?
            .targetRange.duration ?? 3
        let trailing = store.timeline
            .segment(id: context.trailingID)?
            .targetRange.duration ?? 3
        return max(0.2, min(3.0, min(leading, trailing)))
    }

    private var canAdd: Bool {
        store.timeline.segment(id: context.leadingID) != nil
            && store.timeline.segment(id: context.trailingID) != nil
    }

    var body: some View {
        VStack(spacing: 10) {
            InspectorSection("添加转场") {
                Menu {
                    ForEach(
                        EditorTransition.TransitionType.allCases,
                        id: \.self
                    ) { type in
                        Button(transitionTypeTitle(type)) {
                            selectedType = type
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("类型")
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Text(transitionTypeTitle(selectedType))
                            .foregroundStyle(.white.opacity(0.85))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)

                InspectorSliderRow(
                    label: "时长",
                    value: duration,
                    range: 0.2...maxDuration,
                    step: 0.1,
                    format: { String(format: "%.1fs", $0) },
                    onPreview: { duration = $0 },
                    onEnd: { duration = $0 }
                )

                InspectorRow(
                    "连接",
                    "\(String(context.leadingID.uuidString.prefix(8))) → \(String(context.trailingID.uuidString.prefix(8)))"
                )
            }

            Button {
                if let transition = store.addTransition(
                    between: context.leadingID,
                    and: context.trailingID,
                    type: selectedType,
                    duration: duration
                ) {
                    store.selection.selectTransition(transition.id)
                }
            } label: {
                Label("添加转场", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAdd)
        }
    }
}

private struct EditorInspectorTransitionCutInfoContent: View {
    let context: TransitionEditContext

    var body: some View {
        InspectorSection("切点") {
            InspectorRow("状态", "尚未添加转场")
            InspectorRow(
                "前片段",
                String(context.leadingID.uuidString.prefix(8))
            )
            InspectorRow(
                "后片段",
                String(context.trailingID.uuidString.prefix(8))
            )
        }
    }
}

private func transitionTypeTitle(
    _ type: EditorTransition.TransitionType
) -> String {
    switch type {
    case .fade, .crossFade:       return "叠化"
    case .fadeThroughBlack:       return "黑场过渡"
    case .slideLeft,
         .slideRight,
         .slideUp,
         .slideDown:              return "滑动"
    case .pushLeft, .pushRight:   return "推动"
    case .zoom, .zoomIn:          return "缩放"
    case .dissolve:               return "溶解"
    case .wipe:                   return "擦除"
    case .blurFade:               return "模糊淡化"
    }
}

// MARK: - Project

private struct EditorInspectorProjectContent: View {
    let store: EditorStore
    let projectName: String?

    var body: some View {
        VStack(spacing: 10) {
            InspectorSection("项目") {
                InspectorRow("名称", projectName ?? "未命名项目")
            }

            InspectorSection("画布") {
                InspectorRow("尺寸", "\(store.timeline.canvas.width) × \(store.timeline.canvas.height)")
                InspectorRow("帧率", "\(store.timeline.canvas.fps) fps")
                InspectorRow("时长", String(format: "%.2fs", store.timeline.duration))
            }

            InspectorSection("导出") {
                InspectorRow(
                    "规格",
                    store.timeline.effectiveExportConfig.resolution.label
                )
            }
        }
    }
}

// MARK: - Multiple

private struct EditorInspectorMultiSelectionContent: View {
    let count: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.3))
            Text("已选择 \(count) 个片段")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
            Text("多选属性编辑将在后续阶段接入")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

// MARK: - Shared rows

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct InspectorRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct InspectorSliderRow: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let onPreview: (Double) -> Void
    let onEnd: (Double) -> Void

    @State private var localValue: Double
    @State private var isDragging = false

    init(
        label: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String,
        onPreview: @escaping (Double) -> Void,
        onEnd: @escaping (Double) -> Void
    ) {
        self.label = label
        self.value = value
        self.range = range
        self.step = step
        self.format = format
        self.onPreview = onPreview
        self.onEnd = onEnd
        _localValue = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))

                Spacer(minLength: 8)

                Text(format(localValue))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Slider(
                value: Binding(
                    get: { localValue },
                    set: { newValue in
                        localValue = newValue
                        onPreview(newValue)
                    }
                ),
                in: range,
                step: step,
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing {
                        onEnd(localValue)
                    }
                }
            )
            .tint(.white.opacity(0.85))
        }
        .onChange(of: value) { _, newValue in
            if !isDragging {
                localValue = newValue
            }
        }
    }
}
#endif

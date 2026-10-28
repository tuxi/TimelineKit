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
    @Binding var activeTab: EditorInspectorTab
    var onCollapse: (() -> Void)? = nil

    private var segment: EditorSegment? {
        segmentID.flatMap { store.timeline.segment(id: $0) }
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
        .onAppear { normalizeTab() }
        .onChange(of: context) { _, _ in normalizeTab() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("检查器")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))

            if let segmentName {
                Text(segmentName)
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
        if context.availableTabs.count <= 5 {
            Picker("检查器标签", selection: $activeTab) {
                ForEach(context.availableTabs) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(context.availableTabs) { tab in
                        Button {
                            activeTab = tab
                        } label: {
                            Label(tab.title, systemImage: tab.systemImage)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(
                                    activeTab == tab
                                    ? Color.white
                                    : Color.white.opacity(0.55)
                                )
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(
                                            activeTab == tab
                                            ? Color.white.opacity(0.14)
                                            : Color.clear
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch activeTab {
        case .video:
            if let segment {
                EditorInspectorVideoContent(segment: segment)
            } else {
                missingSelection
            }

        case .audio:
            if let segment, case .audio = segment.content {
                EditorInspectorAudioContent(segment: segment)
            } else {
                placeholder(
                    "音频属性",
                    "选择音频片段后显示音量、淡入淡出和速度。"
                )
            }

        case .color:
            if let segment {
                EditorInspectorColorContent(segment: segment)
            } else {
                missingSelection
            }

        case .animation:
            if let segment {
                EditorInspectorAnimationContent(segment: segment)
            } else {
                missingSelection
            }

        case .text, .layout:
            if let segment, segment.isText || segment.isSubtitle {
                EditorInspectorTextContent(segment: segment, tab: activeTab)
            } else {
                placeholder(
                    "文字属性",
                    "选择文字或字幕片段后显示内容、样式和布局。"
                )
            }

        case .info:
            if let segment {
                EditorInspectorInfoContent(segment: segment, store: store)
            } else {
                placeholder("片段信息", "选择片段后显示来源、时长和时间位置。")
            }

        case .project:
            EditorInspectorProjectContent(store: store)

        case .multiSelection:
            EditorInspectorMultiSelectionContent(count: selectionCount)

        case .effects, .transition:
            placeholder(
                activeTab.title,
                "该属性页将在 P1 接入。"
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

    var body: some View {
        VStack(spacing: 10) {
            InspectorSection("变换") {
                InspectorRow("位置", String(
                    format: "%.2f, %.2f",
                    segment.transform.position.x,
                    segment.transform.position.y
                ))
                InspectorRow("缩放", percent(segment.transform.scale))
                InspectorRow("旋转", String(
                    format: "%.1f°",
                    segment.transform.rotation * 180 / .pi
                ))
                InspectorRow("不透明度", percent(segment.transform.opacity))
            }

            InspectorSection("速度") {
                InspectorRow("倍率", String(format: "%.2fx", segment.speed))
            }

            if case .video(let content) = segment.content {
                InspectorSection("内容") {
                    InspectorRow("填充", content.fit.rawValue)
                    InspectorRow("静音", content.isMuted ? "是" : "否")
                }
            }

            Text("属性编辑将在 P1 接入")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

// MARK: - Audio

private struct EditorInspectorAudioContent: View {
    let segment: EditorSegment

    var body: some View {
        if case .audio(let content) = segment.content {
            VStack(spacing: 10) {
                InspectorSection("音量") {
                    InspectorRow("音量", String(format: "%.0f%%", content.volume * 100))
                    InspectorRow("静音", content.isMuted ? "是" : "否")
                    InspectorRow("循环", content.isLooping ? "是" : "否")
                }

                InspectorSection("淡化") {
                    InspectorRow("淡入", String(format: "%.2fs", content.fadeInDuration))
                    InspectorRow("淡出", String(format: "%.2fs", content.fadeOutDuration))
                }

                InspectorSection("速度") {
                    InspectorRow("倍率", String(format: "%.2fx", segment.speed))
                }
            }
        }
    }
}

// MARK: - Color

private struct EditorInspectorColorContent: View {
    let segment: EditorSegment

    var body: some View {
        let adjustment = segment.adjustment
        VStack(spacing: 10) {
            InspectorSection("基础") {
                InspectorRow("亮度", String(format: "%.2f", adjustment.brightness))
                InspectorRow("对比度", String(format: "%.2f", adjustment.contrast))
                InspectorRow("饱和度", String(format: "%.2f", adjustment.saturation))
            }

            InspectorSection("色温") {
                InspectorRow("色温", String(format: "%.0fK", adjustment.temperature))
                InspectorRow("色调", String(format: "%.0f", adjustment.tint))
            }

            InspectorSection("滤镜") {
                InspectorRow("滤镜", adjustment.filterName?.rawValue ?? "无")
                InspectorRow("强度", String(format: "%.0f%%", adjustment.filterIntensity * 100))
            }
        }
    }
}

// MARK: - Animation

private struct EditorInspectorAnimationContent: View {
    let segment: EditorSegment

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

            Text("完整动画选择器将在 P1 接入")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Text

private struct EditorInspectorTextContent: View {
    let segment: EditorSegment
    let tab: EditorInspectorTab

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

            Text("文字属性编辑将在 P1 接入")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
                .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Project

private struct EditorInspectorProjectContent: View {
    let store: EditorStore

    var body: some View {
        VStack(spacing: 10) {
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
#endif

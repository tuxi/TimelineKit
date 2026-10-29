import Foundation

/// Tabs available in the large-screen inspector.
///
/// Tabs describe properties, not commands. Split/delete/copy/paste belong in
/// the toolbar or context menu, not here.
public enum EditorInspectorTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case video
    case audio
    case color
    case animation
    case text
    case layout
    case effects
    case transition
    case info
    case project
    case multiSelection

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .video:         return "视频"
        case .audio:         return "音频"
        case .color:         return "调色"
        case .animation:     return "动画"
        case .text:          return "文字"
        case .layout:        return "布局"
        case .effects:       return "效果"
        case .transition:    return "转场"
        case .info:          return "信息"
        case .project:       return "项目"
        case .multiSelection: return "多选"
        }
    }

    public var systemImage: String {
        switch self {
        case .video:         return "video"
        case .audio:         return "waveform"
        case .color:         return "camera.filters"
        case .animation:     return "wand.and.stars"
        case .text:          return "textformat"
        case .layout:        return "rectangle.3.group"
        case .effects:       return "sparkles"
        case .transition:    return "arrow.left.and.right.square"
        case .info:          return "info.circle"
        case .project:       return "film.stack"
        case .multiSelection: return "square.stack.3d.up"
        }
    }
}

/// The kind of content currently represented by the inspector.
public enum EditorInspectorContentKind: String, CaseIterable, Hashable, Sendable {
    case none
    case video
    case image
    case text
    case subtitle
    case audio
    case transition
    case multiple
    case mediaAsset
}

/// Pure tab decision for the inspector.
///
/// The context is derived from the current selection and decides which tabs are
/// available. It does not read the store or UI.
public struct EditorInspectorContext: Equatable, Sendable {
    public let kind: EditorInspectorContentKind
    public let availableTabs: [EditorInspectorTab]
    public let defaultTab: EditorInspectorTab

    public init(kind: EditorInspectorContentKind) {
        self.kind = kind

        switch kind {
        case .video:
            availableTabs = [.video, .audio, .color, .animation, .info]
            defaultTab = .video
        case .image:
            availableTabs = [.video, .color, .animation, .info]
            defaultTab = .video
        case .text, .subtitle:
            availableTabs = [.text, .layout, .animation, .info]
            defaultTab = .text
        case .audio:
            availableTabs = [.audio, .effects, .info]
            defaultTab = .audio
        case .transition:
            availableTabs = [.transition, .info]
            defaultTab = .transition
        case .none:
            availableTabs = [.project]
            defaultTab = .project
        case .multiple:
            availableTabs = [.multiSelection]
            defaultTab = .multiSelection
        case .mediaAsset:
            availableTabs = [.info]
            defaultTab = .info
        }
    }

    /// Keeps a compatible active tab, otherwise falls back to the kind's
    /// default tab.
    public func resolvedTab(preferred: EditorInspectorTab?) -> EditorInspectorTab {
        guard let preferred, availableTabs.contains(preferred) else {
            return defaultTab
        }
        return preferred
    }
}

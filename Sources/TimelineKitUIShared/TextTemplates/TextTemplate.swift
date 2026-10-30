import Foundation
import TimelineKitCore

/// A pre-styled, insertable text item — the editor's equivalent of a title or
/// caption preset.
///
/// Templates carry a complete `TextStyle` so inserting one produces a finished
/// look in a single tap; the user then edits the words, not the styling.
public struct TextTemplate: Identifiable, Sendable, Hashable {

    /// Which kind of track the template lands on.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// Text track: titles, lower thirds, credits.
        case title
        /// Subtitle track: burned-in captions.
        case caption
    }

    /// Grouping used by the picker's sections.
    public enum Group: String, Sendable, Hashable, CaseIterable {
        case title
        case lowerThird
        case caption

        public var displayName: String {
            switch self {
            case .title:      return "标题"
            case .lowerThird: return "落款"
            case .caption:    return "字幕样式"
            }
        }
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let group: Group
    /// Placeholder words inserted on the timeline; the user overwrites them.
    public let defaultText: String
    public let duration: Double
    public let style: TextStyle
    /// Only meaningful for `.title` templates.
    public let position: NormalizedPoint
    /// Only meaningful for `.title` templates.
    public let anchor: AnchorPoint
    /// Only meaningful for `.caption` templates (0 = top, 1 = bottom).
    public let subtitlePositionY: Double?
    public let maxCharsPerLine: Int?

    public init(
        id: String,
        name: String,
        kind: Kind,
        group: Group,
        defaultText: String,
        duration: Double = 3.0,
        style: TextStyle,
        position: NormalizedPoint = .center,
        anchor: AnchorPoint = .center,
        subtitlePositionY: Double? = nil,
        maxCharsPerLine: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.group = group
        self.defaultText = defaultText
        self.duration = duration
        self.style = style
        self.position = position
        self.anchor = anchor
        self.subtitlePositionY = subtitlePositionY
        self.maxCharsPerLine = maxCharsPerLine
    }

    /// Track kind the segment must be hosted on.
    public var trackKind: EditorTrack.Kind {
        kind == .title ? .text : .subtitle
    }
}

// MARK: - Built-in catalog

/// The shipped template set. Kept free of UIKit so the catalog and its
/// invariants can be tested on any platform.
public enum TextTemplateCatalog {

    public static let all: [TextTemplate] = titles + lowerThirds + captions

    public static func template(id: String) -> TextTemplate? {
        all.first { $0.id == id }
    }

    public static func templates(in group: TextTemplate.Group) -> [TextTemplate] {
        all.filter { $0.group == group }
    }

    // MARK: Titles

    public static let titles: [TextTemplate] = [
        TextTemplate(
            id: "title.center",
            name: "居中标题",
            kind: .title,
            group: .title,
            defaultText: "标题",
            style: TextStyle(
                fontSize: 56,
                fontWeight: .bold,
                color: "#FFFFFF",
                shadowColor: "#000000B3",
                shadowOffsetX: 0,
                shadowOffsetY: 2,
                shadowRadius: 8,
                kerning: 2
            )
        ),
        TextTemplate(
            id: "title.band",
            name: "黑底标题",
            kind: .title,
            group: .title,
            defaultText: "标题",
            style: TextStyle(
                fontSize: 44,
                fontWeight: .semibold,
                color: "#FFFFFF",
                backgroundColor: "#000000A6",
                backgroundRadius: 8,
                paddingH: 22,
                paddingV: 12
            )
        ),
        TextTemplate(
            id: "title.outline",
            name: "描边标题",
            kind: .title,
            group: .title,
            defaultText: "标题",
            style: TextStyle(
                fontSize: 52,
                fontWeight: .heavy,
                color: "#FFFFFF",
                strokeColor: "#000000",
                strokeWidth: 4,
                kerning: 1
            )
        ),
        TextTemplate(
            id: "title.accent",
            name: "高亮标题",
            kind: .title,
            group: .title,
            defaultText: "重点",
            style: TextStyle(
                fontSize: 60,
                fontWeight: .black,
                color: "#FFD400",
                strokeColor: "#1A1A1A",
                strokeWidth: 3,
                shadowColor: "#00000099",
                shadowOffsetX: 0,
                shadowOffsetY: 3,
                shadowRadius: 10
            )
        )
    ]

    // MARK: Lower thirds

    public static let lowerThirds: [TextTemplate] = [
        TextTemplate(
            id: "lowerThird.simple",
            name: "左下落款",
            kind: .title,
            group: .lowerThird,
            defaultText: "姓名 · 职位",
            style: TextStyle(
                fontSize: 30,
                fontWeight: .medium,
                color: "#FFFFFF",
                shadowColor: "#000000B3",
                shadowOffsetX: 0,
                shadowOffsetY: 1,
                shadowRadius: 6,
                alignment: .leading
            ),
            position: NormalizedPoint(x: 0.08, y: 0.82),
            anchor: .bottomLeft
        ),
        TextTemplate(
            id: "lowerThird.boxed",
            name: "左下落款·底条",
            kind: .title,
            group: .lowerThird,
            defaultText: "姓名 · 职位",
            style: TextStyle(
                fontSize: 26,
                fontWeight: .semibold,
                color: "#FFFFFF",
                backgroundColor: "#000000CC",
                backgroundRadius: 4,
                paddingH: 16,
                paddingV: 8,
                alignment: .leading
            ),
            position: NormalizedPoint(x: 0.08, y: 0.82),
            anchor: .bottomLeft
        )
    ]

    // MARK: Captions

    public static let captions: [TextTemplate] = [
        TextTemplate(
            id: "caption.shadow",
            name: "白字投影",
            kind: .caption,
            group: .caption,
            defaultText: "字幕内容",
            style: TextStyle(
                fontSize: 30,
                fontWeight: .semibold,
                color: "#FFFFFF",
                shadowColor: "#000000E6",
                shadowOffsetX: 0,
                shadowOffsetY: 2,
                shadowRadius: 4
            ),
            subtitlePositionY: 0.88,
            maxCharsPerLine: 18
        ),
        TextTemplate(
            id: "caption.yellow",
            name: "黄字黑边",
            kind: .caption,
            group: .caption,
            defaultText: "字幕内容",
            style: TextStyle(
                fontSize: 32,
                fontWeight: .bold,
                color: "#FFD400",
                strokeColor: "#000000",
                strokeWidth: 4
            ),
            subtitlePositionY: 0.88,
            maxCharsPerLine: 16
        ),
        TextTemplate(
            id: "caption.boxed",
            name: "底框字幕",
            kind: .caption,
            group: .caption,
            defaultText: "字幕内容",
            style: TextStyle(
                fontSize: 26,
                fontWeight: .medium,
                color: "#FFFFFF",
                backgroundColor: "#000000B3",
                backgroundRadius: 6,
                paddingH: 14,
                paddingV: 6
            ),
            subtitlePositionY: 0.86,
            maxCharsPerLine: 20
        ),
        TextTemplate(
            id: "caption.bilingual",
            name: "双语字幕",
            kind: .caption,
            group: .caption,
            defaultText: "第一行\nSecond line",
            duration: 4.0,
            style: TextStyle(
                fontSize: 26,
                fontWeight: .regular,
                color: "#FFFFFF",
                shadowColor: "#000000E6",
                shadowOffsetX: 0,
                shadowOffsetY: 2,
                shadowRadius: 4,
                lineSpacing: 4
            ),
            subtitlePositionY: 0.86,
            maxCharsPerLine: 22
        )
    ]
}

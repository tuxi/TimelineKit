import Foundation

/// v3 P1 (text-entry-spec §9.2): system font whitelist used by `.text` segments.
///
/// Stores UIFont family names and resolves to per-weight PostScript names.
/// Used by both `EditorPreviewView` (SwiftUI `.font(.custom(_:))`) and
/// `CompositionBuilder.makeCTFont` so preview and export render the same typeface.
public struct SystemFontFamily: Sendable, Hashable {
    /// Display name (Chinese, user-facing).
    public let displayName: String
    /// UIFont family name (e.g. "PingFang SC"). Stored in `TextStyle.fontName`.
    public let family: String
    /// PostScript name for each weight. Missing weights fall back to `defaultPostScript`.
    public let postScriptByWeight: [FontWeight: String]
    /// Used when the requested weight is absent from `postScriptByWeight`.
    public let defaultPostScript: String

    public func postScript(for weight: FontWeight) -> String {
        postScriptByWeight[weight] ?? defaultPostScript
    }
}

public enum SystemFontCatalog {

    // MARK: - Catalog

    public static let pingFang = SystemFontFamily(
        displayName: "苹方",
        family: "PingFang SC",
        postScriptByWeight: [
            .thin:     "PingFangSC-Light",
            .light:    "PingFangSC-Light",
            .regular:  "PingFangSC-Regular",
            .medium:   "PingFangSC-Regular",
            .semibold: "PingFangSC-Medium",
            .bold:     "PingFangSC-Semibold",
            .heavy:    "PingFangSC-Semibold",
            .black:    "PingFangSC-Semibold"
        ],
        defaultPostScript: "PingFangSC-Regular"
    )

    public static let songti = SystemFontFamily(
        displayName: "宋体",
        family: "Songti SC",
        postScriptByWeight: [
            .thin:  "STSongti-SC-Light",
            .light: "STSongti-SC-Light",
            .bold:  "STSongti-SC-Bold",
            .heavy: "STSongti-SC-Bold",
            .black: "STSongti-SC-Bold"
        ],
        defaultPostScript: "STSongti-SC-Regular"
    )

    public static let kaiti = SystemFontFamily(
        displayName: "楷体",
        family: "Kaiti SC",
        postScriptByWeight: [
            .bold:  "STKaitiSC-Bold",
            .heavy: "STKaitiSC-Bold",
            .black: "STKaitiSC-Bold"
        ],
        defaultPostScript: "STKaitiSC-Regular"
    )

    public static let yuanti = SystemFontFamily(
        displayName: "圆体",
        family: "Yuanti SC",
        postScriptByWeight: [
            .thin:  "STYuanti-SC-Light",
            .light: "STYuanti-SC-Light",
            .bold:  "STYuanti-SC-Bold",
            .heavy: "STYuanti-SC-Bold",
            .black: "STYuanti-SC-Bold"
        ],
        defaultPostScript: "STYuanti-SC-Regular"
    )

    public static let hanziPen = SystemFontFamily(
        displayName: "手写",
        family: "HanziPen SC",
        postScriptByWeight: [
            .thin:    "HanziPenSC-W3",
            .light:   "HanziPenSC-W3",
            .regular: "HanziPenSC-W3"
        ],
        defaultPostScript: "HanziPenSC-W5"
    )

    /// Display order shown in TextEditPanel font tab. PingFang first (default).
    public static let all: [SystemFontFamily] = [pingFang, songti, kaiti, yuanti, hanziPen]

    // MARK: - Resolution

    /// Look up a family by UIFont family name. Returns nil if not in the whitelist.
    public static func lookup(family: String) -> SystemFontFamily? {
        all.first { $0.family == family }
    }

    /// Resolve a TextStyle to a concrete PostScript font name. Falls back to PingFang SC
    /// when `fontName` is nil or not in the whitelist (e.g. user upgraded from a draft
    /// referencing a since-removed family).
    public static func resolvePostScript(fontName: String?, weight: FontWeight) -> String {
        if let name = fontName, let entry = lookup(family: name) {
            return entry.postScript(for: weight)
        }
        return pingFang.postScript(for: weight)
    }
}

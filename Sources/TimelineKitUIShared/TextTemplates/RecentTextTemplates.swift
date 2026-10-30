import Foundation

/// Most-recently-used ordering for text templates.
///
/// Kept separate from the picker so the ordering rules (dedupe, cap, unknown
/// ids) can be tested without a UI. Storage is an injected `UserDefaults` so
/// tests never touch the app's real preferences.
public struct RecentTextTemplates {

    public static let maxCount = 6
    public static let defaultKey = "timelinekit.editor.recentTextTemplates"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = RecentTextTemplates.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// Recently used template ids, newest first.
    public func ids() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// Moves `id` to the front, dropping duplicates and trimming to `maxCount`.
    @discardableResult
    public func record(_ id: String) -> [String] {
        var next = ids().filter { $0 != id }
        next.insert(id, at: 0)
        if next.count > Self.maxCount {
            next.removeLast(next.count - Self.maxCount)
        }
        defaults.set(next, forKey: key)
        return next
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }

    /// Recent templates that still exist in the catalog, newest first.
    ///
    /// Ids removed from the catalog are skipped rather than surfaced as blanks,
    /// so an older build's history cannot break the picker.
    public func templates(catalog: [TextTemplate] = TextTemplateCatalog.all) -> [TextTemplate] {
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        return ids().compactMap { byID[$0] }
    }
}

#if canImport(UIKit)
import SwiftUI
import TimelineKitUISharedViews

/// Selects the fixed legacy layout or the adaptive policy-driven workspace.
///
/// The default is `legacy` so existing hosts keep their current layout until
/// they opt in.
public enum EditorLayoutMode: String, CaseIterable, Equatable, Sendable {
    case legacy
    case adaptive
}

private struct EditorLayoutModeKey: EnvironmentKey {
    static let defaultValue: EditorLayoutMode = .legacy
}

public extension EnvironmentValues {
    /// Opt-in switch between the legacy fixed layout and the adaptive workspace.
    var editorLayoutMode: EditorLayoutMode {
        get { self[EditorLayoutModeKey.self] }
        set { self[EditorLayoutModeKey.self] = newValue }
    }
}
#endif

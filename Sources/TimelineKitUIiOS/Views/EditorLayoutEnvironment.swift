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

/// Selects the legacy tool rail/panel inspector or the tabbed property inspector
/// in wide landscape workspaces.
public enum EditorInspectorMode: String, CaseIterable, Equatable, Sendable {
    case legacy
    case tabbed
}

private struct EditorLayoutModeKey: EnvironmentKey {
    static let defaultValue: EditorLayoutMode = .legacy
}

private struct EditorInspectorModeKey: EnvironmentKey {
    static let defaultValue: EditorInspectorMode = .legacy
}

public extension EnvironmentValues {
    /// Opt-in switch between the legacy fixed layout and the adaptive workspace.
    var editorLayoutMode: EditorLayoutMode {
        get { self[EditorLayoutModeKey.self] }
        set { self[EditorLayoutModeKey.self] = newValue }
    }

    /// Opt-in switch for the tabbed wide-landscape inspector.
    var editorInspectorMode: EditorInspectorMode {
        get { self[EditorInspectorModeKey.self] }
        set { self[EditorInspectorModeKey.self] = newValue }
    }
}
#endif

#if canImport(UIKit)
import UIKit
import TimelineKitUISharedViews

/// Lives above SwiftUI's stacked/workspace/folded branches. A new platform
/// controller restores the last viewport, while a late dismantle/update from
/// the previous branch cannot overwrite the new owner's state.
@MainActor
final class EditorTrackViewportSession {
    var snapshot: TimelineViewportSnapshot?
    var labelsExpanded = false
    private weak var owner: ClipEditorViewController?

    func attach(_ controller: ClipEditorViewController) {
        owner?.prepareForRemoval()
        owner = controller
    }

    func owns(_ controller: ClipEditorViewController) -> Bool {
        owner === controller
    }

    /// True when a *different* controller has taken over the viewport.
    ///
    /// A layout-branch switch (rotation, fold, size-class change) dismantles the
    /// current controller and immediately builds a replacement. A real exit
    /// leaves `owner` nil. Callers use this to tell the two apart after the view
    /// has left the window.
    func hasReplacement(for controller: ClipEditorViewController) -> Bool {
        guard let owner else { return false }
        return owner !== controller
    }

    func detach(_ controller: ClipEditorViewController) {
        if owns(controller) { owner = nil }
    }
}
#endif

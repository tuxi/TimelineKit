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

    func detach(_ controller: ClipEditorViewController) {
        if owns(controller) { owner = nil }
    }
}
#endif

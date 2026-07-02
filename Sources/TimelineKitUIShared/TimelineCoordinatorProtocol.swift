import Foundation
import CoreMedia
import TimelineKitCore

/// Methods EditorStore calls on the coordinator.
/// Concrete implementation: CompositionCoordinator in TimelineKit umbrella.
@MainActor
public protocol TimelineCoordinatorProtocol: AnyObject {
    func refreshTimelineRuntimeTextLayers(timeline: EditorTimeline)
    func setTimelineRuntimePlaybackActive(_ active: Bool)
    func prepareTimelineRuntimeForSeek(to time: CMTime)
    func renderFrameAndFlush()
    func applyAudioMixOnly(timeline: EditorTimeline)
}

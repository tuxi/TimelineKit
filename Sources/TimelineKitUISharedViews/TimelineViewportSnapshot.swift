import Foundation
import CoreGraphics

/// Viewport state expressed in timeline coordinates, independent of a UIKit
/// controller's lifetime or its current pixel width. The center time is kept
/// stable while the viewport changes size; zoom and vertical position survive
/// rebuilding the platform view.
@MainActor
public struct TimelineViewportSnapshot: Equatable, Sendable {
    public let timelineID: UUID
    public let anchorTime: Double
    public let pixelsPerSecond: CGFloat
    public let verticalOffset: CGFloat

    public init(
        timelineID: UUID,
        layout: TimelineTrackLayout,
        contentOffset: CGPoint,
        viewportWidth: CGFloat,
        preservingAnchorTime: Double? = nil
    ) {
        self.timelineID = timelineID
        anchorTime = min(layout.duration, max(0,
            preservingAnchorTime ?? layout.time(at: contentOffset.x + viewportWidth / 2)
        ))
        pixelsPerSecond = layout.pixelsPerSecond
        verticalOffset = max(0, contentOffset.y)
    }

    /// The iOS timeline uses half-viewport horizontal insets so its beginning
    /// and end can both be centered. Clamp again against the CURRENT content
    /// after edits, track removal, or a taller viewport.
    public func restoredOffset(
        layout: TimelineTrackLayout,
        viewportSize: CGSize,
        contentSize: CGSize
    ) -> CGPoint {
        let halfWidth = max(0, viewportSize.width) / 2
        let minX = -halfWidth
        let maxX = max(minX, contentSize.width - halfWidth)
        let time = min(max(0, anchorTime), layout.duration)
        return CGPoint(
            x: min(max(layout.x(for: time) - halfWidth, minX), maxX),
            y: min(verticalOffset, max(0, contentSize.height - viewportSize.height))
        )
    }
}

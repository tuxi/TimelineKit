import XCTest
import CoreGraphics
@testable import TimelineKitUISharedViews

@MainActor
final class TimelineViewportSnapshotTests: XCTestCase {
    private let id = UUID()
    private let layout = TimelineTrackLayout(duration: 100, pixelsPerSecond: 80)

    func testResizePreservesCenterTimeInsteadOfPixelOffset() {
        let snapshot = capture(time: 37, width: 780)
        let offset = snapshot.restoredOffset(
            layout: layout, viewportSize: CGSize(width: 320, height: 200),
            contentSize: CGSize(width: layout.totalWidth, height: 600)
        )
        XCTAssertEqual(layout.time(at: offset.x + 160), 37, accuracy: 0.0001)
        XCTAssertEqual(snapshot.pixelsPerSecond, 80)
        XCTAssertEqual(snapshot.timelineID, id)
    }

    func testRepeatedFoldAndUnfoldDoesNotAccumulateDrift() {
        var snapshot = capture(time: 53.125, width: 780)
        for width in [320.0, 834, 395, 1032, 402, 780] {
            let offset = snapshot.restoredOffset(
                layout: layout, viewportSize: CGSize(width: width, height: 200),
                contentSize: CGSize(width: layout.totalWidth, height: 600)
            )
            snapshot = TimelineViewportSnapshot(
                timelineID: id, layout: layout, contentOffset: offset, viewportWidth: width
            )
            XCTAssertEqual(snapshot.anchorTime, 53.125, accuracy: 0.0001)
        }
    }

    func testRestorationUsesNewLayoutScaleAndPadding() {
        let snapshot = capture(time: 12, width: 780)
        let newLayout = TimelineTrackLayout(duration: 100, pixelsPerSecond: 160, leftPadding: 24)
        let offset = snapshot.restoredOffset(
            layout: newLayout, viewportSize: CGSize(width: 400, height: 200),
            contentSize: CGSize(width: newLayout.totalWidth, height: 600)
        )
        XCTAssertEqual(newLayout.time(at: offset.x + 200), 12, accuracy: 0.0001)
    }

    func testProgrammaticRestorationPreservesLogicalTimeDespiteRoundedPixels() {
        let snapshot = TimelineViewportSnapshot(
            timelineID: id, layout: layout,
            contentOffset: CGPoint(x: layout.x(for: 12) - 200 + 1.0 / 3.0, y: 40),
            viewportWidth: 400, preservingAnchorTime: 12
        )
        XCTAssertEqual(snapshot.anchorTime, 12)
        XCTAssertEqual(snapshot.verticalOffset, 40)
    }

    func testShortenedTimelineClampsAnchorToNewEnd() {
        let snapshot = capture(time: 90, width: 780)
        let short = TimelineTrackLayout(duration: 20, pixelsPerSecond: 80)
        let offset = snapshot.restoredOffset(
            layout: short, viewportSize: CGSize(width: 400, height: 200),
            contentSize: CGSize(width: short.totalWidth, height: 600)
        )
        XCTAssertEqual(short.time(at: offset.x + 200), 20, accuracy: 0.0001)
    }

    func testStartAndEndCanRemainCentered() {
        for time in [0.0, 100.0] {
            let snapshot = capture(time: time, width: 780)
            let offset = snapshot.restoredOffset(
                layout: layout, viewportSize: CGSize(width: 400, height: 200),
                contentSize: CGSize(width: layout.totalWidth, height: 600)
            )
            XCTAssertEqual(layout.time(at: offset.x + 200), time, accuracy: 0.0001)
        }
    }

    func testVerticalOffsetPreservedAndClampedAfterTrackRemoval() {
        let snapshot = capture(time: 37, width: 780, y: 270)
        let preserved = snapshot.restoredOffset(
            layout: layout, viewportSize: CGSize(width: 400, height: 200),
            contentSize: CGSize(width: layout.totalWidth, height: 600)
        )
        XCTAssertEqual(preserved.y, 270)
        let clamped = snapshot.restoredOffset(
            layout: layout, viewportSize: CGSize(width: 400, height: 200),
            contentSize: CGSize(width: layout.totalWidth, height: 250)
        )
        XCTAssertEqual(clamped.y, 50)
    }

    func testBounceDoesNotPersistNegativeTimeOrVerticalPosition() {
        let snapshot = TimelineViewportSnapshot(
            timelineID: id, layout: layout,
            contentOffset: CGPoint(x: -800, y: -40), viewportWidth: 400
        )
        XCTAssertEqual(snapshot.anchorTime, 0)
        XCTAssertEqual(snapshot.verticalOffset, 0)
    }

    func testEmptyTimelineAndTallerViewportProduceValidOffset() {
        let empty = TimelineTrackLayout(duration: 0, pixelsPerSecond: 60)
        let snapshot = TimelineViewportSnapshot(
            timelineID: id, layout: empty, contentOffset: .zero, viewportWidth: 400
        )
        let offset = snapshot.restoredOffset(
            layout: empty, viewportSize: CGSize(width: 800, height: 500),
            contentSize: CGSize(width: empty.totalWidth, height: 200)
        )
        XCTAssertEqual(offset.x, empty.x(for: 0) - 400)
        XCTAssertEqual(offset.y, 0)
    }

    private func capture(time: Double, width: CGFloat, y: CGFloat = 0) -> TimelineViewportSnapshot {
        TimelineViewportSnapshot(
            timelineID: id, layout: layout,
            contentOffset: CGPoint(x: layout.x(for: time) - width / 2, y: y),
            viewportWidth: width
        )
    }
}

#if canImport(UIKit)
import XCTest
import UIKit
import TimelineKitCore
import TimelineKitUIShared
import TimelineKitUISharedViews
@testable import TimelineKitUIiOS

@MainActor
final class TrackViewportLifecycleTests: XCTestCase {
    func testRepeatedControllerRecreationDoesNotAccumulatePixelRoundingDrift() throws {
        let (store, session) = fixture()
        var controller = mount(store: store, session: session, size: CGSize(width: 834, height: 220))
        let (scroll, canvas) = try trackViews(controller)
        scroll.contentOffset.x = canvas.x(for: 30) - scroll.bounds.width / 2
        let anchor = try XCTUnwrap(session.snapshot).anchorTime
        for index in 0..<24 {
            let width: CGFloat = index.isMultiple(of: 2) ? 395 : 834
            controller = mount(store: store, session: session, size: CGSize(width: width, height: 220))
            XCTAssertEqual(try XCTUnwrap(session.snapshot).anchorTime, anchor, accuracy: 0.000001)
        }
        controller.prepareForRemoval()
    }

    func testResizePreservesZoomTimeAndVerticalPositionWithoutEditingDocument() throws {
        let (store, session) = fixture()
        let controller = mount(store: store, session: session, size: CGSize(width: 834, height: 220))
        let (scroll, canvas) = try trackViews(controller)
        canvas.zoom(to: 120, playheadTime: 0)
        scroll.contentOffset = CGPoint(x: canvas.x(for: 35) - scroll.bounds.width / 2, y: 90)
        let anchor = centerTime(scroll, canvas)
        let timeline = store.timeline
        let playhead = store.selection.playheadTime
        let canUndo = store.canUndo

        for size in [CGSize(width: 395, height: 300), CGSize(width: 1032, height: 220), CGSize(width: 402, height: 220)] {
            controller.view.frame.size = size
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            XCTAssertEqual(centerTime(scroll, canvas), anchor, accuracy: pixelTime(scroll, canvas))
            XCTAssertEqual(canvas.currentPixelsPerSecond, 120)
            XCTAssertEqual(scroll.contentOffset.y, 90, accuracy: 0.001)
        }
        XCTAssertEqual(store.timeline, timeline)
        XCTAssertEqual(store.selection.playheadTime, playhead)
        XCTAssertEqual(store.canUndo, canUndo)
    }

    func testNewControllerRestoresSessionAndLateDismantleCannotOverwriteIt() throws {
        let (store, session) = fixture()
        let first = mount(store: store, session: session, size: CGSize(width: 834, height: 220))
        let (oldScroll, oldCanvas) = try trackViews(first)
        oldCanvas.zoom(to: 150, playheadTime: 0)
        oldScroll.contentOffset = CGPoint(x: oldCanvas.x(for: 45) - oldScroll.bounds.width / 2, y: 80)
        let anchor = centerTime(oldScroll, oldCanvas)

        let second = mount(store: store, session: session, size: CGSize(width: 395, height: 300))
        let (scroll, canvas) = try trackViews(second)
        XCTAssertEqual(centerTime(scroll, canvas), anchor, accuracy: pixelTime(scroll, canvas))
        XCTAssertEqual(canvas.currentPixelsPerSecond, 150)
        XCTAssertEqual(scroll.contentOffset.y, 80, accuracy: 0.001)

        scroll.contentOffset.x = canvas.x(for: 60) - scroll.bounds.width / 2
        let nextAnchor = centerTime(scroll, canvas)
        first.prepareForRemoval()
        oldScroll.contentOffset.x = oldCanvas.x(for: 5)
        first.apply(timeline: store.timeline, selection: store.selection)
        XCTAssertTrue(session.owns(second))
        XCTAssertEqual(try XCTUnwrap(session.snapshot).anchorTime, nextAnchor, accuracy: 0.0001)
    }

    func testZeroSizeUpdateDefersInitialFitUntilRealLayout() throws {
        let (store, session) = fixture()
        let controller = ClipEditorViewController(store: store, viewportSession: session)
        controller.loadViewIfNeeded()
        controller.apply(timeline: store.timeline, selection: store.selection)
        controller.view.frame.size = CGSize(width: 834, height: 220)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let (scroll, canvas) = try trackViews(controller)
        XCTAssertGreaterThan(scroll.bounds.width, 0)
        XCTAssertEqual(centerTime(scroll, canvas), store.selection.playheadTime, accuracy: 0.001)
        XCTAssertNotNil(session.snapshot)
    }

    func testMinimumZoomSurvivesStructuralReconfigure() throws {
        let (store, session) = fixture()
        let controller = mount(store: store, session: session, size: CGSize(width: 1032, height: 220))
        let (_, canvas) = try trackViews(controller)
        canvas.zoom(to: TrackCanvasView.minPixelsPerSecond, playheadTime: 0)
        var short = store.timeline
        short.tracks[0].segments[0].targetRange = TimeRange(start: 0, duration: 1)
        short.tracks.append(EditorTrack(kind: .audio, isMainTrack: false))
        controller.apply(timeline: short, selection: store.selection)
        XCTAssertEqual(canvas.currentPixelsPerSecond, TrackCanvasView.minPixelsPerSecond)
    }

    func testAnotherProjectDoesNotRestorePreviousTimeOrZoom() throws {
        let (store, session) = fixture()
        let first = mount(store: store, session: session, size: CGSize(width: 834, height: 220))
        let (scroll, canvas) = try trackViews(first)
        canvas.zoom(to: 150, playheadTime: 0)
        scroll.contentOffset.x = canvas.x(for: 45) - scroll.bounds.width / 2
        let (other, _) = fixture()
        let second = mount(store: other, session: session, size: CGSize(width: 395, height: 300))
        let (newScroll, newCanvas) = try trackViews(second)
        XCTAssertEqual(centerTime(newScroll, newCanvas), 0, accuracy: pixelTime(newScroll, newCanvas))
        XCTAssertNotEqual(newCanvas.currentPixelsPerSecond, 150)
    }

    func testRemovedControllerIsReleasedByViewportSession() {
        let (store, session) = fixture()
        weak var released: ClipEditorViewController?
        autoreleasepool {
            let controller = mount(store: store, session: session, size: CGSize(width: 834, height: 220))
            released = controller
            controller.prepareForRemoval()
        }
        XCTAssertNil(released)
    }

    func testResizeDuringScrollScrubDoesNotSeekUsingNewWidth() throws {
        let (store, session) = fixture()
        let controller = mount(store: store, session: session, size: CGSize(width: 834, height: 220))
        let (scroll, canvas) = try trackViews(controller)
        scroll.contentOffset.x = canvas.x(for: 30) - scroll.bounds.width / 2
        let anchor = centerTime(scroll, canvas)
        controller.scrollViewWillBeginDragging(scroll)
        let before = store.selection.playheadTime
        controller.view.frame.size = CGSize(width: 395, height: 300)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(store.selection.playheadTime, before)
        XCTAssertEqual(centerTime(scroll, canvas), anchor, accuracy: pixelTime(scroll, canvas))
    }

    private func fixture() -> (EditorStore, EditorTrackViewportSession) {
        let segment = EditorSegment(
            materialID: UUID(), targetRange: TimeRange(start: 0, duration: 100),
            content: .video(.init())
        )
        let tracks = [EditorTrack(kind: .video, segments: [segment], isMainTrack: true)]
            + (0..<10).map { _ in EditorTrack(kind: .audio, isMainTrack: false) }
        return (
            EditorStore(timeline: EditorTimeline(
                canvas: EditorCanvas(width: 1920, height: 1080, fps: 30), tracks: tracks
            )),
            EditorTrackViewportSession()
        )
    }

    private func mount(store: EditorStore, session: EditorTrackViewportSession, size: CGSize) -> ClipEditorViewController {
        let controller = ClipEditorViewController(store: store, viewportSession: session)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return controller
    }

    private func trackViews(_ controller: ClipEditorViewController) throws -> (UIScrollView, TrackCanvasView) {
        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UIScrollView }.first)
        let canvas = try XCTUnwrap(scroll.subviews.compactMap { $0 as? TrackCanvasView }.first)
        return (scroll, canvas)
    }

    private func centerTime(_ scroll: UIScrollView, _ canvas: TrackCanvasView) -> Double {
        canvas.time(at: scroll.contentOffset.x + scroll.bounds.width / 2)
    }

    /// UIScrollView rounds offsets to physical pixels. Validate against the
    /// actual captured time with at most one physical pixel of error.
    private func pixelTime(_ scroll: UIScrollView, _ canvas: TrackCanvasView) -> Double {
        1 / Double(canvas.currentPixelsPerSecond * max(scroll.traitCollection.displayScale, 1))
    }
}
#endif

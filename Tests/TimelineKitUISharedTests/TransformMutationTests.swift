import XCTest
import TimelineKitCore
@testable import TimelineKitUIShared

@MainActor
final class TransformMutationTests: XCTestCase {

    func testPreviewUpdatesWithoutUndoAndCommitCreatesUndoEntry() {
        let materialID = UUID()
        let segment = EditorSegment(
            materialID: materialID,
            targetRange: TimeRange(start: 0, duration: 5),
            content: .video(.init())
        )
        var timeline = EditorTimeline(
            canvas: EditorCanvas(width: 1920, height: 1080)
        )
        timeline.tracks = [
            EditorTrack(
                kind: .video,
                segments: [segment],
                isMainTrack: true
            )
        ]
        let store = EditorStore(timeline: timeline)

        var transform = segment.transform
        transform.position = NormalizedPoint(x: 0.25, y: 0.75)
        transform.scale = 1.5
        transform.rotation = .pi / 4
        transform.opacity = 0.5

        store.previewTransform(segmentID: segment.id, transform: transform)

        let previewed = store.timeline.segment(id: segment.id)?.transform
        XCTAssertEqual(previewed?.position.x, 0.25)
        XCTAssertEqual(previewed?.position.y, 0.75)
        XCTAssertEqual(previewed?.scale, 1.5)
        XCTAssertEqual(previewed?.rotation, .pi / 4)
        XCTAssertEqual(previewed?.opacity, 0.5)
        XCTAssertFalse(store.canUndo)

        store.setTransform(
            segmentID: segment.id,
            transform: transform,
            undoBase: .identity
        )

        XCTAssertTrue(store.canUndo)
        XCTAssertEqual(store.lastUndoLabel, "调整变换")

        store.undo()

        let restored = store.timeline.segment(id: segment.id)?.transform
        XCTAssertEqual(restored, .identity)
    }
}

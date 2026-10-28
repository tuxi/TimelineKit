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

    func testAdjustmentUndoBaseRestoresPreDragState() {
        let (store, segmentID) = makeVideoStore()

        var adjustment = SegmentAdjustment.identity
        adjustment.brightness = 0.4
        adjustment.saturation = 1.2

        store.previewAdjustment(segmentID: segmentID, adjustment: adjustment)
        store.setAdjustment(
            segmentID: segmentID,
            adjustment: adjustment,
            undoBase: .identity
        )
        store.undo()

        XCTAssertEqual(
            store.timeline.segment(id: segmentID)?.adjustment,
            .identity
        )
    }

    func testAudioVolumeUndoBaseRestoresPreDragState() {
        let audio = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 0, duration: 3),
            content: .audio(.init(volume: 1.0))
        )
        var timeline = EditorTimeline(
            canvas: EditorCanvas(width: 1920, height: 1080)
        )
        timeline.tracks = [
            EditorTrack(
                kind: .audio,
                segments: [audio],
                isMainTrack: false
            )
        ]
        let store = EditorStore(timeline: timeline)

        store.previewAudioVolume(segmentID: audio.id, volume: 0.4)
        store.setAudioVolume(
            segmentID: audio.id,
            volume: 0.4,
            undoBase: 1.0
        )
        store.undo()

        guard case .audio(let content) = store.timeline
            .segment(id: audio.id)?.content else {
            return XCTFail("audio segment missing")
        }
        XCTAssertEqual(content.volume, 1.0, accuracy: 0.001)
    }

    private func makeVideoStore() -> (EditorStore, UUID) {
        let segment = EditorSegment(
            materialID: UUID(),
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
        return (EditorStore(timeline: timeline), segment.id)
    }
}

import XCTest
import TimelineKitCore
@testable import TimelineKitUIShared

@MainActor
final class VisualInsertionTests: XCTestCase {

    func testMainTrackInsertionRemovesTransitionBetweenSplitSegments() throws {
        let first = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 0, duration: 3),
            content: .image(.init())
        )
        let second = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 3, duration: 3),
            content: .image(.init())
        )

        var timeline = EditorTimeline(
            canvas: EditorCanvas(width: 1920, height: 1080)
        )
        timeline.metadata.canvasSizingMode = .fixed
        timeline.tracks = [
            EditorTrack(
                kind: .video,
                segments: [first, second],
                isMainTrack: true
            )
        ]
        _ = timeline.addTransition(
            between: first.id,
            and: second.id,
            type: .fade,
            duration: 0.5
        )
        let store = EditorStore(timeline: timeline)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("insertion-transition-cleanup.png")

        _ = store.addVisualSegment(
            localURL: url,
            nativeDuration: nil,
            startTime: 3.5,
            targetTrackID: nil
        )

        XCTAssertTrue(store.timeline.transitions.isEmpty)
    }

    func testDropInsertionSnapsToNearestCutAndShiftsLaterClips() throws {
        let first = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 0, duration: 3),
            content: .image(.init())
        )
        let second = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 3, duration: 3),
            content: .image(.init())
        )

        var timeline = EditorTimeline(
            canvas: EditorCanvas(width: 1920, height: 1080)
        )
        timeline.metadata.canvasSizingMode = .fixed
        timeline.tracks = [
            EditorTrack(
                kind: .video,
                segments: [first, second],
                isMainTrack: true
            )
        ]
        let store = EditorStore(timeline: timeline)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("insertion-fixture.png")

        let insertedID = store.addVisualSegment(
            localURL: url,
            nativeDuration: nil,
            startTime: 3.5,
            targetTrackID: nil
        )

        let segments = store.timeline.mainTrack?.segments ?? []
        let inserted = try XCTUnwrap(segments.first { $0.id == insertedID })
        XCTAssertEqual(inserted.targetRange.start, 3, accuracy: 0.001)
        XCTAssertEqual(inserted.targetRange.duration, 3, accuracy: 0.001)

        let shiftedSecond = try XCTUnwrap(segments.first { $0.id == second.id })
        XCTAssertEqual(shiftedSecond.targetRange.start, 6, accuracy: 0.001)

        XCTAssertEqual(
            segments.map(\.targetRange.start),
            [0, 3, 6]
        )
    }
}

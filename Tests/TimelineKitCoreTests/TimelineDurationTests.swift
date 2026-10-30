import XCTest
@testable import TimelineKitCore

final class TimelineDurationTests: XCTestCase {

    private func makeTimeline(
        mainSegments: [EditorSegment] = [],
        otherTracks: [EditorTrack] = []
    ) -> EditorTimeline {
        let mainTrack = EditorTrack(
            id: UUID(),
            kind: .video,
            segments: mainSegments,
            isMainTrack: true
        )
        var tracks = [mainTrack] + otherTracks
        // Remove empty main track if no main segments and no other tracks
        if mainSegments.isEmpty && otherTracks.isEmpty {
            tracks = []
        }
        return EditorTimeline(
            canvas: EditorCanvas(width: 720, height: 1280),
            tracks: tracks
        )
    }

    // MARK: - Main track only

    func testDurationMainTrackOnly() {
        let seg = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 0, duration: 10),
            content: .video(.init())
        )
        let tl = makeTimeline(mainSegments: [seg])
        XCTAssertEqual(tl.duration, 10, accuracy: 0.001)
    }

    func testDurationEmptyTimeline() {
        let tl = EditorTimeline(canvas: EditorCanvas(width: 720, height: 1280))
        XCTAssertEqual(tl.duration, 0, accuracy: 0.001)
    }

    // MARK: - Text extending past main track

    func testDurationTextExtendsPastMainTrack() {
        let video = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 0, duration: 5),
            content: .video(.init())
        )
        let textSeg = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 4, duration: 4),
            content: .text(.init(text: "End title", style: .default, position: .center, anchor: .center))
        )
        let textTrack = EditorTrack(id: UUID(), kind: .text, segments: [textSeg])
        let tl = makeTimeline(mainSegments: [video], otherTracks: [textTrack])
        // main = 5, text ends at 8
        XCTAssertEqual(tl.duration, 8, accuracy: 0.001)
    }

    func testDurationSubtitleExtendsPastMainTrack() {
        let video = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 0, duration: 3),
            content: .video(.init())
        )
        let subSeg = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 2, duration: 5),
            content: .subtitle(.init(text: "Outro", style: .default))
        )
        let subTrack = EditorTrack(id: UUID(), kind: .subtitle, segments: [subSeg])
        let tl = makeTimeline(mainSegments: [video], otherTracks: [subTrack])
        // main = 3, subtitle ends at 7
        XCTAssertEqual(tl.duration, 7, accuracy: 0.001)
    }

    // MARK: - Text before main track

    func testDurationTextBeforeMainTrack() {
        let video = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 0, duration: 5),
            content: .video(.init())
        )
        let textSeg = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: -2, duration: 2),
            content: .text(.init(text: "Intro", style: .default, position: .center, anchor: .center))
        )
        let textTrack = EditorTrack(id: UUID(), kind: .text, segments: [textSeg])
        let tl = makeTimeline(mainSegments: [video], otherTracks: [textTrack])
        // main = 5, text ends at 0, so duration = 5
        XCTAssertEqual(tl.duration, 5, accuracy: 0.001)
    }

    // MARK: - Multiple tracks

    func testDurationMultipleAuxiliaryTracks() {
        let video = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 0, duration: 6),
            content: .video(.init())
        )
        let textSeg = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 5, duration: 3),
            content: .text(.init(text: "T", style: .default, position: .center, anchor: .center))
        )
        let audioSeg = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 7, duration: 4),
            content: .audio(.init())
        )
        let tl = makeTimeline(
            mainSegments: [video],
            otherTracks: [
                EditorTrack(id: UUID(), kind: .text, segments: [textSeg]),
                EditorTrack(id: UUID(), kind: .audio, segments: [audioSeg]),
            ]
        )
        // main = 6, text ends at 8, audio ends at 11
        XCTAssertEqual(tl.duration, 11, accuracy: 0.001)
    }

    // MARK: - No main track (text-only timeline)

    func testDurationNoMainTrackTextOnly() {
        let textSeg = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 0, duration: 5),
            content: .text(.init(text: "Title", style: .default, position: .center, anchor: .center))
        )
        let tl = EditorTimeline(
            canvas: EditorCanvas(width: 720, height: 1280),
            tracks: [EditorTrack(id: UUID(), kind: .text, segments: [textSeg])]
        )
        XCTAssertEqual(tl.duration, 5, accuracy: 0.001)
    }
}

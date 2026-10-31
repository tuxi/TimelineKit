import XCTest
@testable import TimelineKitCore

@MainActor
final class TextMutationRebuildTests: XCTestCase {

    private func document(mainDuration: Double = 5) -> TimelineDocument {
        let material = EditorAsset(type: .video)
        let segment = EditorSegment(
            materialID: material.id,
            targetRange: TimeRange(start: 0, duration: mainDuration),
            content: .video(.init())
        )
        var timeline = EditorTimeline(canvas: EditorCanvas(width: 720, height: 1280))
        timeline.materials.add(material)
        timeline.tracks = [EditorTrack(kind: .video, segments: [segment], isMainTrack: true)]
        return TimelineDocument(timeline: timeline)
    }

    private func textSegment(start: Double, duration: Double) -> EditorSegment {
        EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: start, duration: duration),
            content: .text(.init(text: "Title", style: .default, position: .center, anchor: .center))
        )
    }

    // MARK: - Adding

    func testAddingTextPastMainTrackBumpsCompositionVersion() {
        let doc = document(mainDuration: 5)
        let before = doc.compositionVersion

        doc.addSegmentAutoTrack(kind: .text, segment: textSegment(start: 6, duration: 3))

        XCTAssertEqual(doc.timeline.duration, 9, accuracy: 0.001)
        XCTAssertGreaterThan(doc.compositionVersion, before,
                             "A caption past the main track must trigger a composition rebuild")
    }

    func testAddingTextInsideMainTrackDoesNotBumpCompositionVersion() {
        let doc = document(mainDuration: 5)
        let before = doc.compositionVersion

        doc.addSegmentAutoTrack(kind: .text, segment: textSegment(start: 1, duration: 2))

        XCTAssertEqual(doc.timeline.duration, 5, accuracy: 0.001)
        XCTAssertEqual(doc.compositionVersion, before,
                       "An overlay caption keeps the lightweight text path")
    }

    func testAddingSubtitlePastMainTrackBumpsCompositionVersion() {
        let doc = document(mainDuration: 4)
        let before = doc.compositionVersion

        let subtitle = EditorSegment(
            materialID: UUID(),
            targetRange: TimeRange(start: 5, duration: 2),
            content: .subtitle(.init(text: "Outro", style: .default))
        )
        doc.addSegmentAutoTrack(kind: .subtitle, segment: subtitle)

        XCTAssertEqual(doc.timeline.duration, 7, accuracy: 0.001)
        XCTAssertGreaterThan(doc.compositionVersion, before)
    }

    // MARK: - Editing content (no timing change)

    func testEditingTextContentDoesNotBumpCompositionVersion() {
        let doc = document(mainDuration: 5)
        let segment = textSegment(start: 1, duration: 2)
        doc.addSegmentAutoTrack(kind: .text, segment: segment)
        let versionAfterAdd = doc.compositionVersion

        doc.mutateTextContent(segmentID: segment.id) { $0.text = "New words" }

        XCTAssertEqual(doc.compositionVersion, versionAfterAdd)
        XCTAssertEqual(doc.timeline.duration, 5, accuracy: 0.001)
        guard case .text(let content)? = doc.timeline.segment(id: segment.id)?.content else {
            return XCTFail("text segment missing")
        }
        XCTAssertEqual(content.text, "New words")
    }

    // MARK: - Trimming

    func testTrimmingTextPastMainTrackBumpsCompositionVersion() {
        let doc = document(mainDuration: 5)
        let segment = textSegment(start: 1, duration: 2)
        doc.addSegmentAutoTrack(kind: .text, segment: segment)
        let before = doc.compositionVersion

        doc.trimSegment(id: segment.id, newTargetRange: TimeRange(start: 1, duration: 8))

        XCTAssertEqual(doc.timeline.duration, 9, accuracy: 0.001)
        XCTAssertGreaterThan(doc.compositionVersion, before)
    }

    func testTrimmingTextInsideMainTrackDoesNotBumpCompositionVersion() {
        let doc = document(mainDuration: 10)
        let segment = textSegment(start: 1, duration: 2)
        doc.addSegmentAutoTrack(kind: .text, segment: segment)
        let before = doc.compositionVersion

        doc.trimSegment(id: segment.id, newTargetRange: TimeRange(start: 1, duration: 4))

        XCTAssertEqual(doc.timeline.duration, 10, accuracy: 0.001)
        XCTAssertEqual(doc.compositionVersion, before)
    }

    // MARK: - Preview then commit (trim handle gesture)

    func testPreviewThenTrimCommitPastMainTrackBumpsCompositionVersion() {
        let doc = document(mainDuration: 5)
        let segment = textSegment(start: 1, duration: 2)
        doc.addSegmentAutoTrack(kind: .text, segment: segment)
        let before = doc.compositionVersion

        // Live trim preview writes the model without bumping the version.
        doc.previewTrimRange(segmentID: segment.id, range: TimeRange(start: 1, duration: 8))
        XCTAssertEqual(doc.compositionVersion, before, "Preview must stay lightweight")
        XCTAssertEqual(doc.timeline.duration, 9, accuracy: 0.001)

        // Commit compares against the last built composition length (5), not
        // against the already-previewed timeline.
        doc.trimSegment(id: segment.id, newTargetRange: TimeRange(start: 1, duration: 8))

        XCTAssertGreaterThan(doc.compositionVersion, before,
                             "Committing a previewed trim past the main track must rebuild")
        XCTAssertEqual(doc.timeline.duration, 9, accuracy: 0.001)
    }

    func testPreviewThenTrimCommitInsideMainTrackDoesNotBumpCompositionVersion() {
        let doc = document(mainDuration: 10)
        let segment = textSegment(start: 1, duration: 2)
        doc.addSegmentAutoTrack(kind: .text, segment: segment)
        let before = doc.compositionVersion

        doc.previewTrimRange(segmentID: segment.id, range: TimeRange(start: 1, duration: 4))
        doc.trimSegment(id: segment.id, newTargetRange: TimeRange(start: 1, duration: 4))

        XCTAssertEqual(doc.compositionVersion, before)
        XCTAssertEqual(doc.timeline.duration, 10, accuracy: 0.001)
    }

    func testCancelledPreviewDoesNotBumpCompositionVersion() {
        let doc = document(mainDuration: 5)
        let segment = textSegment(start: 1, duration: 2)
        doc.addSegmentAutoTrack(kind: .text, segment: segment)
        let before = doc.compositionVersion

        // Drag out past the main track, then cancel back to the original range.
        doc.previewTrimRange(segmentID: segment.id, range: TimeRange(start: 1, duration: 8))
        doc.previewTrimRange(segmentID: segment.id, range: TimeRange(start: 1, duration: 2))
        doc.trimSegment(id: segment.id, newTargetRange: TimeRange(start: 1, duration: 2))

        XCTAssertEqual(doc.compositionVersion, before)
        XCTAssertEqual(doc.timeline.duration, 5, accuracy: 0.001)
    }

    // MARK: - Deleting the tail caption

    func testDeletingTailTextBumpsCompositionVersion() {
        let doc = document(mainDuration: 5)
        let segment = textSegment(start: 6, duration: 3)
        doc.addSegmentAutoTrack(kind: .text, segment: segment)
        XCTAssertEqual(doc.timeline.duration, 9, accuracy: 0.001)
        let before = doc.compositionVersion

        doc.deleteSegment(id: segment.id)

        XCTAssertEqual(doc.timeline.duration, 5, accuracy: 0.001)
        XCTAssertGreaterThan(doc.compositionVersion, before)
    }
}

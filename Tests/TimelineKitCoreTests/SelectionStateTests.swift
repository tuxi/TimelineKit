import XCTest
@testable import TimelineKitCore

final class SelectionStateTests: XCTestCase {

    func testSelectTransitionClearsSegmentSelection() {
        let segmentID = UUID()
        let transitionID = UUID()
        var selection = SelectionState()

        selection.selectOnly(segmentID)
        selection.selectTransition(transitionID)

        XCTAssertNil(selection.singleSelectedID)
        XCTAssertNil(selection.editingSegmentID)
        XCTAssertNil(selection.editingTransitionContext)
        XCTAssertEqual(selection.selectedTransitionID, transitionID)
    }

    func testSelectingSegmentClearsTransition() {
        let segmentID = UUID()
        var selection = SelectionState()

        selection.selectTransition(UUID())
        selection.selectOnly(segmentID)

        XCTAssertEqual(selection.singleSelectedID, segmentID)
        XCTAssertNil(selection.selectedTransitionID)
    }

    func testSelectCutClearsSegmentAndTransitionSelection() {
        let leadingID = UUID()
        let trailingID = UUID()
        var selection = SelectionState()

        selection.selectOnly(UUID())
        selection.selectCut(leadingID: leadingID, trailingID: trailingID)

        XCTAssertNil(selection.singleSelectedID)
        XCTAssertNil(selection.selectedTransitionID)
        XCTAssertEqual(selection.selectedCutContext?.leadingID, leadingID)
        XCTAssertEqual(selection.selectedCutContext?.trailingID, trailingID)
        XCTAssertNil(selection.selectedCutContext?.existingTransition)
    }

    func testSelectingTransitionClearsCutSelection() {
        var selection = SelectionState()
        selection.selectCut(leadingID: UUID(), trailingID: UUID())

        let transitionID = UUID()
        selection.selectTransition(transitionID)

        XCTAssertEqual(selection.selectedTransitionID, transitionID)
        XCTAssertNil(selection.selectedCutContext)
    }

    func testSelectingSegmentClearsCutSelection() {
        var selection = SelectionState()
        selection.selectCut(leadingID: UUID(), trailingID: UUID())
        let segmentID = UUID()

        selection.selectOnly(segmentID)

        XCTAssertEqual(selection.singleSelectedID, segmentID)
        XCTAssertNil(selection.selectedCutContext)
    }

    func testDeselectClearsTransitionAndSegments() {
        var selection = SelectionState()
        selection.selectTransition(UUID())
        selection.selectedCutContext = TransitionEditContext(
            leadingID: UUID(),
            trailingID: UUID(),
            existingTransition: nil
        )

        selection.deselect()

        XCTAssertNil(selection.selectedTransitionID)
        XCTAssertNil(selection.selectedCutContext)
        XCTAssertNil(selection.singleSelectedID)
        XCTAssertNil(selection.editingSegmentID)
    }
}

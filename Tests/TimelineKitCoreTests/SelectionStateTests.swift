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

    func testDeselectClearsTransitionAndSegments() {
        var selection = SelectionState()
        selection.selectTransition(UUID())

        selection.deselect()

        XCTAssertNil(selection.selectedTransitionID)
        XCTAssertNil(selection.singleSelectedID)
        XCTAssertNil(selection.editingSegmentID)
    }
}

import XCTest
import CoreGraphics
@testable import TimelineKitUISharedViews

final class EditorLayoutPolicyTests: XCTestCase {

    // MARK: - Stacked forms

    func testCompactWidthUsesPhoneFormAndCurrentPreviewRatio() {
        let decision = EditorLayoutPolicy.decide(input(container: CGSize(width: 390, height: 844)))

        XCTAssertEqual(decision.form, .phone)
        XCTAssertEqual(decision.foldAxis, .none)
        XCTAssertFalse(decision.showsAuxiliaryPanel)
        XCTAssertFalse(decision.showsInspector)
        XCTAssertEqual(decision.previewSize.width, 390, accuracy: 0.01)
        XCTAssertEqual(decision.previewSize.height, 383.72, accuracy: 0.01)
        XCTAssertEqual(decision.timelineSize.height, 340.28, accuracy: 0.01)
        XCTAssertEqual(decision.timelineDensity, .regular)
    }

    func testRegularMediumWorkspaceShowsOneAuxiliaryPanel() {
        let decision = EditorLayoutPolicy.decide(
            input(container: CGSize(width: 834, height: 1112), horizontal: .regular)
        )

        XCTAssertEqual(decision.form, .mediumWorkspace)
        XCTAssertTrue(decision.showsAuxiliaryPanel)
        XCTAssertFalse(decision.showsInspector)
        XCTAssertEqual(decision.previewSize.height, 615.04, accuracy: 0.01)
    }

    func testWideWorkspaceShowsInspector() {
        let decision = EditorLayoutPolicy.decide(
            input(container: CGSize(width: 1024, height: 1366), horizontal: .regular)
        )

        XCTAssertEqual(decision.form, .wideWorkspace)
        XCTAssertTrue(decision.showsAuxiliaryPanel)
        XCTAssertTrue(decision.showsInspector)
    }

    func testRegularWidthWithShortHeightFallsBackToPhone() {
        let decision = EditorLayoutPolicy.decide(
            input(container: CGSize(width: 1024, height: 480), horizontal: .regular)
        )

        XCTAssertEqual(decision.form, .phone)
        XCTAssertFalse(decision.showsAuxiliaryPanel)
        XCTAssertFalse(decision.showsInspector)
    }

    func testCompactHeightSizeClassFallsBackToPhone() {
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 1024, height: 800),
                horizontal: .regular,
                vertical: .compact
            )
        )

        XCTAssertEqual(decision.form, .phone)
    }

    func testWideThresholdUsesContentWidth() {
        let wide = EditorLayoutPolicy.decide(
            input(container: CGSize(width: 900, height: 1000), horizontal: .regular)
        )
        let medium = EditorLayoutPolicy.decide(
            input(container: CGSize(width: 899, height: 1000), horizontal: .regular)
        )

        XCTAssertEqual(wide.form, .wideWorkspace)
        XCTAssertEqual(medium.form, .mediumWorkspace)
    }

    // MARK: - Safe area, keyboard, minimums

    func testSafeAreaAndKeyboardReduceContentSize() {
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 390, height: 844),
                insets: EditorLayoutInsets(top: 47, leading: 0, bottom: 34, trailing: 0),
                keyboardHeight: 300
            )
        )

        XCTAssertEqual(decision.contentSize.width, 390, accuracy: 0.01)
        XCTAssertEqual(decision.contentSize.height, 463, accuracy: 0.01)
        XCTAssertEqual(decision.timelineDensity, .compact)
    }

    func testPreviewRespectsMinimumHeightAndTimelineReserve() {
        let decision = EditorLayoutPolicy.decide(
            input(container: CGSize(width: 390, height: 300))
        )

        XCTAssertEqual(decision.previewSize.height, 120, accuracy: 0.01)
        XCTAssertEqual(decision.timelineSize.height, 60, accuracy: 0.01)
        XCTAssertEqual(decision.timelineDensity, .compact)
    }

    func testTimelineBecomesCompactBelowHeightThreshold() {
        let decision = EditorLayoutPolicy.decide(
            input(container: CGSize(width: 1024, height: 560), horizontal: .regular)
        )

        XCTAssertEqual(decision.form, .mediumWorkspace)
        XCTAssertEqual(decision.timelineDensity, .compact)
    }

    // MARK: - Fold

    func testVerticalFoldSplitsLeadingAndTrailing() {
        let fold = region(
            .division,
            CGRect(x: 480, y: 0, width: 40, height: 800)
        )
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 1000, height: 800),
                horizontal: .regular,
                regions: [fold]
            )
        )

        XCTAssertEqual(decision.form, .foldedWorkspace)
        XCTAssertEqual(decision.foldAxis, .vertical)
        XCTAssertEqual(decision.previewSize, CGSize(width: 480, height: 800))
        XCTAssertEqual(decision.timelineSize, CGSize(width: 480, height: 800))
        XCTAssertFalse(decision.showsAuxiliaryPanel)
        XCTAssertFalse(decision.showsInspector)
        XCTAssertEqual(decision.activeFoldFrame, fold.frame)
    }

    func testVerticalFoldFallsBackWhenSideIsTooNarrow() {
        let fold = region(
            .division,
            CGRect(x: 100, y: 0, width: 40, height: 800)
        )
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 1000, height: 800),
                horizontal: .regular,
                regions: [fold]
            )
        )

        XCTAssertEqual(decision.form, .wideWorkspace)
        XCTAssertEqual(decision.foldAxis, .none)
        XCTAssertNil(decision.activeFoldFrame)
    }

    func testHorizontalFoldSplitsTopAndBottom() {
        let fold = region(
            .division,
            CGRect(x: 0, y: 380, width: 1000, height: 40)
        )
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 1000, height: 800),
                horizontal: .regular,
                regions: [fold]
            )
        )

        XCTAssertEqual(decision.form, .foldedWorkspace)
        XCTAssertEqual(decision.foldAxis, .horizontal)
        XCTAssertEqual(decision.previewSize, CGSize(width: 1000, height: 380))
        XCTAssertEqual(decision.timelineSize, CGSize(width: 1000, height: 380))
    }

    func testInactiveDivisionIsIgnored() {
        let fold = region(
            .division,
            CGRect(x: 480, y: 0, width: 40, height: 800),
            active: false
        )
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 1000, height: 800),
                horizontal: .regular,
                regions: [fold]
            )
        )

        XCTAssertEqual(decision.form, .wideWorkspace)
        XCTAssertEqual(decision.foldAxis, .none)
        XCTAssertNil(decision.activeFoldFrame)
    }

    func testLargestUsableDivisionWins() {
        let unusable = region(
            .division,
            CGRect(x: 100, y: 0, width: 20, height: 800)
        )
        let usable = region(
            .division,
            CGRect(x: 600, y: 0, width: 40, height: 800)
        )
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 1200, height: 800),
                horizontal: .regular,
                regions: [unusable, usable]
            )
        )

        XCTAssertEqual(decision.foldAxis, .vertical)
        XCTAssertEqual(decision.activeFoldFrame, usable.frame)
    }

    func testNarrowTrailingRegionMakesTimelineCompact() {
        let fold = region(
            .division,
            CGRect(x: 320, y: 0, width: 40, height: 800)
        )
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 600, height: 800),
                horizontal: .regular,
                regions: [fold]
            )
        )

        XCTAssertEqual(decision.foldAxis, .vertical)
        XCTAssertEqual(decision.timelineSize.width, 240, accuracy: 0.01)
        XCTAssertEqual(decision.timelineDensity, .compact)
    }

    // MARK: - Occlusion

    func testActiveOcclusionFramesAreReportedWithoutChangingForm() {
        let active = region(
            .occlusion,
            CGRect(x: 0, y: 0, width: 60, height: 60)
        )
        let inactive = region(
            .occlusion,
            CGRect(x: 0, y: 0, width: 20, height: 20),
            active: false
        )
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 390, height: 844),
                regions: [active, inactive]
            )
        )

        XCTAssertEqual(decision.form, .phone)
        XCTAssertEqual(decision.activeOcclusionFrames, [active.frame])
    }

    // MARK: - Helpers

    private func input(
        container: CGSize,
        horizontal: EditorSizeClass = .compact,
        vertical: EditorSizeClass = .regular,
        insets: EditorLayoutInsets = .zero,
        keyboardHeight: CGFloat = 0,
        regions: [EditorReservedRegion] = []
    ) -> EditorLayoutInput {
        EditorLayoutInput(
            horizontalSizeClass: horizontal,
            verticalSizeClass: vertical,
            containerSize: container,
            safeAreaInsets: insets,
            keyboardHeight: keyboardHeight,
            fixedChromeHeight: 120,
            reservedRegions: regions
        )
    }

    private func region(
        _ kind: EditorReservedRegionKind,
        _ frame: CGRect,
        active: Bool = true
    ) -> EditorReservedRegion {
        EditorReservedRegion(kind: kind, frame: frame, isActive: active)
    }
}

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
        XCTAssertEqual(decision.auxiliaryPanelWidth, 0)
        XCTAssertEqual(decision.previewSize.width, 390, accuracy: 0.01)
        XCTAssertEqual(decision.previewSize.height, 447.32, accuracy: 0.01)
        XCTAssertEqual(decision.timelineSize.height, 276.68, accuracy: 0.01)
        XCTAssertEqual(decision.timelineDensity, .regular)
    }

    func testCompactLandscapeUsesSideBySideLayout() {
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 874, height: 402),
                horizontal: .compact,
                vertical: .compact
            )
        )

        XCTAssertEqual(decision.form, .phoneLandscape)
        XCTAssertEqual(decision.previewSize.width, 402.04, accuracy: 0.01)
        XCTAssertEqual(decision.timelineSize.width, 471.96, accuracy: 0.01)
        XCTAssertEqual(decision.previewSize.height, 402, accuracy: 0.01)
        XCTAssertEqual(decision.timelineSize.height, 402, accuracy: 0.01)
        XCTAssertFalse(decision.showsAuxiliaryPanel)
        XCTAssertFalse(decision.showsInspector)
    }

    func testCompactLandscapeFallsBackBelowWidthThreshold() {
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 600, height: 375),
                horizontal: .compact,
                vertical: .compact
            )
        )

        XCTAssertEqual(decision.form, .phone)
    }

    func testRegularMediumWorkspaceShowsOneAuxiliaryPanel() {
        let decision = EditorLayoutPolicy.decide(
            input(container: CGSize(width: 834, height: 1112), horizontal: .regular)
        )

        XCTAssertEqual(decision.form, .mediumWorkspace)
        XCTAssertTrue(decision.showsAuxiliaryPanel)
        XCTAssertFalse(decision.showsInspector)
        XCTAssertEqual(decision.auxiliaryPanelWidth, 283.56, accuracy: 0.01)
        XCTAssertEqual(decision.previewSize.height, 689.44, accuracy: 0.01)
        XCTAssertEqual(decision.timelineSize.height, 302.56, accuracy: 0.01)
    }

    func testNarrowRegularWidthKeepsMinimumPanelWidth() {
        let decision = EditorLayoutPolicy.decide(
            input(container: CGSize(width: 600, height: 900), horizontal: .regular)
        )

        XCTAssertEqual(decision.form, .mediumWorkspace)
        XCTAssertEqual(decision.auxiliaryPanelWidth, 220, accuracy: 0.01)
    }

    func testWideWorkspaceShowsInspector() {
        let decision = EditorLayoutPolicy.decide(
            input(container: CGSize(width: 1024, height: 1366), horizontal: .regular)
        )

        XCTAssertEqual(decision.form, .wideWorkspace)
        XCTAssertTrue(decision.showsAuxiliaryPanel)
        XCTAssertTrue(decision.showsInspector)
        XCTAssertEqual(decision.auxiliaryPanelWidth, 340, accuracy: 0.01)
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

    func testStackedHeightsFillContentAfterChrome() {
        let decision = EditorLayoutPolicy.decide(
            input(container: CGSize(width: 1024, height: 1366), horizontal: .regular)
        )

        XCTAssertEqual(
            decision.previewSize.height + decision.timelineSize.height + 120,
            decision.contentSize.height,
            accuracy: 0.01
        )
        XCTAssertGreaterThanOrEqual(decision.timelineSize.height, 100)
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
        XCTAssertEqual(decision.auxiliaryPanelWidth, 0)
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

    func testVerticalFoldRequiresPreviewWidth() {
        let fold = region(
            .division,
            CGRect(x: 200, y: 0, width: 40, height: 900)
        )
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 600, height: 900),
                horizontal: .regular,
                regions: [fold]
            )
        )

        XCTAssertEqual(decision.foldAxis, .none)
        XCTAssertEqual(decision.form, .mediumWorkspace)
    }

    func testHorizontalFoldRequiresTimelineHeight() {
        let fold = region(
            .division,
            CGRect(x: 0, y: 100, width: 834, height: 40)
        )
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 834, height: 1104),
                horizontal: .regular,
                regions: [fold]
            )
        )

        XCTAssertEqual(decision.foldAxis, .none)
        XCTAssertEqual(decision.form, .mediumWorkspace)
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

    func testActiveOcclusionInTopBandAddsControlInset() {
        let occlusion = region(
            .occlusion,
            CGRect(x: 340, y: 0, width: 60, height: 60)
        )
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 402, height: 724),
                regions: [occlusion]
            )
        )

        XCTAssertEqual(decision.form, .phone)
        XCTAssertEqual(decision.topControlInset, 44, accuracy: 0.01)
    }

    func testOcclusionBelowTopBandDoesNotMoveControls() {
        let occlusion = region(
            .occlusion,
            CGRect(x: 340, y: 600, width: 60, height: 60)
        )
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 402, height: 724),
                regions: [occlusion]
            )
        )

        XCTAssertEqual(decision.topControlInset, 0)
    }

    func testInactiveOcclusionDoesNotMoveControls() {
        let occlusion = region(
            .occlusion,
            CGRect(x: 340, y: 0, width: 60, height: 60),
            active: false
        )
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 402, height: 724),
                regions: [occlusion]
            )
        )

        XCTAssertEqual(decision.topControlInset, 0)
    }

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

    // MARK: - Sheet height (half-fold avoidance)

    func testHorizontalFoldCapsSheetHeightToRegionBelowFold() {
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
        XCTAssertEqual(decision.sheetMaxHeight, 380)
    }

    func testHorizontalFoldCapAccountsForSafeAreaOrigin() {
        let fold = region(
            .division,
            CGRect(x: 0, y: 380, width: 1000, height: 40)
        )
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 1000, height: 800),
                horizontal: .regular,
                insets: EditorLayoutInsets(top: 60, leading: 0, bottom: 0, trailing: 0),
                regions: [fold]
            )
        )

        // Content now runs from y=60 to y=800, so the lower panel is 800-420.
        XCTAssertEqual(decision.sheetMaxHeight, 380)
    }

    func testVerticalFoldDoesNotCapSheetHeight() {
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

        XCTAssertEqual(decision.foldAxis, .vertical)
        XCTAssertNil(decision.sheetMaxHeight)
    }

    func testStackedFormHasNoSheetHeightCap() {
        let decision = EditorLayoutPolicy.decide(input(container: CGSize(width: 390, height: 844)))

        XCTAssertNil(decision.sheetMaxHeight)
    }

    func testInactiveFoldDoesNotCapSheetHeight() {
        let fold = region(
            .division,
            CGRect(x: 0, y: 380, width: 1000, height: 40),
            active: false
        )
        let decision = EditorLayoutPolicy.decide(
            input(
                container: CGSize(width: 1000, height: 800),
                horizontal: .regular,
                regions: [fold]
            )
        )

        XCTAssertNil(decision.sheetMaxHeight)
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

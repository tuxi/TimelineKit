import XCTest
@testable import TimelineKitCore

final class TextStyleScalingTests: XCTestCase {

    private let referenceWidth: Double = TextStyle.referenceCanvasWidth

    func testReferenceCanvasKeepsStyleUnchanged() {
        let style = TextStyle.default
        let scaled = style.scaledForCanvas(width: referenceWidth)
        XCTAssertEqual(scaled.fontSize, style.fontSize, accuracy: 0.0001)
        XCTAssertEqual(scaled.paddingH, style.paddingH, accuracy: 0.0001)
    }

    func testHDCanvasScalesFontSize() {
        let scaled = TextStyle.default.scaledForCanvas(width: 1920)
        // 34 * 1920 / 720
        XCTAssertEqual(scaled.fontSize, 90.6666, accuracy: 0.001)
    }

    func testPhotoResolutionCanvasScalesFontSize() {
        let scaled = TextStyle.default.scaledForCanvas(width: 4032)
        XCTAssertEqual(scaled.fontSize, 34 * 4032.0 / 720.0, accuracy: 0.001)
    }

    func testPointMetricsScaleTogetherWithFontSize() {
        var style = TextStyle.default
        style.paddingH = 20
        style.paddingV = 10
        style.strokeWidth = 2
        style.shadowRadius = 4
        style.shadowOffsetX = 3
        style.shadowOffsetY = -3
        style.kerning = 2
        style.lineSpacing = 8

        let scaled = style.scaledForCanvas(width: 1440)   // ×2
        XCTAssertEqual(scaled.fontSize, style.fontSize * 2, accuracy: 0.001)
        XCTAssertEqual(scaled.paddingH, 40, accuracy: 0.001)
        XCTAssertEqual(scaled.paddingV, 20, accuracy: 0.001)
        XCTAssertEqual(scaled.strokeWidth, 4, accuracy: 0.001)
        XCTAssertEqual(scaled.shadowRadius, 8, accuracy: 0.001)
        XCTAssertEqual(scaled.shadowOffsetX, 6, accuracy: 0.001)
        XCTAssertEqual(scaled.shadowOffsetY, -6, accuracy: 0.001)
        XCTAssertEqual(scaled.kerning, 4, accuracy: 0.001)
        XCTAssertEqual(scaled.lineSpacing, 16, accuracy: 0.001)
    }

    func testNonSizeAttributesArePreserved() {
        var style = TextStyle.default
        style.color = "#FF0000"
        style.fontWeight = .bold
        style.alignment = .leading
        style.isItalic = true

        let scaled = style.scaledForCanvas(width: 1920)
        XCTAssertEqual(scaled.color, "#FF0000")
        XCTAssertEqual(scaled.fontWeight, .bold)
        XCTAssertEqual(scaled.alignment, .leading)
        XCTAssertTrue(scaled.isItalic)
    }

    func testInvalidWidthLeavesStyleUnchanged() {
        let style = TextStyle.default
        XCTAssertEqual(style.scaledForCanvas(width: 0).fontSize, style.fontSize, accuracy: 0.0001)
        XCTAssertEqual(style.scaledForCanvas(width: -10).fontSize, style.fontSize, accuracy: 0.0001)
    }
}

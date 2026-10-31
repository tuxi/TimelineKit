import XCTest
import TimelineKitCore
@testable import TimelineKitUIShared

@MainActor
final class TextCreationScalingTests: XCTestCase {

    private func store(canvasWidth: Int) -> EditorStore {
        let timeline = EditorTimeline(
            canvas: EditorCanvas(width: canvasWidth, height: canvasWidth * 16 / 9)
        )
        return EditorStore(timeline: timeline)
    }

    func testNewTextOnReferenceCanvasKeepsDefaultSize() throws {
        let store = store(canvasWidth: 720)
        let id = try XCTUnwrap(store.createNewTextSegment())
        guard case .text(let content)? = store.timeline.segment(id: id)?.content else {
            return XCTFail("expected text content")
        }
        XCTAssertEqual(content.style.fontSize, TextStyle.default.fontSize, accuracy: 0.001)
    }

    func testNewTextOnHDCanvasScalesToCanvas() throws {
        let store = store(canvasWidth: 1920)
        let id = try XCTUnwrap(store.createNewTextSegment())
        guard case .text(let content)? = store.timeline.segment(id: id)?.content else {
            return XCTFail("expected text content")
        }
        // Same share of the frame as 34 pt on a 720-wide canvas.
        XCTAssertEqual(content.style.fontSize, 34 * 1920.0 / 720.0, accuracy: 0.001)
    }

    func testNewSubtitleOnPhotoCanvasScalesToCanvas() throws {
        let store = store(canvasWidth: 4032)
        let id = try XCTUnwrap(store.createNewSubtitleSegment())
        guard case .subtitle(let content)? = store.timeline.segment(id: id)?.content else {
            return XCTFail("expected subtitle content")
        }
        XCTAssertEqual(content.style.fontSize, 34 * 4032.0 / 720.0, accuracy: 0.001)
    }

    func testInsertedTemplateScalesToCanvas() throws {
        let store = store(canvasWidth: 1920)
        let template = try XCTUnwrap(TextTemplateCatalog.all.first)
        let id = try XCTUnwrap(store.insertTextTemplate(template, at: 0))

        let style: TextStyle
        switch try XCTUnwrap(store.timeline.segment(id: id)?.content) {
        case .text(let c):     style = c.style
        case .subtitle(let c): style = c.style
        default: return XCTFail("expected text-bearing content")
        }
        XCTAssertEqual(style.fontSize, template.style.fontSize * 1920.0 / 720.0, accuracy: 0.001)
    }
}

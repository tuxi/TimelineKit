import XCTest
@testable import TimelineKitUISharedViews

final class EditorInspectorModelTests: XCTestCase {

    func testVideoTabsAndDefault() {
        let context = EditorInspectorContext(kind: .video)

        XCTAssertEqual(
            context.availableTabs,
            [.video, .audio, .color, .animation, .info]
        )
        XCTAssertEqual(context.defaultTab, .video)
    }

    func testImageTabsExcludeAudio() {
        let context = EditorInspectorContext(kind: .image)

        XCTAssertEqual(
            context.availableTabs,
            [.video, .color, .animation, .info]
        )
        XCTAssertFalse(context.availableTabs.contains(.audio))
        XCTAssertEqual(context.defaultTab, .video)
    }

    func testTextAndSubtitleTabs() {
        for kind in [EditorInspectorContentKind.text, .subtitle] {
            let context = EditorInspectorContext(kind: kind)

            XCTAssertEqual(
                context.availableTabs,
                [.text, .layout, .animation, .info]
            )
            XCTAssertEqual(context.defaultTab, .text)
        }
    }

    func testAudioTabs() {
        let context = EditorInspectorContext(kind: .audio)

        XCTAssertEqual(
            context.availableTabs,
            [.audio, .effects, .info]
        )
        XCTAssertEqual(context.defaultTab, .audio)
    }

    func testTransitionTabs() {
        let context = EditorInspectorContext(kind: .transition)

        XCTAssertEqual(context.availableTabs, [.transition, .info])
        XCTAssertEqual(context.defaultTab, .transition)
    }

    func testNoSelectionShowsProject() {
        let context = EditorInspectorContext(kind: .none)

        XCTAssertEqual(context.availableTabs, [.project])
        XCTAssertEqual(context.defaultTab, .project)
    }

    func testMultipleSelectionShowsSummary() {
        let context = EditorInspectorContext(kind: .multiple)

        XCTAssertEqual(context.availableTabs, [.multiSelection])
        XCTAssertEqual(context.defaultTab, .multiSelection)
    }

    func testCompatiblePreferredTabIsPreserved() {
        let context = EditorInspectorContext(kind: .video)

        XCTAssertEqual(
            context.resolvedTab(preferred: .color),
            .color
        )
    }

    func testIncompatiblePreferredTabFallsBackToDefault() {
        let context = EditorInspectorContext(kind: .video)

        XCTAssertEqual(
            context.resolvedTab(preferred: .text),
            .video
        )
        XCTAssertEqual(
            context.resolvedTab(preferred: nil),
            .video
        )
    }

    func testEveryContextDefaultIsAvailable() {
        for kind in EditorInspectorContentKind.allCases {
            let context = EditorInspectorContext(kind: kind)

            XCTAssertFalse(
                context.availableTabs.isEmpty,
                "\(kind) should expose at least one tab"
            )
            XCTAssertTrue(
                context.availableTabs.contains(context.defaultTab),
                "\(kind) default tab must be available"
            )
        }
    }

    func testEveryTabHasTitleAndIcon() {
        for tab in EditorInspectorTab.allCases {
            XCTAssertFalse(tab.title.isEmpty, "\(tab) needs a title")
            XCTAssertFalse(tab.systemImage.isEmpty, "\(tab) needs an icon")
        }
    }
}

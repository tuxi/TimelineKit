import XCTest
import TimelineKitCore
@testable import TimelineKitUIShared

@MainActor
final class TextTemplateTests: XCTestCase {

    // MARK: - Catalog

    func testCatalogIDsAreUnique() {
        let ids = TextTemplateCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testEveryTemplateHasPlaceholderTextAndDuration() {
        for template in TextTemplateCatalog.all {
            XCTAssertFalse(template.defaultText.isEmpty, template.id)
            XCTAssertFalse(template.name.isEmpty, template.id)
            XCTAssertGreaterThan(template.duration, 0, template.id)
        }
    }

    func testTitleTemplatesLeaveSubtitleFieldsUnset() {
        for template in TextTemplateCatalog.all where template.kind == .title {
            XCTAssertNil(template.subtitlePositionY, template.id)
            XCTAssertNil(template.maxCharsPerLine, template.id)
        }
    }

    func testCaptionTemplatesCarryPositionAndLineLimit() {
        let captions = TextTemplateCatalog.all.filter { $0.kind == .caption }
        XCTAssertFalse(captions.isEmpty)
        for template in captions {
            let positionY = template.subtitlePositionY
            XCTAssertNotNil(positionY, template.id)
            if let positionY {
                XCTAssertTrue((0...1).contains(positionY), template.id)
            }
            XCTAssertNotNil(template.maxCharsPerLine, template.id)
        }
    }

    func testTrackKindFollowsTemplateKind() {
        XCTAssertEqual(TextTemplateCatalog.template(id: "title.center")?.trackKind, .text)
        XCTAssertEqual(TextTemplateCatalog.template(id: "caption.shadow")?.trackKind, .subtitle)
    }

    func testGroupLookupReturnsOnlyThatGroup() {
        for group in TextTemplate.Group.allCases {
            let templates = TextTemplateCatalog.templates(in: group)
            XCTAssertFalse(templates.isEmpty, group.rawValue)
            XCTAssertTrue(templates.allSatisfy { $0.group == group }, group.rawValue)
        }
    }

    // MARK: - Recents

    func testRecentsMoveToFrontAndDedupe() {
        let recents = makeRecents()

        recents.record("title.center")
        recents.record("caption.shadow")
        recents.record("title.center")

        XCTAssertEqual(recents.ids(), ["title.center", "caption.shadow"])
    }

    func testRecentsCapAtMaxCount() {
        let recents = makeRecents()

        for index in 0..<(RecentTextTemplates.maxCount + 3) {
            recents.record("template.\(index)")
        }

        let ids = recents.ids()
        XCTAssertEqual(ids.count, RecentTextTemplates.maxCount)
        XCTAssertEqual(ids.first, "template.\(RecentTextTemplates.maxCount + 2)")
    }

    func testRecentsSkipUnknownIDsWhenResolving() {
        let recents = makeRecents()
        recents.record("title.center")
        recents.record("does.not.exist")
        recents.record("caption.shadow")

        let resolved = recents.templates()
        XCTAssertEqual(resolved.map(\.id), ["caption.shadow", "title.center"])
    }

    func testRecentsClearEmptiesHistory() {
        let recents = makeRecents()
        recents.record("title.center")

        recents.clear()

        XCTAssertTrue(recents.ids().isEmpty)
        XCTAssertTrue(recents.templates().isEmpty)
    }

    // MARK: - Insertion

    func testInsertTitleCreatesStyledTextSegmentAtPlayhead() throws {
        let store = makeStore()
        store.selection.playheadTime = 2.5
        let template = try XCTUnwrap(TextTemplateCatalog.template(id: "title.outline"))

        let segmentID = try XCTUnwrap(store.insertTextTemplate(template))
        let segment = try XCTUnwrap(store.timeline.segment(id: segmentID))

        XCTAssertEqual(segment.targetRange.start, 2.5, accuracy: 0.0001)
        XCTAssertEqual(segment.targetRange.duration, template.duration, accuracy: 0.0001)
        XCTAssertEqual(store.selection.singleSelectedID, segmentID)

        guard case .text(let content) = segment.content else {
            return XCTFail("title template must insert a text segment")
        }
        XCTAssertEqual(content.text, template.defaultText)
        XCTAssertEqual(content.style, template.style)
        XCTAssertEqual(content.position, template.position)
        XCTAssertEqual(content.anchor, template.anchor)
    }

    func testInsertCaptionUsesSubtitleFields() throws {
        let store = makeStore()
        let template = try XCTUnwrap(TextTemplateCatalog.template(id: "caption.yellow"))

        let segmentID = try XCTUnwrap(store.insertTextTemplate(template))
        let segment = try XCTUnwrap(store.timeline.segment(id: segmentID))

        guard case .subtitle(let content) = segment.content else {
            return XCTFail("caption template must insert a subtitle segment")
        }
        XCTAssertEqual(content.style, template.style)
        XCTAssertEqual(content.positionY, template.subtitlePositionY)
        XCTAssertEqual(content.maxCharsPerLine, template.maxCharsPerLine)
    }

    func testInsertLandsOnMatchingTrackKind() throws {
        let store = makeStore()
        let template = try XCTUnwrap(TextTemplateCatalog.template(id: "caption.shadow"))

        let segmentID = try XCTUnwrap(store.insertTextTemplate(template))
        let host = store.timeline.tracks.first { track in
            track.segments.contains { $0.id == segmentID }
        }

        XCTAssertEqual(host?.kind, .subtitle)
    }

    func testInsertIgnoresMismatchedTargetTrack() throws {
        let store = makeStore()
        let videoTrack = EditorTrack(kind: .video, segments: [], isMainTrack: true)
        store.timeline.tracks.append(videoTrack)
        let template = try XCTUnwrap(TextTemplateCatalog.template(id: "title.center"))

        let segmentID = try XCTUnwrap(
            store.insertTextTemplate(template, targetTrackID: videoTrack.id)
        )
        let host = store.timeline.tracks.first { track in
            track.segments.contains { $0.id == segmentID }
        }

        XCTAssertEqual(host?.kind, .text)
        XCTAssertNotEqual(host?.id, videoTrack.id)
    }

    func testInsertRecordsRecentTemplate() throws {
        let store = makeStore()
        let recents = makeRecents()
        let template = try XCTUnwrap(TextTemplateCatalog.template(id: "title.band"))

        store.insertTextTemplate(template, recents: recents)

        XCTAssertEqual(recents.ids(), ["title.band"])
    }

    // MARK: - Helpers

    private func makeStore() -> EditorStore {
        EditorStore(timeline: EditorTimeline(canvas: EditorCanvas(width: 1920, height: 1080)))
    }

    private func makeRecents() -> RecentTextTemplates {
        let suiteName = "TextTemplateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return RecentTextTemplates(defaults: defaults)
    }
}

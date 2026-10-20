import Foundation
import XCTest
@testable import TimelineKitCore

/// Copyable Core fixture for Dreamlog's local integration slice.
/// It intentionally uses only TimelineKitCore types; DraftStore/EditorStore wiring
/// lives in the App and is shown in docs/agent-edit-plan.md.
@MainActor
final class DreamlogIntegrationFixtureTests: XCTestCase {
    func testRoughCutAndTwoSubtitlesApplyAsOnePlan() async throws {
        let material = EditorAsset(type: .video, nativeDuration: 15.067)
        let source = EditorSegment(
            materialID: material.id,
            targetRange: TimeRange(start: 0, duration: 15.067),
            content: .video(.init())
        )
        var timeline = EditorTimeline(canvas: EditorCanvas(width: 720, height: 1280))
        timeline.materials.add(material)
        timeline.tracks = [EditorTrack(kind: .video, segments: [source], isMainTrack: true)]

        let cut1 = UUID()
        let cut2 = UUID()
        let subtitle1 = UUID()
        let subtitle2 = UUID()
        let fixture = """
        {
          "planID": "plan-dreamlog-fixture",
          "baseTimelineVersion": "\(AgentEditPlan.timelineVersion(for: timeline))",
          "commands": [
            {
              "type": "roughCut",
              "materialID": "\(material.id.uuidString)",
              "sourceRanges": [
                { "start": 0.0, "duration": 2.4 },
                { "start": 7.5, "duration": 7.567 }
              ],
              "segmentIDs": ["\(cut1.uuidString)", "\(cut2.uuidString)"]
            },
            {
              "type": "addSubtitle",
              "segmentID": "\(subtitle1.uuidString)",
              "text": "first subtitle",
              "targetStart": 0.4,
              "duration": 1.8
            },
            {
              "type": "addSubtitle",
              "segmentID": "\(subtitle2.uuidString)",
              "text": "second subtitle",
              "targetStart": 3.0,
              "duration": 1.2
            }
          ],
          "expectedSourceFingerprints": {
            "\(material.id.uuidString)": "sha256:fixture"
          },
          "externalPlanID": "plan-external-fixture",
          "externalPlanHash": "sha256:approved-fixture"
        }
        """

        let plan = try JSONDecoder().decode(AgentEditPlan.self, from: Data(fixture.utf8))
        XCTAssertEqual(plan.commands.count, 3)
        let resolver: (EditorAsset) -> String? = { _ in "sha256:fixture" }
        let preview = try AgentEditEngine.preview(plan: plan, timeline: timeline, sourceFingerprint: resolver)

        let store = InMemoryAgentExecutionStore()
        let first = try await AgentEditEngine.apply(
            plan: plan,
            timeline: timeline,
            executionID: "exec-dreamlog-fixture",
            executionStore: store,
            sourceFingerprint: resolver
        )
        let second = try await AgentEditEngine.apply(
            plan: plan,
            timeline: timeline,
            executionID: "exec-dreamlog-fixture",
            executionStore: store,
            sourceFingerprint: resolver
        )

        XCTAssertEqual(first.timeline, preview.timeline)
        XCTAssertEqual(second.timeline, first.timeline)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(first.didApply)
        XCTAssertTrue(second.replayed)
        XCTAssertFalse(second.didApply)
        XCTAssertEqual(first.timeline.mainTrack?.segments.map(\.id), [cut1, cut2])
        XCTAssertEqual(first.timeline.mainTrack?.segments.map(\.sourceRange?.start), [0, 7.5])
        XCTAssertEqual(first.timeline.duration, 9.967, accuracy: 0.000_001)
        XCTAssertEqual(first.timeline.segment(id: subtitle1)?.targetRange.start, 0.4)
        XCTAssertEqual(first.timeline.segment(id: subtitle2)?.targetRange.start, 3.0)
        XCTAssertEqual(first.timeline.materials[subtitle1]?.type, .placeholder)
        XCTAssertEqual(first.timeline.tracks(ofKind: .subtitle).flatMap(\.segments).count, 2)
    }
}

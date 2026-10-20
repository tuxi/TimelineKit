import Foundation
import XCTest
import TimelineKitCore
@testable import TimelineKitMCP

@MainActor
final class MCPAliasTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let timelineURL: URL
        let arguments: [String: JSONValue]
    }

    func testApplyAliasesShareSchemaAndHandler() async throws {
        let standard = try XCTUnwrap(MCPTools.all.first { $0.name == "timelinekit.apply_edits" })
        let alias = try XCTUnwrap(MCPTools.all.first { $0.name == "timelinekit.apply_edit_plan" })

        XCTAssertEqual(Set(standard.parameters.keys), Set(alias.parameters.keys))
        XCTAssertEqual(standard.requiredParams, alias.requiredParams)
        XCTAssertEqual(standard.requiredParams, ["path", "plan"])

        let fixture = try makeFixture()
        var args = fixture.arguments
        args["dry_run"] = .bool(true)
        let standardResult = try await standard.execute(args)
        let aliasResult = try await alias.execute(args)
        XCTAssertEqual(standardResult.content.first?.text, aliasResult.content.first?.text)
    }

    func testApplyWritesThenReplaysWithoutRewriting() async throws {
        let fixture = try makeFixture()
        let executionID = "success-\(UUID().uuidString)"
        var args = fixture.arguments
        args["execution_id"] = .string(executionID)

        let first = try await MCPTools.applyEdits.execute(args)
        let firstObject = try jsonObject(first)
        XCTAssertEqual(firstObject["applied"] as? Bool, true)
        XCTAssertEqual(firstObject["replayed"] as? Bool, false)
        XCTAssertEqual(firstObject["wroteTimeline"] as? Bool, true)

        let saved = try readTimeline(at: fixture.timelineURL)
        XCTAssertEqual(
            AgentEditPlan.timelineVersion(for: saved),
            firstObject["timelineVersion"] as? String
        )

        let second = try await MCPTools.applyEdits.execute(args)
        let secondObject = try jsonObject(second)
        XCTAssertEqual(secondObject["replayed"] as? Bool, true)
        XCTAssertEqual(secondObject["wroteTimeline"] as? Bool, false)
        XCTAssertEqual(secondObject["timelineVersion"] as? String, firstObject["timelineVersion"] as? String)
    }

    func testApplyRetryRepairsTimelineAfterWriteFailure() async throws {
        let fixture = try makeFixture()
        let executionID = "write-failure-\(UUID().uuidString)"
        var args = fixture.arguments
        args["execution_id"] = .string(executionID)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: fixture.directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.directory.path
            )
        }
        guard !FileManager.default.isWritableFile(atPath: fixture.directory.path) else {
            throw XCTSkip("filesystem does not enforce the read-only directory")
        }

        do {
            _ = try await MCPTools.applyEdits.execute(args)
            XCTFail("expected the first write to fail")
        } catch {
            // Core already recorded the execution; the adapter write failed.
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.directory.path
        )

        let retry = try await MCPTools.applyEdits.execute(args)
        let retryObject = try jsonObject(retry)
        XCTAssertEqual(retryObject["applied"] as? Bool, true)
        XCTAssertEqual(retryObject["replayed"] as? Bool, true)
        XCTAssertEqual(retryObject["wroteTimeline"] as? Bool, true)
        XCTAssertEqual(retryObject["repairedReplay"] as? Bool, true)

        let saved = try readTimeline(at: fixture.timelineURL)
        XCTAssertEqual(
            AgentEditPlan.timelineVersion(for: saved),
            retryObject["timelineVersion"] as? String
        )
    }

    // MARK: - Fixture

    private func makeFixture() throws -> Fixture {
        let material = EditorAsset(type: .video, nativeDuration: 10)
        let source = EditorSegment(
            materialID: material.id,
            targetRange: TimeRange(start: 0, duration: 10),
            content: .video(.init())
        )
        var timeline = EditorTimeline(canvas: EditorCanvas(width: 720, height: 1280))
        timeline.materials.add(material)
        timeline.tracks = [EditorTrack(kind: .video, segments: [source], isMainTrack: true)]

        let plan = AgentEditPlan(
            planID: "mcp-alias",
            baseTimelineVersion: AgentEditPlan.timelineVersion(for: timeline),
            commands: [
                .roughCut(
                    materialID: material.id,
                    sourceRanges: [TimeRange(start: 0, duration: 2), TimeRange(start: 4, duration: 2)],
                    segmentIDs: [UUID(), UUID()]
                )
            ]
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("timelinekit-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let timelineURL = directory.appendingPathComponent("timeline.json")
        try JSONEncoder().encode(timeline).write(to: timelineURL, options: .atomic)

        let planData = try JSONEncoder().encode(plan)
        let planValue = try JSONDecoder().decode(JSONValue.self, from: planData)
        return Fixture(
            directory: directory,
            timelineURL: timelineURL,
            arguments: [
                "path": .string(timelineURL.path),
                "plan": planValue
            ]
        )
    }

    private func readTimeline(at url: URL) throws -> EditorTimeline {
        try JSONDecoder().decode(EditorTimeline.self, from: Data(contentsOf: url))
    }

    private func jsonObject(_ result: MCPToolResult) throws -> [String: Any] {
        let text = try XCTUnwrap(result.content.first?.text)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }
}

import XCTest
@testable import TimelineKitCore

@MainActor
final class AgentEditPlanTests: XCTestCase {
    private func timeline() -> EditorTimeline {
        let material = EditorAsset(type: .video)
        let segment = EditorSegment(materialID: material.id, targetRange: TimeRange(start: 0, duration: 10), content: .video(.init()))
        var result = EditorTimeline(canvas: EditorCanvas(width: 720, height: 1280))
        result.materials.add(material)
        result.tracks = [EditorTrack(kind: .video, segments: [segment], isMainTrack: true)]
        return result
    }

    func testPlanHashAndTimelineVersionAreStable() {
        let value = timeline()
        let plan = AgentEditPlan(planID: "p1", baseTimelineVersion: AgentEditPlan.timelineVersion(for: value), commands: [.trim(segmentID: value.tracks[0].segments[0].id, sourceStart: 1, targetStart: 0, duration: 3)])
        XCTAssertEqual(plan.planHash, plan.planHash)
        XCTAssertEqual(AgentEditPlan.timelineVersion(for: value), AgentEditPlan.timelineVersion(for: value))
    }

    func testPreviewDoesNotMutateAndApplyIsIdempotent() async throws {
        let original = timeline()
        let segmentID = original.tracks[0].segments[0].id
        let subtitleID = UUID()
        let plan = AgentEditPlan(planID: "p1", baseTimelineVersion: AgentEditPlan.timelineVersion(for: original), commands: [
            .trim(segmentID: segmentID, sourceStart: 2, targetStart: 0, duration: 4),
            .addSubtitle(segmentID: subtitleID, text: "hello", targetStart: 1, duration: 1)
        ])

        let preview = try AgentEditEngine.preview(plan: plan, timeline: original)
        XCTAssertEqual(original.duration, 10)
        XCTAssertEqual(preview.timeline.segment(id: segmentID)?.targetRange.duration, 4)
        XCTAssertEqual(preview.timeline.segment(id: subtitleID)?.targetRange.duration, 1)
        XCTAssertEqual(preview.timeline.materials[subtitleID]?.type, .placeholder)

        let store = InMemoryAgentExecutionStore()
        let first = try await AgentEditEngine.apply(plan: plan, timeline: original, executionID: "e1", executionStore: store)
        let second = try await AgentEditEngine.apply(plan: plan, timeline: original, executionID: "e1", executionStore: store)
        XCTAssertEqual(first.timeline, second.timeline)
        XCTAssertEqual(first.timeline, preview.timeline)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(first.didApply)
        XCTAssertTrue(second.replayed)
        XCTAssertFalse(second.didApply)
    }

    func testStaleRevisionFailsBeforeMutation() async throws {
        let value = timeline()
        let plan = AgentEditPlan(planID: "p1", baseTimelineVersion: "stale", commands: [])
        do {
            _ = try await AgentEditEngine.apply(plan: plan, timeline: value, executionID: "e1", executionStore: InMemoryAgentExecutionStore())
            XCTFail("expected stale revision")
        } catch let error as AgentEditError {
            guard case .staleTimeline = error else { XCTFail("unexpected error: \(error)"); return }
        }
    }

    func testRoughCutCreatesContinuousStableSegments() throws {
        var value = timeline()
        let materialID = value.tracks[0].segments[0].materialID
        value.materials[materialID]?.nativeDuration = 20
        let ids = [UUID(), UUID()]
        let plan = AgentEditPlan(
            planID: "rough-1",
            baseTimelineVersion: AgentEditPlan.timelineVersion(for: value),
            commands: [.roughCut(materialID: materialID, sourceRanges: [TimeRange(start: 2, duration: 3), TimeRange(start: 10, duration: 4)], segmentIDs: ids)]
        )

        let preview = try AgentEditEngine.preview(plan: plan, timeline: value)
        let segments = try XCTUnwrap(preview.timeline.mainTrack?.segments)
        XCTAssertEqual(segments.map(\.id), ids)
        XCTAssertEqual(segments.map(\.targetRange.start), [0, 3])
        XCTAssertEqual(segments.map(\.sourceRange?.start), [2, 10])
        XCTAssertEqual(AgentEditPlan.timelineVersion(for: preview.timeline), preview.resultingTimelineVersion)
    }

    func testRoughCutAcceptsExplicitFullSourceRange() throws {
        var value = timeline()
        let materialID = value.tracks[0].segments[0].materialID
        value.materials[materialID]?.nativeDuration = 20
        value.tracks[0].segments[0].sourceRange = TimeRange(start: 0, duration: 20)

        let plan = AgentEditPlan(
            planID: "rough-explicit-full",
            baseTimelineVersion: AgentEditPlan.timelineVersion(for: value),
            commands: [.roughCut(
                materialID: materialID,
                sourceRanges: [TimeRange(start: 2, duration: 3)],
                segmentIDs: [UUID()]
            )]
        )
        let preview = try AgentEditEngine.preview(plan: plan, timeline: value)
        XCTAssertEqual(preview.timeline.mainTrack?.segments.count, 1)
        XCTAssertEqual(preview.timeline.mainTrack?.segments[0].sourceRange, TimeRange(start: 2, duration: 3))
    }

    func testTrimWithExplicitSourceStartCreatesSourceRangeWhenAbsent() throws {
        let value = timeline()
        let id = value.tracks[0].segments[0].id
        let plan = AgentEditPlan(planID: "trim-1", baseTimelineVersion: AgentEditPlan.timelineVersion(for: value), commands: [.trim(segmentID: id, sourceStart: 5, targetStart: 0, duration: 2)])
        let preview = try AgentEditEngine.preview(plan: plan, timeline: value)
        XCTAssertEqual(preview.timeline.segment(id: id)?.sourceRange, TimeRange(start: 5, duration: 2))
    }

    func testPreviewRejectsStaleRevision() {
        let value = timeline()
        let plan = AgentEditPlan(planID: "stale-preview", baseTimelineVersion: "stale", commands: [])
        XCTAssertThrowsError(try AgentEditEngine.preview(plan: plan, timeline: value)) { error in
            guard case AgentEditError.staleTimeline = error else { XCTFail("unexpected error: \(error)"); return }
        }
    }

    func testPreviewAndApplyCheckSourceFingerprints() throws {
        let value = timeline()
        let materialID = value.tracks[0].segments[0].materialID
        let plan = AgentEditPlan(
            planID: "fingerprint",
            baseTimelineVersion: AgentEditPlan.timelineVersion(for: value),
            commands: [],
            expectedSourceFingerprints: [materialID: "expected"]
        )

        XCTAssertEqual(try AgentEditEngine.preview(plan: plan, timeline: value, sourceFingerprint: { _ in "expected" }).timeline, value)
        XCTAssertThrowsError(try AgentEditEngine.preview(plan: plan, timeline: value, sourceFingerprint: { _ in "changed" })) { error in
            guard case let AgentEditError.sourceFingerprintMismatch(id, expected, actual) = error else {
                XCTFail("unexpected error: \(error)"); return
            }
            XCTAssertEqual(id, materialID)
            XCTAssertEqual(expected, "expected")
            XCTAssertEqual(actual, "changed")
        }
    }

    func testPlanHashExcludesExternalApprovalIdentity() {
        let value = timeline()
        let base = AgentEditPlan(
            planID: "p1",
            baseTimelineVersion: AgentEditPlan.timelineVersion(for: value),
            commands: []
        )
        let approved = AgentEditPlan(
            planID: "p1",
            baseTimelineVersion: base.baseTimelineVersion,
            commands: [],
            externalPlanID: "dreamai-42",
            externalPlanHash: "approved-hash"
        )
        XCTAssertEqual(base.planHash, approved.planHash)
    }

    func testFingerprintJSONUsesObjectAndRoundTrips() throws {
        let value = timeline()
        let materialID = value.tracks[0].segments[0].materialID
        let plan = AgentEditPlan(
            planID: "p1",
            baseTimelineVersion: AgentEditPlan.timelineVersion(for: value),
            commands: [],
            expectedSourceFingerprints: [materialID: "abc", UUID(): "def"]
        )
        let data = try JSONEncoder().encode(plan)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fingerprints = try XCTUnwrap(object["expectedSourceFingerprints"] as? [String: String])
        XCTAssertEqual(fingerprints[materialID.uuidString], "abc")
        XCTAssertEqual(fingerprints.count, 2)

        let decoded = try JSONDecoder().decode(AgentEditPlan.self, from: data)
        XCTAssertEqual(decoded.expectedSourceFingerprints, plan.expectedSourceFingerprints)
        XCTAssertEqual(decoded.planHash, plan.planHash)
    }

    func testTimelineVersionCanonicalizesFullSourceRange() {
        let material = EditorAsset(type: .video, nativeDuration: 10)
        let segment = EditorSegment(
            materialID: material.id,
            targetRange: TimeRange(start: 0, duration: 10),
            content: .video(.init())
        )
        var compact = EditorTimeline(canvas: EditorCanvas(width: 1, height: 1))
        compact.materials.add(material)
        compact.tracks = [EditorTrack(kind: .video, segments: [segment], isMainTrack: true)]

        var explicit = compact
        explicit.tracks[0].segments[0].sourceRange = TimeRange(start: 0, duration: 10)

        XCTAssertEqual(AgentEditPlan.timelineVersion(for: compact), AgentEditPlan.timelineVersion(for: explicit))
        XCTAssertNil(AgentEditPlan.canonicalTimeline(explicit).tracks[0].segments[0].sourceRange)
    }

    func testTimelineVersionIsStableAcrossMaterialInsertionOrder() {
        let first = EditorAsset(type: .video)
        let second = EditorAsset(type: .audio)
        var a = EditorTimeline(canvas: EditorCanvas(width: 1, height: 1))
        a.materials.add(first); a.materials.add(second)
        var b = EditorTimeline(id: a.id, canvas: EditorCanvas(width: 1, height: 1), metadata: a.metadata)
        b.materials.add(second); b.materials.add(first)
        XCTAssertEqual(AgentEditPlan.timelineVersion(for: a), AgentEditPlan.timelineVersion(for: b))
    }

    func testTrimRejectsSourceRangeBeyondNativeDuration() {
        var value = timeline()
        let materialID = value.tracks[0].segments[0].materialID
        value.materials[materialID]?.nativeDuration = 10
        let segmentID = value.tracks[0].segments[0].id
        let plan = AgentEditPlan(
            planID: "trim-bounds",
            baseTimelineVersion: AgentEditPlan.timelineVersion(for: value),
            commands: [.trim(segmentID: segmentID, sourceStart: 8, targetStart: 0, duration: 4)]
        )
        XCTAssertThrowsError(try AgentEditEngine.preview(plan: plan, timeline: value)) { error in
            guard case AgentEditError.invalidPlan = error else { XCTFail("unexpected error: \(error)"); return }
        }
    }

    func testPlanJSONRoundTripsGeneratedCommandIDs() throws {
        let value = timeline()
        let materialID = value.tracks[0].segments[0].materialID
        let sourceID = value.tracks[0].segments[0].id
        let subtitleID = UUID()
        let splitID = UUID()
        let plan = AgentEditPlan(
            planID: "roundtrip",
            baseTimelineVersion: AgentEditPlan.timelineVersion(for: value),
            commands: [
                .roughCut(materialID: materialID, sourceRanges: [TimeRange(start: 1, duration: 2)], segmentIDs: [UUID()]),
                .addSubtitle(segmentID: subtitleID, text: "subtitle", targetStart: 0, duration: 1),
                .split(segmentID: sourceID, at: 2, newSegmentID: splitID)
            ],
            expectedSourceFingerprints: [materialID: "fingerprint"],
            externalPlanID: "external",
            externalPlanHash: "external-hash"
        )
        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(AgentEditPlan.self, from: data), plan)
    }

    func testExecutionStoreFailuresArePropagated() async {
        let value = timeline()
        let plan = AgentEditPlan(planID: "p1", baseTimelineVersion: AgentEditPlan.timelineVersion(for: value), commands: [])

        do {
            _ = try await AgentEditEngine.apply(
                plan: plan,
                timeline: value,
                executionID: "lookup-failure",
                executionStore: FailingExecutionStore(lookupFailure: true)
            )
            XCTFail("expected lookup failure")
        } catch let error as FailingExecutionStore.Failure {
            XCTAssertEqual(error, .lookup)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        do {
            _ = try await AgentEditEngine.apply(
                plan: plan,
                timeline: value,
                executionID: "record-failure",
                executionStore: FailingExecutionStore(recordFailure: true)
            )
            XCTFail("expected record failure")
        } catch let error as FailingExecutionStore.Failure {
            XCTAssertEqual(error, .record)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(value.duration, 10)
    }

    func testContractFixtureWithoutGeneratedIDsIsDeterministic() throws {
        let value = timeline()
        let sourceID = value.tracks[0].segments[0].id
        let plan = AgentEditPlan(
            planID: "contract-ids",
            baseTimelineVersion: AgentEditPlan.timelineVersion(for: value),
            commands: [
                .addSubtitle(segmentID: nil, text: "one", targetStart: 0, duration: 1),
                .addSubtitle(segmentID: nil, text: "two", targetStart: 2, duration: 1),
                .split(segmentID: sourceID, at: 4, newSegmentID: nil)
            ]
        )
        let decoded = try JSONDecoder().decode(AgentEditPlan.self, from: JSONEncoder().encode(plan))
        let first = try AgentEditEngine.preview(plan: decoded, timeline: value)
        let second = try AgentEditEngine.preview(plan: decoded, timeline: value)
        XCTAssertEqual(first.timeline, second.timeline)
        XCTAssertEqual(first.timeline.tracks(ofKind: .subtitle).flatMap(\.segments).count, 2)
        XCTAssertEqual(first.timeline.mainTrack?.segments.count, 2)
    }

    func testApplyExternalTimelineIsOneUndoUnit() {
        let document = TimelineDocument(timeline: timeline())
        let before = document.timeline
        var changed = before
        changed.tracks[0].segments[0].targetRange = TimeRange(start: 0, duration: 4)
        document.applyExternalTimeline(changed)
        XCTAssertEqual(document.timeline, changed)
        XCTAssertTrue(document.canUndo)
        document.undo()
        XCTAssertEqual(document.timeline, before)
    }

    func testSplitUsesCallerProvidedStableID() throws {
        var value = timeline()
        value.tracks[0].segments[0].targetRange = TimeRange(start: 0, duration: 10)
        let segmentID = value.tracks[0].segments[0].id
        let newID = UUID()
        let plan = AgentEditPlan(
            planID: "split",
            baseTimelineVersion: AgentEditPlan.timelineVersion(for: value),
            commands: [.split(segmentID: segmentID, at: 4, newSegmentID: newID)]
        )
        let first = try AgentEditEngine.preview(plan: plan, timeline: value)
        let second = try AgentEditEngine.preview(plan: plan, timeline: value)
        XCTAssertEqual(first.timeline, second.timeline)
        XCTAssertNotNil(first.timeline.segment(id: newID))
    }
}

private actor FailingExecutionStore: AgentExecutionStore {
    enum Failure: Error, Equatable, Sendable {
        case lookup
        case record
    }

    let lookupFailure: Bool
    let recordFailure: Bool

    init(lookupFailure: Bool = false, recordFailure: Bool = false) {
        self.lookupFailure = lookupFailure
        self.recordFailure = recordFailure
    }

    func result(for executionID: String) throws -> AgentExecutionResult? {
        if lookupFailure { throw Failure.lookup }
        return nil
    }

    func record(_ result: AgentExecutionResult) throws {
        if recordFailure { throw Failure.record }
    }
}

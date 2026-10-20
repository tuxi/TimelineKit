import Foundation

// MARK: - Agent edit plan

/// The small, deterministic command vocabulary shared by the App, CLI and MCP adapters.
/// Agent runtime, networking and persistence are deliberately outside TimelineKitCore.
public struct AgentEditPlan: Codable, Sendable, Hashable {
    public let planID: String
    public let baseTimelineVersion: String
    public let commands: [AgentEditCommand]
    /// Asset ID -> adapter-computed fingerprint. An empty map means no source was checked.
    public let expectedSourceFingerprints: [UUID: String]
    /// Optional identity supplied by an external approval system. Core never verifies it.
    public let externalPlanID: String?
    public let externalPlanHash: String?

    private enum CodingKeys: String, CodingKey {
        case planID, baseTimelineVersion, commands
        case expectedSourceFingerprints, externalPlanID, externalPlanHash
    }

    public init(
        planID: String,
        baseTimelineVersion: String,
        commands: [AgentEditCommand],
        expectedSourceFingerprints: [UUID: String] = [:],
        externalPlanID: String? = nil,
        externalPlanHash: String? = nil
    ) {
        self.planID = planID
        self.baseTimelineVersion = baseTimelineVersion
        self.commands = commands
        self.expectedSourceFingerprints = expectedSourceFingerprints
        self.externalPlanID = externalPlanID
        self.externalPlanHash = externalPlanHash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.planID = try c.decode(String.self, forKey: .planID)
        self.baseTimelineVersion = try c.decode(String.self, forKey: .baseTimelineVersion)
        self.commands = try c.decode([AgentEditCommand].self, forKey: .commands)

        // Canonical JSON form is an object keyed by UUID string. The array fallback
        // accepts plans written by the first in-memory prototype. A present but
        // malformed value is rejected rather than treated as "no source checks".
        if c.contains(.expectedSourceFingerprints) {
            if let object = try? c.decode([String: String].self, forKey: .expectedSourceFingerprints) {
                var fingerprints: [UUID: String] = [:]
                for (key, value) in object {
                    guard let id = UUID(uuidString: key) else {
                        throw DecodingError.dataCorruptedError(forKey: .expectedSourceFingerprints, in: c, debugDescription: "Invalid asset UUID key: \(key)")
                    }
                    fingerprints[id] = value
                }
                self.expectedSourceFingerprints = fingerprints
            } else if let legacyArray = try? c.decode([String].self, forKey: .expectedSourceFingerprints) {
                guard legacyArray.count.isMultiple(of: 2) else {
                    throw DecodingError.dataCorruptedError(forKey: .expectedSourceFingerprints, in: c, debugDescription: "Expected alternating UUID/fingerprint values")
                }
                var fingerprints: [UUID: String] = [:]
                for index in stride(from: 0, to: legacyArray.count, by: 2) {
                    guard let id = UUID(uuidString: legacyArray[index]) else {
                        throw DecodingError.dataCorruptedError(forKey: .expectedSourceFingerprints, in: c, debugDescription: "Invalid asset UUID key: \(legacyArray[index])")
                    }
                    fingerprints[id] = legacyArray[index + 1]
                }
                self.expectedSourceFingerprints = fingerprints
            } else {
                throw DecodingError.dataCorruptedError(forKey: .expectedSourceFingerprints, in: c, debugDescription: "Expected an object keyed by asset UUID string")
            }
        } else {
            self.expectedSourceFingerprints = [:]
        }

        self.externalPlanID = try c.decodeIfPresent(String.self, forKey: .externalPlanID)
        self.externalPlanHash = try c.decodeIfPresent(String.self, forKey: .externalPlanHash)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(planID, forKey: .planID)
        try c.encode(baseTimelineVersion, forKey: .baseTimelineVersion)
        try c.encode(commands, forKey: .commands)
        let fingerprints = Dictionary(uniqueKeysWithValues: expectedSourceFingerprints.map { ($0.key.uuidString, $0.value) })
        try c.encode(fingerprints, forKey: .expectedSourceFingerprints)
        try c.encodeIfPresent(externalPlanID, forKey: .externalPlanID)
        try c.encodeIfPresent(externalPlanHash, forKey: .externalPlanHash)
    }

    /// Stable local hash of the normalized command snapshot. External approval
    /// identity is deliberately excluded: `externalPlanHash` is owned by the
    /// upstream approval system and must never be treated as this value.
    /// This is an optimistic-concurrency token, not a cryptographic signature.
    public var planHash: String {
        let canonical = CanonicalPlan(
            planID: planID,
            baseTimelineVersion: baseTimelineVersion,
            commands: commands,
            expectedSourceFingerprints: Dictionary(uniqueKeysWithValues: expectedSourceFingerprints.map { ($0.key.uuidString, $0.value) })
        )
        return Self.stableHash(Self.canonicalData(canonical))
    }

    /// Semantic canonical form used by revision hashing and host persistence.
    /// A `sourceRange` covering the full native asset is equivalent to `nil`
    /// (the model's "use full asset" representation). Without this, an importer
    /// writing `[0, nativeDuration)` and a later save writing `nil` would produce
    /// two revisions for the same project.
    public static func canonicalTimeline(_ timeline: EditorTimeline) -> EditorTimeline {
        var result = timeline
        for asset in result.materials.all {
            guard let nativeDuration = asset.nativeDuration,
                  nativeDuration.isFinite,
                  nativeDuration > 0 else { continue }
            for trackIndex in result.tracks.indices {
                for segmentIndex in result.tracks[trackIndex].segments.indices
                where result.tracks[trackIndex].segments[segmentIndex].materialID == asset.id {
                    guard let sourceRange = result.tracks[trackIndex].segments[segmentIndex].sourceRange,
                          abs(sourceRange.start) <= 0.001,
                          abs(sourceRange.end - nativeDuration) <= 0.001 else { continue }
                    result.tracks[trackIndex].segments[segmentIndex].sourceRange = nil
                }
            }
        }
        return result
    }

    public static func timelineVersion(for timeline: EditorTimeline) -> String {
        stableHash(canonicalData(canonicalTimeline(timeline)))
    }

    private struct CanonicalPlan: Encodable {
        let planID: String
        let baseTimelineVersion: String
        let commands: [AgentEditCommand]
        let expectedSourceFingerprints: [String: String]
    }

    private static func canonicalData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    /// FNV-1a is intentionally used instead of a platform-dependent hashValue.
    /// This is an opaque optimistic-concurrency token, not a cryptographic signature.
    private static func stableHash(_ data: Data) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in data { hash ^= UInt64(byte); hash &*= 1099511628211 }
        return String(format: "%016llx", hash)
    }
}

public enum AgentEditCommand: Codable, Sendable, Hashable {
    case trim(segmentID: UUID, sourceStart: Double?, targetStart: Double, duration: Double)
    case delete(segmentID: UUID)
    case move(segmentID: UUID, targetStart: Double)
    case split(segmentID: UUID, at: Double, newSegmentID: UUID?)
    case addSubtitle(segmentID: UUID?, text: String, targetStart: Double, duration: Double)
    case roughCut(materialID: UUID, sourceRanges: [TimeRange], segmentIDs: [UUID])

    private enum CodingKeys: String, CodingKey { case type, segmentID, newSegmentID, sourceStart, targetStart, duration, at, text, materialID, sourceRanges, segmentIDs }
    private enum Kind: String, Codable { case trim, delete, move, split, addSubtitle, roughCut }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .trim(id, source, start, duration):
            try c.encode(Kind.trim, forKey: .type); try c.encode(id, forKey: .segmentID)
            try c.encodeIfPresent(source, forKey: .sourceStart); try c.encode(start, forKey: .targetStart); try c.encode(duration, forKey: .duration)
        case let .delete(id): try c.encode(Kind.delete, forKey: .type); try c.encode(id, forKey: .segmentID)
        case let .move(id, start): try c.encode(Kind.move, forKey: .type); try c.encode(id, forKey: .segmentID); try c.encode(start, forKey: .targetStart)
        case let .split(id, at, newID):
            try c.encode(Kind.split, forKey: .type); try c.encode(id, forKey: .segmentID); try c.encode(at, forKey: .at); try c.encodeIfPresent(newID, forKey: .newSegmentID)
        case let .addSubtitle(segmentID, text, start, duration):
            try c.encode(Kind.addSubtitle, forKey: .type); try c.encodeIfPresent(segmentID, forKey: .segmentID); try c.encode(text, forKey: .text); try c.encode(start, forKey: .targetStart); try c.encode(duration, forKey: .duration)
        case let .roughCut(materialID, ranges, segmentIDs):
            try c.encode(Kind.roughCut, forKey: .type); try c.encode(materialID, forKey: .materialID); try c.encode(ranges, forKey: .sourceRanges); try c.encode(segmentIDs, forKey: .segmentIDs)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .trim: self = .trim(segmentID: try c.decode(UUID.self, forKey: .segmentID), sourceStart: try c.decodeIfPresent(Double.self, forKey: .sourceStart), targetStart: try c.decode(Double.self, forKey: .targetStart), duration: try c.decode(Double.self, forKey: .duration))
        case .delete: self = .delete(segmentID: try c.decode(UUID.self, forKey: .segmentID))
        case .move: self = .move(segmentID: try c.decode(UUID.self, forKey: .segmentID), targetStart: try c.decode(Double.self, forKey: .targetStart))
        case .split: self = .split(segmentID: try c.decode(UUID.self, forKey: .segmentID), at: try c.decode(Double.self, forKey: .at), newSegmentID: try c.decodeIfPresent(UUID.self, forKey: .newSegmentID))
        case .addSubtitle: self = .addSubtitle(segmentID: try c.decodeIfPresent(UUID.self, forKey: .segmentID), text: try c.decode(String.self, forKey: .text), targetStart: try c.decode(Double.self, forKey: .targetStart), duration: try c.decode(Double.self, forKey: .duration))
        case .roughCut: self = .roughCut(materialID: try c.decode(UUID.self, forKey: .materialID), sourceRanges: try c.decode([TimeRange].self, forKey: .sourceRanges), segmentIDs: try c.decode([UUID].self, forKey: .segmentIDs))
        }
    }
}

public struct AgentEditPreview: Sendable {
    public let planHash: String
    public let timeline: EditorTimeline
    public let resultingTimelineVersion: String
}

public struct AgentExecutionResult: Codable, Sendable, Hashable {
    public let executionID: String
    public let planID: String
    public let planHash: String
    public let timeline: EditorTimeline
    public let timelineVersion: String
    /// True when this execution produced the stored result at least once.
    public let applied: Bool
    /// True when this call returned the stored result without applying again.
    public let replayed: Bool
    public let externalPlanID: String?
    public let externalPlanHash: String?

    public init(
        executionID: String,
        planID: String,
        planHash: String,
        timeline: EditorTimeline,
        timelineVersion: String,
        applied: Bool,
        replayed: Bool = false,
        externalPlanID: String? = nil,
        externalPlanHash: String? = nil
    ) {
        self.executionID = executionID
        self.planID = planID
        self.planHash = planHash
        self.timeline = timeline
        self.timelineVersion = timelineVersion
        self.applied = applied
        self.replayed = replayed
        self.externalPlanID = externalPlanID
        self.externalPlanHash = externalPlanHash
    }

    /// Adapters should only write the project when this is true.
    public var didApply: Bool { applied && !replayed }
}

public enum AgentEditError: Error, LocalizedError, Sendable, Equatable {
    case invalidPlan(String)
    case staleTimeline(expected: String, actual: String)
    case sourceFingerprintMismatch(assetID: UUID, expected: String, actual: String)
    case executionConflict(executionID: String)

    public var errorDescription: String {
        switch self {
        case .invalidPlan(let message): "Invalid edit plan: \(message)"
        case let .staleTimeline(expected, actual): "Timeline revision is stale (expected \(expected), actual \(actual))"
        case let .sourceFingerprintMismatch(id, expected, actual): "Source fingerprint mismatch for \(id) (expected \(expected), actual \(actual))"
        case .executionConflict(let id): "Execution ID \(id) was already used with a different plan"
        }
    }
}

/// Persistence boundary for exactly-once application. A production App adapter should back
/// this protocol with its project store; Core intentionally only ships an in-memory version.
///
/// `record` is the host commit hook. The host should persist the returned timeline, the
/// single undo unit, and the execution record before returning. If any part fails, throw:
/// Core propagates the error instead of reporting a successful apply.
///
/// `result(for:)` should throw when the host journal is unavailable or corrupt. Returning
/// `nil` means "no record exists" and permits a fresh apply; do not use `nil` for I/O errors.
public protocol AgentExecutionStore: Sendable {
    func result(for executionID: String) async throws -> AgentExecutionResult?
    func record(_ result: AgentExecutionResult) async throws
}

public actor InMemoryAgentExecutionStore: AgentExecutionStore {
    private var results: [String: AgentExecutionResult] = [:]
    public init() {}
    public func result(for executionID: String) throws -> AgentExecutionResult? { results[executionID] }
    public func record(_ result: AgentExecutionResult) throws { results[result.executionID] = result }
}

@MainActor
public enum AgentEditEngine {
    public static func preview(
        plan: AgentEditPlan,
        timeline: EditorTimeline,
        sourceFingerprint: ((EditorAsset) -> String?)? = nil
    ) throws -> AgentEditPreview {
        try validatePreconditions(plan: plan, timeline: timeline, sourceFingerprint: sourceFingerprint ?? defaultSourceFingerprint)
        let updated = try applyCommands(plan.commands, to: timeline)
        return AgentEditPreview(planHash: plan.planHash, timeline: updated, resultingTimelineVersion: AgentEditPlan.timelineVersion(for: updated))
    }

    public static func apply(
        plan: AgentEditPlan,
        timeline: EditorTimeline,
        executionID: String,
        executionStore: AgentExecutionStore,
        sourceFingerprint: ((EditorAsset) -> String?)? = nil
    ) async throws -> AgentExecutionResult {
        if let previous = try await executionStore.result(for: executionID) {
            guard previous.planHash == plan.planHash, previous.planID == plan.planID else { throw AgentEditError.executionConflict(executionID: executionID) }
            return AgentExecutionResult(
                executionID: previous.executionID,
                planID: previous.planID,
                planHash: previous.planHash,
                timeline: previous.timeline,
                timelineVersion: previous.timelineVersion,
                applied: previous.applied,
                replayed: true,
                externalPlanID: previous.externalPlanID,
                externalPlanHash: previous.externalPlanHash
            )
        }
        try validatePreconditions(plan: plan, timeline: timeline, sourceFingerprint: sourceFingerprint ?? defaultSourceFingerprint)
        let updated = try applyCommands(plan.commands, to: timeline)
        let result = AgentExecutionResult(executionID: executionID, planID: plan.planID, planHash: plan.planHash, timeline: updated, timelineVersion: AgentEditPlan.timelineVersion(for: updated), applied: true, externalPlanID: plan.externalPlanID, externalPlanHash: plan.externalPlanHash)
        try await executionStore.record(result)
        return result
    }

    private static func applyCommands(_ commands: [AgentEditCommand], to timeline: EditorTimeline) throws -> EditorTimeline {
        let document = TimelineDocument(timeline: timeline)
        for command in commands {
            switch command {
            case let .delete(id):
                guard document.timeline.segment(id: id) != nil else { throw AgentEditError.invalidPlan("delete target not found: \(id)") }
                document.deleteSegment(id: id)
            case let .trim(id, sourceStart, targetStart, duration):
                guard duration > 0, targetStart >= 0, let segment = document.timeline.segment(id: id) else { throw AgentEditError.invalidPlan("invalid trim for \(id)") }
                let sourceDuration = duration * max(segment.speed, 0.001)
                var effectiveSourceStart: Double? = nil
                switch segment.content {
                case .video, .audio:
                    let start = sourceStart ?? segment.sourceRange?.start ?? 0
                    guard start >= 0 else { throw AgentEditError.invalidPlan("sourceStart must be non-negative") }
                    if let nativeDuration = document.timeline.materials[segment.materialID]?.nativeDuration {
                        guard start + sourceDuration <= nativeDuration + 0.000_001 else {
                            throw AgentEditError.invalidPlan("trim source range exceeds source duration for \(id)")
                        }
                    }
                    effectiveSourceStart = start
                default:
                    effectiveSourceStart = sourceStart
                }
                document.trimSegment(id: id, newTargetRange: TimeRange(start: targetStart, duration: duration), newSourceRangeStart: effectiveSourceStart)
                guard document.timeline.segment(id: id) != segment else { throw AgentEditError.invalidPlan("trim was not applied for \(id)") }
            case let .move(id, start):
                guard start >= 0, document.timeline.segment(id: id) != nil else { throw AgentEditError.invalidPlan("invalid move for \(id)") }
                document.moveSegment(id: id, to: start)
            case let .split(id, at, requestedNewSegmentID):
                let newSegmentID = requestedNewSegmentID ?? stableUUID("split:\(id.uuidString):\(at)")
                guard document.timeline.segment(id: newSegmentID) == nil else { throw AgentEditError.invalidPlan("split target ID already exists: \(newSegmentID)") }
                guard document.splitSegment(id: id, at: at, newSegmentID: newSegmentID) != nil else { throw AgentEditError.invalidPlan("invalid split for \(id)") }
            case let .addSubtitle(requestedSegmentID, text, start, duration):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, start >= 0, duration > 0 else { throw AgentEditError.invalidPlan("subtitle requires non-empty text, non-negative start and positive duration") }
                let segmentID = requestedSegmentID ?? stableUUID("subtitle:\(text):\(start):\(duration)")
                guard document.timeline.segment(id: segmentID) == nil, document.timeline.materials[segmentID] == nil else { throw AgentEditError.invalidPlan("subtitle segmentID already exists: \(segmentID)") }
                // Subtitles need a placeholder material so the timeline passes the same
                // material-reference validation as the App-created subtitle path.
                document.timeline.materials.add(EditorAsset(id: segmentID, type: .placeholder))
                let segment = EditorSegment(id: segmentID, materialID: segmentID, targetRange: TimeRange(start: start, duration: duration), content: .subtitle(.init(text: text)))
                try addSubtitle(segment, to: document)
            case let .roughCut(materialID, sourceRanges, segmentIDs):
                guard sourceRanges.count == segmentIDs.count, !sourceRanges.isEmpty else { throw AgentEditError.invalidPlan("roughCut requires matching non-empty sourceRanges and segmentIDs") }
                guard let asset = document.timeline.materials[materialID], asset.type == .video,
                      let main = document.timeline.mainTrack,
                      main.segments.count == 1,
                      main.segments[0].materialID == materialID,
                      main.segments[0].speed == 1,
                      main.segments[0].keyframes.isEmpty,
                      main.segments[0].animations.isEmpty,
                      main.segments[0].leadingTransitionID == nil,
                      main.segments[0].trailingTransitionID == nil,
                      document.timeline.tracks.flatMap(\.segments).filter({ $0.materialID == materialID }).count == 1,
                      document.timeline.transitions.isEmpty else { throw AgentEditError.invalidPlan("roughCut requires one unique 1x full-source video clip without keyframes, animations or transitions") }
                guard let nativeDuration = asset.nativeDuration else { throw AgentEditError.invalidPlan("roughCut requires a source duration") }
                guard coversFullSource(main.segments[0].sourceRange, nativeDuration: nativeDuration) else {
                    throw AgentEditError.invalidPlan("roughCut requires a full-source main clip")
                }
                guard sourceRanges.allSatisfy({ $0.start >= 0 && $0.duration > 0 && $0.end <= nativeDuration }) else { throw AgentEditError.invalidPlan("roughCut ranges must fit the source duration") }
                guard zip(sourceRanges.dropLast(), sourceRanges.dropFirst()).allSatisfy({ $0.0.end <= $0.1.start }) else { throw AgentEditError.invalidPlan("roughCut sourceRanges must be ordered and non-overlapping") }
                guard Set(segmentIDs).count == segmentIDs.count else { throw AgentEditError.invalidPlan("roughCut segmentIDs must be unique") }
                let original = main.segments[0]
                let occupiedIDs = Set(document.timeline.tracks.flatMap(\.segments).map(\.id)).subtracting([original.id])
                guard occupiedIDs.isDisjoint(with: segmentIDs) else { throw AgentEditError.invalidPlan("roughCut segmentIDs collide with existing segments") }
                var cursor = 0.0
                let generated = zip(sourceRanges, segmentIDs).map { range, id in
                    let segment = EditorSegment(id: id, materialID: materialID, sourceRange: range, targetRange: TimeRange(start: cursor, duration: range.duration), speed: 1, transform: original.transform, blendMode: original.blendMode, keyframes: original.keyframes, content: original.content, adjustment: original.adjustment)
                    cursor += range.duration
                    return segment
                }
                document.mutate("Agent粗剪") { tl in
                    guard let index = tl.tracks.firstIndex(where: { $0.id == main.id }) else { return }
                    tl.tracks[index].segments = generated
                }
            }
        }
        return document.timeline
    }

    /// `nil` and `[0, nativeDuration)` are the same semantic full-source clip.
    private static func coversFullSource(_ sourceRange: TimeRange?, nativeDuration: Double) -> Bool {
        guard let sourceRange else { return true }
        return abs(sourceRange.start) <= 0.001
            && abs(sourceRange.end - nativeDuration) <= 0.001
    }

    /// Stable fallback ID for commands that omit an explicit generated-segment UUID.
    /// This is a local deterministic identifier, not a cryptographic UUID.
    private static func stableUUID(_ value: String) -> UUID {
        var first: UInt64 = 14695981039346656037
        var second: UInt64 = 1099511628211
        for byte in value.utf8 {
            first = (first ^ UInt64(byte)) &* 1099511628211
            second = (second ^ UInt64(byte)) &* 14695981039346656037
        }
        let hex = Array(String(format: "%016llx%016llx", first, second))
        func part(_ range: Range<Int>) -> String { String(hex[range]) }
        return UUID(uuidString: "\(part(0..<8))-\(part(8..<12))-\(part(12..<16))-\(part(16..<20))-\(part(20..<32))")!
    }

    /// Deterministic replacement for `addSegmentAutoTrack(kind: .subtitle, ...)`.
    /// The auto-track helper creates a random track UUID when no reusable track
    /// exists, which makes preview and apply structurally different.
    private static func addSubtitle(_ segment: EditorSegment, to document: TimelineDocument) throws {
        let candidates = document.timeline.tracks(ofKind: .subtitle)
            .sorted { ($0.zPosition, $0.id.uuidString) < ($1.zPosition, $1.id.uuidString) }
        if let reusable = candidates.first(where: { !$0.segments.contains { $0.targetRange.overlaps(segment.targetRange) } }) {
            document.addSegment(toTrack: reusable.id, segment: segment)
            return
        }

        // Track IDs and segment IDs are separate namespaces. Reusing the stable
        // segment UUID gives the generated track a caller-controlled identity.
        let trackID = segment.id
        guard document.timeline.track(id: trackID) == nil else {
            throw AgentEditError.invalidPlan("subtitle track ID already exists: \(trackID)")
        }
        let existing = document.timeline.tracks(ofKind: .subtitle)
        let resolvedZ = existing.isEmpty
            ? TimelineDocument.defaultZPosition(for: .subtitle)
            : (existing.map(\.zPosition).max() ?? 0) + 1
        let label = "\(TimelineDocument.displayName(for: .subtitle)) \(existing.count + 1)"
        let track = EditorTrack(
            id: trackID,
            kind: .subtitle,
            label: label,
            zPosition: resolvedZ,
            segments: [segment],
            isMainTrack: false
        )
        document.mutateSubtitle("Agent字幕") { timeline in
            timeline.tracks.append(track)
        }
    }

    private static func validatePreconditions(plan: AgentEditPlan, timeline: EditorTimeline, sourceFingerprint: (EditorAsset) -> String?) throws {
        let actualVersion = AgentEditPlan.timelineVersion(for: timeline)
        guard actualVersion == plan.baseTimelineVersion else { throw AgentEditError.staleTimeline(expected: plan.baseTimelineVersion, actual: actualVersion) }
        for (assetID, expected) in plan.expectedSourceFingerprints {
            guard let asset = timeline.materials[assetID], let actual = sourceFingerprint(asset) else { throw AgentEditError.sourceFingerprintMismatch(assetID: assetID, expected: expected, actual: "missing") }
            guard actual == expected else { throw AgentEditError.sourceFingerprintMismatch(assetID: assetID, expected: expected, actual: actual) }
        }
    }

    private static func defaultSourceFingerprint(_ asset: EditorAsset) -> String? {
        guard let url = asset.localURL, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash: UInt64 = 14695981039346656037
        while true {
            guard let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            for byte in chunk { hash ^= UInt64(byte); hash &*= 1099511628211 }
        }
        return String(format: "%016llx", hash)
    }
}

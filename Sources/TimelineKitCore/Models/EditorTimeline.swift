import Foundation

/// The canonical in-memory model for the clip editor.
///
/// Design principles:
/// - All times are absolute seconds from the timeline origin. No relative offsets.
/// - Assets live in `materials`; tracks hold segment IDs that reference them.
/// - This type is a pure value (Sendable struct) — mutations are explicit copy-on-write.
/// - Conversion to/from server `VideoTimeline` format is handled by `TimelineImporter` / `TimelineExporter`.
public struct EditorTimeline: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var canvas: EditorCanvas
    /// Ordered list of tracks. zPosition determines compositing order.
    public var tracks: [EditorTrack]
    public var materials: MaterialsPool
    public var transitions: [EditorTransition]
    public var metadata: EditorMetadata

    public init(
        id: UUID = UUID(),
        canvas: EditorCanvas,
        tracks: [EditorTrack] = [],
        materials: MaterialsPool = MaterialsPool(),
        transitions: [EditorTransition] = [],
        metadata: EditorMetadata = EditorMetadata()
    ) {
        self.id          = id
        self.canvas      = canvas
        self.tracks      = tracks
        self.materials   = materials
        self.transitions = transitions
        self.metadata    = metadata
    }

    // MARK: - Computed

    /// Total composition duration in seconds.
    ///
    /// V7 invariant: transitions are render-only visual blends. They do NOT shorten
    /// the timeline — composition time == visual timeline time (1 : 1 mapping).
    /// Duration is simply the sum of all main-track segment durations.
    public var duration: Double {
        let mainSegs = (mainTrack?.segments ?? [])
            .sorted { $0.targetRange.start < $1.targetRange.start }

        guard !mainSegs.isEmpty else {
            return tracks.flatMap { $0.segments }.map { $0.targetRange.end }.max() ?? 0
        }

        return mainSegs.reduce(0) { $0 + $1.targetRange.duration }
    }

    /// The unique backbone track. Nil only if the timeline was built without one.
    public var mainTrack: EditorTrack? {
        tracks.first { $0.isMainTrack }
    }

    public func tracks(ofKind kind: EditorTrack.Kind) -> [EditorTrack] {
        tracks.filter { $0.kind == kind }
    }

    public func track(id: UUID) -> EditorTrack? {
        tracks.first { $0.id == id }
    }

    // MARK: - Mutation helpers

    /// Enforce the single-main-track invariant: if more than one track has
    /// isMainTrack == true, keep only the first one.
    public mutating func normalizeMainTrack() {
        var found = false
        for i in tracks.indices {
            if tracks[i].isMainTrack {
                if found { tracks[i].isMainTrack = false }
                else { found = true }
            }
        }
    }

    public func segment(id: UUID) -> EditorSegment? {
        for track in tracks {
            if let s = track.segment(id: id) { return s }
        }
        return nil
    }

    /// v4: find the track that contains `segmentID`, if any.
    public func track(containing segmentID: UUID) -> EditorTrack? {
        for track in tracks {
            if track.segment(id: segmentID) != nil { return track }
        }
        return nil
    }

    public func activeSegments(at time: Double) -> [EditorSegment] {
        tracks
            .sorted { $0.zPosition < $1.zPosition }
            .compactMap { $0.segment(at: time) }
    }

    // MARK: - Mutation helpers

    public mutating func updateTrack(id: UUID, _ body: (inout EditorTrack) -> Void) {
        guard let idx = tracks.firstIndex(where: { $0.id == id }) else { return }
        body(&tracks[idx])
    }

    public mutating func updateSegment(id segmentID: UUID, _ body: (inout EditorSegment) -> Void) {
        for i in tracks.indices {
            if let j = tracks[i].segments.firstIndex(where: { $0.id == segmentID }) {
                body(&tracks[i].segments[j])
                return
            }
        }
    }

    public mutating func removeSegment(id segmentID: UUID) {
        for i in tracks.indices {
            tracks[i].removeSegment(id: segmentID)
        }
    }

    public mutating func transition(leadingSegmentID: UUID, trailingSegmentID: UUID) -> EditorTransition? {
        transitions.first {
            $0.leadingSegmentID == leadingSegmentID && $0.trailingSegmentID == trailingSegmentID
        }
    }

    // MARK: - Transition mutations (v2)

    /// Adds a transition between two adjacent main-track segments.
    /// Returns the new transition, or nil if the pair is invalid (non-adjacent, too short, already has one).
    @discardableResult
    public mutating func addTransition(
        between leadingID: UUID,
        and trailingID: UUID,
        type: EditorTransition.TransitionType,
        duration: Double
    ) -> EditorTransition? {
        guard let leadingSeg  = segment(id: leadingID),
              let trailingSeg = segment(id: trailingID) else { return nil }

        // Prevent duplicate
        let duplicate = transitions.contains {
            $0.leadingSegmentID == leadingID && $0.trailingSegmentID == trailingID
        }
        guard !duplicate else { return nil }

        let minD: Double = 0.2
        let validMax = min(3.0, min(leadingSeg.targetRange.duration, trailingSeg.targetRange.duration))
        guard validMax >= minD else { return nil }

        let clampedDuration = max(minD, min(duration, validMax))
        let t = EditorTransition(
            type:              type,
            duration:          clampedDuration,
            leadingSegmentID:  leadingID,
            trailingSegmentID: trailingID
        )
        transitions.append(t)
        updateSegment(id: leadingID)  { $0.trailingTransitionID = t.id }
        updateSegment(id: trailingID) { $0.leadingTransitionID  = t.id }
        return t
    }

    /// Removes a transition and clears the back-references on both segments.
    public mutating func removeTransition(id: UUID) {
        guard let t = transitions.first(where: { $0.id == id }) else { return }
        updateSegment(id: t.leadingSegmentID)  { $0.trailingTransitionID = nil }
        updateSegment(id: t.trailingSegmentID) { $0.leadingTransitionID  = nil }
        transitions.removeAll { $0.id == id }
    }

    /// Changes only the duration of an existing transition (clamped to valid range).
    public mutating func updateTransitionDuration(id: UUID, duration: Double) {
        guard let idx = transitions.firstIndex(where: { $0.id == id }) else { return }
        let t = transitions[idx]
        guard let leadingSeg  = segment(id: t.leadingSegmentID),
              let trailingSeg = segment(id: t.trailingSegmentID) else { return }
        let validMax = min(3.0, min(leadingSeg.targetRange.duration, trailingSeg.targetRange.duration))
        transitions[idx].duration = max(0.2, min(duration, validMax))
    }

    /// Changes only the type of an existing transition (no geometry change).
    public mutating func updateTransitionType(id: UUID, type: EditorTransition.TransitionType) {
        guard let idx = transitions.firstIndex(where: { $0.id == id }) else { return }
        transitions[idx].type = type
    }

    /// V7: Add a transition using a presetID instead of a legacy TransitionType.
    @discardableResult
    public mutating func addTransition(
        between leadingID: UUID,
        and trailingID: UUID,
        presetID: String,
        duration: Double
    ) -> EditorTransition? {
        guard let leadingSeg  = segment(id: leadingID),
              let trailingSeg = segment(id: trailingID) else { return nil }

        let duplicate = transitions.contains {
            $0.leadingSegmentID == leadingID && $0.trailingSegmentID == trailingID
        }
        guard !duplicate else { return nil }

        let minD: Double = 0.2
        let validMax = min(3.0, min(leadingSeg.targetRange.duration, trailingSeg.targetRange.duration))
        guard validMax >= minD else { return nil }

        let clampedDuration = max(minD, min(duration, validMax))
        let t = EditorTransition(
            type:              .crossFade,
            duration:          clampedDuration,
            leadingSegmentID:  leadingID,
            trailingSegmentID: trailingID,
            presetID:          presetID
        )
        transitions.append(t)
        updateSegment(id: leadingID)  { $0.trailingTransitionID = t.id }
        updateSegment(id: trailingID) { $0.leadingTransitionID  = t.id }
        return t
    }

    /// V7: Update a transition's presetID (and optionally duration) in one undo-trackable step.
    public mutating func updateTransitionPreset(id: UUID, presetID: String, duration: Double? = nil) {
        guard let idx = transitions.firstIndex(where: { $0.id == id }) else { return }
        transitions[idx].presetID = presetID
        transitions[idx].type     = .crossFade
        if let dur = duration {
            let t = transitions[idx]
            guard let leadingSeg  = segment(id: t.leadingSegmentID),
                  let trailingSeg = segment(id: t.trailingSegmentID) else { return }
            let validMax = min(3.0, min(leadingSeg.targetRange.duration, trailingSeg.targetRange.duration))
            transitions[idx].duration = max(0.2, min(dur, validMax))
        }
    }

    // MARK: - Main track repack

    /// Remove transitions that reference segment pairs that are no longer adjacent
    /// (e.g. after reorder). Also clears back-references on the affected segments.
    public mutating func removeOrphanedTransitions(for segmentOrder: [UUID]) {
        // Build set of adjacent pairs from the current order.
        var adjacentPairs = Set<Pair>()
        for i in 0..<(segmentOrder.count - 1) {
            adjacentPairs.insert(Pair(segmentOrder[i], segmentOrder[i + 1]))
        }
        // Collect transition IDs to remove.
        let toRemove = transitions.filter { t in
            !adjacentPairs.contains(Pair(t.leadingSegmentID, t.trailingSegmentID))
        }
        for t in toRemove {
            updateSegment(id: t.leadingSegmentID)  { $0.trailingTransitionID = nil }
            updateSegment(id: t.trailingSegmentID) { $0.leadingTransitionID  = nil }
            transitions.removeAll { $0.id == t.id }
        }
    }

    /// Pack main-track segments end-to-end from t=0 with no gaps or overlaps.
    /// Used after delete/paste/split to keep the backbone contiguous.
    public mutating func repackMainTrack() {
        guard let ti = tracks.firstIndex(where: { $0.isMainTrack }) else { return }
        var cursor: Double = 0
        for i in tracks[ti].segments.indices {
            tracks[ti].segments[i].targetRange = TimeRange(
                start: cursor,
                duration: tracks[ti].segments[i].targetRange.duration
            )
            cursor += tracks[ti].segments[i].targetRange.duration
        }
    }
}

// MARK: - Helper

/// Unordered pair of Hashable values, used for adjacency checks.
private struct Pair: Hashable {
    let a: UUID
    let b: UUID
    init(_ a: UUID, _ b: UUID) { self.a = a; self.b = b }
}

// MARK: - Metadata

public struct EditorMetadata: Sendable, Hashable, Codable {
    public var sourceTaskID: Int?
    public var sourceWorkflow: String?
    public var productName: String?
    public var createdAt: Date
    public var renderType: String?

    /// V5 导出参数配置。nil 表示"未由用户主动设置"，读取时由
    /// `EditorTimeline.effectiveExportConfig` 按 canvas 派生默认。
    /// Codable 默认合成 `decodeIfPresent` 容错——旧草稿 JSON 不含此键时反序列化为 nil。
    public var exportConfig: ExportConfig?

    public init(
        sourceTaskID: Int? = nil,
        sourceWorkflow: String? = nil,
        productName: String? = nil,
        createdAt: Date = Date(),
        renderType: String? = nil,
        exportConfig: ExportConfig? = nil
    ) {
        self.sourceTaskID    = sourceTaskID
        self.sourceWorkflow  = sourceWorkflow
        self.productName     = productName
        self.createdAt       = createdAt
        self.renderType      = renderType
        self.exportConfig    = exportConfig
    }
}

// MARK: - V5 effective export config

extension EditorTimeline {

    /// V5：读取生效的导出配置。
    /// - `metadata.exportConfig` 非 nil（用户已主动设置）→ 返回该值
    /// - 否则按当前 `canvas` 派生默认（分辨率/帧率跟随画布；码率推荐；HDR 开）
    ///
    /// 派生计算属性挂在 `EditorTimeline` 而非 `EditorMetadata` 上，因为派生默认
    /// 需要 canvas 上下文；`EditorMetadata` 上不提供同名属性，避免误用走
    /// factoryDefault 兜底路径。
    public var effectiveExportConfig: ExportConfig {
        metadata.exportConfig ?? .default(for: canvas)
    }
}

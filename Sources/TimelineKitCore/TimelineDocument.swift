import Foundation
import Observation

// MARK: - TimelineDocument

/// Pure timeline data model with undo/redo mutation logic.
///
/// Lives in TimelineKitCore — no AVFoundation, no UIKit, no coordinator references.
/// EditorStore (umbrella) wraps this to add playback and coordination.
@MainActor @Observable
public final class TimelineDocument: Identifiable {
    public let id = UUID()
    public var timeline: EditorTimeline
    public var selection: SelectionState = SelectionState()

    /// Incremented by every mutation that affects AVComposition (video/audio changes).
    /// Subtitle/text-only mutations do NOT increment this, preventing unnecessary rebuilds (S-04).
    public private(set) var compositionVersion: Int = 0

    /// Bump composition version from outside (e.g. preview operations in EditorStore).
    public func bumpCompositionVersion() { compositionVersion += 1 }

    // MARK: - Undo

    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []

    public static let maxUndoDepth = 50

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var lastUndoLabel: String? { undoStack.last?.label }
    public var lastRedoLabel: String? { redoStack.last?.label }

    /// Called after `mutateSubtitle` completes (before undo push).
    /// EditorStore wires coordinator refresh through this hook.
    public var onDidMutateSubtitle: ((EditorTimeline) -> Void)?

    public init(timeline: EditorTimeline) {
        self.timeline = timeline
    }

    // MARK: - Mutation

    public func mutate(_ label: String, _ body: (inout EditorTimeline) -> Void) {
        let snapshot = timeline
        var t = timeline
        body(&t)
        timeline = t
        compositionVersion += 1
        undoStack.append(UndoEntry(label: label, snapshot: snapshot))
        if undoStack.count > Self.maxUndoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public func mutateSubtitle(_ label: String, _ body: (inout EditorTimeline) -> Void) {
        let snapshot = timeline
        var t = timeline
        body(&t)
        timeline = t
        onDidMutateSubtitle?(timeline)
        undoStack.append(UndoEntry(label: label, snapshot: snapshot))
        if undoStack.count > Self.maxUndoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    // MARK: - Undo / Redo

    public func undo() {
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(UndoEntry(label: entry.label, snapshot: timeline))
        timeline = entry.snapshot
        compositionVersion += 1
        clearStaleSelection()
    }

    public func redo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(UndoEntry(label: entry.label, snapshot: timeline))
        timeline = entry.snapshot
        compositionVersion += 1
        clearStaleSelection()
    }

    private func clearStaleSelection() {
        let allSegIDs  = Set(timeline.tracks.flatMap { $0.segments.map(\.id) })
        let allTransIDs = Set(timeline.transitions.map(\.id))
        selection.selectedSegmentIDs = selection.selectedSegmentIDs.intersection(allSegIDs)
        if let ctx = selection.editingTransitionContext,
           let existingTrans = ctx.existingTransition,
           !allTransIDs.contains(existingTrans.id) {
            selection.editingTransitionContext = nil
        }
    }

    // MARK: - Common Operations

    public func deleteSegment(id: UUID) {
        let isOnMainTrack = timeline.mainTrack?.segment(id: id) != nil
        let hostTrackID: UUID? = timeline.tracks.first(where: { t in
            !t.isMainTrack && t.segments.contains(where: { $0.id == id })
        })?.id

        mutate("删除片段") { tl in
            tl.removeSegment(id: id)
            if isOnMainTrack { tl.repackMainTrack() }
            if let hostID = hostTrackID,
               let host = tl.track(id: hostID),
               !host.isMainTrack, !host.pendingUserCreated, host.segments.isEmpty {
                tl.tracks.removeAll { $0.id == hostID }
            }
        }
        if let hostID = hostTrackID, timeline.track(id: hostID) == nil {
            cancelPendingCleanup(for: hostID)
        }
    }

    @discardableResult
    public func splitSegment(id: UUID, at time: Double) -> UUID? {
        let minDur: Double = 0.2
        guard let seg = timeline.segment(id: id),
              let trackIdx = timeline.tracks.firstIndex(where: { $0.segments.contains(where: { $0.id == id }) }),
              seg.targetRange.duration >= minDur * 2
        else { return nil }

        let clampedTime = Swift.min(Swift.max(time, seg.targetRange.start + minDur),
                                     seg.targetRange.end - minDur)
        let leftDur = clampedTime - seg.targetRange.start
        let rightDur = seg.targetRange.end - clampedTime
        let newTargetLeft  = TimeRange(start: seg.targetRange.start, duration: leftDur)
        let newTargetRight = TimeRange(start: clampedTime, duration: rightDur)
        let splitOffset = leftDur
        var newSourceLeft:  TimeRange? = seg.sourceRange
        var newSourceRight: TimeRange? = nil
        if let src = seg.sourceRange {
            newSourceLeft  = TimeRange(start: src.start, duration: leftDur)
            newSourceRight = TimeRange(start: src.start + splitOffset, duration: rightDur)
        }
        let rightID = UUID()
        mutate("分割片段") { tl in
            guard let si = tl.tracks[trackIdx].segments.firstIndex(where: { $0.id == id }) else { return }
            tl.tracks[trackIdx].segments[si].targetRange = newTargetLeft
            tl.tracks[trackIdx].segments[si].sourceRange = newSourceLeft
            let rightSeg = EditorSegment(
                id: rightID, materialID: seg.materialID,
                sourceRange: newSourceRight, targetRange: newTargetRight,
                speed: seg.speed, transform: seg.transform, blendMode: seg.blendMode,
                content: seg.content, adjustment: seg.adjustment
            )
            tl.tracks[trackIdx].segments.insert(rightSeg, at: si + 1)
        }
        return rightID
    }

    @ObservationIgnored private var clipBoardSegment: EditorSegment?

    public func copySegment(id: UUID) { clipBoardSegment = timeline.segment(id: id) }

    public func pasteSegment(after anchorID: UUID? = nil) {
        guard let copied = clipBoardSegment else { return }
        let trackID: UUID
        let insertStart: Double
        if let anchorID,
           let anchorTrack = timeline.tracks.first(where: { $0.segments.contains(where: { $0.id == anchorID }) }),
           let anchorSeg = anchorTrack.segments.first(where: { $0.id == anchorID }) {
            trackID = anchorTrack.id; insertStart = anchorSeg.targetRange.end
        } else if let main = timeline.mainTrack {
            trackID = main.id; insertStart = main.segments.last?.targetRange.end ?? 0
        } else if let first = timeline.tracks.first {
            trackID = first.id; insertStart = 0
        } else { return }
        let newSeg = EditorSegment(
            id: UUID(), materialID: copied.materialID,
            sourceRange: copied.sourceRange,
            targetRange: TimeRange(start: insertStart, duration: copied.targetRange.duration),
            speed: copied.speed, transform: copied.transform, blendMode: copied.blendMode,
            content: copied.content, adjustment: copied.adjustment
        )
        mutate("粘贴片段") { tl in
            guard let ti = tl.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            tl.tracks[ti].segments.append(newSeg)
            tl.tracks[ti].segments.sort { $0.targetRange.start < $1.targetRange.start }
            if tl.tracks[ti].isMainTrack { tl.repackMainTrack() }
        }
    }

    public var hasClipboardSegment: Bool { clipBoardSegment != nil }

    public func trimSegment(id: UUID, newTargetRange: TimeRange, newSourceRangeStart: Double? = nil) {
        if timeline.mainTrack?.segment(id: id) != nil {
            mutate("裁剪片段") { tl in
                guard let ti = tl.tracks.firstIndex(where: { $0.isMainTrack }),
                      let si = tl.tracks[ti].segments.firstIndex(where: { $0.id == id }) else { return }
                let oldStart = tl.tracks[ti].segments[si].targetRange.start
                let oldEnd = tl.tracks[ti].segments[si].targetRange.end
                var finalRange = newTargetRange
                if newTargetRange.start < oldStart - 0.001 {
                    finalRange = TimeRange(start: oldStart, duration: newTargetRange.duration)
                } else if newTargetRange.start > oldStart + 0.001 {
                    finalRange = TimeRange(start: oldStart, duration: newTargetRange.duration)
                }
                tl.tracks[ti].segments[si].targetRange = finalRange
                if let newStart = newSourceRangeStart, var sr = tl.tracks[ti].segments[si].sourceRange {
                    sr.start = newStart; tl.tracks[ti].segments[si].sourceRange = sr
                }
                let growthDelta = finalRange.end - oldEnd
                if abs(growthDelta) > 0.001 {
                    for i in (si + 1) ..< tl.tracks[ti].segments.count {
                        let s = tl.tracks[ti].segments[i]
                        tl.tracks[ti].segments[i].targetRange =
                            TimeRange(start: s.targetRange.start + growthDelta, duration: s.targetRange.duration)
                    }
                }
            }
        } else if let seg = timeline.segment(id: id), seg.isAudio {
            mutate("裁剪片段") { tl in
                tl.updateSegment(id: id) { seg in
                    seg.targetRange = newTargetRange
                    if let newStart = newSourceRangeStart, var sr = seg.sourceRange {
                        sr.start = newStart; seg.sourceRange = sr
                    }
                }
            }
        } else {
            mutateSubtitle("裁剪片段") { tl in
                tl.updateSegment(id: id) { seg in
                    seg.targetRange = newTargetRange
                    if let newStart = newSourceRangeStart, var sr = seg.sourceRange {
                        sr.start = newStart; seg.sourceRange = sr
                    }
                }
            }
        }
    }

    public func moveSegment(id: UUID, to newStart: Double) {
        mutate("移动片段") { tl in
            tl.updateSegment(id: id) { seg in
                seg.targetRange = TimeRange(start: newStart, duration: seg.targetRange.duration)
            }
        }
    }

    public func reorderSegments(trackID: UUID, newOrder: [UUID]) {
        mutate("重排片段") { tl in
            var needsTransitionCleanup: [UUID]?
            tl.updateTrack(id: trackID) { track in
                let segMap = Dictionary(uniqueKeysWithValues: track.segments.map { ($0.id, $0) })
                let ordered = newOrder.compactMap { segMap[$0] }
                if track.isMainTrack {
                    var cursor = 0.0
                    track.segments = ordered.map { seg in
                        var s = seg
                        s.targetRange = TimeRange(start: cursor, duration: seg.targetRange.duration)
                        cursor += seg.targetRange.duration
                        return s
                    }
                    needsTransitionCleanup = ordered.map { $0.id }
                } else {
                    let slotStarts = track.segments.sorted { $0.targetRange.start < $1.targetRange.start }.map { $0.targetRange.start }
                    track.segments = zip(ordered, slotStarts).map { seg, start in
                        var s = seg; s.targetRange = TimeRange(start: start, duration: seg.targetRange.duration); return s
                    }
                }
            }
            if let order = needsTransitionCleanup { tl.removeOrphanedTransitions(for: order) }
        }
    }

    // MARK: - Text/Subtitle Mutations

    public func mutateTextContent(segmentID: UUID, label: String = "编辑文字", _ modify: (inout SegmentContent.TextContent) -> Void) {
        mutateSubtitle(label) { tl in
            tl.updateSegment(id: segmentID) { seg in
                guard case .text(var c) = seg.content else { return }
                modify(&c); seg.content = .text(c)
            }
        }
    }

    public func mutateTextStyle(segmentID: UUID, label: String = "修改样式", _ modify: (inout TextStyle) -> Void) {
        mutateTextContent(segmentID: segmentID, label: label) { modify(&$0.style) }
    }

    public func updateTextContent(segmentID: UUID, text: String) {
        mutateTextContent(segmentID: segmentID) { $0.text = text }
    }

    public func updateTextPosition(segmentID: UUID, position: NormalizedPoint) {
        mutateTextContent(segmentID: segmentID, label: "移动文字") { $0.position = position }
    }

    public func updateSubtitlePosition(segmentID: UUID, positionY: Double) {
        mutateSubtitleContent(segmentID: segmentID, label: "移动字幕") { $0.positionY = positionY.clamped(to: 0...1) }
    }

    public func updateTextStyle(segmentID: UUID, style: TextStyle) {
        mutateTextStyle(segmentID: segmentID) { $0 = style }
    }

    public func mutateSubtitleContent(segmentID: UUID, label: String = "编辑字幕", _ modify: (inout SegmentContent.SubtitleContent) -> Void) {
        mutateSubtitle(label) { tl in
            tl.updateSegment(id: segmentID) { seg in
                guard case .subtitle(var c) = seg.content else { return }
                modify(&c); seg.content = .subtitle(c)
            }
        }
    }

    public func mutateSubtitleStyle(segmentID: UUID, label: String = "修改字幕样式", _ modify: (inout TextStyle) -> Void) {
        mutateSubtitleContent(segmentID: segmentID, label: label) { modify(&$0.style) }
    }

    // MARK: - Style Operations

    public struct StylePreset: Sendable, Hashable {
        public let color: String; public let shadowColor: String?
        public init(color: String, shadowColor: String?) { self.color = color; self.shadowColor = shadowColor }
    }

    public func applyStylePreset(segmentID: UUID, preset: StylePreset?) {
        let applyToStyle: (inout TextStyle) -> Void = { style in
            if let preset {
                style.color = preset.color
                if let shadowHex = preset.shadowColor, !Self.isFullyTransparent(hex: shadowHex) {
                    style.shadowColor = shadowHex; style.shadowOffsetX = 1; style.shadowOffsetY = 1; style.shadowRadius = 2
                } else {
                    style.shadowColor = nil; style.shadowOffsetX = 0; style.shadowOffsetY = 0; style.shadowRadius = 0
                }
            } else {
                style.color = "#FFFFFF"; style.shadowColor = nil; style.shadowOffsetX = 0; style.shadowOffsetY = 0; style.shadowRadius = 0
            }
        }
        guard let seg = timeline.segment(id: segmentID) else { return }
        if seg.isSubtitle {
            mutateSubtitleStyle(segmentID: segmentID, label: "应用预设样式", applyToStyle)
        } else if seg.isText {
            mutateTextStyle(segmentID: segmentID, label: "应用预设样式", applyToStyle)
        }
    }

    private static func isFullyTransparent(hex: String) -> Bool {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 8 else { return false }
        return trimmed.suffix(2).uppercased() == "00"
    }

    @discardableResult
    public func applyStyleToTrackSegmentsOfKind(trackID: UUID, sourceSegmentID: UUID, includePositionFields: Bool = false) -> Int {
        guard let track = timeline.tracks.first(where: { $0.id == trackID }), !track.isLocked,
              let source = track.segments.first(where: { $0.id == sourceSegmentID }) else { return 0 }
        let sourceIsSubtitle: Bool
        switch source.content { case .subtitle: sourceIsSubtitle = true; case .text: sourceIsSubtitle = false; default: return 0 }
        let sourceStyle: TextStyle; let sourcePositionY: Double?; let sourceMaxChars: Int?
        switch source.content {
        case .subtitle(let c): sourceStyle = c.style; sourcePositionY = c.positionY; sourceMaxChars = c.maxCharsPerLine
        case .text(let c): sourceStyle = c.style; sourcePositionY = nil; sourceMaxChars = nil
        default: return 0
        }
        var mutatedCount = 0
        let body: (inout EditorTimeline) -> Void = { tl in
            guard let trackIdx = tl.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            for i in tl.tracks[trackIdx].segments.indices {
                let segID = tl.tracks[trackIdx].segments[i].id; guard segID != sourceSegmentID else { continue }
                switch tl.tracks[trackIdx].segments[i].content {
                case .subtitle(var c) where sourceIsSubtitle:
                    c.style = sourceStyle; if includePositionFields { if let py = sourcePositionY { c.positionY = py }; if let mc = sourceMaxChars { c.maxCharsPerLine = mc } }
                    tl.tracks[trackIdx].segments[i].content = .subtitle(c); mutatedCount += 1
                case .text(var c) where !sourceIsSubtitle:
                    c.style = sourceStyle; tl.tracks[trackIdx].segments[i].content = .text(c); mutatedCount += 1
                default: continue
                }
            }
        }
        mutateSubtitle("应用到本轨同类", body)
        return mutatedCount
    }

    public func setTextAlignment(segmentID: UUID, alignment: TextAlignment) {
        guard let seg = timeline.segment(id: segmentID) else { return }
        if seg.isSubtitle { mutateSubtitleStyle(segmentID: segmentID, label: "文本对齐") { $0.alignment = alignment } }
        else if seg.isText { mutateTextStyle(segmentID: segmentID, label: "文本对齐") { $0.alignment = alignment } }
    }

    // MARK: - Style Clipboard

    private struct StyleClipboard { let style: TextStyle; let sourceKind: SegmentKind; enum SegmentKind: Sendable { case subtitle, text } }
    private var styleClipboard: StyleClipboard?

    public func copyStyle(segmentID: UUID) {
        guard let seg = timeline.segment(id: segmentID) else { return }
        switch seg.content {
        case .subtitle(let c): styleClipboard = StyleClipboard(style: c.style, sourceKind: .subtitle)
        case .text(let c): styleClipboard = StyleClipboard(style: c.style, sourceKind: .text)
        default: return
        }
    }

    public func canPasteStyle(toSegmentID segmentID: UUID) -> Bool {
        guard let cb = styleClipboard, let seg = timeline.segment(id: segmentID) else { return false }
        switch (cb.sourceKind, seg.content) { case (.subtitle, .subtitle): return true; case (.text, .text): return true; default: return false }
    }

    public func pasteStyle(segmentID: UUID) {
        guard canPasteStyle(toSegmentID: segmentID), let cb = styleClipboard else { return }
        if timeline.segment(id: segmentID)?.isSubtitle == true {
            mutateSubtitleStyle(segmentID: segmentID, label: "粘贴样式") { $0 = cb.style }
        } else {
            mutateTextStyle(segmentID: segmentID, label: "粘贴样式") { $0 = cb.style }
        }
    }

    // MARK: - Z-Order

    public func bringSegmentToFront(segmentID: UUID) { setUserZOrder(segmentID: segmentID, strategy: .toFront) }
    public func sendSegmentToBack(segmentID: UUID) { setUserZOrder(segmentID: segmentID, strategy: .toBack) }
    public func bringSegmentForward(segmentID: UUID) { setUserZOrder(segmentID: segmentID, strategy: .forward) }
    public func sendSegmentBackward(segmentID: UUID) { setUserZOrder(segmentID: segmentID, strategy: .backward) }

    private enum ZOrderStrategy { case toFront, toBack, forward, backward }

    private func setUserZOrder(segmentID: UUID, strategy: ZOrderStrategy) {
        guard let seg = timeline.segment(id: segmentID), seg.isSubtitle || seg.isText else { return }
        let overlapping: [EditorSegment] = timeline.tracks
            .filter { $0.kind == .subtitle || $0.kind == .text }
            .flatMap { $0.segments }
            .filter { $0.id != segmentID && $0.targetRange.overlaps(seg.targetRange) }
            .filter { ($0.isSubtitle && seg.isSubtitle) || ($0.isText && seg.isText) }
        let currentZ = seg.userZOrder ?? 0; let othersZ = overlapping.map { $0.userZOrder ?? 0 }
        let newZ: Int
        switch strategy {
        case .toFront: newZ = (othersZ.max() ?? 0) + 1
        case .toBack: newZ = (othersZ.min() ?? 0) - 1
        case .forward: let higher = othersZ.filter { $0 > currentZ }.sorted(); newZ = higher.first ?? (currentZ + 1)
        case .backward: let lower = othersZ.filter { $0 < currentZ }.sorted(by: >); newZ = lower.first ?? (currentZ - 1)
        }
        mutateSubtitle("调整层级") { tl in tl.updateSegment(id: segmentID) { $0.userZOrder = newZ } }
    }

    // MARK: - Track Management

    @discardableResult
    public func addTrack(kind: EditorTrack.Kind, label: String = "", zPosition: Int? = nil, pendingUserCreated: Bool = false) -> UUID? {
        guard kind != .video else { return nil }
        let existing = timeline.tracks(ofKind: kind)
        let resolvedZ: Int = zPosition ?? (existing.isEmpty ? Self.defaultZPosition(for: kind) : (existing.map(\.zPosition).max() ?? 0) + 1)
        let resolvedLabel = label.isEmpty ? "\(Self.displayName(for: kind)) \(existing.count + 1)" : label
        let newID = UUID()
        let newTrack = EditorTrack(id: newID, kind: kind, label: resolvedLabel, zPosition: resolvedZ, segments: [], isMainTrack: false, pendingUserCreated: pendingUserCreated)
        let body: (inout EditorTimeline) -> Void = { tl in tl.tracks.append(newTrack) }
        switch kind { case .text, .subtitle: mutateSubtitle("新建轨道", body); default: mutate("新建轨道", body) }
        if pendingUserCreated { schedulePendingCleanup(for: newID) }
        return newID
    }

    public func addSegment(toTrack trackID: UUID, segment: EditorSegment) {
        guard timeline.track(id: trackID) != nil else { return }
        let body: (inout EditorTimeline) -> Void = { tl in
            guard let ti = tl.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            tl.tracks[ti].insert(segment); if tl.tracks[ti].pendingUserCreated { tl.tracks[ti].pendingUserCreated = false }
        }
        if Self.segmentTriggersRebuild(segment) { mutate("添加片段", body) } else { mutateSubtitle("添加片段", body) }
        cancelPendingCleanup(for: trackID)
    }

    @discardableResult
    public func addSegmentAutoTrack(kind: EditorTrack.Kind, segment: EditorSegment) -> UUID? {
        guard kind != .video else { return nil }
        let candidates = timeline.tracks(ofKind: kind).sorted { ($0.zPosition, $0.id.uuidString) < ($1.zPosition, $1.id.uuidString) }
        if let reusable = candidates.first(where: { !$0.segments.contains { $0.targetRange.overlaps(segment.targetRange) } }) {
            addSegment(toTrack: reusable.id, segment: segment); return reusable.id
        }
        let existing = timeline.tracks(ofKind: kind)
        let resolvedZ = existing.isEmpty ? Self.defaultZPosition(for: kind) : (existing.map(\.zPosition).max() ?? 0) + 1
        let resolvedLabel = "\(Self.displayName(for: kind)) \(existing.count + 1)"
        let newID = UUID()
        let newTrack = EditorTrack(id: newID, kind: kind, label: resolvedLabel, zPosition: resolvedZ, segments: [segment], isMainTrack: false)
        let body: (inout EditorTimeline) -> Void = { tl in tl.tracks.append(newTrack) }
        if Self.segmentTriggersRebuild(segment) { mutate("添加片段", body) } else { mutateSubtitle("添加片段", body) }
        return newID
    }

    public func removeTrackIfEmpty(id: UUID) {
        guard let track = timeline.track(id: id), !track.isMainTrack, track.segments.isEmpty else { return }
        let body: (inout EditorTimeline) -> Void = { tl in tl.tracks.removeAll { $0.id == id } }
        switch track.kind { case .text, .subtitle: mutateSubtitle("删除空轨", body); default: mutate("删除空轨", body) }
        cancelPendingCleanup(for: id)
    }

    // Selection helpers that use timeline state
    public func clearSelectionForRemovedTrack(id: UUID) {
        if selection.focusedTrackID == id { selection.focusedTrackID = nil }
    }

    // MARK: - Helpers

    public static func defaultZPosition(for kind: EditorTrack.Kind) -> Int {
        switch kind { case .video: 0; case .overlay: -1; case .audio: 0; case .subtitle: 5; case .text: 10; case .adjustment: 0 }
    }

    public static func displayName(for kind: EditorTrack.Kind) -> String {
        switch kind { case .video: "视频"; case .overlay: "叠加"; case .text: "文字"; case .subtitle: "字幕"; case .audio: "音频"; case .adjustment: "调节" }
    }

    public static func segmentTriggersRebuild(_ segment: EditorSegment) -> Bool {
        switch segment.content { case .video, .image, .audio: return true; case .text, .subtitle: return false }
    }

    // MARK: - Pending Cleanup

    @ObservationIgnored private var pendingCleanupTasks: [UUID: Task<Void, Never>] = [:]
    private static let pendingTrackLifetimeNS: UInt64 = 30_000_000_000

    public func schedulePendingCleanup(for trackID: UUID) {
        pendingCleanupTasks[trackID]?.cancel()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pendingTrackLifetimeNS)
            guard let self, !Task.isCancelled else { return }
            if let track = self.timeline.track(id: trackID), track.pendingUserCreated, track.segments.isEmpty, !track.isMainTrack {
                self.removeTrackIfEmpty(id: trackID)
            }
            self.pendingCleanupTasks[trackID] = nil
        }
        pendingCleanupTasks[trackID] = task
    }

    public func cancelPendingCleanup(for trackID: UUID) {
        pendingCleanupTasks[trackID]?.cancel(); pendingCleanupTasks[trackID] = nil
    }

    // MARK: - Preview / Commit Methods

    public func previewTrimRange(segmentID: UUID, range: TimeRange) {
        timeline.updateSegment(id: segmentID) { $0.targetRange = range }
    }

    public func previewAdjustment(segmentID: UUID, adjustment: SegmentAdjustment) {
        timeline.updateSegment(id: segmentID) { $0.adjustment = adjustment }; compositionVersion += 1
    }

    public func setAdjustment(segmentID: UUID, adjustment: SegmentAdjustment) {
        mutate("调色") { tl in tl.updateSegment(id: segmentID) { $0.adjustment = adjustment } }
    }

    public func resetAdjustment(segmentID: UUID) {
        mutate("重置调色") { tl in tl.updateSegment(id: segmentID) { $0.adjustment = .identity } }
    }

    public func previewClipAnimation(segmentID: UUID, animation: ClipAnimation) {
        timeline.updateSegment(id: segmentID) { $0.setAnimation(animation) }; compositionVersion += 1
    }

    public func setClipAnimation(segmentID: UUID, animation: ClipAnimation) {
        mutate("设置动画") { tl in tl.updateSegment(id: segmentID) { $0.setAnimation(animation) } }
    }

    public func removeClipAnimation(segmentID: UUID, timing: AnimationTiming) {
        mutate("移除动画") { tl in tl.updateSegment(id: segmentID) { $0.removeAnimation(timing: timing) } }
    }

    // MARK: - Transitions

    @discardableResult
    public func addTransition(between leadingID: UUID, and trailingID: UUID, type: EditorTransition.TransitionType = .fade, duration: Double = 0.5) -> EditorTransition? {
        var result: EditorTransition?
        mutate("添加转场") { tl in result = tl.addTransition(between: leadingID, and: trailingID, type: type, duration: duration) }
        return result
    }

    @discardableResult
    public func addTransition(between leadingID: UUID, and trailingID: UUID, presetID: String, duration: Double = 0.5) -> EditorTransition? {
        var result: EditorTransition?
        mutate("添加转场") { tl in result = tl.addTransition(between: leadingID, and: trailingID, presetID: presetID, duration: duration) }
        return result
    }

    public func removeTransition(id: UUID) { mutate("删除转场") { tl in tl.removeTransition(id: id) } }
    public func updateTransitionDuration(id: UUID, duration: Double) { mutate("调整转场时长") { tl in tl.updateTransitionDuration(id: id, duration: duration) } }
    public func updateTransitionType(id: UUID, type: EditorTransition.TransitionType) { mutate("切换转场类型") { tl in tl.updateTransitionType(id: id, type: type) } }
    public func updateTransitionPreset(id: UUID, presetID: String, duration: Double? = nil) { mutate("切换转场") { tl in tl.updateTransitionPreset(id: id, presetID: presetID, duration: duration) } }

    // MARK: - Track Lock/Hide

    public func setTrackLocked(id: UUID, isLocked: Bool) { mutate(isLocked ? "锁定轨道" : "解锁轨道") { tl in tl.updateTrack(id: id) { $0.isLocked = isLocked } } }

    public func setTrackHidden(id: UUID, isHidden: Bool) {
        guard let track = timeline.track(id: id), !track.isMainTrack else { return }
        mutate(isHidden ? "隐藏轨道" : "显示轨道") { tl in tl.updateTrack(id: id) { $0.isHidden = isHidden } }
    }

    // MARK: - Audio Mutations (Core — not coordinator-dependent)

    public func muteTrack(id: UUID, isMuted: Bool) { mutate(isMuted ? "静音轨道" : "取消静音") { tl in tl.updateTrack(id: id) { $0.isMuted = isMuted } } }

    public func setAudioVolume(segmentID: UUID, volume: Double) {
        mutate("调整音量") { tl in tl.updateSegment(id: segmentID) { seg in
            guard case .audio(var c) = seg.content else { return }; c.volume = max(0, min(volume, 2.0)); seg.content = .audio(c)
        } }
    }

    public func mutateAudioFade(segmentID: UUID, fadeIn: Double, fadeOut: Double) {
        mutate("调整淡化") { tl in tl.updateSegment(id: segmentID) { seg in
            guard case .audio(var c) = seg.content else { return }
            let halfMax = seg.targetRange.duration / 2
            c.fadeInDuration = max(0, min(fadeIn, halfMax)); c.fadeOutDuration = max(0, min(fadeOut, seg.targetRange.duration - c.fadeInDuration))
            seg.content = .audio(c)
        } }
    }

    public func muteAudioSegment(id: UUID, isMuted: Bool) {
        mutate(isMuted ? "静音片段" : "取消静音") { tl in tl.updateSegment(id: id) { seg in
            guard case .audio(var c) = seg.content else { return }; c.isMuted = isMuted; seg.content = .audio(c)
        } }
    }

    public func setVideoMuted(segmentID: UUID, isMuted: Bool) {
        mutate(isMuted ? "静音原音" : "恢复原音") { tl in tl.updateSegment(id: segmentID) { seg in
            guard case .video(var c) = seg.content else { return }; c.isMuted = isMuted; seg.content = .video(c)
        } }
    }

    public func applyImageAnimation(segmentID: UUID, preset: ImageAnimationPreset) {
        guard let seg = timeline.segment(id: segmentID), case .image = seg.content else { return }
        let kf = ImageAnimationPresetRegistry.keyframes(for: preset, duration: seg.targetRange.duration)
        mutate("应用动画") { tl in tl.updateSegment(id: segmentID) { seg in
            guard case .image(var c) = seg.content else { return }
            c.keyframes = kf; c.animationPresetID = kf == nil ? nil : preset.rawValue; seg.content = .image(c)
        } }
    }

    public func setAudioSpeed(segmentID: UUID, speed: Double) {
        let newSpeed = min(max(speed, Self.audioSpeedRange.lowerBound), Self.audioSpeedRange.upperBound)
        mutate("调整音频速度") { tl in tl.updateSegment(id: segmentID) { seg in
            guard case .audio = seg.content else { return }
            let oldSpeed = max(seg.speed, 0.001); let sourceDur = max(seg.targetRange.duration * oldSpeed, 0.05)
            seg.speed = newSpeed; seg.targetRange = TimeRange(start: seg.targetRange.start, duration: max(sourceDur / newSpeed, 0.05))
        } }
    }

    public static let audioSpeedRange: ClosedRange<Double> = 0.3 ... 3.0

    // MARK: - Material Replacement

    public func replaceSegmentMaterial(segmentID: UUID, localURL: URL, nativeDuration: Double?, clipInTime: Double? = nil) {
        mutate("替换素材") { tl in
            guard var seg = tl.segment(id: segmentID) else { return }
            let isIncomingVideo = nativeDuration != nil
            var asset = tl.materials[seg.materialID] ?? EditorAsset(id: seg.materialID, type: .image)
            asset.localURL = localURL; asset.remoteURL = nil; asset.nativeDuration = nativeDuration; asset.type = isIncomingVideo ? .video : .image
            tl.materials[seg.materialID] = asset
            switch (seg.content, isIncomingVideo) {
            case (.image, true): seg.content = .video(SegmentContent.VideoContent()); seg.sourceRange = nil
            case (.video, false): seg.content = .image(SegmentContent.ImageContent()); seg.sourceRange = nil
            default: break
            }
            if let clipIn = clipInTime, isIncomingVideo { seg.sourceRange = TimeRange(start: clipIn, duration: seg.targetRange.duration) }
            tl.updateSegment(id: segmentID) { $0 = seg }
        }
    }

    // MARK: - Export Config

    public func mutateExportConfig(_ body: (inout ExportConfig) -> Void) {
        var cfg = timeline.effectiveExportConfig; body(&cfg)
        var t = timeline; t.metadata.exportConfig = cfg; timeline = t
    }

    public func resetExportConfigToDefault() {
        var t = timeline; t.metadata.exportConfig = nil; timeline = t
    }

    // MARK: - Subtitle preview (live, no undo)

    public func previewSubtitlePosition(segmentID: UUID, positionY: Double) {
        timeline.updateSegment(id: segmentID) { seg in
            guard case .subtitle(var c) = seg.content else { return }; c.positionY = positionY.clamped(to: 0...1); seg.content = .subtitle(c)
        }
    }

    // MARK: - Types

    private struct UndoEntry { let label: String; let snapshot: EditorTimeline }
}

// MARK: - SelectionState

public struct SelectionState: Sendable {
    public var selectedSegmentIDs: Set<UUID> = []
    public var focusedTrackID: UUID?
    public var playheadTime: Double = 0
    public var editingSegmentID: UUID?
    public var editingTransitionContext: TransitionEditContext?

    public var hasSingleSelection: Bool { selectedSegmentIDs.count == 1 }
    public var singleSelectedID: UUID? { hasSingleSelection ? selectedSegmentIDs.first : nil }

    public mutating func selectOnly(_ id: UUID) { selectedSegmentIDs = [id]; editingSegmentID = id }
    public mutating func deselect() { selectedSegmentIDs.removeAll(); editingSegmentID = nil }
}

// MARK: - TransitionEditContext

public struct TransitionEditContext: Sendable, Equatable {
    public let leadingID: UUID; public let trailingID: UUID; public let existingTransition: EditorTransition?
    public init(leadingID: UUID, trailingID: UUID, existingTransition: EditorTransition?) {
        self.leadingID = leadingID; self.trailingID = trailingID; self.existingTransition = existingTransition
    }
}

// MARK: - SegmentContent helper

extension SegmentContent {
    var textContent: TextContent? { if case .text(let c) = self { return c }; return nil }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

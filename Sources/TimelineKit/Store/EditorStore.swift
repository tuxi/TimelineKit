import Foundation
import Observation
import AVFoundation
import CoreMedia

/// Observable store that owns the EditorTimeline and manages undo/redo.
///
/// All mutations go through `mutate(_:_:)` to guarantee undo stack correctness.
/// The timeline itself is a value type — each undo snapshot is a cheap struct copy.
@MainActor @Observable
public final class EditorStore: Identifiable {
    public let id = UUID()
    public private(set) var timeline: EditorTimeline
    public var selection: SelectionState = SelectionState()

    // MARK: - Player

    /// Simple URL-based player created by setupPlayer(_:) — used as fallback.
    @ObservationIgnored nonisolated(unsafe) public private(set) var player: AVPlayer?
    /// Composition player owned by CompositionCoordinator — wins over `player` when set.
    @ObservationIgnored nonisolated(unsafe) var coordinatorPlayer: AVPlayer?

    /// Internal(set) so CompositionCoordinator can set it to false on playback end.
    public internal(set) var isPlaying: Bool = false

    /// V6 P3: set by CompositionCoordinator when TimelineRuntime is active.
    /// When true, EditorPreviewView overlays a TimelinePreviewView driven by the
    /// TimelineRenderer + TimelineClock engine, bypassing AVVideoCompositing.
    public internal(set) var usesTimelineRuntime: Bool = false

    /// Incremented by every mutation that affects AVComposition (video/audio changes).
    /// Subtitle/text-only mutations do NOT increment this, preventing unnecessary rebuilds (S-04).
    public private(set) var compositionVersion: Int = 0

    /// Weak reference set by ClipEditorView so audio-only mutations can bypass full rebuild.
    @ObservationIgnored nonisolated(unsafe) public weak var coordinator: CompositionCoordinator?

    @ObservationIgnored nonisolated(unsafe) private var playerTimeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var playerEndObserver: Any?

    /// v3: per-track 30-second auto-recycle tasks for `pendingUserCreated` tracks.
    /// Created when `addTrack(pendingUserCreated: true)` runs; cancelled as soon
    /// as the user drops a segment in (then the flag is cleared) or the track is
    /// removed by other means.
    @ObservationIgnored private var pendingCleanupTasks: [UUID: Task<Void, Never>] = [:]

    /// The player currently driving playback.
    private var activePlayer: AVPlayer? { coordinatorPlayer ?? player }

    // MARK: - V4 Style Clipboard (text-typography-spec §4)

    private struct StyleClipboard {
        let style: TextStyle
        let sourceKind: SegmentKind
        enum SegmentKind: Sendable { case subtitle, text }
    }

    private var styleClipboard: StyleClipboard?

    // MARK: - Undo

    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []

    public static let maxUndoDepth = 50

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var lastUndoLabel: String? { undoStack.last?.label }
    public var lastRedoLabel: String? { redoStack.last?.label }

    public init(timeline: EditorTimeline, videoURL: URL? = nil) {
        self.timeline = timeline
        if let url = videoURL {
            setupPlayer(url: url)
        }
    }

    deinit {
        // nonisolated deinit — AVPlayer/removeTimeObserver are thread-safe here
        // because no other code can hold a strong reference at this point.
        if let obs = playerTimeObserver { player?.removeTimeObserver(obs) }
        if let obs = playerEndObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Playback API

    public func togglePlayback() {
#if DEBUG
        let p = activePlayer
        print("[EditorPlayback] toggle requested storeIsPlaying=\(isPlaying) playerRate=\(p?.rate ?? -999) currentTime=\(formatDebugTime(p?.currentTime())) duration=\(formatDebugSeconds(timeline.duration)) usesRuntime=\(usesTimelineRuntime)")
#endif
        if isPlaying { pause() } else { play() }
    }

    public func play() {
        guard let p = activePlayer else { return }
#if DEBUG
        print("[EditorPlayback] play begin storeIsPlaying=\(isPlaying) playerRate=\(p.rate) currentTime=\(formatDebugTime(p.currentTime())) duration=\(formatDebugSeconds(timeline.duration)) usesRuntime=\(usesTimelineRuntime)")
#endif
        coordinator?.setTimelineRuntimePlaybackActive(true)
        if p.currentTime().seconds >= timeline.duration - 0.05 {
            coordinator?.prepareTimelineRuntimeForSeek(to: .zero)
            p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            // V6 P2 Fix: flush display layer + render frame 0 before replay.
            // Without this AVSampleBufferDisplayLayer stays in drained/ended state
            // after the first playback and ignores newly enqueued frames.
            DispatchQueue.main.async {
                self.coordinator?.renderFrameAndFlush()
            }
        }
        p.play()
        isPlaying = true
#if DEBUG
        print("[EditorPlayback] play end storeIsPlaying=\(isPlaying) playerRate=\(p.rate) currentTime=\(formatDebugTime(p.currentTime())) usesRuntime=\(usesTimelineRuntime)")
#endif
    }

    public func pause() {
#if DEBUG
        let p = activePlayer
        print("[EditorPlayback] pause storeIsPlaying=\(isPlaying) playerRate=\(p?.rate ?? -999) currentTime=\(formatDebugTime(p?.currentTime())) usesRuntime=\(usesTimelineRuntime)")
#endif
        activePlayer?.pause()
        isPlaying = false
        coordinator?.setTimelineRuntimePlaybackActive(false)
    }

    public func seek(to time: Double) {
        let clamped = max(0, min(time, timeline.duration))
        let cmTime  = CMTime(seconds: clamped, preferredTimescale: 600)
#if DEBUG
        let p = activePlayer
        print("[EditorPlayback] seek requested target=\(formatDebugSeconds(clamped)) storeIsPlaying=\(isPlaying) playerRate=\(p?.rate ?? -999) currentTime=\(formatDebugTime(p?.currentTime())) usesRuntime=\(usesTimelineRuntime)")
#endif
        coordinator?.setTimelineRuntimePlaybackActive(isPlaying)
        coordinator?.prepareTimelineRuntimeForSeek(to: cmTime)
        activePlayer?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.coordinator?.renderFrameAndFlush()
            }
        }
        selection.playheadTime = clamped
    }

#if DEBUG
    private func formatDebugTime(_ time: CMTime?) -> String {
        guard let time, time.isValid else { return "invalid" }
        return formatDebugSeconds(time.seconds)
    }

    private func formatDebugSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return String(describing: seconds) }
        return String(format: "%.4f", seconds)
    }
#endif

    // MARK: - Private

    private func setupPlayer(url: URL) {
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        self.player = p

        let interval = CMTime(value: 1, timescale: 30)
        playerTimeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.selection.playheadTime = time.seconds
            }
        }

        playerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
    }

    // MARK: - Mutation

    /// Perform a timeline mutation that can be undone.
    /// Increments compositionVersion → triggers AVComposition rebuild.
    /// Use for video/audio/structure changes.
    ///
    /// v4 fix (subtitle preview stale BUG): mutate a *local copy* and assign
    /// the result back, so the top-level `timeline` setter fires explicitly.
    /// `@Observable` does not reliably publish through deep inout chains
    /// (Array subscript → enum associated value → nested struct), so SwiftUI
    /// observation can miss the change. The explicit `timeline = t` guarantees
    /// EditorPreviewView / SubtitleStackView / TextOverlayView all see the new
    /// timeline on the next render pass.
    public func mutate(_ label: String, _ body: (inout EditorTimeline) -> Void) {
        let snapshot = timeline
        var t = timeline
        body(&t)
        timeline = t                    // explicit setter → @Observable publish
        compositionVersion += 1
        undoStack.append(UndoEntry(label: label, snapshot: snapshot))
        if undoStack.count > Self.maxUndoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Perform a subtitle/text-only mutation that can be undone.
    /// Does NOT increment compositionVersion — no AVComposition rebuild (spec S-04).
    ///
    /// v4 fix (subtitle preview stale BUG): see `mutate(_:_:)` for the
    /// rationale behind the copy + explicit assignment pattern. Before this
    /// fix, the in-place `body(&timeline)` path produced no SwiftUI
    /// invalidation for nested edits (e.g. a subtitle segment's
    /// `style.backgroundColor`), so the preview kept rendering the previous
    /// state even though TextEditPanel and the persisted draft already showed
    /// the new value — the "感觉好像存储了两份字幕一样" symptom.
    public func mutateSubtitle(_ label: String, _ body: (inout EditorTimeline) -> Void) {
        let snapshot = timeline
        var t = timeline
        body(&t)
        timeline = t                    // explicit setter → @Observable publish
        coordinator?.refreshTimelineRuntimeTextLayers(timeline: timeline)
        undoStack.append(UndoEntry(label: label, snapshot: snapshot))
        if undoStack.count > Self.maxUndoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    // MARK: - Undo / Redo

    public func undo() {
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(UndoEntry(label: entry.label, snapshot: timeline))
        timeline = entry.snapshot
        compositionVersion += 1   // conservative: may include composition-affecting changes
        clearStaleSelection()
    }

    public func redo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(UndoEntry(label: entry.label, snapshot: timeline))
        timeline = entry.snapshot
        compositionVersion += 1
        clearStaleSelection()
    }

    /// After undo/redo, drop any selection references that point to objects no longer in
    /// the timeline (e.g. a transition that was removed, or a segment that was deleted).
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

    // MARK: - Material Replacement (T7)

    /// Replace the source asset for a segment.
    /// - Updates the asset URL and duration in-place (materialID unchanged → no structural diff).
    /// - Switches the segment's content type when the media kind changes (video↔image) so the
    ///   compositor uses the correct render path and motion/depth parameters are properly cleared.
    public func replaceSegmentMaterial(
        segmentID:      UUID,
        localURL:       URL,
        nativeDuration: Double?,
        clipInTime:     Double? = nil
    ) {
        // Evict old thumbnail from cache before mutating so the strip re-fetches the new asset.
        #if canImport(UIKit)
        if let seg = timeline.segment(id: segmentID),
           let oldURL = timeline.materials[seg.materialID]?.bestURL {
            Task { await ThumbnailProvider.shared.removeCache(for: oldURL) }
        }
        #endif

        mutate("替换素材") { tl in
            guard var seg = tl.segment(id: segmentID) else { return }
            let isIncomingVideo = nativeDuration != nil
            var asset = tl.materials[seg.materialID] ?? EditorAsset(id: seg.materialID, type: .image)

            // ── Update asset record ──────────────────────────────────────────
            asset.localURL       = localURL
            asset.remoteURL      = nil
            asset.nativeDuration = nativeDuration
            asset.type           = isIncomingVideo ? .video : .image
            tl.materials[seg.materialID] = asset

            // ── Upgrade / downgrade content type ────────────────────────────
            var segChanged = false
            switch (seg.content, isIncomingVideo) {
            case (.image, true):
                seg.content     = .video(SegmentContent.VideoContent())
                seg.sourceRange = nil
                segChanged = true
            case (.video, false):
                seg.content     = .image(SegmentContent.ImageContent())
                seg.sourceRange = nil
                segChanged = true
            default:
                break
            }

            // ── Apply clip-in-time (merges replace + sourceRange into one undo entry) ──
            if let clipIn = clipInTime, isIncomingVideo {
                seg.sourceRange = TimeRange(start: clipIn, duration: seg.targetRange.duration)
                segChanged = true
            }

            if segChanged {
                tl.updateSegment(id: segmentID) { $0 = seg }
            }
        }
    }

    // MARK: - Common Operations (convenience wrappers over mutate)

    public func deleteSegment(id: UUID) {
        let isOnMainTrack = timeline.mainTrack?.segment(id: id) != nil
        // v3 (multi-track-architecture §2.4): capture the host non-main track so the
        // mutate body can auto-recycle it if removing this segment leaves it empty.
        let hostTrackID: UUID? = timeline.tracks.first(where: { t in
            !t.isMainTrack && t.segments.contains(where: { $0.id == id })
        })?.id

        mutate("删除片段") { tl in
            tl.removeSegment(id: id)
            if isOnMainTrack {
                tl.repackMainTrack()
            }
            // Recycle empty non-main, non-pendingUserCreated track in the same undo entry.
            if let hostID = hostTrackID,
               let host = tl.track(id: hostID),
               !host.isMainTrack,
               !host.pendingUserCreated,
               host.segments.isEmpty {
                tl.tracks.removeAll { $0.id == hostID }
            }
        }
        if let hostID = hostTrackID, timeline.track(id: hostID) == nil {
            cancelPendingCleanup(for: hostID)
        }
    }

    /// Split a segment at the given timeline time.  Produces two back-to-back
    /// segments that together cover the same source material.
    /// - Returns: The UUID of the newly created right-side segment, or nil on failure.
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

        // Source in-point advances 1:1 with timeline time, matching
        // CompositionBuilder.srcRange (which always reads targetRange.duration of
        // source starting at sourceRange.start). Using the split OFFSET — not a ratio
        // of the possibly-stale sourceRange.duration — keeps the right half's in-point
        // correct even after a trim left sourceRange.duration out of sync with the
        // target duration. splitOffset == leftDur == clampedTime − targetRange.start.
        let splitOffset = leftDur
        var newSourceLeft:  TimeRange? = seg.sourceRange
        var newSourceRight: TimeRange? = nil
        if let src = seg.sourceRange {
            newSourceLeft  = TimeRange(start: src.start, duration: leftDur)
            newSourceRight = TimeRange(start: src.start + splitOffset, duration: rightDur)
        }

        // Clone properties from the original segment, but with new ID for the right half.
        let rightID = UUID()
        mutate("分割片段") { tl in
            guard let si = tl.tracks[trackIdx].segments.firstIndex(where: { $0.id == id })
            else { return }
            // Update left half in-place.
            tl.tracks[trackIdx].segments[si].targetRange  = newTargetLeft
            tl.tracks[trackIdx].segments[si].sourceRange  = newSourceLeft
            // Insert right half as a new segment.
            let rightSeg = EditorSegment(
                id: rightID,
                materialID: seg.materialID,
                sourceRange: newSourceRight,
                targetRange: newTargetRight,
                speed: seg.speed,
                transform: seg.transform,
                blendMode: seg.blendMode,
                content: seg.content,
                adjustment: seg.adjustment
            )
            tl.tracks[trackIdx].segments.insert(rightSeg, at: si + 1)
        }
        return rightID
    }

    /// In-memory single-segment clipboard.
    @ObservationIgnored
    private var clipBoardSegment: EditorSegment?

    public func copySegment(id: UUID) {
        clipBoardSegment = timeline.segment(id: id)
    }

    /// Paste the clipboard segment after the given anchor segment.
    /// The new segment gets a fresh UUID and is placed flush after the anchor.
    public func pasteSegment(after anchorID: UUID? = nil) {
        guard let copied = clipBoardSegment else { return }

        let trackID: UUID
        let insertStart: Double
        if let anchorID,
           let anchorTrack = timeline.tracks.first(where: { $0.segments.contains(where: { $0.id == anchorID }) }),
           let anchorSeg = anchorTrack.segments.first(where: { $0.id == anchorID }) {
            trackID = anchorTrack.id
            insertStart = anchorSeg.targetRange.end
        } else if let main = timeline.mainTrack {
            trackID = main.id
            insertStart = main.segments.last?.targetRange.end ?? 0
        } else if let first = timeline.tracks.first {
            trackID = first.id
            insertStart = 0
        } else {
            return
        }

        let newSeg = EditorSegment(
            id: UUID(),
            materialID: copied.materialID,
            sourceRange: copied.sourceRange,
            targetRange: TimeRange(start: insertStart, duration: copied.targetRange.duration),
            speed: copied.speed,
            transform: copied.transform,
            blendMode: copied.blendMode,
            content: copied.content,
            adjustment: copied.adjustment
        )

        mutate("粘贴片段") { tl in
            guard let ti = tl.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            tl.tracks[ti].segments.append(newSeg)
            tl.tracks[ti].segments.sort { $0.targetRange.start < $1.targetRange.start }
            if tl.tracks[ti].isMainTrack {
                tl.repackMainTrack()
            }
        }
    }

    public var hasClipboardSegment: Bool { clipBoardSegment != nil }

    public func trimSegment(id: UUID, newTargetRange: TimeRange, newSourceRangeStart: Double? = nil) {
        // Main track: magnetic ripple — pin the trimmed segment to its predecessor and
        // shift all subsequent segments so the track stays seamless with no gaps.
        if timeline.mainTrack?.segment(id: id) != nil {
            mutate("裁剪片段") { tl in
                guard let ti = tl.tracks.firstIndex(where: { $0.isMainTrack }),
                      let si = tl.tracks[ti].segments.firstIndex(where: { $0.id == id })
                else { return }

                let oldStart = tl.tracks[ti].segments[si].targetRange.start
                let oldEnd   = tl.tracks[ti].segments[si].targetRange.end

                // ── Pre-roll consumption model (both handles) ──────────────────
                // clampedRange already produces the correct ranges for the main track:
                //
                // Left-handle drag left  (dt < 0): pre-roll extension.
                //   clampedRange returns {start: oldStart, duration: oldDur + ext}
                //   (start anchored, right edge extended).  growthDelta = ext > 0.
                //   Successors shift right by ext.  sourceRange.start decreases.
                //
                // Left-handle drag right (dt > 0): inward trim.
                //   clampedRange returns {start: oldStart + dt, duration: oldDur - dt}
                //   (start moved right, right end fixed).  This creates a gap of dt
                //   between the predecessor's end (oldStart) and the new start.
                //   → pinStart: anchor start to oldStart, keep new duration.
                //   growthDelta = -dt < 0 → successors shift LEFT by dt, closing the gap.
                //
                // Right-handle drag: block grows/shrinks rightward naturally.
                //   clampedRange passes through.  growthDelta > 0 or < 0.
                //   Successors shift accordingly.
                //
                // The track stays contiguous from t=0 with no gaps or overlaps.
                var finalRange = newTargetRange
                if newTargetRange.start < oldStart - 0.001 {
                    // Pre-roll extension (safety net for attachment tracks or if
                    // clampedRange returns a left-shifted start).
                    finalRange = TimeRange(start: oldStart, duration: newTargetRange.duration)
                } else if newTargetRange.start > oldStart + 0.001 {
                    // Inward trim: pin start to predecessor's end, close the gap.
                    finalRange = TimeRange(start: oldStart, duration: newTargetRange.duration)
                }
                tl.tracks[ti].segments[si].targetRange = finalRange

                if let newStart = newSourceRangeStart,
                   var sr = tl.tracks[ti].segments[si].sourceRange {
                    sr.start = newStart
                    tl.tracks[ti].segments[si].sourceRange = sr
                }

                // Shift successors by the net right-edge movement.
                // For pre-roll conversion: finalRange.end = oldStart + (oldDuration + delta) = oldEnd + delta
                //   → growthDelta = delta → successors ripple right.
                // For right extension: finalRange == newTargetRange → growthDelta > 0.
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
            // Audio track trim affects AVComposition — full rebuild needed.
            mutate("裁剪片段") { tl in
                tl.updateSegment(id: id) { seg in
                    seg.targetRange = newTargetRange
                    if let newStart = newSourceRangeStart, var sr = seg.sourceRange {
                        sr.start = newStart; seg.sourceRange = sr
                    }
                }
            }
        } else {
            // Overlay/text/subtitle trim: no composition rebuild needed (S-04).
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

    /// Re-order segments within a track.
    ///
    /// - Video tracks: pack end-to-end with no gaps (video is the time backbone).
    /// - All other tracks: swap time slots without collapsing gaps.
    ///   Each segment gets the *start time* of the slot it moves into; duration is
    ///   unchanged and inter-segment gaps are fully preserved.
    public func reorderSegments(trackID: UUID, newOrder: [UUID]) {
        mutate("重排片段") { tl in
            var needsTransitionCleanup: [UUID]?

            tl.updateTrack(id: trackID) { track in
                let segMap = Dictionary(uniqueKeysWithValues: track.segments.map { ($0.id, $0) })
                let ordered = newOrder.compactMap { segMap[$0] }

                if track.isMainTrack {
                    // Main track (time backbone): pack end-to-end, no gaps allowed.
                    var cursor = 0.0
                    track.segments = ordered.map { seg in
                        var s = seg
                        s.targetRange = TimeRange(start: cursor, duration: seg.targetRange.duration)
                        cursor += seg.targetRange.duration
                        return s
                    }
                    needsTransitionCleanup = ordered.map { $0.id }
                } else {
                    // Attachment tracks (subtitle, text, audio, overlay, adjustment):
                    // preserve original time slots — only content swaps, gaps are kept intact.
                    let slotStarts = track.segments
                        .sorted { $0.targetRange.start < $1.targetRange.start }
                        .map    { $0.targetRange.start }
                    track.segments = zip(ordered, slotStarts).map { seg, start in
                        var s = seg
                        s.targetRange = TimeRange(start: start, duration: seg.targetRange.duration)
                        return s
                    }
                }
            }

            if let order = needsTransitionCleanup {
                tl.removeOrphanedTransitions(for: order)
            }
        }
    }

    /// Update a text segment's font size for live slider preview — NOT undo-tracked.
    /// The caller must call `mutateTextStyle` on gesture end to record an undo entry.
    public func previewFontSize(segmentID: UUID, fontSize: Double) {
        timeline.updateSegment(id: segmentID) { seg in
            guard case .text(var c) = seg.content else { return }
            c.style.fontSize = fontSize
            seg.content = .text(c)
        }
        coordinator?.refreshTimelineRuntimeTextLayers(timeline: timeline)
    }

    /// Update a text segment's position for live drag preview — NOT undo-tracked.
    /// Call `updateTextPosition(segmentID:position:)` on gesture end to record an undo entry.
    public func previewTextPosition(segmentID: UUID, position: NormalizedPoint) {
        timeline.updateSegment(id: segmentID) { seg in
            guard case .text(var c) = seg.content else { return }
            c.position = position
            seg.content = .text(c)
        }
        coordinator?.refreshTimelineRuntimeTextLayers(timeline: timeline)
    }

    /// Mutate a text segment's content in one step (undo-tracked).
    public func mutateTextContent(segmentID: UUID, label: String = "编辑文字", _ modify: (inout SegmentContent.TextContent) -> Void) {
        mutateSubtitle(label) { tl in
            tl.updateSegment(id: segmentID) { seg in
                guard case .text(var c) = seg.content else { return }
                modify(&c)
                seg.content = .text(c)
            }
        }
        // v3 tts-spec §3.4: post a stale toast if any TTS audio references this segment.
        if let seg = timeline.segment(id: segmentID),
           case .text(let c) = seg.content {
            notifyStaleTTSIfNeeded(forSourceSegment: segmentID, newText: c.text)
        }
    }

    /// Mutate only the style of a text segment (undo-tracked).
    public func mutateTextStyle(segmentID: UUID, label: String = "修改样式", _ modify: (inout TextStyle) -> Void) {
        mutateTextContent(segmentID: segmentID, label: label) { modify(&$0.style) }
    }

    // Legacy convenience wrappers kept for compatibility
    public func updateTextContent(segmentID: UUID, text: String) {
        mutateTextContent(segmentID: segmentID) { $0.text = text }
    }

    public func updateTextPosition(segmentID: UUID, position: NormalizedPoint) {
        mutateTextContent(segmentID: segmentID, label: "移动文字") { $0.position = position }
    }

    public func previewSubtitlePosition(segmentID: UUID, positionY: Double) {
        timeline.updateSegment(id: segmentID) { seg in
            guard case .subtitle(var c) = seg.content else { return }
            c.positionY = positionY.clamped(to: 0...1)
            seg.content = .subtitle(c)
        }
        coordinator?.refreshTimelineRuntimeTextLayers(timeline: timeline)
    }

    public func updateSubtitlePosition(segmentID: UUID, positionY: Double) {
        mutateSubtitleContent(segmentID: segmentID, label: "移动字幕") {
            $0.positionY = positionY.clamped(to: 0...1)
        }
    }

    public func updateTextStyle(segmentID: UUID, style: TextStyle) {
        mutateTextStyle(segmentID: segmentID) { $0 = style }
    }

    // MARK: - V4 Style Preset (text-style-fidelity-spec §3)

    /// A pair of color + shadow hexes representing one of the 6 color presets
    /// (plus the "None" reset case, represented by `nil`).
    public struct StylePreset: Sendable, Hashable {
        public let color: String
        /// Hex like "#RRGGBBAA". When the alpha byte is "00" the shadow is
        /// treated as no shadow (matches `stylePresetsRow` visual semantics).
        public let shadowColor: String?

        public init(color: String, shadowColor: String?) {
            self.color = color
            self.shadowColor = shadowColor
        }
    }

    /// Apply a color + shadow preset to a single text/subtitle segment.
    ///
    /// Only `color`, `shadowColor`, `shadowOffsetX/Y`, `shadowRadius` are
    /// overwritten; all other TextStyle fields are preserved. Routes through
    /// `mutateSubtitleStyle / mutateTextStyle` so the existing undo + (for
    /// subtitles) S-04 no-rebuild invariants hold.
    ///
    /// - Parameter preset: `nil` = "None" preset (reset color to white, clear
    ///   shadow). Non-nil presets apply the given color + shadow with default
    ///   offset (1, 1) and radius 2 — matching `stylePresetsRow` visual.
    public func applyStylePreset(segmentID: UUID, preset: StylePreset?) {
        let applyToStyle: (inout TextStyle) -> Void = { style in
            if let preset = preset {
                style.color = preset.color
                if let shadowHex = preset.shadowColor, !Self.isFullyTransparent(hex: shadowHex) {
                    style.shadowColor   = shadowHex
                    style.shadowOffsetX = 1
                    style.shadowOffsetY = 1
                    style.shadowRadius  = 2
                } else {
                    style.shadowColor   = nil
                    style.shadowOffsetX = 0
                    style.shadowOffsetY = 0
                    style.shadowRadius  = 0
                }
            } else {
                // "None" preset: reset color + clear shadow.
                style.color         = "#FFFFFF"
                style.shadowColor   = nil
                style.shadowOffsetX = 0
                style.shadowOffsetY = 0
                style.shadowRadius  = 0
            }
        }
        guard let seg = timeline.segment(id: segmentID) else { return }
        if seg.isSubtitle {
            mutateSubtitleStyle(segmentID: segmentID, label: "应用预设样式", applyToStyle)
        } else if seg.isText {
            mutateTextStyle(segmentID: segmentID, label: "应用预设样式", applyToStyle)
        }
    }

    /// Check whether a hex string like "#RRGGBBAA" has alpha == 0.
    /// `#RRGGBB` (6-digit) → not transparent.
    private static func isFullyTransparent(hex: String) -> Bool {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 8 else { return false }
        let alpha = trimmed.suffix(2).uppercased()
        return alpha == "00"
    }

    // MARK: - V4 Bulk Style Apply (bulk-style-apply-spec §3)

    /// Apply the style of `sourceSegmentID` to all other segments of the same
    /// kind on the same track. Falls into a single mutate block so the entire
    /// batch shows up as one undo entry.
    ///
    /// - Parameter trackID: target track.
    /// - Parameter sourceSegmentID: the segment whose style is the source.
    ///   Must reside in `trackID`. Style fields copied per
    ///   bulk-style-apply-spec §2.3 — TextStyle 16 fields (16 = current count
    ///   incl. v4 `alignment` once that lands).
    /// - Parameter includePositionFields: when true, also copies subtitle
    ///   `positionY` / `maxCharsPerLine` (P1 toggle). V4 P0 always false.
    /// - Returns: number of segments actually mutated (excludes source).
    ///   Returns 0 if the track is locked.
    @discardableResult
    public func applyStyleToTrackSegmentsOfKind(
        trackID: UUID,
        sourceSegmentID: UUID,
        includePositionFields: Bool = false
    ) -> Int {
        guard let track  = timeline.tracks.first(where: { $0.id == trackID }) else { return 0 }
        guard !track.isLocked else { return 0 }
        guard let source = track.segments.first(where: { $0.id == sourceSegmentID }) else { return 0 }

        let sourceIsSubtitle: Bool
        switch source.content {
        case .subtitle: sourceIsSubtitle = true
        case .text:     sourceIsSubtitle = false
        default:        return 0
        }

        // Snapshot the source style + position fields outside the mutate
        // closure so we never read & write the same draft simultaneously.
        let sourceStyle: TextStyle
        let sourcePositionY: Double?
        let sourceMaxChars: Int?
        switch source.content {
        case .subtitle(let c):
            sourceStyle     = c.style
            sourcePositionY = c.positionY
            sourceMaxChars  = c.maxCharsPerLine
        case .text(let c):
            sourceStyle     = c.style
            sourcePositionY = nil
            sourceMaxChars  = nil
        default:
            return 0
        }

        var mutatedCount = 0
        let label = "应用到本轨同类"
        let body: (inout EditorTimeline) -> Void = { tl in
            guard let trackIdx = tl.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            for i in tl.tracks[trackIdx].segments.indices {
                let segID = tl.tracks[trackIdx].segments[i].id
                guard segID != sourceSegmentID else { continue }
                switch tl.tracks[trackIdx].segments[i].content {
                case .subtitle(var c) where sourceIsSubtitle:
                    c.style = sourceStyle
                    if includePositionFields {
                        if let py = sourcePositionY { c.positionY = py }
                        if let mc = sourceMaxChars  { c.maxCharsPerLine = mc }
                    }
                    tl.tracks[trackIdx].segments[i].content = .subtitle(c)
                    mutatedCount += 1
                case .text(var c) where !sourceIsSubtitle:
                    c.style = sourceStyle
                    tl.tracks[trackIdx].segments[i].content = .text(c)
                    mutatedCount += 1
                default:
                    continue
                }
            }
        }
        // Subtitle / text style mutations follow the no-rebuild S-04 path.
        mutateSubtitle(label, body)
        return mutatedCount
    }

    // MARK: - V4 Text Alignment (text-typography-spec §2)

    public func setTextAlignment(segmentID: UUID, alignment: TextAlignment) {
        guard let seg = timeline.segment(id: segmentID) else { return }
        if seg.isSubtitle {
            mutateSubtitleStyle(segmentID: segmentID, label: "文本对齐") { $0.alignment = alignment }
        } else if seg.isText {
            mutateTextStyle(segmentID: segmentID, label: "文本对齐") { $0.alignment = alignment }
        }
    }

    // MARK: - V4 Style Copy/Paste (text-typography-spec §4)

    public func copyStyle(segmentID: UUID) {
        guard let seg = timeline.segment(id: segmentID) else { return }
        let kind: StyleClipboard.SegmentKind
        let style: TextStyle
        switch seg.content {
        case .subtitle(let c):
            kind = .subtitle
            style = c.style
        case .text(let c):
            kind = .text
            style = c.style
        default:
            return
        }
        styleClipboard = StyleClipboard(style: style, sourceKind: kind)
    }

    public func canPasteStyle(toSegmentID segmentID: UUID) -> Bool {
        guard let cb = styleClipboard, let seg = timeline.segment(id: segmentID) else { return false }
        switch (cb.sourceKind, seg.content) {
        case (.subtitle, .subtitle): return true
        case (.text, .text):         return true
        default:                     return false
        }
    }

    public func pasteStyle(segmentID: UUID) {
        guard canPasteStyle(toSegmentID: segmentID), let cb = styleClipboard else { return }
        let sourceStyle = cb.style
        if timeline.segment(id: segmentID)?.isSubtitle == true {
            mutateSubtitleStyle(segmentID: segmentID, label: "粘贴样式") { $0 = sourceStyle }
        } else {
            mutateTextStyle(segmentID: segmentID, label: "粘贴样式") { $0 = sourceStyle }
        }
    }

    // MARK: - V4 Layer Z-Order (text-typography-spec §5)

    public func bringSegmentToFront(segmentID: UUID) {
        setUserZOrder(segmentID: segmentID, strategy: .toFront)
    }

    public func sendSegmentToBack(segmentID: UUID) {
        setUserZOrder(segmentID: segmentID, strategy: .toBack)
    }

    public func bringSegmentForward(segmentID: UUID) {
        setUserZOrder(segmentID: segmentID, strategy: .forward)
    }

    public func sendSegmentBackward(segmentID: UUID) {
        setUserZOrder(segmentID: segmentID, strategy: .backward)
    }

    private enum ZOrderStrategy { case toFront, toBack, forward, backward }

    private func setUserZOrder(segmentID: UUID, strategy: ZOrderStrategy) {
        guard let seg = timeline.segment(id: segmentID) else { return }
        guard seg.isSubtitle || seg.isText else { return }

        // Collect overlapping same-kind segments (excluding self)
        let overlapping: [EditorSegment] = timeline.tracks
            .filter { $0.kind == .subtitle || $0.kind == .text }
            .flatMap { $0.segments }
            .filter { $0.id != segmentID && $0.targetRange.overlaps(seg.targetRange) }
            .filter { ($0.isSubtitle && seg.isSubtitle) || ($0.isText && seg.isText) }

        let currentZ = seg.userZOrder ?? 0
        let othersZ = overlapping.map { $0.userZOrder ?? 0 }

        let newZ: Int
        switch strategy {
        case .toFront:
            newZ = (othersZ.max() ?? 0) + 1
        case .toBack:
            newZ = (othersZ.min() ?? 0) - 1
        case .forward:
            let higher = othersZ.filter { $0 > currentZ }.sorted()
            newZ = higher.first.map { $0 } ?? (currentZ + 1)
        case .backward:
            let lower = othersZ.filter { $0 < currentZ }.sorted(by: >)
            newZ = lower.first.map { $0 } ?? (currentZ - 1)
        }

        mutateSubtitle("调整层级") { tl in
            tl.updateSegment(id: segmentID) { $0.userZOrder = newZ }
        }
    }

    /// Add a new segment to the end of the main track from a media URL.
    public func addSegmentToMainTrack(localURL: URL, nativeDuration: Double?) {
        addVisualSegment(localURL: localURL, nativeDuration: nativeDuration, targetTrackID: nil)
    }

    /// Add a visual media segment either to the main track or to a concrete overlay track.
    ///
    /// Main-track insertion appends at the end, preserving the backbone contract.
    /// Overlay insertion uses the current playhead as the target start so an empty
    /// user-created row can act as a placement target without inventing a second
    /// media-import pipeline.
    @discardableResult
    public func addVisualSegment(
        localURL: URL,
        nativeDuration: Double?,
        targetTrackID: UUID? = nil
    ) -> UUID? {
        let segmentID = UUID()
        let playheadTime = selection.playheadTime
        mutate("添加素材") { tl in
            let trackIndex: Int?
            if let targetTrackID {
                trackIndex = tl.tracks.firstIndex {
                    $0.id == targetTrackID && !$0.isMainTrack && $0.kind == .overlay
                }
            } else {
                trackIndex = tl.tracks.firstIndex(where: { $0.isMainTrack })
            }
            guard let ti = trackIndex else { return }
            let materialID = UUID()
            let isVideo = nativeDuration != nil
            let asset = EditorAsset(
                id: materialID,
                type: isVideo ? .video : .image,
                localURL: localURL,
                nativeDuration: nativeDuration
            )
            tl.materials[materialID] = asset

            let insertStart = targetTrackID == nil
                ? (tl.tracks[ti].segments.last?.targetRange.end ?? 0)
                : playheadTime
            let dur: Double = nativeDuration ?? 3.0  // default 3s for images
            let segment = EditorSegment(
                id: segmentID,
                materialID: materialID,
                // Video MUST carry an explicit source range so a later split can
                // offset the right half's in-point (sourceRange.start). With nil the
                // split can't compute the offset and the right half replays from the
                // first frame. Images have no source-time concept → stay nil.
                sourceRange: isVideo ? TimeRange(start: 0, duration: dur) : nil,
                targetRange: TimeRange(start: insertStart, duration: dur),
                speed: 1.0,
                content: isVideo ? .video(SegmentContent.VideoContent()) : .image(SegmentContent.ImageContent())
            )
            tl.tracks[ti].insert(segment)
            if tl.tracks[ti].pendingUserCreated {
                tl.tracks[ti].pendingUserCreated = false
            }
        }
        if timeline.segment(id: segmentID) != nil {
            if let targetTrackID { cancelPendingCleanup(for: targetTrackID) }
            if targetTrackID != nil {
                selection.selectOnly(segmentID)
            }
            return segmentID
        }
        return nil
    }

    // MARK: - V3 Audio Segments (audio-feature-spec §2.2/§2.3)

    /// Add a local audio file (already on disk and accessible via `localURL`) as
    /// a new audio segment, auto-allocating its track via M1 `addSegmentAutoTrack`.
    /// Used by both audio extraction (video → m4a) and local music import paths.
    ///
    /// - Parameters:
    ///   - localURL: file URL pointing to a stable location inside the asset cache
    ///     (use `AssetDownloadManager.reserveLocalURL(...)` to obtain one).
    ///   - nativeDuration: real audio duration in seconds (drives `targetRange.duration`
    ///     and `EditorAsset.nativeDuration` for trim handle right-cap).
    /// - Returns: the new segment ID, or nil if the host track allocation fails.
    @discardableResult
    public func addAudioSegment(
        localURL: URL,
        nativeDuration: Double,
        startTime: Double? = nil,
        targetTrackID: UUID? = nil,
        ttsSource: SegmentContent.TTSSource? = nil
    ) -> UUID? {
        let assetID = UUID()
        let asset = EditorAsset(
            id:             assetID,
            type:           .audio,
            localURL:       localURL,
            nativeDuration: nativeDuration
        )
        let segmentID = UUID()
        let segment = EditorSegment(
            id:          segmentID,
            materialID:  assetID,
            sourceRange: TimeRange(start: 0, duration: nativeDuration),
            targetRange: TimeRange(
                start:    startTime ?? selection.playheadTime,
                duration: nativeDuration
            ),
            content:     .audio(SegmentContent.AudioContent(
                volume:    1.0,
                ttsSource: ttsSource
            ))
        )
        // Register asset BEFORE addSegmentAutoTrack so the mutate snapshot sees it.
        // Orphaning the asset on undo is acceptable (mirror createNewTextSegment).
        timeline.materials.add(asset)
        let hostTrackID: UUID?
        if let targetTrackID,
           timeline.track(id: targetTrackID)?.kind == .audio {
            addSegment(toTrack: targetTrackID, segment: segment)
            hostTrackID = targetTrackID
        } else {
            hostTrackID = addSegmentAutoTrack(kind: .audio, segment: segment)
        }
        guard hostTrackID != nil else {
            timeline.materials.remove(id: assetID)
            return nil
        }
        return segmentID
    }

    // MARK: - V5.1 增补：进入 ClipEditor 时音频段长度规范化

    /// V5.1 修复：把所有非循环 audio segment 的 `targetRange.duration` cap 到
    /// 音频源文件的真实时长。
    ///
    /// **背景**：`TimelineImporter` 在 AI 工程导入时把 audio 段 `targetRange.duration`
    /// 设为 `schema.duration`（整个工程长度），不考虑音频源文件实际长度。导致 audio
    /// 块 UI 显示成「和主轨道一样长」，即使音频文件实际只有几秒。用户触碰 trim 手柄
    /// 后，`clampedRange` 的 srcCap 才把 duration 缩回真实值。
    ///
    /// **修复**：进入 ClipEditor 时异步加载所有 audio asset 的真实 `.duration`，对
    /// 超出源长度的 segment 自动 cap。silent 修正（无 undo），下次进入时不再触发。
    ///
    /// **跳过条件**：
    /// - `AudioContent.isLooping=true`（BGM 设计就是铺满整个工程循环播放）
    /// - 音频源文件 duration 加载失败
    /// - `targetRange.duration` 已经 ≤ 真实长度（无需 cap）
    public func normalizeAudioDurations() async {
        var changedSegments: [(UUID, TimeRange)] = []

        for track in timeline.tracks where track.kind == .audio && !track.isHidden {
            for seg in track.segments {
                guard case .audio(let content) = seg.content,
                      !content.isLooping else { continue }
                guard let asset = timeline.materials[seg.materialID],
                      let url = asset.bestURL else { continue }

                let avAsset = AVURLAsset(url: url, options: [
                    AVURLAssetPreferPreciseDurationAndTimingKey: true
                ])
                let audioDur: Double
                do {
                    let cmDur = try await avAsset.load(.duration)
                    audioDur = cmDur.seconds
                } catch {
                    continue
                }
                guard audioDur > 0, audioDur.isFinite else { continue }

                let srcStart = seg.sourceRange?.start ?? 0
                let maxAllowed = max(0.1, audioDur - srcStart)

                if seg.targetRange.duration > maxAllowed + 0.05 {
                    let newRange = TimeRange(start: seg.targetRange.start, duration: maxAllowed)
                    changedSegments.append((seg.id, newRange))
                }
            }
        }

        guard !changedSegments.isEmpty else { return }
        for (id, newRange) in changedSegments {
            timeline.updateSegment(id: id) { seg in
                seg.targetRange = newRange
                // 同步把 sourceRange.duration 也修正为 newRange.duration（保持 source/target 一致）
                if var sr = seg.sourceRange {
                    sr.duration = newRange.duration
                    seg.sourceRange = sr
                } else {
                    seg.sourceRange = TimeRange(start: 0, duration: newRange.duration)
                }
            }
        }
        // 触发 AVComposition 重建，但不进入 undo 栈（silent 修正用户没主动操作）
        compositionVersion += 1
    }

    // MARK: - V3 Detach Audio (audio-feature-spec §9)

    public enum DetachAudioError: Swift.Error, LocalizedError {
        case notVideoSegment
        case assetURLMissing

        public var errorDescription: String? {
            switch self {
            case .notVideoSegment: return "请选择视频片段"
            case .assetURLMissing: return "视频素材不可用"
            }
        }
    }

    /// Detach a main-track video segment's audio into an independent `.audio` segment
    /// (audio-feature-spec §9). The extracted m4a auto-allocates an audio track; the
    /// source video segment's `VideoContent.isMuted` flips to true so playback isn't
    /// doubled. Both effects land in one `mutate` snapshot → single-step undo.
    /// - Returns: the new `.audio` segment ID
    /// - Throws: `DetachAudioError` for shape mismatches; `AudioExtractor.Failure`
    ///   (e.g. `.noAudioTrack`) for extraction failures
    @discardableResult
    public func detachAudio(fromVideoSegmentID id: UUID) async throws -> UUID {
        // 1. Validate source — must be a video segment with a registered asset.
        guard let seg = timeline.segment(id: id),
              case .video = seg.content else {
            throw DetachAudioError.notVideoSegment
        }
        guard let videoAsset = timeline.materials[seg.materialID] else {
            throw DetachAudioError.assetURLMissing
        }
        let timelineID = timeline.id

        // 2. Resolve a *local* video URL. AVAssetReader does not support remote URLs
        //    (fails with AVError -11838 "OperationStopped" / NotSupported); if the
        //    asset only has a remoteURL (e.g. fresh OSS link before prefetch), download
        //    it via AssetDownloadManager and persist the mapping.
        let videoLocalURL: URL
        if let local = videoAsset.localURL,
           FileManager.default.fileExists(atPath: local.path) {
            videoLocalURL = local
        } else if let remote = videoAsset.remoteURL {
            videoLocalURL = try await AssetDownloadManager.shared.localURL(
                for:        remote,
                assetID:    videoAsset.id,
                timelineID: timelineID
            )
            updateAssetLocalURL(assetID: videoAsset.id, url: videoLocalURL)
        } else {
            throw DetachAudioError.assetURLMissing
        }

        // 3. Reserve output path inside the per-timeline asset cache.
        let extractedAssetID = UUID()
        let outputURL = try AssetDownloadManager.shared.reserveLocalURL(
            assetID:    extractedAssetID,
            extension:  "m4a",
            timelineID: timelineID
        )

        // 4. Extract entire audio track (async). `AudioExtractor.Failure.noAudioTrack`
        //    surfaces directly so the panel can toast a localized message.
        let extractedDuration = try await AudioExtractor.shared.extract(
            from: videoLocalURL,
            to:   outputURL
        )

        // 5. Build the new asset + segment. Audio segment time-aligns with the video
        //    via mirrored sourceRange (so trim & timeline position both match exactly).
        let audioAsset = EditorAsset(
            id:             extractedAssetID,
            type:           .audio,
            localURL:       outputURL,
            nativeDuration: extractedDuration
        )
        let audioSegmentID = UUID()
        let audioSourceStart = seg.sourceRange?.start ?? 0
        let audioSourceDur   = seg.sourceRange?.duration ?? seg.targetRange.duration
        let audioSegment = EditorSegment(
            id:          audioSegmentID,
            materialID:  extractedAssetID,
            sourceRange: TimeRange(start: audioSourceStart, duration: audioSourceDur),
            targetRange: seg.targetRange,
            content:     .audio(SegmentContent.AudioContent(volume: 1.0))
        )

        // 6. Single mutate → single undo entry covering (a) asset add, (b) audio
        //    track allocate/reuse, (c) original video mute.
        mutate("分离音视频") { tl in
            tl.materials.add(audioAsset)
            Self.allocateAudioTrackInline(in: &tl, segment: audioSegment)
            tl.updateSegment(id: id) { v in
                guard case .video(var c) = v.content else { return }
                c.isMuted = true
                v.content = .video(c)
            }
        }
        return audioSegmentID
    }

    /// Inline mirror of `addSegmentAutoTrack(.audio)` allocation rule, callable
    /// from within an existing `mutate` body without nested mutates. Returns the
    /// host track ID (created or reused).
    @discardableResult
    private static func allocateAudioTrackInline(
        in tl: inout EditorTimeline,
        segment: EditorSegment
    ) -> UUID {
        let candidates = tl.tracks
            .filter { $0.kind == .audio }
            .sorted { ($0.zPosition, $0.id.uuidString) < ($1.zPosition, $1.id.uuidString) }
        if let reusable = candidates.first(where: { track in
            !track.segments.contains { $0.targetRange.overlaps(segment.targetRange) }
        }) {
            if let idx = tl.tracks.firstIndex(where: { $0.id == reusable.id }) {
                tl.tracks[idx].segments.append(segment)
            }
            return reusable.id
        }
        let existing = tl.tracks.filter { $0.kind == .audio }
        let resolvedZ = existing.isEmpty
            ? defaultZPosition(for: .audio)
            : (existing.map(\.zPosition).max() ?? 0) + 1
        let label = "\(displayName(for: .audio)) \(existing.count + 1)"
        let newTrack = EditorTrack(
            id:          UUID(),
            kind:        .audio,
            label:       label,
            zPosition:   resolvedZ,
            segments:    [segment],
            isMainTrack: false
        )
        tl.tracks.append(newTrack)
        return newTrack.id
    }

    // MARK: - V3 TTS (tts-spec §3.6)

    /// Shared sheet state for the TTS config UI. Set non-nil to present the sheet;
    /// the sheet view writes it back to nil on dismiss.
    /// The array is the set of source `.text` / `.subtitle` segment IDs to (re)generate.
    public var ttsConfigSheetTargets: [UUID]? = nil

    /// Last voice / rate the user picked (memorized across launches via UserDefaults).
    public var lastTTSVoice: TTSService.VoiceKind {
        get {
            let raw = UserDefaults.standard.string(forKey: "TimelineKit.tts.lastVoice")
            return raw.flatMap(TTSService.VoiceKind.init(rawValue:)) ?? .female
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "TimelineKit.tts.lastVoice") }
    }
    public var lastTTSRate: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "TimelineKit.tts.lastRate")
            return (v >= 0.5 && v <= 2.0) ? v : 1.0
        }
        set { UserDefaults.standard.set(newValue, forKey: "TimelineKit.tts.lastRate") }
    }

    /// Regenerate the TTS audio segment that points at this source `.text` /
    /// `.subtitle` segment. Removes any existing TTS audio referencing the same
    /// source first (single undo entry covers both).
    /// - Throws: TTSService.Failure on synthesis errors.
    public func regenerateTTS(
        forSourceSegment sourceID: UUID,
        voice: TTSService.VoiceKind,
        rate: Double
    ) async throws {
        try await regenerateTTS(forSourceSegments: [sourceID], voice: voice, rate: rate)
    }

    /// Batch regenerate. Each source segment in `sourceIDs` is synthesized and
    /// the old TTS segments referencing it are atomically replaced in one mutate.
    public func regenerateTTS(
        forSourceSegments sourceIDs: [UUID],
        voice: TTSService.VoiceKind,
        rate: Double
    ) async throws {
        // 1. Resolve text / hosts / target start times.
        struct Job {
            let sourceID: UUID
            let text: String
            let targetStart: Double
            let voiceID: String
            let rate: Double
            let textHash: String
        }
        let voiceID = voice.resolveSystemVoice()?.identifier
                   ?? AVSpeechSynthesisVoice(language: "zh-CN")?.identifier
                   ?? ""

        let jobs: [Job] = sourceIDs.compactMap { id -> Job? in
            guard let seg = timeline.segment(id: id) else { return nil }
            let text: String
            switch seg.content {
            case .text(let c):     text = c.text
            case .subtitle(let c): text = c.text
            default:               return nil
            }
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            return Job(
                sourceID:    id,
                text:        text,
                targetStart: seg.targetRange.start,
                voiceID:     voiceID,
                rate:        rate,
                textHash:    TTSService.textHash(text)
            )
        }
        guard !jobs.isEmpty else { return }

        // 2. Synthesize each off the actor — these are independent.
        var results: [(job: Job, url: URL, duration: Double)] = []
        for job in jobs {
            let (url, dur) = try await TTSService.shared.synthesize(
                text: job.text, voice: job.voiceID, rate: job.rate
            )
            results.append((job, url, dur))
        }

        // 3. Mutate timeline once for the entire batch (single undo entry).
        mutate("生成配音") { tl in
            for (job, _, _) in results {
                // Remove any existing audio segment whose ttsSource references this sourceID.
                for ti in tl.tracks.indices {
                    tl.tracks[ti].segments.removeAll { seg in
                        if case .audio(let c) = seg.content,
                           let src = c.ttsSource,
                           src.sourceSegmentID == job.sourceID {
                            return true
                        }
                        return false
                    }
                }
            }
        }

        // 4. Insert new TTS audio segments — uses addSegmentAutoTrack so each call
        //    handles its own mutate. Note: that means N+1 undo entries (1 batch
        //    delete + N inserts). Acceptable for v3; consolidating requires
        //    exposing addSegment* as raw closures.
        for (job, url, dur) in results {
            let ttsSource = SegmentContent.TTSSource(
                sourceSegmentID: job.sourceID,
                textHash:        job.textHash,
                voice:           job.voiceID,
                rate:            job.rate
            )
            _ = addAudioSegment(
                localURL:       url,
                nativeDuration: dur,
                startTime:      job.targetStart,
                ttsSource:      ttsSource
            )
        }

        // Persist last-used picks.
        lastTTSVoice = voice
        lastTTSRate = rate
    }

    /// Regenerate every `.text` and `.subtitle` segment's TTS audio.
    public func regenerateAllTTS(
        voice: TTSService.VoiceKind,
        rate: Double
    ) async throws {
        let sourceIDs = timeline.tracks.flatMap { $0.segments }.compactMap { seg -> UUID? in
            switch seg.content {
            case .text, .subtitle: return seg.id
            default:               return nil
            }
        }
        try await regenerateTTS(forSourceSegments: sourceIDs, voice: voice, rate: rate)
    }

    // MARK: - V3 TTS stale detection (tts-spec §3.4)

    /// After a text/subtitle edit lands, look up every audio segment whose
    /// `ttsSource.sourceSegmentID == sourceID` and whose `textHash` no longer
    /// matches. If any exist, post a TimelineKit toast so the user can decide.
    fileprivate func notifyStaleTTSIfNeeded(forSourceSegment sourceID: UUID, newText: String) {
        let newHash = TTSService.textHash(newText)
        let stale = timeline.tracks.flatMap { $0.segments }.contains { seg in
            if case .audio(let c) = seg.content,
               let src = c.ttsSource,
               src.sourceSegmentID == sourceID,
               src.textHash != newHash {
                return true
            }
            return false
        }
        if stale {
            ToastContext.shared.show(
                "配音文案已更新，可重新生成",
                icon: "speaker.wave.2",
                style: .warning,
                duration: 3.0,
                position: .top
            )
        }
    }

    // MARK: - V3 Manual Text Entry (text-entry-spec §3.3)

    /// Create a new manual text segment at the current playhead position.
    /// - Auto-allocates the host `.text` track via M1 `addSegmentAutoTrack` (reuse if
    ///   no overlap, else new track).
    /// - Adds a synthetic placeholder `EditorAsset` to satisfy the non-optional
    ///   `materialID` invariant (mirrors [TimelineImporter] text path).
    /// - Selects the new segment (sets `editingSegmentID` so the text edit panel
    ///   opens automatically per spec §3.5).
    /// - Strictly distinct from `.subtitle`: this entry never creates subtitle data.
    /// - Returns nil only if the host track allocation fails (defensive — should not happen
    ///   for `.text` since multi-track rules allow unlimited text tracks).
    @discardableResult
    public func createNewTextSegment(
        defaultText: String = "点击编辑文本",
        defaultDuration: Double = 3.0,
        targetTrackID: UUID? = nil
    ) -> UUID? {
        let placeholderAssetID = UUID()
        let placeholderAsset   = EditorAsset(id: placeholderAssetID, type: .placeholder)

        let segmentID = UUID()
        let segment = EditorSegment(
            id:          segmentID,
            materialID:  placeholderAssetID,
            sourceRange: nil,
            targetRange: TimeRange(start: selection.playheadTime, duration: defaultDuration),
            content: .text(SegmentContent.TextContent(
                text:     defaultText,
                style:    .default,
                position: .center,
                anchor:   .center
            ))
        )
        // Register the asset before addSegmentAutoTrack mutates the timeline so any
        // observer reading materials during the mutate sees the placeholder entry.
        timeline.materials.add(placeholderAsset)

        let hostTrackID: UUID?
        if let targetTrackID,
           timeline.track(id: targetTrackID)?.kind == .text {
            addSegment(toTrack: targetTrackID, segment: segment)
            hostTrackID = targetTrackID
        } else {
            hostTrackID = addSegmentAutoTrack(kind: .text, segment: segment)
        }
        guard hostTrackID != nil else {
            timeline.materials.remove(id: placeholderAssetID)
            return nil
        }
        selection.selectOnly(segmentID)
        return segmentID
    }

    /// Create a new `.subtitle` segment and add it to a subtitle track.
    public func createNewSubtitleSegment(
        defaultText: String = "点击编辑字幕",
        defaultDuration: Double = 3.0,
        targetTrackID: UUID? = nil
    ) -> UUID? {
        let placeholderAssetID = UUID()
        let placeholderAsset   = EditorAsset(id: placeholderAssetID, type: .placeholder)

        let segmentID = UUID()
        let segment = EditorSegment(
            id:          segmentID,
            materialID:  placeholderAssetID,
            sourceRange: nil,
            targetRange: TimeRange(start: selection.playheadTime, duration: defaultDuration),
            content: .subtitle(SegmentContent.SubtitleContent(
                text:  defaultText,
                style: .default
            ))
        )
        timeline.materials.add(placeholderAsset)

        let hostTrackID: UUID?
        if let targetTrackID,
           timeline.track(id: targetTrackID)?.kind == .subtitle {
            addSegment(toTrack: targetTrackID, segment: segment)
            hostTrackID = targetTrackID
        } else {
            hostTrackID = addSegmentAutoTrack(kind: .subtitle, segment: segment)
        }
        guard hostTrackID != nil else {
            timeline.materials.remove(id: placeholderAssetID)
            return nil
        }
        selection.selectOnly(segmentID)
        return segmentID
    }

    // MARK: - V3 Multi-Track Management (multi-track-architecture-spec)

    /// Explicitly create a new empty track. Used by the TrackLabelsView "+" button.
    /// - When `pendingUserCreated` is true, EditorStore schedules a 30-second
    ///   auto-recycle Task that calls `removeTrackIfEmpty` if no segment is added.
    /// - Composition rebuild policy follows spec §2.5:
    ///     .text / .subtitle add → mutateSubtitle (no rebuild)
    ///     otherwise → mutate (rebuild)
    /// - Refuses .video kind (the main video track is unique and cannot be duplicated).
    @discardableResult
    public func addTrack(
        kind: EditorTrack.Kind,
        label: String = "",
        zPosition: Int? = nil,
        pendingUserCreated: Bool = false
    ) -> UUID? {
        guard kind != .video else { return nil }  // .video uniqueness (spec §2.1)

        let existing = timeline.tracks(ofKind: kind)
        let resolvedZ: Int = {
            if let z = zPosition { return z }
            if existing.isEmpty  { return Self.defaultZPosition(for: kind) }
            return (existing.map(\.zPosition).max() ?? 0) + 1
        }()
        let resolvedLabel: String = {
            if !label.isEmpty { return label }
            return "\(Self.displayName(for: kind)) \(existing.count + 1)"
        }()
        let newID = UUID()
        let newTrack = EditorTrack(
            id:                 newID,
            kind:               kind,
            label:              resolvedLabel,
            zPosition:          resolvedZ,
            segments:           [],
            isMainTrack:        false,
            pendingUserCreated: pendingUserCreated
        )
        let body: (inout EditorTimeline) -> Void = { tl in
            tl.tracks.append(newTrack)
        }
        switch kind {
        case .text, .subtitle: mutateSubtitle("新建轨道", body)
        default:               mutate("新建轨道", body)
        }
        if pendingUserCreated {
            schedulePendingCleanup(for: newID)
        }
        return newID
    }

    /// Append a segment to a specific track. Caller is responsible for ensuring
    /// `segment.targetRange` does not overlap existing segments on that track.
    /// Rebuild policy follows segment content:
    ///   .video / .image / .audio → mutate
    ///   .text / .subtitle        → mutateSubtitle
    /// Clears the track's `pendingUserCreated` flag and cancels its 30-second timer.
    public func addSegment(toTrack trackID: UUID, segment: EditorSegment) {
        guard timeline.track(id: trackID) != nil else { return }
        let body: (inout EditorTimeline) -> Void = { tl in
            guard let ti = tl.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            tl.tracks[ti].insert(segment)
            if tl.tracks[ti].pendingUserCreated {
                tl.tracks[ti].pendingUserCreated = false
            }
        }
        if Self.segmentTriggersRebuild(segment) {
            mutate("添加片段", body)
        } else {
            mutateSubtitle("添加片段", body)
        }
        cancelPendingCleanup(for: trackID)
    }

    /// Pick an existing same-kind track with no time overlap, or create a new one.
    /// This is the canonical entry point for auto-allocating audio / text / subtitle
    /// segments (spec §2.2 "复用优先，重叠则新建"). Returns the host track ID.
    /// Refuses .video kind.
    @discardableResult
    public func addSegmentAutoTrack(
        kind: EditorTrack.Kind,
        segment: EditorSegment
    ) -> UUID? {
        guard kind != .video else { return nil }

        // 1. Find a same-kind track with no overlap (sorted: zPosition asc, id asc).
        let candidates = timeline.tracks(ofKind: kind)
            .sorted { ($0.zPosition, $0.id.uuidString) < ($1.zPosition, $1.id.uuidString) }
        if let reusable = candidates.first(where: { track in
            !track.segments.contains { $0.targetRange.overlaps(segment.targetRange) }
        }) {
            addSegment(toTrack: reusable.id, segment: segment)
            return reusable.id
        }

        // 2. All same-kind tracks overlap → create one with the segment in one undo entry.
        let existing = timeline.tracks(ofKind: kind)
        let resolvedZ: Int = existing.isEmpty
            ? Self.defaultZPosition(for: kind)
            : (existing.map(\.zPosition).max() ?? 0) + 1
        let resolvedLabel = "\(Self.displayName(for: kind)) \(existing.count + 1)"
        let newID = UUID()
        let newTrack = EditorTrack(
            id:          newID,
            kind:        kind,
            label:       resolvedLabel,
            zPosition:   resolvedZ,
            segments:    [segment],
            isMainTrack: false
        )
        let body: (inout EditorTimeline) -> Void = { tl in
            tl.tracks.append(newTrack)
        }
        if Self.segmentTriggersRebuild(segment) {
            mutate("添加片段", body)
        } else {
            mutateSubtitle("添加片段", body)
        }
        return newID
    }

    /// Remove a track if it is empty and not the main track. Pending-user-created
    /// flag is not gated here — this is the public API the 30-second timer relies on.
    /// Use `deleteSegment` to recycle via the "last-segment-deleted" implicit path.
    public func removeTrackIfEmpty(id: UUID) {
        guard let track = timeline.track(id: id),
              !track.isMainTrack,
              track.segments.isEmpty
        else { return }
        let kind = track.kind
        let body: (inout EditorTimeline) -> Void = { tl in
            tl.tracks.removeAll { $0.id == id }
        }
        switch kind {
        case .text, .subtitle: mutateSubtitle("删除空轨", body)
        default:               mutate("删除空轨", body)
        }
        cancelPendingCleanup(for: id)
    }

    // MARK: - V3 Helpers

    /// First-track-of-kind default zPosition (matches v1 [TimelineImporter] convention).
    /// Subsequent tracks of the same kind use max(existing) + 1.
    private static func defaultZPosition(for kind: EditorTrack.Kind) -> Int {
        switch kind {
        case .video:      return 0
        case .overlay:    return -1
        case .audio:      return 0
        case .subtitle:   return 5
        case .text:       return 10
        case .adjustment: return 0
        }
    }

    private static func displayName(for kind: EditorTrack.Kind) -> String {
        switch kind {
        case .video:      return "视频"
        case .overlay:    return "叠加"
        case .text:       return "文字"
        case .subtitle:   return "字幕"
        case .audio:      return "音频"
        case .adjustment: return "调节"
        }
    }

    private static func segmentTriggersRebuild(_ segment: EditorSegment) -> Bool {
        switch segment.content {
        case .video, .image, .audio: return true
        case .text,  .subtitle:      return false
        }
    }

    /// 30-second auto-recycle timer for `pendingUserCreated` tracks (spec §2.4).
    private static let pendingTrackLifetimeNS: UInt64 = 30_000_000_000

    private func schedulePendingCleanup(for trackID: UUID) {
        pendingCleanupTasks[trackID]?.cancel()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pendingTrackLifetimeNS)
            guard let self else { return }
            if Task.isCancelled { return }
            // Re-check live state — the track may have been removed or populated.
            if let track = self.timeline.track(id: trackID),
               track.pendingUserCreated,
               track.segments.isEmpty,
               !track.isMainTrack {
                self.removeTrackIfEmpty(id: trackID)
            }
            self.pendingCleanupTasks[trackID] = nil
        }
        pendingCleanupTasks[trackID] = task
    }

    private func cancelPendingCleanup(for trackID: UUID) {
        if let t = pendingCleanupTasks[trackID] {
            t.cancel()
            pendingCleanupTasks[trackID] = nil
        }
    }

    // MARK: - Live Trim Preview (no undo, no rebuild)

    /// Update a segment's time range in real-time during a trim drag gesture.
    /// Not undo-tracked and does NOT increment compositionVersion.
    /// Call trimSegment on gesture end to record the final state.
    public func previewTrimRange(segmentID: UUID, range: TimeRange) {
        timeline.updateSegment(id: segmentID) { $0.targetRange = range }
    }

    // MARK: - Subtitle Mutations (no AVComposition rebuild — spec S-04)

    /// Mutate a subtitle segment's full content (undo-tracked, no rebuild).
    public func mutateSubtitleContent(
        segmentID: UUID,
        label: String = "编辑字幕",
        _ modify: (inout SegmentContent.SubtitleContent) -> Void
    ) {
        mutateSubtitle(label) { tl in
            tl.updateSegment(id: segmentID) { seg in
                guard case .subtitle(var c) = seg.content else { return }
                modify(&c)
                seg.content = .subtitle(c)
            }
        }
        // v3 tts-spec §3.4: post a stale toast if any TTS audio references this segment.
        if let seg = timeline.segment(id: segmentID),
           case .subtitle(let c) = seg.content {
            notifyStaleTTSIfNeeded(forSourceSegment: segmentID, newText: c.text)
        }
    }

    /// Mutate only the style of a subtitle segment (undo-tracked, no rebuild).
    public func mutateSubtitleStyle(
        segmentID: UUID,
        label: String = "修改字幕样式",
        _ modify: (inout TextStyle) -> Void
    ) {
        mutateSubtitleContent(segmentID: segmentID, label: label) { c in
            modify(&c.style)
        }
    }

    /// Live preview: update subtitle text with no undo entry and no rebuild.
    public func previewSubtitleText(segmentID: UUID, text: String) {
        timeline.updateSegment(id: segmentID) { seg in
            guard case .subtitle(var c) = seg.content else { return }
            c.text = text
            seg.content = .subtitle(c)
        }
        coordinator?.refreshTimelineRuntimeTextLayers(timeline: timeline)
    }

    // MARK: - Audio Mutations

    /// Toggle track mute without AVComposition rebuild (A-03 spec: < 100ms).
    public func muteTrack(id: UUID, isMuted: Bool) {
        mutate(isMuted ? "静音轨道" : "取消静音") { tl in
            tl.updateTrack(id: id) { $0.isMuted = isMuted }
        }
        coordinator?.applyAudioMixOnly(timeline: timeline)
    }

    /// Set per-segment audio volume (undo-tracked). Triggers audioMix-only rebuild.
    public func setAudioVolume(segmentID: UUID, volume: Double) {
        mutate("调整音量") { tl in
            tl.updateSegment(id: segmentID) { seg in
                guard case .audio(var c) = seg.content else { return }
                c.volume = max(0, min(volume, 2.0))
                seg.content = .audio(c)
            }
        }
        coordinator?.applyAudioMixOnly(timeline: timeline)
    }

    // MARK: - V4 Audio Fade (audio-track-controls-spec §2.6)

    /// Set fade-in/out durations on an audio segment. Triggers audioMix-only rebuild
    /// (same path as setAudioVolume). Fade values are defensively clamped.
    public func mutateAudioFade(segmentID: UUID, fadeIn: Double, fadeOut: Double) {
        mutate("调整淡化") { tl in
            tl.updateSegment(id: segmentID) { seg in
                guard case .audio(var c) = seg.content else { return }
                let segDuration = seg.targetRange.duration
                let halfMax = segDuration / 2
                c.fadeInDuration  = max(0, min(fadeIn, halfMax))
                c.fadeOutDuration = max(0, min(fadeOut, segDuration - c.fadeInDuration))
                seg.content = .audio(c)
            }
        }
        coordinator?.applyAudioMixOnly(timeline: timeline)
    }

    // MARK: - V5 Export Config (export-config-panel-spec §4)

    /// V5：mutate 导出参数配置。
    ///
    /// - 第一次 mutate 时把 `metadata.exportConfig = nil` → `default(for: canvas)`
    ///   派生值 → 应用 body 修改 → 写回。
    /// - **不 bump `compositionVersion`**：导出参数仅在导出时消费，不影响实时预览
    ///   （沿用 V1 S-04：mutate 不无谓重建）。
    /// - **不进入 undo 栈**：导出参数变更是"工程级偏好"，撤销编辑步骤时不应连带回滚。
    /// - **主动调 `DraftStore.save`**：避免依赖 `DraftStore` 的 compositionVersion 轮询
    ///   节奏（5s），保证用户调参后立即持久化，crash 不丢配置。
    public func mutateExportConfig(_ body: (inout ExportConfig) -> Void) {
        var cfg = timeline.effectiveExportConfig
        body(&cfg)
        var t = timeline
        t.metadata.exportConfig = cfg
        timeline = t                            // explicit setter → @Observable publish
        DraftStore.save(timeline)               // 立即落盘
    }

    /// V5：恢复默认（清回 nil；下次读取 `effectiveExportConfig` 按当前 canvas 重新派生）。
    public func resetExportConfigToDefault() {
        var t = timeline
        t.metadata.exportConfig = nil
        timeline = t
        DraftStore.save(timeline)
    }

    // MARK: - V4 Track Lock/Hide (audio-track-controls-spec §3.4)

    /// Lock or unlock a track. Locked tracks reject all destructive gestures
    /// (drag / trim / long-press reorder) and hide destructive edit buttons.
    public func setTrackLocked(id: UUID, isLocked: Bool) {
        mutate(isLocked ? "锁定轨道" : "解锁轨道") { tl in
            tl.updateTrack(id: id) { $0.isLocked = isLocked }
        }
    }

    /// Hide or show a track. Hidden tracks are skipped during export and
    /// rendered at alpha=0.4 in the canvas. Main track cannot be hidden.
    public func setTrackHidden(id: UUID, isHidden: Bool) {
        guard let track = timeline.track(id: id), !track.isMainTrack else { return }
        mutate(isHidden ? "隐藏轨道" : "显示轨道") { tl in
            tl.updateTrack(id: id) { $0.isHidden = isHidden }
        }
        // Rebuild audio mix so hidden audio tracks are silenced.
        if track.kind == .audio {
            coordinator?.applyAudioMixOnly(timeline: timeline)
        }
    }

    /// Toggle segment-level mute without AVComposition rebuild.
    public func muteAudioSegment(id: UUID, isMuted: Bool) {
        mutate(isMuted ? "静音片段" : "取消静音") { tl in
            tl.updateSegment(id: id) { seg in
                guard case .audio(var c) = seg.content else { return }
                c.isMuted = isMuted
                seg.content = .audio(c)
            }
        }
        coordinator?.applyAudioMixOnly(timeline: timeline)
    }

    /// v3 P3 (audio-feature-spec §11): toggle a video segment's native-audio mute.
    /// Goes through full `mutate` (rebuild) because the audio composition's
    /// participating-tracks set changes — the audioMix fast-path can't add or
    /// remove the underlying audio track.
    public func setVideoMuted(segmentID: UUID, isMuted: Bool) {
        mutate(isMuted ? "静音原音" : "恢复原音") { tl in
            tl.updateSegment(id: segmentID) { seg in
                guard case .video(var c) = seg.content else { return }
                c.isMuted = isMuted
                seg.content = .video(c)
            }
        }
    }

    /// Apply a client-side animation preset to an image segment.
    /// Writes the generated KeyframeSet to `ImageContent.keyframes` and stores
    /// the preset ID for UI selection display. Triggers a full composition rebuild.
    public func applyImageAnimation(segmentID: UUID, preset: ImageAnimationPreset) {
        guard let seg = timeline.segment(id: segmentID),
              case .image = seg.content else { return }
        let duration = seg.targetRange.duration
        let kf = ImageAnimationPresetRegistry.keyframes(for: preset, duration: duration)
        mutate("应用动画") { tl in
            tl.updateSegment(id: segmentID) { seg in
                guard case .image(var c) = seg.content else { return }
                c.keyframes         = kf
                c.animationPresetID = kf == nil ? nil : preset.rawValue
                seg.content = .image(c)
            }
        }
    }

    /// Preview audio volume change live (no undo entry). Call setAudioVolume on gesture end.
    public func previewAudioVolume(segmentID: UUID, volume: Double) {
        timeline.updateSegment(id: segmentID) { seg in
            guard case .audio(var c) = seg.content else { return }
            c.volume = max(0, min(volume, 2.0))
            seg.content = .audio(c)
        }
        coordinator?.applyAudioMixOnly(timeline: timeline)
    }

    /// Audio-segment playback speed range (audio-feature-spec §8.3).
    public static let audioSpeedRange: ClosedRange<Double> = 0.3 ... 3.0

    /// Live preview during slider drag (no undo, debounced rebuild via compositionVersion).
    /// Updates EditorSegment.speed AND targetRange.duration in lock-step so the timeline
    /// block width tracks the new clock-time duration immediately.
    public func previewAudioSpeed(segmentID: UUID, speed: Double) {
        let newSpeed = min(max(speed, Self.audioSpeedRange.lowerBound), Self.audioSpeedRange.upperBound)
        timeline.updateSegment(id: segmentID) { seg in
            guard case .audio = seg.content else { return }
            let oldSpeed  = max(seg.speed, 0.001)
            let sourceDur = max(seg.targetRange.duration * oldSpeed, 0.05)
            seg.speed     = newSpeed
            seg.targetRange = TimeRange(
                start:    seg.targetRange.start,
                duration: max(sourceDur / newSpeed, 0.05)
            )
        }
        compositionVersion += 1
    }

    /// Commit speed change (undo-tracked, triggers full AVComposition rebuild because the
    /// segment's timeRange shifts — audioMix fast path is insufficient).
    public func setAudioSpeed(segmentID: UUID, speed: Double) {
        let newSpeed = min(max(speed, Self.audioSpeedRange.lowerBound), Self.audioSpeedRange.upperBound)
        mutate("调整音频速度") { tl in
            tl.updateSegment(id: segmentID) { seg in
                guard case .audio = seg.content else { return }
                let oldSpeed  = max(seg.speed, 0.001)
                let sourceDur = max(seg.targetRange.duration * oldSpeed, 0.05)
                seg.speed     = newSpeed
                seg.targetRange = TimeRange(
                    start:    seg.targetRange.start,
                    duration: max(sourceDur / newSpeed, 0.05)
                )
            }
        }
    }

    // MARK: - Color Adjustment Operations

    /// Live preview: update adjustment for the current frame without undo.
    /// Debounced rebuild fires 300 ms after the last call (slider drag coalesces).
    public func previewAdjustment(segmentID: UUID, adjustment: SegmentAdjustment) {
        timeline.updateSegment(id: segmentID) { $0.adjustment = adjustment }
        compositionVersion += 1
    }

    /// Commit an adjustment change (undo-tracked, triggers rebuild).
    public func setAdjustment(segmentID: UUID, adjustment: SegmentAdjustment) {
        mutate("调色") { tl in tl.updateSegment(id: segmentID) { $0.adjustment = adjustment } }
    }

    /// Reset a segment's adjustment to identity (undo-tracked).
    public func resetAdjustment(segmentID: UUID) {
        mutate("重置调色") { tl in tl.updateSegment(id: segmentID) { $0.adjustment = .identity } }
    }

    // MARK: - Clip Animation (V7)

    /// Live preview during picker interaction — no undo, triggers render refresh.
    public func previewClipAnimation(segmentID: UUID, animation: ClipAnimation) {
        timeline.updateSegment(id: segmentID) { $0.setAnimation(animation) }
        compositionVersion += 1
    }

    /// Commit clip animation selection (undo-tracked, triggers rebuild).
    public func setClipAnimation(segmentID: UUID, animation: ClipAnimation) {
        mutate("设置动画") { tl in tl.updateSegment(id: segmentID) { $0.setAnimation(animation) } }
    }

    /// Remove clip animation for a given timing (undo-tracked, triggers rebuild).
    public func removeClipAnimation(segmentID: UUID, timing: AnimationTiming) {
        mutate("移除动画") { tl in tl.updateSegment(id: segmentID) { $0.removeAnimation(timing: timing) } }
    }

    // MARK: - Transition Operations (v2)

    /// Add a transition between two adjacent main-track segments (undo-tracked).
    @discardableResult
    public func addTransition(
        between leadingID: UUID,
        and trailingID: UUID,
        type: EditorTransition.TransitionType = .fade,
        duration: Double = 0.5
    ) -> EditorTransition? {
        var result: EditorTransition?
        mutate("添加转场") { tl in
            result = tl.addTransition(between: leadingID, and: trailingID, type: type, duration: duration)
        }
        return result
    }

    /// Remove a transition (undo-tracked).
    public func removeTransition(id: UUID) {
        mutate("删除转场") { tl in tl.removeTransition(id: id) }
    }

    /// Change a transition's duration (undo-tracked).
    public func updateTransitionDuration(id: UUID, duration: Double) {
        mutate("调整转场时长") { tl in tl.updateTransitionDuration(id: id, duration: duration) }
    }

    /// Change a transition's type (undo-tracked).
    public func updateTransitionType(id: UUID, type: EditorTransition.TransitionType) {
        mutate("切换转场类型") { tl in tl.updateTransitionType(id: id, type: type) }
    }

    // MARK: - Transition Operations (V7 presetID)

    /// V7: Add a transition by presetID (undo-tracked).
    @discardableResult
    public func addTransition(
        between leadingID: UUID,
        and trailingID: UUID,
        presetID: String,
        duration: Double = 0.5
    ) -> EditorTransition? {
        var result: EditorTransition?
        mutate("添加转场") { tl in
            result = tl.addTransition(between: leadingID, and: trailingID,
                                      presetID: presetID, duration: duration)
        }
        return result
    }

    /// V7: Update a transition's presetID (and optionally duration) in one undo step.
    public func updateTransitionPreset(id: UUID, presetID: String, duration: Double? = nil) {
        mutate("切换转场") { tl in tl.updateTransitionPreset(id: id, presetID: presetID, duration: duration) }
    }

    // MARK: - Asset Download / Cache

    /// Update the local cached path of an asset after download.
    ///
    /// This is NOT undo-tracked — it is a pure cache-pointer update that survives
    /// restarts. The mapping is persisted to the draft JSON via the existing
    /// DraftStore auto-save (compositionVersion is intentionally not incremented
    /// so no AVComposition rebuild is triggered).
    public func updateAssetLocalURL(assetID: UUID, url: URL) {
        guard timeline.materials[assetID] != nil else { return }
        timeline.materials[assetID]?.localURL = url
    }

    /// Download all assets that have a `remoteURL` but no valid `localURL` on disk.
    ///
    /// Runs concurrently (up to N tasks via task group). On completion each asset's
    /// `localURL` is written back into the timeline; DraftStore auto-save picks up
    /// the change within its next 5-second window, making the mapping persistent.
    ///
    /// Call this once after loading a timeline, e.g. in `ClipEditorView.onAppear`.
    public func prefetchRemoteAssets(timelineID: UUID) {
        let toFetch: [(UUID, URL)] = timeline.materials.all.compactMap { asset in
            if let local = asset.localURL,
               FileManager.default.fileExists(atPath: local.path) { return nil }
            guard let remote = asset.remoteURL else { return nil }
            return (asset.id, remote)
        }
        guard !toFetch.isEmpty else { return }

        Task { [weak self] in
            await withTaskGroup(of: (UUID, URL)?.self) { group in
                for (assetID, remoteURL) in toFetch {
                    group.addTask {
                        guard let local = try? await AssetDownloadManager.shared.localURL(
                            for: remoteURL, assetID: assetID, timelineID: timelineID
                        ) else { return nil }
                        return (assetID, local)
                    }
                }
                for await result in group {
                    guard let (assetID, local) = result else { continue }
                    await MainActor.run { [weak self] in
                        self?.updateAssetLocalURL(assetID: assetID, url: local)
                    }
                }
            }
        }
    }

    // MARK: - Private

    private struct UndoEntry {
        let label: String
        let snapshot: EditorTimeline
    }
}

// MARK: - SelectionState

public struct SelectionState: Sendable {
    public var selectedSegmentIDs: Set<UUID> = []
    public var focusedTrackID: UUID?
    public var playheadTime: Double = 0
    /// Segment currently showing its edit panel.
    public var editingSegmentID: UUID?
    /// Cut-point currently showing the transition sheet.
    public var editingTransitionContext: TransitionEditContext?

    public var hasSingleSelection: Bool { selectedSegmentIDs.count == 1 }
    public var singleSelectedID: UUID? {
        hasSingleSelection ? selectedSegmentIDs.first : nil
    }

    public mutating func selectOnly(_ id: UUID) {
        selectedSegmentIDs = [id]
        editingSegmentID = id
    }

    public mutating func deselect() {
        selectedSegmentIDs.removeAll()
        editingSegmentID = nil
    }
}

// MARK: - TransitionEditContext

/// Identifies the cut-point for which the transition sheet is open.
public struct TransitionEditContext: Sendable, Equatable {
    public let leadingID:  UUID
    public let trailingID: UUID
    /// Nil when the cut-point has no transition yet (add flow).
    public let existingTransition: EditorTransition?

    public init(leadingID: UUID, trailingID: UUID, existingTransition: EditorTransition?) {
        self.leadingID          = leadingID
        self.trailingID         = trailingID
        self.existingTransition = existingTransition
    }
}

// MARK: - SegmentContent accessor helper

extension SegmentContent {
    var textContent: TextContent? {
        if case .text(let c) = self { return c }
        return nil
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

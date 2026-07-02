import Foundation
import Observation
import AVFoundation
import CoreMedia
import TimelineKitCore
import TimelineKitRender

/// Observable store wrapping TimelineDocument with playback and coordination.
///
/// V8: Core mutation logic lives in `TimelineDocument` (TimelineKitCore).
/// EditorStore adds AVPlayer playback, CompositionCoordinator integration,
/// DraftStore persistence, and media import/export helpers.
@MainActor @Observable
public final class EditorStore: @MainActor Identifiable {
    
    public var id: UUID {
        document.id
    }

    // MARK: - Core document

    public let document: TimelineDocument

    /// Convenience accessor — mirrors `document.timeline`.
    public var timeline: EditorTimeline {
        get { document.timeline }
        set { document.timeline = newValue }
    }

    /// Convenience accessor — mirrors `document.selection`.
    public var selection: SelectionState {
        get { document.selection }
        set { document.selection = newValue }
    }

    /// Convenience accessor — mirrors `document.compositionVersion`.
    public var compositionVersion: Int { document.compositionVersion }

    // Convenience accessors for undo state
    public var canUndo: Bool { document.canUndo }
    public var canRedo: Bool { document.canRedo }
    public var lastUndoLabel: String? { document.lastUndoLabel }
    public var lastRedoLabel: String? { document.lastRedoLabel }
    public static let maxUndoDepth = TimelineDocument.maxUndoDepth

    // MARK: - Player

    @ObservationIgnored nonisolated(unsafe) public private(set) var player: AVPlayer?
    @ObservationIgnored nonisolated(unsafe) public var coordinatorPlayer: AVPlayer?
    public var isPlaying: Bool = false
    public var usesTimelineRuntime: Bool = false

#if canImport(UIKit)
    @ObservationIgnored nonisolated(unsafe) public weak var coordinator: (any TimelineCoordinatorProtocol)?
#endif

    @ObservationIgnored nonisolated(unsafe) private var playerTimeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var playerEndObserver: Any?
    private var activePlayer: AVPlayer? { coordinatorPlayer ?? player }

    // MARK: - Init

    public init(timeline: EditorTimeline, videoURL: URL? = nil) {
        self.document = TimelineDocument(timeline: timeline)
        // Wire coordinator callbacks
        document.onDidMutateSubtitle = { [weak self] tl in
#if canImport(UIKit)
            self?.coordinator?.refreshTimelineRuntimeTextLayers(timeline: tl)
#endif
        }
        if let url = videoURL { setupPlayer(url: url) }
    }

    deinit {
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
#if canImport(UIKit)
        coordinator?.setTimelineRuntimePlaybackActive(true)
#endif
        if p.currentTime().seconds >= timeline.duration - 0.05 {
#if canImport(UIKit)
            coordinator?.prepareTimelineRuntimeForSeek(to: .zero)
#endif
            p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            DispatchQueue.main.async {
#if canImport(UIKit)
                self.coordinator?.renderFrameAndFlush()
#endif
            }
        }
        p.play(); isPlaying = true
    }

    public func pause() {
        activePlayer?.pause(); isPlaying = false
#if canImport(UIKit)
        coordinator?.setTimelineRuntimePlaybackActive(false)
#endif
    }

    public func seek(to time: Double) {
        let clamped = max(0, min(time, timeline.duration))
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
#if canImport(UIKit)
        coordinator?.setTimelineRuntimePlaybackActive(isPlaying)
        coordinator?.prepareTimelineRuntimeForSeek(to: cmTime)
#endif
        activePlayer?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
#if canImport(UIKit)
                self?.coordinator?.renderFrameAndFlush()
#endif
            }
        }
        selection.playheadTime = clamped
    }

#if DEBUG
    private func formatDebugTime(_ time: CMTime?) -> String {
        guard let time, time.isValid else { return "invalid" }; return formatDebugSeconds(time.seconds)
    }
    private func formatDebugSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return String(describing: seconds) }; return String(format: "%.4f", seconds)
    }
#endif

    private func setupPlayer(url: URL) {
        let item = AVPlayerItem(url: url); let p = AVPlayer(playerItem: item); p.actionAtItemEnd = .pause; self.player = p
        let interval = CMTime(value: 1, timescale: 30)
        playerTimeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { guard let self, self.isPlaying else { return }; self.selection.playheadTime = time.seconds }
        }
        playerEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    // MARK: - Mutation (delegated to document)

    public func mutate(_ label: String, _ body: (inout EditorTimeline) -> Void) { document.mutate(label, body) }
    public func mutateSubtitle(_ label: String, _ body: (inout EditorTimeline) -> Void) { document.mutateSubtitle(label, body) }
    public func undo() { document.undo() }
    public func redo() { document.redo() }

    // MARK: - Common Operations

    public func deleteSegment(id: UUID) { document.deleteSegment(id: id) }
    @discardableResult public func splitSegment(id: UUID, at time: Double) -> UUID? { document.splitSegment(id: id, at: time) }
    public func copySegment(id: UUID) { document.copySegment(id: id) }
    public func pasteSegment(after anchorID: UUID? = nil) { document.pasteSegment(after: anchorID) }
    public var hasClipboardSegment: Bool { document.hasClipboardSegment }
    public func trimSegment(id: UUID, newTargetRange: TimeRange, newSourceRangeStart: Double? = nil) { document.trimSegment(id: id, newTargetRange: newTargetRange, newSourceRangeStart: newSourceRangeStart) }
    public func moveSegment(id: UUID, to newStart: Double) { document.moveSegment(id: id, to: newStart) }
    public func reorderSegments(trackID: UUID, newOrder: [UUID]) { document.reorderSegments(trackID: trackID, newOrder: newOrder) }
    public func previewTrimRange(segmentID: UUID, range: TimeRange) { document.previewTrimRange(segmentID: segmentID, range: range) }

    // MARK: - Text/Subtitle

    public func mutateTextContent(segmentID: UUID, label: String = "编辑文字", _ modify: (inout SegmentContent.TextContent) -> Void) { document.mutateTextContent(segmentID: segmentID, label: label, modify) }
    public func mutateTextStyle(segmentID: UUID, label: String = "修改样式", _ modify: (inout TextStyle) -> Void) { document.mutateTextStyle(segmentID: segmentID, label: label, modify) }
    public func updateTextContent(segmentID: UUID, text: String) { document.updateTextContent(segmentID: segmentID, text: text) }
    public func updateTextPosition(segmentID: UUID, position: NormalizedPoint) { document.updateTextPosition(segmentID: segmentID, position: position) }
    public func updateSubtitlePosition(segmentID: UUID, positionY: Double) { document.updateSubtitlePosition(segmentID: segmentID, positionY: positionY) }
    public func updateTextStyle(segmentID: UUID, style: TextStyle) { document.updateTextStyle(segmentID: segmentID, style: style) }
    public func mutateSubtitleContent(segmentID: UUID, label: String = "编辑字幕", _ modify: (inout SegmentContent.SubtitleContent) -> Void) { document.mutateSubtitleContent(segmentID: segmentID, label: label, modify) }
    public func mutateSubtitleStyle(segmentID: UUID, label: String = "修改字幕样式", _ modify: (inout TextStyle) -> Void) { document.mutateSubtitleStyle(segmentID: segmentID, label: label, modify) }

    // MARK: - Live preview with coordinator

    public func previewFontSize(segmentID: UUID, fontSize: Double) {
        timeline.updateSegment(id: segmentID) { seg in
            guard case .text(var c) = seg.content else { return }; c.style.fontSize = fontSize; seg.content = .text(c)
        }
#if canImport(UIKit)
        coordinator?.refreshTimelineRuntimeTextLayers(timeline: timeline)
#endif
    }

    public func previewTextPosition(segmentID: UUID, position: NormalizedPoint) {
        timeline.updateSegment(id: segmentID) { seg in
            guard case .text(var c) = seg.content else { return }; c.position = position; seg.content = .text(c)
        }
#if canImport(UIKit)
        coordinator?.refreshTimelineRuntimeTextLayers(timeline: timeline)
#endif
    }

    public func previewSubtitleText(segmentID: UUID, text: String) {
        timeline.updateSegment(id: segmentID) { seg in
            guard case .subtitle(var c) = seg.content else { return }; c.text = text; seg.content = .subtitle(c)
        }
#if canImport(UIKit)
        coordinator?.refreshTimelineRuntimeTextLayers(timeline: timeline)
#endif
    }

    public func previewSubtitlePosition(segmentID: UUID, positionY: Double) {
        document.previewSubtitlePosition(segmentID: segmentID, positionY: positionY)
#if canImport(UIKit)
        coordinator?.refreshTimelineRuntimeTextLayers(timeline: timeline)
#endif
    }

    // MARK: - Style Preset

    public typealias StylePreset = TimelineDocument.StylePreset
    public func applyStylePreset(segmentID: UUID, preset: StylePreset?) { document.applyStylePreset(segmentID: segmentID, preset: preset) }
    @discardableResult public func applyStyleToTrackSegmentsOfKind(trackID: UUID, sourceSegmentID: UUID, includePositionFields: Bool = false) -> Int { document.applyStyleToTrackSegmentsOfKind(trackID: trackID, sourceSegmentID: sourceSegmentID, includePositionFields: includePositionFields) }
    public func setTextAlignment(segmentID: UUID, alignment: TextAlignment) { document.setTextAlignment(segmentID: segmentID, alignment: alignment) }
    public func copyStyle(segmentID: UUID) { document.copyStyle(segmentID: segmentID) }
    public func canPasteStyle(toSegmentID segmentID: UUID) -> Bool { document.canPasteStyle(toSegmentID: segmentID) }
    public func pasteStyle(segmentID: UUID) { document.pasteStyle(segmentID: segmentID) }

    // MARK: - Z-Order

    public func bringSegmentToFront(segmentID: UUID) { document.bringSegmentToFront(segmentID: segmentID) }
    public func sendSegmentToBack(segmentID: UUID) { document.sendSegmentToBack(segmentID: segmentID) }
    public func bringSegmentForward(segmentID: UUID) { document.bringSegmentForward(segmentID: segmentID) }
    public func sendSegmentBackward(segmentID: UUID) { document.sendSegmentBackward(segmentID: segmentID) }

    // MARK: - Track Management

    @discardableResult public func addTrack(kind: EditorTrack.Kind, label: String = "", zPosition: Int? = nil, pendingUserCreated: Bool = false) -> UUID? { document.addTrack(kind: kind, label: label, zPosition: zPosition, pendingUserCreated: pendingUserCreated) }
    public func addSegment(toTrack trackID: UUID, segment: EditorSegment) { document.addSegment(toTrack: trackID, segment: segment) }
    @discardableResult public func addSegmentAutoTrack(kind: EditorTrack.Kind, segment: EditorSegment) -> UUID? { document.addSegmentAutoTrack(kind: kind, segment: segment) }
    public func removeTrackIfEmpty(id: UUID) { document.removeTrackIfEmpty(id: id) }
    public func setTrackLocked(id: UUID, isLocked: Bool) { document.setTrackLocked(id: id, isLocked: isLocked) }
    public func setTrackHidden(id: UUID, isHidden: Bool) {
        guard let track = timeline.track(id: id), !track.isMainTrack else { return }
        document.setTrackHidden(id: id, isHidden: isHidden)
        if track.kind == .audio {
#if canImport(UIKit)
            coordinator?.applyAudioMixOnly(timeline: timeline)
#endif
        }
    }

    // MARK: - Adjustments / Animation / Audio

    public func previewAdjustment(segmentID: UUID, adjustment: SegmentAdjustment) { document.previewAdjustment(segmentID: segmentID, adjustment: adjustment) }
    public func setAdjustment(segmentID: UUID, adjustment: SegmentAdjustment) { document.setAdjustment(segmentID: segmentID, adjustment: adjustment) }
    public func resetAdjustment(segmentID: UUID) { document.resetAdjustment(segmentID: segmentID) }
    public func previewClipAnimation(segmentID: UUID, animation: ClipAnimation) { document.previewClipAnimation(segmentID: segmentID, animation: animation) }
    public func setClipAnimation(segmentID: UUID, animation: ClipAnimation) { document.setClipAnimation(segmentID: segmentID, animation: animation) }
    public func removeClipAnimation(segmentID: UUID, timing: AnimationTiming) { document.removeClipAnimation(segmentID: segmentID, timing: timing) }
    public func applyImageAnimation(segmentID: UUID, preset: ImageAnimationPreset) { document.applyImageAnimation(segmentID: segmentID, preset: preset) }

    // Audio
    public func muteTrack(id: UUID, isMuted: Bool) {
        document.muteTrack(id: id, isMuted: isMuted)
#if canImport(UIKit)
        coordinator?.applyAudioMixOnly(timeline: timeline)
#endif
    }
    public func setAudioVolume(segmentID: UUID, volume: Double) {
        document.setAudioVolume(segmentID: segmentID, volume: volume)
#if canImport(UIKit)
        coordinator?.applyAudioMixOnly(timeline: timeline)
#endif
    }
    public func mutateAudioFade(segmentID: UUID, fadeIn: Double, fadeOut: Double) {
        document.mutateAudioFade(segmentID: segmentID, fadeIn: fadeIn, fadeOut: fadeOut)
#if canImport(UIKit)
        coordinator?.applyAudioMixOnly(timeline: timeline)
#endif
    }
    public func muteAudioSegment(id: UUID, isMuted: Bool) {
        document.muteAudioSegment(id: id, isMuted: isMuted)
#if canImport(UIKit)
        coordinator?.applyAudioMixOnly(timeline: timeline)
#endif
    }
    public func setVideoMuted(segmentID: UUID, isMuted: Bool) { document.setVideoMuted(segmentID: segmentID, isMuted: isMuted) }
    public func setAudioSpeed(segmentID: UUID, speed: Double) { document.setAudioSpeed(segmentID: segmentID, speed: speed) }
    public static let audioSpeedRange: ClosedRange<Double> = TimelineDocument.audioSpeedRange

    public func previewAudioVolume(segmentID: UUID, volume: Double) {
        timeline.updateSegment(id: segmentID) { seg in
            guard case .audio(var c) = seg.content else { return }; c.volume = max(0, min(volume, 2.0)); seg.content = .audio(c)
        }
#if canImport(UIKit)
        coordinator?.applyAudioMixOnly(timeline: timeline)
#endif
    }

    public func previewAudioSpeed(segmentID: UUID, speed: Double) {
        let newSpeed = min(max(speed, Self.audioSpeedRange.lowerBound), Self.audioSpeedRange.upperBound)
        timeline.updateSegment(id: segmentID) { seg in
            guard case .audio = seg.content else { return }
            let oldSpeed = max(seg.speed, 0.001); let sourceDur = max(seg.targetRange.duration * oldSpeed, 0.05)
            seg.speed = newSpeed; seg.targetRange = TimeRange(start: seg.targetRange.start, duration: max(sourceDur / newSpeed, 0.05))
        }
        document.bumpCompositionVersion()
    }

    // MARK: - Transitions

    @discardableResult public func addTransition(between leadingID: UUID, and trailingID: UUID, type: EditorTransition.TransitionType = .fade, duration: Double = 0.5) -> EditorTransition? { document.addTransition(between: leadingID, and: trailingID, type: type, duration: duration) }
    @discardableResult public func addTransition(between leadingID: UUID, and trailingID: UUID, presetID: String, duration: Double = 0.5) -> EditorTransition? { document.addTransition(between: leadingID, and: trailingID, presetID: presetID, duration: duration) }
    public func removeTransition(id: UUID) { document.removeTransition(id: id) }
    public func updateTransitionDuration(id: UUID, duration: Double) { document.updateTransitionDuration(id: id, duration: duration) }
    public func updateTransitionType(id: UUID, type: EditorTransition.TransitionType) { document.updateTransitionType(id: id, type: type) }
    public func updateTransitionPreset(id: UUID, presetID: String, duration: Double? = nil) { document.updateTransitionPreset(id: id, presetID: presetID, duration: duration) }

    // MARK: - Material Replacement

    public func replaceSegmentMaterial(segmentID: UUID, localURL: URL, nativeDuration: Double?, clipInTime: Double? = nil) {
#if canImport(UIKit)
        if let seg = timeline.segment(id: segmentID), let oldURL = timeline.materials[seg.materialID]?.bestURL {
            Task { await ThumbnailProvider.shared.removeCache(for: oldURL) }
        }
#endif
        document.replaceSegmentMaterial(segmentID: segmentID, localURL: localURL, nativeDuration: nativeDuration, clipInTime: clipInTime)
    }

    // MARK: - Media Import

    @discardableResult public func addVisualSegment(localURL: URL, nativeDuration: Double?, targetTrackID: UUID? = nil) -> UUID? {
        let segmentID = UUID(); let playheadTime = selection.playheadTime
        mutate("添加素材") { tl in
            let trackIndex: Int?
            if let targetTrackID { trackIndex = tl.tracks.firstIndex { $0.id == targetTrackID && !$0.isMainTrack && $0.kind == .overlay } }
            else { trackIndex = tl.tracks.firstIndex(where: { $0.isMainTrack }) }
            guard let ti = trackIndex else { return }
            let materialID = UUID(); let isVideo = nativeDuration != nil
            let asset = EditorAsset(id: materialID, type: isVideo ? .video : .image, localURL: localURL, nativeDuration: nativeDuration)
            tl.materials[materialID] = asset
            let insertStart = targetTrackID == nil ? (tl.tracks[ti].segments.last?.targetRange.end ?? 0) : playheadTime
            let dur = nativeDuration ?? 3.0
            let segment = EditorSegment(id: segmentID, materialID: materialID, sourceRange: isVideo ? TimeRange(start: 0, duration: dur) : nil, targetRange: TimeRange(start: insertStart, duration: dur), speed: 1.0, content: isVideo ? .video(SegmentContent.VideoContent()) : .image(SegmentContent.ImageContent()))
            tl.tracks[ti].insert(segment); if tl.tracks[ti].pendingUserCreated { tl.tracks[ti].pendingUserCreated = false }
        }
        if timeline.segment(id: segmentID) != nil {
            if let targetTrackID { document.cancelPendingCleanup(for: targetTrackID) }
            if targetTrackID != nil { selection.selectOnly(segmentID) }
            return segmentID
        }
        return nil
    }

    @discardableResult public func addAudioSegment(localURL: URL, nativeDuration: Double, startTime: Double? = nil, targetTrackID: UUID? = nil, ttsSource: SegmentContent.TTSSource? = nil) -> UUID? {
        let assetID = UUID(); let asset = EditorAsset(id: assetID, type: .audio, localURL: localURL, nativeDuration: nativeDuration)
        let segmentID = UUID()
        let segment = EditorSegment(id: segmentID, materialID: assetID, sourceRange: TimeRange(start: 0, duration: nativeDuration), targetRange: TimeRange(start: startTime ?? selection.playheadTime, duration: nativeDuration), content: .audio(SegmentContent.AudioContent(volume: 1.0, ttsSource: ttsSource)))
        timeline.materials.add(asset)
        let hostTrackID: UUID?
        if let targetTrackID, timeline.track(id: targetTrackID)?.kind == .audio { addSegment(toTrack: targetTrackID, segment: segment); hostTrackID = targetTrackID }
        else { hostTrackID = addSegmentAutoTrack(kind: .audio, segment: segment) }
        guard hostTrackID != nil else { timeline.materials.remove(id: assetID); return nil }
        return segmentID
    }

    public func normalizeAudioDurations() async {
        var changedSegments: [(UUID, TimeRange)] = []
        for track in timeline.tracks where track.kind == .audio && !track.isHidden {
            for seg in track.segments {
                guard case .audio(let content) = seg.content, !content.isLooping else { continue }
                guard let asset = timeline.materials[seg.materialID], let url = asset.bestURL else { continue }
                let avAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                let audioDur: Double
                do { let cmDur = try await avAsset.load(.duration); audioDur = cmDur.seconds } catch { continue }
                guard audioDur > 0, audioDur.isFinite else { continue }
                let srcStart = seg.sourceRange?.start ?? 0; let maxAllowed = max(0.1, audioDur - srcStart)
                if seg.targetRange.duration > maxAllowed + 0.05 {
                    changedSegments.append((seg.id, TimeRange(start: seg.targetRange.start, duration: maxAllowed)))
                }
            }
        }
        guard !changedSegments.isEmpty else { return }
        for (id, newRange) in changedSegments {
            timeline.updateSegment(id: id) { seg in
                seg.targetRange = newRange
                if var sr = seg.sourceRange { sr.duration = newRange.duration; seg.sourceRange = sr }
                else { seg.sourceRange = TimeRange(start: 0, duration: newRange.duration) }
            }
        }
        document.bumpCompositionVersion()
    }

    // MARK: - Detach Audio

    public enum DetachAudioError: Swift.Error, LocalizedError {
        case notVideoSegment, assetURLMissing
        public var errorDescription: String? {
            switch self { case .notVideoSegment: return "请选择视频片段"; case .assetURLMissing: return "视频素材不可用" }
        }
    }

    @discardableResult
    public func detachAudio(fromVideoSegmentID id: UUID) async throws -> UUID {
        guard let seg = timeline.segment(id: id), case .video = seg.content else { throw DetachAudioError.notVideoSegment }
        guard let videoAsset = timeline.materials[seg.materialID] else { throw DetachAudioError.assetURLMissing }
        let timelineID = timeline.id
        let videoLocalURL: URL
        if let local = videoAsset.localURL, FileManager.default.fileExists(atPath: local.path) { videoLocalURL = local }
        else if let remote = videoAsset.remoteURL { videoLocalURL = try await AssetDownloadManager.shared.localURL(for: remote, assetID: videoAsset.id, timelineID: timelineID); updateAssetLocalURL(assetID: videoAsset.id, url: videoLocalURL) }
        else { throw DetachAudioError.assetURLMissing }
        let extractedAssetID = UUID(); let outputURL = try AssetDownloadManager.shared.reserveLocalURL(assetID: extractedAssetID, extension: "m4a", timelineID: timelineID)
        let extractedDuration = try await AudioExtractor.shared.extract(from: videoLocalURL, to: outputURL)
        let audioAsset = EditorAsset(id: extractedAssetID, type: .audio, localURL: outputURL, nativeDuration: extractedDuration)
        let audioSegmentID = UUID()
        let audioSourceStart = seg.sourceRange?.start ?? 0
        let audioSourceDur = seg.sourceRange?.duration ?? seg.targetRange.duration
        let audioSegment = EditorSegment(id: audioSegmentID, materialID: extractedAssetID, sourceRange: TimeRange(start: audioSourceStart, duration: audioSourceDur), targetRange: seg.targetRange, content: .audio(SegmentContent.AudioContent(volume: 1.0)))
        mutate("分离音视频") { tl in
            tl.materials.add(audioAsset)
            Self.allocateAudioTrackInline(in: &tl, segment: audioSegment)
            tl.updateSegment(id: id) { v in guard case .video(var c) = v.content else { return }; c.isMuted = true; v.content = .video(c) }
        }
        return audioSegmentID
    }

    private static func allocateAudioTrackInline(in tl: inout EditorTimeline, segment: EditorSegment) -> UUID {
        let candidates = tl.tracks.filter { $0.kind == .audio }.sorted { ($0.zPosition, $0.id.uuidString) < ($1.zPosition, $1.id.uuidString) }
        if let reusable = candidates.first(where: { !$0.segments.contains { $0.targetRange.overlaps(segment.targetRange) } }) {
            if let idx = tl.tracks.firstIndex(where: { $0.id == reusable.id }) { tl.tracks[idx].segments.append(segment) }; return reusable.id
        }
        let existing = tl.tracks.filter { $0.kind == .audio }
        let resolvedZ = existing.isEmpty ? TimelineDocument.defaultZPosition(for: .audio) : (existing.map(\.zPosition).max() ?? 0) + 1
        let label = "\(TimelineDocument.displayName(for: .audio)) \(existing.count + 1)"
        let newTrack = EditorTrack(id: UUID(), kind: .audio, label: label, zPosition: resolvedZ, segments: [segment], isMainTrack: false)
        tl.tracks.append(newTrack); return newTrack.id
    }

    // MARK: - TTS

    public var ttsConfigSheetTargets: [UUID]? = nil
    public var lastTTSVoice: TTSService.VoiceKind {
        get { UserDefaults.standard.string(forKey: "TimelineKit.tts.lastVoice").flatMap(TTSService.VoiceKind.init(rawValue:)) ?? .female }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "TimelineKit.tts.lastVoice") }
    }
    public var lastTTSRate: Double {
        get { let v = UserDefaults.standard.double(forKey: "TimelineKit.tts.lastRate"); return (v >= 0.5 && v <= 2.0) ? v : 1.0 }
        set { UserDefaults.standard.set(newValue, forKey: "TimelineKit.tts.lastRate") }
    }

    public func regenerateTTS(forSourceSegment sourceID: UUID, voice: TTSService.VoiceKind, rate: Double) async throws { try await regenerateTTS(forSourceSegments: [sourceID], voice: voice, rate: rate) }

    public func regenerateTTS(forSourceSegments sourceIDs: [UUID], voice: TTSService.VoiceKind, rate: Double) async throws {
        struct Job { let sourceID: UUID; let text: String; let targetStart: Double; let voiceID: String; let rate: Double; let textHash: String }
        let voiceID = voice.resolveSystemVoice()?.identifier ?? AVSpeechSynthesisVoice(language: "zh-CN")?.identifier ?? ""
        let jobs: [Job] = sourceIDs.compactMap { id -> Job? in
            guard let seg = timeline.segment(id: id) else { return nil }
            let text: String; switch seg.content { case .text(let c): text = c.text; case .subtitle(let c): text = c.text; default: return nil }
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !normalized.isEmpty else { return nil }
            return Job(sourceID: id, text: text, targetStart: seg.targetRange.start, voiceID: voiceID, rate: rate, textHash: TTSService.textHash(text))
        }
        guard !jobs.isEmpty else { return }
        var results: [(job: Job, url: URL, duration: Double)] = []
        for job in jobs { let (url, dur) = try await TTSService.shared.synthesize(text: job.text, voice: job.voiceID, rate: job.rate); results.append((job, url, dur)) }
        mutate("生成配音") { tl in
            for (job, _, _) in results {
                for ti in tl.tracks.indices {
                    tl.tracks[ti].segments.removeAll { seg in
                        if case .audio(let c) = seg.content, let src = c.ttsSource, src.sourceSegmentID == job.sourceID { return true }; return false
                    }
                }
            }
        }
        for (job, url, dur) in results {
            _ = addAudioSegment(localURL: url, nativeDuration: dur, startTime: job.targetStart, ttsSource: SegmentContent.TTSSource(sourceSegmentID: job.sourceID, textHash: job.textHash, voice: job.voiceID, rate: job.rate))
        }
        lastTTSVoice = voice; lastTTSRate = rate
    }

    public func regenerateAllTTS(voice: TTSService.VoiceKind, rate: Double) async throws {
        let sourceIDs = timeline.tracks.flatMap { $0.segments }.compactMap { seg -> UUID? in
            switch seg.content { case .text, .subtitle: return seg.id; default: return nil }
        }
        try await regenerateTTS(forSourceSegments: sourceIDs, voice: voice, rate: rate)
    }

    /// Hook for TTS text-change detection. Set by umbrella extension.
    public var onTextDidChange: ((_ sourceSegmentID: UUID, _ newText: String) -> Void)?

    // MARK: - Text Segment Creation

    @discardableResult public func createNewTextSegment(defaultText: String = "点击编辑文本", defaultDuration: Double = 3.0, targetTrackID: UUID? = nil) -> UUID? {
        let placeholderAssetID = UUID(); let placeholderAsset = EditorAsset(id: placeholderAssetID, type: .placeholder)
        let segmentID = UUID()
        let segment = EditorSegment(id: segmentID, materialID: placeholderAssetID, sourceRange: nil, targetRange: TimeRange(start: selection.playheadTime, duration: defaultDuration), content: .text(SegmentContent.TextContent(text: defaultText, style: .default, position: .center, anchor: .center)))
        timeline.materials.add(placeholderAsset)
        let hostTrackID: UUID?
        if let targetTrackID, timeline.track(id: targetTrackID)?.kind == .text { addSegment(toTrack: targetTrackID, segment: segment); hostTrackID = targetTrackID }
        else { hostTrackID = addSegmentAutoTrack(kind: .text, segment: segment) }
        guard hostTrackID != nil else { timeline.materials.remove(id: placeholderAssetID); return nil }
        selection.selectOnly(segmentID); return segmentID
    }

    @discardableResult public func createNewSubtitleSegment(defaultText: String = "点击编辑字幕", defaultDuration: Double = 3.0, targetTrackID: UUID? = nil) -> UUID? {
        let placeholderAssetID = UUID(); let placeholderAsset = EditorAsset(id: placeholderAssetID, type: .placeholder)
        let segmentID = UUID()
        let segment = EditorSegment(id: segmentID, materialID: placeholderAssetID, sourceRange: nil, targetRange: TimeRange(start: selection.playheadTime, duration: defaultDuration), content: .subtitle(SegmentContent.SubtitleContent(text: defaultText, style: .default)))
        timeline.materials.add(placeholderAsset)
        let hostTrackID: UUID?
        if let targetTrackID, timeline.track(id: targetTrackID)?.kind == .subtitle { addSegment(toTrack: targetTrackID, segment: segment); hostTrackID = targetTrackID }
        else { hostTrackID = addSegmentAutoTrack(kind: .subtitle, segment: segment) }
        guard hostTrackID != nil else { timeline.materials.remove(id: placeholderAssetID); return nil }
        selection.selectOnly(segmentID); return segmentID
    }

    // MARK: - Export Config

    public func mutateExportConfig(_ body: (inout ExportConfig) -> Void) {
        document.mutateExportConfig(body); DraftStore.save(timeline)
    }

    public func resetExportConfigToDefault() {
        document.resetExportConfigToDefault(); DraftStore.save(timeline)
    }

    // MARK: - Asset Cache

    public func updateAssetLocalURL(assetID: UUID, url: URL) {
        guard timeline.materials[assetID] != nil else { return }; timeline.materials[assetID]?.localURL = url
    }

    public func prefetchRemoteAssets(timelineID: UUID) {
        let toFetch: [(UUID, URL)] = timeline.materials.all.compactMap { asset in
            if let local = asset.localURL, FileManager.default.fileExists(atPath: local.path) { return nil }
            guard let remote = asset.remoteURL else { return nil }; return (asset.id, remote)
        }
        guard !toFetch.isEmpty else { return }
        Task { [weak self] in
            await withTaskGroup(of: (UUID, URL)?.self) { group in
                for (assetID, remoteURL) in toFetch {
                    group.addTask {
                        guard let local = try? await AssetDownloadManager.shared.localURL(for: remoteURL, assetID: assetID, timelineID: timelineID) else { return nil }
                        return (assetID, local)
                    }
                }
                for await result in group {
                    guard let (assetID, local) = result else { continue }
                    await MainActor.run { [weak self] in self?.updateAssetLocalURL(assetID: assetID, url: local) }
                }
            }
        }
    }
}

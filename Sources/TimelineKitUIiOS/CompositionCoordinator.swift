import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
#if canImport(UIKit)
import AVFoundation
import CoreMedia
import UIKit

/// Owns the AVPlayer for the clip editor and keeps it in sync with EditorTimeline.
///
/// Lifecycle:
///   1. ClipEditorView creates a coordinator and calls `start(with store:)`.
///   2. On every timeline change the view calls `scheduleRebuild(timeline:)`.
///   3. The coordinator debounces 300 ms, rebuilds in background, swaps the AVPlayerItem.
///
/// V6 P1 (Stage 1-2): When the main track is image-only, a `TimelineClock`
/// drives a `TimelineRenderer` at screen refresh rate, producing `CVPixelBuffer`
/// frames that are fed to `timelinePreviewView` — bypassing AVVideoCompositing
/// jitter and z-order issues entirely.
///
/// This object lives on MainActor; CompositionBuilder runs on its own background actor.
@MainActor @Observable
public final class CompositionCoordinator {

    // MARK: - Public state

    public private(set) var isRebuilding = false

    // MARK: - Timeline Runtime (V6 P1 — Stage 1-2)

    /// UIView (AVSampleBufferDisplayLayer) that displays Timeline Runtime frames.
    /// Shown by EditorPreviewView when `store.usesTimelineRuntime == true`.
    public let timelinePreviewView = TimelinePreviewView()

    // MARK: - Internal

    let player = AVPlayer()
    private let builder = CompositionBuilder()
    private weak var store: EditorStore?

    // Last-built composition + track map — used by applyAudioMixOnly fast path.
    @ObservationIgnored nonisolated(unsafe) private var lastComposition:  AVMutableComposition?
    @ObservationIgnored nonisolated(unsafe) private var lastAudioTrackMap:[UUID: CMPersistentTrackID] = [:]
    @ObservationIgnored nonisolated(unsafe) private var lastTotalDuration: CMTime = .zero

    // All must be nonisolated(unsafe) so deinit (which is nonisolated) can cancel/remove them.
    @ObservationIgnored nonisolated(unsafe) private var pendingTask:     Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var audioMixTask:    Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var timeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var endObserver:  Any?
    @ObservationIgnored nonisolated(unsafe) private var foregroundObserver: Any?

    // V6 P4: realtime CVPixelBuffer provider for preview video layers.
    private let videoFrameProvider = PreviewFrameProvider()

    // Timeline Runtime components (nil when using AVPlayer/AVVideoCompositing path).
    private var timelineClock:    TimelineClock?
    private var timelineRenderer: TimelineRenderer?
    // Guard against concurrent renders on the same display link tick.
    private var isRenderingFrame: Bool = false
    private var lastRenderTime: CMTime?
    private var lastEnqueuedTime: CMTime?
    private var pendingDeferredSeekRender: DispatchWorkItem?
    private var pendingDeferredSeekRenderTime: CMTime?
    private var lastPreparedSeekTime: CMTime?

    // MARK: - Init / teardown

    public init() {
        player.actionAtItemEnd = .pause
        setupPlayerObservers()
        setupForegroundObserver()
    }

    deinit {
        pendingTask?.cancel()
        audioMixTask?.cancel()
        if let obs = timeObserver { player.removeTimeObserver(obs) }
        if let obs = endObserver  { NotificationCenter.default.removeObserver(obs) }
        if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Attach to store

    /// Connect to an EditorStore.  Call once after creating the coordinator.
    func attach(to store: EditorStore) {
        self.store = store
    }

    // MARK: - Rebuild scheduling

    /// Schedule an asynchronous Composition rebuild.
    /// - Parameters:
    ///   - timeline: snapshot of the current EditorTimeline
    ///   - immediate: skip the 300 ms debounce (use for first build / track additions)
    func scheduleRebuild(timeline: EditorTimeline, immediate: Bool = false) {
        pendingTask?.cancel()
        let delay: UInt64 = immediate ? 0 : 300_000_000  // nanoseconds

        pendingTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            await self.rebuild(timeline: timeline)
        }
    }

    // MARK: - Audio-only fast path (mute / volume change)

    /// Replace only the audioMix on the current AVPlayerItem — no composition rebuild.
    /// Responds in < 100ms per spec A-03.
    public func applyAudioMixOnly(timeline: EditorTimeline) {
        guard let composition = lastComposition else {
            // No composition built yet — fall back to full rebuild.
            scheduleRebuild(timeline: timeline, immediate: true)
            return
        }
        let map      = lastAudioTrackMap
        let duration = lastTotalDuration

        audioMixTask?.cancel()
        audioMixTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let newMix = self.builder.buildAudioMixOnly(
                timeline:      timeline,
                composition:   composition,
                audioTrackMap: map,
                totalDuration: duration
            )
            guard !Task.isCancelled else { return }
            self.player.currentItem?.audioMix = newMix
        }
    }

    // MARK: - Private rebuild

    private func rebuild(timeline: EditorTimeline) async {
        isRebuilding = true
        defer { isRebuilding = false }

        do {
            // Compute gate flags before build — skipImageOverlays prevents
            // UnifiedCompositor from double-rendering image layers when
            // TimelineRuntime handles ALL visual output.
            //
            // P4.5: hasAnyVisual broadened from "mainTrack image/video only" to
            // "any non-hidden, non-empty track". This activates Timeline Runtime
            // for text-only, subtitle-only, overlay-only, and audio-only timelines
            // so the renderer can draw black-background + overlay layers even when
            // the main track has no video content.
            let hasAnyVisual = timeline.duration > 0
                && timeline.tracks.contains { !$0.isHidden && !$0.segments.isEmpty }
            let mainSegs = timeline.mainTrack?.segments ?? []
            let isImageOnly = !mainSegs.isEmpty && mainSegs.allSatisfy {
                if case .image = $0.content { return true }
                return false
            }

            let result = try await builder.build(from: timeline, skipImageOverlays: hasAnyVisual)
            guard !Task.isCancelled else { return }

            // Preserve playhead position across the swap
            let savedTime = player.currentTime()

            // Cache composition + map for applyAudioMixOnly fast path.
            lastComposition   = result.composition
            lastAudioTrackMap = result.audioTrackMap
            lastTotalDuration = result.totalDuration

            let item = AVPlayerItem(asset: result.composition)
            // V6 P2 Stage 4: image-only compositions have no video tracks.
            // Skip videoComposition to avoid AVFoundation validation warnings.
            if !result.composition.tracks(withMediaType: .video).isEmpty {
                item.videoComposition = result.videoComposition
            }
            item.audioMix         = result.audioMix

#if DEBUG
            let trackCount = result.composition.tracks(withMediaType: .video).count
            print("[CompositionCoordinator] replaceCurrentItem — video tracks: \(trackCount), duration: \(String(format: "%.2f", result.totalDuration.seconds))s")
#endif
            videoFrameProvider.invalidate()
            player.replaceCurrentItem(with: item)
            videoFrameProvider.prepare(for: item)
            videoFrameProvider.setPlaybackActive(store?.isPlaying == true)
            rebindEndObserver(to: item)

            // Restore position — savedTime is invalid before any item has loaded,
            // so only seek when we have a real timestamp.
            if savedTime.isValid && savedTime.seconds > 0 {
                player.seek(
                    to: savedTime,
                    toleranceBefore: .zero,
                    toleranceAfter:  CMTime(value: 1, timescale: 600),
                    completionHandler: { [weak self] _ in
                        // After seek completes the player's clock is at savedTime —
                        // re-render so the preview reflects the segment under the
                        // playhead (otherwise the initial-frame render below ran
                        // while player.currentTime() was still 0).
                        Task { @MainActor in
                            self?.renderFrameAndFlush()
                        }
                    }
                )
            }

            // Use the CURRENT isPlaying state (not one captured before the async build),
            // so a pause that happened during the rebuild is respected (Issue 1 fix).
            if store?.isPlaying == true { player.play() }

            // ── V6 P3: Timeline Runtime wiring ───────────────────────────────
            if hasAnyVisual {
                let canvasSize = CGSize(
                    width:  timeline.canvas.width,
                    height: timeline.canvas.height
                )
                // Set up video frame provider for VideoLayerComposer.
                videoFrameProvider.setCanvasSize(canvasSize)
                videoFrameProvider.onSourcePreloadComplete = { [weak self] in
                    self?.renderFrameAndFlush(force: true)
                }
                VideoLayerComposer.frameProvider = videoFrameProvider

                // Create renderer lazily; update on every rebuild.
                if timelineRenderer == nil {
                    timelineRenderer = TimelineRenderer()
                }
                timelineRenderer?.update(timeline: timeline, canvasSize: canvasSize)
                flushTimelineRuntimeDisplay()

                // Start clock lazily.
                if timelineClock == nil {
                    let clock = TimelineClock()
                    clock.onTick = { [weak self] in self?.onRenderTick() }
                    timelineClock = clock
                }
                timelineClock?.start()
                store?.usesTimelineRuntime = true

                // Render the initial frame so the preview isn't black on entry.
                renderFrameAndFlush()
#if DEBUG
                print("[CompositionCoordinator] ▶ Timeline Runtime active — visual timeline (imageOnly=\(isImageOnly))")
#endif
            } else {
                // No visual segments — stop the clock, hide the preview overlay.
                timelineClock?.stop()
                store?.usesTimelineRuntime = false
                videoFrameProvider.onSourcePreloadComplete = nil
                videoFrameProvider.invalidate()
#if DEBUG
                print("[CompositionCoordinator] ▶ AVPlayer path — no visual segments")
#endif
            }

        } catch {
            // Builder error (e.g. no tracks yet) — not fatal; leave current item as-is
#if DEBUG
            print("[CompositionCoordinator] rebuild error: \(error)")
#endif
        }
    }

    // MARK: - Render tick (Timeline Runtime)

    /// Called by `TimelineClock` on every display-link fire (main thread, ~60 fps).
    /// Reads the current player time, renders a frame, and feeds it to the preview view.
    private func onRenderTick() {
        guard !isRenderingFrame,
              let renderer = timelineRenderer else { return }

        // V6 P2 Fix: only render during active playback. Without this guard the
        // display link keeps firing after AVPlayerItemDidPlayToEndTime, enqueuing
        // black frames (from past-the-end times) that flood the display layer.
        guard store?.isPlaying == true else { return }
        videoFrameProvider.setPlaybackActive(true)

        let compositionTime = player.currentTime().seconds
        // Guard against invalid times (before first item loads or after timeline end).
        guard compositionTime >= 0 else { return }
        let cmTime = CMTime(seconds: compositionTime, preferredTimescale: 600)
//#if DEBUG
//        let itemDuration = player.currentItem?.duration.seconds ?? -1
//        print("[Tick] t=\(String(format: "%.3f", compositionTime)) playerRate=\(player.rate) itemDur=\(String(format: "%.3f", itemDuration))")
//#endif
        guard shouldRenderTick(at: cmTime) else { return }

        isRenderingFrame = true
        guard let pixelBuffer = renderer.renderFrame(at: compositionTime) else {
            isRenderingFrame = false
            return
        }

        enqueueTimelineRuntimeFrame(pixelBuffer, presentationTime: cmTime)
        isRenderingFrame = false
    }

    /// Render + display one frame at the current player time.
    /// Called on seek so the preview immediately reflects the new playhead position
    /// even when paused (CADisplayLink is guarded by isPlaying and won't fire).
    public func renderFrameAndFlush() {
        renderFrameAndFlush(force: false)
    }

    public func refreshTimelineRuntimeTextLayers(timeline: EditorTimeline) {
        guard store?.usesTimelineRuntime == true,
              let renderer = timelineRenderer
        else { return }
        renderer.refreshTextLayers(timeline: timeline)
        renderFrameAndFlush(force: true)
    }

    /// Release ownership of `VideoLayerComposer.frameProvider` and stop the
    /// editor render loop. Call when another consumer (e.g. fullscreen preview)
    /// is about to take over the singleton frame-provider slot — otherwise both
    /// the editor's render loop and the fullscreen's render loop compete for
    /// frames through the same global provider, producing freezes/black frames
    /// while the fullscreen warm-up runs.
    func suspendTimelineRuntime() {
        timelineClock?.stop()
        pendingDeferredSeekRender?.cancel()
        pendingDeferredSeekRender = nil
        pendingDeferredSeekRenderTime = nil
        if VideoLayerComposer.frameProvider === videoFrameProvider {
            VideoLayerComposer.frameProvider = nil
        }
        videoFrameProvider.setPlaybackActive(false)
    }

    /// Re-acquire the global provider and restart the render loop after a
    /// previous `suspendTimelineRuntime()` call. Idempotent.
    func resumeTimelineRuntime() {
        guard store?.usesTimelineRuntime == true,
              timelineRenderer != nil
        else { return }
        VideoLayerComposer.frameProvider = videoFrameProvider
        timelineClock?.start()
        renderFrameAndFlush(force: true)
    }

    private func handleAppDidBecomeActive() {
        guard store?.usesTimelineRuntime == true else { return }
#if DEBUG
        logRuntimeState("foreground-active-before-render")
#endif
        // AVSampleBufferDisplayLayer can lose its displayed sample while the app
        // is suspended. Replacing the current frame restores a paused preview
        // without waiting for play/seek to enqueue another sample.
        renderFrameAndFlush(force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
#if DEBUG
            self?.logRuntimeState("foreground-active-delayed-render")
#endif
            self?.renderFrameAndFlush(force: true)
        }
    }

    private func renderFrameAndFlush(force: Bool, retryCount: Int = 6) {
        guard let renderer = timelineRenderer else { return }
        videoFrameProvider.setPlaybackActive(store?.isPlaying == true || player.rate != 0)
        let compositionTime = player.currentTime().seconds
        guard compositionTime >= 0 else { return }

        let cmTime = CMTime(seconds: compositionTime, preferredTimescale: 600)
        if !force && isDuplicateFlushRender(at: cmTime) {
#if DEBUG
            print("[TimelineRuntime] render skipped duplicate force=\(force) t=\(formatDebugTime(cmTime)) \(timelinePreviewView.debugStateDescription)")
#endif
            return
        }
        guard let pixelBuffer = renderer.renderFrame(at: compositionTime) else {
            scheduleDeferredSeekRender(at: cmTime, retryCount: retryCount)
            return
        }
#if DEBUG
        print("[TimelineRuntime] render ok force=\(force) t=\(formatDebugTime(cmTime)) storeIsPlaying=\(store?.isPlaying ?? false) playerRate=\(player.rate) providerBound=\(VideoLayerComposer.frameProvider === videoFrameProvider) preview=\(timelinePreviewView.debugStateDescription)")
#endif
        replaceTimelineRuntimeFrame(pixelBuffer, presentationTime: cmTime)
    }

    public func prepareTimelineRuntimeForSeek(to time: CMTime) {
        if isDuplicatePreparedSeek(to: time) {
            return
        }
        lastPreparedSeekTime = time
        pendingDeferredSeekRender?.cancel()
        pendingDeferredSeekRender = nil
        pendingDeferredSeekRenderTime = nil
        let playbackActive = store?.isPlaying == true || player.rate != 0
        let activeSpecs = activeVideoSpecs(at: time)
        videoFrameProvider.seek(to: time, activeSpecs: activeSpecs, playbackActive: playbackActive)
        lastRenderTime = nil
        lastEnqueuedTime = nil
    }

    /// Returns the `VideoLayerSpec`s whose `timeRange` contains `time`.
    /// Used to drive a targeted pre-seek on the preview provider so the source
    /// player is already moving toward the target frame by the time the next
    /// `frame()` call arrives. Falls back to `[]` when no video segment is under
    /// the playhead (image-only / text-only / pure-audio span).
    private func activeVideoSpecs(at time: CMTime) -> [VideoLayerSpec] {
        guard let store, time.isValid, time.seconds >= 0 else { return [] }
        let timeline = store.timeline
        let canvasSize = CGSize(
            width:  CGFloat(timeline.canvas.width),
            height: CGFloat(timeline.canvas.height)
        )
        guard canvasSize.width > 0, canvasSize.height > 0 else { return [] }
        let specs = LayerResolver.videoSpecs(timeline: timeline, canvasSize: canvasSize)
        return specs.filter { time >= $0.timeRange.start && time < $0.timeRange.end }
    }

    public func setTimelineRuntimePlaybackActive(_ active: Bool) {
        videoFrameProvider.setPlaybackActive(active)
    }

    private func scheduleDeferredSeekRender(at time: CMTime, retryCount: Int) {
        guard retryCount > 0 else { return }
        if let pendingTime = pendingDeferredSeekRenderTime,
           pendingTime.isValid,
           time.isValid,
           abs(pendingTime.seconds - time.seconds) < 0.001 {
            return
        }

        pendingDeferredSeekRender?.cancel()
        pendingDeferredSeekRenderTime = time
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingDeferredSeekRender = nil
            self?.pendingDeferredSeekRenderTime = nil
            self?.renderFrameAndFlush(force: false, retryCount: retryCount - 1)
        }
        pendingDeferredSeekRender = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func flushTimelineRuntimeDisplay() {
        pendingDeferredSeekRender?.cancel()
        pendingDeferredSeekRender = nil
        pendingDeferredSeekRenderTime = nil
        timelinePreviewView.flush()
        lastRenderTime = nil
        lastEnqueuedTime = nil
        lastPreparedSeekTime = nil
    }

    private func replaceTimelineRuntimeFrame(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime
    ) {
        pendingDeferredSeekRender?.cancel()
        pendingDeferredSeekRender = nil
        pendingDeferredSeekRenderTime = nil
        timelinePreviewView.replace(with: pixelBuffer, presentationTime: presentationTime)
        lastRenderTime = presentationTime
        lastEnqueuedTime = presentationTime
    }

    private func isDuplicateFlushRender(at time: CMTime) -> Bool {
        guard let lastEnqueuedTime,
              lastEnqueuedTime.isValid,
              time.isValid
        else { return false }
        return abs(lastEnqueuedTime.seconds - time.seconds) < 0.001
    }

    private func isDuplicatePreparedSeek(to time: CMTime) -> Bool {
        guard let lastPreparedSeekTime,
              lastPreparedSeekTime.isValid,
              time.isValid
        else { return false }
        return abs(lastPreparedSeekTime.seconds - time.seconds) < 0.001
    }

    private func shouldRenderTick(at time: CMTime) -> Bool {
        guard let lastRenderTime,
              lastRenderTime.isValid,
              time.isValid
        else {
            lastRenderTime = time
            return true
        }

        guard abs(time.seconds - lastRenderTime.seconds) > 0.001 else {
            return false
        }
        self.lastRenderTime = time
        return true
    }

    private func enqueueTimelineRuntimeFrame(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime
    ) {
        if let lastEnqueuedTime,
           presentationTime.isValid,
           lastEnqueuedTime.isValid,
           presentationTime <= lastEnqueuedTime {
            return
        }
        timelinePreviewView.enqueue(pixelBuffer, presentationTime: presentationTime)
        lastEnqueuedTime = presentationTime
    }

    // MARK: - Player observers

    private func setupPlayerObservers() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            guard let self, self.store?.isPlaying == true else { return }
            self.store?.selection.playheadTime = time.seconds

            // Fallback end-of-playback detection. AVPlayerItemDidPlayToEndTime is
            // unreliable for image-only timelines anchored by a silent PCM track —
            // floating-point precision in the silent file's actual duration can
            // leave the player just shy of "ended", so endObserver never fires
            // and store.isPlaying / player.rate stay stuck at "playing".
            // Compare against the timeline's intended duration instead.
            let target = self.lastTotalDuration.seconds
            if target > 0,
               time.isValid,
               time.seconds >= target - 0.001 {
                self.player.pause()
                self.store?.isPlaying = false
            }
        }
        // endObserver 现在在 rebuild() 里每次 replaceCurrentItem 后重新绑定到新 item。
        // 旧实现用 object:nil 监听 system-wide didPlayToEndTime，会被
        // FullScreenPreviewController / VideoTrimSelectorSheet 等其他 AVPlayer 的
        // item 误触发 → 主预览还在播但 store.isPlaying 被错误设为 false →
        // 表现为「点击播放后状态变暂停，画面仍在播，时间线停止」。
    }

    private func setupForegroundObserver() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppDidBecomeActive()
            }
        }
    }

#if DEBUG
    private func logRuntimeState(_ reason: String) {
        let currentItemStatus = player.currentItem.map { String(describing: $0.status) } ?? "nil"
        let currentItemDuration = player.currentItem?.duration.seconds ?? .nan
//        print(
//            "[TimelineRuntime] \(reason) " +
//            "storeIsPlaying=\(store?.isPlaying ?? false) " +
//            "playerRate=\(player.rate) " +
//            "playerTime=\(formatDebugTime(player.currentTime())) " +
//            "itemStatus=\(currentItemStatus) " +
//            "itemDuration=\(formatDebugSeconds(currentItemDuration)) " +
//            "usesRuntime=\(store?.usesTimelineRuntime ?? false) " +
//            "rendererReady=\(timelineRenderer != nil) " +
//            "providerBound=\(VideoLayerComposer.frameProvider === videoFrameProvider) " +
//            "preview=\(timelinePreviewView.debugStateDescription) " +
//            "provider=\(videoFrameProvider.debugStateDescription)"
//        )
    }

    private func formatDebugTime(_ time: CMTime) -> String {
        guard time.isValid else { return "invalid" }
        return formatDebugSeconds(time.seconds)
    }

    private func formatDebugSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return String(describing: seconds) }
        return String(format: "%.4f", seconds)
    }
#endif

    /// 把 endObserver 绑定到当前 AVPlayerItem。
    /// rebuild() 每次 replaceCurrentItem 后调用——确保只监听本 player 的当前 item，
    /// 不会被其他 AVPlayer 的播完事件污染 store.isPlaying。
    private func rebindEndObserver(to item: AVPlayerItem) {
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object:  item,
            queue:   .main
        ) { [weak self] _ in
            self?.store?.isPlaying = false
        }
    }
}
#endif

// MARK: - TimelineCoordinatorProtocol conformance

#if canImport(UIKit)
extension CompositionCoordinator: TimelineCoordinatorProtocol {}
#endif

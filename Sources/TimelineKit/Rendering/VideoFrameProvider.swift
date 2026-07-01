import AVFoundation
import CoreImage
import CoreVideo

// MARK: - VideoFrameProviderProtocol

/// Decoded video frame handed to `VideoLayerComposer`.
///
/// `isCanvasFrame` is true when the frame already represents the current
/// composition canvas, such as a frame produced by `AVPlayerItemVideoOutput`
/// from the active player item. In that case `VideoLayerComposer` should not
/// re-apply source fit/segment transforms.
struct VideoFrameImage {
    let image: CIImage
    let isCanvasFrame: Bool
}

/// Pluggable frame source for video layers.
///
/// Preview and export intentionally use different implementations. Preview is
/// optimized for live playback/seek/replay behavior. Export must be
/// deterministic for a frame index/CMTime and should not inherit preview's
/// realtime cache/display assumptions.
protocol VideoFrameProviderProtocol: AnyObject {
    func setCanvasSize(_ size: CGSize)
    func setPlaybackActive(_ active: Bool)
    func preload(videoSpecs: [VideoLayerSpec])
    func prepare(for item: AVPlayerItem)
    func frame(for spec: VideoLayerSpec, at compositionTime: CMTime) -> VideoFrameImage?
    func seek(to time: CMTime)
    /// Seek hint that carries the timeline state — implementations can pre-seek
    /// per-source players to the target sourceTime *before* `frame()` is called,
    /// reducing seek-time black frames. `activeSpecs` is the set of
    /// `VideoLayerSpec`s whose `timeRange` contains `time`; an empty array means
    /// no video layer is under the playhead (image-only / text-only segment).
    func seek(to time: CMTime, activeSpecs: [VideoLayerSpec], playbackActive: Bool)
    func flush()
    func invalidate()
}

extension VideoFrameProviderProtocol {
    func setPlaybackActive(_ active: Bool) {}
    func preload(videoSpecs: [VideoLayerSpec]) {}
    func prepare(for item: AVPlayerItem) {}
    func seek(to time: CMTime) { flush() }
    func seek(to time: CMTime, activeSpecs: [VideoLayerSpec], playbackActive: Bool) {
        setPlaybackActive(playbackActive)
        seek(to: time)
    }
    func flush() {}
    func invalidate() { flush() }
}

// MARK: - ExportFrameProvider

/// Deterministic export/debug frame provider keyed by source asset URL.
///
/// Export is sequential and frame-index driven, so it uses `AVAssetReader`
/// instead of the realtime preview provider. Each timeline video segment owns an
/// independent reader cursor to avoid cross-layer/time-range interference.
public final class ExportFrameProvider {
    private enum SampleCopyResult {
        case sample(CMSampleBuffer, CVPixelBuffer)
        case end
        case timedOut
    }


    private struct ReaderKey: Hashable {
        let url: URL
        let timelineStart: Int64
        let timelineDuration: Int64
        let sourceStart: Int64

        init(spec: VideoLayerSpec) {
            url = spec.assetURL
            timelineStart = spec.timeRange.start.value
            timelineDuration = spec.timeRange.duration.value
            sourceStart = CMTime(seconds: spec.sourceStartTime, preferredTimescale: 600).value
        }
    }

    private final class ReaderState {
        let key: ReaderKey
        let asset: AVURLAsset
        var reader: AVAssetReader?
        var output: AVAssetReaderTrackOutput?
        var readerStartTime: CMTime = .invalid
        var readerEndTime: CMTime = .invalid
        var lastSampleBuffer: CMSampleBuffer?
        var lastFrame: (time: CMTime, buffer: CVPixelBuffer)?
        var pendingSampleBuffer: CMSampleBuffer?
        var pendingFrame: (time: CMTime, buffer: CVPixelBuffer)?
        var didReachEnd = false
        var lastLoggedRequestCount = 0

#if DEBUG
        var requestCount = 0
        var emittedCount = 0
        var reusedCount = 0
        var nilCount = 0
        var restartCount = 0
#endif

        init(key: ReaderKey) {
            self.key = key
            self.asset = AVURLAsset(url: key.url)
        }
    }

    nonisolated(unsafe) private var readers: [ReaderKey: ReaderState] = [:]
    nonisolated(unsafe) private let readersLock = NSLock()
    nonisolated(unsafe) private var canvasSize: CGSize = .zero

    public init() {}

    func setCanvasSize(_ size: CGSize) {
        guard size != canvasSize else { return }
        canvasSize = size
        flush()
    }
}

public typealias VideoFrameProvider = ExportFrameProvider

extension ExportFrameProvider: VideoFrameProviderProtocol {
    func preload(videoSpecs: [VideoLayerSpec]) {
        for spec in videoSpecs {
            let key = ReaderKey(spec: spec)
            _ = readerState(for: key)
        }
    }

    func frame(for spec: VideoLayerSpec, at compositionTime: CMTime) -> VideoFrameImage? {
        let start = spec.timeRange.start
        let end   = spec.timeRange.end
        guard compositionTime >= start, compositionTime < end else { return nil }

        let localTime = clampedLocalTime(for: spec, at: compositionTime)
        let sourceTime = CMTime(
            seconds: spec.sourceStartTime + localTime,
            preferredTimescale: 600
        )

        let key = ReaderKey(spec: spec)
        let state = readerState(for: key)
        #if DEBUG
        let isBoundary = isVideoBoundary(compositionTime: compositionTime, spec: spec)
        #endif

        let sourceEndTime = CMTime(
            seconds: spec.sourceStartTime + spec.timeRange.duration.seconds,
            preferredTimescale: 600
        )
        guard let frame = readerFrame(
            state: state,
            targetTime: sourceTime,
            sourceEndTime: sourceEndTime
        ) else {
#if DEBUG
            if isBoundary {
                logExportReaderFrame(
                    spec: spec,
                    compositionTime: compositionTime,
                    sourceTime: sourceTime,
                    emittedTime: nil,
                    result: "nil"
                )
            }
#endif
            return nil
        }

#if DEBUG
        if isBoundary {
            logExportReaderFrame(
                spec: spec,
                compositionTime: compositionTime,
                sourceTime: sourceTime,
                emittedTime: frame.time,
                result: "ok"
            )
        }
#endif

        return VideoFrameImage(image: CIImage(cvPixelBuffer: frame.buffer), isCanvasFrame: false)
    }

    func prepare(for item: AVPlayerItem) {
        flush()
    }

    func seek(to time: CMTime) {
        flush()
    }

    func flush() {
        readersLock.lock()
        let states = Array(readers.values)
        readers.removeAll()
        readersLock.unlock()

        for state in states {
            state.reader?.cancelReading()
            state.reader = nil
            state.output = nil
            state.lastSampleBuffer = nil
            state.lastFrame = nil
            state.pendingSampleBuffer = nil
            state.pendingFrame = nil
            state.didReachEnd = false
        }
    }

    func invalidate() {
        flush()
    }

    private func readerState(for key: ReaderKey) -> ReaderState {
        readersLock.lock()
        defer { readersLock.unlock() }
        if let state = readers[key] { return state }
        let state = ReaderState(key: key)
        readers[key] = state
        return state
    }

    private func clampedLocalTime(for spec: VideoLayerSpec, at compositionTime: CMTime) -> Double {
        let duration = spec.timeRange.duration.seconds
        guard duration.isFinite, duration > 0 else { return 0 }
        let rawLocalTime = compositionTime.seconds - spec.timeRange.start.seconds
        let frameEpsilon = 1.0 / 600.0
        return min(max(rawLocalTime, 0), max(duration - frameEpsilon, 0))
    }

    private func readerFrame(
        state: ReaderState,
        targetTime: CMTime,
        sourceEndTime: CMTime
    ) -> (time: CMTime, buffer: CVPixelBuffer)? {
        guard targetTime.isValid,
              targetTime.seconds.isFinite,
              targetTime.seconds >= 0
        else {
            recordNil(state)
            return nil
        }

        recordRequest(state)

        if let edgeFrame = endFrameIfNeeded(
            state,
            targetTime: targetTime,
            sourceEndTime: sourceEndTime
        ) {
            recordReuse(state)
//            logReaderEventIfNeeded(
//                state,
//                targetTime: targetTime,
//                sampleTime: edgeFrame.time,
//                result: "reuse-source-end"
//            )
            return edgeFrame
        }

        if shouldRestartReader(state, targetTime: targetTime) {
            resetReader(state, startTime: targetTime)
        }

        if state.reader == nil {
            resetReader(state, startTime: targetTime)
        }

        guard state.reader != nil, state.output != nil else {
            recordNil(state)
//            logReaderEventIfNeeded(
//                state,
//                targetTime: targetTime,
//                sampleTime: nil,
//                result: "nil-no-reader",
//                force: true
//            )
            return nil
        }

        if let completedFrame = completedReaderFrameIfNeeded(state, targetTime: targetTime) {
            recordReuse(state)
//            logReaderEventIfNeeded(
//                state,
//                targetTime: targetTime,
//                sampleTime: completedFrame.time,
//                result: "reuse-reader-completed"
//            )
            return completedFrame
        }

        promotePendingFrameIfReady(state, targetTime: targetTime)

        if let pending = state.pendingFrame {
            if let frame = state.lastFrame {
                recordReuse(state)
//                logReaderEventIfNeeded(
//                    state,
//                    targetTime: targetTime,
//                    sampleTime: frame.time,
//                    result: "reuse-last-before-pending"
//                )
                return frame
            }
            if isFrameCloseEnough(pending.time, to: targetTime) {
                state.lastSampleBuffer = state.pendingSampleBuffer
                state.lastFrame = pending
                state.pendingSampleBuffer = nil
                state.pendingFrame = nil
                recordEmit(state)
//                logReaderEventIfNeeded(
//                    state,
//                    targetTime: targetTime,
//                    sampleTime: pending.time,
//                    result: "emit-pending"
//                )
                return pending
            }

            recordNil(state)
//            logReaderEventIfNeeded(
//                state,
//                targetTime: targetTime,
//                sampleTime: pending.time,
//                result: "nil-pending-too-far",
//                force: true
//            )
            return nil
        }

        let tolerance = CMTime(seconds: 1.0 / 120.0, preferredTimescale: 600)
        let maxSamplesPerRequest = 90
        var copiedSamples = 0
        var lastCopiedTime: CMTime?

        while copiedSamples < maxSamplesPerRequest {
            switch copyNextSampleBuffer(state: state) {
            case .sample(let sample, let buffer):
                let sampleTime = CMSampleBufferGetPresentationTimeStamp(sample)
                copiedSamples += 1
                lastCopiedTime = sampleTime
                if sampleTime <= targetTime + tolerance {
                    state.lastSampleBuffer = sample
                    state.lastFrame = (sampleTime, buffer)
                    continue
                }

                state.pendingSampleBuffer = sample
                state.pendingFrame = (sampleTime, buffer)
                copiedSamples = maxSamplesPerRequest

            case .end:
                copiedSamples = maxSamplesPerRequest

            case .timedOut:
                let fallback = state.lastFrame
                resetHungReader(state)
                if let fallback {
                    recordReuse(state)
//                    logReaderEventIfNeeded(
//                        state,
//                        targetTime: targetTime,
//                        sampleTime: fallback.time,
//                        result: "reuse-last-after-copy-timeout copied=\(copiedSamples) lastCopied=\(lastCopiedTime.map(formatDebugTime) ?? "nil")",
//                        force: true
//                    )
                    return fallback
                }
                recordNil(state)
//                logReaderEventIfNeeded(
//                    state,
//                    targetTime: targetTime,
//                    sampleTime: lastCopiedTime,
//                    result: "nil-copy-timeout copied=\(copiedSamples)",
//                    force: true
//                )
                return nil
            }
        }

        if state.pendingFrame == nil,
           state.output != nil,
           state.reader?.status == .completed {
            state.didReachEnd = true
        }

        if let frame = state.lastFrame {
            recordEmit(state)
//            logReaderEventIfNeeded(
//                state,
//                targetTime: targetTime,
//                sampleTime: frame.time,
//                result: "emit-last copied=\(copiedSamples) lastCopied=\(lastCopiedTime.map(formatDebugTime) ?? "nil")"
//            )
            return frame
        }

        if let pending = state.pendingFrame,
           isFrameCloseEnough(pending.time, to: targetTime) {
            state.lastSampleBuffer = state.pendingSampleBuffer
            state.lastFrame = pending
            state.pendingSampleBuffer = nil
            state.pendingFrame = nil
            recordEmit(state)
//            logReaderEventIfNeeded(
//                state,
//                targetTime: targetTime,
//                sampleTime: pending.time,
//                result: "emit-first-pending copied=\(copiedSamples)"
//            )
            return pending
        }

        if state.didReachEnd, let frame = state.lastFrame {
            recordReuse(state)
//            logReaderEventIfNeeded(
//                state,
//                targetTime: targetTime,
//                sampleTime: frame.time,
//                result: "reuse-end-frame"
//            )
            return frame
        }

        recordNil(state)
//        logReaderEventIfNeeded(
//            state,
//            targetTime: targetTime,
//            sampleTime: lastCopiedTime,
//            result: "nil copied=\(copiedSamples)",
//            force: true
//        )
        return nil
    }

    private func copyNextSampleBuffer(state: ReaderState) -> SampleCopyResult {
        guard let output = state.output else { return .end }
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var sample: CMSampleBuffer?
            var buffer: CVPixelBuffer?
        }
        let box = Box()

        DispatchQueue.global(qos: .userInitiated).async {
            let sample = output.copyNextSampleBuffer()
            box.sample = sample
            if let sample {
                box.buffer = CMSampleBufferGetImageBuffer(sample)
            }
            semaphore.signal()
        }

        let timeout = DispatchTime.now() + .milliseconds(1000)
        if semaphore.wait(timeout: timeout) == .timedOut {
#if DEBUG
            print("[ExportFrameProviderReader] copyNextSampleBuffer timeout asset=\(state.key.url.lastPathComponent) readerStatus=\(state.reader.map { String(describing: $0.status) } ?? "nil")")
#endif
            state.reader?.cancelReading()
            return .timedOut
        }

        guard let sample = box.sample, let buffer = box.buffer else {
            return .end
        }
        return .sample(sample, buffer)
    }

    private func resetHungReader(_ state: ReaderState) {
        state.reader?.cancelReading()
        state.reader = nil
        state.output = nil
        state.pendingSampleBuffer = nil
        state.pendingFrame = nil
        state.didReachEnd = false
        state.readerEndTime = .invalid
        state.lastLoggedRequestCount = 0
    }

    private func endFrameIfNeeded(
        _ state: ReaderState,
        targetTime: CMTime,
        sourceEndTime: CMTime
    ) -> (time: CMTime, buffer: CVPixelBuffer)? {
        guard sourceEndTime.isValid,
              targetTime.isValid,
              sourceEndTime.seconds.isFinite,
              targetTime.seconds.isFinite
        else { return nil }

        let edgePadding = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        guard targetTime >= sourceEndTime - edgePadding else { return nil }

        if let pending = state.pendingFrame,
           pending.time >= targetTime - edgePadding {
            state.lastSampleBuffer = state.pendingSampleBuffer
            state.lastFrame = pending
            state.pendingSampleBuffer = nil
            state.pendingFrame = nil
            return pending
        }

        return state.lastFrame
    }

    private func completedReaderFrameIfNeeded(
        _ state: ReaderState,
        targetTime: CMTime
    ) -> (time: CMTime, buffer: CVPixelBuffer)? {
        guard let reader = state.reader else { return nil }
        switch reader.status {
        case .completed:
            state.didReachEnd = true
            return state.lastFrame
        case .failed, .cancelled:
            return state.lastFrame
        default:
            return nil
        }
    }

    private func promotePendingFrameIfReady(_ state: ReaderState, targetTime: CMTime) {
        guard let pending = state.pendingFrame else { return }
        let tolerance = CMTime(seconds: 1.0 / 120.0, preferredTimescale: 600)
        if pending.time <= targetTime + tolerance {
            state.lastSampleBuffer = state.pendingSampleBuffer
            state.lastFrame = pending
            state.pendingSampleBuffer = nil
            state.pendingFrame = nil
        }
    }

    private func shouldRestartReader(_ state: ReaderState, targetTime: CMTime) -> Bool {
        guard let lastTime = state.lastFrame?.time,
              lastTime.isValid
        else {
            return isTargetOutsideReaderWindow(state, targetTime: targetTime)
        }
        if targetTime < lastTime - CMTime(seconds: 0.02, preferredTimescale: 600) {
            return true
        }
        return isTargetOutsideReaderWindow(state, targetTime: targetTime)
    }

    private func isTargetOutsideReaderWindow(_ state: ReaderState, targetTime: CMTime) -> Bool {
        guard state.readerEndTime.isValid,
              targetTime.isValid,
              state.readerEndTime.seconds.isFinite
        else { return false }
        let edgePadding = CMTime(seconds: 0.25, preferredTimescale: 600)
        return targetTime >= state.readerEndTime - edgePadding
    }

    private func resetReader(_ state: ReaderState, startTime: CMTime) {
        state.reader?.cancelReading()
        state.reader = nil
        state.output = nil
        state.lastSampleBuffer = nil
        state.lastFrame = nil
        state.pendingSampleBuffer = nil
        state.pendingFrame = nil
        state.didReachEnd = false
        state.readerEndTime = .invalid
        state.lastLoggedRequestCount = 0
        recordRestart(state)

        do {
            let reader = try AVAssetReader(asset: state.asset)
            guard let track = state.asset.tracks(withMediaType: .video).first else {
                return
            }

            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                return
            }
            reader.add(output)

            let warmup = CMTime(seconds: 0.1, preferredTimescale: 600)
            let readerStart = max(.zero, startTime - warmup)
            state.readerStartTime = readerStart
            let assetDuration = state.asset.duration
            let windowDuration = CMTime(seconds: 2.0, preferredTimescale: 600)
            if assetDuration.isValid, assetDuration.seconds.isFinite, assetDuration > readerStart {
                let availableDuration = assetDuration - readerStart
                let duration = min(availableDuration, windowDuration)
                state.readerEndTime = readerStart + duration
                reader.timeRange = CMTimeRange(start: readerStart, duration: duration)
            } else {
                state.readerEndTime = readerStart + windowDuration
                reader.timeRange = CMTimeRange(start: readerStart, duration: windowDuration)
            }

            guard reader.startReading() else {
#if DEBUG
                print("[ExportFrameProviderReader] startReading failed asset=\(state.key.url.lastPathComponent) start=\(formatDebugTime(readerStart)) error=\(reader.error.map(String.init(describing:)) ?? "nil")")
#endif
                return
            }

            state.reader = reader
            state.output = output
        } catch {
#if DEBUG
            print("[ExportFrameProviderReader] create reader failed asset=\(state.key.url.lastPathComponent) start=\(formatDebugTime(startTime)) error=\(error)")
#endif
        }
    }

    private func isFrameCloseEnough(_ frameTime: CMTime, to targetTime: CMTime) -> Bool {
        guard frameTime.isValid, targetTime.isValid else { return false }
        return abs(frameTime.seconds - targetTime.seconds) < 0.15
    }

#if DEBUG
    private func isVideoBoundary(compositionTime: CMTime, spec: VideoLayerSpec) -> Bool {
        guard compositionTime.isValid else { return false }
        let start = spec.timeRange.start.seconds
        let end = spec.timeRange.end.seconds
        let t = compositionTime.seconds
        return abs(t - start) < 0.12 || abs(end - t) < 0.12
    }

    private func logExportReaderFrame(
        spec: VideoLayerSpec,
        compositionTime: CMTime,
        sourceTime: CMTime,
        emittedTime: CMTime?,
        result: String
    ) {
        let localTime = compositionTime.seconds - spec.timeRange.start.seconds
        let sourceEnd = spec.sourceStartTime + spec.timeRange.duration.seconds
        print(
            "[ExportFrameProviderReader] " +
            "asset=\(spec.assetURL.lastPathComponent) " +
            "compositionTime=\(formatDebugTime(compositionTime)) " +
            "localTime=\(formatDebugSeconds(localTime)) " +
            "sourceTime=\(formatDebugTime(sourceTime)) " +
            "emittedTime=\(emittedTime.map(formatDebugTime) ?? "nil") " +
            "segmentStart=\(formatDebugTime(spec.timeRange.start)) " +
            "segmentEnd=\(formatDebugTime(spec.timeRange.end)) " +
            "sourceStart=\(formatDebugSeconds(spec.sourceStartTime)) " +
            "sourceEnd=\(formatDebugSeconds(sourceEnd)) " +
            "result=\(result)"
        )
    }

    private func logReaderEventIfNeeded(
        _ state: ReaderState,
        targetTime: CMTime,
        sampleTime: CMTime?,
        result: String,
        force: Bool = false
    ) {
        let shouldLog = force
            || state.requestCount == 1
            || state.requestCount - state.lastLoggedRequestCount >= 120
        guard shouldLog else { return }
        state.lastLoggedRequestCount = state.requestCount

        print(
            "[ExportProvider] " +
            "segmentID=\(segmentID(state.key)) " +
            "asset=\(state.key.url.lastPathComponent) " +
            "sourceTime=\(formatDebugTime(targetTime)) " +
            "readerStatus=\(state.reader.map { String(describing: $0.status) } ?? "nil") " +
            "samplePTS=\(sampleTime.map(formatDebugTime) ?? "nil") " +
            "pendingPTS=\(state.pendingFrame.map { formatDebugTime($0.time) } ?? "nil") " +
            "reuseLastFrame=\(result.contains("reuse")) " +
            "nilFrame=\(result.contains("nil")) " +
            "result=\(result) " +
            "requests=\(state.requestCount) emitted=\(state.emittedCount) reused=\(state.reusedCount) nil=\(state.nilCount) restarts=\(state.restartCount)"
        )
    }

    private func segmentID(_ key: ReaderKey) -> String {
        "\(key.timelineStart)-\(key.timelineDuration)-\(key.sourceStart)"
    }

    private func recordRequest(_ state: ReaderState) {
        state.requestCount += 1
    }

    private func recordEmit(_ state: ReaderState) {
        state.emittedCount += 1
    }

    private func recordReuse(_ state: ReaderState) {
        state.reusedCount += 1
    }

    private func recordNil(_ state: ReaderState) {
        state.nilCount += 1
    }

    private func recordRestart(_ state: ReaderState) {
        state.restartCount += 1
    }
#else
    private func recordRequest(_ state: ReaderState) {}
    private func recordEmit(_ state: ReaderState) {}
    private func recordReuse(_ state: ReaderState) {}
    private func recordNil(_ state: ReaderState) {}
    private func recordRestart(_ state: ReaderState) {}
#endif

    private func formatDebugTime(_ time: CMTime) -> String {
        guard time.isValid else { return "invalid" }
        return formatDebugSeconds(time.seconds)
    }

    private func formatDebugSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return String(describing: seconds) }
        return String(format: "%.4f", seconds)
    }
}

// MARK: - PreviewFrameProvider

/// Realtime preview frame provider backed by `AVPlayerItemVideoOutput`.
///
/// Each source video asset owns its own hidden `AVPlayerItem +
/// AVPlayerItemVideoOutput`. The provider returns source-local video frames
/// (`isCanvasFrame == false`) so `VideoLayerComposer` can apply the same
/// fit/transform/adjustment path as export.
///
/// This avoids the composition-level output problem where a timeline beginning
/// with image-only content has no real video sample at item time 0, so the
/// first later video segment may never wake the output.
final class PreviewFrameProvider: VideoFrameProviderProtocol {
    /// Identifies one timeline video segment. Used both as the `sources`
    /// dictionary key (so each segment owns an independent hidden player) and to
    /// detect segment entry. Includes `url` because an overlay video segment and
    /// a main-track segment can share the same `timelineStart` while pointing at
    /// different files.
    private struct SegmentKey: Hashable {
        let url: URL
        let timelineStart: Double
        let timelineDuration: Double
        let sourceStart: Double

        init(spec: VideoLayerSpec) {
            url = spec.assetURL
            timelineStart = spec.timeRange.start.seconds
            timelineDuration = spec.timeRange.duration.seconds
            sourceStart = spec.sourceStartTime
        }
    }

    private final class SourceOutput {
        let segmentKey: SegmentKey
        let item: AVPlayerItem
        let player: AVPlayer
        var output: AVPlayerItemVideoOutput
        var lastFrame: (time: CMTime, buffer: CVPixelBuffer)?
        var pendingSeekTime: CMTime?
        var lastCompositionTime: CMTime?
        var lastOutputRecoveryTime: CMTime?
        var consecutiveStaleFrameCount = 0
        var activeSegment: SegmentKey?
        var didStartPlaybackForSegment = false
        var isInvalidated = false
        /// Monotonic timestamp (ProcessInfo.systemUptime) of the last `frame()`
        /// request that touched this source. Drives idle-pause so a segment that
        /// scrolled out of the playhead stops decoding, while transition zones
        /// (which request two sources every tick) keep both alive.
        var lastRequestedAt: TimeInterval = 0

        var url: URL { segmentKey.url }

#if DEBUG
        var requestCount = 0
        var noNewPixelBufferCount = 0
        var copyNilCount = 0
        var reusedFrameCount = 0
        var nilFrameCount = 0
        var forcedCopyCount = 0
        var seekCount = 0
#endif

        init(key: SegmentKey, asset: AVURLAsset) {
            self.segmentKey = key
            self.item = AVPlayerItem(asset: asset)
            self.output = Self.makeOutput()
            self.item.add(output)
            self.player = AVPlayer(playerItem: item)
            self.player.isMuted = true
            self.player.actionAtItemEnd = .pause
            self.player.automaticallyWaitsToMinimizeStalling = false
        }

        static func makeOutput() -> AVPlayerItemVideoOutput {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
            output.suppressesPlayerRendering = true
            return output
        }

        func reattachOutput() {
            item.remove(output)
            output = Self.makeOutput()
            item.add(output)
            output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        }

        func invalidate() {
            isInvalidated = true
            player.pause()
            item.remove(output)
            lastFrame = nil
            pendingSeekTime = nil
            lastCompositionTime = nil
            lastOutputRecoveryTime = nil
            consecutiveStaleFrameCount = 0
            activeSegment = nil
            didStartPlaybackForSegment = false
        }

        func resetForSeek() {
            player.pause()
            pendingSeekTime = nil
            lastCompositionTime = nil
            lastOutputRecoveryTime = nil
            consecutiveStaleFrameCount = 0
            activeSegment = nil
            didStartPlaybackForSegment = false
            output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
            resetDebugCounters()
        }

        func resetDebugCounters() {
#if DEBUG
            requestCount = 0
            noNewPixelBufferCount = 0
            copyNilCount = 0
            reusedFrameCount = 0
            nilFrameCount = 0
            forcedCopyCount = 0
            seekCount = 0
#endif
        }
    }

    // Keyed by SegmentKey: each timeline video segment owns an independent
    // hidden player. Multiple segments referencing the same file (common in
    // AI short-drama templates) therefore no longer fight over one player's
    // decode position — which previously caused transition black frames and
    // rewind-seek storms.
    private var sources: [SegmentKey: SourceOutput] = [:]
    // Shared per-URL AVURLAsset so segments on the same file reuse the decoder
    // metadata / file handle instead of opening the asset N times.
    private var assetCache: [URL: AVURLAsset] = [:]
    // All known timeline video segments (metadata only — lightweight). Used to
    // find the "next segment" for sliding-window prefetch and to validate that
    // a SegmentKey still belongs to the current timeline. Registered by
    // `preload`; far cheaper than holding a hidden player per segment.
    private var knownSpecs: [SegmentKey: VideoLayerSpec] = [:]
    // Hard cap on concurrently-alive hidden players. iOS limits simultaneous
    // hardware decode sessions (HEVC especially), so an AI short-drama timeline
    // with dozens of clips cannot keep one player per segment. The pool keeps at
    // most this many; least-recently-requested segments are evicted. 4 covers
    // {current, transition-incoming, prefetched-next} plus headroom.
    private let maxActiveSources = 4
    private var canvasSize: CGSize = .zero
    private var lastSeekTime: CMTime?
    private var lastTimelineCompositionTime: CMTime?
    private var lastDisplayedFrame: (compositionTime: CMTime, buffer: CVPixelBuffer)?
    private var isPlaybackActiveHint = false
    var onSourcePreloadComplete: (() -> Void)?

    func setCanvasSize(_ size: CGSize) {
        canvasSize = size
    }

    func setPlaybackActive(_ active: Bool) {
        isPlaybackActiveHint = active
    }

    func prepare(for item: AVPlayerItem) {
        invalidate()
    }

    func preload(videoSpecs: [VideoLayerSpec]) {
        // Register every segment's metadata (lightweight). Sliding-window
        // prefetch and timeline-membership checks read from here.
        knownSpecs = Dictionary(
            videoSpecs.map { (SegmentKey(spec: $0), $0) },
            uniquingKeysWith: { _, new in new }
        )
        let liveKeys = Set(knownSpecs.keys)

        // Evict sources whose segment no longer exists in the rebuilt timeline
        // (e.g. user deleted/trimmed a clip), so hidden players don't leak.
        for (key, source) in sources where !liveKeys.contains(key) {
            source.invalidate()
            sources[key] = nil
        }
        // Drop cached assets no longer referenced by any live segment.
        let liveURLs = Set(liveKeys.map { $0.url })
        for url in assetCache.keys where !liveURLs.contains(url) {
            assetCache[url] = nil
        }

        // Only warm the first segment (the common "play from the start" entry).
        // Remaining segments are created lazily and warmed by
        // `prefetchNextSegment` as playback approaches them. Warming all N here
        // would spin up N hidden players at once and exhaust decode sessions on
        // a dozens-of-clips timeline.
        guard let firstSpec = videoSpecs.min(by: {
            $0.timeRange.start.seconds < $1.timeRange.start.seconds
        }) else { return }
        if sources[SegmentKey(spec: firstSpec)] == nil {
            warmSource(for: firstSpec)
        }
    }

    /// Create (if needed) and pre-warm a source for `spec`: seek the hidden
    /// player to `sourceStartTime` so `AVPlayerItemVideoOutput` has a decoded
    /// frame ready before the segment is shown. Marks the source freshly-used so
    /// the LRU pool won't immediately evict it.
    private func warmSource(for spec: VideoLayerSpec) {
        let source = sourceOutput(for: spec)
        source.lastRequestedAt = ProcessInfo.processInfo.systemUptime
        // `automaticallyWaitsToMinimizeStalling = false` (set in SourceOutput
        // init) means the hidden player keeps its clock advancing even if decode
        // falls behind. 4 s forward buffer gives the decoder headroom so segment
        // entry via `playImmediately` doesn't spend 30-60 ticks with
        // `hasNewPixelBuffer=false` waiting for the queue to refill.
        source.item.preferredForwardBufferDuration = 4
        source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        let seekTime = CMTime(seconds: spec.sourceStartTime, preferredTimescale: 600)
        if seekTime.isValid && seekTime.seconds >= 0 {
            preloadSource(source, seekTime: seekTime)
        }
    }

    /// Warm the segment that follows `start` in timeline order, if not already
    /// pooled. Called when entering a new segment (playback) or after a targeted
    /// seek, giving the next segment a head start so sequential playback crosses
    /// boundaries without a cold-start black window.
    private func prefetchNextSegment(afterStart start: Double) {
        let next = knownSpecs.values
            .filter { $0.timeRange.start.seconds > start + 0.001 }
            .min { $0.timeRange.start.seconds < $1.timeRange.start.seconds }
        guard let nextSpec = next,
              sources[SegmentKey(spec: nextSpec)] == nil
        else { return }
        warmSource(for: nextSpec)
    }

    private func preloadSource(_ source: SourceOutput, seekTime: CMTime) {
        let asset = source.item.asset
        let keys = ["tracks", "duration", "playable"]
        asset.loadValuesAsynchronously(forKeys: keys) { [weak source] in
            DispatchQueue.main.async {
                guard let source else { return }
                guard !source.isInvalidated else { return }

                source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
                source.player.seek(
                    to: seekTime,
                    toleranceBefore: .zero,
                    toleranceAfter: CMTime(value: 1, timescale: 600)
                ) { [weak source] _ in
                    guard let source else { return }
                    guard !source.isInvalidated else { return }
                    source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)

                    guard source.player.status == .readyToPlay else {
                        self.finishPreloadSource(source, seekTime: seekTime)
                        return
                    }

                    self.prerollPreloadSource(source, seekTime: seekTime)
                }
            }
        }
    }

    private func prerollPreloadSource(_ source: SourceOutput, seekTime: CMTime) {
        guard !source.isInvalidated else { return }
        guard source.player.status == .readyToPlay else {
            finishPreloadSource(source, seekTime: seekTime)
            return
        }

        source.player.preroll(atRate: 1.0) { [weak self, weak source] _ in
            DispatchQueue.main.async {
                guard let self, let source else { return }
                self.finishPreloadSource(source, seekTime: seekTime)
            }
        }
    }

    private func finishPreloadSource(_ source: SourceOutput, seekTime: CMTime) {
        guard !source.isInvalidated else { return }
        source.player.pause()
        source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        var displayTime = CMTime.invalid
        let warmBuffer = source.output.copyPixelBuffer(
            forItemTime: seekTime,
            itemTimeForDisplay: &displayTime
        )
        if let warmBuffer {
            let actualTime = displayTime.isValid ? displayTime : seekTime
            source.lastFrame = (actualTime, warmBuffer)
        }
        onSourcePreloadComplete?()
    }

    func frame(for spec: VideoLayerSpec, at compositionTime: CMTime) -> VideoFrameImage? {
        let start = spec.timeRange.start
        let end = spec.timeRange.end
        guard compositionTime >= start, compositionTime < end else { return nil }

        let localTime = compositionTime.seconds - start.seconds
        let sourceTime = CMTime(
            seconds: spec.sourceStartTime + localTime,
            preferredTimescale: 600
        )
        let source = sourceOutput(for: spec)
        source.lastRequestedAt = ProcessInfo.processInfo.systemUptime
        let timelinePlayback = isTimelinePlayback(at: compositionTime)
        pauseStaleSources()
        guard let buffer = sourceFrame(
            source,
            sourceTime: sourceTime,
            compositionTime: compositionTime,
            segmentKey: SegmentKey(spec: spec),
            timelinePlayback: timelinePlayback
        ) else {
            if !isPlaybackActiveHint,
               let fallbackFrame = lastDisplayedFrame {
                return VideoFrameImage(image: CIImage(cvPixelBuffer: fallbackFrame.buffer), isCanvasFrame: false)
            }
            return nil
        }
        lastDisplayedFrame = (compositionTime, buffer)
        return VideoFrameImage(image: CIImage(cvPixelBuffer: buffer), isCanvasFrame: false)
    }

    func seek(to time: CMTime) {
        if isDuplicateSeek(to: time) {
            return
        }
        lastSeekTime = time
        lastTimelineCompositionTime = nil
        sources.values.forEach { $0.resetForSeek() }
    }

    /// Targeted seek that pre-positions source players before the next render
    /// tick. For every active spec the corresponding `SourceOutput` is reattached
    /// (if entering a new segment), claims the segment, and an `issueSeek` is
    /// fired toward the target `sourceTime`. Inactive sources are paused but not
    /// reset — they keep their `lastFrame` so a quick scrub back into the
    /// segment can reuse it.
    ///
    /// `lastDisplayedFrame` is intentionally preserved (only `flush()` /
    /// `invalidate()` clear it). The preview layer therefore holds the previous
    /// good buffer until the source emits the target frame, avoiding the
    /// 1-3 frame paused-seek black window.
    func seek(to time: CMTime, activeSpecs: [VideoLayerSpec], playbackActive: Bool) {
        isPlaybackActiveHint = playbackActive
        if isDuplicateSeek(to: time) {
            return
        }
        lastSeekTime = time
        lastTimelineCompositionTime = nil

        guard !activeSpecs.isEmpty else {
            // No video layer under the playhead — keep the legacy reset path so
            // sources don't keep decoding while we are over an image-only zone.
            sources.values.forEach { $0.resetForSeek() }
            return
        }

        // Each active spec maps to its own segment-keyed source. In a transition
        // zone two specs (outgoing + incoming) are active simultaneously; both
        // get pre-seeked toward their target sourceTime so neither side is black
        // when the next render tick requests them.
        let activeKeys = Set(activeSpecs.map { SegmentKey(spec: $0) })
        for spec in activeSpecs {
            let source = sourceOutput(for: spec)
            let localTime = max(0, time.seconds - spec.timeRange.start.seconds)
            let sourceTime = CMTime(
                seconds: spec.sourceStartTime + localTime,
                preferredTimescale: 600
            )
            prepareSourceForTargetedSeek(
                source,
                segmentKey: SegmentKey(spec: spec),
                targetSourceTime: sourceTime,
                playbackActive: playbackActive
            )
            // Seeking into a (possibly cold) segment also warms the next one so
            // playback resumed after the seek crosses the boundary cleanly.
            prefetchNextSegment(afterStart: spec.timeRange.start.seconds)
        }

        // Sources not under the playhead: pause and forget the active segment,
        // but don't drop their `lastFrame` — a quick scrub back into the same
        // segment can still reuse it via the 0.1 s window.
        for (key, source) in sources where !activeKeys.contains(key) {
            source.player.pause()
            source.pendingSeekTime = nil
            source.activeSegment = nil
            source.didStartPlaybackForSegment = false
            source.lastOutputRecoveryTime = nil
            source.consecutiveStaleFrameCount = 0
        }
    }

    private func prepareSourceForTargetedSeek(
        _ source: SourceOutput,
        segmentKey: SegmentKey,
        targetSourceTime: CMTime,
        playbackActive: Bool
    ) {
        // Mark as freshly used so a prefetch-triggered eviction in the same
        // seek pass can't release the segment we're actively seeking into.
        source.lastRequestedAt = ProcessInfo.processInfo.systemUptime
        let priorSegment = source.activeSegment
        let isSegmentChange = priorSegment != nil && priorSegment != segmentKey
        source.pendingSeekTime = nil
        source.lastOutputRecoveryTime = nil
        source.consecutiveStaleFrameCount = 0
        source.activeSegment = segmentKey
        source.didStartPlaybackForSegment = false
        source.lastCompositionTime = nil
        // Same rule as `updateActiveSegmentIfNeeded`: only reattach when truly
        // switching between segments on the same URL. Fresh activation keeps
        // the preload warm-frame queue intact.
        if isSegmentChange {
            source.reattachOutput()
        } else {
            source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        }
        source.resetDebugCounters()
        issueSeek(source: source, to: targetSourceTime, activePlayback: playbackActive)
    }

    func flush() {
        lastSeekTime = nil
        lastTimelineCompositionTime = nil
        lastDisplayedFrame = nil
        sources.values.forEach { $0.resetForSeek() }
    }

    func invalidate() {
        lastSeekTime = nil
        lastTimelineCompositionTime = nil
        lastDisplayedFrame = nil
        isPlaybackActiveHint = false
        sources.values.forEach { $0.invalidate() }
        sources.removeAll()
        assetCache.removeAll()
    }

#if DEBUG
    var debugStateDescription: String {
        let sourceDescriptions = sources.values.map { source in
            let itemDuration = source.item.duration.seconds
            return "\(source.url.lastPathComponent){item=\(source.item.status.rawValue),rate=\(String(format: "%.2f", source.player.rate)),playerTime=\(formatTime(source.player.currentTime())),lastFrame=\(source.lastFrame.map { formatTime($0.time) } ?? "nil"),pendingSeek=\(source.pendingSeekTime.map(formatTime) ?? "nil"),activeSegment=\(source.activeSegment != nil)}"
        }
        return "sources=\(sources.count) lastSeek=\(lastSeekTime.map(formatTime) ?? "nil") [\(sourceDescriptions.joined(separator: "; "))]"
    }
#endif

    private func sourceOutput(for spec: VideoLayerSpec) -> SourceOutput {
        let key = SegmentKey(spec: spec)
        if let source = sources[key] { return source }
        let source = SourceOutput(key: key, asset: cachedAsset(for: spec.assetURL))
        // Mark freshly-used on creation so the LRU sweep below doesn't pick this
        // brand-new source (lastRequestedAt would otherwise be 0 = oldest).
        source.lastRequestedAt = ProcessInfo.processInfo.systemUptime
        sources[key] = source
        evictIfNeeded()
        return source
    }

    /// Trim the pool back to `maxActiveSources` by evicting the least-recently
    /// requested sources. Sources touched within the last 0.5 s are protected
    /// (current playhead segment, transition's other half, just-prefetched
    /// next segment), so only genuinely idle past segments are released. If the
    /// active set alone exceeds the cap (rare), the pool temporarily overshoots
    /// rather than evicting a live source.
    private func evictIfNeeded() {
        guard sources.count > maxActiveSources else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let protectWindow: TimeInterval = 0.5
        let evictable = sources
            .filter { now - $0.value.lastRequestedAt > protectWindow }
            .sorted { $0.value.lastRequestedAt < $1.value.lastRequestedAt }
        var overflow = sources.count - maxActiveSources
        for (key, source) in evictable where overflow > 0 {
            source.invalidate()
            sources[key] = nil
            overflow -= 1
        }
    }

    private func cachedAsset(for url: URL) -> AVURLAsset {
        if let asset = assetCache[url] { return asset }
        let asset = AVURLAsset(url: url)
        assetCache[url] = asset
        return asset
    }

    private func isDuplicateSeek(to time: CMTime) -> Bool {
        guard let lastSeekTime,
              lastSeekTime.isValid,
              time.isValid
        else { return false }
        return abs(lastSeekTime.seconds - time.seconds) < 0.001
    }

    private func sourceFrame(
        _ source: SourceOutput,
        sourceTime: CMTime,
        compositionTime: CMTime,
        segmentKey: SegmentKey,
        timelinePlayback: Bool
    ) -> CVPixelBuffer? {
        guard sourceTime.isValid,
              sourceTime.seconds.isFinite,
              sourceTime.seconds >= 0
        else {
            logFrameMiss(source, compositionTime: compositionTime, sourceTime: sourceTime, hasNewPixelBuffer: nil, reason: "invalid sourceTime")
            return nil
        }

        recordRequest(source)

        let sourcePlayback = isActivePlayback(source: source, compositionTime: compositionTime)
        let activePlayback = isPlaybackActiveHint || timelinePlayback || sourcePlayback
        let didEnterSegment = updateActiveSegmentIfNeeded(source: source, segmentKey: segmentKey)
        if didEnterSegment {
            issueSeek(source: source, to: sourceTime, activePlayback: activePlayback)
            // Sliding-window prefetch: as soon as we enter this segment, give the
            // next one a head start so the upcoming boundary has a warm player.
            prefetchNextSegment(afterStart: segmentKey.timelineStart)
        } else if activePlayback {
            startPlaybackIfNeeded(source)
        } else if shouldSeekWhilePaused(source: source, sourceTime: sourceTime) {
            issueSeek(source: source, to: sourceTime, activePlayback: false)
        }

        var displayTime = CMTime.invalid
        let hasNewPixelBuffer = source.output.hasNewPixelBuffer(forItemTime: sourceTime)
        if hasNewPixelBuffer,
           let buffer = source.output.copyPixelBuffer(
                forItemTime: sourceTime,
                itemTimeForDisplay: &displayTime
            ) {
            let actualTime = displayTime.isValid ? displayTime : sourceTime
            source.lastFrame = (actualTime, buffer)
            source.consecutiveStaleFrameCount = 0
            return buffer
        }

        if let cached = reusableLastFrame(source, near: sourceTime) {
            if !hasNewPixelBuffer {
                recordNoNewPixelBuffer(source)
            } else {
                recordCopyNil(source)
            }
            recordReuse(source)
            logFrameReuse(
                source,
                compositionTime: compositionTime,
                sourceTime: sourceTime,
                lastFrameTime: cached.time,
                hasNewPixelBuffer: hasNewPixelBuffer,
                reason: hasNewPixelBuffer ? "copyPixelBuffer nil; reused source frame" : "no new pixel buffer; reused source frame"
            )
            return cached.buffer
        }

        if let cached = reusableEndFrame(source, sourceTime: sourceTime, segmentKey: segmentKey) {
            recordNoNewPixelBuffer(source)
            recordReuse(source)
            logFrameReuse(
                source,
                compositionTime: compositionTime,
                sourceTime: sourceTime,
                lastFrameTime: cached.time,
                hasNewPixelBuffer: hasNewPixelBuffer,
                reason: "near segment end; reused last source frame"
            )
            return cached.buffer
        }

        if let buffer = source.output.copyPixelBuffer(
            forItemTime: sourceTime,
            itemTimeForDisplay: &displayTime
        ) {
            let actualTime = displayTime.isValid ? displayTime : sourceTime
            guard isUsableForcedCopy(displayTime: actualTime, sourceTime: sourceTime) else {
                recordNoNewPixelBuffer(source)
                if activePlayback {
                    source.consecutiveStaleFrameCount += 1
                    recoverStalledOutputIfNeeded(source, sourceTime: sourceTime)
                    let fallbackFrame = source.lastFrame ?? (actualTime, buffer)
                    source.lastFrame = fallbackFrame
                    recordReuse(source)
                    logFrameReuse(
                        source,
                        compositionTime: compositionTime,
                        sourceTime: sourceTime,
                        lastFrameTime: fallbackFrame.time,
                        hasNewPixelBuffer: hasNewPixelBuffer,
                        reason: "stale forced copy displayTime=\(formatTime(actualTime)); held source frame"
                    )
                    return fallbackFrame.buffer
                }
                // Paused / scrubbing: hold the previous source frame if it is
                // within the paused-seek window (0.75 s). Without this, every
                // stale forced copy on a paused playhead falls back to
                // `lastDisplayedFrame` — which may be from a different source —
                // or, when nothing was displayed yet, to a true black frame.
                if let fallback = reusablePausedSeekFrame(source, sourceTime: sourceTime) {
                    recordReuse(source)
                    source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
                    logFrameReuse(
                        source,
                        compositionTime: compositionTime,
                        sourceTime: sourceTime,
                        lastFrameTime: fallback.time,
                        hasNewPixelBuffer: hasNewPixelBuffer,
                        reason: "paused stale forced copy displayTime=\(formatTime(actualTime)); held source frame"
                    )
                    return fallback.buffer
                }
                recordNilFrame(source)
                logFrameMiss(
                    source,
                    compositionTime: compositionTime,
                    sourceTime: sourceTime,
                    hasNewPixelBuffer: hasNewPixelBuffer,
                    reason: "forced copy returned stale displayTime=\(formatTime(actualTime))"
                )
                return nil
            }

            recordForcedCopy(source)
            source.lastFrame = (actualTime, buffer)
            source.consecutiveStaleFrameCount = 0
            logForcedCopy(source, compositionTime: compositionTime, sourceTime: sourceTime, displayTime: actualTime, hasNewPixelBuffer: hasNewPixelBuffer)
            return buffer
        }

        if !hasNewPixelBuffer {
            recordNoNewPixelBuffer(source)
        } else {
            recordCopyNil(source)
        }
        if !activePlayback,
           let fallbackFrame = reusablePausedSeekFrame(source, sourceTime: sourceTime) {
            recordReuse(source)
            source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
            logFrameReuse(
                source,
                compositionTime: compositionTime,
                sourceTime: sourceTime,
                lastFrameTime: fallbackFrame.time,
                hasNewPixelBuffer: hasNewPixelBuffer,
                reason: "paused seek pending pixel buffer; held source frame"
            )
            return fallbackFrame.buffer
        }
        recordNilFrame(source)
        if activePlayback {
            source.consecutiveStaleFrameCount += 1
            recoverStalledOutputIfNeeded(source, sourceTime: sourceTime)
            source.player.playImmediately(atRate: 1.0)
            if let fallbackFrame = reusableStalledFrame(source, sourceTime: sourceTime) {
                recordReuse(source)
                logFrameReuse(
                    source,
                    compositionTime: compositionTime,
                    sourceTime: sourceTime,
                    lastFrameTime: fallbackFrame.time,
                    hasNewPixelBuffer: hasNewPixelBuffer,
                    reason: "missing pixel buffer during playback; held source frame"
                )
                return fallbackFrame.buffer
            }
        }
        source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        logFrameMiss(source, compositionTime: compositionTime, sourceTime: sourceTime, hasNewPixelBuffer: hasNewPixelBuffer, reason: hasNewPixelBuffer ? "copyPixelBuffer returned nil and no reusable source frame" : "no new pixel buffer and no reusable source frame")
        return nil
    }

    /// Pause sources whose segment hasn't been requested recently. Unlike the
    /// old `pauseInactiveSources(except:)`, this keeps every source that was
    /// touched within the idle window alive — essential during transitions,
    /// where two segment sources are requested on every render tick. A single
    /// `except:` would have paused the second source as soon as the first one's
    /// `frame()` ran.
    private func pauseStaleSources() {
        let now = ProcessInfo.processInfo.systemUptime
        let idleWindow: TimeInterval = 0.12
        for source in sources.values where source.player.rate != 0 {
            if now - source.lastRequestedAt > idleWindow {
                source.player.pause()
                source.didStartPlaybackForSegment = false
            }
        }
    }

    private func isActivePlayback(source: SourceOutput, compositionTime: CMTime) -> Bool {
        defer { source.lastCompositionTime = compositionTime }
        guard let last = source.lastCompositionTime,
              last.isValid,
              compositionTime.isValid
        else { return false }
        let delta = compositionTime.seconds - last.seconds
        return delta > 0.001 && delta < 0.12
    }

    private func isTimelinePlayback(at compositionTime: CMTime) -> Bool {
        defer { lastTimelineCompositionTime = compositionTime }
        guard let last = lastTimelineCompositionTime,
              last.isValid,
              compositionTime.isValid
        else { return false }
        let delta = compositionTime.seconds - last.seconds
        return delta > 0.001 && delta < 0.12
    }

    private func updateActiveSegmentIfNeeded(
        source: SourceOutput,
        segmentKey: SegmentKey
    ) -> Bool {
        guard source.activeSegment != segmentKey else { return false }
        // Fresh activation (no prior segment on this source) means `preload`
        // already seeded the output's pixel-buffer queue with a warm frame at
        // `sourceStartTime`. Reattaching the output here would throw away that
        // queue and force the decoder to refill from scratch — empirically a
        // ~200 ms blackout window at every "first time a segment is shown".
        //
        // Only reattach on a true *segment switch* (same URL, different
        // sourceStartTime/timeRange): the output may hold frames at PTS that
        // belong to the old segment and we want a clean slate.
        let isFreshActivation = source.activeSegment == nil
        source.player.pause()
        if isFreshActivation {
            source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        } else {
            source.reattachOutput()
        }
        source.activeSegment = segmentKey
        source.didStartPlaybackForSegment = false
        source.pendingSeekTime = nil
        source.lastOutputRecoveryTime = nil
        source.consecutiveStaleFrameCount = 0
        // Do NOT clear lastFrame here — the 0.1 s reuse window in reusableLastFrame()
        // will naturally reject any stale frame when the seek completes and a new
        // frame arrives. Clearing it causes 1-3 black frames at every segment boundary.
        return true
    }

    private func startPlaybackIfNeeded(_ source: SourceOutput) {
        guard source.pendingSeekTime == nil else { return }
        guard source.item.status == .readyToPlay else {
            source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
            return
        }
        if source.player.rate == 0 {
            source.player.playImmediately(atRate: 1.0)
        }
        source.didStartPlaybackForSegment = true
    }

    private func shouldSeekWhilePaused(source: SourceOutput, sourceTime: CMTime) -> Bool {
        if let pending = source.pendingSeekTime,
           pending.isValid,
           abs(pending.seconds - sourceTime.seconds) < 0.05 {
            return false
        }
        if source.player.rate != 0 { return false }
        if source.didStartPlaybackForSegment { return false }
        let currentTime = source.player.currentTime()
        guard currentTime.isValid,
              currentTime.seconds.isFinite
        else { return true }
        return abs(currentTime.seconds - sourceTime.seconds) > 0.015
    }

    private func issueSeek(source: SourceOutput, to time: CMTime, activePlayback: Bool) {
        source.pendingSeekTime = time
        recordSeek(source)
        source.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak source] _ in
            guard let source else { return }
            source.pendingSeekTime = nil
            source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
            if activePlayback {
                source.player.playImmediately(atRate: 1.0)
            } else {
                var displayTime = CMTime.invalid
                if let buffer = source.output.copyPixelBuffer(
                    forItemTime: time,
                    itemTimeForDisplay: &displayTime
                ) {
                    let actualTime = displayTime.isValid ? displayTime : time
                    if self.isUsableForcedCopy(displayTime: actualTime, sourceTime: time) {
                        source.lastFrame = (actualTime, buffer)
                        source.consecutiveStaleFrameCount = 0
                    }
                }
                source.player.pause()
            }
        }
    }

    /// Two-tier recovery for hidden source players that stop producing pixel
    /// buffers during active playback.
    ///
    /// - **Mild** (consecutiveStaleFrameCount ≥ 6, ~200 ms at 30 fps):
    ///   nudge the hidden player by seeking to the current `sourceTime` and
    ///   resuming. The output stays attached so any already-decoded frames in
    ///   the queue are preserved.
    /// - **Hard** (≥ 30, ~1 s of no new pixel buffers):
    ///   detach + re-add the output, force a fresh seek, and resume. This
    ///   destroys queued buffers and triggers a decoder restart — used only
    ///   when the mild path failed.
    ///
    /// The previous one-shot recovery did the hard path immediately on the
    /// first trigger, which itself often *caused* the next stale window — the
    /// fresh output starts empty and the player clock has already advanced past
    /// what the decoder can deliver.
    private func recoverStalledOutputIfNeeded(_ source: SourceOutput, sourceTime: CMTime) {
        guard source.item.status == .readyToPlay,
              source.pendingSeekTime == nil
        else { return }

        let stale = source.consecutiveStaleFrameCount
        guard stale >= 6 else { return }

        if let lastRecovery = source.lastOutputRecoveryTime,
           lastRecovery.isValid,
           sourceTime.isValid,
           abs(sourceTime.seconds - lastRecovery.seconds) < 0.4 {
            source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
            return
        }

        source.lastOutputRecoveryTime = sourceTime
        if stale >= 30 {
            // Hard recovery: existing queue is wedged, restart the decoder.
            source.player.pause()
            source.reattachOutput()
            issueSeek(source: source, to: sourceTime, activePlayback: true)
        } else {
            // Mild recovery: keep the output attached so already-queued frames
            // survive; seek + play tells the player to refill from sourceTime.
            issueSeek(source: source, to: sourceTime, activePlayback: true)
        }
    }

    private func reusableLastFrame(
        _ source: SourceOutput,
        near time: CMTime
    ) -> (time: CMTime, buffer: CVPixelBuffer)? {
        guard let lastFrame = source.lastFrame,
              lastFrame.time.isValid,
              time.isValid
        else { return nil }

        let delta = abs(lastFrame.time.seconds - time.seconds)
        return delta < 0.1 ? lastFrame : nil
    }

    private func reusableEndFrame(
        _ source: SourceOutput,
        sourceTime: CMTime,
        segmentKey: SegmentKey
    ) -> (time: CMTime, buffer: CVPixelBuffer)? {
        guard let lastFrame = source.lastFrame,
              lastFrame.time.isValid,
              sourceTime.isValid
        else { return nil }

        let sourceEnd = segmentKey.sourceStart + segmentKey.timelineDuration
        guard sourceEnd.isFinite,
              sourceTime.seconds >= sourceEnd - 0.75,
              abs(sourceTime.seconds - lastFrame.time.seconds) < 0.8
        else { return nil }
        return lastFrame
    }

    private func reusableStalledFrame(
        _ source: SourceOutput,
        sourceTime: CMTime
    ) -> (time: CMTime, buffer: CVPixelBuffer)? {
        guard let lastFrame = source.lastFrame,
              lastFrame.time.isValid,
              sourceTime.isValid
        else { return nil }

        let delta = abs(sourceTime.seconds - lastFrame.time.seconds)
        return delta < 1.5 ? lastFrame : nil
    }

    private func reusablePausedSeekFrame(
        _ source: SourceOutput,
        sourceTime: CMTime
    ) -> (time: CMTime, buffer: CVPixelBuffer)? {
        guard let lastFrame = source.lastFrame,
              lastFrame.time.isValid,
              sourceTime.isValid
        else { return nil }

        let delta = abs(sourceTime.seconds - lastFrame.time.seconds)
        return delta < 0.75 ? lastFrame : nil
    }

    private func isUsableForcedCopy(displayTime: CMTime, sourceTime: CMTime) -> Bool {
        guard displayTime.isValid,
              sourceTime.isValid,
              displayTime.seconds.isFinite,
              sourceTime.seconds.isFinite
        else { return false }
        return abs(displayTime.seconds - sourceTime.seconds) < 0.12
    }

    private func logFrameMiss(
        _ source: SourceOutput,
        compositionTime: CMTime,
        sourceTime: CMTime,
        hasNewPixelBuffer: Bool?,
        reason: String
    ) {
#if DEBUG
        let duration = source.item.duration.seconds
        let hasNew = hasNewPixelBuffer.map(String.init(describing:)) ?? "nil"
        print(
            "[AVPlayerItemVideoOutputProvider] frame miss " +
            "asset=\(source.url.lastPathComponent) " +
            "compositionTime=\(formatTime(compositionTime)) " +
            "sourceTime=\(formatTime(sourceTime)) " +
            "hasNewPixelBuffer=\(hasNew) " +
            "outputStatus=attached " +
            "playerItemStatus=\(String(describing: source.item.status)) " +
            "sourceDuration=\(formatSeconds(duration)) " +
            "reason=\(reason) " +
            debugCounterSummary(source)
        )
#endif
    }

    private func logFrameReuse(
        _ source: SourceOutput,
        compositionTime: CMTime,
        sourceTime: CMTime,
        lastFrameTime: CMTime,
        hasNewPixelBuffer: Bool,
        reason: String
    ) {
#if DEBUG
        guard source.reusedFrameCount == 1 || source.reusedFrameCount % 60 == 0 else { return }
        print(
            "[AVPlayerItemVideoOutputProvider] frame reuse " +
            "asset=\(source.url.lastPathComponent) " +
            "compositionTime=\(formatTime(compositionTime)) " +
            "sourceTime=\(formatTime(sourceTime)) " +
            "lastFrameTime=\(formatTime(lastFrameTime)) " +
            "hasNewPixelBuffer=\(hasNewPixelBuffer) " +
            "outputStatus=attached " +
            "playerItemStatus=\(String(describing: source.item.status)) " +
            "sourceDuration=\(formatSeconds(source.item.duration.seconds)) " +
            "reason=\(reason) " +
            debugCounterSummary(source)
        )
#endif
    }

    private func logForcedCopy(
        _ source: SourceOutput,
        compositionTime: CMTime,
        sourceTime: CMTime,
        displayTime: CMTime,
        hasNewPixelBuffer: Bool
    ) {
#if DEBUG
        guard source.forcedCopyCount == 1 || source.forcedCopyCount % 30 == 0 else { return }
        print(
            "[AVPlayerItemVideoOutputProvider] forced copy " +
            "asset=\(source.url.lastPathComponent) " +
            "compositionTime=\(formatTime(compositionTime)) " +
            "sourceTime=\(formatTime(sourceTime)) " +
            "displayTime=\(formatTime(displayTime)) " +
            "hasNewPixelBuffer=\(hasNewPixelBuffer) " +
            "outputStatus=attached " +
            "playerItemStatus=\(String(describing: source.item.status)) " +
            "sourceDuration=\(formatSeconds(source.item.duration.seconds)) " +
            debugCounterSummary(source)
        )
#endif
    }

    private func formatTime(_ time: CMTime) -> String {
        guard time.isValid else { return "invalid" }
        return formatSeconds(time.seconds)
    }

    private func formatSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return String(describing: seconds) }
        return String(format: "%.4f", seconds)
    }

    private func recordRequest(_ source: SourceOutput) {
#if DEBUG
        source.requestCount += 1
#endif
    }

    private func recordNoNewPixelBuffer(_ source: SourceOutput) {
#if DEBUG
        source.noNewPixelBufferCount += 1
#endif
    }

    private func recordCopyNil(_ source: SourceOutput) {
#if DEBUG
        source.copyNilCount += 1
#endif
    }

    private func recordReuse(_ source: SourceOutput) {
#if DEBUG
        source.reusedFrameCount += 1
#endif
    }

    private func recordNilFrame(_ source: SourceOutput) {
#if DEBUG
        source.nilFrameCount += 1
#endif
    }

    private func recordForcedCopy(_ source: SourceOutput) {
#if DEBUG
        source.forcedCopyCount += 1
#endif
    }

    private func recordSeek(_ source: SourceOutput) {
#if DEBUG
        source.seekCount += 1
#endif
    }

    private func debugCounterSummary(_ source: SourceOutput) -> String {
#if DEBUG
        return "requests=\(source.requestCount) hasNewFalse=\(source.noNewPixelBufferCount) copyNil=\(source.copyNilCount) reused=\(source.reusedFrameCount) forcedCopy=\(source.forcedCopyCount) seeks=\(source.seekCount) nilFrames=\(source.nilFrameCount)"
#else
        return ""
#endif
    }
}

typealias AVPlayerItemVideoOutputProvider = PreviewFrameProvider

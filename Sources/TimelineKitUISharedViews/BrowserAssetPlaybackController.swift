import AVFoundation
import CoreVideo
import Observation

/// Shared playback state for a browser-selected media asset.
///
/// The canvas renderer and the bottom transport bar both observe this controller,
/// so switching the canvas source does not require swapping control logic.
@MainActor
@Observable
public final class BrowserAssetPlaybackController {
    public let player = AVPlayer()

    public private(set) var playItem: AVPlayerItem?
    public private(set) var videoOutput: AVPlayerItemVideoOutput?
    public private(set) var asset: EditorPreviewAsset?
    public private(set) var isPlaying = false
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0

    private var timeObserver: Any?

    public init() {
        installTimeObserverIfNeeded()
    }

    public func load(_ asset: EditorPreviewAsset) async {
        stop()
        self.asset = asset
        duration = asset.duration ?? 0

        guard asset.kind != .image else { return }

        let item = AVPlayerItem(url: asset.url)
        if asset.kind == .video {
            let output = AVPlayerItemVideoOutput(
                pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
            )
            videoOutput = output
            item.add(output)
        }

        playItem = item
        player.replaceCurrentItem(with: item)
        player.pause()
        installTimeObserverIfNeeded()

        if duration <= 0,
           let itemDuration = item.duration as CMTime?,
           itemDuration.seconds.isFinite {
            duration = max(0, itemDuration.seconds)
        }
    }

    public func togglePlayback() {
        if isPlaying || player.rate > 0 {
            pause()
        } else {
            play()
        }
    }

    public func play() {
        guard playItem != nil else { return }
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        player.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func seek(to seconds: Double) {
        guard playItem != nil, duration > 0 else {
            currentTime = max(0, seconds)
            return
        }

        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        playItem = nil
        videoOutput = nil
        asset = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func installTimeObserverIfNeeded() {
        guard timeObserver == nil else { return }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.currentTime = max(0, time.seconds)
                if self.duration > 0,
                   self.currentTime >= self.duration - 0.05 {
                    self.player.pause()
                    self.isPlaying = false
                }
            }
        }
    }
}

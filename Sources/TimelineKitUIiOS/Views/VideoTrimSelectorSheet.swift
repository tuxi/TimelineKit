#if canImport(UIKit)
import SwiftUI
import AVFoundation
import TimelineKitRender

// MARK: - VideoTrimSelectorSheet

/// Full-screen immersive view for picking a clip in-point when replacing a segment
/// with a longer video.
///
/// Layout (top → bottom):
///   • Video preview — fills all space from top to 15 pt above the scrubber
///   • 15 pt gap
///   • Thumbnail scrubber (fixed window + scrollable strip + playhead bar)
///   • Duration label ("23.6s")
///   • Button row  [返回] ··· [确定 ▶ red]
struct VideoTrimSelectorSheet: View {

    let videoURL: URL
    let nativeDuration: Double   // total source video length (seconds)
    let targetDuration: Double   // fixed selection window width (= segment targetRange.duration)
    let onConfirm: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var clipInTime: Double = 0
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    /// 0.0 – 1.0: playhead position within the selection window.
    /// Updated every 1/30 s while playing; reset to 0 when paused or scrubbing.
    @State private var playheadProgress: Double = 0
    @State private var playbackTimer: Timer? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Preview ──────────────────────────────────────────────────
                previewArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 15 pt gap between preview bottom and scrubber top
                Spacer().frame(height: 15)

                // ── Scrubber ─────────────────────────────────────────────────
                ThumbnailScrubber(
                    videoURL: videoURL,
                    nativeDuration: nativeDuration,
                    targetDuration: targetDuration,
                    playheadProgress: playheadProgress,
                    clipInTime: $clipInTime
                )

                // ── Duration label ───────────────────────────────────────────
                Text(durationLabel)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)

                // ── Buttons ──────────────────────────────────────────────────
                buttonRow
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            }
        }
        .onAppear { setupPlayer() }
        .onChange(of: clipInTime) { _, t in
            // When user scrubs: stop playback and reset playhead.
            if isPlaying {
                player?.pause()
                isPlaying = false
                stopPlaybackTimer()
            }
            seekPlayer(to: t)
        }
    }

    // MARK: - Preview

    private var previewArea: some View {
        ZStack {
            if let p = player {
                AVPlayerRepresentable(player: p)
                    .background(Color.black)
            } else {
                Color.black
            }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { togglePlayback() }

            if !isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Duration label

    private var durationLabel: String {
        String(format: "%.1fs", nativeDuration)
    }

    // MARK: - Button row

    private var buttonRow: some View {
        HStack(spacing: 12) {
            Button {
                player?.pause()
                stopPlaybackTimer()
                dismiss()
            } label: {
                Text("返回")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Button {
                onConfirm(clipInTime)
                player?.pause()
                stopPlaybackTimer()
                dismiss()
            } label: {
                Text("确定")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color(red: 0.93, green: 0.20, blue: 0.20))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Player

    private func setupPlayer() {
        let p = AVPlayer(url: videoURL)
        p.isMuted = false
        player = p
        seekPlayer(to: 0)
    }

    private func seekPlayer(to time: Double) {
        let t = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: t,
                     toleranceBefore: .zero,
                     toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
    }

    private func togglePlayback() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
            stopPlaybackTimer()
        } else {
            // Seek to the current in-point so playback starts from the selection start.
            p.seek(to: CMTime(seconds: clipInTime, preferredTimescale: 600))
            p.play()
            isPlaying = true
            startPlaybackTimer()
        }
    }

    // MARK: - Playback timer (drives scrubber playhead)

    /// Fires every ~33 ms, reads player.currentTime() and updates playheadProgress.
    /// Automatically stops when the clip reaches the end of the selection window.
    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        let windowEnd = clipInTime + targetDuration
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            guard let p = player else { return }
            let t = p.currentTime().seconds
            if t >= windowEnd {
                // Clip played to end — stop and reset.
                p.pause()
                isPlaying = false
                playheadProgress = 0
                playbackTimer?.invalidate()
                playbackTimer = nil
                // Seek back to in-point so a second tap replays from the start.
                seekPlayer(to: clipInTime)
            } else {
                playheadProgress = max(0, (t - clipInTime) / targetDuration)
            }
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        playheadProgress = 0
    }
}

// MARK: - ThumbnailScrubber

/// Scrollable thumbnail strip with a fixed selection-window overlay and a playhead bar.
///
/// Scroll offset → clipInTime uses a UIScrollView delegate (not SwiftUI PreferenceKey)
/// so updates fire reliably during UIKit deceleration animations.
///
/// Thumbnail pixel size is multiplied by displayScale so Retina tiles are sharp.
private struct ThumbnailScrubber: View {

    let videoURL: URL
    let nativeDuration: Double
    let targetDuration: Double
    /// 0.0 – 1.0; drives the white playhead bar position within the window.
    let playheadProgress: Double
    @Binding var clipInTime: Double

    @Environment(\.displayScale) private var displayScale

    /// Points per second — 1 tile = 1 second.
    private let pps: CGFloat = 52
    private let tileH: CGFloat = 52
    private var windowW: CGFloat { CGFloat(targetDuration) * pps }
    private var tileCount: Int { max(1, Int(ceil(nativeDuration))) }

    /// Request thumbnails at full Retina resolution so tiles render sharply.
    private var tilePixelSize: CGSize {
        CGSize(width: pps * displayScale, height: tileH * displayScale)
    }

    var body: some View {
        GeometryReader { geo in
            let sidePad = max(0, geo.size.width / 2 - windowW / 2)

            ZStack(alignment: .center) {
                TrackingScrollView(
                    contentWidth: CGFloat(tileCount) * pps,
                    height: tileH,
                    horizontalInset: sidePad,
                    content: AnyView(thumbnailTiles),
                    onOffsetChange: { rawOffset in
                        let t = Double(rawOffset) / Double(pps)
                        clipInTime = max(0, min(t, nativeDuration - targetDuration))
                    }
                )

                // ── Fixed selection window border ─────────────────────────
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.yellow, lineWidth: 2.5)
                    .frame(width: windowW, height: tileH)
                    .allowsHitTesting(false)

                // ── Playhead bar ─────────────────────────────────────────
                // Stays within the yellow border and moves left→right as the clip plays.
                if playheadProgress > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2, height: tileH - 4)   // 2 pt inset top/bottom
                        // Offset from the ZStack centre:
                        //   progress 0 → left edge (-windowW/2), 1 → right edge (+windowW/2)
                        .offset(x: playheadProgress * windowW - windowW / 2)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: tileH + 8)
    }

    private var thumbnailTiles: some View {
        HStack(spacing: 0) {
            ForEach(0..<tileCount, id: \.self) { i in
                ThumbnailTile(
                    url:  videoURL,
                    time: Double(i) + 0.5,
                    size: tilePixelSize            // pixel-accurate for Retina
                )
                .frame(width: pps, height: tileH)
            }
        }
    }
}

// MARK: - TrackingScrollView

/// UIScrollView wrapper that fires `onOffsetChange` on every scroll tick via UIKit delegate.
/// Required because SwiftUI's PreferenceKey-based offset tracking doesn't fire during
/// UIScrollView deceleration animations.
private struct TrackingScrollView: UIViewRepresentable {

    let contentWidth: CGFloat
    let height: CGFloat
    let horizontalInset: CGFloat
    let content: AnyView
    var onOffsetChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOffsetChange: onOffsetChange) }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.alwaysBounceHorizontal = false
        sv.delegate = context.coordinator

        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: 0, y: 0, width: contentWidth, height: height)
        sv.addSubview(host.view)
        sv.contentSize = CGSize(width: contentWidth, height: height)
        sv.contentInset = UIEdgeInsets(top: 0, left: horizontalInset, bottom: 0, right: horizontalInset)
        sv.setContentOffset(CGPoint(x: -horizontalInset, y: 0), animated: false)

        context.coordinator.retain(host)
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        context.coordinator.onOffsetChange = onOffsetChange
        if sv.contentInset.left != horizontalInset {
            sv.contentInset = UIEdgeInsets(top: 0, left: horizontalInset, bottom: 0, right: horizontalInset)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var onOffsetChange: (CGFloat) -> Void
        private var retained: AnyObject?

        init(onOffsetChange: @escaping (CGFloat) -> Void) {
            self.onOffsetChange = onOffsetChange
        }

        func retain(_ obj: AnyObject) { retained = obj }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let rawOffset = scrollView.contentOffset.x + scrollView.contentInset.left
            onOffsetChange(max(0, rawOffset))
        }
    }
}

// MARK: - ThumbnailTile

private struct ThumbnailTile: View {

    let url: URL
    let time: Double
    let size: CGSize          // pixel dimensions (pt × displayScale)

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(white: 0.22)
            }
        }
        .clipped()
        .task(id: url.path + "_\(Int(time * 10))") {
            image = await ThumbnailProvider.shared.thumbnail(
                for: url, isImage: false, at: time, size: size
            )
        }
    }
}

#endif

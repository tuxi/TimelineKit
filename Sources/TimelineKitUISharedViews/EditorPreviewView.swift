import SwiftUI
import AVFoundation
import AVKit
import CoreText
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The media source currently rendered by the canvas.
///
/// P2.4A keeps the behavior unchanged but gives the preview one explicit
/// source model instead of scattered `previewAsset` branches.
public enum EditorCanvasSource: Equatable, Sendable {
    case timeline
    case browserAsset(EditorPreviewAsset)
}

public struct EditorCanvasSurface: View {
    @Bindable public var store: EditorStore
    public var source: EditorCanvasSource
    /// When set, this player is used instead of store.player (composition-based preview).
    public var compositionPlayer: AVPlayer? = nil
    /// TimelinePreviewView from CompositionCoordinator (set by umbrella layer).
    public var timelinePreviewView: TimelinePreviewView? = nil
    public var onExitBrowserPreview: (() -> Void)? = nil

    public init(
        store: EditorStore,
        source: EditorCanvasSource,
        compositionPlayer: AVPlayer? = nil,
        timelinePreviewView: TimelinePreviewView? = nil,
        onExitBrowserPreview: (() -> Void)? = nil
    ) {
        self.store = store
        self.source = source
        self.compositionPlayer = compositionPlayer
        self.timelinePreviewView = timelinePreviewView
        self.onExitBrowserPreview = onExitBrowserPreview
    }

    public var body: some View {
        ZStack {
            switch source {
            case .browserAsset(let asset):
                BrowserAssetCanvasRenderer(
                    asset: asset,
                    onExit: onExitBrowserPreview
                )

            case .timeline:
                timelineContent
            }
        }
        .aspectRatio(canvasAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var timelineContent: some View {
        // V6 P1 (Stage 1-2): For image-only timelines the Timeline Runtime
        // renders directly into `TimelinePreviewView`, bypassing AVVideoCompositing.
        // The AVPlayerRepresentable is hidden (not removed) so AVPlayer still
        // drives timing and audio even on the new path.
        if store.usesTimelineRuntime, let previewView = timelinePreviewView {
            TimelinePreviewRepresentable(previewView: previewView)
        } else if let player = compositionPlayer ?? store.player {
            AVPlayerRepresentable(player: player)
        } else {
            Color.black
        }

        // Text overlays: visible in legacy preview, transparent hit-test only
        // in TimelineRuntime because the actual pixels are drawn by
        // TextLayerComposer inside TimelineRenderer.
        GeometryReader { geo in
            ForEach(activeTextOverlays, id: \.seg.id) { item in
                if case .text(let content) = item.seg.content {
                    TextOverlayView(
                        segmentID: item.seg.id,
                        content: content,
                        containerSize: geo.size,
                        isEditing: store.selection.editingSegmentID == item.seg.id,
                        rendersContent: !store.usesTimelineRuntime,
                        onTap: {
                            store.selection.selectOnly(item.seg.id)
                        },
                        onDragChange: { pos in
                            store.previewTextPosition(segmentID: item.seg.id, position: pos)
                        },
                        onDragCommit: { pos in
                            store.updateTextPosition(segmentID: item.seg.id, position: pos)
                        }
                    )
                    .opacity(store.usesTimelineRuntime ? 1.0 : item.opacity)
                    // v4 (track-header-controls-spec §2.2): tapping a locked /
                    // hidden text segment should not enter edit mode — it's
                    // view-only. We still let the user select it so the
                    // segment action panel surfaces (which shows the lock /
                    // hide state and a clear path to toggle it off).
                    .allowsHitTesting(item.opacity == 1.0)
                }
            }
        }

        // Active subtitles: visible in legacy preview, transparent hit-test
        // only in TimelineRuntime.
        GeometryReader { geo in
            SubtitleStackView(
                items:         activeSubtitleOverlays,
                containerSize: geo.size,
                selectedID:    store.selection.singleSelectedID,
                rendersContent: !store.usesTimelineRuntime,
                onTap:         { id in store.selection.selectOnly(id) },
                onDragChange:  { id, y in store.previewSubtitlePosition(segmentID: id, positionY: y) },
                onDragCommit:  { id, y in store.updateSubtitlePosition(segmentID: id, positionY: y) }
            )
        }
        if store.isAwaitingAutomaticCanvas,
           !store.timeline.tracks.flatMap(\.segments).contains(where: {
               switch $0.content {
               case .audio: return false
               default: return true
               }
           }) {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title2)
                Text("添加视频或照片")
                    .font(.headline)
                Text("画布比例将随首个素材自动设置")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .allowsHitTesting(false)
        }
    }

    // MARK: - Computed

    private var canvasAspect: Double {
        let c = store.timeline.canvas
        return Double(c.width) / Double(c.height)
    }

    private var currentTime: Double { store.selection.playheadTime }

    /// v4 (track-header-controls-spec §2.2): pre-compute per-segment opacity so
    /// the preview canvas mirrors the timeline visual state for hidden / locked
    /// tracks (0.4 alpha = "temporarily hidden / locked, not deleted").
    /// Export still drops hidden tracks via CompositionBuilder; locked tracks
    /// remain in the export pipeline.
    fileprivate struct OverlayItem: Identifiable {
        let seg: EditorSegment
        let opacity: Double
        var id: UUID { seg.id }
    }

    private var activeTextOverlays: [OverlayItem] {
        var out: [OverlayItem] = []
        for track in store.timeline.tracks where track.kind == .text {
            let opacity: Double = (track.isHidden || track.isLocked) ? 0.4 : 1.0
            for seg in track.segments where seg.targetRange.contains(currentTime) {
                out.append(OverlayItem(seg: seg, opacity: opacity))
            }
        }
        return out
    }

    private var activeSubtitleOverlays: [OverlayItem] {
        var out: [OverlayItem] = []
        for track in store.timeline.tracks where track.kind == .subtitle {
            let opacity: Double = (track.isHidden || track.isLocked) ? 0.4 : 1.0
            for seg in track.segments where seg.targetRange.contains(currentTime) {
                out.append(OverlayItem(seg: seg, opacity: opacity))
            }
        }
        return out.sorted { $0.seg.targetRange.start < $1.seg.targetRange.start }
    }
}

public struct EditorPreviewView: View {
    @Bindable public var store: EditorStore
    /// When set, this player is used instead of store.player (composition-based preview).
    public var compositionPlayer: AVPlayer? = nil
    /// TimelinePreviewView from CompositionCoordinator (set by umbrella layer).
    public var timelinePreviewView: TimelinePreviewView? = nil
    /// Browser asset preview. When set, it replaces the timeline canvas without
    /// moving the timeline playhead.
    public var previewAsset: EditorPreviewAsset? = nil
    public var onExitPreview: (() -> Void)? = nil

    public init(
        store: EditorStore,
        compositionPlayer: AVPlayer? = nil,
        timelinePreviewView: TimelinePreviewView? = nil,
        previewAsset: EditorPreviewAsset? = nil,
        onExitPreview: (() -> Void)? = nil
    ) {
        self.store = store
        self.compositionPlayer = compositionPlayer
        self.timelinePreviewView = timelinePreviewView
        self.previewAsset = previewAsset
        self.onExitPreview = onExitPreview
    }

    public var body: some View {
        EditorCanvasSurface(
            store: store,
            source: source,
            compositionPlayer: compositionPlayer,
            timelinePreviewView: timelinePreviewView,
            onExitBrowserPreview: onExitPreview
        )
    }

    private var source: EditorCanvasSource {
        if let previewAsset {
            return .browserAsset(previewAsset)
        }
        return .timeline
    }
}

// MARK: - Browser asset preview

#if canImport(UIKit)
private typealias BrowserPreviewImage = UIImage

private struct AVPlayerPreviewViewControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(
        _ uiViewController: AVPlayerViewController,
        context: Context
    ) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        uiViewController.showsPlaybackControls = false
        uiViewController.videoGravity = .resizeAspect
    }
}
#else
private typealias BrowserPreviewImage = NSImage
#endif

struct BrowserAssetCanvasRenderer: View {
    let asset: EditorPreviewAsset
    let onExit: (() -> Void)?

    @State private var player = AVPlayer()
    @State private var playItem: AVPlayerItem?
    @State private var image: BrowserPreviewImage?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var wasPlayingBeforeScrub = false
    @State private var timeObserver: Any?

    var body: some View {
        ZStack {
            Color.black

            previewContent

            VStack {
                HStack(spacing: 8) {
                    Label("素材预览", systemImage: "rectangle.on.rectangle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Color.black.opacity(0.5),
                            in: Capsule()
                        )

                    Spacer(minLength: 8)

                    Button {
                        player.pause()
                        onExit?()
                    } label: {
                        Label("返回时间线", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                Color.black.opacity(0.5),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        if asset.kind != .image {
                            Button {
                                togglePlayback()
                            } label: {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(
                                        Color.white.opacity(0.16),
                                        in: Circle()
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))

                        Text(asset.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text(timeString(duration > 0 ? duration : (asset.duration ?? 0)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    if duration > 0 {
                        HStack(spacing: 8) {
                            Text(timeString(currentTime))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))

                            Slider(
                                value: Binding(
                                    get: { min(currentTime, duration) },
                                    set: { newValue in
                                        seekPreview(to: newValue)
                                    }
                                ),
                                in: 0...duration,
                                onEditingChanged: { editing in
                                    beginOrEndScrub(isEditing: editing)
                                }
                            )
                            .tint(.white)
                        }
                    }
                }
                .padding(8)
                .background(
                    Color.black.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
            .padding(12)
        }
        .task(id: asset.id) {
            await loadPreview()
        }
        .onDisappear {
            removeTimeObserver()
            player.pause()
            player.replaceCurrentItem(with: nil)
            playItem = nil
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch asset.kind {
        case .image:
            if let image {
                platformImageView(image)
            } else {
                ProgressView()
                    .tint(.white)
            }

        case .video:
            GeometryReader { geo in
                if playItem != nil {
                    #if canImport(UIKit)
                    AVPlayerPreviewViewControllerRepresentable(player: player)
                        .frame(
                            width: max(geo.size.width, 1),
                            height: max(geo.size.height, 1)
                        )
                    #else
                    AVPlayerRepresentable(player: player)
                        .frame(
                            width: max(geo.size.width, 1),
                            height: max(geo.size.height, 1)
                        )
                    #endif
                } else {
                    Color.black
                }
            }

        case .audio:
            VStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.white.opacity(0.75))

                Text(asset.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func platformImageView(_ image: BrowserPreviewImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
        #else
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
        #endif
    }

    private var icon: String {
        switch asset.kind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        }
    }

    @MainActor
    private func loadPreview() async {
        player.pause()
        player.replaceCurrentItem(with: nil)
        playItem = nil
        image = nil
        isPlaying = false
        isScrubbing = false
        wasPlayingBeforeScrub = false
        currentTime = 0
        duration = asset.duration ?? 0

        switch asset.kind {
        case .image:
            if let cgImage = await ThumbnailProvider.shared.thumbnail(
                for: asset.url,
                isImage: true,
                at: 0,
                size: CGSize(width: 1280, height: 720)
            ) {
                #if canImport(UIKit)
                image = UIImage(cgImage: cgImage)
                #else
                image = NSImage(cgImage: cgImage, size: .zero)
                #endif
            }

        case .video, .audio:
            configurePlayer()
        }
    }

    private func configurePlayer() {
        player.pause()
        let item = AVPlayerItem(url: asset.url)
        playItem = item
        player.replaceCurrentItem(with: item)

        if duration <= 0, let itemDuration = playItem?.duration,
           itemDuration.seconds.isFinite {
            duration = max(0, itemDuration.seconds)
        }
        installTimeObserverIfNeeded()
    }

    private func togglePlayback() {
        guard playItem != nil else { return }
        if player.rate > 0 {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0 && currentTime >= duration - 0.05 {
                seekPreview(to: 0)
            }
            player.play()
            isPlaying = true
        }
    }

    private func seekPreview(to seconds: Double) {
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

    private func beginOrEndScrub(isEditing: Bool) {
        if isEditing {
            isScrubbing = true
            wasPlayingBeforeScrub = isPlaying
            player.pause()
            isPlaying = false
        } else {
            isScrubbing = false
            if wasPlayingBeforeScrub {
                player.play()
                isPlaying = true
            }
            wasPlayingBeforeScrub = false
        }
    }

    private func installTimeObserverIfNeeded() {
        guard timeObserver == nil else { return }
        installTimeObserver(for: player)
    }

    private func installTimeObserver(for player: AVPlayer) {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { time in
            Task { @MainActor in
                guard !isScrubbing else { return }
                currentTime = max(0, time.seconds)
                if duration > 0, currentTime >= duration - 0.05 {
                    player.pause()
                    isPlaying = false
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - TextOverlayView

private struct TextOverlayView: View {
    let segmentID: UUID
    let content: SegmentContent.TextContent
    let containerSize: CGSize
    let isEditing: Bool
    let rendersContent: Bool

    var onTap: () -> Void
    var onDragChange: (NormalizedPoint) -> Void
    var onDragCommit: (NormalizedPoint) -> Void

    /// Position captured when drag begins — used as baseline for delta math.
    @State private var dragStartPosition: NormalizedPoint? = nil

    var body: some View {
        textView
            // v3 P1 fix: expand hit area to the entire padded text rect so taps just
            // outside the glyphs (e.g. on padding) still register, matching subtitle UX.
            .contentShape(Rectangle())
            .position(
                x: content.position.x * containerSize.width,
                y: content.position.y * containerSize.height
            )
            // Tap to select. Use `.onTapGesture` (matches SubtitleStackView pattern) so
            // tap is recognized reliably before the drag recognizer engages — the prior
            // `.simultaneousGesture(TapGesture)` form could lose to the drag recognizer
            // on real devices.
            .onTapGesture { onTap() }
            // Drag to reposition. minimumDistance: 4 keeps small taps out of the drag
            // recognizer so the tap above always wins for stationary touches.
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if dragStartPosition == nil {
                            dragStartPosition = content.position
                        }
                        guard let start = dragStartPosition else { return }
                        onDragChange(displaced(from: start, by: value.translation))
                    }
                    .onEnded { value in
                        guard let start = dragStartPosition else { return }
                        onDragCommit(displaced(from: start, by: value.translation))
                        dragStartPosition = nil
                    }
            )
    }

    // MARK: - Text View

    private var textView: some View {
        let style = content.style
        let horizontalPadding = CGFloat(style.paddingH)
        let verticalPadding = CGFloat(style.paddingV)
        let runtimeSafetyInset: CGFloat = rendersContent ? 0 : 6
        return Text(content.text)
            // v4 (text-style-fidelity-spec §4): resolveSwiftUIFont handles
            // fontName + weight + italic in one shot, producing a sheared font
            // for isItalic even when the chosen PostScript family lacks a true
            // italic variant (PingFangSC etc.).
            .font(resolveSwiftUIFont(
                fontName: style.fontName,
                weight:   style.fontWeight,
                italic:   style.isItalic,
                size:     scaledFontSize
            ))
            // .italic() omitted — the shear matrix in resolveSwiftUIFont
            // already produces the slant.
            .kerning(style.kerning)
            .lineSpacing(style.lineSpacing)
            .foregroundStyle(Color(hex: style.color) ?? .white)
            .opacity(rendersContent ? 1 : 0.001)
            .multilineTextAlignment(style.alignment.swiftUI)
            .frame(maxWidth: textLayoutWidth, alignment: style.alignment.frameAlignment)
            // v3 P4: stroke via 4-direction zero-radius shadows (SwiftUI Text has
            // no native stroke API). Applied BEFORE padding so the stroke hugs the
            // glyphs rather than the padded background rect.
            .modifier(TextStrokeModifier(
                color: style.strokeColor.flatMap { Color(hex: $0) },
                width: CGFloat(style.strokeWidth)
            ))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: textLayoutWidth + horizontalPadding * 2, alignment: style.alignment.frameAlignment)
            .background(
                RoundedRectangle(cornerRadius: style.backgroundRadius)
                    .fill(rendersContent ? (style.backgroundColor.flatMap { Color(hex: $0) } ?? .clear) : .clear)
            )
            // v3 P4: drop shadow.
            .shadow(
                color: style.shadowColor.flatMap { Color(hex: $0) } ?? .clear,
                radius: style.shadowRadius,
                x: style.shadowOffsetX,
                y: style.shadowOffsetY
            )
            // TimelineRuntime draws the actual text via CoreText. The transparent
            // SwiftUI layer only handles hit-testing/selection, so give its rect
            // a little breathing room to cover CoreText glyph overhang, stroke,
            // and shadow without changing rendered pixels.
            .padding(.horizontal, runtimeSafetyInset)
            .padding(.vertical, runtimeSafetyInset)
            .frame(
                maxWidth: textLayoutWidth + horizontalPadding * 2 + runtimeSafetyInset * 2,
                alignment: style.alignment.frameAlignment
            )
            // Selection indicator
            .overlay {
                if isEditing {
                    selectionBorder
                }
            }
    }

    private var selectionBorder: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                )
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(-6)

            // Move icon hint
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(3)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .offset(x: -12, y: -12)
        }
    }

    // MARK: - Helpers

    private var scaledFontSize: CGFloat {
        // Scale fontSize (designed for canvas width 720) to the displayed preview width
        CGFloat(content.style.fontSize) * (containerSize.width / 720.0)
    }

    private var textLayoutWidth: CGFloat {
        // Mirror SubtitleFrameBuilder.renderText:
        // maxWidth = renderSize.width - 120 * fontScale.
        // EditorPreviewView's text scale uses containerWidth / 720, so the same
        // side margin in preview points is 120 * containerWidth / 720.
        let fontScale = containerSize.width / 720.0
        let sideMargin = 120.0 * fontScale
        return max(24, containerSize.width - sideMargin)
    }

    /// Compute the new NormalizedPoint by adding a pixel translation to a start position.
    private func displaced(from start: NormalizedPoint, by translation: CGSize) -> NormalizedPoint {
        guard containerSize.width > 0, containerSize.height > 0 else { return start }
        let dx = translation.width  / containerSize.width
        let dy = translation.height / containerSize.height
        return NormalizedPoint(
            x: (start.x + dx).clamped(to: 0...1),
            y: (start.y + dy).clamped(to: 0...1)
        )
    }
}

// MARK: - Shared italic font resolver (v4 text-style-fidelity-spec §4)

/// Resolve a SwiftUI `Font` honoring `TextStyle.fontName / fontWeight / isItalic`.
///
/// SwiftUI's `.italic()` modifier silently no-ops when the underlying custom
/// PostScript font (e.g. PingFangSC) lacks a true italic variant — which is
/// the case for almost every CJK font. To match CapCut / 剪映 behavior the
/// resolver builds a `UIFont` with a shear `CGAffineTransform` matrix (c=0.2,
/// ≈11° slant) and wraps it via `Font(_:UIFont)`. Used by both `TextOverlayView`
/// and `SubtitleStackView` for live-preview parity with the export path's
/// `SubtitleFrameBuilder.resolveCTFont`.
private func resolveSwiftUIFont(
    fontName: String?,
    weight:   FontWeight,
    italic:   Bool,
    size:     CGFloat
) -> Font {
    let postScript = SystemFontCatalog.resolvePostScript(
        fontName: fontName, weight: weight
    )
    guard italic else { return .custom(postScript, size: size) }

    // Shear matrix fallback — works regardless of whether the font has a true
    // italic variant. Slant 0.2 ≈ 11° matches CapCut / 剪映 visual.
    // a=1, d=1 means no scaling; c=0.2 means horizontal shear only.
    let shear = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
#if canImport(UIKit)
    let baseDescriptor = UIFontDescriptor(name: postScript, size: size)
    let italicDescriptor = baseDescriptor.addingAttributes([
        .matrix: NSValue(cgAffineTransform: shear)
    ])
    // Pass size explicitly so the matrix's scale terms (a=1, d=1) don't
    // collapse the glyphs to 1pt.
    let uiFont = UIFont(descriptor: italicDescriptor, size: size)
    return Font(uiFont)
#else
    let baseDescriptor = NSFontDescriptor(name: postScript, size: size)
    // NSValue(cgAffineTransform:) is UIKit-only; construct via bytes on macOS.
    var shearCopy = shear
    let matrixValue = NSValue(bytes: &shearCopy, objCType: "{CGAffineTransform=dddddd}")
    let italicDescriptor = baseDescriptor.addingAttributes([
        .matrix: matrixValue
    ])
    let nsFont: NSFont = NSFont(descriptor: italicDescriptor, size: size)
        ?? NSFont.systemFont(ofSize: size)
    return Font(nsFont)
#endif
}

// MARK: - Shared text-stroke modifier (v3 P4 / v4 text-style-fidelity-spec §4)

/// 4-direction zero-radius shadow trick to fake a text stroke — SwiftUI `Text`
/// has no native stroke modifier. Looks close enough to the CoreText
/// `kCTStrokeWidthAttributeName` outline used at export time for typical
/// widths (1-8 pt). Used by both `TextOverlayView` (text segments) and
/// `SubtitleStackView` (subtitle segments) for 1:1 field parity.
private struct TextStrokeModifier: ViewModifier {
    let color: Color?
    let width: CGFloat

    func body(content: Content) -> some View {
        if let color, width > 0 {
            content
                .shadow(color: color, radius: 0, x:  width, y:  0)
                .shadow(color: color, radius: 0, x: -width, y:  0)
                .shadow(color: color, radius: 0, x:  0,     y:  width)
                .shadow(color: color, radius: 0, x:  0,     y: -width)
        } else {
            content
        }
    }
}

// MARK: - Subtitle Stack View

/// Renders all active subtitle segments, stacked from bottom upward (spec S-01/02/03).
private struct SubtitleStackView: View {
    /// v4 (track-header-controls-spec §2.2): items carry per-segment opacity so
    /// segments on hidden / locked tracks dim to 0.4 in the preview canvas,
    /// matching the timeline visual state.
    let items: [EditorCanvasSurface.OverlayItem]
    let containerSize: CGSize
    let selectedID: UUID?
    let rendersContent: Bool
    var onTap: (UUID) -> Void
    var onDragChange: (UUID, Double) -> Void
    var onDragCommit: (UUID, Double) -> Void

    private let defaultPaddingH: CGFloat = 20   // mirrors SubtitleFrameBuilder.subPadH
    private let defaultPaddingV: CGFloat = 10   // mirrors SubtitleFrameBuilder.subPadV
    private let defaultBgRadius: CGFloat = 4    // v3 baseline; only used when style.backgroundRadius == 0
    private let stackGap: CGFloat        = 8
    private let fadeDuration: Double     = 0.08
    @State private var dragStartY: [UUID: Double] = [:]

    var body: some View {
        ZStack {
            ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { idx, item in
                if case .subtitle(let c) = item.seg.content {
                    subtitleView(c, seg: item.seg, stackIndex: idx, opacity: item.opacity)
                }
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }

    @ViewBuilder
    private func subtitleView(
        _ content: SegmentContent.SubtitleContent,
        seg: EditorSegment,
        stackIndex: Int,
        opacity: Double
    ) -> some View {
        let style      = content.style
        let fontSize   = CGFloat(style.fontSize)
        let fontScale  = containerSize.width / 720
        let scaledSize = fontSize * fontScale

        // v4 (text-style-fidelity-spec §4): honor TextStyle paddings + bg radius
        // when set; fall back to v3 subtitle defaults so existing drafts look
        // identical to before. fontSize-based vertical span is recomputed with
        // the resolved padV so layout stays correct under custom padding.
        let padH:     CGFloat = (style.paddingH > 0         ? CGFloat(style.paddingH)         : defaultPaddingH) * fontScale
        let padV:     CGFloat = (style.paddingV > 0         ? CGFloat(style.paddingV)         : defaultPaddingV) * fontScale
        let bgRadius: CGFloat = (style.backgroundRadius > 0 ? CGFloat(style.backgroundRadius) : defaultBgRadius) * fontScale
        let scaledStackGap = stackGap * fontScale

        let frameW     = max(24, containerSize.width - 120 * fontScale)
        let layout     = subtitleLayoutMetrics(
            content: content,
            style: style,
            scaledSize: scaledSize,
            fontScale: fontScale,
            padH: padH,
            padV: padV,
            maxWidth: frameW
        )

        let baseWeight  = style.fontWeight
        let textColor   = Color(hex: style.color) ?? .white
        let bgColor     = Color(hex: style.backgroundColor ?? "#00000000")
                       ?? Color.black.opacity(0.6)

        // positionY: fraction from top in UIKit Y-down (matches SubtitleFrameBuilder).
        // Use the measured CoreText background height, not a single-line estimate,
        // so the transparent edit box stays aligned with rendered multiline subtitles.
        let centerY: CGFloat = content.positionY.map {
            containerSize.height * CGFloat($0)
        } ?? defaultSubtitleCenterY(
            backgroundHeight: layout.backgroundSize.height,
            bottomMargin: 60 * fontScale
        )
        let stackedCenterY = centerY - CGFloat(stackIndex) * (layout.backgroundSize.height + scaledStackGap)
        let isSelected = selectedID == seg.id

        // Build Text: per-segment colour/weight when available, plain text otherwise.
        let label = buildSubtitleText(content: content,
                                      defaultColor:    textColor,
                                      defaultWeight:   baseWeight,
                                      defaultFontName: style.fontName,
                                      italic:          style.isItalic,
                                      scaledSize:      scaledSize)

        label
            // v4 (text-style-fidelity-spec §4): full 12-field consumption — same
            // attribute chain as TextOverlayView for live-preview parity.
            // .italic() omitted: italic is baked into the Font built inside
            // buildSubtitleText via resolveSwiftUIFont's shear-matrix fallback.
            .kerning(style.kerning)
            .lineSpacing(style.lineSpacing)
            .multilineTextAlignment(style.alignment.swiftUI)
            // Stroke applied BEFORE padding so the outline hugs the glyphs.
            .modifier(TextStrokeModifier(
                color: style.strokeColor.flatMap { Color(hex: $0) },
                width: CGFloat(style.strokeWidth)
            ))
            .frame(
                width: layout.textSize.width,
                height: layout.textSize.height,
                alignment: style.alignment.frameAlignment
            )
            .padding(.horizontal, padH)
            .padding(.vertical, padV)
            // Shrink-wrap background to CoreText's measured text rect; cap at
            // the same max width used by the renderer.
//            .frame(
//                width: layout.backgroundSize.width,
//                height: layout.backgroundSize.height,
//                alignment: style.alignment.frameAlignment
//            )
            .background(
                RoundedRectangle(cornerRadius: bgRadius)
                    .fill(rendersContent ? bgColor : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: bgRadius)
                            .strokeBorder(Color.yellow, lineWidth: isSelected ? 1.5 : 0)
                    )
            )
            .background(
                Rectangle().fill(rendersContent ? .clear : Color.white.opacity(0.001))
            )
            .opacity(rendersContent ? opacity : 1.0)
            .contentShape(Rectangle())
            .shadow(
                color: rendersContent ? (style.shadowColor.flatMap { Color(hex: $0) } ?? .clear) : .clear,
                radius: style.shadowRadius,
                x: style.shadowOffsetX,
                y: style.shadowOffsetY
            )
            .position(x: containerSize.width / 2, y: stackedCenterY)
            // v4 (track-header-controls-spec §2.2): dim subtitles from hidden /
            // locked tracks. allowsHitTesting prevents accidental tap-edit on
            // a locked subtitle (selection on the timeline still works).
            .allowsHitTesting(opacity == 1.0)
            .onTapGesture { onTap(seg.id) }
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if dragStartY[seg.id] == nil {
                            dragStartY[seg.id] = content.positionY ?? defaultSubtitlePositionY(
                                backgroundHeight: layout.backgroundSize.height,
                                bottomMargin: 60 * fontScale
                            )
                        }
                        guard let start = dragStartY[seg.id],
                              containerSize.height > 0
                        else { return }
                        let y = (start + Double(value.translation.height / containerSize.height))
                            .clamped(to: 0...1)
                        onDragChange(seg.id, y)
                    }
                    .onEnded { value in
                        guard let start = dragStartY[seg.id],
                              containerSize.height > 0
                        else { return }
                        let y = (start + Double(value.translation.height / containerSize.height))
                            .clamped(to: 0...1)
                        onDragCommit(seg.id, y)
                        dragStartY[seg.id] = nil
                    }
            )
            .transition(.opacity.animation(.linear(duration: fadeDuration)))
            .id(seg.id)
    }

    private func defaultSubtitlePositionY(
        backgroundHeight: CGFloat,
        bottomMargin: CGFloat
    ) -> Double {
        guard containerSize.height > 0 else { return 0.85 }
        let defaultCenterY = defaultSubtitleCenterY(
            backgroundHeight: backgroundHeight,
            bottomMargin: bottomMargin
        )
        return Double(defaultCenterY / containerSize.height).clamped(to: 0...1)
    }

    private func defaultSubtitleCenterY(
        backgroundHeight: CGFloat,
        bottomMargin: CGFloat
    ) -> CGFloat {
        containerSize.height - backgroundHeight / 2 - bottomMargin
    }

    private func subtitleLayoutMetrics(
        content: SegmentContent.SubtitleContent,
        style: TextStyle,
        scaledSize: CGFloat,
        fontScale: CGFloat,
        padH: CGFloat,
        padV: CGFloat,
        maxWidth: CGFloat
    ) -> (textSize: CGSize, backgroundSize: CGSize) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment.nsTextAlignment
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = CGFloat(style.lineSpacing) * fontScale

        let textColor = SubtitleFrameBuilder.parseHexColor(style.color) ?? CGColor(gray: 1, alpha: 1)
        let ctColorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let ctFont = SubtitleFrameBuilder.resolveCTFont(
            fontSize: scaledSize,
            weight: style.fontWeight.rawValue,
            fontName: style.fontName,
            italic: style.isItalic
        )

        var baseAttributes: [NSAttributedString.Key: Any] = [
            .font: ctFont,
            ctColorKey: textColor,
            .paragraphStyle: paragraph
        ]
        if style.kerning != 0 {
            baseAttributes[.kern] = CGFloat(style.kerning) * fontScale
        }
        if style.strokeWidth > 0,
           let strokeHex = style.strokeColor,
           let strokeColor = SubtitleFrameBuilder.parseHexColor(strokeHex) {
            baseAttributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = strokeColor
            baseAttributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] =
                -(CGFloat(style.strokeWidth) * fontScale / max(scaledSize, 0.001)) * 100
        }

        let attributed: NSAttributedString
        if let segments = content.segments,
           !segments.isEmpty,
           segments.map(\.text).joined() == content.text {
            let mutable = NSMutableAttributedString()
            for segment in segments {
                var attributes = baseAttributes
                if let colorHex = segment.color,
                   let segmentColor = SubtitleFrameBuilder.parseHexColor(colorHex) {
                    attributes[ctColorKey] = segmentColor
                }
                if let weight = segment.fontWeight?.rawValue {
                    attributes[.font] = SubtitleFrameBuilder.resolveCTFont(
                        fontSize: scaledSize,
                        weight: weight,
                        fontName: style.fontName,
                        italic: style.isItalic
                    )
                }
                mutable.append(NSAttributedString(string: segment.text, attributes: attributes))
            }
            attributed = mutable
        } else {
            attributed = NSAttributedString(string: content.text, attributes: baseAttributes)
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let measured = SubtitleFrameBuilder.measureTextLayout(
            framesetter: framesetter,
            constraintWidth: maxWidth
        ).size
        let fallbackTextSize = CGSize(width: max(1, maxWidth), height: max(1, scaledSize * 1.6))
        let textSize = measured.width > 0 && measured.height > 0 ? measured : fallbackTextSize
        let backgroundSize = CGSize(
            width: min(textSize.width + padH * 2, maxWidth),
            height: textSize.height + padV * 2
        )
        return (textSize, backgroundSize)
    }

    /// Build a SwiftUI `Text` that mirrors per-segment colour/weight from `SubtitleSegmentItem`.
    /// Falls back to plain `content.text` with the global style when no segments are defined.
    ///
    /// v4 (text-style-fidelity-spec §4): `defaultFontName` is the segment's
    /// `TextStyle.fontName`. Resolved via `SystemFontCatalog` so user-selected
    /// font families (e.g. 宋体 / 楷体) render in the live preview, matching
    /// the export path's `makeCTFont(fontName:)`.
    private func buildSubtitleText(
        content:         SegmentContent.SubtitleContent,
        defaultColor:    Color,
        defaultWeight:   FontWeight,
        defaultFontName: String?,
        italic:          Bool,
        scaledSize:      CGFloat
    ) -> Text {
        // v4 fix (字幕双份存在的根因): SubtitleContent holds BOTH `text` (full
        // string) AND `segments[]` (per-segment text + highlight style). When
        // the user edits the subtitle text via TextEditPanel only `text`
        // updates — `segments` stays at the original JSON-imported value.
        // The renderer here previously preferred `segments` (highlight path),
        // which made the preview show the *old* text even after the panel
        // and the persisted draft both reflected the new text.
        //
        // Fix: only use `segments` when its concatenation still matches
        // `text`. Otherwise treat segments as stale and render the canonical
        // `text` with the global style (losing highlight info, which is
        // expected — the user rewrote the line).
        if let segs = content.segments, !segs.isEmpty,
           segs.map(\.text).joined() == content.text {
            // Concatenate per-segment Text views (SwiftUI supports + operator on Text).
            return segs.reduce(Text("")) { acc, seg in
                let color  = seg.color.flatMap { Color(hex: $0) } ?? defaultColor
                let weight = seg.fontWeight ?? defaultWeight
                return acc + Text(seg.text)
                    .font(resolveSwiftUIFont(
                        fontName: defaultFontName,
                        weight:   weight,
                        italic:   italic,
                        size:     scaledSize
                    ))
                    .foregroundStyle(rendersContent ? color : .clear)
            }
        }
        // No per-segment info, or segments are stale relative to text.
        // foregroundStyle MUST be set here; without it SwiftUI falls back to
        // the environment label color (black), ignoring defaultColor entirely.
        return Text(content.text)
            .font(resolveSwiftUIFont(
                fontName: defaultFontName,
                weight:   defaultWeight,
                italic:   italic,
                size:     scaledSize
            ))
            .foregroundStyle(rendersContent ? defaultColor : .clear)
    }
}

// MARK: - Color Hex helper

extension Color {
    public init?(hex: String) {
        let h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard h.count == 6 || h.count == 8 else { return nil }
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r, g, b, a: Double
        if h.count == 6 {
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8)  & 0xFF) / 255
            b = Double(int & 0xFF) / 255
            a = 1
        } else {
            r = Double((int >> 24) & 0xFF) / 255
            g = Double((int >> 16) & 0xFF) / 255
            b = Double((int >> 8)  & 0xFF) / 255
            a = Double(int & 0xFF) / 255
        }
        self.init(red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - TextAlignment → SwiftUI

private extension TimelineKitCore.TextAlignment {
    var swiftUI: SwiftUI.TextAlignment {
        switch self {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - Double clamping

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

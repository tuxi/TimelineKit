#if canImport(UIKit)
import UIKit
import os

/// The core UIKit canvas that renders all tracks, segments, and the playhead.
///
/// Architecture:
/// - Each EditorTrack → one TrackRowView (horizontal band)
/// - Each EditorSegment within a track → one SegmentBlockView (positioned by targetRange)
/// - TrackLayout converts time ↔ pixels
/// - Playhead is a CALayer for smooth animation
///
/// Gesture separation:
/// - UIScrollView handles horizontal scroll
/// - Trim handles use UIPanGestureRecognizer (high priority, narrow hit area)
/// - Pinch zoom is handled by ClipEditorViewController on the scroll view
/// - Long-press on a segment block activates compact reorder mode for that track
final class TrackCanvasView: UIView {

    // MARK: - Layout Constants

    static let rulerHeight: CGFloat        = 36
    static let trackHeight: CGFloat        = 50
    static let trackSpacing: CGFloat       = 3
    static let leftPadding: CGFloat        = 16
    static let rightPadding: CGFloat       = 32
    static let minPixelsPerSecond: CGFloat = 20
    static let maxPixelsPerSecond: CGFloat = 600
    /// V5.1: 空 timeline 进入剪辑器时的初始 pps。
    /// 1s ≈ 60pt（剪映 / CapCut 风格），3s 图片 ≈ 180pt，约半屏宽，避免空 timeline
    /// 被 fittedPPS 算成 availableWidth/0.1 的巨大值导致新增素材爆缩略图。
    static let defaultPixelsPerSecond: CGFloat = 60

    /// Standard segment block visual parameters.
    enum SegmentVisuals {
        static let cornerRadius: CGFloat = 4
        static let selectedBorderWidth: CGFloat = 2
        static let blockVPadding: CGFloat = 4     // vertical padding inside track row
        static let handleBarInset: CGFloat = 4     // top/bottom inset of the handle bar

        static func blockColor(for kind: EditorTrack.Kind) -> UIColor {
            // Opacity gradient: main video stays heaviest, audio raised for
            // visual hierarchy, overlay/text/subtitle/adjustment unified as
            // lighter auxiliary tracks so the main video reads as primary.
            switch kind {
            case .video:      return UIColor.systemPurple.withAlphaComponent(0.75)
            case .overlay:    return UIColor.systemOrange.withAlphaComponent(0.55)
            case .text:       return UIColor.systemGreen.withAlphaComponent(0.55)
            case .subtitle:   return UIColor.systemBlue.withAlphaComponent(0.55)
            case .audio:      return UIColor.systemTeal.withAlphaComponent(0.65)
            case .adjustment: return UIColor.systemYellow.withAlphaComponent(0.55)
            }
        }

        static let selectedBorderColor = UIColor.systemYellow

        /// Fixed canvas display order: video → overlay → text → subtitle → audio → adjustment.
        static let trackDisplayOrder: [EditorTrack.Kind] = [
            .video, .overlay, .text, .subtitle, .audio, .adjustment
        ]

        /// Sort tracks by the fixed display order.
        static func sortedTracks(_ tracks: [EditorTrack]) -> [EditorTrack] {
            tracks.sorted { a, b in
                let ai = trackDisplayOrder.firstIndex(of: a.kind) ?? 99
                let bi = trackDisplayOrder.firstIndex(of: b.kind) ?? 99
                if ai == bi { return a.id.uuidString < b.id.uuidString }
                return ai < bi
            }
        }
    }

    // MARK: - Properties

    private var timeline: EditorTimeline?
    private(set) var layout: TrackLayout = .empty
    private(set) var currentPixelsPerSecond: CGFloat = minPixelsPerSecond

    private var rulerView: RulerView!
    private var trackRows: [UUID: TrackRowView] = [:]
    private var playheadLayer: CALayer!

    /// Transition badges: keyed by "leadingID–trailingID" string for fast lookup.
    private var transitionBadges: [String: TransitionBadgeView] = [:]

    /// Called when user finishes trimming a segment.
    /// `newSourceRangeStart` is non-nil only when the left handle extended outward.
    var onTrimCommit: ((UUID, TimeRange, Double?) -> Void)?

    /// Called during a trim drag for overlay/subtitle tracks to update preview in real-time.
    var onTrimPreview: ((UUID, TimeRange) -> Void)?

    /// Called when long-press reorder finishes — store should reorder and re-pack.
    var onReorderCommit: ((UUID, [UUID]) -> Void)?

    /// Called when a non-main-track segment is dragged to a new start time.
    var onMoveCommit: ((UUID, Double) -> Void)?

    /// Lock/unlock the scroll view during a free-pan drag so the timeline doesn't drift.
    var onScrollLock: ((Bool) -> Void)?

    /// Called when user taps a cut-point badge (leadingID, trailingID, existing transition or nil).
    var onTransitionTap: ((UUID, UUID, EditorTransition?) -> Void)?

    /// Called when the user taps the empty-state affordance on a user-created empty track.
    var onEmptyTrackAdd: ((UUID, EditorTrack.Kind) -> Void)?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = UIColor(white: 0.1, alpha: 1)

        rulerView = RulerView()
        addSubview(rulerView)

        playheadLayer = CALayer()
        playheadLayer.backgroundColor = UIColor.systemRed.cgColor
        playheadLayer.frame = CGRect(x: 0, y: 0, width: 2, height: 1000)
        layer.addSublayer(playheadLayer)
    }

    // MARK: - Public API

    func configure(timeline: EditorTimeline, availableWidth: CGFloat) {
        self.timeline = timeline
        // V5.1 BUG 2: 空 timeline 走默认 pps，避免 fittedPPS 把 duration=0 膨胀为 0.1s
        // 导致 availableWidth/0.1 算出数千 pps，新增素材瞬间生成海量缩略图。
        if currentPixelsPerSecond == Self.minPixelsPerSecond {
            if timeline.duration < 0.5 {
                currentPixelsPerSecond = Self.defaultPixelsPerSecond
            } else {
                currentPixelsPerSecond = TrackLayout.fittedPPS(duration: timeline.duration, availableWidth: availableWidth)
            }
        }
        layout = TrackLayout(duration: timeline.duration, pixelsPerSecond: currentPixelsPerSecond)
        applyLayout(timeline: timeline)
        rebuildTrackRows(timeline: timeline, availableWidth: availableWidth)
        rebuildTransitionBadges(timeline: timeline)
    }

    @discardableResult
    func zoom(to pixelsPerSecond: CGFloat, playheadTime: Double) -> Void {
        guard let timeline else { return }
        currentPixelsPerSecond = pixelsPerSecond.clamped(to: Self.minPixelsPerSecond...Self.maxPixelsPerSecond)
        layout = TrackLayout(duration: timeline.duration, pixelsPerSecond: currentPixelsPerSecond)
        applyLayout(timeline: timeline)
        for (_, row) in trackRows { row.relayout(layout: layout) }
        updatePlayhead(time: playheadTime)
    }

    /// Lightweight update for trim/move changes: repositions blocks without
    /// rebuilding gesture recognizers or destroying active gestures.
    func relayoutSegments(timeline: EditorTimeline) {
        self.timeline = timeline
        layout = TrackLayout(duration: timeline.duration, pixelsPerSecond: currentPixelsPerSecond)
        applyLayout(timeline: timeline)
        let assetByID = Dictionary(uniqueKeysWithValues: timeline.materials.all.map { ($0.id, $0) })
        for track in timeline.tracks {
            trackRows[track.id]?.update(track: track, layout: layout, materialAssets: assetByID)
        }
        rebuildTransitionBadges(timeline: timeline)
    }

    func updatePlayhead(time: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadLayer.frame.origin.x = layout.x(for: time)
        CATransaction.commit()
    }

    func updateSelection(ids: Set<UUID>) {
        for (_, row) in trackRows { row.updateSelection(ids: ids) }
    }

    /// Briefly flashes a yellow border around the given segment blocks.
    /// Used to acknowledge newly-appeared segments (split / insert).
    /// Safe to call with IDs that don't yet exist in any row — they're skipped.
    func flashSegments(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for (_, row) in trackRows {
            for (id, view) in row.segmentViews where ids.contains(id) {
                let savedWidth = view.layer.borderWidth
                let savedColor = view.layer.borderColor
                view.layer.borderWidth = 2
                view.layer.borderColor = UIColor.systemYellow.cgColor
                UIView.animate(
                    withDuration: 0.35,
                    delay: 0.10,
                    options: [.curveEaseOut, .allowUserInteraction]
                ) {
                    view.layer.borderWidth = savedWidth
                    view.layer.borderColor = savedColor
                }
            }
        }
    }

    /// All segment IDs currently rendered. Used by the view controller to diff
    /// new vs. existing segments across timeline updates.
    var renderedSegmentIDs: Set<UUID> {
        var set: Set<UUID> = []
        for (_, row) in trackRows {
            for id in row.segmentViews.keys { set.insert(id) }
        }
        return set
    }

    func time(at x: CGFloat) -> Double { layout.time(at: x) }
    func x(for time: Double) -> CGFloat { layout.x(for: time) }

    func segmentID(at point: CGPoint) -> UUID? {
        for (_, row) in trackRows {
            let local = convert(point, to: row)
            if let id = row.segmentID(at: local) { return id }
        }
        return nil
    }

    func addPlayheadGesture(_ gr: UIGestureRecognizer) {
        rulerView.addGestureRecognizer(gr)
    }

    func isMainTrackSegment(id: UUID) -> Bool {
        timeline?.mainTrack?.segment(id: id) != nil
    }

    /// Auto-scroll the timeline when a trim handle drag reaches the visible edge.
    /// Speed ramps from 0 to maxSpeed as the touch moves deeper into the edge zone.
    private func handleAutoScroll(touchInWindow: CGPoint) {
        guard let sv = superview as? UIScrollView else { return }
        let touchInScroll = sv.convert(touchInWindow, from: nil)
        let edgeZone: CGFloat = 60
        let maxSpeed: CGFloat = 8   // points per .changed tick

        let leftEdge  = sv.contentOffset.x + edgeZone
        let rightEdge = sv.contentOffset.x + sv.bounds.width - edgeZone

        if touchInScroll.x < leftEdge {
            let speed = min(maxSpeed, (leftEdge - touchInScroll.x) / edgeZone * maxSpeed)
            sv.contentOffset.x = max(0, sv.contentOffset.x - speed)
        } else if touchInScroll.x > rightEdge {
            let speed = min(maxSpeed, (touchInScroll.x - rightEdge) / edgeZone * maxSpeed)
            let maxX = sv.contentSize.width - sv.bounds.width
            sv.contentOffset.x = min(maxX, sv.contentOffset.x + speed)
        }
    }

    // MARK: - Private

    private func applyLayout(timeline: EditorTimeline) {
        let totalHeight = Self.rulerHeight + CGFloat(timeline.tracks.count) * (Self.trackHeight + Self.trackSpacing)
        let totalWidth  = layout.totalWidth + Self.rightPadding
        let contentSize = CGSize(width: totalWidth, height: max(totalHeight, 200))

        frame.size = contentSize
        if let sv = superview as? UIScrollView {
            sv.contentSize = contentSize
        }

        rulerView.frame = CGRect(x: 0, y: 0, width: totalWidth, height: Self.rulerHeight)
        rulerView.configure(layout: layout)

        playheadLayer.frame.size = CGSize(width: 2, height: contentSize.height)
    }

    private func rebuildTrackRows(timeline: EditorTimeline, availableWidth: CGFloat) {
        trackRows.values.forEach { $0.removeFromSuperview() }
        trackRows.removeAll()

        // Pre-compute source durations for trim handle right-cap.
        // Priority: AVURLAsset.duration (loaded file) > asset.nativeDuration (importer-set).
        // Rules:
        //   - ai_video             → nativeDuration = sceneRange.duration
        //   - image_3d / motion    → nativeDuration = sceneRange.duration
        //   - static image         → no nativeDuration, no AVURLAsset duration → no cap
        //   - text / subtitle      → placeholder asset, no URL → no cap
        let allAssets = timeline.materials.all
        let assetByID = Dictionary(uniqueKeysWithValues: allAssets.map { ($0.id, $0) })

        var sourceDurationMap: [UUID: Double] = [:]
        for asset in allAssets {
            if let url = asset.bestURL {
                let avAsset = AssetCache.shared.asset(for: url)
                let dur = avAsset.duration
                if dur.isNumeric && dur.seconds > 0 {
                    sourceDurationMap[asset.id] = dur.seconds
                }
            }
            // Fallback: nativeDuration recorded at import time.
            // Covers: image assets (no AVURLAsset video duration) and ai_video before
            // the AVURLAsset has been loaded asynchronously.
            if sourceDurationMap[asset.id] == nil, let nd = asset.nativeDuration, nd > 0 {
                sourceDurationMap[asset.id] = nd
            }
        }
        // Static images have no nativeDuration — ensure their cap entry is nil.
        // IMPORTANT: do NOT key this on motionPreset/depthEffect being nil, because
        // image_motion and image_3d may have nil content fields when the server sends
        // an unrecognized animation type. Use nativeDuration presence instead:
        // if the asset was given a nativeDuration at import time it is a timed clip;
        // if not, it is a static image that may stretch freely.
        for track in timeline.tracks {
            for seg in track.segments {
                guard case .image = seg.content else { continue }
                let nd = assetByID[seg.materialID]?.nativeDuration
                if (nd ?? 0) <= 0 {
                    sourceDurationMap[seg.materialID] = nil
                }
            }
        }

        // Fixed track display order: video → overlay → text → subtitle → audio → adjustment.
        let orderedTracks = SegmentVisuals.sortedTracks(timeline.tracks)

        var yOffset = Self.rulerHeight
        for track in orderedTracks {
            let row = TrackRowView(
                track: track,
                layout: layout,
                availableWidth: availableWidth,
                sourceDurations: sourceDurationMap,
                materialAssets: assetByID
            ) { [weak self] segID, range, newSrcStart in
                self?.onTrimCommit?(segID, range, newSrcStart)
            }
            row.onTrimPreview = { [weak self] segID, range in
                self?.onTrimPreview?(segID, range)
            }
            row.onReorderCommit = { [weak self] trackID, newOrder in
                self?.onReorderCommit?(trackID, newOrder)
            }
            row.onMoveCommit = { [weak self] segID, newStart in
                self?.onMoveCommit?(segID, newStart)
            }
            row.onScrollLock = { [weak self] lock in
                self?.onScrollLock?(lock)
            }
            row.onAutoScroll = { [weak self] touchInWindow in
                self?.handleAutoScroll(touchInWindow: touchInWindow)
            }
            row.onEmptyTrackAdd = { [weak self] trackID, kind in
                self?.onEmptyTrackAdd?(trackID, kind)
            }
            row.frame = CGRect(x: 0, y: yOffset, width: layout.totalWidth, height: Self.trackHeight)
            addSubview(row)
            trackRows[track.id] = row
            yOffset += Self.trackHeight + Self.trackSpacing
        }
    }

    // MARK: - Transition Badges

    /// Rebuilds or repositions diamond badges at every cut-point on the main track.
    /// Badges for transitions that already exist show filled; bare cut-points show outline.
    private func rebuildTransitionBadges(timeline: EditorTimeline) {
        guard let mainTrack = timeline.mainTrack else {
            transitionBadges.values.forEach { $0.removeFromSuperview() }
            transitionBadges.removeAll()
            return
        }

        let mainTrackRow = trackRows[mainTrack.id]
        let rowY = mainTrackRow.map { convert($0.frame.origin, from: $0.superview) }.map { $0.y }
                   ?? Self.rulerHeight

        // Build the set of cut-point pairs from adjacent main-track segments.
        let segs = mainTrack.segments.sorted { $0.targetRange.start < $1.targetRange.start }
       
        var neededKeys = Set<String>()
        let transitionByLeading = Dictionary(
            uniqueKeysWithValues: timeline.transitions.map { ($0.leadingSegmentID, $0) }
        )

        let badgeSize: CGFloat = 20
        let badgeHalf = badgeSize / 2
        if !segs.isEmpty {
            for i in 0..<(segs.count - 1) {
                let leading  = segs[i]
                let trailing = segs[i + 1]
                let key      = "\(leading.id)–\(trailing.id)"
                neededKeys.insert(key)

                let cutX = layout.x(for: leading.targetRange.end)
                let existing = transitionByLeading[leading.id]

                if let badge = transitionBadges[key] {
                    // Reposition existing badge
                    badge.frame = CGRect(x: cutX - badgeHalf, y: rowY - badgeHalf,
                                         width: badgeSize, height: badgeSize)
                    badge.transition = existing
                } else {
                    // Create new badge
                    let badge = TransitionBadgeView(frame: CGRect(x: cutX - badgeHalf, y: rowY - badgeHalf,
                                                                  width: badgeSize, height: badgeSize))
                    badge.transition = existing
                    badge.onTap = { [weak self, leading, trailing, weak badge] in
                        self?.onTransitionTap?(leading.id, trailing.id, badge?.transition)
                    }
                    addSubview(badge)
                    bringSubviewToFront(badge)
                    transitionBadges[key] = badge
                }
            }
        }

        // Remove stale badges (segments deleted or reordered)
        for key in Set(transitionBadges.keys).subtracting(neededKeys) {
            transitionBadges[key]?.removeFromSuperview()
            transitionBadges[key] = nil
        }
    }
}

// MARK: - TrackLayout

@MainActor
struct TrackLayout {
    let duration: Double
    let pixelsPerSecond: CGFloat
    let totalWidth: CGFloat

    static let empty = TrackLayout(duration: 1, pixelsPerSecond: TrackCanvasView.minPixelsPerSecond)

    static func fittedPPS(duration: Double, availableWidth: CGFloat) -> CGFloat {
        // V5.1 BUG 2: 空 / 极短 timeline 不再硬膨胀为 0.1s（会把 pps 算成 availableWidth/0.1
        // 几千的天文数字），直接走默认 pps。
        if duration < 0.5 { return TrackCanvasView.defaultPixelsPerSecond }
        return max(availableWidth / CGFloat(duration), TrackCanvasView.minPixelsPerSecond)
    }

    init(duration: Double, pixelsPerSecond: CGFloat) {
        // V5.1 BUG 2: totalWidth 计算用 max(duration, 1.0) 兜底，避免空 timeline 时
        // 内容宽度只有 ~6pt 看起来像「卡住」；self.duration 保留原值，让 ruler 等消费者
        // 看到真实时间线长度。
        let d   = max(duration, 0)
        let pps = pixelsPerSecond.clamped(to: TrackCanvasView.minPixelsPerSecond...TrackCanvasView.maxPixelsPerSecond)
        self.duration        = d
        self.pixelsPerSecond = pps
        self.totalWidth      = CGFloat(max(d, 1.0)) * pps + TrackCanvasView.leftPadding
    }

    func x(for time: Double) -> CGFloat {
        TrackCanvasView.leftPadding + CGFloat(time) * pixelsPerSecond
    }

    func width(for duration: Double) -> CGFloat {
        CGFloat(duration) * pixelsPerSecond
    }

    func time(at x: CGFloat) -> Double {
        Double(max(0, x - TrackCanvasView.leftPadding)) / Double(pixelsPerSecond)
    }

    func timeDelta(for dx: CGFloat) -> Double {
        Double(dx) / Double(pixelsPerSecond)
    }
}

// MARK: - RulerView

final class RulerView: UIView {
    private var layout: TrackLayout = .empty

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.14, alpha: 1)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(layout: TrackLayout) {
        self.layout = layout
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let tickColor  = UIColor.white.withAlphaComponent(0.3)
        let labelColor = UIColor.white.withAlphaComponent(0.6)

        let minorInterval = tickInterval(pixelsPerSecond: layout.pixelsPerSecond)
        let majorInterval = minorInterval * 5

        var t: Double = 0
        while t <= layout.duration + minorInterval {
            let x = layout.x(for: t)
            let isMajor = t.truncatingRemainder(dividingBy: majorInterval) < minorInterval * 0.5
            let tickH: CGFloat = isMajor ? 14 : 7
            ctx.setFillColor(tickColor.cgColor)
            ctx.fill(CGRect(x: x - 0.5, y: bounds.height - tickH, width: 1, height: tickH))

            if isMajor {
                let label = formatTime(t)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: labelColor
                ]
                label.draw(at: CGPoint(x: x, y: 4), withAttributes: attrs)
            }
            t += minorInterval
        }
    }

    private func tickInterval(pixelsPerSecond: CGFloat) -> Double {
        let candidates: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60]
        for c in candidates {
            if CGFloat(c) * pixelsPerSecond >= 30 { return c }
        }
        return 60
    }

    private func formatTime(_ s: Double) -> String {
        let m   = Int(s) / 60
        let sec = Int(s) % 60
        let ms  = Int((s - Double(Int(s))) * 10)
        if s < 10 { return String(format: "%d:%02d.%d", m, sec, ms) }
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - TrackRowView

final class TrackRowView: UIView {
    private var track: EditorTrack
    private var layout: TrackLayout
    private let availableWidth: CGFloat
    /// File-internal so TrackCanvasView can flash newly-appeared blocks
    /// and diff rendered segment IDs across timeline updates.
    fileprivate var segmentViews: [UUID: SegmentBlockView] = [:]
    private let onTrimCommit: (UUID, TimeRange, Double?) -> Void
    /// keyed by materialID; used to enforce right-handle source-duration cap (A-05)
    var sourceDurations: [UUID: Double] = [:]
    /// keyed by asset id (= materialID); forwarded to SegmentBlockView for thumbnail generation
    private var materialAssets: [UUID: EditorAsset] = [:]

    var onTrimPreview: ((UUID, TimeRange) -> Void)?
    var onReorderCommit: ((UUID, [UUID]) -> Void)?
    var onMoveCommit: ((UUID, Double) -> Void)?
    var onScrollLock: ((Bool) -> Void)?
    var onEmptyTrackAdd: ((UUID, EditorTrack.Kind) -> Void)?
    /// Forwarded from SegmentBlockView → TrackCanvasView for edge auto-scroll.
    var onAutoScroll: ((CGPoint) -> Void)?

    // MARK: Reorder state (main track)

    private var isReordering = false
    private var reorderOrder: [UUID] = []
    private var draggingID: UUID? = nil
    private var reorderCardWidth: CGFloat = 80
    private var reorderOffset: CGFloat = 0
    private let reorderGap: CGFloat = 6

    // MARK: Free-drag state (attachment tracks)

    private var isFreeDragging = false
    private var freeDragSegmentID: UUID? = nil
    private var freeDragStartTime: Double = 0
    private var freeDragStartTouchX: CGFloat = 0
    private var freeDragLastSnapTime: Double = -1
    private let freeDragFeedback = UIImpactFeedbackGenerator(style: .light)

    /// V7.5: type-aware add affordance shown on an empty pendingUserCreated track.
    private var pendingHintButton: UIButton?

    init(track: EditorTrack, layout: TrackLayout, availableWidth: CGFloat,
         sourceDurations: [UUID: Double] = [:],
         materialAssets:  [UUID: EditorAsset] = [:],
         onTrimCommit: @escaping (UUID, TimeRange, Double?) -> Void) {
        self.track          = track
        self.layout         = layout
        self.availableWidth = availableWidth
        self.sourceDurations = sourceDurations
        self.materialAssets  = materialAssets
        self.onTrimCommit   = onTrimCommit
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.13, alpha: 1)
        layer.cornerRadius = 4
        buildSegments()
        refreshPendingHint()
    }

    /// Create or remove the type-aware empty-track add affordance.
    private func refreshPendingHint() {
        let shouldShow = track.segments.isEmpty && track.pendingUserCreated
        if shouldShow {
            if pendingHintButton == nil {
                let btn = UIButton(type: .system)
                var config = UIButton.Configuration.plain()
                config.image = UIImage(systemName: "plus.circle")
                config.imagePadding = 5
                config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 10)
                config.baseForegroundColor = UIColor.white.withAlphaComponent(0.45)
                config.title = Self.pendingHintTitle(for: track.kind)
                btn.configuration = config
                btn.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .medium)
                btn.contentHorizontalAlignment = .leading
                btn.accessibilityLabel = Self.pendingHintTitle(for: track.kind)
                btn.translatesAutoresizingMaskIntoConstraints = false
                btn.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    self.onEmptyTrackAdd?(self.track.id, self.track.kind)
                }, for: .touchUpInside)
                addSubview(btn)
                NSLayoutConstraint.activate([
                    btn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TrackCanvasView.leftPadding + 4),
                    btn.centerYAnchor.constraint(equalTo: centerYAnchor),
                    btn.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -8)
                ])
                pendingHintButton = btn
            }
        } else {
            pendingHintButton?.removeFromSuperview()
            pendingHintButton = nil
        }
    }

    private static func pendingHintTitle(for kind: EditorTrack.Kind) -> String {
        switch kind {
        case .overlay:    return "添加画中画"
        case .audio:      return "添加音频"
        case .text:       return "添加文字"
        case .subtitle:   return "添加字幕"
        case .adjustment: return "添加调节"
        case .video:      return "添加主轨素材"
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func relayout(layout: TrackLayout) {
        guard !isReordering else { return }
        self.layout = layout
        frame.size.width = layout.totalWidth
        let blockH = TrackCanvasView.trackHeight - TrackCanvasView.SegmentVisuals.blockVPadding * 2
        for seg in track.segments {
            guard let block = segmentViews[seg.id] else { continue }
            block.layout = layout
            // Keep currentRange and siblingRanges in sync so the next gesture's .began
            // baseline is correct — stale values here cause frame jumps on second drag.
            block.currentRange   = seg.targetRange
            block.siblingRanges  = track.segments.filter { $0.id != seg.id }.map { $0.targetRange }
            block.frame = CGRect(
                x: layout.x(for: seg.targetRange.start),
                y: TrackCanvasView.SegmentVisuals.blockVPadding,
                width: max(layout.width(for: seg.targetRange.duration), 16),
                height: blockH
            )
        }

    }

    /// Update track data and reposition blocks without rebuilding gesture recognizers.
    /// Called by relayoutSegments for trim/move changes that preserve segment identity.
    /// Pass `materialAssets` to propagate material replacements to existing blocks.
    func update(track: EditorTrack, layout: TrackLayout,
                materialAssets: [UUID: EditorAsset] = [:]) {
        self.track          = track
        self.materialAssets = materialAssets
        refreshPendingHint()
        // Rebuild sourceDurations from new materialAssets so the right-handle cap reflects
        // the replaced video's true duration (not the old asset's duration).
        for (id, asset) in materialAssets {
            if let nd = asset.nativeDuration, nd > 0 {
                sourceDurations[id] = nd
            }
        }

        // Push updated assets, sourceDurations, sourceRangeStart, and text content to existing blocks.
        for seg in track.segments {
            segmentViews[seg.id]?.updateAsset(materialAssets[seg.materialID])
            segmentViews[seg.id]?.updateContent(from: seg)
            // v4 (track-header-controls-spec rev2 — P0-2): propagate the latest
            // track-level flags so the block's gesture guard, alpha and trim
            // handles reflect a non-structural mutation (lock / hide / mute
            // toggle) without the canvas rebuild.
            segmentViews[seg.id]?.updateTrackFlags(track)
            switch seg.content {
            case .video, .audio:
                segmentViews[seg.id]?.sourceDuration   = sourceDurations[seg.materialID]
                segmentViews[seg.id]?.sourceRangeStart = seg.sourceRange?.start
            default:
                segmentViews[seg.id]?.sourceDuration   = nil
                segmentViews[seg.id]?.sourceRangeStart = nil
            }
        }
        relayout(layout: layout)
    }

    func updateSelection(ids: Set<UUID>) {
        for (id, view) in segmentViews { view.isSelected = ids.contains(id) }
    }

    func segmentID(at point: CGPoint) -> UUID? {
        for (id, view) in segmentViews {
            if view.frame.contains(point) { return id }
        }
        return nil
    }

    // MARK: - Build segments

    private func buildSegments() {
        let blockH = TrackCanvasView.trackHeight - TrackCanvasView.SegmentVisuals.blockVPadding * 2
        for seg in track.segments {
            let x     = layout.x(for: seg.targetRange.start)
            let w     = max(layout.width(for: seg.targetRange.duration), 16)
            let block = SegmentBlockView(segment: seg, track: track, layout: layout,
                                         asset: materialAssets[seg.materialID])
            block.frame = CGRect(x: x, y: TrackCanvasView.SegmentVisuals.blockVPadding, width: w, height: blockH)

            block.onTrimCommit = { [weak self] range, newSrcStart in
                self?.onTrimCommit(seg.id, range, newSrcStart)
                self?.syncFrame(of: block, to: range)
            }

            // Wire auto-scroll: SegmentBlockView → TrackRowView
            block.onAutoScroll = { [weak self] point in
                self?.onAutoScroll?(point)
            }

            if track.isMainTrack {
                // Main track: during drag only the current block's own frame changes.
                // No store preview, no ripple preview, no other blocks move at all.
                // The full magnetic ripple + gap-free repack happens on .ended via
                // trimSegment (store) + relayoutSegments (canvas).
                block.onTrimPreview = nil
            } else {
                // Overlay/subtitle/text tracks: propagate to store for SwiftUI
                // preview layer to reflect the new time range in real-time.
                block.onTrimPreview = { [weak self] range in
                    self?.onTrimPreview?(seg.id, range)
                }
            }

            // Provide sibling ranges for trim collision detection (all tracks).
            block.siblingRanges = track.segments
                .filter { $0.id != seg.id }
                .map    { $0.targetRange }

            // Right-handle source cap (spec A-05).
            // Only timed content (video/audio) gets a cap; images/text/subtitle stretch freely.
            switch seg.content {
            case .video, .audio:
                block.sourceDuration    = sourceDurations[seg.materialID]
                block.sourceRangeStart  = seg.sourceRange?.start
            default:
                block.sourceDuration    = nil
                block.sourceRangeStart  = nil
            }

            if track.isMainTrack {
                // Main track only: long-press activates compact swap/reorder mode.
                block.onLongPressActivated = { [weak self, seg] touchX in
                    self?.beginReorder(draggingID: seg.id, touchX: touchX)
                }
                block.onLongPressMoved = { [weak self] touchX in
                    self?.updateReorder(touchX: touchX)
                }
                block.onLongPressEnded = { [weak self] in
                    self?.commitReorder()
                }
                block.onLongPressCancelled = { [weak self] in
                    self?.cancelReorder()
                }
            } else {
                // Attachment tracks: long-press activates free-drag (no reorder/swap).
                block.onLongPressActivated = { [weak self, seg] touchX in
                    self?.beginFreeDrag(segmentID: seg.id, touchX: touchX)
                }
                block.onLongPressMoved = { [weak self] touchX in
                    self?.updateFreeDrag(touchX: touchX)
                }
                block.onLongPressEnded = { [weak self] in
                    self?.commitFreeDrag()
                }
                block.onLongPressCancelled = { [weak self] in
                    self?.cancelFreeDrag()
                }
            }

            addSubview(block)
            segmentViews[seg.id] = block
        }
    }

    private func syncFrame(of block: SegmentBlockView, to range: TimeRange) {
        let blockH = TrackCanvasView.trackHeight - TrackCanvasView.SegmentVisuals.blockVPadding * 2
        block.frame = CGRect(
            x: layout.x(for: range.start),
            y: TrackCanvasView.SegmentVisuals.blockVPadding,
            width: max(layout.width(for: range.duration), 16),
            height: blockH
        )
    }


    // MARK: - Reorder mode

    private func beginReorder(draggingID: UUID, touchX: CGFloat) {
        guard !isReordering else { return }
        isReordering = true
        self.draggingID = draggingID

        // Establish order from current start times
        reorderOrder = track.segments
            .sorted { $0.targetRange.start < $1.targetRange.start }
            .map { $0.id }

        // Compute card width so all cards fit in the visible viewport
        let count = max(1, reorderOrder.count)
        let totalGaps = CGFloat(count - 1) * reorderGap
        let available = availableWidth - TrackCanvasView.leftPadding - TrackCanvasView.rightPadding
        reorderCardWidth = max(40, floor((available - totalGaps) / CGFloat(count)))

        // Offset all cards so the dragged card stays centered under the finger,
        // regardless of which segment was long-pressed (left or right side).
        let draggingIdx = reorderOrder.firstIndex(of: draggingID) ?? 0
        let defaultDraggedCenterX = TrackCanvasView.leftPadding
            + CGFloat(draggingIdx) * (reorderCardWidth + reorderGap)
            + reorderCardWidth / 2
        reorderOffset = max(0, touchX - defaultDraggedCenterX)

        // Elevate dragged card
        segmentViews[draggingID]?.layer.zPosition = 10

        UIView.animate(withDuration: 0.2) {
            for (i, id) in self.reorderOrder.enumerated() {
                guard let block = self.segmentViews[id] else { continue }
                block.frame.origin.x = self.reorderX(for: i)
                block.frame.size.width = self.reorderCardWidth
                if id == draggingID {
                    block.transform = CGAffineTransform(scaleX: 1.0, y: 1.08)
                    block.alpha = 0.85
                }
            }
        }
    }

    private func updateReorder(touchX: CGFloat) {
        guard isReordering, let draggingID, let block = segmentViews[draggingID] else { return }

        // Move dragged card to follow finger
        let minOriginX = reorderX(for: 0)
        let maxOriginX = reorderX(for: reorderOrder.count - 1)
        let originX = (touchX - reorderCardWidth / 2).clamped(to: minOriginX ... maxOriginX)
        block.frame.origin.x = originX

        // Slot detection from card center.
        // Symmetric threshold: the dragged card must pass the center of the
        // adjacent card before a swap triggers, in either direction.
        let center = originX + reorderCardWidth / 2
        let baseX = TrackCanvasView.leftPadding + reorderOffset + reorderCardWidth / 2
        let rawFloat = (center - baseX) / (reorderCardWidth + reorderGap)

        guard let currentIdx = reorderOrder.firstIndex(of: draggingID) else { return }

        let rawSlot: Int
        if rawFloat > Double(currentIdx) {
            rawSlot = Int(floor(rawFloat))      // rightward: need to pass next center
        } else if rawFloat < Double(currentIdx) {
            rawSlot = Int(ceil(rawFloat))       // leftward: need to pass prev center
        } else {
            rawSlot = currentIdx
        }
        let newSlot = rawSlot.clamped(to: 0 ... reorderOrder.count - 1)

        guard currentIdx != newSlot else { return }

        reorderOrder.remove(at: currentIdx)
        reorderOrder.insert(draggingID, at: newSlot)

        UIView.animate(withDuration: 0.15) {
            for (i, id) in self.reorderOrder.enumerated() {
                guard id != draggingID, let b = self.segmentViews[id] else { continue }
                b.frame.origin.x = self.reorderX(for: i)
            }
        }
    }

    private func commitReorder() {
        guard isReordering, let draggingID else { return }

        let finalOrder = reorderOrder
        let trackID    = track.id

        isReordering    = false
        self.draggingID = nil
        reorderOffset   = 0

        // Always restore to normal time-proportional layout immediately.
        // If the timeline actually changed, configure() will rebuild the rows and
        // interrupt this animation naturally. If nothing changed (no-op reorder),
        // this animation is the only thing that brings the UI back to normal.
        restoreNormalLayout()

        onReorderCommit?(trackID, finalOrder)
    }

    private func restoreNormalLayout() {
        let blockH = TrackCanvasView.trackHeight - TrackCanvasView.SegmentVisuals.blockVPadding * 2

        // Reset transform synchronously BEFORE setting frame.
        // UIKit doc: setting frame is undefined when transform != identity.
        // The animation in beginReorder() immediately commits the non-identity
        // transform to the model layer, so we must clear it first.
        for seg in track.segments {
            segmentViews[seg.id]?.transform = .identity
        }

        UIView.animate(withDuration: 0.2) {
            for seg in self.track.segments {
                guard let block = self.segmentViews[seg.id] else { continue }
                block.frame = CGRect(
                    x: self.layout.x(for: seg.targetRange.start),
                    y: TrackCanvasView.SegmentVisuals.blockVPadding,
                    width: max(self.layout.width(for: seg.targetRange.duration), 16),
                    height: blockH
                )
                block.alpha           = 1.0
                block.layer.zPosition = 0
            }
        }
    }

    private func cancelReorder() {
        guard isReordering, let draggingID else { return }

        isReordering    = false
        self.draggingID = nil
        reorderOffset   = 0

        // Reset transform first (same reason as restoreNormalLayout).
        for seg in track.segments { segmentViews[seg.id]?.transform = .identity }

        let blockH = TrackCanvasView.trackHeight - TrackCanvasView.SegmentVisuals.blockVPadding * 2
        UIView.animate(withDuration: 0.2) {
            for seg in self.track.segments {
                guard let block = self.segmentViews[seg.id] else { continue }
                block.frame = CGRect(
                    x: self.layout.x(for: seg.targetRange.start),
                    y: TrackCanvasView.SegmentVisuals.blockVPadding,
                    width: max(self.layout.width(for: seg.targetRange.duration), 16),
                    height: blockH
                )
                block.alpha           = 1.0
                block.layer.zPosition = 0
            }
        }
    }

    private func reorderX(for slot: Int) -> CGFloat {
        TrackCanvasView.leftPadding + reorderOffset + CGFloat(slot) * (reorderCardWidth + reorderGap)
    }

    // MARK: - Free-drag mode (attachment tracks only)
    // Rules: long-press to start → free movement during drag → validate on release.
    // If the drop position overlaps a sibling, animate back to the original start time.

    private func beginFreeDrag(segmentID: UUID, touchX: CGFloat) {
        guard !isFreeDragging,
              let block = segmentViews[segmentID],
              let seg = track.segments.first(where: { $0.id == segmentID }) else { return }

        isFreeDragging        = true
        freeDragSegmentID     = segmentID
        freeDragStartTime     = seg.targetRange.start
        freeDragStartTouchX   = touchX
        freeDragLastSnapTime  = -1

        freeDragFeedback.prepare()
        onScrollLock?(true)
        block.layer.zPosition = 10
        block.alpha = 0.88
    }

    private func updateFreeDrag(touchX: CGFloat) {
        guard isFreeDragging, let segmentID = freeDragSegmentID,
              let block = segmentViews[segmentID],
              let seg = track.segments.first(where: { $0.id == segmentID }) else { return }

        let dx       = touchX - freeDragStartTouchX
        let rawStart = max(0, freeDragStartTime + layout.timeDelta(for: dx))
        let snapped  = freeDragSnap(rawStart, duration: seg.targetRange.duration, excludeID: segmentID)
        block.frame.origin.x = layout.x(for: snapped)
    }

    /// Snap start time to nearby edges (8pt threshold). Returns snapped time.
    private func freeDragSnap(_ start: Double, duration: Double, excludeID: UUID) -> Double {
        let threshold = max(0.1, 8.0 / Double(layout.pixelsPerSecond))
        var edges: [Double] = [0]
        for seg in track.segments where seg.id != excludeID {
            edges.append(seg.targetRange.start)
            edges.append(seg.targetRange.end)
        }
        let checkPoints = [start, start + duration]
        for point in checkPoints {
            if let nearest = edges.min(by: { abs($0 - point) < abs($1 - point) }),
               abs(nearest - point) <= threshold {
                let offset = point - start          // 0 for start anchor, +duration for end anchor
                let result = nearest - offset
                if abs(nearest - freeDragLastSnapTime) > 0.01 {
                    freeDragFeedback.impactOccurred()
                    freeDragLastSnapTime = nearest
                }
                return max(0, result)
            }
        }
        freeDragLastSnapTime = -1
        return start
    }

    private func commitFreeDrag() {
        guard isFreeDragging,
              let segmentID = freeDragSegmentID,
              let block = segmentViews[segmentID],
              let seg = track.segments.first(where: { $0.id == segmentID }) else {
            finishFreeDrag(); return
        }

        let currentStart = layout.time(at: block.frame.origin.x)
        let siblings     = track.segments.filter { $0.id != segmentID }.map { $0.targetRange }
        let blockH       = TrackCanvasView.trackHeight - 8

        if Self.isValidPosition(currentStart, duration: seg.targetRange.duration, siblings: siblings) {
            // Valid drop — commit and stay.
            UIView.animate(withDuration: 0.1) {
                block.alpha           = 1.0
                block.layer.zPosition = 0
            }
            onMoveCommit?(segmentID, currentStart)
        } else {
            // Invalid — spring back to original position.
            UIView.animate(withDuration: 0.3, delay: 0,
                           usingSpringWithDamping: 0.65, initialSpringVelocity: 0.4,
                           options: .curveEaseOut) {
                block.frame = CGRect(
                    x: self.layout.x(for: self.freeDragStartTime),
                    y: TrackCanvasView.SegmentVisuals.blockVPadding,
                    width: max(self.layout.width(for: seg.targetRange.duration), 16),
                    height: blockH
                )
                block.alpha           = 1.0
                block.layer.zPosition = 0
            }
        }

        finishFreeDrag()
    }

    private func cancelFreeDrag() {
        guard isFreeDragging,
              let segmentID = freeDragSegmentID,
              let block = segmentViews[segmentID],
              let seg = track.segments.first(where: { $0.id == segmentID }) else {
            finishFreeDrag(); return
        }

        let blockH = TrackCanvasView.trackHeight - TrackCanvasView.SegmentVisuals.blockVPadding * 2
        UIView.animate(withDuration: 0.2) {
            block.frame = CGRect(
                x: self.layout.x(for: self.freeDragStartTime),
                y: TrackCanvasView.SegmentVisuals.blockVPadding,
                width: max(self.layout.width(for: seg.targetRange.duration), 16),
                height: blockH
            )
            block.alpha           = 1.0
            block.layer.zPosition = 0
        }

        finishFreeDrag()
    }

    private func finishFreeDrag() {
        isFreeDragging       = false
        freeDragSegmentID    = nil
        freeDragLastSnapTime = -1
        onScrollLock?(false)
    }

    /// True if [start, start+duration) doesn't overlap any sibling range.
    private static func isValidPosition(_ start: Double, duration: Double, siblings: [TimeRange]) -> Bool {
        let end = start + duration
        return !siblings.contains { $0.start < end - 0.001 && $0.end > start + 0.001 }
    }
}

// MARK: - TrimHandleView

/// Transparent hit zone for a trim handle.
/// Normal state  : hitWidth = 24 pt, visualWidth = 6 pt (main track always visible).
/// Selected state: hitWidth = 32 pt, visualWidth = 9 pt (attachment track after tap).
/// Being a subview of SegmentBlockView, UIKit hitTest naturally routes edge
/// touches here before reaching the block's long-press gesture.
final class TrimHandleView: UIView {
    static let hitWidthNormal:      CGFloat = 32
    static let hitWidthSelected:    CGFloat = 44
    static let visualWidthNormal:   CGFloat = 8
    static let visualWidthSelected: CGFloat = 12

    private let bar: UIView
    private var barWidthConstraint: NSLayoutConstraint!

    init(isLeading: Bool) {
        bar = UIView()
        super.init(frame: .zero)
        backgroundColor = .clear

        bar.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        bar.isUserInteractionEnabled = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        let barWidth = bar.widthAnchor.constraint(equalToConstant: Self.visualWidthNormal)
        barWidthConstraint = barWidth

        let edgeAnchor: NSLayoutConstraint = isLeading
            ? bar.leadingAnchor.constraint(equalTo: leadingAnchor)
            : bar.trailingAnchor.constraint(equalTo: trailingAnchor)

        NSLayoutConstraint.activate([
            barWidth,
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            edgeAnchor
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        barWidthConstraint.constant   = selected ? Self.visualWidthSelected : Self.visualWidthNormal
        bar.backgroundColor = selected
            ? UIColor.white.withAlphaComponent(0.9)
            : UIColor.white.withAlphaComponent(0.5)
    }
}

// MARK: - SegmentBlockView

final class SegmentBlockView: UIView {
    /// Stored at init so isSelected can swap between normal and brightened colors.
    private let unselectedBackgroundColor: UIColor
    private let selectedBackgroundColor: UIColor

    var isSelected: Bool = false {
        didSet {
            guard oldValue != isSelected else { return }
            updateHandles()
            // Animate border + background for a smoother transition than instant swap.
            UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.layer.borderWidth = self.isSelected
                    ? TrackCanvasView.SegmentVisuals.selectedBorderWidth
                    : 0
                self.backgroundColor = self.isSelected
                    ? self.selectedBackgroundColor
                    : self.unselectedBackgroundColor
            }
            // Subtle scale pop on becoming selected, so a tap feels acknowledged.
            if isSelected {
                transform = CGAffineTransform(scaleX: 1.02, y: 1.02)
                UIView.animate(
                    withDuration: 0.18, delay: 0,
                    usingSpringWithDamping: 0.55, initialSpringVelocity: 0.4,
                    options: [.allowUserInteraction, .beginFromCurrentState]
                ) {
                    self.transform = .identity
                }
            }
        }
    }

    /// Called on trim gesture end. Second arg is new sourceRange.start (non-nil only when
    /// the left handle extended outward, shifting the clip in-point leftward).
    var onTrimCommit: ((TimeRange, Double?) -> Void)?
    /// Called during drag (.changed) to update store state for live overlay preview.
    var onTrimPreview: ((TimeRange) -> Void)?
    /// Called during trim drag with the touch point in window coordinates.
    /// TrackCanvasView uses this to auto-scroll the UIScrollView when the handle
    /// reaches the visible edge of the timeline.
    var onAutoScroll: ((CGPoint) -> Void)?

    // Long-press callbacks (coordinates in superview space)
    var onLongPressActivated: ((CGFloat) -> Void)?
    var onLongPressMoved:     ((CGFloat) -> Void)?
    var onLongPressEnded:     (() -> Void)?
    var onLongPressCancelled: (() -> Void)?

    private let segment: EditorSegment
    // v4 (track-header-controls-spec rev2 — P0-2): `track` is `var` so the
    // parent row can refresh the flag state in-place when isLocked / isHidden
    // change. The reorder / trim handlers read `track.isLocked` on every event,
    // so the local copy must stay live.
    private var track: EditorTrack
    var layout: TrackLayout
    private var asset: EditorAsset?

    private var trimStartRange: TimeRange = TimeRange(start: 0, duration: 0)
    private let minDuration: Double = 0.2

    /// Set by TrackRowView from the source asset duration. Guards the right handle
    /// from extending past the available source material (spec A-05).
    var sourceDuration: Double? = nil

    /// Set by TrackRowView from segment.sourceRange.start. Guards the LEFT handle from
    /// extending past the beginning of the source clip (A-05 symmetric rule).
    /// nil means no pre-roll available → left handle stays pinned.
    var sourceRangeStart: Double? = nil

    // Same-track sibling ranges — set by TrackRowView; used to clamp trim on both handles.
    var siblingRanges: [TimeRange] = []

    /// The segment's current time range — kept in sync by TrackRowView.relayout after every
    /// commit. Used in .began so that a second gesture always starts from the real current
    /// position, not the stale value baked into the immutable `segment` at init time.
    var currentRange: TimeRange
    // Cached at .began: left edge = prevSibling.end (or 0), right edge = nextSibling.start (or ∞)
    private var trimLeftBound:  Double = 0
    private var trimRightBound: Double = .infinity

    // Handle view references for dynamic visibility / sizing
    private var leadingHandle: TrimHandleView?
    private var trailingHandle: TrimHandleView?
    private var leadingHandleWidthConstraint: NSLayoutConstraint?
    private var trailingHandleWidthConstraint: NSLayoutConstraint?

    // Stored so we can exclude it when touch lands in a handle hit zone.
    private weak var longPressGesture: UILongPressGestureRecognizer?

    // Thumbnail strip — shown for video/image blocks only.
    private let thumbnailStrip = ThumbnailStripView()
    // Waveform strip — shown for audio blocks only.
    private let waveformStrip = WaveformStripView()
    // Width at which thumbnails were last requested; avoids redundant reloads during layout.
    private var lastThumbLoadWidth: CGFloat = 0
    // Suppresses thumbnail reload during live trim drag to avoid thrashing the generator.
    var isTrimming = false

    // V7.5: live thumbnail scrub during a LEFT-handle trim. We keep the already
    // rendered strip content fixed and slide it under the (stationary) leading handle
    // so the leftmost visible frame tracks the new in-point — no per-frame thumbnail
    // re-fetch, no flicker. Only active while dragging the leading handle inward.
    private var isPreviewSliding = false
    private var thumbnailSlideBaseWidth: CGFloat = 0

    // Text preview label — shown for subtitle and text segments.
    private let textLabel = UILabel()

    init(segment: EditorSegment, track: EditorTrack, layout: TrackLayout,
         asset: EditorAsset? = nil) {
        self.segment      = segment
        self.track        = track
        self.layout       = layout
        self.asset        = asset
        self.currentRange = segment.targetRange

        let baseColor = TrackCanvasView.SegmentVisuals.blockColor(for: track.kind)
        let showsThumbs: Bool = {
            switch segment.content {
            case .video, .image: return true
            default: return false
            }
        }()
        if showsThumbs {
            unselectedBackgroundColor = baseColor.withAlphaComponent(0.3)
        } else {
            unselectedBackgroundColor = baseColor
        }
        let boostedAlpha = min(max(unselectedBackgroundColor.cgColor.alpha + 0.2, 0), 1.0)
        selectedBackgroundColor = baseColor.withAlphaComponent(boostedAlpha)

        super.init(frame: .zero)
        // v4 (track-header-controls-spec §2.2): both hidden AND locked tracks
        // render their segment blocks at 0.4 alpha on the timeline canvas to
        // give a clear "this is temporarily disabled, not deleted" cue. The
        // preview canvas applies the same opacity in EditorPreviewView so the
        // two surfaces stay visually in sync.
        self.alpha = (track.isHidden || track.isLocked) ? 0.4 : 1.0
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        layer.cornerRadius = TrackCanvasView.SegmentVisuals.cornerRadius
        layer.borderColor  = TrackCanvasView.SegmentVisuals.selectedBorderColor.cgColor
        backgroundColor    = unselectedBackgroundColor
        clipsToBounds      = true

        // Thumbnail strip sits behind handles as the first subview.
        let showThumbs = shouldShowThumbnails
        if showThumbs {
            thumbnailStrip.frame = bounds
            thumbnailStrip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(thumbnailStrip)
        }

        // Text preview label for subtitle and text segments.
        if shouldShowTextPreview {
            textLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
            textLabel.textColor = UIColor.white.withAlphaComponent(0.9)
            textLabel.lineBreakMode = .byTruncatingTail
            textLabel.numberOfLines = 1
            textLabel.textAlignment = .left
            textLabel.frame = bounds.insetBy(dx: 8, dy: 4)
            textLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(textLabel)
            updateTextLabel()
        }

        // Waveform strip for audio segments.
        if shouldShowWaveform {
            waveformStrip.frame = bounds.insetBy(dx: 4, dy: 8)
            waveformStrip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(waveformStrip)
        }

        addTrimHandle(isLeading: true)
        addTrimHandle(isLeading: false)
        updateHandles()  // set initial visibility

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = 0.3
        lp.delegate = self
        longPressGesture = lp
        addGestureRecognizer(lp)
    }

    private var shouldShowThumbnails: Bool {
        switch segment.content {
        case .video, .image: return true
        default: return false
        }
    }

    private var shouldShowTextPreview: Bool {
        switch segment.content {
        case .text, .subtitle: return true
        default: return false
        }
    }

    private var shouldShowWaveform: Bool {
        if case .audio = segment.content { return true }
        return false
    }

    /// Extract the display text from a text or subtitle segment.
    private var segmentDisplayText: String? {
        switch segment.content {
        case .text(let c):    return c.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .subtitle(let c): return c.text.trimmingCharacters(in: .whitespacesAndNewlines)
        default:              return nil
        }
    }

    private func updateTextLabel(with text: String? = nil) {
        textLabel.text = (text ?? segmentDisplayText) ?? ""
        textLabel.isHidden = textLabel.text?.isEmpty ?? true
        textLabel.textAlignment = .left
        textLabel.frame = bounds.insetBy(dx: 8, dy: 4)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isTrimming else { return }

        if shouldShowTextPreview {
            textLabel.frame = bounds.insetBy(dx: 8, dy: 4)
        }

        if shouldShowThumbnails {
            guard abs(bounds.width - lastThumbLoadWidth) > 1 else { return }
            lastThumbLoadWidth = bounds.width
            // Map thumbnails to the segment's LIVE source slice, not the frozen init
            // segment. After a trim the block persists (relayoutSegments — no canvas
            // rebuild) and only currentRange / sourceRangeStart are refreshed; using the
            // frozen segment would keep showing the original in/out point. Aligning the
            // strip with the live in-point + target duration also lets the post-commit
            // reload land flush with what the left-handle slide previewed.
            var liveSeg = segment
            liveSeg.sourceRange = TimeRange(
                start:    sourceRangeStart ?? segment.sourceRange?.start ?? 0,
                duration: currentRange.duration
            )
            liveSeg.targetRange = currentRange
            thumbnailStrip.load(asset: asset, segment: liveSeg)
        }

        if shouldShowWaveform, let url = asset?.bestURL {
            waveformStrip.frame = bounds.insetBy(dx: 4, dy: 8)
            guard abs(bounds.width - lastThumbLoadWidth) > 1 else { return }
            lastThumbLoadWidth = bounds.width
            waveformStrip.load(url: url)
        }
    }

    /// Update text label from a new segment's content (text/subtitle edits).
    func updateContent(from seg: EditorSegment) {
        switch seg.content {
        case .text(let c):
            updateTextLabel(with: c.text)
        case .subtitle(let c):
            updateTextLabel(with: c.text)
        default:
            break
        }
    }

    /// v4 (track-header-controls-spec rev2 — P0-2): refresh the block's view
    /// of the parent track's flags. Called from `TrackRowView.update(track:…)`
    /// whenever isLocked / isHidden / isMuted change, so the gesture guard +
    /// alpha + trim-handle visibility reflect the new state without the
    /// expensive full canvas rebuild.
    func updateTrackFlags(_ newTrack: EditorTrack) {
        let alphaChanged    = (track.isHidden != newTrack.isHidden)
                           || (track.isLocked != newTrack.isLocked)
        let handlesChanged  = (track.isLocked != newTrack.isLocked)
                           || (track.isMainTrack != newTrack.isMainTrack)
        self.track = newTrack
        if alphaChanged {
            self.alpha = (newTrack.isHidden || newTrack.isLocked) ? 0.4 : 1.0
        }
        if handlesChanged {
            updateHandles()
        }
    }

    /// Called by TrackRowView when the underlying material is restored.
    /// Forces a thumbnail/waveform reload if the asset URL changed.
    func updateAsset(_ newAsset: EditorAsset?) {
        let oldURL = asset?.bestURL
        let newURL = newAsset?.bestURL
        guard oldURL != newURL else { return }
        asset = newAsset
        lastThumbLoadWidth = 0   // invalidate so layoutSubviews triggers reload
        switch segment.content {
        case .audio: waveformStrip.cancelLoading()
        default:     thumbnailStrip.cancelLoading()
        }
        setNeedsLayout()
    }

    // MARK: - Trim Handles

    private func addTrimHandle(isLeading: Bool) {
        let handle = TrimHandleView(isLeading: isLeading)
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.tag = isLeading ? 0 : 1
        addSubview(handle)

        let edgeAnchor: NSLayoutConstraint = isLeading
            ? handle.leadingAnchor.constraint(equalTo: leadingAnchor)
            : handle.trailingAnchor.constraint(equalTo: trailingAnchor)

        let widthConstraint = handle.widthAnchor.constraint(equalToConstant: TrimHandleView.hitWidthNormal)

        NSLayoutConstraint.activate([
            widthConstraint,
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            edgeAnchor
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTrimPan(_:)))
        pan.maximumNumberOfTouches = 1
        handle.addGestureRecognizer(pan)

        if isLeading {
            leadingHandle = handle
            leadingHandleWidthConstraint = widthConstraint
        } else {
            trailingHandle = handle
            trailingHandleWidthConstraint = widthConstraint
        }
    }

    // MARK: - Handle Visibility

    private func updateHandles() {
        let show     = (track.isMainTrack || isSelected) && !track.isLocked
        let hitWidth = isSelected ? TrimHandleView.hitWidthSelected : TrimHandleView.hitWidthNormal

        for (handle, wc) in [(leadingHandle,  leadingHandleWidthConstraint),
                              (trailingHandle, trailingHandleWidthConstraint)] {
            guard let handle else { continue }
            handle.isHidden = !show
            handle.setSelected(isSelected)
            wc?.constant = hitWidth
        }
    }

    // MARK: - Trim Gesture

    @objc private func handleTrimPan(_ gr: UIPanGestureRecognizer) {
        // v4 (audio-track-controls-spec §3.4): locked tracks reject all gestures.
        guard !track.isLocked else { return }
        // Only process trim on the selected segment.  This prevents accidentally
        // triggering a neighbouring segment's handle when both are visible.
        guard isSelected else { return }
        let isLeading = gr.view?.tag == 0
        switch gr.state {
        case .began:
            isTrimming = true
            trimStartRange = currentRange
            let sorted = siblingRanges.sorted { $0.start < $1.start }

            if track.isMainTrack {
                // Right handle: unlimited — successors ripple rightward on commit.
                trimRightBound = .infinity

                // Left handle: pre-roll consumption model.
                // Drag left → block's right edge extends rightward (start anchored).
                // Drag right → inward trim from left (start moves right).
                // The constraint on pre-roll extension is sourceRangeStart (available
                // seconds before the current in-point).  Images have no cap.
                // trimLeftBound is used only for inward trim; try to keep it as wide
                // as possible so the gesture isn't artificially constrained.
                let srcPreRoll: Double = sourceDuration != nil ? (sourceRangeStart ?? 0) : Double.infinity
                trimLeftBound = max(0, trimStartRange.start - srcPreRoll)
            } else {
                // Attachment track: no ripple — adjacent segments are hard blockers.
                // Left: blocked by nearest left sibling, or source pre-roll cap (audio/video only).
                // Right: blocked by nearest right sibling.
                let predecessorEnd = sorted
                    .filter { $0.end <= trimStartRange.start + 0.001 }
                    .map    { $0.end }
                    .max()  ?? 0
                if sourceDuration != nil {
                    // Audio/video on attachment track: limited by available source pre-roll.
                    let backRoom = sourceRangeStart ?? 0
                    trimLeftBound = max(predecessorEnd, trimStartRange.start - backRoom)
                } else {
                    // Text/subtitle/overlay/adjustment: no source cap, only blocked by siblings.
                    trimLeftBound = max(0, predecessorEnd)
                }
                trimRightBound = sorted
                    .filter { $0.start >= trimStartRange.end - 0.001 }
                    .map    { $0.start }
                    .min()  ?? .infinity
            }
            // Left handle: freeze the strip's current content and take manual control
            // of its frame so we can slide it under the leading handle during the drag.
            if isLeading, shouldShowThumbnails {
                isPreviewSliding        = true
                thumbnailSlideBaseWidth = thumbnailStrip.bounds.width
                thumbnailStrip.autoresizingMask = []
            }
        case .changed:
            let dt = layout.timeDelta(for: gr.translation(in: superview).x)
            let range = clampedRange(isLeading: isLeading, dt: dt)
            applyTrimPreview(range: range)
            if isPreviewSliding { slideThumbnailPreview(to: range) }
            onTrimPreview?(range)
            // Auto-scroll when the drag handle reaches the visible edge of the timeline.
            onAutoScroll?(gr.location(in: nil))
        case .ended:
            isTrimming = false
            endThumbnailSlide()
            let dt = layout.timeDelta(for: gr.translation(in: superview).x)
            let newRange = clampedRange(isLeading: isLeading, dt: dt)
            // Left handle: keep the source in-point in sync with the trim so the
            // compositor reads the correct slice (srcRange = sourceRange.start +
            // targetRange.duration).
            //   • Extend outward → in-point moves EARLIER (consume pre-roll).
            //   • Trim inward    → in-point moves LATER  (drop head content).
            // `inPointShift` is the signed amount the in-point must move earlier:
            //   main track  → duration delta (grow = +, shrink = −)
            //   attachment  → start delta    (left = +, right = −)
            // so newSourceStart = srcStart − inPointShift covers BOTH directions.
            // V7.5: the inward branch was previously gated out (> 0.001), so
            // dragging the left handle right kept the same in-point and trimmed the
            // TAIL instead of the head. Now both directions update the in-point.
            var newSourceStart: Double? = nil
            if isLeading, let srcStart = sourceRangeStart {
                let inPointShift: Double
                if track.isMainTrack {
                    inPointShift = newRange.duration - trimStartRange.duration
                } else {
                    inPointShift = trimStartRange.start - newRange.start
                }
                if abs(inPointShift) > 0.001 {
                    newSourceStart = max(0, srcStart - inPointShift)
                }
            }
            onTrimCommit?(newRange, newSourceStart)
        case .cancelled, .failed:
            isTrimming = false
            endThumbnailSlide()
            let blockH = TrackCanvasView.trackHeight - TrackCanvasView.SegmentVisuals.blockVPadding * 2
            frame = CGRect(
                x: layout.x(for: trimStartRange.start),
                y: TrackCanvasView.SegmentVisuals.blockVPadding,
                width: max(layout.width(for: trimStartRange.duration), 16),
                height: blockH
            )
            // Reset store to original range so previewTrimRange doesn't leave stale state.
            onTrimPreview?(trimStartRange)
        default: break
        }
    }

    private func applyTrimPreview(range: TimeRange) {
        let blockH = TrackCanvasView.trackHeight - TrackCanvasView.SegmentVisuals.blockVPadding * 2
        frame = CGRect(
            x: layout.x(for: range.start),
            y: TrackCanvasView.SegmentVisuals.blockVPadding,
            width: max(layout.width(for: range.duration), 16),
            height: blockH
        )
    }

    /// Slide the (fixed-content) thumbnail strip so the leading handle scrubs through
    /// the source during a left-handle trim. Inward trim (start moves right) → shift the
    /// strip left by the same pixels so the leftmost visible frame becomes the new
    /// in-point; the block clips the overflow. Extend / no inward move → just fill the
    /// block (the earlier pre-roll frames aren't rendered, so there's nothing to scrub).
    private func slideThumbnailPreview(to range: TimeRange) {
        let leftShiftPx = layout.x(for: range.start) - layout.x(for: trimStartRange.start)
        let h = bounds.height
        if leftShiftPx > 0 {
            thumbnailStrip.frame = CGRect(x: -leftShiftPx, y: 0,
                                          width: thumbnailSlideBaseWidth, height: h)
        } else {
            thumbnailStrip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        }
    }

    /// Restore the strip to normal autoresize-to-bounds and force a reload, so the
    /// post-commit (or post-cancel) layout re-maps thumbnails to the final in/out point.
    private func endThumbnailSlide() {
        guard isPreviewSliding else { return }
        isPreviewSliding = false
        thumbnailStrip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        thumbnailStrip.frame = bounds
        lastThumbLoadWidth = 0   // invalidate so the next layout reloads the live slice
        setNeedsLayout()
    }

    private func clampedRange(isLeading: Bool, dt: Double) -> TimeRange {
        if isLeading {
            if track.isMainTrack, dt < 0 {
                // ── Pre-roll consumption (main track, drag left) ─────────────
                // The block's left edge stays anchored on the timeline; the right
                // edge extends rightward by up to sourceRangeStart seconds
                // (available pre-roll).  The thumbnail strip shows earlier source
                // content.  First segment works identically — start stays at 0,
                // duration grows right, successors ripple right.
                let preRollCap = sourceRangeStart ?? 0
                let ext = min(abs(dt), preRollCap)
                let newEnd = min(trimStartRange.end + ext, trimRightBound)
                let duration = max(minDuration, newEnd - trimStartRange.start)
                return TimeRange(start: trimStartRange.start, duration: duration)
            } else {
                // Inward trim (dt > 0) or attachment track: move start, end fixed.
                let newStart = (trimStartRange.start + dt)
                    .clamped(to: trimLeftBound ... (trimStartRange.end - minDuration))
                return TimeRange(start: newStart, duration: trimStartRange.end - newStart)
            }
        } else {
            // Right bound: nextSibling.start (or ∞), also capped by source asset duration (A-05).
            // Use the live `sourceRangeStart` property — `segment` is a frozen let from init
            // and its sourceRange becomes stale after material replacement.
            let srcCap: Double = {
                guard let sd = sourceDuration, sd > 0 else { return .infinity }
                let srcStart = sourceRangeStart ?? 0
                return trimStartRange.start + (sd - srcStart)
            }()
            let effectiveRightBound = min(trimRightBound, srcCap)
            let newEnd = (trimStartRange.end + dt)
                .clamped(to: (trimStartRange.start + minDuration) ... effectiveRightBound)
            return TimeRange(start: trimStartRange.start, duration: newEnd - trimStartRange.start)
        }
    }

    // MARK: - Long Press → Reorder

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        let touchX = gr.location(in: superview).x
        switch gr.state {
        case .began:     onLongPressActivated?(touchX)
        case .changed:   onLongPressMoved?(touchX)
        case .ended:     onLongPressEnded?()
        case .cancelled, .failed: onLongPressCancelled?()
        default: break
        }
    }

}

// MARK: - SegmentBlockView + UIGestureRecognizerDelegate

extension SegmentBlockView: UIGestureRecognizerDelegate {
    /// Block the long-press gesture if the initial touch lands inside a trim handle's
    /// hit zone.  UIKit hitTest() already routes the touch to the handle's pan
    /// gesture first, but the long-press can still begin simultaneously on the parent
    /// view.  Returning false here prevents it from ever reaching `.began`.
    override func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
        // v4 (audio-track-controls-spec §3.4 / track-header-controls-spec):
        // locked tracks silently reject *editing* gestures (long-press reorder,
        // trim pan). Selection tap is canvas-level (governed by the controller
        // delegate, not this override) and still works → users can view a
        // locked segment without entering edit mode. The earlier rigid haptic
        // here fired on every aborted long-press attempt (~0.3s hold) which
        // looked exactly like "subtitle tap only buzzes, no response".
        if track.isLocked {
            return false
        }
        if gr === longPressGesture {
            // V7.5: only the *edge* trim zones may block the body long-press, and
            // each zone is capped at 1/3 of the block width so the central third
            // ALWAYS triggers long-press (reorder / free-drag) — selected or not.
            //
            // Previously this rejected the long-press anywhere inside a handle's
            // full hit frame. When a segment is selected the handles widen to
            // 44 pt each (TrimHandleView.hitWidthSelected); on a short clip the two
            // 44 pt zones cover the whole body, so a selected segment could never
            // be long-pressed. A hidden handle (unselected attachment track) is
            // skipped entirely so its body stays fully long-pressable.
            let p = gr.location(in: self)
            let w = bounds.width
            let third = w / 3
            if let lead = leadingHandle, !lead.isHidden,
               p.x < min(lead.frame.width, third) { return false }
            if let trail = trailingHandle, !trail.isHidden,
               p.x > w - min(trail.frame.width, third) { return false }
        }
        return true
    }
}

// MARK: - Helpers

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - TransitionBadgeView

/// Diamond-shaped tap target placed at each cut-point on the main track.
/// Filled (white) when a transition already exists; outlined when no transition.
final class TransitionBadgeView: UIView {

    var onTap: (() -> Void)?

    /// The transition currently assigned to this cut-point, or nil for bare cut.
    var transition: EditorTransition? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let s = min(rect.width, rect.height)
        let cx = rect.midX, cy = rect.midY
        let r = s / 2 - 1

        // Diamond path
        ctx.move(to:    CGPoint(x: cx,     y: cy - r))
        ctx.addLine(to: CGPoint(x: cx + r, y: cy))
        ctx.addLine(to: CGPoint(x: cx,     y: cy + r))
        ctx.addLine(to: CGPoint(x: cx - r, y: cy))
        ctx.closePath()

        if transition != nil {
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }
    }

    @objc private func didTap() { onTap?() }
}

// MARK: - ThumbnailStripView

/// V5.1 BUG 3: 改为 CATiledLayer 驱动的按需渲染，支持超长素材（>16384pt）。
/// 旧实现给整个 segment 宽度预创建 N 个 UIImageView 子视图，1000 秒视频在 minPPS=20
/// 下产生 ~450 个 UIImageView，超过 CALayer 单图层栅格化上限，导致 ScrollView 坐标
/// 异常、Pinch 手势失效。CATiledLayer 只渲染当前可见 tile，子视图数始终为 0。
///
/// API 保持兼容：`load(asset:segment:)` / `cancelLoading()` 调用点不变。
final class ThumbnailStripView: UIView {

    private static let thumbTileWidth: CGFloat = 44  // pt; matches blockH ≈ 40pt

    // 仅在 macOS Catalyst / iOS 上使用 CATiledLayer
    override class var layerClass: AnyClass { ThumbnailTiledLayer.self }
    private var tiled: ThumbnailTiledLayer { layer as! ThumbnailTiledLayer }

    // V5.1 BUG 4: 保存最近一次 load 的入参，用于 thumbnailProviderDidPurge 后主动恢复。
    private var lastAsset: EditorAsset?
    private var lastSegment: EditorSegment?
    // Swift 6 strict concurrency: NSObjectProtocol is not Sendable, but the observer
    // is only assigned on MainActor (init) and read in nonisolated deinit. Mirror the
    // pattern used by CompositionCoordinator / FullScreenPreviewController.
    nonisolated(unsafe) private var purgeObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // CATiledLayer 自动用其内置队列异步绘制；不在 main 排队 layout，避免阻塞。
        tiled.contentsScale = UIScreen.main.scale
        purgeObserver = NotificationCenter.default.addObserver(
            forName: .thumbnailProviderDidPurge,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.window != nil else { return }
            self.tiled.purgeLocalCache()
        }
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    deinit {
        if let purgeObserver { NotificationCenter.default.removeObserver(purgeObserver) }
    }

    private var lastBoundsWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        // bounds 变化时（trim / zoom）：tile 索引含义会变（index→时间戳的映射依赖 totalTiles
        // = ceil(bounds.width/tileW)），必须先清本地 cache 再 invalidate 重绘，否则
        // 旧索引下的图片会被错位渲染到新位置。
        if abs(bounds.width - lastBoundsWidth) > 0.5 {
            lastBoundsWidth = bounds.width
            tiled.purgeLocalCache()
        } else {
            tiled.setNeedsDisplay()
        }
    }

    // MARK: - Load (compat API)

    func load(asset: EditorAsset?, segment: EditorSegment) {
        lastAsset = asset
        lastSegment = segment
        tiled.configure(asset: asset, segment: segment, tileWidthPoints: Self.thumbTileWidth)
    }

    func cancelLoading() {
        // CATiledLayer 自身按需绘制，无显式 Task 列表需要取消；调用点保留兼容。
    }
}

/// CATiledLayer 后备实现。绘制在后台线程，状态读写通过 OSAllocatedUnfairLock 同步。
/// 单个「逻辑 tile」= 一个 44pt 宽的缩略图；CATiledLayer 内部按 256×256 像素分块
/// 调用 draw(in:)，每次绘一片可能包含多个逻辑 tile。
/// Sendable: 所有可变状态都被 stateLock / NSCache（自身线程安全）保护。
private final class ThumbnailTiledLayer: CATiledLayer, @unchecked Sendable {

    /// 关闭 tile 淡入动画，避免缩放时缩略图渐现产生的闪烁。
    override class func fadeDuration() -> CFTimeInterval { 0 }

    // 单个缩略图 tile 在 layer 点坐标系下的宽度。configure 时由 ThumbnailStripView 注入。
    private struct State {
        var url: URL?
        var segment: EditorSegment?
        var isImageAsset: Bool = false
        var thumbTilePoints: CGFloat = 44
        /// configure 调用计数，用于丢弃跨 segment 的过时异步加载结果。
        var generation: UInt64 = 0
    }

    // Swift 6 async-safe scoped locking. CATiledLayer.draw(in:) is called on a background
    // queue; configure() writes from main. NSLock is forbidden in async context.
    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    /// 本地同步缓存：tile 索引 → UIImage。NSCache 自身线程安全。
    /// configure 切换或 purge 通知时清空。
    private let tileImageCache = NSCache<NSNumber, UIImage>()

    override init() {
        super.init()
        contentsScale = UIScreen.main.scale
        // 256×256 像素是 CATiledLayer 推荐尺寸；levelsOfDetail=1 表示无多级 LOD。
        tileSize = CGSize(width: 256, height: 256)
        levelsOfDetail = 1
        levelsOfDetailBias = 0
        tileImageCache.countLimit = 256
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    /// 由 ThumbnailStripView 调用（主线程）。完整切换 asset/segment 上下文。
    func configure(asset: EditorAsset?, segment: EditorSegment?, tileWidthPoints: CGFloat) {
        stateLock.withLock { state in
            state.url = asset?.bestURL
            state.segment = segment
            if let asset, case .image = asset.type {
                state.isImageAsset = true
            } else {
                state.isImageAsset = false
            }
            state.thumbTilePoints = tileWidthPoints
            state.generation &+= 1
        }
        tileImageCache.removeAllObjects()
        setNeedsDisplay()
    }

    /// purge 通知时调用：清本地 cache + 重绘。底层 ThumbnailProvider.cache 已被外部 purge。
    func purgeLocalCache() {
        tileImageCache.removeAllObjects()
        setNeedsDisplay()
    }

    // MARK: - Drawing (background thread)

    override func draw(in ctx: CGContext) {
        let snapshot = stateLock.withLock { $0 }
        let url = snapshot.url
        let segment = snapshot.segment
        let isImage = snapshot.isImageAsset
        let tileW = snapshot.thumbTilePoints
        let myGen = snapshot.generation

        guard let url, let segment, tileW > 0 else { return }

        let clipRect = ctx.boundingBoxOfClipPath
        let h = bounds.height
        let totalW = bounds.width
        let totalTiles = max(1, Int(ceil(totalW / tileW)))
        // CoreAnimation may request drawing for a clipRect entirely beyond the bounds
        // (e.g. during rubber-band overscroll or zoom). Clamp firstIndex to totalTiles
        // so the range firstIndex..<lastIndex is never invalid.
        let firstIndex = min(max(0, Int(floor(clipRect.minX / tileW))), totalTiles)
        let lastIndex  = min(totalTiles, max(0, Int(ceil(clipRect.maxX / tileW))))
        guard firstIndex < lastIndex else { return }
        let srcStart = segment.sourceRange?.start    ?? 0
        let srcDur   = segment.sourceRange?.duration ?? segment.targetRange.duration

        // Request enough pixels for the actual tile aspect. AVAssetImageGenerator
        // preserves source aspect, so final drawing still center-crops below.
        let pixelSize = CGSize(
            width: max(tileW * contentsScale, 88),
            height: max(h * contentsScale, 88)
        )
        
        for i in firstIndex..<lastIndex {
            let key = i as NSNumber
            let tileRect = CGRect(x: CGFloat(i) * tileW, y: 0, width: tileW, height: h)

            if let img = tileImageCache.object(forKey: key), let cg = img.cgImage {
                // ctx 来自 CATiledLayer，坐标系 origin 在左下；翻转 y 后再 draw。
                // Draw with aspect-fill instead of stretching the frame into the
                // tile. This keeps landscape/portrait video and photo thumbnails
                // visually natural at any track height.
                let drawBounds = CGRect(x: tileRect.minX, y: 0,
                                        width: tileRect.width, height: tileRect.height)
                let imageSize = CGSize(width: cg.width, height: cg.height)
                let drawRect = Self.aspectFillRect(for: imageSize, in: drawBounds)
                ctx.saveGState()
                ctx.translateBy(x: 0, y: tileRect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.clip(to: drawBounds)
                ctx.draw(cg, in: drawRect)
                ctx.restoreGState()
            } else {
                // Cache miss：异步请求 + 完成后 setNeedsDisplay(局部 tile)。
                let t: Double = isImage ? 0 :
                    (totalTiles > 1
                        ? srcStart + Double(i) / Double(totalTiles - 1) * srcDur
                        : srcStart)
                Self.fetchTile(layer: self, url: url, isImage: isImage,
                               time: t, size: pixelSize, tileIndex: i,
                               tileRect: tileRect, expectedGeneration: myGen)
            }
        }
    }

    private static func aspectFillRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - scaledSize.width / 2,
            y: bounds.midY - scaledSize.height / 2,
            width: scaledSize.width,
            height: scaledSize.height
        )
    }

    /// Sendable 包装，让 Swift 6 strict concurrency 信任 weak 引用穿越 isolation boundary。
    /// CATiledLayer 自身已声明 @unchecked Sendable，本 wrapper 仅是显式 Sendable 标记。
    private struct WeakRef: @unchecked Sendable {
        weak var value: ThumbnailTiledLayer?
    }

    /// 静态调度，避免在 draw(in:) 内捕获 self 闭包触发 Swift 6 `sending` 检查。
    /// 用 WeakRef + Task.detached：WeakRef 是 Sendable，闭包内通过 ref.value 解引用。
    nonisolated private static func fetchTile(
        layer: ThumbnailTiledLayer,
        url: URL,
        isImage: Bool,
        time: Double,
        size: CGSize,
        tileIndex: Int,
        tileRect: CGRect,
        expectedGeneration: UInt64
    ) {
        let ref = WeakRef(value: layer)
        Task.detached {
            let img = await ThumbnailProvider.shared.thumbnail(
                for: url, isImage: isImage, at: time, size: size
            )
            guard let layer = ref.value, let img else { return }
            let curGen = layer.stateLock.withLock { $0.generation }
            guard curGen == expectedGeneration else { return }
            layer.tileImageCache.setObject(img, forKey: tileIndex as NSNumber)
            await MainActor.run {
                ref.value?.setNeedsDisplay(tileRect)
            }
        }
    }
}

// MARK: - WaveformStripView

/// A waveform visualization for audio segment blocks.
/// Renders symmetric amplitude bars using a CAShapeLayer.
/// Waveform data is generated asynchronously via WaveformProvider and cached.
final class WaveformStripView: UIView {

    /// Gap between bars in the waveform, in points.
    private static let barGap: CGFloat = 0.5

    private let shapeLayer = CAShapeLayer()
    private var loadingTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        shapeLayer.fillColor = UIColor.white.withAlphaComponent(0.6).cgColor
        shapeLayer.strokeColor = nil
        layer.addSublayer(shapeLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds
    }

    // MARK: - Load

    func load(url: URL) {
        loadingTask?.cancel()
        shapeLayer.path = nil

        guard bounds.width > 4, bounds.height > 4 else { return }

        let viewSize = bounds.size
        let task = Task { [weak self] in
            guard let self else { return }
            let samples = await WaveformProvider.shared.waveform(for: url)
            guard !Task.isCancelled, let samples else { return }
            await MainActor.run {
                self.shapeLayer.path = Self.buildPath(samples: samples, size: viewSize)
            }
        }
        loadingTask = task
    }

    func cancelLoading() {
        loadingTask?.cancel()
        loadingTask = nil
    }

    // MARK: - Path building

    private static func buildPath(samples: [Float], size: CGSize) -> CGPath {
        let path = CGMutablePath()
        guard samples.count > 1, size.width > 0, size.height > 0 else { return path }

        let barCount = min(samples.count, Int(size.width / (1 + barGap)))
        let step = max(1, samples.count / barCount)
        let barWidth = max(1, size.width / CGFloat(barCount) - barGap)
        let midY = size.height / 2
        let maxAmp = midY - 2  // 2pt padding from top/bottom

        for i in 0..<barCount {
            let sampleIdx = min(i * step + step / 2, samples.count - 1)
            let amp = CGFloat(samples[sampleIdx]) * maxAmp
            let x = CGFloat(i) * (barWidth + barGap)
            let rect = CGRect(x: x, y: midY - amp, width: barWidth, height: amp * 2)
            path.addRect(rect)
        }

        return path
    }
}
#endif

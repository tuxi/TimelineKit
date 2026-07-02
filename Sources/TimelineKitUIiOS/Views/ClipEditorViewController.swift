#if canImport(UIKit)
import UIKit
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared

/// UIKit root view controller for the clip editor's track area.
/// Owns the scroll view, canvas, and all gesture recognizers.
/// SwiftUI hosts this via TrackEditorRepresentable.
public final class ClipEditorViewController: UIViewController {

    // MARK: - Properties

    private let store: EditorStore
    private var timeline: EditorTimeline
    private var selection: SelectionState

    private var scrollView: UIScrollView!
    private var canvas: TrackCanvasView!
    private var labelsView: TrackLabelsView!
    private var didInitialLayout = false

    /// Guards against re-entrant scroll sync between canvas and labels scroll views.
    private var isSyncingScroll = false

    // Pinch zoom state
    private var pinchStartPPS: CGFloat = 0
    private var pinchAnchorTime: Double = 0
    private var pinchAnchorScreenX: CGFloat = 0

    /// SwiftUI-owned route for empty-track add affordances.
    public var onEmptyTrackAdd: ((UUID, EditorTrack.Kind) -> Void)?

    // Scrub state (spec: timeline-scrub-playback-spec.md)
    private var scrubWasPlaying = false
    private var lastScrubTime: CFTimeInterval = 0
    private let scrubThrottle: CFTimeInterval = 0.033        // 33ms ≈ 30fps
    private var lastSnapTime: Double = -1
    private var isScrollScrubbing = false                    // user dragging timeline

    // Haptic (prepared once, reused)
    private let snapFeedback  = UIImpactFeedbackGenerator(style: .rigid)
    private let lightFeedback = UIImpactFeedbackGenerator(style: .light)

    // MARK: - Init

    public init(store: EditorStore) {
        self.store     = store
        self.timeline  = store.timeline
        self.selection = store.selection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)
        setupTrackLabels()
        setupScrollView()
        setupCanvas()
        setupGestureRecognizers()
    }

    // MARK: - Public API (called from SwiftUI representable)

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Update content insets on every layout so playhead stays centered after rotation.
        updateScrollInsets()
        guard !didInitialLayout else { return }
        didInitialLayout = true
        canvas.configure(timeline: timeline, availableWidth: scrollView.bounds.width)
        labelsView.configure(tracks: timeline.tracks)
        // v4: sync labels scroll view contentSize to match canvas content height,
        // then align initial vertical offset. Both scroll views share the same
        // contentInset (none) so offset equality means row alignment.
        labelsView.syncContentSize(with: scrollView.contentSize.height)
        syncLabelScrollOffset()
        scrollToPlayhead(time: selection.playheadTime, animated: false)
        syncLabelScrollOffset()
        snapFeedback.prepare()
        lightFeedback.prepare()
    }

    public func apply(timeline: EditorTimeline, selection: SelectionState) {
        let structural = hasStructuralChange(from: self.timeline, to: timeline)
        let tracksAdded = timeline.tracks.count > self.timeline.tracks.count
        // Detect newly-appeared segments (e.g. split inserts a new half, photo picker
        // adds a clip) so the canvas can briefly flash them as feedback.
        let appearedSegmentIDs: Set<UUID> = {
            guard structural else { return [] }
            let priorRendered = canvas.renderedSegmentIDs
            // Skip first configure (priorRendered empty) so we don't flash every block on entry.
            guard !priorRendered.isEmpty else { return [] }
            let next = Set(timeline.tracks.flatMap { $0.segments.map(\.id) })
            return next.subtracting(priorRendered)
        }()

        self.timeline  = timeline
        self.selection = selection

        if structural {
            canvas.configure(timeline: timeline, availableWidth: scrollView.bounds.width)
            labelsView.configure(tracks: timeline.tracks)
            labelsView.syncContentSize(with: scrollView.contentSize.height)
            if tracksAdded {
                scrollToRevealNewTracks()
            }
            if !appearedSegmentIDs.isEmpty {
                canvas.flashSegments(ids: appearedSegmentIDs)
            }
        } else {
            canvas.relayoutSegments(timeline: timeline)
            // v4: refresh labels button state immediately on non-structural changes
            // (lock / hide / mute toggles) so icons + tints update without rebuild.
            labelsView.refreshTrackStates(timeline.tracks)
        }
        canvas.updatePlayhead(time: selection.playheadTime)
        canvas.updateSelection(ids: selection.selectedSegmentIDs)

        // Auto-scroll during playback: keep playhead fixed at screen center.
        if store.isPlaying && !isScrollScrubbing {
            scrollToPlayhead(time: selection.playheadTime, animated: false)
        }
    }

    /// Returns true only when tracks or segments are added/removed/reordered —
    /// pure time-range changes (trim/move) are NOT structural and don't need full rebuild.
    private func hasStructuralChange(from old: EditorTimeline, to new: EditorTimeline) -> Bool {
        guard old.tracks.count == new.tracks.count else { return true }
        for (o, n) in zip(old.tracks, new.tracks) {
            guard o.id == n.id, o.segments.count == n.segments.count else { return true }
            if zip(o.segments, n.segments).contains(where: { $0.id != $1.id }) { return true }
        }
        return false
    }

    // MARK: - Layout

    // v4: collapsible sidebar — width animates between collapsed (52pt) and expanded (136pt).
    private var labelsWidthConstraint: NSLayoutConstraint!

    private func setupTrackLabels() {
        labelsView = TrackLabelsView()
        labelsView.translatesAutoresizingMaskIntoConstraints = false
        labelsView.scrollView.delegate = self
        view.addSubview(labelsView)
        labelsWidthConstraint = labelsView.widthAnchor.constraint(equalToConstant: TrackLabelsView.collapsedWidth)
        NSLayoutConstraint.activate([
            labelsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            labelsView.topAnchor.constraint(equalTo: view.topAnchor),
            labelsView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            labelsWidthConstraint
        ])
        labelsView.onAddTrack = { [weak self] kind in
            self?.store.addTrack(kind: kind, pendingUserCreated: true)
        }
        // v4: animate sidebar width when expand/collapse state changes.
        labelsView.onExpandStateChange = { [weak self] expanded in
            guard let self else { return }
            self.labelsWidthConstraint.constant = expanded
                ? TrackLabelsView.expandedWidth
                : TrackLabelsView.collapsedWidth
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) {
                self.view.layoutIfNeeded()
            }
        }
        // v4: wire track control button taps from the collapsible sidebar.
        labelsView.onToggleLock = { [weak self] id in
            guard let t = self?.store.timeline.track(id: id) else { return }
            self?.store.setTrackLocked(id: id, isLocked: !t.isLocked)
        }
        labelsView.onToggleHidden = { [weak self] id in
            guard let t = self?.store.timeline.track(id: id), !t.isMainTrack else { return }
            self?.store.setTrackHidden(id: id, isHidden: !t.isHidden)
        }
        labelsView.onToggleMute = { [weak self] id in
            guard let t = self?.store.timeline.track(id: id) else { return }
            self?.store.muteTrack(id: id, isMuted: !t.isMuted)
        }
    }

    private func setupScrollView() {
        scrollView = UIScrollView()
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.decelerationRate = .fast
        scrollView.backgroundColor = .clear
        // v4: disable automatic safe-area inset adjustment so both scroll views
        // start at contentOffset.y == 0. The canvas and labels scroll views must
        // share identical contentInset for bidirectional offset sync to work.
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: labelsView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupCanvas() {
        canvas = TrackCanvasView()
        // Frame-based layout so configure() can set the full content width for scrolling.
        canvas.translatesAutoresizingMaskIntoConstraints = true
        canvas.autoresizingMask = []
        canvas.frame = CGRect(x: 0, y: 0, width: 100, height: 200)
        scrollView.addSubview(canvas)

        // Wire trim commits to EditorStore (undo-tracked, triggers rebuild for main track).
        // After the store mutation completes synchronously, immediately relay out the canvas
        // so block positions match the new timeline without waiting for the SwiftUI
        // observation cycle (which would leave visible overlaps until the next run-loop turn).
        canvas.onTrimCommit = { [weak self] segID, range, newSrcStart in
            guard let self else { return }
            self.store.trimSegment(id: segID, newTargetRange: range, newSourceRangeStart: newSrcStart)
            self.canvas.relayoutSegments(timeline: self.store.timeline)
        }

        // Wire live trim preview for overlay/subtitle tracks (no undo, no rebuild)
        canvas.onTrimPreview = { [weak self] segID, range in
            self?.store.previewTrimRange(segmentID: segID, range: range)
        }

        // Wire long-press reorder to EditorStore
        canvas.onReorderCommit = { [weak self] trackID, newOrder in
            self?.store.reorderSegments(trackID: trackID, newOrder: newOrder)
        }

        // Wire free-pan move to EditorStore (non-main tracks)
        canvas.onMoveCommit = { [weak self] segID, newStart in
            self?.store.moveSegment(id: segID, to: newStart)
        }

        // Lock scroll while a segment is being panned to prevent timeline drift
        canvas.onScrollLock = { [weak self] lock in
            self?.scrollView.panGestureRecognizer.isEnabled = !lock
        }

        // Transition badge tap → open transition sheet via SelectionState
        canvas.onTransitionTap = { [weak self] leadingID, trailingID, existing in
            self?.store.selection.editingTransitionContext =
                TransitionEditContext(leadingID: leadingID, trailingID: trailingID,
                                     existingTransition: existing)
        }

        // Empty user-created track tap → SwiftUI decides which picker/panel to present.
        canvas.onEmptyTrackAdd = { [weak self] trackID, kind in
            self?.onEmptyTrackAdd?(trackID, kind)
        }
    }

    private func setupGestureRecognizers() {
        let playheadPan = UIPanGestureRecognizer(target: self, action: #selector(handlePlayheadPan(_:)))
        playheadPan.delegate = self
        canvas.addPlayheadGesture(playheadPan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        canvas.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        scrollView.addGestureRecognizer(pinch)
    }

    // MARK: - Gesture Handlers

    /// Direct playhead drag on ruler (spec: ±20pt around playhead line).
    /// Throttled to 33ms, pauses playback while scrubbing, snaps to segment edges.
    @objc private func handlePlayheadPan(_ gr: UIPanGestureRecognizer) {
        switch gr.state {
        case .began:
            scrubWasPlaying = store.isPlaying
            store.pause()
            lowerResolution()
            snapFeedback.prepare()
            lastScrubTime = 0

        case .changed:
            let now = CACurrentMediaTime()
            guard now - lastScrubTime >= scrubThrottle else { return }
            lastScrubTime = now
            let rawTime = canvas.time(at: gr.location(in: canvas).x)
            let snapped = snapToEdge(rawTime)
            store.seek(to: snapped)

        case .ended, .cancelled:
            if scrubWasPlaying { store.play() }
            restoreResolution()

        default:
            break
        }
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        let point = gr.location(in: canvas)
        // v4: header controls moved to TrackLabelsView sidebar — canvas taps
        // are always segment taps (or deselect).
        if let segID = canvas.segmentID(at: point) {
            store.selection.selectedSegmentIDs = [segID]
            store.selection.editingSegmentID   = nil
        } else {
            store.selection.deselect()
        }
    }

    /// Pinch zoom — anchor follows the pinch center (midpoint between two fingers).
    @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
        switch gr.state {
        case .began:
            pinchStartPPS      = canvas.currentPixelsPerSecond
            pinchAnchorScreenX = gr.location(in: scrollView).x
            let canvasX = scrollView.contentOffset.x + pinchAnchorScreenX
            pinchAnchorTime = canvas.time(at: max(0, canvasX))

        case .changed:
            let newPPS = pinchStartPPS * gr.scale
            canvas.zoom(to: newPPS, playheadTime: selection.playheadTime)
            // Keep pinch-anchor time at the same screen position after content size changes.
            let anchorCanvasX = canvas.x(for: pinchAnchorTime)
            let targetOffsetX = anchorCanvasX - pinchAnchorScreenX
            let minX = -scrollView.contentInset.left
            let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right)
            scrollView.contentOffset.x = min(max(targetOffsetX, minX), maxX)

        default:
            break
        }
    }

    // MARK: - Helpers

    /// v4: sync labels scrollView contentOffset.y from the canvas scrollView.
    /// Called after content size changes to keep rows aligned.
    private func syncLabelScrollOffset() {
        isSyncingScroll = true
        labelsView.scrollView.contentOffset.y = scrollView.contentOffset.y
        isSyncingScroll = false
    }

    /// Scroll so `time` is at horizontal screen center.
    private func scrollToPlayhead(time: Double, animated: Bool) {
        let targetX = canvas.x(for: time) - scrollView.bounds.width / 2
        let minX    = -scrollView.contentInset.left
        let maxX    = max(minX, scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right)
        let clamped = min(max(targetX, minX), maxX)
        if animated {
            UIView.animate(withDuration: 0.15) { self.scrollView.contentOffset.x = clamped }
        } else {
            scrollView.contentOffset.x = clamped
        }
    }

    /// Content insets = half scroll-view width on each side so t=0 and t=duration
    /// can both appear at screen center (剪映 paradigm).
    private func updateScrollInsets() {
        let half = scrollView.bounds.width / 2
        guard scrollView.contentInset.left != half else { return }
        scrollView.contentInset = UIEdgeInsets(top: 0, left: half, bottom: 0, right: half)
    }

    /// v4 (multi-track-scroll-spec §2.4): after a new track is appended at the bottom,
    /// scroll vertically just enough to bring the new row into view.
    private func scrollToRevealNewTracks() {
        let maxY = scrollView.contentSize.height - scrollView.bounds.height
        guard maxY > 0 else { return }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: maxY),
            animated: true
        )
        // Sync labels immediately since animated setContentOffset doesn't fire delegate reliably.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.syncLabelScrollOffset()
        }
    }

    /// Snap `time` to the nearest segment edge if within 0.1s; fires haptic on snap.
    private func snapToEdge(_ time: Double) -> Double {
        let pps = Double(canvas.currentPixelsPerSecond)
        let threshold = max(0.1, 8.0 / pps)   // 8pt in seconds, min 0.1s
        let edges: [Double] = timeline.tracks
            .flatMap { $0.segments }
            .flatMap { [$0.targetRange.start, $0.targetRange.end] }
            + [0, timeline.duration]

        guard let nearest = edges.min(by: { abs($0 - time) < abs($1 - time) }),
              abs(nearest - time) <= threshold else {
            lastSnapTime = -1
            return time
        }
        if abs(nearest - lastSnapTime) > 0.01 {
            snapFeedback.impactOccurred()
            lastSnapTime = nearest
        }
        return nearest
    }

    private func lowerResolution() {
        store.coordinatorPlayer?.currentItem?.preferredMaximumResolution = CGSize(width: 960, height: 540)
    }

    private func restoreResolution() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.store.coordinatorPlayer?.currentItem?.preferredMaximumResolution = .zero
        }
    }
}

// MARK: - UIScrollViewDelegate

extension ClipEditorViewController: UIScrollViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // Only respond to canvas scrollView drags (not labels scrollView).
        guard scrollView === self.scrollView else { return }
        isScrollScrubbing = true
        scrubWasPlaying = store.isPlaying
        store.pause()
        lowerResolution()
        lightFeedback.prepare()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // v4: bidirectional native scroll sync — whichever side the user drags,
        // mirror contentOffset.y on the other. Guard against re-entrancy so
        // setting one offset doesn't recursively call back.
        guard !isSyncingScroll else { return }
        isSyncingScroll = true
        if scrollView === self.scrollView {
            // Canvas scrolled → sync labels
            labelsView.scrollView.contentOffset.y = scrollView.contentOffset.y
        } else if scrollView === labelsView.scrollView {
            // Labels scrolled → sync canvas
            self.scrollView.contentOffset.y = scrollView.contentOffset.y
        }
        isSyncingScroll = false

        // Horizontal scroll on canvas: scrub playhead
        guard scrollView === self.scrollView, isScrollScrubbing else { return }
        let centerX = scrollView.contentOffset.x + scrollView.bounds.width / 2
        let newTime = max(0, min(canvas.time(at: max(0, centerX)), timeline.duration))
        store.selection.playheadTime = newTime
        let now = CACurrentMediaTime()
        guard now - lastScrubTime >= scrubThrottle else { return }
        lastScrubTime = now
        store.seek(to: newTime)
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === self.scrollView else { return }
        if !decelerate { finishScrollScrub() }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        finishScrollScrub()
    }

    private func finishScrollScrub() {
        isScrollScrubbing = false
        if scrubWasPlaying { store.play() }
        restoreResolution()
    }
}

// MARK: - UIGestureRecognizerDelegate

extension ClipEditorViewController: UIGestureRecognizerDelegate {
    public func gestureRecognizer(
        _ gr: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Pinch + scroll pan can coexist (two-finger zoom while panning).
        if gr is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer { return true }
        // Trim handle pans block the scroll pan so segments don't drift while trimming.
        if other === scrollView.panGestureRecognizer { return false }
        return true
    }
}

// MARK: - Track Labels Sidebar (v4 collapsible with UIScrollView sync)

/// Fixed left column showing track-kind icon + name, with a tap-to-expand control panel.
///
/// v4 architecture:
/// - Wraps content in its own `UIScrollView` for native bidirectional scroll sync.
/// - **Collapsed** (default, 52pt): icon + name only — all control buttons hidden.
/// - **Expanded** (136pt): full lock / hide / mute buttons per track (per-kind rules).
/// - Toggle via tap on the chevron button at the top of the sidebar.
/// - Auto-collapses 1.5s after any control button tap.
final class TrackLabelsView: UIView {

    // MARK: - Layout constants

    static let collapsedWidth: CGFloat = 52
    static let expandedWidth: CGFloat  = 136

    private static let multiTrackKinds: Set<EditorTrack.Kind> = [.text, .subtitle, .audio, .overlay]

    // MARK: - Subviews

    let scrollView = UIScrollView()
    private let contentContainer = UIView()
    private let toggleButton = UIButton(type: .system)
    private var trackRows: [TrackLabelRowView] = []

    // MARK: - State

    private(set) var isExpanded = false
    private var tracks: [EditorTrack] = []
    private var autoCollapseWorkItem: DispatchWorkItem?

    // MARK: - Callbacks

    var onToggleLock:   ((UUID) -> Void)?
    var onToggleHidden: ((UUID) -> Void)?
    var onToggleMute:   ((UUID) -> Void)?
    var onAddTrack:     ((EditorTrack.Kind) -> Void)?
    var onExpandStateChange: ((Bool) -> Void)?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.10, alpha: 1)
        clipsToBounds = true

        // ScrollView — vertical only, no horizontal bounce/scroll.
        scrollView.showsVerticalScrollIndicator   = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical           = true
        scrollView.alwaysBounceHorizontal         = false
        scrollView.isDirectionalLockEnabled       = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.autoresizingMask               = [.flexibleWidth, .flexibleHeight]
        addSubview(scrollView)

        scrollView.addSubview(contentContainer)

        // Toggle button — fixed at top edge, outside scroll area.
        // Pinned to trailing edge so it stays visible in both collapsed & expanded widths.
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        toggleButton.setImage(UIImage(systemName: "chevron.right.2", withConfiguration: cfg), for: .normal)
        toggleButton.tintColor = UIColor.white.withAlphaComponent(0.45)
        toggleButton.addTarget(self, action: #selector(didTapToggle), for: .touchUpInside)
        addSubview(toggleButton)
        NSLayoutConstraint.activate([
            toggleButton.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            toggleButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            toggleButton.widthAnchor.constraint(equalToConstant: 22),
            toggleButton.heightAnchor.constraint(equalToConstant: 22)
        ])

        // Right separator
        let sep = UIView()
        sep.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)
        NSLayoutConstraint.activate([
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.topAnchor.constraint(equalTo: topAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            sep.widthAnchor.constraint(equalToConstant: 0.5)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
    }

    // MARK: - Configure

    func configure(tracks: [EditorTrack]) {
        self.tracks = tracks
        trackRows.forEach { $0.removeFromSuperview() }
        trackRows.removeAll()

        let ordered = TrackCanvasView.SegmentVisuals.sortedTracks(tracks)

        var lastIndexByKind: [EditorTrack.Kind: Int] = [:]
        for (i, t) in ordered.enumerated() { lastIndexByKind[t.kind] = i }

        // Ruler spacer
        let rulerSpacer = UIView()
        rulerSpacer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TrackCanvasView.rulerHeight)
        contentContainer.addSubview(rulerSpacer)

        var yOffset = TrackCanvasView.rulerHeight
        for (i, track) in ordered.enumerated() {
            let showAdd = Self.multiTrackKinds.contains(track.kind)
                       && lastIndexByKind[track.kind] == i
            let row = TrackLabelRowView(track: track, isExpanded: isExpanded, showAddButton: showAdd)
            row.frame = CGRect(x: 0, y: yOffset, width: Self.expandedWidth, height: TrackCanvasView.trackHeight)

            row.onToggleLock   = { [weak self] in self?.didTapControl(); self?.onToggleLock?(track.id) }
            row.onToggleHidden = { [weak self] in self?.didTapControl(); self?.onToggleHidden?(track.id) }
            row.onToggleMute   = { [weak self] in self?.didTapControl(); self?.onToggleMute?(track.id) }
            row.onAddTrack     = { [weak self] in self?.onAddTrack?(track.kind) }

            contentContainer.addSubview(row)
            trackRows.append(row)
            yOffset += TrackCanvasView.trackHeight + TrackCanvasView.trackSpacing
        }

        let totalHeight = TrackCanvasView.rulerHeight
            + CGFloat(tracks.count) * (TrackCanvasView.trackHeight + TrackCanvasView.trackSpacing)
        contentContainer.frame = CGRect(x: 0, y: 0, width: Self.expandedWidth, height: totalHeight)
        scrollView.contentSize = CGSize(width: Self.expandedWidth, height: totalHeight)
    }

    /// Lightweight refresh of button states without full rebuild. Called on non-structural
    /// timeline updates (lock/hide/mute toggle).
    func refreshTrackStates(_ tracks: [EditorTrack]) {
        self.tracks = tracks
        let ordered = TrackCanvasView.SegmentVisuals.sortedTracks(tracks)
        for (i, track) in ordered.enumerated() where i < trackRows.count {
            trackRows[i].update(track: track, isExpanded: isExpanded)
        }
    }

    // MARK: - Expand / Collapse

    func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        cancelAutoCollapse()
        updateToggleIcon()

        let changes = {
            for row in self.trackRows {
                row.setExpanded(expanded)
            }
        }

        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut, animations: changes)
        } else {
            changes()
        }
        onExpandStateChange?(expanded)
    }

    func toggleExpanded() {
        setExpanded(!isExpanded)
    }

    @objc private func didTapToggle() {
        toggleExpanded()
    }

    private func updateToggleIcon() {
        let cfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let name = isExpanded ? "chevron.left.2" : "chevron.right.2"
        toggleButton.setImage(UIImage(systemName: name, withConfiguration: cfg), for: .normal)
    }

    private func didTapControl() {
        scheduleAutoCollapse()
    }

    private func scheduleAutoCollapse() {
        cancelAutoCollapse()
        let work = DispatchWorkItem { [weak self] in
            self?.setExpanded(false)
        }
        autoCollapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func cancelAutoCollapse() {
        autoCollapseWorkItem?.cancel()
        autoCollapseWorkItem = nil
    }

    // MARK: - Scroll Sync

    /// Total content height of the label rows (including ruler spacer). Used by the
    /// view controller to keep contentSize in sync with the canvas scroll view.
    var contentHeight: CGFloat {
        contentContainer.frame.height
    }

    func syncContentSize(with canvasContentHeight: CGFloat) {
        let h = max(canvasContentHeight, contentHeight)
        scrollView.contentSize = CGSize(width: Self.expandedWidth, height: h)
    }
}

// MARK: - Track Label Row View

/// A single row in the collapsible track labels sidebar.
///
/// Layout (collapsed, 52pt) — pure icon + name, all buttons hidden:
/// ```
/// [icon]
/// [name]
/// ```
///
/// Layout (expanded, 136pt) — full control panel:
/// ```
/// [icon] [name] [lock] [hide] [mute] [+]
/// ```
///
/// Per-kind button visibility:
/// - Lock : every track
/// - Hide : every track EXCEPT main video
/// - Mute : only `.video` and `.audio` tracks
final class TrackLabelRowView: UIView {

    var onToggleLock:   (() -> Void)?
    var onToggleHidden: (() -> Void)?
    var onToggleMute:   (() -> Void)?
    var onAddTrack:     (() -> Void)?

    private var track: EditorTrack
    private var isExpanded: Bool

    private let iconView   = UIImageView()
    private let nameLabel  = UILabel()
    private let buttonStack = UIStackView()
    private var lockBtn: UIButton?
    private var hideBtn: UIButton?
    private var muteBtn: UIButton?
    private var addBtn: UIButton?

    private let haptic = UISelectionFeedbackGenerator()

    private static let tracksWithAudio: Set<EditorTrack.Kind> = [.video, .audio]

    init(track: EditorTrack, isExpanded: Bool, showAddButton: Bool) {
        self.track = track
        self.isExpanded = isExpanded
        super.init(frame: .zero)

        // Icon
        iconView.image = Self.icon(for: track.kind)
        iconView.tintColor = Self.iconColor(for: track.kind)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Name label
        nameLabel.text = Self.labelText(for: track.kind)
        nameLabel.font = UIFont.systemFont(ofSize: 10, weight: .medium)
        nameLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        nameLabel.textAlignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        // Button stack (horizontal)
        buttonStack.axis = .horizontal
        buttonStack.spacing = 4
        buttonStack.alignment = .center
        buttonStack.distribution = .fill
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonStack)

        // Icon + label vertical stack pinned left
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),

            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 6),
            nameLabel.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),

            buttonStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttonStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])

        buildButtons(track: track, showAddButton: showAddButton)
        applyExpandedState(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Update

    func update(track: EditorTrack, isExpanded: Bool) {
        self.track = track
        self.isExpanded = isExpanded
        refreshButtonIcons()
        applyExpandedState(animated: false)
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        applyExpandedState(animated: true)
    }

    private func applyExpandedState(animated: Bool) {
        let changes = {
            // Collapsed: all buttons hidden (pure icon + name).
            // Expanded: full lock / hide / mute per track kind rules.
            let showControls = self.isExpanded

            for btn in [self.lockBtn, self.hideBtn, self.muteBtn].compactMap({ $0 }) {
                btn.alpha = showControls ? 1 : 0
                btn.isHidden = !showControls
            }
            self.addBtn?.alpha = showControls ? 1 : 0
            self.addBtn?.isHidden = !showControls
            self.buttonStack.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut, animations: changes)
        } else {
            changes()
        }
    }

    private func refreshButtonIcons() {
        Self.style(button: lockBtn,
                   icon: track.isLocked ? "lock.fill" : "lock.open",
                   tint: track.isLocked ? .systemYellow : .white.withAlphaComponent(0.65),
                   label: track.isLocked ? "解锁轨道" : "锁定轨道")
        if let h = hideBtn {
            Self.style(button: h,
                       icon: track.isHidden ? "eye.slash.fill" : "eye",
                       tint: track.isHidden ? .systemOrange : .white.withAlphaComponent(0.65),
                       label: track.isHidden ? "显示轨道" : "隐藏轨道")
        }
        if let m = muteBtn {
            Self.style(button: m,
                       icon: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2",
                       tint: track.isMuted ? .systemRed : .white.withAlphaComponent(0.65),
                       label: track.isMuted ? "取消静音" : "静音轨道")
        }
    }

    // MARK: - Button building

    private func buildButtons(track: EditorTrack, showAddButton: Bool) {
        buttonStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        lockBtn = nil; hideBtn = nil; muteBtn = nil; addBtn = nil

        // Lock — every track
        let lock = Self.makeButton()
        Self.style(button: lock,
                   icon: track.isLocked ? "lock.fill" : "lock.open",
                   tint: track.isLocked ? .systemYellow : .white.withAlphaComponent(0.65),
                   label: track.isLocked ? "解锁轨道" : "锁定轨道")
        lock.addAction(UIAction { [weak self] _ in
            self?.haptic.selectionChanged()
            self?.onToggleLock?()
        }, for: .touchUpInside)
        buttonStack.addArrangedSubview(lock)
        lockBtn = lock

        // Hide — every track except main video
        if !track.isMainTrack {
            let hide = Self.makeButton()
            Self.style(button: hide,
                       icon: track.isHidden ? "eye.slash.fill" : "eye",
                       tint: track.isHidden ? .systemOrange : .white.withAlphaComponent(0.65),
                       label: track.isHidden ? "显示轨道" : "隐藏轨道")
            hide.addAction(UIAction { [weak self] _ in
                self?.haptic.selectionChanged()
                self?.onToggleHidden?()
            }, for: .touchUpInside)
            buttonStack.addArrangedSubview(hide)
            hideBtn = hide
        }

        // Mute — only video + audio
        if Self.tracksWithAudio.contains(track.kind) {
            let mute = Self.makeButton()
            Self.style(button: mute,
                       icon: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2",
                       tint: track.isMuted ? .systemRed : .white.withAlphaComponent(0.65),
                       label: track.isMuted ? "取消静音" : "静音轨道")
            mute.addAction(UIAction { [weak self] _ in
                self?.haptic.selectionChanged()
                self?.onToggleMute?()
            }, for: .touchUpInside)
            buttonStack.addArrangedSubview(mute)
            muteBtn = mute
        }

        // "+" add track button
        if showAddButton {
            let plus = Self.makeButton()
            let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            plus.setImage(UIImage(systemName: "plus.circle.fill", withConfiguration: cfg), for: .normal)
            plus.tintColor = UIColor.white.withAlphaComponent(0.55)
            plus.accessibilityLabel = "新建\(Self.labelText(for: track.kind))轨道"
            plus.addAction(UIAction { [weak self] _ in
                self?.onAddTrack?()
            }, for: .touchUpInside)
            buttonStack.addArrangedSubview(plus)
            addBtn = plus
        }
    }

    // MARK: - Helpers

    private static func makeButton() -> UIButton {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 22),
            btn.heightAnchor.constraint(equalToConstant: 22)
        ])
        return btn
    }

    private static func style(button: UIButton?, icon: String, tint: UIColor, label: String) {
        guard let button else { return }
        let cfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        button.setImage(UIImage(systemName: icon, withConfiguration: cfg), for: .normal)
        button.tintColor = tint
        button.accessibilityLabel = label
    }

    // MARK: - Static helpers (same as before)

    static func icon(for kind: EditorTrack.Kind) -> UIImage? {
        let name: String = {
            switch kind {
            case .video:      return "video.fill"
            case .overlay:    return "square.on.square.fill"
            case .text:       return "textformat"
            case .subtitle:   return "captions.bubble.fill"
            case .audio:      return "music.note"
            case .adjustment: return "slider.horizontal.3"
            }
        }()
        return UIImage(systemName: name)
    }

    static func iconColor(for kind: EditorTrack.Kind) -> UIColor {
        switch kind {
        case .video:      return UIColor.systemPurple
        case .overlay:    return UIColor.systemOrange
        case .text:       return UIColor.systemGreen
        case .subtitle:   return UIColor.systemBlue
        case .audio:      return UIColor.systemTeal
        case .adjustment: return UIColor.systemYellow
        }
    }

    static func labelText(for kind: EditorTrack.Kind) -> String {
        switch kind {
        case .video:      return "视频"
        case .overlay:    return "叠加"
        case .text:       return "文字"
        case .subtitle:   return "字幕"
        case .audio:      return "音频"
        case .adjustment: return "调节"
        }
    }
}
#endif

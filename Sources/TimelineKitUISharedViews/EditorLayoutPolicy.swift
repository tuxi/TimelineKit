import CoreGraphics

// MARK: - Input types

/// Width class used by the editor layout policy.
///
/// Kept platform-neutral so the policy can be tested without UIKit or SwiftUI.
public enum EditorSizeClass: String, Equatable, Sendable {
    case compact
    case regular
}

/// Reserved region kinds reported by iPhone Duo.
public enum EditorReservedRegionKind: String, Equatable, Sendable {
    /// The fold. Layout may split the workspace around an active division.
    case division
    /// Camera occlusion. Layout keeps interactive controls out of active frames.
    case occlusion
}

/// Platform-neutral reserved region.
public struct EditorReservedRegion: Equatable, Sendable {
    public let kind: EditorReservedRegionKind
    public let frame: CGRect
    public let isActive: Bool

    public init(kind: EditorReservedRegionKind, frame: CGRect, isActive: Bool) {
        self.kind = kind
        self.frame = frame
        self.isActive = isActive
    }
}

/// Platform-neutral safe-area insets.
public struct EditorLayoutInsets: Equatable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public static let zero = EditorLayoutInsets(top: 0, leading: 0, bottom: 0, trailing: 0)

    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

// MARK: - Metrics

/// Provisional layout thresholds.
///
/// These values are measurement targets for M1, not final device breakpoints.
/// The preview ratios mirror the current `ClipEditorView` behavior so wiring the
/// policy later does not change the existing UI by accident.
public struct EditorLayoutMetrics: Equatable, Sendable {
    public var phonePreviewRatio: CGFloat
    public var largePreviewRatio: CGFloat
    public var minPreviewHeight: CGFloat
    public var minTimelineHeight: CGFloat
    public var regularWorkspaceMinHeight: CGFloat
    public var wideWorkspaceMinWidth: CGFloat
    public var wideWorkspaceMinHeight: CGFloat
    public var foldPreviewMinWidth: CGFloat
    public var foldTimelineMinWidth: CGFloat
    public var foldPreviewMinHeight: CGFloat
    public var foldTimelineMinHeight: CGFloat
    public var compactTimelineMaxHeight: CGFloat
    public var compactTimelineMaxWidth: CGFloat
    public var occlusionTopBandHeight: CGFloat
    public var occlusionControlInset: CGFloat

    public init(
        phonePreviewRatio: CGFloat = 0.53,
        largePreviewRatio: CGFloat = 0.62,
        minPreviewHeight: CGFloat = 120,
        minTimelineHeight: CGFloat = 100,
        regularWorkspaceMinHeight: CGFloat = 500,
        wideWorkspaceMinWidth: CGFloat = 900,
        wideWorkspaceMinHeight: CGFloat = 600,
        foldPreviewMinWidth: CGFloat = 220,
        foldTimelineMinWidth: CGFloat = 220,
        foldPreviewMinHeight: CGFloat = 180,
        foldTimelineMinHeight: CGFloat = 180,
        compactTimelineMaxHeight: CGFloat = 200,
        compactTimelineMaxWidth: CGFloat = 260,
        occlusionTopBandHeight: CGFloat = 88,
        occlusionControlInset: CGFloat = 44
    ) {
        self.phonePreviewRatio = phonePreviewRatio
        self.largePreviewRatio = largePreviewRatio
        self.minPreviewHeight = minPreviewHeight
        self.minTimelineHeight = minTimelineHeight
        self.regularWorkspaceMinHeight = regularWorkspaceMinHeight
        self.wideWorkspaceMinWidth = wideWorkspaceMinWidth
        self.wideWorkspaceMinHeight = wideWorkspaceMinHeight
        self.foldPreviewMinWidth = foldPreviewMinWidth
        self.foldTimelineMinWidth = foldTimelineMinWidth
        self.foldPreviewMinHeight = foldPreviewMinHeight
        self.foldTimelineMinHeight = foldTimelineMinHeight
        self.compactTimelineMaxHeight = compactTimelineMaxHeight
        self.compactTimelineMaxWidth = compactTimelineMaxWidth
        self.occlusionTopBandHeight = occlusionTopBandHeight
        self.occlusionControlInset = occlusionControlInset
    }
}

// MARK: - Input / output

public struct EditorLayoutInput: Equatable, Sendable {
    public var horizontalSizeClass: EditorSizeClass
    public var verticalSizeClass: EditorSizeClass
    public var containerSize: CGSize
    public var safeAreaInsets: EditorLayoutInsets
    public var keyboardHeight: CGFloat
    /// Space occupied by fixed chrome between preview, tracks, and tool bars.
    public var fixedChromeHeight: CGFloat
    public var reservedRegions: [EditorReservedRegion]
    public var metrics: EditorLayoutMetrics

    public init(
        horizontalSizeClass: EditorSizeClass = .compact,
        verticalSizeClass: EditorSizeClass = .regular,
        containerSize: CGSize = .zero,
        safeAreaInsets: EditorLayoutInsets = .zero,
        keyboardHeight: CGFloat = 0,
        fixedChromeHeight: CGFloat = 120,
        reservedRegions: [EditorReservedRegion] = [],
        metrics: EditorLayoutMetrics = EditorLayoutMetrics()
    ) {
        self.horizontalSizeClass = horizontalSizeClass
        self.verticalSizeClass = verticalSizeClass
        self.containerSize = containerSize
        self.safeAreaInsets = safeAreaInsets
        self.keyboardHeight = keyboardHeight
        self.fixedChromeHeight = fixedChromeHeight
        self.reservedRegions = reservedRegions
        self.metrics = metrics
    }
}

public enum EditorLayoutForm: String, Equatable, Sendable {
    /// Compact or short window: focused phone editing.
    case phone
    /// Regular width with one auxiliary panel.
    case mediumWorkspace
    /// Regular width with material and inspector panels.
    case wideWorkspace
    /// Fold-aware split between preview and timeline.
    case foldedWorkspace
}

public enum EditorFoldAxis: String, Equatable, Sendable {
    case none
    case vertical
    case horizontal
}

public enum EditorTimelineDensity: String, Equatable, Sendable {
    case regular
    case compact
}

public struct EditorLayoutDecision: Equatable, Sendable {
    public let form: EditorLayoutForm
    public let contentSize: CGSize
    public let previewSize: CGSize
    public let timelineSize: CGSize
    public let timelineDensity: EditorTimelineDensity
    public let foldAxis: EditorFoldAxis
    public let activeFoldFrame: CGRect?
    public let activeOcclusionFrames: [CGRect]
    public let showsAuxiliaryPanel: Bool
    public let showsInspector: Bool
    /// Preferred inline inspector width; zero when the form has no side panel.
    public let auxiliaryPanelWidth: CGFloat
    /// Extra top inset for custom controls when an active occlusion intersects
    /// the top band. Zero when no avoidance is needed.
    public let topControlInset: CGFloat

    public init(
        form: EditorLayoutForm,
        contentSize: CGSize,
        previewSize: CGSize,
        timelineSize: CGSize,
        timelineDensity: EditorTimelineDensity,
        foldAxis: EditorFoldAxis,
        activeFoldFrame: CGRect?,
        activeOcclusionFrames: [CGRect],
        showsAuxiliaryPanel: Bool,
        showsInspector: Bool,
        auxiliaryPanelWidth: CGFloat,
        topControlInset: CGFloat
    ) {
        self.form = form
        self.contentSize = contentSize
        self.previewSize = previewSize
        self.timelineSize = timelineSize
        self.timelineDensity = timelineDensity
        self.foldAxis = foldAxis
        self.activeFoldFrame = activeFoldFrame
        self.activeOcclusionFrames = activeOcclusionFrames
        self.showsAuxiliaryPanel = showsAuxiliaryPanel
        self.showsInspector = showsInspector
        self.auxiliaryPanelWidth = auxiliaryPanelWidth
        self.topControlInset = topControlInset
    }
}

// MARK: - Policy

/// Pure layout decision for the adaptive editor workspace.
///
/// The policy never reads device idiom, screen size, or orientation. It works from
/// the container size, size classes, safe area, keyboard height, and reserved
/// regions supplied by the platform adapter.
public enum EditorLayoutPolicy {

    public static func decide(_ input: EditorLayoutInput) -> EditorLayoutDecision {
        let content = contentSize(for: input)
        let contentRect = CGRect(
            x: input.safeAreaInsets.leading,
            y: input.safeAreaInsets.top,
            width: content.width,
            height: content.height
        )

        let activeOcclusions = input.reservedRegions
            .filter { $0.kind == .occlusion && $0.isActive }
            .map(\.frame)
        let topControlInset = occlusionTopInset(
            activeOcclusions,
            contentRect: contentRect,
            metrics: input.metrics
        )

        if let fold = usableFold(
            in: input.reservedRegions,
            contentRect: contentRect,
            metrics: input.metrics
        ) {
            return foldedDecision(
                fold: fold,
                contentRect: contentRect,
                activeOcclusions: activeOcclusions,
                topControlInset: topControlInset,
                metrics: input.metrics
            )
        }

        return stackedDecision(
            input: input,
            contentRect: contentRect,
            activeOcclusions: activeOcclusions,
            topControlInset: topControlInset
        )
    }

    // MARK: - Stacked (no active fold)

    private static func stackedDecision(
        input: EditorLayoutInput,
        contentRect: CGRect,
        activeOcclusions: [CGRect],
        topControlInset: CGFloat
    ) -> EditorLayoutDecision {
        let metrics = input.metrics
        let isRegularWidth = input.horizontalSizeClass == .regular
        let isRegularHeight = input.verticalSizeClass == .regular
        let hasWorkspaceHeight = contentRect.height >= metrics.regularWorkspaceMinHeight

        let form: EditorLayoutForm
        if !isRegularWidth || !isRegularHeight || !hasWorkspaceHeight {
            form = .phone
        } else if contentRect.width >= metrics.wideWorkspaceMinWidth,
                  contentRect.height >= metrics.wideWorkspaceMinHeight {
            form = .wideWorkspace
        } else {
            form = .mediumWorkspace
        }

        let ratio = form == .phone ? metrics.phonePreviewRatio : metrics.largePreviewRatio
        let chromeHeight = max(0, input.fixedChromeHeight)
        let maxPreviewHeight = max(
            metrics.minPreviewHeight,
            contentRect.height - chromeHeight - metrics.minTimelineHeight
        )
        let previewHeight = min(
            max(contentRect.height * ratio, metrics.minPreviewHeight),
            maxPreviewHeight
        )
        let timelineHeight = max(0, contentRect.height - chromeHeight - previewHeight)

        let previewSize = CGSize(width: contentRect.width, height: previewHeight)
        let timelineSize = CGSize(width: contentRect.width, height: timelineHeight)

        let auxiliaryPanelWidth: CGFloat
        switch form {
        case .mediumWorkspace, .wideWorkspace:
            auxiliaryPanelWidth = min(340, max(220, contentRect.width * 0.34))
        case .phone, .foldedWorkspace:
            auxiliaryPanelWidth = 0
        }

        return EditorLayoutDecision(
            form: form,
            contentSize: contentRect.size,
            previewSize: previewSize,
            timelineSize: timelineSize,
            timelineDensity: density(for: timelineSize, metrics: metrics),
            foldAxis: .none,
            activeFoldFrame: nil,
            activeOcclusionFrames: activeOcclusions,
            showsAuxiliaryPanel: form == .mediumWorkspace || form == .wideWorkspace,
            showsInspector: form == .wideWorkspace,
            auxiliaryPanelWidth: auxiliaryPanelWidth,
            topControlInset: topControlInset
        )
    }

    // MARK: - Folded

    private static func foldedDecision(
        fold: EditorReservedRegion,
        contentRect: CGRect,
        activeOcclusions: [CGRect],
        topControlInset: CGFloat,
        metrics: EditorLayoutMetrics
    ) -> EditorLayoutDecision {
        let isVertical = fold.frame.height > fold.frame.width
        let previewSize: CGSize
        let timelineSize: CGSize
        let axis: EditorFoldAxis

        if isVertical {
            axis = .vertical
            let leading = max(0, fold.frame.minX - contentRect.minX)
            let trailing = max(0, contentRect.maxX - fold.frame.maxX)
            previewSize = CGSize(width: leading, height: contentRect.height)
            timelineSize = CGSize(width: trailing, height: contentRect.height)
        } else {
            axis = .horizontal
            let top = max(0, fold.frame.minY - contentRect.minY)
            let bottom = max(0, contentRect.maxY - fold.frame.maxY)
            previewSize = CGSize(width: contentRect.width, height: top)
            timelineSize = CGSize(width: contentRect.width, height: bottom)
        }

        return EditorLayoutDecision(
            form: .foldedWorkspace,
            contentSize: contentRect.size,
            previewSize: previewSize,
            timelineSize: timelineSize,
            timelineDensity: density(for: timelineSize, metrics: metrics),
            foldAxis: axis,
            activeFoldFrame: fold.frame,
            activeOcclusionFrames: activeOcclusions,
            showsAuxiliaryPanel: false,
            showsInspector: false,
            auxiliaryPanelWidth: 0,
            topControlInset: topControlInset
        )
    }

    // MARK: - Helpers

    private static func contentSize(for input: EditorLayoutInput) -> CGSize {
        let width = max(
            0,
            input.containerSize.width
                - input.safeAreaInsets.leading
                - input.safeAreaInsets.trailing
        )
        let height = max(
            0,
            input.containerSize.height
                - input.safeAreaInsets.top
                - input.safeAreaInsets.bottom
                - max(0, input.keyboardHeight)
        )
        return CGSize(width: width, height: height)
    }

    /// Returns the largest active division region that leaves usable space on
    /// both sides. Inactive divisions are ignored for layout.
    private static func usableFold(
        in regions: [EditorReservedRegion],
        contentRect: CGRect,
        metrics: EditorLayoutMetrics
    ) -> EditorReservedRegion? {
        let candidates = regions
            .filter { $0.kind == .division && $0.isActive }
            .sorted { area(of: $0.frame) > area(of: $1.frame) }

        for region in candidates {
            let frame = region.frame
            if frame.height > frame.width {
                let leading = frame.minX - contentRect.minX
                let trailing = contentRect.maxX - frame.maxX
                if leading >= metrics.foldPreviewMinWidth,
                   trailing >= metrics.foldTimelineMinWidth {
                    return region
                }
            } else {
                let top = frame.minY - contentRect.minY
                let bottom = contentRect.maxY - frame.maxY
                if top >= metrics.foldPreviewMinHeight,
                   bottom >= metrics.foldTimelineMinHeight {
                    return region
                }
            }
        }

        return nil
    }

    /// Moves custom top controls down only when an active occlusion intersects
    /// the top band. Preview content may continue under the camera.
    private static func occlusionTopInset(
        _ frames: [CGRect],
        contentRect: CGRect,
        metrics: EditorLayoutMetrics
    ) -> CGFloat {
        guard !frames.isEmpty else { return 0 }
        let bandHeight = min(metrics.occlusionTopBandHeight, contentRect.height)
        let topBand = CGRect(
            x: contentRect.minX,
            y: contentRect.minY,
            width: contentRect.width,
            height: bandHeight
        )
        return frames.contains { $0.intersects(topBand) }
            ? metrics.occlusionControlInset
            : 0
    }

    private static func density(
        for size: CGSize,
        metrics: EditorLayoutMetrics
    ) -> EditorTimelineDensity {
        if size.height < metrics.compactTimelineMaxHeight
            || size.width < metrics.compactTimelineMaxWidth {
            return .compact
        }
        return .regular
    }

    private static func area(of rect: CGRect) -> CGFloat {
        max(0, rect.width) * max(0, rect.height)
    }
}

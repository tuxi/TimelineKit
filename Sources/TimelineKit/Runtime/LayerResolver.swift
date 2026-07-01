import Foundation
import CoreMedia

// MARK: - Resolved types

/// One visual layer resolved from the timeline at a specific composition time.
public struct ResolvedLayer: Sendable {
    public let content: LayerContent
    /// Compositing order: lower = bottom, higher = top.
    public let zIndex: Int
    /// V7: clip-level animations for this layer (in / out / combo). Empty = no animation.
    public let animations: [ClipAnimation]

    public init(content: LayerContent, zIndex: Int, animations: [ClipAnimation] = []) {
        self.content    = content
        self.zIndex     = zIndex
        self.animations = animations
    }
}

/// Transition info for blending two main-track layers (image OR video on each side).
///
/// V7: supports image→image, image→video, video→image, video→video.
/// Exactly one of (outgoing, outgoingVideo) is non-nil; same for the incoming side.
/// Overlay / text / subtitle layers are NOT carried here — they are composited
/// independently by TimelineRenderer after TransitionComposer.render returns.
public struct TransitionInfo: Sendable {
    /// Outgoing image layer. Non-nil iff outgoing segment is an image.
    public let outgoing: ImageLayerSpec?
    /// Incoming image layer. Non-nil iff incoming segment is an image.
    public let incoming: ImageLayerSpec?
    /// Outgoing video layer. Non-nil iff outgoing segment is a video.
    public let outgoingVideo: VideoLayerSpec?
    /// Incoming video layer. Non-nil iff incoming segment is a video.
    public let incomingVideo: VideoLayerSpec?
    /// Linear progress 0→1 (0 = 100% outgoing, 1 = 100% incoming).
    public let rawProgress: Float
    public let easing: EditorTransition.Easing
    /// Preset identifier forwarded to TransitionComposer. Defaults to "crossFade".
    public let presetID: String

    public init(
        outgoing: ImageLayerSpec? = nil,
        incoming: ImageLayerSpec? = nil,
        outgoingVideo: VideoLayerSpec? = nil,
        incomingVideo: VideoLayerSpec? = nil,
        rawProgress: Float,
        easing: EditorTransition.Easing,
        presetID: String = "crossFade"
    ) {
        self.outgoing      = outgoing
        self.incoming      = incoming
        self.outgoingVideo = outgoingVideo
        self.incomingVideo = incomingVideo
        self.rawProgress   = rawProgress
        self.easing        = easing
        self.presetID      = presetID
    }

    /// True when at least one side has a valid layer spec.
    public var hasValidContent: Bool {
        outgoing != nil || incoming != nil || outgoingVideo != nil || incomingVideo != nil
    }
}

/// Fully resolved render descriptor for one composition-time frame.
public struct ResolvedFrame: Sendable {
    /// Body layers sorted ascending by zIndex. Render bottom-to-top.
    /// Empty during a pure transition (see `transition`).
    public let layers: [ResolvedLayer]
    /// Active dissolve transition, or nil if in a body zone.
    public let transition: TransitionInfo?

    public static let empty = ResolvedFrame(layers: [], transition: nil)

    public init(layers: [ResolvedLayer], transition: TransitionInfo?) {
        self.layers     = layers
        self.transition = transition
    }
}

// MARK: - LayerResolver

/// Pure-function timeline resolver.
///
/// Converts an `EditorTimeline` snapshot + composition time → `ResolvedFrame`.
/// Mirrors `CompositionBuilder.buildVideoTrackUnified`'s `insertionTimes` algorithm
/// so composition time maps identically between the AVPlayer path and the new
/// Timeline Runtime path.
///
/// Thread-safe: all inputs are Sendable value types; no I/O.
public enum LayerResolver {

    // MARK: - Public API

    public static func videoSpecs(
        timeline: EditorTimeline,
        canvasSize: CGSize
    ) -> [VideoLayerSpec] {
        let mainSegs = (timeline.mainTrack?.segments ?? [])
            .sorted { $0.targetRange.start < $1.targetRange.start }

        let timing = timelineTiming(for: mainSegs, transitions: timeline.transitions)
        var specs: [VideoLayerSpec] = []

        for (i, seg) in mainSegs.enumerated() {
            guard case .video(let vc) = seg.content,
                  let videoURL = timeline.materials[seg.materialID]?.bestURL
            else { continue }

            specs.append(VideoLayerSpec(
                assetURL:        videoURL,
                renderSize:      canvasSize,
                contentMode:     vc.fit,
                sourceStartTime: seg.sourceRange?.start ?? 0,
                timeRange:       CMTimeRange(
                    start:    CMTime(seconds: timing.insertionTimes[i], preferredTimescale: 600),
                    duration: CMTime(seconds: seg.targetRange.duration, preferredTimescale: 600)
                ),
                transform:       seg.transform,
                adjustment:      seg.adjustment,
                zPosition:       0,
                baseOpacity:     Float(seg.transform.opacity)
            ))
        }

        for track in timeline.tracks(ofKind: .overlay) where !track.isHidden {
            for seg in track.segments {
                guard case .video(let vc) = seg.content,
                      let videoURL = timeline.materials[seg.materialID]?.bestURL
                else { continue }

                let start = compStartFor(seg, sceneTiming: timing.sceneTiming)
                specs.append(VideoLayerSpec(
                    assetURL:        videoURL,
                    renderSize:      canvasSize,
                    contentMode:     vc.fit,
                    sourceStartTime: seg.sourceRange?.start ?? 0,
                    timeRange:       CMTimeRange(
                        start:    CMTime(seconds: start, preferredTimescale: 600),
                        duration: CMTime(seconds: seg.targetRange.duration, preferredTimescale: 600)
                    ),
                    transform:       seg.transform,
                    adjustment:      seg.adjustment,
                    zPosition:       -1,
                    baseOpacity:     Float(seg.transform.opacity)
                ))
            }
        }

        return specs
    }

    public static func resolve(
        timeline: EditorTimeline,
        at compositionTime: Double,
        canvasSize: CGSize
    ) -> ResolvedFrame {
        let mainSegs = (timeline.mainTrack?.segments ?? [])
            .sorted { $0.targetRange.start < $1.targetRange.start }

        // ── 1. Compute insertionTimes (same algorithm as CompositionBuilder) ──
        let timing = timelineTiming(for: mainSegs, transitions: timeline.transitions)
        let outgoingMap = timing.outgoingMap
        let incomingMap = timing.incomingMap
        let insertionTimes = timing.insertionTimes

        // ── 2. Scene-timing map for overlay segment remapping ─────────────────
        func compStartFor(_ seg: EditorSegment) -> Double {
            Self.compStartFor(seg, sceneTiming: timing.sceneTiming)
        }

        // ── 3. Build ImageLayerSpec + VideoLayerSpec for main-track segments ──
        var imageLayerMap: [UUID: ImageLayerSpec] = [:]
        var videoLayerMap: [UUID: VideoLayerSpec] = [:]

        for (i, seg) in mainSegs.enumerated() {
            switch seg.content {
            case .image(let imgContent):
                guard let imgURL = timeline.materials[seg.materialID]?.bestURL
                else { continue }
                let kf = resolveKeyframes(imgContent, duration: seg.targetRange.duration)
                imageLayerMap[seg.id] = ImageLayerSpec(
                    imageURL:    imgURL,
                    renderSize:  canvasSize,
                    contentMode: imgContent.fit,
                    timeRange:   CMTimeRange(
                        start:    CMTime(seconds: insertionTimes[i], preferredTimescale: 600),
                        duration: CMTime(seconds: seg.targetRange.duration, preferredTimescale: 600)
                    ),
                    keyframes:   kf,
                    zPosition:   0,
                    baseOpacity: Float(seg.transform.opacity)
                )

            case .video(let vc):
                guard let videoURL = timeline.materials[seg.materialID]?.bestURL
                else { continue }
                videoLayerMap[seg.id] = VideoLayerSpec(
                    assetURL:        videoURL,
                    renderSize:      canvasSize,
                    contentMode:     vc.fit,
                    sourceStartTime: seg.sourceRange?.start ?? 0,
                    timeRange:       CMTimeRange(
                        start:    CMTime(seconds: insertionTimes[i], preferredTimescale: 600),
                        duration: CMTime(seconds: seg.targetRange.duration, preferredTimescale: 600)
                    ),
                    transform:       seg.transform,
                    adjustment:      seg.adjustment,
                    zPosition:       0,
                    baseOpacity:     Float(seg.transform.opacity)
                )

            default:
                break
            }
        }

        // ── 4. Build overlay image specs ──────────────────────────────────────
        let overlaySpecs: [LayerContent] = timeline.tracks(ofKind: .overlay)
            .filter { !$0.isHidden }
            .flatMap { $0.segments }
            .compactMap { seg -> LayerContent? in
                switch seg.content {
                case .image(let imgContent):
                    guard let imgURL = timeline.materials[seg.materialID]?.bestURL
                    else { return nil }
                    let kf = resolveKeyframes(imgContent, duration: seg.targetRange.duration)
                    return .image(ImageLayerSpec(
                        imageURL:    imgURL,
                        renderSize:  canvasSize,
                        contentMode: imgContent.fit,
                        timeRange:   CMTimeRange(
                            start:    CMTime(seconds: compStartFor(seg), preferredTimescale: 600),
                            duration: CMTime(seconds: seg.targetRange.duration, preferredTimescale: 600)
                        ),
                        keyframes:   kf,
                        zPosition:   -1,
                        baseOpacity: Float(seg.transform.opacity)
                    ))

                case .video(let vc):
                    guard let videoURL = timeline.materials[seg.materialID]?.bestURL
                    else { return nil }
                    return .video(VideoLayerSpec(
                        assetURL:        videoURL,
                        renderSize:      canvasSize,
                        contentMode:     vc.fit,
                        sourceStartTime: seg.sourceRange?.start ?? 0,
                        timeRange:       CMTimeRange(
                            start:    CMTime(seconds: compStartFor(seg), preferredTimescale: 600),
                            duration: CMTime(seconds: seg.targetRange.duration, preferredTimescale: 600)
                        ),
                        transform:       seg.transform,
                        adjustment:      seg.adjustment,
                        zPosition:       -1,
                        baseOpacity:     Float(seg.transform.opacity)
                    ))

                default:
                    return nil
                }
            }

        let textSpecs: [LayerContent] = timeline.tracks
            .filter { !$0.isHidden && ($0.kind == .text || $0.kind == .subtitle) }
            .flatMap { track -> [LayerContent] in
                track.segments.compactMap { seg -> LayerContent? in
                    let containsText: Bool
                    switch seg.content {
                    case .text, .subtitle:
                        containsText = true
                    default:
                        containsText = false
                    }
                    guard containsText else { return nil }

                    return .text(TextLayerSpec(
                        segmentID: seg.id,
                        timeRange: CMTimeRange(
                            start: CMTime(seconds: compStartFor(seg), preferredTimescale: 600),
                            duration: CMTime(seconds: seg.targetRange.duration, preferredTimescale: 600)
                        ),
                        zPosition: Int32(seg.userZOrder ?? track.zPosition),
                        baseOpacity: Float(seg.transform.opacity)
                    ))
                }
            }

        // ── 5. Find active layers / transition at compositionTime ──────────────
        var activeLayers: [ResolvedLayer] = []
        var resolvedTransition: TransitionInfo? = nil

        for (i, seg) in mainSegs.enumerated() {
            let segStart = insertionTimes[i]
            let segEnd   = segStart + seg.targetRange.duration

            guard compositionTime >= segStart && compositionTime < segEnd else { continue }

            // ── Outgoing half of transition zone ─────────────────────────────
            // Covers [boundary - halfDur, boundary) — last half of the outgoing
            // segment.  compositionTime < segEnd (= boundary) is guaranteed by
            // the outer guard, so we only need to check the lower bound.
            if let trans = outgoingMap[seg.id], i + 1 < mainSegs.count {
                let nextSeg    = mainSegs[i + 1]
                let boundary   = insertionTimes[i + 1]   // = segEnd with V7 cursor
                let clampedDur = min(trans.duration,
                                     min(seg.targetRange.duration,
                                         nextSeg.targetRange.duration) * 0.5)
                let transStart = boundary - clampedDur / 2

                if compositionTime >= transStart {
                    let elapsed     = compositionTime - transStart
                    let rawProgress = Float(elapsed / clampedDur).clamped(0...1)
                    let info = TransitionInfo(
                        outgoing:      imageLayerMap[seg.id],
                        incoming:      imageLayerMap[nextSeg.id],
                        outgoingVideo: videoLayerMap[seg.id],
                        incomingVideo: videoLayerMap[nextSeg.id],
                        rawProgress:   rawProgress,
                        easing:        trans.easing,
                        // V7: presetID takes priority (new drafts + V7 imports).
                        // Old drafts without presetID resolve through the semantic layer.
                        presetID:      trans.presetID
                                    ?? TransitionSemantic.from(legacyType: trans.type).resolvedPresetID
                    )
                    if info.hasValidContent { resolvedTransition = info }
                    continue
                }
            }

            // ── Incoming half of transition zone ─────────────────────────────
            // Covers [boundary, boundary + halfDur) — first half of the incoming
            // segment.  compositionTime >= segStart (= boundary) is guaranteed.
            if let trans = incomingMap[seg.id], i > 0 {
                let prevSeg    = mainSegs[i - 1]
                let boundary   = insertionTimes[i]       // = segStart with V7 cursor
                let clampedDur = min(trans.duration,
                                     min(prevSeg.targetRange.duration,
                                         seg.targetRange.duration) * 0.5)
                let transEnd   = boundary + clampedDur / 2

                if compositionTime < transEnd {
                    let transStart  = boundary - clampedDur / 2
                    let elapsed     = compositionTime - transStart
                    let rawProgress = Float(elapsed / clampedDur).clamped(0...1)
                    let info = TransitionInfo(
                        outgoing:      imageLayerMap[prevSeg.id],
                        incoming:      imageLayerMap[seg.id],
                        outgoingVideo: videoLayerMap[prevSeg.id],
                        incomingVideo: videoLayerMap[seg.id],
                        rawProgress:   rawProgress,
                        easing:        trans.easing,
                        presetID:      trans.presetID
                                    ?? TransitionSemantic.from(legacyType: trans.type).resolvedPresetID
                    )
                    if info.hasValidContent { resolvedTransition = info }
                    continue
                }
            }

            // Body zone — add as an active layer.
            if let spec = imageLayerMap[seg.id] {
                activeLayers.append(ResolvedLayer(content: .image(spec), zIndex: 0, animations: seg.animations))
            } else if let spec = videoLayerMap[seg.id] {
                activeLayers.append(ResolvedLayer(content: .video(spec), zIndex: 0, animations: seg.animations))
            }
        }

        // Add any active overlay/text/subtitle layers.
        for overlay in overlaySpecs + textSpecs {
            let timeRange: CMTimeRange
            let zIdx: Int
            switch overlay {
            case .image(let spec):
                timeRange = spec.timeRange
                zIdx = Int(spec.zPosition)
            case .video(let spec):
                timeRange = spec.timeRange
                zIdx = Int(spec.zPosition)
            case .text(let spec):
                timeRange = spec.timeRange
                zIdx = Int(spec.zPosition)
            }
            let os = timeRange.start.seconds
            let oe = os + timeRange.duration.seconds
            if compositionTime >= os && compositionTime < oe {
                activeLayers.append(ResolvedLayer(content: overlay, zIndex: zIdx))
            }
        }

        // Sort ascending by zIndex so bottom layers are rendered first.
        activeLayers.sort { $0.zIndex < $1.zIndex }

//#if DEBUG
//        let segCount = mainSegs.count
//        let times = insertionTimes.map { String(format: "%.2f", $0) }.joined(separator: ",")
//        var layerInfo: [String] = []
//        for l in activeLayers {
//            switch l.content {
//            case .image(let s): layerInfo.append("img:\(s.imageURL.lastPathComponent)@\(String(format: "%.2f", s.timeRange.start.seconds))-\(String(format: "%.2f", s.timeRange.end.seconds))")
//            case .video(let s): layerInfo.append("vid:\(s.assetURL.lastPathComponent)@\(String(format: "%.2f", s.timeRange.start.seconds))-\(String(format: "%.2f", s.timeRange.end.seconds))")
//            case .text(let s): layerInfo.append("txt:\(s.segmentID)@\(String(format: "%.2f", s.timeRange.start.seconds))-\(String(format: "%.2f", s.timeRange.end.seconds))")
//            }
//        }
//        print("[Resolver] t=\(String(format: "%.3f", compositionTime)) mainSegs=\(segCount) insertions=[\(times)] layers=\(layerInfo)")
//#endif

        return ResolvedFrame(layers: activeLayers, transition: resolvedTransition)
    }

    // MARK: - Private helpers

    private static func timelineTiming(
        for mainSegs: [EditorSegment],
        transitions: [EditorTransition]
    ) -> (
        insertionTimes: [Double],
        outgoingMap: [UUID: EditorTransition],
        incomingMap: [UUID: EditorTransition],
        sceneTiming: [String: (compStart: Double, timelineStart: Double)]
    ) {
        let mainIDs = Set(mainSegs.map(\.id))
        let relevantTransitions = transitions.filter {
            mainIDs.contains($0.leadingSegmentID) && mainIDs.contains($0.trailingSegmentID)
        }
        let outgoingMap = Dictionary(uniqueKeysWithValues:
            relevantTransitions.map { ($0.leadingSegmentID, $0) })
        let incomingMap = Dictionary(uniqueKeysWithValues:
            relevantTransitions.map { ($0.trailingSegmentID, $0) })

        // V7: transitions are render-only visual blends — they do NOT compress the
        // composition timeline.  insertionTime[i] = sum of all preceding segment
        // durations, so composition time == visual timeline time (1 : 1 mapping).
        var insertionTimes = [Double](repeating: 0, count: mainSegs.count)
        var cursor = 0.0
        for (i, seg) in mainSegs.enumerated() {
            insertionTimes[i] = cursor
            cursor += seg.targetRange.duration
        }

        var sceneTiming: [String: (compStart: Double, timelineStart: Double)] = [:]
        for (i, seg) in mainSegs.enumerated() {
            if let sceneID = seg.sourceSceneID {
                sceneTiming[sceneID] = (insertionTimes[i], seg.targetRange.start)
            }
        }

        return (insertionTimes, outgoingMap, incomingMap, sceneTiming)
    }

    private static func compStartFor(
        _ seg: EditorSegment,
        sceneTiming: [String: (compStart: Double, timelineStart: Double)]
    ) -> Double {
        if let sceneID = seg.sourceSceneID, let t = sceneTiming[sceneID] {
            return t.compStart + (seg.targetRange.start - t.timelineStart)
        }
        return seg.targetRange.start
    }

    private static func resolveKeyframes(
        _ imgContent: SegmentContent.ImageContent,
        duration: Double
    ) -> KeyframeSet? {
        if let kf = imgContent.keyframes { return kf }
        let expanded = AnimationMacro.expand(
            motionPreset: imgContent.motionPreset,
            depthEffect:  imgContent.depthEffect,
            duration:     duration
        )
        return expanded.isEmpty ? nil : expanded
    }
}

// MARK: - Float clamping helper

private extension Float {
    func clamped(_ range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

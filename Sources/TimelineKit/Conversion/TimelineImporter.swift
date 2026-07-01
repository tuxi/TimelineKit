import Foundation
import AVFoundation
import ImageIO

/// Converts a server-format `ServerTimelineSchema` (or raw JSON Data) into an `EditorTimeline`.
///
/// Key transformations:
/// - scene-relative `start_offset` / `end_offset` on text layers → absolute `TimeRange`
/// - z_index routing → track assignment (overlay / video / text)
/// - `transition` detached from scene → standalone `EditorTransition`
/// - subtitle items (already absolute) → subtitle track segments
/// - audio (bgm / voice) → dedicated audio track segments
public enum TimelineImporter {
    public enum MediaImportError: Error {
        case noSupportedMedia
    }

    /// Upper bound for the voice-fit speed-up. Mirrors the clamp applied in
    /// `CompositionBuilder.buildAudio` (`min(max(seg.speed, 0.3), 3.0)`) so the imported
    /// draft reflects what actually renders; beyond this the take's tail is trimmed.
    private static let maxVoiceSpeed: Double = 3.0

    // MARK: - Public API

    public static func importing(from json: Data, taskID: Int? = nil) throws -> EditorTimeline {
        let decoder = JSONDecoder()
        let schema = try decoder.decode(ServerTimelineSchema.self, from: json)
        return importing(from: schema, taskID: taskID)
    }

    /// Async import that probes the real (clock-time) duration of each per-scene
    /// voice-over from its audio file before building, so an over-long take is sped up
    /// to fit its shot instead of overflowing into the next scene's voice slot.
    ///
    /// Prefer this on the editor-open path. Voices whose duration can't be loaded fall
    /// back to the synchronous behaviour (fill the remaining shot window at speed 1.0).
    public static func importingResolvingVoices(from json: Data, taskID: Int? = nil) async throws -> EditorTimeline {
        let schema = try JSONDecoder().decode(ServerTimelineSchema.self, from: json)
        let voiceDurations = await resolveSceneVoiceDurations(in: schema)
        return importing(from: schema, taskID: taskID, voiceDurations: voiceDurations)
    }

    /// Loads the real duration (seconds) of each scene's voice-over audio, keyed by
    /// `SScene.id`. Only scenes whose `voice.duration` is missing/invalid are probed —
    /// a server-provided duration is trusted and skipped. Local file URLs make this a
    /// cheap metadata read; remote URLs trigger a network-backed load.
    public static func resolveSceneVoiceDurations(in schema: ServerTimelineSchema) async -> [String: Double] {
        await withTaskGroup(of: (String, Double)?.self) { group in
            for scene in schema.scenes {
                guard let voice = scene.voice, !voice.url.isEmpty else { continue }
                // Trust an explicit server duration — only probe when it's absent.
                if let d = voice.duration, d > 0 { continue }
                guard let url = URL(string: voice.url) else { continue }
                let sceneID = scene.id
                group.addTask {
                    let asset = AVURLAsset(url: url)
                    guard let seconds = try? await asset.load(.duration).seconds,
                          seconds.isFinite, seconds > 0 else { return nil }
                    return (sceneID, seconds)
                }
            }
            var result: [String: Double] = [:]
            for await pair in group {
                if let (id, seconds) = pair { result[id] = seconds }
            }
            return result
        }
    }

    public static func importingMedia(
        from urls: [URL],
        canvas: EditorCanvas = EditorCanvas(width: 720, height: 1080, fps: 30),
        imageDuration: Double = 3,
        productName: String? = "本地剪辑"
    ) async throws -> EditorTimeline {
        var pool = MaterialsPool()
        var videoTrack = EditorTrack(kind: .video, label: "视频", zPosition: 0, isMainTrack: true)
        var cursor: Double = 0

        for url in urls {
            guard let imported = try await importMediaAsset(from: url, imageDuration: imageDuration) else {
                continue
            }

            pool.add(imported.asset)
            videoTrack.segments.append(.init(
                materialID: imported.asset.id,
                sourceRange: imported.sourceRange,
                targetRange: TimeRange(start: cursor, duration: imported.duration),
                content: imported.content
            ))
            cursor += imported.duration
        }

        guard !videoTrack.segments.isEmpty else {
            throw MediaImportError.noSupportedMedia
        }

        var timeline = EditorTimeline(
            canvas: canvas,
            tracks: [videoTrack],
            materials: pool,
            metadata: EditorMetadata(productName: productName)
        )
        timeline.normalizeMainTrack()
        return timeline
    }

    public static func importing(
        from schema: ServerTimelineSchema,
        taskID: Int? = nil,
        voiceDurations: [String: Double] = [:]
    ) -> EditorTimeline {
        var pool = MaterialsPool()

        // Fixed track IDs so callers can reference by kind
        // videoTrack is always the main track for server-imported timelines.
        var overlayTrack  = EditorTrack(kind: .overlay,   label: "背景",  zPosition: -1)
        var videoTrack    = EditorTrack(kind: .video,     label: "视频",  zPosition: 0,  isMainTrack: true)
        var textTrack     = EditorTrack(kind: .text,      label: "文字",  zPosition: 10)
        var subtitleTrack = EditorTrack(kind: .subtitle,  label: "字幕",  zPosition: 5)
        var voiceTrack    = EditorTrack(kind: .audio,     label: "配音",  zPosition: 0)
        var bgmTrack      = EditorTrack(kind: .audio,     label: "BGM",   zPosition: 0)
        var voiceTrack1    = EditorTrack(kind: .audio,     label: "配音1",  zPosition: 0)

        var transitions: [EditorTransition] = []

        // Track the main-content segment of the previous scene for transition linking
        var prevMainSegmentID: UUID? = nil

        let sortedScenes = schema.scenes.sorted { $0.shotIndex < $1.shotIndex }

        for scene in sortedScenes {
            let sceneDuration: Double = scene.duration
            let sceneRange = TimeRange(start: scene.start, duration: sceneDuration)
            var currentMainSegmentID: UUID? = nil
            
            // Voice track (per-scene voice-over)
            //
            // The voice starts at `sceneRange.start + startOffset` and must stay inside
            // the shot so consecutive scenes' voices don't overlap on the track.
            //
            // Real duration resolution order:
            //   1. server `voice.duration` (trusted when > 0)
            //   2. probed value from `voiceDurations[scene.id]` (loaded from the file)
            //   3. unknown → fall back to filling the remaining shot window
            //
            // Fit rule: an over-long take is sped up (speed = real / window) so it ends
            // exactly at the shot boundary; a take that fits keeps speed 1.0 and plays
            // naturally (trailing silence in the shot is fine).
           
            if let voice = scene.voice,
               !voice.url.isEmpty,
               let url = URL(string: voice.url) {
                let startOffset = voice.startOffset ?? 0
                let window = max(sceneDuration - startOffset, 0)

                let realDuration: Double? = {
                    if let d = voice.duration, d > 0 { return d }
                    if let d = voiceDurations[scene.id], d > 0 { return d }
                    return nil
                }()

                var asset = EditorAsset(id: UUID(), type: .voiceOver, remoteURL: url)
                asset.nativeDuration = realDuration
                pool.add(asset)

                let targetDuration: Double
                let speed: Double
                if let real = realDuration, window > 0, real > window {
                    // Over-long take → compress into the shot. Cap at the composition's
                    // max playback rate (CompositionBuilder clamps speed to 0.3...3.0);
                    // past that the tail is trimmed rather than sped up further.
                    targetDuration = window
                    speed = min(real / window, maxVoiceSpeed)
                } else {
                    // Fits (or unknown) → natural playback, bounded by the shot window.
                    targetDuration = realDuration.map { min($0, window) } ?? window
                    speed = 1.0
                }

                if targetDuration > 0 {
                    let segment = EditorSegment(
                        materialID: asset.id,
                        targetRange: TimeRange(start: sceneRange.start + startOffset, duration: targetDuration),
                        speed: speed,
                        content: .audio(.init(volume: voice.volume))
                    )
                    voiceTrack1.segments.append(segment)
                }
            }

            for layer in scene.layers {
                let zIndex = layer.zIndex ?? 0

                switch layer.type {

                case "image_motion":
                    guard let src = layer.src else { continue }
                    var asset = EditorAsset(
                        id: UUID(),
                        type: .image,
                        remoteURL: URL(string: src)
                    )
                    asset.nativeDuration = sceneDuration
                    pool.add(asset)

                    let preset = layer.imageAnimation?.type.flatMap { ImageMotionPreset(rawValue: $0) }
                    // V6: Parse detailed animation params into KeyframeSet when present.
                    // motionPreset is kept as fallback for AnimationMacro expansion.
                    let keyframes = Self.buildImageMotionKeyframes(
                        from: layer.imageAnimation, duration: sceneDuration,
                        canvasWidth: Double(schema.canvas.width)
                    )
                    let content = SegmentContent.image(.init(
                        fit: ContentFit(rawValue: layer.fit ?? "cover") ?? .cover,
                        motionPreset: preset,
                        blurRadius: layer.blur,
                        keyframes: keyframes
                    ))
                    let segment = EditorSegment(
                        materialID: asset.id,
                        targetRange: sceneRange,
                        content: content,
                        sourceSceneID: scene.id,
                        sourceZIndex: zIndex,
                        animations: importAnimations(from: layer.clipAnimations,
                                                     segmentDuration: sceneDuration)
                    )
                    if zIndex < 0 {
                        overlayTrack.segments.append(segment)
                    } else {
                        videoTrack.segments.append(segment)
                        currentMainSegmentID = segment.id
                    }

                case "image_3d":
                    guard let src = layer.src else { continue }
                    var asset = EditorAsset(id: UUID(), type: .image, remoteURL: URL(string: src))
                    asset.nativeDuration = sceneDuration
                    pool.add(asset)

                    let depth: SegmentContent.DepthEffect? = layer.camera.map {
                        .init(moveDirection: $0.move, intensity: $0.intensity, duration: $0.duration)
                    }
                    // V6: Build KeyframeSet from camera + depth-model params.
                    let keyframes = Self.buildImage3DKeyframes(
                        camera: layer.camera, depthModel: layer.depthModel,
                        duration: sceneDuration
                    )
                    let content = SegmentContent.image(.init(
                        fit: ContentFit(rawValue: layer.fit ?? "cover") ?? .cover,
                        depthEffect: depth,
                        keyframes: keyframes
                    ))
                    let segment = EditorSegment(
                        materialID: asset.id,
                        targetRange: sceneRange,
                        content: content,
                        sourceSceneID: scene.id,
                        sourceZIndex: zIndex,
                        animations: importAnimations(from: layer.clipAnimations,
                                                     segmentDuration: sceneDuration)
                    )
                    if zIndex < 0 {
                        overlayTrack.segments.append(segment)
                    } else {
                        videoTrack.segments.append(segment)
                        currentMainSegmentID = segment.id
                    }

                case "ai_video":
                    guard let videoURL = layer.videoURL, let url = URL(string: videoURL) else { continue }
                    let asset = EditorAsset(
                        id: UUID(),
                        type: .generatedVideo(provider: layer.provider ?? "unknown", model: layer.model ?? ""),
                        remoteURL: url,
                        nativeDuration: sceneDuration,
                        naturalWidth: schema.canvas.width,
                        naturalHeight: schema.canvas.height
                    )
                    pool.add(asset)

                    let segment = EditorSegment(
                        materialID: asset.id,
                        sourceRange: TimeRange(start: 0, duration: sceneDuration),
                        targetRange: sceneRange,
                        content: .video(.init(fit: ContentFit(rawValue: layer.fit ?? "cover") ?? .cover)),
                        sourceSceneID: scene.id,
                        sourceZIndex: zIndex,
                        animations: importAnimations(from: layer.clipAnimations,
                                                     segmentDuration: sceneDuration)
                    )
                    videoTrack.segments.append(segment)
                    currentMainSegmentID = segment.id

                case "text":
                    guard let text = layer.content else { continue }

                    // ← Key conversion: scene-relative offsets → absolute time
                    let absStart = scene.start + (layer.startOffset ?? 0)
                    let absEnd   = scene.start + (layer.endOffset ?? scene.duration)

                    let style = makeTextStyle(from: layer.style)
                    let position = NormalizedPoint(
                        x: layer.position?.x ?? 0.5,
                        y: layer.position?.y ?? 0.15
                    )
                    let anchor = AnchorPoint(rawValue: layer.position?.anchor ?? "center") ?? .center
                    let enter = layer.textAnimation.flatMap { makeTextAnimation(type: $0.enter, duration: $0.enterDuration) }
                    let exit  = layer.textAnimation.flatMap { makeTextAnimation(type: $0.exit,  duration: $0.exitDuration) }

                    // Text segments use a synthetic placeholder asset (no external file)
                    let asset = EditorAsset(id: UUID(), type: .placeholder)
                    pool.add(asset)

                    let segment = EditorSegment(
                        materialID: asset.id,
                        targetRange: TimeRange(start: absStart, end: absEnd),
                        content: .text(.init(
                            text: text,
                            style: style,
                            position: position,
                            anchor: anchor,
                            enterAnimation: enter,
                            exitAnimation: exit
                        )),
                        sourceSceneID: scene.id,
                        sourceZIndex: zIndex
                    )
                    textTrack.segments.append(segment)

                default:
                    break
                }
            }

            // Link transition to the adjacent main-content segments.
            //
            // V7 three-layer resolution:
            //   1. Draft with preset_id  → use directly (editor round-trip, lossless)
            //   2. Server type only      → TransitionSemantic → presetID (server import / old draft)
            //
            // Unknown server types fall back to crossFade and are logged by TransitionSemantic.
            if let t = scene.transition,
               let prevID = prevMainSegmentID,
               let currID = currentMainSegmentID {

                let presetID: String
                if let pid = t.presetID, !pid.isEmpty {
                    // Path 1 — V7 draft carries the client presetID explicitly.
                    presetID = pid
                } else {
                    // Path 2 — server import or pre-V7 draft: map through semantic layer.
                    let semantic = TransitionSemantic.from(serverType: t.type,
                                                           direction: t.direction,
                                                           style: t.style)
                    presetID = semantic.resolvedPresetID
                }

                let transition = EditorTransition(
                    id:                UUID(),
                    type:              .crossFade,   // canonical V7 type; rendering driven by presetID
                    duration:          t.duration,
                    easing:            EditorTransition.Easing(rawValue: t.easing) ?? .easeInOut,
                    leadingSegmentID:  prevID,
                    trailingSegmentID: currID,
                    presetID:          presetID,
                    intensity:         t.intensity.map { Float($0) }
                )
                transitions.append(transition)
                updateTransitionRefs(
                    in: &videoTrack, prevID: prevID, currID: currID, transitionID: transition.id
                )
            }

            if currentMainSegmentID != nil { prevMainSegmentID = currentMainSegmentID }
        }

        // Subtitle track
        if let subtitle = schema.subtitle {
            for item in subtitle.items {
                let asset = EditorAsset(id: UUID(), type: .placeholder)
                pool.add(asset)

                let segs = item.segments?.map { s -> SegmentContent.SubtitleSegmentItem in
                    SegmentContent.SubtitleSegmentItem(
                        text: s.text,
                        isHighlighted: s.highlight ?? false,
                        color: s.style?.typography?.color,
                        fontWeight: s.style?.typography?.fontWeight.flatMap { FontWeight(rawValue: $0) }
                    )
                }

                let s = subtitle.style
                let textStyle = TextStyle(
                    fontSize: s?.typography?.fontSize.map(Double.init) ?? 34,
                    fontWeight: s?.typography?.fontWeight.flatMap { FontWeight(rawValue: $0) } ?? .regular,
                    color: s?.typography?.color ?? "#FFFFFF",
                    backgroundColor: s?.background?.color
                )

                let segment = EditorSegment(
                    materialID: asset.id,
                    targetRange: TimeRange(start: item.start, end: item.end),
                    content: .subtitle(.init(text: item.text, segments: segs, style: textStyle,
                                              positionY: s?.positionY, maxCharsPerLine: s?.maxCharsPerLine))
                )
                subtitleTrack.segments.append(segment)
            }
        }

        // Voice track
        if let voice = schema.audio?.voice,
           !voice.url.isEmpty,
           let url = URL(string: voice.url) {
            let asset = EditorAsset(id: UUID(), type: .voiceOver, remoteURL: url)
            pool.add(asset)
            let startOffset = voice.startOffset ?? 0
            let segment = EditorSegment(
                materialID: asset.id,
                targetRange: TimeRange(start: startOffset, duration: schema.duration - startOffset),
                content: .audio(.init(volume: voice.volume))
            )
            voiceTrack.segments.append(segment)
        }

        // BGM track
        if let bgm = schema.audio?.bgm,
           !bgm.url.isEmpty,
           let url = URL(string: bgm.url) {
            let asset = EditorAsset(id: UUID(), type: .audio, remoteURL: url)
            pool.add(asset)
            let segment = EditorSegment(
                materialID: asset.id,
                targetRange: TimeRange(start: 0, duration: schema.duration),
                content: .audio(.init(
                    volume: bgm.volume,
                    fadeOutDuration: bgm.fadeOutDuration ?? 0,
                    isLooping: bgm.loop
                ))
            )
            bgmTrack.segments.append(segment)
        }

        // Only include non-empty tracks
        var tracks: [EditorTrack] = []
        if !overlayTrack.segments.isEmpty  { tracks.append(overlayTrack) }
        if !videoTrack.segments.isEmpty    { tracks.append(videoTrack) }
        if !textTrack.segments.isEmpty     { tracks.append(textTrack) }
        if !subtitleTrack.segments.isEmpty { tracks.append(subtitleTrack) }
        if !voiceTrack.segments.isEmpty    { tracks.append(voiceTrack) }
        if !bgmTrack.segments.isEmpty      { tracks.append(bgmTrack) }
        if !voiceTrack1.segments.isEmpty { tracks.append(voiceTrack1) }

        let canvas = EditorCanvas(width: schema.canvas.width, height: schema.canvas.height, fps: schema.fps)
        let metadata = EditorMetadata(
            sourceTaskID: taskID,
            sourceWorkflow: schema.meta?.workflowName,
            productName: schema.meta?.productName,
            renderType: schema.meta?.renderType
        )

        var timeline = EditorTimeline(
            canvas: canvas,
            tracks: tracks,
            materials: pool,
            transitions: transitions,
            metadata: metadata
        )
        // Enforce the single-main-track invariant.
        timeline.normalizeMainTrack()
        return timeline
    }

    // MARK: - Private Helpers

    /// V6: Parse `SImageAnimation` into a `KeyframeSet` when detailed numeric params
    /// (scaleFrom/scaleTo/translateXFrom/opacityTo) are present. Falls back to nil
    /// when the server only sends `type`, in which case `AnimationMacro` expands the
    /// `motionPreset` at composition time.
    private static func buildImageMotionKeyframes(
        from anim: SImageAnimation?,
        duration: Double,
        canvasWidth: Double = 720
    ) -> KeyframeSet? {
        guard let anim else { return nil }
        var kf = KeyframeSet()
        var hasAny = false
        let animDur = anim.duration ?? duration
        let ease = parseEasing(anim.easing)

        if let from = anim.scaleFrom, let to = anim.scaleTo, abs(from - to) > 1e-6 {
            kf.scale = [
                Keyframe(time: 0, value: from),
                Keyframe(time: animDur, value: to, easing: ease)
            ]
            hasAny = true
        }
        // V6: translate_x_from is in pixels from the server — normalise to 0…1.
        if let txPx = anim.translateXFrom, abs(txPx) > 1e-6, canvasWidth > 0 {
            let tx = txPx / canvasWidth
            kf.position = [
                Keyframe<NormalizedPoint>(time: 0, value: NormalizedPoint(x: 0.5, y: 0.5)),
                Keyframe<NormalizedPoint>(time: animDur, value: NormalizedPoint(x: 0.5 + tx, y: 0.5), easing: ease)
            ]
            hasAny = true
        }
        if let opacityTo = anim.opacityTo, abs(opacityTo - 1.0) > 1e-6 {
            kf.opacity = [
                Keyframe(time: 0, value: 1.0),
                Keyframe(time: animDur, value: opacityTo, easing: ease)
            ]
            hasAny = true
        }

        return hasAny ? kf : nil
    }

    /// V6 P5: Parse `SCamera` + `SDepthModel` into a `KeyframeSet` for "fake-3D camera move".
    ///
    /// Inputs are still single-layer 2D images (no real depth map / mask / mesh),
    /// so true 3D camera moves are impossible. Instead we use:
    ///
    ///   anchor   = (depthModel.centerX, .centerY)  — subject center on canvas
    ///   pos      = anchor for forward/backward (subject stays in place)
    ///            → drifts toward named direction for pan_* / orbit_*
    ///   scale    = grows / shrinks around anchor
    ///
    /// Because `KeyframeEvaluator` builds the transform as
    /// `s·(p − anchor) + pos`, scaling around an off-center anchor naturally
    /// pushes the image edges OUTWARD asymmetrically — pixels far from the
    /// subject move more than pixels near the subject. This single trick is
    /// what makes "forward" feel like a dolly toward the subject instead of a
    /// flat zoom. `motionSafetyMargin` handles the matching overscan so the
    /// off-center scaling never exposes black edges.
    ///
    /// If `depthModel.center*` is absent, the path degrades to canvas-centered
    /// Ken Burns (anchor = (0.5, 0.5)) — visually similar to `image_motion`.
    private static func buildImage3DKeyframes(
        camera: SCamera?,
        depthModel: SDepthModel?,
        duration: Double
    ) -> KeyframeSet? {
        guard var camera else { return nil }
//        camera.move = "orbit_right"
        let animDur = min(camera.duration, duration)
        guard animDur > 0 else { return nil }

        let ease = parseEasing(camera.easing)
        let rawIntensity = max(0, min(camera.intensity, 1.0))

        // V6 P5: bumped caps so high-intensity moves are actually perceptible.
        // - forward push: scale grows from ~1.04 to ~1.36 at intensity=1
        // - lateral pan: subject travels up to ~18% of canvas at intensity=1
        // The 1.04 floor for scale exists to keep a tiny baseline overscan that
        // hides imperfect safe-scale rounding even at minimum intensity.
        let zoomOffset = min(max(rawIntensity * 0.65, 0.10), 0.32)
        let panOffset  = min(max(rawIntensity * 0.30, 0.05), 0.18)

        // Subject center clamped to a sane range so a glitchy depth model
        // (e.g. (0, 0)) cannot put the anchor in the corner.
        let cx = clamp(depthModel?.centerX ?? 0.5, 0.20, 0.80)
        let cy = clamp(depthModel?.centerY ?? 0.5, 0.20, 0.80)
        let centre = NormalizedPoint(x: cx, y: cy)
        let hasDepth = depthModel?.centerX != nil || depthModel?.centerY != nil

        // Anchor is constant for the whole animation — subject doesn't move
        // within the image, only the camera moves around it.
        var kf = KeyframeSet()
        kf.anchor = [Keyframe<NormalizedPoint>(time: 0, value: centre)]

        // Helper — set pos = anchor at start, drifts to (endX, endY) at end.
        // For forward/backward, end == anchor so pos is effectively constant.
        func setPos(endX: Double, endY: Double) {
            kf.position = [
                Keyframe<NormalizedPoint>(time: 0,       value: centre),
                Keyframe<NormalizedPoint>(time: animDur, value: NormalizedPoint(x: endX, y: endY), easing: ease)
            ]
        }

        switch camera.move {
        // ── Dolly forward — camera pushes toward subject ─────────────────
        case "zoom_in", "forward":
            kf.scale = [
                Keyframe(time: 0,       value: 1.04),
                Keyframe(time: animDur, value: 1.04 + zoomOffset, easing: ease)
            ]
            // pos = anchor (constant) → subject locked, world recedes around it.
            setPos(endX: cx, endY: cy)

        // ── Dolly backward — camera pulls away from subject ──────────────
        // End scale stays at 1.04 (NOT 1.0) to keep a sliver of overscan and
        // avoid edge cases where late-frame fitTransform exposes black.
        case "zoom_out", "backward":
            kf.scale = [
                Keyframe(time: 0,       value: 1.04 + zoomOffset),
                Keyframe(time: animDur, value: 1.04, easing: ease)
            ]
            setPos(endX: cx, endY: cy)

        // ── Lateral pan — camera trucks sideways, subject crosses frame ─
        // Scale held at ~1.10 so the off-center anchor produces a small
        // amount of parallax between subject and edges (depth-cue without
        // a real depth map). Subject moves in the named direction.
        case "pan_left", "left":
            setPos(endX: cx - panOffset, endY: cy)
            kf.scale = [
                Keyframe(time: 0,       value: 1.12),
                Keyframe(time: animDur, value: 1.08, easing: ease)
            ]

        case "pan_right", "right":
            setPos(endX: cx + panOffset, endY: cy)
            kf.scale = [
                Keyframe(time: 0,       value: 1.12),
                Keyframe(time: animDur, value: 1.08, easing: ease)
            ]

        case "pan_up", "up":
            setPos(endX: cx, endY: cy - panOffset)
            kf.scale = [
                Keyframe(time: 0,       value: 1.12),
                Keyframe(time: animDur, value: 1.08, easing: ease)
            ]

        case "pan_down", "down":
            setPos(endX: cx, endY: cy + panOffset)
            kf.scale = [
                Keyframe(time: 0,       value: 1.12),
                Keyframe(time: animDur, value: 1.08, easing: ease)
            ]

        // ── Orbit — camera arcs sideways while pushing in slightly ──────
        // Best "fake-3D" effect for single-layer images: subject travels
        // across frame AND grows, mimicking the parallax of arcing around it.
        case "orbit_left":
            setPos(endX: cx - panOffset * 0.7, endY: cy)
            kf.scale = [
                Keyframe(time: 0,       value: 1.08),
                Keyframe(time: animDur, value: 1.08 + zoomOffset * 0.5, easing: ease)
            ]

        case "orbit_right":
            setPos(endX: cx + panOffset * 0.7, endY: cy)
            kf.scale = [
                Keyframe(time: 0,       value: 1.08),
                Keyframe(time: animDur, value: 1.08 + zoomOffset * 0.5, easing: ease)
            ]

        default:
            return nil
        }

        // V6 P5: structured log for verifying camera.move → keyframe mapping
        // against server-side intensity / depth-center values.
        let posKF = kf.position.map { "t=\(String(format: "%.2f", $0.time))→(\(fmt($0.value.x)),\(fmt($0.value.y)))" }.joined(separator: " ")
        let scaleKF = kf.scale.map { "t=\(String(format: "%.2f", $0.time))→\(fmt($0.value))" }.joined(separator: " ")
        print(
            "[image_3d] move=\(camera.move) intensity=\(fmt(camera.intensity)) "
            + "depthCenter=\(hasDepth ? "(\(fmt(depthModel?.centerX ?? 0)),\(fmt(depthModel?.centerY ?? 0)))" : "nil") "
            + "anchor=(\(fmt(cx)),\(fmt(cy))) "
            + "zoomOffset=\(fmt(zoomOffset)) panOffset=\(fmt(panOffset)) "
            + "pos=[\(posKF)] scale=[\(scaleKF)]"
        )

        return kf.isEmpty ? nil : kf
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, v))
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.3f", v)
    }

    private static func parseEasing(_ s: String?) -> Easing {
        switch s {
        case "linear":       return .linear
        case "ease_in":      return .easeIn
        case "ease_out":     return .easeOut
        case "ease_in_out":  return .easeInOut
        default:             return .easeInOut
        }
    }

    private static func makeTextStyle(from s: STextStyle?) -> TextStyle {
        TextStyle(
            fontSize: Double(s?.fontSize ?? 34),
            fontWeight: FontWeight(rawValue: s?.fontWeight ?? "regular") ?? .regular,
            color: s?.color ?? "#FFFFFF",
            backgroundColor: s?.backgroundColor,
            backgroundRadius: Double(s?.backgroundRadius ?? 0),
            paddingH: Double(s?.padding?.last ?? 0),
            paddingV: Double(s?.padding?.first ?? 0)
        )
    }

    private static func makeTextAnimation(type: String?, duration: Double?) -> TextAnimation? {
        guard let type, let duration else { return nil }
        let animType = TextAnimation.AnimationType(rawValue: type) ?? .none
        return TextAnimation(type: animType, duration: duration)
    }

    private struct ImportedMedia {
        var asset: EditorAsset
        var content: SegmentContent
        var duration: Double
        var sourceRange: TimeRange?
    }

    private static func importMediaAsset(from url: URL, imageDuration: Double) async throws -> ImportedMedia? {
        if let image = imageAsset(from: url, duration: imageDuration) {
            return image
        }

        let avAsset = AVURLAsset(url: url)
        let videoTracks = try await avAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            return nil
        }

        let duration = try await avAsset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            return nil
        }

        let naturalSize = try? await videoTrack.load(.naturalSize)
        let materialID = UUID()
        let asset = EditorAsset(
            id: materialID,
            type: .video,
            localURL: url.isFileURL ? url : nil,
            remoteURL: url.isFileURL ? nil : url,
            nativeDuration: duration,
            naturalWidth: naturalSize.map { Int(abs($0.width)) },
            naturalHeight: naturalSize.map { Int(abs($0.height)) }
        )

        return .init(
            asset: asset,
            content: .video(.init()),
            duration: duration,
            sourceRange: TimeRange(start: 0, duration: duration)
        )
    }

    private static func imageAsset(from url: URL, duration: Double) -> ImportedMedia? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        let materialID = UUID()
        let asset = EditorAsset(
            id: materialID,
            type: .image,
            localURL: url.isFileURL ? url : nil,
            remoteURL: url.isFileURL ? nil : url,
            nativeDuration: duration,
            naturalWidth: pixelWidth,
            naturalHeight: pixelHeight
        )

        return .init(
            asset: asset,
            content: .image(.init()),
            duration: duration,
            sourceRange: nil
        )
    }

    /// V7: Convert server-side `[SAnimation]` into `[ClipAnimation]` for an `EditorSegment`.
    ///
    /// Unknown `type` values produce `.unknown` semantic — rendered as a no-op by
    /// `AnimationComposer` (preset lookup fails silently) and logged for debugging.
    private static func importAnimations(
        from sAnims: [SAnimation]?,
        segmentDuration: Double
    ) -> [ClipAnimation] {
        guard let sAnims, !sAnims.isEmpty else { return [] }
        return sAnims.compactMap { sa in
            let timing   = AnimationTiming(rawValue: sa.timing ?? "in") ?? .in
            let semantic = AnimationSemantic.from(
                serverType: sa.type,
                timing:     timing,
                direction:  sa.direction
            )
            if semantic == .unknown {
                print("[TimelineImporter] unknown animation type '\(sa.type)' — using .unknown fallback")
            }
            return ClipAnimation(
                semantic:  semantic,
                timing:    timing,
                duration:  sa.duration ?? 0.5,
                direction: sa.direction.flatMap { AnimationDirection(rawValue: $0) },
                intensity: sa.intensity
            )
        }
    }

    private static func updateTransitionRefs(
        in track: inout EditorTrack,
        prevID: UUID, currID: UUID,
        transitionID: UUID
    ) {
        for i in track.segments.indices {
            if track.segments[i].id == prevID {
                track.segments[i].trailingTransitionID = transitionID
            }
            if track.segments[i].id == currID {
                track.segments[i].leadingTransitionID = transitionID
            }
        }
    }
}

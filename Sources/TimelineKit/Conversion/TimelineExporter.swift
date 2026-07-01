import Foundation

/// Converts an `EditorTimeline` back to a `ServerTimelineSchema` (and optionally JSON Data).
///
/// Key inverse transformations:
/// - Groups segments by `sourceSceneID` to reconstruct `SScene` objects
/// - Converts absolute text segment `TimeRange` → scene-relative `start_offset` / `end_offset`
/// - Recalculates `scene.start` from segment position (editor is the authority after editing)
/// - Rebuilds `transition` from `EditorTransition` objects
/// - New segments without a `sourceSceneID` get synthetic scene IDs
public enum TimelineExporter {

    // MARK: - Public API

    public static func export(_ timeline: EditorTimeline) -> ServerTimelineSchema {
        let scenes      = buildScenes(from: timeline)
        let audioTrack  = buildAudioTrack(from: timeline)
        let subtitle    = buildSubtitleTrack(from: timeline)

        return ServerTimelineSchema(
            version: "1.0",
            duration: timeline.duration,
            fps: timeline.canvas.fps,
            canvas: SCanvas(width: timeline.canvas.width, height: timeline.canvas.height),
            scenes: scenes,
            audio: audioTrack,
            subtitle: subtitle,
            meta: buildMeta(from: timeline)
        )
    }

    public static func exportJSON(_ timeline: EditorTimeline) throws -> Data {
        let schema = export(timeline)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(schema)
    }

    // MARK: - Scenes

    private static func buildScenes(from timeline: EditorTimeline) -> [SScene] {
        // Collect all video/overlay segments that have a sceneID
        let videoSegments = timeline.tracks
            .filter { $0.kind == .video || $0.kind == .overlay }
            .flatMap { $0.segments }

        let textSegments = timeline.tracks
            .filter { $0.kind == .text }
            .flatMap { $0.segments }

        // Group video/overlay by sourceSceneID (or generate one)
        var sceneMap: [String: [EditorSegment]] = [:]
        for seg in videoSegments {
            let key = seg.sourceSceneID ?? "scene_\(seg.id.uuidString.prefix(8))"
            sceneMap[key, default: []].append(seg)
        }

        // Collect text segments by sceneID
        var textByScene: [String: [EditorSegment]] = [:]
        for seg in textSegments {
            guard let sceneID = seg.sourceSceneID else { continue }
            textByScene[sceneID, default: []].append(seg)
        }

        // Sort scenes by earliest segment start time
        let sortedSceneIDs = sceneMap.keys.sorted { a, b in
            let aStart = sceneMap[a]!.map { $0.targetRange.start }.min() ?? 0
            let bStart = sceneMap[b]!.map { $0.targetRange.start }.min() ?? 0
            return aStart < bStart
        }

        var scenes: [SScene] = []

        for (shotIndex, sceneID) in sortedSceneIDs.enumerated() {
            let segs = sceneMap[sceneID]!
            guard let firstSeg = segs.sorted(by: { $0.targetRange.start < $1.targetRange.start }).first else { continue }

            let sceneStart    = firstSeg.targetRange.start
            let sceneDuration = segs.map { $0.targetRange.duration }.max() ?? firstSeg.targetRange.duration

            var layers = segs.compactMap { seg -> SLayer? in
                buildLayer(
                    from: seg,
                    material: timeline.materials[seg.materialID],
                    canvasWidth: timeline.canvas.width
                )
            }

            // Add text layers that belong to this scene
            let textLayers = (textByScene[sceneID] ?? []).compactMap { seg -> SLayer? in
                buildTextLayer(from: seg, sceneStart: sceneStart)
            }
            layers += textLayers

            // Sort layers by zIndex
            layers.sort { ($0.zIndex ?? 0) < ($1.zIndex ?? 0) }

            // Find the transition that references any of these segments as trailing
            let segIDs = Set(segs.map { $0.id })
            let transition = timeline.transitions.first { segIDs.contains($0.trailingSegmentID) }

            let scene = SScene(
                id: sceneID,
                shotIndex: shotIndex + 1,
                start: sceneStart,
                duration: sceneDuration,
                layers: layers,
                transition: transition.map { t in
                    // V7: write preset_id explicitly so reimport bypasses the semantic
                    // layer and restores the exact preset the user selected.
                    // direction + intensity are also persisted for completeness.
                    STransition(
                        type:      t.type.rawValue,
                        duration:  t.duration,
                        easing:    t.easing.rawValue,
                        direction: t.direction?.rawValue,
                        intensity: t.intensity.map(Double.init),
                        presetID:  t.presetID
                    )
                }
            )
            scenes.append(scene)
        }

        return scenes
    }

    private static func buildLayer(
        from seg: EditorSegment,
        material: EditorAsset?,
        canvasWidth: Int
    ) -> SLayer? {
        var layer = SLayer(type: "unknown")
        layer.zIndex = seg.sourceZIndex ?? 0

        switch seg.content {
        case .video(let v):
            layer.type     = "ai_video"
            layer.fit      = v.fit.rawValue
            // Prefer the cached local file so user-replaced videos survive re-import.
            // Fall back to the original remote CDN URL when no local copy exists.
            layer.videoURL = material?.localURL?.absoluteString
                          ?? material?.remoteURL?.absoluteString
            return layer

        case .image(let img):
            // Same local-first preference for images.
            let src = material?.localURL?.absoluteString
                   ?? material?.remoteURL?.absoluteString
            layer.src = src
            layer.fit = img.fit.rawValue
            layer.blur = img.blurRadius
           
            if let depth = img.depthEffect {
                layer.type   = "image_3d"
                layer.camera = buildImage3DCamera(
                    from: img,
                    segment: seg
                ) ?? SCamera(
                    move: depth.moveDirection,
                    intensity: depth.intensity,
                    duration: depth.duration,
                    easing: "ease_out"
                )
            } else {
                layer.type = "image_motion"
                layer.imageAnimation = buildImageAnimation(
                    from: img,
                    segment: seg,
                    canvasWidth: canvasWidth
                )
            }
            return layer

        default:
            return nil
        }
    }

    private static func buildImage3DCamera(
        from image: SegmentContent.ImageContent,
        segment: EditorSegment
    ) -> SCamera? {
        guard let keyframes = image.keyframes, !keyframes.isEmpty else { return nil }
        let scale = keyframes.scale.sorted(by: { $0.time < $1.time })
        let position = keyframes.position.sorted(by: { $0.time < $1.time })
        let easing = dominantEasing(in: keyframes)?.rawValue ?? "ease_out"
        let duration = max(
            scale.last?.time ?? 0,
            position.last?.time ?? 0,
            segment.targetRange.duration
        )

        if let first = scale.first, let last = scale.last, abs(last.value - first.value) > 1e-6 {
            let move = last.value >= first.value ? "forward" : "backward"
            let intensity = max(abs(last.value - first.value) / 0.20, 0.01)
            return SCamera(
                move: move,
                intensity: intensity,
                duration: duration,
                easing: easing
            )
        }

        if let first = position.first,
           let last = position.last {
            let dx = last.value.x - first.value.x
            let dy = last.value.y - first.value.y
            guard abs(dx) > 1e-6 || abs(dy) > 1e-6 else { return nil }

            let move: String
            let delta: Double
            if abs(dx) >= abs(dy) {
                move = dx >= 0 ? "pan_left" : "pan_right"
                delta = abs(dx)
            } else {
                move = dy >= 0 ? "pan_down" : "pan_up"
                delta = abs(dy)
            }

            return SCamera(
                move: move,
                intensity: max(delta / 0.10, 0.01),
                duration: duration,
                easing: easing
            )
        }

        return nil
    }

    private static func buildImageAnimation(
        from image: SegmentContent.ImageContent,
        segment: EditorSegment,
        canvasWidth: Int
    ) -> SImageAnimation? {
        if let keyframes = image.keyframes, !keyframes.isEmpty {
            return buildImageAnimation(
                from: keyframes,
                fallbackType: image.motionPreset?.rawValue ?? image.animationPresetID,
                duration: segment.targetRange.duration,
                canvasWidth: Double(canvasWidth)
            )
        }

        guard let preset = image.motionPreset else { return nil }
        return SImageAnimation(
            type: preset.rawValue,
            duration: segment.targetRange.duration,
            easing: "ease_out"
        )
    }

    private static func buildImageAnimation(
        from keyframes: KeyframeSet,
        fallbackType: String?,
        duration: Double,
        canvasWidth: Double
    ) -> SImageAnimation? {
        var animation = SImageAnimation(
            type: fallbackType ?? "",
            duration: duration,
            easing: dominantEasing(in: keyframes)?.rawValue ?? "ease_out"
        )
        var hasAnyValue = fallbackType != nil

        if let first = keyframes.scale.sorted(by: { $0.time < $1.time }).first,
           let last = keyframes.scale.sorted(by: { $0.time < $1.time }).last {
            animation.scaleFrom = first.value
            animation.scaleTo = last.value
            animation.duration = max(animation.duration ?? duration, last.time)
            hasAnyValue = true
        }

        if let first = keyframes.position.sorted(by: { $0.time < $1.time }).first,
           let last = keyframes.position.sorted(by: { $0.time < $1.time }).last,
           canvasWidth > 0 {
            animation.translateXFrom = (last.value.x - first.value.x) * canvasWidth
            animation.duration = max(animation.duration ?? duration, last.time)
            hasAnyValue = true
        }

        if let last = keyframes.opacity.sorted(by: { $0.time < $1.time }).last {
            animation.opacityTo = last.value
            animation.duration = max(animation.duration ?? duration, last.time)
            hasAnyValue = true
        }

        return hasAnyValue ? animation : nil
    }

    private static func dominantEasing(in keyframes: KeyframeSet) -> Easing? {
        keyframes.scale.dropFirst().last?.easing
        ?? keyframes.position.dropFirst().last?.easing
        ?? keyframes.opacity.dropFirst().last?.easing
        ?? keyframes.rotation.dropFirst().last?.easing
    }

    private static func buildTextLayer(from seg: EditorSegment, sceneStart: Double) -> SLayer? {
        guard case .text(let c) = seg.content else { return nil }

        var layer = SLayer(type: "text")
        layer.zIndex      = seg.sourceZIndex ?? 10
        layer.content     = c.text
        // ← Key inverse conversion: absolute → scene-relative offsets
        layer.startOffset = seg.targetRange.start - sceneStart
        layer.endOffset   = seg.targetRange.end   - sceneStart
        layer.position    = STextPosition(x: c.position.x, y: c.position.y, anchor: c.anchor.rawValue)
        layer.style       = STextStyle(
            fontSize: Int(c.style.fontSize),
            fontWeight: c.style.fontWeight.rawValue,
            color: c.style.color,
            backgroundColor: c.style.backgroundColor,
            backgroundRadius: Int(c.style.backgroundRadius),
            padding: [Int(c.style.paddingV), Int(c.style.paddingH)]
        )
        layer.textAnimation = STextAnimation(
            enter: c.enterAnimation?.type.rawValue,
            exit:  c.exitAnimation?.type.rawValue,
            enterDuration: c.enterAnimation?.duration,
            exitDuration:  c.exitAnimation?.duration
        )
        return layer
    }

    // MARK: - Audio

    private static func buildAudioTrack(from timeline: EditorTimeline) -> SAudioTrack? {
        let audioTracks = timeline.tracks.filter { $0.kind == .audio }
        guard !audioTracks.isEmpty else { return nil }

        var bgm: SBGM?
        var voice: SVoice?

        for track in audioTracks {
            for seg in track.segments {
                guard case .audio(let a) = seg.content else { continue }
                let mat = timeline.materials[seg.materialID]
                let url = mat?.localURL?.absoluteString ?? mat?.remoteURL?.absoluteString ?? ""

                if track.label == "BGM" || a.isLooping {
                    bgm = SBGM(url: url, volume: a.volume, loop: a.isLooping, fadeOutDuration: a.fadeOutDuration > 0 ? a.fadeOutDuration : nil)
                } else {
                    voice = SVoice(url: url, volume: a.volume, startOffset: seg.targetRange.start > 0 ? seg.targetRange.start : nil)
                }
            }
        }

        guard bgm != nil || voice != nil else { return nil }
        return SAudioTrack(bgm: bgm, voice: voice)
    }

    // MARK: - Subtitle

    private static func buildSubtitleTrack(from timeline: EditorTimeline) -> SSubtitleTrack? {
        let subtitleTracks = timeline.tracks.filter { $0.kind == .subtitle }
        let segments = subtitleTracks.flatMap { $0.segments }
        guard !segments.isEmpty else { return nil }

        let items: [SSubtitleItem] = segments.compactMap { seg in
            guard case .subtitle(let c) = seg.content else { return nil }
            let serverSegs = c.segments?.map { s in
                SSubtitleSegment(
                    text: s.text,
                    highlight: s.isHighlighted ? true : nil,
                    style: s.color != nil || s.fontWeight != nil ? SSubtitleSegmentStyle(
                        typography: STypography(fontWeight: s.fontWeight?.rawValue, color: s.color)
                    ) : nil
                )
            }
            return SSubtitleItem(
                id: "sub_\(seg.id.uuidString.prefix(8))",
                start: seg.targetRange.start,
                end: seg.targetRange.end,
                text: c.text,
                segments: serverSegs,
                style: nil
            )
        }

        return SSubtitleTrack(version: 2, layoutMode: "caption", style: nil, items: items)
    }

    // MARK: - Meta

    private static func buildMeta(from timeline: EditorTimeline) -> SMeta? {
        let m = timeline.metadata
        guard m.sourceWorkflow != nil || m.productName != nil else { return nil }
        return SMeta(
            workflowName: m.sourceWorkflow,
            totalScenes: timeline.tracks.first(where: { $0.kind == .video })?.segments.count,
            renderType: m.renderType ?? "client",
            productName: m.productName
        )
    }
}

// MARK: - SLayer init helper

private extension SLayer {
    init(type: String) {
        self.type = type
    }
}

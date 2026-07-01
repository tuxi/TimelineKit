import Foundation
import CoreImage
import CoreMedia

// MARK: - TransitionComposer

/// Single exit point for all transition blending in both preview and export.
///
/// TimelineRenderer and VideoExporter must NOT contain any if-dissolve / if-slide logic.
/// Overlay / text / subtitle layers are NOT processed here — the caller composites
/// them AFTER this call returns.
public enum TransitionComposer {

    /// Render the main-visual transition frame.
    ///
    /// - Parameters:
    ///   - info: Resolved transition from LayerResolver (image/video specs + progress + presetID).
    ///   - compositionTime: Composition clock time, used to pull video frames.
    ///   - canvasSize: Output canvas size.
    ///   - context: Caller-owned Metal-backed CIContext.
    /// - Returns: Blended main-visual CIImage, or nil if both sides have no content.
    nonisolated public static func render(
        _ info: TransitionInfo,
        at compositionTime: CMTime,
        canvasSize: CGSize,
        context: CIContext
    ) -> CIImage? {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)

        let outgoingFrame = resolveFrame(image: info.outgoing, video: info.outgoingVideo,
                                         at: compositionTime)?.cropped(to: canvasRect)
        let incomingFrame = resolveFrame(image: info.incoming, video: info.incomingVideo,
                                         at: compositionTime)?.cropped(to: canvasRect)

        let easedProgress = Float(EasingLUT.evaluate(
            kind: easingKind(info.easing),
            at: Double(info.rawProgress)
        ))

        let preset = TransitionPresetRegistry.preset(for: info.presetID)
                  ?? TransitionPresetRegistry.preset(for: "crossFade")!

        switch (outgoingFrame, incomingFrame) {
        case (let fg?, let bg?):
            return preset.render(outgoing: fg, incoming: bg,
                                 progress: easedProgress,
                                 canvasSize: canvasSize,
                                 context: context)
        case (let fg?, nil):
            // Only outgoing present — fade it out.
            return fg.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(1 - easedProgress))
            ]).cropped(to: canvasRect)
        case (nil, let bg?):
            // Only incoming present — fade it in.
            return bg.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(easedProgress))
            ]).cropped(to: canvasRect)
        case (nil, nil):
            return nil
        }
    }

    // MARK: - Private

    private static func resolveFrame(
        image: ImageLayerSpec?,
        video: VideoLayerSpec?,
        at time: CMTime
    ) -> CIImage? {
        if let spec = image {
            // Clamp into the spec's valid range so cross-boundary transition frames
            // are pinned to the first/last frame of each side rather than returning nil.
            return ImageLayerComposer.evaluate(spec: spec, at: clamp(time, to: spec.timeRange))
        }
        if let spec = video {
            return VideoLayerComposer.evaluate(spec: spec, at: clamp(time, to: spec.timeRange))
        }
        return nil
    }

    /// Clamp `time` into [range.start, range.end − 1 tick] so it always satisfies
    /// the `>= start && < end` guards in ImageLayerComposer / VideoLayerComposer.
    private static func clamp(_ time: CMTime, to range: CMTimeRange) -> CMTime {
        if time <= range.start { return range.start }
        let end = range.end
        guard time < end else {
            let nearEnd = CMTimeSubtract(end, CMTime(value: 1, timescale: 600))
            return nearEnd > range.start ? nearEnd : range.start
        }
        return time
    }

    private static func easingKind(_ easing: EditorTransition.Easing) -> EasingKind {
        switch easing {
        case .linear:    return .linear
        case .easeIn:    return .easeIn
        case .easeOut:   return .easeOut
        case .easeInOut: return .easeInOut
        }
    }
}

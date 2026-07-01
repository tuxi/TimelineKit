#if canImport(UIKit)
import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal

// MARK: - TimelineRenderer

/// Main-actor frame renderer for mixed visual timelines (V6 P3).
///
/// Each call to `renderFrame(at:)` does:
///   1. `LayerResolver.resolve` → `ResolvedFrame` (pure, cheap)
///   2. `ImageLayerComposer.evaluate` or `VideoLayerComposer.evaluate` per layer
///   3. Overlay layers composited bottom-to-top; transition blend on top
///   4. `CIContext.render` into a `CVPixelBuffer` from the pool
///
/// Compositing order (ascending z-index):
///   • z < 0  — background / overlay layers (rendered first, behind main)
///   • z = 0  — main-track body (rendered last, on top)
///   • transition — dissolve replaces main; overlays stay beneath it
///
/// The CIContext is Metal-backed and shared across frames. The pixel-buffer pool
/// is recreated only when the canvas size changes.
@MainActor
public final class TimelineRenderer {

    // MARK: - State

    private var timeline: EditorTimeline?
    private var canvasSize: CGSize = .zero

    // Metal-backed CIContext — created once, reused across all frames.
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [
                .workingColorSpace: NSNull(),
                .outputColorSpace:  NSNull()
            ])
        }
        return CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace:  NSNull()
        ])
    }()

    // Pixel-buffer pool for output frames — rebuilt when canvasSize changes.
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    // Last successfully rendered frame — returned when LayerResolver returns empty
    // but compositionTime is still within timeline.duration (末態停驻: last-frame hold).
    private var lastValidPixelBuffer: CVPixelBuffer?

    // MARK: - Lifecycle

    public init() {
        TransitionPresetRegistry.ensureDefaultsRegistered()
        AnimationPresetRegistry.ensureDefaultsRegistered()
    }

    // MARK: - Public API

    /// Update the timeline and canvas size. Call after every timeline rebuild.
    public func update(timeline: EditorTimeline, canvasSize: CGSize) {
        self.timeline   = timeline
        self.canvasSize = canvasSize
        lastValidPixelBuffer = nil
        if canvasSize != poolSize {
            rebuildPool(size: canvasSize)
        }
        VideoLayerComposer.frameProvider?.setCanvasSize(canvasSize)
        VideoLayerComposer.frameProvider?.preload(
            videoSpecs: LayerResolver.videoSpecs(timeline: timeline, canvasSize: canvasSize)
        )
        if TextLayerComposer.frameProvider == nil {
            TextLayerComposer.frameProvider = TextFrameProvider()
        }
        TextLayerComposer.frameProvider?.update(timeline: timeline, renderSize: canvasSize)
    }

    /// Refresh only text/subtitle raster layers without touching video providers
    /// or rebuilding the output pixel-buffer pool. Used by live text editing and
    /// drag gestures where AVComposition does not need to change.
    public func refreshTextLayers(timeline: EditorTimeline) {
        self.timeline = timeline
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        if TextLayerComposer.frameProvider == nil {
            TextLayerComposer.frameProvider = TextFrameProvider()
        }
        TextLayerComposer.frameProvider?.update(timeline: timeline, renderSize: canvasSize)
    }

    /// Render the frame at `compositionTime` (seconds, AVPlayer clock) into a
    /// newly allocated `CVPixelBuffer` from the pool.
    ///
    /// Returns nil when no timeline is loaded, the pool is empty, or rendering fails.
    public func renderFrame(at compositionTime: Double) -> CVPixelBuffer? {
        guard let timeline,
              canvasSize.width > 0, canvasSize.height > 0
        else { return nil }

        let frame      = LayerResolver.resolve(timeline: timeline,
                                               at: compositionTime,
                                               canvasSize: canvasSize)
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let cmTime     = CMTime(seconds: compositionTime, preferredTimescale: 600)

        // 末態停驻: if LayerResolver returned empty (no layers, no transition) but we
        // are still within the timeline duration, return the last valid frame so the
        // preview doesn't flash black at the tail of the last segment or when the
        // main track is empty but overlays/text are on other tracks.
        if frame.layers.isEmpty && frame.transition == nil {
            if compositionTime <= timeline.duration, let cached = lastValidPixelBuffer {
#if DEBUG
                print("[Renderer] t=\(String(format: "%.3f", compositionTime)) USE CACHED (empty frame, duration=\(timeline.duration))")
#endif
                return cached
            }
        }

        // Start with an opaque black background.
        var composite: CIImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: canvasRect)

        // ── Step 1: Composite all background/overlay layers (z < 0, sorted first) ──
        // In body zones, frame.layers includes BOTH overlay (z=-1) and main (z=0).
        // In transition zones, frame.layers contains ONLY overlays; the main-layer
        // blend is in frame.transition (applied in Step 2 below).
        for layer in frame.layers {
            let layerImg: CIImage?
            var segmentTimeRange: CMTimeRange = .invalid
            switch layer.content {
            case .image(let spec):
                layerImg = ImageLayerComposer.evaluate(spec: spec, at: cmTime)?
                    .cropped(to: canvasRect)
                segmentTimeRange = spec.timeRange
            case .video(let spec):
                layerImg = VideoLayerComposer.evaluate(spec: spec, at: cmTime)?
                    .cropped(to: canvasRect)
                segmentTimeRange = spec.timeRange
            case .text(let spec):
                layerImg = TextLayerComposer.evaluate(spec: spec, at: cmTime)?
                    .cropped(to: canvasRect)
                segmentTimeRange = spec.timeRange
            }
            guard var li = layerImg else { continue }
            // V7: apply clip animation (in / out / combo) — single exit point
            if !layer.animations.isEmpty && segmentTimeRange != .invalid {
                li = AnimationComposer.apply(
                    to:               li,
                    animations:       layer.animations,
                    compositionTime:  compositionTime,
                    segmentTimeRange: segmentTimeRange,
                    extent:           canvasRect,
                    context:          ciContext
                )
            }
            composite = li.composited(over: composite)
        }

        // ── Step 2: Render transition (main visual only) ─────────────────────────
        // V7: ALL transition logic lives in TransitionComposer — no dissolve/slide logic here.
        // Overlay / text layers in frame.layers are composited in Step 1 (z < 0) and after.
        if let trans = frame.transition,
           let mainVisual = TransitionComposer.render(trans, at: cmTime,
                                                       canvasSize: canvasSize,
                                                       context: ciContext) {
            composite = mainVisual.composited(over: composite)
        }

        let result = renderToCVPixelBuffer(composite, canvasRect: canvasRect)
        if let result { lastValidPixelBuffer = result }
        return result
    }

    // MARK: - Private


    private func rebuildPool(size: CGSize) {
        let w = Int(size.width)
        let h = Int(size.height)
        guard w > 0, h > 0 else { return }

        let attrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey:      kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey:                w,
            kCVPixelBufferHeightKey:               h,
            kCVPixelBufferIOSurfacePropertiesKey:  NSDictionary()
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attrs, &pool)
        if status == kCVReturnSuccess {
            pixelBufferPool = pool
            poolSize = size
        }
    }

    private func renderToCVPixelBuffer(_ image: CIImage, canvasRect: CGRect) -> CVPixelBuffer? {
        if pixelBufferPool == nil || poolSize != canvasSize {
            rebuildPool(size: canvasSize)
        }
        guard let pool = pixelBufferPool else { return nil }

        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess,
              let pb
        else { return nil }

        ciContext.render(image, to: pb,
                         bounds: canvasRect,
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        return pb
    }
}
#endif

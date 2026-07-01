import CoreImage
import os.log

// MARK: - AnimationCategory

public enum AnimationCategory: String, CaseIterable, Sendable {
    case entrance = "入场"
    case exit     = "出场"
    case combo    = "组合"
}

// MARK: - AnimationPreset Protocol

/// A single registered clip animation preset.
///
/// Presets are stateless value types registered once at launch via
/// `AnimationPresetRegistry.ensureDefaultsRegistered()`.
///
/// progress semantics by timing:
///   - .in  animation: 0 = clip start (fully hidden/transformed), 1 = normal state
///   - .out animation: 0 = fully visible (normal state), 1 = clip end (fully gone)
///   - .combo:         0 = clip start, 1 = clip end (continuous)
public protocol AnimationPreset: Sendable {
    var presetID:    String            { get }
    var displayName: String            { get }
    var category:    AnimationCategory { get }
    /// SF Symbol name for the picker thumbnail icon.
    var iconName:    String            { get }

    /// Apply animation transform to a fully-composed CIImage.
    ///
    /// - Parameters:
    ///   - image:    The rendered frame (output of ImageLayerComposer or VideoLayerComposer).
    ///   - progress: Normalized 0.0–1.0 within the animation window (see timing semantics above).
    ///   - extent:   Canvas bounds (for position-based transforms).
    ///   - context:  CIContext.
    /// - Returns: Transformed CIImage. Must not be nil even if no effect.
    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage
}

// MARK: - AnimationPresetRegistry

/// Global registry mapping presetID → AnimationPreset.
///
/// Registration happens once at launch via `ensureDefaultsRegistered()`.
/// All AnimationComposer calls go through this registry.
public enum AnimationPresetRegistry {

    nonisolated(unsafe) private static var table: [String: any AnimationPreset] = [:]
    nonisolated(unsafe) private static var displayOrder: [String] = []
    nonisolated(unsafe) private static var defaultsLoaded = false

    // MARK: Registration

    public static func register(_ preset: any AnimationPreset) {
        if table[preset.presetID] == nil {
            displayOrder.append(preset.presetID)
        }
        table[preset.presetID] = preset
    }

    public static func preset(for id: String) -> (any AnimationPreset)? {
        table[id]
    }

    public static var allIDs: [String] { displayOrder }

    public static func ids(for category: AnimationCategory) -> [String] {
        displayOrder.filter { table[$0]?.category == category }
    }

    // MARK: Default preset bootstrap

    /// Called by TimelineRenderer.init and AnimationComposer — idempotent.
    public static func ensureDefaultsRegistered() {
        guard !defaultsLoaded else { return }
        defaultsLoaded = true

        // Am1: entrance + exit base
        register(FadeInPreset())
        register(FadeOutPreset())

        // Am3: additional entrance presets
        register(SlideInPreset(presetID: "slideInLeft",  displayName: "向右滑入",
                               iconName: "arrow.right",  direction: .left))
        register(SlideInPreset(presetID: "slideInRight", displayName: "向左滑入",
                               iconName: "arrow.left",   direction: .right))
        register(SlideInPreset(presetID: "slideInUp",    displayName: "向下滑入",
                               iconName: "arrow.down",   direction: .up))
        register(SlideInPreset(presetID: "slideInDown",  displayName: "向上滑入",
                               iconName: "arrow.up",     direction: .down))
        register(ZoomInAnimPreset())

        // Am3: exit presets
        register(SlideOutPreset(presetID: "slideOutLeft",  displayName: "向右退出",
                                iconName: "arrow.right",   direction: .left))
        register(SlideOutPreset(presetID: "slideOutRight", displayName: "向左退出",
                                iconName: "arrow.left",    direction: .right))
        register(ZoomOutAnimPreset())

        // Am3: combo presets (original 3)
        register(SlowZoomComboPreset())
        register(SlowZoomOutComboPreset())
        register(PanLeftComboPreset())
        register(PanRightComboPreset())
        register(DriftComboPreset())
        register(FloatComboPreset())

        // Am4 migration: depth / orbit presets (from ImageAnimationPreset)
        register(DepthPushComboPreset())
        register(DepthPullComboPreset())
        register(DepthPanLeftComboPreset())
        register(DepthPanRightComboPreset())
        register(DepthOrbitLeftComboPreset())
        register(DepthOrbitRightComboPreset())
    }
}

// MARK: - FadeInPreset

/// Clip fades in from transparent to fully visible.
/// progress 0 = transparent, progress 1 = fully visible.
struct FadeInPreset: AnimationPreset {
    let presetID    = "fadeIn"
    let displayName = "渐显"
    let category    = AnimationCategory.entrance
    let iconName    = "sun.min"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p = CGFloat(progress)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: p)
        ])
    }
}

// MARK: - FadeOutPreset

/// Clip fades out from fully visible to transparent.
/// progress 0 = fully visible, progress 1 = transparent.
struct FadeOutPreset: AnimationPreset {
    let presetID    = "fadeOut"
    let displayName = "渐隐"
    let category    = AnimationCategory.exit
    let iconName    = "sun.max"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p = CGFloat(1.0 - progress)  // invert: progress 0→1 maps to opacity 1→0
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: p)
        ])
    }
}

// MARK: - SlideInPreset

/// Clip slides in from one edge while fading in.
/// progress 0 = fully off-screen + transparent, progress 1 = in-place + fully visible.
struct SlideInPreset: AnimationPreset {
    let presetID:    String
    let displayName: String
    let category   = AnimationCategory.entrance
    let iconName:    String

    enum Direction { case left, right, up, down }
    let direction: Direction

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p    = CGFloat(progress)
        let ease = easeOut(p)
        let dx: CGFloat
        let dy: CGFloat
        switch direction {
        case .left:  dx = -(1 - ease) * extent.width;  dy = 0
        case .right: dx =  (1 - ease) * extent.width;  dy = 0
        case .up:    dx = 0; dy =  (1 - ease) * extent.height
        case .down:  dx = 0; dy = -(1 - ease) * extent.height
        }
        return image
            .transformed(by: .init(translationX: dx, y: dy))
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: p)
            ])
    }
}

// MARK: - SlideOutPreset

/// Clip slides out toward one edge while fading out.
/// progress 0 = in-place + fully visible, progress 1 = fully off-screen + transparent.
struct SlideOutPreset: AnimationPreset {
    let presetID:    String
    let displayName: String
    let category   = AnimationCategory.exit
    let iconName:    String

    enum Direction { case left, right }
    let direction: Direction

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p    = CGFloat(progress)
        let ease = easeIn(p)
        let dx: CGFloat = direction == .left ? -ease * extent.width : ease * extent.width
        return image
            .transformed(by: .init(translationX: dx, y: 0))
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - p)
            ])
    }
}

// MARK: - ZoomInAnimPreset

/// Clip enters by scaling from 85% to 100% while fading in.
/// progress 0 = scale 0.85 + transparent, progress 1 = scale 1.0 + fully visible.
struct ZoomInAnimPreset: AnimationPreset {
    let presetID    = "zoomIn"
    let displayName = "放大"
    let category    = AnimationCategory.entrance
    let iconName    = "arrow.up.left.and.arrow.down.right"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p     = CGFloat(progress)
        let ease  = easeOut(p)
        let scale = 0.85 + ease * 0.15   // 0.85 → 1.0
        let cx    = extent.midX
        let cy    = extent.midY
        let t = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -cx, y: -cy)
        return image
            .transformed(by: t)
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: p)
            ])
    }
}

// MARK: - ZoomOutAnimPreset

/// Clip exits by scaling from 100% to 85% while fading out.
struct ZoomOutAnimPreset: AnimationPreset {
    let presetID    = "zoomOut"
    let displayName = "缩小"
    let category    = AnimationCategory.exit
    let iconName    = "arrow.down.right.and.arrow.up.left"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p     = CGFloat(progress)
        let ease  = easeIn(p)
        let scale = 1.0 - ease * 0.15   // 1.0 → 0.85
        let cx    = extent.midX
        let cy    = extent.midY
        let t = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -cx, y: -cy)
        return image
            .transformed(by: t)
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - p)
            ])
    }
}

// MARK: - SlowZoomComboPreset

/// Full-clip slow zoom in (1.0 → 1.12). Mirrors Ken Burns `slowZoomIn` semantic.
struct SlowZoomComboPreset: AnimationPreset {
    let presetID    = "slowZoom"
    let displayName = "缓慢放大"
    let category    = AnimationCategory.combo
    let iconName    = "plus.magnifyingglass"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p     = CGFloat(easeOut(CGFloat(progress)))
        let scale = 1.0 + p * 0.12   // 1.0 → 1.12
        let cx    = extent.midX
        let cy    = extent.midY
        let t = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -cx, y: -cy)
        return image.transformed(by: t).cropped(to: extent)
    }
}

// MARK: - DriftComboPreset

/// Full-clip horizontal drift (pan right 3%) with slight zoom.
struct DriftComboPreset: AnimationPreset {
    let presetID    = "drift"
    let displayName = "漂移"
    let category    = AnimationCategory.combo
    let iconName    = "arrow.right"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p  = CGFloat(easeOut(CGFloat(progress)))
        let dx = p * extent.width * 0.03   // 3% drift
        let scale = 1.06 - p * 0.06        // 1.06 → 1.0 (counter-zoom for depth feel)
        let cx = extent.midX
        let cy = extent.midY
        let t = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -cx, y: -cy)
                    .translatedBy(x: dx, y: 0)
        return image.transformed(by: t).cropped(to: extent)
    }
}

// MARK: - FloatComboPreset

/// Full-clip vertical float (gentle sinusoidal vertical bob).
struct FloatComboPreset: AnimationPreset {
    let presetID    = "float"
    let displayName = "漂浮"
    let category    = AnimationCategory.combo
    let iconName    = "waveform"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        // Sinusoidal vertical movement: ±2% of height, 1 full cycle
        let dy = CGFloat(sin(Double(progress) * 2 * .pi)) * extent.height * 0.02
        let t  = CGAffineTransform(translationX: 0, y: dy)
        return image.transformed(by: t).cropped(to: extent)
    }
}

// MARK: - SlowZoomOutComboPreset

/// Full-clip slow zoom out (1.12 → 1.0). Mirrors Ken Burns `slowZoomOut` semantic.
struct SlowZoomOutComboPreset: AnimationPreset {
    let presetID    = "slowZoomOut"
    let displayName = "缓慢缩小"
    let category    = AnimationCategory.combo
    let iconName    = "minus.magnifyingglass"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p     = CGFloat(easeOut(CGFloat(progress)))
        let scale = 1.12 - p * 0.12  // 1.12 → 1.0
        let cx    = extent.midX
        let cy    = extent.midY
        let t = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -cx, y: -cy)
        return image.transformed(by: t).cropped(to: extent)
    }
}

// MARK: - PanLeftComboPreset

/// Full-clip pan left: start with 6% overscan, drift content to the left.
struct PanLeftComboPreset: AnimationPreset {
    let presetID    = "panLeft"
    let displayName = "向左平移"
    let category    = AnimationCategory.combo
    let iconName    = "arrow.left"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p     = CGFloat(easeOut(CGFloat(progress)))
        let dx    = -p * extent.width * 0.06   // drift left 6%
        let scale = 1.06 - p * 0.06            // 1.06 → 1.0 (burn off overscan)
        let cx    = extent.midX
        let cy    = extent.midY
        let t = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -cx, y: -cy)
                    .translatedBy(x: dx, y: 0)
        return image.transformed(by: t).cropped(to: extent)
    }
}

// MARK: - PanRightComboPreset

/// Full-clip pan right: start with 6% overscan, drift content to the right.
struct PanRightComboPreset: AnimationPreset {
    let presetID    = "panRight"
    let displayName = "向右平移"
    let category    = AnimationCategory.combo
    let iconName    = "arrow.right"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p     = CGFloat(easeOut(CGFloat(progress)))
        let dx    =  p * extent.width * 0.06   // drift right 6%
        let scale = 1.06 - p * 0.06
        let cx    = extent.midX
        let cy    = extent.midY
        let t = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -cx, y: -cy)
                    .translatedBy(x: dx, y: 0)
        return image.transformed(by: t).cropped(to: extent)
    }
}

// MARK: - DepthPushComboPreset

/// Depth-sim dolly forward: scale 1.0 → 1.22 (stronger than slowZoomIn).
struct DepthPushComboPreset: AnimationPreset {
    let presetID    = "depthPush"
    let displayName = "景深推进"
    let category    = AnimationCategory.combo
    let iconName    = "arrow.up.forward.circle"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p     = CGFloat(easeOut(CGFloat(progress)))
        let scale = 1.0 + p * 0.22   // 1.0 → 1.22
        let cx    = extent.midX
        let cy    = extent.midY
        let t = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -cx, y: -cy)
        return image.transformed(by: t).cropped(to: extent)
    }
}

// MARK: - DepthPullComboPreset

/// Depth-sim dolly backward: scale 1.22 → 1.0 (camera pulls away).
struct DepthPullComboPreset: AnimationPreset {
    let presetID    = "depthPull"
    let displayName = "景深后退"
    let category    = AnimationCategory.combo
    let iconName    = "arrow.down.backward.circle"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p     = CGFloat(easeOut(CGFloat(progress)))
        let scale = 1.22 - p * 0.22  // 1.22 → 1.0
        let cx    = extent.midX
        let cy    = extent.midY
        let t = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -cx, y: -cy)
        return image.transformed(by: t).cropped(to: extent)
    }
}

// MARK: - DepthPanLeftComboPreset

/// Depth-sim lateral pan left: deeper pan offset + counter-zoom.
struct DepthPanLeftComboPreset: AnimationPreset {
    let presetID    = "depthPanLeft"
    let displayName = "景深左移"
    let category    = AnimationCategory.combo
    let iconName    = "arrow.left.circle"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p     = CGFloat(easeOut(CGFloat(progress)))
        let dx    = -p * extent.width * 0.08   // 8% lateral pan
        let scale = 1.15 - p * 0.15            // 1.15 → 1.0
        let cx    = extent.midX
        let cy    = extent.midY
        let t = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -cx, y: -cy)
                    .translatedBy(x: dx, y: 0)
        return image.transformed(by: t).cropped(to: extent)
    }
}

// MARK: - DepthPanRightComboPreset

/// Depth-sim lateral pan right.
struct DepthPanRightComboPreset: AnimationPreset {
    let presetID    = "depthPanRight"
    let displayName = "景深右移"
    let category    = AnimationCategory.combo
    let iconName    = "arrow.right.circle"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p     = CGFloat(easeOut(CGFloat(progress)))
        let dx    =  p * extent.width * 0.08
        let scale = 1.15 - p * 0.15
        let cx    = extent.midX
        let cy    = extent.midY
        let t = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -cx, y: -cy)
                    .translatedBy(x: dx, y: 0)
        return image.transformed(by: t).cropped(to: extent)
    }
}

// MARK: - DepthOrbitLeftComboPreset

/// Orbit left: pan left while zooming in — "arc around subject" parallax feel.
struct DepthOrbitLeftComboPreset: AnimationPreset {
    let presetID    = "depthOrbitLeft"
    let displayName = "环绕左"
    let category    = AnimationCategory.combo
    let iconName    = "arrow.counterclockwise"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p     = CGFloat(easeOut(CGFloat(progress)))
        let dx    = -p * extent.width * 0.06
        let scale = 1.0 + p * 0.12   // zoom in while panning
        let cx    = extent.midX
        let cy    = extent.midY
        let t = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -cx, y: -cy)
                    .translatedBy(x: dx, y: 0)
        return image.transformed(by: t).cropped(to: extent)
    }
}

// MARK: - DepthOrbitRightComboPreset

/// Orbit right: pan right while zooming in.
struct DepthOrbitRightComboPreset: AnimationPreset {
    let presetID    = "depthOrbitRight"
    let displayName = "环绕右"
    let category    = AnimationCategory.combo
    let iconName    = "arrow.clockwise"

    func apply(to image: CIImage, progress: Float, extent: CGRect, context: CIContext) -> CIImage {
        let p     = CGFloat(easeOut(CGFloat(progress)))
        let dx    =  p * extent.width * 0.06
        let scale = 1.0 + p * 0.12
        let cx    = extent.midX
        let cy    = extent.midY
        let t = CGAffineTransform(translationX: cx, y: cy)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -cx, y: -cy)
                    .translatedBy(x: dx, y: 0)
        return image.transformed(by: t).cropped(to: extent)
    }
}

// MARK: - Easing helpers (file-private)

private func easeOut(_ t: CGFloat) -> CGFloat {
    1 - pow(1 - t, 2)
}

private func easeIn(_ t: CGFloat) -> CGFloat {
    t * t
}

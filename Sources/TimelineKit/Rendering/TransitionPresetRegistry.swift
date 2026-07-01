import Foundation
import CoreImage
import CoreMedia

// MARK: - TransitionCategory

public enum TransitionCategory: String, CaseIterable, Sendable {
    case basic      = "基础"
    case motion     = "移动"
    case zoom       = "缩放"
    case blur       = "模糊"
    case stylized   = "风格化"   // reserved — V7 P2+
}

// MARK: - TransitionPreset protocol

/// A transition preset defines the visual effect for blending two main-track frames.
///
/// Presets are stateless value types registered once at launch.
/// Overlay / text / subtitle layers must NEVER be passed to `render` —
/// they are composited by TimelineRenderer AFTER TransitionComposer returns.
public protocol TransitionPreset: Sendable {
    var presetID:    String             { get }
    var displayName: String             { get }
    var category:    TransitionCategory { get }
    /// SF Symbol name for the picker thumbnail icon.
    var iconName:    String             { get }

    /// Render the blended frame between outgoing and incoming at `progress` (0→1, already eased).
    ///
    /// Both `outgoing` and `incoming` are cropped to canvasSize.
    /// Returns a CIImage representing the composited main-visual result.
    func render(
        outgoing:   CIImage,
        incoming:   CIImage,
        progress:   Float,
        canvasSize: CGSize,
        context:    CIContext
    ) -> CIImage
}

// MARK: - TransitionPresetRegistry

/// Global registry mapping presetID → TransitionPreset.
///
/// Registration happens once at launch (TimelineRenderer.init calls
/// ensureDefaultsRegistered). Custom presets can be added via `register(_:)`.
public enum TransitionPresetRegistry {

    nonisolated(unsafe) private static var table: [String: any TransitionPreset] = [:]
    nonisolated(unsafe) private static var displayOrder: [String] = []
    nonisolated(unsafe) private static var defaultsLoaded = false

    // MARK: - Registration

    public static func register(_ preset: any TransitionPreset) {
        if table[preset.presetID] == nil {
            displayOrder.append(preset.presetID)
        }
        table[preset.presetID] = preset
    }

    public static func preset(for id: String) -> (any TransitionPreset)? {
        table[id]
    }

    public static var allIDs: [String] { displayOrder }

    public static var byCategory: [(category: TransitionCategory, ids: [String])] {
        TransitionCategory.allCases.compactMap { cat in
            let ids = displayOrder.filter { table[$0]?.category == cat }
            return ids.isEmpty ? nil : (cat, ids)
        }
    }

    // MARK: - Default preset bootstrap

    /// Called by TimelineRenderer.init — idempotent, safe to call multiple times.
    public static func ensureDefaultsRegistered() {
        guard !defaultsLoaded else { return }
        defaultsLoaded = true
        // 基础
        register(CrossFadePreset())
        register(FadeThroughBlackPreset())
        // 移动
        register(SlidePreset(presetID: "slideLeft",  displayName: "左移",    iconName: "arrow.left",         direction: .left))
        register(SlidePreset(presetID: "slideRight", displayName: "右移",    iconName: "arrow.right",        direction: .right))
        register(PushPreset (presetID: "pushLeft",   displayName: "推进·左", iconName: "arrow.left.to.line", direction: .left))
        register(PushPreset (presetID: "pushRight",  displayName: "推进·右", iconName: "arrow.right.to.line",direction: .right))
        // 缩放
        register(ZoomInPreset())
        // 模糊
        register(BlurFadePreset())
    }

    // MARK: - Compatibility mapping (legacy TransitionType → presetID)

    /// Maps a V2-era `EditorTransition.TransitionType` to a canonical presetID.
    /// Used when `EditorTransition.presetID` is nil (old drafts without the V7 field).
    public static func presetID(for type: EditorTransition.TransitionType) -> String {
        switch type {
        case .fade:             return "crossFade"
        case .dissolve:         return "crossFade"
        case .slideLeft:        return fallbackIfUnregistered("slideLeft")
        case .slideRight:       return fallbackIfUnregistered("slideRight")
        case .slideUp:          return fallbackIfUnregistered("slideUp")
        case .slideDown:        return fallbackIfUnregistered("slideDown")
        case .zoom:             return fallbackIfUnregistered("zoomIn")
        case .wipe:             return fallbackIfUnregistered("wipeLeft")
        case .crossFade:        return "crossFade"
        case .fadeThroughBlack: return fallbackIfUnregistered("fadeThroughBlack")
        case .pushLeft:         return fallbackIfUnregistered("pushLeft")
        case .pushRight:        return fallbackIfUnregistered("pushRight")
        case .zoomIn:           return fallbackIfUnregistered("zoomIn")
        case .blurFade:         return fallbackIfUnregistered("blurFade")
        }
    }

    private static func fallbackIfUnregistered(_ id: String) -> String {
        table[id] != nil ? id : "crossFade"
    }
}

// MARK: - CrossFadePreset

/// Standard dissolve: outgoing fades out while incoming fades in simultaneously.
struct CrossFadePreset: TransitionPreset {
    let presetID    = "crossFade"
    let displayName = "叠化"
    let category    = TransitionCategory.basic
    let iconName    = "circle.lefthalf.filled"

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        outgoing.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: incoming,
            kCIInputTimeKey:        progress
        ])
    }
}

// MARK: - FadeThroughBlackPreset

/// Outgoing dissolves to black (first half), then black dissolves to incoming (second half).
struct FadeThroughBlackPreset: TransitionPreset {
    let presetID    = "fadeThroughBlack"
    let displayName = "闪黑"
    let category    = TransitionCategory.basic
    let iconName    = "moon.fill"

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: canvasSize))
        if progress < 0.5 {
            let t = progress / 0.5
            return outgoing.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: black,
                kCIInputTimeKey:        t
            ])
        } else {
            let t = (progress - 0.5) / 0.5
            return black.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: incoming,
                kCIInputTimeKey:        t
            ])
        }
    }
}

// MARK: - SlidePreset

/// Incoming frame slides in from one side while outgoing slides off the other.
struct SlidePreset: TransitionPreset {
    let presetID:    String
    let displayName: String
    let category  = TransitionCategory.motion
    let iconName:    String

    enum Direction { case left, right }
    let direction: Direction

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let w      = canvasSize.width
        let offset = CGFloat(progress) * w
        let canvasRect = CGRect(origin: .zero, size: canvasSize)

        let outDx: CGFloat = direction == .left ? -offset : offset
        let inDx:  CGFloat = direction == .left ? (w - offset) : (-w + offset)

        let outSlid = outgoing.transformed(by: .init(translationX: outDx, y: 0))
                              .cropped(to: canvasRect)
        let inSlid  = incoming.transformed(by: .init(translationX: inDx,  y: 0))
                              .cropped(to: canvasRect)

        return inSlid.composited(over: outSlid)
    }
}

// MARK: - PushPreset

/// Both frames move together in the same direction — outgoing exits, incoming enters seamlessly.
struct PushPreset: TransitionPreset {
    let presetID:    String
    let displayName: String
    let category  = TransitionCategory.motion
    let iconName:    String

    enum Direction { case left, right }
    let direction: Direction

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let w      = canvasSize.width
        let offset = CGFloat(progress) * w
        let canvasRect = CGRect(origin: .zero, size: canvasSize)

        let (outDx, inDx): (CGFloat, CGFloat) = direction == .left
            ? (-offset,      w - offset)
            : ( offset,     -w + offset)

        let outPushed = outgoing.transformed(by: .init(translationX: outDx, y: 0))
                                .cropped(to: canvasRect)
        let inPushed  = incoming.transformed(by: .init(translationX: inDx,  y: 0))
                                .cropped(to: canvasRect)

        return inPushed.composited(over: outPushed)
    }
}

// MARK: - ZoomInPreset

/// Outgoing frame zooms out (1.0→1.3 scale) while fading; incoming fades in at normal scale.
struct ZoomInPreset: TransitionPreset {
    let presetID    = "zoomIn"
    let displayName = "放大"
    let category    = TransitionCategory.zoom
    let iconName    = "plus.magnifyingglass"

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let p          = CGFloat(progress)
        let center     = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

        // Outgoing: zoom out from center (scale 1.0 → 1.3) and fade out
        let scale = 1.0 + p * 0.3
        let t = CGAffineTransform(translationX: center.x, y: center.y)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -center.x, y: -center.y)
        let outScaled = outgoing
            .transformed(by: t)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - p)
            ])
            .cropped(to: canvasRect)

        // Incoming: fade in at normal scale
        let inFaded = incoming
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: p)
            ])
            .cropped(to: canvasRect)

        return inFaded.composited(over: outScaled)
    }
}

// MARK: - BlurFadePreset

/// Outgoing blurs out (radius 0→12) while fading; incoming fades in sharp.
struct BlurFadePreset: TransitionPreset {
    let presetID    = "blurFade"
    let displayName = "模糊叠化"
    let category    = TransitionCategory.blur
    let iconName    = "camera.filters"

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let p          = CGFloat(progress)

        // Outgoing: gaussian blur radius 0→12 + fade out
        let blurRadius = p * 12.0
        let outBlurred = outgoing
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blurRadius])
            .cropped(to: canvasRect)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - p)
            ])

        // Incoming: fade in sharp (no blur)
        let inFaded = incoming
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: p)
            ])
            .cropped(to: canvasRect)

        return inFaded.composited(over: outBlurred)
    }
}

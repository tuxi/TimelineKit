import Foundation

// MARK: - LayerContent

/// Unified layer content type for TimelineRenderer compositing.
///
/// Replaces the direct `ImageLayerSpec` reference in `ResolvedLayer` so video,
/// image, and future layer types (text, sticker, effect) can be dispatched
/// uniformly by `TimelineRenderer.renderFrame(at:)`.
public enum LayerContent: Sendable {
    case image(ImageLayerSpec)
    case video(VideoLayerSpec)
#if canImport(UIKit)
    case text(TextLayerSpec)
#endif
}

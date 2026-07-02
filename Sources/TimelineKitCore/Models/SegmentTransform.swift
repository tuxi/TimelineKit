import Foundation

/// Compositing transform applied to a segment during playback.
/// All values are relative to the canvas.
public struct SegmentTransform: Sendable, Hashable, Codable {
    /// Normalized position (0–1) of the segment's anchor point on the canvas.
    public var position: NormalizedPoint
    public var anchor: AnchorPoint
    /// Uniform scale factor (1.0 = no scaling).
    public var scale: Double
    /// Rotation in radians (clockwise positive).
    public var rotation: Double
    /// Opacity 0–1.
    public var opacity: Double

    public init(
        position: NormalizedPoint = .center,
        anchor: AnchorPoint = .center,
        scale: Double = 1.0,
        rotation: Double = 0,
        opacity: Double = 1.0
    ) {
        self.position = position
        self.anchor   = anchor
        self.scale    = scale
        self.rotation = rotation
        self.opacity  = opacity
    }

    public static let identity = SegmentTransform()
}

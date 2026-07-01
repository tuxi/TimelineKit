import Foundation

/// A position expressed as fractions of canvas width/height (0–1).
/// Avoids a CoreGraphics dependency in the pure model layer.
public struct NormalizedPoint: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let center       = NormalizedPoint(x: 0.5, y: 0.5)
    public static let topCenter    = NormalizedPoint(x: 0.5, y: 0.15)
    public static let bottomCenter = NormalizedPoint(x: 0.5, y: 0.85)
    public static let topLeft      = NormalizedPoint(x: 0.0, y: 0.0)
    public static let topRight     = NormalizedPoint(x: 1.0, y: 0.0)
}

public enum AnchorPoint: String, Sendable, Hashable, Codable, CaseIterable {
    case center
    case topLeft      = "top_left"
    case topRight     = "top_right"
    case bottomLeft   = "bottom_left"
    case bottomRight  = "bottom_right"
    case topCenter    = "top_center"
    case bottomCenter = "bottom_center"
}

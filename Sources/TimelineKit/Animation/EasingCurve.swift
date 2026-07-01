import Foundation

// MARK: - Easing LUT

/// Generates a 40-segment look-up table for easing curves.
/// Runtime evaluation is O(1): one lookup + segment-internal linear interpolation.
///
/// 40 segments = 41 sample points, following Final Cut Pro's XML keyframe
/// interpolation density — fine enough for ≤120 fps without visible stepping.
enum EasingLUT {
    static let segments = 40

    /// Evaluate eased progress at normalised time `t` (0…1).
    static func evaluate(kind: EasingKind, at t: Double) -> Double {
        let clamped = max(min(t, 1), 0)
        let scaled  = clamped * Double(segments)
        let idx     = min(Int(scaled), segments)
        let frac    = scaled - Double(idx)

        let lo = Self.sample(kind: kind, index: idx)
        let hi = Self.sample(kind: kind, index: min(idx + 1, segments))
        return lo + (hi - lo) * frac
    }

    private static func sample(kind: EasingKind, index: Int) -> Double {
        let t = Double(index) / Double(segments)
        switch kind {
        case .linear:
            return t
        case .easeIn:
            return cubicBezierY(t: t, x1: 0.42, y1: 0,    x2: 1,    y2: 1)
        case .easeOut:
            return cubicBezierY(t: t, x1: 0,    y1: 0,    x2: 0.58, y2: 1)
        case .easeInOut:
            return cubicBezierY(t: t, x1: 0.42, y1: 0,    x2: 0.58, y2: 1)
        case .cubicBezier(let x1, let y1, let x2, let y2):
            return cubicBezierY(t: t, x1: x1, y1: y1, x2: x2, y2: y2)
        }
    }

    // MARK: - Bézier solver

    /// Find y(t) for a 1D cubic Bézier defined by control-point ordinates.
    /// Solves x(s)=t via Newton-Raphson, then returns y(s).
    private static func cubicBezierY(
        t:  Double,
        x1: Double, y1: Double,
        x2: Double, y2: Double
    ) -> Double {
        var s = t
        for _ in 0..<4 {
            let x  = bezier3(s, x1, x2)
            let dx = bezier3Derivative(s, x1, x2)
            guard abs(dx) > 1e-9 else { break }
            s = s - (x - t) / dx
        }
        s = max(min(s, 1), 0)
        return bezier3(s, y1, y2)
    }

    @inline(__always)
    private static func bezier3(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
    }

    @inline(__always)
    private static func bezier3Derivative(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - s
        return 6 * u * s * (p2 - p1) + 3 * u * u * p1 + 3 * s * s * (1 - p2)
    }
}

// MARK: - EasingKind

/// Standalone easing curve enum that mirrors `KeyframeSet.Keyframe.Easing`
/// so the animation layer does not import the full model layer.
enum EasingKind: Hashable, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case cubicBezier(x1: Double, y1: Double, x2: Double, y2: Double)
}

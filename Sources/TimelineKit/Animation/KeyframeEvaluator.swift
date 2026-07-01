import Foundation
import CoreGraphics

// MARK: - KeyframeEvaluator

/// Stateless evaluator that computes a composite `CGAffineTransform` and opacity
/// from a `KeyframeSet` at a given local time (in seconds, 0…duration).
///
/// V6 Fix E: Time contract is **seconds within the segment**, not a 0…1 fraction.
/// Keyframes' `.time` field is already absolute seconds (matches `Keyframe.time`
/// doc comment), so `localTime` is compared to keyframe times directly. This
/// supports partial animations (keyframes that don't span the full segment) —
/// values past the last keyframe hold at the last value, instead of being
/// stretched to fit segment duration.
///
/// The transform chain follows the standard affine order:
///   position → anchor(in canvas px) → rotation → scale → translate(-anchor)
enum KeyframeEvaluator {

    /// Evaluate all keyframe dimensions at `localTime` (seconds within the
    /// segment, clamped to [0, duration]) and return the composite motion
    /// matrix + opacity.
    /// - Parameters:
    ///   - keyframes: full keyframe set (nil = identity transform)
    ///   - localTime: seconds since segment start
    ///   - canvasSize: canvas dimensions in points (for anchor pixel conversion)
    /// - Returns: (transform, opacity)
    static func evaluate(
        keyframes: KeyframeSet?,
        at localTime: Double,
        canvasSize: CGSize
    ) -> (transform: CGAffineTransform, opacity: Double) {
        guard let kf = keyframes, !kf.isEmpty else {
            return (.identity, 1.0)
        }

        let pos    = interpolate(points: kf.position, at: localTime) ?? .center
        let scl    = interpolate(points: kf.scale,    at: localTime) ?? 1.0
        let rot    = interpolate(points: kf.rotation, at: localTime) ?? 0.0
        let anchor = interpolate(points: kf.anchor,   at: localTime) ?? NormalizedPoint(x: 0.5, y: 0.5)
        let opacity = interpolate(points: kf.opacity, at: localTime) ?? 1.0

        let anchorPx = CGPoint(x: anchor.x * canvasSize.width,
                               y: anchor.y * canvasSize.height)
        let posPx    = CGPoint(x: pos.x * canvasSize.width,
                               y: pos.y * canvasSize.height)

        // Build "scale/rotate around anchor, then place anchor at pos":
        //   p' = s·(p − anchor) + pos   (for r=0)
        //
        // CGAffineTransform uses COLUMN vectors: t * p applies the rightmost
        // operation first. So to get T(pos)·S(s)·T(−anchor)·p we must build:
        //   t = T(pos) * S(scl) * R(rot) * T(-anchor)
        // .translatedBy right-concatenates Translate, so we build left-to-right.
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: posPx.x, y: posPx.y)
        t = t.scaledBy(x: CGFloat(scl), y: CGFloat(scl))
        t = t.rotated(by: CGFloat(rot))
        t = t.translatedBy(x: -anchorPx.x, y: -anchorPx.y)
//        #if DEBUG
//        print("[KFE] localTime=\(localTime) pos=\(pos) scale=\(scl) anchor=\(anchor)")
//        print("[KFE] anchorPx=\(anchorPx) posPx=\(posPx) transform=\(t)")
//        #endif
        return (t, opacity)
    }

    // MARK: - Interpolation

    /// Generic keyframe interpolator.
    ///
    /// V6 Fix E: `t` is local time in **seconds** within the segment. Compared
    /// directly to `Keyframe.time` (also seconds, per the model contract).
    /// Values clamp to the first / last keyframe when outside their span — so
    /// keyframes that finish before segment end hold at their last value.
    /// Returns nil if the track is empty.
    private static func interpolate<T: KeyframeInterpolatable>(
        points: [Keyframe<T>],
        at t: Double
    ) -> T? {
        guard !points.isEmpty else { return nil }
        // Sort once per evaluation — keyframes may be stored in any order by the user.
        let sorted = points.sorted { $0.time < $1.time }

        // Clamp to endpoints
        if t <= sorted[0].time { return sorted[0].value }
        if t >= sorted.last!.time { return sorted.last!.value }

        // Find surrounding pair
        for i in 0..<(sorted.count - 1) {
            if t >= sorted[i].time && t <= sorted[i + 1].time {
                let span   = sorted[i + 1].time - sorted[i].time
                let localT = span > 1e-9 ? (t - sorted[i].time) / span : 0
                let eased  = EasingLUT.evaluate(kind: sorted[i + 1].easing.easingKind, at: localT)
                return T.lerp(from: sorted[i].value, to: sorted[i + 1].value, t: eased)
            }
        }
        return sorted.last!.value
    }
}

// MARK: - Interpolatable Protocol

protocol KeyframeInterpolatable {
    static func lerp(from: Self, to: Self, t: Double) -> Self
}

extension Double: KeyframeInterpolatable {
    static func lerp(from: Double, to: Double, t: Double) -> Double {
        from + (to - from) * t
    }
}

extension NormalizedPoint: KeyframeInterpolatable {
    static func lerp(from: NormalizedPoint, to: NormalizedPoint, t: Double) -> NormalizedPoint {
        NormalizedPoint(
            x: Double.lerp(from: from.x, to: to.x, t: t),
            y: Double.lerp(from: from.y, to: to.y, t: t)
        )
    }
}

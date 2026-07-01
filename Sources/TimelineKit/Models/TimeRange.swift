import Foundation

/// A half-open time interval [start, end) in seconds, measured from the timeline origin.
/// All times in TimelineKit use this type — there are no scene-relative offsets.
public struct TimeRange: Sendable, Hashable, Codable {
    public var start: Double
    public var duration: Double

    public var end: Double { start + duration }

    public init(start: Double, duration: Double) {
        self.start = start
        self.duration = max(duration, 0)
    }

    public init(start: Double, end: Double) {
        self.start = start
        self.duration = max(end - start, 0)
    }

    public static let zero = TimeRange(start: 0, duration: 0)

    public func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }

    public func overlaps(_ other: TimeRange) -> Bool {
        start < other.end && end > other.start
    }

    public func union(_ other: TimeRange) -> TimeRange {
        TimeRange(start: min(start, other.start), end: max(end, other.end))
    }

    public func intersection(_ other: TimeRange) -> TimeRange? {
        let s = max(start, other.start)
        let e = min(end, other.end)
        guard s < e else { return nil }
        return TimeRange(start: s, end: e)
    }

    /// Returns a copy shifted by `delta` seconds.
    public func shifted(by delta: Double) -> TimeRange {
        TimeRange(start: start + delta, duration: duration)
    }

    /// Clamp duration so end does not exceed `limit`.
    public func clamped(end limit: Double) -> TimeRange {
        TimeRange(start: start, duration: max(0, min(duration, limit - start)))
    }
}

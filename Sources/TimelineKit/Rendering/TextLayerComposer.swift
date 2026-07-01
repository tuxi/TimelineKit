#if canImport(UIKit)
import CoreImage
import CoreMedia
import Foundation

// MARK: - TextLayerSpec

public struct TextLayerSpec: Sendable, Codable {
    public var segmentID: UUID
    public var timeRange: CMTimeRange
    public var zPosition: Int32
    public var baseOpacity: Float

    public init(
        segmentID: UUID,
        timeRange: CMTimeRange,
        zPosition: Int32,
        baseOpacity: Float = 1
    ) {
        self.segmentID = segmentID
        self.timeRange = timeRange
        self.zPosition = zPosition
        self.baseOpacity = baseOpacity
    }

    enum CodingKeys: String, CodingKey {
        case segmentID, timeRangeStart, timeRangeDuration, zPosition, baseOpacity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segmentID = try c.decode(UUID.self, forKey: .segmentID)
        let start = try c.decode(Double.self, forKey: .timeRangeStart)
        let duration = try c.decode(Double.self, forKey: .timeRangeDuration)
        timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        zPosition = try c.decode(Int32.self, forKey: .zPosition)
        baseOpacity = try c.decodeIfPresent(Float.self, forKey: .baseOpacity) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(segmentID, forKey: .segmentID)
        try c.encode(timeRange.start.seconds, forKey: .timeRangeStart)
        try c.encode(timeRange.duration.seconds, forKey: .timeRangeDuration)
        try c.encode(zPosition, forKey: .zPosition)
        try c.encode(baseOpacity, forKey: .baseOpacity)
    }
}

// MARK: - TextFrameProvider

final class TextFrameProvider: @unchecked Sendable {
    private var framesByID: [UUID: SubtitleRenderFrame] = [:]

    @MainActor
    func update(timeline: EditorTimeline, renderSize: CGSize) {
        let segments = Self.textSegments(timeline: timeline)
        let canvasShortSide = CGFloat(min(timeline.canvas.width, timeline.canvas.height))
        let renderShortSide = min(renderSize.width, renderSize.height)
        let fontScale = canvasShortSide > 0 ? renderShortSide / canvasShortSide : 1.0
        let frames = SubtitleFrameBuilder.build(
            segments: segments,
            renderSize: renderSize,
            totalDuration: max(timeline.duration, 0.1),
            fontScale: fontScale
        )
        framesByID = Dictionary(uniqueKeysWithValues: frames.map { ($0.segmentID, $0) })
    }

    func frame(for segmentID: UUID) -> SubtitleRenderFrame? {
        framesByID[segmentID]
    }

    func invalidate() {
        framesByID.removeAll()
    }

    private static func textSegments(timeline: EditorTimeline) -> [EditorSegment] {
        timeline.tracks
            .filter { !$0.isHidden && ($0.kind == .text || $0.kind == .subtitle) }
            .flatMap(\.segments)
            .filter {
                switch $0.content {
                case .text, .subtitle:
                    return true
                default:
                    return false
                }
            }
    }
}

// MARK: - TextLayerComposer

enum TextLayerComposer {
    nonisolated(unsafe) static var frameProvider: TextFrameProvider?

    static func evaluate(spec: TextLayerSpec, at compositionTime: CMTime) -> CIImage? {
        guard compositionTime >= spec.timeRange.start,
              compositionTime < spec.timeRange.end,
              let frame = frameProvider?.frame(for: spec.segmentID)
        else { return nil }

        let opacity = Double(spec.baseOpacity) * opacityForFrame(frame, at: compositionTime.seconds)
        guard opacity > 0 else { return nil }
        if opacity >= 0.999 {
            return frame.ciImage
        }
        return frame.ciImage.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        ])
    }

    private static func opacityForFrame(_ frame: SubtitleRenderFrame, at time: Double) -> Double {
        let fadeIn = max(frame.fadeInDuration, 0.001)
        let fadeOut = max(frame.fadeOutDuration, 0.001)
        if time < frame.startTime + frame.fadeInDuration {
            return max(0, min(1, (time - frame.startTime) / fadeIn))
        }
        if time > frame.endTime - frame.fadeOutDuration {
            return max(0, min(1, (frame.endTime - time) / fadeOut))
        }
        return 1
    }
}
#endif

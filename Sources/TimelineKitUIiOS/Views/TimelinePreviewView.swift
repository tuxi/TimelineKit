#if canImport(UIKit)
import UIKit
import AVFoundation
import CoreMedia
import CoreVideo
import SwiftUI

// MARK: - TimelinePreviewView

/// UIView that displays rendered `CVPixelBuffer` frames using `AVSampleBufferDisplayLayer`.
///
/// Used by the Timeline Runtime (V6 P1 — Stage 1-2) to present image-layer
/// composites at screen refresh rate, bypassing AVVideoCompositing entirely.
///
/// Usage:
/// ```swift
/// let view = TimelinePreviewView()
/// // ... add to view hierarchy ...
/// view.enqueue(pixelBuffer, presentationTime: cmTime)
/// ```
@MainActor
public final class TimelinePreviewView: UIView {

    // MARK: - Display layer

    private let sampleBufferLayer = AVSampleBufferDisplayLayer()

    /// PTS of the most recently enqueued sample. `AVSampleBufferDisplayLayer`
    /// schedules frames by presentationTimeStamp against its internal clock, so
    /// a sample whose PTS is far in the *past* (e.g. replay jumps from the
    /// timeline end back to 0 while playing) is silently dropped — freezing the
    /// preview. We track the last PTS to detect that backwards jump and flush
    /// the layer's timebase before enqueuing.
    private var lastEnqueuedPTS: CMTime?

    /// Backwards-jump threshold. Normal playback advances < 0.5 s per frame, so
    /// anything beyond this is a replay / large seek that requires a timebase
    /// reset rather than in-order scheduling.
    private let backwardsResetThreshold = CMTime(value: 1, timescale: 2) // 0.5 s

    // MARK: - Lifecycle

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        sampleBufferLayer.videoGravity          = .resizeAspect
        sampleBufferLayer.backgroundColor       = UIColor.black.cgColor
        sampleBufferLayer.contentsGravity       = .resizeAspect
        layer.addSublayer(sampleBufferLayer)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sampleBufferLayer.frame = bounds
        CATransaction.commit()
    }

    // MARK: - Public API

    /// Enqueue a rendered pixel buffer for immediate display.
    ///
    /// - Parameters:
    ///   - pixelBuffer:       The rendered frame.
    ///   - presentationTime:  The composition time corresponding to this frame.
    public func enqueue(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        enqueue(pixelBuffer, presentationTime: presentationTime, displayImmediately: false)
    }

    /// Replace the currently displayed frame immediately.
    ///
    /// Used by scrub/seek paths where presentation timestamps can jump
    /// backwards. The flush and enqueue happen together, and the sample is
    /// marked display-immediately to reduce visible black between the two.
    public func replace(with pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let sampleBuffer = makeSampleBuffer(
            pixelBuffer,
            at: presentationTime,
            displayImmediately: true
        ) else { return }

        sampleBufferLayer.flush()
        sampleBufferLayer.enqueue(sampleBuffer)
        lastEnqueuedPTS = presentationTime.isValid ? presentationTime : nil
    }

    private func enqueue(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        displayImmediately: Bool
    ) {
        // Detect a large backwards PTS jump (replay / seek-to-start while the
        // render loop is enqueuing). Without flushing, the layer keeps its old
        // (larger) timebase and discards every lower-PTS sample → frozen frame.
        var forceImmediate = displayImmediately
        if let last = lastEnqueuedPTS,
           last.isValid, presentationTime.isValid,
           presentationTime < last - backwardsResetThreshold {
            sampleBufferLayer.flush()
            forceImmediate = true
        }

        guard let sampleBuffer = makeSampleBuffer(
            pixelBuffer,
            at: presentationTime,
            displayImmediately: forceImmediate
        )
        else { return }

        // Recover from failed/interrupted layer state.
        if sampleBufferLayer.status == .failed {
            sampleBufferLayer.flush()
        }
        sampleBufferLayer.enqueue(sampleBuffer)
        if presentationTime.isValid { lastEnqueuedPTS = presentationTime }
    }

    /// Flush the display layer (e.g. after a timeline swap).
    public func flush() {
        sampleBufferLayer.flush()
        lastEnqueuedPTS = nil
    }

#if DEBUG
    public var debugStateDescription: String {
        let status: String
        switch sampleBufferLayer.status {
        case .unknown: status = "unknown"
        case .rendering: status = "rendering"
        case .failed: status = "failed"
        @unknown default: status = "unknown(\(sampleBufferLayer.status.rawValue))"
        }
        return "layerStatus=\(status) isReady=\(sampleBufferLayer.isReadyForMoreMediaData) error=\(sampleBufferLayer.error?.localizedDescription ?? "nil") bounds=\(bounds)"
    }
#endif

    // MARK: - Private

    private func makeSampleBuffer(
        _ pixelBuffer: CVPixelBuffer,
        at presentationTime: CMTime,
        displayImmediately: Bool = false
    ) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator:            nil,
            imageBuffer:          pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let formatDesc else { return nil }

        var timingInfo = CMSampleTimingInfo(
            duration:              .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp:       .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator:             nil,
            imageBuffer:           pixelBuffer,
            dataReady:             true,
            makeDataReadyCallback: nil,
            refcon:                nil,
            formatDescription:     formatDesc,
            sampleTiming:          &timingInfo,
            sampleBufferOut:       &sampleBuffer
        )
        guard let sampleBuffer else { return nil }
        if displayImmediately,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: true
           ),
           CFArrayGetCount(attachments) > 0,
           let attachment = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary?.self
           ) {
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}

// MARK: - SwiftUI Representable

/// Wraps `TimelinePreviewView` for embedding in SwiftUI hierarchies.
struct TimelinePreviewRepresentable: UIViewRepresentable {
    let previewView: TimelinePreviewView

    func makeUIView(context: Context) -> TimelinePreviewView {
        previewView
    }

    func updateUIView(_ uiView: TimelinePreviewView, context: Context) {
        // No-op: the view is driven imperatively via enqueue(_:presentationTime:).
    }
}

#endif

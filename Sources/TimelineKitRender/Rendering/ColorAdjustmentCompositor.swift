import TimelineKitCore
#if canImport(UIKit)
import AVFoundation
import CoreImage
import CoreMedia

// MARK: - ColorAdjustmentInstruction

/// Custom AVVideoCompositionInstruction carrying per-segment color adjustment data.
final class ColorAdjustmentInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange:            CMTimeRange
    var enablePostProcessing: Bool
    var containsTweening:     Bool = false

    /// Source track IDs the compositor needs pixel buffers from.
    var requiredSourceTrackIDs: [NSValue]? { [NSValue(nonretainedObject: sourceTrackID)] }
    /// No sample data tracks needed.
    var requiredSourceSampleDataTrackIDs: [CMPersistentTrackID] { [] }
    /// Not a passthrough instruction.
    var passthroughTrackID: CMPersistentTrackID { kCMPersistentTrackID_Invalid }

    let sourceTrackID: CMPersistentTrackID
    let segmentID:     UUID
    let adjustment:    SegmentAdjustment

    init(
        timeRange:     CMTimeRange,
        sourceTrackID: CMPersistentTrackID,
        segmentID:     UUID,
        adjustment:    SegmentAdjustment
    ) {
        self.timeRange            = timeRange
        self.sourceTrackID        = sourceTrackID
        self.segmentID            = segmentID
        self.adjustment           = adjustment
        self.enablePostProcessing = !adjustment.isIdentity
    }
}

// MARK: - ColorAdjustmentCompositor

/// Custom AVVideoCompositing that applies CIFilter-based color adjustments per segment.
///
/// Identity segments (isIdentity == true) short-circuit by returning the source pixel buffer
/// directly, matching v1 performance for unedited clips.
final class ColorAdjustmentCompositor: NSObject, AVVideoCompositing {

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instr = request.videoCompositionInstruction as? ColorAdjustmentInstruction else {
            request.finish(with: CompositorError.badInstruction)
            return
        }

        guard let pixelBuffer = request.sourceFrame(byTrackID: instr.sourceTrackID) else {
            request.finish(with: CompositorError.missingSourceFrame)
            return
        }

        guard !instr.adjustment.isIdentity else {
            request.finish(withComposedVideoFrame: pixelBuffer)
            return
        }

        guard let outputBuffer = request.renderContext.newPixelBuffer() else {
            request.finish(with: CompositorError.noOutputBuffer)
            return
        }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let result = applyAdjustments(instr.adjustment, to: source)
        ciContext.render(result, to: outputBuffer)
        request.finish(withComposedVideoFrame: outputBuffer)
    }

    func cancelAllPendingVideoCompositionRequests() {}

    // MARK: - CIFilter chain

    private func applyAdjustments(_ adj: SegmentAdjustment, to image: CIImage) -> CIImage {
        var result = image

        // CIColorControls — brightness / contrast / saturation
        if adj.brightness != 0 || adj.contrast != 1.0 || adj.saturation != 1.0 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: adj.brightness,
                kCIInputContrastKey:   adj.contrast,
                kCIInputSaturationKey: adj.saturation
            ])
        }

        // CITemperatureAndTint — white balance
        if adj.temperature != 6500 || adj.tint != 0 {
            result = result.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral":       CIVector(x: CGFloat(adj.temperature), y: CGFloat(adj.tint)),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        }

        // CIHighlightShadowAdjust — highlights / shadows
        // inputHighlightAmount: 0=recover, 1=preserve. Map adj.highlights: +1→recover, 0→identity, -1→boost.
        if adj.highlights != 0 || adj.shadows != 0 {
            result = result.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1.0 - adj.highlights,
                "inputShadowAmount":    adj.shadows
            ])
        }

        // Preset CIPhotoEffect filter with optional intensity blend
        if let preset = adj.filterName {
            let filtered = result.applyingFilter(preset.ciFilterName)
            if adj.filterIntensity >= 1.0 {
                result = filtered
            } else if adj.filterIntensity > 0 {
                // Blend: original * (1 - intensity) + filtered * intensity
                result = filtered.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: result,
                    kCIInputTimeKey:        1.0 - adj.filterIntensity
                ])
            }
        }

        return result
    }

    // MARK: - Errors

    private enum CompositorError: Error {
        case badInstruction, missingSourceFrame, noOutputBuffer
    }
}
#endif

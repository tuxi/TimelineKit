import TimelineKitCore
#if canImport(UIKit)
import AVFoundation
import CoreImage

// MARK: - SentinelAsset

/// Generates a minimal 16×16 black MP4 used to fill empty track regions at
/// image segment positions. Without sentinel frames the composition video track
/// has no media in those time ranges, and AVFoundation may skip calling the
/// custom compositor during continuous playback (seek is unaffected because it
/// forces a single-frame render).
///
/// The sentinel is a tiny H.264 file created once and cached to disk.
/// The file contains two frames (t=0 and t=1 s) so it has non-zero duration,
/// and `track.scaleTimeRange` stretches each insertion to match segment length.
enum SentinelAsset {
    private static let sentinelSize = 16

    private actor Cache {
        private var url: URL?
        func get() -> URL? { url }
        func set(_ u: URL) { url = u }
    }
    private static let cache = Cache()

    static func url() async throws -> URL {
        if let url = await cache.get(), FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("timelinekit_sentinel_16x16_v2.mp4")
        try? FileManager.default.removeItem(at: url)

        // H.264 hardware encoders on some iPad devices do not tolerate 1×1
        // frames. Use a macroblock-friendly 16×16 black frame; UnifiedCompositor
        // filters this sentinel by buffer size before compositing.
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, sentinelSize, sentinelSize,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ] as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pb else {
            throw SentinelError.pixelBufferFailed
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            base.initializeMemory(
                as: UInt8.self,
                repeating: 0,
                count: bytesPerRow * sentinelSize
            )
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: sentinelSize,
                AVVideoHeightKey: sentinelSize,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: nil
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw SentinelError.writerFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        // Write two transparent frames (t=0 and t=1s) so the MP4 track has
        // a [0, 1] timeRange with non-zero duration for scaleTimeRange.
        let t0 = CMTime(seconds: 0, preferredTimescale: 600)
        let t1 = CMTime(seconds: 1, preferredTimescale: 600)
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        adaptor.append(pixelBuffer, withPresentationTime: t0)
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        adaptor.append(pixelBuffer, withPresentationTime: t1)
        input.markAsFinished()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed {
                    cont.resume()
                } else {
                    cont.resume(throwing: SentinelError.writerFailed(writer.error))
                }
            }
        }

        await cache.set(url)
        return url
    }

    enum SentinelError: Error {
        case pixelBufferFailed
        case writerFailed(Error?)
    }
}
#endif

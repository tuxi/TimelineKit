import TimelineKitRender
import Foundation
import AVFoundation

/// Extracts the audio track from a video file into an m4a (AAC) file.
///
/// V3 audio-feature-spec §2.2: PHPicker .videos → AudioExtractor → addAudioSegment.
/// Implementation mirrors [StaticImageRenderer] — actor-isolated pull loop using
/// `AVAssetReader` (PCM 44.1 kHz / 16-bit stereo) → `AVAssetWriter` (m4a / AAC 256 kbps).
/// Honors `Task.cancel()` and reports progress in `[0, 1]`.
public actor AudioExtractor {

    public static let shared = AudioExtractor()

    public enum Failure: Swift.Error, LocalizedError {
        case noAudioTrack
        case readerSetupFailed(any Error)
        case writerSetupFailed(any Error)
        case cancelled
        case underlying(any Error)

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack:             return "该视频不包含音频轨道"
            case .readerSetupFailed(let e): return "解码器初始化失败：\(e.localizedDescription)"
            case .writerSetupFailed(let e): return "编码器初始化失败：\(e.localizedDescription)"
            case .cancelled:                return "已取消"
            case .underlying(let e):        return e.localizedDescription
            }
        }
    }

    /// Extract audio from `videoURL` and write it to `outputURL` (must be writable).
    /// - Returns: actual duration of the produced m4a in seconds.
    @discardableResult
    public func extract(
        from videoURL: URL,
        to outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Double {
        let asset = AVURLAsset(url: videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else { throw Failure.noAudioTrack }
        let totalDuration = (try? await asset.load(.duration).seconds) ?? 0

        // Reader: decode to PCM (16-bit interleaved stereo, 44.1 kHz)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Failure.readerSetupFailed(error)
        }
        let pcmSettings: [String: Any] = [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVSampleRateKey:             44_100,
            AVNumberOfChannelsKey:       2,
            AVLinearPCMBitDepthKey:      16,
            AVLinearPCMIsFloatKey:       false,
            AVLinearPCMIsBigEndianKey:   false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
        guard reader.canAdd(readerOutput) else {
            throw Failure.readerSetupFailed(NSError(domain: "AudioExtractor", code: 1))
        }
        reader.add(readerOutput)

        // Writer: AAC m4a, 256 kbps stereo
        try? FileManager.default.removeItem(at: outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        } catch {
            throw Failure.writerSetupFailed(error)
        }
        let aacSettings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey:       44_100,
            AVEncoderBitRateKey:   256_000
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw Failure.writerSetupFailed(NSError(domain: "AudioExtractor", code: 2))
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw Failure.readerSetupFailed(reader.error ?? NSError(domain: "AudioExtractor", code: 3))
        }
        guard writer.startWriting() else {
            throw Failure.writerSetupFailed(writer.error ?? NSError(domain: "AudioExtractor", code: 4))
        }
        writer.startSession(atSourceTime: .zero)

        // Pull-loop on the actor — no external dispatch queue, no @Sendable closures.
        // If writer is back-pressured, yield briefly and retry. Cancellation is honored.
        pullLoop: while true {
            if Task.isCancelled {
                reader.cancelReading()
                writerInput.markAsFinished()
                writer.cancelWriting()
                throw Failure.cancelled
            }
            if !writerInput.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms back-off
                continue
            }
            guard let sample = readerOutput.copyNextSampleBuffer() else {
                break pullLoop  // EOF or reader error — verified below
            }
            if !writerInput.append(sample) {
                reader.cancelReading()
                writerInput.markAsFinished()
                writer.cancelWriting()
                throw Failure.underlying(writer.error ?? NSError(domain: "AudioExtractor", code: 5))
            }
            if let progress, totalDuration > 0 {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                progress(max(0, min(1, pts / totalDuration)))
            }
        }

        writerInput.markAsFinished()

        if reader.status != .completed {
            writer.cancelWriting()
            throw Failure.underlying(reader.error ?? NSError(domain: "AudioExtractor", code: 7))
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            writer.finishWriting {
                if writer.status == .completed {
                    cont.resume()
                } else {
                    cont.resume(throwing: Failure.underlying(
                        writer.error ?? NSError(domain: "AudioExtractor", code: 6)
                    ))
                }
            }
        }

        if let progress { progress(1.0) }

        // Probe the produced file's duration so segment timing matches reality.
        let produced = AVURLAsset(url: outputURL)
        let producedDur = (try? await produced.load(.duration).seconds) ?? totalDuration
        return producedDur
    }
}

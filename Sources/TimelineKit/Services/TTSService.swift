import Foundation
import AVFoundation
import CommonCrypto

/// V3 tts-spec §5.1: client-side text-to-speech synthesis using Apple's offline
/// `AVSpeechSynthesizer.write(_:toBufferCallback:)`. Produces m4a/AAC files keyed
/// by sha1(text + voice + rate) and stored in the cross-timeline TTS pool
/// `Assets/_shared/tts/{key}.m4a` (see AssetDownloadManager).
public actor TTSService {

    public static let shared = TTSService()

    public enum Failure: Swift.Error, LocalizedError {
        case voiceNotAvailable
        case writeFailed(any Error)
        case noOutput
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .voiceNotAvailable: return "无可用语音包"
            case .writeFailed(let e): return "音频写入失败：\(e.localizedDescription)"
            case .noOutput:           return "合成无输出"
            case .cancelled:          return "已取消"
            }
        }
    }

    /// V3 limits voice picker to 2 stable choices. We resolve to a concrete system
    /// `AVSpeechSynthesisVoice` at synthesis time; identifier strings are stored on
    /// disk via `TTSSource.voice` for stable round-trip.
    public enum VoiceKind: String, Sendable, CaseIterable, Codable {
        case female = "zh-CN-female"
        case male   = "zh-CN-male"

        public var displayName: String {
            switch self {
            case .female: return "女声"
            case .male:   return "男声"
            }
        }

        /// Picks the best-matching system voice for this kind. Falls back to
        /// any zh-* voice, finally to system default zh-CN.
        public func resolveSystemVoice() -> AVSpeechSynthesisVoice? {
            let all = AVSpeechSynthesisVoice.speechVoices()
            let zh  = all.filter { $0.language.hasPrefix("zh") }
            let preferred: AVSpeechSynthesisVoiceGender = (self == .male) ? .male : .female
            return zh.first(where: { $0.gender == preferred })
                ?? zh.first
                ?? AVSpeechSynthesisVoice(language: "zh-CN")
        }
    }

    /// SHA-1 hash of trimmed text (used as `TTSSource.textHash` for stale detection).
    public static func textHash(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha1Hex(Data(normalized.utf8))
    }

    /// Stable cache key = sha1(text + voice + rate). Hits across timelines so the
    /// same content with the same voice / rate only synthesizes once.
    public static func cacheKey(text: String, voice: String, rate: Double) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = "\(normalized)|\(voice)|\(String(format: "%.2f", rate))"
        return sha1Hex(Data(raw.utf8))
    }

    /// SHA-1 → lowercase hex string. Uses CommonCrypto so no extra dependency
    /// is required (swift-crypto is not in TimelineKit's Package.swift deps).
    private static func sha1Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Public API

    /// Offline synthesize the given text into an m4a file. Returns the file URL
    /// and the produced audio's real duration.
    /// - If the same `(text, voice, rate)` was synthesized before, returns the
    ///   cached file with no actual rendering work.
    /// - Throws `Failure.cancelled` when the surrounding `Task` is cancelled.
    public func synthesize(
        text: String,
        voice voiceID: String,
        rate: Double
    ) async throws -> (url: URL, duration: Double) {
        let key = Self.cacheKey(text: text, voice: voiceID, rate: rate)
        let outputURL = try AssetDownloadManager.shared.reserveSharedTTSURL(key: key)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            // Cache hit — verify with a duration probe in case the file is corrupt.
            let asset = AVURLAsset(url: outputURL)
            let dur = (try? await asset.load(.duration).seconds) ?? 0
            if dur > 0 { return (outputURL, dur) }
            try? FileManager.default.removeItem(at: outputURL)
        }

        // Resolve voice; fall back to system default zh-CN if identifier is unknown.
        let resolvedVoice = AVSpeechSynthesisVoice(identifier: voiceID)
                         ?? AVSpeechSynthesisVoice(language: "zh-CN")
        guard let avVoice = resolvedVoice else { throw Failure.voiceNotAvailable }

        try await synthesizeToFile(
            text: text,
            voice: avVoice,
            userRate: rate,
            outputURL: outputURL
        )

        let asset = AVURLAsset(url: outputURL)
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        if dur <= 0 {
            try? FileManager.default.removeItem(at: outputURL)
            throw Failure.noOutput
        }
        return (outputURL, dur)
    }

    // MARK: - Core renderer

    /// Runs AVSpeechSynthesizer.write(...) and pipes PCM buffers into AVAudioFile.
    /// The synth instance is captured strongly inside the callback `[synth]` to
    /// guarantee it outlives the async write — without this Swift ARC would dealloc
    /// the synth as soon as the outer scope returns, killing in-flight callbacks.
    private func synthesizeToFile(
        text: String,
        voice: AVSpeechSynthesisVoice,
        userRate: Double,
        outputURL: URL
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // Map user-facing rate (0.5..2.0, 1.0 = natural) → AVSpeechUtterance.rate.
        // AVSpeechUtteranceDefaultSpeechRate represents "natural" on the system scale.
        let mappedRate = Float(userRate) * AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate,
                             min(AVSpeechUtteranceMaximumSpeechRate, mappedRate))

        let synth = AVSpeechSynthesizer()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            // `audioFile` and `didFinish` must be reference-typed for the callback
            // (which can be invoked many times) to share state. Box them.
            let box = WriteState()
            synth.write(utterance) { [synth] buffer in
                _ = synth  // explicit strong capture so synth outlives outer scope
                guard !box.didFinish else { return }

                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    box.didFinish = true
                    cont.resume(throwing: Failure.noOutput)
                    return
                }

                if pcm.frameLength == 0 {
                    // Synthesis complete (empty trailing buffer marks EOS).
                    box.didFinish = true
                    let hadContent = box.file != nil
                    // Critical: release the AVAudioFile NOW so its deinit flushes the
                    // buffered audio to disk synchronously. If we leave `box.file` alive
                    // and just call `cont.resume()`, the caller's `AVURLAsset.load(.duration)`
                    // runs against a file that hasn't been finalized yet (returns 0s, or
                    // FileManager reports it doesn't exist). AVAudioFile finalizes its
                    // ExtAudioFileRef only on dealloc — there is no explicit close API.
                    box.file = nil
                    if hadContent {
                        cont.resume()
                    } else {
                        cont.resume(throwing: Failure.noOutput)
                    }
                    return
                }

                if Task.isCancelled {
                    box.didFinish = true
                    box.file = nil  // flush whatever was written so far
                    cont.resume(throwing: Failure.cancelled)
                    return
                }

                if box.file == nil {
                    // Lazily create file on first PCM buffer — format only known here.
                    // AVSpeechSynthesizer typically outputs 22050 Hz mono. AAC bit-rate
                    // limits depend on (sampleRate × channels), so a hard-coded 128 kbps
                    // for mono speech is REJECTED by AudioConverter
                    // (`kAudioConverterEncodeBitRate` error 560226676).
                    // Quality-based settings let the encoder pick a compatible bitrate.
                    let settings: [String: Any] = [
                        AVFormatIDKey:             kAudioFormatMPEG4AAC,
                        AVSampleRateKey:           pcm.format.sampleRate,
                        AVNumberOfChannelsKey:     pcm.format.channelCount,
                        AVEncoderAudioQualityKey:  AVAudioQuality.medium.rawValue
                    ]
                    do {
                        box.file = try AVAudioFile(forWriting: outputURL, settings: settings)
                    } catch {
                        box.didFinish = true
                        cont.resume(throwing: Failure.writeFailed(error))
                        return
                    }
                }
                do {
                    try box.file?.write(from: pcm)
                } catch {
                    box.didFinish = true
                    box.file = nil  // flush + release partial file
                    cont.resume(throwing: Failure.writeFailed(error))
                }
            }
        }
    }
}

// MARK: - Callback state box

/// Reference-typed state shared across the AVSpeechSynthesizer.write callback
/// invocations. AVAudioFile must persist across many callback calls.
private final class WriteState: @unchecked Sendable {
    var file: AVAudioFile?
    var didFinish: Bool = false
}

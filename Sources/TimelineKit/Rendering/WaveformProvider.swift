#if canImport(UIKit)
import AVFoundation
import UIKit

/// Async waveform data generator for audio assets.
///
/// Concurrency design mirrors ThumbnailProvider: one generator per URL, in-flight cap
/// prevents AVFoundation queue saturation during bulk waveform requests.
actor WaveformProvider {

    static let shared = WaveformProvider()

    /// Number of amplitude samples per waveform.
    static let sampleCount = 200

    // MARK: - Cache

    private var cache: [URL: [Float]] = [:]

    // MARK: - Concurrency gate

    private let maxInFlight = 2
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.purge() }
        }
    }

    // MARK: - Public

    /// Returns normalized amplitude samples (0…1) for the audio at `url`.
    /// Returns nil if the asset has no readable audio track.
    func waveform(for url: URL) async -> [Float]? {
        if let hit = cache[url] { return hit }

        await acquireSlot()
        defer { releaseSlot() }

        if let hit = cache[url] { return hit }

        let samples = await decodeWaveform(url: url, count: Self.sampleCount)
        if let s = samples { cache[url] = s }
        return samples
    }

    func purge() {
        cache.removeAll()
    }

    func removeCache(for url: URL) {
        cache.removeValue(forKey: url)
    }

    // MARK: - Concurrency gate

    private func acquireSlot() async {
        if inFlight < maxInFlight {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseSlot() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            inFlight -= 1
        }
    }

    // MARK: - Decode

    private nonisolated func decodeWaveform(url: URL, count: Int) async -> [Float]? {
        // AVAssetReader only works with local file URLs.
        // Use AssetDownloadManager so the file is cached persistently — subsequent
        // calls (same session or across restarts) hit disk instead of the network.
        let localURL: URL
        if url.isFileURL {
            localURL = url
        } else {
            guard let cached = try? await AssetDownloadManager.shared.localURL(for: url) else {
                return nil
            }
            localURL = cached
        }

        let asset = AVURLAsset(url: localURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            return nil
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1
        ])
        reader.add(output)
        reader.startReading()

        // Collect all sample buffers.
        var allData = Data()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length,
                                        totalLengthOut: nil, dataPointerOut: &pointer)
            if let ptr = pointer {
                allData.append(UnsafeBufferPointer(start: ptr, count: length))
            }
        }

        guard allData.count >= 2 else { return nil }

        // Interpret as Int16 samples and compute amplitude envelope.
        let samples = allData.withUnsafeBytes { ptr -> [Int16] in
            Array(ptr.bindMemory(to: Int16.self))
        }
        guard !samples.isEmpty else { return nil }

        let bucketSize = max(1, samples.count / count)
        var waveform = [Float](repeating: 0, count: count)

        for i in 0..<count {
            let start = i * bucketSize
            let end   = min(start + bucketSize, samples.count)
            guard start < end else { break }
            // Use `magnitude` (UInt16) instead of `abs` to avoid trapping on
            // Int16.min (= -32768): abs(-32768) would overflow Int16.max (32767)
            // and crash on Swift's signed-numeric `-prefix` trap. Real-world audio
            // (especially extracted from loud videos) routinely clips to Int16.min.
            var peak: UInt16 = 0
            for j in start..<end {
                let absVal = samples[j].magnitude  // UInt16, lossless
                if absVal > peak { peak = absVal }
            }
            waveform[i] = Float(peak) / 32768.0
        }

        return waveform
    }
}
#endif

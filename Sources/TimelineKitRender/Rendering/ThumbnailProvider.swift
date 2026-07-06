import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import CoreGraphics
import ImageIO

public extension Notification.Name {
    static let thumbnailProviderDidPurge = Notification.Name("TimelineKit.thumbnailProviderDidPurge")
}

/// Wrapper so CGImage can be stored in NSCache.
private final class ThumbnailImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Async thumbnail generator for video and image assets.
public actor ThumbnailProvider {

    static public let shared = ThumbnailProvider()

    // MARK: - Cache

    private let cache = NSCache<NSString, ThumbnailImage>()

    // MARK: - Generator pool (one per URL)

    private var generators: [URL: AVAssetImageGenerator] = [:]

    // MARK: - Concurrency gate

    private let maxInFlight = 5
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private let maxRetries = 2
    private let retryDelaysMs: [UInt64] = [0, 100, 250]

    // MARK: - Init

    init() {
        cache.totalCostLimit = 50 * 1_024 * 1_024  // 50 MB
#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.purge() }
        }
#endif
    }

    // MARK: - Public

    /// Returns a thumbnail CGImage for the asset at `url`.
    /// - Parameters:
    ///   - isImage: true → decode as still image; false → use AVAssetImageGenerator
    ///   - time: source timestamp (seconds) — ignored for image assets
    ///   - size: maximum pixel dimensions (2× backing recommended for Retina)
    public func thumbnail(for url: URL, isImage: Bool, at time: Double, size: CGSize) async -> CGImage? {
        let key = cacheKey(url: url, time: isImage ? 0 : time, size: size)
        if let hit = cache.object(forKey: key) { return hit.image }

        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delayNs = retryDelaysMs[attempt] * 1_000_000
                try? await Task.sleep(nanoseconds: delayNs)
                if let hit = cache.object(forKey: key) { return hit.image }
            }

            await acquireSlot()
            let result: CGImage?
            if isImage {
                result = await imageThumb(url: url, size: size)
            } else {
                result = await videoThumb(url: url, at: time, size: size)
            }
            releaseSlot()

            if let img = result {
                let cost = Int(img.width * img.height * 4)
                cache.setObject(ThumbnailImage(img), forKey: key, cost: cost)
                return img
            }

            if !isImage { generators.removeValue(forKey: url) }
        }
        return nil
    }

    public func purge() {
        cache.removeAllObjects()
        generators.removeAll()
        Task { @MainActor in
            NotificationCenter.default.post(name: .thumbnailProviderDidPurge, object: nil)
        }
    }

    public func removeCache(for url: URL) {
        cache.removeAllObjects()
        generators.removeValue(forKey: url)
    }

    // MARK: - Concurrency gate helpers

    private func acquireSlot() async {
        if inFlight < maxInFlight {
            inFlight += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseSlot() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            inFlight -= 1
        }
    }

    // MARK: - Thumb generation

    private func imageThumb(url: URL, size: CGSize) async -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return coverCropped(image, to: size)
    }

    private func videoThumb(url: URL, at time: Double, size: CGSize) async -> CGImage? {
        let gen = generator(for: url, size: size)
        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)

        return await withCheckedContinuation { continuation in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: cmTime)]) { _, image, _, result, _ in
                guard result == .succeeded, let image else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    private func generator(for url: URL, size: CGSize) -> AVAssetImageGenerator {
        if let existing = generators[url] { return existing }
        let asset = AVURLAsset(url: url,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = size
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter  = CMTime(seconds: 1.0, preferredTimescale: 600)
        generators[url] = gen
        return gen
    }

    // MARK: - Cache key

    private func cacheKey(url: URL, time: Double, size: CGSize) -> NSString {
        "\(url.absoluteString)_t\(String(format: "%.3f", time))_\(Int(size.width))x\(Int(size.height))" as NSString
    }
}

// MARK: - CGImage cover-crop helper

private func coverCropped(_ image: CGImage, to size: CGSize) -> CGImage? {
    guard size.width > 0, size.height > 0 else { return nil }
    let imgW = CGFloat(image.width), imgH = CGFloat(image.height)
    guard imgW > 0, imgH > 0 else { return nil }

    let scale = max(size.width / imgW, size.height / imgH)
    let scaledW = imgW * scale, scaledH = imgH * scale
    let originX = -(scaledW - size.width) / 2
    let originY = -(scaledH - size.height) / 2

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: Int(size.width), height: Int(size.height),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: originX, y: originY, width: scaledW, height: scaledH))
    return ctx.makeImage()
}
#endif

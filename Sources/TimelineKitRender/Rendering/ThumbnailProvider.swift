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

#if canImport(AppKit)
    /// macOS memory-pressure watcher (DISPATCH_SOURCE_TYPE_MEMORYPRESSURE).
    /// AppKit has no memory-warning notification on modern SDKs.
    private let memoryPressureSource = DispatchSource.makeMemoryPressureSource(
        eventMask: [.warning, .critical],
        queue: .main
    )
#endif

    // MARK: - Generator pool (one per URL + output size)

    /// Keyed by URL AND requested maximum size. A generator created for a smaller
    /// `maximumSize` would silently cap later, larger requests at the stale
    /// resolution — and because cache keys include size, that wrong-resolution
    /// frame would be cached under the larger key. Pooling per size prevents this.
    private var generators: [String: AVAssetImageGenerator] = [:]

    private func generatorKey(url: URL, size: CGSize) -> String {
        "\(url.absoluteString)|\(Int(size.width))x\(Int(size.height))"
    }

    private func removeGenerators(for url: URL) {
        let prefix = url.absoluteString + "|"
        generators = generators.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Concurrency gate

    private let maxInFlight = 5
    private var inFlight = 0
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    private let maxRetries = 2
    private let retryDelaysMs: [UInt64] = [0, 100, 250]

    // MARK: - In-flight coalescing

    /// Waiters attached to an identical (url, time, size, aspectFill) request that
    /// is currently being generated. The leader resumes every waiter when it
    /// finishes and removes the entry. A waiter whose own task is cancelled is
    /// still resumed — cancellation of one waiter can never cancel the generation
    /// or strand the remaining waiters.
    private var pendingRequests: [NSString: [CheckedContinuation<CGImage?, Never>]] = [:]

    /// Counts actual generation attempts (slot acquisitions). Test hook proving
    /// coalescing: N identical concurrent requests → 1 generation.
    private(set) var generationCount = 0

    /// Number of keys currently coalescing requests. Test hook for cleanup.
    var pendingRequestKeyCount: Int { pendingRequests.count }

    /// Number of pooled generators. Test hook for per-size pooling.
    var debugGeneratorCount: Int { generators.count }

    // MARK: - Init

    public init() {
        cache.totalCostLimit = 50 * 1_024 * 1_024  // 50 MB
#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.purge() }
        }
#elseif canImport(AppKit)
        memoryPressureSource.setEventHandler { [weak self] in
            Task { await self?.purge() }
        }
        memoryPressureSource.resume()
#endif
    }

    // MARK: - Public

    /// Returns a thumbnail CGImage for the asset at `url`.
    /// - Parameters:
    ///   - isImage: true → decode as still image; false → use AVAssetImageGenerator
    ///   - time: source timestamp (seconds) — ignored for image assets
    ///   - size: maximum pixel dimensions (2× backing recommended for Retina)
    ///   - aspectFill: true → the returned image is cover-cropped to exactly
    ///     `size` (stable aspect-fill, e.g. project covers at 16:9 buckets).
    ///     false keeps the historical behavior (images cropped, videos
    ///     aspect-fitted within `size`).
    ///
    /// Identical concurrent requests (same url/time/size/aspectFill) are
    /// coalesced into a single generation; all callers receive its result.
    public func thumbnail(for url: URL, isImage: Bool, at time: Double, size: CGSize,
                          aspectFill: Bool = false) async -> CGImage? {
        let key = cacheKey(url: url, time: isImage ? 0 : time, size: size, aspectFill: aspectFill)
        if let hit = cache.object(forKey: key) { return hit.image }

        // Joiner path: a generation for this exact key is already running.
        // Appending happens synchronously in the actor, before suspension.
        if pendingRequests[key] != nil {
            return await withCheckedContinuation { continuation in
                pendingRequests[key, default: []].append(continuation)
            }
        }

        // Leader path: claim the key before any suspension so later duplicates
        // join instead of starting a second generation.
        pendingRequests[key] = []
        let result = await generate(url: url, isImage: isImage, time: time,
                                    size: size, aspectFill: aspectFill, key: key)
        drainPendingRequests(for: key, result: result)
        return result
    }

    /// The single generation loop for the leader of `key`. Never checks the
    /// leader task's cancellation: it must always finish so every attached
    /// waiter is resumed exactly once and the pending entry is cleaned up.
    private func generate(url: URL, isImage: Bool, time: Double, size: CGSize,
                          aspectFill: Bool, key: NSString) async -> CGImage? {
        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delayNs = retryDelaysMs[attempt] * 1_000_000
                try? await Task.sleep(nanoseconds: delayNs)
                if let hit = cache.object(forKey: key) { return hit.image }
            }

            await acquireSlot()
            generationCount += 1
            let raw: CGImage?
            if isImage {
                raw = await imageThumb(url: url, size: size)
            } else {
                raw = await videoThumb(url: url, at: time, size: size)
            }
            releaseSlot()

            var result = raw
            if isImage == false, aspectFill, let raw {
                result = Self.coverCropped(raw, to: size)
            }

            if let img = result {
                let cost = Int(img.width * img.height * 4)
                cache.setObject(ThumbnailImage(img), forKey: key, cost: cost)
                return img
            }

            if !isImage { removeGenerators(for: url) }
        }
        return nil
    }

    /// Resumes all attached waiters with the leader's result and removes the
    /// pending entry. Safe to call even when no waiter ever joined.
    private func drainPendingRequests(for key: NSString, result: CGImage?) {
        let waiters = pendingRequests.removeValue(forKey: key) ?? []
        for waiter in waiters {
            waiter.resume(returning: result)
        }
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
        removeGenerators(for: url)
    }

    // MARK: - Concurrency gate helpers

    private func acquireSlot() async {
        if inFlight < maxInFlight {
            inFlight += 1
            return
        }
        await withCheckedContinuation { continuation in
            gateWaiters.append(continuation)
        }
    }

    private func releaseSlot() {
        if let next = gateWaiters.first {
            gateWaiters.removeFirst()
            next.resume()
        } else {
            inFlight -= 1
        }
    }

    // MARK: - Thumb generation

    private func imageThumb(url: URL, size: CGSize) async -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // kCGImageSourceCreateThumbnailWithTransform：自动应用 EXIF orientation
        // （竖拍照片像素是横的，不应用会得到横屏缩略图）。
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return Self.coverCropped(image, to: size)
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
        let key = generatorKey(url: url, size: size)
        if let existing = generators[key] { return existing }
        let asset = AVURLAsset(url: url,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = size
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter  = CMTime(seconds: 1.0, preferredTimescale: 600)
        generators[key] = gen
        return gen
    }

    // MARK: - Cache key

    private func cacheKey(url: URL, time: Double, size: CGSize, aspectFill: Bool) -> NSString {
        "\(url.absoluteString)_t\(String(format: "%.3f", time))_\(Int(size.width))x\(Int(size.height))_\(aspectFill ? "fill" : "fit")" as NSString
    }

    // MARK: - CGImage cover-crop helper

    /// Aspect-fill (cover) crop: scale to fill `size`, then center-crop.
    /// Deterministic and stable — the same source always yields the same crop.
    nonisolated static func coverCropped(_ image: CGImage, to size: CGSize) -> CGImage? {
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
}

// MARK: - Fixed pixel-size buckets

/// Fixed 16:9 pixel buckets for cover-style thumbnails.
///
/// Callers snap their requested size to a bucket so small layout changes
/// (window drag, dynamic type, split-view nudges) do NOT produce new cache
/// keys and re-trigger generation. Buckets are exact 16:9 integer sizes.
public enum ThumbnailPixelBucket {
    /// Ascending 16:9 bucket widths (px). Heights are width × 9/16.
    public static let widthBuckets: [Int] = [256, 384, 512, 768, 1024]

    /// Smallest bucket whose width covers `pixelWidth`; largest bucket above that.
    public static func size(forPixelWidth pixelWidth: CGFloat) -> CGSize {
        let target = max(1, Int(pixelWidth.rounded(.up)))
        let width = widthBuckets.first(where: { $0 >= target }) ?? widthBuckets.last!
        let height = Int((CGFloat(width) * 9.0 / 16.0).rounded())
        return CGSize(width: width, height: height)
    }

    /// Bucket for a view displayed at `points` wide on a `scale`× display.
    public static func size(forDisplayWidth points: CGFloat, scale: CGFloat) -> CGSize {
        size(forPixelWidth: points * max(1, scale))
    }
}
#endif

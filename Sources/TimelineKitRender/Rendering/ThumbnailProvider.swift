#if canImport(UIKit)
import AVFoundation
import CoreMedia
import UIKit

public extension Notification.Name {
    /// V5.1 BUG 4: 内存警告触发 cache 全量清空后广播此通知，让所有
    /// ThumbnailStripView 主动 re-load 当前可见 segment 的缩略图，
    /// 避免 purge 后用户一直看到紫色 fallback 色块。
    static let thumbnailProviderDidPurge = Notification.Name("TimelineKit.thumbnailProviderDidPurge")
}

/// Async thumbnail generator for video and image assets.
///
/// Concurrency design
/// ──────────────────
/// Each call to `thumbnail(for:)` is actor-isolated so cache reads/writes are
/// data-race–free.  Two additional guards prevent AVFoundation queue saturation:
///
/// 1. **Generator reuse** — one `AVAssetImageGenerator` is kept per URL.
///    Creating a generator per tile would cause AVFoundation to open N decode
///    sessions simultaneously, flooding `generateimagesasyncqueue`.
///
/// 2. **In-flight cap** — at most `maxInFlight` (= 3) concurrent image
///    generation calls are allowed.  Excess callers suspend inside the actor
///    until a slot is released; slot ownership is transferred (not double-counted)
///    so the count never exceeds the cap.
public actor ThumbnailProvider {

    static public let shared = ThumbnailProvider()

    // MARK: - Cache

    private let cache = NSCache<NSString, UIImage>()

    // MARK: - Generator pool (one per URL)

    private var generators: [URL: AVAssetImageGenerator] = [:]

    // MARK: - Concurrency gate

    // V5.1 BUG 4: 3 → 5。iPad 大屏或多 segment 场景下 3-slot 容易堆积；
    // 5-slot 在并发能力与 AVFoundation 队列压力之间更平衡。
    private let maxInFlight = 5
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // V5.1 BUG 4: 失败重试上限（首次 + maxRetries 次重试 = 共 maxRetries+1 次尝试）。
    private let maxRetries = 2
    /// 重试退避（毫秒）：100ms / 250ms。第 0 次为首次尝试，无 sleep。
    private let retryDelaysMs: [UInt64] = [0, 100, 250]

    // MARK: - Init

    init() {
        cache.totalCostLimit = 50 * 1_024 * 1_024  // 50 MB
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.purge() }
        }
    }

    // MARK: - Public

    /// Returns a thumbnail UIImage for the asset at `url`.
    /// - Parameters:
    ///   - isImage: true → decode as UIImage; false → use AVAssetImageGenerator
    ///   - time: source timestamp (seconds) — ignored for image assets
    ///   - size: maximum pixel dimensions (2× backing recommended for Retina)
    public func thumbnail(for url: URL, isImage: Bool, at time: Double, size: CGSize) async -> UIImage? {
        let key = cacheKey(url: url, time: isImage ? 0 : time, size: size)
        if let hit = cache.object(forKey: key) { return hit }

        // V5.1 BUG 4: 失败重试 + 指数退避。退避 sleep 在 releaseSlot 之后执行，
        // 不占用并发 slot；视频生成失败时丢弃坏掉的 generator，让下次重试重建。
        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delayNs = retryDelaysMs[attempt] * 1_000_000
                try? await Task.sleep(nanoseconds: delayNs)
                if let hit = cache.object(forKey: key) { return hit }
            }

            await acquireSlot()
            let result: UIImage?
            if isImage {
                result = await imageThumb(url: url, size: size)
            } else {
                result = await videoThumb(url: url, at: time, size: size)
            }
            releaseSlot()

            if let img = result {
                let cost = Int(img.size.width * img.size.height * 4)
                cache.setObject(img, forKey: key, cost: cost)
                return img
            }

            // 视频生成失败时丢弃当前 generator，避免坏掉的 AVAssetImageGenerator
            // 反复返回 nil 让重试也无效。
            if !isImage { generators.removeValue(forKey: url) }
        }
        return nil
    }

    public func purge() {
        cache.removeAllObjects()
        generators.removeAll()
        // V5.1 BUG 4: 广播 purge 事件，让 ThumbnailStripView 主动重新加载可见 segment 缩略图。
        // hop 到 main 发送通知，订阅方在主线程响应即可。
        Task { @MainActor in
            NotificationCenter.default.post(name: .thumbnailProviderDidPurge, object: nil)
        }
    }

    /// Evict all cached thumbnails for `url` and discard its generator.
    /// Call this before replacing an asset so the strip fetches fresh frames.
    public func removeCache(for url: URL) {
        cache.removeAllObjects()   // NSCache has no key enumeration; full purge is safe.
        generators.removeValue(forKey: url)
    }

    // MARK: - Concurrency gate helpers

    /// Acquire one in-flight slot.  If all slots are busy the caller suspends
    /// until a slot is released (transferred directly — not decremented/incremented).
    private func acquireSlot() async {
        if inFlight < maxInFlight {
            inFlight += 1
            return
        }
        // Suspend and wait for a slot to be transferred to us.
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        // Slot has been transferred by releaseSlot(); inFlight is unchanged.
    }

    /// Release a slot.  If waiters are queued the slot is transferred to the
    /// first waiter (inFlight stays the same); otherwise it is decremented.
    private func releaseSlot() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()           // slot ownership transferred — inFlight unchanged
        } else {
            inFlight -= 1
        }
    }

    // MARK: - Thumb generation

    private func imageThumb(url: URL, size: CGSize) async -> UIImage? {
        guard let data = try? Data(contentsOf: url),
              let src  = UIImage(data: data) else { return nil }
        return src.coverCropped(to: size)
    }

    private func videoThumb(url: URL, at time: Double, size: CGSize) async -> UIImage? {
        let gen = generator(for: url, size: size)
        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)

        // Use the callback-based API instead of the async `image(at:)` overload.
        // `image(at:)` is a nonisolated async method, and Swift 6 refuses to send
        // the actor-isolated, non-Sendable `gen` across the isolation boundary.
        // `generateCGImagesAsynchronously` is a plain synchronous call (void return)
        // that fires a completion handler on AVFoundation's internal queue — no actor
        // boundary crossing, no Sendable requirement.
        return await withCheckedContinuation { continuation in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: cmTime)]) { _, image, _, result, _ in
                guard result == .succeeded, let image else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: UIImage(cgImage: image))
            }
        }
    }


    /// Returns a cached generator for `url`, creating one if needed.
    /// Reusing the same generator for all tiles of a video keeps AVFoundation's
    /// internal decode session open and prevents queue explosion.
    private func generator(for url: URL, size: CGSize) -> AVAssetImageGenerator {
        if let existing = generators[url] { return existing }
        let asset = AVURLAsset(url: url,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = size
        // Generous tolerance so nearby timestamps reuse the same decoded frame.
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter  = CMTime(seconds: 1.0, preferredTimescale: 600)
        generators[url] = gen
        return gen
    }

    // MARK: - Cache key

    private func cacheKey(url: URL, time: Double, size: CGSize) -> NSString {
        // V5.1 BUG 4: 用完整 absoluteString 替代 lastPathComponent，避免
        // 不同目录下同名文件互相覆盖、切换 asset 时串图。
        "\(url.absoluteString)_t\(String(format: "%.3f", time))_\(Int(size.width))x\(Int(size.height))" as NSString
    }
}

// MARK: - UIImage cover-crop helper

private extension UIImage {
    /// Resizes and center-crops the image to exactly fill `size` (like CSS background-size: cover).
    func coverCropped(to size: CGSize) -> UIImage? {
        guard size.width > 0, size.height > 0,
              self.size.width > 0, self.size.height > 0 else { return nil }
        let scale = max(size.width / self.size.width, size.height / self.size.height)
        let scaledSize = CGSize(width: self.size.width * scale, height: self.size.height * scale)
        let origin = CGPoint(x: -(scaledSize.width  - size.width)  / 2,
                             y: -(scaledSize.height - size.height) / 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: origin, size: scaledSize))
        }
    }
}
#endif

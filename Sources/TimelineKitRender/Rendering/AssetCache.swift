import Foundation
#if canImport(AVFoundation)
import AVFoundation

/// URLAsset cache — one instance per process.
/// NSCache evicts under memory pressure; the cache only holds asset *descriptors*
/// (no decoded frames), so each entry is small (~10 KB).
public final class AssetCache: @unchecked Sendable {

    static public let shared = AssetCache()

    private let cache = NSCache<NSString, AVURLAsset>()
    private let lock  = NSLock()

    private init() {
        cache.totalCostLimit = 20 * 1_024 * 1_024  // 20 MB (metadata only)
#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(memoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
#endif
    }

    public func asset(for url: URL) -> AVURLAsset {
        let key = url.absoluteString as NSString
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache.object(forKey: key) { return hit }
        let fresh = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        cache.setObject(fresh, forKey: key, cost: 10_000)
        return fresh
    }

    /// Called on background/foreground transition — releases decoded frame data
    /// without destroying the asset descriptor.
    public func purgeDecodedCache() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAllObjects()
    }

    @objc private func memoryWarning() {
        purgeDecodedCache()
    }
}
#endif

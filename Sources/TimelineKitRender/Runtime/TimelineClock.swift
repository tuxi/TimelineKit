#if canImport(UIKit)
import Foundation
import QuartzCore

// MARK: - TimelineClock

/// Drives the Timeline Runtime rendering loop via `CADisplayLink`.
///
/// Fires `onTick` on every screen refresh while started.
/// The coordinator reads `player.currentTime()` inside `onTick` to obtain the
/// current composition time — no separate time tracking needed here.
///
/// Lifecycle:
///   - `start()` — add display link to the main run loop.
///   - `stop()`  — invalidate and remove the display link.
///   - deinit    — automatically invalidates the display link.
@MainActor
public final class TimelineClock {

    // MARK: - Public

    /// Called on each CADisplayLink fire (main actor, ~60 fps).
    public var onTick: (() -> Void)?

    // MARK: - Private

    // nonisolated(unsafe): deinit is nonisolated; CADisplayLink.invalidate() is thread-safe.
    nonisolated(unsafe) private var displayLink: CADisplayLink?

    // MARK: - Lifecycle

    public init() {}

    deinit {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Public API

    /// Start firing `onTick` at screen refresh rate. Idempotent.
    public func start() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy(target: self)
        let link  = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Stop the display link (e.g. when switching to AVPlayer path or view disappears).
    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Internal (called by proxy on main thread)

    fileprivate func handleTick() {
        onTick?()
    }
}

// MARK: - DisplayLinkProxy

/// `@MainActor` weak-proxy that breaks the `CADisplayLink → target` retain cycle.
/// Both `TimelineClock` and this proxy are `@MainActor`, so passing `self` between
/// them is safe under Swift 6 strict concurrency. `CADisplayLink` fires on the main
/// run loop, which is the main actor's executor, so `@objc func tick()` always runs
/// in the correct actor context.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var target: TimelineClock?

    init(target: TimelineClock) {
        self.target = target
    }

    @objc func tick() {
        target?.handleTick()
    }
}

#endif

import XCTest
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import TimelineKitRender

/// Project-cover behavior for `ThumbnailProvider`: fixed 16:9 pixel buckets,
/// stable aspect-fill crop, in-flight coalescing with safe cancellation and
/// completion-state cleanup, and per-size generator pooling.
final class ThumbnailProviderCoverTests: XCTestCase {

    // MARK: - Helpers

    /// Solid-color PNG written to a temp file.
    private func makeTestImageURL(width: Int, height: Int) throws -> URL {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tlk_cover_img_\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// Single-frame H.264 video whose rows form three horizontal bands:
    /// top = red, middle = green, bottom = blue. A center crop must keep the
    /// green band — this makes the crop position observable.
    private func makeBandedVideoURL(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tlk_cover_vid_\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, nil, &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else {
            throw NSError(domain: "test", code: 11)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw NSError(domain: "test", code: 11)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
                // BGRA byte order.
                if y < height / 3 { p[0] = 30; p[1] = 30; p[2] = 200 }        // red band
                else if y < (height * 2) / 3 { p[0] = 30; p[1] = 200; p[2] = 30 } // green band
                else { p[0] = 200; p[1] = 30; p[2] = 30 }                     // blue band
                p[3] = 255
            }
        }
        var readyPolls = 0
        while !input.isReadyForMoreMediaData && readyPolls < 500 {
            usleep(2_000)
            readyPolls += 1
        }
        XCTAssertTrue(adaptor.append(buffer, withPresentationTime: .zero))
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 0.1, preferredTimescale: 600))

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == AVAssetWriter.Status.completed else {
            throw NSError(domain: "test", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "video write failed: \(String(describing: writer.error))"])
        }
        return url
    }

    /// Samples one pixel (top-left origin) of a CGImage as RGB 0–255.
    private func sampledPixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.flush()
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    private func makeBandedCGImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // CGContext origin is bottom-left; bands top→bottom = red/green/blue.
        let cw = CGFloat(width), ch = CGFloat(height)
        let band = ch / 3.0
        ctx.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 2 * band, width: cw, height: band))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: band, width: cw, height: band))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: band))
        return ctx.makeImage()!
    }

    // MARK: - Pixel buckets

    func testBucketIsExact16By9() {
        for width in ThumbnailPixelBucket.widthBuckets {
            let size = ThumbnailPixelBucket.size(forPixelWidth: CGFloat(width))
            XCTAssertEqual(Int(size.width), width)
            XCTAssertEqual(size.height * 16, size.width * 9, "bucket \(width) must be exactly 16:9")
        }
    }

    func testBucketSnapsToNextLargerFixedSize() {
        XCTAssertEqual(ThumbnailPixelBucket.size(forPixelWidth: 256), CGSize(width: 256, height: 144))
        XCTAssertEqual(ThumbnailPixelBucket.size(forPixelWidth: 257), CGSize(width: 384, height: 216))
        XCTAssertEqual(ThumbnailPixelBucket.size(forPixelWidth: 600), CGSize(width: 768, height: 432))
        // Above the largest bucket the request is capped, not unbounded.
        XCTAssertEqual(ThumbnailPixelBucket.size(forPixelWidth: 4000), CGSize(width: 1024, height: 576))
    }

    func testBucketStableAcrossSmallLayoutChanges() {
        // 1pt layout jitter must not change the bucket (no re-generation).
        for points in [300.0, 300.5, 301, 305, 310, 315] {
            XCTAssertEqual(
                ThumbnailPixelBucket.size(forDisplayWidth: CGFloat(points), scale: 2),
                CGSize(width: 768, height: 432),
                "width \(points)@2x should stay in the 768 bucket"
            )
        }
        for points in [100.0, 101, 102] {
            XCTAssertEqual(
                ThumbnailPixelBucket.size(forDisplayWidth: CGFloat(points), scale: 2),
                CGSize(width: 256, height: 144)
            )
        }
    }

    func testBucketMonotonicAcrossWidthRange() {
        var previousWidth = 0
        for points in stride(from: 1.0, through: 1200.0, by: 1.0) {
            let size = ThumbnailPixelBucket.size(forDisplayWidth: CGFloat(points), scale: 2)
            XCTAssertGreaterThanOrEqual(size.width, CGFloat(previousWidth),
                                        "buckets must never shrink as width grows")
            previousWidth = Int(size.width)
        }
    }

    // MARK: - Aspect-fill crop

    func testCoverCropKeepsCenterBandAtExactSize() {
        let portrait = makeBandedCGImage(width: 180, height: 320)
        let cropped = ThumbnailProvider.coverCropped(portrait, to: CGSize(width: 320, height: 180))
        XCTAssertNotNil(cropped)
        guard let cropped else { return }
        XCTAssertEqual(cropped.width, 320)
        XCTAssertEqual(cropped.height, 180)
        // Center of a portrait source under a cover crop = the middle band (green).
        let center = sampledPixel(cropped, x: 160, y: 90)
        XCTAssertNotNil(center)
        if let center {
            XCTAssertGreaterThan(center.g, center.r, "center crop must keep the middle band (got \(center))")
            XCTAssertGreaterThan(center.g, center.b, "center crop must keep the middle band (got \(center))")
        }
    }

    func testCoverCropIsDeterministic() {
        let source = makeBandedCGImage(width: 180, height: 320)
        let a = ThumbnailProvider.coverCropped(source, to: CGSize(width: 320, height: 180))
        let b = ThumbnailProvider.coverCropped(source, to: CGSize(width: 320, height: 180))
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        if let a, let b, let pa = sampledPixel(a, x: 10, y: 90), let pb = sampledPixel(b, x: 10, y: 90) {
            XCTAssertEqual(Double(pa.r), Double(pb.r), accuracy: 2)
            XCTAssertEqual(Double(pa.g), Double(pb.g), accuracy: 2)
            XCTAssertEqual(Double(pa.b), Double(pb.b), accuracy: 2)
        }
    }

    func testImageAspectFillReturnsExactBucketSize() async throws {
        let url = try makeTestImageURL(width: 200, height: 600)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = ThumbnailProvider()
        let size = CGSize(width: 320, height: 180)
        let image = await provider.thumbnail(for: url, isImage: true, at: 0, size: size, aspectFill: true)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 320)
        XCTAssertEqual(image?.height, 180)
    }

    func testVideoAspectFillReturnsExactBucketSizeWithCenterFrame() async throws {
        let url = try makeBandedVideoURL(width: 180, height: 320)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = ThumbnailProvider()
        let size = CGSize(width: 320, height: 180)
        let image = await provider.thumbnail(for: url, isImage: false, at: 0, size: size, aspectFill: true)
        XCTAssertNotNil(image)
        guard let image else { return }
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 180)
        if let center = sampledPixel(image, x: 160, y: 90) {
            XCTAssertGreaterThan(center.g, center.r, "video cover crop must keep the middle band (got \(center))")
            XCTAssertGreaterThan(center.g, center.b, "video cover crop must keep the middle band (got \(center))")
        }
    }

    /// Legacy behavior guard: `aspectFill == false` must NOT crop videos —
    /// existing callers (track strips, browser media panel) keep their frames.
    func testVideoWithoutAspectFillKeepsPortraitAspect() async throws {
        let url = try makeBandedVideoURL(width: 180, height: 320)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = ThumbnailProvider()
        let image = await provider.thumbnail(for: url, isImage: false, at: 0,
                                             size: CGSize(width: 320, height: 180))
        XCTAssertNotNil(image)
        if let image {
            XCTAssertGreaterThan(image.height, image.width,
                                 "non-aspectFill video thumbs keep their native aspect (fit)")
        }
    }

    /// Root-cause fix: generators are pooled per URL *and* size. Two sizes for
    /// the same URL must not share a stale `maximumSize` generator.
    func testGeneratorsPooledPerRequestedSize() async throws {
        let url = try makeBandedVideoURL(width: 320, height: 180)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = ThumbnailProvider()
        let small = await provider.thumbnail(for: url, isImage: false, at: 0,
                                             size: CGSize(width: 320, height: 180), aspectFill: true)
        let large = await provider.thumbnail(for: url, isImage: false, at: 0,
                                             size: CGSize(width: 640, height: 360), aspectFill: true)
        XCTAssertNotNil(small)
        XCTAssertNotNil(large)
        XCTAssertEqual(small?.width, 320)
        XCTAssertEqual(large?.width, 640)
        let pooled = await provider.debugGeneratorCount
        XCTAssertEqual(pooled, 2, "each requested size must get its own generator")
    }

    // MARK: - In-flight coalescing

    func testConcurrentIdenticalRequestsProduceOneGeneration() async throws {
        let url = try makeBandedVideoURL(width: 320, height: 180)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = ThumbnailProvider()
        let size = CGSize(width: 320, height: 180)
        async let a = provider.thumbnail(for: url, isImage: false, at: 0, size: size, aspectFill: true)
        async let b = provider.thumbnail(for: url, isImage: false, at: 0, size: size, aspectFill: true)
        async let c = provider.thumbnail(for: url, isImage: false, at: 0, size: size, aspectFill: true)
        let (ra, rb, rc) = await (a, b, c)
        XCTAssertNotNil(ra)
        XCTAssertNotNil(rb)
        XCTAssertNotNil(rc)
        let count = await provider.generationCount
        XCTAssertEqual(count, 1, "identical concurrent requests must coalesce into a single generation")
        let pending = await provider.pendingRequestKeyCount
        XCTAssertEqual(pending, 0, "pending state must be cleaned up after completion")
    }

    /// Deterministic waiter-path test: a failing video request retries with
    /// 100ms/250ms sleeps, so concurrent duplicates attach as waiters while the
    /// leader is between attempts. Without coalescing each caller would retry
    /// independently (2 callers → 6 generations); with coalescing there is
    /// exactly one leader (3 generations) and both callers get its result.
    func testCoalescedFailuresShareRetriesAndCleanUp() async {
        let url = URL(fileURLWithPath: "/nonexistent/tlk_cover_missing_\(UUID().uuidString).mp4")
        let provider = ThumbnailProvider()
        let size = CGSize(width: 320, height: 180)
        async let a = provider.thumbnail(for: url, isImage: false, at: 0, size: size, aspectFill: true)
        async let b = provider.thumbnail(for: url, isImage: false, at: 0, size: size, aspectFill: true)
        let (ra, rb) = await (a, b)
        XCTAssertNil(ra)
        XCTAssertNil(rb)
        let count = await provider.generationCount
        XCTAssertEqual(count, 3, "leader-only retries: 3 attempts, not 3 per waiter")
        let pending = await provider.pendingRequestKeyCount
        XCTAssertEqual(pending, 0, "pending state must be cleaned up after failure")
    }

    /// A cancelled waiter must still be resumed by the leader and must not
    /// cancel the generation for the other (uncancelled) waiter.
    func testCancelledWaiterDoesNotStrandOrCancelOthers() async throws {
        let url = try makeBandedVideoURL(width: 320, height: 180)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = ThumbnailProvider()
        let size = CGSize(width: 320, height: 180)

        let leader = Task {
            await provider.thumbnail(for: url, isImage: false, at: 0, size: size, aspectFill: true)
        }
        // Let the leader claim the key and enter generation.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let joiner = Task {
            await provider.thumbnail(for: url, isImage: false, at: 0, size: size, aspectFill: true)
        }
        joiner.cancel()

        let leaderResult = await leader.value
        let joinerResult = await joiner.value
        XCTAssertNotNil(leaderResult, "generation must complete despite a cancelled waiter")
        XCTAssertNotNil(joinerResult, "a cancelled waiter is still resumed exactly once")
        let count = await provider.generationCount
        XCTAssertEqual(count, 1)
        let pending = await provider.pendingRequestKeyCount
        XCTAssertEqual(pending, 0)
    }

    /// Different aspectFill flags are different requests (different cache
    /// keys); they must not collide.
    func testAspectFillAndLegacyRequestsDoNotCollide() async throws {
        let url = try makeBandedVideoURL(width: 320, height: 180)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = ThumbnailProvider()
        let size = CGSize(width: 320, height: 180)
        let filled = await provider.thumbnail(for: url, isImage: false, at: 0, size: size, aspectFill: true)
        let fitted = await provider.thumbnail(for: url, isImage: false, at: 0, size: size)
        XCTAssertEqual(filled?.width, 320)
        XCTAssertEqual(filled?.height, 180)
        XCTAssertNotNil(fitted)
        let count = await provider.generationCount
        XCTAssertEqual(count, 2, "aspectFill and legacy variants are separate cache entries")
    }
}

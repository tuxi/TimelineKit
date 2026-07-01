#if canImport(UIKit)
import AVFoundation
import CoreImage
import CoreVideo
import UIKit

/// Converts a static/animated image segment into a local MP4 for AVMutableComposition.
///
/// Rendering uses CIImage + CIContext, identical to TimelineCompositionPlayer's
/// ImageVideoGenerator, so coordinate handling and motion transforms are correct.
///
/// Motion strategy:
///   - No motion (nil preset, nil depthEffect): 1 fps — minimal encoding cost.
///   - motionPreset / depthEffect present: full fps — per-frame zoom/pan keyframes.
///
/// Results are cached by a stable key (URL + content hash + duration + size).
actor StaticImageRenderer {

    static let shared = StaticImageRenderer()

    private var cache: [String: URL] = [:]
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Public

    func render(
        imageURL:     URL,
        imageContent: SegmentContent.ImageContent,
        duration:     Double,
        fps:          Double,
        renderSize:   CGSize
    ) async throws -> URL {
        let key = cacheKey(url: imageURL, content: imageContent,
                           duration: duration, fps: fps, size: renderSize)
        if let cached = cache[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let cgImage = try await downloadCGImage(from: imageURL)

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("img_\(key).mp4")

        try await writeVideo(
            cgImage:      cgImage,
            imageContent: imageContent,
            to:           outURL,
            duration:     duration,
            fps:          fps,
            renderSize:   renderSize
        )
        cache[key] = outURL
        return outURL
    }

    // MARK: - Errors

    enum RendererError: Error {
        case downloadFailed
        case writerSetupFailed
        case writingFailed(Error?)
    }

    // MARK: - Private: cache key

    private func cacheKey(
        url: URL, content: SegmentContent.ImageContent,
        duration: Double, fps: Double, size: CGSize
    ) -> String {
        let motion = content.motionPreset?.rawValue ?? content.depthEffect?.moveDirection ?? "static"
        let raw = "\(url.lastPathComponent)_\(motion)_d\(String(format:"%.2f",duration))_\(Int(size.width))x\(Int(size.height))"
        return raw.replacingOccurrences(of: "/", with: "_")
    }

    // MARK: - Private: download

    private func downloadCGImage(from url: URL) async throws -> CGImage {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (d, _) = try await URLSession.shared.data(from: url)
            data = d
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw RendererError.downloadFailed
        }
        return img
    }

    // MARK: - Private: video writer

    private func writeVideo(
        cgImage:      CGImage,
        imageContent: SegmentContent.ImageContent,
        to outURL:    URL,
        duration:     Double,
        fps:          Double,
        renderSize:   CGSize
    ) async throws {
        try? FileManager.default.removeItem(at: outURL)

        let hasMotion = imageContent.motionPreset != nil || imageContent.depthEffect != nil
        let writeFPS  = hasMotion ? fps : 1.0

        guard let writer = try? AVAssetWriter(outputURL: outURL, fileType: .mp4) else {
            throw RendererError.writerSetupFailed
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(renderSize.width),
            kCVPixelBufferHeightKey as String: Int(renderSize.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pbAttrs
        )
        writer.add(input)

        guard writer.startWriting() else { throw RendererError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)
        guard adaptor.pixelBufferPool != nil else {
            writer.cancelWriting()
            throw RendererError.writerSetupFailed
        }

        // ── Base cover-fit scale (same math as ImageVideoGenerator) ──────────
        let imageSize  = CGSize(width: cgImage.width, height: cgImage.height)
        let scaleX     = renderSize.width  / imageSize.width
        let scaleY     = renderSize.height / imageSize.height
        let isContain  = imageContent.fit == .contain
        let baseScale  = isContain ? min(scaleX, scaleY) : max(scaleX, scaleY)

        // Safety margin: pan/zoom motions shift the image; ensure edges stay covered.
        let motionIntensity: Double = {
            if let d = imageContent.depthEffect { return d.intensity }
            return 0.15
        }()
        let safeScale  = max(baseScale,
            (renderSize.width  + 2 * renderSize.width  * motionIntensity) / imageSize.width,
            (renderSize.height + 2 * renderSize.height * motionIntensity) / imageSize.height)

        let scaledW    = imageSize.width  * safeScale
        let scaledH    = imageSize.height * safeScale
        let baseCenterX = (scaledW - renderSize.width)  / 2
        let baseCenterY = (scaledH - renderSize.height) / 2

        let ciImage    = CIImage(cgImage: cgImage)
        let totalFrames = max(2, Int(ceil(duration * writeFPS)))
        let timescale   = CMTimeScale(600)

        // Render all evenly-spaced frames plus a sentinel at exactly `duration`.
        // The sentinel guarantees the MP4 container records a duration ≥ `duration`
        // even if AVAssetWriter's last-sample implied duration falls short by a tick.
        var presentationTimes: [CMTime] = (0..<totalFrames).map {
            CMTime(seconds: Double($0) / writeFPS, preferredTimescale: timescale)
        }
        let sentinelTime = CMTime(seconds: duration, preferredTimescale: timescale)
        if sentinelTime > (presentationTimes.last ?? .zero) {
            presentationTimes.append(sentinelTime)
        }

        for (frameIdx, presentationTime) in presentationTimes.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard !Task.isCancelled else { writer.cancelWriting(); return }

            // Normalised t in [0,1] — sentinel reuses t=1.0 (last motion keyframe).
            let rawT  = totalFrames > 1 ? Double(min(frameIdx, totalFrames - 1)) / Double(totalFrames - 1) : 0
            let t     = easeOut(rawT)

            // ── Base transform: scale to cover, then center ──────────────────
            var transform = CGAffineTransform.identity
                .scaledBy(x: safeScale, y: safeScale)
                .translatedBy(x: -baseCenterX, y: -baseCenterY)

            // ── Motion layer on top ──────────────────────────────────────────
            transform = applyMotion(
                transform:   transform,
                t:           t,
                content:     imageContent,
                renderSize:  renderSize
            )

            let frameImage = ciImage
                .transformed(by: transform)
                .cropped(to: CGRect(origin: .zero, size: renderSize))

            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess,
                  let buffer = pb else { continue }

            ciContext.render(frameImage, to: buffer)
            adaptor.append(buffer, withPresentationTime: presentationTime)
        }

        input.markAsFinished()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed {
                    cont.resume()
                } else {
                    cont.resume(throwing: RendererError.writingFailed(writer.error))
                }
            }
        }
    }

    // MARK: - Motion transform

    private func applyMotion(
        transform:  CGAffineTransform,
        t:          Double,           // eased, 0…1
        content:    SegmentContent.ImageContent,
        renderSize: CGSize
    ) -> CGAffineTransform {
        var tf = transform
        let intensity = content.depthEffect.map { CGFloat($0.intensity) } ?? 0.15

        // motionPreset takes priority; fall back to depthEffect direction
        let direction: String? = {
            if let p = content.motionPreset { return p.rawValue }
            return content.depthEffect?.moveDirection.lowercased()
        }()

        switch direction {
        case "zoom_in", "forward":
            let s = 1.0 + intensity * CGFloat(t)
            tf = tf.scaledBy(x: s, y: s)
            tf = compensateCenter(tf, renderSize: renderSize, extraScale: s)

        case "zoom_out", "backward":
            let s = 1.0 + intensity * (1.0 - CGFloat(t))
            tf = tf.scaledBy(x: s, y: s)
            tf = compensateCenter(tf, renderSize: renderSize, extraScale: s)

        case "zoom_in_slow":
            let s = 1.0 + (intensity * 0.5) * CGFloat(t)
            tf = tf.scaledBy(x: s, y: s)
            tf = compensateCenter(tf, renderSize: renderSize, extraScale: s)

        case "pan_left", "left":
            tf = tf.translatedBy(x: -intensity * renderSize.width * CGFloat(t), y: 0)

        case "pan_right", "right":
            tf = tf.translatedBy(x:  intensity * renderSize.width * CGFloat(t), y: 0)

        case "pan_up", "up":
            tf = tf.translatedBy(x: 0, y: -intensity * renderSize.height * CGFloat(t))

        case "pan_down", "down":
            tf = tf.translatedBy(x: 0, y:  intensity * renderSize.height * CGFloat(t))

        default:
            break
        }
        return tf
    }

    /// Translate back to keep the zoomed image centered in the output rect.
    private func compensateCenter(
        _ transform:  CGAffineTransform,
        renderSize:   CGSize,
        extraScale s: CGFloat
    ) -> CGAffineTransform {
        let ox = (renderSize.width  * (s - 1)) / 2
        let oy = (renderSize.height * (s - 1)) / 2
        return transform.translatedBy(x: -ox, y: -oy)
    }

    // MARK: - Easing

    private func easeOut(_ t: Double) -> Double {
        1.0 - pow(1.0 - t, 2)
    }
}
#endif

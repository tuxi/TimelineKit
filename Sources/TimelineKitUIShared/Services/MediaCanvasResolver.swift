import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import TimelineKitCore

/// Shared by project creation and imports into an existing empty editor.
/// Dimensions describe the displayed image, including EXIF/video rotation.
public enum MediaCanvasResolver {
    public static func canvas(for url: URL, fallbackFrameRate: Int = 30) async -> EditorCanvas? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let type = CGImageSourceGetType(source),
           UTType(type as String)?.conforms(to: .image) == true,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0 {
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let rotated = (5...8).contains(orientation)
            return normalized(
                width: rotated ? height : width, height: rotated ? width : height,
                fps: fallbackFrameRate
            )
        }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let displayed = size.applying(transform)
        guard displayed.width.isFinite, displayed.height.isFinite,
              abs(displayed.width) >= 1, abs(displayed.height) >= 1 else { return nil }
        let rate = (try? await track.load(.nominalFrameRate)) ?? 0
        let fps = rate.isFinite && rate > 0 ? Int(rate.rounded()).clamped(to: 10...120) : fallbackFrameRate
        return normalized(width: Int(abs(displayed.width)), height: Int(abs(displayed.height)), fps: fps)
    }

    private static func normalized(width: Int, height: Int, fps: Int) -> EditorCanvas {
        EditorCanvas(width: max(2, width - width % 2), height: max(2, height - height % 2), fps: fps)
    }
}

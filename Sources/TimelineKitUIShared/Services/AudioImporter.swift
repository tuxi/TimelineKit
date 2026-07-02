import Foundation
import AVFoundation

/// Copies a user-picked local audio file into the TimelineKit asset cache.
///
/// V3 audio-feature-spec §2.3: DocumentPicker (UTType.audio) → AudioImporter →
/// addAudioSegment. The picked URL is a security-scoped temporary reference from
/// the system picker; we must copy its contents into a stable location before
/// the picker's scope ends.
public actor AudioImporter {

    public static let shared = AudioImporter()

    public enum Failure: Swift.Error, LocalizedError {
        case unsupportedFormat
        case copyFailed(any Error)
        case noAudioTrack
        case scopedAccessDenied

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat:   return "不支持的音频格式"
            case .copyFailed(let e):   return "拷贝音频文件失败：\(e.localizedDescription)"
            case .noAudioTrack:        return "选择的文件不包含音频轨道"
            case .scopedAccessDenied:  return "无法访问该音频文件"
            }
        }
    }

    /// Copy a user-picked audio file to `outputURL` and return its real duration.
    ///
    /// `pickedURL` may be security-scoped (DocumentPicker returns such URLs). The
    /// caller is responsible for invoking `startAccessingSecurityScopedResource`
    /// *before* calling and `stopAccessingSecurityScopedResource` *after* awaiting.
    /// We never hold the scope across actor hops.
    @discardableResult
    public func `import`(
        from pickedURL: URL,
        to outputURL: URL
    ) async throws -> Double {
        // Sanity check: file must exist and be probe-able.
        guard FileManager.default.fileExists(atPath: pickedURL.path) else {
            throw Failure.scopedAccessDenied
        }

        // Probe before copying so unsupported formats fail fast.
        let probeAsset = AVURLAsset(url: pickedURL)
        let audioTracks = (try? await probeAsset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else { throw Failure.noAudioTrack }

        do {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.copyItem(at: pickedURL, to: outputURL)
        } catch {
            throw Failure.copyFailed(error)
        }

        let producedAsset = AVURLAsset(url: outputURL)
        let dur = (try? await producedAsset.load(.duration).seconds) ?? 0
        return dur
    }
}

#if canImport(UIKit)
import Foundation
import PhotosUI
import SwiftUI

/// Owns only the temporary copies created while loading a Photos selection.
/// Both project creation and editor imports preserve the user's selection order.
@MainActor
struct EditorMediaSelection {
    var urls: [URL] = []

    func removeTemporaryCopies() {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    static func load(_ items: [PhotosPickerItem]) async -> EditorMediaSelection {
        var selection = EditorMediaSelection()
        for item in items {
            if let movie = try? await item.loadTransferable(type: VideoTransferable.self) {
                selection.urls.append(movie.url)
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                do {
                    try data.write(to: url)
                    selection.urls.append(url)
                } catch { continue }
            }
        }
        return selection
    }
}
#endif

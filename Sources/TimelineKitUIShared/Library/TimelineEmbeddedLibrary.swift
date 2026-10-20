//
//  TimelineEmbeddedLibrary.swift
//  TimelineKitUIShared
//
//  Compatibility bridge for embedders that still own an EditorStore and a
//  preloaded timeline. It maps that timeline onto a stable, single-project
//  .tlkbundle so the library-driven editor keeps working without the host
//  having to manage a library UI.
//

import Foundation
import TimelineKitCore

@available(*, deprecated, message: "Temporary compatibility bridge; remove after Dreamlog migrates to library-driven LibraryProject storage.")
@MainActor
public enum TimelineEmbeddedLibrary {

    /// Opens (or creates) the embedded bundle for `timeline.id`, writes the
    /// supplied timeline as its single project, and returns both.
    public static func openOrCreate(
        for timeline: EditorTimeline,
        name: String = "Embedded Project"
    ) throws -> (store: TimelineLibraryStore, project: LibraryProject) {
        let store = TimelineLibraryStore()
        let bundleURL = try bundleURL(for: timeline.id)
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            try store.openLibrary(at: bundleURL)
        } else {
            try FileManager.default.createDirectory(
                at: bundleURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try store.createLibrary(at: bundleURL, name: name)
        }

        let project = LibraryProject(id: timeline.id, name: name, timeline: timeline)
        _ = try store.saveProject(project)
        return (store, project)
    }

    public static func bundleURL(for timelineID: UUID) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("TimelineKit/EmbeddedLibraries", isDirectory: true)
            .appendingPathComponent("\(timelineID.uuidString).tlkbundle", isDirectory: true)
    }
}

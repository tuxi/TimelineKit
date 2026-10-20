import Foundation
import XCTest
import TimelineKitCore
@testable import TimelineKitUIShared

@MainActor
final class LibraryPersistenceTests: XCTestCase {
    func testSingleProjectBundleRoundTripKeepsProjectAndTimelineIdentity() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("timelinekit-\(UUID().uuidString).tlkbundle", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let library = try TimelineLibrary.create(at: bundleURL, name: "Test Library")
        XCTAssertNoThrow(library)

        let store = TimelineLibraryStore()
        try store.openLibrary(at: bundleURL)
        let project = try store.createProject(name: "Demo")

        // The project identity owns the .tlkproj filename; the timeline identity
        // belongs to EditorTimeline/EditorStore. They are related but not equal.
        XCTAssertNotEqual(project.id, project.timeline.id)

        var edited = project
        edited.timeline.canvas.width = 1080
        try store.saveProject(edited)

        let projectFile = bundleURL
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(project.id.uuidString)
            .appendingPathExtension("tlkproj")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectFile.path))

        let loaded = try store.loadProject(projectID: project.id)
        XCTAssertEqual(loaded.id, project.id)
        XCTAssertEqual(loaded.timeline.id, project.timeline.id)
        XCTAssertEqual(loaded.timeline.canvas.width, 1080)
    }
}

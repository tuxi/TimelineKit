import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreVideo
import TimelineKitCore
@testable import TimelineKitUIShared

@MainActor
final class AutomaticCanvasTests: XCTestCase {
    private var directory: URL!
    private let placeholder = EditorCanvas(width: 1920, height: 1080, fps: 30)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testBatchMatchesFirstVisualAndCanvasBelongsToImportUndo() async throws {
        let store = automaticStore()
        let portrait = try image(width: 360, height: 640)
        let square = try image(width: 400, height: 400)
        let first = store.addVisualSegment(localURL: portrait, nativeDuration: nil)
        _ = store.addVisualSegment(localURL: square, nativeDuration: nil)
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(store.timeline.canvas, EditorCanvas(width: 360, height: 640))
        XCTAssertEqual(store.timeline.metadata.canvasSizingMode, .fixed)
        XCTAssertEqual(store.lastUndoLabel, "添加素材")

        store.undo()
        XCTAssertNotNil(store.timeline.segment(id: try XCTUnwrap(first)))
        XCTAssertEqual(store.timeline.canvas.width, 360)
        store.undo()
        XCTAssertEqual(store.timeline.canvas, placeholder)
        XCTAssertTrue(store.isAwaitingAutomaticCanvas)
        store.redo()
        XCTAssertEqual(store.timeline.canvas.width, 360)
        XCTAssertEqual(store.timeline.metadata.canvasSizingMode, .fixed)
    }

    func testAudioAndOverlayDoNotChooseCanvas() async throws {
        let overlayID = UUID()
        let store = automaticStore(tracks: [EditorTrack(id: overlayID, kind: .overlay)])
        _ = store.addAudioSegment(localURL: directory.appendingPathComponent("audio.m4a"), nativeDuration: 5)
        _ = store.addVisualSegment(localURL: try image(width: 400, height: 400), nativeDuration: nil, targetTrackID: overlayID)
        await store.waitForAutomaticCanvasResolution()
        XCTAssertTrue(store.isAwaitingAutomaticCanvas)
        _ = store.addVisualSegment(localURL: try image(width: 360, height: 640), nativeDuration: nil)
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(store.timeline.canvas.width, 360)
        XCTAssertEqual(store.timeline.canvas.height, 640)
    }

    func testInsertAtTimeUsesSameAutomaticRule() async throws {
        let store = automaticStore()
        let id = store.insertVisualSegment(localURL: try image(width: 360, height: 640), nativeDuration: nil, at: 2)
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(store.timeline.canvas.width, 360)
        XCTAssertEqual(store.timeline.segment(id: try XCTUnwrap(id))?.targetRange.start, 2)
    }

    func testReplacingUnreadableFirstVisualResolvesPendingCanvas() async throws {
        let store = automaticStore()
        let id = try XCTUnwrap(store.addVisualSegment(
            localURL: directory.appendingPathComponent("missing.jpg"), nativeDuration: nil
        ))
        await store.waitForAutomaticCanvasResolution()
        XCTAssertTrue(store.isAwaitingAutomaticCanvas)
        store.replaceSegmentMaterial(segmentID: id, localURL: try image(width: 360, height: 640), nativeDuration: nil)
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(store.timeline.canvas.height, 640)
        XCTAssertEqual(store.timeline.metadata.canvasSizingMode, .fixed)
        store.undo()
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(store.timeline.canvas, placeholder)
        XCTAssertTrue(store.isAwaitingAutomaticCanvas)
        store.redo()
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(store.timeline.canvas.height, 640)
        XCTAssertEqual(store.timeline.metadata.canvasSizingMode, .fixed)
    }

    func testManualChoiceWinsOverPendingMetadata() async throws {
        let store = automaticStore()
        _ = store.addVisualSegment(localURL: try image(width: 360, height: 640), nativeDuration: nil)
        let manual = EditorCanvas(width: 800, height: 800, fps: 24)
        store.setCanvas(manual)
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(store.timeline.canvas, manual)
        XCTAssertEqual(store.timeline.metadata.canvasSizingMode, .fixed)
    }

    func testUndoBeforeResolutionDoesNotResizeEmptyProjectAndRedoResumes() async throws {
        let store = automaticStore()
        _ = store.addVisualSegment(localURL: try image(width: 360, height: 640), nativeDuration: nil)
        store.undo()
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(store.timeline.canvas, placeholder)
        XCTAssertTrue(store.timeline.tracks.allSatisfy { $0.segments.isEmpty })
        store.redo()
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(store.timeline.canvas.height, 640)
    }

    func testDeletingEverythingAndReopeningKeepsResolvedCanvas() async throws {
        let store = automaticStore()
        let id = try XCTUnwrap(store.addVisualSegment(localURL: try image(width: 360, height: 640), nativeDuration: nil))
        await store.waitForAutomaticCanvasResolution()
        store.deleteSegment(id: id)
        let reopened = EditorStore(timeline: try roundTrip(store.timeline))
        _ = reopened.addVisualSegment(localURL: try image(width: 400, height: 400), nativeDuration: nil)
        await reopened.waitForAutomaticCanvasResolution()
        XCTAssertEqual(reopened.timeline.canvas.width, 360)
        XCTAssertEqual(reopened.timeline.canvas.height, 640)
    }

    func testEmptyProjectRoundTripKeepsAutomaticPolicy() async throws {
        let library = try libraryStore()
        let project = try library.createProject(name: "空白")
        let reopened = EditorStore(timeline: try library.loadProject(projectID: project.id).timeline)
        XCTAssertTrue(reopened.isAwaitingAutomaticCanvas)
        _ = reopened.addVisualSegment(localURL: try image(width: 360, height: 640), nativeDuration: nil)
        await reopened.waitForAutomaticCanvasResolution()
        XCTAssertEqual(reopened.timeline.canvas.width, 360)
    }

    func testPendingPopulatedProjectResolvesAfterReopening() async throws {
        let store = automaticStore()
        _ = store.addVisualSegment(localURL: try image(width: 360, height: 640), nativeDuration: nil)
        let reopened = EditorStore(timeline: try roundTrip(store.timeline))
        await reopened.waitForAutomaticCanvasResolution()
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(reopened.timeline.canvas.height, 640)
    }

    func testMediaFirstCreationMatchesOrderAndUsesLibraryCopies() async throws {
        let library = try libraryStore()
        let first = try image(width: 360, height: 640)
        let second = try image(width: 400, height: 400)
        let project = try await library.createProject(name: "素材项目", mediaURLs: [first, second])
        XCTAssertEqual(project.timeline.canvas, EditorCanvas(width: 360, height: 640))
        XCTAssertEqual(project.timeline.mainTrack?.segments.count, 2)
        XCTAssertEqual(project.timeline.metadata.canvasSizingMode, .fixed)
        let loaded = try library.loadProject(projectID: project.id)
        XCTAssertEqual(loaded.timeline, project.timeline)
        for asset in project.timeline.materials.all {
            XCTAssertTrue(try XCTUnwrap(asset.localURL).path.hasPrefix(try XCTUnwrap(library.library).mediaDirectory.path))
        }
    }

    func testExplicitCanvasIsRespectedByBothCreationPaths() async throws {
        let library = try libraryStore()
        let manual = EditorCanvas(width: 800, height: 800, fps: 24)
        let blank = try library.createProject(name: "手动空白", canvas: manual)
        let store = EditorStore(timeline: blank.timeline)
        _ = store.addVisualSegment(localURL: try image(width: 360, height: 640), nativeDuration: nil)
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(store.timeline.canvas, manual)
        let project = try await library.createProject(name: "手动素材", mediaURLs: [try image(width: 360, height: 640)], canvas: manual)
        XCTAssertEqual(project.timeline.canvas, manual)
    }

    func testUnreadableSelectionDoesNotCreateProject() async throws {
        let library = try libraryStore()
        let invalid = directory.appendingPathComponent("invalid.jpg")
        try Data("invalid".utf8).write(to: invalid)
        do {
            _ = try await library.createProject(name: "失败", mediaURLs: [invalid])
            XCTFail("Invalid media must not create an empty project")
        } catch { }
        XCTAssertTrue(library.projects.isEmpty)
    }

    func testUnreadableFirstMediaFallsBackToFirstReadableVisual() async throws {
        let invalid = directory.appendingPathComponent("invalid.jpg")
        try Data("invalid".utf8).write(to: invalid)
        let portrait = try image(width: 360, height: 640)
        let imported = try await TimelineImporter.importingMedia(from: [invalid, portrait])
        XCTAssertEqual(imported.canvas.width, 360)
        let store = automaticStore()
        _ = store.addVisualSegment(localURL: invalid, nativeDuration: nil)
        _ = store.addVisualSegment(localURL: portrait, nativeDuration: nil)
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(store.timeline.canvas.height, 640)
    }

    func testImageOrientationAndExistingFrameRateAreRespected() async throws {
        let photo = try image(width: 640, height: 360, orientation: 6)
        let store = EditorStore(timeline: EditorTimeline(
            canvas: EditorCanvas(width: 1920, height: 1080, fps: 24),
            metadata: EditorMetadata(canvasSizingMode: .automatic)
        ))
        _ = store.addVisualSegment(localURL: photo, nativeDuration: nil)
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(store.timeline.canvas, EditorCanvas(width: 360, height: 640, fps: 24))
        let imported = try await TimelineImporter.importingMedia(from: [photo])
        XCTAssertEqual(imported.canvas, EditorCanvas(width: 360, height: 640, fps: 30))
    }

    func testLegacyPopulatedProjectKeepsCanvasAndMetadataEncoding() async throws {
        let photo = try image(width: 360, height: 640)
        let assetID = UUID()
        let segment = EditorSegment(materialID: assetID, targetRange: TimeRange(start: 0, duration: 3), content: .image(.init()))
        let legacy = EditorTimeline(canvas: placeholder, tracks: [EditorTrack(kind: .video, segments: [segment], isMainTrack: true)])
        let decoded = try roundTrip(legacy)
        XCTAssertNil(decoded.metadata.canvasSizingMode)
        let store = EditorStore(timeline: decoded)
        _ = store.addVisualSegment(localURL: photo, nativeDuration: nil)
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(store.timeline.canvas, placeholder)
        XCTAssertNil(store.timeline.metadata.canvasSizingMode)
        store.deleteSegment(id: segment.id)
        for added in store.timeline.mainTrack?.segments ?? [] { store.deleteSegment(id: added.id) }
        let reopened = EditorStore(timeline: try roundTrip(store.timeline))
        _ = reopened.addVisualSegment(localURL: photo, nativeDuration: nil)
        await reopened.waitForAutomaticCanvasResolution()
        XCTAssertEqual(reopened.timeline.canvas, placeholder)
    }

    func testRotatedVideoDefinesDisplayedPortraitCanvas() async throws {
        let url = directory.appendingPathComponent("rotated.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640, AVVideoHeightKey: 360
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddress(pixel), 80, CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        for index in 0..<3 {
            for _ in 0..<1000 where !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 24)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let imported = try await TimelineImporter.importingMedia(from: [url])
        XCTAssertEqual(imported.canvas.width, 360)
        XCTAssertEqual(imported.canvas.height, 640)
        XCTAssertEqual(imported.canvas.fps, 24)
        let store = automaticStore()
        _ = store.addVisualSegment(localURL: url, nativeDuration: 0.125)
        await store.waitForAutomaticCanvasResolution()
        XCTAssertEqual(store.timeline.canvas, imported.canvas)
    }

    private func automaticStore(tracks: [EditorTrack] = []) -> EditorStore {
        EditorStore(timeline: EditorTimeline(
            canvas: placeholder, tracks: tracks,
            metadata: EditorMetadata(canvasSizingMode: .automatic)
        ))
    }

    private func libraryStore() throws -> TimelineLibraryStore {
        let store = TimelineLibraryStore()
        try store.createLibrary(at: directory.appendingPathComponent("Library.tlkbundle"))
        return store
    }

    private func roundTrip(_ timeline: EditorTimeline) throws -> EditorTimeline {
        try JSONDecoder().decode(EditorTimeline.self, from: JSONEncoder().encode(timeline))
    }

    private func image(width: Int, height: Int, orientation: Int = 1) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.15, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = directory.appendingPathComponent("\(UUID().uuidString).jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}

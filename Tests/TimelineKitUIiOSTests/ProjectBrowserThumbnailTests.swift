import XCTest
import Foundation
import CoreGraphics
import TimelineKitCore
import TimelineKitUIShared
@testable import TimelineKitUIiOS

/// Cover-source resolution for `LibraryProject` (pure model logic, lives in
/// TimelineKitUIShared; exercised here because the browser view is its
/// consumer). Not gated by UIKit: runs on the macOS host with `swift test`.
final class ProjectThumbnailSourceTests: XCTestCase {

    // MARK: - Fixtures

    private func asset(_ type: EditorAsset.AssetType, url: URL?, idLike id: UUID? = nil) -> EditorAsset {
        EditorAsset(id: id ?? UUID(), type: type, localURL: url,
                    nativeDuration: type == .image ? nil : 10)
    }

    private func fileURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/tlk_thumbnail_tests/\(name)")
    }

    private func segment(content: SegmentContent,
                         material: UUID,
                         targetStart: Double,
                         targetDuration: Double = 2,
                         sourceRange: TimeRange? = nil) -> EditorSegment {
        EditorSegment(
            materialID: material,
            sourceRange: sourceRange,
            targetRange: TimeRange(start: targetStart, duration: targetDuration),
            content: content
        )
    }

    private func project(mainSegments: [EditorSegment],
                         materials: [EditorAsset],
                         overlaySegments: [EditorSegment] = []) -> LibraryProject {
        var pool = MaterialsPool()
        for m in materials { pool.add(m) }
        var tracks = [
            EditorTrack(kind: .video, label: "main", segments: mainSegments, isMainTrack: true)
        ]
        if !overlaySegments.isEmpty {
            tracks.append(EditorTrack(kind: .overlay, label: "overlay", zPosition: 1, segments: overlaySegments))
        }
        let timeline = EditorTimeline(
            canvas: EditorCanvas(width: 1920, height: 1080, fps: 30),
            tracks: tracks,
            materials: pool
        )
        return LibraryProject(name: "P", timeline: timeline)
    }

    // MARK: - Tests

    func testEmptyProjectHasNoThumbnailSource() {
        let p = project(mainSegments: [], materials: [])
        XCTAssertNil(p.thumbnailSource)
    }

    func testProjectWithoutMainTrackHasNoThumbnailSource() {
        let imageID = UUID()
        let overlay = segment(content: .image(SegmentContent.ImageContent()),
                              material: imageID, targetStart: 0)
        var pool = MaterialsPool()
        pool.add(asset(.image, url: fileURL("a.png"), idLike: imageID))
        let timeline = EditorTimeline(
            canvas: EditorCanvas(width: 1920, height: 1080, fps: 30),
            tracks: [EditorTrack(kind: .overlay, zPosition: 1, segments: [overlay])],
            materials: pool
        )
        let p = LibraryProject(name: "P", timeline: timeline)
        XCTAssertNil(p.thumbnailSource)
    }

    func testEarliestVisualMainTrackSegmentWins() {
        let videoID = UUID(), imageID = UUID(), textID = UUID()
        let p = project(
            mainSegments: [
                segment(content: .text(SegmentContent.TextContent(text: "hi")),
                        material: textID, targetStart: 0),
                segment(content: .image(SegmentContent.ImageContent()),
                        material: imageID, targetStart: 1),
                segment(content: .video(SegmentContent.VideoContent()),
                        material: videoID, targetStart: 5),
            ],
            materials: [
                asset(.video, url: fileURL("v.mp4"), idLike: videoID),
                asset(.image, url: fileURL("i.png"), idLike: imageID),
            ]
        )
        let source = p.thumbnailSource
        XCTAssertEqual(source?.url, fileURL("i.png"))
        XCTAssertEqual(source?.isImage, true)
        XCTAssertEqual(source?.time, 0)
    }

    func testVideoUsesSourceRangeStartAsFrameTime() {
        let videoID = UUID()
        let p = project(
            mainSegments: [
                segment(content: .video(SegmentContent.VideoContent()),
                        material: videoID, targetStart: 0,
                        sourceRange: TimeRange(start: 12.5, duration: 3)),
            ],
            materials: [asset(.video, url: fileURL("v.mp4"), idLike: videoID)]
        )
        let source = p.thumbnailSource
        XCTAssertEqual(source?.url, fileURL("v.mp4"))
        XCTAssertEqual(source?.isImage, false)
        XCTAssertEqual(source?.time, 12.5)
    }

    func testVideoWithoutSourceRangeUsesTimeZero() {
        let videoID = UUID()
        let p = project(
            mainSegments: [
                segment(content: .video(SegmentContent.VideoContent()),
                        material: videoID, targetStart: 0, sourceRange: nil),
            ],
            materials: [asset(.video, url: fileURL("v.mp4"), idLike: videoID)]
        )
        XCTAssertEqual(p.thumbnailSource?.time, 0)
    }

    func testSegmentsAreScannedByTargetStartEvenWhenUnsorted() {
        let videoID = UUID(), imageID = UUID()
        let p = project(
            mainSegments: [
                // Deliberately out of order: the image at t=1 must win over
                // the video at t=5 regardless of array order.
                segment(content: .video(SegmentContent.VideoContent()),
                        material: videoID, targetStart: 5),
                segment(content: .image(SegmentContent.ImageContent()),
                        material: imageID, targetStart: 1),
            ],
            materials: [
                asset(.video, url: fileURL("v.mp4"), idLike: videoID),
                asset(.image, url: fileURL("i.png"), idLike: imageID),
            ]
        )
        XCTAssertEqual(p.thumbnailSource?.url, fileURL("i.png"))
    }

    func testSegmentWithMissingOrURLlessMaterialIsSkipped() {
        let brokenID = UUID()   // no material in the pool
        let noURLID = UUID()    // material without any URL
        let goodID = UUID()
        let p = project(
            mainSegments: [
                segment(content: .video(SegmentContent.VideoContent()),
                        material: brokenID, targetStart: 0),
                segment(content: .video(SegmentContent.VideoContent()),
                        material: noURLID, targetStart: 1),
                segment(content: .image(SegmentContent.ImageContent()),
                        material: goodID, targetStart: 2),
            ],
            materials: [
                asset(.video, url: nil, idLike: noURLID),
                asset(.image, url: fileURL("i.png"), idLike: goodID),
            ]
        )
        XCTAssertEqual(p.thumbnailSource?.url, fileURL("i.png"))
        XCTAssertEqual(p.thumbnailSource?.isImage, true)
    }

    func testNonVisualContentAndAudioMaterialsAreSkipped() {
        let audioID = UUID()
        let videoID = UUID()
        let p = project(
            mainSegments: [
                segment(content: .audio(SegmentContent.AudioContent()),
                        material: audioID, targetStart: 0),
                segment(content: .video(SegmentContent.VideoContent()),
                        material: videoID, targetStart: 1),
            ],
            materials: [
                asset(.audio, url: fileURL("a.m4a"), idLike: audioID),
                asset(.video, url: fileURL("v.mp4"), idLike: videoID),
            ]
        )
        XCTAssertEqual(p.thumbnailSource?.url, fileURL("v.mp4"))
    }

    func testOverlayOnlyVisualDoesNotBecomeCover() {
        let imageID = UUID()
        let overlayImage = segment(content: .image(SegmentContent.ImageContent()),
                                   material: imageID, targetStart: 0)
        let p = project(
            mainSegments: [],
            materials: [asset(.image, url: fileURL("i.png"), idLike: imageID)],
            overlaySegments: [overlayImage]
        )
        XCTAssertNil(p.thumbnailSource)
    }

    func testSourceIsStableAndHashableAcrossCalls() {
        let videoID = UUID()
        let p = project(
            mainSegments: [
                segment(content: .video(SegmentContent.VideoContent()),
                        material: videoID, targetStart: 0,
                        sourceRange: TimeRange(start: 3, duration: 2)),
            ],
            materials: [asset(.video, url: fileURL("v.mp4"), idLike: videoID)]
        )
        let a = p.thumbnailSource
        let b = p.thumbnailSource
        XCTAssertEqual(a, b, "identity must be value-stable so request tasks do not restart")
        XCTAssertEqual(Set([a, b]).count, 1)
    }

    func testRenameOrPinDoesNotChangeThumbnailSource() {
        let imageID = UUID()
        var p = project(
            mainSegments: [
                segment(content: .image(SegmentContent.ImageContent()),
                        material: imageID, targetStart: 0),
            ],
            materials: [asset(.image, url: fileURL("i.png"), idLike: imageID)]
        )
        let before = p.thumbnailSource
        p.name = "renamed"
        p.isPinned = true
        p.createdAt = Date().addingTimeInterval(3600)
        XCTAssertEqual(p.thumbnailSource, before)
    }

    // MARK: - Multiple main tracks (demo fixture regression)

    /// Builder for drafts with several `isMainTrack` tracks, matching the
    /// persisted Inspector Fixture shape (empty leading backbone + a later
    /// backbone carrying the real visual segments).
    private func multiMainProject(
        mainTracks: [[EditorSegment]],
        materials: [EditorAsset],
        nonMainSegments: [EditorSegment] = []
    ) -> LibraryProject {
        var pool = MaterialsPool()
        for m in materials { pool.add(m) }
        var tracks: [EditorTrack] = []
        for (index, segments) in mainTracks.enumerated() {
            tracks.append(EditorTrack(kind: .video, label: "main\(index)",
                                      zPosition: index, segments: segments, isMainTrack: true))
        }
        if !nonMainSegments.isEmpty {
            tracks.append(EditorTrack(kind: .overlay, label: "overlay",
                                      zPosition: 99, segments: nonMainSegments, isMainTrack: false))
        }
        let timeline = EditorTimeline(
            canvas: EditorCanvas(width: 1920, height: 1080, fps: 30),
            tracks: tracks,
            materials: pool
        )
        return LibraryProject(name: "P", timeline: timeline)
    }

    /// Regression (Codex review, reproduced on the real demo fixture): the
    /// first main track is empty, a later main track holds the image segment.
    /// The cover must resolve to that image, not the noThumbnail placeholder.
    func testEmptyFirstMainTrackStillFindsCoverInLaterMainTrack() {
        let imageID = UUID()
        let p = multiMainProject(
            mainTracks: [
                [],
                [segment(content: .image(SegmentContent.ImageContent()),
                         material: imageID, targetStart: 0)],
            ],
            materials: [asset(.image, url: fileURL("i.png"), idLike: imageID)]
        )
        let source = p.thumbnailSource
        XCTAssertEqual(source?.url, fileURL("i.png"))
        XCTAssertEqual(source?.isImage, true)
        XCTAssertEqual(source?.time, 0)
    }

    /// Across main tracks the GLOBAL earliest visual wins, regardless of
    /// which track it lives in; non-main tracks never become the cover.
    func testMultipleMainTracksPickEarliestGlobalSegment() {
        let videoID = UUID(), imageID = UUID(), overlayID = UUID()
        let laterIsEarlier = multiMainProject(
            mainTracks: [
                [segment(content: .video(SegmentContent.VideoContent()),
                         material: videoID, targetStart: 5,
                         sourceRange: TimeRange(start: 20, duration: 3))],
                [segment(content: .image(SegmentContent.ImageContent()),
                         material: imageID, targetStart: 1)],
            ],
            materials: [
                asset(.video, url: fileURL("v.mp4"), idLike: videoID),
                asset(.image, url: fileURL("i.png"), idLike: imageID),
            ],
            // An even earlier visual on a non-main track must be ignored.
            nonMainSegments: [segment(content: .image(SegmentContent.ImageContent()),
                                      material: overlayID, targetStart: 0)]
        )
        let s1 = laterIsEarlier.thumbnailSource
        XCTAssertEqual(s1?.url, fileURL("i.png"), "image at t=1 beats video at t=5 across main tracks")

        let earlierTrackIsLater = multiMainProject(
            mainTracks: [
                [segment(content: .image(SegmentContent.ImageContent()),
                         material: imageID, targetStart: 5)],
                [segment(content: .video(SegmentContent.VideoContent()),
                         material: videoID, targetStart: 0,
                         sourceRange: TimeRange(start: 12.5, duration: 3))],
            ],
            materials: [
                asset(.video, url: fileURL("v.mp4"), idLike: videoID),
                asset(.image, url: fileURL("i.png"), idLike: imageID),
            ]
        )
        let s2 = earlierTrackIsLater.thumbnailSource
        XCTAssertEqual(s2?.url, fileURL("v.mp4"), "video at t=0 beats image at t=5 regardless of track order")
        XCTAssertEqual(s2?.isImage, false)
        XCTAssertEqual(s2?.time, 12.5, "video frame time still comes from sourceRange.start")
    }

    /// Equal global starts across main tracks must resolve deterministically
    /// (stable order) so the request identity never jitters between calls.
    func testTieBreakAcrossMainTracksIsStable() {
        let firstID = UUID(), secondID = UUID()
        let p = multiMainProject(
            mainTracks: [
                [segment(content: .image(SegmentContent.ImageContent()),
                         material: firstID, targetStart: 2)],
                [segment(content: .video(SegmentContent.VideoContent()),
                         material: secondID, targetStart: 2)],
            ],
            materials: [
                asset(.image, url: fileURL("first.png"), idLike: firstID),
                asset(.video, url: fileURL("second.mp4"), idLike: secondID),
            ]
        )
        // First track's segment wins by stable (track, segment) order...
        XCTAssertEqual(p.thumbnailSource?.url, fileURL("first.png"))
        // ...and repeated resolution yields the identical value every time.
        var results: [ProjectThumbnailSource?] = []
        for _ in 0..<10 { results.append(p.thumbnailSource) }
        for result in results { XCTAssertEqual(result, results[0]) }
        XCTAssertEqual(Set(results.compactMap { $0 }).count, 1)
    }

    /// All main tracks empty → still noThumbnail (no accidental fallback to
    /// overlay/text/audio).
    func testAllMainTracksEmptyWithLaterOverlayIsStillNoThumbnail() {
        let overlayID = UUID()
        let p = multiMainProject(
            mainTracks: [[], []],
            materials: [asset(.image, url: fileURL("i.png"), idLike: overlayID)],
            nonMainSegments: [segment(content: .image(SegmentContent.ImageContent()),
                                      material: overlayID, targetStart: 0)]
        )
        XCTAssertNil(p.thumbnailSource)
    }
}

// MARK: - Layout policy

/// Width-driven layout decision for `ProjectBrowserView`. The policy itself is
/// platform-neutral (CoreGraphics only) so it runs on the macOS host.
final class ProjectBrowserLayoutPolicyTests: XCTestCase {

    func testNarrowWidthsUseListLayout() {
        // iPhone portrait range.
        for width in [320.0, 375, 390, 430] {
            XCTAssertEqual(ProjectBrowserLayoutPolicy.style(for: CGFloat(width)), .list,
                           "iPhone portrait \(width) should use rows")
        }
        // iPad split 1/3 and 1/2 widths.
        for width in [320.0, 387, 506, 540] {
            XCTAssertEqual(ProjectBrowserLayoutPolicy.style(for: CGFloat(width)), .list,
                           "iPad split \(width) should use rows")
        }
    }

    func testWideWidthsUseGridLayout() {
        // iPhone landscape range.
        for width in [667.0, 740, 844, 932] {
            XCTAssertEqual(ProjectBrowserLayoutPolicy.style(for: CGFloat(width)), .grid,
                           "iPhone landscape \(width) should use cards")
        }
        // iPad full widths.
        for width in [810.0, 834, 1024, 1112, 1366] {
            XCTAssertEqual(ProjectBrowserLayoutPolicy.style(for: CGFloat(width)), .grid,
                           "iPad full \(width) should use cards")
        }
    }

    func testThresholdIsExactlyAtBoundary() {
        XCTAssertEqual(ProjectBrowserLayoutPolicy.style(for: ProjectBrowserLayoutPolicy.listStyleMaxWidth - 1), .list)
        XCTAssertEqual(ProjectBrowserLayoutPolicy.style(for: ProjectBrowserLayoutPolicy.listStyleMaxWidth), .grid)
    }

    func testCardWidthBoundsAreOrderedAndBounded() {
        XCTAssertLessThan(ProjectBrowserLayoutPolicy.gridMinCardWidth,
                          ProjectBrowserLayoutPolicy.gridMaxCardWidth)
        XCTAssertGreaterThanOrEqual(ProjectBrowserLayoutPolicy.gridContentMaxWidth,
                                    ProjectBrowserLayoutPolicy.gridMaxCardWidth)
        XCTAssertLessThanOrEqual(ProjectBrowserLayoutPolicy.listContentMaxWidth,
                                 ProjectBrowserLayoutPolicy.listStyleMaxWidth + 160)
    }

    func testThumbnailAspectRatioIs16By9() {
        XCTAssertEqual(ProjectBrowserLayoutPolicy.thumbnailAspectRatio, 16.0 / 9.0, accuracy: 0.0001)
        // Row thumbnail height derived from the ratio stays within row bounds.
        let height = ProjectBrowserLayoutPolicy.rowThumbnailWidth
            / ProjectBrowserLayoutPolicy.thumbnailAspectRatio
        XCTAssertGreaterThan(height, 60)
        XCTAssertLessThan(height, 100)
    }
}

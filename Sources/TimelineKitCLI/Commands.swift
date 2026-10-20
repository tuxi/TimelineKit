import Foundation
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared

// MARK: - Command implementations

enum Commands {

    static func help() {
        print("""
        TimelineKit CLI v8.0

        Commands:
          inspect <timeline.json>                    View timeline summary
          import-media <file1> <file2>... [options]   Create draft from media files
          export-json <draft.json> [--output out]     Export to server JSON format
          apply-plan <timeline.json> --plan plan.json --execution-id id [--dry-run]
          render <draft.json> --output out.mp4         Render timeline to video (iOS)
          thumbnail <draft.json> --time 3.2            Generate thumbnail (iOS)
          waveform <audio.m4a>                         Generate waveform data (iOS)
          validate <timeline.json>                     Validate timeline structure

        Options:
          --output, -o <path>    Output file path
          --resolution <res>     1080p, 720p, 4k (default: 1080p)
          --fps <n>              Frames per second (default: 30)
          --time <seconds>       Time position for thumbnail
          --canvas-width <px>    Canvas width (default: 720)
          --canvas-height <px>   Canvas height (default: 1280)
          --image-duration <s>   Default duration for images (default: 3.0)
          --plan <path>          AgentEditPlan JSON for apply-plan
          --execution-id <id>    Stable idempotency key for apply-plan
          --dry-run              Preview apply-plan without writing the timeline
        """)
        fflush(stdout)
    }

    // MARK: inspect

    static func inspect(_ opts: Options) async throws {
        guard let path = opts.input else { CLI.fail(1, "Missing input file") }
        let data = try Data(contentsOf: resolve(path))
        let timeline: EditorTimeline
        do {
            timeline = try JSONDecoder().decode(EditorTimeline.self, from: data)
        } catch {
            CLI.fail(3, "Failed to decode timeline: \(error.localizedDescription)")
        }

        let trackInfo: [[String: Any]] = timeline.tracks.map { t in
            ["id": t.id.uuidString, "kind": String(describing: t.kind),
             "label": t.label, "segments": t.segments.count,
             "isMainTrack": t.isMainTrack, "isHidden": t.isHidden, "isLocked": t.isLocked]
        }

        CLI.ok([
            "timelineID": timeline.id.uuidString, "duration": timeline.duration,
            "canvas": ["width": timeline.canvas.width, "height": timeline.canvas.height],
            "tracks": timeline.tracks.count,
            "totalSegments": timeline.tracks.reduce(0) { $0 + $1.segments.count },
            "transitions": timeline.transitions.count, "materials": timeline.materials.count,
            "trackDetails": trackInfo
        ])
    }

    // MARK: import-media

    static func importMedia(_ opts: Options) async throws {
        let urls = opts.urls.map { resolve($0) }
        guard !urls.isEmpty else { CLI.fail(1, "Missing media file paths") }

        CLI.log("Importing \(urls.count) media file(s)...")
        let canvas = EditorCanvas(width: opts.canvasWidth, height: opts.canvasHeight, fps: opts.fps)
        let timeline = try await TimelineImporter.importingMedia(
            from: urls, canvas: canvas, imageDuration: opts.imageDuration
        )

        let draftID = await MainActor.run { DraftStore.save(timeline) }
        CLI.ok([
            "timelineID": timeline.id.uuidString, "draftID": draftID.uuidString,
            "duration": timeline.duration, "tracks": timeline.tracks.count,
            "totalSegments": timeline.tracks.reduce(0) { $0 + $1.segments.count }
        ])
    }

    // MARK: export-json

    static func exportJSON(_ opts: Options) async throws {
        guard let path = opts.input else { CLI.fail(1, "Missing input file") }
        let data = try Data(contentsOf: resolve(path))
        let timeline = try JSONDecoder().decode(EditorTimeline.self, from: data)
        let jsonData = try TimelineExporter.exportJSON(timeline)

        if let outputPath = opts.output {
            try jsonData.write(to: resolve(outputPath), options: .atomic)
            CLI.ok(["output": outputPath, "bytes": jsonData.count])
        } else {
            guard let jsonStr = String(data: jsonData, encoding: .utf8) else {
                CLI.fail(3, "Failed to encode JSON")
            }
            print(jsonStr)
        }
    }

    // MARK: apply-plan

    @MainActor
    static func applyPlan(_ opts: Options) async throws {
        guard let path = opts.input, let planPath = opts.plan else { CLI.fail(1, "apply-plan requires input and --plan") }
        let timeline = try JSONDecoder().decode(EditorTimeline.self, from: Data(contentsOf: resolve(path)))
        let plan = try JSONDecoder().decode(AgentEditPlan.self, from: Data(contentsOf: resolve(planPath)))
        if opts.dryRun {
            let preview = try AgentEditEngine.preview(plan: plan, timeline: timeline)
            CLI.ok(["dryRun": true, "planHash": preview.planHash, "externalPlanID": plan.externalPlanID ?? NSNull(), "externalPlanHash": plan.externalPlanHash ?? NSNull(), "timelineVersion": preview.resultingTimelineVersion, "duration": preview.timeline.duration])
            return
        }
        guard let executionID = opts.executionID, !executionID.isEmpty else { CLI.fail(1, "apply-plan requires --execution-id") }
        let result = try await AgentEditEngine.apply(plan: plan, timeline: timeline, executionID: executionID, executionStore: InMemoryAgentExecutionStore())
        if result.didApply {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            try encoder.encode(result.timeline).write(to: resolve(path), options: .atomic)
        }
        CLI.ok(["applied": result.applied, "replayed": result.replayed, "wroteTimeline": result.didApply, "executionID": result.executionID, "planHash": result.planHash, "timelineVersion": result.timelineVersion, "externalPlanID": result.externalPlanID ?? NSNull(), "externalPlanHash": result.externalPlanHash ?? NSNull()])
    }

    // MARK: render

    static func render(_ opts: Options) async throws {
#if canImport(UIKit)
        guard let path = opts.input else { CLI.fail(1, "Missing input file") }
        guard let outputPath = opts.output else { CLI.fail(1, "Missing --output") }
        let data = try Data(contentsOf: resolve(path))
        let timeline = try JSONDecoder().decode(EditorTimeline.self, from: data)
        CLI.log("Rendering \(String(format: "%.1f", timeline.duration))s timeline...")
        let exporter = VideoExporter()
        await exporter.export(timeline: timeline)
        CLI.ok(["output": outputPath, "duration": timeline.duration])
#else
        CLI.fail(1, "Render requires UIKit. Available on iOS/macOS Catalyst.")
#endif
    }

    // MARK: thumbnail

    static func thumbnail(_ opts: Options) async throws {
#if canImport(UIKit)
        CLI.fail(1, "Thumbnail: headless CLI path pending (requires Render CGImage support)")
#else
        CLI.fail(1, "Thumbnail requires UIKit.")
#endif
    }

    // MARK: waveform

    static func waveform(_ opts: Options) async throws {
#if canImport(UIKit)
        CLI.fail(1, "Waveform: headless CLI path pending (requires Render CG support)")
#else
        CLI.fail(1, "Waveform requires UIKit.")
#endif
    }

    // MARK: validate

    static func validate(_ opts: Options) async throws {
        guard let path = opts.input else { CLI.fail(1, "Missing input file") }
        let data = try Data(contentsOf: resolve(path))
        let timeline = try JSONDecoder().decode(EditorTimeline.self, from: data)

        var issues: [[String: Any]] = []

        if timeline.tracks.isEmpty { issues.append(["severity": "error", "message": "Timeline has no tracks"]) }
        let mainTracks = timeline.tracks.filter(\.isMainTrack)
        if mainTracks.isEmpty { issues.append(["severity": "warning", "message": "No main video track"]) }
        if mainTracks.count > 1 { issues.append(["severity": "error", "message": "Multiple main tracks"]) }

        let allSegs = timeline.tracks.flatMap(\.segments)
        if allSegs.isEmpty { issues.append(["severity": "warning", "message": "Timeline has no segments"]) }

        for track in timeline.tracks {
            let sorted = track.segments.sorted { $0.targetRange.start < $1.targetRange.start }
            for i in 0..<(sorted.count - 1) {
                let a = sorted[i], b = sorted[i + 1]
                if a.targetRange.end > b.targetRange.start {
                    issues.append(["severity": "error", "track": track.label,
                        "message": "Overlapping segments at \(String(format: "%.2f", a.targetRange.end))s"])
                }
            }
        }
        for seg in allSegs where timeline.materials[seg.materialID] == nil {
            issues.append(["severity": "error", "segmentID": seg.id.uuidString, "message": "Missing material"])
        }
        for trans in timeline.transitions {
            if timeline.segment(id: trans.leadingSegmentID) == nil {
                issues.append(["severity": "error", "transitionID": trans.id.uuidString, "message": "Missing leading segment"])
            }
            if timeline.segment(id: trans.trailingSegmentID) == nil {
                issues.append(["severity": "error", "transitionID": trans.id.uuidString, "message": "Missing trailing segment"])
            }
        }

        CLI.ok([
            "timelineID": timeline.id.uuidString, "duration": timeline.duration,
            "valid": issues.filter { ($0["severity"] as? String) == "error" }.isEmpty,
            "errorCount": issues.filter { ($0["severity"] as? String) == "error" }.count,
            "warningCount": issues.filter { ($0["severity"] as? String) == "warning" }.count,
            "issues": issues
        ])
    }

    // MARK: - Helpers

    private static func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
    }
}

// MARK: - Options

struct Options {
    let input: String?
    let output: String?
    let resolution: String
    let fps: Int
    let time: Double
    let canvasWidth: Int
    let canvasHeight: Int
    let imageDuration: Double
    let urls: [String]
    let plan: String?
    let executionID: String?
    let dryRun: Bool

    init(args: [String]) {
        func opt(_ name: String) -> String? {
            guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func int(_ name: String, _ fallback: Int) -> Int { opt(name).flatMap(Int.init) ?? fallback }
        func dbl(_ name: String, _ fallback: Double) -> Double { opt(name).flatMap(Double.init) ?? fallback }

        var positional: [String] = []
        var skip = false
        for arg in args {
            if skip { skip = false; continue }
            if arg == "--dry-run" { continue }
            if arg.hasPrefix("--") { if !arg.contains("=") { skip = true }; continue }
            positional.append(arg)
        }
        self.urls = positional
        self.plan = opt("plan")
        self.executionID = opt("execution-id")
        self.dryRun = args.contains("--dry-run")
        self.input  = opt("input")  ?? positional.first
        self.output = opt("output") ?? opt("o")
        self.resolution = opt("resolution") ?? "1080p"
        self.fps = int("fps", 30)
        self.time = dbl("time", 0)
        self.canvasWidth  = int("canvas-width", 720)
        self.canvasHeight = int("canvas-height", 1280)
        self.imageDuration = dbl("image-duration", 3.0)
    }
}

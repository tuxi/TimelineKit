import Foundation
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared

// MARK: - Tool Types (all Sendable)

struct MCPParameter: Sendable {
    let name: String
    let description: String
    let type: String
    var required: Bool = true
    var schema: [String: JSONValue] {
        ["type": .string(type), "description": .string(description)]
    }
}

struct MCPTool: @unchecked Sendable {
    let name: String
    let description: String
    let parameters: [String: MCPParameter]
    let execute: @MainActor @Sendable ([String: JSONValue]) async throws -> MCPToolResult

    var requiredParams: [String] {
        parameters.filter { $0.value.required }.keys.sorted()
    }
}

struct MCPToolResult: Sendable {
    struct Content: Sendable {
        let type: String
        let text: String
        var json: [String: JSONValue] {
            ["type": .string(type), "text": .string(text)]
        }
    }
    let content: [Content]
    let metadata: [String: JSONValue]?

    static func text(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [Content(type: "text", text: text)], metadata: nil)
    }
}

// MARK: - Helpers (non-isolated-safe)

private func resolvePath(_ path: String) -> URL {
    if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
}

private func readTimeline(from path: String) throws -> EditorTimeline {
    let data = try Data(contentsOf: resolvePath(path))
    return try JSONDecoder().decode(EditorTimeline.self, from: data)
}

private func writeTimeline(_ timeline: EditorTimeline, to path: String) throws {
    let data = try JSONEncoder().encode(timeline)
    try data.write(to: resolvePath(path), options: .atomic)
}

private func jsonString(from dict: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .sortedKeys),
          let str = String(data: data, encoding: .utf8) else { return "{}" }
    return str
}

// MARK: - Tool Registry

enum MCPTools {
    private static let agentExecutionStore = InMemoryAgentExecutionStore()
    static let all: [MCPTool] = [inspect, importMedia, applyEdits, applyEditPlan, render, thumbnail, validate]

    // MARK: apply_edits / apply_edit_plan
    //
    // `apply_edits` is the V8 standard MCP name. `apply_edit_plan` remains a
    // compatibility alias. Both use the exact same schema and handler.

    private static let applyPlanParameters: [String: MCPParameter] = [
        "path": MCPParameter(name: "path", description: "Path to the timeline JSON", type: "string"),
        "plan": MCPParameter(name: "plan", description: "AgentEditPlan object", type: "object"),
        "execution_id": MCPParameter(name: "execution_id", description: "Stable retry key for this apply; required unless dry_run is true", type: "string", required: false),
        "dry_run": MCPParameter(name: "dry_run", description: "Preview without writing the timeline", type: "boolean", required: false)
    ]

    private static func makeApplyPlanTool(name: String, description: String) -> MCPTool {
        MCPTool(name: name, description: description, parameters: applyPlanParameters) { args in
            try await executeApplyPlan(args)
        }
    }

    @MainActor
    private static func executeApplyPlan(_ args: [String: JSONValue]) async throws -> MCPToolResult {
        guard let path = args["path"]?.stringValue else { throw MCPError(-32602, "Missing 'path' parameter") }
        guard let planValue = args["plan"], let planData = try? JSONEncoder().encode(planValue),
              let plan = try? JSONDecoder().decode(AgentEditPlan.self, from: planData) else { throw MCPError(-32602, "Invalid 'plan' object") }
        let timeline = try readTimeline(from: path)
        if args["dry_run"]?.boolValue == true {
            let preview = try AgentEditEngine.preview(plan: plan, timeline: timeline)
            return .text(jsonString(from: ["dryRun": true, "planHash": preview.planHash, "externalPlanID": plan.externalPlanID ?? NSNull(), "externalPlanHash": plan.externalPlanHash ?? NSNull(), "timelineVersion": preview.resultingTimelineVersion, "duration": preview.timeline.duration]))
        }
        guard let executionID = args["execution_id"]?.stringValue, !executionID.isEmpty else { throw MCPError(-32602, "Missing 'execution_id' parameter") }
        let result = try await AgentEditEngine.apply(plan: plan, timeline: timeline, executionID: executionID, executionStore: agentExecutionStore)
        var wroteTimeline = false
        var repairedReplay = false
        if result.didApply {
            try writeTimeline(result.timeline, to: path)
            wroteTimeline = true
        } else if result.replayed {
            // Core records before the adapter writes. If the first write failed,
            // a retry is a replay whose stored result is already authoritative.
            // Repair only when the file is still exactly at the plan's base
            // revision; never overwrite a timeline that moved on.
            let currentVersion = AgentEditPlan.timelineVersion(for: timeline)
            if currentVersion != result.timelineVersion {
                guard currentVersion == plan.baseTimelineVersion else {
                    throw MCPError(-32603, "Execution replay requires reconciliation: timeline diverged from both base and result revisions")
                }
                try writeTimeline(result.timeline, to: path)
                wroteTimeline = true
                repairedReplay = true
            }
        }
        return .text(jsonString(from: ["applied": result.applied, "replayed": result.replayed, "wroteTimeline": wroteTimeline, "repairedReplay": repairedReplay, "executionID": result.executionID, "planHash": result.planHash, "timelineVersion": result.timelineVersion, "externalPlanID": result.externalPlanID ?? NSNull(), "externalPlanHash": result.externalPlanHash ?? NSNull()]))
    }

    static let applyEdits = makeApplyPlanTool(
        name: "timelinekit.apply_edits",
        description: "Preview or atomically apply a versioned AgentEditPlan. Commands include trim, delete, move, split(newSegmentID), addSubtitle(segmentID), and roughCut(materialID, ordered sourceRanges, stable segmentIDs). planHash is TimelineKit's local normalized-command hash; external approval hashes are only carried through."
    )

    static let applyEditPlan = makeApplyPlanTool(
        name: "timelinekit.apply_edit_plan",
        description: "Compatibility alias for timelinekit.apply_edits. Same schema and handler; prefer timelinekit.apply_edits."
    )

    // MARK: inspect

    static let inspect = MCPTool(
        name: "timelinekit.inspect",
        description: "Read a timeline JSON file and return a structured summary: duration, tracks, segments, transitions, materials count, and canvas dimensions.",
        parameters: [
            "path": MCPParameter(name: "path", description: "Path to the timeline .json file", type: "string")
        ],
        execute: { args in
            guard let path = args["path"]?.stringValue else { throw MCPError(-32602, "Missing 'path' parameter") }
            let timeline = try readTimeline(from: path)
            let trackInfo = timeline.tracks.map { t in "\(t.label) (\(String(describing: t.kind))): \(t.segments.count) segments" }
            return .text(jsonString(from: [
                "timelineID": timeline.id.uuidString, "duration": timeline.duration,
                "canvas": ["width": timeline.canvas.width, "height": timeline.canvas.height],
                "trackCount": timeline.tracks.count,
                "totalSegments": timeline.tracks.reduce(0) { $0 + $1.segments.count },
                "transitionCount": timeline.transitions.count, "materialCount": timeline.materials.count,
                "tracks": trackInfo
            ]))
        }
    )

    // MARK: import_media

    static let importMedia = MCPTool(
        name: "timelinekit.import_media",
        description: "Import media files (images/videos) to create an editable timeline draft. Returns the draft ID, timeline ID, duration, and output path.",
        parameters: [
            "files": MCPParameter(name: "files", description: "Array of absolute file paths to media", type: "array"),
            "output": MCPParameter(name: "output", description: "Output path for the draft JSON (optional)", type: "string"),
            "canvas_width": MCPParameter(name: "canvas_width", description: "Canvas width (default: 720)", type: "integer"),
            "canvas_height": MCPParameter(name: "canvas_height", description: "Canvas height (default: 1280)", type: "integer"),
            "fps": MCPParameter(name: "fps", description: "Frames per second (default: 30)", type: "integer"),
            "image_duration": MCPParameter(name: "image_duration", description: "Default still image duration in seconds (default: 3)", type: "number")
        ],
        execute: { args in
            let files = args["files"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            guard !files.isEmpty else { throw MCPError(-32602, "Missing 'files' parameter") }
            let canvas = EditorCanvas(width: args["canvas_width"]?.intValue ?? 720, height: args["canvas_height"]?.intValue ?? 1280, fps: args["fps"]?.intValue ?? 30)
            let imageDuration = (args["image_duration"]?.intValue).map(Double.init) ?? (args["image_duration"]?.stringValue.flatMap(Double.init)) ?? 3.0
            let urls = files.map { resolvePath($0) }
            let timeline = try await TimelineImporter.importingMedia(from: urls, canvas: canvas, imageDuration: imageDuration)
            let outputPath = args["output"]?.stringValue ?? "draft_\(timeline.id.uuidString).json"
            try writeTimeline(timeline, to: outputPath)
            let draftID = DraftStore.save(timeline)
            return .text(jsonString(from: [
                "timelineID": timeline.id.uuidString, "draftID": draftID.uuidString,
                "duration": timeline.duration, "tracks": timeline.tracks.count,
                "totalSegments": timeline.tracks.reduce(0) { $0 + $1.segments.count }, "output": outputPath
            ]))
        }
    )

    // MARK: render

    static let render = MCPTool(
        name: "timelinekit.render",
        description: "Render a timeline to MP4 video. Requires UIKit (iOS/macOS Catalyst).",
        parameters: [
            "path": MCPParameter(name: "path", description: "Path to timeline JSON", type: "string"),
            "output": MCPParameter(name: "output", description: "Output MP4 path", type: "string")
        ],
        execute: { args in
            guard let path = args["path"]?.stringValue else { throw MCPError(-32602, "Missing 'path'") }
            guard args["output"]?.stringValue != nil else { throw MCPError(-32602, "Missing 'output'") }
#if canImport(UIKit)
            let timeline = try readTimeline(from: path)
            let exporter = VideoExporter()
            await exporter.export(timeline: timeline)
            return .text(jsonString(from: ["rendered": true, "duration": timeline.duration]))
#else
            throw MCPError(-32601, "Render requires UIKit. Available on iOS/macOS Catalyst.")
#endif
        }
    )

    // MARK: thumbnail

    static let thumbnail = MCPTool(
        name: "timelinekit.thumbnail",
        description: "Generate a thumbnail image from a timeline at a specific time. Requires UIKit.",
        parameters: [
            "path": MCPParameter(name: "path", description: "Path to timeline JSON", type: "string"),
            "time": MCPParameter(name: "time", description: "Time position in seconds", type: "number")
        ],
        execute: { args in
            guard let path = args["path"]?.stringValue else { throw MCPError(-32602, "Missing 'path'") }
            let time = args["time"]?.doubleValue ?? 0.0
            guard time > 0 else { throw MCPError(-32602, "Missing or zero 'time' parameter") }
#if canImport(UIKit)
            let timeline = try readTimeline(from: path)
            let provider = ThumbnailProvider()
            for track in timeline.tracks {
                for seg in track.segments {
                    if let asset = timeline.materials[seg.materialID], let assetURL = asset.bestURL {
                        if let _ = await provider.thumbnail(for: assetURL, isImage: asset.type == .image, at: time, size: CGSize(width: 360, height: 640)) {
                            return .text(jsonString(from: ["generated": true, "time": time]))
                        }
                    }
                }
            }
            throw MCPError(-32603, "No renderable media at time \(time)")
#else
            throw MCPError(-32601, "Thumbnail requires UIKit.")
#endif
        }
    )

    // MARK: validate

    static let validate = MCPTool(
        name: "timelinekit.validate",
        description: "Validate a timeline JSON file for structural issues: overlapping segments, missing materials, invalid transitions, empty tracks.",
        parameters: [
            "path": MCPParameter(name: "path", description: "Path to the timeline JSON file", type: "string")
        ],
        execute: { args in
            guard let path = args["path"]?.stringValue else { throw MCPError(-32602, "Missing 'path'") }
            let timeline = try readTimeline(from: path)
            var issues: [[String: Any]] = []

            if timeline.tracks.isEmpty { issues.append(["severity": "error", "message": "No tracks"]) }
            if timeline.tracks.filter(\.isMainTrack).isEmpty { issues.append(["severity": "warning", "message": "No main video track"]) }
            if timeline.tracks.flatMap(\.segments).isEmpty { issues.append(["severity": "warning", "message": "No segments"]) }

            for t in timeline.tracks {
                let sorted = t.segments.sorted { $0.targetRange.start < $1.targetRange.start }
                for i in 0..<(sorted.count - 1) where sorted[i].targetRange.end > sorted[i + 1].targetRange.start {
                    issues.append(["severity": "error", "track": t.label, "message": "Overlapping segments"])
                }
            }
            for s in timeline.tracks.flatMap(\.segments) where timeline.materials[s.materialID] == nil {
                issues.append(["severity": "error", "segmentID": s.id.uuidString, "message": "Missing material"])
            }
            for trans in timeline.transitions {
                if timeline.segment(id: trans.leadingSegmentID) == nil || timeline.segment(id: trans.trailingSegmentID) == nil {
                    issues.append(["severity": "error", "transitionID": trans.id.uuidString, "message": "Invalid transition"])
                }
            }

            return .text(jsonString(from: [
                "timelineID": timeline.id.uuidString, "duration": timeline.duration,
                "valid": !issues.contains(where: { ($0["severity"] as? String) == "error" }),
                "errorCount": issues.filter { ($0["severity"] as? String) == "error" }.count,
                "warningCount": issues.filter { ($0["severity"] as? String) == "warning" }.count,
                "issues": issues
            ]))
        }
    )
}

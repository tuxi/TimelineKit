import Foundation
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared

// MARK: - Tool Types (all Sendable)

struct MCPParameter: Sendable {
    let name: String
    let description: String
    let type: String
    var schema: [String: JSONValue] {
        ["type": .string(type), "description": .string(description)]
    }
}

struct MCPTool: @unchecked Sendable {
    let name: String
    let description: String
    let parameters: [String: MCPParameter]
    let execute: @MainActor @Sendable ([String: JSONValue]) async throws -> MCPToolResult

    var requiredParams: [String] { Array(parameters.keys) }
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
    static let all: [MCPTool] = [inspect, importMedia, applyEdits, render, thumbnail, validate]

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

    // MARK: apply_edits

    static let applyEdits = MCPTool(
        name: "timelinekit.apply_edits",
        description: """
        Apply edit operations to a timeline draft and save. Supported operations:
          delete_segment (segment_id), trim_segment (segment_id, target_start, target_duration),
          move_segment (segment_id, new_start), split_segment (segment_id, at_time),
          add_text (playhead, text, duration), add_subtitle (playhead, text, duration),
          set_audio_volume (segment_id, volume), add_transition (leading_id, trailing_id, duration)
        """,
        parameters: [
            "path": MCPParameter(name: "path", description: "Path to the timeline JSON", type: "string"),
            "operations": MCPParameter(name: "operations", description: "Array of edit operation objects", type: "array")
        ],
        execute: { args in
            guard let path = args["path"]?.stringValue else { throw MCPError(-32602, "Missing 'path'") }
            guard let ops = args["operations"]?.arrayValue, !ops.isEmpty else { throw MCPError(-32602, "Missing 'operations' array") }
            let timeline = try readTimeline(from: path)
            let doc = TimelineDocument(timeline: timeline)
            var applied: [String] = []

            for op in ops {
                guard let o = op.objectValue, let opType = o["op"]?.stringValue else { continue }
                switch opType {
                case "delete_segment":
                    if let sid = o["segment_id"]?.stringValue, let id = UUID(uuidString: sid) { doc.deleteSegment(id: id); applied.append("deleted:\(sid)") }
                case "trim_segment":
                    if let sid = o["segment_id"]?.stringValue, let id = UUID(uuidString: sid),
                       let start = o["target_start"]?.stringValue.flatMap(Double.init),
                       let dur = o["target_duration"]?.stringValue.flatMap(Double.init) {
                        doc.trimSegment(id: id, newTargetRange: TimeRange(start: start, duration: dur)); applied.append("trimmed:\(sid)")
                    }
                case "move_segment":
                    if let sid = o["segment_id"]?.stringValue, let id = UUID(uuidString: sid),
                       let newStart = o["new_start"]?.stringValue.flatMap(Double.init) {
                        doc.moveSegment(id: id, to: newStart); applied.append("moved:\(sid)")
                    }
                case "split_segment":
                    if let sid = o["segment_id"]?.stringValue, let id = UUID(uuidString: sid),
                       let at = o["at_time"]?.stringValue.flatMap(Double.init),
                       let newID = doc.splitSegment(id: id, at: at) { applied.append("split:\(sid)->\(newID)") }
                case "add_text":
                    let playhead = o["playhead"]?.doubleValue ?? 0
                    let text = o["text"]?.stringValue ?? "New text"
                    let dur = o["duration"]?.doubleValue ?? 3.0
                    let seg = EditorSegment(id: UUID(), materialID: UUID(), targetRange: TimeRange(start: playhead, duration: dur), content: .text(SegmentContent.TextContent(text: text, style: .default, position: .center, anchor: .center)))
                    _ = doc.addSegmentAutoTrack(kind: .text, segment: seg); applied.append("text@\(playhead)")
                case "add_subtitle":
                    let playhead = o["playhead"]?.doubleValue ?? 0
                    let text = o["text"]?.stringValue ?? "New subtitle"
                    let dur = o["duration"]?.doubleValue ?? 3.0
                    let seg = EditorSegment(id: UUID(), materialID: UUID(), targetRange: TimeRange(start: playhead, duration: dur), content: .subtitle(SegmentContent.SubtitleContent(text: text, style: .default)))
                    _ = doc.addSegmentAutoTrack(kind: .subtitle, segment: seg); applied.append("subtitle@\(playhead)")
                case "set_audio_volume":
                    if let sid = o["segment_id"]?.stringValue, let id = UUID(uuidString: sid),
                       let vol = o["volume"]?.stringValue.flatMap(Double.init) { doc.setAudioVolume(segmentID: id, volume: vol); applied.append("volume:\(sid)=\(vol)") }
                case "add_transition":
                    if let lid = o["leading_id"]?.stringValue, let leading = UUID(uuidString: lid),
                       let tid = o["trailing_id"]?.stringValue, let trailing = UUID(uuidString: tid),
                       let dur = o["duration"]?.stringValue.flatMap(Double.init) {
                        if let t = doc.addTransition(between: leading, and: trailing, type: .fade, duration: dur) { applied.append("transition:\(t.id)") }
                    }
                default: throw MCPError(-32602, "Unknown operation: \(opType)")
                }
            }

            try writeTimeline(doc.timeline, to: path)
            return .text(jsonString(from: ["applied": applied.count, "operations": applied, "timelineID": doc.timeline.id.uuidString, "duration": doc.timeline.duration]))
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

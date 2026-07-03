import Foundation
import TimelineKitCore

log("timelinekit-mcp v\(timelineKitCoreVersion)")

let srv = MCPServer()

// Use FileHandle for non-buffered stdin reading
let stdin = FileHandle.standardInput
stdin.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else {
        // EOF — stdin closed
        log("stdin closed")
        stdin.readabilityHandler = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        return
    }
    // Process each line in the data
    let text = String(data: data, encoding: .utf8) ?? ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let lineData = line.data(using: .utf8) else { continue }
        Task { @MainActor in await srv.process(data: lineData) }
    }
}

dispatchMain()

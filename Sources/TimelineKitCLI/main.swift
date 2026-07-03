import Foundation
import Dispatch

// MARK: - timelinekit CLI (M5 MVP)

let args = CommandLine.arguments
guard args.count >= 2 else {
    CLI.fail(1, "Usage: timelinekit <command> [options]")
}

let command = args[1]
let opts = Options(args: Array(args.dropFirst(2)))

if command == "help" || command == "-h" || command == "--help" {
    Commands.help()
    Darwin.exit(0)
}

DispatchQueue.main.async {
    Task { @MainActor in
        do {
            switch command {
            case "inspect":     try await Commands.inspect(opts)
            case "import-media": try await Commands.importMedia(opts)
            case "export-json":  try await Commands.exportJSON(opts)
            case "render":       try await Commands.render(opts)
            case "thumbnail":    try await Commands.thumbnail(opts)
            case "waveform":     try await Commands.waveform(opts)
            case "validate":     try await Commands.validate(opts)
            default: CLI.fail(1, "Unknown command: \(command)")
            }
            Darwin.exit(0)
        } catch {
            CLI.fail(2, error.localizedDescription)
        }
    }
}

dispatchMain()

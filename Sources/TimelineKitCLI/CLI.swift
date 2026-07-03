import Foundation

// MARK: - CLI Output

/// All CLI output goes through this type to guarantee stable JSON on stdout.
enum CLI {

    // MARK: - Output helpers

    /// Write a successful result as JSON to stdout.
    static func ok(_ payload: [String: Any]) {
        var dict = payload
        dict["ok"] = true
        writeJSON(dict)
    }

    /// Write a failure result as JSON to stdout, then exit.
    static func fail(_ code: Int, _ message: String, details: [String: Any] = [:]) -> Never {
        var dict = details
        dict["ok"] = false
        dict["error"] = message
        dict["code"] = code
        writeJSON(dict)
        fflush(stdout)
        Darwin.exit(Int32(code))
    }

    /// Write progress/log messages to stderr (never stdout, to keep JSON clean).
    static func log(_ message: String) {
        var stderr = FileHandle.standardError
        if let data = (message + "\n").data(using: .utf8) {
            try? stderr.write(contentsOf: data)
        }
    }

    // MARK: - Private

    private static func writeJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8) else {
            print("{\"ok\":false,\"error\":\"JSON encoding failed\"}")
            return
        }
        print(json)
    }
}

import Foundation
import TimelineKitCore
import TimelineKitRender
import TimelineKitUIShared

// MARK: - Logging

func log(_ message: String) {
    let line = "[timelinekit-mcp] \(message)\n"
    if let data = line.data(using: .utf8) {
        try? FileHandle.standardError.write(contentsOf: data)
    }
}

// MARK: - JSON-RPC Types

struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String
    let id: Int?
    let method: String?
    let params: [String: JSONValue]?
}

struct JSONRPCResponse: Codable, Sendable {
    let jsonrpc = "2.0"
    let id: Int?
    var result: [String: JSONValue]? = nil
    var error: JSONRPCError? = nil
}

struct JSONRPCError: Codable, Sendable { let code: Int; let message: String }

enum JSONValue: Codable, Sendable {
    case string(String), int(Int), double(Double), bool(Bool)
    case object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if c.decodeNil() { self = .null }
        else { throw DecodingError.typeMismatch(JSONValue.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown JSON value")) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }
    var intValue: Int? { if case .int(let v) = self { return v } else { return nil } }
    var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v } else { return nil } }
    var arrayValue: [JSONValue]? { if case .array(let v) = self { return v } else { return nil } }
    var doubleValue: Double? {
        if case .int(let v) = self { return Double(v) }
        if case .double(let v) = self { return v }
        if case .string(let v) = self { return Double(v) }
        return nil
    }
}

// MARK: - MCP Server

@MainActor
final class MCPServer {
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return e }()
    private let decoder = JSONDecoder()
    private var initialized = false

    init() { log("ready") }

    func process(data: Data) async {
        guard let req = try? decoder.decode(JSONRPCRequest.self, from: data) else {
            log("Parse error: \(String(data: data, encoding: .utf8)?.prefix(100) ?? "?")"); return
        }

        guard let id = req.id, let method = req.method else {
            if let m = req.method {
                if m == "notifications/initialized" { initialized = true; log("initialized") }
            }
            return
        }

        do {
            let result = try await dispatch(method, params: req.params ?? [:])
            send(JSONRPCResponse(id: id, result: result))
        } catch let e as MCPError {
            send(JSONRPCResponse(id: id, error: JSONRPCError(code: e.code, message: e.message)))
        } catch {
            send(JSONRPCResponse(id: id, error: JSONRPCError(code: -32603, message: error.localizedDescription)))
        }
    }

    nonisolated func flush() {}

    private func dispatch(_ method: String, params: [String: JSONValue]) async throws -> [String: JSONValue] {
        switch method {
        case "initialize": return await doInit(params)
        case "tools/list": return await doToolsList()
        case "tools/call": return try await doToolCall(params)
        default: throw MCPError(-32601, "Method not found: \(method)")
        }
    }

    private func doInit(_ params: [String: JSONValue]) async -> [String: JSONValue] {
        log("initialize from \(params["clientInfo"]?.objectValue?["name"]?.stringValue ?? "?")")
        return [
            "protocolVersion": .string("2024-11-05"),
            "serverInfo": .object(["name": .string("timelinekit-mcp"), "version": .string(timelineKitCoreVersion)]),
            "capabilities": .object(["tools": .object([:])])
        ]
    }

    private func doToolsList() async -> [String: JSONValue] {
        let defs = MCPTools.all.map { t in JSONValue.object([
            "name": .string(t.name), "description": .string(t.description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(t.parameters.mapValues { .object($0.schema) }),
                "required": .array(t.requiredParams.map { .string($0) })
            ])
        ])}
        return ["tools": .array(defs)]
    }

    private func doToolCall(_ params: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let name = params["name"]?.stringValue else { throw MCPError(-32602, "Missing tool name") }
        guard let tool = MCPTools.all.first(where: { $0.name == name }) else { throw MCPError(-32602, "Unknown tool: \(name)") }
        let args = params["arguments"]?.objectValue ?? [:]
        log("call: \(name)")

        do {
            let result = try await tool.execute(args)
            var resp: [String: JSONValue] = ["content": .array(result.content.map { .object($0.json) })]
            if let meta = result.metadata { resp["structuredContent"] = .object(meta) }
            return resp
        } catch let e as MCPError {
            return errResult(e.message)
        } catch {
            return errResult(error.localizedDescription)
        }
    }

    private func errResult(_ msg: String) -> [String: JSONValue] {
        ["content": .array([.object(["type": .string("text"), "text": .string("Error: \(msg)")])]), "isError": .bool(true)]
    }

    private func send(_ r: JSONRPCResponse) {
        guard let d = try? encoder.encode(r), let j = String(data: d, encoding: .utf8) else { return }
        print(j); fflush(stdout)
    }
}

struct MCPError: Error, Sendable { let code: Int; let message: String; init(_ c: Int, _ m: String) { code = c; message = m } }

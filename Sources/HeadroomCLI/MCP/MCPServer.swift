import Foundation
import HeadroomCore

/// A JSON document without `Any`: requests are decoded into it and narrowed case by case.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? c.decode(Double.self) {
            self = .double(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(value): try c.encode(value)
        case let .int(value): try c.encode(value)
        case let .double(value): try c.encode(value)
        case let .string(value): try c.encode(value)
        case let .array(value): try c.encode(value)
        case let .object(value): try c.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case let .object(fields) = self else { return nil }
        return fields[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard case let .array(items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var doubleValue: Double? {
        switch self {
        case let .int(value): Double(value)
        case let .double(value): value
        default: nil
        }
    }
}

/// `headroom mcp`: a read-only MCP server over newline-delimited JSON-RPC 2.0 on stdio. It speaks the
/// initialize-based (legacy) protocol revisions; dual-era clients probe with `server/discover`, get -32601 and
/// fall back to `initialize`.
final class MCPServer {
    /// Newest first. An unknown requested version is answered with the first, as the spec's negotiation requires.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let paths: Paths
    private let now: @Sendable () -> Double
    private let calendar = Calendar.current
    private var initialized = false

    init(paths: Paths, now: @escaping @Sendable () -> Double) {
        self.paths = paths
        self.now = now
    }

    private struct RPCError: Encodable {
        let code: Int
        let message: String
    }

    private struct Response: Encodable {
        let jsonrpc = "2.0"
        let id: JSONValue
        let result: JSONValue?
        let error: RPCError?
    }

    /// Longest line accepted. A longer one is answered with a single parse error and skipped up to its newline, so
    /// a runaway client can't grow the buffer without bound.
    static let maxLineBytes = 1 << 20

    func serve(input: FileHandle, output: FileHandle) {
        func write(_ reply: Data?) -> Bool {
            guard let reply else { return true }
            return (try? output.write(contentsOf: reply + Data([0x0A]))) != nil
        }
        func respond(_ line: Data) -> Bool {
            if line.count > Self.maxLineBytes { return write(parseError) }
            guard line.contains(where: { !Self.isSpace($0) }) else { return true }
            return write(handle(line: line))
        }

        // `buffer` stays zero-based: it is only appended to, or rebuilt from its unconsumed tail once per chunk.
        var buffer = Data()
        var scanFrom = 0
        var discarding = false
        var chunk = [UInt8](repeating: 0, count: 65_536)
        // read(2) returns whatever the pipe holds. FileHandle.read(upToCount:) waits for the full count or EOF, so a
        // client that keeps stdin open would never see a reply.
        while true {
            let count = chunk.withUnsafeMutableBytes { read(input.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[..<count])
            var lineStart = 0
            while let newline = buffer[scanFrom...].firstIndex(of: 0x0A) {
                if discarding {
                    discarding = false
                } else {
                    guard respond(buffer[lineStart..<newline]) else { return }
                }
                lineStart = newline + 1
                scanFrom = lineStart
            }
            if !discarding, buffer.count - lineStart > Self.maxLineBytes {
                guard write(parseError) else { return }
                discarding = true
            }
            if discarding { lineStart = buffer.count }
            buffer = Data(buffer[lineStart...])
            scanFrom = buffer.count
        }
        if !discarding { _ = respond(buffer) }
    }

    private var parseError: Data? { reply(id: .null, error: RPCError(code: -32700, message: "parse error")) }

    func handle(line: Data) -> Data? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            return parseError
        }
        guard case let .object(fields) = message else {
            return reply(id: .null, error: RPCError(code: -32600, message: "invalid request"))
        }
        let id = fields["id"]
        // A reply to a request this server never sends has no method; there is nothing to answer.
        if fields["method"] == nil, fields["result"] != nil || fields["error"] != nil { return nil }
        guard fields["jsonrpc"] == .string("2.0"), let method = fields["method"]?.stringValue else {
            return reply(id: Self.validId(id) ?? .null, error: RPCError(code: -32600, message: "invalid request"))
        }
        guard let id else { return nil }
        guard let requestId = Self.validId(id) else {
            return reply(id: .null, error: RPCError(code: -32600, message: "invalid request id"))
        }
        let params = fields["params"]

        switch method {
        case "initialize":
            initialized = true
            let requested = params?["protocolVersion"]?.stringValue
            let version = requested.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            return reply(
                id: requestId,
                result: .object([
                    "protocolVersion": .string(version),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object(["name": .string("headroom"), "version": .string(HeadroomVersion.current)]),
                ]))
        case "ping":
            return reply(id: requestId, result: .object([:]))
        case "tools/list":
            return reply(id: requestId, result: .object(["tools": MCPTools.definitions]))
        case "tools/call":
            guard initialized else { return reply(id: requestId, error: RPCError(code: -32002, message: "not initialized")) }
            guard let name = params?["name"]?.stringValue else {
                return reply(id: requestId, error: RPCError(code: -32602, message: "tools/call needs a tool name"))
            }
            let arguments: [String: JSONValue]
            switch params?["arguments"] {
            case nil, .null?: arguments = [:]
            case let .object(value)?: arguments = value
            default: return reply(id: requestId, error: RPCError(code: -32602, message: "arguments must be an object"))
            }
            let outcome: (text: String, isError: Bool)
            do {
                outcome = try MCPTools.call(name: name, arguments: arguments, paths: paths, now: now(), calendar: calendar)
            } catch {
                switch error {
                case let .unknownTool(message): return reply(id: requestId, error: RPCError(code: -32602, message: message))
                case let .invalidArguments(message): outcome = (message, true)
                }
            }
            return reply(
                id: requestId,
                result: .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(outcome.text)])]),
                    "isError": .bool(outcome.isError),
                ]))
        default:
            return reply(id: requestId, error: RPCError(code: -32601, message: "method not found: \(method)"))
        }
    }

    private static func validId(_ id: JSONValue?) -> JSONValue? {
        switch id {
        case .string?, .int?, .double?: id
        default: nil
        }
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A }

    private func reply(id: JSONValue, result: JSONValue? = nil, error: RPCError? = nil) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(Response(id: id, result: result, error: error))
    }
}

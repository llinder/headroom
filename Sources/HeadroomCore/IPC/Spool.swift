import Foundation

public enum SpoolRecord: Codable, Sendable, Equatable {
    case tag(ts: Double, text: String)
    case command(ts: Double, exe: String, seconds: Double)
    case agentSession(ts: Double, tool: String, sessionId: String, model: String?, rootPid: Int32, rootStart: UInt64)

    private enum CodingKeys: String, CodingKey {
        case type, ts, text, exe, seconds, tool, sessionId, model, rootPid, rootStart
    }

    private enum Kind: String, Codable {
        case tag, command, agentSession
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .tag:
            self = .tag(ts: try c.decode(Double.self, forKey: .ts), text: try c.decode(String.self, forKey: .text))
        case .command:
            self = .command(
                ts: try c.decode(Double.self, forKey: .ts),
                exe: try c.decode(String.self, forKey: .exe),
                seconds: try c.decode(Double.self, forKey: .seconds))
        case .agentSession:
            self = .agentSession(
                ts: try c.decode(Double.self, forKey: .ts),
                tool: try c.decode(String.self, forKey: .tool),
                sessionId: try c.decode(String.self, forKey: .sessionId),
                model: try c.decodeIfPresent(String.self, forKey: .model),
                rootPid: try c.decode(Int32.self, forKey: .rootPid),
                rootStart: try c.decode(UInt64.self, forKey: .rootStart))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .tag(ts, text):
            try c.encode(Kind.tag, forKey: .type)
            try c.encode(ts, forKey: .ts)
            try c.encode(text, forKey: .text)
        case let .command(ts, exe, seconds):
            try c.encode(Kind.command, forKey: .type)
            try c.encode(ts, forKey: .ts)
            try c.encode(exe, forKey: .exe)
            try c.encode(seconds, forKey: .seconds)
        case let .agentSession(ts, tool, sessionId, model, rootPid, rootStart):
            try c.encode(Kind.agentSession, forKey: .type)
            try c.encode(ts, forKey: .ts)
            try c.encode(tool, forKey: .tool)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encodeIfPresent(model, forKey: .model)
            try c.encode(rootPid, forKey: .rootPid)
            try c.encode(rootStart, forKey: .rootStart)
        }
    }
}

/// Producers append one line with a single O_APPEND write; only headroomd drains.
public struct Spool: Sendable {
    /// A single write up to PIPE_BUF is atomic under O_APPEND, so lines never interleave.
    private static let maxLineBytes = 4096

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    private var ingestingPath: String { url.path + ".ingesting" }

    @discardableResult
    public func append(_ r: SpoolRecord) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard var line = try? encoder.encode(r) else { return false }
        line.append(0x0A)
        guard line.count <= Self.maxLineBytes else { return false }

        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return written == line.count
    }

    /// Drains one cycle behind: the previous cycle's renamed file is read first, so a
    /// writer that opened the file just before the rename has had a full cycle to finish.
    public func drain() -> (records: [SpoolRecord], malformed: Int) {
        var records: [SpoolRecord] = []
        var malformed = 0

        if let data = FileManager.default.contents(atPath: ingestingPath) {
            let decoder = JSONDecoder()
            let pieces = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            for (i, piece) in pieces.enumerated() {
                if i == pieces.count - 1 && piece.isEmpty { continue }
                if let record = try? decoder.decode(SpoolRecord.self, from: Data(piece)) {
                    records.append(record)
                } else {
                    malformed += 1
                }
            }
            unlink(ingestingPath)
        }

        rename(url.path, ingestingPath)
        return (records, malformed)
    }
}

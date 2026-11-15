import Foundation

/// What made the advice hook speak. The raw values are stored in `agent_warning` payloads.
public enum AdviceTrigger: String, Codable, Sendable, CaseIterable {
    case critical, swapGrowing, leftovers
}

public enum SpoolRecord: Codable, Sendable, Equatable {
    case tag(ts: Double, text: String)
    case command(ts: Double, exe: String, seconds: Double)
    case agentSession(ts: Double, tool: String, sessionId: String, model: String?, rootPid: Int32, rootStart: UInt64)
    /// `trigger` is nil in records written before it was added.
    case agentWarning(ts: Double, trigger: AdviceTrigger?)
    /// `start` marks commands that start containers, the only ones that can make a run an item's owner. It is
    /// false in records written before it was added.
    case containerIntent(ts: Double, rootPid: Int32, rootStart: UInt64, start: Bool)

    private enum CodingKeys: String, CodingKey {
        case type, ts, text, exe, seconds, tool, sessionId, model, rootPid, rootStart, trigger, start
    }

    private enum Kind: String, Codable {
        case tag, command, agentSession, agentWarning, containerIntent
    }

    public init(from decoder: any Decoder) throws {
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
        case .agentWarning:
            // An unknown trigger from a newer hook still counts as a warning.
            self = .agentWarning(
                ts: try c.decode(Double.self, forKey: .ts),
                trigger: try c.decodeIfPresent(String.self, forKey: .trigger).flatMap(AdviceTrigger.init(rawValue:)))
        case .containerIntent:
            self = .containerIntent(
                ts: try c.decode(Double.self, forKey: .ts),
                rootPid: try c.decode(Int32.self, forKey: .rootPid),
                rootStart: try c.decode(UInt64.self, forKey: .rootStart),
                start: try c.decodeIfPresent(Bool.self, forKey: .start) ?? false)
        }
    }

    public func encode(to encoder: any Encoder) throws {
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
        case let .agentWarning(ts, trigger):
            try c.encode(Kind.agentWarning, forKey: .type)
            try c.encode(ts, forKey: .ts)
            try c.encodeIfPresent(trigger?.rawValue, forKey: .trigger)
        case let .containerIntent(ts, rootPid, rootStart, start):
            try c.encode(Kind.containerIntent, forKey: .type)
            try c.encode(ts, forKey: .ts)
            try c.encode(rootPid, forKey: .rootPid)
            try c.encode(rootStart, forKey: .rootStart)
            try c.encode(start, forKey: .start)
        }
    }
}

/// Producers append one line with a single O_APPEND write; only headroomd drains.
public struct Spool: Sendable {
    /// O_APPEND seeks to end of file and writes in one step, and a single bounded write of
    /// at most this size makes a short write, and so interleaving between writers, practically impossible.
    private static let maxLineBytes = 4096
    /// Bounds what headroomd must read after a long stop; further appends are dropped.
    private static let maxFileBytes: Int64 = 16 * 1024 * 1024
    private static let maxWriteAttempts = 3

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

        var st = stat()
        guard fstat(fd, &st) == 0, Int64(st.st_size) <= Self.maxFileBytes else { return false }

        for _ in 0..<Self.maxWriteAttempts {
            let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written == line.count { return true }
            // EINTR means nothing was written, so retrying cannot duplicate a line.
            if written < 0 && errno == EINTR { continue }
            return false
        }
        return false
    }

    /// Drains one cycle behind: the previous cycle's renamed file is read first, so a
    /// writer that opened the file just before the rename has had a full cycle to finish.
    /// If that file can't be read, nothing is rotated, so an unread batch is never overwritten, and
    /// `drainFailed` says so: otherwise a stuck spool would look the same as an empty one.
    public func drain() -> (records: [SpoolRecord], malformed: Int, drainFailed: Bool) {
        var records: [SpoolRecord] = []
        var malformed = 0

        switch readIngesting() {
        case .failed:
            return ([], 0, true)
        case .missing:
            break
        case let .data(data):
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
        return (records, malformed, false)
    }

    private enum IngestingRead {
        case data(Data)
        case missing
        case failed
    }

    private func readIngesting() -> IngestingRead {
        let fd = open(ingestingPath, O_RDONLY | O_CLOEXEC)
        if fd < 0 { return errno == ENOENT ? .missing : .failed }
        defer { close(fd) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                data.append(buffer, count: n)
            } else if n == 0 {
                return .data(data)
            } else if errno != EINTR {
                return .failed
            }
        }
    }
}

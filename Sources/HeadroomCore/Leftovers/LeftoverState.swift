import Foundation

public struct EngineStatus: Codable, Sendable, Equatable {
    public var context: String
    public var socket: String
    public var lastPass: Double
    public var ok: Bool
    /// Consecutive failed list calls.
    public var failures: Int

    public init(context: String, socket: String, lastPass: Double, ok: Bool, failures: Int) {
        self.context = context
        self.socket = socket
        self.lastPass = lastPass
        self.ok = ok
        self.failures = failures
    }
}

public struct FlaggedItem: Codable, Sendable, Equatable {
    public var item: LeftoverItem
    public var startedAt: Double
    public var reason: String
    /// Estimated working set, read once when the stats call budget allows; nil until then.
    public var memoryBytes: UInt64?
    public var firstFlagged: Double

    public init(item: LeftoverItem, startedAt: Double, reason: String, memoryBytes: UInt64?, firstFlagged: Double) {
        self.item = item
        self.startedAt = startedAt
        self.reason = reason
        self.memoryBytes = memoryBytes
        self.firstFlagged = firstFlagged
    }
}

public struct KeptItem: Codable, Sendable, Equatable {
    public var key: String
    /// `keep list` or `label keep`.
    public var why: String

    public init(key: String, why: String) {
        self.key = key
        self.why = why
    }
}

/// The `leftovers.json` sidecar. It names containers, so it stays local and never goes into SQLite.
public struct LeftoverState: Codable, Sendable, Equatable {
    public var updated: Double
    public var engines: [EngineStatus]
    public var items: [FlaggedItem]
    public var kept: [KeptItem]
    public var keepWarning: String?
    /// Testcontainers session id to the last time its reaper was seen running.
    public var seenReapers: [String: Double]
    /// Start time per container ID, flagged or not, so a later pass doesn't spend its call budget inspecting it again.
    public var starts: [String: Double]
    /// Container ID to the time its inspect last failed, so one bad container can't take the budget every pass.
    public var inspectFailedAt: [String: Double]
    /// Container ID to the time its stats call last failed, with the same backoff as inspects.
    public var statsFailedAt: [String: Double]

    public init(
        updated: Double = 0, engines: [EngineStatus] = [], items: [FlaggedItem] = [], kept: [KeptItem] = [],
        keepWarning: String? = nil, seenReapers: [String: Double] = [:], starts: [String: Double] = [:],
        inspectFailedAt: [String: Double] = [:], statsFailedAt: [String: Double] = [:]
    ) {
        self.updated = updated
        self.engines = engines
        self.items = items
        self.kept = kept
        self.keepWarning = keepWarning
        self.seenReapers = seenReapers
        self.starts = starts
        self.inspectFailedAt = inspectFailedAt
        self.statsFailedAt = statsFailedAt
    }

    public var totalBytes: UInt64 {
        items.reduce(0) { LeftoverMonitor.saturatingAdd($0, $1.memoryBytes ?? 0) }
    }

    /// A missing or unreadable file is an empty state: the next pass rebuilds it from the engines.
    public static func load(from url: URL) -> LeftoverState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(LeftoverState.self, from: data)
        else { return LeftoverState() }
        return state
    }

    /// Readers such as the CLI may open the file at any time, so it is replaced by rename, never rewritten in place.
    /// It names containers and projects, so it is readable by the user only (0600).
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try PrivateFile.write(try encoder.encode(self), to: url)
    }
}

/// Sidecar files that name containers: written to a temp file at mode 0600, then renamed over the old one, so a
/// reader never sees a partial file and no one else can read it.
enum PrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
        else {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

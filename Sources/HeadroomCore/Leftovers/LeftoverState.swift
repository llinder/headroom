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
    /// Start time per item key, flagged or not, so a later pass doesn't spend its call budget inspecting it again.
    public var starts: [String: Double]

    public init(
        updated: Double = 0, engines: [EngineStatus] = [], items: [FlaggedItem] = [], kept: [KeptItem] = [],
        keepWarning: String? = nil, seenReapers: [String: Double] = [:], starts: [String: Double] = [:]
    ) {
        self.updated = updated
        self.engines = engines
        self.items = items
        self.kept = kept
        self.keepWarning = keepWarning
        self.seenReapers = seenReapers
        self.starts = starts
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
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

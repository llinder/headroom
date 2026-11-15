import Foundation

public struct Paths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `HEADROOM_ROOT` relocates everything, so tests and smoke runs never touch the real data directory.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        if let override = environment["HEADROOM_ROOT"], !override.isEmpty {
            return Paths(root: URL(filePath: override, directoryHint: .isDirectory))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Paths(root: support.appending(path: "headroom"))
    }

    public var database: URL { root.appending(path: "headroom.db") }
    public var liveState: URL { root.appending(path: "live.state") }
    public var spool: URL { root.appending(path: "spool.jsonl") }
    public var groups: URL { root.appending(path: "groups.json") }
    public var config: URL { root.appending(path: "config.json") }
    public var tiers: URL { root.appending(path: "tiers.json") }
    public var baseline: URL { root.appending(path: "baseline.json") }
    public var pretool: URL { root.appending(path: "pretool", directoryHint: .isDirectory) }

    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}

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
    public var leftovers: URL { root.appending(path: "leftovers.json") }
    public var keeps: URL { root.appending(path: "keeps.json") }
    public var pretool: URL { root.appending(path: "pretool", directoryHint: .isDirectory) }

    /// The root holds container and project names (`leftovers.json`, `keeps.json`), so it is the user's alone; an
    /// older install's looser directory is tightened.
    public func ensureRoot() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let mode = (try fm.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if mode & 0o077 != 0 { try fm.setAttributes([.posixPermissions: mode & 0o700], ofItemAtPath: root.path) }
    }
}

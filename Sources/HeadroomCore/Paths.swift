import Foundation

public struct Paths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func standard() -> Paths {
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

    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}

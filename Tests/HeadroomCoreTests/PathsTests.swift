import Foundation
import Testing
@testable import HeadroomCore

@Test func pathsLayout() {
    let paths = Paths(root: URL(filePath: "/tmp/hr"))
    #expect(paths.database.path == "/tmp/hr/headroom.db")
    #expect(paths.liveState.lastPathComponent == "live.state")
    #expect(paths.spool.lastPathComponent == "spool.jsonl")
    #expect(paths.groups.lastPathComponent == "groups.json")
    #expect(paths.config.lastPathComponent == "config.json")
    #expect(paths.tiers.lastPathComponent == "tiers.json")
    #expect(paths.baseline.lastPathComponent == "baseline.json")
}

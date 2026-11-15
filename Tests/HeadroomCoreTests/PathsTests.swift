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
    #expect(paths.pretool.path == "/tmp/hr/pretool")
}

@Test func pathsRootOverride() {
    #expect(Paths.standard(environment: ["HEADROOM_ROOT": "/tmp/hr-x"]).root.path == "/tmp/hr-x")
    #expect(Paths.standard(environment: ["HEADROOM_ROOT": ""]).root.lastPathComponent == "headroom")
    #expect(Paths.standard(environment: [:]).root.path.hasSuffix("Library/Application Support/headroom"))
}

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

@Test func ensureRootIsPrivate() throws {
    let fm = FileManager.default
    let parent = fm.temporaryDirectory.appending(path: "headroom-perm-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: parent) }
    let mode = { (url: URL) in (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int }

    let fresh = Paths(root: parent.appending(path: "fresh"))
    try fresh.ensureRoot()
    #expect(mode(fresh.root) == 0o700)

    let loose = parent.appending(path: "loose")
    try fm.createDirectory(at: loose, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try Paths(root: loose).ensureRoot()
    #expect(mode(loose) == 0o700)

    // A symlinked root is the user's own choice of location: chmod would follow it and change the target.
    let target = parent.appending(path: "target")
    try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let link = parent.appending(path: "link")
    try fm.createSymbolicLink(at: link, withDestinationURL: target)
    try Paths(root: link).ensureRoot()
    #expect(mode(target) == 0o755)
}

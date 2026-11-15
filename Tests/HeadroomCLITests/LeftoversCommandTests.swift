import Foundation
import Testing

@testable import HeadroomCLI
@testable import HeadroomCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private final class Sandbox {
    let paths: Paths
    var out: [String] = []
    var err: [String] = []

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "headroom-leftovers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths = Paths(root: dir)
    }

    deinit { try? FileManager.default.removeItem(at: paths.root) }
}

private func flagged(memory: UInt64?, started: Double) -> FlaggedItem {
    FlaggedItem(
        item: LeftoverItem(
            key: "docker/kind:dev", engine: "docker", kind: .kind, name: "dev", containerIDs: ["abc"], sessionId: nil,
            lifetime: nil, cleanup: ["kind delete cluster --name dev", "docker rm -f abc"]),
        startedAt: started, reason: "no owner", memoryBytes: memory, firstFlagged: started)
}

@Suite struct LeftoversCommandTests {
    @Test func leftoversCommandListsAndQuotes() throws {
        let box = try Sandbox()
        #expect(Leftovers.run(paths: box.paths, now: now, json: false, kept: false) { box.out.append($0) } == 0)
        #expect(box.out == ["no abandoned containers"])

        box.out = []
        let state = LeftoverState(items: [
            flagged(memory: 2_400_000_000, started: now.timeIntervalSince1970 - (3 * 86400 + 4 * 3600)),
            flagged(memory: nil, started: now.timeIntervalSince1970 - 42 * 60),
        ])
        try state.save(to: box.paths.leftovers)
        _ = Leftovers.run(paths: box.paths, now: now, json: false, kept: false) { box.out.append($0) }
        #expect(box.out == [
            "docker/kind dev · no owner · 2.4 GB · up 3d4h",
            "  kind delete cluster --name dev",
            "  docker rm -f abc",
            "docker/kind dev · no owner · memory unknown · up 42m",
            "  kind delete cluster --name dev",
            "  docker rm -f abc",
        ])
    }

    @Test func leftoversJSON() throws {
        let box = try Sandbox()
        let item = flagged(memory: 1_000_000_000, started: 100)
        try LeftoverState(items: [item]).save(to: box.paths.leftovers)
        _ = Leftovers.run(paths: box.paths, now: now, json: true, kept: false) { box.out.append($0) }
        #expect(box.out.count == 1)
        #expect(try JSONDecoder().decode([FlaggedItem].self, from: Data(box.out[0].utf8)) == [item])
    }

    @Test func keptListed() throws {
        let box = try Sandbox()
        try LeftoverState(kept: [KeptItem(key: "docker/kind:ci", why: "keep list")]).save(to: box.paths.leftovers)
        _ = Leftovers.run(paths: box.paths, now: now, json: false, kept: true) { box.out.append($0) }
        #expect(box.out == ["no abandoned containers", "docker/kind:ci · kept (keep list)"])
        box.out = []
        _ = Leftovers.run(paths: box.paths, now: now, json: false, kept: false) { box.out.append($0) }
        #expect(box.out == ["no abandoned containers"])
    }

    @Test func keepAddsEntryWithExpiry() throws {
        let box = try Sandbox()
        #expect(Leftovers.keep(name: "a", forSeconds: 3600, paths: box.paths, now: now, out: { box.out.append($0) }, err: { box.err.append($0) }) == 0)
        #expect(Leftovers.keep(name: "b", forSeconds: nil, paths: box.paths, now: now, out: { box.out.append($0) }, err: { box.err.append($0) }) == 0)
        #expect(KeepList.load(from: box.paths.keeps).0.entries == [
            KeepEntry(name: "a", until: now.timeIntervalSince1970 + 3600), KeepEntry(name: "b"),
        ])
        box.out = []
        _ = Leftovers.keeps(paths: box.paths, now: now, out: { box.out.append($0) }, err: { box.err.append($0) })
        #expect(box.out == ["a · until 2027-01-15T09:00:00Z", "b · kept forever"])
        #expect(box.err.isEmpty)
    }

    @Test func unkeepRemoves() throws {
        let box = try Sandbox()
        try KeepList(entries: [KeepEntry(name: "a"), KeepEntry(name: "b")]).save(to: box.paths.keeps)
        #expect(Leftovers.unkeep(name: "a", paths: box.paths, out: { box.out.append($0) }, err: { box.err.append($0) }) == 0)
        #expect(KeepList.load(from: box.paths.keeps).0.entries == [KeepEntry(name: "b")])
        #expect(Leftovers.unkeep(name: "zzz", paths: box.paths, out: { box.out.append($0) }, err: { box.err.append($0) }) == 1)
    }

    @Test func keepAndUnkeepRefuseUnreadableFile() throws {
        for content in [#"{"entries":[{"name":"a"},{"nope":1}]}"#, "not json"] {
            let box = try Sandbox()
            try Data(content.utf8).write(to: box.paths.keeps)
            let message = "keeps.json has unreadable entries; fix or remove them before changing the keep list"
            #expect(Leftovers.keep(name: "x", forSeconds: nil, paths: box.paths, now: now, out: { box.out.append($0) }, err: { box.err.append($0) }) == 1)
            #expect(Leftovers.unkeep(name: "a", paths: box.paths, out: { box.out.append($0) }, err: { box.err.append($0) }) == 1)
            #expect(box.err == [message, message])
            #expect(try Data(contentsOf: box.paths.keeps) == Data(content.utf8))
        }
    }
}

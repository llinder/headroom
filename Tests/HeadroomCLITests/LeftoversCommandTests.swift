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
            "  keep: headroom keep 'kind:dev'",
            "docker/kind dev · no owner · memory unknown · up 42m",
            "  kind delete cluster --name dev",
            "  docker rm -f abc",
            "  keep: headroom keep 'kind:dev'",
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

    @Test func leftoversJSONWithKept() throws {
        struct Both: Decodable, Equatable {
            let items: [FlaggedItem]
            let kept: [KeptItem]
        }
        let box = try Sandbox()
        let item = flagged(memory: 1_000_000_000, started: 100)
        let kept = KeptItem(key: "docker/kind:ci", why: "keep list")
        try LeftoverState(items: [item], kept: [kept]).save(to: box.paths.leftovers)
        _ = Leftovers.run(paths: box.paths, now: now, json: true, kept: true) { box.out.append($0) }
        #expect(box.out.count == 1)
        #expect(try JSONDecoder().decode(Both.self, from: Data(box.out[0].utf8)) == Both(items: [item], kept: [kept]))
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

    @Test func keptListsBuiltInIgnores() throws {
        let box = try Sandbox()
        let running = [
            DockerContainer(id: "b1", names: ["buildx_buildkit_default0"], image: "moby/buildkit:v0", labels: [:], state: "running"),
            DockerContainer(id: "r1", names: ["registry"], image: "registry.corp.example:5000/registry:2", labels: [:], state: "running"),
        ]
        let ignored = LeftoverGrouper.group(running, engine: "orb", ignore: IgnoreRules()).ignored
        try LeftoverState(kept: ignored).save(to: box.paths.leftovers)
        _ = Leftovers.run(paths: box.paths, now: now, json: false, kept: true) { box.out.append($0) }
        #expect(box.out == [
            "no abandoned containers",
            "orb/container/buildx_buildkit_default0 · kept (built-in ignore)",
            "orb/container/registry · kept (built-in ignore)",
        ])
        #expect(!box.out.joined().contains("corp.example"))
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

    @Test func keepLineUsesMatchableKeyAndQuoting() throws {
        let box = try Sandbox()
        func item(_ kind: LeftoverKind, _ name: String, names: [String] = []) -> FlaggedItem {
            FlaggedItem(
                item: LeftoverItem(
                    key: "k", engine: "docker", kind: kind, name: name, containerIDs: ["abc"], sessionId: nil, lifetime: nil,
                    cleanup: ["docker rm -f 'my name'"], containerNames: names),
                startedAt: 0, reason: "r", memoryBytes: nil, firstFlagged: 0)
        }
        try LeftoverState(items: [item(.compose, "shop"), item(.container, "web", names: ["it's web"])]).save(to: box.paths.leftovers)
        _ = Leftovers.run(paths: box.paths, now: now, json: false, kept: false) { box.out.append($0) }
        #expect(box.out.contains("  docker rm -f 'my name'"))
        #expect(box.out.contains("  keep: headroom keep 'compose:shop'"))
        #expect(box.out.contains("  keep: headroom keep 'it'\\''s web'"))
        let name = "it's web"
        #expect(KeepList(entries: [KeepEntry(name: name)]).covers(item(.container, "web", names: [name]).item, now: 0))
    }

    @Test func keepHintsAtMissingPrefix() throws {
        let box = try Sandbox()
        let group = FlaggedItem(
            item: LeftoverItem(
                key: "k", engine: "docker", kind: .kind, name: "dev", containerIDs: ["abc"], sessionId: nil, lifetime: nil,
                cleanup: []),
            startedAt: 0, reason: "r", memoryBytes: nil, firstFlagged: 0)
        let single = FlaggedItem(
            item: LeftoverItem(
                key: "k2", engine: "docker", kind: .container, name: "web", containerIDs: ["def"], sessionId: nil,
                lifetime: nil, cleanup: [], containerNames: ["web"]),
            startedAt: 0, reason: "r", memoryBytes: nil, firstFlagged: 0)
        try LeftoverState(items: [group, single]).save(to: box.paths.leftovers)
        func keep(_ name: String) -> Int32 {
            Leftovers.keep(name: name, forSeconds: nil, paths: box.paths, now: now, out: { box.out.append($0) }, err: { box.err.append($0) })
        }
        #expect(keep("dev") == 0)
        #expect(box.err == ["note: \"dev\" matches no container; did you mean headroom keep kind:dev?"])
        box.err = []
        #expect(keep("kind:dev") == 0)
        #expect(keep("web") == 0)
        #expect(keep("other") == 0)
        #expect(box.err.isEmpty)
        #expect(KeepList.load(from: box.paths.keeps).0.entries.map(\.name) == ["dev", "kind:dev", "web", "other"])
    }

    @Test func failingSavePrintsNoSuccessLine() throws {
        let box = try Sandbox()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: box.paths.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: box.paths.root.path) }
        #expect(Leftovers.keep(name: "a", forSeconds: nil, paths: box.paths, now: now, out: { box.out.append($0) }, err: { box.err.append($0) }) == 1)
        #expect(box.out.isEmpty && box.err.count == 1)
    }

    @Test func keepReplacesSameNameEntry() throws {
        let box = try Sandbox()
        try KeepList(entries: [KeepEntry(name: "a", until: 5), KeepEntry(name: "b")]).save(to: box.paths.keeps)
        #expect(Leftovers.keep(name: "a", forSeconds: nil, paths: box.paths, now: now, out: { box.out.append($0) }, err: { box.err.append($0) }) == 0)
        #expect(KeepList.load(from: box.paths.keeps).0.entries == [KeepEntry(name: "b"), KeepEntry(name: "a")])
    }

    @Test func keepForTwoHoursThroughRun() throws {
        let box = try Sandbox()
        // run() resolves paths from HEADROOM_ROOT-less standard(); the parsed command and Leftovers.keep are the seam.
        #expect(try parse(["headroom", "keep", "x", "--for", "2h"]) == .keep(name: "x", forSeconds: 7200))
        _ = Leftovers.keep(name: "x", forSeconds: 7200, paths: box.paths, now: now, out: { box.out.append($0) }, err: { box.err.append($0) })
        #expect(KeepList.load(from: box.paths.keeps).0.entries == [KeepEntry(name: "x", until: now.timeIntervalSince1970 + 7200)])
    }

    @Test func memoryRoundsLikeStatusLine() throws {
        let box = try Sandbox()
        try LeftoverState(items: [flagged(memory: 1_250_000_000, started: 0)]).save(to: box.paths.leftovers)
        _ = Leftovers.run(paths: box.paths, now: now, json: false, kept: false) { box.out.append($0) }
        #expect(box.out[0].contains("· 1.3 GB ·"))
    }
}

import Foundation
import Testing

@testable import HeadroomCore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appending(path: "keeptest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func items() -> [LeftoverItem] {
    let cs = [
        DockerContainer(id: "k1", names: ["dev-cp"], image: "n", labels: ["io.x-k8s.kind.cluster": "dev"], state: "running"),
        DockerContainer(id: "c1", names: ["web"], image: "n", labels: ["com.docker.compose.project": "shop"], state: "running"),
        DockerContainer(id: "abcdef0123456789", names: ["scratch"], image: "n", labels: [:], state: "running"),
    ]
    return LeftoverGrouper.group(cs, engine: "orbstack", ignore: IgnoreRules()).items
}

struct KeepListTests {
    @Test func keepListCoversByFormsAndExpires() {
        let all = items()
        let (kindItem, composeItem, single) = (all[0], all[1], all[2])
        let now = 1000.0
        func covers(_ name: String, _ item: LeftoverItem, until: Double? = nil) -> Bool {
            KeepList(entries: [KeepEntry(name: name, until: until)]).covers(item, now: now)
        }
        #expect(covers("kind:dev", kindItem))
        #expect(covers("orbstack/kind:dev", kindItem))
        #expect(!covers("kind:dev", composeItem))
        #expect(covers("compose:shop", composeItem))
        #expect(covers("orbstack/compose:shop", composeItem))
        #expect(!covers("compose:shop", kindItem))
        #expect(covers("scratch", single))
        #expect(covers("orbstack/scratch", single))
        #expect(covers("abcdef012345", single))
        #expect(!covers("abcdef0", single))
        #expect(!covers("other/scratch", single))
        #expect(covers("scratch", single, until: 2000))
        #expect(!covers("scratch", single, until: 500))
    }

    @Test func malformedKeepsIsEmptyWithWarning() throws {
        let url = try tempDir().appending(path: "keeps.json")
        try Data("{nope".utf8).write(to: url)
        let (list, warning) = KeepList.load(from: url)
        #expect(list.entries.isEmpty)
        #expect(warning != nil)
        let (missing, none) = KeepList.load(from: url.deletingLastPathComponent().appending(path: "absent.json"))
        #expect(missing.entries.isEmpty)
        #expect(none == nil)
    }

    @Test func lenientDecode() throws {
        let url = try tempDir().appending(path: "keeps.json")
        try Data("{}".utf8).write(to: url)
        let (empty, w1) = KeepList.load(from: url)
        #expect(empty.entries.isEmpty)
        #expect(w1 == nil)
        try Data(#"{"entries":[{"name":"a"},{"nope":1},{"name":"b","until":9}]}"#.utf8).write(to: url)
        let (list, w2) = KeepList.load(from: url)
        #expect(list.entries == [KeepEntry(name: "a"), KeepEntry(name: "b", until: 9)])
        #expect(w2 == nil)
    }

    @Test func keepSaveIsAtomic() throws {
        let dir = try tempDir()
        let url = dir.appending(path: "keeps.json")
        let list = KeepList(entries: [KeepEntry(name: "a", until: 5)])
        try list.save(to: url)
        try list.save(to: url)
        #expect(KeepList.load(from: url).0 == list)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["keeps.json"])
    }
}

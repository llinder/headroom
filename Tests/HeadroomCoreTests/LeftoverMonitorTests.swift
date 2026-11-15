import CryptoKit
import Foundation
import Testing

@testable import HeadroomCore

private typealias Route = FakeUnixHTTPServer.Route

private struct Box: Sendable {
    let id: String
    let name: String
    var labels: [String: String] = [:]
    var image = "img"
    var startedAt: Double
    var usage: UInt64 = 0
    var inactive: UInt64 = 0
}

private func ok(_ body: String) -> Route {
    Route(response: Array("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
}

private func hexID(_ n: Int) -> String { String(format: "%064x", n) }

private func rfc3339(_ ts: Double) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: Date(timeIntervalSince1970: ts.rounded(.down)))
}

private func json(_ value: Any) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
}

private func statsPath(_ id: String) -> String { "/containers/\(id)/stats?stream=false&one-shot=true" }

/// A route map for a Docker engine running `boxes`; `statsDelay` slows every stats reply.
private func engineRoutes(_ boxes: [Box], statsDelay: Double = 0) -> [String: Route] {
    let list: [[String: Any]] = boxes.map {
        ["Id": $0.id, "Names": ["/" + $0.name], "Image": $0.image, "Labels": $0.labels, "State": "running"]
    }
    var routes = ["/containers/json": ok(json(list))]
    for b in boxes {
        routes["/containers/\(b.id)/json"] = ok(json(["State": ["StartedAt": rfc3339(b.startedAt)]]))
        var stats = ok(json(["memory_stats": ["usage": b.usage, "stats": ["inactive_file": b.inactive]]]))
        stats.delay = statsDelay
        routes[statsPath(b.id)] = stats
    }
    return routes
}

private func ref(_ key: String) -> String {
    String(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
}

private final class TempDB {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-lm-\(UUID().uuidString).db").path

    init() throws {
        try Schema.migrate(Database(path: path, readOnly: false))
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    func facts(now: Double) -> (Double) -> OwnershipFacts? {
        let path = self.path
        return { since in
            guard let db = try? Database(path: path, readOnly: true) else { return nil }
            return try? Queries(db: db).ownershipFacts(machineId: "m1", since: since, now: now, idleThreshold: 3600)
        }
    }
}

private func monitor(_ servers: [(context: String, server: FakeUnixHTTPServer)], timeout: Double = 2) -> LeftoverMonitor {
    let engines = servers.map { DockerEngine(context: $0.context, socketPath: $0.server.socketPath) }
    return LeftoverMonitor(
        engines: { engines }, client: { DockerClient(socketPath: $0, timeout: timeout) }, config: LeftoversConfig())
}

private func wallNow() -> Double { Date().timeIntervalSince1970 }

@Suite struct LeftoverMonitorTests {
    private let day = 86_400.0

    @Test func flagsUnownedAfter24hAndEmitsEvent() throws {
        let now = wallNow()
        let old = Box(id: hexID(1), name: "old-one", startedAt: now - 25 * 3600, usage: 300 << 20, inactive: 100 << 20)
        let young = Box(id: hexID(2), name: "young-one", startedAt: now - 3600, usage: 50 << 20)
        let server = try FakeUnixHTTPServer(routes: engineRoutes([old, young]))
        defer { server.stop() }
        let db = try TempDB()
        let m = monitor([("default", server)])

        let first = m.pass(previous: LeftoverState(), facts: db.facts(now: now), keeps: KeepList(), now: now, deadline: wallNow() + 10)
        let key = "default/container/\(old.id)"
        #expect(first.state.items.map(\.item.key) == [key])
        let flagged = try #require(first.state.items.first)
        #expect(flagged.reason == "running for more than 24 hours with no agent owner")
        #expect(flagged.memoryBytes == 200 << 20)
        #expect(flagged.firstFlagged == now)
        #expect(abs(flagged.startedAt - old.startedAt.rounded(.down)) < 1)
        #expect(first.state.engines == [
            EngineStatus(context: "default", socket: server.socketPath, lastPass: now, ok: true, failures: 0),
        ])
        #expect(first.events.count == 1)
        #expect(first.events.first?.kind == "leftover")
        #expect(first.events.first?.payload == [
            "kind": "container", "ref": ref(key), "bytes": String(200 << 20), "totalBytes": String(200 << 20),
        ])
        // The young container is inspected but not flagged; stats are fetched only for the flagged one.
        #expect(!server.requests.contains(statsPath(young.id)))
        #expect(server.requests.contains("/containers/\(young.id)/json"))

        let before = server.requests.count
        let second = m.pass(previous: first.state, facts: db.facts(now: now + 300), keeps: KeepList(), now: now + 300,
                            deadline: wallNow() + 10)
        #expect(second.events.isEmpty)
        #expect(second.state.items.first?.firstFlagged == now)
        #expect(Array(server.requests[before...]) == ["/containers/json"], "known starts and memory are not fetched again")
    }

    @Test func clearsWhenContainerGone() throws {
        let now = wallNow()
        let box = Box(id: hexID(1), name: "gone-soon", startedAt: now - 2 * day, usage: 64 << 20)
        let full = try FakeUnixHTTPServer(routes: engineRoutes([box]))
        let empty = try FakeUnixHTTPServer(routes: engineRoutes([]))
        defer { full.stop(); empty.stop() }
        let db = try TempDB()

        let first = monitor([("orb", full)]).pass(
            previous: LeftoverState(), facts: db.facts(now: now), keeps: KeepList(), now: now, deadline: wallNow() + 10)
        let second = monitor([("orb", empty)]).pass(
            previous: first.state, facts: db.facts(now: now), keeps: KeepList(), now: now + 300, deadline: wallNow() + 10)

        #expect(second.state.items.isEmpty)
        #expect(second.events.count == 1)
        #expect(second.events.first?.kind == "leftover_cleared")
        #expect(second.events.first?.payload == [
            "kind": "container", "ref": ref("orb/container/\(box.id)"), "bytes": String(64 << 20), "totalBytes": "0",
        ])
        #expect(second.events.first?.payload["ref"] == first.events.first?.payload["ref"])
    }

    @Test func refusedEngineDropsItems() throws {
        let now = wallNow()
        let box = Box(id: hexID(1), name: "orphan", startedAt: now - 2 * day)
        let server = try FakeUnixHTTPServer(routes: engineRoutes([box]))
        let db = try TempDB()
        let m = monitor([("default", server)])

        let first = m.pass(previous: LeftoverState(), facts: db.facts(now: now), keeps: KeepList(), now: now, deadline: wallNow() + 10)
        #expect(first.state.items.count == 1)
        server.stop()
        let second = m.pass(previous: first.state, facts: db.facts(now: now), keeps: KeepList(), now: now + 300,
                            deadline: wallNow() + 10)

        #expect(second.state.items.isEmpty)
        #expect(second.events.map(\.kind) == ["leftover_cleared"])
        #expect(second.state.engines.first?.ok == false)
        #expect(second.state.engines.first?.lastPass == now + 300)
    }

    @Test func timeoutKeepsForThreePasses() throws {
        let now = wallNow()
        let box = Box(id: hexID(1), name: "orphan", startedAt: now - 2 * day)
        let healthy = try FakeUnixHTTPServer(routes: engineRoutes([box]))
        let silent = try FakeUnixHTTPServer(routes: ["/containers/json": Route(response: nil)])
        defer { healthy.stop(); silent.stop() }
        let db = try TempDB()

        var state = monitor([("default", healthy)]).pass(
            previous: LeftoverState(), facts: db.facts(now: now), keeps: KeepList(), now: now, deadline: wallNow() + 10
        ).state
        let stalled = monitor([("default", silent)], timeout: 0.1)
        for failures in 1...3 {
            let r = stalled.pass(previous: state, facts: db.facts(now: now), keeps: KeepList(), now: now, deadline: wallNow() + 10)
            #expect(r.events.isEmpty)
            #expect(r.state.items.count == 1, "kept after \(failures) timeouts")
            #expect(r.state.engines.first?.failures == failures)
            #expect(r.state.engines.first?.ok == false)
            state = r.state
        }
        let dropped = stalled.pass(previous: state, facts: db.facts(now: now), keeps: KeepList(), now: now, deadline: wallNow() + 10)
        #expect(dropped.state.items.isEmpty)
        #expect(dropped.events.map(\.kind) == ["leftover_cleared"])
        #expect(dropped.state.engines.first?.failures == 4)

        let recovered = monitor([("default", healthy)]).pass(
            previous: dropped.state, facts: db.facts(now: now), keeps: KeepList(), now: now, deadline: wallNow() + 10)
        #expect(recovered.state.engines.first?.failures == 0)
        #expect(recovered.state.items.count == 1)
    }

    @Test func deadlineStopsStatsCalls() throws {
        let now = wallNow()
        let boxes = (1...30).map { Box(id: hexID($0), name: "c\($0)", startedAt: now - 2 * day, usage: 1 << 20) }
        let server = try FakeUnixHTTPServer(routes: engineRoutes(boxes, statsDelay: 0.2))
        defer { server.stop() }
        let db = try TempDB()
        var previous = LeftoverState()
        for b in boxes { previous.starts["default/container/\(b.id)"] = b.startedAt }

        let deadline = wallNow() + 1
        let r = monitor([("default", server)]).pass(
            previous: previous, facts: db.facts(now: now), keeps: KeepList(), now: now, deadline: deadline)
        let finished = wallNow()

        let stats = server.requests.filter { $0.hasSuffix("/stats?stream=false&one-shot=true") }
        #expect(!stats.isEmpty)
        #expect(stats.count <= 20)
        #expect(stats.count < 10, "the deadline, not the call budget, ended the stats calls")
        #expect(finished < deadline + 1)
        #expect(r.state.items.count == 30, "items without memory are still flagged")
        #expect(r.state.items.filter { $0.memoryBytes != nil }.count == stats.count)
    }

    @Test func callBudgetCapsInspectAndStatsAtTwenty() throws {
        let now = wallNow()
        let boxes = (1...30).map { Box(id: hexID($0), name: "c\($0)", startedAt: now - 2 * day, usage: 1 << 20) }
        let server = try FakeUnixHTTPServer(routes: engineRoutes(boxes))
        defer { server.stop() }
        let db = try TempDB()
        let m = monitor([("default", server)])

        let first = m.pass(previous: LeftoverState(), facts: db.facts(now: now), keeps: KeepList(), now: now, deadline: wallNow() + 10)
        #expect(server.requests.count == 21, "one list call plus twenty inspect calls")
        #expect(first.state.starts.count == 20)
        #expect(first.state.items.count == 20, "only inspected items can be decided")
        #expect(first.state.items.allSatisfy { $0.memoryBytes == nil }, "no budget was left for stats")

        let second = m.pass(previous: first.state, facts: db.facts(now: now), keeps: KeepList(), now: now, deadline: wallNow() + 10)
        let calls = server.requests.dropFirst(21)
        #expect(calls.count == 21)
        #expect(calls.filter { $0.hasSuffix("/json") && $0 != "/containers/json" }.count == 10)
        #expect(second.state.items.count == 30)
        #expect(second.state.items.filter { $0.memoryBytes != nil }.count == 10)
        #expect(second.events.count == 10, "only the newly flagged items emit")
    }

    @Test func memoryFromStatsEstimate() throws {
        let now = wallNow()
        let compose = ["com.docker.compose.project": "shop"]
        let web = Box(id: hexID(1), name: "shop-web-1", labels: compose, startedAt: now - 2 * day, usage: 500, inactive: 200)
        let db = Box(id: hexID(2), name: "shop-db-1", labels: compose, startedAt: now - 2 * day, usage: 1000, inactive: 0)
        var routes = engineRoutes([web, db])
        // cgroup v1 reports reclaimable cache as total_inactive_file.
        routes[statsPath(db.id)] = ok(json(["memory_stats": ["usage": 1000, "stats": ["total_inactive_file": 400]]]))
        let server = try FakeUnixHTTPServer(routes: routes)
        defer { server.stop() }
        let temp = try TempDB()

        let r = monitor([("default", server)]).pass(
            previous: LeftoverState(), facts: temp.facts(now: now), keeps: KeepList(), now: now, deadline: wallNow() + 10)
        #expect(r.state.items.map(\.item.key) == ["default/compose/shop"])
        #expect(r.state.items.first?.memoryBytes == 300 + 600)
        #expect(r.events.first?.payload["bytes"] == "900")
        #expect(r.events.first?.payload["totalBytes"] == "900")
        #expect(r.state.totalBytes == 900)
    }

    @Test func goneReaperFlagsTestcontainersSession() throws {
        let now = wallNow()
        let tc = ["org.testcontainers": "true", "org.testcontainers.sessionId": "s1"]
        let pg = Box(id: hexID(1), name: "pg", labels: tc, startedAt: now - 60)
        let ryuk = Box(id: hexID(2), name: "testcontainers-ryuk-s1", labels: tc, image: "testcontainers/ryuk:0.6", startedAt: now - 60)
        let withReaper = try FakeUnixHTTPServer(routes: engineRoutes([pg, ryuk]))
        let without = try FakeUnixHTTPServer(routes: engineRoutes([pg]))
        defer { withReaper.stop(); without.stop() }
        let db = try TempDB()

        let first = monitor([("default", withReaper)]).pass(
            previous: LeftoverState(), facts: db.facts(now: now), keeps: KeepList(), now: now, deadline: wallNow() + 10)
        #expect(first.state.items.isEmpty)
        #expect(first.state.seenReapers == ["s1": now])

        let second = monitor([("default", without)]).pass(
            previous: first.state, facts: db.facts(now: now + 300), keeps: KeepList(), now: now + 300, deadline: wallNow() + 10)
        #expect(second.state.items.first?.reason == "its test run finished")
        #expect(second.state.seenReapers == ["s1": now])

        let muchLater = now + 2 * day
        let third = monitor([("default", without)]).pass(
            previous: second.state, facts: db.facts(now: muchLater), keeps: KeepList(), now: muchLater, deadline: wallNow() + 10)
        #expect(third.state.seenReapers.isEmpty, "a reaper is forgotten a day after it was last seen")
    }

    @Test func keptItemsAndUnreadableKeepEntries() throws {
        let now = wallNow()
        let keptByList = Box(id: hexID(1), name: "pinned", startedAt: now - 2 * day)
        let keptByLabel = Box(id: hexID(2), name: "labelled", labels: [Lifetime.labelKey: "keep"], startedAt: now - 2 * day)
        let orphan = Box(id: hexID(3), name: "orphan", startedAt: now - 2 * day)
        let server = try FakeUnixHTTPServer(routes: engineRoutes([keptByList, keptByLabel, orphan]))
        defer { server.stop() }
        let db = try TempDB()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("keeps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"entries":[{"name":"pinned"},{"bogus":1}]}"#.utf8).write(to: file)
        let (keeps, warning) = KeepList.load(from: file)
        #expect(keeps.skipped == 1)

        let r = monitor([("default", server)]).pass(
            previous: LeftoverState(), facts: db.facts(now: now), keeps: keeps, keepWarning: warning, now: now,
            deadline: wallNow() + 10)
        #expect(r.state.kept == [
            KeptItem(key: "default/container/\(keptByList.id)", why: "keep list"),
            KeptItem(key: "default/container/\(keptByLabel.id)", why: "label keep"),
        ])
        #expect(r.state.keepWarning == warning)
        #expect(r.state.items.map(\.item.key) == ["default/container/\(orphan.id)"])
        #expect(r.state.items.first?.reason
            == "running for more than 24 hours with no agent owner (keeps.json has unreadable entries)")
        #expect(!server.requests.contains("/containers/\(keptByList.id)/json"), "kept items are never inspected")
    }

    @Test func sidecarRoundTripAndAtomic() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-lo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("leftovers.json")

        #expect(LeftoverState.load(from: url) == LeftoverState())
        try Data("not json".utf8).write(to: url)
        #expect(LeftoverState.load(from: url) == LeftoverState())

        let item = LeftoverItem(
            key: "orb/compose/shop", engine: "orb", kind: .compose, name: "shop", containerIDs: ["a", "b"],
            sessionId: nil, lifetime: .duration(3600), cleanup: ["docker --context 'orb' compose -p 'shop' down"],
            containerNames: ["shop-web-1", "shop-db-1"])
        let state = LeftoverState(
            updated: 1_800_000_000,
            engines: [EngineStatus(context: "orb", socket: "/tmp/s", lastPass: 1_800_000_000, ok: true, failures: 0)],
            items: [FlaggedItem(item: item, startedAt: 1_799_000_000, reason: "r", memoryBytes: 42, firstFlagged: 1_799_900_000)],
            kept: [KeptItem(key: "orb/kind/dev", why: "keep list")], keepWarning: "w", seenReapers: ["s1": 1],
            starts: ["orb/compose/shop": 1_799_000_000])
        let inode = { (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber]) as? Int }
        let before = inode()
        try state.save(to: url)
        #expect(LeftoverState.load(from: url) == state)
        #expect(inode() != before, "saved by rename over the old file, not rewritten in place")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["leftovers.json"])
    }

    @Test func noNamesInEventPayloads() throws {
        let now = wallNow()
        let boxes = [
            Box(id: hexID(1), name: "secret-db", startedAt: now - 2 * day, usage: 10),
            Box(id: hexID(2), name: "acme-web-1", labels: ["com.docker.compose.project": "acme"], startedAt: now - 2 * day),
            Box(id: hexID(3), name: "devcluster-control-plane", labels: ["io.x-k8s.kind.cluster": "devcluster"],
                startedAt: now - 2 * day),
        ]
        let full = try FakeUnixHTTPServer(routes: engineRoutes(boxes))
        let empty = try FakeUnixHTTPServer(routes: engineRoutes([]))
        defer { full.stop(); empty.stop() }
        let db = try TempDB()

        let first = monitor([("default", full)]).pass(
            previous: LeftoverState(), facts: db.facts(now: now), keeps: KeepList(), now: now, deadline: wallNow() + 10)
        let second = monitor([("default", empty)]).pass(
            previous: first.state, facts: db.facts(now: now), keeps: KeepList(), now: now, deadline: wallNow() + 10)
        let events = first.events + second.events
        #expect(events.map(\.kind) == ["leftover", "leftover", "leftover", "leftover_cleared", "leftover_cleared", "leftover_cleared"])

        let names = ["secret-db", "acme", "acme-web-1", "devcluster", "devcluster-control-plane"]
        for event in events {
            #expect(Set(event.payload.keys) == ["kind", "ref", "bytes", "totalBytes"])
            for value in event.payload.values {
                #expect(!names.contains { value.contains($0) }, "payload value \(value) names a container")
            }
        }
    }
}

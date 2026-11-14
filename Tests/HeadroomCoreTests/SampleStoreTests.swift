import Foundation
import Testing

@testable import HeadroomCore

private let machine = "m1"
// A minute boundary well inside the 32-bit epoch, so bucket math is easy to read.
private let base: Int64 = 1_800_000_000 - 1_800_000_000 % 3600

private func tempDBPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("headroom-store-\(UUID().uuidString).db").path
}

private final class Fixture {
    let path: String
    let db: Database
    let store: SampleStore

    init() throws {
        path = tempDBPath()
        db = try Database(path: path, readOnly: false)
        try Schema.migrate(db)
        store = try SampleStore(db: db, machineId: machine)
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    func int(_ sql: String) throws -> Int64 {
        let s = try db.prepare(sql)
        _ = try s.step()
        return s.int64(0)
    }

    func double(_ sql: String) throws -> Double {
        let s = try db.prepare(sql)
        _ = try s.step()
        return s.double(0)
    }

    func rows(_ sql: String, columns: Int32) throws -> [[String]] {
        let s = try db.prepare(sql)
        var out: [[String]] = []
        while try s.step() { out.append((0..<columns).map { s.string($0) }) }
        return out
    }
}

private func noAgents() -> AgentUpdate {
    AgentUpdate(started: [], ended: [], live: [], activeCount: 0, idleCount: 0)
}

private func tick(
    _ ts: Int64,
    busy: Double = 0.25,
    memUsed: UInt64 = 8_000,
    swapUsed: UInt64 = 1_000,
    flags: LimitFlags = [],
    groups: [WorkloadGroup: GroupTotals] = [:],
    topByCPU: [(name: String, group: WorkloadGroup, value: Double)] = [],
    topByMemory: [(name: String, group: WorkloadGroup, value: Double)] = [],
    agents: AgentUpdate = noAgents()
) -> Tick {
    Tick(
        ts: Double(ts),
        cpu: CPUReading(
            user: busy, system: 0, idle: 1 - busy, perCoreBusy: [busy, busy],
            load1: 1.5, load5: 1, load15: 0.5, busySeconds: busy * 20),
        memory: MemoryReading(
            total: 16_000, used: memUsed, app: 5_000, wired: 2_000, compressed: 1_000, free: 4_000,
            fileBacked: 500, pressure: .normal, memorystatusLevel: nil, swapUsed: swapUsed,
            swapTotal: 4_000, swapins: 0, swapouts: 0, pageins: 3, pageouts: 0),
        disk: DiskReading(
            capacity: 1_000_000, free: 400_000, availableImportant: 450_000,
            readBytes: 100, writeBytes: 200, readOps: 1, writeOps: 2),
        thermal: .nominal, flags: flags, groups: groups, topByCPU: topByCPU, topByMemory: topByMemory,
        agents: agents, selfCPU: 0.01, selfFootprint: 9_000_000)
}

private func run(_ pid: Int32, cpu: Double, footprint: UInt64, write: UInt64 = 0, active: Bool = true) -> AgentRun {
    AgentRun(
        root: ProcessKey(pid: pid, start: UInt64(pid) * 1_000_000), tool: .claude, started: Double(base),
        isActive: active, cpuSeconds: cpu, footprint: footprint, diskWriteBytes: write)
}

@Suite struct SampleStoreTests {
    // Unattributed CPU lands in .system even when no system process could be read, so the row must survive.
    @Test func groupWithCPUButNoProcessesIsKept() throws {
        let f = try Fixture()
        f.store.append(tick(base, groups: [
            .system: GroupTotals(cpuSeconds: 2.5, footprint: 0, diskWriteBytes: 0, procCount: 0),
            .browsers: GroupTotals(cpuSeconds: 0, footprint: 0, diskWriteBytes: 0, procCount: 0),
        ]))
        try f.store.flush()
        #expect(try f.int("SELECT COUNT(*) FROM group_samples") == 1)
        #expect(try f.double("SELECT cpu_seconds FROM group_samples WHERE group_id='system'") == 2.5)
    }

    @Test func flushWritesOneTransaction() throws {
        let f = try Fixture()
        let groups: [WorkloadGroup: GroupTotals] = [
            .goBuilds: GroupTotals(cpuSeconds: 4, footprint: 100, diskWriteBytes: 10, procCount: 3),
            .ide: GroupTotals(cpuSeconds: 1, footprint: 50, diskWriteBytes: 0, procCount: 1),
            .browsers: GroupTotals(cpuSeconds: 0, footprint: 0, diskWriteBytes: 0, procCount: 0),
        ]
        for i in 0..<6 {
            let flags: LimitFlags = i < 2 ? [.memoryLimited, .cpuSaturated] : (i == 2 ? [.memoryLimited] : [])
            f.store.append(tick(base + Int64(i) * 10, flags: flags, groups: groups))
        }
        #expect(f.store.bufferedTicks == 6)
        try f.store.flush()
        #expect(f.store.bufferedTicks == 0)

        #expect(try f.int("SELECT COUNT(*) FROM samples WHERE machine_id='m1'") == 6)
        #expect(try f.int("SELECT COUNT(*) FROM group_samples") == 12)
        #expect(try f.int("SELECT COUNT(DISTINCT group_id) FROM group_samples") == 2)
        let rollups = try f.rows("SELECT metric FROM rollup WHERE resolution=60 AND ts=\(base)", columns: 1)
        #expect(Set(rollups.map { $0[0] }) == Set(Metric.allCases.map(\.rawValue)))
        #expect(rollups.count == Metric.allCases.count)

        let limits = Dictionary(uniqueKeysWithValues: try f.rows(
            "SELECT kind, seconds FROM limit_seconds WHERE resolution=60 AND ts=\(base)", columns: 2
        ).map { ($0[0], Double($0[1]) ?? -1) })
        #expect(limits[LimitKind.memoryLimited.rawValue] == 30)
        #expect(limits[LimitKind.cpuSaturated.rawValue] == 20)
        #expect(limits[LimitKind.heavySwap.rawValue] == 0)
        #expect(limits[LimitKind.thermalLimited.rawValue] == 0)

        let heartbeat = try f.int("SELECT CAST(value AS INTEGER) FROM meta WHERE key='heartbeat'")
        #expect(abs(Double(heartbeat) - Date().timeIntervalSince1970) < 5)
    }

    @Test func memDemandIsPerTickSumOfUsedAndSwap() throws {
        let f = try Fixture()
        // The peak of the sum (8k + 3k) is not the sum of the separate peaks (10k + 3k).
        f.store.append(tick(base, memUsed: 10_000, swapUsed: 0))
        f.store.append(tick(base + 10, memUsed: 8_000, swapUsed: 3_000))
        try f.store.flush()
        let row = try f.rows(
            "SELECT avg, max FROM rollup WHERE resolution=60 AND ts=\(base) AND metric='memDemand'", columns: 2)
        #expect(row == [["10500.0", "11000.0"]])
    }

    @Test func minuteSplitAcrossFlushesIsRolledUpWhole() throws {
        let f = try Fixture()
        f.store.append(tick(base + 30, busy: 0.2, flags: [.cpuSaturated]))
        try f.store.flush()
        f.store.append(tick(base + 40, busy: 0.4, flags: [.cpuSaturated]))
        f.store.append(tick(base + 60, busy: 0.9))
        try f.store.flush()
        #expect(abs(try f.double(
            "SELECT avg FROM rollup WHERE resolution=60 AND ts=\(base) AND metric='cpuBusy'") - 0.3) < 1e-9)
        #expect(try f.double(
            "SELECT seconds FROM limit_seconds WHERE resolution=60 AND ts=\(base) AND kind='cpuSaturated'") == 20)
        #expect(try f.int("SELECT COUNT(*) FROM samples") == 3)
    }

    @Test func topProcsPerMinute() throws {
        let f = try Fixture()
        for i in 0..<6 {
            let cpu = (0..<8).map { j in (name: "p\(j)", group: WorkloadGroup.other, value: Double(j + i)) }
            let mem = (0..<3).map { j in (name: "m\(j)", group: WorkloadGroup.ide, value: Double(j * 100)) }
            f.store.append(tick(base + Int64(i) * 10, topByCPU: cpu, topByMemory: mem))
        }
        // A spike in one tick should rank by its peak, not be averaged away.
        f.store.append(tick(base + 60, topByCPU: [(name: "spike", group: .goBuilds, value: 1)]))
        try f.store.flush()

        let perKind = try f.rows(
            "SELECT ts, kind, COUNT(*) FROM top_procs_1m GROUP BY ts, kind ORDER BY ts, kind", columns: 3)
        #expect(perKind == [["\(base)", "cpu", "5"], ["\(base)", "memory", "3"], ["\(base + 60)", "cpu", "1"]])
        let ranked = try f.rows(
            "SELECT rank, name, group_id, value FROM top_procs_1m WHERE ts=\(base) AND kind='cpu' ORDER BY rank",
            columns: 4)
        #expect(ranked.map { $0[1] } == ["p7", "p6", "p5", "p4", "p3"])
        #expect(ranked[0] == ["1", "p7", "other", "12.0"])
    }

    @Test func rollupHourP95() throws {
        let f = try Fixture()
        let hourEnd = base + 3600
        for i in 0..<360 {
            var agents = noAgents()
            agents.activeCount = i % 3
            let flags: LimitFlags = switch i % 3 {
            case 1: [.memoryLimited]
            case 2: [.memoryLimited, .cpuSaturated]
            default: []
            }
            f.store.append(tick(base + Int64(i) * 10, busy: Double(i) / 359, flags: flags, agents: agents))
        }
        try f.store.flush()
        try f.store.rollupHour(endingAt: hourEnd)

        let s = try f.db.prepare(
            "SELECT avg, max, p95 FROM rollup WHERE resolution=3600 AND ts=\(base) AND metric='cpuBusy'")
        #expect(try s.step())
        #expect(abs(s.double(0) - 0.5) < 1e-9)
        #expect(s.double(1) == 1)
        // Nearest rank: ceil(0.95 * 360) = 342nd smallest, which is 341/359.
        #expect(abs(s.double(2) - 0.95) <= 1.0 / 359)
        #expect(abs(s.double(2) - 341.0 / 359) < 1e-9)
        #expect(try f.int("SELECT COUNT(*) FROM rollup WHERE resolution=3600") == Int64(Metric.allCases.count))

        let hist = try f.rows(
            "SELECT active_agents, seconds, memory_limited, cpu_saturated FROM agent_histogram WHERE ts=\(base) ORDER BY active_agents",
            columns: 4)
        #expect(hist == [
            ["0", "1200.0", "0.0", "0.0"],
            ["1", "1200.0", "1200.0", "0.0"],
            ["2", "1200.0", "1200.0", "1200.0"],
        ])

        let hourLimits = Dictionary(uniqueKeysWithValues: try f.rows(
            "SELECT kind, seconds FROM limit_seconds WHERE resolution=3600 AND ts=\(base)", columns: 2
        ).map { ($0[0], Double($0[1]) ?? -1) })
        #expect(hourLimits == [
            "memoryLimited": 2400, "cpuSaturated": 1200, "heavySwap": 0, "thermalLimited": 0,
        ])
        #expect(try f.double(
            "SELECT SUM(seconds) FROM limit_seconds WHERE resolution=60 AND kind='memoryLimited'") == 2400)

        // Rerunning the same hour replaces rather than duplicates.
        try f.store.rollupHour(endingAt: hourEnd)
        #expect(try f.int("SELECT COUNT(*) FROM agent_histogram") == 3)
    }

    @Test func agentRowsAndSessions() throws {
        let f = try Fixture()
        let a = run(100, cpu: 2, footprint: 500, write: 7)
        f.store.append(tick(base, agents: AgentUpdate(started: [a], ended: [], live: [a], activeCount: 1, idleCount: 0)))
        let a2 = run(100, cpu: 3, footprint: 900, write: 1, active: false)
        f.store.append(tick(base + 10, agents: AgentUpdate(started: [], ended: [], live: [a2], activeCount: 0, idleCount: 1)))
        let a3 = run(100, cpu: 1, footprint: 700)
        f.store.append(tick(base + 20, agents: AgentUpdate(started: [], ended: [], live: [a3], activeCount: 1, idleCount: 0)))
        f.store.append(tick(base + 30, agents: AgentUpdate(started: [], ended: [a.root], live: [], activeCount: 0, idleCount: 0)))
        f.store.ingest([
            .agentSession(ts: Double(base + 5), tool: "claude", sessionId: "s1", model: "opus", rootPid: 100, rootStart: 100_000_000),
            .agentSession(ts: Double(base + 6), tool: "claude", sessionId: "s1", model: "opus", rootPid: 100, rootStart: 100_000_000),
            .agentSession(ts: Double(base + 25), tool: "claude", sessionId: "s2", model: nil, rootPid: 100, rootStart: 100_000_000),
        ])
        try f.store.flush()

        let runs = try f.rows("SELECT run_id, tool, root_pid, root_start, started, ended FROM agent_runs", columns: 6)
        #expect(runs.count == 1)
        #expect(Array(runs[0].dropFirst()) == ["claude", "100", "100000000", "\(base)", "\(base + 30)"])
        let runId = runs[0][0]

        let usage = try f.rows(
            "SELECT run_id, ts, cpu_seconds, peak_footprint, disk_write, active_seconds FROM run_usage", columns: 6)
        #expect(usage == [[runId, "\(base)", "6.0", "900", "8", "20.0"]])

        let sessions = try f.rows(
            "SELECT run_id, session_id, model, first_seen FROM agent_run_sessions ORDER BY session_id", columns: 4)
        #expect(sessions == [[runId, "s1", "opus", "\(base + 5)"], [runId, "s2", "", "\(base + 25)"]])
    }

    @Test func agentSessionBeforeRunCreatesRow() throws {
        let f = try Fixture()
        f.store.ingest([
            .agentSession(ts: Double(base + 40), tool: "codex", sessionId: "c1", model: "gpt", rootPid: 200, rootStart: 200_000_000),
        ])
        try f.store.flush()
        #expect(try f.rows("SELECT tool, root_pid, root_start, started, ended IS NULL FROM agent_runs", columns: 5)
            == [["codex", "200", "200000000", "\(base + 40)", "1"]])

        // The sweep later sees the run as started earlier; the earliest start wins and the row is reused.
        var r = run(200, cpu: 1, footprint: 10)
        r.tool = .codex
        r.started = Double(base)
        f.store.append(tick(base + 50, agents: AgentUpdate(started: [r], ended: [], live: [r], activeCount: 1, idleCount: 0)))
        try f.store.flush()
        #expect(try f.rows("SELECT COUNT(*), MIN(started) FROM agent_runs", columns: 2) == [["1", "\(base)"]])
        #expect(try f.int("SELECT COUNT(*) FROM agent_run_sessions") == 1)
        #expect(try f.int("SELECT COUNT(*) FROM run_usage") == 1)
    }

    @Test func ingestTagAndCommand() throws {
        let f = try Fixture()
        f.store.ingest([
            .tag(ts: Double(base) + 1.7, text: "kind cluster up"),
            .command(ts: Double(base + 2), exe: "go", seconds: 12.5),
        ])
        f.store.recordEvent(kind: "wake", ts: Double(base + 3), payload: ["reason": "lid"])
        try f.store.flush()

        let events = try f.rows("SELECT ts, kind, payload FROM events WHERE machine_id='m1' ORDER BY ts", columns: 3)
        #expect(events.map { Array($0.prefix(2)) } == [
            ["\(base + 1)", "tag"], ["\(base + 2)", "command"], ["\(base + 3)", "wake"],
        ])
        func object(_ json: String) throws -> [String: Any] {
            let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
            guard let dict = value as? [String: Any] else { throw DatabaseError.open("payload is not an object") }
            return dict
        }
        #expect(try object(events[0][2])["text"] as? String == "kind cluster up")
        let command = try object(events[1][2])
        #expect(Set(command.keys) == ["exe", "seconds"])
        #expect(command["exe"] as? String == "go")
        #expect(command["seconds"] as? Double == 12.5)
        #expect(try object(events[2][2])["reason"] as? String == "lid")
    }

    @Test func closeOrphanRunsEndsOpenRunsOnly() throws {
        let f = try Fixture()
        try f.db.exec("""
            INSERT INTO agent_runs(run_id, machine_id, tool, root_pid, root_start, started, ended) VALUES
                (1, '\(machine)', 'claude', 1, 1, 1000, NULL),
                (2, '\(machine)', 'claude', 2, 1, 1000, NULL),
                (3, '\(machine)', 'claude', 3, 1, 1000, 1500),
                (4, 'other', 'claude', 4, 1, 1000, NULL);
            INSERT INTO run_usage VALUES(1, 1200, 1, 0, 0, 0), (1, 1260, 1, 0, 0, 0);
            """)
        try f.store.closeOrphanRuns(machineId: machine, fallbackEnd: 5000.7)
        let ended = try f.rows("SELECT run_id, COALESCE(ended, 'open') FROM agent_runs ORDER BY run_id", columns: 2)
        // Last usage minute plus 60 s; no usage falls back; already ended and other machines are untouched.
        #expect(ended == [["1", "1320"], ["2", "5000"], ["3", "1500"], ["4", "open"]])
    }

    @Test func retentionDeletesOnlyRawTables() throws {
        let f = try Fixture()
        let old = base - 31 * 86_400
        let a = run(300, cpu: 1, footprint: 1)
        f.store.append(tick(old, groups: [.ide: GroupTotals(cpuSeconds: 1, footprint: 1, diskWriteBytes: 1, procCount: 1)],
                            topByCPU: [(name: "x", group: .ide, value: 1)],
                            agents: AgentUpdate(started: [a], ended: [], live: [a], activeCount: 1, idleCount: 0)))
        f.store.append(tick(base, groups: [.ide: GroupTotals(cpuSeconds: 1, footprint: 1, diskWriteBytes: 1, procCount: 1)],
                            topByCPU: [(name: "x", group: .ide, value: 1)]))
        f.store.recordEvent(kind: "sleep", ts: Double(old), payload: [:])
        try f.store.flush()

        try f.store.applyRetention(now: Double(base + 100))
        #expect(try f.int("SELECT COUNT(*) FROM samples") == 1)
        #expect(try f.int("SELECT MIN(ts) FROM samples") == base)
        #expect(try f.int("SELECT COUNT(*) FROM group_samples") == 1)
        #expect(try f.int("SELECT COUNT(*) FROM top_procs_1m") == 1)
        #expect(try f.int("SELECT COUNT(*) FROM rollup WHERE ts=\(old)") == Int64(Metric.allCases.count))
        #expect(try f.int("SELECT COUNT(*) FROM events WHERE ts=\(old)") == 1)
        #expect(try f.int("SELECT COUNT(*) FROM agent_runs") == 1)
        #expect(try f.int("SELECT COUNT(*) FROM run_usage") == 1)
    }

    @Test func flushFailureKeepsBounded() throws {
        let f = try Fixture()
        // A second connection holding the write lock makes BEGIN IMMEDIATE fail after the busy timeout.
        let blocker = try Database(path: f.path, readOnly: false)
        try blocker.exec("BEGIN IMMEDIATE")
        for i in 0..<400 { f.store.append(tick(base + Int64(i) * 10)) }
        f.store.ingest([.tag(ts: Double(base), text: "kept")])
        #expect(f.store.bufferedTicks == 360)
        #expect(throws: DatabaseError.self) { try f.store.flush() }
        #expect(f.store.bufferedTicks == 360)
        try blocker.exec("ROLLBACK")

        try f.store.flush()
        #expect(f.store.bufferedTicks == 0)
        #expect(try f.int("SELECT COUNT(*) FROM samples") == 360)
        #expect(try f.int("SELECT MIN(ts) FROM samples") == base + 400)
        #expect(try f.int("SELECT COUNT(*) FROM events WHERE kind='tag'") == 1)
    }

    @Test func failureInsideTransactionWritesNothing() throws {
        let f = try Fixture()
        f.store.append(tick(base))
        f.store.ingest([.tag(ts: Double(base), text: "t")])
        // Dropping a table the flush writes late makes the transaction fail after earlier inserts ran.
        try f.db.exec("DROP TABLE run_usage")
        let a = run(1, cpu: 1, footprint: 1)
        f.store.append(tick(base + 10, agents: AgentUpdate(started: [a], ended: [], live: [a], activeCount: 1, idleCount: 0)))
        #expect(throws: DatabaseError.self) { try f.store.flush() }
        #expect(f.store.bufferedTicks == 2)
        #expect(try f.int("SELECT COUNT(*) FROM samples") == 0)
        #expect(try f.int("SELECT COUNT(*) FROM events") == 0)
        #expect(try f.int("SELECT COUNT(*) FROM agent_runs") == 0)
    }

    @Test func refreshCoverageCountsSamples() throws {
        let f = try Fixture()
        for i in 0..<6 { f.store.append(tick(base + Int64(i) * 10)) }
        f.store.append(tick(base + 86_400))
        try f.store.flush()
        try f.store.refreshCoverage(day: "d1", dayStart: Double(base), dayEnd: Double(base + 86_400), now: Double(base + 90_000))
        #expect(try f.rows("SELECT seconds_recorded, seconds_asleep, seconds_gap, gaps FROM coverage WHERE day='d1'", columns: 4)
            == [["60.0", "0.0", "0.0", "[]"]])
    }

    @Test func refreshCoverageClipsSleepAndGaps() throws {
        let f = try Fixture()
        let day1 = base, day2 = base + 86_400, day2End = base + 2 * 86_400
        f.store.recordEvent(kind: "sleep", ts: Double(day1 + 23 * 3600), payload: [:])
        f.store.recordEvent(kind: "wake", ts: Double(day2 + 7 * 3600), payload: [:])
        f.store.recordEvent(kind: "gap", ts: Double(day2 + 8 * 3600),
                            payload: ["start": String(day2 - 600), "end": String(day2 + 300)])
        f.store.recordEvent(kind: "gap", ts: Double(day2), payload: ["start": "garbage", "end": "1"])
        // A sleep still open at `now` runs to now, not to the end of the day.
        f.store.recordEvent(kind: "sleep", ts: Double(day2 + 20 * 3600), payload: [:])
        try f.store.flush()

        let now = Double(day2 + 21 * 3600)
        try f.store.refreshCoverage(day: "d1", dayStart: Double(day1), dayEnd: Double(day2), now: now)
        try f.store.refreshCoverage(day: "d2", dayStart: Double(day2), dayEnd: Double(day2End), now: now)
        let rows = try f.rows("SELECT day, seconds_asleep, seconds_gap, gaps FROM coverage ORDER BY day", columns: 4)
        #expect(rows == [
            ["d1", "3600.0", "600.0", "[[\(day2 - 600),\(day2)]]"],
            ["d2", "\(Double(8 * 3600))", "300.0", "[[\(day2),\(day2 + 300)]]"],
        ])
    }

    @Test func refreshCoverageIsIdempotent() throws {
        let f = try Fixture()
        for i in 0..<3 { f.store.append(tick(base + Int64(i) * 10)) }
        f.store.recordEvent(kind: "sleep", ts: Double(base + 100), payload: [:])
        f.store.recordEvent(kind: "wake", ts: Double(base + 400), payload: [:])
        f.store.recordEvent(kind: "gap", ts: Double(base + 500), payload: ["start": String(base + 450), "end": String(base + 500)])
        try f.store.flush()
        let sql = "SELECT * FROM coverage"
        try f.store.refreshCoverage(day: "d", dayStart: Double(base), dayEnd: Double(base + 86_400), now: Double(base + 1000))
        let first = try f.rows(sql, columns: 6)
        try f.store.refreshCoverage(day: "d", dayStart: Double(base), dayEnd: Double(base + 86_400), now: Double(base + 1000))
        #expect(try f.rows(sql, columns: 6) == first)
        #expect(first == [["m1", "d", "30.0", "300.0", "50.0", "[[\(base + 450),\(base + 500)]]"]])
    }

    @Test func rewritesKeepOneGroupRowAndEarliestSession() throws {
        let f = try Fixture()
        let groups: [WorkloadGroup: GroupTotals] = [.ide: GroupTotals(cpuSeconds: 1, footprint: 1, diskWriteBytes: 1, procCount: 1)]
        f.store.append(tick(base, groups: groups))
        f.store.ingest([.agentSession(ts: Double(base + 20), tool: "claude", sessionId: "s", model: nil, rootPid: 9, rootStart: 9)])
        try f.store.flush()
        f.store.append(tick(base, groups: groups))
        f.store.ingest([.agentSession(ts: Double(base + 5), tool: "claude", sessionId: "s", model: "opus", rootPid: 9, rootStart: 9)])
        try f.store.flush()
        #expect(try f.int("SELECT COUNT(*) FROM group_samples") == 1)
        #expect(try f.rows("SELECT model, first_seen FROM agent_run_sessions", columns: 2) == [["opus", "\(base + 5)"]])
    }
}

import Foundation
import Testing

@testable import HeadroomCore

private let machine = "m1"

private func utc() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return c
}

// Offsets from 2026-12-01 00:00 UTC.
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Int64 {
    1_796_083_200 + Int64(day) * 86_400 + Int64(hour) * 3600 + Int64(minute) * 60
}

private func date(_ ts: Int64) -> Date { Date(timeIntervalSince1970: Double(ts)) }

private final class Fixture {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-q-\(UUID().uuidString).db").path
    let db: Database

    init() throws {
        db = try Database(path: path, readOnly: false)
        try Schema.migrate(db)
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    func rollup(_ resolution: Int64, _ ts: Int64, _ metric: Metric, avg: Double, max: Double, p95: Double) throws {
        let s = try db.prepare("INSERT INTO rollup VALUES(?,?,?,?,?,?,?)")
        s.bind(1, machine)
        s.bind(2, resolution)
        s.bind(3, ts)
        s.bind(4, metric.rawValue)
        s.bind(5, avg)
        s.bind(6, max)
        s.bind(7, p95)
        _ = try s.step()
    }

    func limit(_ resolution: Int64, _ ts: Int64, _ kind: LimitKind, _ seconds: Double) throws {
        let s = try db.prepare("INSERT INTO limit_seconds VALUES(?,?,?,?,?)")
        s.bind(1, machine)
        s.bind(2, resolution)
        s.bind(3, ts)
        s.bind(4, kind.rawValue)
        s.bind(5, seconds)
        _ = try s.step()
    }
}

@Suite struct QueriesTests {
    @Test func containerIntentsInRange() throws {
        let f = try Fixture()
        try f.db.exec("""
            INSERT INTO events VALUES('m1', \(at(0, 3)), 'container_intent', '{"rootPid":"30","rootStart":"3000","start":"true"}');
            INSERT INTO events VALUES('m1', \(at(0, 1)), 'container_intent', '{"rootPid":"10","rootStart":"1000"}');
            INSERT INTO events VALUES('m1', \(at(0, 2)), 'container_intent', '{"rootPid":"bad"}');
            INSERT INTO events VALUES('m1', \(at(0, 5)), 'container_intent', '{"rootPid":"50","rootStart":"5000"}');
            """)
        let got = try Queries(db: f.db).containerIntents(machineId: "m1", from: Double(at(0, 0)), to: Double(at(0, 4)))
        #expect(got.map(\.ts) == [Double(at(0, 1)), Double(at(0, 3))])
        #expect(got.map(\.root) == [ProcessKey(pid: 10, start: 1000), ProcessKey(pid: 30, start: 3000)])
        #expect(got.map(\.start) == [false, true])
    }

    @Test func ownershipFactsFromSeededDB() throws {
        let f = try Fixture()
        let since = Double(at(38, 23, 50)), now = Double(at(40, 0))
        try f.db.exec("""
            INSERT INTO agent_runs VALUES(1, 'm1', 'claude', 10, 1000, \(at(5, 0)), NULL);
            INSERT INTO agent_runs VALUES(2, 'm1', 'codex', 20, 2000, \(at(38, 0)), \(at(38, 23, 55)));
            INSERT INTO agent_runs VALUES(3, 'm1', 'claude', 30, 3000, \(at(30, 0)), \(at(38, 0)));
            INSERT INTO agent_runs VALUES(4, 'm2', 'claude', 40, 4000, \(at(39, 0)), NULL);
            INSERT INTO agent_run_sessions VALUES(1, 's1', NULL, 0);
            INSERT INTO agent_run_sessions VALUES(1, 's2', NULL, 0);
            INSERT INTO run_usage VALUES(1, \(at(39, 1)), 1, 0, 0, 30);
            INSERT INTO run_usage VALUES(1, \(at(39, 2)), 1, 0, 0, 0);
            INSERT INTO run_usage VALUES(1, \(at(39, 3)), 1, 0, 0, 5);
            INSERT INTO run_usage VALUES(1, \(at(20, 0)), 1, 0, 0, 60);
            INSERT INTO run_usage VALUES(2, \(at(38, 23, 50)), 1, 0, 0, 60);
            INSERT INTO events VALUES('m1', \(at(38, 23, 55)), 'container_intent', '{"rootPid":"10","rootStart":"1000"}');
            INSERT INTO events VALUES('m1', \(at(39, 4)), 'container_intent', '{"rootPid":"10","rootStart":"1000"}');
            INSERT INTO events VALUES('m1', \(at(38, 23, 40)), 'container_intent', '{"rootPid":"20","rootStart":"2000"}');
            """)
        for k in 0..<180 { try f.db.exec("INSERT INTO samples(machine_id, ts) VALUES('m1', \(at(39, 23) + Int64(k) * 10))") }
        try f.db.exec("INSERT INTO samples(machine_id, ts) VALUES('m2', \(at(39, 23, 1)))")

        let q = Queries(db: f.db)
        let facts = try q.ownershipFacts(machineId: machine, since: since, now: now, idleThreshold: 3600)

        #expect(facts.intents.map(\.ts) == [Double(at(38, 23, 55)), Double(at(39, 4))])
        let one = ProcessKey(pid: 10, start: 1000), two = ProcessKey(pid: 20, start: 2000)
        #expect(Set(facts.runs.keys) == [one, two])
        #expect(facts.runs[one] == RunFacts(
            sessionIds: ["s1", "s2"], started: Double(at(5, 0)), ended: nil, lastIntent: Double(at(39, 4)),
            activeMinutes: [Double(at(39, 1)), Double(at(39, 3))]))
        #expect(facts.runs[two] == RunFacts(
            sessionIds: [], started: Double(at(38, 0)), ended: Double(at(38, 23, 55)), lastIntent: nil,
            activeMinutes: [Double(at(38, 23, 50))]))

        #expect(facts.awakeSeconds(Double(at(39, 23)), now) == 1800)
        #expect(facts.awakeSeconds(Double(at(39, 23, 10)), now) == 1200)
        #expect(facts.awakeSeconds(Double(at(39, 23)) + 5, Double(at(39, 23)) + 25) == 20)
        #expect(facts.awakeSeconds(Double(at(5, 0)), now) == 1800)
        #expect(facts.awakeSeconds(now, now) == 0)

        // 61 samples cover 600 s, so anything starting before the oldest of them is reported as the threshold.
        let bounded = try q.ownershipFacts(machineId: machine, since: since, now: now, idleThreshold: 600)
        #expect(bounded.awakeSeconds(Double(at(39, 23)), now) == 600)
        #expect(bounded.awakeSeconds(Double(at(5, 0)), now) == 600)
        #expect(bounded.awakeSeconds(Double(at(39, 23, 25)), now) == 300)
        #expect(bounded.awakeSeconds(Double(at(39, 23, 19)) + 50, now) == 610)
    }

    @Test func ownershipFactsSurviveAHugeIdleThreshold() throws {
        let f = try Fixture()
        let now = Double(at(40, 0))
        for k in 0..<3 { try f.db.exec("INSERT INTO samples(machine_id, ts) VALUES('m1', \(at(39, 23) + Int64(k) * 10))") }
        let facts = try Queries(db: f.db).ownershipFacts(
            machineId: machine, since: now - 600, now: now, idleThreshold: Double(Int.max) * 60)
        #expect(facts.awakeSeconds(Double(at(39, 23)), now) == 30)
    }

    @Test func leftoverPeakIncludesBytesEventsAndSeedsFromBeforeTheRange() throws {
        let f = try Fixture()
        try f.db.exec("""
            INSERT INTO events VALUES('m1', \(at(0, 1)), 'leftover', '{"kind":"compose","ref":"a","bytes":"0","totalBytes":"0","totalCount":"1"}');
            INSERT INTO events VALUES('m1', \(at(0, 2)), 'leftover_bytes', '{"totalBytes":"4000000000","totalCount":"1"}');
            INSERT INTO events VALUES('m1', \(at(0, 3)), 'leftover', 'not json');
            INSERT INTO events VALUES('m1', \(at(1, 5)), 'leftover_cleared', '{"kind":"compose","ref":"a","bytes":"4000000000","totalBytes":"0","totalCount":"0"}');
            """)
        let q = Queries(db: f.db)
        #expect(try q.leftoverPeakBytes(machineId: machine, from: date(at(0, 0)), to: date(at(0, 23))) == 4_000_000_000,
                "memory learned on a later pass reaches the peak")
        #expect(try q.leftoverPeakBytes(machineId: machine, from: date(at(1, 0)), to: date(at(1, 4))) == 4_000_000_000,
                "a container still held from before the range counts")
        #expect(try q.leftoverPeakBytes(machineId: machine, from: date(at(1, 0)), to: date(at(1, 6))) == 4_000_000_000)
        #expect(try q.leftoverPeakBytes(machineId: machine, from: date(at(2, 0)), to: date(at(2, 6))) == 0)
        #expect(try q.leftoverPeakBytes(machineId: machine, from: date(at(-1, 0)), to: date(at(0, 0))) == nil)
    }

    @Test func leftoverCountPrefersTotalCount() throws {
        let f = try Fixture()
        // A sidecar rebuilt from scratch flagged the same item twice; the running sum would say 2.
        try f.db.exec("""
            INSERT INTO events VALUES('m1', \(at(0, 1)), 'leftover', '{"kind":"compose","ref":"a","bytes":"5","totalBytes":"5","totalCount":"1"}');
            INSERT INTO events VALUES('m1', \(at(0, 2)), 'leftover', '{"kind":"compose","ref":"a","bytes":"5","totalBytes":"5","totalCount":"1"}');
            INSERT INTO events VALUES('m1', \(at(0, 3)), 'leftover_bytes', '{"totalBytes":"9","totalCount":"1"}');
            """)
        let q = Queries(db: f.db)
        #expect(try q.leftoversBefore(machineId: machine, before: Double(at(0, 2, 30))) == (count: 1, bytes: 5))
        #expect(try q.leftoversBefore(machineId: machine, before: Double(at(0, 4))) == (count: 1, bytes: 9))

        // Rows from before totalCount fall back to the running sum, which a bytes event doesn't move.
        let old = try Fixture()
        try old.db.exec("""
            INSERT INTO events VALUES('m1', \(at(0, 1)), 'leftover', '{"kind":"compose","ref":"a","bytes":"5","totalBytes":"5"}');
            INSERT INTO events VALUES('m1', \(at(0, 2)), 'leftover', '{"kind":"kind","ref":"b","bytes":"5","totalBytes":"10"}');
            INSERT INTO events VALUES('m1', \(at(0, 3)), 'leftover_cleared', '{"kind":"kind","ref":"b","bytes":"5","totalBytes":"5"}');
            """)
        #expect(try Queries(db: old.db).leftoversBefore(machineId: machine, before: Double(at(0, 4))) == (count: 1, bytes: 5))
    }

    @Test func ownershipNeedsSinceBeforeTheIntentWindow() throws {
        let f = try Fixture()
        let startedAt = Double(at(39, 12)), now = startedAt + 7200
        try f.db.exec("""
            INSERT INTO agent_runs VALUES(1, 'm1', 'claude', 10, 1000, \(at(39, 0)), \(at(39, 12, 2)));
            INSERT INTO events VALUES('m1', \(at(39, 12) - 30), 'container_intent', '{"rootPid":"10","rootStart":"1000","start":"true"}');
            """)
        let item = LeftoverItem(
            key: "e/container/c", engine: "e", kind: .container, name: "c", containerIDs: ["c"], sessionId: nil,
            lifetime: nil, cleanup: [])
        func decide(since: Double) throws -> LeftoverDecision {
            let facts = try Queries(db: f.db).ownershipFacts(machineId: machine, since: since, now: now, idleThreshold: 3600)
            return LeftoverPolicy.decide(
                item, startedAt: startedAt, facts: facts, keeps: KeepList(), liveReapers: [], goneReapers: [],
                now: now, config: LeftoversConfig())
        }
        #expect(try decide(since: startedAt - 600) == .leftover(reason: "the agent session that started it is done"))
        // A `since` after the start drops the owner's marker, so the item falls to the unowned rule.
        #expect(try decide(since: startedAt + 60) == .notYet)
    }

    @Test func queriesDailyMetric() throws {
        let f = try Fixture()
        for (hour, max) in [(1, 0.5), (2, 0.9), (3, 0.7)] {
            try f.rollup(3600, at(0, hour), .cpuBusy, avg: max / 2, max: max, p95: max - 0.1)
        }
        try f.rollup(3600, at(1, 5), .cpuBusy, avg: 0.2, max: 0.3, p95: 0.25)

        let stats = try Queries(db: f.db).dailyMetric(
            machineId: machine, metric: .cpuBusy, from: date(at(0, 0)), to: date(at(2, 0)), calendar: utc())

        #expect(stats.map(\.day) == ["2026-12-01", "2026-12-02"])
        #expect(stats[0].max == 0.9)
        #expect(abs(stats[0].avg - (0.25 + 0.45 + 0.35) / 3) < 1e-9)
        #expect(abs(stats[0].p95 - 0.8) < 1e-9)
        #expect(stats[1].max == 0.3)
    }

    @Test func dailyMetricUsesLocalDays() throws {
        let f = try Fixture()
        try f.rollup(3600, at(0, 23), .load1, avg: 1, max: 1, p95: 1)
        try f.rollup(3600, at(1, 1), .load1, avg: 2, max: 2, p95: 2)
        var tokyo = utc()
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt

        let stats = try Queries(db: f.db).dailyMetric(
            machineId: machine, metric: .load1, from: date(at(0, 0)), to: date(at(2, 0)), calendar: tokyo)

        // 08:00 and 10:00 on 2 December in Tokyo: one local day, two UTC days.
        #expect(stats.map(\.day) == ["2026-12-02"])
        #expect(stats[0].max == 2)
    }

    @Test func currentHourFallsBackToMinuteRows() throws {
        let f = try Fixture()
        try f.rollup(3600, at(0, 1), .cpuBusy, avg: 0.4, max: 0.4, p95: 0.4)
        // Minute rows of a completed hour are ignored; the in-progress hour uses its minute rows.
        try f.rollup(60, at(0, 1, 5), .cpuBusy, avg: 0.9, max: 0.9, p95: 0.9)
        try f.rollup(60, at(0, 2, 0), .cpuBusy, avg: 0.2, max: 0.6, p95: 0.5)
        try f.rollup(60, at(0, 2, 1), .cpuBusy, avg: 0.4, max: 0.8, p95: 0.7)

        let stats = try Queries(db: f.db).dailyMetric(
            machineId: machine, metric: .cpuBusy, from: date(at(0, 0)), to: date(at(1, 0)), calendar: utc())

        #expect(stats.count == 1)
        #expect(stats[0].max == 0.8)
        #expect(abs(stats[0].avg - (0.4 + 0.3) / 2) < 1e-9)
    }

    @Test func todayLimitSecondsCombinesHoursAndCurrentMinutes() throws {
        let f = try Fixture()
        try f.limit(3600, at(0, 1), .memoryLimited, 100)
        try f.limit(3600, at(0, 2), .memoryLimited, 50)
        try f.limit(60, at(0, 2, 10), .memoryLimited, 999)
        try f.limit(60, at(0, 3, 0), .memoryLimited, 20)
        try f.limit(60, at(0, 3, 1), .memoryLimited, 10)
        try f.limit(3600, at(1, 1), .memoryLimited, 7)

        let today = try Queries(db: f.db).todayLimitSeconds(machineId: machine, now: date(at(0, 3, 5)), calendar: utc())

        #expect(today[.memoryLimited] == 180)
    }

    @Test func agentHistogramSumsPerLevel() throws {
        let f = try Fixture()
        try f.db.exec("""
            INSERT INTO agent_histogram VALUES('m1', \(at(0, 1)), 2, 3000, 100, 50);
            INSERT INTO agent_histogram VALUES('m1', \(at(0, 2)), 2, 600, 0, 10);
            INSERT INTO agent_histogram VALUES('m1', \(at(0, 2)), 0, 3000, 0, 0);
            INSERT INTO agent_histogram VALUES('m1', \(at(5, 2)), 2, 9999, 9999, 9999);
            """)

        let h = try Queries(db: f.db).agentHistogram(machineId: machine, from: date(at(0, 0)), to: date(at(1, 0)))

        #expect(h[2] == AgentLevelStats(seconds: 3600, memoryLimited: 100, cpuSaturated: 60))
        #expect(h[0]?.seconds == 3000)
    }

    @Test func selfUsageCoverageEventsAndMachines() throws {
        let f = try Fixture()
        for i in 0..<6 {
            try f.db.exec("""
                INSERT INTO samples(machine_id, ts, self_cpu, self_footprint)
                VALUES('m1', \(at(0, 1) + Int64(i) * 10), 0.05, \(1_000_000 * (i + 1)))
                """)
        }
        try f.db.exec("""
            INSERT INTO coverage VALUES('m1', '2026-12-01', 80000, 6000, 400, '[[\(at(0, 5)), \(at(0, 5, 10))]]');
            INSERT INTO events VALUES('m1', \(at(0, 2)), 'tag', '{}');
            INSERT INTO events VALUES('m1', \(at(0, 3)), 'tag', '{}');
            INSERT INTO events VALUES('m1', \(at(0, 4)), 'sleep', '{}');
            INSERT INTO machines VALUES('m1', 'Mac15,6', 'h', 8, 4, 17179869184, 1000, 1, 2);
            INSERT INTO meta VALUES('heartbeat', '123');
            """)
        let q = Queries(db: f.db)
        let from = date(at(0, 0))
        let to = date(at(1, 0))

        let usage = try q.selfUsage(machineId: machine, from: from, to: to)
        #expect(abs(usage.avgCPU - 0.005) < 1e-9)
        #expect(usage.maxFootprint == 6_000_000)

        #expect(try q.coverage(machineId: machine, from: from, to: to, calendar: utc()) == [
            DayCoverage(
                day: "2026-12-01", recorded: 80000, asleep: 6000, gap: 400,
                gaps: [DateInterval(start: date(at(0, 5)), duration: 600)])
        ])
        #expect(try q.eventCounts(machineId: machine, from: from, to: to) == ["tag": 2, "sleep": 1])
        #expect(try q.heartbeat() == 123)
        #expect(try q.machines().first?.model == "Mac15,6")
        #expect(try q.machines().first?.perfCores == 8)
    }

    @Test func thermalSlowdownsCountOnlyEntriesIntoSerious() throws {
        let f = try Fixture()
        for (minute, level) in [0, 1, 0, 2, 3, 0].enumerated() {
            try f.db.exec("INSERT INTO events VALUES('m1', \(at(0, 1, minute)), 'thermal', '{\"level\":\"\(level)\"}')")
        }
        let q = Queries(db: f.db)
        #expect(try q.thermalSlowdowns(machineId: machine, from: date(at(0, 0)), to: date(at(1, 0))) == 1)
    }

    @Test func thermalSlowdownsSeedFromTheLastEventBeforeTheRange() throws {
        let f = try Fixture()
        try f.db.exec("""
            INSERT INTO events VALUES('m1', \(at(0, 1)), 'thermal', '{"level":"2"}');
            INSERT INTO events VALUES('m1', \(at(1, 1)), 'thermal', '{"level":"3"}');
            INSERT INTO events VALUES('m1', \(at(1, 2)), 'thermal', '{"level":"1"}');
            INSERT INTO events VALUES('m1', \(at(1, 3)), 'thermal', '{"level":"2"}');
            INSERT INTO events VALUES('m2', \(at(1, 4)), 'thermal', '{"level":"3"}');
            """)
        let q = Queries(db: f.db)
        // Already serious when the range opens, so critical isn't a new slowdown; the later climb from fair is.
        #expect(try q.thermalSlowdowns(machineId: machine, from: date(at(1, 0)), to: date(at(2, 0))) == 1)
        #expect(try q.thermalSlowdowns(machineId: machine, from: date(at(0, 0)), to: date(at(2, 0))) == 2)
    }

    @Test func groupTotalsSumsCPUAndTakesPeakFootprint() throws {
        let f = try Fixture()
        try f.db.exec("""
            INSERT INTO group_samples VALUES('m1', \(at(0, 1)), 'agents', 1.5, 100, 10, 2);
            INSERT INTO group_samples VALUES('m1', \(at(0, 1) + 10), 'agents', 2.5, 900, 20, 5);
            INSERT INTO group_samples VALUES('m1', \(at(0, 1) + 20), 'agents', 1.0, 300, 30, 3);
            INSERT INTO group_samples VALUES('m1', \(at(0, 1)), 'ide', 4, 50, 0, 1);
            INSERT INTO group_samples VALUES('m1', \(at(3, 1)), 'agents', 99, 99999, 99, 99);
            """)

        let totals = try Queries(db: f.db).groupTotals(machineId: machine, from: date(at(0, 0)), to: date(at(1, 0)))

        #expect(totals[.agents] == GroupTotals(cpuSeconds: 5, footprint: 900, diskWriteBytes: 60, procCount: 5))
        #expect(totals[.ide]?.cpuSeconds == 4)
        #expect(totals.count == 2)
    }

    @Test func daylightSavingDayHas25HourlyRows() throws {
        let f = try Fixture()
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        // 2026-11-01 00:00 PDT; the clocks go back that morning, so the local day lasts 25 hours.
        let start: Int64 = 1_793_516_400
        for h in 0..<26 {
            try f.rollup(3600, start + Int64(h) * 3600, .load1, avg: Double(h), max: Double(h), p95: Double(h))
            try f.limit(3600, start + Int64(h) * 3600, .heavySwap, 1)
        }
        let q = Queries(db: f.db)
        let to = date(start + 27 * 3600)

        let stats = try q.dailyMetric(machineId: machine, metric: .load1, from: date(start), to: to, calendar: la)
        let limits = try q.limitSecondsByDay(machineId: machine, from: date(start), to: to, calendar: la)

        #expect(stats.map(\.day) == ["2026-11-01", "2026-11-02"])
        #expect(stats[0].avg == 12)
        #expect(stats[0].max == 24)
        #expect(stats[1].max == 25)
        #expect(limits["2026-11-01"]?[.heavySwap] == 25)
        #expect(limits["2026-11-02"]?[.heavySwap] == 1)
    }

    /// Any Double a caller passes must bind, never trap: the MCP server hands these bounds straight from its input.
    @Test func nonFiniteAndHugeBoundsDoNotTrap() throws {
        let f = try Fixture()
        try f.rollup(60, at(0, 1), .cpuBusy, avg: 0.5, max: 0.9, p95: 0.8)
        let q = Queries(db: f.db)
        for (from, to) in [(-Double.infinity, Double.infinity), (Double.nan, Double.nan), (-1e300, 1e300)] {
            let all = try q.metricSeries(machineId: machine, metric: .cpuBusy, resolution: 60, from: from, to: to, limit: 10)
            #expect(all.count == (from.isNaN ? 0 : 1))
            _ = try q.metricPeak(machineId: machine, metric: .cpuBusy, resolution: 60, from: from, to: to)
            _ = try q.limitSeconds(machineId: machine, resolution: 60, from: from, to: to)
            _ = try q.maxPressure(machineId: machine, from: from, to: to)
            _ = try q.topProcesses(machineId: machine, from: from, to: to)
            _ = try q.agentRunActivity(machineId: machine, from: from, to: to, limit: 5)
            _ = try q.events(machineId: machine, from: from, to: to, limit: 5)
            _ = try q.leftoversBefore(machineId: machine, before: to)
            _ = try q.containerIntents(machineId: machine, from: from, to: to)
            _ = try q.groupTotals(
                machineId: machine, from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to))
            _ = try q.leftoverPeakBytes(
                machineId: machine, from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to))
            _ = try q.thermalSlowdowns(
                machineId: machine, from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to))
            _ = try q.limitSecondsByDay(
                machineId: machine, from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to),
                calendar: utc())
        }
    }
}

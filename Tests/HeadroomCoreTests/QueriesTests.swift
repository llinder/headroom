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
    @Test func queriesDailyMetric() throws {
        let f = try Fixture()
        for (hour, max) in [(1, 0.5), (2, 0.9), (3, 0.7)] {
            try f.rollup(3600, at(0, hour), .cpuBusy, avg: max / 2, max: max, p95: max - 0.1)
        }
        try f.rollup(3600, at(1, 5), .cpuBusy, avg: 0.2, max: 0.3, p95: 0.25)

        let stats = Queries(db: f.db).dailyMetric(
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

        let stats = Queries(db: f.db).dailyMetric(
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

        let stats = Queries(db: f.db).dailyMetric(
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

        let today = Queries(db: f.db).todayLimitSeconds(machineId: machine, now: date(at(0, 3, 5)), calendar: utc())

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

        let h = Queries(db: f.db).agentHistogram(machineId: machine, from: date(at(0, 0)), to: date(at(1, 0)))

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

        let usage = q.selfUsage(machineId: machine, from: from, to: to)
        #expect(abs(usage.avgCPU - 0.005) < 1e-9)
        #expect(usage.maxFootprint == 6_000_000)

        #expect(q.coverage(machineId: machine, from: from, to: to, calendar: utc()) == [
            DayCoverage(
                day: "2026-12-01", recorded: 80000, asleep: 6000, gap: 400,
                gaps: [DateInterval(start: date(at(0, 5)), duration: 600)])
        ])
        #expect(q.eventCounts(machineId: machine, from: from, to: to) == ["tag": 2, "sleep": 1])
        #expect(q.heartbeat() == 123)
        #expect(q.machines().first?.model == "Mac15,6")
        #expect(q.machines().first?.perfCores == 8)
    }
}

import Foundation

public struct DayCoverage: Sendable, Equatable {
    public var day: String
    public var recorded: Double
    public var asleep: Double
    public var gap: Double
    public var gaps: [DateInterval]

    public init(day: String, recorded: Double, asleep: Double, gap: Double, gaps: [DateInterval]) {
        self.day = day
        self.recorded = recorded
        self.asleep = asleep
        self.gap = gap
        self.gaps = gaps
    }
}

public struct DailyStat: Sendable, Equatable {
    public var day: String
    public var avg: Double
    public var max: Double
    public var p95: Double

    public init(day: String, avg: Double, max: Double, p95: Double) {
        self.day = day
        self.avg = avg
        self.max = max
        self.p95 = p95
    }
}

public struct AgentLevelStats: Sendable, Equatable {
    public var seconds: Double
    public var memoryLimited: Double
    public var cpuSaturated: Double

    public init(seconds: Double, memoryLimited: Double, cpuSaturated: Double) {
        self.seconds = seconds
        self.memoryLimited = memoryLimited
        self.cpuSaturated = cpuSaturated
    }
}

/// Read-only views over the recorder's database for the CLI, report and MCP server. A failed query throws,
/// so a busy or corrupt database is never mistaken for an empty one.
public struct Queries {
    private static let hour: Int64 = 3600
    private static let minute: Int64 = 60
    private static let sampleInterval = 10.0

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    public func machines() throws(DatabaseError) -> [MachineInfo] {
        try rows(
            "SELECT model, serial_hash, perf_cores, eff_cores, ram_bytes, disk_bytes FROM machines ORDER BY first_seen"
        ) { _ in
        } read: { s in
            MachineInfo(
                model: s.string(0), chip: "", serialHash: s.string(1), perfCores: Int(s.int64(2)),
                effCores: Int(s.int64(3)), ramBytes: UInt64(clamping: s.int64(4)),
                diskBytes: UInt64(clamping: s.int64(5)))
        }
    }

    /// Epoch seconds of the recorder's last flush.
    public func heartbeat() throws(DatabaseError) -> Double? {
        try rows("SELECT value FROM meta WHERE key='heartbeat'") { _ in
        } read: { Double($0.string(0)) }.first ?? nil
    }

    public func coverage(machineId: String, from: Date, to: Date, calendar: Calendar = .current) throws(DatabaseError) -> [DayCoverage] {
        let first = LocalDay(containing: from.timeIntervalSince1970, calendar: calendar).name
        let last = LocalDay(containing: to.timeIntervalSince1970 - 1, calendar: calendar).name
        let raw = try rows(
            """
            SELECT day, seconds_recorded, seconds_asleep, seconds_gap, gaps FROM coverage
            WHERE machine_id=? AND day>=? AND day<=? ORDER BY day
            """
        ) { s in
            s.bind(1, machineId)
            s.bind(2, first)
            s.bind(3, last)
        } read: { s in (day: s.string(0), recorded: s.double(1), asleep: s.double(2), gap: s.double(3), gaps: s.string(4)) }

        return try raw.map { row throws(DatabaseError) in
            let pairs: [[Double]]
            do {
                pairs = try JSONDecoder().decode([[Double]].self, from: Data(row.gaps.utf8))
            } catch {
                // SQLITE_CORRUPT: the recorder only ever writes a JSON array of [start, end] pairs.
                throw .sqlite(code: 11, message: "malformed gaps in coverage row \(row.day)")
            }
            let gaps = pairs.compactMap { p in
                p.count == 2 && p[1] >= p[0]
                    ? DateInterval(start: Date(timeIntervalSince1970: p[0]), end: Date(timeIntervalSince1970: p[1]))
                    : nil
            }
            return DayCoverage(day: row.day, recorded: row.recorded, asleep: row.asleep, gap: row.gap, gaps: gaps)
        }
    }

    public func limitSecondsByDay(
        machineId: String, from: Date, to: Date, calendar: Calendar = .current
    ) throws(DatabaseError) -> [String: [LimitKind: Double]] {
        let hourly = try limitRows(machineId, resolution: Self.hour, from: from, to: to)
        // Hours without an hourly rollup yet (the current one) fall back to their minute rows.
        let covered = Set(hourly.map(\.ts))
        let minutes = try limitRows(machineId, resolution: Self.minute, from: from, to: to)
            .filter { !covered.contains(Self.hourStart($0.ts)) }

        // Each hourly row belongs to the local day containing its start, so in time zones that are not
        // whole hours from UTC up to 30 or 45 minutes of an hour shift across local midnight.
        var byDay: [String: [LimitKind: Double]] = [:]
        for row in hourly + minutes {
            let day = LocalDay(containing: Double(row.ts), calendar: calendar).name
            byDay[day, default: [:]][row.kind, default: 0] += row.seconds
        }
        return byDay
    }

    public func dailyMetric(
        machineId: String, metric: Metric, from: Date, to: Date, calendar: Calendar = .current
    ) throws(DatabaseError) -> [DailyStat] {
        let hourly = try metricRows(machineId, metric, resolution: Self.hour, from: from, to: to)
        let covered = Set(hourly.map(\.ts))
        let minutes = Dictionary(
            grouping: try metricRows(machineId, metric, resolution: Self.minute, from: from, to: to)
                .filter { !covered.contains(Self.hourStart($0.ts)) },
            by: { Self.hourStart($0.ts) })
        let partialHours = minutes.map { hour, rows in
            MetricRow(
                ts: hour, avg: rows.reduce(0) { $0 + $1.avg } / Double(rows.count),
                max: rows.map(\.max).max() ?? 0, p95: rows.map(\.p95).max() ?? 0)
        }

        let byDay = Dictionary(grouping: hourly + partialHours) {
            LocalDay(containing: Double($0.ts), calendar: calendar).name
        }
        return byDay.map { day, hours in
            // Hourly rollups can't be merged into an exact daily 95th percentile, so the day reports the
            // worst hour's p95: an upper bound that never hides a bad hour.
            DailyStat(
                day: day, avg: hours.reduce(0) { $0 + $1.avg } / Double(hours.count),
                max: hours.map(\.max).max() ?? 0, p95: hours.map(\.p95).max() ?? 0)
        }.sorted { $0.day < $1.day }
    }

    public func agentHistogram(machineId: String, from: Date, to: Date) throws(DatabaseError) -> [Int: AgentLevelStats] {
        let levels = try rows(
            """
            SELECT active_agents, SUM(seconds), SUM(memory_limited), SUM(cpu_saturated) FROM agent_histogram
            WHERE machine_id=? AND ts>=? AND ts<? GROUP BY active_agents
            """
        ) { s in bindRange(s, machineId, from, to) } read: { s in
            (
                Int(s.int64(0)),
                AgentLevelStats(seconds: s.double(1), memoryLimited: s.double(2), cpuSaturated: s.double(3))
            )
        }
        return Dictionary(uniqueKeysWithValues: levels)
    }

    /// CPU and disk writes are summed over the range; footprint and process count are the peak tick.
    public func groupTotals(machineId: String, from: Date, to: Date) throws(DatabaseError) -> [WorkloadGroup: GroupTotals] {
        let groups = try rows(
            """
            SELECT group_id, SUM(cpu_seconds), MAX(footprint), SUM(disk_write), MAX(proc_count) FROM group_samples
            WHERE machine_id=? AND ts>=? AND ts<? GROUP BY group_id
            """
        ) { s in bindRange(s, machineId, from, to) } read: { s -> (WorkloadGroup, GroupTotals)? in
            guard let group = WorkloadGroup(rawValue: s.string(0)) else { return nil }
            return (
                group,
                GroupTotals(
                    cpuSeconds: s.double(1), footprint: UInt64(clamping: s.int64(2)),
                    diskWriteBytes: UInt64(clamping: s.int64(3)), procCount: Int(s.int64(4))))
        }
        return Dictionary(uniqueKeysWithValues: groups.compactMap { $0 })
    }

    public func eventCounts(machineId: String, from: Date, to: Date) throws(DatabaseError) -> [String: Int] {
        let counts = try rows(
            "SELECT kind, COUNT(*) FROM events WHERE machine_id=? AND ts>=? AND ts<? GROUP BY kind"
        ) { s in bindRange(s, machineId, from, to) } read: { ($0.string(0), Int($0.int64(1))) }
        return Dictionary(uniqueKeysWithValues: counts)
    }

    /// `avgCPU` is a fraction of one core: the sum of per-tick CPU seconds over the seconds the ticks span.
    public func selfUsage(machineId: String, from: Date, to: Date) throws(DatabaseError) -> (avgCPU: Double, maxFootprint: UInt64) {
        let usage = try rows(
            "SELECT COALESCE(SUM(self_cpu), 0), COUNT(*), COALESCE(MAX(self_footprint), 0) FROM samples WHERE machine_id=? AND ts>=? AND ts<?"
        ) { s in bindRange(s, machineId, from, to) } read: { s in
            let count = Double(s.int64(1))
            return (
                avgCPU: count > 0 ? s.double(0) / (count * Self.sampleInterval) : 0,
                maxFootprint: UInt64(clamping: s.int64(2))
            )
        }
        return usage.first ?? (0, 0)
    }

    public func todayLimitSeconds(
        machineId: String, now: Date, calendar: Calendar = .current
    ) throws(DatabaseError) -> [LimitKind: Double] {
        let day = LocalDay(containing: now.timeIntervalSince1970, calendar: calendar)
        let byDay = try limitSecondsByDay(
            machineId: machineId, from: Date(timeIntervalSince1970: day.start),
            to: Date(timeIntervalSince1970: day.end), calendar: calendar)
        return byDay[day.name] ?? [:]
    }

    // MARK: - Helpers

    private struct LimitRow {
        var ts: Int64
        var kind: LimitKind
        var seconds: Double
    }

    private struct MetricRow {
        var ts: Int64
        var avg: Double
        var max: Double
        var p95: Double
    }

    private static func hourStart(_ ts: Int64) -> Int64 { ts - ts % hour }

    private func limitRows(_ machineId: String, resolution: Int64, from: Date, to: Date) throws(DatabaseError) -> [LimitRow] {
        try rows(
            """
            SELECT ts, kind, seconds FROM limit_seconds
            WHERE machine_id=? AND resolution=? AND ts>=? AND ts<?
            """
        ) { s in
            s.bind(1, machineId)
            s.bind(2, resolution)
            s.bind(3, Int64(from.timeIntervalSince1970))
            s.bind(4, Int64(to.timeIntervalSince1970))
        } read: { s in
            LimitKind(rawValue: s.string(1)).map { LimitRow(ts: s.int64(0), kind: $0, seconds: s.double(2)) }
        }.compactMap { $0 }
    }

    private func metricRows(_ machineId: String, _ metric: Metric, resolution: Int64, from: Date, to: Date) throws(DatabaseError) -> [MetricRow] {
        try rows(
            """
            SELECT ts, avg, max, p95 FROM rollup
            WHERE machine_id=? AND resolution=? AND metric=? AND ts>=? AND ts<?
            """
        ) { s in
            s.bind(1, machineId)
            s.bind(2, resolution)
            s.bind(3, metric.rawValue)
            s.bind(4, Int64(from.timeIntervalSince1970))
            s.bind(5, Int64(to.timeIntervalSince1970))
        } read: { MetricRow(ts: $0.int64(0), avg: $0.double(1), max: $0.double(2), p95: $0.double(3)) }
    }

    private func bindRange(_ s: Statement, _ machineId: String, _ from: Date, _ to: Date) {
        s.bind(1, machineId)
        s.bind(2, Int64(from.timeIntervalSince1970))
        s.bind(3, Int64(to.timeIntervalSince1970))
    }

    private func rows<T>(_ sql: String, bind: (Statement) -> Void, read: (Statement) -> T) throws(DatabaseError) -> [T] {
        let stmt = try db.prepare(sql)
        bind(stmt)
        var out: [T] = []
        while try stmt.step() { out.append(read(stmt)) }
        return out
    }
}

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

public struct MetricPoint: Sendable, Equatable {
    public var ts: Double
    public var avg: Double
    public var max: Double
    public var p95: Double
}

/// One `top_procs_1m` entry. `kind` is `cpu` (CPU seconds in the peak 10 s tick) or `memory` (bytes).
public struct TopProcess: Sendable, Equatable {
    public var kind: String
    public var name: String
    public var group: String
    public var value: Double
}

public struct RunActivity: Sendable, Equatable {
    public var tool: String
    public var started: Double
    public var ended: Double?
    public var lastUsage: Double?
    public var cpuSeconds: Double
    public var peakFootprint: UInt64
    public var activeSeconds: Double
}

public struct StoredEvent: Sendable, Equatable {
    public var ts: Double
    public var kind: String
    public var payload: String
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

    public func mostRecentMachineId() throws(DatabaseError) -> String? {
        try rows("SELECT machine_id FROM machines ORDER BY last_seen DESC LIMIT 1") { _ in
        } read: { $0.string(0) }.first
    }

    /// Tags whose payload isn't the recorder's `{"text": …}` are skipped: a marker on a chart isn't worth failing
    /// a report over.
    public func tags(machineId: String, from: Date, to: Date) throws(DatabaseError) -> [(Date, String)] {
        try rows(
            "SELECT ts, payload FROM events WHERE machine_id=? AND kind='tag' AND ts>=? AND ts<? ORDER BY ts"
        ) { s in bindRange(s, machineId, from, to) } read: { s -> (Date, String)? in
            guard let payload = try? JSONDecoder().decode([String: String].self, from: Data(s.string(1).utf8)),
                let text = payload["text"]
            else { return nil }
            return (Date(timeIntervalSince1970: s.double(0)), text)
        }.compactMap { $0 }
    }

    /// Rows whose payload lacks a parseable root are skipped, like `tags`.
    public func containerIntents(machineId: String, from: Double, to: Double) throws(DatabaseError) -> [(ts: Double, root: ProcessKey)] {
        try rows(
            "SELECT ts, payload FROM events WHERE machine_id=? AND kind='container_intent' AND ts>=? AND ts<? ORDER BY ts"
        ) { s in
            s.bind(1, machineId)
            s.bind(2, Self.epoch(from))
            s.bind(3, Self.epoch(to))
        } read: { s -> (ts: Double, root: ProcessKey)? in
            guard let payload = try? JSONDecoder().decode([String: String].self, from: Data(s.string(1).utf8)),
                let pid = payload["rootPid"].flatMap({ Int32($0) }),
                let start = payload["rootStart"].flatMap({ UInt64($0) })
            else { return nil }
            return (s.double(0), ProcessKey(pid: pid, start: start))
        }.compactMap { $0 }
    }

    /// Warnings per trigger. Rows written before the trigger was recorded only ever fired on critical pressure.
    public func agentWarningCounts(machineId: String, from: Date, to: Date) throws(DatabaseError) -> [String: Int] {
        let counts = try rows(
            """
            SELECT COALESCE(json_extract(payload, '$.trigger'), 'critical'), COUNT(*) FROM events
            WHERE machine_id=? AND kind='agent_warning' AND ts>=? AND ts<? GROUP BY 1
            """
        ) { s in bindRange(s, machineId, from, to) } read: { ($0.string(0), Int($0.int64(1))) }
        return Dictionary(counts, uniquingKeysWith: +)
    }

    static let leftoverKinds = "('leftover','leftover_cleared','leftover_bytes')"

    /// The running total after each leftover event, so its maximum is the peak. The last total before the range
    /// counts too, because containers already held when the range opens are still held at its start. Unparseable
    /// payloads are skipped; nil means no leftover event at or before the range.
    public func leftoverPeakBytes(machineId: String, from: Date, to: Date) throws(DatabaseError) -> UInt64? {
        let inRange = try rows(
            "SELECT payload FROM events WHERE machine_id=? AND kind IN \(Self.leftoverKinds) AND ts>=? AND ts<?"
        ) { s in bindRange(s, machineId, from, to) } read: { Self.leftoverTotals($0.string(0)).bytes }.compactMap { $0 }
        let seed = try lastLeftoverTotals(machineId: machineId, before: from.timeIntervalSince1970)?.bytes
        return (inRange + (seed.map { [$0] } ?? [])).max()
    }

    /// The newest leftover event before `before` whose payload carries a parseable `totalBytes`.
    private func lastLeftoverTotals(machineId: String, before: Double) throws(DatabaseError) -> (bytes: UInt64, count: Int?)? {
        try rows(
            """
            SELECT payload FROM events WHERE machine_id=? AND kind IN \(Self.leftoverKinds) AND ts<?
            AND json_valid(payload) AND json_extract(payload, '$.totalBytes') IS NOT NULL
            ORDER BY ts DESC, rowid DESC LIMIT 1
            """
        ) { s in
            s.bind(1, machineId)
            s.bind(2, Self.epoch(before.rounded(.up)))
        } read: { s -> (bytes: UInt64, count: Int?)? in
            let totals = Self.leftoverTotals(s.string(0))
            return totals.bytes.map { (bytes: $0, count: totals.count) }
        }.first ?? nil
    }

    private static func leftoverTotals(_ payload: String) -> (bytes: UInt64?, count: Int?) {
        guard let fields = try? JSONDecoder().decode([String: String].self, from: Data(payload.utf8)) else { return (nil, nil) }
        return (fields["totalBytes"].flatMap { UInt64($0) }, fields["totalCount"].flatMap { Int($0) })
    }

    /// Ownership facts for the leftover pass, covering intents, runs that are live or ended at or after `since`, and
    /// their active minutes from `since` on. `lastIntent` is a run's latest marker since then.
    ///
    /// Precondition: `since` must be at or before the earliest candidate item's `startedAt - 600`, the intent
    /// window. A later `since` drops the markers that name the item's owner, and the item looks unowned.
    ///
    /// `awakeSeconds` counts 10 s samples in [a, b), read up front because the closure must be Sendable and can't
    /// hold the connection. Only the newest `idleThreshold / 10 + 1` samples are loaded, which is all the policy
    /// needs to tell whether an owner has been idle that long: when that many exist, a range starting before the
    /// oldest of them reports `idleThreshold` instead of its exact length. `idleThreshold` must be the largest
    /// threshold the policy applies.
    public func ownershipFacts(
        machineId: String, since: Double, now: Double, idleThreshold: Double
    ) throws(DatabaseError) -> OwnershipFacts {
        let intents = try containerIntents(machineId: machineId, from: since, to: now + 1)

        let runRows = try rows(
            """
            SELECT r.run_id, r.root_pid, r.root_start, r.started, r.ended, s.session_id
            FROM agent_runs r LEFT JOIN agent_run_sessions s ON s.run_id = r.run_id
            WHERE r.machine_id=? AND (r.ended IS NULL OR r.ended>=?)
            """
        ) { s in
            s.bind(1, machineId)
            s.bind(2, Self.epoch(since.rounded(.down)))
        } read: { s in
            (
                id: s.int64(0), key: ProcessKey(pid: Int32(clamping: s.int64(1)), start: UInt64(clamping: s.int64(2))),
                started: s.double(3), ended: s.isNull(4) ? nil : s.double(4), session: s.isNull(5) ? nil : s.string(5)
            )
        }

        var lastIntent: [ProcessKey: Double] = [:]
        for intent in intents { lastIntent[intent.root] = max(lastIntent[intent.root] ?? intent.ts, intent.ts) }

        let usage = try db.prepare("SELECT ts FROM run_usage WHERE run_id=? AND ts>=? AND active_seconds>0 ORDER BY ts")
        let firstMinute = Self.epoch((since / 60).rounded(.down) * 60)
        var runs: [ProcessKey: RunFacts] = [:]
        var seen = Set<Int64>()
        for row in runRows {
            if let session = row.session { runs[row.key]?.sessionIds.insert(session) }
            guard seen.insert(row.id).inserted else { continue }
            usage.reset()
            usage.bind(1, row.id)
            usage.bind(2, firstMinute)
            var minutes: [Double] = []
            while try usage.step() { minutes.append(usage.double(0)) }
            runs[row.key] = RunFacts(
                sessionIds: row.session.map { [$0] } ?? [], started: row.started, ended: row.ended,
                lastIntent: lastIntent[row.key], activeMinutes: minutes)
        }

        // The threshold comes from config, so it is clamped before the conversion, which traps past Int64.max.
        let maxThreshold = Double(LeftoversConfig.maxAfterMinutes) * 60
        let threshold = idleThreshold.isNaN ? 0 : min(max(0, idleThreshold), maxThreshold)
        let limit = Int64(threshold / Self.sampleInterval) + 1
        let samples: [Double] = try rows(
            "SELECT ts FROM samples WHERE machine_id=? AND ts<? ORDER BY ts DESC LIMIT ?"
        ) { s in
            s.bind(1, machineId)
            s.bind(2, Self.epoch(now.rounded(.up)))
            s.bind(3, limit)
        } read: { $0.double(0) }.reversed()
        let saturated = samples.count == Int(limit)
        let oldest = samples.first ?? now

        let interval = Self.sampleInterval
        return OwnershipFacts(intents: intents, runs: runs) { a, b in
            guard b > a else { return 0 }
            if saturated && a < oldest { return threshold }
            return Self.count(samples, from: a, to: b) * interval
        }
    }

    /// Elements of an ascending array in [from, to).
    private static func count(_ sorted: [Double], from: Double, to: Double) -> Double {
        func lowerBound(_ x: Double) -> Int {
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid] < x { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        return Double(lowerBound(to) - lowerBound(from))
    }

    /// Runs with usage recorded in the range, and the CPU seconds of that usage, so both describe one set. A run
    /// left open by a crash has no later usage, so it can't inflate ranges after it.
    public func agentRunTotals(machineId: String, from: Date, to: Date) throws(DatabaseError) -> (runs: Int, cpuSeconds: Double) {
        let runs = try rows(
            """
            SELECT COUNT(DISTINCT r.run_id) FROM agent_runs r WHERE r.machine_id=?
            AND EXISTS (SELECT 1 FROM run_usage u WHERE u.run_id = r.run_id AND u.ts>=? AND u.ts<?)
            """
        ) { s in bindRange(s, machineId, from, to) } read: { Int($0.int64(0)) }.first ?? 0
        let cpu = try rows(
            """
            SELECT COALESCE(SUM(u.cpu_seconds), 0) FROM run_usage u JOIN agent_runs r ON r.run_id = u.run_id
            WHERE r.machine_id=? AND u.ts>=? AND u.ts<?
            """
        ) { s in bindRange(s, machineId, from, to) } read: { $0.double(0) }.first ?? 0
        return (runs, cpu)
    }

    /// Bytes written to the drive per local day, summed from the 10 s samples so every tick counts once. Only days
    /// still inside raw retention appear.
    public func dailySSDWriteBytes(
        machineId: String, from: Date, to: Date, calendar: Calendar = .current
    ) throws(DatabaseError) -> [String: Double] {
        let hours = try rows(
            """
            SELECT ts - ts % 3600, SUM(ssd_write) FROM samples
            WHERE machine_id=? AND ts>=? AND ts<? AND ssd_write IS NOT NULL GROUP BY 1
            """
        ) { s in bindRange(s, machineId, from, to) } read: { (ts: $0.int64(0), bytes: $0.double(1)) }
        var byDay: [String: Double] = [:]
        for hour in hours {
            byDay[LocalDay(containing: Double(hour.ts), calendar: calendar).name, default: 0] += hour.bytes
        }
        return byDay
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

    /// Entries into serious or critical. The recorder logs every level change, so counting raw thermal events
    /// would also count each step back down and each serious-to-critical move as another slowdown. The last
    /// level before the range seeds the walk, so a slowdown already under way when the range opens isn't new.
    public func thermalSlowdowns(machineId: String, from: Date, to: Date) throws(DatabaseError) -> Int {
        let level = "COALESCE(CAST(json_extract(payload, '$.level') AS INTEGER), 0)"
        let seed = try rows(
            "SELECT \(level) FROM events WHERE machine_id=? AND kind='thermal' AND ts<? ORDER BY ts DESC, rowid DESC LIMIT 1"
        ) { s in
            s.bind(1, machineId)
            s.bind(2, Self.epoch(from.timeIntervalSince1970))
        } read: { $0.int64(0) }
        let levels = try rows(
            "SELECT \(level) FROM events WHERE machine_id=? AND kind='thermal' AND ts>=? AND ts<? ORDER BY ts, rowid"
        ) { s in bindRange(s, machineId, from, to) } read: { $0.int64(0) }

        let serious = Int64(ThermalLevel.serious.rawValue)
        var previous = seed.first ?? Int64(ThermalLevel.nominal.rawValue)
        var entries = 0
        for current in levels {
            if current >= serious && previous < serious { entries += 1 }
            previous = current
        }
        return entries
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

    // MARK: - Point-in-time views for the MCP server

    public static let minuteResolution = minute
    public static let hourResolution = hour

    /// Rollup rows of one resolution in [from, to), oldest first.
    public func metricSeries(
        machineId: String, metric: Metric, resolution: Int64, from: Double, to: Double, limit: Int
    ) throws(DatabaseError) -> [MetricPoint] {
        try rows(
            """
            SELECT ts, avg, max, p95 FROM rollup
            WHERE machine_id=? AND resolution=? AND metric=? AND ts>=? AND ts<? ORDER BY ts LIMIT ?
            """
        ) { s in
            s.bind(1, machineId)
            s.bind(2, resolution)
            s.bind(3, metric.rawValue)
            s.bind(4, Self.epoch(from.rounded(.down)))
            s.bind(5, Self.epoch(to.rounded(.up)))
            s.bind(6, Int64(limit))
        } read: { MetricPoint(ts: $0.double(0), avg: $0.double(1), max: $0.double(2), p95: $0.double(3)) }
    }

    /// The largest per-row maximum in [from, to), or nil when no rollup covers the range.
    public func metricPeak(
        machineId: String, metric: Metric, resolution: Int64, from: Double, to: Double
    ) throws(DatabaseError) -> Double? {
        try rows(
            "SELECT MAX(max) FROM rollup WHERE machine_id=? AND resolution=? AND metric=? AND ts>=? AND ts<?"
        ) { s in
            s.bind(1, machineId)
            s.bind(2, resolution)
            s.bind(3, metric.rawValue)
            s.bind(4, Self.epoch(from.rounded(.down)))
            s.bind(5, Self.epoch(to.rounded(.up)))
        } read: { $0.isNull(0) ? nil : $0.double(0) }.first ?? nil
    }

    public func limitSeconds(
        machineId: String, resolution: Int64, from: Double, to: Double
    ) throws(DatabaseError) -> [LimitKind: Double] {
        var totals: [LimitKind: Double] = [:]
        for row in try limitRows(
            machineId, resolution: resolution, from: Date(timeIntervalSince1970: from.rounded(.down)),
            to: Date(timeIntervalSince1970: to.rounded(.up)))
        {
            totals[row.kind, default: 0] += row.seconds
        }
        return totals
    }

    /// The worst memory-pressure level among raw samples in [from, to); nil once they have aged out.
    public func maxPressure(machineId: String, from: Double, to: Double) throws(DatabaseError) -> Int? {
        try rows("SELECT MAX(pressure) FROM samples WHERE machine_id=? AND ts>=? AND ts<?") { s in
            bindSeconds(s, machineId, from, to)
        } read: { $0.isNull(0) ? nil : Int($0.int64(0)) }.first ?? nil
    }

    /// The newest tick that recorded workload groups.
    public func latestGroupSample(machineId: String) throws(DatabaseError) -> Double? {
        try rows("SELECT MAX(ts) FROM group_samples WHERE machine_id=?") { s in
            s.bind(1, machineId)
        } read: { $0.isNull(0) ? nil : $0.double(0) }.first ?? nil
    }

    /// The newest minute of top processes, by kind and rank.
    public func latestTopProcesses(machineId: String) throws(DatabaseError) -> [TopProcess] {
        try rows(
            """
            SELECT kind, name, group_id, value FROM top_procs_1m
            WHERE machine_id=?1 AND ts=(SELECT MAX(ts) FROM top_procs_1m WHERE machine_id=?1) ORDER BY kind, rank
            """
        ) { s in s.bind(1, machineId) } read: {
            TopProcess(kind: $0.string(0), name: $0.string(1), group: $0.string(2), value: $0.double(3))
        }
    }

    /// Each process's peak minute in [from, to), largest first within each kind.
    public func topProcesses(machineId: String, from: Double, to: Double) throws(DatabaseError) -> [TopProcess] {
        try rows(
            """
            SELECT kind, name, group_id, MAX(value) FROM top_procs_1m
            WHERE machine_id=? AND ts>=? AND ts<? GROUP BY kind, name ORDER BY kind, 4 DESC, name
            """
        ) { s in bindSeconds(s, machineId, from, to) } read: {
            TopProcess(kind: $0.string(0), name: $0.string(1), group: $0.string(2), value: $0.double(3))
        }
    }

    /// Runs not yet closed, each with its newest usage minute (zero when it has none yet).
    public func openAgentRuns(machineId: String, limit: Int) throws(DatabaseError) -> [RunActivity] {
        try rows(
            """
            SELECT r.tool, r.started, u.ts, u.cpu_seconds, u.peak_footprint, u.active_seconds
            FROM agent_runs r LEFT JOIN run_usage u
                ON u.run_id = r.run_id AND u.ts = (SELECT MAX(ts) FROM run_usage WHERE run_id = r.run_id)
            WHERE r.machine_id=? AND r.ended IS NULL ORDER BY r.started LIMIT ?
            """
        ) { s in
            s.bind(1, machineId)
            s.bind(2, Int64(limit))
        } read: { s in
            RunActivity(
                tool: s.string(0), started: s.double(1), ended: nil, lastUsage: s.isNull(2) ? nil : s.double(2),
                cpuSeconds: s.double(3), peakFootprint: UInt64(clamping: s.int64(4)), activeSeconds: s.double(5))
        }
    }

    /// Runs with usage in [from, to) and that usage summed, busiest first.
    public func agentRunActivity(
        machineId: String, from: Double, to: Double, limit: Int
    ) throws(DatabaseError) -> [RunActivity] {
        try rows(
            """
            SELECT r.tool, r.started, r.ended, MAX(u.ts), SUM(u.cpu_seconds), MAX(u.peak_footprint), SUM(u.active_seconds)
            FROM run_usage u JOIN agent_runs r ON r.run_id = u.run_id
            WHERE r.machine_id=? AND u.ts>=? AND u.ts<? GROUP BY r.run_id ORDER BY 5 DESC LIMIT ?
            """
        ) { s in
            bindSeconds(s, machineId, from, to)
            s.bind(4, Int64(limit))
        } read: { s in
            RunActivity(
                tool: s.string(0), started: s.double(1), ended: s.isNull(2) ? nil : s.double(2), lastUsage: s.double(3),
                cpuSeconds: s.double(4), peakFootprint: UInt64(clamping: s.int64(5)), activeSeconds: s.double(6))
        }
    }

    public func events(machineId: String, from: Double, to: Double, limit: Int) throws(DatabaseError) -> [StoredEvent] {
        try rows(
            "SELECT ts, kind, payload FROM events WHERE machine_id=? AND ts>=? AND ts<? ORDER BY ts, rowid LIMIT ?"
        ) { s in
            bindSeconds(s, machineId, from, to)
            s.bind(4, Int64(limit))
        } read: { StoredEvent(ts: $0.double(0), kind: $0.string(1), payload: $0.string(2)) }
    }

    /// Leftovers flagged and not cleared before `before`, and the running byte total the last event carried. The
    /// count is the last event's `totalCount`; rows written before it existed fall back to flags minus clears.
    public func leftoversBefore(machineId: String, before: Double) throws(DatabaseError) -> (count: Int, bytes: UInt64) {
        let last = try lastLeftoverTotals(machineId: machineId, before: before)
        if let last, let count = last.count { return (max(0, count), last.bytes) }
        let count = try rows(
            """
            SELECT COALESCE(SUM(CASE kind WHEN 'leftover' THEN 1 WHEN 'leftover_cleared' THEN -1 ELSE 0 END), 0) FROM events
            WHERE machine_id=? AND kind IN ('leftover','leftover_cleared') AND ts<?
            """
        ) { s in
            s.bind(1, machineId)
            s.bind(2, Self.epoch(before.rounded(.up)))
        } read: { Int($0.int64(0)) }.first ?? 0
        // A sidecar rebuilt from scratch can flag an item twice, so the running count is never shown below zero.
        return (max(0, count), last?.bytes ?? 0)
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

    /// Bounds arrive from callers such as the MCP server's input, so any Double must bind: NaN becomes 0 and values
    /// past Int64's range clamp, where `Int64(_:)` would trap.
    static func epoch(_ x: Double) -> Int64 {
        if x.isNaN { return 0 }
        if x >= 9.2e18 { return .max }
        if x <= -9.2e18 { return .min }
        return Int64(x)
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
            s.bind(3, Self.epoch(from.timeIntervalSince1970))
            s.bind(4, Self.epoch(to.timeIntervalSince1970))
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
            s.bind(4, Self.epoch(from.timeIntervalSince1970))
            s.bind(5, Self.epoch(to.timeIntervalSince1970))
        } read: { MetricRow(ts: $0.int64(0), avg: $0.double(1), max: $0.double(2), p95: $0.double(3)) }
    }

    private func bindRange(_ s: Statement, _ machineId: String, _ from: Date, _ to: Date) {
        s.bind(1, machineId)
        s.bind(2, Self.epoch(from.timeIntervalSince1970))
        s.bind(3, Self.epoch(to.timeIntervalSince1970))
    }

    private func bindSeconds(_ s: Statement, _ machineId: String, _ from: Double, _ to: Double) {
        s.bind(1, machineId)
        s.bind(2, Self.epoch(from.rounded(.down)))
        s.bind(3, Self.epoch(to.rounded(.up)))
    }

    private func rows<T>(_ sql: String, bind: (Statement) -> Void, read: (Statement) -> T) throws(DatabaseError) -> [T] {
        let stmt = try db.prepare(sql)
        bind(stmt)
        var out: [T] = []
        while try stmt.step() { out.append(read(stmt)) }
        return out
    }
}

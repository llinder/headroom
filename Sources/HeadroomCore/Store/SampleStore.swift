import Foundation

public struct GroupTotals: Sendable, Equatable {
    public var cpuSeconds: Double
    public var footprint: UInt64
    public var diskWriteBytes: UInt64
    public var procCount: Int

    public init(cpuSeconds: Double, footprint: UInt64, diskWriteBytes: UInt64, procCount: Int) {
        self.cpuSeconds = cpuSeconds
        self.footprint = footprint
        self.diskWriteBytes = diskWriteBytes
        self.procCount = procCount
    }
}

public struct Tick: Sendable {
    public var ts: Double
    public var cpu: CPUReading
    public var memory: MemoryReading
    public var disk: DiskReading
    public var thermal: ThermalLevel
    public var flags: LimitFlags
    public var groups: [WorkloadGroup: GroupTotals]
    public var topByCPU: [(name: String, group: WorkloadGroup, value: Double)]
    public var topByMemory: [(name: String, group: WorkloadGroup, value: Double)]
    public var agents: AgentUpdate
    public var selfCPU: Double
    public var selfFootprint: UInt64

    public init(
        ts: Double, cpu: CPUReading, memory: MemoryReading, disk: DiskReading, thermal: ThermalLevel,
        flags: LimitFlags, groups: [WorkloadGroup: GroupTotals],
        topByCPU: [(name: String, group: WorkloadGroup, value: Double)],
        topByMemory: [(name: String, group: WorkloadGroup, value: Double)],
        agents: AgentUpdate, selfCPU: Double, selfFootprint: UInt64
    ) {
        self.ts = ts
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.thermal = thermal
        self.flags = flags
        self.groups = groups
        self.topByCPU = topByCPU
        self.topByMemory = topByMemory
        self.agents = agents
        self.selfCPU = selfCPU
        self.selfFootprint = selfFootprint
    }
}

public enum Metric: String, CaseIterable, Sendable {
    case cpuBusy, load1, memUsed, memApp, memCompressed, swapUsed
    /// memUsed + swapUsed per tick: the peak of the sum can't be rebuilt from the separate rollups.
    case memDemand
    case ssdWrite, diskFree, activeAgents
}

public enum LimitKind: String, CaseIterable, Sendable {
    case memoryLimited, heavySwap, cpuSaturated, thermalLimited

    var flag: LimitFlags {
        switch self {
        case .memoryLimited: .memoryLimited
        case .heavySwap: .heavySwap
        case .cpuSaturated: .cpuSaturated
        case .thermalLimited: .thermalLimited
        }
    }
}

/// What a rollup needs from one 10 s sample. The 1-minute path builds it from buffered ticks and the
/// hourly path from `samples` rows, so both resolutions compute every metric the same way.
private struct RollupInput {
    var ts: Int64
    var cpuUser: Double
    var cpuSystem: Double
    var load1: Double
    var memUsed: UInt64
    var memApp: UInt64
    var memCompressed: UInt64
    var swapUsed: UInt64
    var ssdWrite: UInt64
    var diskFree: UInt64
    var activeAgents: Int
    var flags: LimitFlags

    init(_ t: Tick) {
        ts = Int64(t.ts.rounded(.down))
        cpuUser = t.cpu.user
        cpuSystem = t.cpu.system
        load1 = t.cpu.load1
        memUsed = t.memory.used
        memApp = t.memory.app
        memCompressed = t.memory.compressed
        swapUsed = t.memory.swapUsed
        ssdWrite = t.disk.writeBytes
        diskFree = t.disk.free
        activeAgents = t.agents.activeCount
        flags = t.flags
    }

    init(row s: Statement) {
        ts = s.int64(0)
        cpuUser = s.double(1)
        cpuSystem = s.double(2)
        load1 = s.double(3)
        memUsed = UInt64(clamping: s.int64(4))
        memApp = UInt64(clamping: s.int64(5))
        memCompressed = UInt64(clamping: s.int64(6))
        swapUsed = UInt64(clamping: s.int64(7))
        ssdWrite = UInt64(clamping: s.int64(8))
        diskFree = UInt64(clamping: s.int64(9))
        activeAgents = Int(s.int64(10))
        flags = LimitFlags(rawValue: UInt8(clamping: s.int64(11)))
    }

    func value(_ m: Metric) -> Double {
        switch m {
        case .cpuBusy: min(1, max(0, cpuUser + cpuSystem))
        case .load1: load1
        case .memUsed: Double(memUsed)
        case .memApp: Double(memApp)
        case .memCompressed: Double(memCompressed)
        case .swapUsed: Double(swapUsed)
        case .memDemand: Double(memUsed) + Double(swapUsed)
        case .ssdWrite: Double(ssdWrite)
        case .diskFree: Double(diskFree)
        case .activeAgents: Double(activeAgents)
        }
    }
}

private enum Pending {
    case event(ts: Int64, kind: String, payload: String)
    case session(ts: Int64, tool: String, sessionId: String, model: String?, root: ProcessKey)
}

private struct CommandPayload: Encodable {
    var exe: String
    var seconds: Double
}

/// The recorder's single writer. Ticks and spool records are buffered in memory and written in one
/// transaction per flush, so a crash loses at most one flush interval.
public final class SampleStore {
    private static let maxPendingRecords = 10_000
    private static let topCount = 5
    private static let minute: Int64 = 60
    private static let hour: Int64 = 3600

    private let db: Database
    private let machineId: String
    private let interval: Double
    private let maxBufferedTicks: Int

    private var buffer: [Tick] = []
    private var pending: [Pending] = []
    // Ticks of the newest minute already written as samples. A flush that lands mid-minute rolls up
    // the partial minute; the next flush recomputes that minute whole from these plus the new ticks.
    private var carry: [Tick] = []

    private let insertSample: Statement
    private let insertGroup: Statement
    private let deleteTop: Statement
    private let insertTop: Statement
    private let upsertRollup: Statement
    private let upsertLimit: Statement
    private let upsertHistogram: Statement
    private let insertEvent: Statement
    private let insertRun: Statement
    private let lowerRunStart: Statement
    private let endRun: Statement
    private let selectRunId: Statement
    private let insertSession: Statement
    private let upsertRunUsage: Statement
    private let setHeartbeat: Statement
    private let selectHour: Statement
    private let deleteGroups: Statement
    private let countSamples: Statement
    private let selectSleepWake: Statement
    private let selectGapEvents: Statement
    private let replaceCoverage: Statement
    private let pruneSamples: Statement
    private let pruneGroups: Statement
    private let pruneTop: Statement

    public init(db: Database, machineId: String, interval: Double = 10) throws {
        self.db = db
        self.machineId = machineId
        self.interval = interval
        maxBufferedTicks = max(1, Int((3600 / interval).rounded()))

        insertSample = try db.prepare("""
            INSERT OR REPLACE INTO samples(
                machine_id, ts, cpu_user, cpu_sys, per_core, load1, load5, load15,
                mem_total, mem_used, mem_app, mem_wired, mem_compressed, mem_free,
                pressure, memorystatus_level, swap_used, swap_total, swapins, swapouts,
                pageins, pageouts, ssd_read, ssd_write, disk_free, disk_capacity,
                thermal, limit_flags, active_agents, idle_agents, self_cpu, self_footprint)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        insertGroup = try db.prepare("""
            INSERT INTO group_samples(machine_id, ts, group_id, cpu_seconds, footprint, disk_write, proc_count)
            VALUES(?,?,?,?,?,?,?)
            """)
        deleteTop = try db.prepare("DELETE FROM top_procs_1m WHERE machine_id=? AND ts=?")
        insertTop = try db.prepare("""
            INSERT INTO top_procs_1m(machine_id, ts, kind, rank, name, group_id, value) VALUES(?,?,?,?,?,?,?)
            """)
        upsertRollup = try db.prepare("""
            INSERT OR REPLACE INTO rollup(machine_id, resolution, ts, metric, avg, max, p95) VALUES(?,?,?,?,?,?,?)
            """)
        upsertLimit = try db.prepare("""
            INSERT OR REPLACE INTO limit_seconds(machine_id, resolution, ts, kind, seconds) VALUES(?,?,?,?,?)
            """)
        upsertHistogram = try db.prepare("""
            INSERT OR REPLACE INTO agent_histogram(machine_id, ts, active_agents, seconds, memory_limited, cpu_saturated)
            VALUES(?,?,?,?,?,?)
            """)
        insertEvent = try db.prepare("INSERT INTO events(machine_id, ts, kind, payload) VALUES(?,?,?,?)")
        insertRun = try db.prepare("""
            INSERT OR IGNORE INTO agent_runs(machine_id, tool, root_pid, root_start, started) VALUES(?,?,?,?,?)
            """)
        lowerRunStart = try db.prepare("""
            UPDATE agent_runs SET started=MIN(started, ?) WHERE machine_id=? AND root_pid=? AND root_start=?
            """)
        endRun = try db.prepare("""
            UPDATE agent_runs SET ended=? WHERE machine_id=? AND root_pid=? AND root_start=? AND ended IS NULL
            """)
        selectRunId = try db.prepare("SELECT run_id FROM agent_runs WHERE machine_id=? AND root_pid=? AND root_start=?")
        insertSession = try db.prepare("""
            INSERT INTO agent_run_sessions(run_id, session_id, model, first_seen) VALUES(?,?,?,?)
            ON CONFLICT(run_id, session_id) DO UPDATE SET
                first_seen = MIN(first_seen, excluded.first_seen),
                model = COALESCE(model, excluded.model)
            """)
        upsertRunUsage = try db.prepare("""
            INSERT OR REPLACE INTO run_usage(run_id, ts, cpu_seconds, peak_footprint, disk_write, active_seconds)
            VALUES(?,?,?,?,?,?)
            """)
        setHeartbeat = try db.prepare("INSERT OR REPLACE INTO meta(key, value) VALUES('heartbeat', ?)")
        selectHour = try db.prepare("""
            SELECT ts, cpu_user, cpu_sys, load1, mem_used, mem_app, mem_compressed, swap_used,
                   ssd_write, disk_free, active_agents, limit_flags
            FROM samples WHERE machine_id=? AND ts>=? AND ts<? ORDER BY ts
            """)
        deleteGroups = try db.prepare("DELETE FROM group_samples WHERE machine_id=? AND ts=?")
        countSamples = try db.prepare("SELECT COUNT(*) FROM samples WHERE machine_id=? AND ts>=? AND ts<?")
        // Starts at the last sleep before the day, so a sleep that began on an earlier day is still paired.
        selectSleepWake = try db.prepare("""
            SELECT ts, kind FROM events
            WHERE machine_id=?1 AND kind IN ('sleep', 'wake') AND ts < ?3
              AND ts >= COALESCE(
                  (SELECT MAX(ts) FROM events WHERE machine_id=?1 AND kind='sleep' AND ts < ?2), ?2)
            ORDER BY ts
            """)
        // A gap event's own ts says nothing about the interval it describes, so all of them are read.
        selectGapEvents = try db.prepare("SELECT payload FROM events WHERE machine_id=? AND kind='gap'")
        replaceCoverage = try db.prepare("""
            INSERT OR REPLACE INTO coverage(machine_id, day, seconds_recorded, seconds_asleep, seconds_gap, gaps)
            VALUES(?,?,?,?,?,?)
            """)
        // Raw tables are pruned for every machine in the file, including ones the DB was copied from.
        pruneSamples = try db.prepare("DELETE FROM samples WHERE ts < ?")
        pruneGroups = try db.prepare("DELETE FROM group_samples WHERE ts < ?")
        pruneTop = try db.prepare("DELETE FROM top_procs_1m WHERE ts < ?")
    }

    public var bufferedTicks: Int { buffer.count }

    public func append(_ t: Tick) {
        buffer.append(t)
        if buffer.count > maxBufferedTicks { buffer.removeFirst(buffer.count - maxBufferedTicks) }
    }

    public func ingest(_ records: [SpoolRecord]) {
        enqueue(records.map { r in
            switch r {
            case let .tag(ts, text):
                .event(ts: Self.seconds(ts), kind: "tag", payload: Self.json(["text": text]))
            case let .command(ts, exe, seconds):
                .event(ts: Self.seconds(ts), kind: "command", payload: Self.json(CommandPayload(exe: exe, seconds: seconds)))
            case let .agentSession(ts, tool, sessionId, model, rootPid, rootStart):
                .session(
                    ts: Self.seconds(ts), tool: tool, sessionId: sessionId, model: model,
                    root: ProcessKey(pid: rootPid, start: rootStart))
            }
        })
    }

    public func recordEvent(kind: String, ts: Double, payload: [String: String]) {
        enqueue([.event(ts: Self.seconds(ts), kind: kind, payload: Self.json(payload))])
    }

    public func flush() throws {
        let rollupTicks = carry + buffer
        let heartbeat = Int64(Date().timeIntervalSince1970)
        try db.transaction {
            for t in buffer { try writeTick(t) }
            for p in pending { try writePending(p) }
            try writeMinutes(rollupTicks)
            try step(setHeartbeat) { $0.bind(1, String(heartbeat)) }
        }
        if let last = rollupTicks.last.map({ Self.bucket($0, Self.minute) }) {
            carry = rollupTicks.filter { Self.bucket($0, Self.minute) == last }
        }
        buffer.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
    }

    /// Rolls up the hour [hourTs - 3600, hourTs) from `samples`; rerunning an hour replaces its rows.
    public func rollupHour(endingAt hourTs: Int64) throws {
        let start = hourTs - Self.hour
        selectHour.reset()
        selectHour.bind(1, machineId)
        selectHour.bind(2, start)
        selectHour.bind(3, hourTs)
        var inputs: [RollupInput] = []
        while try selectHour.step() { inputs.append(RollupInput(row: selectHour)) }
        selectHour.reset()
        guard !inputs.isEmpty else { return }

        try db.transaction {
            try writeRollup(inputs, resolution: Self.hour, ts: start)
            try writeHistogram(inputs, ts: start)
        }
    }

    public func applyRetention(now: Double, days: Int = 30) throws {
        let cutoff = Int64(now.rounded(.down)) - Int64(days) * 86_400
        try db.transaction {
            for s in [pruneSamples, pruneGroups, pruneTop] {
                try step(s) { $0.bind(1, cutoff) }
            }
        }
    }

    /// Recomputes the day's coverage row from `samples` and the sleep, wake and gap events, and replaces
    /// it, so calling it again (after a crash, or for a day still in progress) never double counts.
    /// `day` is the caller's local-time YYYY-MM-DD and [dayStart, dayEnd) its epoch bounds.
    public func refreshCoverage(
        day: String, dayStart: Double, dayEnd: Double, now: Double = Date().timeIntervalSince1970
    ) throws {
        func clipped(_ start: Double, _ end: Double) -> (Double, Double)? {
            let s = max(start, dayStart), e = min(end, dayEnd)
            return e > s ? (s, e) : nil
        }

        try db.transaction {
            countSamples.reset()
            countSamples.bind(1, machineId)
            countSamples.bind(2, dayStart)
            countSamples.bind(3, dayEnd)
            let recorded = try countSamples.step() ? Double(countSamples.int64(0)) * interval : 0
            countSamples.reset()

            var asleep = 0.0
            var sleepStart: Double?
            selectSleepWake.reset()
            selectSleepWake.bind(1, machineId)
            selectSleepWake.bind(2, dayStart)
            selectSleepWake.bind(3, dayEnd)
            while try selectSleepWake.step() {
                let ts = selectSleepWake.double(0)
                if selectSleepWake.string(1) == "sleep" {
                    // A repeated sleep without a wake between keeps the first.
                    if sleepStart == nil { sleepStart = ts }
                } else if let start = sleepStart {
                    if let c = clipped(start, ts) { asleep += c.1 - c.0 }
                    sleepStart = nil
                }
            }
            selectSleepWake.reset()
            if let start = sleepStart, let c = clipped(start, min(dayEnd, now)) { asleep += c.1 - c.0 }

            var gaps: [(Double, Double)] = []
            selectGapEvents.reset()
            selectGapEvents.bind(1, machineId)
            while try selectGapEvents.step() {
                guard let payload = try? JSONDecoder().decode(
                    [String: String].self, from: Data(selectGapEvents.string(0).utf8)),
                    let start = payload["start"].flatMap(Double.init),
                    let end = payload["end"].flatMap(Double.init),
                    let gap = clipped(start, end)
                else { continue }
                gaps.append(gap)
            }
            selectGapEvents.reset()
            gaps.sort { $0.0 < $1.0 }

            let gapSeconds = gaps.reduce(0) { $0 + $1.1 - $1.0 }
            let gapsJSON = Self.json(gaps.map { [Self.seconds($0.0), Self.seconds($0.1)] })
            try step(replaceCoverage) { s in
                s.bind(1, machineId)
                s.bind(2, day)
                s.bind(3, recorded)
                s.bind(4, asleep)
                s.bind(5, gapSeconds)
                s.bind(6, gapsJSON)
            }
        }
    }

    // MARK: - Writing

    private func enqueue(_ batch: [Pending]) {
        pending.append(contentsOf: batch)
        if pending.count > Self.maxPendingRecords { pending.removeFirst(pending.count - Self.maxPendingRecords) }
    }

    private func writeTick(_ t: Tick) throws {
        let ts = Self.seconds(t.ts)
        try step(insertSample) { s in
            s.bind(1, machineId)
            s.bind(2, ts)
            s.bind(3, t.cpu.user)
            s.bind(4, t.cpu.system)
            s.bind(5, Self.perCoreBlob(t.cpu.perCoreBusy))
            s.bind(6, t.cpu.load1)
            s.bind(7, t.cpu.load5)
            s.bind(8, t.cpu.load15)
            s.bind(9, Int64(clamping: t.memory.total))
            s.bind(10, Int64(clamping: t.memory.used))
            s.bind(11, Int64(clamping: t.memory.app))
            s.bind(12, Int64(clamping: t.memory.wired))
            s.bind(13, Int64(clamping: t.memory.compressed))
            s.bind(14, Int64(clamping: t.memory.free))
            s.bind(15, Int64(t.memory.pressure.rawValue))
            s.bind(16, t.memory.memorystatusLevel.map(Int64.init))
            s.bind(17, Int64(clamping: t.memory.swapUsed))
            s.bind(18, Int64(clamping: t.memory.swapTotal))
            s.bind(19, Int64(clamping: t.memory.swapins))
            s.bind(20, Int64(clamping: t.memory.swapouts))
            s.bind(21, Int64(clamping: t.memory.pageins))
            s.bind(22, Int64(clamping: t.memory.pageouts))
            s.bind(23, Int64(clamping: t.disk.readBytes))
            s.bind(24, Int64(clamping: t.disk.writeBytes))
            s.bind(25, Int64(clamping: t.disk.free))
            s.bind(26, Int64(clamping: t.disk.capacity))
            s.bind(27, Int64(t.thermal.rawValue))
            s.bind(28, Int64(t.flags.rawValue))
            s.bind(29, Int64(t.agents.activeCount))
            s.bind(30, Int64(t.agents.idleCount))
            s.bind(31, t.selfCPU)
            s.bind(32, Int64(clamping: t.selfFootprint))
        }
        // Matches the samples REPLACE: rewriting a tick replaces its group rows instead of adding to them.
        try step(deleteGroups) { s in
            s.bind(1, machineId)
            s.bind(2, ts)
        }
        for (group, totals) in t.groups.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where totals.procCount > 0 {
            try step(insertGroup) { s in
                s.bind(1, machineId)
                s.bind(2, ts)
                s.bind(3, group.rawValue)
                s.bind(4, totals.cpuSeconds)
                s.bind(5, Int64(clamping: totals.footprint))
                s.bind(6, Int64(clamping: totals.diskWriteBytes))
                s.bind(7, Int64(totals.procCount))
            }
        }
        // Live runs are upserted, not only started ones, so a run whose start tick was dropped from a
        // full buffer still gets a row and its usage.
        for run in t.agents.live {
            try ensureRun(root: run.root, tool: run.tool.rawValue, started: Self.seconds(run.started))
        }
        for key in t.agents.ended {
            try step(endRun) { s in
                s.bind(1, ts)
                s.bind(2, machineId)
                s.bind(3, Int64(key.pid))
                s.bind(4, Self.rootStart(key))
            }
        }
    }

    private func writePending(_ p: Pending) throws {
        switch p {
        case let .event(ts, kind, payload):
            try step(insertEvent) { s in
                s.bind(1, machineId)
                s.bind(2, ts)
                s.bind(3, kind)
                s.bind(4, payload)
            }
        case let .session(ts, tool, sessionId, model, root):
            try ensureRun(root: root, tool: tool, started: ts)
            guard let runId = try runId(root) else { return }
            try step(insertSession) { s in
                s.bind(1, runId)
                s.bind(2, sessionId)
                s.bind(3, model)
                s.bind(4, ts)
            }
        }
    }

    /// Creates the run row if missing and keeps the earliest start, whichever of the process sweep
    /// and a hook's session record reported the run first.
    private func ensureRun(root: ProcessKey, tool: String, started: Int64) throws {
        try step(insertRun) { s in
            s.bind(1, machineId)
            s.bind(2, tool)
            s.bind(3, Int64(root.pid))
            s.bind(4, Self.rootStart(root))
            s.bind(5, started)
        }
        try step(lowerRunStart) { s in
            s.bind(1, started)
            s.bind(2, machineId)
            s.bind(3, Int64(root.pid))
            s.bind(4, Self.rootStart(root))
        }
    }

    private func runId(_ root: ProcessKey) throws -> Int64? {
        selectRunId.reset()
        selectRunId.bind(1, machineId)
        selectRunId.bind(2, Int64(root.pid))
        selectRunId.bind(3, Self.rootStart(root))
        let id = try selectRunId.step() ? selectRunId.int64(0) : nil
        selectRunId.reset()
        return id
    }

    private func writeMinutes(_ ticks: [Tick]) throws {
        let byMinute = Dictionary(grouping: ticks) { Self.bucket($0, Self.minute) }
        for (minute, minuteTicks) in byMinute.sorted(by: { $0.key < $1.key }) {
            try writeRollup(minuteTicks.map(RollupInput.init), resolution: Self.minute, ts: minute)
            try writeTop(minuteTicks, minute: minute)
            try writeRunUsage(minuteTicks, minute: minute)
        }
    }

    private func writeRollup(_ inputs: [RollupInput], resolution: Int64, ts: Int64) throws {
        for metric in Metric.allCases {
            let stats = Self.stats(inputs.map { $0.value(metric) })
            try step(upsertRollup) { s in
                s.bind(1, machineId)
                s.bind(2, resolution)
                s.bind(3, ts)
                s.bind(4, metric.rawValue)
                s.bind(5, stats.avg)
                s.bind(6, stats.max)
                s.bind(7, stats.p95)
            }
        }
        for kind in LimitKind.allCases {
            let seconds = Double(inputs.filter { $0.flags.contains(kind.flag) }.count) * interval
            try step(upsertLimit) { s in
                s.bind(1, machineId)
                s.bind(2, resolution)
                s.bind(3, ts)
                s.bind(4, kind.rawValue)
                s.bind(5, seconds)
            }
        }
    }

    private func writeHistogram(_ inputs: [RollupInput], ts: Int64) throws {
        let byLevel = Dictionary(grouping: inputs, by: \.activeAgents)
        for (level, rows) in byLevel.sorted(by: { $0.key < $1.key }) {
            try step(upsertHistogram) { s in
                s.bind(1, machineId)
                s.bind(2, ts)
                s.bind(3, Int64(level))
                s.bind(4, Double(rows.count) * interval)
                s.bind(5, Double(rows.filter { $0.flags.contains(.memoryLimited) }.count) * interval)
                s.bind(6, Double(rows.filter { $0.flags.contains(.cpuSaturated) }.count) * interval)
            }
        }
    }

    private func writeTop(_ ticks: [Tick], minute: Int64) throws {
        try step(deleteTop) { s in
            s.bind(1, machineId)
            s.bind(2, minute)
        }
        let kinds: [(String, KeyPath<Tick, [(name: String, group: WorkloadGroup, value: Double)]>)] = [
            ("cpu", \.topByCPU), ("memory", \.topByMemory),
        ]
        for (kind, path) in kinds {
            var peak: [String: (group: WorkloadGroup, value: Double)] = [:]
            for t in ticks {
                for p in t[keyPath: path] where p.value > (peak[p.name]?.value ?? -.infinity) {
                    peak[p.name] = (p.group, p.value)
                }
            }
            let ranked = peak.sorted { ($0.value.value, $1.key) > ($1.value.value, $0.key) }.prefix(Self.topCount)
            for (rank, entry) in ranked.enumerated() {
                try step(insertTop) { s in
                    s.bind(1, machineId)
                    s.bind(2, minute)
                    s.bind(3, kind)
                    s.bind(4, Int64(rank + 1))
                    s.bind(5, entry.key)
                    s.bind(6, entry.value.group.rawValue)
                    s.bind(7, entry.value.value)
                }
            }
        }
    }

    private func writeRunUsage(_ ticks: [Tick], minute: Int64) throws {
        var usage: [ProcessKey: (cpu: Double, footprint: UInt64, write: UInt64, active: Double)] = [:]
        for t in ticks {
            for run in t.agents.live {
                var u = usage[run.root] ?? (0, 0, 0, 0)
                u.cpu += run.cpuSeconds
                u.footprint = max(u.footprint, run.footprint)
                u.write += run.diskWriteBytes
                if run.isActive { u.active += interval }
                usage[run.root] = u
            }
        }
        for (root, u) in usage {
            guard let runId = try runId(root) else { continue }
            try step(upsertRunUsage) { s in
                s.bind(1, runId)
                s.bind(2, minute)
                s.bind(3, u.cpu)
                s.bind(4, Int64(clamping: u.footprint))
                s.bind(5, Int64(clamping: u.write))
                s.bind(6, u.active)
            }
        }
    }

    private func step(_ s: Statement, _ bind: (Statement) -> Void) throws {
        // Reset first so a statement left mid-step by an earlier failure starts clean.
        s.reset()
        bind(s)
        _ = try s.step()
    }

    // MARK: - Helpers

    private static func seconds(_ ts: Double) -> Int64 { Int64(ts.rounded(.down)) }

    private static func bucket(_ t: Tick, _ size: Int64) -> Int64 {
        let ts = seconds(t.ts)
        return ts - ts % size
    }

    // root_start is the process start in microseconds since the epoch, which fits an Int64 for ~290k years.
    private static func rootStart(_ key: ProcessKey) -> Int64 { Int64(clamping: key.start) }

    private static func stats(_ values: [Double]) -> (avg: Double, max: Double, p95: Double) {
        let sorted = values.sorted()
        guard let last = sorted.last else { return (0, 0, 0) }
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        return (sorted.reduce(0, +) / Double(sorted.count), last, sorted[max(0, rank - 1)])
    }

    // Little-endian Float32 per core: half the size of Double, and per-core busy needs no more precision.
    private static func perCoreBlob(_ values: [Double]) -> Data {
        var data = Data(capacity: values.count * 4)
        for v in values {
            withUnsafeBytes(of: Float32(v).bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Encoding plain strings, numbers and arrays of them cannot fail.
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

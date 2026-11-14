import Darwin
import Foundation
import HeadroomCore
import os

@MainActor
final class Recorder {
    private static let interval = 10.0
    private static let flushEvery = 6
    private static let spaceRefreshEvery = 6
    private static let scanEvery = 30
    private static let hour: Int64 = 3600
    private static let maxCatchUpHours: Int64 = 48
    // Rescans overlap the previous scan a little so a report written as a scan runs isn't missed;
    // the scanner drops the files it already returned.
    private static let scanOverlap = 300.0
    private static let maxCoverageDays = 31

    private let log = Logger(subsystem: "io.github.llinder.headroom", category: "recorder")
    private let store: SampleStore
    private let machineId: String
    private let spool: Spool
    private let readMeta: Statement
    private let writeMeta: Statement
    private let timebase: mach_timebase_info_data_t
    private let clock = SuspendingClock()
    private var liveState: LiveStateWriter
    private var pipeline: SamplingPipeline
    private var scanner: DiagnosticScanner
    private var power: PowerMonitor?
    private var timer: (any DispatchSourceTimer)?
    private var terminate: (any DispatchSourceSignal)?

    private var tickCount = 0
    private var lastSample: SuspendingClock.Instant
    private var sleep = SleepState()
    private var thermal = ThermalLevel.current()
    private var lastSelfCPU: Double?
    private var nextScanSince = Date()
    // Coverage is refreshed for every local day from here through today, then this moves to the flush time.
    // It starts at the last heartbeat, so a restart settles each day a gap touched, and the first flush after
    // midnight settles the day before.
    private var coverageFrom = Date().timeIntervalSince1970
    private var lastRolledHour: Int64?
    private var lastLiveWarning = -Double.infinity

    init(paths: Paths) throws {
        try paths.ensureRoot()
        let db = try Database(path: paths.database.path, readOnly: false)
        try Schema.migrate(db)
        let machine = MachineInfo.current()
        try machine.register(in: db, now: Date())

        let (config, configWarning) = HeadroomConfig.load(from: paths.config)
        if let configWarning { log.warning("config: \(configWarning)") }
        let (rules, rulesWarning) = GroupRules.load(from: paths.groups)
        if let rulesWarning { log.warning("group rules: \(rulesWarning)") }

        machineId = machine.machineId
        store = try SampleStore(db: db, machineId: machine.machineId, interval: Self.interval)
        spool = Spool(url: paths.spool)
        liveState = try LiveStateWriter(url: paths.liveState)
        readMeta = try db.prepare("SELECT value FROM meta WHERE key=?")
        writeMeta = try db.prepare("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)")
        pipeline = SamplingPipeline(
            classifier: Classifier(rules: rules, currentUID: getuid()), config: config, interval: Self.interval)
        scanner = DiagnosticScanner(directories: [
            URL(filePath: "/Library/Logs/DiagnosticReports", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports"),
        ])
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info
        lastSample = clock.now
    }

    func start() {
        let now = Date().timeIntervalSince1970
        var heartbeat: Double?
        do {
            heartbeat = try metaValue("heartbeat").flatMap(Double.init)
            lastRolledHour = try metaValue("last_rollup_hour").flatMap(Int64.init)
        } catch {
            log.error("reading meta failed: \(String(describing: error), privacy: .public)")
        }
        let (lastSleep, lastWake) = GapDetector.lastSleepWake()
        if let gap = GapDetector.startupGap(
            lastHeartbeat: heartbeat, now: now, bootTime: GapDetector.bootTime(), lastSleep: lastSleep,
            lastWake: lastWake)
        {
            store.recordEvent(kind: "gap", ts: now, payload: [
                "start": String(Int64(gap.start.timeIntervalSince1970)),
                "end": String(Int64(gap.end.timeIntervalSince1970)),
            ])
            log.notice("recorder was absent for \(Int(gap.duration)) s while the machine was awake")
        }
        store.recordEvent(kind: "recorder_start", ts: now, payload: [:])
        do {
            try store.closeOrphanRuns(machineId: machineId, fallbackEnd: heartbeat ?? now)
        } catch {
            log.error("closing orphaned agent runs failed: \(String(describing: error), privacy: .public)")
        }
        // Reports written while the recorder was down are still picked up; a first run starts from now.
        nextScanSince = Date(timeIntervalSince1970: heartbeat ?? now)
        coverageFrom = heartbeat ?? now

        let power = PowerMonitor { [weak self] event in self?.handlePower(event) }
        if !power.start() { log.error("sleep/wake notifications unavailable; asleep time will not be recorded") }
        self.power = power

        pipeline.discard()
        _ = readSelfUsage()
        lastSample = clock.now

        // The sources hold the recorder strongly and the recorder holds them: nothing else owns it, and it
        // lives as long as the process.
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler { MainActor.assumeIsolated { self.stop() } }
        terminate.resume()
        self.terminate = terminate

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.interval, repeating: Self.interval, leeway: .seconds(1))
        timer.setEventHandler { MainActor.assumeIsolated { self.tick() } }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        let instant = clock.now
        let elapsed = Self.seconds(lastSample.duration(to: instant))
        lastSample = instant
        tickCount += 1

        let level = ThermalLevel.current()
        if level != thermal {
            thermal = level
            store.recordEvent(kind: "thermal", ts: now, payload: ["level": String(level.rawValue)])
        }

        let resumed = sleep.onTick()
        if resumed {
            log.warning("wake notification missed; resuming")
            store.recordEvent(kind: "wake", ts: now, payload: [:])
        }

        // A tick between the real sleep and the wake notification only moves the baselines, so neither the
        // samples nor agent activity count the sleep. A nil tick still advanced every counter.
        var sampled: Tick?
        if sleep.isAsleep || resumed {
            pipeline.discard()
            lastSample = clock.now
        } else {
            sampled = pipeline.sample(
                now: now, interval: elapsed, refreshSpace: tickCount % Self.spaceRefreshEvery == 0, thermal: level)
        }
        let usage = readSelfUsage()
        if var tick = sampled {
            tick.selfCPU = usage.cpu
            tick.selfFootprint = usage.footprint
            store.append(tick)
            writeLiveState(tick)
        }

        if tickCount % Self.flushEvery == 0 { flushCycle(now: now) }
        if tickCount % Self.scanEvery == 0 { scanDiagnostics(now: now) }
    }

    private func handlePower(_ event: PowerEvent) {
        switch event {
        case .willSleep(let ts):
            sleep.onWillSleep()
            store.recordEvent(kind: "sleep", ts: ts, payload: [:])
            flushCycle(now: ts)
        case .didWake(let ts):
            sleep.onDidWake()
            store.recordEvent(kind: "wake", ts: ts, payload: [:])
            pipeline.discard()
            lastSample = clock.now
        }
    }

    private func stop() {
        let now = Date().timeIntervalSince1970
        store.recordEvent(kind: "recorder_stop", ts: now, payload: [:])
        // If this final flush fails, the spool records it drained are lost; accepted, as the spool is best effort.
        flushCycle(now: now)
        exit(0)
    }

    /// The spool is ingested and flushed in the same cycle: drain deletes what it read, so the records are
    /// safe only once the flush has committed them.
    private func flushCycle(now: Double) {
        let drained = spool.drain()
        if drained.malformed > 0 { log.warning("skipped \(drained.malformed) malformed spool lines") }
        store.ingest(drained.records)
        do {
            try store.flush()
        } catch {
            log.error("flush failed: \(String(describing: error), privacy: .public)")
            return
        }
        refreshCoverage(now: now)
        rollUp(now: now)
    }

    private func refreshCoverage(now: Double) {
        do {
            for day in LocalDay.span(from: coverageFrom, through: now, limit: Self.maxCoverageDays) {
                try store.refreshCoverage(day: day.name, dayStart: day.start, dayEnd: day.end, now: now)
            }
            coverageFrom = now
        } catch {
            log.error("coverage refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Rolls up each hour completed since the last one rolled, after the flush that wrote its last ticks.
    private func rollUp(now: Double) {
        let currentHour = Int64((now / Double(Self.hour)).rounded(.down)) * Self.hour
        guard let last = lastRolledHour else {
            // First run: no earlier hour holds samples, and the current one is rolled when it completes.
            recordRolledHour(currentHour)
            return
        }
        guard currentHour > last else { return }
        var hour = max(last + Self.hour, currentHour - (Self.maxCatchUpHours - 1) * Self.hour)
        while hour <= currentHour {
            do {
                try store.rollupHour(endingAt: hour)
            } catch {
                log.error("hourly rollup failed: \(String(describing: error), privacy: .public)")
                return
            }
            recordRolledHour(hour)
            hour += Self.hour
        }
        do {
            try store.applyRetention(now: now)
        } catch {
            log.error("retention failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func recordRolledHour(_ hour: Int64) {
        lastRolledHour = hour
        do {
            try setMeta("last_rollup_hour", String(hour))
        } catch {
            log.error("saving rollup progress failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func scanDiagnostics(now: Double) {
        for report in scanner.scan(since: nextScanSince) {
            let event = DiagnosticScanner.event(for: report)
            store.recordEvent(kind: event.kind, ts: event.ts, payload: event.payload)
        }
        nextScanSince = Date(timeIntervalSince1970: now - Self.scanOverlap)
    }

    private func writeLiveState(_ tick: Tick) {
        let snapshot = LiveSnapshot(
            timestamp: tick.ts, cpuBusy: Float(1 - tick.cpu.idle),
            memUsed: tick.memory.used, memTotal: tick.memory.total, swapUsed: tick.memory.swapUsed,
            diskFree: tick.disk.free, diskCapacity: tick.disk.capacity,
            pressure: UInt8(tick.memory.pressure.rawValue), thermal: UInt8(tick.thermal.rawValue),
            limitFlags: tick.flags.rawValue,
            activeAgents: UInt16(clamping: tick.agents.activeCount), idleAgents: UInt16(clamping: tick.agents.idleCount))
        guard !liveState.write(snapshot), tick.ts - lastLiveWarning >= Double(Self.hour) else { return }
        lastLiveWarning = tick.ts
        log.error("live state write failed")
    }

    /// The recorder's own CPU since the previous call, in seconds, and its current footprint.
    private func readSelfUsage() -> (cpu: Double, footprint: UInt64) {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0 else { return (0, 0) }
        let total = ProcessSampler.cpuSeconds(
            userNs: info.ri_user_time, systemNs: info.ri_system_time, timebase: timebase)
        let delta = lastSelfCPU.map { max(0, total - $0) } ?? 0
        lastSelfCPU = total
        return (delta, info.ri_phys_footprint)
    }

    private func metaValue(_ key: String) throws -> String? {
        readMeta.reset()
        defer { readMeta.reset() }
        readMeta.bind(1, key)
        return try readMeta.step() ? readMeta.string(0) : nil
    }

    private func setMeta(_ key: String, _ value: String) throws {
        writeMeta.reset()
        defer { writeMeta.reset() }
        writeMeta.bind(1, key)
        writeMeta.bind(2, value)
        _ = try writeMeta.step()
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

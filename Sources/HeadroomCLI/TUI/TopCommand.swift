import Darwin
import Foundation
import HeadroomCore

/// Live samples come from the same pipeline the recorder runs, in this process; today's totals and coverage
/// are read from the recorder's database every 30 s. A missing or unreadable database leaves the live view
/// intact and shows "not recording".
@MainActor
final class TopSession {
    private static let historyLength = 60
    private static let dbRefreshInterval = 30.0
    private static let heartbeatFreshness = 90.0
    private static let spaceRefreshEvery = 60
    private static let growthWindowDays = 14

    private struct Stored {
        var today: [LimitKind: Double] = [:]
        var recordingDays = 0
        var gapCount = 0
        var recorderRunning = false
        var diskGrowthPerDay: Double?
    }

    private let paths: Paths
    private let machine = MachineInfo.current()
    private var pipeline: SamplingPipeline
    private var history: [Double] = []
    private var latest: Tick?
    private var stored = Stored()
    private var lastDBRead = -Double.infinity
    private var ticks = 0
    var showProcesses = false
    var showAgents = true

    init(paths: Paths) {
        self.paths = paths
        let (config, _) =
            FileManager.default.fileExists(atPath: paths.config.path)
            ? HeadroomConfig.load(from: paths.config) : (HeadroomConfig(), nil)
        let rules = GroupRules.effective(from: paths.groups).0
        pipeline = SamplingPipeline(
            classifier: Classifier(rules: rules, currentUID: getuid()), config: config, interval: 1)
    }

    func advance(now: Date) {
        let ts = now.timeIntervalSince1970
        if let tick = pipeline.sample(
            now: ts, interval: 1, refreshSpace: ticks % Self.spaceRefreshEvery == 0, thermal: .current()
        ).tick {
            latest = tick
            history.append(tick.cpu.user + tick.cpu.system)
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        }
        ticks += 1
        if ts - lastDBRead >= Self.dbRefreshInterval {
            lastDBRead = ts
            stored = readStored(now: now)
        }
    }

    func state() -> TopState? {
        guard let tick = latest else { return nil }
        let memoryByName = Dictionary(tick.topByMemory.map { ($0.name, $0.value) }, uniquingKeysWith: max)
        return TopState(
            machine: machine, cpu: tick.cpu, cpuHistory: history, memory: tick.memory, disk: tick.disk,
            diskGrowthPerDay: stored.diskGrowthPerDay,
            groups: tick.groups.map { ($0.key, $0.value) },
            topProcs: tick.topByCPU.map { ($0.name, $0.value, TopRenderer.clampedUInt64(memoryByName[$0.name] ?? 0)) },
            // The tracker dates a run from when this process first saw it; the process's own start time is the real age.
            agents: tick.agents.live.map { run in
                var shown = run
                shown.started = Self.startedSeconds(microseconds: run.root.start)
                return (run: shown, directory: Self.workingDirectoryName(pid: run.root.pid))
            },
            today: stored.today, recordingDays: stored.recordingDays, gapCount: stored.gapCount,
            recorderRunning: stored.recorderRunning, showProcesses: showProcesses, showAgents: showAgents,
            now: tick.ts)
    }

    nonisolated static func startedSeconds(microseconds: UInt64) -> Double { Double(microseconds) / 1_000_000 }

    private func readStored(now: Date) -> Stored {
        guard FileManager.default.fileExists(atPath: paths.database.path),
            let db = try? Database(path: paths.database.path, readOnly: true)
        else { return Stored() }
        let queries = Queries(db: db)
        do {
            let known = try queries.machines().map(\.machineId)
            let id = known.contains(machine.machineId) ? machine.machineId : known.first ?? machine.machineId
            var result = Stored()
            result.recorderRunning = try queries.heartbeat().map { now.timeIntervalSince1970 - $0 < Self.heartbeatFreshness } == true
            result.today = try queries.todayLimitSeconds(machineId: id, now: now)
            let days = try queries.coverage(
                machineId: id, from: Date(timeIntervalSince1970: 0), to: now.addingTimeInterval(86_400))
            result.recordingDays = days.filter { $0.recorded > 0 }.count
            result.gapCount = days.reduce(0) { $0 + $1.gaps.count }
            let free = try queries.dailyMetric(
                machineId: id, metric: .diskFree,
                from: now.addingTimeInterval(-Double(Self.growthWindowDays) * 86_400), to: now.addingTimeInterval(1))
            result.diskGrowthPerDay = Self.growth(free)
            return result
        } catch {
            return Stored()
        }
    }

    /// Free space falling is growth, so the sign flips; nil until two distinct days exist.
    private static func growth(_ free: [DailyStat]) -> Double? {
        guard let first = free.first, let last = free.last, let start = date(first.day), let end = date(last.day) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
        return days > 0 ? (first.avg - last.avg) / Double(days) : nil
    }

    private static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Display only: the basename of the process's working directory, never stored or logged.
    private static func workingDirectoryName(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || path.isEmpty ? nil : name
    }
}

enum TopCommand {
    private static let pipeWidth = 100
    private static let pipeHeight = 60

    private enum Outcome: Sendable {
        case frame(String)
        case failed(String)
    }

    static func run(paths: Paths, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        // The session's closures are @MainActor-bound, so the sinks stay out here and only values cross.
        let outcome = MainActor.assumeIsolated { isatty(STDOUT_FILENO) == 1 ? interactive(paths: paths) : oneFrame(paths: paths) }
        switch outcome {
        case let .frame(text):
            out(text)
            return 0
        case let .failed(message):
            err(message)
            return 1
        }
    }

    /// Piped output gets a single frame, which also makes the dashboard easy to check without a terminal.
    @MainActor
    private static func oneFrame(paths: Paths) -> Outcome {
        let session = TopSession(paths: paths)
        session.advance(now: Date())
        // CPU is a delta, so the first sample has none; a second one a second later does.
        Thread.sleep(forTimeInterval: 1)
        session.advance(now: Date())
        guard let state = session.state() else { return .failed("headroom: could not read system statistics") }
        return .frame(TopRenderer.render(state, width: pipeWidth, height: pipeHeight).joined(separator: "\n"))
    }

    @MainActor
    private static func interactive(paths: Paths) -> Outcome {
        let terminal: Terminal
        do {
            terminal = try Terminal()
        } catch {
            return .failed("headroom: top needs an interactive terminal")
        }
        let session = TopSession(paths: paths)
        session.advance(now: Date())

        func draw() {
            let (width, height) = terminal.size()
            let lines = session.state().map { TopRenderer.render($0, width: width, height: height) } ?? [" headroom: sampling…"]
            terminal.draw(lines)
        }
        func finish(_ code: Int32) {
            terminal.restore()
            exit(code)
        }

        var sources: [any DispatchSourceProtocol] = []
        // A runtime trap can still leave the terminal raw (restoring from a fatal-signal handler would need global
        // termios storage); `render` is kept trap-free instead, and `reset` recovers in the rare case.
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { finish(0) } }
            sources.append(source)
        }
        signal(SIGWINCH, SIG_IGN)
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        resize.setEventHandler { MainActor.assumeIsolated { draw() } }
        sources.append(resize)

        let keys = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        keys.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            // EOF means the terminal went away; looping on a readable-forever fd would spin.
            if count <= 0 {
                MainActor.assumeIsolated { finish(0) }
                return
            }
            for byte in buffer.prefix(count) {
                MainActor.assumeIsolated {
                    switch byte {
                    case UInt8(ascii: "q"), 3: finish(0)
                    case UInt8(ascii: "g"): session.showProcesses.toggle()
                    case UInt8(ascii: "a"): session.showAgents.toggle()
                    default: break
                    }
                }
            }
            MainActor.assumeIsolated { draw() }
        }
        sources.append(keys)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        timer.setEventHandler {
            MainActor.assumeIsolated {
                session.advance(now: Date())
                draw()
            }
        }
        sources.append(timer)

        draw()
        for source in sources { source.resume() }
        withExtendedLifetime(sources) { dispatchMain() }
    }
}

import Foundation

public struct ComparisonRow: Sendable, Equatable {
    public var label: String
    public var thisMachine: String
    public var reference: String
    public var previousMachine: String?
}

public struct Appendix: Sendable {
    public var groups: [(ReportGroup, cpuHours: Double, peakMemoryGB: Double)]
    public var agentRunCount: Int
    public var agentCPUHours: Double
    /// Days with recorded drive writes. The yearly projection needs `minProjectionDays` of them: one busy partial
    /// day projected over a year would be wildly wrong.
    public var ssdDays: Int
    public var ssdWriteGBPerDay: Double
    public var ssdWriteTBPerYear: Double
    public var events: [String: Int]
    public var thresholds: [String]
    public var workdayDefinition: String
    public var recorderAvgCPUPercent: Double
    public var recorderMaxFootprintMB: Double
    public var notes: [String]

    public static let minProjectionDays = 7
}

/// Everything the PDF shows, worked out from the database so the renderer only lays it out. Only workload
/// groups reach the model: process names, commands and event payloads are never read.
public struct ReportModel: Sendable {
    public var title: String
    public var coverage: String
    /// Empty when the range has no workday, and page 1 says there isn't enough data instead.
    public var verdicts: [Verdict]
    public var capacitySentence: String
    public var spec: SpecRecommendation
    /// Every local day in the range, oldest first, so a day without data is a gap on the charts.
    public var days: [String]
    public var dayLabels: [String]
    public var range: DateInterval
    public var dailyMemory: [DailyStat]
    /// Cores busy, so it shares a scale with the core count it's drawn against.
    public var dailyCPU: [DailyStat]
    public var dailyDiskUsed: [DailyStat]
    public var limits: (memoryBytes: Double, cores: Double, diskBytes: Double)
    public var tags: [(Date, String)]
    public var capacityBars: [(Int, Double)]
    public var capacityThreshold: Double
    public var comparisonHeader: ComparisonRow?
    public var comparison: [ComparisonRow]?
    public var appendix: Appendix
    public var footer: String

    private static let gib = 1_073_741_824.0
    private static let mib = 1_048_576.0
    private static let rawRetention = 30.0 * 86_400
    private static let unknown = "—"

    public static func build(
        queries: Queries, machineId: String, from: Date, to: Date, config: HeadroomConfig, tiers: Tiers,
        baseline: Baseline?, calendar: Calendar, now: Date = Date(), currentMachine: MachineInfo? = nil
    ) throws(DatabaseError) -> ReportModel {
        let machines = try queries.machines()
        let machine = machines.first { $0.machineId == machineId }
        let span = LocalDay.span(
            from: from.timeIntervalSince1970, through: to.timeIntervalSince1970 - 1, limit: .max, calendar: calendar)
        let this = try Figures(
            queries: queries, machineId: machineId, machine: machine, span: span, from: from, to: to, config: config,
            calendar: calendar)

        // Measured once: the storage verdict and the storage recommendation must agree on whether there's a trend.
        let growth = Verdicts.storageGrowthBytesPerDay(this.dailyFree)
        let verdicts =
            this.workdays.isEmpty
            ? []
            : [
                Verdicts.memory(
                    limitedByDay: this.limitedByDay(.memoryLimited), workdays: this.workdays,
                    minSeconds: Double(config.limits.memoryLimitedDayMinSeconds)),
                Verdicts.cpu(saturatedByDay: this.limitedByDay(.cpuSaturated), workdays: this.workdays),
                Verdicts.storage(
                    capacity: this.capacity, dailyFree: this.dailyFree, growthBytesPerDay: growth, now: now,
                    calendar: calendar),
            ]
        let spec = SpecRecommender.recommend(
            dailyPeakMemoryBytes: this.memory.map(\.max), medianSaturatedSeconds: this.medianSaturatedSeconds,
            currentCores: this.cores, currentMemoryGB: machine.map { Int((Double($0.ramBytes) / gib).rounded()) },
            usedBytes: this.usedBytes ?? 0, growthBytesPerDay: growth, tiers: tiers)

        let name =
            if let currentMachine, currentMachine.machineId == machineId, !currentMachine.chip.isEmpty {
                currentMachine.chip
            } else {
                machine?.model ?? "unknown machine"
            }
        let cores = Double(this.cores)
        let capacity = Double(this.capacity)

        var previous: Figures?
        for m in machines.reversed() where m.machineId != machineId {
            let f = try Figures(
                queries: queries, machineId: m.machineId, machine: m, span: span, from: from, to: to, config: config,
                calendar: calendar)
            if f.coverage.contains(where: { $0.recorded > 0 }) {
                previous = f
                break
            }
        }
        let hasComparison = baseline != nil || previous != nil

        return ReportModel(
            // Non-breaking spaces keep the date range on one line when the title wraps.
            title:
                "Hardware capacity report: \(name), "
                + rangeText(from: from, to: to, calendar: calendar).replacingOccurrences(of: " ", with: "\u{00A0}"),
            coverage: Verdicts.coverage(this.coverage),
            verdicts: verdicts,
            capacitySentence: AgentCapacity.sentence(this.agentCapacity(config)),
            spec: spec,
            days: span.map(\.name),
            dayLabels: span.map { format("MMM d", Date(timeIntervalSince1970: $0.start), calendar) },
            range: DateInterval(start: from, end: max(from, to)),
            dailyMemory: this.memory,
            dailyCPU: this.cpu.map { DailyStat(day: $0.day, avg: $0.avg * cores, max: $0.max * cores, p95: $0.p95 * cores) },
            dailyDiskUsed: capacity > 0
                ? this.free.map {
                    // Rollups keep no daily minimum of free space, so used space is drawn from the day's average.
                    let used = max(capacity - $0.avg, 0)
                    return DailyStat(day: $0.day, avg: used, max: used, p95: used)
                } : [],
            limits: (memoryBytes: Double(machine?.ramBytes ?? 0), cores: cores, diskBytes: capacity),
            tags: try queries.tags(machineId: machineId, from: from, to: to),
            capacityBars: capacityBars(this, config),
            capacityThreshold: config.capacityMaxLimitedShare,
            comparisonHeader: hasComparison
                ? ComparisonRow(
                    label: "", thisMachine: "This machine", reference: baseline?.label ?? "No reference",
                    previousMachine: previous?.machine?.model) : nil,
            comparison: hasComparison ? comparisonRows(this, baseline, previous, config) : nil,
            appendix: try appendix(
                queries: queries, machineId: machineId, figures: this, from: from, to: to, now: now, config: config),
            footer: "Generated by headroom \(HeadroomVersion.current) · \(format("MMM d, yyyy", now, calendar))")
    }

    /// "Nov 14 – Dec 13, 2026"; `to` is exclusive, so the last day shown is the one before it.
    static func rangeText(from: Date, to: Date, calendar: Calendar) -> String {
        let last = max(from, to.addingTimeInterval(-1))
        let full = format("MMM d, yyyy", last, calendar)
        guard !calendar.isDate(from, inSameDayAs: last) else { return full }
        let sameYear = calendar.component(.year, from: from) == calendar.component(.year, from: last)
        return "\(format(sameYear ? "MMM d" : "MMM d, yyyy", from, calendar)) – \(full)"
    }

    private static func format(_ pattern: String, _ date: Date, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }

    /// "1 hour", "2 hours", "15 minutes".
    private static func quantity(_ value: Double, _ noun: String) -> String {
        "\(Wording.trimmed(value)) \(noun)\(value == 1 ? "" : "s")"
    }

    /// Only levels the capacity walk would judge are drawn, and none at all when there isn't enough agent data:
    /// a bar from a few minutes of samples would contradict "not enough data".
    private static func capacityBars(_ f: Figures, _ config: HeadroomConfig) -> [(Int, Double)] {
        if case .insufficientData = f.agentCapacity(config) { return [] }
        return f.histogram.filter { $0.key >= 1 && $0.value.seconds >= Double(config.capacityMinSecondsPerLevel) }
            .sorted { $0.key < $1.key }
            .map { ($0.key, max($0.value.memoryLimited, $0.value.cpuSaturated) / $0.value.seconds) }
    }

    private static func comparisonRows(
        _ this: Figures, _ baseline: Baseline?, _ previous: Figures?, _ config: HeadroomConfig
    ) -> [ComparisonRow] {
        func gb(_ value: Double?, places: Int) -> String {
            value.map { "\(places == 0 ? Wording.trimmed($0) : Wording.decimal($0, places: places)) GB" } ?? unknown
        }
        func row(_ label: String, _ ref: String, _ value: (Figures) -> String) -> ComparisonRow {
            ComparisonRow(label: label, thisMachine: value(this), reference: ref, previousMachine: previous.map(value))
        }
        return [
            row("Cores", baseline.map { "\($0.cores)" } ?? unknown) { "\($0.cores)" },
            row("Memory", gb(baseline?.memoryGB, places: 0)) { f in
                f.machine.map { "\(Int((Double($0.ramBytes) / gib).rounded())) GB" } ?? unknown
            },
            row("Peak memory demand", gb(baseline?.peakMemoryUsedGB, places: 1)) { f in
                gb(SpecRecommender.typicalHeavyDay(f.memory.map(\.max)).map { $0 / gib }, places: 1)
            },
            row("Busiest-hour CPU, median day", baseline?.cpuP95.map(Wording.percent) ?? unknown) { f in
                f.cpu.isEmpty ? unknown : Wording.percent(Verdicts.median(f.cpu.map(\.p95)))
            },
            row("Disk used", baseline?.diskUsedGB.map { "\(Wording.decimal($0, places: 0)) GB" } ?? unknown) { f in
                f.usedBytes.map { "\(Wording.decimal(Double($0) / 1e9, places: 0)) GB" } ?? unknown
            },
            row("Agents at once", baseline?.concurrentAgents.map(String.init) ?? unknown) { f in
                switch f.agentCapacity(config) {
                case .insufficientData: unknown
                case .limitedAtOne: "0"
                case let .capacity(n, _): "\(n)"
                }
            },
        ]
    }

    private static func appendix(
        queries: Queries, machineId: String, figures: Figures, from: Date, to: Date, now: Date, config: HeadroomConfig
    ) throws(DatabaseError) -> Appendix {
        var folded: [ReportGroup: (cpu: Double, peak: Double)] = [:]
        for (group, totals) in try queries.groupTotals(machineId: machineId, from: from, to: to) {
            // Folded groups may not have peaked at the same moment, so adding their peaks gives an upper bound
            // rather than a figure that could understate the group.
            let current = folded[group.reportGroup] ?? (0, 0)
            folded[group.reportGroup] = (current.cpu + totals.cpuSeconds, current.peak + Double(totals.footprint))
        }
        let groups = ReportGroup.allCases.compactMap { g in
            folded[g].map { (g, cpuHours: $0.cpu / 3600, peakMemoryGB: $0.peak / gib) }
        }

        let written = Array(
            try queries.dailySSDWriteBytes(machineId: machineId, from: from, to: to, calendar: figures.calendar).values)
        let gbPerDay = written.isEmpty ? 0 : written.reduce(0, +) / Double(written.count) / 1e9

        let agents = try queries.agentRunTotals(machineId: machineId, from: from, to: to)
        let usage = try queries.selfUsage(machineId: machineId, from: from, to: to)
        let limits = config.limits

        var notes = [
            "Agent capacity is measured while that many agents were active; it is a correlation, not proof that agents caused all of the load.",
            "Work inside containers is counted under Containers & Kind, not under the agent that started it.",
        ]
        if from < now.addingTimeInterval(-rawRetention) {
            notes.append(
                "Workload figures and the recorder's own use cover at most the last 30 days, because detailed samples are kept for 30 days.")
        }

        return Appendix(
            groups: groups, agentRunCount: agents.runs, agentCPUHours: agents.cpuSeconds / 3600,
            ssdDays: written.count, ssdWriteGBPerDay: gbPerDay, ssdWriteTBPerYear: gbPerDay * 365 / 1000,
            events: try queries.eventCounts(machineId: machineId, from: from, to: to),
            thresholds: [
                "Memory ran out: memory pressure was at warning or critical, or memory was being swapped out to disk.",
                "A workday counts as running out of memory after \(quantity(Double(limits.memoryLimitedDayMinSeconds) / 60, "minute")) of that.",
                "Heavy swapping: swap above \(Wording.percent(limits.heavySwapFractionOfRAM)) of memory while swapping back in.",
                "Processor fully busy: total CPU at least \(Wording.percent(limits.cpuSaturatedFraction)), or load at least \(Wording.trimmed(limits.loadPerCoreMultiplier))× the core count.",
                "Thermal-limited: the system reported a serious or critical thermal state.",
                "Agent capacity: each level needs at least \(quantity(Double(config.capacityMinSecondsPerLevel) / 3600, "hour")) of samples and must be limited under \(Wording.percent(config.capacityMaxLimitedShare)) of the time.",
                "Memory is sized from the 95th percentile of daily peaks plus 25%; storage from used space plus a year of growth plus 20%.",
            ],
            workdayDefinition:
                "A workday is any day with at least \(quantity(Double(config.workdayMinAwakeSeconds) / 3600, "hour")) of awake time on the machine, judged from the machine's state, never from whether anyone was at the keyboard.",
            recorderAvgCPUPercent: usage.avgCPU * 100, recorderMaxFootprintMB: Double(usage.maxFootprint) / mib,
            notes: notes)
    }
}

/// One machine's daily series over the range, shared by the main report and the comparison column.
private struct Figures {
    let machine: MachineInfo?
    let calendar: Calendar
    let coverage: [DayCoverage]
    let workdays: [String]
    let limits: [String: [LimitKind: Double]]
    let memory: [DailyStat]
    let cpu: [DailyStat]
    let free: [DailyStat]
    let dailyFree: [(Date, UInt64)]
    let histogram: [Int: AgentLevelStats]

    init(
        queries: Queries, machineId: String, machine: MachineInfo?, span: [LocalDay], from: Date, to: Date,
        config: HeadroomConfig, calendar: Calendar
    ) throws(DatabaseError) {
        self.machine = machine
        self.calendar = calendar
        coverage = try queries.coverage(machineId: machineId, from: from, to: to, calendar: calendar)
        workdays = Workdays.workdays(coverage, minAwakeSeconds: Double(config.workdayMinAwakeSeconds))
        limits = try queries.limitSecondsByDay(machineId: machineId, from: from, to: to, calendar: calendar)
        memory = try queries.dailyMetric(machineId: machineId, metric: .memDemand, from: from, to: to, calendar: calendar)
        cpu = try queries.dailyMetric(machineId: machineId, metric: .cpuBusy, from: from, to: to, calendar: calendar)
        free = try queries.dailyMetric(machineId: machineId, metric: .diskFree, from: from, to: to, calendar: calendar)
        let starts = Dictionary(span.map { ($0.name, $0.start) }, uniquingKeysWith: { a, _ in a })
        dailyFree = free.compactMap { s in
            starts[s.day].map { (Date(timeIntervalSince1970: $0), Self.bytes(s.avg)) }
        }
        histogram = try queries.agentHistogram(machineId: machineId, from: from, to: to)
    }

    /// A corrupt or non-finite average reads as nothing free rather than trapping the conversion.
    private static func bytes(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= 1.8e19 ? .max : UInt64(value.rounded())
    }

    var cores: Int { (machine?.perfCores ?? 0) + (machine?.effCores ?? 0) }
    var capacity: UInt64 { machine?.diskBytes ?? 0 }

    var usedBytes: UInt64? {
        guard capacity > 0, let latest = dailyFree.max(by: { $0.0 < $1.0 }) else { return nil }
        return capacity - min(latest.1, capacity)
    }

    /// The same median over every workday that the processor verdict reports.
    var medianSaturatedSeconds: Double { Verdicts.median(workdays.map { limits[$0]?[.cpuSaturated] ?? 0 }) }

    func limitedByDay(_ kind: LimitKind) -> [String: Double] { limits.compactMapValues { $0[kind] } }

    func agentCapacity(_ config: HeadroomConfig) -> AgentCapacityResult { AgentCapacity.compute(histogram, config: config) }
}

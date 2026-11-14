import Foundation
import PDFKit
import Testing

@testable import HeadroomCore

private let gib = 1_073_741_824.0

private func utc() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return c
}

// 2026-11-14 00:00 UTC; the fixture covers 30 days from here.
private let rangeStart: Int64 = 1_794_614_400
private let rangeEnd = rangeStart + 30 * 86_400
private let now = Date(timeIntervalSince1970: Double(rangeEnd) - 3600)

private func dayName(_ d: Int) -> String { LocalDay(containing: Double(rangeStart + Int64(d) * 86_400), calendar: utc()).name }

private func at(_ d: Int, _ hour: Int) -> Int64 { rangeStart + Int64(d) * 86_400 + Int64(hour) * 3600 }

private let thisMachine = MachineInfo(
    model: "Mac15,6", chip: "Apple M3 Pro", serialHash: "a", perfCores: 6, effCores: 6, ramBytes: 18 * 1_073_741_824,
    diskBytes: 512_000_000_000)
private let oldMachine = MachineInfo(
    model: "MacBookPro18,1", chip: "", serialHash: "b", perfCores: 8, effCores: 2, ramBytes: 16 * 1_073_741_824,
    diskBytes: 1_000_000_000_000)

private let baseline = Baseline(
    label: "Reference workstation", cores: 16, memoryGB: 64, cpuP95: 0.6, peakMemoryUsedGB: 40, diskUsedGB: 700,
    concurrentAgents: 4, source: "made up")

private final class ReportFixture {
    let dir: URL
    let paths: Paths
    let db: Database

    init(days: Int = 30, secondMachine: Bool = true) throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "headroom-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths = Paths(root: dir)
        db = try Database(path: paths.database.path, readOnly: false)
        try Schema.migrate(db)
        try thisMachine.register(in: db, now: now)
        try seedMachine(thisMachine.machineId, days: days)
        if secondMachine {
            try oldMachine.register(in: db, now: Date(timeIntervalSince1970: Double(rangeStart)))
            try seedMachine(oldMachine.machineId, days: 5)
        }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func insert(_ sql: String, _ values: [Any]) throws {
        let s = try db.prepare(sql)
        for (i, v) in values.enumerated() {
            let index = Int32(i + 1)
            switch v {
            case let v as String: s.bind(index, v)
            case let v as Int64: s.bind(index, v)
            case let v as Int: s.bind(index, Int64(v))
            case let v as Double: s.bind(index, v)
            default: Issue.record("unsupported binding \(v)")
            }
        }
        _ = try s.step()
    }

    private func seedMachine(_ id: String, days: Int) throws {
        for d in 0..<days {
            try insert("INSERT INTO coverage VALUES(?,?,?,?,?,?)", [id, dayName(d), 28_800.0, 57_600.0, 0.0, "[]"])
            for hour in 9..<17 {
                let ts = at(d, hour)
                let rollup = "INSERT INTO rollup VALUES(?,3600,?,?,?,?,?)"
                try insert(rollup, [id, ts, Metric.memDemand.rawValue, 20 * gib, 28 * gib, 26 * gib])
                try insert(rollup, [id, ts, Metric.cpuBusy.rawValue, 0.3, 0.95, 0.8])
                try insert(rollup, [id, ts, Metric.diskFree.rawValue, 200e9 - Double(d) * 1e9, 200e9, 200e9])
            }
            try insert("INSERT INTO limit_seconds VALUES(?,3600,?,?,?)", [id, at(d, 10), "memoryLimited", 1800.0])
            try insert("INSERT INTO limit_seconds VALUES(?,3600,?,?,?)", [id, at(d, 11), "cpuSaturated", 2400.0])
            for (group, cpu) in [("browsers", 600.0), ("communication", 300.0), ("other", 100.0), ("containers", 900.0)] {
                try insert("INSERT INTO group_samples VALUES(?,?,?,?,?,?,?)", [id, at(d, 12), group, cpu, 2_000_000_000, 0, 3])
            }
            for (rank, name) in ["Slack", "Google Chrome", "secret-repo"].enumerated() {
                try insert(
                    "INSERT INTO top_procs_1m VALUES(?,?,?,?,?,?,?)", [id, at(d, 12), "cpu", rank, name, "other", 1.0])
            }
            try insert("INSERT INTO events VALUES(?,?,?,?)", [id, at(d, 13), "command", #"{"exe":"secret-repo","seconds":40}"#])
            // 38 GB a day from two ticks of unequal size, so an average of averages would come out wrong.
            let sample = "INSERT INTO samples(machine_id, ts, self_cpu, self_footprint, ssd_write) VALUES(?,?,?,?,?)"
            try insert(sample, [id, at(d, 9), 0.005, 9_437_184, 30_000_000_000])
            try insert(sample, [id, at(d, 9) + 10, 0.005, 9_437_184, 8_000_000_000])
        }
        try insert("INSERT INTO events VALUES(?,?,?,?)", [id, at(2, 14), "tag", #"{"text":"load test"}"#])
        for kind in ["thermal", "jetsam", "hang", "hang"] {
            try insert("INSERT INTO events VALUES(?,?,?,?)", [id, at(3, 14), kind, #"{"file":"/Users/x/secret-repo/hang.ips"}"#])
        }
        try insert("INSERT INTO agent_histogram VALUES(?,?,?,?,?,?)", [id, at(1, 9), 1, 10_800.0, 0.0, 0.0])
        try insert("INSERT INTO agent_histogram VALUES(?,?,?,?,?,?)", [id, at(1, 9), 2, 10_800.0, 2160.0, 0.0])
        try insert(
            "INSERT INTO agent_runs(machine_id, tool, root_pid, root_start, started) VALUES(?,?,?,?,?)",
            [id, "claude", 42, 1, at(1, 9)])
        try insert("INSERT INTO run_usage VALUES((SELECT MAX(run_id) FROM agent_runs),?,?,?,?,?)", [at(1, 9), 3600.0, 0, 0, 0.0])
        try insert(
            "INSERT INTO agent_run_sessions VALUES((SELECT MAX(run_id) FROM agent_runs),?,?,?)",
            ["sess-SECRET-123", "model-SECRET", at(1, 9)])
    }

    func exec(_ sql: String) throws { try db.exec(sql) }

    func model(
        baseline: Baseline?, from: Int64 = rangeStart, to: Int64 = rangeEnd, config: HeadroomConfig = HeadroomConfig()
    ) throws -> ReportModel {
        try ReportModel.build(
            queries: Queries(db: db), machineId: thisMachine.machineId, from: Date(timeIntervalSince1970: Double(from)),
            to: Date(timeIntervalSince1970: Double(to)), config: config, tiers: .defaults, baseline: baseline,
            calendar: utc(), now: now, currentMachine: thisMachine)
    }

    func render(_ m: ReportModel) throws -> PDFDocument {
        let url = dir.appending(path: "report-\(UUID().uuidString).pdf")
        try PDFReport.render(m, to: url)
        return try #require(PDFDocument(url: url))
    }
}

/// PDFKit breaks wrapped lines with newlines, so sentences are compared with whitespace collapsed.
private func text(_ page: PDFPage?) -> String {
    (page?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func fullText(_ doc: PDFDocument) -> String {
    (0..<doc.pageCount).map { text(doc.page(at: $0)) }.joined(separator: " ")
}

@Suite struct ReportTests {
    @Test func titleAndPageCount() throws {
        let f = try ReportFixture()
        let m = try f.model(baseline: baseline)
        let doc = try f.render(m)

        #expect(doc.pageCount == 4)
        let first = text(doc.page(at: 0))
        #expect(first.contains("Hardware capacity report: Apple M3 Pro, Nov 14 – Dec 13, 2026"))
        #expect(first.contains(m.coverage))
        #expect(m.coverage == "Recorded continuously for 30 days (100% of awake time).")
        #expect(first.contains("Recommended:"))
        #expect(first.contains("Memory ran out on 30 of 30 workdays"))
        #expect(text(doc.page(at: 2)).contains("Reference workstation"))
        #expect(text(doc.page(at: 2)).contains("MacBookPro18,1"))
        #expect(first.contains("Page 1 of 4"))
        #expect(first.contains("Generated by headroom \(HeadroomVersion.current) · Dec 13, 2026"))
    }

    @Test func noComparisonPage() throws {
        let f = try ReportFixture(secondMachine: false)
        let m = try f.model(baseline: nil)
        #expect(m.comparison == nil)
        #expect(try f.render(m).pageCount == 3)
    }

    @Test func comparisonRows() throws {
        let f = try ReportFixture()
        let rows = try #require(try f.model(baseline: baseline).comparison)
        #expect(rows.map(\.label) == ["Cores", "Memory", "Peak memory demand", "Busiest-hour CPU, median day", "Disk used", "Agents at once"])
        #expect(rows[0].thisMachine == "12")
        #expect(rows[0].reference == "16")
        #expect(rows[0].previousMachine == "10")
        #expect(rows[5].thisMachine == "1")
        #expect(rows[5].reference == "4")

        let onlyOld = try #require(try f.model(baseline: nil).comparison)
        #expect(onlyOld.allSatisfy { $0.reference == "—" })
    }

    @Test func privacyNoProcessNames() throws {
        let f = try ReportFixture()
        let all = fullText(try f.render(try f.model(baseline: baseline)))
        for name in [
            "Slack", "Google Chrome", "secret-repo", "hang.ips", "Browsers", "Communication", "sess-SECRET-123",
            "model-SECRET", "claude",
        ] {
            #expect(!all.contains(name), "\(name) leaked into the report")
        }
        #expect(all.contains("Everyday apps"))
    }

    @Test func groupsFoldIntoEverydayApps() throws {
        let f = try ReportFixture()
        let groups = try f.model(baseline: nil).appendix.groups
        let everyday = try #require(groups.first { $0.0 == .everydayApps })
        #expect(abs(everyday.cpuHours - 30 * 1000 / 3600) < 1e-9)
        #expect(groups.contains { $0.0 == .containers })
        #expect(groups.count == 2)
    }

    @Test func ssdProjection() throws {
        let f = try ReportFixture()
        let m = try f.model(baseline: nil)
        #expect(abs(m.appendix.ssdWriteGBPerDay - 38) < 1e-6)
        #expect(abs(m.appendix.ssdWriteTBPerYear - 13.87) < 1e-6)
        let doc = try f.render(m)
        #expect(text(doc.page(at: doc.pageCount - 1)).contains("At this rate the drive absorbs 13.9 TB of writes a year."))
    }

    @Test func ssdProjectionNeedsSevenDays() throws {
        let f = try ReportFixture(days: 6, secondMachine: false)
        let m = try f.model(baseline: nil)
        #expect(m.appendix.ssdDays == 6)
        let appendix = text(try f.render(m).page(at: 2))
        #expect(!appendix.contains("At this rate"))
        #expect(appendix.contains("Drive writes were recorded on 6 days; a yearly projection needs at least 7."))
    }

    @Test func agentRunsCountedWhileActive() throws {
        let f = try ReportFixture(secondMachine: false)
        let id = thisMachine.machineId
        // Started before the range and still running: counted. Ended before the range: not.
        try f.exec("INSERT INTO agent_runs(machine_id, tool, root_pid, root_start, started) VALUES('\(id)', 'codex', 7, 1, \(rangeStart - 86_400))")
        try f.exec(
            "INSERT INTO agent_runs(machine_id, tool, root_pid, root_start, started, ended) VALUES('\(id)', 'codex', 8, 1, \(rangeStart - 86_400), \(rangeStart - 60))")
        #expect(try f.model(baseline: nil).appendix.agentRunCount == 2)
    }

    @Test func thresholdsPluralize() throws {
        var config = HeadroomConfig()
        config.workdayMinAwakeSeconds = 3600
        config.limits.memoryLimitedDayMinSeconds = 60
        let a = try ReportFixture(days: 1, secondMachine: false).model(baseline: nil, config: config).appendix
        #expect(a.workdayDefinition.contains("at least 1 hour of awake time"))
        #expect(a.thresholds.contains { $0.contains("after 1 minute of that") })
        #expect(a.thresholds.contains { $0.contains("at least 1 hour of samples") })
        let defaults = try ReportFixture(days: 1, secondMachine: false).model(baseline: nil).appendix
        #expect(defaults.thresholds.contains { $0.contains("after 15 minutes of that") })
    }

    @Test func groupPeaksReadAsUpperBounds() throws {
        let f = try ReportFixture(secondMachine: false)
        let appendix = text(try f.render(try f.model(baseline: nil)).page(at: 2))
        #expect(appendix.contains("Everyday apps: 8.3 CPU hours, up to 5.6 GB of memory."))
    }

    @Test func appendixNotes() throws {
        let f = try ReportFixture()
        let m = try f.model(baseline: nil)
        let doc = try f.render(m)
        let appendix = text(doc.page(at: doc.pageCount - 1))
        #expect(appendix.contains(m.appendix.workdayDefinition))
        #expect(m.appendix.workdayDefinition.contains("at least 2 hours"))
        #expect(appendix.contains(
            "Agent capacity is measured while that many agents were active; it is a correlation, not proof that agents caused all of the load."))
        #expect(appendix.contains("Work inside containers is counted under Containers & Kind, not under the agent that started it."))
        #expect(appendix.contains("headroomd used 0.05% of one core and at most 9.0 MB of memory."))
        #expect(m.appendix.events["hang"] == 2)
        #expect(m.appendix.agentRunCount == 1)
        #expect(m.appendix.agentCPUHours == 1)
    }

    @Test func growthMeasuredOnceForVerdictAndSpec() throws {
        let f = try ReportFixture(days: 5, secondMachine: false)
        let m = try f.model(baseline: nil)
        let storage = try #require(m.verdicts.first { $0.resource == "storage" })
        #expect(storage.sentence.hasPrefix("Storage is "))
        #expect(!storage.sentence.contains("growing"))
        #expect(m.spec.reasons[2].contains("growth not yet measured"))

        let month = try ReportFixture(secondMachine: false).model(baseline: nil)
        let monthly = try #require(month.verdicts.first { $0.resource == "storage" })
        #expect(monthly.sentence.contains("growing 7 GB a week"))
        #expect(month.spec.reasons[2].contains("grows 1.0 GB a day"))
    }

    @Test func specInputs() throws {
        let m = try ReportFixture(secondMachine: false).model(baseline: nil)
        // 28 GiB peaks plus 25% is 35 GiB; 2,400 saturated seconds a day steps up from 12 cores.
        #expect(m.spec.memoryGB == 36)
        #expect(m.spec.cores == 14)
        #expect(m.spec.reasons[2].hasPrefix("Storage holds 341 GB"))
    }

    @Test func notEnoughDataStillRenders() throws {
        let f = try ReportFixture(secondMachine: false)
        let later = rangeEnd + 86_400 * 10
        let m = try f.model(baseline: nil, from: later, to: later + 86_400 * 3)
        #expect(m.verdicts.isEmpty)
        let doc = try f.render(m)
        #expect(doc.pageCount == 3)
        let first = text(doc.page(at: 0))
        #expect(first.contains("Not enough data in this range yet."))
        // No recommendation without evidence: the spec box would otherwise claim "8 cores are enough".
        #expect(!first.contains("Recommended:"))
        #expect(!first.contains("cores are enough"))
    }

    @Test func capacityBarsOnlyForJudgedLevels() throws {
        let f = try ReportFixture(secondMachine: false)
        try f.exec("INSERT INTO agent_histogram VALUES('\(thisMachine.machineId)', \(at(1, 9)), 3, 600, 600, 0)")
        #expect(try f.model(baseline: nil).capacityBars.map(\.0) == [1, 2])

        try f.exec("DELETE FROM agent_histogram WHERE active_agents=2")
        let thin = try f.model(baseline: nil)
        #expect(thin.capacitySentence == "Not enough AI agent activity recorded yet to measure agent capacity.")
        #expect(thin.capacityBars.isEmpty)
        let picture = text(try f.render(thin).page(at: 1))
        #expect(picture.contains("Not enough AI agent activity recorded yet."))
        #expect(!picture.contains("1 agent"))
    }

    @Test func axisSurvivesDegenerateMaximums() {
        for maximum in [Double.nan, .infinity, -.infinity, 0, -5, .leastNonzeroMagnitude, .greatestFiniteMagnitude] {
            let axis = Axis(maximum: maximum)
            #expect(axis.step > 0 && axis.step.isFinite)
            #expect(axis.top.isFinite)
            #expect(axis.ticks.count <= 12)
        }
    }

    @Test func chartsCarryGapsAndTags() throws {
        let m = try ReportFixture(days: 20, secondMachine: false).model(baseline: nil)
        #expect(m.days.count == 30)
        #expect(m.dailyMemory.count == 20)
        #expect(m.dailyCPU.first?.max == 0.95 * 12)
        #expect(m.limits.memoryBytes == 18 * gib)
        #expect(m.limits.cores == 12)
        #expect(m.tags.map(\.1) == ["load test"])
        #expect(m.capacityBars.map(\.0) == [1, 2])
        #expect(abs(m.capacityBars[1].1 - 0.2) < 1e-9)
    }
}

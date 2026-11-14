import Foundation
import Testing

@testable import HeadroomCore

private let gib = 1_073_741_824.0

private func utc() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return c
}

private func day(_ i: Int) -> String { String(format: "2026-10-%02d", i + 1) }

private func days(_ n: Int) -> [String] { (0..<n).map(day) }

// Whole limited seconds, so a share computed back from them is exactly the literal fraction.
private func stats(_ seconds: Double, memory: Double, cpu: Double = 0) -> AgentLevelStats {
    AgentLevelStats(
        seconds: seconds, memoryLimited: (seconds * memory).rounded(), cpuSaturated: (seconds * cpu).rounded())
}

private func tempFile(_ text: String?) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-a-\(UUID().uuidString).json")
    if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
    return url
}

private func recommend(
    peaks: [Double] = [30 * gib], medianSaturated: Double = 0, cores: Int = 8,
    used: UInt64 = 400_000_000_000, growthPerDay: Double = 1e9
) -> SpecRecommendation {
    SpecRecommender.recommend(
        dailyPeakMemoryBytes: peaks, medianSaturatedSeconds: medianSaturated, currentCores: cores,
        usedBytes: used, growthBytesPerDay: growthPerDay, tiers: .defaults)
}

@Suite struct AnalysisTests {
    // MARK: Workdays and coverage

    @Test func workdaysThreshold() {
        let coverage = [
            DayCoverage(day: "2026-11-02", recorded: 7000, asleep: 50_000, gap: 199, gaps: []),
            DayCoverage(day: "2026-11-03", recorded: 7000, asleep: 50_000, gap: 200, gaps: []),
        ]
        #expect(Workdays.workdays(coverage, minAwakeSeconds: 7200) == ["2026-11-03"])
    }

    @Test func dstDayCounts() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-a-\(UUID().uuidString).db").path
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let db = try Database(path: path, readOnly: false)
        try Schema.migrate(db)
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        // 2026-11-01 00:00 PDT; the clocks go back that morning, so the local day holds 25 hourly rows.
        let start: Int64 = 1_793_516_400
        for h in 0..<25 {
            let s = try db.prepare("INSERT INTO limit_seconds VALUES(?,?,?,?,?)")
            s.bind(1, "m1")
            s.bind(2, Int64(3600))
            s.bind(3, start + Int64(h) * 3600)
            s.bind(4, LimitKind.memoryLimited.rawValue)
            s.bind(5, 60.0)
            _ = try s.step()
        }
        let byDay = try Queries(db: db).limitSecondsByDay(
            machineId: "m1", from: Date(timeIntervalSince1970: Double(start)),
            to: Date(timeIntervalSince1970: Double(start + 25 * 3600)), calendar: la)

        #expect(Array(byDay.keys) == ["2026-11-01"])
        #expect(byDay["2026-11-01"]?[.memoryLimited] == 1500)
    }

    @Test func coverageSentence() {
        let c = (0..<41).map { DayCoverage(day: day($0 % 31), recorded: 35_856, asleep: 40_000, gap: 144, gaps: []) }
        #expect(Verdicts.coverage(c) == "Recorded continuously for 41 days (99.6% of awake time).")
    }

    @Test func coverageWithLargeGapsIsNotContinuous() {
        let c = (0..<3).map { DayCoverage(day: day($0), recorded: 8000, asleep: 0, gap: 2000, gaps: []) }
        #expect(Verdicts.coverage(c) == "Recorded for 3 days (80% of awake time).")
    }

    // MARK: Verdicts

    @Test func memoryVerdict() {
        let workdays = days(22)
        var limited: [String: Double] = ["2026-10-30": 80_000]
        for (i, d) in workdays.enumerated() { limited[d] = i < 18 ? 13_980 : 450 }

        let v = Verdicts.memory(limitedByDay: limited, workdays: workdays, minSeconds: 900)
        #expect(v.sentence == "Memory ran out on 18 of 22 workdays, an average of 3.2 hours a day.")
        #expect(v.isProblem)
        #expect(v.resource == "memory")

        let none = Verdicts.memory(limitedByDay: [:], workdays: workdays, minSeconds: 900)
        #expect(none.sentence == "Memory never ran out in 22 workdays.")
        #expect(!none.isProblem)
    }

    @Test func memoryVerdictCountsExactlyMinSeconds() {
        let v = Verdicts.memory(limitedByDay: [day(0): 900], workdays: days(2), minSeconds: 900)
        #expect(v.sentence == "Memory ran out on 1 of 2 workdays, an average of 0.1 hours a day.")
    }

    @Test func cpuVerdict() {
        let workdays = days(5)
        let busy: [String: Double] = [day(0): 7000, day(1): 5040, day(2): 6000, day(3): 100]
        let v = Verdicts.cpu(saturatedByDay: busy, workdays: workdays)
        #expect(v.sentence == "The processor was fully busy for 1.4 hours on a typical workday.")
        #expect(v.isProblem)

        let quiet = Verdicts.cpu(saturatedByDay: [day(0): 359, day(1): 359], workdays: days(3))
        #expect(quiet.sentence == "The processor was rarely fully busy.")
        #expect(!quiet.isProblem)
    }

    @Test func cpuVerdictProblemFromHalfHour() {
        let v = Verdicts.cpu(saturatedByDay: [day(0): 1800], workdays: days(1))
        #expect(v.isProblem)
        #expect(v.sentence == "The processor was fully busy for 0.5 hours on a typical workday.")
    }

    @Test func storageVerdict() {
        let cal = utc()
        let now = Date(timeIntervalSince1970: 1_794_614_400)  // 2026-11-14 00:00 UTC
        func weekly(_ lossPerWeek: UInt64) -> [(Date, UInt64)] {
            (0..<5).map { (w: Int) -> (Date, UInt64) in
                let weeksAgo = 4 - w
                let when = now.addingTimeInterval(-Double(weeksAgo) * 7 * 86_400)
                return (when, 92_160_000_000 + UInt64(weeksAgo) * lossPerWeek)
            }
        }

        let growing = Verdicts.storage(capacity: 512_000_000_000, dailyFree: weekly(6_000_000_000), now: now, calendar: cal)
        #expect(growing.sentence == "Storage is 82% full and growing 6 GB a week. It fills by March.")
        #expect(growing.isProblem)

        let slow = Verdicts.storage(capacity: 512_000_000_000, dailyFree: weekly(1_330_000_000), now: now, calendar: cal)
        #expect(slow.sentence == "Storage is 82% full and growing 1.3 GB a week. It fills by March 2028.")
        #expect(!slow.isProblem)

        let distant = Verdicts.storage(capacity: 512_000_000_000, dailyFree: weekly(100_000_000), now: now, calendar: cal)
        #expect(distant.sentence == "Storage is 82% full and growing 0.1 GB a week.")

        let flat = Verdicts.storage(capacity: 512_000_000_000, dailyFree: weekly(0), now: now, calendar: cal)
        #expect(flat.sentence == "Storage is 82% full and not growing.")
        #expect(!flat.isProblem)
    }

    @Test func storageNinetyPercentFullIsAProblem() {
        let now = Date(timeIntervalSince1970: 1_794_614_400)
        let v = Verdicts.storage(
            capacity: 1_000_000_000_000, dailyFree: [(now, 100_000_000_000)], now: now, calendar: utc())
        #expect(v.sentence == "Storage is 90% full and not growing.")
        #expect(v.isProblem)
    }

    // MARK: Agent capacity

    @Test func capacityStopsAtFirstFail() {
        let h = [1: stats(7200, memory: 0.01), 2: stats(10_800, memory: 0.06, cpu: 0.02), 3: stats(7200, memory: 0.04)]
        let r = AgentCapacity.compute(h, config: HeadroomConfig())
        #expect(r == .capacity(n: 1, next: (.memory, 0.06)))
    }

    @Test func capacityNamesTheLargerShareAtNextLevel() {
        let h = [1: stats(7200, memory: 0), 2: stats(7200, memory: 0.01), 3: stats(7200, memory: 0.07, cpu: 0.12)]
        #expect(AgentCapacity.compute(h, config: HeadroomConfig()) == .capacity(n: 2, next: (.cpu, 0.12)))
    }

    @Test func capacityAtHighestObservedLevelHasNoNext() {
        let h = [0: stats(90_000, memory: 0.9), 1: stats(10_800, memory: 0), 2: stats(10_800, memory: 0.049)]
        #expect(AgentCapacity.compute(h, config: HeadroomConfig()) == .capacity(n: 2, next: nil))
    }

    @Test func capacityShortLevelStopsTheWalk() {
        let h = [1: stats(18_000, memory: 0), 2: stats(3599, memory: 0), 3: stats(7200, memory: 0)]
        #expect(AgentCapacity.compute(h, config: HeadroomConfig()) == .capacity(n: 1, next: nil))
    }

    @Test func capacityLimitedAtOne() {
        let h = [1: stats(18_000, memory: 0.09, cpu: 0.03)]
        #expect(AgentCapacity.compute(h, config: HeadroomConfig()) == .limitedAtOne(resource: .memory, share: 0.09))
    }

    @Test func capacityInsufficient() {
        let fourHours = [0: stats(360_000, memory: 0), 1: stats(7200, memory: 0), 2: stats(7200, memory: 0)]
        #expect(AgentCapacity.compute(fourHours, config: HeadroomConfig()) == .insufficientData(totalHours: 4))

        let shortLevelOne = [1: stats(1800, memory: 0), 2: stats(18_000, memory: 0)]
        #expect(AgentCapacity.compute(shortLevelOne, config: HeadroomConfig()) == .insufficientData(totalHours: 5.5))
    }

    @Test func capacitySentence() {
        #expect(
            AgentCapacity.sentence(.capacity(n: 3, next: (.memory, 0.22)))
                == "This machine handles 3 AI agents at once. With 4 it runs out of memory 22% of the time.")
        #expect(
            AgentCapacity.sentence(.limitedAtOne(resource: .memory, share: 0.09))
                == "This machine runs short of memory even with a single AI agent (limited 9% of the time).")
        #expect(
            AgentCapacity.sentence(.insufficientData(totalHours: 2))
                == "Not enough AI agent activity recorded yet to measure agent capacity.")
    }

    @Test func capacitySentenceOtherForms() {
        #expect(
            AgentCapacity.sentence(.capacity(n: 1, next: (.cpu, 0.125)))
                == "This machine handles 1 AI agent at once. With 2 the processor is fully busy 12.5% of the time.")
        #expect(
            AgentCapacity.sentence(.capacity(n: 2, next: nil))
                == "This machine handles 2 AI agents at once. More than 2 hasn't been recorded long enough to measure.")
        #expect(
            AgentCapacity.sentence(.limitedAtOne(resource: .cpu, share: 0.3))
                == "This machine runs short of processor time even with a single AI agent (limited 30% of the time).")
    }

    // MARK: Spec recommendation

    @Test func specMemory() {
        // Nearest-rank p95 of 20 days is the 19th smallest: 30 GB, not the 60 GB outlier.
        let peaks = Array(repeating: 20 * gib, count: 18) + [60 * gib, 30 * gib]
        let r = recommend(peaks: peaks)
        #expect(r.memoryGB == 48)
        #expect(r.headline.hasPrefix("Recommended: 48 GB memory"))
        #expect(
            r.reasons[0]
                == "Peak memory demand reached 30.0 GB on a typical heavy day; 48 GB is the smallest option with at least 25% headroom.")
    }

    @Test func specMemoryBeyondLargestTier() {
        let r = recommend(peaks: [200 * gib])
        #expect(r.memoryGB == 128)
        #expect(r.reasons[0].contains("exceeds the largest configuration"))
    }

    @Test func specCores() {
        let busy = recommend(medianSaturated: 2400, cores: 8)
        #expect(busy.cores == 10)
        #expect(busy.headline == "Recommended: 48 GB memory, 10+ cores, 1 TB storage")

        let quiet = recommend(medianSaturated: 1200, cores: 8)
        #expect(quiet.cores == nil)
        #expect(quiet.headline == "Recommended: 48 GB memory, 1 TB storage")

        let maxed = recommend(medianSaturated: 2400, cores: 16)
        #expect(maxed.cores == 16)
        #expect(maxed.reasons[1].contains("exceeds the largest configuration"))
    }

    @Test func specStorage() {
        let r = recommend(used: 400_000_000_000, growthPerDay: 1e9)
        #expect(r.storageGB == 1024)
        #expect(r.headline.hasSuffix("1 TB storage"))
        #expect(
            r.reasons[2]
                == "Storage holds 400 GB and grows 1.0 GB a day; a year of growth plus 20% needs 918 GB, so 1 TB.")

        #expect(recommend(used: 300_000_000_000, growthPerDay: -5e9).storageGB == 512)
        #expect(recommend(used: 300_000_000_000, growthPerDay: -5e9).headline.hasSuffix("512 GB storage"))
        #expect(recommend(used: 1_500_000_000_000, growthPerDay: 0).headline.hasSuffix("2 TB storage"))
    }

    // MARK: Tiers and baseline files

    @Test func badTiersFallsBack() throws {
        let url = try tempFile("{nope")
        defer { try? FileManager.default.removeItem(at: url) }
        let (tiers, warning) = Tiers.load(from: url)
        #expect(tiers == Tiers.defaults)
        #expect(warning != nil)

        let empty = try tempFile(#"{"memoryGB":[],"cores":[8],"storageGB":[512]}"#)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(Tiers.load(from: empty).0 == Tiers.defaults)
        #expect(Tiers.load(from: empty).warning != nil)

        let missing = Tiers.load(from: try tempFile(nil))
        #expect(missing.0 == Tiers.defaults)
        #expect(missing.warning == nil)
        #expect(Tiers.defaults.memoryGB == [16, 24, 32, 36, 48, 64, 96, 128])
        #expect(Tiers.defaults.cores == [8, 10, 12, 14, 16])
        #expect(Tiers.defaults.storageGB == [512, 1024, 2048, 4096, 8192])
    }

    @Test func badBaselineIgnored() throws {
        let url = try tempFile(#"{"label":"x"}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let (baseline, warning) = Baseline.load(from: url)
        #expect(baseline == nil)
        #expect(warning != nil)

        let missing = Baseline.load(from: try tempFile(nil))
        #expect(missing.0 == nil)
        #expect(missing.warning == nil)
    }

    @Test func exampleBaselineLoads() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/baseline.example.json")
        let (baseline, warning) = Baseline.load(from: url)
        #expect(warning == nil)
        #expect(baseline?.label == "Example reference workstation")
    }
}

import Foundation
import Testing

@testable import HeadroomCore

struct SamplingBenchmarkTests {
    // Wall-clock budgets are flaky on a loaded machine, so they only run under `make bench`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEADROOM_BENCH"] == "1", "wall-clock budget; run via make bench")) func samplingPassBudget() {
        var pipeline = SamplingPipeline(classifier: Classifier(rules: .defaults, currentUID: getuid()), config: HeadroomConfig())
        pipeline.discard()
        var counter = ProcessSampler()
        let processCount = counter.sweep().count
        let budget = budgetPerProcess * processCount

        // The median of batch means, so one batch slowed by other tests running in parallel can't fail the run.
        let batches = 10
        let passesPerBatch = 100
        var recorded = 0
        var batchMeans: [Duration] = []
        let clock = ContinuousClock()
        for batch in 0..<batches {
            let start = clock.now
            for pass in 0..<passesPerBatch {
                let i = batch * passesPerBatch + pass
                let tick = pipeline.sample(
                    now: Double(i * 10), interval: 10, refreshSpace: i % 6 == 0, thermal: ThermalLevel.current())
                if tick != nil { recorded += 1 }
            }
            batchMeans.append((clock.now - start) / passesPerBatch)
        }
        batchMeans.sort()
        let median = (batchMeans[batches / 2 - 1] + batchMeans[batches / 2]) / 2
        #expect(recorded == batches * passesPerBatch)
        #expect(median <= budget, "median sampling pass \(median) for \(processCount) processes, budget \(budget)")
    }

    // The pass sweeps every readable process, so its cost grows with the process count; a fixed 5 ms cap flaked
    // as a dev machine got busier. Measured in a debug build (what `swift test` runs) on an M-series machine:
    // 3.4–3.6 ms for ~410 swept processes (~8.5 µs each) when quiet, 4.7–5.1 ms for ~430 (~11 µs each) under
    // load average 4. Release is about half that. 20 µs leaves about 2× headroom at the loaded rate.
    private let budgetPerProcess = Duration.microseconds(20)
}

struct SamplingPipelineTests {
    @Test func firstSampleHasNoBaselineThenTicksFlow() throws {
        var pipeline = SamplingPipeline(classifier: Classifier(rules: .defaults, currentUID: getuid()), config: HeadroomConfig())
        #expect(pipeline.sample(now: 0, interval: 10, refreshSpace: true, thermal: .nominal) == nil)
        let second = pipeline.sample(now: 10, interval: 10, refreshSpace: false, thermal: .fair)
        let tick = try #require(second)
        #expect(tick.ts == 10)
        #expect(tick.thermal == .fair)
        #expect(tick.disk.capacity > 0)
        #expect(tick.memory.total > 0)
        #expect(tick.groups[.system] != nil)
        #expect(tick.groups.values.reduce(0) { $0 + $1.procCount } > 1)
        #expect(tick.topByCPU.count == 5 && tick.topByMemory.count == 5)
        #expect(tick.selfCPU == 0 && tick.selfFootprint == 0)
    }

    @Test func discardSetsTheBaseline() {
        var pipeline = SamplingPipeline(classifier: Classifier(rules: .defaults, currentUID: getuid()), config: HeadroomConfig())
        pipeline.discard()
        #expect(pipeline.sample(now: 10, interval: 10, refreshSpace: true, thermal: .nominal) != nil)
    }
}

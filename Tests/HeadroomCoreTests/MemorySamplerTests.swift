import Foundation
import Testing

@testable import HeadroomCore

@Suite struct MemorySamplerTests {
    private func counters(
        internalPages: UInt64 = 0, purgeable: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0,
        external: UInt64 = 0, swapins: UInt64 = 0, swapouts: UInt64 = 0
    ) -> VMCounters {
        VMCounters(
            free: 0, active: 0, inactive: 0, wired: wired, compressed: compressed, purgeable: purgeable,
            external: external, internalPages: internalPages, swapins: swapins, swapouts: swapouts,
            pageins: 0, pageouts: 0)
    }

    private func reading(previous: VMCounters?, current: VMCounters) -> MemoryReading {
        MemorySampler.reading(
            previous: previous, current: current, pageSize: 16384, total: 1 << 34, pressure: .normal,
            memorystatusLevel: 80, swapUsed: 0, swapTotal: 0)
    }

    @Test func appMemoryFormula() {
        let current = counters(internalPages: 1000, purgeable: 100, wired: 200, compressed: 300, external: 50)
        let result = reading(previous: nil, current: current)
        #expect(result.app == (1000 - 100) * 16384)
        #expect(result.wired == 200 * 16384)
        #expect(result.compressed == 300 * 16384)
        #expect(result.used == result.app + 200 * 16384 + 300 * 16384)
        #expect(result.fileBacked == 50 * 16384)
    }

    @Test func firstReadingHasZeroDeltas() {
        let result = reading(previous: nil, current: counters(swapins: 10, swapouts: 20))
        #expect(result.swapins == 0)
        #expect(result.swapouts == 0)
    }

    @Test func deltasUseCounterDelta() {
        let result = reading(previous: counters(swapouts: 50), current: counters(swapins: 7, swapouts: 20))
        #expect(result.swapouts == 0)
        #expect(result.swapins == 7)
    }

    @Test func liveSmoke() {
        var sampler = MemorySampler()
        let result = sampler.sample()
        #expect(result.total == ProcessInfo.processInfo.physicalMemory)
        #expect(result.swapTotal >= result.swapUsed)
        #expect([PressureLevel.normal, .warn, .critical].contains(result.pressure))
    }
}

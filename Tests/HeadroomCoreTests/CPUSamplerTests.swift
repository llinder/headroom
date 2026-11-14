import Foundation
import Testing
@testable import HeadroomCore

@Suite struct CPUSamplerTests {
    @Test func counterDeltaResetsToZero() {
        #expect(counterDelta(10, 3) == 0)
        #expect(counterDelta(3, 10) == 7)
    }

    @Test func readingFromTicks() {
        let previous = [CoreTicks(user: 0, system: 0, idle: 0, nice: 0), CoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let current = [CoreTicks(user: 30, system: 10, idle: 60, nice: 0), CoreTicks(user: 0, system: 0, idle: 100, nice: 0)]
        let reading = CPUSampler.reading(previous: previous, current: current, interval: 1, load: (1, 2, 3))
        #expect(abs(reading.user - 0.15) < 1e-9)
        #expect(abs(reading.system - 0.05) < 1e-9)
        #expect(abs(reading.idle - 0.8) < 1e-9)
        #expect(reading.perCoreBusy.count == 2)
        #expect(abs(reading.perCoreBusy[0] - 0.4) < 1e-9)
        #expect(abs(reading.perCoreBusy[1]) < 1e-9)
        #expect(abs(reading.busySeconds - 0.4) < 1e-9)
        #expect(reading.load1 == 1 && reading.load5 == 2 && reading.load15 == 3)
    }

    @Test func tickResetIsNotNegative() {
        let previous = [CoreTicks(user: 100, system: 100, idle: 100, nice: 100)]
        let current = [CoreTicks(user: 10, system: 10, idle: 10, nice: 10)]
        let reading = CPUSampler.reading(previous: previous, current: current, interval: 1, load: (0, 0, 0))
        #expect(reading.perCoreBusy[0] == 0)
        #expect(reading.busySeconds == 0)
        #expect(reading.user >= 0 && reading.system >= 0 && reading.idle >= 0)
    }

    @Test func liveSamplerSmoke() async throws {
        var sampler = CPUSampler()
        let first = sampler.sample(interval: 0.2)
        #expect(first == nil)
        try await Task.sleep(for: .milliseconds(200))
        let second = sampler.sample(interval: 0.2)
        let reading = try #require(second)
        #expect(reading.perCoreBusy.count == ProcessInfo.processInfo.activeProcessorCount)
        for value in reading.perCoreBusy + [reading.user, reading.system, reading.idle] {
            #expect((0.0...1.0).contains(value))
        }
    }
}

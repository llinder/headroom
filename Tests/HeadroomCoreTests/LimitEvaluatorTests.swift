import Testing
@testable import HeadroomCore

private let gb: UInt64 = 1_000_000_000

private func cpu(idle: Double = 0.5, load1: Double = 1) -> CPUReading {
    CPUReading(
        user: 0.3, system: 0.2, idle: idle, perCoreBusy: [], load1: load1, load5: load1, load15: load1, busySeconds: 0)
}

private func memory(
    pressure: PressureLevel = .normal, swapUsed: UInt64 = 0, swapins: UInt64 = 0, swapouts: UInt64 = 0
) -> MemoryReading {
    MemoryReading(
        total: 16 * gb, used: 8 * gb, app: 4 * gb, wired: 2 * gb, compressed: gb, free: 4 * gb, fileBacked: 2 * gb,
        pressure: pressure, memorystatusLevel: nil, swapUsed: swapUsed, swapTotal: 8 * gb,
        swapins: swapins, swapouts: swapouts, pageins: 0, pageouts: 0)
}

private func evaluate(
    cpu: CPUReading = cpu(), memory: MemoryReading = memory(), thermal: ThermalLevel = .nominal, cores: Int = 8
) -> LimitFlags {
    LimitEvaluator.evaluate(cpu: cpu, memory: memory, thermal: thermal, logicalCores: cores, config: LimitConfig())
}

@Suite struct LimitEvaluatorTests {
    @Test func warnPressureIsMemoryLimited() {
        #expect(evaluate(memory: memory(pressure: .warn)) == [.memoryLimited])
    }

    @Test func swapoutsAtNormalPressureIsMemoryLimited() {
        #expect(evaluate(memory: memory(swapouts: 1)) == [.memoryLimited])
    }

    @Test func heavySwapNeedsSwapins() {
        let used = UInt64(0.3 * Double(16 * gb))
        #expect(evaluate(memory: memory(swapUsed: used, swapins: 1)) == [.heavySwap])
        #expect(evaluate(memory: memory(swapUsed: used, swapins: 0)).isEmpty)
    }

    @Test func lowIdleIsCPUSaturated() {
        #expect(evaluate(cpu: cpu(idle: 0.09)) == [.cpuSaturated])
    }

    @Test func loadAboveTwiceCoresIsCPUSaturated() {
        #expect(evaluate(cpu: cpu(load1: 17)) == [.cpuSaturated])
        #expect(evaluate(cpu: cpu(load1: 15)).isEmpty)
    }

    @Test func seriousThermalIsThermalLimited() {
        #expect(evaluate(thermal: .serious) == [.thermalLimited])
    }

    @Test func diskTightUsesLargerOfFractionAndMinimum() {
        let config = LimitConfig()
        #expect(LimitEvaluator.isDiskTight(free: 40 * gb, capacity: 512 * gb, config: config))
        #expect(LimitEvaluator.isDiskTight(free: 60 * gb, capacity: 2000 * gb, config: config))
        #expect(!LimitEvaluator.isDiskTight(free: 300 * gb, capacity: 2000 * gb, config: config))
    }
}

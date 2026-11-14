import Foundation

public struct LimitFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let memoryLimited = LimitFlags(rawValue: 1)
    public static let heavySwap = LimitFlags(rawValue: 2)
    public static let cpuSaturated = LimitFlags(rawValue: 4)
    public static let thermalLimited = LimitFlags(rawValue: 8)
}

public enum ThermalLevel: Int, Sendable {
    case nominal = 0
    case fair
    case serious
    case critical

    public static func current() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }
}

public enum LimitEvaluator {
    public static func evaluate(
        cpu: CPUReading, memory: MemoryReading, thermal: ThermalLevel, logicalCores: Int, config: LimitConfig
    ) -> LimitFlags {
        var flags: LimitFlags = []
        if memory.pressure != .normal || memory.swapouts > 0 {
            flags.insert(.memoryLimited)
        }
        if Double(memory.swapUsed) > config.heavySwapFractionOfRAM * Double(memory.total), memory.swapins > 0 {
            flags.insert(.heavySwap)
        }
        if 1 - cpu.idle >= config.cpuSaturatedFraction
            || cpu.load1 >= Double(logicalCores) * config.loadPerCoreMultiplier
        {
            flags.insert(.cpuSaturated)
        }
        switch thermal {
        case .serious, .critical: flags.insert(.thermalLimited)
        case .nominal, .fair: break
        }
        return flags
    }

    public static func isDiskTight(free: UInt64, capacity: UInt64, config: LimitConfig) -> Bool {
        free < max(UInt64(Double(capacity) * config.diskTightFraction), config.diskTightMinBytes)
    }
}

import Foundation

public struct LimitConfig: Codable, Sendable, Equatable {
    public var cpuSaturatedFraction = 0.90
    public var loadPerCoreMultiplier = 2.0
    public var heavySwapFractionOfRAM = 0.25
    public var diskTightFraction = 0.10
    public var diskTightMinBytes: UInt64 = 50_000_000_000
    public var memoryLimitedDayMinSeconds = 900

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LimitConfig()
        cpuSaturatedFraction = try c.decodeIfPresent(Double.self, forKey: .cpuSaturatedFraction) ?? d.cpuSaturatedFraction
        loadPerCoreMultiplier = try c.decodeIfPresent(Double.self, forKey: .loadPerCoreMultiplier) ?? d.loadPerCoreMultiplier
        heavySwapFractionOfRAM = try c.decodeIfPresent(Double.self, forKey: .heavySwapFractionOfRAM) ?? d.heavySwapFractionOfRAM
        diskTightFraction = try c.decodeIfPresent(Double.self, forKey: .diskTightFraction) ?? d.diskTightFraction
        diskTightMinBytes = try c.decodeIfPresent(UInt64.self, forKey: .diskTightMinBytes) ?? d.diskTightMinBytes
        memoryLimitedDayMinSeconds =
            try c.decodeIfPresent(Int.self, forKey: .memoryLimitedDayMinSeconds) ?? d.memoryLimitedDayMinSeconds
    }
}

public struct HeadroomConfig: Codable, Sendable, Equatable {
    public var limits = LimitConfig()
    public var workdayMinAwakeSeconds = 7200
    public var agentActiveCoreFraction = 0.05
    public var capacityMaxLimitedShare = 0.05
    public var capacityMinSecondsPerLevel = 3600
    public var capacityMinTotalSeconds = 18000

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HeadroomConfig()
        limits = try c.decodeIfPresent(LimitConfig.self, forKey: .limits) ?? d.limits
        workdayMinAwakeSeconds = try c.decodeIfPresent(Int.self, forKey: .workdayMinAwakeSeconds) ?? d.workdayMinAwakeSeconds
        agentActiveCoreFraction = try c.decodeIfPresent(Double.self, forKey: .agentActiveCoreFraction) ?? d.agentActiveCoreFraction
        capacityMaxLimitedShare = try c.decodeIfPresent(Double.self, forKey: .capacityMaxLimitedShare) ?? d.capacityMaxLimitedShare
        capacityMinSecondsPerLevel =
            try c.decodeIfPresent(Int.self, forKey: .capacityMinSecondsPerLevel) ?? d.capacityMinSecondsPerLevel
        capacityMinTotalSeconds = try c.decodeIfPresent(Int.self, forKey: .capacityMinTotalSeconds) ?? d.capacityMinTotalSeconds
    }

    /// A missing file is the normal first-run state, so it yields the defaults without a warning.
    public static func load(from url: URL) -> (HeadroomConfig, warning: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (HeadroomConfig(), nil) }
        do {
            let data = try Data(contentsOf: url)
            return (try JSONDecoder().decode(HeadroomConfig.self, from: data), nil)
        } catch {
            return (HeadroomConfig(), "ignoring \(url.path): \(error.localizedDescription)")
        }
    }
}

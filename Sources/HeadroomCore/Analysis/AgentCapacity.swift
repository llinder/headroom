public enum Resource: String, Sendable {
    case memory, cpu
}

public enum AgentCapacityResult: Equatable, Sendable {
    case insufficientData(totalHours: Double)
    case limitedAtOne(resource: Resource, share: Double)
    case capacity(n: Int, next: (resource: Resource, share: Double)?)

    public static func == (a: AgentCapacityResult, b: AgentCapacityResult) -> Bool {
        switch (a, b) {
        case let (.insufficientData(x), .insufficientData(y)):
            x == y
        case let (.limitedAtOne(r1, s1), .limitedAtOne(r2, s2)):
            r1 == r2 && s1 == s2
        case let (.capacity(n1, next1), .capacity(n2, next2)):
            n1 == n2 && next1?.resource == next2?.resource && next1?.share == next2?.share
        case (.insufficientData, _), (.limitedAtOne, _), (.capacity, _):
            false
        }
    }
}

public enum AgentCapacity {
    /// Capacity is the largest N where every level 1…N has enough samples and a limited share under the
    /// threshold; the walk stops at the first level that fails, even if a higher one passes.
    public static func compute(_ h: [Int: AgentLevelStats], config: HeadroomConfig) -> AgentCapacityResult {
        let minPerLevel = Double(config.capacityMinSecondsPerLevel)
        let total = h.filter { $0.key >= 1 }.reduce(0) { $0 + $1.value.seconds }
        guard total >= Double(config.capacityMinTotalSeconds), let one = h[1], one.seconds >= minPerLevel else {
            return .insufficientData(totalHours: total / 3600)
        }
        let first = limited(one)
        guard first.share < config.capacityMaxLimitedShare else {
            return .limitedAtOne(resource: first.resource, share: first.share)
        }

        var n = 1
        while let stats = h[n + 1], stats.seconds >= minPerLevel {
            let next = limited(stats)
            guard next.share < config.capacityMaxLimitedShare else { return .capacity(n: n, next: next) }
            n += 1
        }
        // The next level is unobserved or too short to judge, so no share is claimed for it.
        return .capacity(n: n, next: nil)
    }

    public static func sentence(_ r: AgentCapacityResult) -> String {
        switch r {
        case .insufficientData:
            return "Not enough AI agent activity recorded yet to measure agent capacity."
        case let .limitedAtOne(resource, share):
            let what = resource == .memory ? "memory" : "processor time"
            return "This machine runs short of \(what) even with a single AI agent (limited \(Wording.percent(share)) of the time)."
        case let .capacity(n, next):
            let handles = "This machine handles \(n) AI agent\(n == 1 ? "" : "s") at once."
            guard let next else { return "\(handles) Running more than \(n) at once hasn't been recorded long enough to measure." }
            let effect = next.resource == .memory ? "it runs out of memory" : "the processor is fully busy"
            return "\(handles) With \(n + 1) \(effect) \(Wording.percent(next.share)) of the time."
        }
    }

    /// The histogram keeps memory-limited and CPU-saturated seconds separately, so their union (time limited by
    /// either) can't be recovered. The larger of the two is the tightest bound available without double
    /// counting overlap: it can understate the union but never exceeds it.
    private static func limited(_ s: AgentLevelStats) -> (resource: Resource, share: Double) {
        guard s.seconds > 0 else { return (.memory, 0) }
        return s.memoryLimited >= s.cpuSaturated
            ? (.memory, s.memoryLimited / s.seconds) : (.cpu, s.cpuSaturated / s.seconds)
    }
}

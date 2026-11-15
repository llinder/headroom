public enum TickAggregation {
    private static let topCount = 5

    /// Per-group totals for one tick. CPU the kernel counted as busy but no readable process accounts for
    /// (processes refusing rusage, exited mid-sweep, the kernel itself) goes to `.system`.
    public static func groupTotals(
        processes: [ProcessUsage], groups: [ProcessKey: WorkloadGroup], busySeconds: Double
    ) -> [WorkloadGroup: GroupTotals] {
        var totals: [WorkloadGroup: GroupTotals] = [:]
        var attributed = 0.0
        for p in processes {
            let group = groups[p.identity.key] ?? .other
            var t = totals[group] ?? GroupTotals(cpuSeconds: 0, footprint: 0, diskWriteBytes: 0, procCount: 0)
            t.cpuSeconds += p.cpuSeconds
            t.footprint &+= p.footprint
            t.diskWriteBytes &+= p.diskWriteBytes
            t.procCount += 1
            totals[group] = t
            attributed += p.cpuSeconds
        }
        var system = totals[.system] ?? GroupTotals(cpuSeconds: 0, footprint: 0, diskWriteBytes: 0, procCount: 0)
        system.cpuSeconds += max(0, busySeconds - attributed)
        totals[.system] = system
        return totals
    }

    public static func top(
        processes: [ProcessUsage], groups: [ProcessKey: WorkloadGroup]
    ) -> (
        byCPU: [(name: String, group: WorkloadGroup, value: Double)],
        byMemory: [(name: String, group: WorkloadGroup, value: Double)]
    ) {
        // A bounded insertion keeps this linear; sorting every process each tick costs far more than the pick.
        func entries(_ value: (ProcessUsage) -> Double) -> [(name: String, group: WorkloadGroup, value: Double)] {
            var best: [(usage: ProcessUsage, value: Double)] = []
            best.reserveCapacity(topCount + 1)
            for p in processes {
                let v = value(p)
                if best.count == topCount, let last = best.last, v <= last.value { continue }
                let at = best.firstIndex { v > $0.value } ?? best.count
                best.insert((usage: p, value: v), at: at)
                if best.count > topCount { best.removeLast() }
            }
            return best.map { (name: $0.usage.identity.name, group: groups[$0.usage.identity.key] ?? .other, value: $0.value) }
        }
        return (entries { $0.cpuSeconds }, entries { Double($0.footprint) })
    }
}

/// Swap change per minute, measured against a sample 55-90 s old. Nothing older is trusted: after a sleep the
/// newest surviving sample is hours old and would report the whole sleep as one minute of growth.
public struct SwapGrowth: Sendable {
    private static let window = 60.0
    private static let minAge = 55.0
    private static let maxAge = 90.0
    // 10 samples at the recorder's 10 s tick cover maxAge.
    private static let capacity = 10
    private var samples: [(at: Double, used: UInt64)] = []

    public init() {}

    public mutating func record(swapUsed: UInt64, at: Double) -> Int64 {
        let reference = samples
            .filter { (Self.minAge...Self.maxAge).contains(at - $0.at) }
            .min { abs(at - $0.at - Self.window) < abs(at - $1.at - Self.window) }
        samples.append((at: at, used: swapUsed))
        if samples.count > Self.capacity { samples.removeFirst() }
        guard let reference else { return 0 }
        let delta = Double(swapUsed) - Double(reference.used)
        let perMinute = delta * Self.window / (at - reference.at)
        // Double(Int64.max) rounds up to 2^63, which Int64() would trap on, so compare strictly.
        if perMinute >= Double(Int64.max) { return Int64.max }
        if perMinute <= Double(Int64.min) { return Int64.min }
        return Int64(perMinute.rounded())
    }
}

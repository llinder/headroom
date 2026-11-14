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

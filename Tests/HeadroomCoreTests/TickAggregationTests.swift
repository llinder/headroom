import Foundation
import Testing

@testable import HeadroomCore

struct TickAggregationTests {
    func usage(_ pid: Int32, _ name: String, cpu: Double, footprint: UInt64 = 0, write: UInt64 = 0, attributed: Bool = true) -> ProcessUsage {
        ProcessUsage(
            identity: ProcessIdentity(key: ProcessKey(pid: pid, start: 1), ppid: 1, uid: 501, name: name, path: ""),
            cpuSeconds: cpu, footprint: footprint, diskReadBytes: 0, diskWriteBytes: write, attributed: attributed)
    }

    @Test func groupTotalsAddUnattributedToSystem() {
        let procs = [
            usage(10, "go", cpu: 2, footprint: 100, write: 5),
            usage(11, "compile", cpu: 1, footprint: 50, write: 1),
            usage(12, "WindowServer", cpu: 0.5, footprint: 10),
            usage(13, "denied", cpu: 0, attributed: false),
            usage(14, "unknown", cpu: 0.25),
        ]
        let groups: [ProcessKey: WorkloadGroup] = [
            procs[0].identity.key: .goBuilds, procs[1].identity.key: .goBuilds,
            procs[2].identity.key: .system, procs[3].identity.key: .system,
        ]
        let totals = TickAggregation.groupTotals(processes: procs, groups: groups, busySeconds: 5)
        #expect(totals[.goBuilds] == GroupTotals(cpuSeconds: 3, footprint: 150, diskWriteBytes: 6, procCount: 2))
        // 5 busy − 3.75 attributed = 1.25 unattributed, on top of the 0.5 measured for system.
        #expect(totals[.system] == GroupTotals(cpuSeconds: 1.75, footprint: 10, diskWriteBytes: 0, procCount: 2))
        #expect(totals[.other] == GroupTotals(cpuSeconds: 0.25, footprint: 0, diskWriteBytes: 0, procCount: 1))
    }

    @Test func unattributedNeverNegative() {
        let procs = [usage(10, "go", cpu: 9)]
        let totals = TickAggregation.groupTotals(
            processes: procs, groups: [procs[0].identity.key: .goBuilds], busySeconds: 5)
        #expect(totals[.system] == GroupTotals(cpuSeconds: 0, footprint: 0, diskWriteBytes: 0, procCount: 0))
        #expect(totals[.goBuilds]?.cpuSeconds == 9)
    }

    @Test func topFiveByCPUAndFootprint() {
        let procs = (1...7).map { usage(Int32($0), "p\($0)", cpu: Double($0), footprint: UInt64(100 - $0)) }
        let groups = Dictionary(uniqueKeysWithValues: procs.map { ($0.identity.key, WorkloadGroup.ide) })
        let top = TickAggregation.top(processes: procs, groups: groups)
        #expect(top.byCPU.map(\.name) == ["p7", "p6", "p5", "p4", "p3"])
        #expect(top.byCPU.map(\.value) == [7, 6, 5, 4, 3])
        #expect(top.byCPU.allSatisfy { $0.group == .ide })
        #expect(top.byMemory.map(\.name) == ["p1", "p2", "p3", "p4", "p5"])
        #expect(top.byMemory.first?.value == 99)
    }
}

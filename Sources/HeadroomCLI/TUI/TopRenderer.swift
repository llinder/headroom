import Foundation
import HeadroomCore

struct TopState {
    var machine: MachineInfo
    var cpu: CPUReading
    var cpuHistory: [Double]
    var memory: MemoryReading
    var disk: DiskReading
    var diskGrowthPerDay: Double?
    var groups: [(WorkloadGroup, GroupTotals)]
    var topProcs: [(String, Double, UInt64)]
    var agents: [(run: AgentRun, directory: String?)]
    var today: [LimitKind: Double]
    var recordingDays: Int
    var gapCount: Int
    var recorderRunning: Bool
    var showProcesses: Bool
    var showAgents: Bool
    /// Agent ages are measured against this, which keeps `render` a pure function of its input.
    var now: Double = Date().timeIntervalSince1970
}

/// Pure: turns a state into screen lines, so everything visible is testable without a terminal. CPU seconds in
/// the state are per one-second sample, which is what `headroom top` samples at.
enum TopRenderer {
    private static let sparkBlocks = Array("▁▂▃▄▅▆▇█")
    private static let barCells = 13
    private static let sparkCells = 20
    private static let paneRows = 8
    private static let gib = 1_073_741_824.0
    private static let gb = 1_000_000_000.0

    static func render(_ s: TopState, width: Int, height: Int) -> [String] {
        var lines = [header(s, width: width), cpuRow(s), memoryRow(s), swapRow(s), diskRow(s)]
        lines += s.showProcesses ? processPane(s, width: width) : groupPane(s, width: width)
        if s.showAgents { lines += agentPane(s, width: width) }
        return lines.prefix(max(0, height)).map { fit($0, width) }
    }

    /// Every character `top` draws (box, block, sparkline, dots) is one column wide, so a scalar count is the width.
    static func displayWidth(_ text: String) -> Int { text.unicodeScalars.count }

    private static func fit(_ text: String, _ width: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(max(0, width))))
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        let cut = fit(text, width)
        return cut + String(repeating: " ", count: width - displayWidth(cut))
    }

    private static func rpad(_ text: String, _ width: Int) -> String {
        let cut = fit(text, width)
        return String(repeating: " ", count: width - displayWidth(cut)) + cut
    }

    private static func header(_ s: TopState, width: Int) -> String {
        let name = s.machine.chip.isEmpty ? s.machine.model : s.machine.chip
        let ram = Int((Double(s.machine.ramBytes) / gib).rounded())
        let disk = Int((Double(s.machine.diskBytes) / gb).rounded())
        let left = " headroom ── \(name) · \(s.machine.perfCores + s.machine.effCores) cores · \(ram) GB · \(disk) GB "
        let right = s.recorderRunning ? "recording ● \(s.recordingDays)d, \(s.gapCount) gaps" : "not recording ○"
        let fill = max(1, width - displayWidth(left) - displayWidth(right) - 1)
        return left + String(repeating: "─", count: fill) + " " + right
    }

    private static func cpuRow(_ s: TopState) -> String {
        let spark = s.cpuHistory.suffix(sparkCells).map { value -> Character in
            sparkBlocks[Int((min(1, max(0, value)) * Double(sparkBlocks.count - 1)).rounded())]
        }
        let percent = Int(((s.cpu.user + s.cpu.system) * 100).rounded())
        return " CPU     \(String(spark))  \(percent)%   saturated \(hours(s.today[.cpuSaturated])) today"
    }

    private static func memoryRow(_ s: TopState) -> String {
        let m = s.memory
        let pressure =
            switch m.pressure {
            case .normal: "NORMAL"
            case .warn: "WARN"
            case .critical: "CRITICAL"
            }
        return " Memory  \(bar(Double(m.used), of: Double(m.total))) \(gigs(m.used, gib))/\(gigs(m.total, gib, digits: 0)) GB"
            + "   pressure \(pressure)  memory-limited \(hours(s.today[.memoryLimited])) today"
    }

    private static func swapRow(_ s: TopState) -> String {
        " Swap    \(bar(Double(s.memory.swapUsed), of: Double(s.memory.swapTotal))) \(gigs(s.memory.swapUsed, gib)) GB"
    }

    private static func diskRow(_ s: TopState) -> String {
        let used = s.disk.capacity > s.disk.free ? s.disk.capacity - s.disk.free : 0
        var row =
            " Disk    \(bar(Double(used), of: Double(s.disk.capacity))) \(gigs(used, gb, digits: 0))/\(gigs(s.disk.capacity, gb, digits: 0)) GB"
        if let growth = s.diskGrowthPerDay {
            row += "   \(growth < 0 ? "-" : "+")\(String(format: "%.1f", abs(growth) / gb)) GB/day"
        }
        return row
    }

    private static func bar(_ value: Double, of total: Double) -> String {
        let filled = total > 0 ? Int((min(1, max(0, value / total)) * Double(barCells)).rounded()) : 0
        return String(repeating: "█", count: filled) + String(repeating: "░", count: barCells - filled)
    }

    private static func gigs(_ bytes: UInt64, _ unit: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", Double(bytes) / unit)
    }

    private static func hours(_ seconds: Double?) -> String {
        String(format: "%.1fh", (seconds ?? 0) / 3600)
    }

    private static func ruled(_ title: String, tail: String, width: Int) -> String {
        let left = " ── \(title) "
        let right = " \(tail)"
        return left + String(repeating: "─", count: max(1, width - displayWidth(left) - displayWidth(right))) + right
    }

    private static func groupPane(_ s: TopState, width: Int) -> [String] {
        let rows = s.groups.sorted { $0.1.cpuSeconds > $1.1.cpuSeconds }.prefix(paneRows)
        return [ruled("by workload", tail: "CPU ── Mem ──", width: width)]
            + rows.map { usageRow($0.0.displayName, $0.1.cpuSeconds, $0.1.footprint, width: width) }
    }

    private static func processPane(_ s: TopState, width: Int) -> [String] {
        let rows = s.topProcs.sorted { $0.1 > $1.1 }.prefix(paneRows)
        return [ruled("top processes", tail: "CPU ── Mem ──", width: width)]
            + rows.map { usageRow($0.0, $0.1, $0.2, width: width) }
    }

    private static func usageRow(_ name: String, _ cpuSeconds: Double, _ footprint: UInt64, width: Int) -> String {
        " " + pad(name, max(0, width - 14)) + rpad("\(Int((cpuSeconds * 100).rounded()))%", 6)
            + rpad(gigs(footprint, gib) + "G", 7)
    }

    private static func agentPane(_ s: TopState, width: Int) -> [String] {
        let rows = s.agents.map { agent -> String in
            let run = agent.run
            return " " + pad(run.tool.rawValue, 7) + pad(agent.directory ?? "—", max(0, width - 35))
                + rpad(age(s.now - run.started), 8) + rpad("\(Int((run.cpuSeconds * 100).rounded()))%", 6)
                + rpad(gigs(run.footprint, gib) + "G", 7) + rpad(run.isActive ? "" : "idle", 6)
        }
        return [ruled("agents (\(s.agents.count))", tail: "age ── CPU ── Mem ──", width: width)] + rows
    }

    private static func age(_ seconds: Double) -> String {
        let minutes = Int(max(0, seconds) / 60)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h\(minutes % 60)m"
    }
}

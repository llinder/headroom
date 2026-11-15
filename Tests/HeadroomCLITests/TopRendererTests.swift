import Foundation
import Testing

@testable import HeadroomCLI
@testable import HeadroomCore

private let gib: UInt64 = 1_073_741_824
private let now = 1_800_000_000.0

private func state(
    chip: String = "M3", history: [Double] = [0, 0.5, 1], pressure: PressureLevel = .normal,
    today: [LimitKind: Double] = [:], running: Bool = true, agents: [(run: AgentRun, directory: String?)] = []
) -> TopState {
    TopState(
        machine: MachineInfo(
            model: "Mac15,6", chip: chip, serialHash: "h", perfCores: 4, effCores: 4, ramBytes: 16 * gib,
            diskBytes: 512_000_000_000),
        cpu: CPUReading(user: 0.5, system: 0.22, idle: 0.28, perCoreBusy: [], load1: 1, load5: 1, load15: 1, busySeconds: 0),
        cpuHistory: history,
        memory: MemoryReading(
            total: 16 * gib, used: 15 * gib, app: 0, wired: 0, compressed: 0, free: 0, fileBacked: 0, pressure: pressure,
            memorystatusLevel: nil, swapUsed: 14 * gib, swapTotal: 16 * gib, swapins: 0, swapouts: 0, pageins: 0, pageouts: 0),
        disk: DiskReading(
            capacity: 512_000_000_000, free: 95_000_000_000, availableImportant: 0, readBytes: 0, writeBytes: 0,
            readOps: 0, writeOps: 0),
        diskGrowthPerDay: 6_200_000_000,
        groups: [
            (.browsers, GroupTotals(cpuSeconds: 0.04, footprint: 2 * gib, diskWriteBytes: 0, procCount: 3)),
            (.containers, GroupTotals(cpuSeconds: 0.31, footprint: 7 * gib, diskWriteBytes: 0, procCount: 3)),
        ],
        topProcs: [("kind", 0.3, gib)], agents: agents, today: today, recordingDays: 41, gapCount: 0,
        recorderRunning: running, showProcesses: false, showAgents: true, now: now)
}

private func run(_ tool: AgentTool, pid: Int32, minutes: Double, cpu: Double, active: Bool) -> AgentRun {
    AgentRun(
        root: ProcessKey(pid: pid, start: 1), tool: tool, started: now - minutes * 60, isActive: active, cpuSeconds: cpu,
        footprint: 2 * gib, diskWriteBytes: 0)
}

private func leftover(_ name: String, kind: LeftoverKind = .compose, memory: UInt64? = 2_400_000_000, minutes: Double = 125) -> FlaggedItem {
    FlaggedItem(
        item: LeftoverItem(
            key: "docker/\(name)", engine: "docker", kind: kind, name: name, containerIDs: ["abc"], sessionId: nil, lifetime: nil,
            cleanup: ["docker rm -f abc"]),
        startedAt: now - minutes * 60, reason: "no owner", memoryBytes: memory, firstFlagged: now - minutes * 60)
}

@Suite struct TopRendererTests {
    @Test func headerShowsLeftoverMarker() {
        var s = state()
        #expect(!TopRenderer.render(s, width: 90, height: 40)[0].contains("⚑"))
        s.leftovers = [leftover("shop"), leftover("dev", kind: .kind)]
        let line = TopRenderer.render(s, width: 90, height: 40)[0]
        #expect(line.hasSuffix("recording ● 41d, 0 gaps · ⚑ 2"))
        #expect(TopRenderer.displayWidth(line) == 90)
    }

    @Test func leftoversPaneRows() throws {
        var s = state()
        s.leftovers = [leftover("shop"), leftover("dev", kind: .kind, memory: nil, minutes: 30)]
        #expect(!TopRenderer.render(s, width: 100, height: 40).contains { $0.contains("leftovers (") })
        s.showLeftovers = true
        let lines = TopRenderer.render(s, width: 100, height: 40)
        let at = try #require(lines.firstIndex { $0.contains("── leftovers (2)") })
        #expect(lines[at + 1].contains("compose") && lines[at + 1].contains("shop") && lines[at + 1].contains("no owner"))
        #expect(lines[at + 1].contains("2.4 GB") && lines[at + 1].hasSuffix("2h5m"))
        #expect(lines[at + 2].contains("kind") && lines[at + 2].contains("unknown") && lines[at + 2].hasSuffix("30m"))
        #expect(!lines.contains { $0.contains("docker rm") })
    }

    @Test func leftoversPaneFitsWidth() {
        var s = state()
        s.leftovers = [leftover("a-remarkably-long-compose-project-name-for-testing")]
        s.showLeftovers = true
        for width in [20, 40, 80] {
            for line in TopRenderer.render(s, width: width, height: 40) {
                #expect(TopRenderer.displayWidth(line) <= width)
            }
        }
        let wide = TopRenderer.render(s, width: 80, height: 40).first { $0.contains("compose") }
        #expect(wide?.contains("2.4 GB") == true && wide?.hasSuffix("2h5m") == true)
    }

    @Test func headerLine() {
        let line = TopRenderer.render(state(), width: 90, height: 40)[0]
        #expect(line.hasPrefix(" headroom ── M3 · 8 cores · 16 GB · 512 GB"))
        #expect(line.hasSuffix("recording ● 41d, 0 gaps"))
        #expect(TopRenderer.displayWidth(line) == 90)
    }

    @Test func headerFallsBackToModel() {
        #expect(TopRenderer.render(state(chip: ""), width: 90, height: 40)[0].contains("── Mac15,6 · "))
    }

    @Test func fitsWidth() {
        let agents = [
            (run: run(.claude, pid: 1, minutes: 121, cpu: 0.6, active: true), directory: Optional("a-very-long-directory-name-indeed"))
        ]
        for width in [20, 40, 60, 80, 120] {
            for line in TopRenderer.render(state(today: [.cpuSaturated: 5000], agents: agents), width: width, height: 40) {
                #expect(TopRenderer.displayWidth(line) <= width)
            }
        }
    }

    @Test func sparkline() {
        let cpu = TopRenderer.render(state(), width: 100, height: 40)[1]
        #expect(cpu.contains("▁▅█"))
        #expect(cpu.contains("72%"))
    }

    @Test func memoryRowWarn() {
        let line = TopRenderer.render(state(pressure: .warn, today: [.memoryLimited: 11520]), width: 120, height: 40)[2]
        #expect(line.contains("pressure WARN"))
        #expect(line.contains("memory-limited 3.2h today"))
        #expect(line.contains("15.0/16 GB"))
    }

    @Test func diskRowShowsGrowth() {
        let line = TopRenderer.render(state(), width: 120, height: 40)[4]
        #expect(line.contains("417/512 GB"))
        #expect(line.contains("+6.2 GB/day"))
    }

    @Test func groupsSortedByCPU() {
        let lines = TopRenderer.render(state(), width: 80, height: 40)
        let pane = lines.drop { !$0.contains("by workload") }
        #expect(pane.dropFirst().first?.contains("Containers & Kind") == true)
        #expect(pane.dropFirst().first?.contains("31%") == true)
    }

    @Test func agentsPane() {
        let agents = [
            (run: run(.claude, pid: 1, minutes: 42, cpu: 0.18, active: true), directory: Optional("headroom")),
            (run: run(.claude, pid: 2, minutes: 121, cpu: 0.61, active: true), directory: Optional("api-service")),
            (run: run(.codex, pid: 3, minutes: 9, cpu: 0.03, active: false), directory: nil),
        ]
        let lines = TopRenderer.render(state(agents: agents), width: 100, height: 40)
        let pane = Array(lines.drop { !$0.contains("── agents (3)") })
        #expect(pane.count == 4)
        #expect(pane[1].contains("claude") && pane[1].contains("headroom") && pane[1].contains("42m") && pane[1].contains("18%"))
        #expect(pane[2].contains("2h1m") && pane[2].contains("61%") && pane[2].contains("2.0G"))
        #expect(pane[3].contains("codex") && pane[3].contains("—") && pane[3].hasSuffix("idle"))
        #expect(!pane[1].contains("idle"))
    }

    @Test func processesToggle() {
        var s = state()
        s.showProcesses = true
        s.showAgents = false
        let lines = TopRenderer.render(s, width: 80, height: 40)
        #expect(lines.contains { $0.contains("top processes") })
        #expect(!lines.contains { $0.contains("agents (") })
    }

    @Test func notRecording() {
        #expect(TopRenderer.render(state(running: false), width: 90, height: 40)[0].hasSuffix("not recording ○"))
    }

    @Test func heightTruncates() {
        #expect(TopRenderer.render(state(), width: 80, height: 3).count == 3)
    }

    @Test func tinyTerminalNeverTraps() {
        let agents = [(run: run(.claude, pid: 1, minutes: 5, cpu: 0.2, active: true), directory: Optional("x"))]
        for (width, height) in [(10, 3), (1, 1), (0, 0)] {
            let lines = TopRenderer.render(state(agents: agents), width: width, height: height)
            #expect(lines.count <= height)
            for line in lines { #expect(TopRenderer.displayWidth(line) <= width) }
        }
    }

    @Test func garbageInputsNeverTrap() {
        var s = state(history: [.nan, .infinity, 1e30, -1])
        s.cpu.user = .nan
        s.cpu.system = .infinity
        s.memory.total = 0
        s.memory.swapTotal = 0
        s.disk.capacity = 0
        s.diskGrowthPerDay = .nan
        s.today = [.cpuSaturated: .infinity, .memoryLimited: .nan]
        s.groups = [(.other, GroupTotals(cpuSeconds: 1e30, footprint: UInt64.max, diskWriteBytes: 0, procCount: 1))]
        s.topProcs = [("p", .infinity, UInt64.max)]
        s.agents = [
            (run: AgentRun(
                root: ProcessKey(pid: 1, start: 0), tool: .claude, started: 0, isActive: true, cpuSeconds: .nan,
                footprint: UInt64.max, diskWriteBytes: 0), directory: nil),
            (run: AgentRun(
                root: ProcessKey(pid: 2, start: 0), tool: .codex, started: now + 1e12, isActive: false, cpuSeconds: 1e30,
                footprint: 0, diskWriteBytes: 0), directory: nil),
        ]
        for showProcesses in [false, true] {
            s.showProcesses = showProcesses
            let lines = TopRenderer.render(s, width: 100, height: 40)
            #expect(!lines.isEmpty)
            #expect(lines.allSatisfy { TopRenderer.displayWidth($0) <= 100 })
        }
        #expect(TopRenderer.render(s, width: 100, height: 40).contains { $0.contains("416d15h") })
    }

    @Test func startedConvertsMicrosecondsToSeconds() {
        #expect(TopSession.startedSeconds(microseconds: 1_700_000_000_500_000) == 1_700_000_000.5)
        #expect(TopSession.startedSeconds(microseconds: 0) == 0)
    }
}

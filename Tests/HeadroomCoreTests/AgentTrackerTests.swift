import Testing

@testable import HeadroomCore

struct AgentTrackerTests {
    func id(_ pid: Int32, _ ppid: Int32, _ name: String, start: UInt64? = nil, path: String = "") -> ProcessIdentity {
        ProcessIdentity(key: ProcessKey(pid: pid, start: start ?? UInt64(pid)), ppid: ppid, uid: 501, name: name, path: path)
    }

    func usage(_ i: ProcessIdentity, cpu: Double = 0, footprint: UInt64 = 0, write: UInt64 = 0) -> ProcessUsage {
        ProcessUsage(identity: i, cpuSeconds: cpu, footprint: footprint, diskReadBytes: 0, diskWriteBytes: write, attributed: true)
    }

    static func ownGroup(_ p: ProcessIdentity) -> WorkloadGroup? {
        if p.name == "claude" || p.name == "codex" || p.path.contains("@anthropic-ai/claude-code") { return .agents }
        return nil
    }

    func run(_ t: inout AgentTracker, _ procs: [ProcessUsage], groups: [ProcessKey: WorkloadGroup] = [:], now: Double = 0) -> AgentUpdate {
        t.update(processes: procs, groups: groups, ownGroup: Self.ownGroup, now: now)
    }

    @Test func topLevelOnly() {
        var t = AgentTracker(activeCoreFraction: 0.05)
        let outer = id(10, 1, "claude"), inner = id(11, 10, "claude")
        let u = run(&t, [usage(outer), usage(inner)])
        #expect(u.live.count == 1)
        #expect(u.live[0].root == outer.key)
        #expect(u.started.count == 1)
    }

    @Test func toolFromName() {
        var t = AgentTracker(activeCoreFraction: 0.05)
        let codex = id(10, 1, "codex")
        let node = id(20, 1, "node", path: "/x/node_modules/@anthropic-ai/claude-code/cli.js")
        let u = run(&t, [usage(codex), usage(node)])
        #expect(u.live.first { $0.root == codex.key }?.tool == .codex)
        #expect(u.live.first { $0.root == node.key }?.tool == .claude)
    }

    @Test func idleUntilCPU() {
        var t = AgentTracker(activeCoreFraction: 0.05)
        let root = id(10, 1, "claude")
        var u = run(&t, [usage(root)])
        for i in 1..<6 { u = run(&t, [usage(root)], now: Double(i * 10)) }
        #expect(u.live[0].isActive == false)
        #expect(u.idleCount == 1 && u.activeCount == 0)
        for i in 6..<12 { u = run(&t, [usage(root, cpu: 0.5)], now: Double(i * 10)) }
        #expect(u.live[0].isActive)
        #expect(u.activeCount == 1)
    }

    @Test func buildChildMakesActive() {
        var t = AgentTracker(activeCoreFraction: 0.05)
        let root = id(10, 1, "claude"), build = id(11, 10, "go")
        let u = run(&t, [usage(root), usage(build)], groups: [build.key: .goBuilds, root.key: .agents])
        #expect(u.live[0].isActive)
    }

    @Test func endsOnExit() {
        var t = AgentTracker(activeCoreFraction: 0.05)
        let root = id(10, 1, "claude")
        _ = run(&t, [usage(root)])
        let u = run(&t, [])
        #expect(u.ended == [root.key])
        #expect(u.live.isEmpty)
    }

    @Test func pidReuseIsNewRun() {
        var t = AgentTracker(activeCoreFraction: 0.05)
        let a = id(10, 1, "claude", start: 100), b = id(10, 1, "claude", start: 200)
        _ = run(&t, [usage(a)], now: 1)
        let u = run(&t, [usage(b)], now: 2)
        #expect(u.ended == [a.key])
        #expect(u.started.map(\.root) == [b.key])
        #expect(u.started[0].started == 2)
    }

    @Test func treeUsageSums() {
        var t = AgentTracker(activeCoreFraction: 0.05)
        let root = id(10, 1, "claude"), child = id(11, 10, "sh"), grand = id(12, 11, "node"), other = id(30, 1, "sh")
        let u = run(&t, [
            usage(root, cpu: 1, footprint: 100, write: 10), usage(child, cpu: 2, footprint: 200, write: 20),
            usage(grand, cpu: 3, footprint: 300, write: 30), usage(other, cpu: 50, footprint: 999, write: 99),
        ])
        #expect(u.live[0].cpuSeconds == 6)
        #expect(u.live[0].footprint == 600)
        #expect(u.live[0].diskWriteBytes == 60)
    }

    @Test func missingParentAndCycleTerminate() {
        var t = AgentTracker(activeCoreFraction: 0.05)
        let orphan = id(10, 999, "claude"), c1 = id(20, 21, "sh"), c2 = id(21, 20, "sh")
        let u = run(&t, [usage(orphan), usage(c1), usage(c2)])
        #expect(u.live.map(\.root) == [orphan.key])
    }

    @Test func realClassifierIntegration() {
        var t = AgentTracker(activeCoreFraction: 0.05)
        let classifier = Classifier(rules: .defaults, currentUID: 501)
        let root = id(10, 1, "claude"), inner = id(11, 10, "claude")
        let u = t.update(processes: [usage(root), usage(inner)], groups: classifier.classify([root, inner]), ownGroup: classifier.ownGroup, now: 0)
        #expect(u.live.count == 1)
    }
}

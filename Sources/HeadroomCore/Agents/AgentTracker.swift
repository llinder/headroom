import Foundation

public enum AgentTool: String, Codable, Sendable {
    case claude, codex
}

public struct AgentRun: Sendable, Equatable {
    public var root: ProcessKey
    public var tool: AgentTool
    public var started: Double
    public var isActive: Bool
    public var cpuSeconds: Double
    public var footprint: UInt64
    public var diskWriteBytes: UInt64

    public init(root: ProcessKey, tool: AgentTool, started: Double, isActive: Bool, cpuSeconds: Double, footprint: UInt64, diskWriteBytes: UInt64) {
        self.root = root
        self.tool = tool
        self.started = started
        self.isActive = isActive
        self.cpuSeconds = cpuSeconds
        self.footprint = footprint
        self.diskWriteBytes = diskWriteBytes
    }
}

public struct AgentUpdate: Sendable {
    public var started: [AgentRun]
    public var ended: [ProcessKey]
    public var live: [AgentRun]
    public var activeCount: Int
    public var idleCount: Int

    public init(started: [AgentRun], ended: [ProcessKey], live: [AgentRun], activeCount: Int, idleCount: Int) {
        self.started = started
        self.ended = ended
        self.live = live
        self.activeCount = activeCount
        self.idleCount = idleCount
    }
}

public struct AgentTracker {
    private static let ringSize = 6

    private struct RunState {
        var tool: AgentTool
        var started: Double
        var ring: [Double] = []
    }

    private struct TreeUsage {
        var cpu = 0.0
        var footprint: UInt64 = 0
        var write: UInt64 = 0
        var hasNonAgent = false
    }

    private let activeCoreFraction: Double
    private let sampleInterval: Double
    private var runs: [ProcessKey: RunState] = [:]

    public init(activeCoreFraction: Double, sampleInterval: Double = 10) {
        self.activeCoreFraction = activeCoreFraction
        self.sampleInterval = sampleInterval
    }

    public mutating func update(
        processes: [ProcessUsage],
        groups: [ProcessKey: WorkloadGroup],
        ownGroup: (ProcessIdentity) -> WorkloadGroup?,
        now: Double
    ) -> AgentUpdate {
        var byPid: [Int32: ProcessUsage] = [:]
        var isAgent: [Int32: Bool] = [:]
        for p in processes {
            byPid[p.identity.key.pid] = p
            isAgent[p.identity.key.pid] = ownGroup(p.identity) == .agents
        }

        // Memoizes both outcomes (a root, or no root above) so the sweep stays O(n).
        var rootOf: [Int32: ProcessKey?] = [:]
        func resolve(_ start: Int32) -> ProcessKey? {
            var path: [Int32] = []
            var visited: Set<Int32> = []
            var cursor = start
            var known: ProcessKey?
            while true {
                if let memo = rootOf[cursor] {
                    known = memo
                    break
                }
                guard let proc = byPid[cursor], visited.insert(cursor).inserted else { break }
                path.append(cursor)
                let parent = proc.identity.ppid
                guard byPid[parent] != nil else { break }
                cursor = parent
            }
            // Topmost agent on the path is the root; everything below it belongs to it.
            var current = known
            for pid in path.reversed() {
                if current == nil, isAgent[pid] == true { current = byPid[pid]?.identity.key }
                rootOf[pid] = .some(current)
            }
            return current
        }

        var usage: [ProcessKey: TreeUsage] = [:]
        var rootIdentities: [ProcessKey: ProcessIdentity] = [:]
        for p in processes {
            guard let root = resolve(p.identity.key.pid) else { continue }
            if root == p.identity.key { rootIdentities[root] = p.identity }
            var u = usage[root] ?? TreeUsage()
            u.cpu += p.cpuSeconds
            u.footprint += p.footprint
            u.write += p.diskWriteBytes
            if let g = groups[p.identity.key], g != .agents { u.hasNonAgent = true }
            usage[root] = u
        }

        let ended = runs.keys.filter { rootIdentities[$0] == nil }
        for key in ended { runs[key] = nil }

        var newKeys: Set<ProcessKey> = []
        for (key, identity) in rootIdentities where runs[key] == nil {
            runs[key] = RunState(tool: Self.tool(of: identity), started: now)
            newKeys.insert(key)
        }

        // Window first, then fraction: 0.05 * (6 * 10) is exactly 3.0, where (0.05 * 6) * 10 rounds above it.
        let threshold = activeCoreFraction * (Double(Self.ringSize) * sampleInterval)
        var live: [AgentRun] = []
        for (key, state) in runs {
            guard let u = usage[key] else { continue }
            var ring = state.ring
            ring.append(u.cpu)
            if ring.count > Self.ringSize { ring.removeFirst(ring.count - Self.ringSize) }
            runs[key]?.ring = ring
            live.append(AgentRun(
                root: key, tool: state.tool, started: state.started,
                isActive: u.hasNonAgent || ring.reduce(0, +) >= threshold,
                cpuSeconds: u.cpu, footprint: u.footprint, diskWriteBytes: u.write))
        }
        live.sort { ($0.started, $0.root.pid) < ($1.started, $1.root.pid) }

        let active = live.filter(\.isActive).count
        return AgentUpdate(
            started: live.filter { newKeys.contains($0.root) }, ended: ended,
            live: live, activeCount: active, idleCount: live.count - active)
    }

    private static func tool(of identity: ProcessIdentity) -> AgentTool {
        let last = identity.path.split(separator: "/").last.map(String.init) ?? ""
        if last == "codex" || identity.name == "codex" || identity.path.contains("/@openai/codex") { return .codex }
        return .claude
    }
}

import Foundation

/// One recorder tick's sampling work: every sampler, classification, agent tracking and limits, as one value
/// so the recorder and the footprint benchmark run exactly the same code.
public struct SamplingPipeline {
    private let classifier: Classifier
    private let limits: LimitConfig
    private let logicalCores: Int
    private var cpu = CPUSampler()
    private var memory = MemorySampler()
    private var disk = DiskSampler()
    private var processes = ProcessSampler()
    private var agents: AgentTracker
    // A process's own group depends only on its identity, which is fixed per key, so it is matched once.
    private var ownGroups: [ProcessKey: WorkloadGroup?] = [:]

    public init(
        classifier: Classifier, config: HeadroomConfig,
        logicalCores: Int = ProcessInfo.processInfo.activeProcessorCount, interval: Double = 10
    ) {
        self.classifier = classifier
        self.limits = config.limits
        self.logicalCores = logicalCores
        self.agents = AgentTracker(activeCoreFraction: config.agentActiveCoreFraction, sampleInterval: interval)
    }

    /// Moves every counter baseline to now and drops the deltas, so an interval that shouldn't count as
    /// activity (the machine was asleep) never reaches a tick or an agent run's activity window.
    public mutating func discard() {
        _ = cpu.sample(interval: 0)
        _ = memory.sample()
        _ = disk.sample(refreshSpace: false)
        _ = processes.sweep()
        agents.resetActivity()
    }

    /// The tick is nil when CPU, memory or disk can't be read, which for CPU includes the first call. Every sampler
    /// and the agent tracker still advance on such a tick, so the next tick's deltas stay continuous, and the agent
    /// update is returned either way: the tracker has dropped the runs it reports ended.
    public mutating func sample(
        now: Double, interval: Double, refreshSpace: Bool, thermal: ThermalLevel
    ) -> (tick: Tick?, agents: AgentUpdate) {
        let cpuReading = cpu.sample(interval: interval)
        let memoryReading = memory.sample()
        let diskReading = disk.sample(refreshSpace: refreshSpace)
        let procs = processes.sweep()
        let groups = classify(procs)
        // Every inherited .agents process has an own-rule agent above it in the same tree, so the topmost
        // .agents process on any path, which is what the tracker roots on, is the same as with own groups.
        let agentUpdate = agents.update(
            processes: procs, groups: groups, ownGroup: { groups[$0.key] == .agents ? .agents : nil }, now: now)
        guard let cpuReading, let memoryReading, let diskReading else { return (nil, agentUpdate) }

        let top = TickAggregation.top(processes: procs, groups: groups)
        let tick = Tick(
            ts: now, cpu: cpuReading, memory: memoryReading, disk: diskReading, thermal: thermal,
            flags: LimitEvaluator.evaluate(
                cpu: cpuReading, memory: memoryReading, thermal: thermal, logicalCores: logicalCores, config: limits),
            groups: TickAggregation.groupTotals(processes: procs, groups: groups, busySeconds: cpuReading.busySeconds),
            topByCPU: top.byCPU, topByMemory: top.byMemory, agents: agentUpdate, selfCPU: 0, selfFootprint: 0,
            battery: BatterySampler.read())
        return (tick, agentUpdate)
    }

    private mutating func classify(_ procs: [ProcessUsage]) -> [ProcessKey: WorkloadGroup] {
        var next: [ProcessKey: WorkloadGroup?] = [:]
        next.reserveCapacity(procs.count)
        for p in procs {
            // updateValue, because assigning a nil group through the subscript would remove the key.
            next.updateValue(ownGroups[p.identity.key] ?? classifier.ownGroup(p.identity), forKey: p.identity.key)
        }
        ownGroups = next
        return classifier.classify(procs.map(\.identity)) { next[$0.key] ?? nil }
    }
}

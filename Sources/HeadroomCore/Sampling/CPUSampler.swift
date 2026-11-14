import Darwin

public struct CoreTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public struct CPUReading: Sendable, Equatable {
    public var user: Double
    public var system: Double
    public var idle: Double
    public var perCoreBusy: [Double]
    public var load1: Double
    public var load5: Double
    public var load15: Double
    public var busySeconds: Double

    public init(
        user: Double, system: Double, idle: Double, perCoreBusy: [Double],
        load1: Double, load5: Double, load15: Double, busySeconds: Double
    ) {
        self.user = user
        self.system = system
        self.idle = idle
        self.perCoreBusy = perCoreBusy
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.busySeconds = busySeconds
    }
}

public struct CPUSampler {
    private var previous: [CoreTicks]?

    public init() {}

    public mutating func sample(interval: Double) -> CPUReading? {
        guard let current = Self.readTicks() else { return nil }
        defer { previous = current }
        guard let previous, previous.count == current.count else { return nil }
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) != 3 { loads = [0, 0, 0] }
        return Self.reading(previous: previous, current: current, interval: interval, load: (loads[0], loads[1], loads[2]))
    }

    public static func reading(
        previous: [CoreTicks], current: [CoreTicks], interval: Double, load: (Double, Double, Double)
    ) -> CPUReading {
        var userTicks = 0.0
        var systemTicks = 0.0
        var totalTicks = 0.0
        var perCoreBusy = [Double]()
        perCoreBusy.reserveCapacity(current.count)
        for (before, after) in zip(previous, current) {
            let user = Double(counterDelta(before.user, after.user) + counterDelta(before.nice, after.nice))
            let system = Double(counterDelta(before.system, after.system))
            let idle = Double(counterDelta(before.idle, after.idle))
            let total = user + system + idle
            userTicks += user
            systemTicks += system
            totalTicks += total
            perCoreBusy.append(total > 0 ? (user + system) / total : 0)
        }
        let userFraction = totalTicks > 0 ? userTicks / totalTicks : 0
        let systemFraction = totalTicks > 0 ? systemTicks / totalTicks : 0
        return CPUReading(
            user: userFraction,
            system: systemFraction,
            idle: max(0, min(1, 1 - userFraction - systemFraction)),
            perCoreBusy: perCoreBusy,
            load1: load.0,
            load5: load.1,
            load15: load.2,
            busySeconds: perCoreBusy.reduce(0, +) * interval
        )
    }

    private static func readTicks() -> [CoreTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let host = mach_host_self()
        // mach_host_self() adds a send-right reference on each call; a copyable struct can't own one, so release per call.
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard status == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(cpuCount) * stride else { return nil }
        return (0..<Int(cpuCount)).map { core in
            let base = core * stride
            return CoreTicks(
                user: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])),
                system: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])),
                idle: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])),
                nice: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
    }
}

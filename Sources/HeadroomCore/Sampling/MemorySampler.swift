import Darwin
import Foundation

public enum PressureLevel: Int, Sendable {
    case normal = 1
    case warn = 2
    case critical = 4
}

public struct VMCounters: Sendable, Equatable {
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var purgeable: UInt64
    public var external: UInt64
    public var internalPages: UInt64
    public var swapins: UInt64
    public var swapouts: UInt64
    public var pageins: UInt64
    public var pageouts: UInt64

    public init(
        free: UInt64, active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64, purgeable: UInt64,
        external: UInt64, internalPages: UInt64, swapins: UInt64, swapouts: UInt64, pageins: UInt64,
        pageouts: UInt64
    ) {
        self.free = free
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.compressed = compressed
        self.purgeable = purgeable
        self.external = external
        self.internalPages = internalPages
        self.swapins = swapins
        self.swapouts = swapouts
        self.pageins = pageins
        self.pageouts = pageouts
    }
}

public struct MemoryReading: Sendable, Equatable {
    public var total: UInt64
    public var used: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var free: UInt64
    public var fileBacked: UInt64
    public var pressure: PressureLevel
    public var memorystatusLevel: Int?
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var swapins: UInt64
    public var swapouts: UInt64
    public var pageins: UInt64
    public var pageouts: UInt64

    public init(
        total: UInt64, used: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, free: UInt64,
        fileBacked: UInt64, pressure: PressureLevel, memorystatusLevel: Int?, swapUsed: UInt64,
        swapTotal: UInt64, swapins: UInt64, swapouts: UInt64, pageins: UInt64, pageouts: UInt64
    ) {
        self.total = total
        self.used = used
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.free = free
        self.fileBacked = fileBacked
        self.pressure = pressure
        self.memorystatusLevel = memorystatusLevel
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.swapins = swapins
        self.swapouts = swapouts
        self.pageins = pageins
        self.pageouts = pageouts
    }
}

public struct MemorySampler {
    private var previous: VMCounters?

    public init() {}

    public mutating func sample() -> MemoryReading {
        let counters = Self.readCounters()
        defer { previous = counters }
        let swap = Self.readSwap()
        let level = Self.sysctlInt32("kern.memorystatus_level")
        return Self.reading(
            previous: previous,
            current: counters ?? Self.emptyCounters,
            pageSize: Self.kernelPageSize(),
            total: ProcessInfo.processInfo.physicalMemory,
            pressure: Self.sysctlInt32("kern.memorystatus_vm_pressure_level")
                .flatMap { PressureLevel(rawValue: Int($0)) } ?? .normal,
            memorystatusLevel: level.map(Int.init),
            swapUsed: swap.used,
            swapTotal: swap.total)
    }

    /// App = (internal − purgeable) pages; used = app + wired + compressed, matching Activity Monitor.
    public static func reading(
        previous: VMCounters?, current: VMCounters, pageSize: UInt64, total: UInt64, pressure: PressureLevel,
        memorystatusLevel: Int?, swapUsed: UInt64, swapTotal: UInt64
    ) -> MemoryReading {
        let app = (current.internalPages &- min(current.purgeable, current.internalPages)) * pageSize
        let wired = current.wired * pageSize
        let compressed = current.compressed * pageSize
        func delta(_ keyPath: KeyPath<VMCounters, UInt64>) -> UInt64 {
            guard let previous else { return 0 }
            return counterDelta(previous[keyPath: keyPath], current[keyPath: keyPath])
        }
        return MemoryReading(
            total: total,
            used: app + wired + compressed,
            app: app,
            wired: wired,
            compressed: compressed,
            free: current.free * pageSize,
            fileBacked: current.external * pageSize,
            pressure: pressure,
            memorystatusLevel: memorystatusLevel,
            swapUsed: swapUsed,
            swapTotal: swapTotal,
            swapins: delta(\.swapins),
            swapouts: delta(\.swapouts),
            pageins: delta(\.pageins),
            pageouts: delta(\.pageouts))
    }

    private static let emptyCounters = VMCounters(
        free: 0, active: 0, inactive: 0, wired: 0, compressed: 0, purgeable: 0, external: 0,
        internalPages: 0, swapins: 0, swapouts: 0, pageins: 0, pageouts: 0)

    private static func readCounters() -> VMCounters? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        // mach_host_self() adds a send-right reference on each call, so release it on every path.
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return VMCounters(
            free: UInt64(stats.free_count),
            active: UInt64(stats.active_count),
            inactive: UInt64(stats.inactive_count),
            wired: UInt64(stats.wire_count),
            compressed: UInt64(stats.compressor_page_count),
            purgeable: UInt64(stats.purgeable_count),
            external: UInt64(stats.external_page_count),
            internalPages: UInt64(stats.internal_page_count),
            swapins: stats.swapins,
            swapouts: stats.swapouts,
            pageins: stats.pageins,
            pageouts: stats.pageouts)
    }

    // vm_kernel_page_size is a mutable C global, which Swift 6 rejects; host_page_size reports the same value.
    private static func kernelPageSize() -> UInt64 {
        var size: vm_size_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard host_page_size(host, &size) == KERN_SUCCESS, size > 0 else { return 16384 }
        return UInt64(size)
    }

    private static func readSwap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

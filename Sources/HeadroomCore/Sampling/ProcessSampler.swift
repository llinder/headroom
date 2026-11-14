import Darwin
import Foundation

public struct ProcessKey: Hashable, Sendable {
    public var pid: Int32
    /// Microseconds since the epoch; with the pid it survives pid reuse.
    public var start: UInt64

    public init(pid: Int32, start: UInt64) {
        self.pid = pid
        self.start = start
    }
}

public struct ProcessIdentity: Sendable, Equatable {
    public var key: ProcessKey
    public var ppid: Int32
    public var uid: UInt32
    public var name: String
    public var path: String

    public init(key: ProcessKey, ppid: Int32, uid: UInt32, name: String, path: String) {
        self.key = key
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.path = path
    }
}

public struct ProcessUsage: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var cpuSeconds: Double
    public var footprint: UInt64
    public var diskReadBytes: UInt64
    public var diskWriteBytes: UInt64
    /// False when the kernel refused rusage (EPERM); usage fields are then zero.
    public var attributed: Bool

    public init(
        identity: ProcessIdentity, cpuSeconds: Double, footprint: UInt64, diskReadBytes: UInt64,
        diskWriteBytes: UInt64, attributed: Bool
    ) {
        self.identity = identity
        self.cpuSeconds = cpuSeconds
        self.footprint = footprint
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.attributed = attributed
    }
}

public struct ProcessSampler {
    struct Totals: Equatable {
        var cpu: Double
        var diskRead: UInt64
        var diskWrite: UInt64
    }

    private let timebase: mach_timebase_info_data_t
    private var pids = [Int32](repeating: 0, count: 1024)
    // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) isn't imported into Swift.
    private var pathBuffer = [UInt8](repeating: 0, count: 4096)
    private var nameBuffer = [UInt8](repeating: 0, count: 256)
    private var previous: [ProcessKey: Totals] = [:]
    private var identities: [ProcessKey: ProcessIdentity] = [:]

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info
    }

    /// The `Ns` parameter names are historical: the inputs are Mach absolute ticks, scaled by the timebase.
    public static func cpuSeconds(userNs: UInt64, systemNs: UInt64, timebase: mach_timebase_info_data_t) -> Double {
        guard timebase.denom != 0 else { return 0 }
        let ticks = Double(userNs) + Double(systemNs)
        return ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// A key not seen before has no baseline, so its first sweep reports zero rather than lifetime CPU.
    static func delta(previous: [ProcessKey: Totals], key: ProcessKey, total: Double) -> Double {
        guard let prior = previous[key] else { return 0 }
        return total >= prior.cpu ? total - prior.cpu : 0
    }

    public mutating func sweep() -> [ProcessUsage] {
        let count = listPids()
        var usages: [ProcessUsage] = []
        usages.reserveCapacity(count)
        var nextPrevious: [ProcessKey: Totals] = [:]
        nextPrevious.reserveCapacity(count)
        var nextIdentities: [ProcessKey: ProcessIdentity] = [:]
        nextIdentities.reserveCapacity(count)

        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0, let bsd = Self.bsdInfo(pid) else { continue }
            let key = Self.key(pid: pid, bsd: bsd)
            // PROC_PIDTBSDINFO is needed every sweep to build the key, so the cache only spares the path and
            // name lookups; that still avoids two syscalls per process per sweep.
            let identity = identities[key] ?? makeIdentity(key: key, bsd: bsd)
            nextIdentities[key] = identity

            let rusage: rusage_info_v6
            switch readRusage(pid) {
            case .gone:
                nextIdentities[key] = nil
                continue
            case .denied:
                usages.append(
                    ProcessUsage(
                        identity: identity, cpuSeconds: 0, footprint: 0, diskReadBytes: 0, diskWriteBytes: 0,
                        attributed: false))
                continue
            case .ok(let info):
                rusage = info
            }
            let total = Self.cpuSeconds(
                userNs: rusage.ri_user_time, systemNs: rusage.ri_system_time, timebase: timebase)
            let prior = previous[key]
            usages.append(
                ProcessUsage(
                    identity: identity,
                    cpuSeconds: Self.delta(previous: previous, key: key, total: total),
                    footprint: rusage.ri_phys_footprint,
                    diskReadBytes: prior.map { counterDelta($0.diskRead, rusage.ri_diskio_bytesread) } ?? 0,
                    diskWriteBytes: prior.map { counterDelta($0.diskWrite, rusage.ri_diskio_byteswritten) } ?? 0,
                    attributed: true))
            nextPrevious[key] = Totals(
                cpu: total, diskRead: rusage.ri_diskio_bytesread, diskWrite: rusage.ri_diskio_byteswritten)
        }
        previous = nextPrevious
        identities = nextIdentities
        return usages
    }

    /// Returns the number of valid entries in `pids`, growing the buffer until the list fits.
    private mutating func listPids() -> Int {
        while true {
            let bytes = Int32(pids.count * MemoryLayout<Int32>.stride)
            let count = Int(pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) })
            guard count > 0 else { return 0 }
            // A full buffer may have truncated the list.
            if count < pids.count { return count }
            pids = [Int32](repeating: 0, count: pids.count * 2)
        }
    }

    /// Nil when the process exited mid-sweep or can't be inspected (ESRCH, EPERM); either way it can't be keyed.
    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return written == size ? info : nil
    }

    private static func key(pid: Int32, bsd: proc_bsdinfo) -> ProcessKey {
        ProcessKey(pid: pid, start: bsd.pbi_start_tvsec &* 1_000_000 &+ bsd.pbi_start_tvusec)
    }

    private mutating func makeIdentity(key: ProcessKey, bsd: proc_bsdinfo) -> ProcessIdentity {
        Self.makeIdentity(key: key, bsd: bsd, pathBuffer: &pathBuffer, nameBuffer: &nameBuffer)
    }

    private static func makeIdentity(
        key: ProcessKey, bsd: proc_bsdinfo, pathBuffer: inout [UInt8], nameBuffer: inout [UInt8]
    ) -> ProcessIdentity {
        let pathLength = proc_pidpath(key.pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(decoding: pathBuffer[..<Int(pathLength)], as: UTF8.self) : ""
        let nameLength = proc_name(key.pid, &nameBuffer, UInt32(nameBuffer.count))
        var name = nameLength > 0 ? String(decoding: nameBuffer[..<Int(nameLength)], as: UTF8.self) : ""
        if name.isEmpty { name = (path as NSString).lastPathComponent }
        if name.isEmpty { name = "pid \(key.pid)" }
        return ProcessIdentity(key: key, ppid: Int32(bitPattern: bsd.pbi_ppid), uid: bsd.pbi_uid, name: name, path: path)
    }

    /// One-off lookup for short-lived callers such as hooks; nil when the process is gone or off limits.
    public static func identity(pid: Int32) -> ProcessIdentity? {
        guard pid > 0, let bsd = bsdInfo(pid) else { return nil }
        var pathBuffer = [UInt8](repeating: 0, count: 4096)
        var nameBuffer = [UInt8](repeating: 0, count: 256)
        return makeIdentity(key: key(pid: pid, bsd: bsd), bsd: bsd, pathBuffer: &pathBuffer, nameBuffer: &nameBuffer)
    }

    private enum RusageResult {
        case ok(rusage_info_v6)
        /// EPERM: the process is real but off limits, so it is reported unattributed.
        case denied
        /// ESRCH or any other failure: treated as exited mid-sweep.
        case gone
    }

    private func readRusage(_ pid: Int32) -> RusageResult {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        if status == 0 { return .ok(info) }
        return errno == EPERM ? .denied : .gone
    }

    func isTracked(_ key: ProcessKey) -> Bool {
        identities[key] != nil
    }
}

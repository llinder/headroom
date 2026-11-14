import CryptoKit
import Darwin
import Foundation
import IOKit

public struct MachineInfo: Sendable, Equatable, Codable {
    public var model: String
    /// Display only; schema v1 has no column for it.
    public var chip: String
    public var serialHash: String
    public var perfCores: Int
    public var effCores: Int
    public var ramBytes: UInt64
    public var diskBytes: UInt64

    /// Computed once from the raw serial, which is never kept, so it is stored instead of derived.
    public var machineId: String

    public static func current() -> MachineInfo {
        let model = sysctlString("hw.model") ?? "unknown"
        let serial = platformSerial() ?? ""
        let perf = sysctlInt("hw.perflevel0.logicalcpu") ?? ProcessInfo.processInfo.processorCount
        let eff = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        return MachineInfo(
            model: model, chip: sysctlString("machdep.cpu.brand_string") ?? "",
            serialHash: sha256Hex(serial), perfCores: perf, effCores: eff,
            ramBytes: ProcessInfo.processInfo.physicalMemory, diskBytes: dataVolumeCapacity(),
            machineId: String(sha256Hex(model + ":" + serial).prefix(16)))
    }

    public func register(in db: Database, now: Date) throws {
        let ts = Int64(now.timeIntervalSince1970)
        let stmt = try db.prepare(
            """
            INSERT INTO machines(machine_id, model, serial_hash, perf_cores, eff_cores, ram_bytes, disk_bytes,
                                 first_seen, last_seen)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(machine_id) DO UPDATE SET
                last_seen = excluded.last_seen, model = excluded.model, ram_bytes = excluded.ram_bytes,
                disk_bytes = excluded.disk_bytes, perf_cores = excluded.perf_cores, eff_cores = excluded.eff_cores
            """)
        stmt.bind(1, machineId)
        stmt.bind(2, model)
        stmt.bind(3, serialHash)
        stmt.bind(4, Int64(perfCores))
        stmt.bind(5, Int64(effCores))
        stmt.bind(6, Int64(clamping: ramBytes))
        stmt.bind(7, Int64(clamping: diskBytes))
        stmt.bind(8, ts)
        stmt.bind(9, ts)
        _ = try stmt.step()
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func platformSerial() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)
        return property?.takeRetainedValue() as? String
    }

    private static func dataVolumeCapacity() -> UInt64 {
        var stats = statfs()
        guard statfs("/System/Volumes/Data", &stats) == 0 else { return 0 }
        return UInt64(stats.f_blocks) * UInt64(stats.f_bsize)
    }
}

import Darwin
import Foundation
import IOKit

public struct DiskReading: Sendable, Equatable {
    public var capacity: UInt64
    public var free: UInt64
    public var availableImportant: UInt64
    public var readBytes: UInt64
    public var writeBytes: UInt64
    public var readOps: UInt64
    public var writeOps: UInt64

    public init(
        capacity: UInt64, free: UInt64, availableImportant: UInt64, readBytes: UInt64, writeBytes: UInt64,
        readOps: UInt64, writeOps: UInt64
    ) {
        self.capacity = capacity
        self.free = free
        self.availableImportant = availableImportant
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.readOps = readOps
        self.writeOps = writeOps
    }
}

struct DiskIOTotals: Sendable, Equatable {
    var readBytes: UInt64
    var writeBytes: UInt64
    var readOps: UInt64
    var writeOps: UInt64
}

struct DiskSpace: Sendable, Equatable {
    var capacity: UInt64
    var free: UInt64
    var availableImportant: UInt64
}

public struct DiskSampler {
    private static let dataVolume = "/System/Volumes/Data"

    private var previous: DiskIOTotals?
    private var space: DiskSpace?

    public init() {}

    /// Nil when the I/O totals can't be read, or when space can't be read and none was ever read before.
    public mutating func sample(refreshSpace: Bool) -> DiskReading? {
        let freshSpace = refreshSpace || space == nil ? Self.readSpace() : nil
        return record(totals: Self.ioTotals(), space: freshSpace)
    }

    // Split from sample() so the failure paths are testable without the kernel; a failed I/O read clears
    // `previous` so the next good sample reports zero deltas instead of a spike. `space` is nil when no
    // refresh was attempted or the refresh failed, in which case the last good values carry over.
    mutating func record(totals: DiskIOTotals?, space freshSpace: DiskSpace?) -> DiskReading? {
        guard let totals else {
            previous = nil
            return nil
        }
        let before = previous
        previous = totals
        if let freshSpace { space = freshSpace }
        guard let space else { return nil }
        func delta(_ keyPath: KeyPath<DiskIOTotals, UInt64>) -> UInt64 {
            guard let before else { return 0 }
            return counterDelta(before[keyPath: keyPath], totals[keyPath: keyPath])
        }
        return DiskReading(
            capacity: space.capacity, free: space.free, availableImportant: space.availableImportant,
            readBytes: delta(\.readBytes), writeBytes: delta(\.writeBytes),
            readOps: delta(\.readOps), writeOps: delta(\.writeOps))
    }

    private static func readSpace() -> DiskSpace? {
        var stats = statfs()
        guard statfs(dataVolume, &stats) == 0 else { return nil }
        let blockSize = UInt64(stats.f_bsize)
        let capacity = UInt64(stats.f_blocks) * blockSize
        let free = UInt64(stats.f_bavail) * blockSize
        let important = try? URL(filePath: dataVolume)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        return DiskSpace(
            capacity: capacity, free: free, availableImportant: important.map { UInt64(max($0, 0)) } ?? free)
    }

    /// Sums the counters of the internal `IOBlockStorageDriver`s only, so USB/Thunderbolt drives and disk images
    /// don't count as SSD writes. Nil when none can be enumerated or none is internal with statistics.
    static func ioTotals() -> DiskIOTotals? {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
                == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var totals = DiskIOTotals(readBytes: 0, writeBytes: 0, readOps: 0, writeOps: 0)
        var internalDrives = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard isInternal(service),
                let property = IORegistryEntryCreateCFProperty(
                    service, "Statistics" as CFString, kCFAllocatorDefault, 0),
                let statistics = property.takeRetainedValue() as? [String: Any]
            else { continue }
            internalDrives += 1
            func value(_ key: String) -> UInt64 { (statistics[key] as? NSNumber)?.uint64Value ?? 0 }
            totals.readBytes &+= value("Bytes (Read)")
            totals.writeBytes &+= value("Bytes (Write)")
            totals.readOps &+= value("Operations (Read)")
            totals.writeOps &+= value("Operations (Write)")
        }
        return internalDrives > 0 ? totals : nil
    }

    // The interconnect location lives on a parent of the driver, not on the driver itself. Swift imports the
    // search result as managed (CF_RETURNS_RETAINED), so ARC releases it; no takeRetainedValue() here.
    private static func isInternal(_ service: io_object_t) -> Bool {
        guard
            let property = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "Protocol Characteristics" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)),
            let characteristics = property as? [String: Any]
        else { return false }
        return characteristics["Physical Interconnect Location"] as? String == "Internal"
    }
}

import Foundation

public struct LiveSnapshot: Sendable, Equatable {
    public var timestamp: Double
    public var cpuBusy: Float
    public var memUsed: UInt64
    public var memTotal: UInt64
    public var swapUsed: UInt64
    public var diskFree: UInt64
    public var diskCapacity: UInt64
    public var pressure: UInt8
    public var thermal: UInt8
    public var limitFlags: UInt8
    public var activeAgents: UInt16
    public var idleAgents: UInt16
    public var leftoverCount: UInt16
    public var leftoverBytes: UInt64
    public var swapGrowthBytesPerMin: Int64
    /// Nil on a Mac without a battery, and in a file written by a recorder from before batteries were recorded.
    public var battery: BatteryReading?

    public init(
        timestamp: Double, cpuBusy: Float,
        memUsed: UInt64, memTotal: UInt64, swapUsed: UInt64,
        diskFree: UInt64, diskCapacity: UInt64,
        pressure: UInt8, thermal: UInt8, limitFlags: UInt8,
        activeAgents: UInt16, idleAgents: UInt16,
        leftoverCount: UInt16 = 0, leftoverBytes: UInt64 = 0, swapGrowthBytesPerMin: Int64 = 0,
        battery: BatteryReading? = nil
    ) {
        self.timestamp = timestamp
        self.cpuBusy = cpuBusy
        self.memUsed = memUsed
        self.memTotal = memTotal
        self.swapUsed = swapUsed
        self.diskFree = diskFree
        self.diskCapacity = diskCapacity
        self.pressure = pressure
        self.thermal = thermal
        self.limitFlags = limitFlags
        self.activeAgents = activeAgents
        self.idleAgents = idleAgents
        self.leftoverCount = leftoverCount
        self.leftoverBytes = leftoverBytes
        self.swapGrowthBytesPerMin = swapGrowthBytesPerMin
        self.battery = battery
    }
}

// Shared by writer and reader so the two can't disagree on the layout. New fields go in bytes every
// earlier writer left zero, with zero meaning absent, and the version stays 1: a reader from either side of
// an upgrade then reads the other's file, where a version bump would make the older one print
// "headroom: off" until both binaries match.
private enum Layout {
    static let size = 128
    static let magic: [UInt8] = Array("HDRM".utf8)
    static let version: UInt32 = 1
    static let versionOffset = 4
    static let seqBegin = 8
    static let timestamp = 16
    static let cpuBusy = 24
    static let pressure = 28
    static let thermal = 29
    static let limitFlags = 30
    static let memUsed = 32
    static let memTotal = 40
    static let swapUsed = 48
    static let diskFree = 56
    static let diskCapacity = 64
    static let activeAgents = 72
    static let idleAgents = 74
    static let leftoverCount = 76
    static let leftoverBytes = 80
    static let swapGrowth = 88
    static let batteryPercent = 96
    static let batteryFlags = 97
    static let seqEnd = 120
}

// The present bit is what tells "no battery" (or an older writer) from a flat battery at 0%.
private enum BatteryFlags {
    static let present: UInt8 = 1
    static let charging: UInt8 = 2
    static let onAC: UInt8 = 4
}

// Each write builds the record off to the side and renames it into place. Rename is
// atomic, so a reader's single pread always sees one whole record; deletion or
// replacement of the file self-heals on the next write; and with no mapping there is
// no SIGBUS when something truncates the file.
public struct LiveStateWriter: Sendable {
    private let url: URL
    private let tmpURL: URL
    private var seq: UInt64 = 0

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url
        self.tmpURL = url.appendingPathExtension("tmp")
    }

    @discardableResult
    public mutating func write(_ s: LiveSnapshot) -> Bool {
        seq &+= 1
        if seq == 0 { seq = 1 }
        var buf = [UInt8](repeating: 0, count: Layout.size)
        buf.withUnsafeMutableBytes { base in
            for (i, byte) in Layout.magic.enumerated() { base[i] = byte }
            base.storeBytes(of: Layout.version.littleEndian, toByteOffset: Layout.versionOffset, as: UInt32.self)
            base.storeBytes(of: seq.littleEndian, toByteOffset: Layout.seqBegin, as: UInt64.self)
            base.storeBytes(of: s.timestamp.bitPattern.littleEndian, toByteOffset: Layout.timestamp, as: UInt64.self)
            base.storeBytes(of: s.cpuBusy.bitPattern.littleEndian, toByteOffset: Layout.cpuBusy, as: UInt32.self)
            base[Layout.pressure] = s.pressure
            base[Layout.thermal] = s.thermal
            base[Layout.limitFlags] = s.limitFlags
            base.storeBytes(of: s.memUsed.littleEndian, toByteOffset: Layout.memUsed, as: UInt64.self)
            base.storeBytes(of: s.memTotal.littleEndian, toByteOffset: Layout.memTotal, as: UInt64.self)
            base.storeBytes(of: s.swapUsed.littleEndian, toByteOffset: Layout.swapUsed, as: UInt64.self)
            base.storeBytes(of: s.diskFree.littleEndian, toByteOffset: Layout.diskFree, as: UInt64.self)
            base.storeBytes(of: s.diskCapacity.littleEndian, toByteOffset: Layout.diskCapacity, as: UInt64.self)
            base.storeBytes(of: s.activeAgents.littleEndian, toByteOffset: Layout.activeAgents, as: UInt16.self)
            base.storeBytes(of: s.idleAgents.littleEndian, toByteOffset: Layout.idleAgents, as: UInt16.self)
            base.storeBytes(of: s.leftoverCount.littleEndian, toByteOffset: Layout.leftoverCount, as: UInt16.self)
            base.storeBytes(of: s.leftoverBytes.littleEndian, toByteOffset: Layout.leftoverBytes, as: UInt64.self)
            base.storeBytes(of: s.swapGrowthBytesPerMin.littleEndian, toByteOffset: Layout.swapGrowth, as: Int64.self)
            if let b = s.battery {
                base[Layout.batteryPercent] = b.percent
                base[Layout.batteryFlags] = BatteryFlags.present
                    | (b.charging ? BatteryFlags.charging : 0) | (b.onAC ? BatteryFlags.onAC : 0)
            }
            base.storeBytes(of: seq.littleEndian, toByteOffset: Layout.seqEnd, as: UInt64.self)
        }
        let fd = open(tmpURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        var written = -1
        repeat {
            written = buf.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, Layout.size) }
        } while written < 0 && errno == EINTR
        close(fd)
        guard written == Layout.size else { return false }
        return rename(tmpURL.path, url.path) == 0
    }
}

public enum LiveStateReader {
    public static func read(url: URL) -> LiveSnapshot? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: Layout.size)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Layout.size, 0) }
        guard n == Layout.size else { return nil }

        return buf.withUnsafeBytes { raw -> LiveSnapshot? in
            guard raw[0] == Layout.magic[0], raw[1] == Layout.magic[1],
                  raw[2] == Layout.magic[2], raw[3] == Layout.magic[3],
                  UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.versionOffset, as: UInt32.self)) == Layout.version
            else { return nil }
            let begin = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.seqBegin, as: UInt64.self))
            let end = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.seqEnd, as: UInt64.self))
            guard begin != 0, begin == end else { return nil }
            let batteryFlags = raw[Layout.batteryFlags]
            return LiveSnapshot(
                timestamp: Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.timestamp, as: UInt64.self))),
                cpuBusy: Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.cpuBusy, as: UInt32.self))),
                memUsed: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.memUsed, as: UInt64.self)),
                memTotal: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.memTotal, as: UInt64.self)),
                swapUsed: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.swapUsed, as: UInt64.self)),
                diskFree: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.diskFree, as: UInt64.self)),
                diskCapacity: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.diskCapacity, as: UInt64.self)),
                pressure: raw[Layout.pressure],
                thermal: raw[Layout.thermal],
                limitFlags: raw[Layout.limitFlags],
                activeAgents: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.activeAgents, as: UInt16.self)),
                idleAgents: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.idleAgents, as: UInt16.self)),
                leftoverCount: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.leftoverCount, as: UInt16.self)),
                leftoverBytes: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.leftoverBytes, as: UInt64.self)),
                swapGrowthBytesPerMin: Int64(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.swapGrowth, as: Int64.self)),
                battery: batteryFlags & BatteryFlags.present == 0 ? nil : BatteryReading(
                    percent: raw[Layout.batteryPercent],
                    charging: batteryFlags & BatteryFlags.charging != 0,
                    onAC: batteryFlags & BatteryFlags.onAC != 0)
            )
        }
    }
}

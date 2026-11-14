import Foundation
import Synchronization

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

    public init(
        timestamp: Double, cpuBusy: Float,
        memUsed: UInt64, memTotal: UInt64, swapUsed: UInt64,
        diskFree: UInt64, diskCapacity: UInt64,
        pressure: UInt8, thermal: UInt8, limitFlags: UInt8,
        activeAgents: UInt16, idleAgents: UInt16
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
    }
}

// Shared by writer and reader so the two can't disagree on the layout.
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
    static let seqEnd = 120
}

public final class LiveStateWriter {
    private let fd: Int32
    private let base: UnsafeMutableRawPointer

    public init(url: URL) throws {
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard ftruncate(fd, off_t(Layout.size)) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }
        let map = mmap(nil, Layout.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let map, map != MAP_FAILED else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }
        self.fd = fd
        self.base = map
        for (i, byte) in Layout.magic.enumerated() {
            base.storeBytes(of: byte, toByteOffset: i, as: UInt8.self)
        }
        base.storeBytes(of: Layout.version.littleEndian, toByteOffset: Layout.versionOffset, as: UInt32.self)
    }

    deinit {
        munmap(base, Layout.size)
        close(fd)
    }

    public func write(_ s: LiveSnapshot) {
        let seq = base.loadUnaligned(fromByteOffset: Layout.seqBegin, as: UInt64.self).littleEndian &+ 1
        base.storeBytes(of: seq.littleEndian, toByteOffset: Layout.seqBegin, as: UInt64.self)
        atomicMemoryFence(ordering: .sequentiallyConsistent)
        base.storeBytes(of: s.timestamp.bitPattern.littleEndian, toByteOffset: Layout.timestamp, as: UInt64.self)
        base.storeBytes(of: s.cpuBusy.bitPattern.littleEndian, toByteOffset: Layout.cpuBusy, as: UInt32.self)
        base.storeBytes(of: s.pressure, toByteOffset: Layout.pressure, as: UInt8.self)
        base.storeBytes(of: s.thermal, toByteOffset: Layout.thermal, as: UInt8.self)
        base.storeBytes(of: s.limitFlags, toByteOffset: Layout.limitFlags, as: UInt8.self)
        base.storeBytes(of: s.memUsed.littleEndian, toByteOffset: Layout.memUsed, as: UInt64.self)
        base.storeBytes(of: s.memTotal.littleEndian, toByteOffset: Layout.memTotal, as: UInt64.self)
        base.storeBytes(of: s.swapUsed.littleEndian, toByteOffset: Layout.swapUsed, as: UInt64.self)
        base.storeBytes(of: s.diskFree.littleEndian, toByteOffset: Layout.diskFree, as: UInt64.self)
        base.storeBytes(of: s.diskCapacity.littleEndian, toByteOffset: Layout.diskCapacity, as: UInt64.self)
        base.storeBytes(of: s.activeAgents.littleEndian, toByteOffset: Layout.activeAgents, as: UInt16.self)
        base.storeBytes(of: s.idleAgents.littleEndian, toByteOffset: Layout.idleAgents, as: UInt16.self)
        atomicMemoryFence(ordering: .sequentiallyConsistent)
        base.storeBytes(of: seq.littleEndian, toByteOffset: Layout.seqEnd, as: UInt64.self)
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
                idleAgents: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: Layout.idleAgents, as: UInt16.self))
            )
        }
    }
}

import Foundation
import Testing
@testable import HeadroomCore

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).bin")
}

private let sample = LiveSnapshot(
    timestamp: 1_760_000_000.25, cpuBusy: 0.625,
    memUsed: 12_000_000_000, memTotal: 36_000_000_000, swapUsed: 1_234_567,
    diskFree: 400_000_000_000, diskCapacity: 994_000_000_000,
    pressure: 2, thermal: 1, limitFlags: 5, activeAgents: 3, idleAgents: 7
)

@Suite struct LiveStateTests {
    @Test func roundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var writer = try LiveStateWriter(url: url)
        writer.write(sample)
        #expect(LiveStateReader.read(url: url) == sample)
        var next = sample
        next.cpuBusy = 0.1
        next.activeAgents = 9
        writer.write(next)
        #expect(LiveStateReader.read(url: url) == next)
    }

    @Test func fileIs128BytesWithMagic() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var writer = try LiveStateWriter(url: url)
        writer.write(sample)
        let data = try Data(contentsOf: url)
        #expect(data.count == 128)
        #expect(Array(data.prefix(4)) == Array("HDRM".utf8))
    }

    @Test func missingFileNil() {
        #expect(LiveStateReader.read(url: tempURL()) == nil)
    }

    @Test func neverWrittenNil() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: 128).write(to: url)
        #expect(LiveStateReader.read(url: url) == nil)
    }

    @Test func writeReplacesForeignFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0xFF, count: 200).write(to: url)
        var writer = try LiveStateWriter(url: url)
        let ok = writer.write(sample)
        #expect(ok)
        #expect(LiveStateReader.read(url: url) == sample)
    }

    @Test func writeRecreatesDeletedFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var writer = try LiveStateWriter(url: url)
        writer.write(sample)
        try FileManager.default.removeItem(at: url)
        #expect(LiveStateReader.read(url: url) == nil)
        writer.write(sample)
        #expect(LiveStateReader.read(url: url) == sample)
    }

    @Test func badMagicRejected() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var writer = try LiveStateWriter(url: url)
        writer.write(sample)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("XXXX".utf8))
        try handle.close()
        #expect(LiveStateReader.read(url: url) == nil)
    }

    @Test func shortFileRejected() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var writer = try LiveStateWriter(url: url)
        writer.write(sample)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 64)
        try handle.close()
        #expect(LiveStateReader.read(url: url) == nil)
    }

    @Test func tornRecordRejected() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var writer = try LiveStateWriter(url: url)
        writer.write(sample)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 120)
        try handle.write(contentsOf: Data([0xFF, 0, 0, 0, 0, 0, 0, 0]))
        try handle.close()
        #expect(LiveStateReader.read(url: url) == nil)
    }

    @Test func roundTripNewFields() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var writer = try LiveStateWriter(url: url)
        var s = sample
        s.leftoverCount = 4
        s.leftoverBytes = 3_500_000_000
        s.swapGrowthBytesPerMin = -250_000_000
        writer.write(s)
        #expect(LiveStateReader.read(url: url) == s)
        s.swapGrowthBytesPerMin = 900_000_000
        writer.write(s)
        #expect(LiveStateReader.read(url: url)?.swapGrowthBytesPerMin == 900_000_000)
    }

    @Test func phase1FileReadsZeroForNewFields() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var writer = try LiveStateWriter(url: url)
        var s = sample
        s.leftoverCount = 4
        s.leftoverBytes = 3_500_000_000
        s.swapGrowthBytesPerMin = 7
        writer.write(s)
        var bytes = [UInt8](try Data(contentsOf: url))
        for i in 76..<96 { bytes[i] = 0 }
        try Data(bytes).write(to: url)
        #expect(bytes.count == 128)
        let read = try #require(LiveStateReader.read(url: url))
        #expect(read.leftoverCount == 0)
        #expect(read.leftoverBytes == 0)
        #expect(read.swapGrowthBytesPerMin == 0)
        #expect(read.memUsed == sample.memUsed)
    }

    @Test func roundTripBattery() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var writer = try LiveStateWriter(url: url)
        let readings: [BatteryReading?] = [
            BatteryReading(percent: 68, charging: true, onAC: true),
            BatteryReading(percent: 0, charging: false, onAC: false),
            BatteryReading(percent: 100, charging: false, onAC: true),
            BatteryReading(percent: 9, charging: false, onAC: false),
            BatteryReading(percent: 50, charging: true, onAC: false),
            nil,
        ]
        for battery in readings {
            var s = sample
            s.battery = battery
            writer.write(s)
            #expect(LiveStateReader.read(url: url) == s)
        }
    }

    /// A new reader against a file from a recorder that predates batteries: here a real record the 0.2.0
    /// recorder wrote on a MacBook running on battery, so "no battery" can only come from the format.
    @Test func preBatteryRecorderFileReadsNoBattery() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(Self.preBatteryRecord).write(to: url)
        let read = try #require(LiveStateReader.read(url: url))
        #expect(read.battery == nil)
        #expect(read.timestamp == 1_795_807_709.484206)
        #expect(read.memUsed == 34_597_093_376)
        #expect(read.memTotal == 51_539_607_552)
        #expect(read.swapUsed == 1_891_368_960)
        #expect(read.diskFree == 214_527_647_744)
        #expect(read.diskCapacity == 494_384_795_648)
        #expect(read.pressure == 1)
        #expect(read.activeAgents == 1 && read.idleAgents == 13)
    }

    /// An older reader against a new file. Every earlier reader checks version 1 and the sequence at 120, and
    /// decodes only bytes 0–95, so if the battery changes nothing else, it reads exactly what it would from
    /// a record without one.
    @Test func batteryTouchesOnlyBytesOlderReadersIgnore() throws {
        func record(_ battery: BatteryReading?) throws -> [UInt8] {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }
            var writer = try LiveStateWriter(url: url)
            var s = sample
            s.battery = battery
            writer.write(s)
            return [UInt8](try Data(contentsOf: url))
        }
        let without = try record(nil)
        let with = try record(BatteryReading(percent: 100, charging: true, onAC: true))
        #expect(with.count == 128)
        #expect(Array(with[4..<8]) == [1, 0, 0, 0])
        #expect(with.indices.filter { with[$0] != without[$0] } == [96, 97])
    }

    private static let preBatteryRecord: [UInt8] = {
        let hex =
            "4844524d01000000a37a0000000000003bfd5e7776c2da41e014da3d0100000000c0250e08000000000000000c00000000"
            + "00bc70000000000020d8f2310000000050a11b7300000001000d0000000000000000000000000000000000000000000000"
            + "00000000000000000000000000000000000000000000a37a000000000000"
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<next], radix: 16)!)
            i = next
        }
        return bytes
    }()

    @Test func swapGrowthUsesSampleFromAMinuteAgo() {
        var growth = SwapGrowth()
        let gb: UInt64 = 1_000_000_000
        var last: Int64 = -1
        for i in 0...7 { last = growth.record(swapUsed: UInt64(i) * gb, at: Double(i) * 10) }
        #expect(last == 6 * Int64(gb))
    }

    @Test func swapGrowthZeroUntilAMinuteOfHistory() {
        var growth = SwapGrowth()
        for i in 0...5 {
            #expect(growth.record(swapUsed: UInt64(i) * 1_000_000_000, at: Double(i) * 10) == 0)
        }
    }

    @Test func staleReferenceAfterSleepIsIgnored() {
        var growth = SwapGrowth()
        let gb: UInt64 = 1_000_000_000
        for i in 0...6 { _ = growth.record(swapUsed: UInt64(i) * gb, at: Double(i) * 10) }
        #expect(growth.record(swapUsed: 50 * gb, at: 36_000) == 0)
        for i in 1...5 {
            #expect(growth.record(swapUsed: 50 * gb, at: 36_000 + Double(i) * 10) == 0)
        }
    }

    @Test func growthIsNormalisedToAMinute() {
        var growth = SwapGrowth()
        let gb: UInt64 = 1_000_000_000
        _ = growth.record(swapUsed: 0, at: 0)
        #expect(growth.record(swapUsed: 7 * gb, at: 70) == 6 * Int64(gb))
    }
}

@Suite(.serialized) struct LiveStateSpeedTests {
    // Wall-clock budgets are flaky on a loaded machine, so they only run under `make bench`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEADROOM_BENCH"] == "1", "wall-clock budget; run via make bench")) func readerSpeed() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var writer = try LiveStateWriter(url: url)
        writer.write(sample)
        let n = 10_000
        let elapsed = ContinuousClock().measure {
            for _ in 0..<n { _ = LiveStateReader.read(url: url) }
        }
        let micros = Double(elapsed.components.seconds) * 1e6 + Double(elapsed.components.attoseconds) / 1e12
        #expect(micros / Double(n) < 50)
    }
}

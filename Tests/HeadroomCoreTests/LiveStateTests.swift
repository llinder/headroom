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

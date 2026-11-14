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

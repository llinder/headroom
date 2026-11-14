import Foundation
import Testing

@testable import HeadroomCore

@Suite struct DiskSamplerTests {
    private let space = DiskSpace(capacity: 1000, free: 400, availableImportant: 450)

    private func totals(_ bytes: UInt64) -> DiskIOTotals {
        DiskIOTotals(readBytes: bytes, writeBytes: bytes * 2, readOps: bytes / 10, writeOps: bytes / 5)
    }

    @Test func deltasAndCarriedSpace() throws {
        var sampler = DiskSampler()
        let firstReading = sampler.record(totals: totals(100), space: space)
        let first = try #require(firstReading)
        #expect(first.writeBytes == 0)
        #expect(first.capacity == 1000 && first.availableImportant == 450)
        let secondReading = sampler.record(totals: totals(150), space: nil)
        let second = try #require(secondReading)
        #expect(second.readBytes == 50)
        #expect(second.writeBytes == 100)
        #expect(second.readOps == 5)
        #expect(second.writeOps == 10)
        #expect(second.capacity == 1000 && second.free == 400)
    }

    @Test func ioFailureClearsPreviousSoNextSampleHasZeroDeltas() throws {
        var sampler = DiskSampler()
        _ = sampler.record(totals: totals(100), space: space)
        #expect(sampler.record(totals: nil, space: nil) == nil)
        let nextReading = sampler.record(totals: totals(1_000_000), space: nil)
        let next = try #require(nextReading)
        #expect(next.readBytes == 0 && next.writeBytes == 0 && next.readOps == 0 && next.writeOps == 0)
    }

    @Test func noSpaceEverReadYieldsNil() {
        var sampler = DiskSampler()
        #expect(sampler.record(totals: totals(100), space: nil) == nil)
    }

    @Test func backwardsCounterIsZeroDelta() throws {
        var sampler = DiskSampler()
        _ = sampler.record(totals: totals(500), space: space)
        let nextReading = sampler.record(totals: totals(100), space: nil)
        let next = try #require(nextReading)
        #expect(next.readBytes == 0 && next.writeBytes == 0)
    }

    private func writeAndSync(megabytes: Int, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let chunk = [UInt8](repeating: 0xA5, count: 1 << 20)
        for _ in 0..<megabytes {
            let written = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            try #require(written == chunk.count)
        }
        fsync(fd)
    }

    @Test func liveSmoke() throws {
        var sampler = DiskSampler()
        let firstReading = sampler.sample(refreshSpace: true)
        let first = try #require(firstReading)
        #expect(first.capacity > 0)
        #expect(first.free <= first.capacity)
        #expect(first.readBytes == 0 && first.writeBytes == 0 && first.readOps == 0 && first.writeOps == 0)

        let url = FileManager.default.temporaryDirectory.appending(path: "headroom-disk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeAndSync(megabytes: 4, to: url)
        let secondReading = sampler.sample(refreshSpace: false)
        let second = try #require(secondReading)
        #expect(second.writeBytes > 0)
        #expect(second.capacity == first.capacity)
    }
}

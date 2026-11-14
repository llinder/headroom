import Foundation
import Testing
@testable import HeadroomCore

@Suite struct MachineInfoTests {
    @Test func machineIdStable() {
        let a = MachineInfo.current()
        let b = MachineInfo.current()
        #expect(a.machineId == b.machineId)
        #expect(a.machineId.count == 16)
        #expect(a.machineId.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(a.ramBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(a.perfCores + a.effCores == ProcessInfo.processInfo.processorCount)
        #expect(a.diskBytes > 0)
        #expect(a.serialHash.count == 64)
    }

    @Test func registerUpserts() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-test-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try Database(path: path, readOnly: false)
        try Schema.migrate(db)
        let info = MachineInfo.current()
        try info.register(in: db, now: Date(timeIntervalSince1970: 1_000))
        try info.register(in: db, now: Date(timeIntervalSince1970: 2_000))
        let stmt = try db.prepare("SELECT machine_id, serial_hash, first_seen, last_seen FROM machines")
        #expect(try stmt.step())
        #expect(stmt.string(0) == info.machineId)
        #expect(stmt.string(1) == info.serialHash)
        #expect(stmt.int64(2) == 1_000)
        #expect(stmt.int64(3) == 2_000)
        #expect(try !stmt.step())
    }
}

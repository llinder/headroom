import Foundation
import Testing

@testable import HeadroomCLI
@testable import HeadroomCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private final class Fixture {
    let dir: URL
    let paths: Paths
    let home: URL
    let db: Database
    let id: String

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "headroom-status-\(UUID().uuidString)")
        home = dir.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = Paths(root: dir)
        db = try Database(path: paths.database.path, readOnly: false)
        try Schema.migrate(db)
        let machine = MachineInfo(
            model: "Mac15,6", chip: "", serialHash: "h", perfCores: 8, effCores: 4, ramBytes: 17_179_869_184, diskBytes: 0)
        try machine.register(in: db, now: now)
        id = machine.machineId
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func heartbeat(age: Int) throws {
        try db.exec("INSERT OR REPLACE INTO meta VALUES('heartbeat', '\(Int(now.timeIntervalSince1970) - age)')")
    }

    func render() throws -> String {
        try Status.render(queries: Queries(db: db), paths: paths, machineId: id, now: now, home: home)
    }
}

@Suite struct StatusTests {
    @Test func heartbeatFreshnessBoundary() throws {
        let f = try Fixture()
        try f.heartbeat(age: 89)
        #expect(try f.render().hasPrefix("recording ●"))
        try f.heartbeat(age: 91)
        #expect(try f.render().hasPrefix("not recording ○"))
    }

    @Test func countsGapsAcrossDays() throws {
        let f = try Fixture()
        try f.db.exec("""
            INSERT INTO coverage VALUES('\(f.id)', '2027-01-14', 9000, 0, 600, '[[1799900000,1799900300],[1799900500,1799900800]]');
            """)
        #expect(try f.render().contains("coverage 93.8% of awake time · gaps 2"))
    }

    @Test func noCoverageRowsShowNotAvailable() throws {
        let f = try Fixture()
        let out = try f.render()
        #expect(out.contains("coverage n/a of awake time · gaps 0"))
        #expect(out.contains("days recorded 0"))
    }

    @Test func missingDatabasePrintsNoDataAndSucceeds() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "headroom-none-\(UUID().uuidString)")
        var out: [String] = []
        var errors: [String] = []

        let rc = Status.run(paths: Paths(root: dir), now: now, out: { out.append($0) }, err: { errors.append($0) })

        #expect(rc == 0)
        #expect(out == ["no data yet — run `headroom install`"])
        #expect(errors.isEmpty)
    }

    @Test func corruptDatabaseIsReportedAsUnreadable() throws {
        let f = try Fixture()
        let bad = Paths(root: f.dir.appending(path: "bad"))
        try FileManager.default.createDirectory(at: bad.root, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8192).write(to: bad.database)
        var out: [String] = []
        var errors: [String] = []

        let rc = Status.run(paths: bad, now: now, out: { out.append($0) }, err: { errors.append($0) })

        #expect(rc == 1)
        #expect(out.isEmpty)
        #expect(errors.count == 1 && errors[0].hasPrefix("database unreadable: "))
    }
}

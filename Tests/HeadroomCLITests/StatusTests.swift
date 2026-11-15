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

    @Test func noEnginesAfterAPass() throws {
        let f = try Fixture()
        try LeftoverState(updated: now.timeIntervalSince1970 - 120).save(to: f.paths.leftovers)
        let out = try f.render()
        #expect(out.contains("docker no engines found · last checked 2m ago"))
        #expect(!out.contains("not checked yet"))
    }

    @Test func agentHookEventsAreListed() throws {
        let f = try Fixture()
        #expect(try f.render().contains("agent hooks: none · run headroom install --agents"))

        let claude = f.home.appending(path: ".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let session = #"{"hooks":[{"type":"command","command":"/b/headroom agent-hook claude"}]}"#
        let pretool = #"{"matcher":"Bash","hooks":[{"type":"command","command":"/b/headroom agent-hook pretool claude"}]}"#
        try Data(#"{"hooks":{"SessionStart":[\#(session)]}}"#.utf8).write(to: claude.appending(path: "settings.json"))
        #expect(try f.render().contains("agent hooks: SessionStart · PreToolUse missing, run headroom install --agents"))

        try Data(#"{"hooks":{"SessionStart":[\#(session)],"PreToolUse":[\#(pretool)]}}"#.utf8)
            .write(to: claude.appending(path: "settings.json"))
        let out = try f.render()
        #expect(out.hasSuffix("agent hooks: SessionStart, PreToolUse"))
    }

    @Test func statusShowsEngines() throws {
        let f = try Fixture()
        #expect(try f.render().contains("docker not checked yet"))

        let state = LeftoverState(
            updated: now.timeIntervalSince1970,
            engines: [
                EngineStatus(context: "desktop-linux", socket: "/s", lastPass: now.timeIntervalSince1970 - 180, ok: true, failures: 0),
                EngineStatus(context: "colima", socket: "/c", lastPass: now.timeIntervalSince1970 - 3600, ok: false, failures: 4),
            ],
            keepWarning: "keeps.json: 1 entry could not be read and was ignored")
        try state.save(to: f.paths.leftovers)
        let out = try f.render()
        #expect(out.contains("docker desktop-linux ok · last checked 3m ago"))
        #expect(out.contains("docker colima unreachable · last checked 60m ago"))
        #expect(out.contains("keep list: keeps.json: 1 entry could not be read and was ignored"))
        #expect(!out.contains("not checked yet"))
    }
}

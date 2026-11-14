import Foundation
import Testing

@testable import HeadroomCLI
@testable import HeadroomCore

private func utc() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return c
}

// 2026-12-13 12:00 UTC.
private let now = Date(timeIntervalSince1970: 1_797_163_200)

private let machine = MachineInfo(
    model: "Mac15,6", chip: "Apple M3 Pro", serialHash: "a", perfCores: 6, effCores: 6, ramBytes: 18 * 1_073_741_824,
    diskBytes: 512_000_000_000)
private let other = MachineInfo(
    model: "Mac14,6", chip: "", serialHash: "b", perfCores: 8, effCores: 4, ramBytes: 32 * 1_073_741_824, diskBytes: 0)

private final class Fixture {
    let dir = FileManager.default.temporaryDirectory.appending(path: "headroom-report-cli-\(UUID().uuidString)")
    let paths: Paths

    init(seed: Bool = true) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths = Paths.standard(environment: ["HEADROOM_ROOT": dir.path])
        guard seed else { return }
        let db = try Database(path: paths.database.path, readOnly: false)
        try Schema.migrate(db)
        try machine.register(in: db, now: now)
        try other.register(in: db, now: now.addingTimeInterval(-86_400))
        try db.exec("INSERT INTO coverage VALUES('\(machine.machineId)', '2026-12-12', 28800, 0, 0, '[]')")
        try db.exec("INSERT INTO rollup VALUES('\(machine.machineId)', 3600, 1797066000, 'memDemand', 1e10, 2e10, 1.5e10)")
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func run(
        since: Date? = nil, until: Date? = nil, machine id: String? = nil, current: MachineInfo = machine
    ) -> (status: Int32, out: [String], err: [String], file: URL) {
        let file = dir.appending(path: "r.pdf")
        var out: [String] = []
        var err: [String] = []
        let status = Report.run(
            since: since, until: until, machine: id, file: file.path, paths: paths, now: now, calendar: utc(),
            current: current, out: { out.append($0) }, err: { err.append($0) })
        return (status, out, err, file)
    }
}

@Suite struct ReportCommandTests {
    @Test func reportCLIWritesFile() throws {
        let f = try Fixture()
        let result = f.run()
        #expect(result.status == 0)
        #expect(result.err.isEmpty)
        #expect(result.out == ["wrote \(result.file.path)"])
        let size = try FileManager.default.attributesOfItem(atPath: result.file.path)[.size] as? Int ?? 0
        #expect(size > 0)
    }

    @Test func missingDatabaseIsAnError() throws {
        let f = try Fixture(seed: false)
        let result = f.run()
        #expect(result.status == 1)
        #expect(result.err == ["no data yet — run `headroom install`"])
        #expect(!FileManager.default.fileExists(atPath: result.file.path))
    }

    @Test func unreadableDatabaseIsReported() throws {
        let f = try Fixture(seed: false)
        try Data("not a database".utf8).write(to: f.paths.database)
        let result = f.run()
        #expect(result.status == 1)
        #expect(result.err.count == 1)
        #expect(result.err.first?.hasPrefix("database unreadable: ") == true)
    }

    @Test func machinePrefixSelects() throws {
        let f = try Fixture()
        #expect(f.run(machine: String(other.machineId.prefix(6))).status == 0)
        let none = f.run(machine: "zzzz")
        #expect(none.status == 1)
        #expect(none.err == ["headroom: no machine id starts with zzzz"])
        #expect(f.run(machine: "").status == 1)
    }

    @Test func unknownCurrentMachineFallsBackToMostRecent() throws {
        let f = try Fixture()
        let stranger = MachineInfo(
            model: "Mac99,1", chip: "", serialHash: "z", perfCores: 1, effCores: 0, ramBytes: 0, diskBytes: 0)
        #expect(f.run(current: stranger).status == 0)
    }

    @Test func rangeIsWholeLocalDaysWithInclusiveUntil() throws {
        let cal = utc()
        let day = { (d: Int) in cal.date(from: DateComponents(year: 2026, month: 12, day: d)) ?? .distantPast }

        let both = try #require(Report.range(since: day(1), until: day(3), now: now, calendar: cal))
        #expect(both.start == day(1))
        #expect(both.end == day(4))

        let defaults = try #require(Report.range(since: nil, until: nil, now: now, calendar: cal))
        #expect(defaults.end == day(14))
        #expect(defaults.start == (try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 14)))))
        #expect(ReportModel.rangeText(from: defaults.start, to: defaults.end, calendar: cal) == "Nov 14 – Dec 13, 2026")

        #expect(Report.range(since: day(5), until: day(3), now: now, calendar: cal) == nil)
        #expect(Report.range(since: day(3), until: day(3), now: now, calendar: cal)?.duration == 86_400)
    }
}

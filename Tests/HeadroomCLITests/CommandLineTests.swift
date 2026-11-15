import Foundation
import Testing

@testable import HeadroomCLI
@testable import HeadroomCore

private func localMidnight(_ y: Int, _ m: Int, _ d: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: m, day: d)) ?? .distantPast
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "headroom-cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct CommandLineTests {
    @Test func parseBasics() throws {
        #expect(try parse(["headroom", "tag", "kind + 6 agents"]) == .tag("kind + 6 agents"))
        #expect(try parse(["headroom", "report", "--since", "2026-12-01", "--out", "r.pdf"])
            == .report(since: localMidnight(2026, 12, 1), until: nil, machine: nil, out: "r.pdf"))
        #expect(try parse(["headroom", "statusline", "--no-color"]) == .statusline(format: nil, color: false, quiet: false))
        #expect(try parse(["headroom", "install", "--agents"]) == .install(agents: true))
        #expect(try parse(["headroom", "tag", "--", "fixing", "--no-cache"]) == .tag("fixing --no-cache"))
        #expect(try parse(["headroom"]) == .top)
        #expect(try parse(["headroom", "hook", "zsh"]) == .hookZsh)
        #expect(try parse(["headroom", "agent-hook", "claude"]) == .agentHook(tool: "claude"))
        #expect(try parse(["headroom", "record-command", "make", "2.5"]) == .recordCommand(exe: "make", seconds: 2.5))
    }

    @Test func parseRejectsBadInput() {
        #expect(throws: UsageError.self) { try parse(["headroom", "bogus"]) }
        #expect(throws: UsageError.self) { try parse(["headroom", "status", "--wat"]) }
        #expect(throws: UsageError.self) { try parse(["headroom", "report", "--bogus", "x"]) }
        #expect(throws: UsageError.self) { try parse(["headroom", "report", "--since", "2026-02-30"]) }
        #expect(throws: UsageError.self) { try parse(["headroom", "report", "--since"]) }
        #expect(throws: UsageError.self) { try parse(["headroom", "tag"]) }
        #expect(throws: UsageError.self) { try parse(["headroom", "tag", "--"]) }
        #expect(throws: UsageError.self) { try parse(["headroom", "tag", "fixing", "--no-cache"]) }
        #expect(throws: UsageError.self) { try parse(["headroom", "tag", "--no-cache"]) }
        #expect(throws: UsageError.self) { try parse(["headroom", "install", "--wat"]) }
    }

    @Test func runReturnsTwoOnUsageError() {
        var errors: [String] = []
        #expect(run(["headroom", "bogus"], out: { _ in }, err: { errors.append($0) }) == 2)
        #expect(errors.count == 1 && errors[0].hasPrefix("headroom: unknown command bogus"))
    }

    @Test func tagAppendsSpoolRecord() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(root: dir)

        var printed: [String] = []
        let status = Tag.run(
            text: "kind + 6 agents", paths: paths, now: Date(timeIntervalSince1970: 1000),
            out: { printed.append($0) }, err: { _ in })
        #expect(status == 0)
        #expect(printed == ["tagged"])

        let line = try String(contentsOf: paths.spool, encoding: .utf8)
        let record = try JSONDecoder().decode(SpoolRecord.self, from: Data(line.utf8))
        #expect(record == .tag(ts: 1000, text: "kind + 6 agents"))
    }

    @Test func tagFailsWhenSpoolUnwritable() {
        let paths = Paths(root: URL(filePath: "/nonexistent-\(UUID().uuidString)"))
        var errors: [String] = []
        #expect(Tag.run(text: "x", paths: paths, now: Date(), out: { _ in }, err: { errors.append($0) }) == 1)
        #expect(errors == ["could not write tag"])
    }

    @Test func statusOutput() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(root: dir)
        let db = try Database(path: paths.database.path, readOnly: false)
        try Schema.migrate(db)
        let machine = MachineInfo(
            model: "Mac15,6", chip: "", serialHash: "h", perfCores: 8, effCores: 4, ramBytes: 17_179_869_184,
            diskBytes: 0)
        try machine.register(in: db, now: Date(timeIntervalSince1970: 1_000))
        let id = machine.machineId
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ts = Int(now.timeIntervalSince1970)
        try db.exec("""
            INSERT INTO meta VALUES('heartbeat', '\(ts - 20)');
            INSERT INTO coverage VALUES('\(id)', '2027-01-14', 9900, 0, 100, '[]');
            INSERT INTO coverage VALUES('\(id)', '2027-01-15', 0, 0, 0, '[]');
            INSERT INTO samples(machine_id, ts, self_cpu, self_footprint) VALUES('\(id)', \(ts - 100), 0.01, 8388608);
            """)
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try "{\"hooks\": \"headroom agent-hook claude\"}".write(
            to: home.appending(path: ".claude/settings.json"), atomically: true, encoding: .utf8)

        let out = try Status.render(queries: Queries(db: db), paths: paths, machineId: id, now: now, home: home)

        #expect(out.contains("recording ●"))
        #expect(out.contains("machine Mac15,6 · 12 cores · 16 GB"))
        #expect(out.contains("days recorded 1"))
        #expect(out.contains("coverage 99.0% of awake time · gaps 0"))
        #expect(out.contains("database "))
        #expect(out.contains("headroomd CPU 0.1% · memory 8.0 MB"))
        #expect(out.contains("agent hooks installed"))

        try db.exec("UPDATE meta SET value='1' WHERE key='heartbeat'")
        let stale = try Status.render(queries: Queries(db: db), paths: paths, machineId: id, now: now, home: dir)
        #expect(stale.hasPrefix("not recording ○"))
        #expect(stale.contains("agent hooks not installed"))
    }

    @Test func parseLeftoversAndKeep() throws {
        #expect(try parse(["headroom", "leftovers"]) == .leftovers(json: false, kept: false))
        #expect(try parse(["headroom", "leftovers", "--json", "--kept"]) == .leftovers(json: true, kept: true))
        #expect(try parse(["headroom", "keep", "kind:dev"]) == .keep(name: "kind:dev", forSeconds: nil))
        #expect(try parse(["headroom", "keep", "kind:dev", "--for", "8h"]) == .keep(name: "kind:dev", forSeconds: 28_800))
        #expect(try parse(["headroom", "keep", "--for", "7d", "x"]) == .keep(name: "x", forSeconds: 604_800))
        #expect(try parse(["headroom", "unkeep", "x"]) == .unkeep(name: "x"))
        #expect(try parse(["headroom", "keeps"]) == .keeps)
    }

    @Test func keepWithBadDurationIsUsageError() {
        for bad in ["keep", "temporary", "0h", "soon"] {
            #expect(throws: UsageError.self) { try parse(["headroom", "keep", "x", "--for", bad]) }
        }
        #expect(throws: UsageError.self) { try parse(["headroom", "keep"]) }
        #expect(throws: UsageError.self) { try parse(["headroom", "keep", "x", "--for"]) }
        #expect(throws: UsageError.self) { try parse(["headroom", "unkeep"]) }
        #expect(throws: UsageError.self) { try parse(["headroom", "keeps", "x"]) }
        #expect(throws: UsageError.self) { try parse(["headroom", "leftovers", "--nope"]) }
    }

    @Test func parseMCP() throws {
        #expect(try parse(["headroom", "mcp"]) == .mcp)
        #expect(throws: UsageError.self) { try parse(["headroom", "mcp", "--stdio"]) }
        #expect(usageText.contains("  mcp "))
    }
}

import Foundation
import Synchronization
import Testing

@testable import HeadroomCLI
@testable import HeadroomCore

private let now = 1_800_000_000.0

private final class MCPFixture {
    let dir = FileManager.default.temporaryDirectory.appending(path: "headroom-mcp-\(UUID().uuidString)")
    let paths: Paths
    let server: MCPServer
    private(set) var db: Database?
    private(set) var machineId = ""

    init(seed: Bool = true) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths = Paths(root: dir)
        server = MCPServer(paths: paths, now: { now })
        guard seed else { return }
        let db = try Database(path: paths.database.path, readOnly: false)
        try Schema.migrate(db)
        let machine = MachineInfo(
            model: "Test1,1", chip: "", serialHash: "mcp", perfCores: 8, effCores: 4, ramBytes: 17_179_869_184,
            diskBytes: 0)
        try machine.register(in: db, now: Date(timeIntervalSince1970: now))
        machineId = machine.machineId
        self.db = db
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func exec(_ sql: String) throws {
        try #require(db).exec(sql)
    }

    func send(_ text: String) throws -> JSONValue? {
        guard let reply = server.handle(line: Data(text.utf8)) else { return nil }
        #expect(!reply.contains(0x0A))
        return try JSONDecoder().decode(JSONValue.self, from: reply)
    }

    func initialize(version: String = "2025-06-18") throws -> JSONValue? {
        try send(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#
        )
    }

    /// Calls a tool after initializing and returns the summary line and the parsed JSON body.
    func call(_ name: String, _ arguments: String = "{}") throws -> (summary: String, body: JSONValue, isError: Bool) {
        _ = try initialize()
        let reply = try #require(
            try send(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#))
        let result = try #require(reply["result"])
        let text = try #require(result["content"]?[0]?["text"]?.stringValue)
        let isError = result["isError"] == .bool(true)
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        let body = parts.count == 2 ? try JSONDecoder().decode(JSONValue.self, from: Data(parts[1].utf8)) : .null
        return (parts[0], body, isError)
    }
}

@Suite struct MCPServerTests {
    @Test func initializeThenToolsList() throws {
        let f = try MCPFixture(seed: false)
        let reply = try #require(try f.initialize())
        #expect(reply["jsonrpc"] == .string("2.0"))
        #expect(reply["id"] == .int(1))
        let result = try #require(reply["result"])
        #expect(result["protocolVersion"] == .string("2025-06-18"))
        #expect(result["capabilities"] == .object(["tools": .object([:])]))
        #expect(result["serverInfo"]?["name"] == .string("headroom"))
        #expect(result["serverInfo"]?["version"] == .string(HeadroomVersion.current))

        let newest = try #require(try f.initialize(version: "1999-01-01"))
        #expect(newest["result"]?["protocolVersion"] == .string("2025-11-25"))

        let list = try #require(try f.send(#"{"jsonrpc":"2.0","id":"list-1","method":"tools/list"}"#))
        #expect(list["id"] == .string("list-1"))
        let tools = try #require(list["result"]?["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["name"]?.stringValue } == ["current_status", "query_metric", "explain_slowdown"])
        for tool in tools {
            #expect(tool["inputSchema"]?["type"] == .string("object"))
            #expect(tool["annotations"]?["readOnlyHint"] == .bool(true))
        }
        let metricEnum = tools[1]["inputSchema"]?["properties"]?["metric"]?["enum"]?.arrayValue
        #expect(metricEnum?.compactMap(\.stringValue) == Metric.allCases.map(\.rawValue))
    }

    @Test func callBeforeInitializeErrors() throws {
        let f = try MCPFixture()
        let reply = try #require(
            try f.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"current_status"}}"#))
        #expect(reply["id"] == .int(3))
        #expect(reply["error"]?["code"] == .int(-32002))
        #expect(reply["error"]?["message"] == .string("not initialized"))
        #expect(reply["result"] == nil)
    }

    @Test func malformedLineIsParseErrorAndServerContinues() throws {
        let f = try MCPFixture(seed: false)
        let bad = try #require(try f.send(#"{"jsonrpc":"2.0","id":1,"method":"#))
        #expect(bad["id"] == .null)
        #expect(bad["error"]?["code"] == .int(-32700))

        let ping = try #require(try f.send(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#))
        #expect(ping["id"] == .string("abc"))
        #expect(ping["result"] == .object([:]))

        let notRequest = try #require(try f.send(#"[1,2]"#))
        #expect(notRequest["error"]?["code"] == .int(-32600))
        #expect(notRequest["id"] == .null)
    }

    @Test func notificationGetsNoReply() throws {
        let f = try MCPFixture(seed: false)
        _ = try f.initialize()
        #expect(try f.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(try f.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#) == nil)

        let unknown = try #require(try f.send(#"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#))
        #expect(unknown["error"]?["code"] == .int(-32601))
        // A dual-era client probes with server/discover and falls back to initialize on a non-modern error.
        let discover = try #require(try f.send(#"{"jsonrpc":"2.0","id":10,"method":"server/discover"}"#))
        #expect(discover["error"]?["code"] == .int(-32601))
    }

    @Test func unknownToolIsInvalidParams() throws {
        let f = try MCPFixture()
        _ = try f.initialize()
        let reply = try #require(
            try f.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"drop_tables","arguments":{}}}"#))
        #expect(reply["error"]?["code"] == .int(-32602))

        let noName = try #require(try f.send(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{}}"#))
        #expect(noName["error"]?["code"] == .int(-32602))
    }

    /// A known tool given bad arguments answers with a tool error the model can read and correct, not a protocol error.
    @Test func badArgumentsAreToolErrors() throws {
        let f = try MCPFixture()
        let cases: [(String, String)] = [
            ("query_metric", #"{"metric":"nope","from":"-1h"}"#),
            ("query_metric", #"{"from":"-1h"}"#),
            ("query_metric", #"{"metric":"cpuBusy","from":"-1h","resolution":"week"}"#),
            ("query_metric", #"{"metric":"cpuBusy","from":"now","to":"-1h"}"#),
            ("query_metric", #"{"metric":7,"from":["-1h"]}"#),
            ("explain_slowdown", #"{"at":"yesterday-ish"}"#),
            ("explain_slowdown", #"{"at":"-1h","windowMinutes":"thirty"}"#),
            ("explain_slowdown", #"{"at":"-1h","windowMinutes":1.5}"#),
            ("explain_slowdown", #"{"at":"-1h","windowMinutes":0}"#),
            ("explain_slowdown", #"{"at":"-1h","windowMinutes":null}"#),
            ("explain_slowdown", #"{"at":{"t":1}}"#),
        ]
        for (tool, arguments) in cases {
            let result = try f.call(tool, arguments)
            #expect(result.isError, "\(tool) \(arguments)")
            #expect(result.body == .null, "\(tool) \(arguments)")
        }
    }

    /// Times far outside the calendar used to reach the Int64 binds and trap; each must come back as a tool error.
    @Test func outOfRangeTimesAreToolErrorsNotTraps() throws {
        let f = try MCPFixture()
        let huge = [
            "-99999999999999999999d", "-" + String(repeating: "9", count: 400) + "d", "0001-01-01T00:00:00Z",
            "99999-01-01T00:00:00Z", "1969-12-31T23:59:59Z", "10000-01-01",
        ]
        for time in huge {
            #expect(MCPTime.parse(time, now: now, calendar: .current) == nil, "\(time)")
            let metric = try f.call("query_metric", #"{"metric":"cpuBusy","from":"\#(time)"}"#)
            #expect(metric.isError, "\(time)")
            let explain = try f.call("explain_slowdown", #"{"at":"\#(time)"}"#)
            #expect(explain.isError, "\(time)")
        }
        #expect(MCPTime.parse("-999999999999m", now: now, calendar: .current) == nil)
        #expect(MCPTime.parse("-9999999999999m", now: now, calendar: .current) == nil)
        #expect(MCPTime.parse("9999-12-31T23:59:59Z", now: now, calendar: .current) == 253_402_300_799)
        #expect(MCPTime.parse("1970-01-01T00:00:00Z", now: now, calendar: .current) == 0)
    }

    @Test func hostileEnvelopes() throws {
        let f = try MCPFixture()
        _ = try f.initialize()
        let nullId = try #require(try f.send(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#))
        #expect(nullId["error"]?["code"] == .int(-32600))
        #expect(nullId["id"] == .null)

        let objectId = try #require(try f.send(#"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#))
        #expect(objectId["error"]?["code"] == .int(-32600))

        for params in [#""current_status""#, #"[1]"#, #"{"name":7}"#, #"{"name":"current_status","arguments":[1]}"#,
            #"{"name":"current_status","arguments":"x"}"#]
        {
            let reply = try #require(try f.send(#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":\#(params)}"#))
            #expect(reply["error"]?["code"] == .int(-32602), "\(params)")
            #expect(reply["id"] == .int(11))
        }

        let oddInit = try #require(try f.send(#"{"jsonrpc":"2.0","id":12,"method":"initialize","params":"x"}"#))
        #expect(oddInit["result"]?["protocolVersion"] == .string("2025-11-25"))

        let noVersion = try #require(try f.send(#"{"id":13,"method":"ping"}"#))
        #expect(noVersion["error"]?["code"] == .int(-32600))
        #expect(noVersion["id"] == .int(13))
    }

    @Test func leftoverItemsAreCappedAtFifty() throws {
        let f = try MCPFixture()
        let items = (0..<60).map { i in
            FlaggedItem(
                item: LeftoverItem(
                    key: "default/container/c\(i)", engine: "default", kind: .container, name: "c\(i)",
                    containerIDs: ["id\(i)"], sessionId: nil, lifetime: nil, cleanup: ["docker stop c\(i)"]),
                startedAt: now - 100, reason: "done", memoryBytes: 10, firstFlagged: now)
        }
        try LeftoverState(updated: now, items: items).save(to: f.paths.leftovers)
        let result = try f.call("current_status")
        #expect(result.body["leftovers"]?["count"] == .int(60))
        #expect(result.body["leftovers"]?["totalBytes"] == .int(600))
        #expect(result.body["leftovers"]?["items"]?.arrayValue?.count == 50)
    }

    @Test func unknownLeftoverMemoryIsLeftOutOfTheSummary() throws {
        let f = try MCPFixture()
        let item = FlaggedItem(
            item: LeftoverItem(
                key: "default/container/c", engine: "default", kind: .container, name: "c", containerIDs: ["id"],
                sessionId: nil, lifetime: nil, cleanup: []),
            startedAt: now - 100, reason: "done", memoryBytes: nil, firstFlagged: now)
        try LeftoverState(updated: now, items: [item]).save(to: f.paths.leftovers)
        let result = try f.call("current_status")
        #expect(result.summary.hasSuffix(" · 1 leftover"), "\(result.summary)")
        #expect(!result.summary.contains("GB)"))
    }

    @Test func missingDatabaseIsToolError() throws {
        let f = try MCPFixture(seed: false)
        let result = try f.call("query_metric", #"{"metric":"cpuBusy","from":"-1h"}"#)
        #expect(result.isError)
        #expect(result.summary.contains("no data yet"))
    }

    @Test func currentStatusWorksWithoutADatabase() throws {
        let f = try MCPFixture(seed: false)
        var writer = try LiveStateWriter(url: f.paths.liveState)
        writer.write(
            LiveSnapshot(
                timestamp: now, cpuBusy: 0.5, memUsed: 1, memTotal: 2, swapUsed: 0, diskFree: 0, diskCapacity: 0,
                pressure: 1, thermal: 0, limitFlags: 0, activeAgents: 2, idleAgents: 1))
        let item = FlaggedItem(
            item: LeftoverItem(
                key: "default/container/c", engine: "default", kind: .container, name: "c", containerIDs: ["id"],
                sessionId: nil, lifetime: nil, cleanup: ["docker rm -f 'id'"]),
            startedAt: now - 100, reason: "done", memoryBytes: 2_000_000_000, firstFlagged: now)
        try LeftoverState(updated: now, items: [item]).save(to: f.paths.leftovers)

        let result = try f.call("current_status")
        #expect(!result.isError)
        #expect(result.summary == "mem 50% · swap 0.0 GB · cpu 50% · pressure normal · 3 agents running · 1 leftover (2.0 GB)")
        #expect(result.body["live"]?["cpuBusy"] == .double(0.5))
        #expect(result.body["leftovers"]?["count"] == .int(1))
        #expect(result.body["note"]?.stringValue?.contains("no recorded history") == true)
        for key in ["todayLimitSeconds", "topGroups", "topProcesses", "agentRuns"] {
            #expect(result.body[key] == nil, "\(key) needs the database")
        }
    }

    @Test func queryMetricAutoResolution() throws {
        let f = try MCPFixture()
        let id = f.machineId
        for minute in stride(from: now - 7200, to: now, by: 60) {
            try f.exec("INSERT INTO rollup VALUES('\(id)', 60, \(Int(minute)), 'cpuBusy', 0.5, 0.9, 0.8)")
        }
        for hour in stride(from: now - 2 * 86_400, to: now, by: 3600) {
            try f.exec("INSERT INTO rollup VALUES('\(id)', 3600, \(Int(hour)), 'cpuBusy', 0.4, 0.7, 0.6)")
        }

        let short = try f.call("query_metric", #"{"metric":"cpuBusy","from":"-2h","to":"now","resolution":"auto"}"#)
        #expect(!short.isError)
        #expect(short.body["resolution"] == .string("minute"))
        #expect(short.body["points"]?.arrayValue?.count == 120)
        #expect(short.body["points"]?[0]?["max"] == .double(0.9))
        #expect(short.body["truncated"] == .bool(false))

        let long = try f.call("query_metric", #"{"metric":"cpuBusy","from":"-2d"}"#)
        #expect(long.body["resolution"] == .string("hour"))
        #expect(long.body["points"]?.arrayValue?.count == 48)

        let forced = try f.call("query_metric", #"{"metric":"cpuBusy","from":"-2d","resolution":"minute"}"#)
        #expect(forced.body["points"]?.arrayValue?.count == 120)

        for minute in stride(from: now - 86_400, to: now - 7200, by: 60) {
            try f.exec("INSERT INTO rollup VALUES('\(id)', 60, \(Int(minute)), 'cpuBusy', 0.5, 0.9, 0.8)")
        }
        let capped = try f.call("query_metric", #"{"metric":"cpuBusy","from":"-1d","resolution":"minute"}"#)
        #expect(capped.body["points"]?.arrayValue?.count == 500)
        #expect(capped.body["truncated"] == .bool(true))
        #expect(capped.summary.contains("500"))
    }

    @Test func explainSlowdownShape() throws {
        let f = try MCPFixture()
        let id = f.machineId
        let at = Int(now) - 3600
        try f.exec(
            """
            INSERT INTO limit_seconds VALUES('\(id)', 60, \(at - 600), 'memoryLimited', 40);
            INSERT INTO limit_seconds VALUES('\(id)', 60, \(at), 'memoryLimited', 20);
            INSERT INTO limit_seconds VALUES('\(id)', 60, \(at), 'heavySwap', 10);
            INSERT INTO limit_seconds VALUES('\(id)', 60, \(at - 2000), 'memoryLimited', 999);
            INSERT INTO rollup VALUES('\(id)', 60, \(at), 'memDemand', 25e9, 30e9, 29e9);
            INSERT INTO rollup VALUES('\(id)', 60, \(at - 300), 'memDemand', 15e9, 20e9, 19e9);
            INSERT INTO rollup VALUES('\(id)', 60, \(at - 300), 'swapUsed', 4e9, 5e9, 5e9);
            INSERT INTO samples(machine_id, ts, pressure) VALUES('\(id)', \(at - 100), 4);
            INSERT INTO samples(machine_id, ts, pressure) VALUES('\(id)', \(at - 90), 1);
            INSERT INTO group_samples VALUES('\(id)', \(at), 'containers', 100, 8000000000, 0, 3);
            INSERT INTO group_samples VALUES('\(id)', \(at), 'go', 300, 2000000000, 0, 9);
            INSERT INTO group_samples VALUES('\(id)', \(at), 'browsers', 50, 3000000000, 0, 20);
            INSERT INTO group_samples VALUES('\(id)', \(at), 'agents', 10, 1000000000, 0, 2);
            INSERT INTO top_procs_1m VALUES('\(id)', \(at), 'cpu', 1, 'compile', 'go', 9.0);
            INSERT INTO top_procs_1m VALUES('\(id)', \(at), 'memory', 1, 'com.docker.virtualization', 'containers', 8e9);
            INSERT INTO agent_runs(run_id, machine_id, tool, root_pid, root_start, started, ended)
                VALUES(1, '\(id)', 'claude', 100, 1, \(at - 5000), NULL);
            INSERT INTO run_usage VALUES(1, \(at), 120, 2000000000, 0, 60);
            INSERT INTO events VALUES('\(id)', \(at - 10), 'tag', '{"text":"build"}');
            INSERT INTO events VALUES('\(id)', \(at - 3000), 'leftover', '{"bytes":"1000","kind":"compose","ref":"a","totalBytes":"1000"}');
            INSERT INTO events VALUES('\(id)', \(at + 100), 'leftover', '{"bytes":"2000","kind":"kind","ref":"b","totalBytes":"3000"}');
            INSERT INTO events VALUES('\(id)', \(at + 5000), 'tag', '{"text":"later"}');
            """)

        let result = try f.call("explain_slowdown", #"{"at":"-1h","windowMinutes":30}"#)
        #expect(!result.isError)
        let body = result.body
        #expect(body["limitSeconds"]?["memoryLimited"] == .int(60))
        #expect(body["limitSeconds"]?["heavySwap"] == .int(10))
        #expect(body["peaks"]?["memDemandBytes"] == .int(30_000_000_000))
        #expect(body["peaks"]?["swapBytes"] == .int(5_000_000_000))
        #expect(body["peaks"]?["pressure"] == .string("critical"))
        #expect(body["topGroups"]?["byCPU"]?.arrayValue?.compactMap { $0["group"]?.stringValue } == ["go", "containers", "browsers"])
        #expect(body["topGroups"]?["byMemory"]?[0]?["group"] == .string("containers"))
        #expect(body["topProcesses"]?["byCPU"]?[0]?["name"] == .string("compile"))
        #expect(body["topProcesses"]?["byCPU"]?[0]?["cpuCores"] == .double(0.9))
        #expect(body["topProcesses"]?["byMemory"]?[0]?["bytes"] == .int(8_000_000_000))
        #expect(body["rawDataKept"] == .bool(true))
        #expect(body["agentRuns"]?[0]?["tool"] == .string("claude"))
        #expect(body["agentRuns"]?[0]?["cpuSeconds"] == .int(120))
        #expect(body["leftovers"]?["count"] == .int(2))
        #expect(body["leftovers"]?["bytes"] == .int(3000))
        #expect(body["leftovers"]?["peakBytesInWindow"] == .int(3000))
        let kinds = body["events"]?.arrayValue?.compactMap { $0["kind"]?.stringValue }
        #expect(kinds == ["tag", "leftover"])
        #expect(body["events"]?[0]?["payload"]?["text"] == .string("build"))
        #expect(result.summary.contains("memoryLimited"))
    }

    @Test func currentStatusReadsLiveStateAndSidecar() throws {
        let f = try MCPFixture()
        var writer = try LiveStateWriter(url: f.paths.liveState)
        writer.write(
            LiveSnapshot(
                timestamp: now - 5, cpuBusy: 0.25, memUsed: 8_000_000_000, memTotal: 16_000_000_000, swapUsed: 0,
                diskFree: 1, diskCapacity: 2, pressure: 1, thermal: 0, limitFlags: 0, activeAgents: 1, idleAgents: 0))
        let item = LeftoverItem(
            key: "default/compose/db", engine: "default", kind: .compose, name: "db", containerIDs: ["c1"],
            sessionId: nil, lifetime: nil, cleanup: ["docker --context default compose -p db stop"])
        try LeftoverState(
            updated: now, items: [FlaggedItem(item: item, startedAt: now - 7200, reason: "done", memoryBytes: 500, firstFlagged: now)]
        ).save(to: f.paths.leftovers)
        let ts = Int(now) - 30
        try f.exec(
            """
            INSERT INTO group_samples VALUES('\(f.machineId)', \(ts), 'go', 60, 1000, 0, 4);
            INSERT INTO group_samples VALUES('\(f.machineId)', \(ts - 600), 'browsers', 999, 1000, 0, 4);
            INSERT INTO top_procs_1m VALUES('\(f.machineId)', \(ts), 'cpu', 1, 'compile', 'go', 5.0);
            INSERT INTO top_procs_1m VALUES('\(f.machineId)', \(ts - 600), 'cpu', 1, 'old', 'go', 5.0);
            INSERT INTO agent_runs(run_id, machine_id, tool, root_pid, root_start, started, ended)
                VALUES(1, '\(f.machineId)', 'codex', 100, 1, \(Int(now) - 600), NULL);
            INSERT INTO agent_runs(run_id, machine_id, tool, root_pid, root_start, started, ended)
                VALUES(2, '\(f.machineId)', 'claude', 101, 1, \(Int(now) - 900), \(Int(now) - 300));
            INSERT INTO run_usage VALUES(1, \(ts), 12, 3000, 0, 30);
            """)
        let result = try f.call("current_status")
        #expect(!result.isError)
        #expect(result.summary.contains("mem 50%"))
        #expect(result.body["live"]?["cpuBusy"] == .double(0.25))
        #expect(result.body["topGroups"]?.arrayValue?.compactMap { $0["group"]?.stringValue } == ["go"])
        #expect(result.body["topGroups"]?[0]?["cpuCores"] == .int(1))
        #expect(result.body["topProcesses"]?["byCPU"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["compile"])
        #expect(result.body["agentRuns"]?.arrayValue?.count == 1)
        #expect(result.body["agentRuns"]?[0]?["tool"] == .string("codex"))
        #expect(result.body["agentRuns"]?[0]?["active"] == .bool(true))
        #expect(result.body["leftovers"]?["count"] == .int(1))
        #expect(result.body["leftovers"]?["items"]?[0]?["cleanup"]?[0] == .string("docker --context default compose -p db stop"))
    }

    @Test func nonFiniteLiveStateDoesNotTrap() throws {
        let f = try MCPFixture()
        var writer = try LiveStateWriter(url: f.paths.liveState)
        writer.write(
            LiveSnapshot(
                timestamp: .nan, cpuBusy: .infinity, memUsed: 1, memTotal: 2, swapUsed: 0, diskFree: 0, diskCapacity: 0,
                pressure: 9, thermal: 9, limitFlags: 0, activeAgents: 0, idleAgents: 0))
        let stale = try f.call("current_status")
        #expect(!stale.isError)
        #expect(stale.summary.hasPrefix("recorder not running"))
        #expect(stale.body["live"]?["pressure"] == .string("unknown"))

        writer.write(
            LiveSnapshot(
                timestamp: now, cpuBusy: .nan, memUsed: 1, memTotal: 2, swapUsed: 0, diskFree: 0, diskCapacity: 0,
                pressure: 1, thermal: 0, limitFlags: 1, activeAgents: 0, idleAgents: 0))
        let fresh = try f.call("current_status")
        #expect(fresh.summary.contains("cpu 0%"))
        #expect(fresh.body["live"]?["limits"] == .array([.string("memoryLimited")]))
    }

    @Test func relativeAndISOTimes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let base = 1_800_000_000.0
        #expect(MCPTime.parse("-30m", now: base, calendar: calendar) == base - 1800)
        #expect(MCPTime.parse("-2h", now: base, calendar: calendar) == base - 7200)
        #expect(MCPTime.parse("-1d", now: base, calendar: calendar) == base - 86_400)
        #expect(MCPTime.parse("now", now: base, calendar: calendar) == base)
        #expect(MCPTime.parse("2027-01-15T08:00:00Z", now: base, calendar: calendar) == 1_800_000_000)
        #expect(MCPTime.parse("2027-01-15T09:00:00+01:00", now: base, calendar: calendar) == 1_800_000_000)
        #expect(MCPTime.parse("2027-01-15T08:00:00.500Z", now: base, calendar: calendar) == 1_800_000_000.5)
        // No offset means the calendar's local time: 00:00 in Los Angeles is 08:00 UTC in January.
        #expect(MCPTime.parse("2027-01-15T00:00:00", now: base, calendar: calendar) == 1_800_000_000)
        #expect(MCPTime.parse("2027-01-15T00:00", now: base, calendar: calendar) == 1_800_000_000)
        #expect(MCPTime.parse("2027-01-15 00:00", now: base, calendar: calendar) == 1_800_000_000)
        #expect(MCPTime.parse("2027-01-15", now: base, calendar: calendar) == 1_800_000_000)
        for bad in ["", "-", "-h", "-2x", "-1.5h", "--2h", "2027-02-30T00:00", "2027-01-15T25:00", "15:00", "soon", "-inf"] {
            #expect(MCPTime.parse(bad, now: base, calendar: calendar) == nil, "\(bad)")
        }
    }

    @Test func serveStopsOnEOF() throws {
        let f = try MCPFixture(seed: false)
        let input = Pipe()
        let output = Pipe()
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            "",
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
        ]
        try input.fileHandleForWriting.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        f.server.serve(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try output.fileHandleForWriting.close()
        let written = try #require(try output.fileHandleForReading.readToEnd())
        let replies = String(decoding: written, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(replies.count == 3)
        #expect(replies.last == "")
        let ids = try replies.dropLast().map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))["id"] }
        #expect(ids == [.int(1), .int(2)])
    }

    /// Feeds `input` through a real pipe from another thread, since a write larger than the pipe buffer would block.
    private func serve(_ input: Data) throws -> [JSONValue] {
        let f = try MCPFixture(seed: false)
        let inPipe = Pipe()
        let outPipe = Pipe()
        let writer = inPipe.fileHandleForWriting
        let done = DispatchSemaphore(value: 0)
        Thread {
            try? writer.write(contentsOf: input)
            try? writer.close()
            done.signal()
        }.start()
        f.server.serve(input: inPipe.fileHandleForReading, output: outPipe.fileHandleForWriting)
        done.wait()
        try outPipe.fileHandleForWriting.close()
        let written = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        return try String(decoding: written, as: UTF8.self).split(separator: "\n").map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
    }

    /// A ping padded past the cap. It is valid JSON, so only the cap can turn it into a parse error.
    private func paddedPing(id: Int, bytes: Int) -> String {
        let prefix = #"{"jsonrpc":"2.0","id":\#(id),"method":"ping","params":{"pad":""#
        let suffix = #""}}"#
        return prefix + String(repeating: "a", count: bytes - prefix.utf8.count - suffix.utf8.count) + suffix
    }

    @Test func oversizedLineIsOneParseErrorThenServingContinues() throws {
        let input = Data((paddedPing(id: 4, bytes: 2 << 20) + "\n" + #"{"jsonrpc":"2.0","id":5,"method":"ping"}"# + "\n").utf8)
        let replies = try serve(input)
        #expect(replies.count == 2)
        #expect(replies.first?["error"]?["code"] == .int(-32700))
        #expect(replies.first?["id"] == .null)
        #expect(replies.last?["id"] == .int(5))
        #expect(replies.last?["result"] == .object([:]))
    }

    @Test func lineJustUnderTheCapParses() throws {
        let line = paddedPing(id: 6, bytes: (1 << 20) - 1)
        #expect(line.utf8.count == (1 << 20) - 1)
        let replies = try serve(Data((line + "\n" + line + "\n").utf8))
        #expect(replies.map { $0["id"] } == [.int(6), .int(6)])
    }

    @Test func oversizedFinalLineWithoutNewlineIsOneParseError() throws {
        let replies = try serve(Data(paddedPing(id: 7, bytes: (1 << 20) + 10).utf8))
        #expect(replies.count == 1)
        #expect(replies.first?["error"]?["code"] == .int(-32700))
    }

    /// A live client keeps stdin open and waits for each reply. Earlier tests closed the pipe first, which hid a
    /// read that waited for 64 KiB or EOF before handing anything back.
    @Test func repliesWhileTheClientHoldsThePipeOpen() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "headroom-mcp-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(root: root)
        let inPipe = Pipe()
        let outPipe = Pipe()
        let reader = outPipe.fileHandleForReading
        let serverOut = outPipe.fileHandleForWriting
        let serverIn = inPipe.fileHandleForReading
        let lines = Mutex<[String]>([])
        let finished = Mutex(false)

        Thread {
            MCPServer(paths: paths, now: { now }).serve(input: serverIn, output: serverOut)
            finished.withLock { $0 = true }
            try? serverOut.close()
        }.start()
        Thread {
            var pending = Data()
            while let chunk = try? reader.read(upToCount: 1), !chunk.isEmpty {
                pending.append(chunk)
                if chunk == Data([0x0A]) {
                    let line = String(decoding: pending.dropLast(), as: UTF8.self)
                    lines.withLock { $0.append(line) }
                    pending = Data()
                }
            }
        }.start()

        func waitFor(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if condition() { return true }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return condition()
        }

        let writer = inPipe.fileHandleForWriting
        try writer.write(contentsOf: Data((#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"# + "\n").utf8))
        #expect(waitFor { lines.withLock { $0.count } == 1 }, "initialize reply must arrive while stdin is open")
        try writer.write(contentsOf: Data((#"{"jsonrpc":"2.0","id":2,"method":"ping"}"# + "\n").utf8))
        #expect(waitFor { lines.withLock { $0.count } == 2 }, "ping reply must arrive while stdin is open")
        #expect(!finished.withLock { $0 })

        try writer.close()
        #expect(waitFor { finished.withLock { $0 } }, "serve returns at EOF")
        let ids = try lines.withLock { $0 }.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))["id"] }
        #expect(ids == [.int(1), .int(2)])
    }

    @Test func jsonValueRoundTripsIds() throws {
        for text in [#"7"#, #""seven""#, #"-3"#, #"1.5"#, #"true"#, #"null"#, #"{"a":[1,"b",false]}"#] {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            #expect(String(decoding: try JSONEncoder().encode(value), as: UTF8.self) == text)
        }
    }
}

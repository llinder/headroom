import Darwin
import Foundation
import Testing

@testable import HeadroomCLI
@testable import HeadroomCore

private func scratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "headroom-hook-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func identity(_ pid: Int32, ppid: Int32, path: String) -> ProcessIdentity {
    ProcessIdentity(
        key: ProcessKey(pid: pid, start: UInt64(pid) * 1000), ppid: ppid, uid: 501,
        name: String(path.split(separator: "/").last ?? ""), path: path)
}

/// `drain` reads one cycle behind, so a second call is needed to see what was just appended.
private func spooled(_ spool: Spool) -> [SpoolRecord] {
    spool.drain().records + spool.drain().records
}

private func runProcess(_ path: String, _ args: [String], stdin: Data? = nil, environment: [String: String]? = nil)
    throws -> (status: Int32, stdout: String, stderr: String)
{
    let process = Process()
    process.executableURL = URL(filePath: path)
    process.arguments = args
    if let environment { process.environment = environment }
    let out = Pipe()
    let err = Pipe()
    let input = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = input
    try process.run()
    if let stdin { input.fileHandleForWriting.write(stdin) }
    try input.fileHandleForWriting.close()
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
}

private let releaseBinary: URL? = {
    let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: ".build/release/headroom")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}()

@Suite struct AgentHookTests {
    @Test func findsRoot() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = Spool(url: dir.appending(path: "spool.jsonl"))
        let chain: [Int32: ProcessIdentity] = [
            10: identity(10, ppid: 20, path: "/bin/sh"),
            20: identity(20, ppid: 30, path: "/usr/local/bin/claude"),
            30: identity(30, ppid: 40, path: "/bin/zsh"),
            40: identity(40, ppid: 50, path: "/usr/local/bin/claude"),
            50: identity(50, ppid: 1, path: "/usr/bin/login"),
        ]
        let stdin = Data(#"{"session_id":"abc","model":"claude-opus-5-5","cwd":"/x"}"#.utf8)

        #expect(AgentHook.record(tool: "claude", stdin: stdin, parentPid: 10, lookup: { chain[$0] }, spool: spool, now: 100))

        let raw = try String(contentsOf: spool.url, encoding: .utf8)
        #expect(!raw.contains("/x"))
        #expect(spooled(spool) == [
            .agentSession(ts: 100, tool: "claude", sessionId: "abc", model: "claude-opus-5-5", rootPid: 40, rootStart: 40_000)
        ])
    }

    @Test func userAgentRulesMoveTheRoot() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = Spool(url: dir.appending(path: "spool.jsonl"))
        let chain: [Int32: ProcessIdentity] = [
            10: identity(10, ppid: 20, path: "/usr/local/bin/claude"),
            20: identity(20, ppid: 1, path: "/opt/bin/agent-wrapper"),
        ]
        let rules = dir.appending(path: "groups.json")
        try Data(#"{"rules":[{"group":"agents","names":["agent-wrapper"],"pathPrefixes":[]}]}"#.utf8).write(to: rules)
        let stdin = Data(#"{"session_id":"s"}"#.utf8)
        #expect(AgentHook.record(
            tool: "claude", stdin: stdin, parentPid: 10, lookup: { chain[$0] }, spool: spool, now: 1,
            rules: GroupRules.effective(from: rules).0))
        #expect(spooled(spool) == [.agentSession(ts: 1, tool: "claude", sessionId: "s", model: nil, rootPid: 20, rootStart: 20_000)])
    }

    @Test func modelIsOptional() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = Spool(url: dir.appending(path: "spool.jsonl"))
        let chain: [Int32: ProcessIdentity] = [10: identity(10, ppid: 1, path: "/opt/bin/codex")]
        #expect(AgentHook.record(tool: "codex", stdin: Data(#"{"session_id":"s"}"#.utf8), parentPid: 10, lookup: { chain[$0] }, spool: spool, now: 1))
        #expect(spooled(spool) == [.agentSession(ts: 1, tool: "codex", sessionId: "s", model: nil, rootPid: 10, rootStart: 10_000)])
    }

    @Test func badStdinStillExitsCleanly() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = Spool(url: dir.appending(path: "spool.jsonl"))
        let chain: [Int32: ProcessIdentity] = [10: identity(10, ppid: 1, path: "/usr/local/bin/claude")]
        #expect(!AgentHook.record(tool: "claude", stdin: Data("not json".utf8), parentPid: 10, lookup: { chain[$0] }, spool: spool, now: 1))
        #expect(!AgentHook.record(tool: "claude", stdin: Data(#"{"model":"m"}"#.utf8), parentPid: 10, lookup: { chain[$0] }, spool: spool, now: 1))
        #expect(spooled(spool).isEmpty)
    }

    @Test func noAgentAncestor() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = Spool(url: dir.appending(path: "spool.jsonl"))
        let chain: [Int32: ProcessIdentity] = [
            10: identity(10, ppid: 20, path: "/bin/sh"),
            20: identity(20, ppid: 1, path: "/bin/zsh"),
        ]
        #expect(!AgentHook.record(tool: "claude", stdin: Data(#"{"session_id":"a"}"#.utf8), parentPid: 10, lookup: { chain[$0] }, spool: spool, now: 1))
        #expect(spooled(spool).isEmpty)
    }

    @Test func unknownToolIsRejected() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = Spool(url: dir.appending(path: "spool.jsonl"))
        let chain: [Int32: ProcessIdentity] = [10: identity(10, ppid: 1, path: "/usr/local/bin/claude")]
        #expect(!AgentHook.record(tool: "vim", stdin: Data(#"{"session_id":"a"}"#.utf8), parentPid: 10, lookup: { chain[$0] }, spool: spool, now: 1))
    }

    @Test func walkStopsAtMissingProcessAndOnParentLoop() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = Spool(url: dir.appending(path: "spool.jsonl"))
        let stdin = Data(#"{"session_id":"a"}"#.utf8)

        let blocked: [Int32: ProcessIdentity] = [
            10: identity(10, ppid: 20, path: "/usr/local/bin/claude"),
            30: identity(30, ppid: 1, path: "/usr/local/bin/claude"),
        ]
        #expect(AgentHook.record(tool: "claude", stdin: stdin, parentPid: 10, lookup: { blocked[$0] }, spool: spool, now: 1))
        #expect(spooled(spool) == [.agentSession(ts: 1, tool: "claude", sessionId: "a", model: nil, rootPid: 10, rootStart: 10_000)])

        let loop: [Int32: ProcessIdentity] = [
            10: identity(10, ppid: 11, path: "/bin/sh"),
            11: identity(11, ppid: 10, path: "/bin/sh"),
        ]
        #expect(!AgentHook.record(tool: "claude", stdin: stdin, parentPid: 10, lookup: { loop[$0] }, spool: spool, now: 1))
    }

    @Test func stdinReadIsBoundedAndHonoursDeadline() {
        // The reader stops at its cap and closes while the writer is still writing.
        signal(SIGPIPE, SIG_IGN)
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let (readEnd, writeEnd) = (fds[0], fds[1])
        let writer = Thread {
            let chunk = [UInt8](repeating: 0x61, count: 1024)
            for _ in 0..<200 where write(writeEnd, chunk, chunk.count) <= 0 { break }
            close(writeEnd)
        }
        writer.start()
        #expect(AgentHook.readStdin(fd: readEnd).count == 64 * 1024)
        close(readEnd)

        // A writer that never closes its end must not stall the reader.
        var idle: [Int32] = [0, 0]
        #expect(pipe(&idle) == 0)
        defer { close(idle[0]); close(idle[1]) }
        let start = DispatchTime.now().uptimeNanoseconds
        #expect(AgentHook.readStdin(fd: idle[0]).isEmpty)
        #expect(DispatchTime.now().uptimeNanoseconds - start < 500_000_000)
    }

    @Test func recordCommandStripsPath() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = Spool(url: dir.appending(path: "spool.jsonl"))
        #expect(ShellHook.recordCommand(exe: "/usr/local/go/bin/go", seconds: 42, spool: spool, now: 1000))
        #expect(spooled(spool) == [.command(ts: 958, exe: "go", seconds: 42)])
    }

    @Test func recordCommandRejectsBadSeconds() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = Spool(url: dir.appending(path: "spool.jsonl"))
        for seconds in [Double.nan, .infinity, -1, 32 * 24 * 3600] {
            #expect(!ShellHook.recordCommand(exe: "go", seconds: seconds, spool: spool, now: 1000))
        }
        #expect(!ShellHook.recordCommand(exe: "/", seconds: 40, spool: spool, now: 1000))
        #expect(spooled(spool).isEmpty)
    }

    @Test func snippetShape() {
        let snippet = ShellHook.zshSnippet
        #expect(snippet.contains("add-zsh-hook preexec"))
        #expect(snippet.contains("add-zsh-hook precmd"))
        #expect(snippet.contains("headroom record-command"))
        #expect(snippet.contains("zmodload zsh/datetime"))
        #expect(snippet.contains("${(z)1}"))
        #expect(!snippet.contains("$1\""))
        #expect(snippet.contains("$HOME/.local/bin/headroom"))
    }

    /// Runs the snippet in a real zsh against a stub `headroom` so the quoting and word splitting are exercised.
    private func runSnippet(command: String, elapsed: Double, stub: Bool = true) throws -> (log: String, stderr: String) {
        let home = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = home.appending(path: "log")
        if stub {
            let path = bin.appending(path: "headroom")
            try "#!/bin/sh\necho \"$@\" > '\(log.path)'\n".write(to: path, atomically: true, encoding: .utf8)
            chmod(path.path, 0o755)
        }
        let quoted = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
            \(ShellHook.zshSnippet)
            _headroom_preexec \(quoted)
            _headroom_start=$(( EPOCHREALTIME - \(elapsed) ))
            _headroom_precmd
            [[ -z $_headroom_start && -z $_headroom_exe ]] || echo leaked
            sleep 0.5
            """
        let result = try runProcess("/bin/zsh", ["-f", "-c", script], environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        #expect(result.status == 0)
        #expect(!result.stdout.contains("leaked"))
        return ((try? String(contentsOf: log, encoding: .utf8)) ?? "", result.stderr)
    }

    private func recordedExe(_ command: String, elapsed: Double = 45) throws -> String? {
        let (log, stderr) = try runSnippet(command: command, elapsed: elapsed)
        #expect(stderr.isEmpty)
        let fields = log.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 3, fields[0] == "record-command" else { return nil }
        #expect((Double(fields[2]) ?? 0) >= elapsed - 0.05)
        return fields[1]
    }

    @Test func snippetRecordsLongCommandWithFirstWordOnly() throws {
        #expect(try recordedExe("go test ./... -run 'a b'") == "go")
    }

    @Test func snippetSkipsEnvAssignmentsAndRedirections() throws {
        #expect(try recordedExe("API_KEY=s3cr3t go test ./x") == "go")
        #expect(try recordedExe("A=1 B=2 make") == "make")
        #expect(try recordedExe(">/tmp/f make") == "make")
        #expect(try recordedExe("2>/tmp/f make") == "make")
        #expect(try recordedExe("2> /tmp/f make") == "make")
        #expect(try recordedExe("! make") == "make")
        #expect(try recordedExe("API_KEY=s3cr3t") == nil)
        let (log, _) = try runSnippet(command: "API_KEY=s3cr3t go test ./x", elapsed: 45)
        #expect(!log.contains("s3cr3t"))
    }

    @Test func snippetIgnoresShortCommands() throws {
        #expect(try recordedExe("ls", elapsed: 5) == nil)
    }

    @Test func snippetThreshold() throws {
        #expect(try recordedExe("go", elapsed: 29.9) == nil)
        #expect(try recordedExe("go", elapsed: 30.1) == "go")
    }

    @Test func snippetIsQuietWhenHeadroomIsMissing() throws {
        let (log, stderr) = try runSnippet(command: "go test", elapsed: 45, stub: false)
        #expect(log.isEmpty)
        #expect(stderr.isEmpty)
    }

    @Test func recordCommandRejectsUnsafeNames() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = Spool(url: dir.appending(path: "spool.jsonl"))
        for exe in ["API_KEY=x", String(repeating: "a", count: 65), "a b", "x;y"] {
            #expect(!ShellHook.recordCommand(exe: exe, seconds: 40, spool: spool, now: 1000))
        }
        #expect(ShellHook.recordCommand(exe: String(repeating: "a", count: 64), seconds: 40, spool: spool, now: 1000))
        #expect(ShellHook.recordCommand(exe: "g++-14.2_x+y", seconds: 40, spool: spool, now: 1000))
        #expect(spooled(spool).count == 2)
    }

    private static let pretoolNow = 1_000_000.0
    private static let agentChain: [Int32: ProcessIdentity] = [
        10: identity(10, ppid: 20, path: "/bin/zsh"),
        20: identity(20, ppid: 1, path: "/usr/local/bin/claude"),
    ]

    private func pretoolSnapshot(age: Double = 1, pressure: UInt8 = 1) -> LiveSnapshot {
        LiveSnapshot(
            timestamp: Self.pretoolNow - age, cpuBusy: 0, memUsed: 0, memTotal: 0, swapUsed: 14_000_000_000,
            diskFree: 0, diskCapacity: 0, pressure: pressure, thermal: 0, limitFlags: 0,
            activeAgents: 0, idleAgents: 0, swapGrowthBytesPerMin: pressure == 4 ? 600_000_000 : 0)
    }

    private func bashInput(_ command: String, session: String = "s1", agent: String? = nil) -> Data {
        var object: [String: Any] = [
            "session_id": session, "hook_event_name": "PreToolUse", "tool_name": "Bash",
            "tool_input": ["command": command, "description": "d"],
        ]
        if let agent { object["agent_id"] = agent }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func pretool(
        _ stdin: Data, snapshot: LiveSnapshot?, paths: Paths, now: Double = pretoolNow, tool: String = "claude"
    ) -> (stdout: String?, spool: [SpoolRecord]) {
        AgentHook.pretool(
            tool: tool, stdin: { stdin }, snapshot: snapshot, now: now, paths: paths, config: { HeadroomConfig() },
            parentPid: 10, lookup: { Self.agentChain[$0] }, rules: { .defaults })
    }

    private func throttleFiles(_ paths: Paths) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: paths.pretool.path)) ?? []
    }

    @Test func noTriggerNoOutputButIntentRecorded() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(root: dir)
        let result = pretool(bashInput("docker run x"), snapshot: pretoolSnapshot(), paths: paths)
        #expect(result.stdout == nil)
        let intent = SpoolRecord.containerIntent(ts: Self.pretoolNow, rootPid: 20, rootStart: 20_000)
        #expect(result.spool == [intent])
        #expect(spooled(Spool(url: paths.spool)) == [intent])
    }

    @Test func staleSnapshotStillRecordsKubectlAndHelmIntents() throws {
        for command in ["kubectl apply -f x", "helm install x ./chart"] {
            let dir = try scratchDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let result = pretool(bashInput(command), snapshot: pretoolSnapshot(age: 600), paths: Paths(root: dir))
            #expect(result.stdout == nil)
            #expect(result.spool == [SpoolRecord.containerIntent(ts: Self.pretoolNow, rootPid: 20, rootStart: 20_000)],
                    "\(command)")
        }
    }

    @Test func intentIsThrottledPerMinuteAndRecordedWithoutSnapshot() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(root: dir)
        #expect(pretool(bashInput("kind create cluster"), snapshot: nil, paths: paths).spool.count == 1)
        #expect(pretool(bashInput("kind create cluster"), snapshot: nil, paths: paths, now: Self.pretoolNow + 30).spool.isEmpty)
        #expect(pretool(bashInput("kind create cluster"), snapshot: nil, paths: paths, now: Self.pretoolNow + 60).spool.count == 1)
        #expect(pretool(bashInput("ls"), snapshot: nil, paths: paths, now: Self.pretoolNow + 600).spool.isEmpty)
        #expect(spooled(Spool(url: paths.spool)).count == 2)
    }

    @Test func criticalGivesAdviceOncePerFiveMinutes() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(root: dir)
        let first = pretool(bashInput("go test ./..."), snapshot: pretoolSnapshot(pressure: 4), paths: paths)
        let second = pretool(
            bashInput("go test ./..."), snapshot: pretoolSnapshot(age: -59, pressure: 4), paths: paths,
            now: Self.pretoolNow + 60)
        #expect(first.stdout != nil)
        #expect(first.spool == [.agentWarning(ts: Self.pretoolNow)])
        #expect(second.stdout == nil)
        #expect(second.spool.isEmpty)
        #expect(spooled(Spool(url: paths.spool)) == [.agentWarning(ts: Self.pretoolNow)])
        let later = pretool(
            bashInput("go test ./..."), snapshot: pretoolSnapshot(age: -299, pressure: 4), paths: paths,
            now: Self.pretoolNow + 300)
        #expect(later.stdout != nil)
    }

    @Test func subagentsThrottledSeparately() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(root: dir)
        let snapshot = pretoolSnapshot(pressure: 4)
        #expect(pretool(bashInput("make", agent: "a1"), snapshot: snapshot, paths: paths).stdout != nil)
        #expect(pretool(bashInput("make", agent: "a2"), snapshot: snapshot, paths: paths).stdout != nil)
        #expect(pretool(bashInput("make"), snapshot: snapshot, paths: paths).stdout != nil)
        #expect(pretool(bashInput("make", agent: "a1"), snapshot: snapshot, paths: paths).stdout == nil)
        #expect(Set(throttleFiles(paths)) == ["s1.a1", "s1.a2", "s1"])
    }

    @Test func malformedStdinIsSilent() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(root: dir)
        let inputs = [
            Data(), Data("not json".utf8), Data(repeating: 0x78, count: 70 * 1024),
            Data(#"{"session_id":"s1","tool_name":"Bash","note":"docker run x"}"#.utf8),
            bashInput("docker run x", session: "../etc"),
        ]
        for input in inputs {
            let result = pretool(input, snapshot: pretoolSnapshot(pressure: 4), paths: paths)
            #expect(result.stdout == nil)
            #expect(result.spool.isEmpty)
        }
        #expect(spooled(Spool(url: paths.spool)).isEmpty)
        #expect(throttleFiles(paths).isEmpty)
    }

    @Test func unknownToolIsSilentForPretool() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(root: dir)
        let result = pretool(bashInput("docker run x"), snapshot: pretoolSnapshot(pressure: 4), paths: paths, tool: "vim")
        #expect(result.stdout == nil)
        #expect(result.spool.isEmpty)
        #expect(throttleFiles(paths).isEmpty)
    }

    @Test func outputJSONShape() throws {
        struct Output: Decodable {
            struct Specific: Decodable {
                let hookEventName: String
                let additionalContext: String
            }
            let hookSpecificOutput: Specific
        }
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(root: dir)
        let snapshot = pretoolSnapshot(pressure: 4)
        for tool in ["claude", "codex"] {
            let stdout = try #require(
                pretool(bashInput("go test ./...", session: tool), snapshot: snapshot, paths: paths, tool: tool).stdout)
            #expect(!stdout.contains("\n"))
            #expect(!stdout.contains("permissionDecision"))
            let output = try JSONDecoder().decode(Output.self, from: Data(stdout.utf8))
            #expect(output.hookSpecificOutput.hookEventName == "PreToolUse")
            #expect(output.hookSpecificOutput.additionalContext
                == PreToolAdvice.text(trigger: .critical, kind: .go, snapshot: snapshot))
        }
    }

    @Test func unknownModeOnOldBinaryShape() throws {
        #expect(HeadroomCLI.run(["headroom", "agent-hook", "pretool"]) == 0)
        #expect(try parse(["headroom", "agent-hook", "pretool", "claude"]) == .agentPretool(tool: "claude"))
        #expect(try parse(["headroom", "agent-hook", "claude"]) == .agentHook(tool: "claude"))
    }

    @Test(.enabled(if: releaseBinary != nil, "needs `swift build -c release`"), .enabled(if: ProcessInfo.processInfo.environment["HEADROOM_BENCH"] == "1", "wall-clock budget; run via make bench"))
    func pretoolIsFast() throws {
        let binary = try #require(releaseBinary)
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var writer = try LiveStateWriter(url: Paths(root: dir).liveState)
        let written = writer.write(pretoolSnapshot(age: Date().timeIntervalSince1970 - Self.pretoolNow + 3600, pressure: 4))
        #expect(written)

        var durations: [Double] = []
        for _ in 0..<100 {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try runProcess(
                binary.path, ["agent-hook", "pretool", "claude"], stdin: bashInput("go test ./..."),
                environment: ["HEADROOM_ROOT": dir.path])
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            #expect(result.status == 0)
            #expect(result.stdout.isEmpty)
        }
        let median = durations.sorted()[50]
        #expect(median < 10, "median \(median) ms")
    }

    // Wall-clock budgets are flaky on a loaded machine, so they only run under `make bench`.
    @Test(.enabled(if: releaseBinary != nil, "needs `swift build -c release`"), .enabled(if: ProcessInfo.processInfo.environment["HEADROOM_BENCH"] == "1", "wall-clock budget; run via make bench"))
    func releaseBinaryHookIsFast() throws {
        let binary = try #require(releaseBinary)
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var durations: [Double] = []
        for _ in 0..<100 {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try runProcess(
                binary.path, ["agent-hook", "claude"], stdin: Data(#"{"session_id":"x"}"#.utf8),
                environment: ["HEADROOM_ROOT": dir.path])
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            #expect(result.status == 0)
            #expect(result.stdout.isEmpty)
        }
        let median = durations.sorted()[50]
        #expect(median < 10, "median \(median) ms")
    }
}

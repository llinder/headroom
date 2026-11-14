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
        #expect(snippet.contains("${${(z)1}[1]}"))
        #expect(!snippet.contains("$1\""))
        #expect(snippet.contains("$HOME/.local/bin/headroom"))
    }

    /// Runs the snippet in a real zsh against a stub `headroom` so the quoting and word splitting are exercised.
    private func runSnippet(command: String, elapsed: Int) throws -> String {
        let home = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = home.appending(path: "log")
        let stub = bin.appending(path: "headroom")
        try "#!/bin/sh\necho \"$@\" > '\(log.path)'\n".write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)
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
        #expect(result.stderr.isEmpty)
        #expect(!result.stdout.contains("leaked"))
        return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    @Test func snippetRecordsLongCommandWithFirstWordOnly() throws {
        let log = try runSnippet(command: "go test ./... -run 'a b'", elapsed: 45)
        let fields = log.split(whereSeparator: \.isWhitespace).map(String.init)
        #expect(fields.count == 3)
        #expect(Array(fields.prefix(2)) == ["record-command", "go"])
        #expect((Double(fields.last ?? "") ?? 0) >= 45)
    }

    @Test func snippetIgnoresShortCommands() throws {
        #expect(try runSnippet(command: "ls", elapsed: 5).isEmpty)
    }

    @Test func releaseBinaryHookIsFast() throws {
        let binary = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".build/release/headroom")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The rest of the suite runs in parallel and can starve a batch, so a quiet batch is what counts.
        var medians: [Double] = []
        for _ in 0..<3 {
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
            medians.append(durations.sorted()[50])
            if medians.last ?? .infinity < 5 { return }
        }
        #expect(Bool(false), "medians \(medians) ms")
    }
}

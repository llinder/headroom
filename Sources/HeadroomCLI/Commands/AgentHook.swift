import Darwin
import Foundation
import HeadroomCore

public enum AgentHook {
    private static let maxStdinBytes = 64 * 1024
    private static let stdinDeadline = 0.05
    private static let maxHops = 64
    private static let tools: Set<String> = ["claude", "codex"]

    private struct Payload: Decodable {
        let session_id: String
        let model: String?
    }

    private struct PretoolPayload: Decodable {
        struct ToolInput: Decodable {
            let command: String
        }
        let session_id: String
        let agent_id: String?
        let tool_input: ToolInput
    }

    private struct HookOutput: Encodable {
        struct Specific: Encodable {
            let hookEventName = "PreToolUse"
            let additionalContext: String
        }
        let hookSpecificOutput: Specific
    }

    private static let containerWords = ["docker", "kind", "compose", "kubectl", "helm"]

    /// Always returns 0: a hook must never fail the agent that runs it.
    static func run(tool: String) -> Int32 {
        let paths = Paths.standard()
        let recorded = record(
            tool: tool, stdin: readStdin(fd: STDIN_FILENO), parentPid: getppid(), lookup: ProcessSampler.identity,
            spool: Spool(url: paths.spool), now: Date().timeIntervalSince1970,
            rules: GroupRules.effective(from: paths.groups).0)
        if !recorded { FileHandle.standardError.write(Data("headroom: agent-hook recorded nothing\n".utf8)) }
        return 0
    }

    /// Skips config loading and the rest of the CLI because it runs on every agent session start.
    public static func runFast(tool: String) -> Never {
        signal(SIGPIPE, SIG_IGN)
        exit(run(tool: tool))
    }

    /// Always returns 0 and never sets a permission decision: the advice must not block or fail the command.
    static func runPretool(tool: String) -> Int32 {
        guard tools.contains(tool) else { return 0 }
        let paths = Paths.standard()
        // live.state comes first: when it is stale and the command names no container tool, nothing else is read.
        let snapshot = LiveStateReader.read(url: paths.liveState)
        let result = pretool(
            tool: tool, stdin: { readStdin(fd: STDIN_FILENO) }, snapshot: snapshot, now: Date().timeIntervalSince1970,
            paths: paths, config: { HeadroomConfig.load(from: paths.config).0 }, parentPid: getppid(),
            lookup: ProcessSampler.identity, rules: { GroupRules.effective(from: paths.groups).0 })
        if let stdout = result.stdout { try? FileHandle.standardOutput.write(contentsOf: Data((stdout + "\n").utf8)) }
        return 0
    }

    /// Runs before every shell command an agent issues, so it skips config loading and the rest of the CLI.
    public static func runPretoolFast(tool: String) -> Never {
        signal(SIGPIPE, SIG_IGN)
        exit(runPretool(tool: tool))
    }

    /// Container intent is recorded before the trigger check, because leftover ownership needs it even when
    /// there is no pressure. Returns the hook JSON to print, if any, and the records it appended to the spool.
    static func pretool(
        tool: String, stdin: () -> Data, snapshot: LiveSnapshot?, now: Double, paths: Paths,
        config: () -> HeadroomConfig, parentPid: Int32, lookup: (Int32) -> ProcessIdentity?, rules: () -> GroupRules
    ) -> (stdout: String?, spool: [SpoolRecord]) {
        guard tools.contains(tool) else { return (nil, []) }
        let fresh = snapshot.map { now - $0.timestamp <= PreToolAdvice.staleSeconds } ?? false
        let raw = stdin()
        guard fresh || mentionsContainerTool(raw),
            let payload = try? JSONDecoder().decode(PretoolPayload.self, from: raw)
        else { return (nil, []) }
        let command = payload.tool_input.command
        let key = payload.agent_id.map { "\(payload.session_id).\($0)" } ?? payload.session_id
        let throttle = PreToolAdvice.Throttle(directory: paths.pretool)
        let spool = Spool(url: paths.spool)
        var appended: [SpoolRecord] = []

        let intentKey = key + ".ci"
        if PreToolAdvice.classify(command, heavy: []).containerIntent,
            throttle.due(key: intentKey, now: now, minutes: 1),
            let root = outermostAgent(from: parentPid, lookup: lookup, rules: rules())
        {
            let record = SpoolRecord.containerIntent(ts: now, rootPid: root.key.pid, rootStart: root.key.start)
            if spool.append(record) {
                throttle.touch(key: intentKey, now: now)
                appended.append(record)
            }
        }

        guard fresh, let snapshot else { return (nil, appended) }
        let agents = config().agents
        guard let trigger = PreToolAdvice.trigger(snapshot, now: now, config: agents),
            throttle.due(key: key, now: now, minutes: agents.adviceMinutes)
        else { return (nil, appended) }
        let text = PreToolAdvice.text(
            trigger: trigger, kind: PreToolAdvice.classify(command, heavy: agents.heavyCommands).kind,
            snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let json = try? encoder.encode(HookOutput(hookSpecificOutput: .init(additionalContext: text))) else {
            return (nil, appended)
        }
        throttle.touch(key: key, now: now)
        let warning = SpoolRecord.agentWarning(ts: now, trigger: trigger)
        if spool.append(warning) { appended.append(warning) }
        return (String(decoding: json, as: UTF8.self), appended)
    }

    /// A byte search over the raw input, so a stale snapshot only pays for JSON decoding when the command
    /// could start a container.
    private static func mentionsContainerTool(_ raw: Data) -> Bool {
        raw.withUnsafeBytes { bytes in
            containerWords.contains { word in
                word.utf8CString.withUnsafeBufferPointer {
                    memmem(bytes.baseAddress, bytes.count, $0.baseAddress, $0.count - 1) != nil
                }
            }
        }
    }

    static func record(
        tool: String, stdin: Data, parentPid: Int32, lookup: (Int32) -> ProcessIdentity?, spool: Spool, now: Double,
        rules: GroupRules = .defaults
    ) -> Bool {
        guard tools.contains(tool), let payload = try? JSONDecoder().decode(Payload.self, from: stdin),
            let root = outermostAgent(from: parentPid, lookup: lookup, rules: rules)
        else { return false }
        return spool.append(
            .agentSession(
                ts: now, tool: tool, sessionId: payload.session_id, model: payload.model, rootPid: root.key.pid,
                rootStart: root.key.start))
    }

    /// Takes the same effective rules as the recorder, so the root it names is the one AgentTracker roots on.
    private static func outermostAgent(
        from start: Int32, lookup: (Int32) -> ProcessIdentity?, rules: GroupRules
    ) -> ProcessIdentity? {
        let classifier = Classifier(rules: rules, currentUID: getuid())
        var outermost: ProcessIdentity?
        var pid = start
        for _ in 0..<maxHops {
            guard pid > 1, let identity = lookup(pid) else { break }
            if classifier.ownGroup(identity) == .agents { outermost = identity }
            pid = identity.ppid
        }
        return outermost
    }

    /// Reads at most 64 KB, giving up on the whole read after 50 ms so a parent that never closes stdin can't stall us.
    static func readStdin(fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(stdinDeadline * 1e9)
        while data.count < maxStdinBytes {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32((deadline - now + 999_999) / 1_000_000))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break }
            let n = read(fd, &buffer, min(buffer.count, maxStdinBytes - data.count))
            if n > 0 {
                data.append(buffer, count: n)
            } else if n == 0 || errno != EINTR {
                break
            }
        }
        return data
    }
}

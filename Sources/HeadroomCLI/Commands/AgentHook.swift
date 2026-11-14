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

    /// Always returns 0: a hook must never fail the agent that runs it.
    static func run(tool: String) -> Int32 {
        let paths = Paths.standard()
        let recorded = record(
            tool: tool, stdin: readStdin(fd: STDIN_FILENO), parentPid: getppid(), lookup: ProcessSampler.identity,
            spool: Spool(url: paths.spool), now: Date().timeIntervalSince1970)
        if !recorded { FileHandle.standardError.write(Data("headroom: agent-hook recorded nothing\n".utf8)) }
        return 0
    }

    /// Skips config loading and the rest of the CLI because it runs on every agent session start.
    public static func runFast(tool: String) -> Never {
        signal(SIGPIPE, SIG_IGN)
        exit(run(tool: tool))
    }

    static func record(
        tool: String, stdin: Data, parentPid: Int32, lookup: (Int32) -> ProcessIdentity?, spool: Spool, now: Double
    ) -> Bool {
        guard tools.contains(tool), let payload = try? JSONDecoder().decode(Payload.self, from: stdin),
            let root = outermostAgent(from: parentPid, lookup: lookup)
        else { return false }
        return spool.append(
            .agentSession(
                ts: now, tool: tool, sessionId: payload.session_id, model: payload.model, rootPid: root.key.pid,
                rootStart: root.key.start))
    }

    /// Uses the built-in rules rather than the user's groups.json so the hook stays fast; the recorder's
    /// AgentTracker only sees the same root when the user hasn't customised the agents group.
    private static func outermostAgent(from start: Int32, lookup: (Int32) -> ProcessIdentity?) -> ProcessIdentity? {
        let classifier = Classifier(rules: .defaults, currentUID: getuid())
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

import Foundation
import HeadroomCore

public struct UsageError: Error, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

public enum Command: Equatable {
    case top
    case status
    case tag(String)
    case report(since: Date?, until: Date?, machine: String?, out: String?)
    case install(agents: Bool)
    case uninstall
    case statusline(format: String?, color: Bool, quiet: Bool)
    case agentHook(tool: String)
    case hookZsh
    case recordCommand(exe: String, seconds: Double)
    case version
    case help
}

let usageText = """
    usage: headroom [command]

      top                        live terminal view (default)
      status                     recorder health and coverage
      tag <text>                 mark the current moment
      report [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--machine ID] [--out FILE]
      install [--agents]         install the LaunchAgent (and agent hooks)
      uninstall                  remove the LaunchAgent
      statusline [--format FMT] [--no-color] [--quiet]
      agent-hook <tool>          hook entry point for agent tools
      hook zsh                   print the zsh preexec/precmd snippet
      record-command <exe> <seconds>
      version
      help
    """

public func parse(_ args: [String]) throws(UsageError) -> Command {
    var rest = Array(args.dropFirst())
    guard !rest.isEmpty else { return .top }
    let name = rest.removeFirst()

    switch name {
    case "top":
        try expectNoArguments(rest, for: name)
        return .top
    case "status":
        try expectNoArguments(rest, for: name)
        return .status
    case "uninstall":
        try expectNoArguments(rest, for: name)
        return .uninstall
    case "version", "--version":
        try expectNoArguments(rest, for: name)
        return .version
    case "help", "--help", "-h":
        return .help
    case "tag":
        if let flag = rest.first(where: { $0.hasPrefix("--") }) { throw UsageError("unknown flag \(flag) for tag") }
        guard !rest.isEmpty else { throw UsageError("tag needs text") }
        return .tag(rest.joined(separator: " "))
    case "report":
        return try parseReport(rest)
    case "install":
        var agents = false
        for arg in rest {
            guard arg == "--agents" else { throw unknown(arg, for: name) }
            agents = true
        }
        return .install(agents: agents)
    case "statusline":
        return try parseStatusline(rest)
    case "agent-hook":
        guard rest.count == 1, let tool = rest.first, !tool.hasPrefix("--") else {
            throw UsageError("agent-hook needs exactly one tool name")
        }
        return .agentHook(tool: tool)
    case "hook":
        guard rest == ["zsh"] else { throw UsageError("hook supports only: zsh") }
        return .hookZsh
    case "record-command":
        guard rest.count == 2, let seconds = Double(rest[1]), seconds >= 0 else {
            throw UsageError("record-command needs <exe> <seconds>")
        }
        return .recordCommand(exe: rest[0], seconds: seconds)
    default:
        throw UsageError("unknown command \(name)")
    }
}

private func unknown(_ arg: String, for command: String) -> UsageError {
    arg.hasPrefix("-") ? UsageError("unknown flag \(arg) for \(command)") : UsageError("unexpected argument \(arg) for \(command)")
}

private func expectNoArguments(_ rest: [String], for command: String) throws(UsageError) {
    if let arg = rest.first { throw unknown(arg, for: command) }
}

private func parseReport(_ args: [String]) throws(UsageError) -> Command {
    var since: Date?
    var until: Date?
    var machine: String?
    var out: String?
    var index = 0
    while index < args.count {
        let flag = args[index]
        guard ["--since", "--until", "--machine", "--out"].contains(flag) else { throw unknown(flag, for: "report") }
        guard index + 1 < args.count else { throw UsageError("\(flag) needs a value") }
        let value = args[index + 1]
        switch flag {
        case "--since": since = try parseDay(value, flag: flag)
        case "--until": until = try parseDay(value, flag: flag)
        case "--machine": machine = value
        default: out = value
        }
        index += 2
    }
    return .report(since: since, until: until, machine: machine, out: out)
}

private func parseStatusline(_ args: [String]) throws(UsageError) -> Command {
    var format: String?
    var color = true
    var quiet = false
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--no-color":
            color = false
        case "--quiet":
            quiet = true
        case "--format":
            guard index + 1 < args.count else { throw UsageError("--format needs a value") }
            format = args[index + 1]
            index += 1
        default:
            throw unknown(args[index], for: "statusline")
        }
        index += 1
    }
    return .statusline(format: format, color: color, quiet: quiet)
}

private func parseDay(_ text: String, flag: String) throws(UsageError) -> Date {
    let calendar = Calendar.current
    let parts = text.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
    guard parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2],
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
    else { throw UsageError("\(flag) needs a date as YYYY-MM-DD") }
    // `date(from:)` rolls 2026-02-30 over into March, so the round trip is what rejects it.
    let back = calendar.dateComponents([.year, .month, .day], from: date)
    guard back.year == year, back.month == month, back.day == day else {
        throw UsageError("\(flag) needs a real date as YYYY-MM-DD")
    }
    return date
}

public func run(_ args: [String]) -> Int32 {
    run(args, out: { print($0) }, err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
}

func run(_ args: [String], out: (String) -> Void, err: (String) -> Void) -> Int32 {
    let command: Command
    do {
        command = try parse(args)
    } catch {
        err("headroom: \(error.message)\n\(usageText)")
        return 2
    }

    switch command {
    case .status:
        return Status.run(paths: .standard(), now: Date())
    case let .tag(text):
        return Tag.run(text: text, paths: .standard(), now: Date(), out: out, err: err)
    case .version:
        out("headroom 0.1.0")
        return 0
    case .help:
        out(usageText)
        return 0
    case .top, .report, .install, .uninstall, .statusline, .agentHook, .hookZsh, .recordCommand:
        err("headroom: this command is not available in this build")
        return 1
    }
}

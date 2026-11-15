import Foundation
import HeadroomCLI

// Checked before anything else so the status line, which runs on every refresh,
// skips config loading and the rest of the CLI.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "statusline" {
    StatusLine.runFast(CommandLine.arguments)
}

// The agent and shell hooks run on every session start and every long command, so they skip config too.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "agent-hook", CommandLine.arguments[2] == "pretool" {
    AgentHook.runPretoolFast(tool: CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "")
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "agent-hook" {
    AgentHook.runFast(tool: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "")
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "record-command" {
    ShellHook.runRecordCommandFast(arguments: CommandLine.arguments)
}

exit(HeadroomCLI.run(CommandLine.arguments))

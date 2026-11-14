import Foundation
import HeadroomCLI

// Checked before anything else so the status line, which runs on every refresh,
// skips config loading and the rest of the CLI.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "statusline" {
    StatusLine.runFast(CommandLine.arguments)
}

exit(HeadroomCLI.run(CommandLine.arguments))

import Darwin
import Foundation
import HeadroomCore

public enum ShellHook {
    static let maxSeconds = 31.0 * 24 * 3600

    // `(z)` splits like the shell parser, so quoted words and tabs don't leak arguments into the record.
    static let zshSnippet = """
        zmodload zsh/datetime
        autoload -Uz add-zsh-hook

        _headroom_preexec() {
          _headroom_start=$EPOCHREALTIME
          _headroom_exe=${${(z)1}[1]}
        }

        _headroom_precmd() {
          [[ -n $_headroom_start ]] || return 0
          local elapsed=$(( EPOCHREALTIME - _headroom_start ))
          if (( elapsed >= 30 )) && [[ -n $_headroom_exe ]]; then
            $HOME/.local/bin/headroom record-command "$_headroom_exe" "$elapsed" &!
          fi
          unset _headroom_start _headroom_exe
        }

        add-zsh-hook preexec _headroom_preexec
        add-zsh-hook precmd _headroom_precmd
        """

    static func recordCommand(exe: String, seconds: Double, spool: Spool, now: Double) -> Bool {
        guard seconds.isFinite, seconds >= 0, seconds <= maxSeconds else { return false }
        let name = exe.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        guard !name.isEmpty else { return false }
        return spool.append(.command(ts: now - seconds, exe: name, seconds: seconds))
    }

    /// Always returns 0: it runs in the background after the user's command and must never disturb the shell.
    static func runRecordCommand(exe: String, seconds: Double) -> Int32 {
        _ = recordCommand(
            exe: exe, seconds: seconds, spool: Spool(url: Paths.standard().spool), now: Date().timeIntervalSince1970)
        return 0
    }

    /// Skips config loading and the rest of the CLI so the hook stays cheap.
    public static func runRecordCommandFast(arguments: [String]) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let seconds = arguments.count > 3 ? Double(arguments[3]) : nil
        exit(arguments.count > 3 && seconds != nil ? runRecordCommand(exe: arguments[2], seconds: seconds ?? 0) : 0)
    }
}

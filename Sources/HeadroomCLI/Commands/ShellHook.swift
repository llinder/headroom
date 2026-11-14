import Darwin
import Foundation
import HeadroomCore

public enum ShellHook {
    static let maxSeconds = 31.0 * 24 * 3600

    // `(z)` splits like the shell parser, so quoted words and tabs don't leak arguments into the record.
    // Leading `NAME=value` assignments and redirections (operator plus target) are skipped because they can carry secrets.
    static let zshSnippet = #"""
        zmodload zsh/datetime
        autoload -Uz add-zsh-hook

        _headroom_preexec() {
          emulate -L zsh
          setopt extendedglob
          local -a words=(${(z)1})
          local word
          local skip=0
          _headroom_start=$EPOCHREALTIME
          _headroom_exe=
          for word in $words; do
            if (( skip )); then skip=0; continue; fi
            if [[ $word == [0-9]#(\<|\>)##'&'# ]]; then skip=1; continue; fi
            case $word in
              *=*|\<*|\>*|[0-9]\<*|[0-9]\>*|\(|\{|\!) continue ;;
            esac
            _headroom_exe=$word
            break
          done
        }

        _headroom_precmd() {
          emulate -L zsh
          [[ -n $_headroom_start ]] || return 0
          local elapsed=$(( EPOCHREALTIME - _headroom_start ))
          if (( elapsed >= 30 )) && [[ -n $_headroom_exe && -x $HOME/.local/bin/headroom ]]; then
            $HOME/.local/bin/headroom record-command "$_headroom_exe" "$elapsed" &!
          fi
          unset _headroom_start _headroom_exe
        }

        add-zsh-hook preexec _headroom_preexec
        add-zsh-hook precmd _headroom_precmd
        """#

    private static func allowedNameByte(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
            UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "+"), UInt8(ascii: "-"):
            true
        default:
            false
        }
    }

    static func recordCommand(exe: String, seconds: Double, spool: Spool, now: Double) -> Bool {
        guard seconds.isFinite, seconds >= 0, seconds <= maxSeconds else { return false }
        let name = exe.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        // The snippet already skips assignments; this second guard keeps anything odd, such as `NAME=value`, out of the spool.
        guard !name.isEmpty, name.utf8.count <= 64, name.utf8.allSatisfy(Self.allowedNameByte) else { return false }
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

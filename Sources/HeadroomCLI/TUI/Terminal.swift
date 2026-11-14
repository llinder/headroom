import Darwin
import Foundation

enum TerminalError: Error {
    case notATerminal
    case setup
}

/// Owns raw mode and the alternate screen. `restore()` is idempotent, so every exit path (quit key, signal,
/// failed setup) can call it without tracking whether another already did.
@MainActor
final class Terminal {
    private static let enter = "\u{1B}[?1049h\u{1B}[?25l"
    private static let leave = "\u{1B}[?25h\u{1B}[?1049l"

    private var original = termios()
    private var restored = false

    init() throws {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1, tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw TerminalError.notATerminal
        }
        var raw = original
        cfmakeraw(&raw)
        // cfmakeraw turns output processing off, which would make "\n" a bare line feed.
        raw.c_oflag |= tcflag_t(OPOST)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { throw TerminalError.setup }
        write(Self.enter)
    }

    func size() -> (Int, Int) {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 else { return (80, 24) }
        return (Int(ws.ws_col), Int(ws.ws_row))
    }

    /// One `write` per frame so the screen never shows a half-drawn state.
    func draw(_ lines: [String]) {
        write("\u{1B}[H" + lines.map { $0 + "\u{1B}[K" }.joined(separator: "\n") + "\u{1B}[J")
    }

    func restore() {
        guard !restored else { return }
        restored = true
        write(Self.leave)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
    }

    private func write(_ text: String) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return }
            bytes = bytes.dropFirst(written)
        }
    }
}

import Foundation
import HeadroomCore

public enum StatusLineFormatter {
    public static let defaultTemplate = "{mem} {swap} · {cpu} · {disk} · {agents} · {leftovers}"
    static let staleAfter = 60.0

    // Integer math and interpolation only: this runs on every status-line refresh, so
    // no formatters and no allocation beyond the output string.
    public static func format(_ s: LiveSnapshot?, now: Double, template: String, color: Bool, quiet: Bool) -> String {
        guard let s, now - s.timestamp <= staleAfter else { return quiet ? "" : "headroom: off" }

        let warn = s.pressure == 2
        let critical = s.pressure == 4
        var mem = "mem \(percent(s.memUsed, of: s.memTotal))%"
        if warn || critical { mem += " ⚠" }
        if color && (warn || critical) { mem = "\(critical ? "\u{1B}[31m" : "\u{1B}[33m")\(mem)\u{1B}[0m" }

        let swap = s.swapUsed == 0 ? "" : "swap \(roundedInt(Double(s.swapUsed) / 1_073_741_824, upTo: 1e9))G"
        let cpu = "cpu \(roundedInt(Double(s.cpuBusy) * 100, upTo: 100))%"
        let usedDisk = s.diskCapacity > s.diskFree ? s.diskCapacity - s.diskFree : 0
        let disk = "disk \(roundedInt(Double(usedDisk) / 1e9, upTo: 1e9))G"
        let agents = s.activeAgents == 1 ? "1 agent" : "\(s.activeAgents) agents"

        var leftovers = ""
        if s.leftoverCount > 0 {
            let tenths = roundedInt(Double(s.leftoverBytes) / 1e8, upTo: 1e12)
            leftovers = "⚑ \(s.leftoverCount) leftover\(s.leftoverCount == 1 ? "" : "s") · \(tenths / 10).\(tenths % 10) GB"
        }

        // Substituting per segment means an empty token drops its whole segment instead of
        // leaving a dangling separator.
        return template.components(separatedBy: " · ")
            .map { segment in
                segment
                    .replacingOccurrences(of: "{mem}", with: mem)
                    .replacingOccurrences(of: "{swap}", with: swap)
                    .replacingOccurrences(of: "{cpu}", with: cpu)
                    .replacingOccurrences(of: "{disk}", with: disk)
                    .replacingOccurrences(of: "{agents}", with: agents)
                    .replacingOccurrences(of: "{leftovers}", with: leftovers)
                    .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private static func percent(_ used: UInt64, of total: UInt64) -> Int {
        total == 0 ? 0 : roundedInt(Double(used) / Double(total) * 100, upTo: 999)
    }

    // The live file's raw bits can decode to NaN, infinity or absurd magnitudes, and Int(_:) traps on those.
    private static func roundedInt(_ x: Double, upTo limit: Double) -> Int {
        x.isFinite ? Int(min(max(x, 0), limit).rounded()) : 0
    }
}

public enum StatusLine {
    /// Entry point for `headroom statusline`. It must never fail and never read stdin,
    /// so bad flags fall back to defaults instead of erroring.
    public static func runFast(_ arguments: [String]) -> Never {
        signal(SIGPIPE, SIG_IGN)
        var template = StatusLineFormatter.defaultTemplate
        var color = true
        var quiet = false
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--no-color": color = false
            case "--quiet": quiet = true
            case "--format":
                if index + 1 < arguments.count {
                    template = arguments[index + 1]
                    index += 1
                }
            default: break
            }
            index += 1
        }
        print(render(template: template, color: color, quiet: quiet))
        exit(0)
    }

    static func render(template: String, color: Bool, quiet: Bool) -> String {
        StatusLineFormatter.format(
            LiveStateReader.read(url: Paths.standard().liveState), now: Date().timeIntervalSince1970,
            template: template, color: color, quiet: quiet)
    }
}

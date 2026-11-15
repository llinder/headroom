import Darwin
import Foundation
import HeadroomCore

enum AdviceTrigger: Equatable { case critical, swapGrowing, leftovers }

enum CommandKind { case go, container, build, js }

enum PreToolAdvice {
    private static let staleSeconds = 60.0
    private static let leftoverTriggerBytes: UInt64 = 1_000_000_000
    private static let wrappers: Set<String> = ["time", "env", "sudo"]
    private static let containerIntentPrefixes = ["docker run", "docker compose up", "kind create cluster", "docker buildx"]

    static func trigger(_ s: LiveSnapshot, now: Double, config: AgentsConfig) -> AdviceTrigger? {
        guard now - s.timestamp <= staleSeconds else { return nil }
        if s.pressure == 4 { return .critical }
        if config.swapGrowthBytesPerMin > 0, s.swapGrowthBytesPerMin >= config.swapGrowthBytesPerMin { return .swapGrowing }
        if s.leftoverBytes >= leftoverTriggerBytes { return .leftovers }
        return nil
    }

    static func classify(_ command: String, heavy: [String]) -> (kind: CommandKind?, containerIntent: Bool) {
        var kind: CommandKind?
        var intent = false
        let separators = command
            .replacing("&&", with: "\n")
            .replacing("||", with: "\n")
        for raw in separators.split(whereSeparator: { $0 == "\n" || $0 == ";" || $0 == "|" }) {
            var words = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            while let first = words.first, wrappers.contains(first) || isAssignment(first) {
                words.removeFirst()
            }
            guard let head = words.first else { continue }
            let segment = words.joined(separator: " ")
            if containerIntentPrefixes.contains(where: { hasPrefix(segment, $0) }) { intent = true }
            if kind == nil, heavy.contains(where: { hasPrefix(segment, $0) }) { kind = kindOf(head) }
        }
        return (kind, intent)
    }

    static func text(trigger: AdviceTrigger, kind: CommandKind?, snapshot s: LiveSnapshot) -> String {
        let swap = gb(Double(s.swapUsed))
        let growth = (s.swapGrowthBytesPerMin >= 0 ? "+" : "") + gb(Double(s.swapGrowthBytesPerMin))
        var out: String
        switch trigger {
        case .critical: out = "headroom: memory pressure is critical (swap \(swap) GB, \(growth) GB/min)."
        case .swapGrowing: out = "headroom: swap is growing fast (\(growth) GB/min, \(swap) GB used)."
        case .leftovers: out = "headroom: memory is tight."
        }
        switch kind {
        case .go?: out += " Prefer go test -p 2 ./<package>/... over the whole module, and one package build at a time."
        case .container?: out += " Avoid starting another container or Kind cluster until pressure drops."
        case .build?: out += " Prefer building one target at a time."
        case .js?: out += " Prefer running one test file or project at a time."
        case nil: out += " Prefer narrow builds and tests, and avoid starting containers or clusters right now."
        }
        if s.leftoverCount > 0 {
            let noun = s.leftoverCount == 1 ? "abandoned container holds" : "abandoned containers hold"
            out += " \(s.leftoverCount) \(noun) \(gb(Double(s.leftoverBytes))) GB; see headroom leftovers."
        }
        return out
    }

    /// Keys become file names, so anything outside the allowed set is refused rather than escaped.
    struct Throttle {
        let directory: URL

        init(directory: URL) {
            self.directory = directory
        }

        func due(key: String, now: Double, minutes: Int) -> Bool {
            guard validKey(key) else { return false }
            var st = stat()
            guard stat(directory.appending(path: key).path, &st) == 0 else { return true }
            let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            return now - mtime >= Double(minutes) * 60
        }

        func touch(key: String, now: Double) {
            guard validKey(key) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appending(path: key).path
            let fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return }
            close(fd)
            let whole = now.rounded(.down)
            let t = timeval(tv_sec: Int(whole), tv_usec: Int32((now - whole) * 1e6))
            var times = [t, t]
            utimes(path, &times)
        }

        private func validKey(_ key: String) -> Bool {
            !key.isEmpty && key.utf8.count <= 128 && key != "." && key != ".."
                && key.utf8.allSatisfy {
                    ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                        || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
                }
        }
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        return word[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            && !(word[..<eq].first?.isNumber ?? false)
    }

    private static func hasPrefix(_ segment: String, _ pattern: String) -> Bool {
        segment == pattern || segment.hasPrefix(pattern + " ")
    }

    private static func kindOf(_ head: String) -> CommandKind? {
        switch head {
        case "go", "golangci-lint": .go
        case "docker", "kind", "kubectl": .container
        case "make", "swift", "cargo", "bazel", "bazelisk": .build
        case "npm", "npx", "pnpm", "pytest": .js
        default: nil
        }
    }

    private static func gb(_ bytes: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), bytes / 1e9)
    }
}

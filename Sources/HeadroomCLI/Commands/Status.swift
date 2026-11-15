import Foundation
import HeadroomCore

enum Status {
    private static let recordingFreshness = 90.0
    private static let megabyte = 1_048_576.0

    static func run(
        paths: Paths, now: Date, out: (String) -> Void = { print($0) },
        err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) -> Int32 {
        guard FileManager.default.fileExists(atPath: paths.database.path) else {
            out("no data yet — run `headroom install`")
            return 0
        }
        do {
            let queries = Queries(db: try Database(path: paths.database.path, readOnly: true))
            let machineId = MachineInfo.current().machineId
            let known = try queries.machines().map(\.machineId)
            let id = known.contains(machineId) ? machineId : known.first ?? machineId
            out(try render(queries: queries, paths: paths, machineId: id, now: now))
            return 0
        } catch {
            switch error {
            case let .open(message), let .sqlite(_, message): err("database unreadable: \(message)")
            }
            return 1
        }
    }

    static func render(
        queries: Queries, paths: Paths, machineId: String, now: Date,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws(DatabaseError) -> String {
        var lines: [String] = []

        let beat = try queries.heartbeat()
        lines.append(beat.map { now.timeIntervalSince1970 - $0 < recordingFreshness } == true ? "recording ●" : "not recording ○")

        if let m = try queries.machines().first(where: { $0.machineId == machineId }) {
            let gigabytes = Double(m.ramBytes) / 1_073_741_824
            lines.append("machine \(m.model) · \(m.perfCores + m.effCores) cores · \(format(gigabytes, 0)) GB")
        } else {
            lines.append("machine unknown")
        }

        let days = try queries.coverage(
            machineId: machineId, from: Date(timeIntervalSince1970: 0), to: now.addingTimeInterval(86_400))
        let recorded = days.reduce(0) { $0 + $1.recorded }
        let gap = days.reduce(0) { $0 + $1.gap }
        let gapCount = days.reduce(0) { $0 + $1.gaps.count }
        lines.append("days recorded \(days.filter { $0.recorded > 0 }.count)")
        let covered = recorded + gap > 0 ? format(recorded / (recorded + gap) * 100, 1) + "%" : "n/a"
        lines.append("coverage \(covered) of awake time · gaps \(gapCount)")

        let size = (try? FileManager.default.attributesOfItem(atPath: paths.database.path))?[.size] as? Int ?? 0
        lines.append("database \(format(Double(size) / megabyte, 1)) MB")

        let usage = try queries.selfUsage(
            machineId: machineId, from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(1))
        lines.append("headroomd CPU \(format(usage.avgCPU * 100, 1))% · memory \(format(Double(usage.maxFootprint) / megabyte, 1)) MB")

        lines += dockerLines(state: LeftoverState.load(from: paths.leftovers), now: now)

        lines.append(hooksLine(home: home))
        return lines.joined(separator: "\n")
    }

    private static func dockerLines(state: LeftoverState, now: Date) -> [String] {
        func ago(_ ts: Double) -> String {
            "last checked \(TopRenderer.clampedInt((now.timeIntervalSince1970 - ts) / 60, upTo: 99_999))m ago"
        }
        var lines = state.engines.map { engine in
            "docker \(engine.context) \(engine.ok ? "ok" : "unreachable") · \(ago(engine.lastPass))"
        }
        if lines.isEmpty { lines = [state.updated > 0 ? "docker no engines found · \(ago(state.updated))" : "docker not checked yet"] }
        if let warning = state.keepWarning { lines.append("keep list: \(warning)") }
        return lines
    }

    /// The events headroom's hooks are installed for, in either agent's config. Advice needs PreToolUse, which a
    /// phase 1 install didn't add.
    private static func hooksLine(home: URL) -> String {
        let files = [".claude/settings.json", ".codex/hooks.json"].compactMap { try? Data(contentsOf: home.appending(path: $0)) }
        let found = ["SessionStart", "PreToolUse"].filter { event in files.contains { HookConfig.contains($0, event: event) } }
        let hint = "run headroom install --agents"
        if found.isEmpty { return "agent hooks: none · \(hint)" }
        let listed = "agent hooks: " + found.joined(separator: ", ")
        return found.contains("PreToolUse") ? listed : "\(listed) · PreToolUse missing, \(hint)"
    }

    private static func format(_ value: Double, _ digits: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(digits)).grouping(.never))
    }
}

import Foundation
import HeadroomCore

enum Leftovers {
    private static let unreadableKeeps = "keeps.json has unreadable entries; fix or remove them before changing the keep list"

    static func run(paths: Paths, now: Date, json: Bool, kept: Bool, out: (String) -> Void) -> Int32 {
        let state = LeftoverState.load(from: paths.leftovers)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            out((try? String(data: encoder.encode(state.items), encoding: .utf8)) ?? "[]")
            return 0
        }
        if state.items.isEmpty { out("no abandoned containers") }
        for flagged in state.items {
            let item = flagged.item
            let memory = flagged.memoryBytes.map(memoryText) ?? "memory unknown"
            let age = TopRenderer.age(now.timeIntervalSince1970 - flagged.startedAt)
            out("\(item.engine)/\(item.kind.rawValue) \(item.name) · \(flagged.reason) · \(memory) · up \(age)")
            for command in item.cleanup { out("  \(command)") }
        }
        if kept { for entry in state.kept { out("\(entry.key) · kept (\(entry.why))") } }
        return 0
    }

    static func keep(
        name: String, forSeconds: Double?, paths: Paths, now: Date, out: (String) -> Void, err: (String) -> Void
    ) -> Int32 {
        modify(paths: paths, err: err) { list in
            list.entries.removeAll { $0.name == name }
            list.entries.append(KeepEntry(name: name, until: forSeconds.map { now.timeIntervalSince1970 + $0 }))
            out("keeping \(name)")
            return true
        }
    }

    static func unkeep(name: String, paths: Paths, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        modify(paths: paths, err: err) { list in
            let before = list.entries.count
            list.entries.removeAll { $0.name == name }
            guard list.entries.count < before else {
                err("headroom: \(name) is not in the keep list")
                return false
            }
            out("no longer keeping \(name)")
            return true
        }
    }

    static func keeps(paths: Paths, now: Date, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        let (list, warning) = KeepList.load(from: paths.keeps)
        if let warning { err("keep list: \(warning)") }
        if list.entries.isEmpty { out("keep list is empty") }
        for entry in list.entries {
            guard let until = entry.until else {
                out("\(entry.name) · kept forever")
                continue
            }
            let stamp = Date(timeIntervalSince1970: until).formatted(.iso8601)
            out("\(entry.name) · \(until <= now.timeIntervalSince1970 ? "expired" : "until") \(stamp)")
        }
        return 0
    }

    /// Never writes over a file that could not be fully read, so a hand-edited or damaged keeps.json is not lost.
    private static func modify(paths: Paths, err: (String) -> Void, _ change: (inout KeepList) -> Bool) -> Int32 {
        var (list, warning) = KeepList.load(from: paths.keeps)
        guard warning == nil, list.skipped == 0 else {
            err(unreadableKeeps)
            return 1
        }
        guard change(&list) else { return 1 }
        do {
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try list.save(to: paths.keeps)
        } catch {
            err("headroom: cannot write \(paths.keeps.path): \(error.localizedDescription)")
            return 1
        }
        return 0
    }

    private static func memoryText(_ bytes: UInt64) -> String {
        let megabytes = bytes / 1_000_000
        return megabytes < 1000 ? "\(megabytes) MB" : "\(megabytes / 100 / 10).\(megabytes / 100 % 10) GB"
    }
}

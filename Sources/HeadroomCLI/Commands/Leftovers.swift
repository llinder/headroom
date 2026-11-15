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
            out("  keep: headroom keep \(LeftoverGrouper.quote(keepKey(item)))")
        }
        if kept { for entry in state.kept { out("\(entry.key) · kept (\(entry.why))") } }
        return 0
    }

    static func keep(
        name: String, forSeconds: Double?, paths: Paths, now: Date, out: (String) -> Void, err: (String) -> Void
    ) -> Int32 {
        let status = modify(paths: paths, err: err) { list in
            list.entries.removeAll { $0.name == name }
            list.entries.append(KeepEntry(name: name, until: forSeconds.map { now.timeIntervalSince1970 + $0 }))
            return true
        }
        guard status == 0 else { return status }
        out("keeping \(name)")
        if let hint = unprefixedHint(name: name, items: LeftoverState.load(from: paths.leftovers).items) {
            err("note: \"\(name)\" matches no container; did you mean headroom keep \(hint)?")
        }
        return 0
    }

    /// The string `KeepList.covers` matches for this item.
    private static func keepKey(_ item: LeftoverItem) -> String {
        switch item.kind {
        case .kind: "kind:\(item.name)"
        case .compose: "compose:\(item.name)"
        case .testcontainers, .container: item.containerNames.first ?? item.name
        }
    }

    /// A bare name that only names a kind or compose group is almost always a missed prefix.
    private static func unprefixedHint(name: String, items: [FlaggedItem]) -> String? {
        guard !name.hasPrefix("kind:"), !name.hasPrefix("compose:") else { return nil }
        let bare = items.contains { flagged in
            let item = flagged.item
            let prefix = "\(item.engine)/"
            let stripped = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
            return item.containerNames.contains(stripped) || (stripped.count >= 12 && item.containerIDs.contains { $0.hasPrefix(stripped) })
        }
        guard !bare else { return nil }
        return items.map(\.item).first { ($0.kind == .kind || $0.kind == .compose) && $0.name == name }.map(keepKey)
    }

    static func unkeep(name: String, paths: Paths, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        let status = modify(paths: paths, err: err) { list in
            let before = list.entries.count
            list.entries.removeAll { $0.name == name }
            guard list.entries.count < before else {
                err("headroom: \(name) is not in the keep list")
                return false
            }
            return true
        }
        if status == 0 { out("no longer keeping \(name)") }
        return status
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
        guard bytes >= 1_000_000_000 else { return "\(bytes / 1_000_000) MB" }
        let tenths = TopRenderer.clampedInt((Double(bytes) / 1e8).rounded(), upTo: 1e12)
        return "\(tenths / 10).\(tenths % 10) GB"
    }
}

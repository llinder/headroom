import CryptoKit
import Foundation

public typealias LeftoverEvent = (kind: String, payload: [String: String])

/// One background pass over every Docker engine: list, group, inspect start times, decide, then read memory for
/// flagged items. It holds no state; the previous pass's `LeftoverState` goes in and the next one comes out.
public struct LeftoverMonitor: Sendable {
    static let callBudget = 20
    /// A timeout or bad reply keeps an engine's items this many passes, so one slow moment doesn't clear and re-flag.
    static let maxTransientFailures = 3
    static let reaperMemory = 86_400.0
    static let skippedKeepsNote = " (keeps.json has unreadable entries)"

    private let engines: @Sendable () -> [DockerEngine]
    private let client: @Sendable (String) -> DockerClient
    private let config: LeftoversConfig

    public init(
        engines: @escaping @Sendable () -> [DockerEngine],
        client: @escaping @Sendable (String) -> DockerClient = { DockerClient(socketPath: $0) },
        config: LeftoversConfig
    ) {
        self.engines = engines
        self.client = client
        self.config = config
    }

    /// `facts` is called at most once, with a `since` that covers the intent window before the oldest start time,
    /// and returns nil when the database can't be read. `deadline` is wall-clock epoch seconds, checked between calls.
    public func pass(
        previous: LeftoverState, facts: (Double) -> OwnershipFacts?, keeps: KeepList, keepWarning: String? = nil,
        now: Double, deadline: Double
    ) -> (state: LeftoverState, events: [LeftoverEvent]) {
        var budget = Self.callBudget
        func mayCall() -> Bool { budget > 0 && Date().timeIntervalSince1970 < deadline }

        let previousStatus = Dictionary(previous.engines.map { ($0.context, $0) }, uniquingKeysWith: { a, _ in a })
        let previousFlagged = Dictionary(previous.items.map { ($0.item.key, $0) }, uniquingKeysWith: { a, _ in a })
        var statuses: [EngineStatus] = []
        var sockets: [String: String] = [:]
        var listed: [LeftoverItem] = []
        var carriedEngines = Set<String>()
        var reapers = Set<String>()

        for engine in engines() {
            let before = previousStatus[engine.context]
            sockets[engine.context] = engine.socketPath
            guard Date().timeIntervalSince1970 < deadline else {
                carriedEngines.insert(engine.context)
                statuses.append(before ?? EngineStatus(
                    context: engine.context, socket: engine.socketPath, lastPass: 0, ok: false, failures: 0))
                continue
            }
            let failures = (before?.failures ?? 0) + 1
            switch list(engine) {
            case .success(let containers):
                let grouped = LeftoverGrouper.group(containers, engine: engine.context, ignore: config.ignore)
                listed += grouped.items
                reapers.formUnion(grouped.reapers)
                statuses.append(EngineStatus(context: engine.context, socket: engine.socketPath, lastPass: now, ok: true, failures: 0))
            case .failure(let error):
                if error != .refused && failures <= Self.maxTransientFailures { carriedEngines.insert(engine.context) }
                statuses.append(EngineStatus(
                    context: engine.context, socket: engine.socketPath, lastPass: now, ok: false, failures: failures))
            }
        }

        // Item keys start with `<context>/`; kept entries and start times carry only the key.
        func carried(_ key: String) -> Bool { carriedEngines.contains { key.hasPrefix($0 + "/") } }
        var kept = previous.kept.filter { carried($0.key) }
        var candidates: [LeftoverItem] = []
        for item in listed {
            if keeps.covers(item, now: now) {
                kept.append(KeptItem(key: item.key, why: "keep list"))
            } else if item.lifetime == .keep {
                kept.append(KeptItem(key: item.key, why: "label keep"))
            } else {
                candidates.append(item)
            }
        }

        var starts = previous.starts
        for flagged in previous.items where starts[flagged.item.key] == nil { starts[flagged.item.key] = flagged.startedAt }
        for item in candidates where starts[item.key] == nil {
            guard mayCall() else { break }
            guard let id = item.containerIDs.first, let socket = sockets[item.engine] else { continue }
            budget -= 1
            guard let data = try? client(socket).get("/containers/\(id)/json"),
                  let detail = ContainerDetail.parse(inspectJSON: data)
            else { continue }
            starts[item.key] = detail.startedAt
        }

        var seenReapers = previous.seenReapers.filter { now - $0.value <= Self.reaperMemory }
        for session in reapers { seenReapers[session] = now }
        let goneReapers = Set(seenReapers.keys).subtracting(reapers)

        let known = candidates.compactMap { item in starts[item.key].map { (item: item, startedAt: $0) } }
        var flagged: [FlaggedItem] = []
        if let oldest = known.map(\.startedAt).min() {
            if let facts = facts(oldest - LeftoverPolicy.intentWindow) {
                for (item, startedAt) in known {
                    let decision = LeftoverPolicy.decide(
                        item, startedAt: startedAt, facts: facts, keeps: keeps, liveReapers: reapers,
                        goneReapers: goneReapers, now: now, config: config)
                    guard case .leftover(let reason) = decision else { continue }
                    let before = previousFlagged[item.key]
                    flagged.append(FlaggedItem(
                        item: item, startedAt: startedAt, reason: keeps.skipped > 0 ? reason + Self.skippedKeepsNote : reason,
                        memoryBytes: before?.memoryBytes, firstFlagged: before?.firstFlagged ?? now))
                }
            } else {
                // Without ownership facts nothing new can be decided, so what was flagged stays as it was.
                flagged = known.compactMap { item, _ in
                    previousFlagged[item.key].map { var f = $0; f.item = item; return f }
                }
            }
        }

        stats: for i in flagged.indices where flagged[i].memoryBytes == nil {
            guard let socket = sockets[flagged[i].item.engine] else { continue }
            var total: UInt64 = 0
            var read = false
            for id in flagged[i].item.containerIDs {
                // An item read only in part would understate its memory, and it is never read again once set.
                guard mayCall() else { break stats }
                budget -= 1
                guard let data = try? client(socket).get("/containers/\(id)/stats?stream=false&one-shot=true"),
                      let bytes = ContainerDetail.memoryEstimate(statsJSON: data)
                else { continue }
                total = Self.saturatingAdd(total, bytes)
                read = true
            }
            if read { flagged[i].memoryBytes = total }
        }

        let items = previous.items.filter { carriedEngines.contains($0.item.engine) } + flagged
        let presentKeys = Set(listed.map(\.key))
        starts = starts.filter { presentKeys.contains($0.key) || carried($0.key) }

        let state = LeftoverState(
            updated: now, engines: statuses, items: items, kept: kept, keepWarning: keepWarning,
            seenReapers: seenReapers, starts: starts)
        return (state, events(previous: previous.items, current: items))
    }

    private func list(_ engine: DockerEngine) -> Result<[DockerContainer], DockerError> {
        let data: Data
        do {
            data = try client(engine.socketPath).get("/containers/json")
        } catch {
            return .failure(error)
        }
        guard let containers = try? DockerContainer.decodeList(data) else { return .failure(.malformed) }
        return .success(containers)
    }

    /// Clears come before new flags, and each event's `totalBytes` is the running sum after it, so the last event
    /// of a pass carries the pass's total.
    private func events(previous: [FlaggedItem], current: [FlaggedItem]) -> [LeftoverEvent] {
        let currentKeys = Set(current.map(\.item.key))
        let previousKeys = Set(previous.map(\.item.key))
        let cleared = previous.filter { !currentKeys.contains($0.item.key) }
        let added = current.filter { !previousKeys.contains($0.item.key) }

        var total = current.filter { previousKeys.contains($0.item.key) }
            .reduce(0) { Self.saturatingAdd($0, $1.memoryBytes ?? 0) }
        total = cleared.reduce(total) { Self.saturatingAdd($0, $1.memoryBytes ?? 0) }

        var out: [LeftoverEvent] = []
        for f in cleared {
            let bytes = f.memoryBytes ?? 0
            total = total >= bytes ? total - bytes : 0
            out.append((kind: "leftover_cleared", payload: Self.payload(f, bytes: bytes, total: total)))
        }
        for f in added {
            let bytes = f.memoryBytes ?? 0
            total = Self.saturatingAdd(total, bytes)
            out.append((kind: "leftover", payload: Self.payload(f, bytes: bytes, total: total)))
        }
        return out
    }

    /// Events go into SQLite, which never holds container names, so the key is reduced to a short hash.
    private static func payload(_ f: FlaggedItem, bytes: UInt64, total: UInt64) -> [String: String] {
        let digest = SHA256.hash(data: Data(f.item.key.utf8)).map { String(format: "%02x", $0) }.joined()
        return ["kind": f.item.kind.rawValue, "ref": String(digest.prefix(12)), "bytes": String(bytes), "totalBytes": String(total)]
    }

    static func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }
}

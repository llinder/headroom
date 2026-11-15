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
    static let inspectRetry = 1800.0
    /// Bounds the ownership read; older items lose their intent markers and are judged as unowned.
    static let factsHorizon = 31 * 86_400.0

    private let engines: @Sendable () -> [DockerEngine]
    private let client: @Sendable (String) -> DockerClient
    private let config: LeftoversConfig
    private let machineId: String

    public init(
        machineId: String,
        engines: @escaping @Sendable () -> [DockerEngine],
        client: @escaping @Sendable (String) -> DockerClient = { DockerClient(socketPath: $0) },
        config: LeftoversConfig
    ) {
        self.engines = engines
        self.client = client
        self.config = config
        self.machineId = machineId
    }

    /// `facts` is called at most once, with a `since` that covers the intent window before the oldest start time
    /// (but no earlier than `factsHorizon` before `now`), and returns nil when the database can't be read. `deadline` is wall-clock epoch seconds, checked between calls.
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
        var ignored: [KeptItem] = []

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
                let grouped = LeftoverGrouper.group(
                    containers, engine: engine.context, dockerHost: engine.dockerHost, ignore: config.ignore)
                listed += grouped.items
                reapers.formUnion(grouped.reapers)
                ignored += grouped.ignored
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
        // Ignored containers never become candidates, so listing them here changes no flag, count or event.
        kept += ignored

        // Keyed by container, not item: `compose down && up` or a Kind recreate keeps the item key with new containers.
        var starts = previous.starts
        var inspectFailedAt = previous.inspectFailedAt.filter { now - $0.value < Self.inspectRetry }
        var statsFailedAt = previous.statsFailedAt.filter { now - $0.value < Self.inspectRetry }
        inspect: for item in candidates {
            guard let socket = sockets[item.engine] else { continue }
            for id in item.containerIDs where starts[id] == nil && inspectFailedAt[id] == nil {
                guard mayCall() else { break inspect }
                budget -= 1
                if let data = try? client(socket).get("/containers/\(id)/json"),
                   let detail = ContainerDetail.parse(inspectJSON: data) {
                    starts[id] = detail.startedAt
                } else {
                    inspectFailedAt[id] = now
                }
            }
        }

        // The newest member start, on purpose: a stack that was recreated or gained a container counts from that
        // change, so an owner who just touched it is found. Erring young only delays a flag; erring old raises a
        // false one. An item with any member not yet inspected waits.
        func itemStart(_ item: LeftoverItem) -> Double? {
            var newest: Double?
            for id in item.containerIDs {
                guard let start = starts[id] else { return nil }
                newest = max(newest ?? start, start)
            }
            return newest
        }

        var seenReapers = previous.seenReapers.filter { now - $0.value <= Self.reaperMemory }
        for session in reapers { seenReapers[session] = now }
        let goneReapers = Set(seenReapers.keys).subtracting(reapers)

        let known = candidates.compactMap { item in itemStart(item).map { (item: item, startedAt: $0) } }
        var flagged: [FlaggedItem] = []
        if let oldest = known.map(\.startedAt).min() {
            if let facts = facts(max(oldest - LeftoverPolicy.intentWindow, now - Self.factsHorizon)) {
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

        // Memory is set only once every member is read, because it is never read again after that: a partial sum
        // would understate the item for good. An item too big for the remaining budget waits for a later pass.
        stats: for i in flagged.indices where flagged[i].memoryBytes == nil {
            let ids = flagged[i].item.containerIDs
            guard let socket = sockets[flagged[i].item.engine], !ids.isEmpty, ids.count <= budget,
                  !ids.contains(where: { statsFailedAt[$0] != nil })
            else { continue }
            var total: UInt64 = 0
            var complete = true
            for id in ids {
                guard Date().timeIntervalSince1970 < deadline else { break stats }
                budget -= 1
                guard let data = try? client(socket).get("/containers/\(id)/stats?stream=false&one-shot=true"),
                      let bytes = ContainerDetail.memoryEstimate(statsJSON: data)
                else {
                    statsFailedAt[id] = now
                    complete = false
                    break
                }
                total = Self.saturatingAdd(total, bytes)
            }
            if complete { flagged[i].memoryBytes = total }
        }

        let items = previous.items.filter { carriedEngines.contains($0.item.engine) } + flagged
        let presentIDs = Set(listed.flatMap(\.containerIDs) + items.flatMap(\.item.containerIDs))
        starts = starts.filter { presentIDs.contains($0.key) }
        inspectFailedAt = inspectFailedAt.filter { presentIDs.contains($0.key) }
        statsFailedAt = statsFailedAt.filter { presentIDs.contains($0.key) }

        let state = LeftoverState(
            updated: now, engines: statuses, items: items, kept: kept, keepWarning: keepWarning,
            seenReapers: seenReapers, starts: starts, inspectFailedAt: inspectFailedAt,
            statsFailedAt: statsFailedAt)
        return (state, events(previous: previous.items, current: items))
    }

    /// Whether a scheduled pass should run. Each pass wakes every engine, and an idle Docker VM may be kept awake by
    /// that; nothing new can be owned while no agent runs, and leftovers matter most once memory is short. The
    /// first pass after start always runs, so the sidecar reflects this recorder's engines. While anything is
    /// flagged a container is running, so the VM is awake anyway, and a removed one clears without waiting.
    public static func shouldPass(first: Bool, liveAgentRuns: Int, pressure: PressureLevel, flagged: Int) -> Bool {
        first || liveAgentRuns > 0 || pressure != .normal || flagged > 0
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

    /// Clears come before new flags, and each event's `totalBytes` and `totalCount` are the running sum and count
    /// after it, so the last event of a pass carries the pass's totals. Memory is often read a pass after the flag,
    /// so a pass that only changes the total emits `leftover_bytes`; without it the report's peak would miss it.
    private func events(previous: [FlaggedItem], current: [FlaggedItem]) -> [LeftoverEvent] {
        let currentKeys = Set(current.map(\.item.key))
        let previousKeys = Set(previous.map(\.item.key))
        let cleared = previous.filter { !currentKeys.contains($0.item.key) }
        let added = current.filter { !previousKeys.contains($0.item.key) }
        let stayed = current.filter { previousKeys.contains($0.item.key) }

        var total = stayed.reduce(0) { Self.saturatingAdd($0, $1.memoryBytes ?? 0) }
        total = cleared.reduce(total) { Self.saturatingAdd($0, $1.memoryBytes ?? 0) }
        var count = stayed.count + cleared.count

        var out: [LeftoverEvent] = []
        for f in cleared {
            let bytes = f.memoryBytes ?? 0
            total = total >= bytes ? total - bytes : 0
            count -= 1
            out.append((kind: "leftover_cleared", payload: payload(f, bytes: bytes, total: total, count: count)))
        }
        for f in added {
            let bytes = f.memoryBytes ?? 0
            total = Self.saturatingAdd(total, bytes)
            count += 1
            out.append((kind: "leftover", payload: payload(f, bytes: bytes, total: total, count: count)))
        }
        let before = previous.reduce(0) { Self.saturatingAdd($0, $1.memoryBytes ?? 0) }
        if out.isEmpty && total != before {
            out.append((kind: "leftover_bytes", payload: ["totalBytes": String(total), "totalCount": String(count)]))
        }
        return out
    }

    /// Events go into SQLite, which never holds container names, so the key is reduced to a short hash. The machine
    /// id salts it, so a common name such as `compose/postgres` can't be matched across machines by its hash.
    private func payload(_ f: FlaggedItem, bytes: UInt64, total: UInt64, count: Int) -> [String: String] {
        let digest = SHA256.hash(data: Data((machineId + "\n" + f.item.key).utf8)).map { String(format: "%02x", $0) }.joined()
        return [
            "kind": f.item.kind.rawValue, "ref": String(digest.prefix(12)), "bytes": String(bytes),
            "totalBytes": String(total), "totalCount": String(count),
        ]
    }

    static func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }
}

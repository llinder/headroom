import Foundation

public struct RunFacts: Sendable, Equatable {
    public var sessionIds: Set<String>
    /// Epoch seconds the run was first seen; stands in for its last activity when it has none recorded.
    public var started: Double
    public var ended: Double?
    public var lastIntent: Double?
    /// Minute starts with `active_seconds > 0`, ascending.
    public var activeMinutes: [Double]

    public init(sessionIds: Set<String>, started: Double, ended: Double?, lastIntent: Double?, activeMinutes: [Double]) {
        self.sessionIds = sessionIds
        self.started = started
        self.ended = ended
        self.lastIntent = lastIntent
        self.activeMinutes = activeMinutes
    }
}

public struct OwnershipFacts: Sendable {
    public var intents: [(ts: Double, root: ProcessKey)]
    public var runs: [ProcessKey: RunFacts]
    /// Recorded awake seconds in [from, to): sleep and recorder gaps don't count toward idleness. `to` must be the
    /// `now` the facts were read at, because the bounded clock from `Queries.ownershipFacts` only holds the newest
    /// samples before it and saturates at its idle threshold.
    public var awakeSeconds: @Sendable (Double, Double) -> Double

    public init(
        intents: [(ts: Double, root: ProcessKey)], runs: [ProcessKey: RunFacts],
        awakeSeconds: @escaping @Sendable (Double, Double) -> Double
    ) {
        self.intents = intents
        self.runs = runs
        self.awakeSeconds = awakeSeconds
    }
}

public enum LeftoverDecision: Equatable, Sendable {
    case leftover(reason: String)
    case notYet
    case kept
    case ignored
}

public enum LeftoverPolicy {
    static let intentWindow = 600.0
    /// Hook and recorder clocks are read separately, so a marker may land just after the container it announced.
    static let clockSkew = 5.0
    /// `temporary` still waits this long, so a pause between two commands doesn't flag an owner's containers.
    static let temporaryIdle = 300.0
    /// An exited agent is often restarted at once, and its resumed session needs time to show up as a new run.
    static let exitGrace = 300.0
    private static let ownerDone = "the agent session that started it is done"

    /// `liveReapers` and `goneReapers` are Testcontainers session ids whose Ryuk reaper is running, or was seen
    /// running and has since gone. A session in neither (Ryuk disabled, or not seen yet) is decided by ownership.
    public static func decide(
        _ item: LeftoverItem, startedAt: Double, facts: OwnershipFacts, keeps: KeepList,
        liveReapers: Set<String>, goneReapers: Set<String>, now: Double, config: LeftoversConfig
    ) -> LeftoverDecision {
        if keeps.covers(item, now: now) { return .kept }

        var idleThreshold = Double(config.afterMinutes) * 60
        switch item.lifetime {
        case .keep:
            return .kept
        case .duration(let seconds):
            return now - startedAt >= seconds ? .leftover(reason: "older than its \(label(seconds)) lifetime") : .notYet
        case .temporary:
            idleThreshold = min(idleThreshold, temporaryIdle)
        case nil:
            break
        }

        if item.kind == .testcontainers, let session = item.sessionId {
            if liveReapers.contains(session) { return .notYet }
            if goneReapers.contains(session) { return .leftover(reason: "its test run finished") }
        }

        if let owner = intentOwner(startedAt: startedAt, facts: facts) {
            let run = facts.runs[owner] ?? unrecordedRun(owner, facts: facts)
            let decider = inheritor(of: run, facts: facts)?.run ?? run
            let done = isDone(decider, lastActivity: lastActivity(decider), threshold: idleThreshold, now: now, facts: facts)
            return done ? .leftover(reason: ownerDone) : .notYet
        }

        let minute = (startedAt / 60).rounded(.down) * 60
        let owners = facts.runs.values.filter { $0.activeMinutes.contains(minute) || $0.activeMinutes.contains(minute - 60) }
        if !owners.isEmpty {
            // Several runs active in the creation minute can't be told apart, so the item waits for all of them.
            let allDone = owners.allSatisfy { run in
                let decider = inheritor(of: run, facts: facts)?.run ?? run
                return isDone(decider, lastActivity: lastActivity(decider), threshold: idleThreshold, now: now, facts: facts)
            }
            return allDone ? .leftover(reason: ownerDone) : .notYet
        }

        let hours = config.unownedAfterHours
        return now - startedAt >= Double(hours) * 3600
            ? .leftover(reason: "running for more than \(hours) hours with no agent owner") : .notYet
    }

    /// The run whose marker is the latest at or before the start, within the window; the closest marker wins.
    private static func intentOwner(startedAt: Double, facts: OwnershipFacts) -> ProcessKey? {
        facts.intents
            .filter { $0.ts <= startedAt + clockSkew && startedAt - $0.ts <= intentWindow }
            .max { $0.ts < $1.ts }?.root
    }

    /// A marker can arrive before the recorder has seen its process, so the run counts as live from its markers.
    private static func unrecordedRun(_ root: ProcessKey, facts: OwnershipFacts) -> RunFacts {
        let marks = facts.intents.filter { $0.root == root }.map(\.ts)
        return RunFacts(sessionIds: [], started: marks.min() ?? 0, ended: nil, lastIntent: marks.max(), activeMinutes: [])
    }

    /// Markers only come from container commands, so an agent busy with other work still counts as active
    /// through its recorded CPU minutes; a minute's activity can run to its end.
    private static func lastActivity(_ run: RunFacts) -> Double {
        max(run.lastIntent ?? run.started, (run.activeMinutes.last ?? -.infinity) + 60)
    }

    /// A resumed session runs under a new process, so a live run sharing a session id takes over an ended owner.
    /// The most recently active one wins; ties go to the smaller key so the choice doesn't follow dictionary order.
    static func inheritor(of run: RunFacts, facts: OwnershipFacts) -> (key: ProcessKey, run: RunFacts)? {
        guard run.ended != nil, !run.sessionIds.isEmpty else { return nil }
        return facts.runs
            .filter { $0.value.ended == nil && !$0.value.sessionIds.isDisjoint(with: run.sessionIds) }
            .max { lhs, rhs in
                let l = lastActivity(lhs.value), r = lastActivity(rhs.value)
                if l != r { return l < r }
                return (lhs.key.pid, lhs.key.start) > (rhs.key.pid, rhs.key.start)
            }
            .map { (key: $0.key, run: $0.value) }
    }

    private static func isDone(
        _ run: RunFacts, lastActivity: Double, threshold: Double, now: Double, facts: OwnershipFacts
    ) -> Bool {
        if let ended = run.ended { return now - ended >= exitGrace }
        return facts.awakeSeconds(lastActivity, now) >= threshold
    }

    /// `Lifetime` keeps only seconds, so the label is rebuilt in the largest whole unit: `24h` reads as `1d`.
    private static func label(_ seconds: Double) -> String {
        // A label or a hand-edited sidecar can hold any magnitude, and Int(_:) traps past Int.max.
        let s = seconds.isFinite ? Int(min(max(seconds, 0), 1e15)) : 0
        if s % 86_400 == 0 { return "\(s / 86_400)d" }
        if s % 3600 == 0 { return "\(s / 3600)h" }
        return "\(s / 60)m"
    }
}

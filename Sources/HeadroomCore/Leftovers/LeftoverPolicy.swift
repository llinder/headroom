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
    /// Recorded awake seconds in [from, to): sleep and recorder gaps don't count toward idleness.
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
    private static let ownerDone = "the agent session that started it is done"

    public static func decide(
        _ item: LeftoverItem, startedAt: Double, facts: OwnershipFacts, keeps: KeepList, reapers: Set<String>,
        now: Double, config: LeftoversConfig
    ) -> LeftoverDecision {
        if keeps.covers(item, now: now) { return .kept }

        var idleThreshold = Double(config.afterMinutes) * 60
        switch item.lifetime {
        case .keep:
            return .kept
        case .duration(let seconds):
            return now - startedAt >= seconds ? .leftover(reason: "older than its \(label(seconds)) lifetime") : .notYet
        case .temporary:
            idleThreshold = 0
        case nil:
            break
        }

        if item.kind == .testcontainers, let session = item.sessionId, !reapers.contains(session) {
            return .leftover(reason: "its test run finished")
        }

        if let owner = intentOwner(startedAt: startedAt, facts: facts) {
            let run = facts.runs[owner] ?? unrecordedRun(owner, facts: facts)
            let decider = inheritor(of: run, facts: facts) ?? run
            let done = isDone(decider, lastActivity: decider.lastIntent ?? decider.started,
                              threshold: idleThreshold, now: now, facts: facts)
            return done ? .leftover(reason: ownerDone) : .notYet
        }

        let minute = (startedAt / 60).rounded(.down) * 60
        let owners = facts.runs.values.filter { $0.activeMinutes.contains(minute) || $0.activeMinutes.contains(minute - 60) }
        if !owners.isEmpty {
            // Several runs active in the creation minute can't be told apart, so the item waits for all of them.
            let allDone = owners.allSatisfy { run in
                let decider = inheritor(of: run, facts: facts) ?? run
                return isDone(decider, lastActivity: decider.activeMinutes.last ?? decider.started,
                              threshold: idleThreshold, now: now, facts: facts)
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
            .filter { $0.ts <= startedAt && startedAt - $0.ts <= intentWindow }
            .max { $0.ts < $1.ts }?.root
    }

    /// A marker can arrive before the recorder has seen its process, so the run counts as live from its markers.
    private static func unrecordedRun(_ root: ProcessKey, facts: OwnershipFacts) -> RunFacts {
        let marks = facts.intents.filter { $0.root == root }.map(\.ts)
        return RunFacts(sessionIds: [], started: marks.min() ?? 0, ended: nil, lastIntent: marks.max(), activeMinutes: [])
    }

    /// A resumed session runs under a new process, so a live run sharing a session id takes over an ended owner.
    private static func inheritor(of run: RunFacts, facts: OwnershipFacts) -> RunFacts? {
        guard run.ended != nil, !run.sessionIds.isEmpty else { return nil }
        return facts.runs.values
            .filter { $0.ended == nil && !$0.sessionIds.isDisjoint(with: run.sessionIds) }
            .max { ($0.lastIntent ?? -.infinity) < ($1.lastIntent ?? -.infinity) }
    }

    /// `temporary` drops the idle wait but still needs some awake time since the last activity, so an owner
    /// active right now keeps its containers.
    private static func isDone(
        _ run: RunFacts, lastActivity: Double, threshold: Double, now: Double, facts: OwnershipFacts
    ) -> Bool {
        if run.ended != nil { return true }
        let idle = facts.awakeSeconds(lastActivity, now)
        return idle > 0 && idle >= threshold
    }

    /// `Lifetime` keeps only seconds, so the label is rebuilt in the largest whole unit: `24h` reads as `1d`.
    private static func label(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s % 86_400 == 0 { return "\(s / 86_400)d" }
        if s % 3600 == 0 { return "\(s / 3600)h" }
        return "\(s / 60)m"
    }
}

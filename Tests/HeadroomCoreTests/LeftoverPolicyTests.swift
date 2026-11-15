import Foundation
import Testing

@testable import HeadroomCore

private let t0 = 1_800_000_000.0
private let a = ProcessKey(pid: 100, start: 1_000)
private let b = ProcessKey(pid: 200, start: 2_000)

private func item(kind: LeftoverKind = .container, lifetime: Lifetime? = nil, sessionId: String? = nil) -> LeftoverItem {
    LeftoverItem(
        key: "orbstack/\(kind.rawValue)/x", engine: "orbstack", kind: kind, name: "x", containerIDs: ["abc"],
        sessionId: sessionId, lifetime: lifetime, cleanup: [], containerNames: ["x"])
}

private func run(
    sessions: Set<String> = [], started: Double = t0 - 3600, ended: Double? = nil, lastIntent: Double? = nil,
    activeMinutes: [Double] = []
) -> RunFacts {
    RunFacts(sessionIds: sessions, started: started, ended: ended, lastIntent: lastIntent, activeMinutes: activeMinutes)
}

private let wallClock: @Sendable (Double, Double) -> Double = { from, to in max(0, to - from) }

/// `intents` are start markers; `lookups` are markers from commands that only use containers, such as `docker ps`.
private func facts(
    intents: [(ts: Double, root: ProcessKey)] = [], lookups: [(ts: Double, root: ProcessKey)] = [],
    runs: [ProcessKey: RunFacts] = [:], awake: @escaping @Sendable (Double, Double) -> Double = wallClock
) -> OwnershipFacts {
    OwnershipFacts(
        intents: intents.map { (ts: $0.ts, root: $0.root, start: true) } + lookups.map { (ts: $0.ts, root: $0.root, start: false) },
        runs: runs, awakeSeconds: awake)
}

private func decide(
    _ item: LeftoverItem, startedAt: Double = t0, facts: OwnershipFacts = facts(), keeps: KeepList = KeepList(),
    liveReapers: Set<String> = [], goneReapers: Set<String> = [], now: Double
) -> LeftoverDecision {
    LeftoverPolicy.decide(
        item, startedAt: startedAt, facts: facts, keeps: keeps, liveReapers: liveReapers, goneReapers: goneReapers,
        now: now, config: LeftoversConfig())
}

struct LeftoverPolicyTests {
    @Test func keepListWins() {
        let keeps = KeepList(entries: [KeepEntry(name: "x")])
        #expect(decide(item(lifetime: .duration(60)), keeps: keeps, now: t0 + 86_400 * 30) == .kept)
    }

    @Test func labelKeep() {
        #expect(decide(item(lifetime: .keep), now: t0 + 86_400 * 30) == .kept)
    }

    @Test func durationNotYetThenLeftover() {
        let sevenDays = item(lifetime: Lifetime(label: "7d"))
        #expect(decide(sevenDays, now: t0 + 6 * 86_400) == .notYet)
        #expect(decide(sevenDays, now: t0 + 8 * 86_400) == .leftover(reason: "older than its 7d lifetime"))
        #expect(decide(item(lifetime: Lifetime(label: "8h")), now: t0 + 9 * 3600)
            == .leftover(reason: "older than its 8h lifetime"))
    }

    @Test func temporaryLeftoverAfterFiveIdleMinutes() {
        let temporary = item(lifetime: .temporary)
        let intents = [(ts: t0 - 30, root: a)]
        let live = facts(intents: intents, runs: [a: run(lastIntent: t0 + 100)])
        #expect(decide(temporary, facts: live, now: t0 + 100) == .notYet)
        #expect(decide(temporary, facts: live, now: t0 + 110) == .notYet)
        #expect(decide(temporary, facts: live, now: t0 + 401)
            == .leftover(reason: "the agent session that started it is done"))
        #expect(decide(item(), facts: live, now: t0 + 401) == .notYet)
    }

    @Test func onlyStartMarkersNameTheOwner() {
        // An agent's `docker ps` two minutes before a human's `compose up` doesn't make the agent the owner.
        let agent = run(ended: t0 + 60, lastIntent: t0 - 120)
        let peeked = facts(lookups: [(ts: t0 - 120, root: a)], runs: [a: agent])
        #expect(decide(item(kind: .compose), facts: peeked, now: t0 + 3600) == .notYet)

        let started = facts(intents: [(ts: t0 - 120, root: a)], runs: [a: agent])
        #expect(decide(item(kind: .compose), facts: started, now: t0 + 3600)
            == .leftover(reason: "the agent session that started it is done"))

        // A lookup still counts as activity, so a later one keeps the owner of a start marker alive.
        let busy = facts(
            intents: [(ts: t0 - 120, root: a)], lookups: [(ts: t0 + 3000, root: a)],
            runs: [a: run(lastIntent: t0 + 3000)])
        #expect(decide(item(), facts: busy, now: t0 + 3700) == .notYet)
    }

    @Test func recentActivityKeepsOwnerAlive() {
        let minute = ((t0 + 5000) / 60).rounded(.down) * 60
        let f = facts(intents: [(ts: t0 - 30, root: a)], runs: [a: run(lastIntent: t0 - 30, activeMinutes: [minute])])
        #expect(decide(item(), facts: f, now: minute + 60 + 3599) == .notYet)
        #expect(decide(item(), facts: f, now: minute + 60 + 3600)
            == .leftover(reason: "the agent session that started it is done"))
    }

    @Test func inheritorActivityCounts() {
        let minute = ((t0 + 6000) / 60).rounded(.down) * 60
        let runs = [
            a: run(sessions: ["sess"], ended: t0 + 600, lastIntent: t0 - 30),
            b: run(sessions: ["sess"], started: t0 + 700, activeMinutes: [minute]),
        ]
        let f = facts(intents: [(ts: t0 - 30, root: a)], runs: runs)
        #expect(decide(item(), facts: f, now: t0 + 7200) == .notYet)
        #expect(decide(item(), facts: f, now: minute + 60 + 3600)
            == .leftover(reason: "the agent session that started it is done"))
    }

    @Test func testcontainersReaperStates() {
        let tc = item(kind: .testcontainers, sessionId: "s1")
        let endedOwner = facts(intents: [(ts: t0 - 30, root: a)], runs: [a: run(ended: t0, lastIntent: t0 - 30)])
        #expect(decide(tc, facts: endedOwner, liveReapers: ["s1"], now: t0 + 7200) == .notYet)
        #expect(decide(tc, facts: endedOwner, goneReapers: ["s1"], now: t0 + 60)
            == .leftover(reason: "its test run finished"))
        #expect(decide(tc, facts: endedOwner, liveReapers: ["s2"], goneReapers: ["s3"], now: t0 + 7200)
            == .leftover(reason: "the agent session that started it is done"))

        // With Ryuk disabled there is never a reaper, so the item falls through to its owner.
        let activeOwner = facts(intents: [(ts: t0 - 30, root: a)], runs: [a: run(lastIntent: t0 + 3000)])
        #expect(decide(tc, facts: activeOwner, now: t0 + 3600) == .notYet)
    }

    @Test func closestIntentOwns() {
        let intents = [(ts: t0 - 300, root: a), (ts: t0 - 30, root: b)]
        let runs = [a: run(lastIntent: t0 + 7000), b: run(ended: t0 + 100, lastIntent: t0 - 30)]
        #expect(decide(item(), facts: facts(intents: intents, runs: runs), now: t0 + 400)
            == .leftover(reason: "the agent session that started it is done"))

        let flipped = [a: run(ended: t0 + 100, lastIntent: t0 - 300), b: run(lastIntent: t0 + 7000)]
        #expect(decide(item(), facts: facts(intents: intents, runs: flipped), now: t0 + 7200) == .notYet)
    }

    @Test func intentTooOldIsNotOwner() {
        // The run that marked 700 s before the start has ended, but it is too far away to own the item; the
        // fallback finds the live run active in the creation minute instead.
        let minute = (t0 / 60).rounded(.down) * 60
        let runs = [
            a: run(ended: t0 + 10, lastIntent: t0 - 700),
            b: run(activeMinutes: [minute, minute + 60]),
        ]
        #expect(decide(item(), facts: facts(intents: [(ts: t0 - 700, root: a)], runs: runs), now: t0 + 300) == .notYet)
    }

    @Test func ownerIdleSixtyAwakeMinutesIsDone() {
        let lastIntent = t0 - 30
        let sleepStart = t0 + 1800, sleepEnd = sleepStart + 10 * 3600
        let awake: @Sendable (Double, Double) -> Double = { from, to in
            let asleep = max(0, min(to, sleepEnd) - max(from, sleepStart))
            return max(0, to - from - asleep)
        }
        let f = facts(intents: [(ts: lastIntent, root: a)], runs: [a: run(lastIntent: lastIntent)], awake: awake)
        #expect(decide(item(), facts: f, now: t0 + 8 * 3600) == .notYet)
        #expect(decide(item(), facts: f, now: sleepEnd + 1760) == .notYet)
        #expect(decide(item(), facts: f, now: sleepEnd + 1770)
            == .leftover(reason: "the agent session that started it is done"))
    }

    @Test func resumedSessionKeepsOwnership() {
        let intents = [(ts: t0 - 30, root: a)]
        let older = ProcessKey(pid: 300, start: 3_000)
        let runs = [
            a: run(sessions: ["sess"], ended: t0 + 600, lastIntent: t0 - 30),
            older: run(sessions: ["sess"], started: t0 + 700, lastIntent: t0 + 800),
            b: run(sessions: ["sess", "other"], started: t0 + 700, lastIntent: t0 + 7000),
        ]
        // b has the most recent intent, so its state decides, not the idle `older` run.
        #expect(decide(item(), facts: facts(intents: intents, runs: runs), now: t0 + 7200) == .notYet)

        let unrelated = [
            a: run(sessions: ["sess"], ended: t0 + 600, lastIntent: t0 - 30),
            b: run(sessions: ["other"], lastIntent: t0 + 7000),
        ]
        #expect(decide(item(), facts: facts(intents: intents, runs: unrelated), now: t0 + 7200)
            == .leftover(reason: "the agent session that started it is done"))
    }

    @Test func fallbackActiveMinuteOwner() {
        let minute = (t0 / 60).rounded(.down) * 60
        let active = facts(runs: [a: run(activeMinutes: [minute - 60, minute + 1200])])
        #expect(decide(item(), facts: active, now: minute + 1260 + 3599) == .notYet)
        #expect(decide(item(), facts: active, now: minute + 1260 + 3600)
            == .leftover(reason: "the agent session that started it is done"))

        let elsewhere = facts(runs: [a: run(activeMinutes: [minute - 120, minute + 60])])
        #expect(decide(item(), facts: elsewhere, now: t0 + 3600 * 5) == .notYet)
    }

    @Test func unownedAfter24h() {
        #expect(decide(item(), now: t0 + 23 * 3600) == .notYet)
        #expect(decide(item(), now: t0 + 24 * 3600)
            == .leftover(reason: "running for more than 24 hours with no agent owner"))
    }

    @Test func intentWithoutRecordedRunIsLiveUntilIdle() {
        let f = facts(intents: [(ts: t0 - 30, root: a)])
        #expect(decide(item(), facts: f, now: t0 + 1800) == .notYet)
        #expect(decide(item(), facts: f, now: t0 + 3570)
            == .leftover(reason: "the agent session that started it is done"))
    }

    @Test func intentsAllowFiveSecondsOfClockSkew() {
        let runs = [a: run(ended: t0, lastIntent: t0 + 5), b: run(lastIntent: t0 + 7000)]
        let skewed = facts(intents: [(ts: t0 + 5, root: a)], runs: runs)
        #expect(decide(item(), facts: skewed, now: t0 + 600)
            == .leftover(reason: "the agent session that started it is done"))
        let tooLate = facts(intents: [(ts: t0 + 6, root: a)], runs: runs)
        #expect(decide(item(), facts: tooLate, now: t0 + 600) == .notYet)
    }

    @Test func endedOwnerGetsFiveMinutesOfGrace() {
        let f = facts(intents: [(ts: t0 - 30, root: a)], runs: [a: run(ended: t0 + 100, lastIntent: t0 - 30)])
        #expect(decide(item(), facts: f, now: t0 + 399) == .notYet)
        #expect(decide(item(), facts: f, now: t0 + 400)
            == .leftover(reason: "the agent session that started it is done"))
    }

    @Test func inheritorIsTheMostRecentlyActiveLiveRun() {
        let c = ProcessKey(pid: 300, start: 3_000)
        let runs = [
            a: run(sessions: ["sess"], ended: t0 + 600, lastIntent: t0 - 30),
            b: run(sessions: ["sess"], started: t0 + 5000),
            c: run(sessions: ["sess"], started: t0 + 700),
        ]
        let f = facts(intents: [(ts: t0 - 30, root: a)], runs: runs)
        #expect(decide(item(), facts: f, now: t0 + 7200) == .notYet)

        let tied = [
            a: run(sessions: ["sess"], ended: t0 + 600),
            c: run(sessions: ["sess"], started: t0 + 700),
            b: run(sessions: ["sess"], started: t0 + 700),
        ]
        let owner = tied[a] ?? run()
        for _ in 0..<20 {
            #expect(LeftoverPolicy.inheritor(of: owner, facts: facts(runs: tied))?.key == b)
        }
    }

    @Test func fallbackWaitsForEveryActiveOwner() {
        let minute = (t0 / 60).rounded(.down) * 60
        let runs = [
            a: run(ended: t0 + 120, activeMinutes: [minute]),
            b: run(activeMinutes: [minute - 60, minute + 3000]),
        ]
        #expect(decide(item(), facts: facts(runs: runs), now: t0 + 3600) == .notYet)
        let both = [a: run(ended: t0 + 120, activeMinutes: [minute]), b: run(ended: t0 + 200, activeMinutes: [minute])]
        #expect(decide(item(), facts: facts(runs: both), now: t0 + 600)
            == .leftover(reason: "the agent session that started it is done"))
    }

    @Test func fallbackOwnerWithLaterIntentIsNotDone() {
        let minute = (t0 / 60).rounded(.down) * 60
        let f = facts(runs: [a: run(lastIntent: t0 + 3000, activeMinutes: [minute])])
        #expect(decide(item(), facts: f, now: t0 + 4000) == .notYet)
        #expect(decide(item(), facts: f, now: t0 + 6600)
            == .leftover(reason: "the agent session that started it is done"))
    }
}

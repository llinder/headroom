import Foundation
import HeadroomCore
import Testing
@testable import HeadroomCLI

@Suite struct PreToolAdviceTests {
    private let config = AgentsConfig()
    private let now = 1_000_000.0

    private func snap(
        age: Double = 1, pressure: UInt8 = 1, swapUsed: UInt64 = 0, growth: Int64 = 0,
        leftoverCount: UInt16 = 0, leftoverBytes: UInt64 = 0
    ) -> LiveSnapshot {
        LiveSnapshot(
            timestamp: now - age, cpuBusy: 0, memUsed: 0, memTotal: 0, swapUsed: swapUsed,
            diskFree: 0, diskCapacity: 0, pressure: pressure, thermal: 0, limitFlags: 0,
            activeAgents: 0, idleAgents: 0,
            leftoverCount: leftoverCount, leftoverBytes: leftoverBytes, swapGrowthBytesPerMin: growth)
    }

    @Test func staleSnapshotNeverTriggers() {
        #expect(PreToolAdvice.trigger(snap(age: 61, pressure: 4), now: now, config: config) == nil)
        #expect(PreToolAdvice.trigger(snap(age: 60, pressure: 4), now: now, config: config) == .critical)
    }

    @Test func criticalBeatsSwapGrowth() {
        let s = snap(pressure: 4, growth: 500_000_000, leftoverBytes: 2_000_000_000)
        #expect(PreToolAdvice.trigger(s, now: now, config: config) == .critical)
        #expect(PreToolAdvice.trigger(snap(growth: 268_435_456, leftoverBytes: 2_000_000_000), now: now, config: config) == .swapGrowing)
    }

    @Test func warnAloneDoesNotTrigger() {
        #expect(PreToolAdvice.trigger(snap(pressure: 2), now: now, config: config) == nil)
    }

    @Test func leftoversOverAGigTrigger() {
        #expect(PreToolAdvice.trigger(snap(leftoverBytes: 1_000_000_000), now: now, config: config) == .leftovers)
        #expect(PreToolAdvice.trigger(snap(leftoverBytes: 999_999_999), now: now, config: config) == nil)
    }

    @Test func classifyStripsEnvAndChains() {
        let heavy = config.heavyCommands
        #expect(PreToolAdvice.classify("cd x && FOO=1 time go test ./...", heavy: heavy).kind == .go)
        let kind = PreToolAdvice.classify("echo hi | kind create cluster", heavy: heavy)
        #expect(kind.kind == .container)
        #expect(kind.containerIntent)
        let none = PreToolAdvice.classify("ls", heavy: heavy)
        #expect(none.kind == nil)
        #expect(!none.containerIntent)
        #expect(PreToolAdvice.classify("sudo env A=b make all\nls", heavy: heavy).kind == .build)
        #expect(PreToolAdvice.classify("ls; npm test || true", heavy: heavy).kind == .js)
        #expect(PreToolAdvice.classify("gofmt x", heavy: heavy).kind == nil)
        #expect(PreToolAdvice.classify("docker ps", heavy: heavy).kind == nil)
        #expect(PreToolAdvice.classify("docker compose up -d", heavy: heavy).containerIntent)
        #expect(PreToolAdvice.classify("docker buildx build .", heavy: heavy).containerIntent)
    }

    @Test func adviceTextExact() {
        let s = snap(swapUsed: 14_000_000_000, growth: 600_000_000)
        let critical = "headroom: memory pressure is critical (swap 14.0 GB, +0.6 GB/min)."
        #expect(PreToolAdvice.text(trigger: .critical, kind: .go, snapshot: s)
            == critical + " Prefer go test -p 2 ./<package>/... over the whole module, and one package build at a time.")
        #expect(PreToolAdvice.text(trigger: .critical, kind: .container, snapshot: s)
            == critical + " Avoid starting another container or Kind cluster until pressure drops.")
        #expect(PreToolAdvice.text(trigger: .critical, kind: .build, snapshot: s)
            == critical + " Prefer building one target at a time.")
        #expect(PreToolAdvice.text(trigger: .critical, kind: .js, snapshot: s)
            == critical + " Prefer running one test file or project at a time.")
        let narrow = " Prefer narrow builds and tests, and avoid starting containers or clusters right now."
        #expect(PreToolAdvice.text(trigger: .critical, kind: nil, snapshot: s) == critical + narrow)
        #expect(PreToolAdvice.text(trigger: .swapGrowing, kind: nil, snapshot: s)
            == "headroom: swap is growing fast (+0.6 GB/min, 14.0 GB used)." + narrow)
        #expect(PreToolAdvice.text(trigger: .leftovers, kind: nil, snapshot: s) == "headroom: memory is tight." + narrow)
        #expect(PreToolAdvice.text(trigger: .leftovers, kind: .build, snapshot: s)
            == "headroom: memory is tight. Prefer building one target at a time.")
    }

    @Test func adviceTextFormatsNegativeGrowthAndLeftoverSuffix() {
        let neg = snap(swapUsed: 1_500_000_000, growth: -260_000_000)
        #expect(PreToolAdvice.text(trigger: .swapGrowing, kind: .js, snapshot: neg).hasPrefix("headroom: swap is growing fast (-0.3 GB/min, 1.5 GB used)."))
        let one = snap(leftoverCount: 1, leftoverBytes: 1_200_000_000)
        #expect(PreToolAdvice.text(trigger: .leftovers, kind: .build, snapshot: one)
            == "headroom: memory is tight. Prefer building one target at a time. 1 abandoned container holds 1.2 GB; see headroom leftovers.")
        let many = snap(leftoverCount: 2, leftoverBytes: 3_100_000_000)
        #expect(PreToolAdvice.text(trigger: .leftovers, kind: .build, snapshot: many)
            == "headroom: memory is tight. Prefer building one target at a time. 2 abandoned containers hold 3.1 GB; see headroom leftovers.")
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "headroom-throttle-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func throttleDueThenNotThenDue() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let throttle = PreToolAdvice.Throttle(directory: dir)
        #expect(throttle.due(key: "sess.1-a_b", now: 1000, minutes: 5))
        throttle.touch(key: "sess.1-a_b", now: 1000)
        #expect(!throttle.due(key: "sess.1-a_b", now: 1000 + 4 * 60, minutes: 5))
        #expect(throttle.due(key: "sess.1-a_b", now: 1000 + 5 * 60, minutes: 5))
        #expect(throttle.due(key: "other", now: 1000, minutes: 5))
    }

    @Test func throttleRejectsBadKeys() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let throttle = PreToolAdvice.Throttle(directory: dir)
        for key in ["../x", "a b", "", String(repeating: "a", count: 129)] {
            #expect(!throttle.due(key: key, now: 1000, minutes: 5))
            throttle.touch(key: key, now: 1000)
            #expect(!throttle.due(key: key, now: 1_000_000, minutes: 5))
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appending(path: "x").path))
    }
}

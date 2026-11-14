import Testing

@testable import HeadroomCore

struct SleepStateTests {
    /// Runs `count` ticks and returns which of them resumed.
    func ticks(_ s: inout SleepState, _ count: Int) -> [Bool] {
        (0..<count).map { _ in s.onTick() }
    }

    @Test func awakeTicksNeverResume() {
        var s = SleepState()
        #expect(ticks(&s, 10).allSatisfy { !$0 })
        #expect(!s.isAsleep)
    }

    @Test func sixthAsleepTickResumes() {
        var s = SleepState()
        s.onWillSleep()
        #expect(ticks(&s, 5) == [false, false, false, false, false])
        #expect(s.isAsleep)
        #expect(ticks(&s, 2) == [true, false])
        #expect(!s.isAsleep)
    }

    @Test func wakeResetsTheCount() {
        var s = SleepState()
        s.onWillSleep()
        _ = ticks(&s, 5)
        s.onDidWake()
        #expect(!s.isAsleep)
        s.onWillSleep()
        #expect(ticks(&s, 6) == [false, false, false, false, false, true])
    }

    @Test func sleepAgainResetsTheCount() {
        var s = SleepState()
        s.onWillSleep()
        _ = ticks(&s, 5)
        s.onWillSleep()
        #expect(ticks(&s, 6) == [false, false, false, false, false, true])
    }
}

import Foundation
import Testing

@testable import HeadroomCore

struct GapDetectorTests {
    @Test func noGapWhenRebooted() {
        let gap = GapDetector.startupGap(lastHeartbeat: 1000, now: 9000, bootTime: 2000, lastSleep: nil, lastWake: nil)
        #expect(gap == nil)
    }

    @Test func gapWhenAwakeAndAbsent() {
        let gap = GapDetector.startupGap(lastHeartbeat: 1000, now: 2000, bootTime: 0, lastSleep: nil, lastWake: nil)
        #expect(gap == DateInterval(start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 2000)))
    }

    @Test func sleepSubtracted() {
        let gap = GapDetector.startupGap(lastHeartbeat: 1000, now: 5000, bootTime: 0, lastSleep: 1100, lastWake: 4900)
        #expect(gap == nil)
    }

    @Test func shortGapIgnored() {
        let gap = GapDetector.startupGap(lastHeartbeat: 1000, now: 1090, bootTime: 0, lastSleep: nil, lastWake: nil)
        #expect(gap == nil)
    }

    @Test func firstRunNoHeartbeat() {
        let gap = GapDetector.startupGap(lastHeartbeat: nil, now: 5000, bootTime: 0, lastSleep: nil, lastWake: nil)
        #expect(gap == nil)
    }

    // A gap event must never cover asleep time, or coverage would count it twice.
    @Test func gapAroundSleepIsTheLongerAwakeStretch() {
        let gap = GapDetector.startupGap(lastHeartbeat: 1000, now: 9000, bootTime: 0, lastSleep: 1300, lastWake: 4000)
        #expect(gap == DateInterval(start: Date(timeIntervalSince1970: 4000), end: Date(timeIntervalSince1970: 9000)))
        let early = GapDetector.startupGap(lastHeartbeat: 1000, now: 4200, bootTime: 0, lastSleep: 3000, lastWake: 4000)
        #expect(early == DateInterval(start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 3000)))
    }

    @Test func sleepBeforeHeartbeatIgnored() {
        let gap = GapDetector.startupGap(lastHeartbeat: 1000, now: 2000, bootTime: 0, lastSleep: 100, lastWake: 200)
        #expect(gap == DateInterval(start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 2000)))
    }

    @Test func kernelTimesAreSane() {
        let now = Date().timeIntervalSince1970
        let boot = GapDetector.bootTime()
        #expect(boot > 0 && boot < now)
        let (sleep, wake) = GapDetector.lastSleepWake()
        if let sleep { #expect(sleep > 0 && sleep < now) }
        if let wake { #expect(wake > 0 && wake < now) }
    }
}

struct LocalDayTests {
    func calendar(_ zone: String) throws -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = try #require(TimeZone(identifier: zone))
        return c
    }

    @Test func ordinaryDay() throws {
        let c = try calendar("UTC")
        let day = LocalDay(containing: 1_800_000_000, calendar: c)
        #expect(day.name == "2027-01-15")
        #expect(day.end - day.start == 86_400)
        #expect(day.start <= 1_800_000_000 && 1_800_000_000 < day.end)
        #expect(day.previous(calendar: c).name == "2027-01-14")
        #expect(day.previous(calendar: c).end == day.start)
    }

    @Test func spanCoversEveryDayTouched() throws {
        let c = try calendar("UTC")
        let noon: Double = 1_799_971_200 + 12 * 3600  // 2027-01-15 12:00 UTC
        #expect(LocalDay.span(from: noon - 3600, through: noon, limit: 31, calendar: c).map(\.name) == ["2027-01-15"])
        #expect(
            LocalDay.span(from: noon - 13 * 3600, through: noon, limit: 31, calendar: c).map(\.name)
                == ["2027-01-14", "2027-01-15"])
        let capped = LocalDay.span(from: noon - 90 * 86_400, through: noon, limit: 3, calendar: c)
        #expect(capped.map(\.name) == ["2027-01-13", "2027-01-14", "2027-01-15"])
    }

    @Test func dstDaysAreShortAndLong() throws {
        let c = try calendar("America/New_York")
        // Noon local on each transition day.
        let spring = LocalDay(containing: 1_772_985_600, calendar: c)
        #expect(spring.name == "2026-03-08")
        #expect(spring.end - spring.start == 23 * 3600)
        let fall = LocalDay(containing: 1_793_552_400, calendar: c)
        #expect(fall.name == "2026-11-01")
        #expect(fall.end - fall.start == 25 * 3600)
    }
}

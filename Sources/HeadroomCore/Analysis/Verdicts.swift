import Foundation

public struct Verdict: Equatable, Sendable {
    public var resource: String
    public var sentence: String
    public var isProblem: Bool

    public init(resource: String, sentence: String, isProblem: Bool) {
        self.resource = resource
        self.sentence = sentence
        self.isProblem = isProblem
    }
}

/// Number formatting shared by every report sentence, pinned to `en_US_POSIX` so a report reads the same
/// whatever the user's locale.
enum Wording {
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", locale: posix, value)
    }

    static func hours(_ seconds: Double) -> String { decimal(seconds / 3600, places: 1) }

    /// One decimal with a whole number's ".0" dropped ("82%", "99.6%"); under 10 there are no decimals ("9%").
    static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        return (value < 10 ? decimal(value, places: 0) : trimmed(value)) + "%"
    }

    static func trimmed(_ value: Double) -> String {
        let text = decimal(value, places: 1)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    static func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
}

public enum Verdicts {
    private static let cpuProblemSeconds = 1800.0
    // Under 0.1 hours rounds to "0.0 hours", which would read as a contradiction.
    private static let cpuRarelySeconds = 360.0
    private static let storageFullFraction = 0.9
    // Below this the weekly figure rounds to "0 GB", so the drive isn't described as growing.
    private static let minWeeklyGrowthBytes = 50_000_000.0
    private static let minTrendSpan = 7.0 * 86_400

    public static func memory(limitedByDay: [String: Double], workdays: [String], minSeconds: Double) -> Verdict {
        guard !workdays.isEmpty else { return Verdict(resource: "memory", sentence: noWorkdays, isProblem: false) }
        let limited = workdays.map { limitedByDay[$0] ?? 0 }
        let days = limited.filter { $0 >= minSeconds }.count
        let total = Wording.plural(workdays.count, "workday")
        guard days > 0 else {
            return Verdict(resource: "memory", sentence: "Memory never ran out in \(total).", isProblem: false)
        }
        let average = limited.reduce(0, +) / Double(workdays.count)
        // An average that rounds to "0.0 hours" would contradict "ran out".
        let howLong =
            average < 180
            ? "for under 0.1 hours a day on average" : "an average of \(Wording.hours(average)) hours a day"
        return Verdict(resource: "memory", sentence: "Memory ran out on \(days) of \(total), \(howLong).", isProblem: true)
    }

    /// Days without a saturated row count as zero, so the median is over every workday.
    public static func cpu(saturatedByDay: [String: Double], workdays: [String]) -> Verdict {
        guard !workdays.isEmpty else { return Verdict(resource: "cpu", sentence: noWorkdays, isProblem: false) }
        let typical = median(workdays.map { saturatedByDay[$0] ?? 0 })
        let sentence =
            typical < cpuRarelySeconds
            ? "The processor was rarely fully busy."
            : "The processor was fully busy for \(Wording.hours(typical)) hours on a typical workday."
        return Verdict(resource: "cpu", sentence: sentence, isProblem: typical > cpuProblemSeconds)
    }

    /// `growthBytesPerDay` comes from `storageGrowthBytesPerDay` and is passed in, so the report computes it once and the
    /// verdict and the spec recommendation can never disagree about whether a trend was measured.
    public static func storage(
        capacity: UInt64, dailyFree: [(Date, UInt64)], growthBytesPerDay: Double?, now: Date, calendar: Calendar
    ) -> Verdict {
        guard let latest = dailyFree.max(by: { $0.0 < $1.0 }), capacity > 0 else {
            return Verdict(resource: "storage", sentence: "Storage use wasn't recorded.", isProblem: false)
        }
        let free = Double(min(latest.1, capacity))
        let fullFraction = (Double(capacity) - free) / Double(capacity)
        let full = "Storage is \(Wording.percent(fullFraction)) full"
        let nearlyFull = fullFraction >= storageFullFraction

        guard free > 0, let lossPerDay = growthBytesPerDay else {
            return Verdict(resource: "storage", sentence: "\(full).", isProblem: nearlyFull || free == 0)
        }
        guard lossPerDay * 7 >= minWeeklyGrowthBytes else {
            return Verdict(resource: "storage", sentence: "\(full) and not growing.", isProblem: nearlyFull)
        }
        let growing = "\(full) and growing \(Wording.trimmed(lossPerDay * 7 / 1e9)) GB a week."
        // The latest reading is where the projection starts; it can be older than `now`.
        let fill = latest.0.addingTimeInterval(free / lossPerDay * 86_400)
        let isProblem = nearlyFull || fill <= months(12, after: now, calendar)
        guard fill <= months(24, after: now, calendar) else {
            return Verdict(resource: "storage", sentence: growing, isProblem: isProblem)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // A bare month name reads as the coming one, so the year is added once that could be wrong: past 11
        // months, or a later year's instance of the current month.
        let sameMonthLaterYear =
            calendar.component(.month, from: fill) == calendar.component(.month, from: now)
            && calendar.component(.year, from: fill) > calendar.component(.year, from: now)
        let needsYear = fill > months(11, after: now, calendar) || sameMonthLaterYear
        formatter.dateFormat = needsYear ? "LLLL yyyy" : "LLLL"
        return Verdict(
            resource: "storage", sentence: "\(growing) It fills by \(formatter.string(from: fill)).", isProblem: isProblem)
    }

    /// Bytes of free space lost per day: the least-squares slope over the range, so one large download or
    /// cleanup doesn't swing it the way a first-to-last difference would. Nil under a week of readings, which is
    /// too short to tell a trend from day-to-day churn.
    public static func storageGrowthBytesPerDay(_ dailyFree: [(Date, UInt64)]) -> Double? {
        let points = dailyFree.sorted { $0.0 < $1.0 }
        guard let first = points.first, let last = points.last,
            last.0.timeIntervalSince(first.0) >= minTrendSpan
        else { return nil }
        let xs = points.map { $0.0.timeIntervalSince(first.0) / 86_400 }
        let ys = points.map { Double($0.1) }
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let spread = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        return -zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) } / spread
    }

    /// "Continuously" is only claimed when gaps are under 1% of awake time. Under a day of recording is given
    /// in hours: "1 day" for a two-hour trial, or "2 days" for one evening across midnight, would overstate it.
    public static func coverage(_ c: [DayCoverage]) -> String {
        let recorded = c.reduce(0) { $0 + $1.recorded }
        let awake = c.reduce(0) { $0 + $1.recorded + $1.gap }
        let days = c.filter { $0.recorded > 0 }.count
        guard days > 0, awake > 0 else { return "Nothing has been recorded yet." }
        let share = recorded / awake
        let percent = Wording.percent(share)
        if recorded < 86_400 {
            let hours = recorded / 3600
            // Below 9.95 the one decimal can't round up to "10.0".
            let text = hours < 9.95 ? Wording.decimal(hours, places: 1) : Wording.decimal(hours, places: 0)
            return "Recorded for \(text) \(text == "1" ? "hour" : "hours") (\(percent) of awake time)."
        }
        let how = share >= 0.99 ? "Recorded continuously" : "Recorded"
        return "\(how) for \(Wording.plural(days, "day")) (\(percent) of awake time)."
    }

    private static let noWorkdays = "No workdays recorded yet."

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    private static func months(_ n: Int, after date: Date, _ calendar: Calendar) -> Date {
        calendar.date(byAdding: .month, value: n, to: date) ?? date.addingTimeInterval(Double(n) * 30.44 * 86_400)
    }
}

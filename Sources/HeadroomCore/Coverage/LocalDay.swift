import Foundation

/// A calendar day in the user's time zone, the unit coverage is stored in. Bounds come from the calendar, so
/// daylight-saving days are 23 or 25 hours long.
public struct LocalDay: Sendable, Equatable {
    /// YYYY-MM-DD.
    public let name: String
    public let start: Double
    public let end: Double

    public init(containing ts: Double, calendar: Calendar = .current) {
        let date = Date(timeIntervalSince1970: ts)
        let startDate = calendar.startOfDay(for: date)
        let endDate = calendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate.addingTimeInterval(86_400)
        let parts = calendar.dateComponents([.year, .month, .day], from: startDate)
        name = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        start = startDate.timeIntervalSince1970
        end = endDate.timeIntervalSince1970
    }

    public func previous(calendar: Calendar = .current) -> LocalDay {
        LocalDay(containing: start - 1, calendar: calendar)
    }

    /// The days containing `from` through the day containing `through`, oldest first, keeping at most the
    /// newest `limit`.
    public static func span(from: Double, through: Double, limit: Int, calendar: Calendar = .current) -> [LocalDay] {
        var days = [LocalDay(containing: through, calendar: calendar)]
        while days.count < limit, let earliest = days.first, earliest.start > from {
            days.insert(earliest.previous(calendar: calendar), at: 0)
        }
        return days
    }
}

import Foundation
import HeadroomCore

enum Report {
    private static let defaultDays = 30

    static func run(
        since: Date?, until: Date?, machine: String?, file: String?, paths: Paths, now: Date,
        calendar: Calendar = .current, current: MachineInfo = .current(), out: (String) -> Void, err: (String) -> Void
    ) -> Int32 {
        // There is nothing to report without a database, so unlike `status` this is an error.
        guard FileManager.default.fileExists(atPath: paths.database.path) else {
            err("no data yet — run `headroom install`")
            return 1
        }
        guard let range = range(since: since, until: until, now: now, calendar: calendar) else {
            err("headroom: --since must be on or before --until")
            return 1
        }

        let (config, configWarning) = HeadroomConfig.load(from: paths.config)
        let (tiers, tiersWarning) = Tiers.load(from: paths.tiers)
        let (baseline, baselineWarning) = Baseline.load(from: paths.baseline)
        for warning in [configWarning, tiersWarning, baselineWarning].compactMap({ $0 }) { err("headroom: \(warning)") }

        let model: ReportModel
        do {
            let queries = Queries(db: try Database(path: paths.database.path, readOnly: true))
            let known = try queries.machines()
            guard !known.isEmpty else {
                err("no data yet — run `headroom install`")
                return 1
            }
            let id: String
            if let prefix = machine {
                let matches = known.filter { $0.machineId.hasPrefix(prefix) }
                guard matches.count == 1, let match = matches.first else {
                    err(matches.isEmpty ? "headroom: no machine id starts with \(prefix)" : "headroom: more than one machine id starts with \(prefix)")
                    return 1
                }
                id = match.machineId
            } else if known.contains(where: { $0.machineId == current.machineId }) {
                id = current.machineId
            } else {
                id = try queries.mostRecentMachineId() ?? known[0].machineId
            }
            model = try ReportModel.build(
                queries: queries, machineId: id, from: range.start, to: range.end, config: config, tiers: tiers,
                baseline: baseline, calendar: calendar, now: now, currentMachine: current)
        } catch {
            switch error {
            case let .open(message), let .sqlite(_, message): err("database unreadable: \(message)")
            }
            return 1
        }

        let url = URL(filePath: file ?? defaultFileName(now: now, calendar: calendar))
        do {
            try PDFReport.render(model, to: url)
        } catch {
            switch error {
            case let .cannotCreate(path): err("headroom: could not write \(path)")
            }
            return 1
        }
        out("wrote \(url.path)")
        return 0
    }

    /// `since` and `until` are whole local days and both are included; the end is the midnight after `until`.
    /// Without flags the range is the last 30 days, ending at the end of today.
    static func range(since: Date?, until: Date?, now: Date, calendar: Calendar) -> DateInterval? {
        let lastDay = calendar.startOfDay(for: until ?? now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
        let start = since.map { calendar.startOfDay(for: $0) } ?? calendar.date(byAdding: .day, value: -defaultDays, to: end)
        guard let start, start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func defaultFileName(now: Date, calendar: Calendar) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "headroom-report-%04d-%02d-%02d.pdf", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}

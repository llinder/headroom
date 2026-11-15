import Foundation
import HeadroomCore

enum MCPToolError: Error, Equatable {
    /// Answered as JSON-RPC -32602: the call names nothing this server has.
    case unknownTool(String)
    /// Answered as a tool result with `isError: true`, so the model sees the message and can fix its arguments.
    case invalidArguments(String)
}

enum MCPTime {
    /// 9999-12-31T23:59:59Z. Results outside [epoch, this] are rejected so no caller has to bound them.
    static let latest = 253_402_300_799.0
    private static let maxDigits = 12

    /// ISO 8601 with or without an offset (local time without one), a bare `YYYY-MM-DD` (local midnight), `now`,
    /// or `-Nm`, `-Nh`, `-Nd` before `now`.
    static func parse(_ s: String, now: Double, calendar: Calendar) -> Double? {
        let text = s.trimmingCharacters(in: .whitespaces)
        let value: Double?
        if text == "now" {
            value = now
        } else if text.hasPrefix("-") {
            value = relative(text, now: now)
        } else {
            value = iso(text, calendar: calendar)
        }
        guard let value, value.isFinite, (0...latest).contains(value) else { return nil }
        return value
    }

    private static func relative(_ text: String, now: Double) -> Double? {
        let digits = text.dropFirst().dropLast()
        guard let unit = text.last, (1...maxDigits).contains(digits.count), digits.allSatisfy(\.isASCII),
            digits.allSatisfy(\.isNumber), let count = Double(digits)
        else { return nil }
        switch unit {
        case "m": return now - count * 60
        case "h": return now - count * 3600
        case "d": return now - count * 86_400
        default: return nil
        }
    }

    private static func iso(_ text: String, calendar: Calendar) -> Double? {
        let separator = text.firstIndex { $0 == "T" || $0 == " " }
        let datePart = separator.map { text[..<$0] } ?? Substring(text)
        let dateFields = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard dateFields.count == 3, dateFields[0].count == 4, dateFields[1].count == 2, dateFields[2].count == 2,
            let year = number(dateFields[0]), let month = number(dateFields[1]), let day = number(dateFields[2])
        else { return nil }

        var hour = 0, minute = 0, second = 0.0
        var zone = calendar.timeZone
        if let separator {
            var timePart = text[text.index(after: separator)...]
            if timePart.hasSuffix("Z") {
                zone = TimeZone(secondsFromGMT: 0) ?? zone
                timePart = timePart.dropLast()
            } else if let sign = timePart.lastIndex(where: { $0 == "+" || $0 == "-" }) {
                guard let offset = offsetSeconds(timePart[sign...]), let fixed = TimeZone(secondsFromGMT: offset) else {
                    return nil
                }
                zone = fixed
                timePart = timePart[..<sign]
            }
            let fields = timePart.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 2 || fields.count == 3, fields[0].count == 2, fields[1].count == 2,
                let h = number(fields[0]), let m = number(fields[1])
            else { return nil }
            hour = h
            minute = m
            if fields.count == 3 {
                let secondText = fields[2]
                guard secondText.count >= 2, secondText.prefix(2).allSatisfy(\.isNumber),
                    secondText.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), let value = Double(secondText),
                    value < 60
                else { return nil }
                second = value
            }
        }

        var local = calendar
        local.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = local.date(from: components) else { return nil }
        // `date(from:)` rolls 2027-02-30 over into March and 25:00 into the next day, so the round trip rejects them.
        let back = local.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard back.year == year, back.month == month, back.day == day, back.hour == hour, back.minute == minute else {
            return nil
        }
        return date.timeIntervalSince1970 + second
    }

    private static func number(_ s: Substring) -> Int? {
        s.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(s) : nil
    }

    /// `+HH:MM`, `+HHMM` or `+HH`.
    private static func offsetSeconds(_ s: Substring) -> Int? {
        let sign = s.first == "-" ? -1 : 1
        let digits = s.dropFirst().filter { $0 != ":" }
        guard digits.count == 2 || digits.count == 4, let hours = number(Substring(digits.prefix(2))),
            let minutes = digits.count == 4 ? number(Substring(digits.suffix(2))) : 0, hours < 24, minutes < 60
        else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }
}

enum MCPTools {
    private static let pointCap = 500
    private static let leftoverCap = 50
    private static let autoMinuteRange = 6.0 * 3600
    private static let rawRetention = 30.0 * 86_400
    private static let minuteRetention = 90.0 * 86_400
    private static let sampleInterval = 10.0
    private static let noData = "no data yet — run `headroom install`"

    private static let timeHelp =
        "ISO 8601 (local time when there is no offset), YYYY-MM-DD, now, or relative such as -30m, -2h, -1d; "
        + "between 1970 and 9999"

    static let definitions: JSONValue = .array([
        tool(
            "current_status",
            "What the machine is doing now: live CPU, memory, swap and pressure; today's seconds spent at a limit; "
                + "the busiest workload groups and processes over the last minute; running AI agent sessions; and "
                + "containers left running after their work ended, with cleanup commands.",
            properties: [:], required: []),
        tool(
            "query_metric",
            "A recorded metric as a time series of avg, max and p95 per minute or hour, at most 500 points. "
                + "auto uses minutes for ranges of 6 hours or less. Memory, swap and disk values are bytes; cpuBusy "
                + "is the busy fraction of all cores.",
            properties: [
                "metric": .object([
                    "type": .string("string"), "enum": .array(Metric.allCases.map { .string($0.rawValue) }),
                ]),
                "from": .object(["type": .string("string"), "description": .string(timeHelp)]),
                "to": .object(["type": .string("string"), "description": .string(timeHelp + ". Defaults to now.")]),
                "resolution": .object([
                    "type": .string("string"), "enum": .array(["minute", "hour", "auto"].map { .string($0) }),
                    "default": .string("auto"),
                ]),
            ],
            required: ["metric", "from"]),
        tool(
            "explain_slowdown",
            "Why the machine was slow around a moment: limits hit and for how long, peak memory demand, pressure "
                + "and swap, the three largest workload groups by CPU and memory, top processes (last 30 days only), "
                + "AI agent sessions active, leftover containers, and events. The window is centered on `at`.",
            properties: [
                "at": .object(["type": .string("string"), "description": .string(timeHelp)]),
                "windowMinutes": .object([
                    "type": .string("integer"), "minimum": .int(1), "maximum": .int(1440), "default": .int(30),
                ]),
            ],
            required: ["at"]),
    ])

    private static func tool(
        _ name: String, _ description: String, properties: [String: JSONValue], required: [String]
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object([
            "name": .string(name), "description": .string(description), "inputSchema": .object(schema),
            "annotations": .object(["readOnlyHint": .bool(true), "openWorldHint": .bool(false)]),
        ])
    }

    /// Arguments are checked before the database is opened, so a bad call never depends on stored data.
    static func call(
        name: String, arguments: [String: JSONValue], paths: Paths, now: Double, calendar: Calendar
    ) throws(MCPToolError) -> (text: String, isError: Bool) {
        let clock = Clock(calendar: calendar)
        switch name {
        case "current_status":
            return run(paths) { q, id throws(DatabaseError) in try currentStatus(q, id, paths: paths, now: now, clock: clock) }
        case "query_metric":
            let request = try metricRequest(arguments, now: now, calendar: calendar)
            return run(paths) { q, id throws(DatabaseError) in try queryMetric(q, id, request, clock: clock) }
        case "explain_slowdown":
            guard let atText = arguments["at"]?.stringValue else { throw .invalidArguments("at is required") }
            guard let at = MCPTime.parse(atText, now: now, calendar: calendar) else {
                throw .invalidArguments("at must be \(timeHelp)")
            }
            let minutes = try windowMinutes(arguments["windowMinutes"])
            return run(paths) { q, id throws(DatabaseError) in
                try explainSlowdown(q, id, at: at, minutes: minutes, now: now, clock: clock)
            }
        default:
            throw .unknownTool("unknown tool \(name)")
        }
    }

    // MARK: - Arguments

    private struct MetricRequest {
        var metric: Metric
        var from: Double
        var to: Double
        var resolution: Int64
    }

    private static func metricRequest(
        _ arguments: [String: JSONValue], now: Double, calendar: Calendar
    ) throws(MCPToolError) -> MetricRequest {
        guard let metric = arguments["metric"]?.stringValue.flatMap(Metric.init(rawValue:)) else {
            throw .invalidArguments("metric must be one of \(Metric.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let fromText = arguments["from"]?.stringValue, let from = MCPTime.parse(fromText, now: now, calendar: calendar)
        else { throw .invalidArguments("from must be \(timeHelp)") }
        var to = now
        if let toValue = arguments["to"] {
            guard let text = toValue.stringValue, let parsed = MCPTime.parse(text, now: now, calendar: calendar) else {
                throw .invalidArguments("to must be \(timeHelp)")
            }
            to = parsed
        }
        guard from < to else { throw .invalidArguments("from must be before to") }
        let resolution: Int64
        switch arguments["resolution"].map({ $0.stringValue ?? "" }) ?? "auto" {
        case "minute": resolution = Queries.minuteResolution
        case "hour": resolution = Queries.hourResolution
        case "auto": resolution = to - from <= autoMinuteRange ? Queries.minuteResolution : Queries.hourResolution
        default: throw .invalidArguments("resolution must be minute, hour or auto")
        }
        return MetricRequest(metric: metric, from: from, to: to, resolution: resolution)
    }

    private static func windowMinutes(_ value: JSONValue?) throws(MCPToolError) -> Int {
        guard let value else { return 30 }
        guard let number = value.doubleValue, number == number.rounded(), (1...1440).contains(number) else {
            throw .invalidArguments("windowMinutes must be a whole number from 1 to 1440")
        }
        return Int(number)
    }

    // MARK: - Running

    /// Each call opens the database read-only and drops it on return, so no connection outlives the call.
    private static func run(
        _ paths: Paths, _ body: (Queries, String) throws(DatabaseError) -> (summary: String, json: String)
    ) -> (text: String, isError: Bool) {
        guard FileManager.default.fileExists(atPath: paths.database.path) else { return (noData, true) }
        do {
            let queries = Queries(db: try Database(path: paths.database.path, readOnly: true))
            let known = try queries.machines().map(\.machineId)
            let current = MachineInfo.current().machineId
            let id: String
            if known.contains(current) {
                id = current
            } else if let recent = try queries.mostRecentMachineId() {
                id = recent
            } else {
                return (noData, true)
            }
            let output = try body(queries, id)
            return (output.summary + "\n" + output.json, false)
        } catch {
            switch error {
            case let .open(message), let .sqlite(_, message): return ("database unreadable: \(message)", true)
            }
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // live.state's raw bits can decode to NaN or infinity, which JSON can't hold as numbers.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    private struct Clock {
        let calendar: Calendar
        let formatter = ISO8601DateFormatter()

        init(calendar: Calendar) {
            self.calendar = calendar
            formatter.timeZone = calendar.timeZone
        }

        func iso(_ ts: Double) -> String { formatter.string(from: Date(timeIntervalSince1970: ts)) }
    }

    // MARK: - current_status

    private struct LiveOut: Encodable {
        var asOf: String
        var ageSeconds: Double
        var stale: Bool
        var cpuBusy: Double
        var memUsedBytes: UInt64
        var memTotalBytes: UInt64
        var swapUsedBytes: UInt64
        var swapGrowthBytesPerMin: Int64
        var diskFreeBytes: UInt64
        var diskCapacityBytes: UInt64
        var pressure: String
        var thermal: String
        var limits: [String]
        var activeAgents: UInt16
        var idleAgents: UInt16
    }

    private struct GroupNow: Encodable {
        var group: String
        var cpuCores: Double
        var footprintBytes: UInt64
        var processes: Int
    }

    private struct ProcessesOut: Encodable {
        var byCPU: [ProcessCPU]
        var byMemory: [ProcessMemory]
    }

    private struct ProcessCPU: Encodable {
        var name: String
        var group: String
        var cpuCores: Double
    }

    private struct ProcessMemory: Encodable {
        var name: String
        var group: String
        var bytes: UInt64
    }

    private struct LiveRun: Encodable {
        var tool: String
        var ageSeconds: Double
        var cpuCores: Double
        var footprintBytes: UInt64
        var active: Bool
        var lastUsage: String?
    }

    private struct LeftoverOut: Encodable {
        var name: String
        var kind: String
        var engine: String
        var reason: String
        var memoryBytes: UInt64?
        var runningSeconds: Double
        var cleanup: [String]
    }

    private struct LeftoversNow: Encodable {
        var count: Int
        var totalBytes: UInt64
        var items: [LeftoverOut]
    }

    private struct StatusOut: Encodable {
        var live: LiveOut?
        var todayLimitSeconds: [String: Double]
        var groupsAsOf: String?
        var topGroups: [GroupNow]
        var topProcesses: ProcessesOut
        var agentRuns: [LiveRun]
        var leftovers: LeftoversNow
    }

    private static func currentStatus(
        _ q: Queries, _ id: String, paths: Paths, now: Double, clock: Clock
    ) throws(DatabaseError) -> (summary: String, json: String) {
        let snapshot = LiveStateReader.read(url: paths.liveState)
        let live = snapshot.map { s in
            LiveOut(
                asOf: clock.iso(s.timestamp), ageSeconds: (now - s.timestamp).rounded(),
                stale: !(now - s.timestamp <= StatusLineFormatter.staleAfter), cpuBusy: rounded(Double(s.cpuBusy), 3),
                memUsedBytes: s.memUsed, memTotalBytes: s.memTotal, swapUsedBytes: s.swapUsed,
                swapGrowthBytesPerMin: s.swapGrowthBytesPerMin, diskFreeBytes: s.diskFree,
                diskCapacityBytes: s.diskCapacity, pressure: pressureName(Int(s.pressure)),
                thermal: thermalName(Int(s.thermal)), limits: limitNames(LimitFlags(rawValue: s.limitFlags)),
                activeAgents: s.activeAgents, idleAgents: s.idleAgents)
        }

        let today = try q.todayLimitSeconds(machineId: id, now: Date(timeIntervalSince1970: now), calendar: clock.calendar)
        var groups: [GroupNow] = []
        let latest = try q.latestGroupSample(machineId: id)
        if let latest {
            // The last minute is the six 10 s ticks ending at the newest one.
            let totals = try q.groupTotals(
                machineId: id, from: Date(timeIntervalSince1970: latest - 59), to: Date(timeIntervalSince1970: latest + 1))
            groups = totals.sorted { ($0.value.cpuSeconds, $1.key.rawValue) > ($1.value.cpuSeconds, $0.key.rawValue) }
                .map {
                    GroupNow(
                        group: $0.key.rawValue, cpuCores: rounded($0.value.cpuSeconds / 60, 2),
                        footprintBytes: $0.value.footprint, processes: $0.value.procCount)
                }
        }
        let processes = split(try q.latestTopProcesses(machineId: id), limit: 5)
        let runs = try q.openAgentRuns(machineId: id, limit: 50).map { r in
            LiveRun(
                tool: r.tool, ageSeconds: max(0, now - r.started), cpuCores: rounded(r.cpuSeconds / 60, 2),
                footprintBytes: r.peakFootprint, active: r.activeSeconds > 0, lastUsage: r.lastUsage.map(clock.iso))
        }

        let sidecar = LeftoverState.load(from: paths.leftovers)
        let leftovers = LeftoversNow(
            count: sidecar.items.count, totalBytes: sidecar.totalBytes,
            items: sidecar.items.prefix(leftoverCap).map { f in
                LeftoverOut(
                    name: f.item.name, kind: f.item.kind.rawValue, engine: f.item.engine, reason: f.reason,
                    memoryBytes: f.memoryBytes, runningSeconds: max(0, now - f.startedAt).rounded(), cleanup: f.item.cleanup)
            })

        let out = StatusOut(
            live: live, todayLimitSeconds: nonZero(today), groupsAsOf: latest.map(clock.iso), topGroups: groups,
            topProcesses: processes, agentRuns: runs, leftovers: leftovers)

        var summary: String
        if let s = snapshot, let l = live, !l.stale {
            let memPercent = s.memTotal == 0 ? 0 : Double(s.memUsed) / Double(s.memTotal) * 100
            let cpuPercent = TopRenderer.clampedInt((l.cpuBusy * 100).rounded(), upTo: 100)
            summary = "mem \(TopRenderer.clampedInt(memPercent.rounded()))% · swap \(gigabytes(Double(s.swapUsed))) GB"
            summary += " · cpu \(cpuPercent)%"
            summary += " · pressure \(l.pressure) · \(runs.count) agent\(runs.count == 1 ? "" : "s") running"
        } else if let l = live {
            summary = "recorder not running: live state is \(TopRenderer.clampedInt(l.ageSeconds))s old"
        } else {
            summary = "recorder not running: no live state"
        }
        if leftovers.count > 0 {
            let plural = leftovers.count == 1 ? "" : "s"
            summary += " · \(leftovers.count) leftover\(plural)"
            // Memory not read yet is zero, and "(0.0 GB)" would claim the containers hold nothing.
            let held = gigabytes(Double(leftovers.totalBytes))
            if held != "0.0" { summary += " (\(held) GB)" }
        }
        return (summary, encode(out))
    }

    // MARK: - query_metric

    private struct PointOut: Encodable {
        var t: String
        var avg: Double
        var max: Double
        var p95: Double
    }

    private struct SeriesOut: Encodable {
        var metric: String
        var unit: String
        var resolution: String
        var from: String
        var to: String
        var points: [PointOut]
        var truncated: Bool
        var next: String?
    }

    private static func queryMetric(
        _ q: Queries, _ id: String, _ r: MetricRequest, clock: Clock
    ) throws(DatabaseError) -> (summary: String, json: String) {
        let rows = try q.metricSeries(
            machineId: id, metric: r.metric, resolution: r.resolution, from: r.from, to: r.to, limit: pointCap + 1)
        let truncated = rows.count > pointCap
        let kept = rows.prefix(pointCap)
        let next = truncated ? kept.last.map { clock.iso($0.ts + Double(r.resolution)) } : nil
        let resolution = r.resolution == Queries.minuteResolution ? "minute" : "hour"
        let out = SeriesOut(
            metric: r.metric.rawValue, unit: unit(r.metric), resolution: resolution, from: clock.iso(r.from),
            to: clock.iso(r.to), points: kept.map { PointOut(t: clock.iso($0.ts), avg: $0.avg, max: $0.max, p95: $0.p95) },
            truncated: truncated, next: next)

        var summary = "\(r.metric.rawValue) · \(kept.count) \(resolution) points from \(out.from) to \(out.to)"
        if let peak = kept.map(\.max).max() { summary += " · max \(trimmed(peak)) \(unit(r.metric))" }
        if let next { summary += " · truncated at \(pointCap) points; continue from \(next)" }
        if kept.isEmpty { summary += " · no data for that range" }
        return (summary, encode(out))
    }

    // MARK: - explain_slowdown

    private struct Peaks: Encodable {
        var memDemandBytes: Double?
        var swapBytes: Double?
        var pressure: String?
    }

    private struct GroupWindow: Encodable {
        var group: String
        var cpuSeconds: Double
        var peakFootprintBytes: UInt64
    }

    private struct GroupsOut: Encodable {
        var byCPU: [GroupWindow]
        var byMemory: [GroupWindow]
    }

    private struct RunWindow: Encodable {
        var tool: String
        var started: String
        var ended: String?
        var cpuSeconds: Double
        var peakFootprintBytes: UInt64
        var activeSeconds: Double
    }

    private struct LeftoversThen: Encodable {
        var count: Int
        var bytes: UInt64
        var peakBytesInWindow: UInt64?
    }

    private struct EventOut: Encodable {
        var t: String
        var kind: String
        var payload: JSONValue
    }

    private struct ExplainOut: Encodable {
        var at: String
        var from: String
        var to: String
        var resolution: String
        var limitSeconds: [String: Double]
        var peaks: Peaks
        var topGroups: GroupsOut
        var rawDataKept: Bool
        var topProcesses: ProcessesOut?
        var agentRuns: [RunWindow]
        var leftovers: LeftoversThen
        var events: [EventOut]
    }

    private static func explainSlowdown(
        _ q: Queries, _ id: String, at: Double, minutes: Int, now: Double, clock: Clock
    ) throws(DatabaseError) -> (summary: String, json: String) {
        let half = Double(minutes) * 30
        let from = at - half
        let to = at + half
        // Minute rollups are kept 90 days; older windows fall back to the hours that overlap them.
        let minuteKept = from >= now - minuteRetention
        let resolution = minuteKept ? Queries.minuteResolution : Queries.hourResolution
        let rollupFrom = minuteKept ? from : from - from.truncatingRemainder(dividingBy: 3600)

        let limits = nonZero(try q.limitSeconds(machineId: id, resolution: resolution, from: rollupFrom, to: to))
        let peaks = Peaks(
            memDemandBytes: try q.metricPeak(machineId: id, metric: .memDemand, resolution: resolution, from: rollupFrom, to: to),
            swapBytes: try q.metricPeak(machineId: id, metric: .swapUsed, resolution: resolution, from: rollupFrom, to: to),
            pressure: try q.maxPressure(machineId: id, from: from, to: to).map(pressureName))

        let totals = try q.groupTotals(
            machineId: id, from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to))
        let windows = totals.map {
            GroupWindow(group: $0.key.rawValue, cpuSeconds: $0.value.cpuSeconds, peakFootprintBytes: $0.value.footprint)
        }
        let groups = GroupsOut(
            byCPU: Array(windows.sorted { ($0.cpuSeconds, $1.group) > ($1.cpuSeconds, $0.group) }.prefix(3)),
            byMemory: Array(windows.sorted { ($0.peakFootprintBytes, $1.group) > ($1.peakFootprintBytes, $0.group) }.prefix(3)))

        let rawKept = from >= now - rawRetention
        let processes = rawKept ? split(try q.topProcesses(machineId: id, from: from, to: to), limit: 5) : nil

        let runs = try q.agentRunActivity(machineId: id, from: from, to: to, limit: 20).map { r in
            RunWindow(
                tool: r.tool, started: clock.iso(r.started), ended: r.ended.map(clock.iso), cpuSeconds: r.cpuSeconds,
                peakFootprintBytes: r.peakFootprint, activeSeconds: r.activeSeconds)
        }

        let state = try q.leftoversBefore(machineId: id, before: to)
        let leftovers = LeftoversThen(
            count: state.count, bytes: state.bytes,
            peakBytesInWindow: try q.leftoverPeakBytes(
                machineId: id, from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to)))

        let events = try q.events(machineId: id, from: from, to: to, limit: pointCap).map { e in
            EventOut(
                t: clock.iso(e.ts), kind: e.kind,
                payload: (try? JSONDecoder().decode(JSONValue.self, from: Data(e.payload.utf8))) ?? .string(e.payload))
        }

        let out = ExplainOut(
            at: clock.iso(at), from: clock.iso(from), to: clock.iso(to), resolution: minuteKept ? "minute" : "hour",
            limitSeconds: limits, peaks: peaks, topGroups: groups, rawDataKept: rawKept, topProcesses: processes,
            agentRuns: runs, leftovers: leftovers, events: events)

        var parts = ["\(out.at) ±\(trimmed(Double(minutes) / 2)) min"]
        if limits.isEmpty {
            parts.append("no limits hit")
        } else {
            let ranked = limits.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            parts.append("limits: " + ranked.map { "\($0.key) \(TopRenderer.clampedInt($0.value))s" }.joined(separator: ", "))
        }
        if let demand = peaks.memDemandBytes { parts.append("peak memory demand \(gigabytes(demand)) GB") }
        if let pressure = peaks.pressure { parts.append("pressure \(pressure)") }
        if let busiest = groups.byCPU.first { parts.append("most CPU \(busiest.group)") }
        if let largest = groups.byMemory.first { parts.append("most memory \(largest.group)") }
        if !runs.isEmpty { parts.append("\(runs.count) agent session\(runs.count == 1 ? "" : "s")") }
        if state.count > 0 { parts.append("\(state.count) leftover\(state.count == 1 ? "" : "s")") }
        return (parts.joined(separator: " · "), encode(out))
    }

    // MARK: - Helpers

    private static func split(_ rows: [TopProcess], limit: Int) -> ProcessesOut {
        // A cpu row's value is CPU seconds in its peak 10 s tick, so dividing by the tick gives cores busy.
        ProcessesOut(
            byCPU: rows.filter { $0.kind == "cpu" }.prefix(limit).map {
                ProcessCPU(name: $0.name, group: $0.group, cpuCores: rounded($0.value / sampleInterval, 2))
            },
            byMemory: rows.filter { $0.kind == "memory" }.prefix(limit).map {
                ProcessMemory(name: $0.name, group: $0.group, bytes: TopRenderer.clampedUInt64($0.value))
            })
    }

    private static func nonZero(_ seconds: [LimitKind: Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: seconds.filter { $0.value > 0 }.map { ($0.key.rawValue, $0.value) })
    }

    private static func limitNames(_ flags: LimitFlags) -> [String] {
        LimitKind.allCases.filter { kind in
            switch kind {
            case .memoryLimited: flags.contains(.memoryLimited)
            case .heavySwap: flags.contains(.heavySwap)
            case .cpuSaturated: flags.contains(.cpuSaturated)
            case .thermalLimited: flags.contains(.thermalLimited)
            }
        }.map(\.rawValue)
    }

    private static func pressureName(_ level: Int) -> String {
        switch PressureLevel(rawValue: level) {
        case .normal?: "normal"
        case .warn?: "warn"
        case .critical?: "critical"
        case nil: "unknown"
        }
    }

    private static func thermalName(_ level: Int) -> String {
        switch ThermalLevel(rawValue: level) {
        case .nominal?: "nominal"
        case .fair?: "fair"
        case .serious?: "serious"
        case .critical?: "critical"
        case nil: "unknown"
        }
    }

    private static func unit(_ metric: Metric) -> String {
        switch metric {
        case .cpuBusy: "fraction of all cores"
        case .load1: "load average"
        case .memUsed, .memApp, .memCompressed, .swapUsed, .memDemand, .diskFree: "bytes"
        case .ssdWrite: "bytes per 10 s sample"
        case .activeAgents: "sessions"
        }
    }

    private static func rounded(_ value: Double, _ digits: Int) -> Double {
        let scale = pow(10, Double(digits))
        return (value * scale).rounded() / scale
    }

    private static func gigabytes(_ bytes: Double) -> String {
        (bytes / 1e9).formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(1)).grouping(.never))
    }

    private static func trimmed(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...3)).grouping(.never))
    }
}

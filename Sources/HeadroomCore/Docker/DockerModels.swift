import Foundation

public struct DockerContainer: Decodable, Sendable, Equatable {
    public let id: String
    public let names: [String]
    public let image: String
    public let labels: [String: String]
    public let state: String

    private enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", labels = "Labels", state = "State"
    }

    public init(id: String, names: [String], image: String, labels: [String: String], state: String) {
        self.id = id
        self.names = names
        self.image = image
        self.labels = labels
        self.state = state
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        names = (try c.decodeIfPresent([String].self, forKey: .names) ?? []).map {
            $0.hasPrefix("/") ? String($0.dropFirst()) : $0
        }
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
    }

    public static func decodeList(_ data: Data) throws -> [DockerContainer] {
        try JSONDecoder().decode([DockerContainer].self, from: data)
    }
}

public struct ContainerDetail: Sendable, Equatable {
    /// Unix epoch seconds.
    public let startedAt: Double

    private struct Inspect: Decodable {
        struct State: Decodable { let StartedAt: String? }
        let State: State?
    }

    /// Returns nil for malformed JSON, an unparseable timestamp, or Docker's zero time.
    public static func parse(inspectJSON: Data) -> ContainerDetail? {
        guard let inspect = try? JSONDecoder().decode(Inspect.self, from: inspectJSON),
              let raw = inspect.State?.StartedAt,
              let seconds = parseRFC3339(raw), seconds > 0
        else { return nil }
        return ContainerDetail(startedAt: seconds)
    }

    // ISO8601DateFormatter rejects more than 3 fractional digits, and Docker emits 9.
    static func parseRFC3339(_ s: String) -> Double? {
        var base = s
        var fraction = 0.0
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end] >= "0", s[end] <= "9" { end = s.index(after: end) }
            let digits = s[s.index(after: dot)..<end]
            guard !digits.isEmpty, let f = Double("0." + digits) else { return nil }
            fraction = f
            base = String(s[..<dot]) + String(s[end...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: base) else { return nil }
        return max(0, date.timeIntervalSince1970 + fraction)
    }

    private struct Stats: Decodable {
        struct Memory: Decodable {
            struct Detail: Decodable {
                let inactive_file: UInt64?
                let total_inactive_file: UInt64?
            }
            let usage: UInt64?
            let stats: Detail?
        }
        let memory_stats: Memory?
    }

    /// Mirrors `docker stats`: usage minus reclaimable page cache (cgroup v2 `inactive_file`,
    /// cgroup v1 `total_inactive_file`).
    public static func memoryEstimate(statsJSON: Data) -> UInt64? {
        guard let mem = (try? JSONDecoder().decode(Stats.self, from: statsJSON))?.memory_stats,
              let usage = mem.usage
        else { return nil }
        let inactive = mem.stats?.inactive_file ?? mem.stats?.total_inactive_file ?? 0
        return usage > inactive ? usage - inactive : 0
    }
}

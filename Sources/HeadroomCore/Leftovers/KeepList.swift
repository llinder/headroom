import Foundation

public struct KeepEntry: Codable, Sendable, Equatable {
    public var name: String
    /// Unix epoch seconds; nil keeps forever.
    public var until: Double?

    public init(name: String, until: Double? = nil) {
        self.name = name
        self.until = until
    }
}

public struct KeepList: Codable, Sendable, Equatable {
    public var entries: [KeepEntry]
    /// Entries that could not be read at load time; not encoded. Callers must not save over a file with skipped entries.
    public private(set) var skipped = 0

    private enum CodingKeys: String, CodingKey { case entries }

    public init(entries: [KeepEntry] = []) {
        self.entries = entries
    }

    private struct LossyEntry: Decodable {
        let entry: KeepEntry?
        init(from decoder: any Decoder) throws {
            entry = try? KeepEntry(from: decoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lossy = try c.decodeIfPresent([LossyEntry].self, forKey: .entries) ?? []
        entries = lossy.compactMap(\.entry)
        skipped = lossy.count - entries.count
    }

    public static func load(from url: URL) -> (KeepList, warning: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (KeepList(), nil) }
        do {
            let list = try JSONDecoder().decode(KeepList.self, from: Data(contentsOf: url))
            guard list.skipped > 0 else { return (list, nil) }
            let phrase = list.skipped == 1 ? "1 entry could not be read and was ignored"
                : "\(list.skipped) entries could not be read and were ignored"
            return (list, "\(url.lastPathComponent): \(phrase)")
        } catch {
            return (KeepList(), "ignoring \(url.path): \(error.localizedDescription)")
        }
    }

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    public func covers(_ item: LeftoverItem, now: Double) -> Bool {
        let byName: Set<String>
        switch item.kind {
        case .kind: byName = ["kind:\(item.name)"]
        case .compose: byName = ["compose:\(item.name)"]
        case .testcontainers, .container: byName = Set(item.containerNames + [item.name])
        }
        let prefix = "\(item.engine)/"
        let idMatchable = item.kind == .testcontainers || item.kind == .container
        return entries.contains { entry in
            if let until = entry.until, until <= now { return false }
            let bare = entry.name.hasPrefix(prefix) ? String(entry.name.dropFirst(prefix.count)) : entry.name
            if byName.contains(bare) { return true }
            return idMatchable && bare.count >= 12 && item.containerIDs.contains { $0.hasPrefix(bare) }
        }
    }
}

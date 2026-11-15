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

    public init(entries: [KeepEntry] = []) {
        self.entries = entries
    }

    public static func load(from url: URL) -> (KeepList, warning: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (KeepList(), nil) }
        do {
            return (try JSONDecoder().decode(KeepList.self, from: Data(contentsOf: url)), nil)
        } catch {
            return (KeepList(), "ignoring \(url.path): \(error.localizedDescription)")
        }
    }

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).tmp")
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
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

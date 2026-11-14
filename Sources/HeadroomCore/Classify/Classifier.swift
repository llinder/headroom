import Foundation

public struct Classifier: Sendable {
    private struct Matcher: Sendable {
        let group: WorkloadGroup
        let names: [String]
        let pathPrefixes: [String]
    }

    private let matchers: [Matcher]
    private let currentUID: UInt32

    /// `~/` is expanded here, once, rather than on every match.
    public init(rules: GroupRules, currentUID: UInt32) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.matchers = rules.rules.map { rule in
            Matcher(
                group: rule.group,
                names: rule.names,
                pathPrefixes: rule.pathPrefixes.map { $0.hasPrefix("~/") ? home + String($0.dropFirst()) : $0 })
        }
        self.currentUID = currentUID
    }

    public func ownGroup(_ p: ProcessIdentity) -> WorkloadGroup? {
        for m in matchers {
            if m.names.contains(where: { Self.globMatches($0, p.name) })
                || m.pathPrefixes.contains(where: { p.path.hasPrefix($0) })
            {
                return m.group
            }
        }
        return nil
    }

    public func classify(_ procs: [ProcessIdentity]) -> [ProcessKey: WorkloadGroup] {
        var byPid: [Int32: ProcessIdentity] = [:]
        for p in procs { byPid[p.key.pid] = p }
        var resolved: [ProcessKey: WorkloadGroup] = [:]
        resolved.reserveCapacity(procs.count)

        for p in procs where resolved[p.key] == nil {
            var chain: [ProcessIdentity] = []
            var visited: Set<Int32> = []
            var cursor: ProcessIdentity? = p
            var inherited: WorkloadGroup?
            while let node = cursor, visited.insert(node.key.pid).inserted {
                if let known = resolved[node.key] ?? ownGroup(node) {
                    resolved[node.key] = known
                    inherited = known
                    break
                }
                chain.append(node)
                cursor = byPid[node.ppid]
            }
            // With no classified ancestor, each process falls back on its own uid, not the chain's.
            for node in chain {
                resolved[node.key] = inherited ?? (node.uid != currentUID ? .system : .other)
            }
        }
        return resolved
    }

    /// `*` is honoured only as a full prefix, a full suffix, or both; anything else is literal.
    static func globMatches(_ pattern: String, _ name: String) -> Bool {
        let starts = pattern.hasPrefix("*")
        let ends = pattern.count > 1 && pattern.hasSuffix("*")
        switch (starts, ends) {
        case (true, true): return name.contains(pattern.dropFirst().dropLast())
        case (true, false): return name.hasSuffix(pattern.dropFirst())
        case (false, true): return name.hasPrefix(pattern.dropLast())
        case (false, false): return name == pattern
        }
    }
}

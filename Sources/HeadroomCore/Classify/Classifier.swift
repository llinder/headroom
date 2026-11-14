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
        // proc_name truncates to 31 characters, so the executable's basename is the reliable name.
        let name = p.path.isEmpty ? p.name : String(p.path.split(separator: "/", omittingEmptySubsequences: true).last ?? Substring(p.name))
        for m in matchers {
            if m.names.contains(where: { Self.globMatches($0, name) })
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
        // Only rule-derived groups are memoized. The uid fallback applies to a process's own uid and must
        // never be inherited by descendants, or results would depend on input order.
        var classified: [ProcessKey: WorkloadGroup] = [:]
        var unclassified: Set<ProcessKey> = []

        for p in procs where classified[p.key] == nil && !unclassified.contains(p.key) {
            var chain: [ProcessIdentity] = []
            var visited: Set<Int32> = []
            var cursor: ProcessIdentity? = p
            var inherited: WorkloadGroup?
            while let node = cursor, visited.insert(node.key.pid).inserted {
                if unclassified.contains(node.key) { break }
                if let known = classified[node.key] ?? ownGroup(node) {
                    inherited = known
                    classified[node.key] = known
                    break
                }
                chain.append(node)
                cursor = byPid[node.ppid]
            }
            for node in chain {
                if let inherited {
                    classified[node.key] = inherited
                } else {
                    unclassified.insert(node.key)
                }
            }
        }

        var result: [ProcessKey: WorkloadGroup] = [:]
        result.reserveCapacity(procs.count)
        for p in procs {
            result[p.key] = classified[p.key] ?? (p.uid != currentUID ? .system : .other)
        }
        return result
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

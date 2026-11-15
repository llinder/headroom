import Foundation

public enum LeftoverKind: String, Codable, Sendable {
    case kind, compose, testcontainers, container
}

public enum Lifetime: Codable, Sendable, Equatable {
    case keep
    case temporary
    case duration(Double)

    public static let labelKey = "io.github.llinder.headroom.lifetime"

    /// Accepts `keep`, `temporary` and `<positive int><m|h|d>`; anything else (including `0h`) is nil.
    public init?(label: String) {
        switch label {
        case "keep": self = .keep
        case "temporary": self = .temporary
        default:
            let digits = label.dropLast()
            // Int("+5") parses, so require plain ASCII digits.
            guard let unit = label.last, !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let n = Int(digits), n > 0 else { return nil }
            switch unit {
            case "m": self = .duration(Double(n) * 60)
            case "h": self = .duration(Double(n) * 3600)
            case "d": self = .duration(Double(n) * 86400)
            default: return nil
            }
        }
    }

    /// `temporary` counts as zero; `keep` has no finite length.
    var seconds: Double {
        switch self {
        case .keep: return .infinity
        case .temporary: return 0
        case .duration(let s): return s
        }
    }
}

public struct LeftoverItem: Codable, Sendable, Equatable {
    public var key: String
    public var engine: String
    public var kind: LeftoverKind
    public var name: String
    public var containerIDs: [String]
    /// Every container name in the item, so the keep list can match single and Testcontainers items by name.
    public var containerNames: [String]
    public var sessionId: String?
    public var lifetime: Lifetime?
    public var cleanup: [String]

    public init(
        key: String, engine: String, kind: LeftoverKind, name: String, containerIDs: [String],
        sessionId: String?, lifetime: Lifetime?, cleanup: [String], containerNames: [String] = []
    ) {
        self.key = key
        self.engine = engine
        self.kind = kind
        self.name = name
        self.containerIDs = containerIDs
        self.containerNames = containerNames
        self.sessionId = sessionId
        self.lifetime = lifetime
        self.cleanup = cleanup
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        engine = try c.decode(String.self, forKey: .engine)
        kind = try c.decode(LeftoverKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        containerIDs = try c.decode([String].self, forKey: .containerIDs)
        containerNames = try c.decodeIfPresent([String].self, forKey: .containerNames) ?? []
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        lifetime = try c.decodeIfPresent(Lifetime.self, forKey: .lifetime)
        cleanup = try c.decode([String].self, forKey: .cleanup)
    }
}

public enum LeftoverGrouper {
    private static let kindLabel = "io.x-k8s.kind.cluster"
    private static let composeLabel = "com.docker.compose.project"
    private static let tcLabel = "org.testcontainers"
    private static let tcSessionLabel = "org.testcontainers.sessionId"

    private static let builtIn = IgnoreRules(
        names: ["buildx_buildkit*", "testcontainers-ryuk*", "reaper_*", "kind-registry"],
        images: [
            "moby/buildkit*", "*/moby/buildkit*", "registry:*", "*/registry:*",
            "testcontainers/ryuk*", "*/testcontainers/ryuk*",
        ],
        labels: ["io.kubernetes.pod.name", "org.testcontainers.reuse.enable=true"]
    )

    private struct Bucket {
        let kind: LeftoverKind
        let name: String
        let session: String?
        var members: [DockerContainer] = []
    }

    public static func group(
        _ containers: [DockerContainer], engine: String, ignore: IgnoreRules
    ) -> (items: [LeftoverItem], reapers: Set<String>) {
        var reapers = Set<String>()
        var order: [String] = []
        var buckets: [String: Bucket] = [:]

        for c in containers where c.state == "running" {
            if c.names.contains(where: { $0.hasPrefix("testcontainers-ryuk") || $0.hasPrefix("reaper_") }),
               let session = c.labels[tcSessionLabel] {
                reapers.insert(session)
            }
            if ignored(c, builtIn) || ignored(c, ignore) { continue }

            let bucket: Bucket
            if let cluster = c.labels[kindLabel] {
                bucket = Bucket(kind: .kind, name: cluster, session: nil)
            } else if let project = c.labels[composeLabel] {
                bucket = Bucket(kind: .compose, name: project, session: nil)
            } else if c.labels[tcLabel] == "true", let s = c.labels[tcSessionLabel] {
                bucket = Bucket(kind: .testcontainers, name: s, session: s)
            } else {
                bucket = Bucket(kind: .container, name: c.names.first ?? c.id, session: nil)
            }
            let identity = bucket.kind == .container ? c.id : bucket.name
            let key = "\(engine)/\(bucket.kind.rawValue)/\(identity)"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = bucket
            }
            buckets[key]?.members.append(c)
        }

        let items = order.compactMap { key -> LeftoverItem? in
            guard let b = buckets[key] else { return nil }
            return LeftoverItem(
                key: key, engine: engine, kind: b.kind, name: b.name,
                containerIDs: b.members.map(\.id), sessionId: b.session,
                lifetime: lifetime(of: b.members),
                cleanup: cleanup(kind: b.kind, name: b.name, engine: engine, members: b.members),
                containerNames: b.members.flatMap(\.names))
        }
        return (items, reapers)
    }

    private static func ignored(_ c: DockerContainer, _ rules: IgnoreRules) -> Bool {
        if c.names.contains(where: { n in rules.names.contains { Classifier.globMatches($0, n) } }) { return true }
        if rules.images.contains(where: { Classifier.globMatches($0, c.image) }) { return true }
        return rules.labels.contains { rule in
            if let eq = rule.firstIndex(of: "=") {
                return c.labels[String(rule[..<eq])] == String(rule[rule.index(after: eq)...])
            }
            return c.labels[rule] != nil
        }
    }

    private static func lifetime(of members: [DockerContainer]) -> Lifetime? {
        let all = members.compactMap { $0.labels[Lifetime.labelKey].flatMap(Lifetime.init(label:)) }
        if all.contains(.keep) { return .keep }
        return all.min { $0.seconds < $1.seconds }
    }

    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func cleanup(
        kind: LeftoverKind, name: String, engine: String, members: [DockerContainer]
    ) -> [String] {
        let ctx = quote(engine)
        switch kind {
        case .kind:
            let nodes = members.map { quote($0.names.first ?? $0.id) }.joined(separator: " ")
            return [
                "docker --context \(ctx) stop \(nodes)",
                "DOCKER_CONTEXT=\(ctx) kind delete cluster --name \(quote(name))",
            ]
        case .compose:
            return ["docker --context \(ctx) compose -p \(quote(name)) down"]
        case .testcontainers, .container:
            return ["docker --context \(ctx) rm -f \(members.map { quote($0.id) }.joined(separator: " "))"]
        }
    }
}

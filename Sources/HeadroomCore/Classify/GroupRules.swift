import Foundation

public enum WorkloadGroup: String, Codable, CaseIterable, Sendable {
    case containers
    case goBuilds = "go"
    case agents
    case ide
    case browsers
    case communication
    case system
    case other

    public var displayName: String {
        switch self {
        case .containers: "Containers & Kind"
        case .goBuilds: "Go builds & tests"
        case .agents: "AI agents"
        case .ide: "IDE & editors"
        case .browsers: "Browsers"
        case .communication: "Communication"
        case .system: "macOS system"
        case .other: "Other"
        }
    }

    public var reportGroup: ReportGroup {
        switch self {
        case .containers: .containers
        case .goBuilds: .goBuilds
        case .agents: .agents
        case .ide: .ide
        case .browsers, .communication, .other: .everydayApps
        case .system: .system
        }
    }
}

public enum ReportGroup: String, CaseIterable, Sendable {
    case containers, goBuilds, agents, ide, everydayApps, system

    public var displayName: String {
        switch self {
        case .containers: "Containers & Kind"
        case .goBuilds: "Go builds & tests"
        case .agents: "AI agents"
        case .ide: "IDE & editors"
        case .everydayApps: "Everyday apps"
        case .system: "macOS system"
        }
    }
}

public struct GroupRule: Codable, Sendable, Equatable {
    public var group: WorkloadGroup
    public var names: [String]
    public var pathPrefixes: [String]

    public init(group: WorkloadGroup, names: [String] = [], pathPrefixes: [String] = []) {
        self.group = group
        self.names = names
        self.pathPrefixes = pathPrefixes
    }
}

public struct GroupRules: Codable, Sendable, Equatable {
    public var rules: [GroupRule]

    public init(rules: [GroupRule]) {
        self.rules = rules
    }

    public static let defaults = GroupRules(rules: [
        GroupRule(group: .containers, names: [
            "com.apple.Virtualization.VirtualMachine", "vfkit", "qemu-*", "com.docker.*",
            "Docker Desktop*", "colima", "limactl", "OrbStack*",
        ]),
        GroupRule(group: .goBuilds, names: [
            "go", "compile", "link", "asm", "cgo", "vet", "*.test", "golangci-lint", "gopls",
        ]),
        GroupRule(
            group: .agents,
            names: ["claude", "codex"],
            pathPrefixes: [
                "~/.claude/", "~/.local/share/claude/",
                "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code",
                "/opt/homebrew/lib/node_modules/@openai/codex",
            ]),
        GroupRule(
            group: .ide,
            names: ["goland", "idea", "Code Helper*", "zed", "Xcode"],
            pathPrefixes: ["/Applications/Visual Studio Code.app/"]),
        GroupRule(group: .browsers, names: [
            "Google Chrome*", "Arc*", "Safari", "com.apple.WebKit.*", "firefox", "plugin-container",
        ]),
        GroupRule(group: .communication, names: ["Slack*", "zoom.us", "Microsoft Teams*"]),
    ])

    /// The file holds only the user's own rules, matched before the defaults, so a future release's new
    /// defaults still apply. It is never written: a missing file means defaults only, and an invalid one is
    /// left untouched, because overwriting it would destroy the user's edits.
    public static func effective(from url: URL) -> (GroupRules, warning: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (defaults, nil) }
        do {
            let overrides = try JSONDecoder().decode(GroupRules.self, from: Data(contentsOf: url))
            return (GroupRules(rules: overrides.rules + defaults.rules), nil)
        } catch {
            return (defaults, "ignoring \(url.path): \(error.localizedDescription)")
        }
    }
}

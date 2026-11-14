import Foundation
import Testing

@testable import HeadroomCLI
@testable import HeadroomCore

private let ours = "/Users/x/.local/bin/headroom agent-hook claude"

private let existing = """
    {"statusLine":{"type":"command","command":"bash sl.sh"},"permissions":{"allow":["Bash"]},
     "hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash herdr-agent-state.sh session"}]}]}}
    """

private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func commands(_ data: Data) throws -> [String] {
    let hooks = try #require(try object(data)["hooks"] as? [String: Any])
    let groups = try #require(hooks["SessionStart"] as? [[String: Any]])
    return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

@Suite struct HookConfigTests {
    @Test func plistKeys() throws {
        let data = LaunchAgent.plist(binary: "/opt/headroomd")
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "io.github.llinder.headroom")
        #expect(plist["ProgramArguments"] as? [String] == ["/opt/headroomd"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["ProcessType"] as? String == "Background")
        #expect(plist["LowPriorityIO"] as? Bool == true)
        #expect(plist["StandardOutPath"] as? String == "/dev/null")
        #expect(plist["StandardErrorPath"] as? String == "/dev/null")
    }

    @Test func mergePreservesExisting() throws {
        let out = try HookConfig.merged(Data(existing.utf8), command: ours)
        let root = try object(out)
        #expect(root["statusLine"] != nil)
        #expect(root["permissions"] != nil)
        #expect(try commands(out) == ["bash herdr-agent-state.sh session", ours])
    }

    @Test func mergeIdempotent() throws {
        let once = try HookConfig.merged(Data(existing.utf8), command: ours)
        let twice = try HookConfig.merged(once, command: ours)
        #expect(try commands(twice).filter { $0.contains("headroom agent-hook") }.count == 1)
        #expect(once == twice)
        #expect(HookConfig.contains(twice))
    }

    @Test func removeOnlyOurs() throws {
        let merged = try HookConfig.merged(Data(existing.utf8), command: ours)
        let out = try HookConfig.removed(merged)
        #expect(try commands(out) == ["bash herdr-agent-state.sh session"])
        #expect(!HookConfig.contains(out))
    }

    @Test func removeDropsEmptiedKeys() throws {
        let merged = try HookConfig.merged(Data(#"{"model":"m"}"#.utf8), command: ours)
        let out = try object(try HookConfig.removed(merged))
        #expect(out["hooks"] == nil)
        #expect(out["model"] as? String == "m")
    }

    @Test func nilInputCreates() throws {
        let out = try HookConfig.merged(nil, command: ours)
        let hooks = try #require(try object(out)["hooks"] as? [String: Any])
        let group = try #require((hooks["SessionStart"] as? [[String: Any]])?.first)
        let entry = try #require((group["hooks"] as? [[String: Any]])?.first)
        #expect(entry["type"] as? String == "command")
        #expect(entry["command"] as? String == ours)
        #expect(entry["timeout"] as? Int == 5)
    }

    @Test func neverTouchesStatusLine() throws {
        let before = try #require(try object(Data(existing.utf8))["statusLine"])
        let after = try #require(try object(try HookConfig.merged(Data(existing.utf8), command: ours))["statusLine"])
        let opts: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        #expect(
            try JSONSerialization.data(withJSONObject: before, options: opts)
                == JSONSerialization.data(withJSONObject: after, options: opts))
    }

    @Test func nonObjectIsRejected() {
        #expect(throws: HookConfigError.self) { try HookConfig.merged(Data("[1]".utf8), command: ours) }
        #expect(throws: HookConfigError.self) { try HookConfig.merged(Data("nope".utf8), command: ours) }
    }
}

private final class Home {
    let dir = FileManager.default.temporaryDirectory.appending(path: "headroom-install-\(UUID().uuidString)")
    var home: URL { dir.appending(path: "home") }
    var source: URL { dir.appending(path: "src") }
    var launchctlCalls: [[String]] = []

    init() throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["headroom", "headroomd"] {
            try Data("bin-\(name)".utf8).write(to: source.appending(path: name))
        }
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func install(agents: Bool, bootstrapStatus: Int32 = 0) -> (Int32, [String], [String]) {
        var out: [String] = []
        var err: [String] = []
        let code = Install.run(
            agents: agents, home: home, sourceDir: source, uid: 501, now: Date(timeIntervalSince1970: 1_800_000_000),
            launchctl: { args in
                self.launchctlCalls.append(args)
                return args.first == "bootstrap" ? bootstrapStatus : 0
            },
            out: { out.append($0) }, err: { err.append($0) })
        return (code, out, err)
    }

    func uninstall() -> (Int32, [String]) {
        var out: [String] = []
        let code = Install.uninstall(
            home: home, dataDirectory: dir.appending(path: "data"), uid: 501,
            now: Date(timeIntervalSince1970: 1_800_000_001),
            launchctl: { self.launchctlCalls.append($0); return 0 }, out: { out.append($0) }, err: { _ in })
        return (code, out)
    }
}

@Suite struct InstallRunTests {
    @Test func installsBinariesPlistAndBootstraps() throws {
        let h = try Home()
        let (code, _, _) = h.install(agents: false)
        #expect(code == 0)
        let bin = h.home.appending(path: ".local/bin")
        #expect(try String(contentsOf: bin.appending(path: "headroomd"), encoding: .utf8) == "bin-headroomd")
        let plistURL = h.home.appending(path: "Library/LaunchAgents/io.github.llinder.headroom.plist")
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == [bin.appending(path: "headroomd").path])
        #expect(
            h.launchctlCalls == [
                ["bootout", "gui/501/io.github.llinder.headroom"], ["bootstrap", "gui/501", plistURL.path],
            ])
        #expect(!FileManager.default.fileExists(atPath: h.home.appending(path: ".claude/settings.json").path))
    }

    @Test func reinstallReplacesBinaries() throws {
        let h = try Home()
        _ = h.install(agents: false)
        try Data("new".utf8).write(to: h.source.appending(path: "headroomd"))
        _ = h.install(agents: false)
        #expect(try String(contentsOf: h.home.appending(path: ".local/bin/headroomd"), encoding: .utf8) == "new")
    }

    @Test func bootstrapFailureReturnsOne() throws {
        let h = try Home()
        let (code, _, err) = h.install(agents: false, bootstrapStatus: 5)
        #expect(code == 1)
        #expect(!err.isEmpty)
    }

    @Test func agentsMergesBacksUpAndSkipsMissingDirs() throws {
        let h = try Home()
        let settings = h.home.appending(path: ".claude/settings.json")
        try Data(existing.utf8).write(to: settings)
        let (code, out, _) = h.install(agents: true)
        #expect(code == 0)
        let written = try Data(contentsOf: settings)
        let abs = h.home.appending(path: ".local/bin/headroom").path
        #expect(try commands(written).contains("\(abs) agent-hook claude"))
        let backup = h.home.appending(path: ".claude/settings.json.headroom-backup-1800000000")
        #expect(try Data(contentsOf: backup) == Data(existing.utf8))
        #expect(!FileManager.default.fileExists(atPath: h.home.appending(path: ".codex").path))
        #expect(out.contains { $0.contains("\(abs) statusline") })

        let claudeDir = h.home.appending(path: ".claude").path
        let before = try FileManager.default.contentsOfDirectory(atPath: claudeDir)
        _ = h.install(agents: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: claudeDir).count == before.count)
    }

    @Test func nonObjectFileIsLeftAlone() throws {
        let h = try Home()
        let settings = h.home.appending(path: ".claude/settings.json")
        try Data("[1,2]".utf8).write(to: settings)
        let (_, _, err) = h.install(agents: true)
        #expect(try Data(contentsOf: settings) == Data("[1,2]".utf8))
        #expect(err.contains { $0.contains("settings.json") })
    }

    @Test func uninstallRemovesEverythingOursAndKeepsData() throws {
        let h = try Home()
        let settings = h.home.appending(path: ".claude/settings.json")
        try Data(existing.utf8).write(to: settings)
        _ = h.install(agents: true)
        h.launchctlCalls = []
        let (code, out) = h.uninstall()
        #expect(code == 0)
        #expect(h.launchctlCalls == [["bootout", "gui/501/io.github.llinder.headroom"]])
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: h.home.appending(path: ".local/bin/headroom").path))
        #expect(!fm.fileExists(atPath: h.home.appending(path: ".local/bin/headroomd").path))
        #expect(!fm.fileExists(atPath: h.home.appending(path: "Library/LaunchAgents/io.github.llinder.headroom.plist").path))
        #expect(try commands(Data(contentsOf: settings)) == ["bash herdr-agent-state.sh session"])
        #expect(out.contains { $0.contains("data") && $0.contains("kept") })
    }
}

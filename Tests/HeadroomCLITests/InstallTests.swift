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

private func commands(_ data: Data, event: String = "SessionStart") throws -> [String] {
    let hooks = try #require(try object(data)["hooks"] as? [String: Any])
    let groups = try #require(hooks[event] as? [[String: Any]])
    return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

@Suite struct HookConfigTests {
    @Test func plistKeys() throws {
        let data = try LaunchAgent.plist(binary: "/opt/headroomd")
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
        let out = try HookConfig.merged(Data(existing.utf8), event: "SessionStart", matcher: nil, command: ours)
        let root = try object(out)
        #expect(root["statusLine"] != nil)
        #expect(root["permissions"] != nil)
        #expect(try commands(out) == ["bash herdr-agent-state.sh session", ours])
    }

    @Test func mergeIdempotent() throws {
        let once = try HookConfig.merged(Data(existing.utf8), event: "SessionStart", matcher: nil, command: ours)
        let twice = try HookConfig.merged(once, event: "SessionStart", matcher: nil, command: ours)
        #expect(try commands(twice).filter { $0.contains("headroom agent-hook") }.count == 1)
        #expect(once == twice)
        #expect(HookConfig.contains(twice, event: "SessionStart"))
    }

    @Test func mergeWithMarkerReturnsTheOriginalBytes() throws {
        let installed = Data(
            #"{ "zeta": 1, "hooks": {"SessionStart": [{"hooks": [{"command": "\#(ours)", "type": "command"}]}]}, "alpha": "a/b" }"#
                .utf8)
        #expect(try HookConfig.merged(installed, event: "SessionStart", matcher: nil, command: ours) == installed)
    }

    @Test func removeOnlyOurs() throws {
        let merged = try HookConfig.merged(Data(existing.utf8), event: "SessionStart", matcher: nil, command: ours)
        let out = try HookConfig.removed(merged)
        #expect(try commands(out) == ["bash herdr-agent-state.sh session"])
        #expect(!HookConfig.contains(out, event: "SessionStart"))
    }

    @Test func removeDropsEmptiedKeys() throws {
        let merged = try HookConfig.merged(Data(#"{"model":"m"}"#.utf8), event: "SessionStart", matcher: nil, command: ours)
        let out = try object(try HookConfig.removed(merged))
        #expect(out["hooks"] == nil)
        #expect(out["model"] as? String == "m")
    }

    @Test func nilInputCreates() throws {
        let out = try HookConfig.merged(nil, event: "SessionStart", matcher: nil, command: ours)
        let hooks = try #require(try object(out)["hooks"] as? [String: Any])
        let group = try #require((hooks["SessionStart"] as? [[String: Any]])?.first)
        let entry = try #require((group["hooks"] as? [[String: Any]])?.first)
        #expect(entry["type"] as? String == "command")
        #expect(entry["command"] as? String == ours)
        #expect(entry["timeout"] as? Int == 5)
    }

    @Test func upgradeFromPhase1AddsPreToolUse() throws {
        let phase1 = try HookConfig.merged(Data(existing.utf8), event: "SessionStart", matcher: nil, command: ours)
        let pre = "/Users/x/.local/bin/headroom agent-hook pretool claude"
        let out = try HookConfig.merged(phase1, event: "PreToolUse", matcher: "Bash", command: pre)
        #expect(try commands(out) == ["bash herdr-agent-state.sh session", ours])
        #expect(try commands(out, event: "PreToolUse") == [pre])
        let hooks = try #require(try object(out)["hooks"] as? [String: Any])
        let group = try #require((hooks["PreToolUse"] as? [[String: Any]])?.first)
        #expect(group["matcher"] as? String == "Bash")
        #expect(HookConfig.contains(out, event: "PreToolUse"))
    }

    @Test func mergeIsIdempotentPerEvent() throws {
        let pre = "/Users/x/.local/bin/headroom agent-hook pretool claude"
        let once = try HookConfig.merged(Data(existing.utf8), event: "PreToolUse", matcher: "Bash", command: pre)
        let twice = try HookConfig.merged(once, event: "PreToolUse", matcher: "Bash", command: pre)
        #expect(once == twice)
    }

    @Test func removeDropsAllOurEventsKeepsOthers() throws {
        let foreign = Data(
            #"{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"other.sh"}]}]}}"#.utf8)
        let pre = "/Users/x/.local/bin/headroom agent-hook pretool claude"
        let a = try HookConfig.merged(foreign, event: "SessionStart", matcher: nil, command: ours)
        let b = try HookConfig.merged(a, event: "PreToolUse", matcher: "Bash", command: pre)
        let out = try HookConfig.removed(b)
        #expect(try commands(out, event: "PreToolUse") == ["other.sh"])
        let hooks = try #require(try object(out)["hooks"] as? [String: Any])
        #expect(hooks["SessionStart"] == nil)
        #expect(!HookConfig.contains(out, event: "PreToolUse"))
    }

    @Test func pathChangeReplacesInPlace() throws {
        let old = "/old/headroom agent-hook pretool claude"
        let moved = "/new/headroom agent-hook pretool claude"
        let first = try HookConfig.merged(Data(existing.utf8), event: "PreToolUse", matcher: "Bash", command: old)
        let out = try HookConfig.merged(first, event: "PreToolUse", matcher: "Bash", command: moved)
        #expect(try commands(out, event: "PreToolUse") == [moved])
        let hooks = try #require(try object(out)["hooks"] as? [String: Any])
        let group = try #require((hooks["PreToolUse"] as? [[String: Any]])?.first)
        #expect(group["matcher"] as? String == "Bash")
    }

    @Test func duplicateSameModeEntriesCollapse() throws {
        let dupes = Data(
            #"""
            {"hooks":{"SessionStart":[
            {"hooks":[{"type":"command","command":"/a/headroom agent-hook claude"}]},
            {"hooks":[{"type":"command","command":"keep.sh"},{"type":"command","command":"/b/headroom agent-hook claude"}]}]}}
            """#.utf8)
        let out = try HookConfig.merged(dupes, event: "SessionStart", matcher: nil, command: ours)
        #expect(try commands(out) == [ours, "keep.sh"])
    }

    @Test func foreignHookSharingGroupSurvivesRemove() throws {
        let shared = Data(
            #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"command":"other.sh"},{"command":"/a/headroom agent-hook pretool claude"}]}]}}"#
                .utf8)
        let out = try HookConfig.removed(shared)
        #expect(try commands(out, event: "PreToolUse") == ["other.sh"])
    }

    @Test func sessionStartHasNoMatcherKey() throws {
        let out = try HookConfig.merged(nil, event: "SessionStart", matcher: nil, command: ours)
        let hooks = try #require(try object(out)["hooks"] as? [String: Any])
        let group = try #require((hooks["SessionStart"] as? [[String: Any]])?.first)
        #expect(group["matcher"] == nil)
    }

    @Test func foreignEmptyEventListSurvivesRemove() throws {
        let src = Data(#"{"hooks":{"Stop":[],"SessionStart":[{"hooks":[{"command":"/a/headroom agent-hook claude"}]}]}}"#.utf8)
        let hooks = try #require(try object(try HookConfig.removed(src))["hooks"] as? [String: Any])
        #expect((hooks["Stop"] as? [Any])?.isEmpty == true)
        #expect(hooks["SessionStart"] == nil)
    }

    @Test func neverTouchesStatusLine() throws {
        let before = try #require(try object(Data(existing.utf8))["statusLine"])
        let after = try #require(try object(try HookConfig.merged(Data(existing.utf8), event: "SessionStart", matcher: nil, command: ours))["statusLine"])
        let opts: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        #expect(
            try JSONSerialization.data(withJSONObject: before, options: opts)
                == JSONSerialization.data(withJSONObject: after, options: opts))
    }

    @Test func nonObjectIsRejected() {
        #expect(throws: HookConfigError.self) { try HookConfig.merged(Data("[1]".utf8), event: "SessionStart", matcher: nil, command: ours) }
        #expect(throws: HookConfigError.self) { try HookConfig.merged(Data("nope".utf8), event: "SessionStart", matcher: nil, command: ours) }
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

    var bootstrapResults: [Int32] = []
    var sleeps: [TimeInterval] = []
    /// CLIs the fake PATH lookup finds, by name, and what their `mcp list` prints.
    var onPath: [String: String] = [:]
    var addStatus: Int32 = 0
    var runnerCalls: [[String]] = []

    func runner(_ args: [String]) -> (status: Int32, stdout: String) {
        runnerCalls.append(args)
        let name = URL(filePath: args[0]).lastPathComponent
        if args.dropFirst().starts(with: ["mcp", "list"]) { return (0, onPath[name] ?? "") }
        if args.dropFirst().starts(with: ["mcp", "add"]) { return (addStatus, "") }
        return (1, "")
    }

    func find(_ name: String) -> String? {
        onPath[name] == nil ? nil : "/fake/bin/\(name)"
    }

    func install(agents: Bool, bootstrapStatus: Int32 = 0) -> (Int32, [String], [String]) {
        var out: [String] = []
        var err: [String] = []
        let code = Install.run(
            agents: agents, home: home, sourceDir: source, uid: 501, now: Date(timeIntervalSince1970: 1_800_000_000),
            launchctl: { args in
                self.launchctlCalls.append(args)
                guard args.first == "bootstrap" else { return 0 }
                return self.bootstrapResults.isEmpty ? bootstrapStatus : self.bootstrapResults.removeFirst()
            },
            sleep: { self.sleeps.append($0) }, runner: runner, find: find,
            out: { out.append($0) }, err: { err.append($0) })
        return (code, out, err)
    }

    func uninstall() -> (Int32, [String]) {
        var out: [String] = []
        let code = Install.uninstall(
            home: home, dataDirectory: dir.appending(path: "data"), uid: 501,
            now: Date(timeIntervalSince1970: 1_800_000_001),
            launchctl: { self.launchctlCalls.append($0); return 0 }, runner: runner, find: find,
            out: { out.append($0) }, err: { _ in })
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

    @Test func installAgentsWritesBothEventsForBothTools() throws {
        let h = try Home()
        try FileManager.default.createDirectory(at: h.home.appending(path: ".codex"), withIntermediateDirectories: true)
        let (_, out, _) = h.install(agents: true)
        let abs = h.home.appending(path: ".local/bin/headroom").path
        for (path, tool) in [(".claude/settings.json", "claude"), (".codex/hooks.json", "codex")] {
            let data = try Data(contentsOf: h.home.appending(path: path))
            #expect(try commands(data) == ["\(abs) agent-hook \(tool)"])
            #expect(try commands(data, event: "PreToolUse") == ["\(abs) agent-hook pretool \(tool)"])
            let hooks = try #require(try object(data)["hooks"] as? [String: Any])
            let group = try #require((hooks["PreToolUse"] as? [[String: Any]])?.first)
            #expect(group["matcher"] as? String == "Bash")
        }
        #expect(out.contains("codex: approve the new headroom hooks when Codex asks you to trust them"))
    }

    @Test func codexUserHooksSurviveInstall() throws {
        let h = try Home()
        let codex = h.home.appending(path: ".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let user = #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"mine.sh"}]}]}}"#
        try Data(user.utf8).write(to: codex.appending(path: "hooks.json"))
        _ = h.install(agents: true)
        let data = try Data(contentsOf: codex.appending(path: "hooks.json"))
        let abs = h.home.appending(path: ".local/bin/headroom").path
        #expect(try commands(data, event: "PreToolUse") == ["mine.sh", "\(abs) agent-hook pretool codex"])
        #expect(try commands(data) == ["\(abs) agent-hook codex"])
    }

    @Test func codexMessageOnlyWhenWritten() throws {
        let h = try Home()
        try FileManager.default.createDirectory(at: h.home.appending(path: ".codex"), withIntermediateDirectories: true)
        let note = "codex: approve the new headroom hooks when Codex asks you to trust them"
        let (_, first, _) = h.install(agents: true)
        #expect(first.contains(note))
        let (_, second, _) = h.install(agents: true)
        #expect(!second.contains(note))
    }

    @Test func installedFileIsLeftByteIdentical() throws {
        let h = try Home()
        let settings = h.home.appending(path: ".claude/settings.json")
        let abs = h.home.appending(path: ".local/bin/headroom").path
        let installed = Data(
            #"""
            { "zeta": 1, "hooks": {"SessionStart": [{"hooks": [{"command": "\#(abs) agent-hook claude"}]}],
            "PreToolUse": [{"matcher": "Bash", "hooks": [{"command": "\#(abs) agent-hook pretool claude"}]}]} }
            """#.utf8)
        try installed.write(to: settings)
        let (_, out, _) = h.install(agents: true)
        #expect(try Data(contentsOf: settings) == installed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.home.appending(path: ".claude").path) == ["settings.json"])
        #expect(!out.contains { $0.hasPrefix("updated") })
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

    @Test func bootstrapRetriesAfterTransientFailure() throws {
        let h = try Home()
        h.bootstrapResults = [5, 0]
        let (code, _, _) = h.install(agents: false)
        #expect(code == 0)
        #expect(h.launchctlCalls.filter { $0.first == "bootstrap" }.count == 2)
        #expect(h.sleeps == [0.2])
    }

    @Test func bootstrapGivesUpAfterFiveAttempts() throws {
        let h = try Home()
        let (code, _, _) = h.install(agents: false, bootstrapStatus: 5)
        #expect(code == 1)
        #expect(h.launchctlCalls.filter { $0.first == "bootstrap" }.count == 5)
    }

    @Test func unreadableFileIsLeftAlone() throws {
        let h = try Home()
        let settings = h.home.appending(path: ".claude/settings.json")
        try Data(existing.utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path) }
        let (_, _, err) = h.install(agents: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        #expect(try Data(contentsOf: settings) == Data(existing.utf8))
        #expect(err.contains { $0.contains("settings.json") && $0.contains("unreadable") })
        let names = try FileManager.default.contentsOfDirectory(atPath: h.home.appending(path: ".claude").path)
        #expect(names == ["settings.json"])
    }

    @Test func symlinkedConfigStaysASymlink() throws {
        let h = try Home()
        let elsewhere = h.dir.appending(path: "dotfiles")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = elsewhere.appending(path: "settings.json")
        try Data(existing.utf8).write(to: target)
        let link = h.home.appending(path: ".claude/settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        _ = h.install(agents: true)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(try commands(Data(contentsOf: target)).contains { $0.contains("headroom agent-hook claude") })
        _ = h.uninstall()
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(try commands(Data(contentsOf: target)) == ["bash herdr-agent-state.sh session"])
    }

    @Test func existingBackupIsNotClobberedAndKeepsMode() throws {
        let h = try Home()
        let settings = h.home.appending(path: ".claude/settings.json")
        try Data(existing.utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        let taken = h.home.appending(path: ".claude/settings.json.headroom-backup-1800000000")
        try Data("older".utf8).write(to: taken)
        _ = h.install(agents: true)
        #expect(try Data(contentsOf: taken) == Data("older".utf8))
        let next = h.home.appending(path: ".claude/settings.json.headroom-backup-1800000000-1")
        #expect(try Data(contentsOf: next) == Data(existing.utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: next.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func missingSourceBinaryInstallsNothing() throws {
        let h = try Home()
        try FileManager.default.removeItem(at: h.source.appending(path: "headroomd"))
        let (code, _, err) = h.install(agents: false)
        #expect(code == 1)
        #expect(!err.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.home.appending(path: ".local/bin/headroom").path))
        #expect(h.launchctlCalls.isEmpty)
    }

    @Test func uninstallOnEmptyHomeSucceeds() throws {
        let h = try Home()
        let (code, _) = h.uninstall()
        #expect(code == 0)
    }

    @Test func configModeSurvivesInstallAndUninstall() throws {
        let h = try Home()
        let settings = h.home.appending(path: ".claude/settings.json")
        try Data(existing.utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        func mode() throws -> Int? {
            (try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? NSNumber)?.intValue
        }
        _ = h.install(agents: true)
        #expect(try mode() == 0o600)
        _ = h.uninstall()
        #expect(try mode() == 0o600)
    }

    @Test func newConfigIsCreatedPrivate() throws {
        let h = try Home()
        _ = h.install(agents: true)
        let settings = h.home.appending(path: ".claude/settings.json")
        let mode = try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func uninstallNeverCreatesMissingConfig() throws {
        let h = try Home()
        _ = h.uninstall()
        #expect(!FileManager.default.fileExists(atPath: h.home.appending(path: ".claude/settings.json").path))
    }

    @Test func mcpRegistersWhenAbsentAndSkipsWhenPresent() throws {
        let h = try Home()
        let abs = h.home.appending(path: ".local/bin/headroom").path
        h.onPath = [
            "claude": "Checking MCP server health…\n\nother: /bin/other mcp - ✔ Connected\n",
            "codex": "Name      Command                Args\nheadroom  /old/headroom  mcp\n",
        ]
        let (code, out, _) = h.install(agents: true)
        #expect(code == 0)
        #expect(
            h.runnerCalls == [
                ["/fake/bin/claude", "mcp", "list"],
                ["/fake/bin/claude", "mcp", "add", "--scope", "user", "headroom", "--", abs, "mcp"],
                ["/fake/bin/codex", "mcp", "list"],
            ])
        #expect(out.contains("claude: registered the headroom MCP server"))
        #expect(out.contains("codex: headroom MCP server already registered"))

        h.runnerCalls = []
        h.onPath = ["codex": "No MCP servers configured yet.\n"]
        _ = h.install(agents: true)
        #expect(
            h.runnerCalls == [["/fake/bin/codex", "mcp", "list"], ["/fake/bin/codex", "mcp", "add", "headroom", "--", abs, "mcp"]])
    }

    /// `claude mcp list` health-checks every server and can take ~30 s, so the user is told before it starts.
    @Test func mcpCheckAnnouncesItselfOnlyWhenACLIIsPresent() throws {
        let h = try Home()
        h.onPath = ["claude": ""]
        let (_, out, _) = h.install(agents: true)
        let notice = try #require(out.firstIndex(of: "checking MCP registrations…"))
        let registered = try #require(out.firstIndex(of: "claude: registered the headroom MCP server"))
        #expect(notice < registered)
        #expect(out.filter { $0 == "checking MCP registrations…" }.count == 1)

        h.onPath = [:]
        let (_, quiet, _) = h.install(agents: true)
        #expect(!quiet.contains("checking MCP registrations…"))
    }

    @Test func mcpNameMustMatchExactly() throws {
        let h = try Home()
        h.onPath = ["claude": "headroom-dev: /x/headroom mcp - ✔ Connected\nnotes: /git/headroom/run - ✔ Connected\n"]
        _ = h.install(agents: true)
        #expect(h.runnerCalls.contains { $0.contains("add") })
    }

    @Test func mcpAddFailureIsReportedAndInstallSucceeds() throws {
        let h = try Home()
        h.onPath = ["claude": ""]
        h.addStatus = 1
        let (code, _, err) = h.install(agents: true)
        #expect(code == 0)
        #expect(err.contains { $0.contains("claude mcp add") && $0.contains("status 1") })

        h.runnerCalls = []
        _ = h.install(agents: false)
        #expect(h.runnerCalls.isEmpty)
    }

    @Test func uninstallRemovesMCPRegistrations() throws {
        let h = try Home()
        h.onPath = ["claude": "", "codex": ""]
        let (code, _) = h.uninstall()
        #expect(code == 0)
        #expect(
            h.runnerCalls == [
                ["/fake/bin/claude", "mcp", "remove", "--scope", "user", "headroom"],
                ["/fake/bin/codex", "mcp", "remove", "headroom"],
            ])
    }

    @Test func noCLIsOnPathRunsNothing() throws {
        let h = try Home()
        _ = h.install(agents: true)
        _ = h.uninstall()
        #expect(h.runnerCalls.isEmpty)
    }
}

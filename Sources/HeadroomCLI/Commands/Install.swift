import Foundation

enum LaunchAgent {
    static let label = "io.github.llinder.headroom"

    // The recorder logs through os.Logger, so launchd's stdout/stderr files would only collect nothing.
    static func plist(binary: String) -> Data {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        // A literal dictionary of plist types always serializes.
        return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? Data()
    }
}

struct HookConfigError: Error, Equatable {
    let message: String
}

enum HookConfig {
    static let marker = "headroom agent-hook"
    private static let writing: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    static func merged(_ json: Data?, command: String) throws -> Data {
        var root = try parse(json)
        if contains(root) { return try encode(root) }
        var hooks = try section(root["hooks"])
        var groups = try groupList(hooks["SessionStart"])
        let entry: [String: Any] = ["type": "command", "command": command, "timeout": 5]
        groups.append(["hooks": [entry]])
        hooks["SessionStart"] = groups
        root["hooks"] = hooks
        return try encode(root)
    }

    static func removed(_ json: Data) throws -> Data {
        var root = try parse(json)
        var hooks = try section(root["hooks"])
        guard hooks["SessionStart"] != nil else { return try encode(root) }
        let kept = try groupList(hooks["SessionStart"]).compactMap { group -> [String: Any]? in
            guard let entries = group["hooks"] as? [[String: Any]] else { return group }
            let rest = entries.filter { !isOurs($0) }
            if rest.count == entries.count { return group }
            if rest.isEmpty { return nil }
            var copy = group
            copy["hooks"] = rest
            return copy
        }
        hooks["SessionStart"] = kept.isEmpty ? nil : kept
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try encode(root)
    }

    static func contains(_ json: Data) -> Bool {
        guard let root = try? parse(json) else { return false }
        return contains(root)
    }

    private static func contains(_ root: [String: Any]) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any], let groups = hooks["SessionStart"] as? [[String: Any]] else {
            return false
        }
        return groups.contains { ($0["hooks"] as? [[String: Any]] ?? []).contains(where: isOurs) }
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(marker) == true
    }

    private static func parse(_ json: Data?) throws -> [String: Any] {
        guard let json else { return [:] }
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw HookConfigError(message: "not a JSON object")
        }
        return root
    }

    private static func section(_ value: Any?) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let dict = value as? [String: Any] else { throw HookConfigError(message: "hooks is not an object") }
        return dict
    }

    private static func groupList(_ value: Any?) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let list = value as? [[String: Any]] else {
            throw HookConfigError(message: "hooks.SessionStart is not a list of objects")
        }
        return list
    }

    private static func encode(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: writing)
    }
}

enum Install {
    private static let binaries = ["headroom", "headroomd"]

    static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        // bootout of a job that isn't loaded is the normal first-install case, so its complaint is noise.
        if arguments.first == "bootout" { process.standardError = FileHandle.nullDevice }
        guard (try? process.run()) != nil else { return 127 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func hookFiles(home: URL) -> [(url: URL, tool: String)] {
        [(home.appending(path: ".claude/settings.json"), "claude"), (home.appending(path: ".codex/hooks.json"), "codex")]
    }

    private static func plistURL(home: URL) -> URL {
        home.appending(path: "Library/LaunchAgents/\(LaunchAgent.label).plist")
    }

    static func run(
        agents: Bool, home: URL, sourceDir: URL, uid: UInt32, now: Date, launchctl: ([String]) -> Int32,
        out: (String) -> Void, err: (String) -> Void
    ) -> Int32 {
        let fm = FileManager.default
        let bin = home.appending(path: ".local/bin")
        do {
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            for name in binaries {
                try replace(bin.appending(path: name), withCopyOf: sourceDir.appending(path: name))
            }
            let plist = plistURL(home: home)
            try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LaunchAgent.plist(binary: bin.appending(path: "headroomd").path).write(to: plist, options: .atomic)

            _ = launchctl(["bootout", "gui/\(uid)/\(LaunchAgent.label)"])
            let status = launchctl(["bootstrap", "gui/\(uid)", plist.path])
            guard status == 0 else {
                err("launchctl bootstrap failed with status \(status)")
                return 1
            }
        } catch {
            err("install failed: \(error.localizedDescription)")
            return 1
        }
        out("installed \(bin.path) and started \(LaunchAgent.label)")

        guard agents else { return 0 }
        let exe = bin.appending(path: "headroom").path
        for (file, tool) in hookFiles(home: home) where fm.fileExists(atPath: file.deletingLastPathComponent().path) {
            update(file, now: now, out: out, err: err) {
                try HookConfig.merged($0, command: "\(exe) agent-hook \(tool)")
            }
        }
        out(
            """
            status line: ccstatusline custom command: \(exe) statusline
            or Claude Code: "statusLine": {"type":"command","command":"\(exe) statusline"}
            """)
        return 0
    }

    static func uninstall(
        home: URL, dataDirectory: URL, uid: UInt32, now: Date, launchctl: ([String]) -> Int32,
        out: (String) -> Void, err: (String) -> Void
    ) -> Int32 {
        let fm = FileManager.default
        _ = launchctl(["bootout", "gui/\(uid)/\(LaunchAgent.label)"])
        let targets = [plistURL(home: home)] + binaries.map { home.appending(path: ".local/bin/\($0)") }
        for target in targets where fm.fileExists(atPath: target.path) {
            do {
                try fm.removeItem(at: target)
            } catch {
                err("could not remove \(target.path): \(error.localizedDescription)")
            }
        }
        for (file, _) in hookFiles(home: home) where fm.fileExists(atPath: file.path) {
            guard let existing = try? Data(contentsOf: file), HookConfig.contains(existing) else { continue }
            update(file, now: now, out: out, err: err) { try HookConfig.removed($0 ?? existing) }
        }
        out("uninstalled \(LaunchAgent.label)")
        out("data kept at \(dataDirectory.path)")
        return 0
    }

    /// Backs up the original and writes only when the content changes; an unparseable file is reported and left alone.
    private static func update(
        _ file: URL, now: Date, out: (String) -> Void, err: (String) -> Void, transform: (Data?) throws -> Data
    ) {
        let existing = try? Data(contentsOf: file)
        do {
            let updated = try transform(existing)
            if let existing {
                let old = try JSONSerialization.jsonObject(with: existing) as? NSDictionary
                let new = try JSONSerialization.jsonObject(with: updated) as? NSDictionary
                if old == new { return }
                let backup = file.deletingLastPathComponent().appending(
                    path: "\(file.lastPathComponent).headroom-backup-\(Int(now.timeIntervalSince1970))")
                try existing.write(to: backup)
            }
            try updated.write(to: file, options: .atomic)
            out("updated \(file.path)")
        } catch let error as HookConfigError {
            err("\(file.path): \(error.message); left unchanged")
        } catch {
            err("\(file.path): \(error.localizedDescription); left unchanged")
        }
    }

    // rename(2) swaps the file atomically, so a running recorder never sees a half-written binary.
    private static func replace(_ destination: URL, withCopyOf source: URL) throws {
        let temp = destination.deletingLastPathComponent().appending(
            path: ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: temp)
        guard rename(temp.path, destination.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

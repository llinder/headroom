import Foundation

enum LaunchAgent {
    static let label = "io.github.llinder.headroom"

    // The recorder logs through os.Logger, so launchd's stdout/stderr files would only collect nothing.
    static func plist(binary: String) throws -> Data {
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
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }
}

struct HookConfigError: Error, Equatable {
    let message: String
}

enum HookConfig {
    static let marker = "headroom agent-hook"
    private static let writing: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    /// An entry with exactly this command under the event leaves the file as the same bytes, so a reinstall never
    /// rewrites, re-sorts or backs it up.
    static func merged(_ json: Data?, event: String, matcher: String?, command: String) throws -> Data {
        var root = try parse(json)
        var hooks = try section(root["hooks"])
        var groups = try groupList(hooks[event], event: event)
        let present = groups.contains { ($0["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command } }
        if let json, present { return json }
        let entry: [String: Any] = ["type": "command", "command": command, "timeout": 5]
        var group: [String: Any] = ["hooks": [entry]]
        group["matcher"] = matcher
        groups.append(group)
        hooks[event] = groups
        root["hooks"] = hooks
        return try encode(root)
    }

    static func removed(_ json: Data) throws -> Data {
        var root = try parse(json)
        var hooks = try section(root["hooks"])
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let rest = entries.filter { !isOurs($0) }
                if rest.count == entries.count { return group }
                if rest.isEmpty { return nil }
                var copy = group
                copy["hooks"] = rest
                return copy
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try encode(root)
    }

    static func contains(_ json: Data, event: String) -> Bool {
        guard let root = try? parse(json), let hooks = root["hooks"] as? [String: Any],
            let groups = hooks[event] as? [[String: Any]]
        else { return false }
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

    private static func groupList(_ value: Any?, event: String) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let list = value as? [[String: Any]] else {
            throw HookConfigError(message: "hooks.\(event) is not a list of objects")
        }
        return list
    }

    private static func encode(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: writing)
    }
}

enum Install {
    private static let hookEvents = ["SessionStart", "PreToolUse"]
    private static let binaries = ["headroom", "headroomd"]
    private static let bootstrapAttempts = 5

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
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        out: (String) -> Void, err: (String) -> Void
    ) -> Int32 {
        let fm = FileManager.default
        let bin = home.appending(path: ".local/bin")
        do {
            for name in binaries where !fm.isReadableFile(atPath: sourceDir.appending(path: name).path) {
                err("install failed: \(sourceDir.appending(path: name).path) not found")
                return 1
            }
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            for name in binaries {
                try replace(bin.appending(path: name), withCopyOf: sourceDir.appending(path: name))
            }
            let plist = plistURL(home: home)
            try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LaunchAgent.plist(binary: bin.appending(path: "headroomd").path).write(to: plist, options: .atomic)

            _ = launchctl(["bootout", "gui/\(uid)/\(LaunchAgent.label)"])
            // Bootstrapping right after bootout of a live job often fails with I/O error 5 until launchd finishes teardown.
            var status = launchctl(["bootstrap", "gui/\(uid)", plist.path])
            for _ in 1..<bootstrapAttempts where status != 0 {
                sleep(0.2)
                status = launchctl(["bootstrap", "gui/\(uid)", plist.path])
            }
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
                let session = try HookConfig.merged(
                    $0, event: "SessionStart", matcher: nil, command: "\(exe) agent-hook \(tool)")
                return try HookConfig.merged(
                    session, event: "PreToolUse", matcher: "Bash", command: "\(exe) agent-hook pretool \(tool)")
            }
            if tool == "codex" { out("codex: approve the new headroom hooks when Codex asks you to trust them") }
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
            update(file, now: now, out: out, err: err) { data in
                guard let data, hookEvents.contains(where: { HookConfig.contains(data, event: $0) }) else { return nil }
                return try HookConfig.removed(data)
            }
        }
        out("uninstalled \(LaunchAgent.label)")
        out("data kept at \(dataDirectory.path)")
        return 0
    }

    /// Backs up the original and writes only when the content changes. Only a missing file counts as empty: an
    /// unreadable or unparseable one is reported and left alone. Symlinks are resolved so the link survives the write.
    private static func update(
        _ original: URL, now: Date, out: (String) -> Void, err: (String) -> Void, transform: (Data?) throws -> Data?
    ) {
        let file = original.resolvingSymlinksInPath()
        let fm = FileManager.default
        var existing: Data?
        if fm.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file) else {
                err("\(original.path): unreadable, left unchanged")
                return
            }
            existing = data
        }
        do {
            guard let updated = try transform(existing) else { return }
            if let existing {
                if updated == existing { return }
                let old = try JSONSerialization.jsonObject(with: existing) as? NSDictionary
                let new = try JSONSerialization.jsonObject(with: updated) as? NSDictionary
                if old == new { return }
                try backup(file, contents: existing, now: now)
            }
            // Atomic writes land a new inode at the default mode; configs here can hold tokens, so keep the original's.
            let mode = existing == nil ? 0o600 : try permissions(of: file)
            try updated.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
            out("updated \(original.path)")
        } catch let error as HookConfigError {
            err("\(original.path): \(error.message); left unchanged")
        } catch {
            err("\(original.path): \(error.localizedDescription); left unchanged")
        }
    }

    private static func permissions(of file: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
    }

    // O_EXCL makes the name claim atomic, so concurrent installs can't clobber each other's backup.
    private static func backup(_ file: URL, contents: Data, now: Date) throws {
        let mode = try permissions(of: file)
        let base = file.deletingLastPathComponent().appending(
            path: "\(file.lastPathComponent).headroom-backup-\(Int(now.timeIntervalSince1970))")
        var suffix = 0
        while true {
            let target = suffix == 0 ? base : URL(filePath: "\(base.path)-\(suffix)")
            let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode))
            if fd < 0 {
                guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                suffix += 1
                continue
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: contents)
            try handle.close()
            return
        }
    }

    // rename(2) swaps the file atomically, so a running recorder never sees a half-written binary.
    private static func replace(_ destination: URL, withCopyOf source: URL) throws {
        let temp = destination.deletingLastPathComponent().appending(
            path: ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: temp)
            guard rename(temp.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}

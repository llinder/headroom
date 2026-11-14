import Foundation
import IOKit
import IOKit.pwr_mgt

public enum PowerEvent: Sendable {
    case willSleep(Double)
    case didWake(Double)
}

/// Sleep and wake notifications from IOKit, delivered on the main queue.
@MainActor
public final class PowerMonitor {
    // IOMessage.h builds these with a function-like macro (iokit_common_msg), which Swift doesn't import.
    private enum Message {
        static let canSystemSleep: natural_t = 0xE000_0270
        static let systemWillSleep: natural_t = 0xE000_0280
        static let systemHasPoweredOn: natural_t = 0xE000_0300
    }

    private let handler: @MainActor (PowerEvent) -> Void
    private var registration: Registration?

    public init(handler: @escaping @MainActor (PowerEvent) -> Void) {
        self.handler = handler
    }

    /// False when IOKit refused the registration; sleep and wake then go unrecorded.
    @discardableResult
    public func start() -> Bool {
        guard registration == nil else { return true }
        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        // A C callback can't capture, so the monitor travels as refcon. It is unretained: the registration is
        // released with the monitor and deregisters, so no notification arrives for a freed monitor.
        let root = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(), &port,
            { refcon, _, messageType, argument in
                guard let refcon else { return }
                MainActor.assumeIsolated {
                    Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
                        .receive(messageType, argument: Int(bitPattern: argument))
                }
            }, &notifier)
        guard root != 0, let port else { return false }
        IONotificationPortSetDispatchQueue(port, .main)
        registration = Registration(rootPort: root, notifyPort: port, notifier: notifier)
        return true
    }

    private func receive(_ messageType: natural_t, argument: Int) {
        switch messageType {
        case Message.canSystemSleep:
            allow(argument)
        case Message.systemWillSleep:
            // The handler runs before the acknowledgement, so whatever it flushes is on disk before sleep.
            handler(.willSleep(Date().timeIntervalSince1970))
            allow(argument)
        case Message.systemHasPoweredOn:
            handler(.didWake(Date().timeIntervalSince1970))
        default:
            break
        }
    }

    private func allow(_ argument: Int) {
        guard let registration else { return }
        IOAllowPowerChange(registration.rootPort, argument)
    }
}

// Owns the IOKit handles. It is not main-actor isolated, so its deinit can release them; a main-actor class's
// deinit can't touch its non-Sendable stored properties.
private final class Registration {
    let rootPort: io_connect_t
    let notifyPort: IONotificationPortRef
    var notifier: io_object_t

    init(rootPort: io_connect_t, notifyPort: IONotificationPortRef, notifier: io_object_t) {
        self.rootPort = rootPort
        self.notifyPort = notifyPort
        self.notifier = notifier
    }

    deinit {
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(rootPort)
        IONotificationPortDestroy(notifyPort)
    }
}

/// Finds new jetsam and hang reports. Only report kinds and file names are returned, never their contents.
public struct DiagnosticScanner {
    private let directories: [URL]
    // Files already returned that are still newer than the last `since`, so an overlapping rescan skips them.
    private var reported: Set<String> = []

    public init(directories: [URL]) {
        self.directories = directories
    }

    public mutating func scan(since: Date) -> [(kind: String, ts: Double, file: String)] {
        var found: [(kind: String, ts: Double, file: String)] = []
        var stillRecent: Set<String> = []
        let fm = FileManager.default
        for directory in directories {
            guard
                let urls = try? fm.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles])
            else { continue }
            for url in urls {
                let name = url.lastPathComponent
                guard let kind = Self.kind(of: name),
                    let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate,
                    modified > since
                else { continue }
                stillRecent.insert(url.path)
                if !reported.contains(url.path) {
                    found.append((kind: kind, ts: modified.timeIntervalSince1970, file: name))
                }
            }
        }
        reported = stillRecent
        return found
    }

    /// The event a report is recorded as. The file name stays out: hang reports are named after the app.
    public static func event(
        for report: (kind: String, ts: Double, file: String)
    ) -> (kind: String, ts: Double, payload: [String: String]) {
        (kind: report.kind, ts: report.ts, payload: [:])
    }

    private static func kind(of name: String) -> String? {
        if name.hasPrefix("JetsamEvent-") && name.hasSuffix(".ips") { return "jetsam" }
        if name.hasSuffix(".hang") || name.hasSuffix(".spin") { return "hang" }
        return nil
    }
}

import Darwin
import Foundation

public enum GapDetector {
    /// Shorter stretches are an ordinary restart: a heartbeat is up to 60 s old, plus launchd's restart throttle.
    static let minimumGap = 120.0

    /// The time the machine was awake while the recorder wasn't running, or nil when there was none worth recording.
    /// The kernel only remembers the last sleep and wake, so a gap event never covers that sleep: when it splits the
    /// absence, the longer awake stretch is the gap, and it must on its own reach the minimum.
    public static func startupGap(
        lastHeartbeat: Double?, now: Double, bootTime: Double, lastSleep: Double?, lastWake: Double?
    ) -> DateInterval? {
        guard let lastHeartbeat, now > lastHeartbeat, bootTime <= lastHeartbeat else { return nil }
        var stretches = [(lastHeartbeat, now)]
        if let lastSleep, let lastWake, lastWake > lastSleep, lastWake > lastHeartbeat, lastSleep < now {
            stretches = [(lastHeartbeat, max(lastHeartbeat, lastSleep)), (min(now, lastWake), now)]
        }
        guard let longest = stretches.max(by: { $0.1 - $0.0 < $1.1 - $1.0 }), longest.1 - longest.0 >= minimumGap
        else { return nil }
        return DateInterval(start: Date(timeIntervalSince1970: longest.0), end: Date(timeIntervalSince1970: longest.1))
    }

    public static func bootTime() -> Double {
        sysctlTime("kern.boottime") ?? 0
    }

    public static func lastSleepWake() -> (sleep: Double?, wake: Double?) {
        (sysctlTime("kern.sleeptime"), sysctlTime("kern.waketime"))
    }

    /// Nil when the sysctl is missing or zero (no sleep since boot).
    private static func sysctlTime(_ name: String) -> Double? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Double(value.tv_sec) + Double(value.tv_usec) / 1e6
    }
}

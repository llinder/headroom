import Foundation
import IOKit.ps

public struct BatteryReading: Sendable, Equatable {
    /// 0–100.
    public var percent: UInt8
    public var charging: Bool
    public var onAC: Bool

    public init(percent: UInt8, charging: Bool, onAC: Bool) {
        self.percent = percent
        self.charging = charging
        self.onAC = onAC
    }
}

public enum BatterySampler {
    /// The internal battery, or nil on a Mac without one. One call to powerd, about 40 µs on an M4 Pro.
    public static func read() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        // The description follows the get rule: it belongs to `info`, so it isn't released here.
        return reading(from: list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        })
    }

    // Split from read() so the parsing is testable without hardware. A UPS is also a power source, but its
    // charge isn't the machine's, so only an internal battery counts.
    static func reading(from descriptions: [[String: Any]]) -> BatteryReading? {
        for d in descriptions {
            guard d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                (d[kIOPSIsPresentKey] as? NSNumber)?.boolValue ?? true,
                let current = (d[kIOPSCurrentCapacityKey] as? NSNumber)?.intValue,
                let max = (d[kIOPSMaxCapacityKey] as? NSNumber)?.intValue, max > 0
            else { continue }
            // Apple silicon reports Max Capacity as 100, but other Macs report mAh. Clamping first keeps the
            // result in 0–100 whatever powerd says, and Double can't overflow on an absurd capacity.
            let capped = min(Swift.max(current, 0), max)
            return BatteryReading(
                percent: UInt8((Double(capped) / Double(max) * 100).rounded()),
                charging: (d[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false,
                onAC: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
}

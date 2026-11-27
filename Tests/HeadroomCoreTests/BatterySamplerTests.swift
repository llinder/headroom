import Foundation
import Testing

@testable import HeadroomCore

@Suite struct BatterySamplerTests {
    // The keys and values IOPSGetPowerSourceDescription returned on an M4 Pro MacBook running on battery.
    private func battery(
        current: Any = 63, max: Any = 100, charging: Any = false, state: String = "Battery Power",
        present: Any = true, type: String = "InternalBattery"
    ) -> [String: Any] {
        [
            "Type": type, "Name": "InternalBattery-0", "Transport Type": "Internal", "Is Present": present,
            "Current Capacity": current, "Max Capacity": max, "Is Charging": charging,
            "Power Source State": state, "Time to Empty": 855, "Current": -150,
        ]
    }

    @Test func dischargingOnBattery() {
        #expect(BatterySampler.reading(from: [battery()]) == BatteryReading(percent: 63, charging: false, onAC: false))
    }

    @Test func chargingOnAC() {
        let d = battery(current: 41, charging: true, state: "AC Power")
        #expect(BatterySampler.reading(from: [d]) == BatteryReading(percent: 41, charging: true, onAC: true))
    }

    @Test func fullOnAC() {
        let d = battery(current: 100, charging: false, state: "AC Power")
        #expect(BatterySampler.reading(from: [d]) == BatteryReading(percent: 100, charging: false, onAC: true))
    }

    // Booleans come back from IOKit as CFBoolean, but a 0/1 CFNumber must read the same.
    @Test func numericFlags() {
        let d = battery(charging: NSNumber(value: 1), present: NSNumber(value: 1))
        #expect(BatterySampler.reading(from: [d])?.charging == true)
    }

    @Test func capacityInMilliampHours() {
        #expect(BatterySampler.reading(from: [battery(current: 4_480, max: 5_000)])?.percent == 90)
        #expect(BatterySampler.reading(from: [battery(current: 4_475, max: 5_000)])?.percent == 90)
        #expect(BatterySampler.reading(from: [battery(current: 4_474, max: 5_000)])?.percent == 89)
    }

    @Test func outOfRangeCapacityClamps() {
        #expect(BatterySampler.reading(from: [battery(current: 130)])?.percent == 100)
        #expect(BatterySampler.reading(from: [battery(current: -5)])?.percent == 0)
        #expect(BatterySampler.reading(from: [battery(current: Int.max, max: Int.max)])?.percent == 100)
    }

    @Test func noUsableBattery() {
        #expect(BatterySampler.reading(from: []) == nil)
        #expect(BatterySampler.reading(from: [battery(max: 0)]) == nil)
        #expect(BatterySampler.reading(from: [battery(present: false)]) == nil)
        #expect(BatterySampler.reading(from: [battery(current: "63")]) == nil)
        var missing = battery()
        missing["Current Capacity"] = nil
        #expect(BatterySampler.reading(from: [missing]) == nil)
    }

    @Test func upsIsNotTheBattery() {
        let ups = battery(current: 30, state: "AC Power", type: "UPS")
        #expect(BatterySampler.reading(from: [ups]) == nil)
        #expect(BatterySampler.reading(from: [ups, battery()])?.percent == 63)
    }

    @Test func liveReadIsInRange() {
        // Nil on a Mac without a battery; otherwise a valid level.
        if let reading = BatterySampler.read() { #expect(reading.percent <= 100) }
    }
}

import Foundation
import Testing
@testable import HeadroomCore

@Suite struct ConfigTests {
    private func write(_ text: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-config-\(UUID().uuidString).json")
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    @Test func configPartialFile() throws {
        let url = try write(#"{"limits":{"cpuSaturatedFraction":0.8}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let (config, warning) = HeadroomConfig.load(from: url)
        #expect(warning == nil)
        #expect(config.limits.cpuSaturatedFraction == 0.8)
        #expect(config.limits.loadPerCoreMultiplier == 2.0)
        #expect(config.workdayMinAwakeSeconds == 7200)
    }

    @Test func configInvalidFile() throws {
        let url = try write("{nope")
        defer { try? FileManager.default.removeItem(at: url) }
        let (config, warning) = HeadroomConfig.load(from: url)
        #expect(config == HeadroomConfig())
        #expect(warning != nil)
    }

    @Test func configMissingFile() throws {
        let (config, warning) = HeadroomConfig.load(from: try write(nil))
        #expect(config == HeadroomConfig())
        #expect(warning == nil)
    }

    @Test func agentsDefaultsAndPartial() throws {
        let defaults = HeadroomConfig().agents
        #expect(defaults.adviceMinutes == 5)
        #expect(defaults.swapGrowthBytesPerMin == 268_435_456)
        #expect(defaults.heavyCommands.count == 22)
        #expect(defaults.heavyCommands.contains("go test"))

        let url = try write(#"{"agents":{"adviceMinutes":2,"heavyCommands":["make"]}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let (config, warning) = HeadroomConfig.load(from: url)
        #expect(warning == nil)
        #expect(config.agents.adviceMinutes == 2)
        #expect(config.agents.heavyCommands == ["make"])
        #expect(config.agents.swapGrowthBytesPerMin == 268_435_456)
    }

    @Test func hugeLeftoverMinutesAreClamped() throws {
        let url = try write(#"{"leftovers":{"afterMinutes":1e18}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let (config, warning) = HeadroomConfig.load(from: url)
        #expect(warning == nil)
        #expect(config.leftovers.afterMinutes == 44_640)

        let negative = try write(#"{"leftovers":{"afterMinutes":-5}}"#)
        defer { try? FileManager.default.removeItem(at: negative) }
        #expect(HeadroomConfig.load(from: negative).0.leftovers.afterMinutes == 0)
    }
}

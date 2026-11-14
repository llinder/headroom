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
}

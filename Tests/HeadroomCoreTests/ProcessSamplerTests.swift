import Darwin
import Foundation
import Testing

@testable import HeadroomCore

@Suite struct ProcessSamplerTests {
    @Test func timebaseConversion() {
        let timebase = mach_timebase_info_data_t(numer: 125, denom: 3)
        let seconds = ProcessSampler.cpuSeconds(userNs: 24, systemNs: 0, timebase: timebase)
        #expect(abs(seconds - 1000e-9) < 1e-15)
    }

    @Test func selfAppearsAttributed() {
        var sampler = ProcessSampler()
        _ = sampler.sweep()
        let me = sampler.sweep().first { $0.identity.key.pid == getpid() }
        #expect(me != nil)
        #expect(me?.attributed == true)
        #expect((me?.footprint ?? 0) > 0)
        #expect(me?.identity.name.isEmpty == false)
    }

    @Test func firstSightHasZeroDelta() {
        var sampler = ProcessSampler()
        let usages = sampler.sweep()
        #expect(!usages.isEmpty)
        #expect(usages.allSatisfy { $0.cpuSeconds == 0 })
    }

    @Test func pidReuseStartsFresh() {
        let old = ProcessKey(pid: 42, start: 1)
        let reused = ProcessKey(pid: 42, start: 2)
        let previous = [old: ProcessSampler.Totals(cpu: 5.0, diskRead: 0, diskWrite: 0)]
        #expect(ProcessSampler.delta(previous: previous, key: reused, total: 1.0) == 0)
        #expect(ProcessSampler.delta(previous: previous, key: old, total: 7.0) == 2.0)
    }

    @Test func burnShowsCPU() async {
        var sampler = ProcessSampler()
        _ = sampler.sweep()
        await withCheckedContinuation { continuation in
            let thread = Thread {
                let deadline = Date().addingTimeInterval(0.3)
                var x = 1.0
                while Date() < deadline { x = x * 1.0000001 + 0.1 }
                if x < 0 { print(x) }
                continuation.resume()
            }
            thread.start()
        }
        let me = sampler.sweep().first { $0.identity.key.pid == getpid() }
        #expect((me?.cpuSeconds ?? 0) >= 0.2)
    }
}

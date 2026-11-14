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
        #expect(ProcessSampler.delta(previous: previous, key: reused, total: 1.0, previousSweep: nil) == 0)
        #expect(ProcessSampler.delta(previous: previous, key: old, total: 7.0, previousSweep: nil) == 2.0)
    }

    @Test func processBornSinceThePreviousSweepIsCreditedItsWholeTotal() {
        let born = ProcessKey(pid: 7, start: 2_000)
        #expect(ProcessSampler.delta(previous: [:], key: born, total: 3.5, previousSweep: 1_500) == 3.5)
        #expect(ProcessSampler.delta(previous: [:], key: born, total: 3.5, previousSweep: 2_000) == 3.5)
        #expect(ProcessSampler.writeDelta(prior: nil, key: born, total: 4096, previousSweep: 1_500) == 4096)
    }

    @Test func processThatExistedBeforeTheFirstSweepGetsZero() {
        let existing = ProcessKey(pid: 7, start: 1_000)
        #expect(ProcessSampler.delta(previous: [:], key: existing, total: 3.5, previousSweep: 1_500) == 0)
        #expect(ProcessSampler.delta(previous: [:], key: existing, total: 3.5, previousSweep: nil) == 0)
        #expect(ProcessSampler.writeDelta(prior: nil, key: existing, total: 4096, previousSweep: 1_500) == 0)
        #expect(ProcessSampler.writeDelta(prior: nil, key: existing, total: 4096, previousSweep: nil) == 0)
    }

    @Test func childSpawnedBetweenSweepsIsCredited() throws {
        var sampler = ProcessSampler()
        _ = sampler.sweep()
        var pid: pid_t = 0
        let script = "i=0; while [ $i -lt 1000000 ]; do i=$((i+1)); done"
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sh"), strdup("-c"), strdup(script), nil]
        defer { argv.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/bin/sh", nil, nil, argv, environ) == 0)
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, Self.cpuTicks(pid) < 1_000_000 { usleep(10_000) }
        let usage = try #require(sampler.sweep().first { $0.identity.key.pid == pid })
        #expect(usage.cpuSeconds > 0)
    }

    private static func cpuTicks(_ pid: pid_t) -> UInt64 {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return status == 0 ? info.ri_user_time + info.ri_system_time : 0
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

    // Restricted environments deny PROC_PIDTBSDINFO for many pids (EPERM), and those can't be keyed, so
    // coverage is measured against the pids an independent probe can inspect rather than the raw list.
    @Test func sweepCoversAllProcesses() {
        var sampler = ProcessSampler()
        let usages = sampler.sweep()

        var listed = [Int32](repeating: 0, count: Int(proc_listallpids(nil, 0)) * 2)
        let bytes = Int32(listed.count * MemoryLayout<Int32>.stride)
        let count = Int(listed.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) })
        let keyable = listed[..<count].filter { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            return pid > 0 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size
        }.sorted()

        #expect(usages.count >= keyable.count * 8 / 10)
        let sweptMax = usages.map(\.identity.key.pid).max() ?? 0
        #expect(sweptMax >= keyable[keyable.count * 9 / 10])
    }

    @Test func exitedProcessIsEvicted() throws {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/bin/sleep", nil, nil, argv, environ) == 0)

        var sampler = ProcessSampler()
        let child = try #require(sampler.sweep().first { $0.identity.key.pid == pid }?.identity.key)
        #expect(sampler.isTracked(child))

        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        _ = sampler.sweep()
        #expect(!sampler.isTracked(child))
    }
}

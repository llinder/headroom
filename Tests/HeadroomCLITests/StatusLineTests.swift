import Darwin
import Foundation
import Testing

@testable import HeadroomCLI
@testable import HeadroomCore

private let now = 1_800_000_000.0

private func snapshot(
    timestamp: Double = now, mem: Double = 0.82, swap: UInt64 = 14 * (1 << 30), cpu: Float = 0.71,
    pressure: UInt8 = 2, agents: UInt16 = 3, leftovers: UInt16 = 0, leftoverBytes: UInt64 = 0,
    battery: BatteryReading? = nil
) -> LiveSnapshot {
    LiveSnapshot(
        timestamp: timestamp, cpuBusy: cpu, memUsed: UInt64(mem * 1000), memTotal: 1000, swapUsed: swap,
        diskFree: 583_000_000_000, diskCapacity: 1_000_000_000_000, pressure: pressure, thermal: 0, limitFlags: 0,
        activeAgents: agents, idleAgents: 0, leftoverCount: leftovers, leftoverBytes: leftoverBytes, battery: battery)
}

private func bat(_ percent: UInt8, charging: Bool = false, onAC: Bool = false) -> BatteryReading {
    BatteryReading(percent: percent, charging: charging, onAC: onAC)
}

private func render(_ s: LiveSnapshot?, color: Bool = false, quiet: Bool = false, template: String = StatusLineFormatter.defaultTemplate) -> String {
    StatusLineFormatter.format(s, now: now, template: template, color: color, quiet: quiet)
}

@Suite struct StatusLineTests {
    @Test func defaultFormat() {
        #expect(render(snapshot()) == "mem 82% ⚠ swap 14G · cpu 71% · disk 417G · 3 agents")
    }

    @Test func zeroSwapOmitsToken() {
        let s = snapshot(mem: 0.40, swap: 0, cpu: 0.05, pressure: 1, agents: 0)
        #expect(render(s) == "mem 40% · cpu 5% · disk 417G · 0 agents")
    }

    @Test func singularAgent() {
        #expect(render(snapshot(agents: 1), template: "{agents}") == "1 agent")
    }

    @Test func emptySegmentsLeaveNoSeparators() {
        let s = snapshot(swap: 0)
        #expect(render(s, template: "{swap} · {cpu} · {swap}") == "cpu 71%")
        #expect(render(s, template: "{swap}") == "")
    }

    @Test func unknownTokensStayLiteral() {
        #expect(render(snapshot(), template: "{cpu} {nope}") == "cpu 71% {nope}")
    }

    @Test func garbageSnapshotNeverTraps() {
        for cpu in [Float.nan, .infinity, -.infinity, 1e30] {
            #expect(!render(snapshot(cpu: cpu)).isEmpty)
        }
        var s = snapshot()
        s.memTotal = 0
        #expect(render(s).hasPrefix("mem 0%"))
        s.memTotal = 1
        s.memUsed = .max
        #expect(!render(s).isEmpty)
        s.swapUsed = .max
        s.diskCapacity = 1
        s.diskFree = .max
        #expect(render(s).contains("disk 0G"))
    }

    @Test func fractionalValuesRound() {
        var s = snapshot(mem: 0.826, swap: UInt64(13.6 * Double(1 << 30)))
        s.diskCapacity = 1_000_000_000_000
        s.diskFree = 1_000_000_000_000 - 417_600_000_000
        #expect(render(s, template: "{mem} · {swap} · {disk}") == "mem 83% ⚠ · swap 14G · disk 418G")
    }

    @Test func staleIsOff() {
        let old = snapshot(timestamp: now - 61)
        #expect(render(old) == "headroom: off")
        #expect(render(old, quiet: true) == "")
        #expect(render(snapshot(timestamp: now - 60), template: "{cpu}") == "cpu 71%")
    }

    @Test func nilIsOff() {
        #expect(render(nil) == "headroom: off")
        #expect(render(nil, quiet: true) == "")
    }

    @Test func colorCritical() {
        let out = render(snapshot(pressure: 4), color: true, template: "{mem} {cpu}")
        #expect(out == "\u{1B}[31mmem 82% ⚠\u{1B}[0m cpu 71%")
    }

    @Test func colorWarn() {
        #expect(render(snapshot(pressure: 2), color: true, template: "{mem}") == "\u{1B}[33mmem 82% ⚠\u{1B}[0m")
    }

    @Test func noColorWhenNormal() {
        #expect(render(snapshot(pressure: 1), color: true, template: "{mem}") == "mem 82%")
    }
}

@Suite struct StatusLineBatteryTests {
    private let amber = "\u{1B}[33m"
    private let red = "\u{1B}[31m"
    private let reset = "\u{1B}[0m"

    @Test func percentOnBattery() {
        #expect(render(snapshot(battery: bat(68)), template: "{battery}") == "bat 68%")
        #expect(render(snapshot(battery: bat(0)), template: "{battery}") == "bat 0%", "a flat battery still shows")
    }

    @Test func chargingShowsBolt() {
        #expect(render(snapshot(battery: bat(68, charging: true, onAC: true)), template: "{battery}") == "bat 68% ⚡")
    }

    @Test func fullOnACIsPlain() {
        #expect(render(snapshot(battery: bat(100, onAC: true)), template: "{battery}") == "bat 100%")
        // Some reports keep the charging flag at 100%; there is nothing left to charge.
        #expect(render(snapshot(battery: bat(100, charging: true, onAC: true)), template: "{battery}") == "bat 100%")
        #expect(render(snapshot(battery: bat(80, onAC: true)), template: "{battery}") == "bat 80%", "charge held at a limit")
    }

    @Test func lowAndCriticalColourOnBattery() {
        #expect(render(snapshot(battery: bat(21)), color: true, template: "{battery}") == "bat 21%")
        #expect(render(snapshot(battery: bat(20)), color: true, template: "{battery}") == "\(amber)bat 20%\(reset)")
        #expect(render(snapshot(battery: bat(11)), color: true, template: "{battery}") == "\(amber)bat 11%\(reset)")
        #expect(render(snapshot(battery: bat(10)), color: true, template: "{battery}") == "\(red)bat 10%\(reset)")
        #expect(render(snapshot(battery: bat(0)), color: true, template: "{battery}") == "\(red)bat 0%\(reset)")
    }

    @Test func lowIsUncolouredWhenChargingOrOnAC() {
        #expect(render(snapshot(battery: bat(8, charging: true, onAC: true)), color: true, template: "{battery}") == "bat 8% ⚡")
        #expect(render(snapshot(battery: bat(8, onAC: true)), color: true, template: "{battery}") == "bat 8%")
        #expect(render(snapshot(battery: bat(8, charging: true)), color: true, template: "{battery}") == "bat 8% ⚡")
    }

    @Test func lowIsUncolouredWithNoColor() {
        #expect(render(snapshot(battery: bat(5)), color: false, template: "{battery}") == "bat 5%")
    }

    @Test func noBatteryDropsTheSegment() {
        #expect(render(snapshot(), template: "{battery}") == "")
        #expect(render(snapshot(), template: "{cpu} · {battery} · {agents}") == "cpu 71% · 3 agents")
        #expect(render(snapshot()) == "mem 82% ⚠ swap 14G · cpu 71% · disk 417G · 3 agents")
    }

    @Test func defaultTemplatePlacesBatteryAfterDisk() {
        #expect(render(snapshot(battery: bat(68, charging: true, onAC: true)))
            == "mem 82% ⚠ swap 14G · cpu 71% · disk 417G · bat 68% ⚡ · 3 agents")
    }

    @Test func staleSnapshotIsOffEvenWithBattery() {
        let old = snapshot(timestamp: now - 61, battery: bat(5))
        #expect(render(old, color: true) == "headroom: off")
        #expect(render(old, quiet: true) == "")
    }

    @Test func garbagePercentClamps() {
        #expect(render(snapshot(battery: bat(255)), template: "{battery}") == "bat 100%")
    }
}

private let binary: URL? = {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    // Release only: an unoptimised binary's startup sits right at the budget and would make this flaky.
    let release = root.appending(path: ".build/release/headroom")
    return FileManager.default.isExecutableFile(atPath: release.path) ? release : nil
}()

@Suite struct StatusLineSpeedTests {
    // Wall-clock budgets are flaky on a loaded machine, so they only run under `make bench`.
    @Test(.enabled(if: binary != nil), .enabled(if: ProcessInfo.processInfo.environment["HEADROOM_BENCH"] == "1", "wall-clock budget; run via make bench")) func statuslineSpeed() throws {
        let exe = try #require(binary)
        let dir = FileManager.default.temporaryDirectory.appending(path: "headroom-sl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var writer = try LiveStateWriter(url: Paths(root: dir).liveState)
        writer.write(snapshot(timestamp: Date().timeIntervalSince1970, battery: bat(15)))

        var times: [Double] = []
        for _ in 0..<200 {
            var fileActions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&fileActions)
            posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe.path), strdup("statusline"), nil]
            let envp: [UnsafeMutablePointer<CChar>?] = [strdup("HEADROOM_ROOT=\(dir.path)"), nil]
            defer { (argv + envp).forEach { free($0) } }

            let start = DispatchTime.now().uptimeNanoseconds
            var pid: pid_t = 0
            #expect(posix_spawn(&pid, exe.path, &fileActions, nil, argv, envp) == 0)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            #expect(status == 0)
        }
        times.sort()
        let median = times[times.count / 2]
        print("statusline median wall time: \(median) ms (\(exe.path))")
        #expect(median < 5)
    }

    @Test func leftoversTokenSingularPlural() {
        #expect(render(snapshot(leftovers: 1, leftoverBytes: 1_250_000_000), template: "{leftovers}") == "⚑ 1 leftover · 1.3 GB")
        #expect(render(snapshot(leftovers: 3, leftoverBytes: 0), template: "{leftovers}") == "⚑ 3 leftovers")
        #expect(render(snapshot(leftovers: 1, leftoverBytes: 0), template: "{leftovers}") == "⚑ 1 leftover",
                "memory not read yet is left out, not shown as 0.0 GB")
    }

    @Test func leftoversTokenClampsHugeBytes() {
        #expect(!render(snapshot(leftovers: 2, leftoverBytes: .max), template: "{leftovers}").isEmpty)
    }

    @Test func emptyWhenNone() {
        #expect(render(snapshot(), template: "{leftovers}") == "")
        #expect(render(snapshot(), template: "{cpu} · {leftovers}") == "cpu 71%")
    }

    @Test func defaultTemplateIncludesLeftovers() {
        #expect(render(snapshot(leftovers: 2, leftoverBytes: 4_000_000_000))
            == "mem 82% ⚠ swap 14G · cpu 71% · disk 417G · 3 agents · ⚑ 2 leftovers · 4.0 GB")
    }
}

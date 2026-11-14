# headroom Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build phase 1 of headroom. That covers the `headroomd` recorder, the SQLite store, the `headroom` CLI (`top`, `status`, `tag`, `report`, `install`/`uninstall`, `statusline`, `agent-hook`, `hook zsh`), agent-run tracking, agent capacity and the PDF capacity report.

**Architecture:** One SwiftPM package:
- `HeadroomCore`, a library holding all logic.
- `headroomd`, a LaunchAgent that is the only database writer. It runs on the main actor with one `DispatchSourceTimer`.
- `headroom`, the CLI and terminal UI.

Short-lived producers append JSON lines to a spool that headroomd ingests. headroomd also publishes a fixed-size `live.state` file for microsecond reads.

**Tech Stack:** Swift 6.1 (Swift 6 language mode), SwiftPM, Swift Testing (shipped with Command Line Tools; XCTest is not installed), SQLite3 from the macOS SDK, Darwin/Mach/libproc, IOKit, CryptoKit, CoreGraphics/CoreText. PDFKit is used in tests only.

**Spec:** `docs/superpowers/specs/2026-11-14-headroom-design.md`. Read it before any task. Phases 1.5 (pretool hook, MCP, leftovers) and 2 (menu bar) get their own plans.

## Global Constraints

- macOS 15+, Apple Silicon. `// swift-tools-version: 6.0`, `platforms: [.macOS(.v15)]`.
- **No third-party dependencies.** Apple frameworks and the SDK only. No swift-argument-parser, no swift-atomics.
- No global mutable state. Strict concurrency with no warnings. No `@unchecked Sendable`, no `nonisolated(unsafe)`.
- The recorder never spawns processes. Only the CLI may (`launchctl`, and `claude`/`codex` in phase 1.5).
- Privacy: never record window titles, URLs, document names, keystrokes, input idle time, focused-app time, command arguments or repo/directory names. Reports show workload groups only, never process names. Browsers, Communication and Other fold into **Everyday apps** in reports.
- App data directory: `~/Library/Application Support/headroom/`, holding `headroom.db`, `live.state`, `spool.jsonl`, `groups.json`, `config.json`, `tiers.json` and `baseline.json`.
- LaunchAgent label `io.github.llinder.headroom`, at `~/Library/LaunchAgents/io.github.llinder.headroom.plist`. Binaries go in `~/.local/bin`.
- Sampling every 10 s. DB flush every 60 s in one transaction. Raw 10 s tables keep 30 days; rollups, events, coverage and agent tables are kept forever.
- Footprint budget for headroomd: under 0.1% average of one core, under 15 MB footprint. `statusline` and `agent-hook` must take under 5 ms, and `statusline` aims for 2 ms. Both always exit 0.
- Only comments that explain *why*. No TODO or placeholder code.
- Commits have no `Claude-Session` trailer and no session URLs. The repo carries no personal or employer context.

## Review Focus

1. **PID reuse:** a pid that comes back with a new start time is a new process. It must never produce a negative or huge CPU delta, and it must not inherit the old group or agent run. Covered in Task 7.
2. **Counter resets after reboot, wake or driver reload:** SSD byte counters and Mach VM counters going backwards produce a 0 delta, never a wrapped UInt64. Covered in Tasks 3–5 through `counterDelta`.
3. **Bad user files:** an invalid `groups.json`, `config.json`, `tiers.json` or `baseline.json` must not stop the recorder or the report. headroomd falls back to defaults and logs one line. Covered in Tasks 8, 9 and 20.
4. **Malformed spool lines:** a truncated, oversized or garbage line is skipped and counted, and later lines are still ingested. A spool file that isn't there at all is normal. Covered in Task 10.
5. **Local-day boundaries across DST and time-zone changes:** timestamps are stored as UTC epoch seconds. Days are computed in the current time zone at query time, so a 23-hour or 25-hour day still counts as one day. Covered in Task 20.

---

## File structure

```
Package.swift
Makefile
README.md  LICENSE (MIT)  .gitignore
examples/baseline.example.json
Sources/HeadroomCore/
  Paths.swift                     app-data locations
  Config.swift                    HeadroomConfig + LimitConfig (config.json)
  Store/Database.swift            thin SQLite wrapper
  Store/Schema.swift              migrations
  Store/SampleStore.swift         buffered writer, rollups, retention, coverage rows
  Store/Queries.swift             read-only queries for CLI/report
  Sampling/Counters.swift         counterDelta
  Sampling/CPUSampler.swift
  Sampling/MemorySampler.swift
  Sampling/DiskSampler.swift
  Sampling/MachineInfo.swift
  Sampling/ProcessSampler.swift
  Sampling/SystemEvents.swift     power notifications, thermal, DiagnosticReports scan
  Classify/GroupRules.swift
  Classify/Classifier.swift
  Agents/AgentTracker.swift
  Limits/LimitEvaluator.swift
  IPC/Spool.swift
  IPC/LiveState.swift
  Coverage/GapDetector.swift
  Analysis/Workdays.swift  Analysis/Verdicts.swift  Analysis/AgentCapacity.swift
  Analysis/SpecRecommender.swift  Analysis/Tiers.swift  Analysis/Baseline.swift
  Report/ReportModel.swift  Report/PDFReport.swift  Report/Charts.swift
Sources/headroomd/main.swift  Sources/headroomd/Recorder.swift
Sources/headroom/main.swift      thin: calls HeadroomCLI.run (from Task 15)
Sources/HeadroomCLI/CommandLine.swift
Sources/HeadroomCLI/Commands/{Status,Tag,Install,StatusLine,AgentHook,ShellHook,Report}.swift
Sources/HeadroomCLI/TUI/{Terminal,TopRenderer,TopCommand}.swift
Tests/HeadroomCoreTests/…Tests.swift (one file per Core file under test)
Tests/HeadroomCLITests/…Tests.swift
```

Facts already checked on the dev machine (macOS 26.4, CLT Swift 6.1.2):
- The SDK defines `RUSAGE_INFO_V6`.
- `kern.memorystatus_vm_pressure_level`, `kern.memorystatus_level` and `vm.swapusage` are readable without root.
- `/Library/Logs/DiagnosticReports` is listable by an admin user.
- Swift Testing is at `/Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework`.

---

### Task 1: Repository and package scaffold

**Files:**
- Create: `Package.swift`, `Makefile`, `README.md`, `LICENSE`, `.gitignore`, `Sources/HeadroomCore/Paths.swift`, `Sources/headroomd/main.swift`, `Sources/headroom/main.swift`, `Tests/HeadroomCoreTests/PathsTests.swift`

**Interfaces:**
- Produces:
  - `public struct Paths: Sendable { public let root: URL; public init(root: URL); public static func standard() -> Paths; public var database, liveState, spool, groups, config, tiers, baseline: URL { get }; public func ensureRoot() throws }`
  - The package's library and executable targets.

- [ ] **Step 1:** In `~/git/llinder/headroom`, run `git init -b main` and `git remote add origin https://github.com/llinder/headroom.git`. The spec and this plan already exist under `docs/`.
- [ ] **Step 2: Write `Package.swift`.**
  - Targets: `HeadroomCore` (linker settings `.linkedLibrary("sqlite3")`, `.linkedFramework("IOKit")`), `headroomd` and `headroom` (both depend on `HeadroomCore`), and `HeadroomCoreTests`.
  - `swiftSettings: [.enableUpcomingFeature("ExistentialAny")]` on all targets.
- [ ] **Step 3: Write the failing test** `@Test func pathsLayout()`. With `Paths(root: URL(filePath: "/tmp/hr"))`, assert `database.path == "/tmp/hr/headroom.db"`, `liveState.lastPathComponent == "live.state"`, `spool.lastPathComponent == "spool.jsonl"`, and likewise for `groups.json`, `config.json`, `tiers.json` and `baseline.json`.
- [ ] **Step 4:** Run `swift test --filter PathsTests`. Expected: FAIL to compile, because `Paths` doesn't exist.
- [ ] **Step 5: Implement `Paths`.** `standard()` uses `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "headroom")`. The `main.swift` files print `headroom 0.1.0` for now.
- [ ] **Step 6:** Run `swift test`. Expected: PASS.
- [ ] **Step 7: Write the supporting files.**
  - `Makefile`: `build` runs `swift build -c release`; `test` runs `swift test`; `install` runs `build` then `.build/release/headroom install`.
  - `README.md`: the spec's Intent, the install steps and the privacy promises. No personal context.
  - `LICENSE`: MIT.
  - `.gitignore`: `.build/` and `*.db`.
- [ ] **Step 8:** Commit with message `chore: scaffold headroom package`, including `docs/`.

### Task 2: SQLite wrapper and schema v1

**Files:**
- Create: `Sources/HeadroomCore/Store/Database.swift`, `Sources/HeadroomCore/Store/Schema.swift`, `Tests/HeadroomCoreTests/DatabaseTests.swift`

**Interfaces:**
- Produces:
  - `public final class Database { public init(path: String, readOnly: Bool) throws(DatabaseError); public func exec(_ sql: String) throws(DatabaseError); public func prepare(_ sql: String) throws(DatabaseError) -> Statement; public func transaction(_ body: () throws -> Void) throws }`. It is not `Sendable`; one owner at a time.
  - `public final class Statement { func bind(_ i: Int32, _ v: Int64?); bind(_ i: Int32, _ v: Double?); bind(_ i: Int32, _ v: String?); bind(_ i: Int32, _ v: Data?); func step() throws(DatabaseError) -> Bool; func int64(_ col: Int32) -> Int64; double; string; data; isNull; func reset() }`
  - `public enum DatabaseError: Error, Equatable { case open(String), sqlite(code: Int32, message: String) }`
  - `public enum Schema { public static let version = 1; public static func migrate(_ db: Database) throws }`

- [ ] **Step 1: Write the failing tests.**
  - `migrateCreatesAllTables`: on a temp-file DB, `migrate` then `SELECT name FROM sqlite_master WHERE type='table'` contains `machines, samples, group_samples, top_procs_1m, rollup, limit_seconds, agent_histogram, events, coverage, agent_runs, agent_run_sessions, run_usage, meta`. `PRAGMA journal_mode` returns `wal`.
  - `migrateIsIdempotent`: calling `migrate` twice leaves `meta.schema_version` at `"1"`.
  - `readOnlyRejectsWrites`: opening `readOnly: true` and calling `exec("INSERT INTO meta VALUES('k','v')")` throws `.sqlite`.
- [ ] **Step 2:** Run `swift test --filter DatabaseTests`. Expected: FAIL.
- [ ] **Step 3: Implement the wrapper and schema.**
  - Opening: `sqlite3_open_v2` with `SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE` or `SQLITE_OPEN_READONLY`, then `busy_timeout=50`. For read-write handles: `journal_mode=WAL`, `synchronous=NORMAL`.
  - Strings bind with `SQLITE_TRANSIENT` (`unsafeBitCast(-1, to: sqlite3_destructor_type.self)`).
  - Migrations are an array of SQL strings applied in a transaction, with the version kept in `meta`.
  - Schema v1 columns (every time-series table leads with `machine_id TEXT NOT NULL, ts INTEGER NOT NULL`, where ts is UTC epoch seconds):
    - `machines(machine_id PK, model, serial_hash, perf_cores, eff_cores, ram_bytes, disk_bytes, first_seen, last_seen)`
    - `samples(…, cpu_user REAL, cpu_sys REAL, per_core BLOB, load1, load5, load15 REAL, mem_total, mem_used, mem_app, mem_wired, mem_compressed, mem_free INTEGER, pressure INTEGER, memorystatus_level INTEGER NULL, swap_used, swap_total, swapins, swapouts, pageins, pageouts, ssd_read, ssd_write, disk_free, disk_capacity INTEGER, thermal INTEGER, limit_flags INTEGER, active_agents, idle_agents INTEGER, self_cpu REAL, self_footprint INTEGER)` with `PRIMARY KEY(machine_id, ts)`
    - `group_samples(…, group_id TEXT, cpu_seconds REAL, footprint INTEGER, disk_write INTEGER, proc_count INTEGER)`
    - `top_procs_1m(…, kind TEXT, rank INTEGER, name TEXT, group_id TEXT, value REAL)`
    - `rollup(machine_id, resolution INTEGER /*60|3600*/, ts, metric TEXT, avg REAL, max REAL, p95 REAL, PRIMARY KEY(machine_id,resolution,ts,metric))`
    - `limit_seconds(machine_id, resolution, ts, kind TEXT, seconds REAL, PK(...,kind))`
    - `agent_histogram(machine_id, ts /*hour*/, active_agents INTEGER, seconds REAL, memory_limited REAL, cpu_saturated REAL, PK(machine_id, ts, active_agents))`
    - `events(…, kind TEXT, payload TEXT)`
    - `coverage(machine_id, day TEXT /*YYYY-MM-DD local*/, seconds_recorded REAL, seconds_asleep REAL, seconds_gap REAL, gaps TEXT, PK(machine_id, day))`
    - `agent_runs(run_id INTEGER PK AUTOINCREMENT, machine_id, tool TEXT, root_pid INTEGER, root_start INTEGER, started INTEGER, ended INTEGER NULL, UNIQUE(machine_id, root_pid, root_start))`
    - `agent_run_sessions(run_id, session_id TEXT, model TEXT NULL, first_seen INTEGER, PK(run_id, session_id))`
    - `run_usage(run_id, ts /*minute*/, cpu_seconds REAL, peak_footprint INTEGER, disk_write INTEGER, active_seconds REAL, PK(run_id, ts))`
    - `meta(key PK, value)`
  - Indexes on `(machine_id, ts)` for `group_samples`, `top_procs_1m` and `events`.
- [ ] **Step 4:** Run `swift test --filter DatabaseTests`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(store): sqlite wrapper and schema v1`.

### Task 3: Counters, CPU and load sampler

**Files:**
- Create: `Sources/HeadroomCore/Sampling/Counters.swift`, `Sources/HeadroomCore/Sampling/CPUSampler.swift`, `Tests/HeadroomCoreTests/CPUSamplerTests.swift`

**Interfaces:**
- Produces:
  - `public func counterDelta(_ previous: UInt64, _ current: UInt64) -> UInt64`, which returns 0 when `current < previous`.
  - `public struct CoreTicks: Sendable, Equatable { user, system, idle, nice: UInt64 }`
  - `public struct CPUReading: Sendable, Equatable { user, system, idle: Double /*fractions of all cores, sum 1*/; perCoreBusy: [Double]; load1, load5, load15: Double; busySeconds: Double /*core-seconds busy in interval*/ }`
  - `public struct CPUSampler { public init(); public mutating func sample(interval: Double) -> CPUReading? /*nil on first call*/; public static func reading(previous: [CoreTicks], current: [CoreTicks], interval: Double, load: (Double, Double, Double)) -> CPUReading }`

- [ ] **Step 1: Write the failing tests.**
  - `counterDeltaResetsToZero`: `counterDelta(10, 3) == 0` and `counterDelta(3, 10) == 7`.
  - `readingFromTicks`: two cores, previous all 0, current `(user 30, system 10, idle 60, nice 0)` and `(0, 0, 100, 0)`, interval 1. Expected: `user == 0.15`, `system == 0.05`, `perCoreBusy == [0.4, 0.0]`, `busySeconds == 0.4`.
  - `tickResetIsNotNegative`: current ticks lower than previous produce `perCoreBusy[0] == 0` and `busySeconds == 0`.
  - `liveSamplerSmoke`: two `sample` calls 0.2 s apart. The first returns nil; the second has `perCoreBusy.count == ProcessInfo.processInfo.activeProcessorCount` and all fractions within `0...1`.
- [ ] **Step 2:** Run `swift test --filter CPUSamplerTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Use `host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, …)` and copy the ticks out.
  - Free the info array with `vm_deallocate` on every call.
  - Load averages come from `getloadavg`.
  - Busy is user + system + nice. Convert ticks to seconds as `busyFraction × interval` per core.
- [ ] **Step 4:** Run `swift test --filter CPUSamplerTests`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(sampling): cpu and load sampler`.

### Task 4: Memory, pressure and swap sampler

**Files:**
- Create: `Sources/HeadroomCore/Sampling/MemorySampler.swift`, `Tests/HeadroomCoreTests/MemorySamplerTests.swift`

**Interfaces:**
- Produces:
  - `public enum PressureLevel: Int, Sendable { case normal = 1, warn = 2, critical = 4 }`
  - `public struct VMCounters: Sendable, Equatable { free, active, inactive, wired, compressed /*compressor_page_count*/, purgeable, external /*file-backed*/, internalPages, swapins, swapouts, pageins, pageouts: UInt64 }`
  - `public struct MemoryReading: Sendable, Equatable { total, used, app, wired, compressed, free, fileBacked: UInt64; pressure: PressureLevel; memorystatusLevel: Int?; swapUsed, swapTotal: UInt64; swapins, swapouts, pageins, pageouts: UInt64 /*deltas, pages*/ }`
  - `public struct MemorySampler { public init(); public mutating func sample() -> MemoryReading; public static func reading(previous: VMCounters?, current: VMCounters, pageSize: UInt64, total: UInt64, pressure: PressureLevel, memorystatusLevel: Int?, swapUsed: UInt64, swapTotal: UInt64) -> MemoryReading }`

- [ ] **Step 1: Write the failing tests.**
  - `appMemoryFormula`: with pageSize 16384 and `internalPages 1000, purgeable 100, wired 200, compressed 300`, expect `app == (1000-100)*16384`, `used == app + 200*16384 + 300*16384`, and `fileBacked == external*16384`.
  - `firstReadingHasZeroDeltas`: `previous: nil` gives `swapins == 0` and `swapouts == 0`.
  - `deltasUseCounterDelta`: going from `swapouts 50` to `swapouts 20` gives 0.
  - `liveSmoke`: `sample().total == ProcessInfo.processInfo.physicalMemory`, `swapTotal >= swapUsed`, and `pressure` is one of the three cases.
- [ ] **Step 2:** Run `swift test --filter MemorySamplerTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Counters come from `host_statistics64(HOST_VM_INFO64)` (`vm_statistics64`, `HOST_VM_INFO64_COUNT`). Page size is `vm_kernel_page_size`.
  - App memory is `(internal_page_count − purgeable_count) × pageSize`, and used is app + wired + compressed. This matches Activity Monitor. Document the formula in a one-line doc comment.
  - Read pressure and level with `sysctlbyname` on `kern.memorystatus_vm_pressure_level` and `kern.memorystatus_level`. Read swap with `sysctlbyname("vm.swapusage")` into `xsw_usage`. An unknown pressure value maps to `.normal`, and a failed level read gives `nil`.
- [ ] **Step 4:** Run `swift test --filter MemorySamplerTests`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(sampling): memory, pressure and swap sampler`.

### Task 5: Disk space and SSD I/O sampler

**Files:**
- Create: `Sources/HeadroomCore/Sampling/DiskSampler.swift`, `Tests/HeadroomCoreTests/DiskSamplerTests.swift`

**Interfaces:**
- Produces:
  - `public struct DiskReading: Sendable, Equatable { capacity, free, availableImportant: UInt64; readBytes, writeBytes, readOps, writeOps: UInt64 /*deltas*/ }`
  - `public struct DiskSampler { public init(); public mutating func sample(refreshSpace: Bool) -> DiskReading }`. Space values carry over from the last refresh.
  - `static func ioTotals() -> (readBytes: UInt64, writeBytes: UInt64, readOps: UInt64, writeOps: UInt64)`, summed over all `IOBlockStorageDriver` services.

- [ ] **Step 1: Write the failing tests.**
  - `liveSmoke`: the first `sample(refreshSpace: true)` gives `capacity > 0`, `free <= capacity` and all I/O deltas `== 0`. After writing a 4 MB temp file with `F_NOCACHE` plus `fsync`, a second `sample(refreshSpace: false)` gives `writeBytes > 0` and `capacity` unchanged.
- [ ] **Step 2:** Run `swift test --filter DiskSamplerTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Space: `statfs("/System/Volumes/Data")` for capacity and free, and `URL(filePath: "/System/Volumes/Data").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])` for available.
  - I/O: `IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"))`. For each service read the `"Statistics"` dictionary keys `"Bytes (Read)"`, `"Bytes (Write)"`, `"Operations (Read)"` and `"Operations (Write)"` via `IORegistryEntryCreateCFProperty`, and release every object.
  - Deltas go through `counterDelta`.
- [ ] **Step 4:** Run `swift test --filter DiskSamplerTests`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(sampling): disk space and ssd io sampler`.

### Task 6: Machine identity and config

**Files:**
- Create: `Sources/HeadroomCore/Sampling/MachineInfo.swift`, `Sources/HeadroomCore/Config.swift`, `Tests/HeadroomCoreTests/MachineInfoTests.swift`, `Tests/HeadroomCoreTests/ConfigTests.swift`

**Interfaces:**
- Produces:
  - `public struct MachineInfo: Sendable, Equatable, Codable { model: String /*hw.model*/; chip: String /*machdep.cpu.brand_string*/; serialHash: String; perfCores, effCores: Int; ramBytes, diskBytes: UInt64; public var machineId: String /*first 16 hex of sha256(model+serial)*/; public static func current() -> MachineInfo; public func register(in db: Database, now: Date) throws }`. `register` upserts `machines`, keeping `first_seen` and updating `last_seen`.
  - `public struct LimitConfig: Codable, Sendable, Equatable` with defaults: `cpuSaturatedFraction = 0.90`, `loadPerCoreMultiplier = 2.0`, `heavySwapFractionOfRAM = 0.25`, `diskTightFraction = 0.10`, `diskTightMinBytes = 50_000_000_000`, `memoryLimitedDayMinSeconds = 900`.
  - `public struct HeadroomConfig: Codable, Sendable, Equatable { limits: LimitConfig; workdayMinAwakeSeconds = 7200; agentActiveCoreFraction = 0.05; capacityMaxLimitedShare = 0.05; capacityMinSecondsPerLevel = 3600; capacityMinTotalSeconds = 18000; commandMinSeconds = 30; public static func load(from: URL) -> (HeadroomConfig, warning: String?) }`
  - Every field uses `decodeIfPresent` with its default, so a partial file works. A missing file returns the defaults with no warning. An invalid file returns the defaults and a warning.

- [ ] **Step 1: Write the failing tests.**
  - `machineIdStable`: two `current()` calls give the same `machineId`, which is 16 hex characters. `ramBytes == ProcessInfo.processInfo.physicalMemory`, and `perfCores + effCores == ProcessInfo.processInfo.processorCount`.
  - `registerUpserts`: registering at t1 then t2 gives one row with `first_seen == t1` and `last_seen == t2`.
  - `configPartialFile`: `{"limits":{"cpuSaturatedFraction":0.8}}` gives `limits.cpuSaturatedFraction == 0.8` and `workdayMinAwakeSeconds == 7200`.
  - `configInvalidFile`: `"{nope"` gives the defaults and a non-nil warning.
- [ ] **Step 2:** Run `swift test --filter "MachineInfoTests|ConfigTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Cores: `hw.perflevel0.logicalcpu` and `hw.perflevel1.logicalcpu`, with 0 when the second is missing.
  - Serial: the `IOPlatformExpertDevice` property `kIOPlatformSerialNumberKey`, hashed with CryptoKit `SHA256`. The raw serial is never stored.
  - `diskBytes` is the Data volume capacity.
- [ ] **Step 4:** Run `swift test --filter "MachineInfoTests|ConfigTests"`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(core): machine identity and config`.

### Task 7: Process sampler

**Files:**
- Create: `Sources/HeadroomCore/Sampling/ProcessSampler.swift`, `Tests/HeadroomCoreTests/ProcessSamplerTests.swift`

**Interfaces:**
- Produces:
  - `public struct ProcessKey: Hashable, Sendable { pid: Int32; start: UInt64 /*µs since epoch, from pbi_start_tvsec/tvusec*/ }`
  - `public struct ProcessIdentity: Sendable, Equatable { key: ProcessKey; ppid: Int32; uid: UInt32; name: String; path: String }`
  - `public struct ProcessUsage: Sendable, Equatable { identity: ProcessIdentity; cpuSeconds: Double /*delta*/; footprint: UInt64; diskReadBytes, diskWriteBytes: UInt64 /*deltas*/; attributed: Bool /*false when rusage was EPERM*/ }`
  - `public struct ProcessSampler { public init(); public mutating func sweep() -> [ProcessUsage]; public static func cpuSeconds(userNs: UInt64, systemNs: UInt64, timebase: mach_timebase_info_data_t) -> Double }`

- [ ] **Step 1: Write the failing tests.**
  - `timebaseConversion`: with `numer 125, denom 3`, `userNs 24, systemNs 0` (Mach ticks) gives `1000e-9` seconds.
  - `selfAppearsAttributed`: the second `sweep()` contains an entry with `pid == getpid()`, `attributed == true`, `footprint > 0` and `name` non-empty.
  - `firstSightHasZeroDelta`: every usage in the first `sweep()` has `cpuSeconds == 0`.
  - `pidReuseStartsFresh` (Review Focus 1): feed the internal delta function prior state `{ProcessKey(pid: 42, start: 1): 5.0}` and a current reading for `ProcessKey(pid: 42, start: 2)` with total 1.0. Expect delta 0 (first sight) and the old key evicted. Expose the function as `static func delta(previous: [ProcessKey: Double], key: ProcessKey, total: Double) -> Double`.
  - `burnShowsCPU`: spin a child `Thread` for 300 ms between sweeps, then expect self `cpuSeconds >= 0.2`.
- [ ] **Step 2:** Run `swift test --filter ProcessSamplerTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Pid list: `proc_listallpids` into a reused `[Int32]` buffer, growing it ×2 when full.
  - For each pid:
    - Identity comes from `proc_pidinfo(PROC_PIDTBSDINFO)`, plus `proc_pidpath` and `proc_name`. It's computed only for keys not in the identity cache, and the cache drops dead keys each sweep.
    - Usage comes from `proc_pid_rusage(pid, RUSAGE_INFO_V6, …)`, giving `ri_user_time + ri_system_time` (Mach absolute units, converted with `mach_timebase_info`), `ri_phys_footprint`, `ri_diskio_bytesread` and `ri_diskio_byteswritten`.
    - EPERM gives `attributed: false` with zero usage, but the identity is kept so ancestry still works.
- [ ] **Step 4:** Run `swift test --filter ProcessSamplerTests`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(sampling): per-process sampler with identity cache`.

### Task 8: Workload groups and classifier

**Files:**
- Create: `Sources/HeadroomCore/Classify/GroupRules.swift`, `Sources/HeadroomCore/Classify/Classifier.swift`, `Tests/HeadroomCoreTests/ClassifierTests.swift`

**Interfaces:**
- Produces:
  - `public enum WorkloadGroup: String, Codable, CaseIterable, Sendable { case containers, goBuilds = "go", agents, ide, browsers, communication, system, other; public var displayName: String; public var reportGroup: ReportGroup }`
  - Display names: "Containers & Kind", "Go builds & tests", "AI agents", "IDE & editors", "Browsers", "Communication", "macOS system", "Other".
  - `public enum ReportGroup: String, CaseIterable, Sendable { case containers, goBuilds, agents, ide, everydayApps, system }`. `everydayApps` displays as "Everyday apps" and covers browsers, communication and other.
  - `public struct GroupRule: Codable, Sendable { group: WorkloadGroup; names: [String] /*globs, * prefix or suffix*/; pathPrefixes: [String] /*~ expanded*/ }`
  - `public struct GroupRules: Codable, Sendable { rules: [GroupRule]; public static let defaults: GroupRules; public static func load(from: URL) -> (GroupRules, warning: String?) /*writes defaults if missing*/ }`
  - `public struct Classifier: Sendable { public init(rules: GroupRules, currentUID: UInt32); public func ownGroup(_ p: ProcessIdentity) -> WorkloadGroup?; public func classify(_ procs: [ProcessIdentity]) -> [ProcessKey: WorkloadGroup] }`

- [ ] **Step 1: Write the failing tests.** Build fixtures from `ProcessIdentity` values.
  - `ownRuleWins`: `go` (ppid = `claude`) is classified `.goBuilds`.
  - `nearestAncestorInherits`: with the chain `claude` → `zsh` → `foo.test` → `kubectl`, `kubectl` gets `.goBuilds` (from `foo.test`) and `zsh` gets `.agents`.
  - `globSuffixPrefix`: `pkg.test` is `.goBuilds`, and `qemu-system-aarch64` is `.containers`.
  - `otherUserUnclassifiedIsSystem`: uid 0, `launchd` child, no rule gives `.system`. The current uid with no rule and no classified ancestor gives `.other`.
  - `invalidRulesFileFallsBack` (Review Focus 3): the file content `[1,2` gives `rules == defaults.rules` and a non-nil warning.
  - `missingRulesFileWritesDefaults`: afterwards the file exists and decodes to the defaults.
  - `reportFolding`: `.browsers.reportGroup == .everydayApps`, and likewise for `.communication` and `.other`.
- [ ] **Step 2:** Run `swift test --filter ClassifierTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Default rules, in order:
  - containers: names `com.apple.Virtualization.VirtualMachine`, `vfkit`, `qemu-*`, `com.docker.*`, `Docker Desktop*`, `colima`, `limactl`, `OrbStack*`.
  - goBuilds: `go`, `compile`, `link`, `asm`, `cgo`, `vet`, `*.test`, `golangci-lint`, `gopls`.
  - agents: names `claude`, `codex`; path prefixes `~/.claude/`, `~/.local/share/claude/`, `/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code`, `/opt/homebrew/lib/node_modules/@openai/codex`.
  - ide: `goland`, `idea`, `Code Helper*`, `Electron` under `/Applications/Visual Studio Code.app`, `zed`, `Xcode`.
  - browsers: `Google Chrome*`, `Arc*`, `Safari`, `com.apple.WebKit.*`, `firefox`, `plugin-container`.
  - communication: `Slack*`, `zoom.us`, `Microsoft Teams*`.

  `classify` builds a pid→identity map and resolves each process by walking `ppid` to the nearest process whose `ownGroup` is non-nil, memoizing results. If none is found: uid ≠ current gives `.system`, otherwise `.other`.
- [ ] **Step 4:** Run `swift test --filter ClassifierTests`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(classify): workload groups with nearest-ancestor rule`.

### Task 9: Limit evaluator

**Files:**
- Create: `Sources/HeadroomCore/Limits/LimitEvaluator.swift`, `Tests/HeadroomCoreTests/LimitEvaluatorTests.swift`

**Interfaces:**
- Consumes: `CPUReading`, `MemoryReading`, `DiskReading`, `LimitConfig`.
- Produces:
  - `public struct LimitFlags: OptionSet, Sendable { memoryLimited = 1, heavySwap = 2, cpuSaturated = 4, thermalLimited = 8 }`
  - `public enum ThermalLevel: Int, Sendable { nominal, fair, serious, critical; public static func current() -> ThermalLevel }`
  - `public enum LimitEvaluator { public static func evaluate(cpu: CPUReading, memory: MemoryReading, thermal: ThermalLevel, logicalCores: Int, config: LimitConfig) -> LimitFlags; public static func isDiskTight(free: UInt64, capacity: UInt64, config: LimitConfig) -> Bool }`

- [ ] **Step 1: Write the failing tests** (one each):
  - pressure `.warn` gives `memoryLimited`.
  - `swapouts 1` at normal pressure gives `memoryLimited`.
  - `swapUsed` = 0.3 × total with `swapins 1` gives `heavySwap`, and with `swapins 0` it doesn't.
  - CPU idle 0.09 gives `cpuSaturated`.
  - load1 17 on 8 cores gives `cpuSaturated`, and load1 15 doesn't.
  - thermal `.serious` gives `thermalLimited`.
  - disk tight: free 40 GB of 512 GB is true (below 50 GB). Free 60 GB of 2 TB is true (below 10% = 200 GB). Free 300 GB of 2 TB is false.
- [ ] **Step 2:** Run `swift test --filter LimitEvaluatorTests`. Expected: FAIL.
- [ ] **Step 3: Implement** straight from the spec's "At the limit" thresholds via `LimitConfig`. `ThermalLevel.current()` maps `ProcessInfo.processInfo.thermalState`.
- [ ] **Step 4:** Run `swift test --filter LimitEvaluatorTests`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(limits): at-the-limit evaluator`.

### Task 10: Spool

**Files:**
- Create: `Sources/HeadroomCore/IPC/Spool.swift`, `Tests/HeadroomCoreTests/SpoolTests.swift`

**Interfaces:**
- Produces:
  - `public enum SpoolRecord: Codable, Sendable, Equatable { case tag(ts: Double, text: String); case command(ts: Double, exe: String, seconds: Double); case agentSession(ts: Double, tool: String, sessionId: String, model: String?, rootPid: Int32, rootStart: UInt64) }`. It's encoded with a `"type"` discriminator.
  - `public struct Spool: Sendable { public init(url: URL); @discardableResult public func append(_ r: SpoolRecord) -> Bool; public func drain() -> (records: [SpoolRecord], malformed: Int) }`

- [ ] **Step 1: Write the failing tests.**
  - `appendThenDrainTwice`: append 3 records. The first `drain()` returns `[]`, because it rotates `spool.jsonl` → `spool.jsonl.ingesting`. The second `drain()` returns all 3 in order.
  - `malformedLinesSkipped` (Review Focus 4): a file containing a valid line, then `{"type":"tag"`, then `garbage`, then a valid line gives 2 records and `malformed == 2`.
  - `oversizedRecordRejected`: a tag whose text is longer than 4000 bytes makes `append` return false and writes nothing.
  - `missingFileIsEmpty`: `drain()` on a missing file returns `([], 0)`.
  - `concurrentAppends`: 8 tasks × 200 appends, then two drains, yield 1600 records and 0 malformed.
- [ ] **Step 2:** Run `swift test --filter SpoolTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `append`: `open(O_WRONLY|O_APPEND|O_CREAT, 0o600)`, then one `write` of the JSON plus `"\n"`, then `close`. Errors return false and are never thrown.
  - `drain`: (1) read, parse and delete `.ingesting` if it exists; (2) `rename(spool, .ingesting)`.

    Draining one cycle behind lets writers that opened the file just before the rename finish their write (an O_APPEND writer completes in microseconds). That's the reason for the order.
- [ ] **Step 4:** Run `swift test --filter SpoolTests`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(ipc): append-only spool`.

### Task 11: Live state file

**Files:**
- Create: `Sources/HeadroomCore/IPC/LiveState.swift`, `Tests/HeadroomCoreTests/LiveStateTests.swift`

**Interfaces:**
- Produces:
  - `public struct LiveSnapshot: Sendable, Equatable { timestamp: Double; cpuBusy: Float; memUsed, memTotal, swapUsed, diskFree, diskCapacity: UInt64; pressure: UInt8; thermal: UInt8; limitFlags: UInt8; activeAgents, idleAgents: UInt16 }`
  - `public final class LiveStateWriter { public init(url: URL) throws; public func write(_ s: LiveSnapshot) }`
  - `public enum LiveStateReader { public static func read(url: URL) -> LiveSnapshot? }`

- [ ] **Step 1: Write the failing tests.**
  - `roundTrip`: write, then read, returns an equal snapshot.
  - `missingFileNil`: reading a missing file returns nil.
  - `tornRecordRejected`: write a valid snapshot, then overwrite the trailing sequence field with a different value via `FileHandle`. `read` returns nil.
  - `readerSpeed`: 10,000 `read` calls average under 20 µs each.
- [ ] **Step 2:** Run `swift test --filter LiveStateTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** The file is a fixed 128 bytes: magic `HDRM` (4 bytes), version `UInt32 = 1`, `seqBegin: UInt64`, the payload in little-endian fields, and `seqEnd: UInt64` in the last 8 bytes.
  - The writer `mmap`s the file (`MAP_SHARED`). For each write it sets `seqBegin += 1`, calls `atomicMemoryFence(ordering: .sequentiallyConsistent)` (from `Synchronization`), writes the payload, fences again, then sets `seqEnd = seqBegin`. It never `msync`s.
  - The reader does one `pread` of 128 bytes and accepts the record only when the magic and version match and `seqBegin == seqEnd`. A matched pair can't be torn, because a writer that runs every 10 s can't finish a full cycle inside one pread. That's why one read is enough.
- [ ] **Step 4:** Run `swift test --filter LiveStateTests`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(ipc): seqlocked live state file`.

### Task 12: Agent tracker

**Files:**
- Create: `Sources/HeadroomCore/Agents/AgentTracker.swift`, `Tests/HeadroomCoreTests/AgentTrackerTests.swift`

**Interfaces:**
- Consumes: `ProcessUsage`, `[ProcessKey: WorkloadGroup]`, `Classifier.ownGroup`, `HeadroomConfig.agentActiveCoreFraction`.
- Produces:
  - `public enum AgentTool: String, Codable, Sendable { case claude, codex }`
  - `public struct AgentRun: Sendable, Equatable { root: ProcessKey; tool: AgentTool; started: Double; isActive: Bool; cpuSeconds: Double /*this interval*/; footprint: UInt64; diskWriteBytes: UInt64 }`
  - `public struct AgentUpdate: Sendable { started: [AgentRun]; ended: [ProcessKey]; live: [AgentRun]; activeCount: Int; idleCount: Int }`
  - `public struct AgentTracker { public init(activeCoreFraction: Double, sampleInterval: Double = 10); public mutating func update(processes: [ProcessUsage], groups: [ProcessKey: WorkloadGroup], ownGroup: (ProcessIdentity) -> WorkloadGroup?, now: Double) -> AgentUpdate }`

- [ ] **Step 1: Write the failing tests.**
  - `topLevelOnly`: a `claude` process whose parent is another `claude` gives exactly 1 run, rooted at the outer one.
  - `toolFromName`: a root named `codex` gives `.codex`. A node process under the `@anthropic-ai/claude-code` path gives `.claude`.
  - `idleUntilCPU`: a root with 0 CPU and no non-agent descendants over 6 updates is idle. Adding 3.0 cpu-seconds across the trailing 6 samples (0.05 × 60) makes it active.
  - `buildChildMakesActive`: a `go` descendant (group `.goBuilds`) makes the run active immediately, even at 0 CPU.
  - `endsOnExit`: when the root disappears from `processes`, `ended` contains its key.
  - `pidReuseIsNewRun`: the same pid with a new start time gives one `ended` plus one `started`.
  - `treeUsageSums`: run `cpuSeconds` equals the sum over the root and all its descendants.
- [ ] **Step 2:** Run `swift test --filter AgentTrackerTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - A root is a process whose `ownGroup == .agents` and that has no ancestor with `ownGroup == .agents`.
  - Each process is assigned to a root by walking `ppid`.
  - Each run keeps a ring of its last 6 interval CPU values. It's active when `sum ≥ activeCoreFraction × 6 × interval`, or when any descendant's group is not `.agents`.
- [ ] **Step 4:** Run `swift test --filter AgentTrackerTests`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(agents): agent run tracker`.

### Task 13: Sample store (buffered writes, rollups, retention, agent rows)

**Files:**
- Create: `Sources/HeadroomCore/Store/SampleStore.swift`, `Tests/HeadroomCoreTests/SampleStoreTests.swift`

**Interfaces:**
- Consumes: `Database`, all reading types, `LimitFlags`, `AgentUpdate`, `SpoolRecord`, `WorkloadGroup`.
- Produces:
  - `public struct GroupTotals: Sendable, Equatable { cpuSeconds: Double; footprint: UInt64; diskWriteBytes: UInt64; procCount: Int }`
  - `public struct Tick: Sendable { ts: Double; cpu: CPUReading; memory: MemoryReading; disk: DiskReading; thermal: ThermalLevel; flags: LimitFlags; groups: [WorkloadGroup: GroupTotals]; topByCPU, topByMemory: [(name: String, group: WorkloadGroup, value: Double)]; agents: AgentUpdate; selfCPU: Double; selfFootprint: UInt64 }`
  - `public enum Metric: String, CaseIterable { cpuBusy, load1, memUsed, memApp, memCompressed, swapUsed, ssdWrite, diskFree, activeAgents }`
  - `public enum LimitKind: String, CaseIterable { memoryLimited, heavySwap, cpuSaturated, thermalLimited }`
  - `public final class SampleStore { public init(db: Database, machineId: String, interval: Double = 10); public func append(_ t: Tick); public func ingest(_ records: [SpoolRecord]); public func recordEvent(kind: String, ts: Double, payload: [String: String]); public func flush() throws; public func rollupHour(endingAt hourTs: Int64) throws; public func applyRetention(now: Double, days: Int = 30) throws; public func recordCoverage(day: String, recorded: Double, asleep: Double, gap: Double, gaps: [DateInterval]) throws; public var bufferedTicks: Int { get } }`

- [ ] **Step 1: Write the failing tests.** Use a temp DB and synthetic ticks.
  - `flushWritesOneTransaction`: 6 ticks then `flush()` give 6 `samples` rows, group rows for each non-empty group, 1 minute of `rollup` rows per `Metric` at resolution 60, and `limit_seconds` of 10 × the number of flagged ticks per kind.
  - `topProcsPerMinute`: `top_procs_1m` has at most 5 rows per kind per minute.
  - `rollupHourP95`: 360 ticks with `cpuBusy` = 0…359/359 give an hourly `avg ≈ 0.5`, `max == 1`, and `p95` ≈ the 95th-percentile value within 1/359. The `agent_histogram` row seconds equal 10 × ticks at each `activeAgents` level, with memory-limited and cpu-saturated seconds split out.
  - `agentRowsAndSessions`:
    - A started run inserts `agent_runs`; an ended run sets `ended`.
    - Per-minute `run_usage` sums `cpuSeconds` and takes the max footprint.
    - An ingested `.agentSession` with a matching `(rootPid, rootStart)` inserts `agent_run_sessions`. When it arrives before the run, the store creates the run row with `started = ts` and the tool from the record. That's the anonymous/hook merge.
  - `ingestTagAndCommand`: these become `events` rows with kinds `tag` and `command`. The command payload holds `exe` and `seconds` only.
  - `retentionDeletesOnlyRawTables`: rows older than 30 days are removed from `samples`, `group_samples` and `top_procs_1m` and kept in `rollup`, `events` and `agent_runs`.
  - `flushFailureKeepsBounded`: close the DB, then `append` 400 ticks and `flush()` throws. `bufferedTicks <= 360`; the oldest are dropped first, capping the buffer at 1 hour.
- [ ] **Step 2:** Run `swift test --filter SampleStoreTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Statements are prepared once in `init`.
  - The 1-minute rollup and the per-minute top procs are computed in memory from the buffered ticks.
  - `rollupHour` reads that hour's `samples` back, computes avg, max and p95 in Swift (nearest-rank), and writes resolution 3600 rows plus `agent_histogram`.
  - The heartbeat is `meta['heartbeat'] = ts` in every flush.
- [ ] **Step 4:** Run `swift test --filter SampleStoreTests`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(store): buffered sample store with rollups and retention`.

### Task 14: System events, coverage and the recorder

**Files:**
- Create: `Sources/HeadroomCore/Sampling/SystemEvents.swift`, `Sources/HeadroomCore/Coverage/GapDetector.swift`, `Sources/headroomd/Recorder.swift`
- Modify: `Sources/headroomd/main.swift`
- Test: `Tests/HeadroomCoreTests/GapDetectorTests.swift`, `Tests/HeadroomCoreTests/DiagnosticScanTests.swift`, `Tests/HeadroomCoreTests/SamplingBenchmarkTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–13.
- Produces:
  - `public enum PowerEvent: Sendable { case willSleep(Double), didWake(Double) }`
  - `@MainActor public final class PowerMonitor { public init(handler: @escaping @MainActor (PowerEvent) -> Void); public func start() }`. It uses `IORegisterForSystemPower` with `IONotificationPortSetDispatchQueue(.main)`, and acknowledges `kIOMessageSystemWillSleep`/`CanSystemSleep` with `IOAllowPowerChange`.
  - `public struct DiagnosticScanner { public init(directories: [URL]); public mutating func scan(since: Date) -> [(kind: String, ts: Double, file: String)] }`. Kinds: `JetsamEvent-*.ips` gives `jetsam`, and `*.hang` or `*.spin` gives `hang`. Only files whose mtime is after `since`.
  - `public enum GapDetector { public static func startupGap(lastHeartbeat: Double?, now: Double, bootTime: Double, lastSleep: Double?, lastWake: Double?) -> DateInterval?; public static func bootTime() -> Double; public static func lastSleepWake() -> (sleep: Double?, wake: Double?) }`. The last two read `kern.boottime`, `kern.sleeptime` and `kern.waketime`.
  - `@MainActor final class Recorder { init(paths: Paths) throws; func start() }` in `headroomd`.

- [ ] **Step 1: Write the failing tests.**
  - `noGapWhenRebooted`: `bootTime > lastHeartbeat` gives nil.
  - `gapWhenAwakeAndAbsent`: heartbeat 1000, now 2000, boot 0, no sleep gives `DateInterval(1000…2000)`.
  - `sleepSubtracted`: heartbeat 1000, now 5000, sleep 1100, wake 4900 gives nil, because the remaining 100 s + 100 s fall under the 120 s minimum.
  - `shortGapIgnored`: a 90 s absence gives nil.
  - `firstRunNoHeartbeat`: nil.
  - `diagnosticScanFiltersByNameAndTime`: in a temp directory, `JetsamEvent-2026-11-14.ips` (new) is found as jetsam, `x.hang` (new) as hang, `foo.diag` is ignored, and an old `.ips` is ignored.
  - `samplingPassBudget`: run the full sampling pass (`CPUSampler`, `MemorySampler`, `DiskSampler`, `ProcessSampler.sweep`, `Classifier.classify`, `AgentTracker.update`, `LimitEvaluator`) 1,000 times. The mean must be ≤ `budget`. First measure on the dev machine, then set `budget` to 2× the measured mean, capped at 5 ms, and record the measured value in a comment.
- [ ] **Step 2:** Run `swift test --filter "GapDetectorTests|DiagnosticScanTests|SamplingBenchmarkTests"`. Expected: FAIL.
- [ ] **Step 3: Implement the core pieces and the `Recorder`.**
  - On start:
    - `Paths.ensureRoot()`.
    - Open the DB read-write and migrate.
    - `MachineInfo.current().register`.
    - Load config and group rules, logging warnings with `os.Logger(subsystem: "io.github.llinder.headroom", category: "recorder")`.
    - Check `GapDetector.startupGap` against `meta['heartbeat']` and record a `gap` event if there is one. Record a `recorder_start` event.
    - Start `PowerMonitor`.
  - Every 10 s, from a `DispatchSourceTimer` on `.main` with 1 s leeway:
    - Sample everything and classify.
    - Build `[WorkloadGroup: GroupTotals]`. The unattributed bucket is `max(0, cpu.busySeconds − Σ attributed cpuSeconds)`, added to `.system`.
    - Update agents and evaluate limits.
    - Read self usage via `proc_pid_rusage(getpid())`.
    - `store.append`, `LiveStateWriter.write`.
    - Every 6th tick: `store.ingest(spool.drain().records)` (log the malformed count if > 0), then `flush()`.
    - When the clock crosses an hour: `rollupHour`, then `applyRetention`.
    - Every 30th tick: `DiagnosticScanner.scan` events.
    - Every 6th tick: a disk space refresh.
    - When thermal changes: a `thermal` event.
  - Sleep and wake: `willSleep` flushes and records a `sleep` event. `didWake` records `wake`, discards the first CPU and process deltas after wake (call `sample` once and ignore the result), and accumulates daily coverage seconds.
  - Per-day coverage: recorded seconds = ticks × 10, asleep seconds = between sleep and wake events, gap seconds = from detected gaps. Write it at flush for the current local day.
  - SIGTERM: a `DispatchSource.makeSignalSource` that flushes, records `recorder_stop` and exits 0.
  - `main.swift`: `MainActor.assumeIsolated { try Recorder(paths: .standard()).start() }`, then `dispatchMain()`. If `Recorder.init` fails, log and `exit(1)` so launchd restarts it.
- [ ] **Step 4:** Run `swift test`. Expected: PASS.
- [ ] **Step 5: Smoke-test the recorder.** Run `swift build -c release && HEADROOM_ROOT=$(mktemp -d) .build/release/headroomd & sleep 75; kill %1`. Then `sqlite3 "$HEADROOM_ROOT/headroom.db" 'select count(*) from samples'` gives ≥ 6. Add the `HEADROOM_ROOT` env override to `Paths.standard()` for this; tests and the smoke run use it.
- [ ] **Step 6:** Commit with message `feat(recorder): headroomd sampling loop, coverage and system events`.

### Task 15: CLI skeleton, `status` and `tag`

**Files:**
- Create: `Sources/HeadroomCLI/CommandLine.swift`, `Sources/HeadroomCLI/Commands/Status.swift`, `Sources/HeadroomCLI/Commands/Tag.swift`, `Sources/HeadroomCore/Store/Queries.swift`, `Tests/HeadroomCLITests/CommandLineTests.swift`, `Tests/HeadroomCoreTests/QueriesTests.swift`
- Modify: `Package.swift` (add a `HeadroomCLI` library target and a `HeadroomCLITests` target; the `headroom` executable becomes a thin `main.swift` calling `HeadroomCLI.run(CommandLine.arguments)`)

**Interfaces:**
- Produces:
  - `public enum Command: Equatable { case top, status, tag(String), report(since: Date?, until: Date?, machine: String?, out: String?), install(agents: Bool), uninstall, statusline(format: String?, color: Bool, quiet: Bool), agentHook(tool: String), hookZsh, recordCommand(exe: String, seconds: Double), version, help }`
  - `public func parse(_ args: [String]) throws(UsageError) -> Command`
  - `public func run(_ args: [String]) -> Int32`
  - `public struct Queries` (read-only):
    - `public init(db: Database)`
    - `func machines() -> [MachineInfo]`
    - `func heartbeat() -> Double?`
    - `func coverage(machineId: String, from: Date, to: Date) -> [DayCoverage]`
    - `func limitSecondsByDay(machineId: String, from: Date, to: Date, calendar: Calendar) -> [String: [LimitKind: Double]]`
    - `func dailyMetric(machineId: String, metric: Metric, from: Date, to: Date, calendar: Calendar) -> [DailyStat]`
    - `func agentHistogram(machineId: String, from: Date, to: Date) -> [Int: AgentLevelStats]`
    - `func groupTotals(machineId: String, from: Date, to: Date) -> [WorkloadGroup: GroupTotals]`
    - `func eventCounts(machineId: String, from: Date, to: Date) -> [String: Int]`
    - `func selfUsage(machineId: String, from: Date, to: Date) -> (avgCPU: Double, maxFootprint: UInt64)`
    - `func todayLimitSeconds(machineId: String, now: Date) -> [LimitKind: Double]`
  - `public struct DayCoverage { day: String; recorded, asleep, gap: Double; gaps: [DateInterval] }`
  - `public struct DailyStat { day: String; avg, max, p95: Double }`
  - `public struct AgentLevelStats { seconds, memoryLimited, cpuSaturated: Double }`

- [ ] **Step 1: Write the failing tests.**
  - `parseBasics`:
    - `["headroom","tag","kind + 6 agents"]` gives `.tag("kind + 6 agents")`.
    - `["headroom","report","--since","2026-12-01","--out","r.pdf"]` gives `.report` with since = local midnight 2026-12-01.
    - `["headroom","statusline","--no-color"]` gives `color: false`.
    - `["headroom","install","--agents"]` gives `agents: true`.
    - An unknown subcommand throws.
  - `queriesDailyMetric`: seed `rollup` rows at resolution 3600 for 2 days and get 2 `DailyStat` with max = the max of the hours.
  - `statusOutput`: against a seeded DB, `Status.render(…)` contains `"recording"`, `"coverage 99."`, `"gaps 0"` and `"headroomd CPU"`.
- [ ] **Step 2:** Run `swift test --filter "CommandLineTests|QueriesTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `status` prints:
    - recorder state: running if the heartbeat is under 90 s old;
    - LaunchAgent loaded: whether the plist exists;
    - machines and days recorded;
    - coverage % (recorded ÷ (recorded + gap)) and the gap list;
    - DB size;
    - headroomd average CPU % and max footprint over the last 24 h;
    - agent hooks installed (grep the two hook files for `headroom agent-hook`).
  - `tag` appends `SpoolRecord.tag`, prints `tagged`, and returns 0.
- [ ] **Step 4:** Run `swift test`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(cli): command parsing, status and tag`.

### Task 16: `install` / `uninstall` (LaunchAgent and agent hooks)

**Files:**
- Create: `Sources/HeadroomCLI/Commands/Install.swift`, `Tests/HeadroomCLITests/InstallTests.swift`

**Interfaces:**
- Produces:
  - `enum LaunchAgent { static let label = "io.github.llinder.headroom"; static func plist(binary: String) -> Data }`
  - `enum HookConfig { static func merged(_ json: Data?, command: String) throws -> Data; static func removed(_ json: Data) throws -> Data; static func contains(_ json: Data) -> Bool }`. These work on the shared `{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":…,"timeout":5}]}]}}` shape used by both `~/.claude/settings.json` and `~/.codex/hooks.json`.

- [ ] **Step 1: Write the failing tests.**
  - `plistKeys`: the decoded plist has `Label`, `ProgramArguments == [binary]`, `RunAtLoad == true`, `KeepAlive == true`, `ProcessType == "Background"` and `LowPriorityIO == true`.
  - `mergePreservesExisting`: an input with an existing `SessionStart` entry running `bash herdr-agent-state.sh session`, plus unrelated top-level keys (`statusLine`, `permissions`), gives output that still has both, plus one entry whose command is `~/.local/bin/headroom agent-hook claude`.
  - `mergeIdempotent`: merging twice gives one headroom entry.
  - `removeOnlyOurs`: `removed` keeps herdr and drops ours. An emptied `SessionStart` array is removed.
  - `nilInputCreates`: merging `nil` gives a minimal valid document.
  - `neverTouchesStatusLine`: the `statusLine` value is byte-identical after the merge.
- [ ] **Step 2:** Run `swift test --filter InstallTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `install`:
    - Copy `headroom` and `headroomd` from the running binary's directory to `~/.local/bin`.
    - Write the plist.
    - `launchctl bootout gui/$UID/<label>` (ignore failure), then `launchctl bootstrap gui/$UID <plist>` via `Process`.
    - With `--agents`: for each of `~/.claude/settings.json` and `~/.codex/hooks.json`, if the parent directory exists, back up to `<file>.headroom-backup-<epoch>`, then write the merged JSON with `JSONSerialization` and `.prettyPrinted, .sortedKeys`.
    - Print the status-line snippet: `ccstatusline custom command: ~/.local/bin/headroom statusline`, or Claude Code `"statusLine": {"type":"command","command":"~/.local/bin/headroom statusline"}`.
  - `uninstall` reverses all of this and leaves the data directory alone. It prints its path.
- [ ] **Step 4:** Run `swift test --filter InstallTests`. Expected: PASS.
- [ ] **Step 5: Smoke-test.** Run `make install` then `launchctl print gui/$UID/io.github.llinder.headroom | grep state` and expect `state = running`. After 2 minutes `headroom status` shows running. **From this point the real recording has started.**
- [ ] **Step 6:** Commit with message `feat(cli): install and uninstall with agent hooks`.

### Task 17: `statusline`

**Files:**
- Create: `Sources/HeadroomCLI/Commands/StatusLine.swift`, `Tests/HeadroomCLITests/StatusLineTests.swift`

**Interfaces:**
- Consumes: `LiveStateReader`, `LiveSnapshot`, `LimitFlags`.
- Produces: `enum StatusLineFormatter { static let defaultTemplate = "{mem} {swap} · {cpu} · {disk} · {agents}"; static func format(_ s: LiveSnapshot?, now: Double, template: String, color: Bool, quiet: Bool) -> String }`

- [ ] **Step 1: Write the failing tests.**
  - `defaultFormat`: memUsed 0.82 × total, pressure warn, swap 14 GiB, cpu 0.71, disk used 417 GB, 3 active agents, `color: false` gives exactly `mem 82% ⚠ swap 14G · cpu 71% · disk 417G · 3 agents`.
  - `zeroSwapOmitsToken`: swapUsed 0 gives `mem 40% · cpu 5% · disk 417G · 0 agents`. `{swap}` renders as empty, and doubled spaces collapse.
  - `staleIsOff`: a timestamp older than 60 s gives `headroom: off`, and with `quiet: true` it gives `""`.
  - `nilIsOff`: same as stale.
  - `colorCritical`: pressure critical with `color: true` wraps the mem token in `\u{1B}[31m … \u{1B}[0m`. Warn uses `\u{1B}[33m`.
  - `statuslineSpeed`: launch the built binary 200 times via `posix_spawn` against a fixture live.state. The median wall time must be under 5 ms (skip if the release binary isn't built).
- [ ] **Step 2:** Run `swift test --filter StatusLineTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** `headroom statusline` never opens SQLite and never reads stdin, so it doesn't block when the caller pipes JSON. It always exits 0. The parse path for `statusline` must not load config files.
- [ ] **Step 4:** Run `swift test --filter StatusLineTests`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(cli): statusline segment`.

### Task 18: `agent-hook`, `hook zsh`, `record-command`

**Files:**
- Create: `Sources/HeadroomCLI/Commands/AgentHook.swift`, `Sources/HeadroomCLI/Commands/ShellHook.swift`, `Tests/HeadroomCLITests/AgentHookTests.swift`

**Interfaces:**
- Consumes: `Spool`, `SpoolRecord.agentSession`, `SpoolRecord.command`, `ProcessIdentity` lookups via `proc_pidinfo`.
- Produces:
  - `enum AgentHook { static func record(tool: String, stdin: Data, parentPid: Int32, lookup: (Int32) -> ProcessIdentity?, spool: Spool, now: Double) -> Bool }`
  - `enum ShellHook { static let zshSnippet: String }`

- [ ] **Step 1: Write the failing tests.**
  - `findsRoot`: with lookup chain hook → `sh` → `claude`(inner) → `zsh` → `claude`(outer) → `login`, the spooled record has `rootPid` = outer claude, plus `sessionId` and `model` from stdin `{"session_id":"abc","model":"claude-opus-5-5","cwd":"/x"}`. The cwd isn't stored.
  - `badStdinStillExitsCleanly`: stdin `not json` gives `record` false, and the command's exit code is still 0.
  - `noAgentAncestor`: the record is skipped and the result is false.
  - `snippetShape`: `zshSnippet` contains `add-zsh-hook preexec`, `add-zsh-hook precmd`, `headroom record-command`, and `${1%% *}` (first word only). It never contains `$1"` passed whole, which guards the no-arguments rule.
  - `recordCommandStripsPath`: `record-command /usr/local/go/bin/go 42` spools `exe == "go"`.
- [ ] **Step 2:** Run `swift test --filter AgentHookTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `agent-hook`: read stdin up to 64 KB with a 50 ms deadline, decode the fields it needs with `Codable`, walk `getppid()` up to the outermost `claude`/`codex` by name, append to the spool, and exit 0.
  - zsh snippet: `preexec` stores `EPOCHREALTIME` and `${1%% *}`. `precmd`, when the elapsed time ≥ 30 s, runs `headroom record-command "$exe" "$secs" &!`.
- [ ] **Step 4:** Run `swift test --filter AgentHookTests`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(cli): agent session hook and zsh command hook`.

### Task 19: `headroom top`

**Files:**
- Create: `Sources/HeadroomCLI/TUI/Terminal.swift`, `Sources/HeadroomCLI/TUI/TopRenderer.swift`, `Sources/HeadroomCLI/TUI/TopCommand.swift`, `Tests/HeadroomCLITests/TopRendererTests.swift`

**Interfaces:**
- Consumes: the samplers, `Classifier`, `AgentTracker`, `Queries.todayLimitSeconds`, `Queries.coverage`, `MachineInfo`.
- Produces:
  - `struct TopState { machine: MachineInfo; cpu: CPUReading; cpuHistory: [Double]; memory: MemoryReading; disk: DiskReading; diskGrowthPerDay: Double?; groups: [(WorkloadGroup, GroupTotals)]; topProcs: [(String, Double, UInt64)]; agents: [(run: AgentRun, directory: String?)]; today: [LimitKind: Double]; recordingDays: Int; gapCount: Int; recorderRunning: Bool; showProcesses: Bool; showAgents: Bool }`
  - `enum TopRenderer { static func render(_ s: TopState, width: Int, height: Int) -> [String] }`
  - `final class Terminal { init() throws; func size() -> (Int, Int); func draw(_ lines: [String]); func restore() }`

- [ ] **Step 1: Write the failing tests.**
  - `headerLine`: for an M3 with 8 cores, 16 GB, 512 GB, 41 days and 0 gaps, line 0 starts with ` headroom ── M3 · 8 cores · 16 GB · 512 GB` and ends with `recording ● 41d, 0 gaps`, padded to the width.
  - `fitsWidth`: every line's display width is ≤ the width for widths 60, 80 and 120. Count the block and sparkline characters as width 1.
  - `sparkline`: history `[0, 0.5, 1]` contains `▁▅█`.
  - `memoryRowWarn`: pressure warn renders `pressure WARN`, and memory-limited 11520 s renders `memory-limited 3.2h today`.
  - `agentsPane`: 3 runs render a header `── agents (3)` and rows with the tool, directory, age as `42m` or `2h1m`, CPU % and memory. Idle runs are marked `idle`.
  - `notRecording`: `recorderRunning == false` shows `not recording ○` in the header.
- [ ] **Step 2:** Run `swift test --filter TopRendererTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Terminal setup: `termios` raw mode (`cfmakeraw` without `OPOST`), alternate screen `\e[?1049h`, cursor hidden.
  - Signals: `SIGWINCH`, `SIGINT` and `SIGTERM` through `DispatchSource` signal sources, restoring the terminal on exit.
  - Input: stdin via `DispatchSource.makeReadSource` with keys `q`, `g` and `a`.
  - A 1 Hz `DispatchSourceTimer` on `.main` resamples and redraws the whole frame in one `write`.
  - The agent directory comes from `proc_pidinfo(PROC_PIDVNODEPATHINFO)` → `pvi_cdir.vip_path` basename, and is kept in memory only.
  - DB reads (today's totals, coverage) refresh every 30 s from a read-only connection.
- [ ] **Step 4:** Run `swift test --filter TopRendererTests`. Expected: PASS.
- [ ] **Step 5: Check by hand.** In a real terminal, run `.build/release/headroom top`, resize the window, press `g` and `a`, and quit with `q`. The shell prompt must come back intact.
- [ ] **Step 6:** Commit with message `feat(cli): headroom top terminal dashboard`.

### Task 20: Analysis (workdays, verdicts, agent capacity, spec recommendation)

**Files:**
- Create: `Sources/HeadroomCore/Analysis/Workdays.swift`, `Verdicts.swift`, `AgentCapacity.swift`, `SpecRecommender.swift`, `Tiers.swift`, `Baseline.swift`, `examples/baseline.example.json`, `Tests/HeadroomCoreTests/AnalysisTests.swift`

**Interfaces:**
- Consumes: the `Queries` outputs and `HeadroomConfig`.
- Produces:
  - `public struct Tiers: Codable, Sendable { memoryGB: [Int]; cores: [Int]; storageGB: [Int]; public static let defaults; public static func load(from: URL) -> (Tiers, warning: String?) }`. Defaults: memory `[16, 24, 32, 36, 48, 64, 96, 128]`, cores `[8, 10, 12, 14, 16]`, storage `[512, 1024, 2048, 4096, 8192]`.
  - `public struct Baseline: Codable, Sendable { label: String; cores: Int; memoryGB: Double; cpuP95: Double?; peakMemoryUsedGB: Double?; cacheGB: Double?; diskUsedGB: Double?; concurrentAgents: Int?; source: String?; public static func load(from: URL) -> (Baseline?, warning: String?) }`
  - `public enum Workdays { public static func workdays(_ coverage: [DayCoverage], minAwakeSeconds: Double) -> [String] }`, where awake = recorded + gap.
  - `public enum AgentCapacityResult: Equatable { case insufficientData(totalHours: Double); case limitedAtOne(resource: Resource, share: Double); case capacity(n: Int, next: (resource: Resource, share: Double)?) }`, with `public enum Resource: String { memory, cpu }`
  - `public enum AgentCapacity { public static func compute(_ h: [Int: AgentLevelStats], config: HeadroomConfig) -> AgentCapacityResult; public static func sentence(_ r: AgentCapacityResult) -> String }`
  - `public struct Verdict: Equatable { resource: String; sentence: String; isProblem: Bool }`
  - `public enum Verdicts { public static func memory(limitedByDay: [String: Double], workdays: [String], minSeconds: Double) -> Verdict; public static func cpu(saturatedByDay: [String: Double], workdays: [String]) -> Verdict; public static func storage(capacity: UInt64, dailyFree: [(Date, UInt64)], now: Date, calendar: Calendar) -> Verdict; public static func coverage(_ c: [DayCoverage]) -> String }`
  - `public struct SpecRecommendation: Equatable { memoryGB: Int; cores: Int?; storageGB: Int; reasons: [String]; public var headline: String }`
  - `public enum SpecRecommender { public static func recommend(dailyPeakMemoryBytes: [Double], medianSaturatedSeconds: Double, currentCores: Int, usedBytes: UInt64, growthBytesPerDay: Double, tiers: Tiers) -> SpecRecommendation }`

- [ ] **Step 1: Write the failing tests.** Copy the exact wording below.
  - `workdaysThreshold`: days with awake 7199 s and 7200 s give only the second.
  - `dstDayCounts` (Review Focus 5): in `TimeZone(identifier: "America/Los_Angeles")`, samples across 2026-11-01 (a 25-hour day) bucket into exactly one day `"2026-11-01"` via `Queries.limitSecondsByDay` on a seeded DB.
  - `memoryVerdict`: 18 of 22 workdays with ≥ 900 s, averaging 11520 s per workday, give `"Memory ran out on 18 of 22 workdays, an average of 3.2 hours a day."`. Zero days give `"Memory never ran out in 22 workdays."`.
  - `cpuVerdict`: a median of 5040 s gives `"The processor was fully busy for 1.4 hours on a typical workday."`. A median under 360 s gives `"The processor was rarely fully busy."`.
  - `storageVerdict`: capacity 512e9, used 82%, losing 6e9 per week, with now = 2026-11-14, gives `"Storage is 82% full and growing 6 GB a week. It fills by March."`. A fill date more than 24 months away drops the second sentence. No growth gives `"Storage is 82% full and not growing."`.
  - `coverageSentence`: 41 days, 99.6% gives `"Recorded continuously for 41 days (99.6% of awake time)."`.
  - `capacityStopsAtFirstFail`: levels 1 (2 h, 1%), 2 (3 h, 6%), 3 (2 h, 4%) give `.capacity(n: 1, next: (.memory, 0.06))`, as long as memory is the larger share at level 2.
  - `capacitySentence`: `.capacity(n: 3, next: (.memory, 0.22))` gives `"This machine handles 3 AI agents at once. With 4 it runs out of memory 22% of the time."`. `.limitedAtOne(.memory, 0.09)` gives `"This machine runs short of memory even with a single AI agent (limited 9% of the time)."`. `.insufficientData` gives `"Not enough AI agent activity recorded yet to measure agent capacity."`.
  - `capacityInsufficient`: 4 h in total, or level 1 under 1 h, give `.insufficientData`.
  - `specMemory`: daily peaks with a p95 of 30 GB give 30 × 1.25 = 37.5, rounded up to the tier 48. The headline starts `"Recommended: 48 GB memory"`.
  - `specCores`: median saturated 2400 s (above 1800) on 8 cores gives the next tier, 10. At 1200 s, `cores == nil` and the headline omits cores.
  - `specStorage`: 400 GB used, 1 GB/day: 400 + 365 = 765, × 1.2 = 918 → 1024. The headline shows `1 TB storage`.
  - `badTiersFallsBack` and `badBaselineIgnored` (Review Focus 3): invalid JSON gives the defaults or nil, with a warning.
- [ ] **Step 2:** Run `swift test --filter AnalysisTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Nearest-rank p95.
  - Storage growth is a least-squares slope of daily min free over the range, with days to full = free ÷ slope. The month name comes from `DateFormatter` `"LLLL"` in the given calendar.
  - Hours and percentages format to 1 decimal. Percentages under 10 show no decimal (`9%`). Numbers in the sentences use `en_US_POSIX` formatting.
  - `examples/baseline.example.json` holds obviously fictional values (`"label": "Example reference workstation"`).
- [ ] **Step 4:** Run `swift test --filter AnalysisTests`. Expected: PASS.
- [ ] **Step 5:** Commit with message `feat(analysis): verdicts, agent capacity and spec recommendation`.

### Task 21: PDF report and `headroom report`

**Files:**
- Create: `Sources/HeadroomCore/Report/ReportModel.swift`, `Sources/HeadroomCore/Report/Charts.swift`, `Sources/HeadroomCore/Report/PDFReport.swift`, `Sources/HeadroomCLI/Commands/Report.swift`, `Tests/HeadroomCoreTests/ReportTests.swift`

**Interfaces:**
- Consumes: `Queries`, everything from Task 20, `MachineInfo`.
- Produces:
  - `public struct ReportModel: Sendable { title: String; coverage: String; verdicts: [Verdict]; capacitySentence: String; spec: SpecRecommendation; dailyMemory, dailyCPU, dailyDiskUsed: [DailyStat]; limits: (memoryBytes: Double, cores: Double, diskBytes: Double); tags: [(Date, String)]; capacityBars: [(Int, Double)]; comparison: [ComparisonRow]?; appendix: Appendix; public static func build(queries: Queries, machineId: String, from: Date, to: Date, config: HeadroomConfig, tiers: Tiers, baseline: Baseline?, calendar: Calendar) -> ReportModel }`
  - `public struct ComparisonRow { label: String; thisMachine: String; reference: String; previousMachine: String? }`
  - `public struct Appendix { groups: [(ReportGroup, cpuHours: Double, peakMemoryGB: Double)]; agentRunCount: Int; agentCPUHours: Double; ssdWriteGBPerDay: Double; ssdWriteTBPerYear: Double; events: [String: Int]; thresholds: [String]; workdayDefinition: String; recorderAvgCPUPercent: Double; recorderMaxFootprintMB: Double; notes: [String] }`
  - `public enum PDFReport { public static func render(_ m: ReportModel, to url: URL) throws }`

- [ ] **Step 1: Write the failing tests.** Seed a DB fixture covering 30 days, 2 machines and a baseline file.
  - `titleAndPageCount`: the PDF opened with `PDFKit.PDFDocument` has 4 pages (with a comparison) and page 1's text contains `"Hardware capacity report"`, the coverage sentence and `"Recommended:"`.
  - `noComparisonPage`: no baseline and one machine gives 3 pages.
  - `privacyNoProcessNames`: seed `top_procs_1m` with `Slack`, `Google Chrome` and `secret-repo`. The full PDF text contains none of them, and it contains `"Everyday apps"`.
  - `ssdProjection`: 38 GB/day gives `ssdWriteTBPerYear ≈ 13.9`, and the appendix contains `"At this rate the drive absorbs 13.9 TB of writes a year."`.
  - `appendixNotes`: the appendix contains the workday definition, the sentence `"Agent capacity is measured while that many agents were active; it is a correlation, not proof that agents caused all of the load."` and `"Work inside containers is counted under Containers & Kind, not under the agent that started it."`.
  - `reportCLIWritesFile`: running `report --out <tmp>/r.pdf` against the fixture via `HEADROOM_ROOT` writes a non-empty file and exits 0.
- [ ] **Step 2:** Run `swift test --filter ReportTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - The page is US Letter, 612 × 792 pt, created with `CGContext(consumer:mediaBox:)` and `beginPDFPage`. Text uses CoreText `CTFramesetter` with the system font at 11 pt body, 24 pt title and 14 pt verdicts.
  - Palette: ink `#1F2328`, muted `#6E7781`, series `#3B6FD8`, limit/alarm red `#C62828` (used only for the limit line and over-limit verdict marks), grid `#E5E7EB`.
  - Charts: `Charts.dailyLine(ctx:rect:series:limit:tags:)` draws max as a line and p95 as a lighter line, with a dashed red horizontal limit line and tag ticks along the bottom. `Charts.bars(ctx:rect:values:threshold:)` draws the capacity chart.
  - Pages: page 1 holds the verdicts, the capacity sentence and the spec box; page 2 the three charts and the capacity bars; page 3 the comparison (only if there is one); the last page is the appendix. The page order is in the spec.
- [ ] **Step 4:** Run `swift test --filter ReportTests`. Expected: PASS.
- [ ] **Step 5: Check by hand.** Run `headroom report --out /tmp/headroom-report.pdf && open /tmp/headroom-report.pdf` on the real DB and check that it's legible.
- [ ] **Step 6:** Commit with message `feat(report): native PDF capacity report`.

### Task 22: README and end-to-end check

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Write the README.** It covers:
  - what headroom is, plus a `top` screenshot made as a text block;
  - install (`make install`, `headroom install --agents`);
  - adding the status line to Claude Code or ccstatusline;
  - `headroom hook zsh >> ~/.zshrc`;
  - `report`;
  - the config files and their defaults;
  - the privacy promises, copied from the spec's anti-goals;
  - the footprint numbers measured in Task 14 and from `headroom status` after 24 h;
  - uninstall.

  It contains no personal context.
- [ ] **Step 2: Run the end-to-end check.**
  - `swift test` passes.
  - `make install` succeeds.
  - `headroom status` shows running.
  - `headroom statusline` prints a line.
  - `headroom top` runs.
  - Start a Claude Code session and confirm `agent_run_sessions` gets a row within 20 s (`sqlite3 … 'select * from agent_run_sessions'`).
  - `headroom report` produces a PDF.
- [ ] **Step 3:** Commit with message `docs: README with install, privacy and footprint`.

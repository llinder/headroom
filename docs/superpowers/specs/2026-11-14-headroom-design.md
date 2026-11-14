# headroom: design

Date: 2026-11-14
Status: design ready for approval

## Intent

Engineers increasingly run many things at once on a laptop: several AI coding
agents (Claude Code, Codex), parallel Go builds and test suites (often with
testcontainers), Docker image builds and local Kubernetes (Kind) clusters. When
the laptop is too small for that work, the engineer feels it every day, but the
person who approves hardware usually sees only a request and a price.

headroom is a lightweight, native macOS monitor that does two things:

1. **Records**, continuously and without gaps, how often CPU, memory and disk
   are the limit on the machine, broken down by workload (containers, builds,
   agents) instead of by raw process.
2. **Produces evidence** from that record: a short report a non-technical
   reader can act on, ending in a concrete recommended spec.

It's also a daily-use monitor for engineers: a terminal dashboard, a status-line
segment for AI coding agents, and (phase 2) a configurable menu bar. It knows
about AI agent sessions, measures what each one costs the machine, and can tell
agents when the machine is under pressure.

headroom is open source. Nothing in the repo refers to a particular person,
employer or hardware request.

## Goals

1. **An unbroken record.** System and per-workload resource use from the day
   it's installed, across months and across machines. Sleep is recorded as
   sleep, and recorder downtime is a gap, surfaced loudly.
2. **Evidence anyone can read.** Page 1 of the report has plain-language
   verdicts ("Memory ran out on 18 of 22 workdays"), simple charts with the
   machine's limit drawn as a red line, and a recommended spec. Technical
   detail goes in an appendix.
3. **Negligible footprint.** The monitor must never become a measurable part of
   the load it measures. The recorder's budget is at most 0.1% average of one
   core and 15 MB resident memory. It records its own usage so the report can
   prove it.
4. **Agent-aware.** It attributes resource use to AI agent sessions, reports
   how many concurrent agents the machine can carry, and shows live load inside
   the agent's own status line.
5. **An engineer-grade live view:** `headroom top` in the terminal, and a
   native menu bar in phase 2.

## Non-goals

- Any GUI in phase 1. The menu bar and dropdown are phase 2.
- Network, Bluetooth, battery and GPU panels. GPU and network may come later.
- Cloud sync, telemetry, or any network use. The only socket headroom ever
  opens is the local Docker Engine Unix socket (phase 1.5).
- An LLM in the loop. Verdicts and report wording are deterministic rules, so
  the evidence is reproducible and headroom makes no network calls.
- Notarized or App Store distribution in phase 1. It's built from source with
  `swift build` or `make`.
- Importing other monitoring formats (`sar`, CloudWatch). Reference workloads
  enter as a hand-written `baseline.json`.

## Anti-goals (failure even if it works)

- **It looks like surveillance.** Reports get shown to people who approve
  hardware. headroom never records window titles, URLs, document names,
  keystrokes, input idle time, focused-app time or command arguments: nothing
  that describes what the person is doing as opposed to what the machine is
  doing. Reports show workload groups, never individual process names.
- **Gaps or doubt in the record.** If a reader can ask "how do we know it was
  running?", the evidence is weak. Coverage is a first-class metric.
- **The tool is the load.** A monitor that shows up in its own top-10 list
  discredits its report.
- **A report only an engineer can read.**
- **Agent integration that slows agents down.** Hooks and the status-line
  segment must return in single-digit milliseconds (process launch dominates,
  about 4 ms) and never fail an agent's
  action because headroom is missing or broken.

## Constraints

- **Native macOS only.** Swift plus Apple frameworks: Darwin/Mach, libproc,
  IOKit, SQLite3 from the SDK, CoreGraphics/CoreText, and SwiftUI/AppKit in
  phase 2. **No third-party dependencies**, no Electron, no web views, no
  HTML rendering.
- Apple Silicon, macOS 15+. Built and tested with Swift 6.1 or later.
- Runs as the logged-in user without root. Anything that needs root degrades
  gracefully.
- Assumes an unmanaged Mac. A home-built, ad-hoc-signed binary run by a plain
  LaunchAgent is enough; no Developer ID signing, notarization or SMAppService.
- Swift 6 language mode with strict concurrency. No global mutable state.
  Samplers are plain structs or actors that own their state.
- MIT or Apache-2.0 licence (builder picks; MIT is the default).

## Approaches considered

1. **Background recorder plus separate UIs, terminal UI first (chosen).**
   `headroomd` is a LaunchAgent with `KeepAlive` that samples and writes SQLite.
   `headroom` is the CLI, terminal UI, status-line segment, hook handler and
   MCP server, all reading the DB. The phase 2 menu-bar app is another reader.
   Recording survives UI crashes and quits, so the record has no gaps.
2. **A single menu-bar app doing everything.** Rejected: quitting or crashing
   the app stops recording.
3. **Go recorder plus Swift UI.** Rejected: the APIs that matter (Mach host
   statistics, `proc_pid_rusage`, IOKit storage statistics, memorystatus
   sysctls) are C/Swift. Go would be cgo glue that adds a runtime, GC overhead
   and build complexity without reducing the footprint.

## Phases

| Phase | Contents |
|---|---|
| 1 | recorder, storage, rollups, coverage; `top`, `status`, `tag`, `report`, `install`, `uninstall`; shell hook; **status-line segment**; **agent session tracking**; **agent capacity** in the report |
| 1.5 | **load-aware agent hook**; **MCP server**; **leftover-resource alerts** (with a Docker Engine socket reader) |
| 2 | menu-bar app with configurable status-bar modules and a SwiftUI dropdown |

Build order inside phase 1: the recorder and storage come first, so recording
can start while the rest is built.

## Architecture

One Swift package, `headroom`:

| Target | Kind | Role |
|---|---|---|
| `HeadroomCore` | library | samplers, workload classifier, storage schema and queries, rollups, analysis (verdicts, capacity, spec recommendation), live-state file |
| `headroomd` | executable | the recorder; LaunchAgent; the only writer of time series |
| `headroom` | executable | CLI and terminal UI, `statusline`, `agent-hook`, `mcp`, `report` |
| `HeadroomCoreTests` | tests | unit tests using recorded fixtures |

Phase 2 adds `HeadroomBar`, a menu-bar `.app` that depends on `HeadroomCore`.

**Writers.** `headroomd` is the **only** process that writes the database.
Short-lived producers (`headroom tag`, the shell hook and the agent hooks)
append one JSON line, under 4 KB, to `~/Library/Application Support/headroom/spool.jsonl`
with a single `O_APPEND` write. That write is atomic at that size, takes
microseconds and never waits on a lock. `headroomd` ingests the spool every
10 s and truncates what it has consumed, using a rename-then-read so a
concurrent append is never lost. If headroomd isn't running, lines wait in the
spool and are ingested on the next start. Everything else opens the DB
read-only.

**Live state.** `headroomd` also keeps a fixed-size binary file,
`~/Library/Application Support/headroom/live.state` (latest sample: CPU,
memory, pressure, swap, disk, active agents, thermal, timestamp). It's written
to a temp file and atomically renamed every 10 s, and never `fsync`'d. Readers
do one `pread`, so they can't see a torn record and need no mapping or sequence
counter; a rename replaces the whole file, which an in-place update couldn't
guarantee without one. The status line and the agent hooks read only this
file, which keeps them to microseconds with no SQLite open.

### Data flow

```
 Mach / sysctl / IOKit / libproc        spool.jsonl ◄── tag, shell hook,
            │  every 10 s                   │           Claude Code / Codex hooks
            ▼                               │  ingested every 10 s
       headroomd ◄──────────────────────────┘
            │  ├──► live.state (atomic rename, every 10 s) ──► headroom statusline / agent-hook
            │  └──► power + thermal events
            ▼
   1-min accumulator ──► SQLite (WAL, headroomd is the only writer)
                          ├─ samples, group_samples, top_procs_1m (30 days)
                          ├─ rollup_1m, rollup_1h (forever)
                          ├─ events, coverage, machines (forever)
                          └─ agent_runs, agent_run_sessions, run_usage (forever)

 headroom top / status / report / mcp ── read-only ──► SQLite
```

## What gets measured

All sampling uses direct system calls. The recorder **never shells out** to
`ps`, `top`, `vm_stat` and so on.

| Metric | Source | Cadence |
|---|---|---|
| CPU user/system/idle, total and per core | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` tick deltas | 10 s |
| Load average 1/5/15 | `getloadavg` | 10 s |
| Memory: total, active, inactive, wired, compressed, free, purgeable, file-backed | `host_statistics64(HOST_VM_INFO64)` × page size | 10 s |
| "App memory" and "memory used", computed as Activity Monitor does | derived | 10 s |
| Memory pressure level | sysctl `kern.memorystatus_vm_pressure_level` | 10 s |
| Memory free percent as the OS sees it | sysctl `kern.memorystatus_level` | 10 s |
| Swap used/total | sysctl `vm.swapusage` | 10 s |
| Swap-ins/outs, page-ins/outs, compressions/decompressions | `HOST_VM_INFO64` counter deltas | 10 s |
| Boot volume capacity, free, available for important usage | `statfs`, `volumeAvailableCapacityForImportantUsage` | 60 s |
| SSD bytes read/written, op counts | IOKit `IOBlockStorageDriver` `Statistics` deltas | 10 s |
| Thermal state | `ProcessInfo.thermalState` and its change notification | event |
| Sleep/wake | IOKit `IORegisterForSystemPower` | event |
| Per-process CPU time, phys footprint, disk bytes | `proc_listallpids` + `proc_pid_rusage` (highest supported `RUSAGE_INFO_V*`) | 10 s |
| Process identity | `proc_pidpath`, `proc_name`, `proc_pidinfo(PROC_PIDTBSDINFO)` | once per (pid, start time) |
| Jetsam (memory kill) and hang reports | new `JetsamEvent-*.ips`, `*.hang`, `*.spin` in `/Library/Logs/DiagnosticReports` and `~/Library/Logs/DiagnosticReports` | 5 min scan |
| headroomd's own CPU and footprint | `proc_pid_rusage` on self | 10 s |

### Per-process sampling and permissions

`proc_pid_rusage` on another user's process fails with EPERM for a non-root
caller. Those processes go into a **macOS system (unattributed)** bucket,
computed as the total minus everything attributed. Docker Desktop, Colima and
OrbStack VMs, Kind, agents, Go and IDE processes all run as the user, so the
groups that matter are fully attributed.

Cost control for the process sweep:
- Cache identity (path, name, group, agent session) per (pid, start time).
- Keep the previous CPU time per pid in a dictionary sized to the live pid set,
  and compute deltas. Drop pids that disappear.
- Reuse the pid buffer between sweeps.

### Workload groups

A rules file at `~/Library/Application Support/headroom/groups.json`, created
with defaults on first run, maps processes to groups. Each rule matches on
executable path prefix or process name. **Classification:** a process's own
rule wins. If it has none, it takes the group of its **nearest** classified
ancestor. Unmatched processes with no classified ancestor go to **Other**.

So `go test` started by an agent counts as Go builds, and `kubectl` started by
a `.test` binary also counts as Go. The point is that the report says "Go builds
needed X", not "agents needed X". Per-session attribution (below) still credits
that work to the agent session that caused it.

Default groups:
- **Containers & Kind:** Docker Desktop, Colima and OrbStack VM processes,
  `com.apple.Virtualization.VirtualMachine`, `vfkit`, `qemu-*`.
- **Go builds & tests:** `go`, `compile`, `link`, `asm`, `cgo`, `vet`, `*.test`
  binaries, `golangci-lint`, `gopls`.
- **AI agents:** `claude`, `codex`, and node processes under a Claude Code or
  Codex install.
- **IDE & editors:** GoLand/IntelliJ, VS Code and helpers, Zed, Xcode.
- **Browsers**, **Communication** (Slack, Zoom, Teams), **macOS system**,
  **Other.**

Phase 1 counts all container load (including testcontainers started by
`go test`) as Containers & Kind. Splitting it per container comes with the
Docker socket reader in phase 1.5.

The top 5 individual processes by CPU and by memory are stored per minute for
the TUI and `headroom status`. **They never appear in a report.** In reports,
Browsers, Communication and Other are folded into one group, **Everyday apps**.

## AI agent integration

### Agents and agent runs (phase 1)

**The process tree is the source of truth; hooks only add labels.**

- An **agent** is an **agent run**: one top-level `claude` or `codex` process
  (an AI-agents-group process with no AI-agents-group ancestor), from its start
  to its exit. It's keyed by `(machine_id, root_pid, root_start_time)`.
  headroomd detects runs from the process sweep alone, so tracking works with no
  hooks installed and whatever Codex's hook support turns out to be.
- **Nested agents** (`claude -p` or `codex exec` started from inside another
  agent's shell, or subagents) belong to the outer run. They aren't separate
  agents.
- **A run ends when its root process exits.** `SessionEnd` isn't needed and
  isn't trusted, because it doesn't fire on a crash.
- **Session ids are labels on a run.** `/clear` and compaction change the
  session id inside the same process, so the run stays the same and gets a
  second id. `--resume` starts a new process, so it's a new run that carries
  the old id.
- **Out of scope:** hosts that run several sessions inside one process (desktop
  apps, IDE extensions, Agent SDK servers, Codex app-server) count as one run
  in phase 1.

`headroom install --agents` adds `SessionStart` hook entries for Claude Code
(`~/.claude/settings.json`) and Codex (its hooks file, `~/.codex/hooks.json`
today; verify at build time). It merges into existing hooks without replacing
them, and `uninstall` removes only its own entries. The hook runs
`headroom agent-hook <claude|codex>`. That reads the hook JSON from stdin,
finds the run root by walking up from its parent pid, and appends
`{session_id, tool, model, root_pid, root_start_time}` to the spool. It always
exits 0, and its budget is a hard 5 ms.

**Active vs idle.** A run is **active** in a 10 s sample if, over the trailing
60 s, its process tree used at least 5% of one core, or its non-agent members
(a build, a test, a `docker` CLI) used at least 0.5 CPU-seconds in the
interval. Presence alone doesn't count: an idle session keeps language-server
and similar child processes alive, so "has a descendant" would make every
session look busy. Otherwise it's idle, like a session left at the prompt
overnight. `active_agents` and agent
capacity count active runs only. `top` shows both.

Tables:
- `agent_runs(run_id, machine_id, tool, root_pid, root_start_time, started, ended)`
- `agent_run_sessions(run_id, session_id, model, first_seen)`
- `run_usage(run_id, minute, cpu_seconds, peak_footprint, disk_write_bytes, active_seconds)`

Phase-1 `run_usage` covers the run's process tree only. Container work inside
the Docker or Colima VM isn't descended from the agent and stays in Containers
& Kind. The report says so plainly. Phase 1.5's Docker socket reader credits
containers to runs where labels allow, such as testcontainers' `sessionId`
matched to the `go test` process that started it.

**Repo names are never stored.** The `top` agents pane shows the run's
directory basename, read live from the root process's cwd with
`proc_pidinfo(PROC_PIDVNODEPATHINFO)`, and keeps it in memory only. Reports and
the MCP server never have repo names.

Shown in: `headroom top` (an agents pane listing each live run's tool, live
directory, age, active or idle, CPU and memory now, and CPU-hours so far),
`headroom status`, and the report appendix (totals and distributions only).

### Agent capacity (phase 1, in the report)

Every 10 s sample records `active_agents`. The 1-hour rollups keep, for each
active-agent count, the seconds observed, the memory-limited seconds and the
CPU-saturated seconds: a small histogram kept forever.

For each level N (1, 2, 3 …), **limited share** is the fraction of time at N
that was memory-limited or CPU-saturated. The histogram doesn't store the
union of the two, so it's computed as the larger of the memory-limited and
CPU-saturated shares. That's a lower bound on the true share, so capacity can
read slightly optimistic. **Agent capacity** is the largest N
such that **every** level from 1 to N has at least 1 hour of samples and a
limited share under 5%. It stops at the first level that fails, even if a
higher level happens to pass.

- Page 1 sentence: "This machine handles 3 AI agents at once. With 4 it runs
  out of memory 22% of the time." The resource named is whichever of memory
  and CPU has the larger limited share at N+1. Levels with under 1 hour of
  samples stop the walk. If even 1 agent fails: "This
  machine runs short of memory even with a single AI agent (limited 9% of the
  time)."
- It needs at least 5 hours of active-agent samples in total, and at least
  1 hour at level 1. Below that, the section says there isn't enough data yet.
- It's a correlation, measured while N agents were active, not a claim that
  agents caused all the load. The appendix says so, and shows a bar chart of
  limited share by agent count alongside the share of CPU that agent runs
  accounted for at each level.
- If `baseline.json` gives a reference agent count, page 3 shows it side by
  side.

### Status-line segment (phase 1)

`headroom statusline [--format FORMAT]` prints a single line from `live.state`,
for example `mem 82% ⚠ swap 14G · cpu 71% · disk 417G · 3 agents`. It works as
a Claude Code `statusLine` command, as a custom-command widget in
`ccstatusline`, inside Codex where a status line or footer command is
supported, and in tmux or a shell prompt.

- It reads `live.state` only: no SQLite, no sampling, no allocation-heavy
  formatting. The target is under 2 ms wall time.
- It ignores stdin JSON if given. It doesn't need it.
- Colour thresholds come from the same config as "At the limit": amber when
  warn, red when critical. `--no-color` turns colour off.
- If `live.state` is missing or older than 60 s it prints `headroom: off` (or
  nothing with `--quiet`) and exits 0.
- `--format` takes a small template, for example `"{mem} {swap} {cpu} {agents}"`.

### Load-aware agent hook (phase 1.5)

A `PreToolUse` hook for the shell tool in Claude Code, and the matching hook in
Codex. `headroom agent-hook pretool` reads the pending command from stdin and
checks whether it starts a heavy job (`go build`, `go test`, `make`,
`docker build`, `docker compose up`, `kind create cluster`; the patterns are
configurable). If it does, and `live.state` says memory pressure is critical or
swap is growing fast, it returns guidance to the agent through the hook's
context field, for example: "Memory pressure is critical (swap 14 GB). Prefer
`go test -p 2 ./pkg/...` over the whole module, and avoid starting another Kind
cluster." It doesn't block by default. `agents.pretool_mode = "ask"` makes it
ask for permission instead.

The command text is used in memory only and never stored. Each warning is
recorded as an `agent_warning` event (no command text) so the report can count
them. The exact hook output JSON for each tool is verified against current
Claude Code and Codex hook docs at build time.

### MCP server (phase 1.5)

`headroom mcp` is a stdio MCP server (JSON-RPC 2.0, written directly in Swift,
no SDK). It's read-only. Tools:
- `current_status`: the latest sample plus top groups and live agent sessions.
- `query_metric(metric, from, to, resolution)`: the time series from the
  rollups.
- `top_workloads(from, to)`: group totals, including top processes (local to
  the user's own agent, so process names are allowed here; repo names aren't
  stored, so there are none).
- `events(from, to, kinds)`: tags, jetsam, hangs, thermal, agent warnings.
- `agent_runs(from, to)`: per-run usage and session ids.
- `explain_slowdown(at)`: the window around a time, with what was limited and
  which groups were largest. It's deterministic summarisation; the calling
  agent does the narration.

`headroom install --agents` registers it by running `claude mcp add` and
`codex mcp add` when those CLIs exist, rather than editing `~/.claude.json`
(which running sessions rewrite) or Codex's TOML directly. Shelling out is
fine in the CLI; only the recorder must never shell out.

### Leftover-resource alerts (phase 1.5)

The detector runs every 5 minutes in `headroomd`. It looks for:
- Kind clusters and testcontainers that are still running when the agent
  session or process that created them ended more than N minutes ago (default
  60). This uses a read-only client for the Docker Engine API over its local
  Unix socket (`/var/run/docker.sock` or the Colima/OrbStack equivalent),
  reading container labels (`io.x-k8s.kind.cluster`, `org.testcontainers`,
  `org.testcontainers.sessionId`) and creation times. With the socket reader in
  place, container CPU and memory can also be split per container in the
  Containers & Kind group.
- Build daemons (`gopls`, Gradle/Bazel daemons and the like) idle for more than
  N hours.

Each finding becomes a `leftover` event with an estimated memory size, and
shows in `headroom top`, the status line (`⚑ 2 leftovers, 6.1 GB`) and an
optional macOS notification (`UNUserNotificationCenter` needs an app bundle,
so phase 1.5 uses `osascript display notification` only if the user opts in;
phase 2 moves it to the app). headroom never stops or deletes anything itself.
`headroom leftovers` lists them with the commands to clean up.

## Storage

SQLite from the SDK (`import SQLite3`), WAL mode, `synchronous=NORMAL`, at
`~/Library/Application Support/headroom/headroom.db`. Statements are prepared
once. Inserts are batched in one transaction every 60 s, so a crash loses at
most a minute.

Tables (the builder finalizes columns and indexes):
- `machines(machine_id, model, serial_hash, perf_cores, eff_cores, ram_bytes, disk_bytes, first_seen, last_seen)`
- `samples(machine_id, ts, cpu_*, per_core BLOB, load*, mem_*, pressure_level, memorystatus_level, swap_*, vm counter deltas, ssd_*, disk_*, thermal_state, active_agents, self_cpu, self_footprint)`
- `group_samples(machine_id, ts, group_id, cpu_seconds, footprint_bytes, disk_write_bytes, proc_count)`
- `rollup_1m`, `rollup_1h`: avg, max and p95 per numeric field, plus the
  at-the-limit seconds and a histogram of seconds by active-agent count.
- `top_procs_1m(machine_id, ts, rank_kind, rank, name, group_id, value)`
- `agent_runs`, `agent_run_sessions`, `run_usage` (above)
- `events(machine_id, ts, kind, payload JSON)`, where kind is one of `tag`,
  `sleep`, `wake`, `thermal`, `jetsam`, `hang`, `recorder_start`,
  `recorder_stop`, `command`, `agent_warning`, `leftover`. Hang and jetsam
  events store no file name, only the kind and time.
- `coverage(machine_id, day, seconds_awake, seconds_recorded, seconds_asleep, gaps JSON)`
- `meta(key, value)`: schema version.

Every table that holds time-based data carries `machine_id` from the first
release. Moving to a new Mac means copying the DB file. `headroomd` registers
the new machine and recording continues in the same file. Schema changes go
through numbered migrations that run at `headroomd` start.

Retention: the 10 s tables keep 30 days. Rollups, sessions, events and coverage
are kept forever, about 50–80 MB a year.

### Workdays

A **workday** is any day with at least 2 hours of awake time on the machine
(configurable). It's judged from machine state, never from user presence or
input idle time. Overnight agent runs count.

### "At the limit"

Computed in the recorder at 10 s resolution and summed into the rollups:
- **Memory-limited:** pressure is warn or critical, or swap-outs are above 0 in
  the interval.
- **Heavy swapping:** swap used above 25% of RAM and swap-ins above 0.
- **CPU-saturated:** total CPU at least 90%, or load1 at least 2× the core
  count.
- **Thermal-limited:** thermal state is serious or critical.
- **Disk-tight (per day):** free space below 10% or 50 GB, whichever is larger.

The thresholds live in `config.json`, with these defaults.

## Coverage and gaps

- `headroomd` writes a heartbeat with each 60 s batch.
- If a wake notification is missed, 6 consecutive ticks that see the machine
  asleep resume recording, so a lost wake can't leave a silent gap.
- Coverage is recomputed per day from the samples and events, so it's
  idempotent: running it again gives the same answer.
- Sleep and wake come from IOKit power notifications, so asleep time isn't a
  gap.
- On start, `headroomd` compares the last heartbeat with now, using the wake
  events and `kern.waketime`/`kern.boottime`. Time the machine was running
  without the recorder is a **gap**.
- `headroom status` prints recorder health, days recorded, coverage of awake
  time and any gaps. The `top` header shows `recording ● 41d, 0 gaps`. Page 1
  of the report states coverage.

## CLI and terminal UI

`headroom top` draws a full-screen live view with ANSI escape codes and
`termios` raw mode, with no library. It redraws at 1 Hz. Live values come from
the same `HeadroomCore` samplers; today's totals and sparklines come from the
DB. It handles SIGWINCH, `q` to quit, `g` to toggle groups and processes, and
`a` to toggle the agents pane. It restores the terminal on exit, SIGINT and
SIGTERM.

```
 headroom ── M3 · 8 cores · 16 GB · 512 GB ─────────── recording ● 41d, 0 gaps
 CPU     ▁▂▅█▇▆▃▂▅██▇  72%   saturated 1.4h today
 Memory  ████████████░ 15.1/16 GB   pressure WARN  memory-limited 3.2h today
 Swap    ███████████░░ 14.1 GB      SSD writes today 38 GB
 Disk    ██████████░░░ 417/512 GB   +6.2 GB/day
 ── by workload ───────────────── CPU ── Mem ──
  Containers & Kind               31%    6.8G
  AI agents                       22%    3.1G
  Go builds & tests               14%    1.2G
  Browsers                         4%    2.4G
 ── agents (3) ─────────── age ── CPU ── Mem ── CPU-h ──
  claude  headroom          42m    18%   2.1G    0.4
  claude  api-service       2h1m   61%   5.9G    2.3
  codex   infra              9m     3%   0.6G    0.0
```

Commands:
- `headroom status`: recorder health, coverage, DB size, the recorder's own
  average CPU and memory, and agent hooks installed or not.
- `headroom tag "<note>"`: a timestamped note that appears on report charts.
- `headroom report [--since DATE] [--until DATE] [--machine ID] [--out FILE.pdf]`
  (default: the last 30 days, current machine).
- `headroom statusline`, `headroom agent-hook …`, `headroom mcp`,
  `headroom leftovers` (see AI agent integration).
- `headroom install [--agents]` / `uninstall`: copy binaries to `~/.local/bin`,
  write and `launchctl bootstrap` / `bootout` the LaunchAgent
  `~/Library/LaunchAgents/io.github.llinder.headroom.plist` (`RunAtLoad`,
  `KeepAlive`, `ProcessType=Background`, `LowPriorityIO`), and with
  `--agents` merge the hooks and MCP registration. It's idempotent and backs
  up any file it edits. It **never** changes Claude Code's `statusLine`
  setting, because users usually already have one (such as ccstatusline).
  Instead it prints the snippet to add as a custom command or to use as the
  whole status line.
- `headroom hook zsh`: prints a `preexec`/`precmd` snippet that records
  commands taking more than 30 s as `command` events: the executable name and
  duration only, never arguments. It skips leading `NAME=value` assignments
  and redirections, and the recorder rejects names outside `[A-Za-z0-9._+-]`
  or longer than 64 characters. Reports show only totals per workload group
  ("waited 2.1 h/week on Go builds and tests").

## The report

A PDF rendered natively with a CoreGraphics PDF context and CoreText. US
Letter. Legible type and a calm palette, with one alarm red reserved for "over
the limit". Titled "Hardware capacity report: <machine model>, <date range>".

**Page 1, for the decision-maker.**
- Coverage: "Recorded continuously for 41 days (99.6% of awake time)."
- Three verdicts, one sentence and one number each:
  - "Memory ran out on 18 of 22 workdays, an average of 3.2 hours a day."
  - "The processor was fully busy for 1.4 hours on a typical workday."
  - "Storage is 82% full and growing 6 GB a week. It fills by March."
- Agent capacity, one sentence (above).
- **Recommended spec:** one box, for example "Recommended: 64 GB memory, 14+
  cores, 2 TB storage", with one line of reasoning each.

Honesty rules: with no workday in the range there are no verdicts and no
spec box. Storage growth and SSD-wear projections need at least 7 days of
data. Capacity bars are drawn only for levels that were judged.

**Page 2, the picture.** One chart per resource: daily max and p95 over the
range, the machine's limit as a red line, and tags as markers. Plus the agent
capacity bar chart.

**Page 3, the comparison.** Shown only when there's something to compare: the
reference workload from `baseline.json`, and earlier machines in the same DB.

**Appendix, for technical readers.** Per-workload breakdown (with Everyday apps
folded), agent session totals, SSD writes and drive-wear projection, thermal,
jetsam and hang counts, method and thresholds, the workday definition, and the
recorder's own footprint.

### `baseline.json`

Optional, user-written, kept in `~/Library/Application Support/headroom/` and
never in the repo. It describes a reference workload measured elsewhere: a
label, cores, memory, typical and peak CPU, peak memory used, cache, disk used,
concurrent agents, and a free-text note on the source. The repo ships
`examples/baseline.example.json` with obviously made-up numbers.

### Spec recommendation

- **Memory:** take the daily peak of (app memory + wired + compressed + swap
  used), use the 95th percentile of those daily peaks, add 25%, and round up to
  the next tier.
- **CPU:** if CPU-saturated time exceeds 30 minutes on a median workday,
  recommend the next core-count tier.
- **Storage:** used space + 12 months of linear growth + 20%, rounded up to the
  next tier.
- Storage tiers are decimal GB, as Apple sells them (512, 1000, 2000 …);
  memory tiers are binary.
- The tiers live in an editable `tiers.json` (shipped with Apple's current
  MacBook Pro memory, core and storage options), so the report can be updated
  without code changes.

## Footprint budget

- `headroomd`: under 0.1% average CPU, under 15 MB footprint, one small DB
  write a minute plus in-place `live.state` updates.
- `ProcessType=Background`; a single `DispatchSourceTimer` with leeway; no
  busy loops; no Foundation-heavy formatting on the hot path.
- It records its own usage each sample. `status` and the report show it.
- `statusline` and `agent-hook` in single-digit milliseconds (process launch dominates, about 4 ms), with wall-clock budgets enforced in `make bench`.
- Benchmark tests: a full sampling pass run 1,000 times, and 1,000
  `statusline` invocations, each failing above a budget the builder sets after
  measuring.

## Phase 2: menu bar (outline)

`HeadroomBar.app` puts one AppKit `NSStatusItem` per configured module, drawn
with CoreGraphics into small images. Each module has a metric, a style
(sparkline, bar, ring, number only, or a stacked vertical label such as
"DSK ▯ 417.83 GB"), a refresh interval and amber/red thresholds. The dropdown
is a SwiftUI panel with history charts (Swift Charts), live agent sessions and
leftovers, and "Generate report". It reads `live.state` and the DB read-only,
and takes over notifications from the phase 1.5 `osascript` fallback. It gets
its own design pass when phase 1.5 ships.

## Decisions

Decided by the owner:
- Native macOS, Swift, Apple frameworks only, optimized for minimal resources.
- A background recorder plus separate UIs: the terminal UI first, a SwiftUI
  menu bar in phase 2 with configurable status-bar modules.
- Reports show whether CPU, memory or disk is the limit and end in a
  recommended spec.
- Open source; the repo carries no personal or employer context.
- All six AI features, in two phases: status line, agent sessions and agent
  capacity in phase 1; the load-aware hook, MCP server and leftover alerts in
  phase 1.5.
- No LLM-generated report text.

Calls made in this design (overridable):
- 10 s sampling, a 60 s batch write, 30-day raw retention, and rollups kept
  forever.
- Workload groups and nearest-ancestor classification.
- At-the-limit thresholds, the workday definition, the agent capacity rule
  (under 5% limited, at least 1 h of samples) and the spec formulas.
- PDF through CoreGraphics; reports show groups only, with Everyday apps
  folded.
- One DB across machines, tagged by `machine_id`.
- headroomd is the only DB writer; hooks and tags go through an append-only
  spool.
- An agent is a top-level agent process run; idle runs don't count toward
  capacity; the process tree, not hooks, decides run start and end.
- Agent capacity stops at the first failing level and is reported as a
  correlation.
- Per-run container attribution waits for phase 1.5.
- `live.state` as a small file replaced by atomic rename every 10 s.
- No root, so other users' processes go into the unattributed bucket.
- Repo names are never stored, only shown live in `top`.
- The LaunchAgent label `io.github.llinder.headroom`.

## Left to the builder

- Exact SQLite columns and indexes.
- The "app memory" formula from `vm_statistics64` (match Activity Monitor, and
  document it).
- The highest `RUSAGE_INFO_V*` version available on macOS 15+.
- Whether the `kern.memorystatus_*` sysctls and DiagnosticReports directories
  are readable without root. Degrade gracefully and note it in the appendix
  if not.
- Exact hook output JSON for Claude Code and Codex, and whether Codex exposes a
  status-line or footer command (verify against current docs).
- The test framework (Swift Testing preferred if the toolchain supports it).
- TUI layout details beyond the sketch.
- The licence (MIT unless there's a reason otherwise).

# headroom

A lightweight, native macOS monitor that answers one question: is this laptop
big enough for the work being run on it?

Engineers increasingly run many things at once: several AI coding agents,
parallel Go builds and test suites, Docker image builds and local Kubernetes
clusters. headroom is a background recorder plus a terminal view that:

1. **Records**, continuously and without gaps, how often CPU, memory and disk
   are the limit on the machine, broken down by workload (containers, builds,
   agents) instead of by raw process.
2. **Produces evidence** from that record: a short PDF report a non-technical
   reader can act on, ending in a concrete recommended spec.

It also works as a daily-use monitor: a live terminal dashboard and a status-line
segment for AI coding agents. It tracks agent sessions, measures what each one
costs the machine, and reports how many agents the machine can carry at once.

Native Swift, Apple frameworks only, no third-party dependencies, no network
use. Requires macOS 15 or later on Apple Silicon and Swift 6.1 or later.

## What `headroom top` looks like

An illustrative frame (the numbers are made up):

```
 headroom ── Apple M3 · 8 cores · 16 GB · 494 GB ──────────────────── recording ● 41d, 0 gaps
 CPU     ▁▂▅█▇▆▃▂▅██▇  72%   saturated 1.4h today
 Memory  ███████████░░ 13.5/16 GB   pressure WARN  memory-limited 3.2h today
 Swap    ████████████░ 8.2 GB
 Disk    ███████████░░ 425/494 GB
 ── by workload ──────────────────────────────────────────────────── CPU ── Mem ──
 Containers & Kind                                                    31%    6.8G
 AI agents                                                            22%    3.1G
 Go builds & tests                                                    14%    1.2G
 Browsers                                                              4%    2.4G
```

Keys: `q` quits, `g` toggles groups and processes, `a` toggles the agents pane.

## Install

```sh
make install
```

This builds the release binaries, copies `headroom` and `headroomd` to
`~/.local/bin`, writes the LaunchAgent
`~/Library/LaunchAgents/io.github.llinder.headroom.plist` (`RunAtLoad`,
`KeepAlive`, background process type, low-priority I/O) and starts it. Running it
again upgrades in place. Add `~/.local/bin` to your `PATH` to run `headroom`
directly.

### Agent hooks

```sh
headroom install --agents
```

Does everything `make install` does, then adds a `SessionStart` hook that runs
`headroom agent-hook <claude|codex>` to:

- `~/.claude/settings.json` (Claude Code), and
- `~/.codex/hooks.json` (Codex).

`install` copies the binaries from the directory of the `headroom` you run, and it
doesn't build anything: run `make install` first, or `swift build -c release` and
then `.build/release/headroom install --agents`.

A file is only touched if its directory already exists. The hook is merged in
next to your existing hooks, and nothing is added twice. Before changing a file
it saves a copy next to it as `<name>.headroom-backup-<unix time>` with the
original permissions. A file that can't be parsed is reported and left
unchanged. It **never** touches `statusLine`.

Hooks only add labels (session id, model) to agent runs. Runs are detected from
the process tree, so tracking works without them. The hook always exits 0 and
never fails an agent's action.

## Status line

`headroom statusline` prints one line from a small state file the recorder keeps
current, without opening the database:

```
mem 83% ⚠ swap 8G · cpu 46% · disk 425G · 2 agents
```

Memory turns amber at pressure warn and red at critical (`--no-color` turns
colour off). If the recorder isn't running (the file is older than 60 s) it
prints `headroom: off`, or nothing with `--quiet`. It never reads stdin and
always exits 0.

Options: `--format "{mem} {swap} · {cpu} · {disk} · {agents}"` (this is the
default; segments are separated by ` · ` and an empty one is dropped),
`--no-color`, `--quiet`.

`headroom install --agents` prints these snippets, which you add yourself:

- ccstatusline: a custom command widget running
  `~/.local/bin/headroom statusline`
- Claude Code: `"statusLine": {"type":"command","command":"~/.local/bin/headroom statusline"}`
  (use the absolute path the installer prints)

## Shell hook

```sh
headroom hook zsh >> ~/.zshrc
```

Records commands that take **30 seconds or more**, to show how long you wait on
builds and tests. It records the **command name only** (the basename of the
executable) and the duration, never arguments. Leading `NAME=value` assignments
and redirections are skipped, because they can carry secrets, and the recorder
rejects names with characters outside `[A-Za-z0-9._+-]` or longer than 64
characters. The recording runs in the background after your command finishes.
Reports show only totals per workload group.

## Report

```sh
headroom report [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--machine ID] [--out FILE.pdf]
```

- `--since` and `--until` are local calendar days and both are **inclusive**
  (`--until 2026-11-14` includes all of the 14th). The default is the last 30
  days ending today.
- `--machine` takes a machine id prefix; the default is this machine.
- `--out` defaults to `headroom-report-YYYY-MM-DD.pdf` in the current
  directory.

The PDF is US Letter, rendered natively, with wording from deterministic rules
(no LLM, no network):

- **Page 1, the decision:** how much of the awake time was recorded, three
  plain-language verdicts (memory, processor, storage), how many AI agents the
  machine handles at once, and a recommended spec with a line of reasoning for
  each part. With no workday in the range there are no verdicts and no spec.
- **Page 2, the picture:** daily max and p95 for memory, processor and disk,
  with the machine's limit as a red line and your tags as markers, plus time
  limited by number of concurrent agents.
- **Page 3, the comparison** (only when there's something to compare): a
  reference workload from `baseline.json` and earlier machines in the same
  database.
- **Appendix:** per-workload totals, agent run totals, drive writes (a yearly
  projection needs at least 7 days of data), thermal, jetsam and hang counts,
  the method and thresholds, the workday definition, and the recorder's own
  footprint.

## Other commands

- `headroom status` shows recorder health, the machine, days recorded, coverage
  of awake time and gaps, database size, the recorder's own average CPU and
  peak memory over the last 24 h, and whether agent hooks are installed.
- `headroom tag "<note>"` adds a timestamped note that appears as a marker on the
  report charts. Use `--` first if the text starts with dashes.
- `headroom top` is the live terminal view shown above (also the default when you
  run `headroom` with no arguments). Piped, it prints a single frame.
- `headroom version`, `headroom help`.

## Configuration

Everything lives in `~/Library/Application Support/headroom/`. Set
`HEADROOM_ROOT` to use another directory. All files are optional and an invalid
one is ignored with a warning, never overwritten.

| File | Purpose |
|---|---|
| `headroom.db` | the SQLite database (written only by the recorder) |
| `config.json` | thresholds, with the defaults below |
| `groups.json` | your own workload rules, matched before the built-in ones (never written by headroom) |
| `tiers.json` | the configurations a recommendation rounds up to |
| `baseline.json` | an optional reference workload for the comparison page |

**`config.json`** defaults (any key you omit keeps its default):

```json
{
  "limits": {
    "cpuSaturatedFraction": 0.90,
    "loadPerCoreMultiplier": 2.0,
    "heavySwapFractionOfRAM": 0.25,
    "diskTightFraction": 0.10,
    "diskTightMinBytes": 50000000000,
    "memoryLimitedDayMinSeconds": 900
  },
  "workdayMinAwakeSeconds": 7200,
  "agentActiveCoreFraction": 0.05,
  "capacityMaxLimitedShare": 0.05,
  "capacityMinSecondsPerLevel": 3600,
  "capacityMinTotalSeconds": 18000
}
```

A workday is a day with at least 2 hours awake. CPU is saturated at 90% total
or a 1-minute load of 2x the core count. A run counts as active when its process
tree uses at least 5% of a core (or its non-agent members, such as builds, are
working). Agent capacity is the largest N where every level up to N has at least
1 hour of samples and is limited under 5% of the time.

Workload rules map process names (with `*` wildcards) and executable path
prefixes to workload groups. A process's own rule wins; otherwise it takes the
group of its nearest classified ancestor, so `go test` run by an agent counts as
Go builds.

**`groups.json`** is optional and holds only your own rules. They are matched
before the built-in ones, so a rule there wins over a default, and the defaults
still cover everything else. The recorder and the agent hook read the same
file. headroom never writes it; an invalid file is ignored with a warning.
The recorder reads it at start, so restart it after editing
(`launchctl kickstart -k gui/$(id -u)/io.github.llinder.headroom`).

```json
{
  "rules": [
    { "group": "agents", "names": ["my-agent"], "pathPrefixes": [] },
    { "group": "ide", "names": [], "pathPrefixes": ["/Applications/Nova.app/"] }
  ]
}
```

Groups are `containers`, `go`, `agents`, `ide`, `browsers`, `communication`,
`system` and `other`. Built-in rules:

| Group | Matches |
|---|---|
| `containers` | Virtualization.framework VMs, `vfkit`, `qemu-*`, Docker Desktop, Colima, `limactl`, OrbStack |
| `go` | `go`, `compile`, `link`, `asm`, `cgo`, `vet`, `*.test`, `golangci-lint`, `gopls` |
| `agents` | `claude`, `codex`, and processes under `~/.claude/`, `~/.local/share/claude/` or the npm installs of Claude Code and Codex |
| `ide` | GoLand, IntelliJ, VS Code and helpers, Zed, Xcode |
| `browsers` | Chrome, Arc, Safari, WebKit, Firefox |
| `communication` | Slack, Zoom, Teams |

Everything else falls into `system` or `other`. In reports, browsers,
communication and other are folded into **Everyday apps**.

**`tiers.json`** defaults (memory in binary GB, storage in decimal GB, as Apple
sells them):

```json
{
  "memoryGB": [16, 24, 32, 36, 48, 64, 96, 128],
  "cores": [8, 10, 12, 14, 16],
  "storageGB": [512, 1000, 2000, 4000, 8000]
}
```

The recommendation rounds up to these: memory is the 95th percentile of daily
peak demand plus 25%; cores step up when the processor is saturated for more
than 30 minutes on a typical workday; storage is used space plus 12 months of
growth plus 20%.

**`baseline.json`** describes a reference workload measured elsewhere, so page 3
can show it next to this machine. See
[`examples/baseline.example.json`](examples/baseline.example.json) (made-up
numbers). Fields: `label`, `cores`, `memoryGB` (required), and optionally
`cpuP95`, `peakMemoryUsedGB`, `cacheGB`, `diskUsedGB`, `concurrentAgents`,
`source`.

## Privacy

headroom records what the machine is doing, never what the person is doing.

- It never records window titles, URLs, document names, keystrokes, input idle
  time, focused-app time or command arguments: nothing that describes what the
  person is doing as opposed to what the machine is doing.
- Reports show workload groups, never individual process names. The top
  processes are kept briefly for `headroom top` and `headroom status` only and
  never appear in a report.
- Reports never contain repository or directory names. Those are never stored.
  `headroom top` reads an agent's directory name live and keeps it in memory.
- Hang and jetsam events store no file names. Shell commands are recorded as a
  name and a duration only.
- All data stays on the machine. headroom makes no network calls, sends no
  telemetry and uses no LLM. It runs as your user, without root.

## Footprint

The recorder must never become part of the load it measures. Its budget is at
most 0.1% of one core on average and 15 MB resident. Measured on an Apple M3
during development: about 0.06% of one core and about 5 MB. Run `headroom status`
for live figures from your own machine (the recorder records its own usage, and
the report appendix includes it), and `make bench` to run the budget tests.

The status line and the agent hook finish in single-digit milliseconds, almost
all of it process launch.

## Development

```sh
make test      # swift test: the default suite
make bench     # wall-clock budget tests (reader speed, sampling pass, status line, hook); run on an idle machine
make build     # release build only
```

## Uninstall

```sh
headroom uninstall
```

Stops and removes the LaunchAgent, deletes `headroom` and `headroomd` from
`~/.local/bin`, and removes only headroom's own hook entries from
`~/.claude/settings.json` and `~/.codex/hooks.json` (saving a backup first). Your
data in `~/Library/Application Support/headroom/` is kept; delete that directory
to remove the history. Remove the `headroom hook zsh` lines from `~/.zshrc` and any
status-line setting you added by hand.

## License

MIT

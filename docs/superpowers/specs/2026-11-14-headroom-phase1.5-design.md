# headroom phase 1.5: design

Date: 2026-11-14 (revised 2026-11-15 after an independent review)
Status: design ready for approval
Builds on: `2026-11-14-headroom-design.md`, which covers phase 1 as shipped.

## Intent

Phase 1 records how often the machine is at its limit and attributes the load to workloads and AI agent runs. Phase 1.5 makes that knowledge useful *while the work is happening*:

1. **Advise agents under memory pressure.** When memory is critical or swap is growing fast, an agent running heavy commands gets a short note suggesting narrower work. It adapts instead of pushing the machine further into swap.
2. **Let agents ask.** A read-only MCP server exposes the recorded history and live state, so an agent can answer "why was the machine slow at 3 pm?" or "what is using memory right now?".
3. **Surface abandoned containers.** Kind clusters, test containers, compose stacks and other containers that nobody needs any more are flagged, along with the memory they hold and the exact command to clean each one up. Containers meant to stay are recognised from labels or a keep list.

## Goals

- Agents get a short, actionable note during memory pressure. Work is never blocked.
- Agents can query headroom with no network access and no write access.
- Abandoned containers become visible in the status line, `top`, `headroom leftovers` and MCP.
- The owner can say what's long-running and what's temporary, with Docker labels or `headroom keep`.
- Everything works for both Claude Code and Codex.

## Non-goals

- Blocking or asking before commands. **Decided: advise only.**
- Stopping, deleting or pruning anything. headroom only reports and suggests commands.
- Flagging images, volumes or build caches. **Decided: never.** No suggestion ever includes `prune` or `down -v`.
- Idle build daemons (gopls, Gradle and similar). They reparent to launchd, and killing by pid is unsafe after pid reuse. They may come later.
- macOS notifications. These move to the phase 2 menu-bar app, because the recorder may not spawn `osascript`.
- A per-container split of the Containers & Kind group in reports.
- LLM-generated text anywhere.

## Anti-goals

- **Nagging.** Advice is rate-limited and fires only on real pressure. On a busy machine pressure can sit at warn most of the time, so advising at warn would mean advising constantly.
- **Slowing agents.** The pre-command hook stays in single-digit milliseconds. It reads `live.state` first and exits immediately when there's nothing to do.
- **False leftovers.** Flagging the registry, BuildKit builder or a database the owner relies on would teach the owner to ignore the flag, and could lead an agent to delete a cache.
- **Privacy regression.** Command text is never stored. Container, compose-project and cluster names (compose names contain directory names) never go into the SQLite database or reports.

## Constraints

Phase 1 constraints carry over: native Swift and Apple frameworks only, no third-party dependencies, no global mutable state, strict concurrency, the recorder never spawns processes, and `headroomd` is the only database writer.

A typical machine runs **OrbStack** or Docker Desktop, sometimes both, and `/var/run/docker.sock` may point at either. Long-lived infrastructure is common: a compose database, a local registry, a buildx BuildKit builder.

Claude Code and Codex both document `PreToolUse` with a `Bash` matcher and `additionalContext`. Codex asks the user to trust each hook definition.

## Approaches considered

1. **Extend the phase 1 binaries (chosen).**
   - The advice hook becomes an `agent-hook pretool` mode on the existing fast path. That shape is safe on an old binary, which always exits 0 for `agent-hook`.
   - The MCP server becomes a `headroom mcp` subcommand speaking JSON-RPC over stdio.
   - Leftover detection becomes a background pass in `headroomd`, using a minimal Docker client over Unix sockets.
   - Current leftovers live in a sidecar file, not the database.
2. **A separate helper daemon.** Rejected: a second thing to install and keep alive.
3. **An MCP SDK or Docker client library.** Rejected: it breaks the no-dependency constraint.
4. **A `leftovers` table (schema v2).** Rejected after review:
   - it would store compose names, which contain repo names, in SQLite;
   - a downgraded recorder would refuse the database and crash-loop under launchd;
   - per-pass upserts bypass the one-transaction-a-minute flush.

## Design

### 1. Advice hook (`headroom agent-hook pretool <claude|codex>`)

**Install.** `headroom install --agents` adds a `PreToolUse` entry (matcher `Bash`, timeout 5) to `~/.claude/settings.json` and `~/.codex/hooks.json`. The command is `<abs>/headroom agent-hook pretool <tool>`.

`HookConfig` becomes **per event and per entry**. Merge, contains and remove each work on a given event name and command, so an upgrade from phase 1 adds the new hook beside the existing `SessionStart` one, and uninstall removes both. There is a test for upgrading from a phase 1 settings file.

After installing for Codex, install prints that Codex will ask you to trust the new hook.

**Order of work, kept cheap on every shell command:**

1. Read `live.state`. If it is stale or nothing triggers (see below), exit 0 silently.
2. Only then read stdin: the phase 1 reader, a 64 KB cap and a 50 ms deadline. Decode `session_id`, the optional `agent_id`, and the command from the tool input.
3. Read the throttle file. If it isn't due, exit.
4. Classify the command, print the advice, update the throttle, and append the spool record.

**Triggers.** Advice is given when any of these holds:

- pressure is critical;
- swap grew by at least `agents.swapGrowthBytesPerMin` (default 256 MB) in the last minute;
- `live.state` shows leftovers holding at least 1 GB, in which case the advice names them.

**What the advice covers.** Advice is added to the agent's context **alongside the result of the command that triggered it**, so it shapes the agent's *next* commands, not the one already running. The design accepts that.

The advice is given on **any** shell command while a trigger holds, rate-limited, so the agent learns before its next build. The sentence depends on the command:

- When the command matches a heavy pattern, the sentence is specific. For a `go` match: "prefer `go test -p 2 ./<package>/...` over the whole module". There are also `container`, `build` and `js` variants.
- Otherwise it is general: "memory pressure is critical (swap 14 GB, +0.6 GB/min); prefer narrow builds and tests, and avoid starting containers or clusters right now".
- If leftovers hold memory, it adds: "2 abandoned containers hold 3.1 GB; see `headroom leftovers`".

**Heavy patterns** come from `agents.heavyCommands`. Commands are split on newlines, `&&`, `||`, `;` and `|`. Leading `NAME=value`, `time`, `env` and `sudo` are dropped before matching. Defaults:

```
go build, go test, go vet, golangci-lint, make, docker build, docker buildx, docker compose up,
docker run, kind create cluster, kubectl apply, swift build, swift test, cargo build, cargo test,
npm test, npm run build, npx vitest, pnpm test, pytest, bazel, bazelisk
```

**Rate limit.** Advice is given at most once per `agents.adviceMinutes` (default 5) per throttle key. The key is `session_id`, plus `agent_id` when present, because subagents share their parent's session id. Ids are validated against `[A-Za-z0-9._-]`, then used as the file name under `Application Support/headroom/pretool/`. The file's modification time is the timestamp. `headroomd` deletes entries older than 1 day.

**Container ownership marker.** When the command contains a container-kind segment (`docker run`, `docker compose up`, `kind create cluster`, `docker buildx`), the hook appends `SpoolRecord.containerIntent(ts, rootPid, rootStart)`. It does this **whether or not advice was given**, rate-limited to once a minute per throttle key. No command text is stored. This is what leftover ownership uses (section 3).

**Record.** Advice appends `SpoolRecord.agentWarning(ts, trigger)`, which becomes an `agent_warning` event with the payload `{"trigger":"critical"}`, `{"trigger":"swapGrowing"}` or `{"trigger":"leftovers"}`. Records and rows written before the trigger was added have none and an empty payload; they count as `critical`, the only trigger that existed then. There is no schema change.

**Budget.** Single-digit milliseconds, and always exit 0. Gated in `make bench`.

### 2. MCP server (`headroom mcp`)

**Transport.**
- JSON-RPC 2.0 over stdio, one newline-delimited message per line. stdout is flushed after every message, and the server exits on stdin EOF.
- Implements `initialize` (the protocol version is the newest one both clients accept, verified at build time), `notifications/initialized`, `ping`, `tools/list` and `tools/call`. It declares only the tools capability.
- Footprint budget: under 15 MB resident, since there is one process per agent session.

**Data.**
- The database is opened read-only (busy timeout 2000 ms) per call.
- Live values come from `live.state`.
- Leftovers come from the sidecar file (section 3).

**Tools** (three, all read-only). Times are ISO 8601, local when there's no offset, or relative (`-2h`, `-30m`, `-1d`). Results are capped at 500 rows. Each result is one `text` item: a one-line summary followed by compact JSON.

| Tool | Inputs | Returns |
|---|---|---|
| `current_status` | — | the live snapshot; today's limit seconds; top groups and processes now; live agent runs (tool, age, CPU, memory, active/idle); current leftovers with memory and cleanup commands |
| `query_metric` | `metric`, `from`, `to`, `resolution` (`minute`, `hour` or `auto`) | a time series from the rollups. `auto` uses minutes when the range is 6 h or less |
| `explain_slowdown` | `at`, `windowMinutes` (default 30) | limits hit and for how long; peak memory demand, pressure and swap; the 3 largest groups by CPU and memory; top processes, where raw data still exists; agent runs active, with CPU; the count and bytes of leftovers then (from events); events in the window |

**Privacy.** Process, container and cluster names may appear, because this is the owner's agent on the owner's machine. The README says plainly that MCP output goes into the agent's context, and so to the model provider. Command text and repo names are never available here, because they are never stored.

**Registration.**
- `install --agents` runs `claude mcp add --scope user headroom -- <abs>/headroom mcp` and `codex mcp add headroom -- <abs>/headroom mcp`.
- Each runs only if that CLI is on `PATH`, and is skipped if `headroom` is already registered.
- `uninstall` removes both registrations.

### 3. Leftover detection (a background pass in `headroomd`, every 5 minutes)

**Engines.** The pass looks for Docker engines in three places:
- every `unix://` endpoint in `~/.docker/contexts/meta/*/meta.json`, together with that context's name;
- `/var/run/docker.sock` (context `default`);
- `DOCKER_HOST`, when it's `unix://`.

Paths are resolved through symlinks and deduplicated, keeping the first context name found.

**Client.**
- A minimal HTTP/1.1 client over a Unix socket, with `SO_NOSIGPIPE` set. headroomd doesn't ignore SIGPIPE.
- It handles `Content-Length` and chunked bodies. OrbStack replies chunked even to HTTP/1.0.
- Each request times out after 2 s.
- **Unversioned API paths:**
  - `GET /containers/json` gives id, names, image, labels and state;
  - `GET /containers/{id}/json` gives `State.StartedAt`, fetched only for candidates;
  - `GET /containers/{id}/stats?stream=false&one-shot=true` gives memory, only for candidates. Memory is `usage - inactive_file` and is reported as an estimate.

**Execution.**
- The pass runs on its own serial background queue.
- It has a 10 s overall deadline, at most 20 inspect or stats calls per pass, and 2 s per request.
- Results return to the main actor. Sampling never waits.
- `status` shows the engines found and when the last pass ran.
- A refused connection or a missing socket clears that engine's items. A timeout keeps them for at most 3 passes.

**Grouping.** Each item is keyed by `<engine context>/<kind>/<id or name>`.

| Item | Identified by | Cleanup suggested |
|---|---|---|
| Kind cluster | label `io.x-k8s.kind.cluster` | `docker --context <ctx> stop <nodes…>`, which keeps the loaded images, or `DOCKER_CONTEXT=<ctx> kind delete cluster --name <name>` |
| Compose stack | label `com.docker.compose.project` | `docker --context <ctx> compose -p <project> down`, never `-v` |
| Testcontainers session | labels `org.testcontainers=true` and `org.testcontainers.sessionId` | `docker --context <ctx> rm -f <ids>` |
| Other container | each one | `docker --context <ctx> rm -f <id>` |

**Lifetime: labels and the keep list.**
- **Label.** `io.github.llinder.headroom.lifetime` on any container in the item can be:
  - `keep` (never flagged);
  - `temporary` (flagged as soon as its owner is done);
  - a duration such as `8h` or `7d` (flagged once older than that, measured from start).

  For compose stacks, any service's label counts, and the shortest lifetime wins.
- **Keep list.** `headroom keep <name> [--for 7d]` and `headroom unkeep <name>` edit `Application Support/headroom/keeps.json`. A name can be a container name, `compose:<project>` or `kind:<cluster>`, optionally prefixed `<context>/`. Keep entries override labels. Kind clusters can only be kept this way, because Kind doesn't pass labels through to its node containers.
- **Built-in ignores.** These are never flagged and can be extended in `leftovers.ignore`, by name glob, image glob or label:
  - BuildKit builders (`buildx_buildkit*`, image `moby/buildkit*`);
  - registries (image `registry:*`, `kind-registry`);
  - the Testcontainers reaper (`testcontainers-ryuk*`);
  - containers labelled `io.kubernetes.pod.name`;
  - Testcontainers reuse containers (label `org.testcontainers.reuse.enable=true`, or the equivalent the builder confirms).

**Ownership** (used when there is no label or keep entry).

- **Owner.** An item's owner is the agent run whose most recent `containerIntent` marker comes at or before the item's start, within 10 minutes. Several runs can't co-own an item: the closest marker wins.
- **Done.** The owner is done when its process has exited, or when it has sent no container marker for `leftovers.afterMinutes` (default 60) of **awake, recorded time**. Sleep and recorder gaps don't count.
  - A live run that shares the owner's `session_id` inherits ownership, so a resumed session keeps its containers.
- **Testcontainers.** When the reaper for that `sessionId` is gone but containers remain, the item is a leftover immediately.
- **Fallback when no hook data is available.** This covers hooks not installed, and containers that existed before phase 1.5. Owners are the runs active in the creation minute, and done means the same as above, measured from `run_usage`.
- **No owner.** The item is a leftover after `leftovers.unownedAfterHours` (default 24) of running time.

**State.**
- **Sidecar file.** Current leftovers live in `Application Support/headroom/leftovers.json`. It's written by temp file plus atomic rename, like `live.state`, and holds:
  - the engine context, kind, name, start time, owner state, memory estimate and cleanup command per item;
  - the last-pass time and status per engine.

  It's local-only and is never copied into SQLite.
- **Events in SQLite.** These go through the normal flush, with no schema change:
  - `leftover`, with payload `kind`, `ref` (the first 12 hex characters of SHA256 of the key, salted with the machine id), `bytes`, `totalBytes`, the sum of all current leftovers after this change, and `totalCount`, the number flagged after it;
  - `leftover_cleared`, with the same fields;
  - `leftover_bytes`, with only `totalBytes` and `totalCount`, when a pass changes the total without flagging or clearing anything. Memory is usually read a pass after the flag, so without it the peak would miss that memory.

  Readers take the count from the last event's `totalCount`. Rows written before it existed fall back to flags minus clears.
- **Live state.** The phase 1 reserved bytes are used. The version stays 1, and zero means none:

| Offset | Field |
|---|---|
| 76 | `leftoverCount` u16 |
| 78 | pad u16 |
| 80 | `leftoverBytes` u64 |
| 88 | `swapGrowthBytesPerMin` i64 (swap now minus 60 s ago) |

**Surfaces.**
- **Status line:** a `{leftovers}` token renders `⚑ 2 leftovers · 3.1 GB`, or nothing. It's in the default template.
- **`top`:** the same marker in the header, plus an `l` pane listing engine, kind, name, owner state, memory and cleanup.
- **`headroom leftovers` (with `--json`):** lists everything with copy-pasteable commands. A `--kept` flag shows kept and ignored items too, so you can see why something isn't flagged.
- **`headroom keep` / `unkeep` / `keeps`:** manage the keep list.
- **Report appendix:** two lines, with no names:
  - "Agents were advised to narrow work N times: A while memory was critical, B while swap was growing, C because abandoned containers held memory." Only the non-zero parts are listed. With one part the sentence has no breakdown, for example "Agents were advised to narrow work 2 times while swap was growing."
  - "Abandoned containers held up to X GB at their peak." This is the maximum `totalBytes` from the three leftover event kinds in the range, seeded with the last `totalBytes` before the range, so containers already held when the range opens count.

### Config additions (`config.json`, all optional with defaults)

```json
{
  "agents": { "heavyCommands": ["..."], "adviceMinutes": 5, "swapGrowthBytesPerMin": 268435456 },
  "leftovers": { "afterMinutes": 60, "unownedAfterHours": 24,
                 "ignore": { "names": [], "images": [], "labels": [] } }
}
```

## Backwards compatibility

- **No schema change.** Phase 1.5 adds no tables. New data goes into events, the sidecar files and the reserved `live.state` bytes, so a downgrade to phase 1 keeps working.
- **Spool.** A phase 1 recorder that meets the new `agentWarning` or `containerIntent` records counts them as malformed and skips them. `install` updates both binaries together.
- **Hooks.** These are merged per event and per entry, so upgrading from phase 1 adds the `PreToolUse` hook. `uninstall` removes all of headroom's entries.
- **Old `agent-hook` binaries.** These ignore an unknown mode and exit 0, so a newer settings file never blocks a tool.

## Decided by the owner

- Phase 1.5 comes before phase 2.
- The pre-command hook advises only.
- Nearly all running containers are temporary. Images, volumes and caches are never flagged or pruned.
- Containers no agent started are flagged after a while.
- Long-running versus abandoned is decided by Docker labels, plus `headroom keep` for things that can't be labelled.
- Both agents are in scope.

## Calls made in this design (overridable)

- **Triggers:** critical pressure, swap growth of at least 256 MB/min, or leftovers holding at least 1 GB. Advice on any shell command while a trigger holds, at most every 5 minutes per session and subagent.
- **Ownership:** container-intent markers from the hook (closest marker within 10 minutes). Done means exited or 60 awake minutes without a container marker. Session-id inheritance. The fallback without hooks. Unowned items flagged after 24 hours.
- **The label name and values** (`keep`, `temporary`, durations). The keep list overrides labels, and Kind clusters use the keep list.
- **Built-in ignores** for BuildKit, registries, the Testcontainers reaper, Kubernetes pods and reuse containers.
- **Leftover state** in a sidecar file plus hashed events. No `leftovers` table, and no `leftoverBytes` metric.
- **Cleanup commands** name the engine context. For Kind, offer `docker stop` (keeps images) or `kind delete`.
- **Three MCP tools.**
- **Cut:** idle daemons and notifications.

## Left to the builder

- Exact `PreToolUse` input and output JSON, and the trust behaviour, for both clients.
- The MCP protocol version string, and the `claude mcp add` / `codex mcp add` flags.
- The Testcontainers reuse label, and how to detect a reaper per `sessionId`.
- HTTP client details.
- Whether a 5-minute poll keeps an idle OrbStack VM awake (measure it; if it does, poll only while an agent run is live or pressure isn't normal).

## Verified during implementation

**Hook JSON (`PreToolUse`).**
- Input, for both Claude Code and Codex: `session_id`, `tool_name` and `tool_input.command` for Bash. Claude Code adds `agent_id` when the session uses `--agent` or the hook fires inside a subagent. Codex sends no `agent_id` on `PreToolUse`, so Codex advice is throttled per session only.
- Output, for both: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"<text>"}}` on one line, with exit 0. No `permissionDecision` and no other field is emitted; Codex marks a hook run as failed when it sees fields such as `continue` or `stopReason`. Plain stdout is ignored by Codex.
- Codex asks the user to trust newly added hooks, so `install --agents` prints a note.

**MCP protocol.**
- Spec revisions published are 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25 and 2026-07-28. The server implements the `initialize` handshake and negotiates 2024-11-05 through 2025-11-25: a requested version in that set is echoed, anything else gets 2025-11-25.
- 2026-07-28 drops the handshake (per-request `_meta`, `server/discover`). A client that supports only 2026-07-28 is not supported. Dual-era clients probe with `server/discover`, get -32601, and fall back to `initialize`. The installed Claude Code and Codex CLIs both do this.

**CLI flags.**
- `claude mcp add --scope user headroom -- <exe> mcp`, and `claude mcp remove --scope user headroom`. `--scope` is `local`, `user` or `project`.
- `codex mcp add headroom -- <exe> mcp`, and `codex mcp remove headroom`. Codex has no scope flag: its config is per user.
- `mcp list` is used to detect an existing registration: the first field of a line must equal `headroom` (or `headroom:`), because a substring match would skip registration when another server's path contains the word.

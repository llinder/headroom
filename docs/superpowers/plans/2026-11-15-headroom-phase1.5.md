# headroom Phase 1.5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the pre-command advice hook, the read-only MCP server and abandoned-container detection (with lifetime labels and a keep list) on top of the shipped phase 1.

**Architecture:** All new logic lives in `HeadroomCore` (pure, tested) or `HeadroomCLI`. `headroomd` gains one background Docker pass. There's no schema change: new data goes to events, a `leftovers.json` sidecar, `keeps.json`, throttle files and the reserved `live.state` bytes. The hook keeps the fast path: it reads `live.state` first.

**Tech Stack:** Swift 6.1 (Swift 6 mode) with Swift Testing, plus Darwin Unix sockets, SQLite3, Foundation and CryptoKit. There are no third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-11-14-headroom-phase1.5-design.md`, which builds on `docs/superpowers/specs/2026-11-14-headroom-design.md`.

## Global Constraints

- macOS 15+, Apple Silicon, `swift-tools-version: 6.0`. No third-party dependencies.
- Concurrency: no global mutable state, no `@unchecked Sendable`, no `nonisolated(unsafe)`.
- `headroomd` never spawns processes, and is the only SQLite writer. Hooks and the CLI write only through the spool or sidecar files.
- No schema change in phase 1.5. `Schema.migrations` stays at count 1.
- Advice only: the hook never sets a permission decision and always exits 0. It never prints to stdout except the hook JSON.
- Command text is never stored. Container, compose-project and cluster names never go into SQLite or reports. They live only in `leftovers.json` and `keeps.json`.
- Never suggest `prune` or `compose down -v`.
- Hook budget: single-digit milliseconds. It reads `live.state` before stdin, config or throttle files.
- Paths live under `Application Support/headroom/`:
  - `leftovers.json` and `keeps.json`;
  - `pretool/<key>` throttle files;
  - `HEADROOM_ROOT` still overrides the whole location.
- Wall-clock budget tests are gated with `HEADROOM_BENCH=1` (`make bench`).
- Commits carry no trailers, no session URLs and no personal context.

## Review Focus

1. **The Docker engine vanishing mid-pass** (OrbStack quit, socket deleted, connection reset). Expect: no crash and no hang past the deadline, and that engine's items cleared on refusal. Covered by Tasks 6 and 10.
2. **Malformed hook input:** stdin that is empty, 64 KB+, invalid JSON, or has no `tool_input.command`. Expect: exit 0, no stdout, no throttle or spool writes. Covered by Task 5.
3. **Names that break shell commands:** container, project or cluster names with spaces, quotes or `$`. Expect: cleanup commands single-quote every name so they're safe to copy and paste. Covered by Task 8.
4. **A malformed or half-written `keeps.json`.** Expect: treated as empty plus a warning, and `headroom keep` writes atomically. Covered by Tasks 8 and 11.
5. **Bad MCP traffic:** a malformed JSON line, an unknown method, `tools/call` before `initialize`, a notification without an id, an unknown tool. Expect: JSON-RPC errors (-32700, -32601, -32602), no reply to notifications, no crash, and the server keeps serving. Covered by Task 13.

---

### Task 1: Live state carries leftovers and swap growth

**Files:**
- Modify: `Sources/HeadroomCore/IPC/LiveState.swift`
- Modify: `Sources/headroomd/Recorder.swift` (compute swap growth)
- Test: `Tests/HeadroomCoreTests/LiveStateTests.swift`

**Interfaces:**
- Produces: `LiveSnapshot` gains `leftoverCount: UInt16`, `leftoverBytes: UInt64` and `swapGrowthBytesPerMin: Int64`, all with defaulted init parameters (`= 0`), so existing call sites compile. They sit at layout offsets 76 (u16), 80 (u64) and 88 (i64, little-endian). The version stays 1.
- Produces: `struct SwapGrowth { mutating func record(swapUsed: UInt64, at: Double) -> Int64 }` in `Sources/HeadroomCore/Sampling/TickAggregation.swift`. It returns used minus the value from about 60 s ago, nearest sample at least 55 s old, and 0 until one exists. It keeps at most 8 samples.

- [ ] **Step 1: Write failing tests:**
  - `roundTripNewFields` writes all three fields (including a negative growth) and reads them back.
  - `phase1FileReadsZeroForNewFields`: a 128-byte record with bytes 76–95 zeroed reads count 0, bytes 0, growth 0.
  - `swapGrowthUsesSampleFromAMinuteAgo`: samples at t = 0, 10 … 70 with used 0, 1 GB … 7 GB. At t = 70 it returns 6 GB.
  - `swapGrowthZeroUntilAMinuteOfHistory`.
- [ ] **Step 2:** Run `swift test --filter LiveStateTests`. Expect FAIL (no member).
- [ ] **Step 3: Implement** the offsets in the private `Layout`, then `SwapGrowth`. `Recorder.tick` sets `swapGrowthBytesPerMin` on each written snapshot. The leftover fields stay 0 until Task 10.
- [ ] **Step 4:** Run `swift test --filter 'LiveStateTests|TickAggregation'`. Expect PASS.
- [ ] **Step 5:** Commit: `feat(ipc): live state carries leftovers and swap growth`

### Task 2: Spool records for advice and container intent

**Files:**
- Modify: `Sources/HeadroomCore/IPC/Spool.swift`
- Modify: `Sources/HeadroomCore/Store/SampleStore.swift` (ingest)
- Modify: `Sources/HeadroomCore/Store/Queries.swift`
- Test: `Tests/HeadroomCoreTests/SpoolTests.swift`, `SampleStoreTests.swift`, `QueriesTests.swift`

**Interfaces:**
- Produces: `SpoolRecord.agentWarning(ts: Double)` and `SpoolRecord.containerIntent(ts: Double, rootPid: Int32, rootStart: UInt64)`. Their `"type"` discriminators are `agentWarning` and `containerIntent`.
- Produces, on ingest:
  - `agentWarning` becomes an event of kind `agent_warning` with payload `[:]`;
  - `containerIntent` becomes an event of kind `container_intent` with payload `["rootPid": "<n>", "rootStart": "<µs>"]`.
- Produces: `Queries.containerIntents(machineId: String, from: Double, to: Double) throws(DatabaseError) -> [(ts: Double, root: ProcessKey)]`, ordered by ts.

- [ ] **Step 1: Write failing tests:**
  - `newRecordsRoundTrip` (Spool).
  - `ingestWritesWarningAndIntentEvents` (store): the payloads are exactly as above.
  - `containerIntentsInRange` (Queries): three intents, two in range, returned ordered with the correct `ProcessKey`.
  - `phase1RecorderSkipsNewRecords`: decoding with only the phase 1 cases counts them as malformed. Simulate it by feeding a line with an unknown `"type"` to the existing drain path; that's the existing behaviour, so this asserts it.
- [ ] **Step 2:** Run `swift test --filter 'SpoolTests|SampleStoreTests|QueriesTests'`. Expect FAIL.
- [ ] **Step 3: Implement** the cases, the ingest mapping and the query (`events WHERE kind='container_intent'`, parsing the payload strings and skipping unparseable rows).
- [ ] **Step 4:** Run the same filter. Expect PASS.
- [ ] **Step 5:** Commit: `feat(spool): agent warning and container intent records`

### Task 3: Hook config per event and per entry

**Files:**
- Modify: `Sources/HeadroomCLI/Commands/Install.swift`
- Test: `Tests/HeadroomCLITests/InstallTests.swift`

**Interfaces:**
- Produces:
  - `HookConfig.merged(_ json: Data?, event: String, matcher: String?, command: String) throws -> Data`. It adds `{"matcher"?: m, "hooks":[{"type":"command","command":c,"timeout":5}]}` to `hooks[event]` unless an entry with exactly `command` already exists under that event. In that case it returns the original bytes unchanged, which keeps phase 1's byte-identical behaviour.
  - `HookConfig.removed(_ json: Data) throws -> Data` removes every headroom entry under every event, dropping emptied events and an emptied `hooks`.
  - `HookConfig.contains(_ json: Data, event: String) -> Bool`.
- Produces: `Install.run(... agents: true)` merges two hooks per tool:
  - `SessionStart` (no matcher) → `<abs>/headroom agent-hook <tool>`;
  - `PreToolUse` with matcher `Bash` → `<abs>/headroom agent-hook pretool <tool>`.

  After Codex, it prints `codex: approve the new headroom hooks when Codex asks you to trust them`.

- [ ] **Step 1: Write failing tests:**
  - `upgradeFromPhase1AddsPreToolUse`: a phase 1 file with only the SessionStart hook ends with both events and the SessionStart entry unchanged.
  - `mergeIsIdempotentPerEvent`: merging twice gives byte-identical output.
  - `removeDropsAllOurEventsKeepsOthers`: a foreign `PreToolUse` hook survives.
  - `installAgentsWritesBothEventsForBothTools`, using the existing temp-home harness.
- [ ] **Step 2:** Run `swift test --filter InstallTests`. Expect FAIL.
- [ ] **Step 3: Implement.** Keep `isOurs` (the `headroom agent-hook` substring). Update existing call sites and tests to the new signature.
- [ ] **Step 4:** Run `swift test --filter InstallTests`. Expect PASS.
- [ ] **Step 5:** Commit: `feat(install): hook config per event; add the PreToolUse hook`

### Task 4: Advice logic (pure)

**Files:**
- Create: `Sources/HeadroomCLI/Commands/PreToolAdvice.swift`
- Modify: `Sources/HeadroomCore/Config.swift`
- Test: `Tests/HeadroomCLITests/PreToolAdviceTests.swift`, `Tests/HeadroomCoreTests/ConfigTests.swift`

**Interfaces:**
- Produces in Config: `public struct AgentsConfig: Codable, Sendable, Equatable { heavyCommands: [String]; adviceMinutes: Int = 5; swapGrowthBytesPerMin: Int64 = 268_435_456 }` as `HeadroomConfig.agents`, decoded with `decodeIfPresent`. The `heavyCommands` default is copied verbatim from the spec's list.
- Produces in `PreToolAdvice.swift`:
  - `enum AdviceTrigger: Equatable { case critical, swapGrowing, leftovers }`
  - `static func trigger(_ s: LiveSnapshot, now: Double, config: AgentsConfig) -> AdviceTrigger?`. It returns nil if stale (more than 60 s). The precedence is critical (pressure == 4), then swapGrowing (≥ threshold), then leftovers (`leftoverBytes` ≥ 1_000_000_000).
  - `enum CommandKind { case go, container, build, js }`
  - `static func classify(_ command: String, heavy: [String]) -> (kind: CommandKind?, containerIntent: Bool)`. It splits on `\n`, `&&`, `||`, `;` and `|`, trims, and drops leading `NAME=value`, `time`, `env` and `sudo` words before prefix-matching.
    - Kind map: `go`/`golangci-lint` → go; `docker`/`kind`/`kubectl` → container; `make`/`swift`/`cargo`/`bazel`/`bazelisk` → build; `npm`/`npx`/`pnpm`/`pytest` → js.
    - `containerIntent` is true for segments starting `docker run`, `docker compose up`, `kind create cluster` or `docker buildx`.
  - `static func text(trigger: AdviceTrigger, kind: CommandKind?, snapshot: LiveSnapshot) -> String`. The exact copy is below.
  - `struct Throttle { init(directory: URL); func due(key: String, now: Double, minutes: Int) -> Bool; func touch(key: String, now: Double) }`. Keys are validated against `^[A-Za-z0-9._-]{1,128}$`; an invalid key is never due. `touch` creates the directory as needed and sets mtime with `utimes`.

Exact advice copy. GB values come from bytes ÷ 1e9 with one decimal, and growth is shown as `+N.N GB/min`. The sentence starts with a trigger clause:

- critical: `headroom: memory pressure is critical (swap {swap} GB, {growth} GB/min).`
- swapGrowing: `headroom: swap is growing fast ({growth} GB/min, {swap} GB used).`
- leftovers: `headroom: memory is tight.`

Then a kind clause:

- go: ` Prefer go test -p 2 ./<package>/... over the whole module, and one package build at a time.`
- container: ` Avoid starting another container or Kind cluster until pressure drops.`
- build: ` Prefer building one target at a time.`
- js: ` Prefer running one test file or project at a time.`
- nil: ` Prefer narrow builds and tests, and avoid starting containers or clusters right now.`

Then, when `leftoverCount > 0`: ` {n} abandoned container(s) hold {bytes} GB; see headroom leftovers.` The noun is singular for 1.

- [ ] **Step 1: Write failing tests:**
  - `staleSnapshotNeverTriggers`.
  - `criticalBeatsSwapGrowth`.
  - `warnAloneDoesNotTrigger`: pressure 2 with growth 0 gives nil.
  - `leftoversOverAGigTrigger`.
  - `classifyStripsEnvAndChains`: `"cd x && FOO=1 time go test ./..."` gives `.go`; `"echo hi | kind create cluster"` gives `.container` with intent true; `"ls"` gives `(nil, false)`.
  - `adviceTextExact`: one assertion per trigger-and-kind pair listed above, plus the leftover suffix in singular and plural.
  - `throttleDueThenNotThenDue`: due, touch, not due at +4 min, due at +5 min. Uses a temp dir with mtime set via `touch`.
  - `throttleRejectsBadKeys`: `../x` and `a b` are never due and never create files.
  - Config: `agentsDefaultsAndPartial`.
- [ ] **Step 2:** Run `swift test --filter 'PreToolAdviceTests|ConfigTests'`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the same filter. Expect PASS.
- [ ] **Step 5:** Commit: `feat(cli): pre-command advice logic`

### Task 5: `agent-hook pretool` fast path

**Files:**
- Modify: `Sources/HeadroomCLI/Commands/AgentHook.swift`, `Sources/headroom/main.swift`, `Sources/HeadroomCLI/CommandLine.swift`
- Modify: `Sources/headroomd/Recorder.swift` (throttle cleanup)
- Test: `Tests/HeadroomCLITests/AgentHookTests.swift`

**Interfaces:**
- Consumes: Task 1 `LiveStateReader` fields, Task 2 records, Task 4 `PreToolAdvice`.
- Produces: `AgentHook.pretool(tool: String, stdin: () -> Data, snapshot: LiveSnapshot?, now: Double, paths: Paths, config: () -> HeadroomConfig, parentPid: Int32, lookup: (Int32) -> ProcessIdentity?, rules: () -> GroupRules) -> (stdout: String?, spool: [SpoolRecord])`. It's pure enough to test: it reads and writes only through `paths` (throttle dir and spool).

  Order, which is binding:
  1. If the tool isn't in {claude, codex}, return nil.
  2. Read stdin and decode `session_id`, optional `agent_id`, and `tool_input.command`. On any failure, return nil.
  3. Container intent: if `classify(...).containerIntent`, the throttle key `"<session>.<agent>.ci"` (agent omitted when absent) is due at 1 minute, and the root agent resolves via `outermostAgent`, then append `.containerIntent`.
  4. Advice: if `snapshot` is nil or there's no trigger, stop. Otherwise check the throttle key `"<session>.<agent>"` against `adviceMinutes`. If due, output the hook JSON, touch the throttle and append `.agentWarning`.

  Step 3 runs before the trigger check, because ownership must be recorded even when there's no pressure. To keep the budget, step 3 only parses stdin when the snapshot is fresh **or** the cheap `strstr` pre-check finds `docker`, `kind` or `compose` in the raw stdin bytes.
- Hook JSON for **both** tools: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"<text>"}}`. It's encoded with JSONEncoder and printed as one line to stdout. Verify Codex accepts the same shape against current Codex docs; if Codex needs a different field, branch on `tool` and note it in the report.
- `main.swift`: `agent-hook pretool <tool>` routes to `AgentHook.runPretoolFast(tool:)`, which ignores SIGPIPE and exits 0. `agent-hook <tool>` is unchanged.
- Recorder: once an hour, delete files in `pretool/` with mtime older than 1 day.

- [ ] **Step 1: Write failing tests**, using a temp `HEADROOM_ROOT` and fixture snapshots:
  - `noTriggerNoOutputButIntentRecorded`: normal pressure plus `docker run x` gives no stdout, and one `.containerIntent` in the spool.
  - `criticalGivesAdviceOncePerFiveMinutes`: two calls 1 min apart give one output and one `.agentWarning`.
  - `subagentsThrottledSeparately`: different `agent_id` values both get advice.
  - `malformedStdinIsSilent`: covers empty, `not json`, 70 KB of `x`, and JSON with no `tool_input`. Each gives nil stdout, an empty spool, and no files under `pretool/`.
  - `outputJSONShape`: decode stdout and assert `hookSpecificOutput.hookEventName == "PreToolUse"` and that the `additionalContext` text equals the Task 4 copy.
  - `unknownModeOnOldBinaryShape`: `HeadroomCLI.run(["headroom","agent-hook","pretool"])` with no tool returns 0.
  - Bench-gated `pretoolIsFast`: a release binary, 100 runs with a stale live.state, median under 10 ms.
- [ ] **Step 2:** Run `swift test --filter AgentHookTests`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run `swift test --filter AgentHookTests`. Expect PASS.
- [ ] **Step 5:** Commit: `feat(cli): agent-hook pretool advice and container intent`

### Task 6: Docker Unix-socket HTTP client

**Files:**
- Create: `Sources/HeadroomCore/Docker/DockerClient.swift`
- Test: `Tests/HeadroomCoreTests/DockerClientTests.swift`, plus `Tests/HeadroomCoreTests/Support/FakeUnixHTTPServer.swift`

**Interfaces:**
- Produces:
  - `public struct DockerClient: Sendable { public init(socketPath: String, timeout: Double = 2); public func get(_ path: String) throws(DockerError) -> Data }`. It returns the body for a 2xx status and otherwise throws `.status(Int)`.
  - `public enum DockerError: Error, Equatable { case refused, timeout, status(Int), malformed }`. `refused` covers ENOENT, ECONNREFUSED and ENOTSOCK on connect.
- Request details: send `GET <path> HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n`. Read until EOF or until the body is complete. Support `Content-Length` and `Transfer-Encoding: chunked`. Set `SO_NOSIGPIPE` on the socket and `SO_RCVTIMEO`/`SO_SNDTIMEO` to the timeout. The overall deadline is checked against `ContinuousClock`.
- Test helper `FakeUnixHTTPServer`: binds a socket in a temp dir, serves one canned raw response per connection on a background thread, and has a `stop()`.

- [ ] **Step 1: Write failing tests:**
  - `contentLengthBody`.
  - `chunkedBody`, with three chunks including an empty final chunk.
  - `non2xxThrowsStatus` (404).
  - `missingSocketIsRefused`.
  - `serverThatNeverRespondsTimesOut`, with a 0.3 s timeout that returns within 1 s.
  - `serverClosingMidBodyIsMalformed`.
- [ ] **Step 2:** Run `swift test --filter DockerClientTests`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run `swift test --filter DockerClientTests`. Expect PASS.
- [ ] **Step 5:** Commit: `feat(docker): unix-socket http client`

### Task 7: Engine discovery and container models

**Files:**
- Create: `Sources/HeadroomCore/Docker/DockerEngines.swift`, `Sources/HeadroomCore/Docker/DockerModels.swift`
- Test: `Tests/HeadroomCoreTests/DockerEnginesTests.swift`

**Interfaces:**
- Produces: `public struct DockerEngine: Sendable, Equatable { context: String; socketPath: String }`, and `public enum DockerEngines { static func discover(home: URL, environment: [String: String]) -> [DockerEngine] }`.
  - The order is: contexts from `~/.docker/contexts/meta/*/meta.json` (`Name` and `Endpoints.docker.Host` with a `unix://` prefix), then `/var/run/docker.sock` as `default`, then `DOCKER_HOST` as `env`.
  - Socket paths are resolved with `realpath` and deduplicated, keeping the first context name. Non-existent paths are dropped.
- Produces: `public struct DockerContainer: Decodable, Sendable, Equatable { id: String; names: [String]; image: String; labels: [String: String]; state: String }`. It decodes `/containers/json` (`Id`, `Names` with the leading `/` stripped, `Image`, `Labels`, `State`).
- Produces: `public struct ContainerDetail: Sendable { startedAt: Double }`, parsed from `/containers/{id}/json` → `State.StartedAt` (RFC 3339 with fractional seconds).
- Produces: `public static func memoryEstimate(statsJSON: Data) -> UInt64?`, which is `memory_stats.usage - memory_stats.stats.inactive_file`, clamped at 0. It returns nil when usage is missing.

- [ ] **Step 1: Write failing tests:**
  - `discoversContextsAndDedupes`: a temp home with two contexts, one symlinked to the same socket, plus `DOCKER_HOST` gives two engines, with the first-found names kept.
  - `skipsNonUnixAndMissing`.
  - `decodesContainerList`: a fixture JSON with names, labels and state.
  - `parsesStartedAtFractional`.
  - `memoryEstimateSubtractsInactiveFile`, plus a missing-usage case that returns nil.
- [ ] **Step 2:** Run `swift test --filter DockerEnginesTests`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the same filter. Expect PASS.
- [ ] **Step 5:** Commit: `feat(docker): engine discovery and container models`

### Task 8: Grouping, ignores, lifetime labels and the keep list

**Files:**
- Create: `Sources/HeadroomCore/Leftovers/LeftoverItems.swift`, `Sources/HeadroomCore/Leftovers/KeepList.swift`
- Modify: `Sources/HeadroomCore/Config.swift` (`LeftoversConfig`), `Sources/HeadroomCore/Paths.swift` (`leftovers`, `keeps` and `pretool` URLs)
- Test: `Tests/HeadroomCoreTests/LeftoverItemsTests.swift`, `KeepListTests.swift`

**Interfaces:**
- Produces in Config: `public struct LeftoversConfig { afterMinutes: Int = 60; unownedAfterHours: Int = 24; ignore: IgnoreRules }`, where `IgnoreRules { names: [String]; images: [String]; labels: [String] }`. Globs follow phase 1's `*` prefix and suffix rules, and labels are `key` or `key=value`.
- Produces:
  - `public enum LeftoverKind: String, Codable { case kind, compose, testcontainers, container }`
  - `public struct LeftoverItem: Codable, Sendable, Equatable { key: String; engine: String; kind: LeftoverKind; name: String; containerIDs: [String]; sessionId: String? /*testcontainers*/; lifetime: Lifetime?; cleanup: [String] }`
  - `public enum Lifetime: Codable, Equatable { case keep, temporary, duration(Double) }`, parsed by `Lifetime(label:)` from `keep`, `temporary`, `Nm`, `Nh` and `Nd`. Anything else is nil.
- Produces: `public enum LeftoverGrouper { static func group(_ containers: [DockerContainer], engine: String, ignore: IgnoreRules) -> (items: [LeftoverItem], reapers: Set<String> /*testcontainers sessionIds with a live ryuk*/) }`.
  - Only `state == "running"` containers count.
  - **Built-in ignores** are always applied:
    - names `buildx_buildkit*` and `testcontainers-ryuk*`, plus `kind-registry`;
    - images `moby/buildkit*` and `registry:*`;
    - the label `io.kubernetes.pod.name`, and the label `org.testcontainers.reuse.enable=true`.
  - **Grouping precedence:** kind label `io.x-k8s.kind.cluster`, then `com.docker.compose.project`, then `org.testcontainers=true`, then a single container.
  - **Lifetime:** the shortest lifetime among the members, where `keep` beats everything and `temporary` counts as zero.
  - **Key format:** `<engine>/<kind>/<cluster|project|sessionId|id>`.
  - **Cleanup commands.** Every name and id is single-quoted with `'` escaped as `'\''`:
    - kind: `docker --context '<ctx>' stop <'node'…>` and `DOCKER_CONTEXT='<ctx>' kind delete cluster --name '<name>'`;
    - compose: `docker --context '<ctx>' compose -p '<project>' down`;
    - testcontainers and container: `docker --context '<ctx>' rm -f <'id'…>`.
- Produces: `public struct KeepList: Codable { entries: [KeepEntry] }`, with `KeepEntry { name: String; until: Double? }`.
  - `static func load(from: URL) -> (KeepList, warning: String?)`. A missing file is empty with no warning; an invalid file is empty with a warning.
  - `func save(to: URL) throws`, using a temp file and rename.
  - `func covers(_ item: LeftoverItem, now: Double) -> Bool`. It matches `name` against `<ctx>/`-optional forms of the container name, `compose:<project>` or `kind:<cluster>`. An expired entry doesn't cover.

- [ ] **Step 1: Write failing tests:**
  - `groupsKindComposeTestcontainersAndSingles`: a fixture of 7 containers gives 4 items with the expected keys.
  - `builtInIgnores`: buildkit, `registry:3`, ryuk and a k8s-pod container are all excluded, with the ryuk sessionId in `reapers`.
  - `configIgnoreByImageAndLabel`.
  - `lifetimeParsing`: `keep`, `temporary`, `8h` → 28800, `7d`; `abc` gives nil.
  - `shortestLifetimeWinsInCompose`.
  - `cleanupCommandsExactAndQuoted`, with a project named `my app's` → `docker --context 'orbstack' compose -p 'my app'\''s' down`. Assert no command contains `prune` or `-v`.
  - `keepListCoversByFormsAndExpires`.
  - `malformedKeepsIsEmptyWithWarning`.
  - `keepSaveIsAtomic`: the temp file is gone after save.
- [ ] **Step 2:** Run `swift test --filter 'LeftoverItemsTests|KeepListTests'`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the same filter. Expect PASS.
- [ ] **Step 5:** Commit: `feat(leftovers): grouping, ignores, lifetime labels and keep list`

### Task 9: Leftover decision policy (pure)

**Files:**
- Create: `Sources/HeadroomCore/Leftovers/LeftoverPolicy.swift`
- Modify: `Sources/HeadroomCore/Store/Queries.swift` (facts)
- Test: `Tests/HeadroomCoreTests/LeftoverPolicyTests.swift`, `QueriesTests.swift`

**Interfaces:**
- Produces: `public struct OwnershipFacts: Sendable`. It has:
  - `intents: [(ts: Double, root: ProcessKey)]`;
  - `runs: [ProcessKey: RunFacts]`;
  - `awakeSeconds: (Double, Double) -> Double`, the recorded awake seconds between two times, as a Sendable closure.

  `RunFacts { sessionIds: Set<String>; ended: Double?; lastIntent: Double?; activeMinutes: [Double] /*minute starts with active_seconds > 0*/ }`.
- Produces: `public enum LeftoverDecision: Equatable { case leftover(reason: String), notYet, kept, ignored }`, and `public enum LeftoverPolicy { static func decide(_ item: LeftoverItem, startedAt: Double, facts: OwnershipFacts, keeps: KeepList, reapers: Set<String>, now: Double, config: LeftoversConfig) -> LeftoverDecision }`. The rules apply in order:
  1. If `keeps.covers` is true, the result is `.kept`.
  2. **Lifetime label:**
     - `keep` gives `.kept`;
     - a duration gives `.leftover("older than its <label> lifetime")` once `now - startedAt ≥ d`, otherwise `.notYet`;
     - `temporary` sets the threshold to 0 for rule 4.
  3. **Testcontainers:** a session with no live reaper (sessionId not in `reapers`) is `.leftover("its test run finished")`.
  4. **Owner:** the run whose intent `ts` is the latest at or before `startedAt` and within 600 s. A live run sharing any `sessionId` with the owner replaces it.
     - The owner is done if it ended, or if `awakeSeconds(lastIntent ?? started, now) ≥ afterMinutes*60`. A `temporary` lifetime makes the threshold 0, so the item is done as soon as the owner has ended or shown no intent in the last 0 s.
     - If done: `.leftover("the agent session that started it is done")`. Otherwise: `.notYet`.
  5. **Fallback with no intents near `startedAt`:** the owners are runs with an active minute equal to `floor(startedAt/60)*60` or the minute before. They're done as in rule 4, using their last active minute in place of the last intent.
  6. **No owner:** `.leftover("running for more than <N> hours with no agent owner")` when `now - startedAt ≥ unownedAfterHours*3600`, otherwise `.notYet`.
- Produces: `Queries.ownershipFacts(machineId: String, since: Double, now: Double) throws(DatabaseError) -> OwnershipFacts`.
  - It reads intents (Task 2), and `agent_runs` joined with `agent_run_sessions` for runs active since `since`.
  - It reads `run_usage` active minutes per candidate run through its primary key.
  - `awakeSeconds` is the count of `samples` in a range × 10, plus the minute rollups when the range is beyond raw retention.

- [ ] **Step 1: Write failing tests**, one per rule, with fixed timestamps:
  - `keepListWins`, `labelKeep`, `durationNotYetThenLeftover` (`7d` at 6 d and at 8 d).
  - `temporaryLeftoverAsSoonAsOwnerEnds`.
  - `testcontainersWithoutReaper`.
  - `closestIntentOwns`: two runs with intents at −300 s and −30 s; the −30 s run owns.
  - `intentTooOldIsNotOwner`: 700 s means the fallback path.
  - `ownerIdleSixtyAwakeMinutesIsDone`, using an `awakeSeconds` that excludes a 10 h sleep, so it's not done after 8 h of wall time.
  - `resumedSessionKeepsOwnership`.
  - `fallbackActiveMinuteOwner`.
  - `unownedAfter24h`.
  - Queries: `ownershipFactsFromSeededDB`.
- [ ] **Step 2:** Run `swift test --filter 'LeftoverPolicyTests|QueriesTests'`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the same filter. Expect PASS.
- [ ] **Step 5:** Commit: `feat(leftovers): ownership and lifetime decision policy`

### Task 10: Leftover monitor in `headroomd`

**Files:**
- Create: `Sources/HeadroomCore/Leftovers/LeftoverMonitor.swift`, `Sources/HeadroomCore/Leftovers/LeftoverState.swift`
- Modify: `Sources/headroomd/Recorder.swift`
- Test: `Tests/HeadroomCoreTests/LeftoverMonitorTests.swift`

**Interfaces:**
- Produces:
  - `public struct LeftoverState: Codable, Sendable, Equatable { updated: Double; engines: [EngineStatus]; items: [FlaggedItem] }`
  - `EngineStatus { context: String; socket: String; lastPass: Double; ok: Bool; failures: Int }`
  - `FlaggedItem { item: LeftoverItem; startedAt: Double; reason: String; memoryBytes: UInt64?; firstFlagged: Double }`
  - `LeftoverState.load(from:)` (missing or invalid gives empty) and `save(to:)` (atomic rename).
- Produces: `public struct LeftoverMonitor: Sendable`, built as `init(engines: () -> [DockerEngine], client: (String) -> DockerClient, config: LeftoversConfig)`. Its method `pass(previous: LeftoverState, facts: OwnershipFacts, keeps: KeepList, now: Double, deadline: Double) -> (state: LeftoverState, events: [(kind: String, payload: [String: String])])`.
  - **Per engine:** a list call, then group, decide, and up to 20 detail/stats calls shared across engines, for candidates only. Candidates are items not already decided `.kept`/`.ignored` and old enough to matter.
  - **On `refused`,** drop that engine's items. **On `timeout` or `malformed`,** keep its items for up to 3 consecutive failures, then drop them. The deadline is checked between calls.
  - **Events:**
    - a newly flagged item emits `leftover`;
    - an item gone or no longer flagged emits `leftover_cleared`.

    The payload is `["kind": k, "ref": first 12 hex of SHA256(key), "bytes": "<n or 0>", "totalBytes": "<sum after change>"]`.
- Recorder wiring:
  - Every 30th tick (5 min), on a private serial `DispatchQueue`, run `pass` with `deadline = now + 10`. Ownership facts are read on that queue from a read-only `Database`/`Queries`, a separate connection with busy timeout 2000. Hop back to the main actor.
  - On the main actor: save the sidecar, call `store.recordEvent` for each event (persisted at the next flush), and set `live.state` `leftoverCount` and `leftoverBytes` on the next snapshot writes.
  - Skip a pass while the previous one is still running.

- [ ] **Step 1: Write failing tests**, using the Task 6 fake server and a temp DB:
  - `flagsUnownedAfter24hAndEmitsEvent`.
  - `clearsWhenContainerGone`: emits `leftover_cleared` with a matching `ref`.
  - `refusedEngineDropsItems`.
  - `timeoutKeepsForThreePasses`.
  - `deadlineStopsStatsCalls`: 30 candidates and a fake server that's slow on stats. At most 20 stats calls, and the pass returns before the deadline plus 1 s.
  - `memoryFromStatsEstimate`.
  - `sidecarRoundTripAndAtomic`.
  - `noNamesInEventPayloads`: the payload values never contain any container name from the fixture.
- [ ] **Step 2:** Run `swift test --filter LeftoverMonitorTests`. Expect FAIL.
- [ ] **Step 3: Implement the monitor and the Recorder wiring.**
- [ ] **Step 4:** Run `swift test --filter LeftoverMonitorTests`, then the full `swift test` once. Expect PASS.
- [ ] **Step 5:** Commit: `feat(recorder): background leftover detection`

### Task 11: CLI surfaces: status line, `leftovers`, `keep`, `status`

**Files:**
- Modify: `Sources/HeadroomCLI/Commands/StatusLine.swift`, `CommandLine.swift`, `Commands/Status.swift`
- Create: `Sources/HeadroomCLI/Commands/Leftovers.swift`
- Test: `Tests/HeadroomCLITests/StatusLineTests.swift`, `LeftoversCommandTests.swift`, `StatusTests.swift`, `CommandLineTests.swift`

**Interfaces:**
- **Status line:** a `{leftovers}` token renders `⚑ {n} leftover(s) · {bytes} GB` (decimal, one decimal place), or empty when the count is 0. The default template becomes `"{mem} {swap} · {cpu} · {disk} · {agents} · {leftovers}"`, and empty segments drop as before.
- **Commands:**
  - `.leftovers(json: Bool, kept: Bool)`
  - `.keep(name: String, forSeconds: Double?)`, from `--for 8h|7d`
  - `.unkeep(name: String)`
  - `.keeps`
- **`headroom leftovers`** prints one block per flagged item:

  ```
  <engine>/<kind> <name> · <reason> · <memory or "memory unknown"> · up <age>
    <cleanup command 1>
    <cleanup command 2>
  ```

  or `no abandoned containers`. With `--json` it prints the sidecar `items` as JSON. With `--kept` it also lists kept and ignored items with their reason. That means the sidecar also stores `kept: [ { key, why } ]`; add it to `LeftoverState`.
- **`keep` / `unkeep`** load, modify and save `keeps.json` atomically. `keeps` lists the entries with their expiry.
- **`status`** adds `docker <context> ok|unreachable · last checked <m>m ago`, one line per engine, from the sidecar. It prints `docker not checked yet` when there's no sidecar.

- [ ] **Step 1: Write failing tests:**
  - Status line: `leftoversTokenSingularPlural`, `emptyWhenNone`, `defaultTemplateIncludesLeftovers`.
  - `leftoversCommandListsAndQuotes`, `leftoversJSON`, `keptListed`.
  - `keepAddsEntryWithExpiry`, `unkeepRemoves`, `keepWithBadDurationIsUsageError`.
  - `statusShowsEngines`.
  - The parse tests for the new commands.
- [ ] **Step 2:** Run `swift test --filter 'StatusLineTests|LeftoversCommandTests|StatusTests|CommandLineTests'`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the same filter. Expect PASS.
- [ ] **Step 5:** Commit: `feat(cli): leftovers, keep list and status line token`

### Task 12: `top` leftovers pane and report lines

**Files:**
- Modify: `Sources/HeadroomCLI/TUI/TopRenderer.swift`, `TopCommand.swift`
- Modify: `Sources/HeadroomCore/Report/ReportModel.swift`, `PDFReport.swift`, `Sources/HeadroomCore/Store/Queries.swift`
- Test: `Tests/HeadroomCLITests/TopRendererTests.swift`, `Tests/HeadroomCoreTests/ReportTests.swift`

**Interfaces:**
- **`TopState`** gains `leftovers: [FlaggedItem]` and `showLeftovers: Bool`.
  - The header right side appends ` · ⚑ {n}` when n > 0.
  - Key `l` toggles a pane titled `── leftovers ({n})`, with rows of kind, name, reason, memory and age. The cleanup commands aren't shown; that's for `headroom leftovers`.
- **Queries:**
  - `agentWarningCount(machineId:from:to:) throws(DatabaseError) -> Int`
  - `leftoverPeakBytes(machineId:from:to:) throws(DatabaseError) -> UInt64?`, the max `totalBytes` over `leftover` and `leftover_cleared` events.
- **Report appendix lines,** each shown only when non-zero:
  - `Agents were advised to narrow work {n} time(s) while memory was critical.`
  - `Abandoned containers held up to {x} GB at their peak.`

  No names appear.

- [ ] **Step 1: Write failing tests:**
  - `headerShowsLeftoverMarker`, `leftoversPaneRows`, `leftoversPaneFitsWidth` (widths 20, 40 and 80).
  - `appendixAdviceAndLeftoverLines`.
  - `privacyNoContainerNamesInPDF`: seed events and a sidecar with a distinctive name, and assert it's absent from the PDF text.
- [ ] **Step 2:** Run `swift test --filter 'TopRendererTests|ReportTests'`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the same filter. Expect PASS.
- [ ] **Step 5:** Commit: `feat: leftovers in top and report`

### Task 13: MCP server and registration

**Files:**
- Create: `Sources/HeadroomCLI/MCP/MCPServer.swift`, `Sources/HeadroomCLI/MCP/MCPTools.swift`
- Modify: `CommandLine.swift` (`.mcp`), `Commands/Install.swift`
- Test: `Tests/HeadroomCLITests/MCPServerTests.swift`, `InstallTests.swift`

**Interfaces:**
- **`MCPServer`** is built as `init(paths: Paths, now: @escaping @Sendable () -> Double)`.
  - `func handle(line: Data) -> Data?` returns one JSON line, or nil for notifications.
  - `func serve(input: FileHandle, output: FileHandle)` reads lines until EOF, writes each response followed by `\n`, and flushes.
  - **Methods:**
    - `initialize` replies with `protocolVersion` (the newest version both Claude Code and Codex accept; verify, and record it in the report), `capabilities: {tools: {}}` and `serverInfo: {name: "headroom", version}`.
    - `notifications/initialized` gets no reply.
    - `ping` replies `{}`.
    - `tools/list` and `tools/call`.
  - **Errors:**
    - a parse failure returns -32700 with `id: null`;
    - an unknown method returns -32601;
    - bad parameters or an unknown tool return -32602;
    - `tools/call` before `initialize` returns -32002 with the message `not initialized`.
- **Tools.** The input schemas are JSON Schema objects. Each result is `{content: [{type: "text", text: "<summary>\n<compact JSON>"}]}`. A tool failure, such as an unreadable DB, gives `isError: true` with the message.
  - `current_status`: live.state; today's limit seconds (`Queries.todayLimitSeconds`); top groups now (the last minute of `group_samples`); top processes (the latest `top_procs_1m`); live agent runs (open `agent_runs` with their last `run_usage` minute); leftovers (from the sidecar).
  - `query_metric {metric, from, to, resolution}`. `metric` must be one of the `Metric` raw values. `auto` picks minutes for ranges of 6 h or less. Results are capped at 500 points.
  - `explain_slowdown {at, windowMinutes=30}`. It returns:
    - the limit seconds per kind in the window;
    - the max `memDemand`, pressure and swap;
    - the top 3 groups by CPU and by memory;
    - the top processes if within raw retention;
    - the agent runs with usage in the window;
    - leftover count and bytes from events;
    - the events in the window.
  - Time parsing is `MCPTime.parse(_ s: String, now: Double, calendar: Calendar) -> Double?`. It accepts ISO 8601 with or without an offset (local time when there's none) and relative forms `-Nm`, `-Nh` and `-Nd`.
- **Registration.** `Install.run(agents: true)` calls `mcpRegister(runner:)`, with `runner` an injectable `([String]) -> (status: Int32, stdout: String)`.
  - For each of `claude` and `codex` found on PATH:
    - run `<cli> mcp list`;
    - if the output contains `headroom`, skip;
    - otherwise run `claude mcp add --scope user headroom -- <abs> mcp` or `codex mcp add headroom -- <abs> mcp`.
  - `uninstall` runs `<cli> mcp remove headroom` (Claude: `--scope user`), ignoring failures.
  - Verify the flags against the installed CLIs, and note any difference in the report.

- [ ] **Step 1: Write failing tests:**
  - `initializeThenToolsList`.
  - `callBeforeInitializeErrors`.
  - `malformedLineIsParseErrorAndServerContinues`.
  - `notificationGetsNoReply`.
  - `unknownToolIsInvalidParams`.
  - `queryMetricAutoResolution`: a 2 h range uses minutes and a 2-day range uses hours.
  - `explainSlowdownShape`, against a seeded DB.
  - `relativeAndISOTimes`.
  - `serveStopsOnEOF`, via a pipe.
  - Install: `mcpRegistersWhenAbsentAndSkipsWhenPresent`, using a fake runner.
- [ ] **Step 2:** Run `swift test --filter 'MCPServerTests|InstallTests'`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the same filter. Expect PASS.
- [ ] **Step 5: Smoke test.** Run `printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"<v>","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | HEADROOM_ROOT=<temp> .build/debug/headroom mcp`. Expect two JSON lines.
- [ ] **Step 6:** Commit: `feat(mcp): read-only stdio server with three tools; register on install`

### Task 14: README, spec sync and end-to-end check

**Files:**
- Modify: `README.md`, `docs/superpowers/specs/2026-11-14-headroom-phase1.5-design.md` (record what you verified: the hook JSON, the MCP version and the CLI flags)

- [ ] **Step 1: README.** Add these sections:
  - **Advice for agents:** what triggers it, and that it's advice only.
  - **Abandoned containers:** the label and its values, with a compose `labels:` example; `headroom keep`; the built-in ignores; the 24 h unowned rule.
  - **MCP:** the tools, and a note that output reaches the model provider.
  - Update the status line example.
- [ ] **Step 2: Run `swift test`.** Expect all to pass, with bench tests skipped.
- [ ] **Step 3: Run `make install`.** Then check:
  - `headroom install --agents`. This is approved for the owner's machine in this phase: it's the feature being shipped, and it backs up the files it edits.
  - `headroom status` shows a docker line within 5 minutes.
  - `headroom leftovers --kept` lists the registry and BuildKit containers as ignored.
  - `claude mcp list` shows `headroom`.
  - `headroom statusline --no-color`.

  Paste every output into the report.
- [ ] **Step 4:** Commit: `docs: phase 1.5 README and spec notes`

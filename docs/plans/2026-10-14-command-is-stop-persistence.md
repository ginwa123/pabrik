# Plan — `command` tool: `is_stop` + `persistence`

- **Task**: `task_1791972455755_8` — "add new parameter to ai agent command"
- **Worktree**: `~/.config/pabrik/.worktrees/add-new-parameter-to-ai-agent-command-1791972429011`
- **Branch**: `worktree/add-new-parameter-to-ai-agent-command-1791972429011` (base `main`)
- **Status**: PLAN — awaiting human decisions (§7) before any code

---

## 1. The ask (verbatim)

> is_stop mean ai agent will stop in while loop workflow immediately, and maybe will
> start agent if the long command process running is send a output, and persistence mean
> it will run a for example command `pnpm run dev` that stay in memory for a long time.

Three requirements, in increasing order of size:

| # | Requirement | Shape |
|---|---|---|
| R1 | `is_stop` — the agent ends its loop from inside a tool call | small, self-contained |
| R2 | `persistence` — a long-lived process (`pnpm run dev`) that "stays in memory" | medium; a new execution lifecycle |
| R3 | "start agent if the long command process … send a output" — wake the agent on new output | medium; the only genuinely new runtime |

---

## 2. What already exists — do NOT rebuild

Everything below was read at `main` (`4486797c`) and is load-bearing for this plan.
The goal is to add **two parameters**, not a second process subsystem.

### 2.1 A long-running process already works

`command` already has `background: bool`:

- `src/modules/agent/tools/command.zig:170-182` — the LLM-facing `background` param.
- `src/modules/agent/tools/shell.zig:1210-1230` — `input.background` forks to
  `spawn_background` **before** the foreground path, and is deliberately exempt from
  the `mandatory_timeout` check and the 60 s cap.
- `src/modules/agent/tools/shell.zig:1523-1600` — `spawn_background` builds
  `nohup {cmd} > {tmp}/bg_{ms}.log 2>&1 & echo $!` on POSIX and
  `Start-Process -NoNewWindow …` on Windows (`backgroundSpec`, pure + host-testable),
  spawns it in the caller's `cwd`, and returns `"PID: {pid}\nLog: {path}"`.
- `src/agentic_loop/tools_exec_command.zig:60-106` — parses that stdout, writes the row
  to `session_background_process`, emits `background_process_created`, and schedules
  `background_watcher.spawnCompletionWatcher`.

### 2.2 The process registry, notification and wake path already exist

- **Table**: `session_background_process(session_id, pid, command, log_path, started_at, status)`
  — migration 014 (`src/migrations/migration.zig`, `Migration014AddBackgroundProcess`).
- **CRUD**: `src/agentic_loop/background_process.zig` — `save` / `getBySession` /
  `getRunning` / `updateStatus` / `delete` / `killProcess` / `killAllForSession`.
- **Immediate completion watcher**: `src/agentic_loop/background_watcher.zig` —
  fire-and-forget Io task on `di.group_bg_watchers`, polls `isProcessRunning(pid)` every
  2 s, and on exit inserts the completion queue message + wakes the session.
- **Cron fallback**: `src/schedulers/cleanup_stale_background_process.zig` — every minute;
  notify-then-delete for dead PIDs only (no time-based reaping, so a live server is safe).
  `wakeSessionForCompletion` emits `run_agent` with `skip_initial_queue_message=true`.
- **SSE**: `src/agentic_loop/background_process_events.zig` —
  `background_process_created` / `background_process_completed` on routing key
  `background_process`.
- **HTTP**: `GET /api/llm/session/:id/background_processes`
  (`src/http_handlers/background_processes_list.zig`), row includes a live
  `running` bool.
- **Frontend**: `components/preview/BackgroundCommandsPopup.vue`
  (+ `api/__tests__/backgroundProcesses.spec.ts`) renders the list; it used a 5 s poll
  before the SSE push landed.
- **Wake drains mid-run**: `workflow.zig` re-reads queued messages at the top of every
  loop iteration (`getQueueMessage`) and on `finish_reason == .stop`
  (`hasQueuedMessages → continue`). So a completion queued while a run is in flight is
  picked up by the next iteration — no special case needed.

### 2.3 The loop, and why `is_stop` has a natural seam

`workflow.zig:831` `while (true)`, and the decision point at `workflow.zig:1560-1760`:

- `finish_reason == .stop` → persist, `deleteWorker`, **`break`** (ends the turn).
  Note: **empty content `continue`s instead** (`workflow.zig:1568-1576`) — a model that
  returns nothing does *not* end the loop.
- `finish_reason == .tool_calls` → `handle_tool(...)` → **falls through, loops back**
  for another LLM call. This is the arm `is_stop` has to override.
- `ask_user` pending → `break` (the precedent for "a tool ends the turn").
- `isWorkerCancelled` → `break` (the out-of-band Stop button).

`handle_tool` (`src/agentic_loop/handle_tool.zig:466`) currently returns `!void`, and has
**exactly one caller** (`workflow.zig:1676`) — so widening its return type is a two-file
change, not a refactor.

`ToolExecResult` (`src/agentic_loop/tools.zig:157`) is the established channel for
"the tool wants to change the loop": it already carries `temperature`, `is_thinking`,
`skill_save`, `agent_save`, `progressive_tool_save`. A `stop_loop: bool` belongs there.

### 2.4 Arg parsing already has a lenient, LLM-proof seam

`src/agentic_loop/tools_exec_bash_args.zig` — `parseShellArgs` parses
`std.json.Value` and coerces field-by-field, with `NUMERIC_*_FIELDS` / `BOOL_FIELDS` /
`STRING_FIELDS` tables and structured `InvalidField` errors. Two new booleans are one
table entry each; nothing new is needed.

---

## 3. The actual gaps

Numbered so the task list in §6 can cite them.

| id | Gap | Evidence |
|---|---|---|
| **G1** | **No way to read a running process's output.** The model must issue a *second* `command` call (`tail -n 50 <log_path>`) and carry the path across turns. Two extra LLM round-trips per poll, and the path is easily dropped by compaction. | `shell.zig:1523` returns the path; nothing in the agent surface reads a log by PID. |
| **G2** | **No output-driven wake exists.** `background_watcher` polls `isProcessRunning(pid)` — it fires on *exit only*. A dev server exits once, eventually, so R3 is unimplemented. The 24 h `watcher_max_iters` cap then retires the watcher silently (`background_watcher.zig:81-96`). | `background_watcher.zig:88-96`. |
| **G3** | **`kill <pid>` does not kill the tree.** The recorded PID is the *shell's* child (`nohup cmd &`), and `pnpm run dev` spawns its own child (vite → esbuild). Killing the recorded PID routinely leaves grandchildren holding the port. The foreground path already solves this (`.pgid = 0` at spawn + `kill(-pgid)`); the background path does not. | `shell.zig:1215` (foreground, `.pgid = 0`) vs `shell.zig:1523-1600` (background, no pgid). `background_process.killProcess` = single-PID `TerminateProcess`/`kill`. |
| **G4** | **The row carries no lifecycle state.** No `kind` (build vs service), no handle/name, no byte offset of what the agent has already been shown. | migration 014 columns, §2.2. |
| **G5** | **The prompt forbids the use case.** The `command` description says: "No unbounded output, no destructive commands, **no dev servers (`vite`, `http.server`, `nohup ... &`)**". Today the model is told *not* to start `pnpm run dev` at all. | `command.zig:113`; `command.zig:96` ("never start dev servers"). |
| **G6** | **PID reuse.** `isProcessRunning(pid)` is the only liveness signal; after a reboot or PID wrap a stale row can read as alive. Low probability, cheap to harden (compare `started_at` + command). | `background_process.zig:isProcessRunning`. |
| **G7** | **FOUND WHILE PLANNING — the completion envelope no longer matches the frontend parser.** Backend `buildCompletionMessage` emits **JSON** (`{"pid":…,"command":…,"stdout":…,"truncated":…,"total_bytes":…,"log_path":…}`, `background_process.zig:283-330`) and `tests/functional/background_command_completion_test.zig:413` asserts `"pid":`. Frontend `helpers/isBackgroundCommandOutput.ts` only recognises `<background_command>` **XML** or a legacy prose prefix, and `ChatView.vue:2052` gates the shell-card rendering on it. So a background completion is currently queued as JSON and rendered as a raw-JSON user bubble. Regression from commit `ff69c587` ("Agent tool output XML to JSON migration (hard cut)", #563), which moved the backend and not the helper. | `helpers/isBackgroundCommandOutput.ts:52` vs `background_process.zig:283`. |

**G7 is a prerequisite for R2/R3, not a side quest**: persistence output reuses exactly
this channel, so without the fix the user sees JSON in a chat bubble instead of a card.
Verify with one functional replay before touching anything (see §6 T0).

---

## 4. Design

### 4.1 R1 — `is_stop`

**Semantics (proposed): end the agent's turn after the current tool batch finishes.**
Run the command, persist every result, then `break` — exactly what `ask_user` does today.
It is *not* the Stop button (`isWorkerCancelled` kills work in flight and is the user's
lever); `is_stop` is the model's own "I am done" signal.

Why "after the batch", not "immediately":
`handle_tool` runs a 3-phase protocol whose whole point is that **every `tool_call_id`
gets a matching `role=tool` row** (Phase 1 placeholders, `handle_tool.zig:490-560`).
Aborting mid-batch would leave dangling `tool_call_id`s and the next turn would be
rejected by the provider. So `handle_tool` dispatches the whole batch, OR-merges
`stop_loop` across the batch, and returns it.

Plumbing (all four files already identified above):

| step | file | change |
|---|---|---|
| 1 | `tools_exec_bash_args.zig` | `parseShellArgs` returns a wrapper `CommandArgs{ shell: ShellInput, is_stop: bool }` (recommended) — keeps `shell.zig` free of loop concerns. `BOOL_FIELDS += "is_stop"`. |
| 2 | `src/agentic_loop/tools.zig:157` | `ToolExecResult.stop_loop: bool = false` |
| 3 | `tools_exec_command.zig` | set `.stop_loop = args.is_stop` on the result |
| 4 | `handle_tool.zig` | return `!ToolBatchOutcome{ .stop_loop: bool }`; OR-merge in Phase 3; add `stop_loop` to the `defer`-free early-`continue` paths (unknown tool / MCP / hook short-circuit) where the value is false by construction |
| 5 | `workflow.zig:1676` | `const outcome = try handle_tool(...)`; in the `.tool_calls` arm, after the `ask_user` check: persist `last_finish_reason = "stop"`, `deleteWorker`, `break` |
| 6 | `command.zig` | schema + description text for `is_stop` (and fix G5 in the same edit) |

Guard rails to decide in review:

- **`is_stop` + `background`/`persistence` is legal and encouraged** — "start the dev
  server, then end my turn" is the single most useful combination. It must not be
  rejected by a naive "is_stop requires a foreground command" rule.
- **Non-blocking on empty content.** Because `finish_reason == .tool_calls` normally has
  no prose, `is_stop` must instruct the model (in the param description) to put its final
  answer in the assistant `content` of the same message. Otherwise the turn ends on a bare
  tool card. This is a prompt contract, and the plan's functional test must pin it.
- **Sub-agents** hit the same code path, so `is_stop` gives a sub-agent an explicit bound.
  That is a feature, not a leak — but the description should say "ends *this* agent's turn".
- `is_stop` on the *placeholder* path: a batch where one call is an unknown tool still
  returns the outcome; the unknown-tool `continue` must not drop it.

### 4.2 R2 — `persistence`

`persistence=true` is **a superset of `background=true`, and not a synonym**:

> `background` — "long job, outlives the call, notify me when it finishes" (today: builds).
> `persistence` — "session-scoped service, stays alive, let me read/stop it, and tell me
> when it says something interesting" (today: `pnpm run dev`).

Reuse everything in §2.2; add only:

**a. A `kind` + a handle.** Migration 107, on `session_background_process`:

```sql
ALTER TABLE session_background_process ADD COLUMN kind TEXT NOT NULL DEFAULT 'job';
-- 'job' | 'service'
ALTER TABLE session_background_process ADD COLUMN name TEXT;         -- optional label
ALTER TABLE session_background_process ADD COLUMN last_read_offset INTEGER NOT NULL DEFAULT 0;
ALTER TABLE session_background_process ADD COLUMN wakes_sent INTEGER NOT NULL DEFAULT 0;
```

`kind` matters in three places: the completion message wording ("your dev server
exited" vs "the build finished"), the popup badge, and the wake policy (a `job` never
gets output wakes).

**b. A read surface that does not cost an LLM round-trip per poll.**

Recommended: **a new `process` tool** (`read` / `stop` / `list`) rather than three more
parameters on `command`. Reasons:

- `command` already has 8 params, 3 of them required; two more booleans (10) plus a read
  and a stop action (12+) makes it the tool most likely to be mis-invoked.
- A `process` call means "act on a thing I already started", not "run a shell command" —
  it should not need `cwd` and `mandatory_timeout`, both of which are *required* on
  `command`. Making them conditionally-required is exactly the kind of schema the lenient
  parser exists to paper over.
- The registry is a flat table (`tools_equipped.UNIFIED_TOOL_REGISTRY`) and a new entry
  there is cheap; `isKnownToolOrMCP`, the Lua pre/post hooks, secret substitution and the
  progressive catalog all cover it for free.

Alternative (A), if you prefer one tool: `persistence` stays a boolean and `command`
grows `persistence_action: "start"|"read"|"stop"|"list"` + `persistence_id: number`.
Cheap to build, worse to describe. **Recommendation: B.**

`read` returns the **delta** since `last_read_offset` (head-capped at 20 KiB, reusing
`bg_proc.completion_log_cap_bytes`) and advances the offset — so a poll loop is one call
per poll and never re-reads what the model has already seen. `stop` kills the process and
marks the row `killed`; `list` is the same data as the HTTP endpoint.

**c. A real detach + a tree kill (G3).** This is the riskiest item and deserves its own
review. Today's `nohup cmd & echo $!` gives a PID whose process group is the *spawning
shell's* — so `kill(-pgid)` would kill our own shell, and single-PID kill orphans
vite/esbuild. Options:

- **(c1) Native detached spawn, recommended.** Reuse the *foreground* pipeline's spawn
  (`.pgid = 0`, `shell.zig:1215`) but redirect stdout/stderr to the log file instead of
  pipes, record `(pid, pgid == pid)`, and hand reaping to the watcher thread
  (`waitpid(WNOHANG)` — which also yields a real exit code for the completion message).
  This deletes `nohup`/`Start-Process` quoting, `tempDirFor` and `quotePwsh` from the
  background path. `stop` becomes `kill(-pid)` on POSIX, `taskkill /T /F /PID` on Windows.
  Keep the plan pure-data (`stopPlan(os_tag) []StopKill`, mirroring `timeoutKillPlan`,
  `shell.zig`), so both arms are assertable from a Linux runner — required by the
  "every test handles every platform" rule in `CODING_STANDARDS.md` §2.
- (c2) Keep the shell detach and add `setsid` on Linux. Rejected as the primary path:
  `setsid` is a util-linux binary and does **not** exist on macOS, so it would need a
  third per-OS arm anyway, and we would still be parsing a shell's `$!` instead of owning
  the PID.
- (c3) Ship `stop` as best-effort single-PID kill, documented. Acceptable as a Phase-1
  stopgap only; a dev server that keeps answering on its port after "stop" is worse than
  no stop button.

Windows caveat to state explicitly in the PR: no Job Objects, so `taskkill /T` is a
best-effort tree walk; a Windows-child detach is out of scope for Phase 1.

**d. Survive a pabrik restart.** The DB row survives; the in-memory watcher does not.
Proposed: on boot, re-arm watchers for every `status='running'` row whose PID is alive
(one pass, reuse `spawnCompletionWatcher`), and mark the rest `orphaned`. `list` already
computes liveness live, so the UI stays honest either way.

### 4.3 R3 — wake on new output

Deliberately **not** "wake on every write". A dev server prints on every request; an
unbounded wake is an unbounded LLM bill. Any implementation must debounce, settle, cap
and rate-limit. Design:

- New `src/agentic_loop/persistence_watcher.zig`, shaped like `background_watcher.zig`:
  fire-and-forget on `di.group_bg_watchers`, poll 1 s, `logger` on every failure,
  never panic, never block the caller.
- **Fire when** `log_size > last_notified_offset` **AND** one of:
  - the file has been **quiet for `settle_ms`** (default 1500) — the common case, and it
    collapses a burst of HMR lines into one wake; or
  - the pending delta reached `flush_bytes` (default 8 KiB) — so a chatty process cannot
    starve behind the settle window.
- **Rate limit**: at most one wake per `min_interval_ms` (default 10 000) and at most
  `max_wakes` (default 20) per process. On hitting the cap, the last message says so
  ("further notifications suppressed — `process read <pid>` for the log") and the watcher
  retires. This is the knob that keeps R3 from becoming a cost incident.
- **Arming**: decision needed (§7.3). Recommendation: **opt-in** — `persistence=true`
  starts it silent, and the agent (or user) arms wakes once it has seen the output rate.
  Automatic-on-start is available as a config default if you want it.
- **Delivery**: reuse `insertQueueMessage` + `wakeSessionForCompletion` verbatim. A
  running worker drains it on its next iteration; an idle session gets an `emit_run_agent`.
- **Envelope**: the same `background_command`-shaped message as G7 — which is why G7
  comes first, and why the new message should carry `action:"output"` vs the existing
  `action:"completed"` discriminator so the card can say "new output" vs "exited".

### 4.4 G7 — fix the completion envelope first

Two options; recommend the second:

1. Revert the backend to XML — reintroduces escaping, contradicts #563's hard cut.
2. Teach the frontend the JSON envelope: extend `isBackgroundCommandOutput.ts` with a
   JSON branch (`JSON.parse` → the same `ParsedBackgroundCommandOutput`), keep the legacy
   XML/prose branches for old rows, and pin it with a spec that feeds the **exact** string
   `buildCompletionMessage` produces (copy it from `background_command_completion_test.zig`
   so the two cannot drift).

---

## 5. Non-goals

- No PTY. Output stays redirected-to-file, not interactive. `pnpm run dev` printing
  progress works; a process that needs a TTY does not, and the description must say so.
- No output *streaming* into the chat transcript. Wakes are batched queue messages.
- No change to the foreground spawn semantics, the 60 s cap, or `mandatory_timeout`.
- No change to `isWorkerCancelled` / the Stop button.
- Not touching the `bash`/`pwsh` retired-name handling.

## 6. Task breakdown

Ordered so each step is independently shippable and testable.

**T0 — verify G7, then fix it** (prerequisite)
One functional replay of the real envelope through the frontend helper + extend the spec.
No production code until the mismatch is reproduced.

**T1 — PR 1: `is_stop`** (R1, small)
Steps 1–6 of §4.1. Prompt text. Test: functional — boot the harness, drive a session whose
fake model emits a `command` call with `is_stop:true`, assert the worker row is gone, the
loop does not issue another LLM call, and the tool result row is persisted with a matching
`tool_call_id`.

**T2 — migration 107 + `kind`/handle** (R2a)
Columns from §4.2a; `background_process.save` gains `kind`; `persistence=true` routes to
the same `spawn_background` with `kind='service'`. Test: in-memory SQLite through the real
migration chain (`MigrationManager.registerAllMigrations + runMigrations`), then a
functional round-trip through `command` + `GET …/background_processes`.

**T3 — the `process` tool** (R2b, R2c)
`read` (delta + offset advance) / `stop` / `list`; native detached spawn + `stopPlan`.
Tests: `read` offset advance against a real growing file (no shell); `stop` kills the tree
— assert the *grandchild* is gone (`bash -c 'sleep 300 & wait'`), the guard for G3;
`stopPlan(.linux)` / `stopPlan(.windows)` asserted from Linux as pure data.

**T4 — re-arm on boot + `orphaned`** (R2d)

**T5 — `persistence_watcher`** (R3)
Tests: settle collapses a burst (a single wake for N lines written in < `settle_ms`); the
rate limit caps a chatty process; the cap message names `process read`; the watcher
retires without leaking (mirror `abandoned_reader_count`-style observability).

**T6 — frontend**
`BackgroundCommandsPopup.vue` badge for `kind='service'` + alive/stopped state; the
`process` tool card; the JSON envelope branch from T0. Follows the repo's URL-sync rule
if any view state is added.

**T7 — prompt text + `AGENTS.md`/`PABRIK.md` guidance** for the new params, and removal of
G5's blanket ban (replaced by: "a dev server is `persistence=true`; a `background=true`
job must be bounded").

## 7. Decisions I need from you

1. **`is_stop` scope** — end the **turn** (recommended, mirrors `ask_user`), or also
   **cancel the worker** (Stop-button semantics, kills in-flight work)?
2. **`persistence` shape** — (A) 2 booleans on `command` + `persistence_action`, or
   (B) **recommended**: 2 booleans on `command` + a new `process` tool for
   read/stop/list?
3. **Wake on output** — automatic when `persistence=true`, or **recommended**:
   opt-in (`process watch`), with the §4.3 defaults (settle 1.5 s, ≥10 s apart, ≤20 per
   process)? Do you want the numbers somewhere in Settings?
4. **Stop semantics** — tree kill via native detached spawn (**recommended**, but it is
   the one genuinely risky item), or single-PID kill as a Phase-1 stopgap?
5. **Restart behaviour** — persistent processes keep running across a pabrik restart
   (**recommended**), or are all killed on boot?
6. **UI** — is a popup badge + Stop button in scope for T6, or backend-only for now?

## 8. Risks

| risk | mitigation |
|---|---|
| R3 becomes an LLM-spend incident (a chatty dev server). | Debounce + settle + per-process cap + opt-in arming (§4.3). Must be in PR 1 of the wake feature, not a follow-up. |
| Tree-kill changes the background path every `background=true` caller already depends on. | T3 lands the new spawn **behind `kind='service'`**; `background=true` keeps `nohup` until the new path has a functional test on Linux **and** a CI cell on macOS/Windows. |
| `handle_tool` signature change ripples. | It has exactly one caller (`workflow.zig:1676`) — verified. |
| Buffered stdout: `pnpm run dev` under a redirect may emit nothing until flush. | Document `stdbuf -oL` (Linux) in the description; a `persistence` functional test uses a genuinely line-buffered command so the test does not encode the assumption. |
| G7 fix touches rendered history. | Keep the legacy XML/prose branches; the new spec feeds the exact backend string. |

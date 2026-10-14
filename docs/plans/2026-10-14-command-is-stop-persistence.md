# Plan — `command` tool: `is_stop` + a 3-way run mode

- **Task**: `task_1791972455755_8` — "add new parameter to ai agent command"
- **Worktree**: `~/.config/pabrik/.worktrees/add-new-parameter-to-ai-agent-command-1791972429011`
- **Branch**: `worktree/add-new-parameter-to-ai-agent-command-1791972429011` (base `main`)
- **Status**: **Revision 3 — DECIDED, ready to implement.** All four open decisions are closed (§1.3).
  No code yet; PR 1 (`is_stop`) starts on approval.

---

## 1. Requirement, restated after the user's answers

### 1.1 The answers (verbatim)

> **is_stop** mean, the worker running in while loop is exit, but the command in background still
> running, `while (true) { exit`, check the workflow.zig
>
> command can be make 3 categorize ?
> 1. foreground,
> 2. background, mean running the long process command in background, but after that it will send a queue,
> 3. background_persistence mean running the long process command in bucketround without send a queue,
>
> 5. yes if pabrik service kill, the process that running is killed oo
> 6. backend first

### 1.2 What that settles

| # | Requirement | Answer |
|---|---|---|
| R1 | `is_stop` — **exit the `while (true)` loop**; a background/persistent command started by the same call **keeps running**. | ✅ semantics fixed |
| R2 | `command` gets **one 3-way `mode`**, not two booleans. | ✅ shape fixed |
| R2a | `mode = background` → detaches **and sends a queue message** on completion. | ✅ |
| R2b | `mode = background_persistence` → detaches and **never sends a queue message**. | ✅ |
| R3 | Wake-the-agent-on-output — **DROPPED**. `background_persistence` is silent by definition, so there is no wake to design. | ✅ out of scope |
| D5 | A running process **dies with the pabrik service**. | ✅ |
| D6 | **Backend first** — no frontend work in this PR. | ✅ |
| D2 | `mode` lives **on `command`** (the user's own framing). | ✅ |
| D3 | No wake ⇒ no `persistence_watcher`, no `watch` action, no debounce/rate-limit. | ✅ simplified |
| D4 | Stop mechanism — **native detached spawn + tree kill**. | ✅ |
| D7 | Read ergonomics — **a `process` tool with a delta read**, as its own later PR. | ✅ §3.7 |
| D8 | Cancel semantics — **the Stop button stops nothing**. | ✅ §3.5 |
| D9 | G8 dead helpers — **adopt `killAllForSession`, delete `pollAndUpdateStatus`**. | ✅ §3.6 |

### 1.3 The four answers (verbatim)

> 1. i choose recommended,
> 2. what the best for you ?
> 3. not dont stop,
> 4. okey

Decoded: **(1)** tree kill. **(2)** my call — a `process` delta read, §3.7. **(3)** "don't stop" —
the Stop button must **not** stop the processes, §3.5. **(4)** adopt/delete as recommended, §3.6.

**The single biggest simplification from Revision 1**: dropping the wake removes the whole
`persistence_watcher` (settle window, flush threshold, per-process wake cap, spend risk) — that was
the only genuinely new runtime in the plan. What is left is a *mode flag*, a *loop break* and a
*correct kill*, all of which fit inside the existing machinery.

---

## 2. `is_stop` — verified against `workflow.zig`

The user asked me to check. Confirmed:

- The loop is `src/agentic_loop/workflow.zig:831` — `while (true) {`.
- The decision point is `workflow.zig:1560-1760`, a three-arm `if (finish_reason)`:
  - `.stop` → persist + `deleteWorker` + **`break`** — this is the `exit` the user means.
    Note `workflow.zig:1568-1576`: `.stop` with **empty content does `continue`, not `break`** —
    so a model that returns nothing does *not* leave the loop.
  - `.tool_calls` → `handle_tool(...)` at `workflow.zig:1676` → **falls through and loops back**
    for another LLM call. **This is the arm `is_stop` must override.**
  - `ask_user` pending → `break`; worker cancelled → `break`.

So `is_stop` = "take the `break` in the `.tool_calls` arm". Nothing is killed; the detached
command keeps running exactly as the user described.

### 2.1 Why "after the batch", not "the moment it is parsed"

`handle_tool` implements a 3-phase protocol whose entire purpose is that **every `tool_call_id`
gets a matching `role=tool` row** — Phase 1 writes placeholders BEFORE any tool runs
(`handle_tool.zig:490-560`), which is the fix for the "Invalid function ID" class of bug.
Aborting mid-batch would leave dangling `tool_call_id`s and the provider would reject the next
turn. So `handle_tool` dispatches the full batch, OR-merges the stop request, and returns it.

### 2.2 Plumbing (5 small edits, 4 files)

`ToolExecResult` (`src/agentic_loop/tools.zig:157`) is already the channel for "the tool wants to
change the loop" — it carries `temperature`, `is_thinking`, `skill_save`, `agent_save`,
`progressive_tool_save`. `stop_loop: bool` belongs there.

| # | file | change |
|---|---|---|
| 1 | `src/agentic_loop/tools_exec_bash_args.zig` | parse `is_stop` (+ `mode`) into a wrapper `CommandArgs{ shell, mode, is_stop }`; add to `BOOL_FIELDS`. Keeps `shell.zig` free of loop concerns. |
| 2 | `src/agentic_loop/tools.zig:157` | `ToolExecResult.stop_loop: bool = false` |
| 3 | `tools_exec_command.zig` | set `.stop_loop = args.is_stop` |
| 4 | `handle_tool.zig:466` | return `!ToolBatchOutcome{ .stop_loop: bool }`; OR-merge across the batch. **Safe**: `handle_tool` has exactly ONE caller (`workflow.zig:1676`, verified by grep). |
| 5 | `workflow.zig:1676` + the `.tool_calls` arm | `const outcome = try handle_tool(...)`; after the `ask_user` check, `if (outcome.stop_loop)` → persist `last_finish_reason = "stop"`, `deleteWorker`, `break`. |
| 6 | `command.zig` | schema + description for `is_stop` / `mode`; drop the blanket "no dev servers" ban (§4.5). |

### 2.3 Prompt contract (must be in the param description)

`finish_reason == .tool_calls` normally carries **no prose**. A turn that ends via `is_stop`
therefore ends on a bare tool card unless the model puts its final answer in the assistant
`content` of the *same* message. The description must say so, and the functional test must pin it.

Also state: `is_stop` ends **this agent's** turn (sub-agents hit the same code path — which is
useful, it gives a sub-agent an explicit bound), and it **kills nothing**.

---

## 3. `mode` — the 3-way category the user asked for

```jsonc
"mode": "foreground" | "background" | "background_persistence"   // default "foreground"
```

| | `foreground` | `background` | `background_persistence` |
|---|---|---|---|
| detaches | no | yes | yes |
| `mandatory_timeout` | **required, 1–60** | ignored | ignored |
| written to `session_background_process` | no | yes (`kind='job'`) | yes (`kind='service'`) |
| **queue message on exit** | n/a (result returned inline) | **yes** | **never** |
| immediate watcher scheduled | no | yes | no |
| cron may notify | no | yes | **must skip** |
| dies with pabrik | n/a | no | **yes** (D5) |
| intended for | `ls`, `git status`, builds ≤60 s | long build / test / migration | `pnpm run dev`, a watcher |

### 3.1 Back-compat for `background: bool`

Keep `background` accepted (it is in transcripts, cached schemas and every existing caller) as a
**tolerated alias**: `true` ⇒ `mode="background"`. `mode` wins when both are present; a
contradiction (`background:true` + `mode:"foreground"`) returns the structured
`InvalidField` error naming both fields. This mirrors the existing alias/retired-name pattern in
`tools_equipped.zig` (`resolveToolAlias`) — no new mechanism.

### 3.2 "Without send a queue" has to be enforced in TWO places

The user's category 3 is defined by a *negative* — and the negative is currently unreachable
because two independent actors both notify on exit:

1. `background_watcher.spawnCompletionWatcher` — scheduled today from
   `tools_exec_command.zig:104`. For `background_persistence`, **do not schedule it**.
2. `cleanup_stale_background_process.zig` — the per-minute cron selects **every** row whose PID is
   dead and notifies it. It must therefore **skip `kind='service'` rows**, or a persistent dev
   server that eventually exits would queue a message a month later.

So `kind` is not cosmetic (G4) — it is the only thing that makes category 3's contract hold.

### 3.3 "Dies with pabrik" (D5) — native detached spawn (decided)

The command is spawned **by pabrik itself**, not by a shell:

```zig
std.process.spawn(io, .{
    .argv = argv,                       // argv_prefix ++ [command] — no `nohup`, no `cmd &`
    .cwd  = .{ .path = cwd },
    .stdin  = .close,
    .stdout = .{ .file = log_file },    // StdIo.file — verified present in Zig 0.16
    .stderr = .{ .file = log_file },    // (std/process.zig:408, StdIo.file: File)
    .pgid = if (comptime builtin.os.tag == .windows) null else @as(?std.posix.pid_t, 0),
});
```

Why this beats the `nohup`/`Start-Process` string it replaces:

- **`pid == pgid`.** `.pgid = 0` makes the child its own process-group leader, so
  `kill(-pid)` reaches vite *and* esbuild *and* anything else it forked. The `nohup cmd &`
  idiom gives a PID whose group is the *spawning shell's*, which is why `kill(-pgid)` was never
  usable there (G3).
- **No shell wrapper, no quoting.** `backgroundSpec`, `tempDirFor` and `quotePwsh` exist only to
  build a shell string and its log path; a direct spawn deletes all three from this path.
- **No reader threads.** The child writes straight into the log file, so the whole
  `Reader` / `settleReader` / `abandoned_reader_count` machinery (written for the foreground
  deadline problem) is not involved.
- **A real exit code.** The reaper is `shell.wait_pid_bounded` — already used by the foreground
  path — so the completion message can carry the actual status instead of inferring it from
  liveness.

D5 in three pieces, in order of reliability:

- **Clean shutdown**: the SIGINT/SIGTERM path runs the post-listen block at `main.zig:346-356`
  before `std.process.exit(0)`. Kill every live `kind='service'` row **there**.
- **Hard kill (`kill -9`)**: no handler can run, so the boot sweep (§3.4) is the answer.
- **Linux belt-and-braces**: `prctl(PR_SET_PDEATHSIG, SIGKILL)` in the child, so even a `kill -9`
  of pabrik takes the service down immediately. **macOS has no equivalent** — do not pretend it
  does; the boot sweep is the fallback there.

Windows: no process groups and no Job Objects here, so `stopPlan(.windows)` is
`taskkill /T /F /PID`. Keep the plan **pure data** — `stopPlan(os_tag) []StopKill`, mirroring
`timeoutKillPlan` (`shell.zig`) — so the Windows arm is assertable from a Linux runner, which
`CODING_STANDARDS.md` §2 requires.

`mode='job'` (category 2) keeps the existing `nohup` path until the new spawn has a functional
test on Linux **and** a CI cell on macOS/Windows. Two implementations may look wasteful; a
regression in the mode every existing `background=true` caller depends on would be worse.

### 3.4 Boot: kill leftovers, re-arm jobs

One pass over `status='running'` rows:

| row | PID alive? | action |
|---|---|---|
| `kind='service'` | yes | **kill it** (D5 — it outlived pabrik), mark `orphaned` |
| `kind='service'` | no | mark `orphaned` |
| `kind='job'` | yes | re-arm `spawnCompletionWatcher` — the watcher thread did not survive the restart |
| `kind='job'` | no | notify + delete (the cron's job, so just let the cron do it) |

### 3.5 The Stop button stops nothing (D8)

The user's answer is `not dont stop`. So:

- **Cancel / Stop** (`isWorkerCancelled`) does **not** kill background or persistent processes.
  This also preserves today's behaviour exactly — see G8 in §4: nothing kills them today.
- **`is_stop`** kills nothing either (§2).
- The **only** two killers are pabrik's own shutdown (§3.3) and the boot sweep (§3.4).

Consequence worth stating in the PR: a dev server started for a task stays up after the user hits
Stop, and stays up across turns. That is the point of `background_persistence`, but it means the
agent must be told to `stop` it when it is done, or the port stays held. If you later want
"Stop also kills `kind='job'`", it is one condition behind the existing `kind` column — not a
re-design.

### 3.6 G8 — adopt one, delete the other (D9)

`background_process.zig` today:

| helper | disposition | why |
|---|---|---|
| `killAllForSession` (:151) | **adopt, rescoped** | The shutdown + boot sweep need exactly this walk, but scoped to `kind='service'` and **never** called from cancel (D8). Rename so the scope is in the name (`killServicesForShutdown`) — `killAllFor**Session**` invites the cancel-path misuse the user just ruled out. |
| `pollAndUpdateStatus` (:172) | **delete** | Superseded by the cron's notify-then-delete, which additionally *queues the log* and wakes the session. Keeping a liveness-only variant means two liveness sources that can disagree — `background_processes_list.zig` already computes `running` live precisely because the stored `status` drifts. |

### 3.7 Reading output (D7) — my recommendation: a `process` tool, as its own PR

You asked what is best. **A `process` tool with `read` / `stop` / `list`, shipped as PR 3**, and
here is the reasoning rather than a preference:

1. **`command` is the wrong shape for a read.** `command`, `cwd` and `mandatory_timeout` are all
   *required* (`command.zig`, `.required = &.{ "command", "cwd", "mandatory_timeout" }`). Reading a
   log would mean inventing a dummy command and a dummy deadline on every poll. Making them
   conditionally required is exactly the kind of schema the lenient parser exists to paper over.
2. **A delta read is not a nicety, it is the token cost.** A dev server's log grows continuously.
   `tail -n 50` after 500 lines of HMR output returns 50 lines of the same repeated noise — and you
   pay for those tokens again on *every* poll. A delta read returns "no new output" (single-digit
   tokens) for the eight polls out of ten where nothing happened. That is the difference between a
   usable loop and one the agent avoids because it is expensive.
3. **`list` removes the memory problem.** With `tail`, the agent must keep `pid` and `log_path` in
   context across turns — and compaction drops exactly that kind of detail. `process list` turns
   "remember a path" into "ask what I am running", which is robust to compaction by construction.
4. **The mechanism is already there.** `ToolExecContext` carries `db` + `session_id`, so the tool
   reads `session_background_process` directly: `last_read_offset` advances per read, and there is
   no new state, no new table, and no new event.

And the staging matters: **PR 3 is not a blocker.** After PR 2, `mode="background_persistence"` is
already *usable* — the start result carries the PID and log path, `command` + `tail` reads it, and
`command` + `kill -- -<pid>` stops the whole tree (which is what PR 2's spawn makes possible). PR 3
is the ergonomics that make it cheap enough that an agent will actually do it.

**PR staging (this is the answer to "backend first")**

| PR | contents | independently useful? |
|---|---|---|
| **PR 1** | `is_stop` (§2) | yes — the exit you asked for, on its own |
| **PR 2** | `mode` + migration 107 `kind` + native spawn + tree kill + dies-with-pabrik (§3) | yes — mode 3 works, `tail`/`kill` read it |
| **PR 3** | the `process` tool (§3.7) | yes — makes mode 3 cheap to poll |

---

## 4. Gaps

| id | gap | status |
|---|---|---|
| G1 | No read surface for a running process. | **Answered by D7** → PR 3. Usable, but clumsy, before that. |
| G2 | No output-driven wake. | **Out of scope** — `background_persistence` is silent by definition. |
| G3 | `kill <pid>` does not kill the tree. | **Fixed by PR 2** (§3.3). |
| G4 | The row carries no lifecycle state. | **Fixed by PR 2** — `kind` is what enforces "no queue" (§3.2). |
| G5 | The prompt **forbids dev servers** (`command.zig:113`, `command.zig:96`). | PR 2 — lift it for `mode="background_persistence"`. |
| G6 | PID reuse → a stale row reads as alive. | Deferred; low priority. Cheap hardening: compare `started_at` too. |
| G7 | **Live bug**: backend completion envelope is JSON, frontend helper parses XML-only (regression from #563). | **Deferred** — frontend, and the user said backend first. Affects `mode="background"`, so it is named in the PR 2 body. |
| G8 | `killAllForSession` / `pollAndUpdateStatus` have ZERO callers — nothing kills background processes today. | **Resolved by D9** (§3.6). |

Evidence for G8: `grep -rn "killAllForSession" src/` returns only the definition
(`background_process.zig:151`); same for `pollAndUpdateStatus` (`:172`).

---

## 5. Task list

**PR 1 — `is_stop`** (§2.2 steps 1–6, minus `mode`)
Functional test: drive a session whose scripted model emits a `command` call with
`is_stop: true`, and assert (a) no further LLM call is issued, (b) the worker row is gone,
(c) the tool-result row exists with a matching `tool_call_id`, and (d) a
`mode="background_persistence"` command started in the same call **is still alive after the loop
exits** — (d) is the user's exact sentence and the guard against someone "helpfully" killing the
batch on the way out.

**PR 2 — `mode`** (§3)
- T2.1 schema + parser + `background` alias; `shell.zig` validation switches to
  `mode == .foreground` for `MandatoryTimeoutMissing` / `MandatoryTimeoutTooLarge`.
- T2.2 migration 107 + `kind`; `background_persistence` skips `spawnCompletionWatcher`; the cron's
  SELECT adds `AND kind = 'job'`. Test: a `kind='service'` row with a dead PID is **not** notified
  **and** a `kind='job'` control row **is** — a negative assertion needs the positive control.
- T2.3 native detached spawn + `stopPlan(os_tag)` + `wait_pid_bounded` reaping. Test: `stop` on
  `bash -c 'sleep 300 & wait'` kills the **grandchild** — the direct guard for G3.
- T2.4 shutdown hook + boot sweep + `PR_SET_PDEATHSIG`. Test: start a service process, stop pabrik,
  assert the PID is gone **and** a `kind='job'` control row is **not** killed.
- T2.5 prompt text: `mode` descriptions, lift G5's ban, note `stdbuf -oL` on Linux.
- T2.6 G8 disposition (§3.6).

**PR 3 — the `process` tool** (§3.7): `read` / `stop` / `list`, delta + `last_read_offset`.

---

## 6. Decisions — all closed

| # | decision | answer |
|---|---|---|
| 1 | Kill mechanism | native detached spawn + tree kill (§3.3) |
| 2 | Read ergonomics | `process` tool with a delta read, as PR 3 (§3.7) |
| 3 | Cancel | the Stop button stops nothing (§3.5) |
| 4 | G8 | adopt `killAllForSession` (rescoped), delete `pollAndUpdateStatus` (§3.6) |

Remaining at implementation time, not requiring a decision now: the concrete `PR_SET_PDEATHSIG`
call shape on Linux, and whether the `process` tool needs its own card in the desktop UI (D6 was
backend-first, so: no).

---

## 7. Risks

| risk | mitigation |
|---|---|
| A process that *should* notify (e.g. `pnpm run migrate`) is started in mode 3 and the agent never learns it failed. | `kind` is **mode-derived**, never inferred from the command string; the cron test pins both directions. The `mode` description must say plainly what mode 3 gives up. |
| The native spawn regresses the path every existing `background=true` caller depends on. | `kind='job'` keeps `nohup` until the new path passes on Linux **and** a macOS/Windows CI cell. |
| D5 kills a process the user wanted kept across a restart. | Requested behaviour. `orphaned` rows stay visible in the popup, so it is legible rather than silent. |
| A dev server is left holding a port after the user hits Stop (by design, D8). | The `mode` description tells the agent to `stop` when done; the popup lists it so a human can. |
| `handle_tool` signature change ripples. | Exactly one caller — verified (`workflow.zig:1676`). |
| Buffered stdout: `pnpm run dev` under a redirect may print nothing until flush. | Document `stdbuf -oL`; the persistence functional test uses a genuinely line-buffered command so the test does not encode the assumption. |

---

## 9. Implementation log — PR 1 (`is_stop`)

Status: **implemented and verified** on
`worktree/add-new-parameter-to-ai-agent-command-1791972429011`.

### 9.1 Files

| file | change |
|---|---|
| `src/modules/agent/tools/shell.zig` | `ShellInput.is_stop: bool = false`, documented as loop control that `shell.zig` never reads. |
| `src/agentic_loop/tools_exec_bash_args.zig` | parse `is_stop`; `BOOL_FIELDS += "is_stop"`. |
| `src/agentic_loop/tools.zig` | `ToolExecResult.stop_loop: bool = false`. |
| `src/agentic_loop/tools_exec_command.zig` | `runWithContext` returns `RunResult{ payload, stop_loop }`; `execCommand` propagates it. |
| `src/agentic_loop/handle_tool.zig` | `ToolResult.stop_loop`, `ToolBatchOutcome`, `handle_tool` returns it, OR-merged in Phase 3. |
| `src/agentic_loop/workflow.zig` | capture the outcome; new `is_stop` arm in `.tool_calls` — `last_finish_reason = "stop"`, `deleteWorker`, `break`. |
| `src/modules/agent/tools/command.zig` | the `is_stop` schema property + the rule in the description and the system prompt. |
| `tests/functional/command_is_stop_test.zig` | the wire test (below). |

### 9.2 Deviation from §2.2 step 1, with the reason

The plan proposed a wrapper `CommandArgs{ shell, is_stop }` to keep `ShellInput` free of loop
concerns. Implemented as a field ON `ShellInput` instead, because the wrapper changes the
`parseShellArgs` return payload and therefore every `.success => |input| input.field` in ~20
existing tests — ~20 edits with no behavioural gain, all of them in tests unrelated to this work.
`shell.zig` still has no loop behaviour: it never reads the field, and its doc comment says so.

### 9.3 Verification actually run

**Unit** — `zig build test --summary all`:
**26/26 steps succeeded; 4334/4344 tests passed (10 skipped); 0 failed.** Added 5 parser tests
(`is_stop` absent → false, JSON bool, string bool, garbage → `InvalidField` naming `is_stop`,
present in `BOOL_FIELDS`) and 2 schema tests (optional boolean + full contract in the description;
the rule reaches description AND system prompt).

Positive control for the new tests: one of them was deliberately inverted
(`expect(!input.is_stop)`) and the suite went red with
`'agentic_loop.tools_exec_bash_args.test.parseShellArgs: is_stop reads a string boolean' failed`
— `4333/4344 passed (1 failed)`, exit 1 — then reverted. This rules out the failure mode where a
new test is compiled but never selected by the runner's `--test-filter` sharding.

**Functional** — `tests/functional/command_is_stop_test.zig`, a stub upstream that counts requests,
driven through `POST /api/llm/session`:

- `is_stop ends the turn after one model call, with the batch persisted` — the stub saw **exactly 1**
  agent round; the `worker` row is gone; `sessions.last_finish_reason = 'stop'` (the loop's own
  overwrite, not the provider's `tool_calls`); the `role='tool'` row exists for the real
  `tool_call_id`; the assistant row still carries `finish_reason = 'tool_calls'`.
- `without is_stop the loop calls the model again (positive control)` — same run, flag omitted:
  **≥ 2** model calls. Without this, "exactly 1 call" would also be satisfied by a run that died
  early.

Both pass. The matched pair is the point: one asserts the override, the other asserts the
behaviour being overridden.

### 9.4 Still to come

PR 2 (`mode` + migration 107 `kind` + native detached spawn + tree kill + dies-with-pabrik) and
PR 3 (the `process` tool) — §3 and §5. `mode` is deliberately absent from PR 1 so the loop-control
change can be reviewed on its own.

# Plan — `command` tool: `is_stop` + a 3-way run mode

- **Task**: `task_1791972455755_8` — "add new parameter to ai agent command"
- **Worktree**: `~/.config/pabrik/.worktrees/add-new-parameter-to-ai-agent-command-1791972429011`
- **Branch**: `worktree/add-new-parameter-to-ai-agent-command-1791972429011` (base `main`)
- **Status**: **Revision 2** — incorporates the user's answers of 2026-10-14 (§1.1). PLAN only, no code yet.

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
| D4 | Stop mechanism (tree kill vs single-PID) — **not answered**; §4.4 recommends and flags it. | ⬜ |

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

### 3.3 "Dies with pabrik" (D5)

Three pieces, in order of reliability:

- **Clean shutdown**: `main.zig:274-276` installs SIGINT/SIGTERM handlers, and the signal path runs
  the post-listen block at `main.zig:346-356` before `std.process.exit(0)`. Kill every live
  `kind='service'` row **there** (before the exit).
- **Hard kill (`kill -9`)**: no handler runs, so the boot sweep handles it (§3.4).
- **Linux-only belt-and-braces**: `prctl(PR_SET_PDEATHSIG, SIGKILL)` in the child, so a `kill -9`
  of pabrik takes the service down without waiting for a restart. macOS has no equivalent —
  document, do not pretend.

### 3.4 Boot: kill leftovers

On boot, for every `status='running'` row: if the PID is alive and `kind='service'`, **kill it**
(D5) and mark `orphaned`; if dead, mark `orphaned`. The same pass re-arms completion watchers for
`kind='job'` rows, whose watcher thread did not survive the restart.

---

## 4. Gaps (Revision 1 list, updated)

| id | gap | status after the answers |
|---|---|---|
| G1 | No read surface for a running process — the agent must `command` + `tail <log_path>` and carry the path across turns. | **Now the whole story**: with no wake, polling is the only way to see a dev server's output. |
| G2 | No output-driven wake. | **Out of scope** — the user defined `background_persistence` as silent. |
| G3 | `kill <pid>` does not kill the tree (recorded PID is the *shell's* child; `pnpm run dev` forks again). Foreground already fixed it (`.pgid = 0` + `kill(-pgid)`); the background path never did. | **Open, and now more important** — for a dev server, `stop` means "free the port", which a single-PID kill does not do. |
| G4 | The row carries no lifecycle state. | **Required**: `kind` is what enforces "no queue" (§3.2). |
| G5 | The prompt **forbids dev servers** (`command.zig:113`, `command.zig:96`). | Must be lifted for `mode="background_persistence"`. |
| G6 | PID reuse → a stale row reads as alive. | Low priority; cheap hardening. |
| G7 | **Live bug**: backend completion envelope is JSON, frontend helper parses XML-only. | **Deferred** — it is frontend, and the user said backend first. It affects `mode="background"`, so flag it in the PR body. |
| **G8** | **NEW: `background_process.killAllForSession` and `.pollAndUpdateStatus` have ZERO callers.** Nothing kills background processes today — not on session cancel, not at shutdown. | D5 has no existing hook to lean on; §3.3/§3.4 are new code, not a wiring fix. |

Evidence for G8: `grep -rn "killAllForSession" src/` → only the definition
(`background_process.zig:151`); same for `pollAndUpdateStatus` (`:172`).

---

## 5. Task breakdown (backend first)

**T1 — `is_stop`** (R1) — the smallest useful PR, and independent of the rest.
§2.2 steps 1–6 minus `mode`. Functional test: drive a session whose scripted model emits a
`command` call with `is_stop:true`; assert (a) no further LLM call is issued, (b) the worker row is
gone, (c) the tool-result row exists with a matching `tool_call_id`, (d) a
`mode="background_persistence"` command started in the same call **is still alive after the loop
exits** — that last one is the user's exact sentence, and the guard against someone "helpfully"
killing the batch on the way out.

**T2 — `mode`** (R2) — schema + parser + `background` alias + `shell.zig` validation switch
(`mode == .foreground` replaces `!input.background` in the `MandatoryTimeoutMissing` /
`MandatoryTimeoutTooLarge` guards at `shell.zig:1232-1244`). Migration not needed yet.

**T3 — migration 107 + `kind`** (R2a/R2b)
```sql
ALTER TABLE session_background_process ADD COLUMN kind TEXT NOT NULL DEFAULT 'job';
```
`save` gains `kind`; `background_persistence` skips `spawnCompletionWatcher`; the cron's SELECT
adds `AND kind = 'job'`. Test: `kind='service'` row with a dead PID is **not** notified by the cron
(and the `kind='job'` control row IS) — a negative assertion needs that positive control.

**T4 — the correct kill (G3)** — the one genuinely risky item.
Recommended: reuse the **foreground** spawn pipeline's semantics (`.pgid = 0`, `shell.zig:1215`)
for a native detached spawn with stdout/stderr redirected to the log file, so recorded `pid ==
pgid` and `kill(-pid)` reaches vite + esbuild. Keep the OS plan **pure data**
(`stopPlan(os_tag) []StopKill`, mirroring `timeoutKillPlan`) so the Windows arm is assertable from
a Linux runner — required by `CODING_STANDARDS.md` §2. `stopPlan(.windows)` = `taskkill /T /F`.
Fallback if you want the smaller diff: keep `nohup` and ship single-PID `kill`, documented as
best-effort — but then "stop the dev server" will often leave the port held.

**T5 — dies with pabrik (D5)** — clean shutdown hook (`main.zig:346-356`) + boot sweep
(§3.4) + Linux `PR_SET_PDEATHSIG`. Test: start a service mode process, signal pabrik to stop,
assert the PID is gone — and a `kind='job'` control row is **not** killed.

**T6 — revive the lifecycle helpers (G8)** — decide whether `pollAndUpdateStatus` /
`killAllForSession` are adopted or deleted. Dead code that looks like the safety net is worse than
no code.

**T7 — prompt text** — `mode` / `is_stop` descriptions, the "put your final answer in `content`
when you pass `is_stop`" contract, lift G5's ban (a dev server is
`mode="background_persistence"`), and say protected output may need `stdbuf -oL` on Linux.

**Deferred / separate PRs**: the `process` read-offset tool (G1 ergonomics), the wake-on-output
feature (R3), G7 (frontend envelope), UI (D6 = backend first).

---

## 6. Open decisions

1. **T4 kill mechanism** — native detached spawn + tree kill (**recommended**; correctly frees the
   port, bigger diff, touches the path `background=true` shares) **or** single-PID kill as a
   Phase-1 stopgap?
2. **G1 read ergonomics** — is `command` + `tail <log_path>` good enough for now (zero new
   surface), or do you want a `process read` that returns only the delta? With the wake dropped,
   this is the only thing standing between the agent and a usable dev-server loop.
3. **Cancel semantics** — the session Stop button should kill every process including
   `background_persistence` (**recommended**), while `is_stop` kills nothing. Confirm?
4. **G8** — adopt `killAllForSession` / `pollAndUpdateStatus` in this work, or delete them?

## 7. Risks

| risk | mitigation |
|---|---|
| A "persistent" process that actually *should* notify (e.g. `pnpm run migrate`) is started in mode 3 and the agent never learns it failed. | T3's `kind` skip must be **mode-derived**, never inferred from the command string; the cron test pins both directions. |
| Tree kill changes the path `background=true` is built on. | T4 lands behind `kind='service'`; `kind='job'` keeps `nohup` until the new path has a functional test on Linux **and** a CI cell on macOS/Windows. |
| D5 kills a process the user wanted to keep across a restart. | That is the requested behaviour; the popup keeps listing `orphaned` rows so it is visible rather than silent. |
| `handle_tool` signature change ripples. | Exactly one caller — verified (`workflow.zig:1676`). |
| Buffered stdout: `pnpm run dev` under a redirect may print nothing until flush. | Document `stdbuf -oL`; the persistence functional test uses a genuinely line-buffered command so the test does not encode the assumption. |

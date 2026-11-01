# Routine runs — one real chat session per fire, and a Running list

**Status:** design, not implemented.
**Wireframe:** `docs/wireframes/routine-runs.html`.
**Task:** `task_1793556739964_1` — "Fix how to use routines, features need polished".
**User's requirement, verbatim:** *"when routines run it will open a new chat session that running, currently it is still not create, also the list running is here, we can open that"*.

---

## 1. What is wrong, with the evidence

A routine fires, the agent runs, `workspace_routines.last_status` becomes `success` — and no chat exists anywhere. Five separate defects produce that one symptom.

### 1.1 Nothing creates the session row

Firing takes a shortcut around the only funnel that creates a session.

| Step | Chat send | Routine fire |
| --- | --- | --- |
| entry | `http_handlers/session_create.zig:327` → `App.emit_run_agent` | `ai_workflow/tui/routines/fire.zig:60` → `runFire` |
| who inserts `sessions` | `App.insert_worker` (`src/app.zig:232`), `INSERT INTO sessions … ON CONFLICT DO NOTHING` at `app.zig:236` | **nobody** |
| who inserts `worker` | `insert_worker` | **nobody** |
| `sessions.created` broadcast | `insert_worker` (`app.zig:277`) | **nobody** |
| agent trigger | `event_bus.emit(RunParamsNew)` inside `insert_worker` | `fire.zig:95` emits `RunParamsNew` **directly** |

`runFire` emits the run-params event itself, so the agent loop does run — the model calls, the tools, the tokens all happen and `llm_history` rows are written under the routine id — but the parent `sessions` row never exists. Everything that lists sessions reads that row:

- `GET /api/sessions` — `SELECT … FROM sessions s` (`agentic_loop/llm_history.zig:387`). A run cannot appear in the sidebar, not ever.
- `GET /api/workers` — `WHERE w.cancelled = 0 AND w.session_id = ?` (`http_handlers/worker_list.zig:69`). No worker row was inserted, so the routine's own "Running now" query returns nothing.
- `GET /api/session/:id` — needs the row to answer.

### 1.2 Every run reuses one id

```zig
// src/ai_workflow/tui/routines/fire.zig:48
const sid = try di.allocator.dupe(u8, routine.id);
```

The session id **is** the routine item id, forever. So even if a session row did exist, run 2 would continue run 1's conversation, and there would be no per-run thing to open. This is the defect that makes "open that run" impossible rather than merely invisible.

### 1.3 There is no run record

`workspace_routines` keeps exactly one slot — `last_run_at`, `last_status`, `last_error` (`routines/model.zig:30-40`). Migration 084 replaced the old routines table with this shape. A one-slot table cannot answer "which runs are live right now", "how long did the 09:00 run take", or "open the run from yesterday that failed".

### 1.4 The "Running now" panel is dead code

`RoutineView.vue` has a `Running now` section fed by `api.getWorkers(undefined, 50, props.itemId)` — note the third argument is the routine id — and it only mounts when `runningSessions.length > 0` and only polls while `last_status === 'running'`. Given §1.1, `runningSessions` is permanently empty, so the panel never renders. The screenshot on the task shows the result: a routine with a green `Success` pill and no run anywhere.

### 1.5 "Run now" throws the run away

```ts
// RoutineView.vue handleRunNow
await workspacesStore.runRoutineItem(props.workspaceId, props.itemId, props.itemId)
await load()
```

The store returns the handler's body, and `workspace_routines_run.zig:74` answers `{"session_id": "<routine_id>", "status": "firing"}` — a session id that is not a session. Nothing navigates, so pressing **Run now** produces no visible response except a pill that flips.

### 1.6 An errored run reports success

`runFire` calls `markRunFinished` → `model.markSuccess` unconditionally (`fire.zig:120`, `fire.zig:143`). `last_status` is a statement about the fire, not about the run. (The scheduler hardening in PR #1114 fixed the *timing* of that write; it did not give it an outcome to write.)

---

## 2. The design in one paragraph

A fire becomes a **run**, and a run owns a **real chat session**. A new table `routine_runs` records the run (who fired it, when, why, how it ended). The fire path stops emitting `RunParamsNew` itself and goes through `App.emit_run_agent` — the same funnel a chat send uses — so `insert_worker` inserts the `worker` row and the `sessions.created` event reaches the UI. The session is created *by us*, before the agent starts, stamped with the workspace and the routine, so that it is in the sidebar while the first token is still streaming. Three surfaces read that one truth: a **Runs** section in the routine view, a **Running now** group at the top of the chat list, and a **run header** on the run's chat.

```
POST /run  ──► routine_runs row (queued) ──► sessions row (active, workspace, cwd)
                                          ──► sessions.created  ──► sidebar + running list
                                          ──► emit_run_agent    ──► worker row ──► agent loop
                                                                        │
            agent loop ends (worker row deleted) ◄──────────────────────┘
                                          ──► routine_runs row (success | failed | needs_you)
```

---

## 3. Data model — Migration 125

New table. No column is added to `sessions`: that table is read by every list query and joined in a dozen places in `llm_history.zig`, and a run's lifecycle is not a session's lifecycle (a run is `queued` before any session work happens, and `needs_you` after the session has gone quiet).

```sql
CREATE TABLE IF NOT EXISTS routine_runs (
    id                TEXT PRIMARY KEY,          -- run_<unix_seconds>_<item suffix>
    routine_id        TEXT NOT NULL,             -- workspace_routines.id (== the routine item id)
    workspace_item_id TEXT NOT NULL,
    workspace_id      TEXT NOT NULL,
    session_id        TEXT NOT NULL UNIQUE,      -- sessions.id of this run's chat (= id)
    trigger           TEXT NOT NULL,             -- 'schedule' | 'manual'
    due_at            TEXT,                      -- the scheduled slot, NULL for manual
    status            TEXT NOT NULL DEFAULT 'queued',
                                                 -- queued|running|success|failed|cancelled|needs_you|stale
    started_at        TEXT NOT NULL,             -- SQLite UTC 'YYYY-MM-DD HH:MM:SS'
    finished_at       TEXT,
    error             TEXT,
    created_at        TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_routine_runs_routine ON routine_runs(routine_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_routine_runs_session ON routine_runs(session_id);
CREATE INDEX IF NOT EXISTS idx_routine_runs_status  ON routine_runs(status, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_routine_runs_ws      ON routine_runs(workspace_id, started_at DESC);
```

Decisions:

- **`routine_runs.id` == `routine_runs.session_id`.** One id, one pair of rows, no join table. `sessions.id` is free-form text (`app.zig:236`), so this costs nothing. Format `run_<unix_seconds>_<item suffix>` (e.g. `run_1793556739_1793535810996950572`) is readable in a log and monotonic enough; the insert retries with `+1s` on a primary-key collision.
- **`trigger` and `due_at` are columns, not derivable** — "did a human press Run now, or did the clock?" is the first question asked of any failed run, and `latest` is not good enough later.
- **`status` is written, not computed.** Only four writers: the fire (queued → nothing), the terminal step (success/failed/needs_you), the stop endpoint (cancelled), and the boot/steady-state reclaimer (stale → failed). Everything else reads.
- **Retention:** insert and prune in the same statement pair — keep the newest 200 runs per routine. A 5-minute routine produces 288 runs/day; unbounded is not an option.
- The table is additive and replayable: `IF NOT EXISTS` everywhere, so migration 125 re-runs as a no-op (the convention `migration_124.zig` follows).

`sessions` gains nothing, but three values matter and must be set at insert: **`workspace_id`** (so `workspace_scope.workspaceSessionIds`, `agentic_loop/workspace_scope.zig:118-160`, resolves the run into its workspace — it re-resolves every session through `resolveWorkspaceId`, whose step 2 is this stamp), **`cwd`** (the routine item's `path`, so tools and the git badge behave like a normal chat), and **`name`** (`Collect security issues · 18:09` — the chat list has to be readable).

---

## 4. The fire sequence (replaces `fireWorkspaceRoutine`)

```
fireWorkspaceRoutine(allocator, db, di, io, routine_id, trigger, due_at) !RunRef
 1. routine = model.loadWorkspaceRoutineById(...)          -- existing
    ctx     = model.loadRoutineContext(...)                -- NEW: workspace_id, item path, item name, owner
    if (!routine.enabled) return FireError.Disabled
 2. if (model.openRunFor(allocator, db, routine_id)) |open| return FireError.AlreadyRunning{ .run = open }
                                                           -- the overlap guard, now a fact not a status string
 3. run_id    = makeRunId(allocator, routine_id, now)      -- run_<secs>_<suffix>
    session_id = run_id
 4. run = model.insertRun(.{ id = run_id, routine_id, …, trigger, due_at, status = "queued" })
    model.pruneRuns(allocator, db, routine_id, 200)
 5. sessions.Insert:  INSERT INTO sessions (id, name, status, cwd, workspace_id, created_at, updated_at,
                                            selected_profile_model, is_auto_retry_until_stop, user_id)
                       VALUES (?, ?, 'active', ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, '0', ?)
                      -- NOT ON CONFLICT DO NOTHING: a collision is a bug, and we want it loud
    on_event_sent.onEventSendSessions(.{ .action = "created", .id = session_id, … })
                      -- the run is in the sidebar BEFORE the agent starts
 6. model.markRoutineRunStarted(...)  -- workspace_routines.last_status='running', last_run_at=now,
                                       -- next_run_at = nextFireTime(now) (schedule fires only; unchanged semantics)
 7. di.emit_run_agent(.{
        .session_id       = session_id,
        .session_name     = session_name,          -- "<routine name> · HH:MM"
        .queue_message    = payload.message,        -- formatRoutineMessage(...), unchanged
        .cwd              = ctx.path,
        .selected_profile_model = routine.selected_profile_model,
        .is_auto_retry_until_stop = "0",            -- routines are NOT auto-retry-until-stop
        .user_id          = ctx.owner_user_id,
    })
        └─ insert_worker: INSERT INTO sessions … ON CONFLICT DO NOTHING  → no-op (changes()==0, no second broadcast)
                         INSERT INTO worker  → "running" becomes observable through GET /api/workers
                         emit RunParamsNew   → workflow: worker slot, queue message, agent loop
 8. after emit returns (the loop has finished; emit is synchronous):
    reason = sessions.last_finish_reason of session_id
    status = reason == "stop"          → success
           : reason == "awaiting_user" → needs_you     (the routine asked a question)
           : else                      → failed
    model.finishRun(run_id, status, finished_at, error)
    model.markRoutineRunFinished(routine_id, status)   -- last_status/last_error, mirrors today's markSuccess/markFailed
```

Why this order and not "let `insert_worker` do it":

- `insert_worker` cannot stamp `workspace_id`, and it broadcasts `sessions.created` with an empty `cwd` payload; doing the insert first and broadcasting ourselves means the sidebar row is correct on arrival, not corrected later.
- Because the sessions insert is `ON CONFLICT DO NOTHING` (`app.zig:236`) and the broadcast is gated on `db.changes() > 0`, our row makes `insert_worker` a silent no-op — exactly one broadcast, no duplicate sidebar row.
- `App.emit_run_agent` stamps `last_human_touched_at_nano = NULL` (`app.zig:129-141`), which is correct: an automated fire must not clear the "unread" dot on a human conversation, and it must not make the run look touched by a human.

Two smaller changes in the same step:

- **`FireError.AlreadyRunning` carries the open run** instead of being a boolean, so the endpoint can answer `409 {"error":"routine is already running","run_id":"…","session_id":"…"}` and the UI can offer *Open the run in progress*.
- **The overlap guard moves off `last_status`.** Today `claimForRun` writes `last_status='running'` and `listDueWorkspaceRoutineIds` skips `running` rows (`model.zig:118-127`). The guard becomes `openRunFor()` — a query on `routine_runs` — and `last_status` goes back to being a *display* value. A stuck row can no longer wedge a routine forever: `Scheduler.reclaimStaleRuns` closes the run and clears the flag together.

---

## 5. API

| Method | Path | Change |
| --- | --- | --- |
| `POST` | `/api/workspaces/:ws/items/:item/routines/:routine_id/run` | **202** `{ run_id, session_id, status: "queued" }` (was 200 `{success, session_id: <routine_id>, status:"firing"}`). `409` now carries `run_id` / `session_id` of the run in flight. |
| `GET` | `/api/workspaces/:ws/routine-runs?status=live\|all&limit=50` | **New.** The workspace-wide Running list. |
| `GET` | `/api/workspaces/:ws/items/:item/routines/:routine_id/runs?limit=20` | **New.** One routine's history, for the Runs section. |
| `POST` | `/api/routine-runs/:run_id/stop` | **New.** Cancels the run (worker `cancelled=1` via the existing stop path, run → `cancelled`). |
| `GET` | `/api/sessions` | Unchanged shape **plus** `routine_run_id` and `routine_name` (nullable, from `LEFT JOIN routine_runs r ON r.session_id = s.id`), so a run's row in the chat list can be badged. |

Row shape for both list endpoints (identical, so the two panels share one store):

```json
{
  "id": "run_1793556739_1793535810996950572",
  "routine_id": "item_1793535810996950572",
  "routine_name": "Collecting security Issuess",
  "workspace_item_id": "item_1793535810996950572",
  "session_id": "run_1793556739_1793535810996950572",
  "status": "running",
  "trigger": "manual",
  "due_at": null,
  "started_at": "2026-11-01 18:09:56",
  "finished_at": null,
  "elapsed_ms": 41000,
  "error": null,
  "last_activity_description": "Read src/http_handlers/worker_list.zig"
}
```

`last_activity_description` comes from the `worker` row (`worker.last_activity_description`, already populated by the loop) and is `null` once the worker is gone — the panel then shows the finished duration instead of a stale activity line. Never a joined string built in SQL: the run list is polled, so it stays one query per endpoint.

`status=live` is the running list (`queued`, `running`), `status=all` the history. Both order `started_at DESC`.

---

## 6. State machine

```
queued ──worker row appears──► running
   │                             │
   │                             ├─ last_finish_reason = 'stop'          ─► success
   │                             ├─ last_finish_reason = 'awaiting_user' ─► needs_you
   │                             ├─ other / no rows                       ─► failed
   │                             ├─ user pressed Stop                     ─► cancelled
   │                             └─ no activity for 30 min (reclaim)     ─► stale ─► failed
   └─ insert failed / never started ─────────────────────────────────────► failed
```

- **`stale` is transient and honest**: the 30-minute threshold is `Scheduler.stale_run_timeout_seconds`, which already exists for `reclaimStaleRuns`; the run row shows `stale` for one tick and then `failed` with `error = "no activity for 30 minutes"`.
- **Boot closes open runs.** `Scheduler.start` already calls `resetStuckRunning` before the first tick; it gains the run-table equivalent (`UPDATE routine_runs SET status='failed', error='process killed (restart detected)' WHERE status IN ('queued','running')`), in the same transaction.
- **`needs_you` is the state this design exists for.** A routine that hits `ask_user` currently ends silently. With a real session it ends as a session you can open and answer, and the running list says so before you look.

---

## 7. UI — three surfaces, one truth

### 7.1 The routine view (Routine tab)

The dead `Running now` block is replaced by a **Runs** section that is always mounted:

- **Live run, when there is one:** status dot, `started 18:09` + live elapsed, the worker's last activity line, and two actions — `Open chat` (primary) and `Stop`. The header pill becomes this run's status and is itself a link to the chat.
- **History, always:** the last 5 runs, one line each — status, started time, duration, trigger (`Scheduled` / `Manual`), and `Open` — with `Show all runs` opening the full list. A failed row carries its error on a second line, truncated, with the full text in the title. An empty history says so, once, in the panel: *"No runs yet. Run now fires it once; a schedule fires it on its own."*
- **Run now** navigates: `await runRoutineItem(...)` returns `{run_id, session_id}` → `router.replace(chat url)` on success. The old behaviour (stay on the form, refresh the pill) is what makes the feature feel broken.

### 7.2 The chat list (sidebar)

A **Running now** group above the regular chats, rendered only when non-empty, collapsible, one row per live run:

```
● Collecting security Issuess        0:41
  Routine · manual · Read src/httphandlers/worker_list.zig
```

- The dot pulses (reduced-motion: static); the elapsed chip is the same `WorkerElapsedChip` the task rows already use, so the vocabulary is not new.
- Click → that run's chat. A `Stop` action appears on row hover, never as a second always-visible control.
- Data: `GET /api/workspaces/:ws/routine-runs?status=live`, polled every 4s while the group is non-empty, plus the existing `sessions.created` SSE event for the instant insert. When the group empties it stops polling.

Routine-run sessions themselves also appear in the normal chat list, badged `Routine` (from `routine_run_id`/`routine_name`), so a run survives the group emptying and stays findable.

### 7.3 The run's chat

A run header strip sits above the message list, in the same place a sub-agent or PR badge already sits:

```
⟳ Collecting security Issuess · Scheduled 09:00 · started 18:09 · 0:41     [Stop]  [Routine ↗]
```

- `Scheduled 09:00` / `Manual` is the trigger. Time is in the user's locale, not UTC — UTC belongs on the cron field in the form, where the schedule is authored.
- The fire message keeps `formatRoutineMessage`'s text but is rendered as a **routine instruction** block (a distinct role treatment, monospace body, quoted) rather than a user bubble: the user did not type it, and pretending otherwise is what makes an automated run confusing to read back.
- For `needs_you`: a bar above the composer — *"The routine asked you a question. Your reply continues this run."*
- For `failed`: the error is inline at the end of the transcript, with `Retry run` (re-fires the routine; new run, new session) and `Open routine`.

### 7.4 States the panels must each prove

`never run` · `queued` (worker not yet claimed) · `running` · `success` · `failed` (with error) · `cancelled` · `needs_you` · `stale`. The wireframe draws the five that change layout.

---

## 8. Files

**Backend**

| File | Work |
| --- | --- |
| `src/migrations/migration_125.zig` | the table + four indexes, `IF NOT EXISTS`, one replay test; register in `src/migrations/migration.zig` |
| `src/ai_workflow/tui/routines/model.zig` | `RoutineRun` type, `insertRun`, `openRunFor`, `finishRun`, `listRuns`, `pruneRuns`, `loadRoutineContext`; drop `claimForRun`'s status write |
| `src/ai_workflow/tui/routines/fire.zig` | the §4 sequence; delete the direct `event_bus.emit` and the unconditional `markSuccess` |
| `src/ai_workflow/tui/routines/Scheduler.zig` | boot: close open runs; tick: stale run → failed; `fireDueRoutines` passes `trigger="schedule"`, `due_at` |
| `src/http_handlers/workspace_routines_run.zig` | 202 + `{run_id, session_id}`; 409 carries the open run |
| `src/http_handlers/workspace_routine_runs_list.zig` | **new** — both list endpoints' use case (`listRunsUseCase`) with workspace scoping |
| `src/http_handlers/routine_run_stop.zig` | **new** — stop via the existing worker-cancel path |
| `src/http_handlers/mod.zig`, `src/http_routes.zig` | exports + three routes |
| `src/agentic_loop/llm_history.zig` | `LEFT JOIN routine_runs` in `getSessionListWithCursor`; two nullable fields on `SessionTableInfo` |

**Frontend**

| File | Work |
| --- | --- |
| `src/apps/desktop/src/api/routineRuns.ts` | **new** — wire types + four calls |
| `src/apps/desktop/src/stores/routineRuns.ts` | **new** — live list, poll lifecycle, stop, the "one failure is never an empty list" rule |
| `src/apps/desktop/src/components/views/RoutineView.vue` | Runs section, header pill → open run, `Run now` navigates |
| `src/apps/desktop/src/components/views/chatsList/RunningRunsGroup.vue` | **new** — the sidebar group |
| `src/apps/desktop/src/components/views/chat/RunHeader.vue` | **new** — the run strip above the transcript |
| `src/apps/desktop/src/helpers/runMessage.ts` | **new** — recognise the `formatRoutineMessage` header, so the transcript can render it as a routine instruction |

---

## 9. Tests

**Zig unit (`zig build test`, `src/ai_workflow/tui/routines/*`)**

1. *A fire creates the session row* — the regression test for this bug: after `fireWorkspaceRoutine`, `SELECT workspace_id, cwd FROM sessions WHERE id = <run.session_id>` returns the workspace and the routine's path. Fails today.
2. *A fire creates the run row* — status `running`, trigger and `due_at` preserved.
3. *A second fire while one is open* → `FireError.AlreadyRunning` carrying the open run's id; the routine's own fields are untouched.
4. *A terminal reason maps to a status*: `stop`→`success`, `awaiting_user`→`needs_you`, `length`/absent→`failed`, with `finished_at` set.
5. *Boot closes open runs*: `Scheduler.start`'s reset leaves no `queued`/`running` row and writes the restart error.
6. *Retention*: the 201st insert prunes the oldest, and the newest survives.
7. *Migration 125 replays* as a no-op (the `migration_124.zig` test shape).

**Zig functional (`zig build functional-test:zig`)**

8. `POST …/run` → 202 with a `run_id`; `GET …/routine-runs?status=live` lists it; `GET /api/sessions?workspace_id=…` includes the run's session id — the three assertions the bug broke, in one test.
9. A disabled routine still 409s; a non-routine id still 404s.
10. `POST /api/routine-runs/:id/stop` → the row is `cancelled` and vanishes from `status=live`.

**Vitest (`cd src/apps/desktop && pnpm run test`)**

11. `RoutineView` renders a live run with `Open chat`; renders the empty history sentence when there are none; renders a failed run's error.
12. `Run now` navigates to the returned `session_id` (and does *not* navigate on a 409).
13. `RunningRunsGroup` is absent when empty, and polls only while non-empty.
14. `RunHeader` shows `Scheduled` vs `Manual`, and the `needs_you` bar.

---

## 10. Rollout, and what is deliberately out of scope

Ship in three commits, each green on its own:

1. **backend** — migration 125, the fire sequence, the three endpoints, tests 1–10. Nothing in the UI changes yet; runs already become real sessions.
2. **routine view** — the Runs section, `Run now` navigation, tests 11–12.
3. **shared surfaces** — the sidebar group, the chat run header, tests 13–14.

Deliberately not in this design:

- **Next-fire arithmetic.** `next_run_at` is still computed from completion time. Changing it to "next slot after `due_at`" changes scheduling semantics for every existing routine; it deserves its own task and its own proof.
- **Catch-up fires** missed while the server was down. Today they are silently dropped (PR #1114 made that visible, not repaired). With `routine_runs` a `missed` row becomes possible — later.
- **Retry policy** for a failed run. The run is visible and re-fireable; automatic retries are a separate decision (`is_auto_retry_until_stop` must stay `0` for routines).
- **Per-routine conversation continuity** (a "continue the previous run's chat" toggle). Fresh session per run is the honest default; the toggle is a two-line addition once runs exist, and the design keeps `routine_runs.session_id` unique so a continuous mode would need a second column, not a schema rewrite.

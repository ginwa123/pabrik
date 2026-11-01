# Routine runs — one real chat session per fire, and a Running list

**Status:** design, not implemented. Revision 2 (storage simplified after review: no `routine_runs` table, no task rows).
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

`workspace_routines` keeps exactly one slot — `last_run_at`, `last_status`, `last_error`. A one-slot table cannot answer "which runs are live right now", "how long did the 09:00 run take", or "open the run from yesterday that failed".

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

A fire becomes a **run**, and a run **is a chat session**. The session is created by the fire, before the agent starts, through the same funnel a chat send uses (`App.emit_run_agent`), stamped with the workspace, the routine and the trigger — so `insert_worker` inserts the `worker` row, `sessions.created` reaches the UI, and the run is in the sidebar while the first token streams. Four new columns on `sessions` carry the three things a session cannot infer (which routine, which trigger, which due slot) plus the error text. Nothing else is added: the run's state is **derived** from the `worker` row and `sessions.last_finish_reason`, exactly the signals the chat already trusts. Three surfaces read that one truth: a **Runs** section in the routine view, a **Running now** group at the top of the chat list, and a **run header** on the run's chat.

```
POST /run  ──► sessions row (id = run id, routine_id, trigger, due_at, workspace_id, cwd)
                            ──► sessions.created  ──► sidebar + running list
                            ──► emit_run_agent    ──► worker row ──► agent loop
      loop ends (worker row deleted) ◄──────────────────────────────┘
                            ──► last_finish_reason written  ──► the run's state, derived
```

---

## 3. Storage: what is reused, what is added, what is dropped

Three questions came out of review: *can a run just be a `workspace_item_tasks` row?* and *do we even need `workspace_routines`?* Both were measured against the tree; the answers differ.

### 3.1 Verdicts

| Piece | Verdict | Why |
| --- | --- | --- |
| `workspace_items` (`id, workspace_id, item_type, name, path, …`) | **reused as the routine's identity** | name and folder path already live here (`workspaces_list.zig:174`); a second copy is what §3.3 deletes |
| `sessions` (`id` is the chat id) | **reused as the run** | §3.2: four nullable-by-default columns, no new table |
| `workspace_item_tasks` (id **is** the session id) | **not used for runs** | §3.4 |
| `agent_configs` (`item_type='routine'`) | **unchanged** | already the routine's knowledge, tools and system prompts (migration 116) |
| `workspace_routines` | **kept, 13 columns → 7** | §3.3: cron state has no other home, but four of its columns are duplicates or derivable |
| `routine_runs` (revision 1 of this doc) | **dropped** | every field it held was already on the session, or derivable from it |

### 3.2 The run is a session row with four extra columns (migration 125)

```sql
ALTER TABLE sessions ADD COLUMN routine_id   TEXT NOT NULL DEFAULT '';  -- '' = an ordinary chat
ALTER TABLE sessions ADD COLUMN run_trigger  TEXT NOT NULL DEFAULT '';  -- 'schedule' | 'manual'
ALTER TABLE sessions ADD COLUMN run_due_at   TEXT NOT NULL DEFAULT '';  -- the scheduled slot; '' for manual
ALTER TABLE sessions ADD COLUMN run_error    TEXT NOT NULL DEFAULT '';  -- why it failed, if it did
CREATE INDEX IF NOT EXISTS idx_sessions_routine ON sessions(routine_id, created_at DESC);
```

Four columns, written with the repo's `addColumnIfMissing` guard so migration 125 replays as a no-op (the `migration_124.zig` shape).

Why this and not a `routine_runs` table: a run needs identity, start, end, workspace, cwd, a chat, a status and an error. The session already has the first six. A separate table would buy a `status` column, and cost a 1:1 join in every list, a second id to keep equal to the first, a second row to create and fail to create, and its own retention code. The three genuinely new values are `trigger`, `due_at` and `error` — that is not a table.

**State is derived, never stored:**

| State | Predicate (one query, no join) |
| --- | --- |
| `queued` | `routine_id <> '' AND created within 60s AND NOT EXISTS (SELECT 1 FROM worker w WHERE w.session_id = s.id)` |
| `running` | `EXISTS (SELECT 1 FROM worker w WHERE w.session_id = s.id AND w.cancelled = 0)` |
| `cancelled` | `s.status = 'cancelled'` (the column and `updateSessionStatus` already exist, `llm_history.zig:3466`) |
| `needs you` | `s.last_finish_reason = 'awaiting_user'` |
| `success` | `s.last_finish_reason = 'stop'` |
| `failed` | no worker, no `stop`, not cancelled — with `run_error` in hand |
| `stale` | running, and the worker's `last_activity_nano` is older than 30 min (`Scheduler.stale_run_timeout_seconds`) |

`run_error` is new information the product currently **loses**: the loop builds the message (`workflow.zig:1309`, `last_dynamic_agent_error_message`) and pushes it to a live SSE client, but nothing persists it — close the tab and a failed run's reason is gone. Writing it on the way out fixes the run list and repairs the chat.

**The chat list keeps runs out of the way** — one predicate in `getSessionListWithCursor`, beside the one that already hides sub-agent sessions (`s.id NOT LIKE '%subagent%'`, `llm_history.zig:300`):

```sql
AND COALESCE(CAST(s.routine_id AS TEXT), '') = ''
```

A 5-minute routine produces 288 sessions a day. They must not be 288 rows in the chat list; they are reached through the runs endpoints, and the "All chats / Routine runs" switch is the opt-in.

**Retention** is deleting the session, which is a thing the user already understands: keep the newest 200 runs per routine, `DELETE FROM sessions WHERE …`, plus its messages. Detail to verify at implementation: `delete_session` (`llm_history.zig:3805`) removes only the `sessions` row today, so the message-delete path the chat's own delete uses must be called with it.

### 3.3 `workspace_routines` is real, but it is carrying dead weight

Current shape (migration 84 + 124 + 110): `id, workspace_item_id, description, instruction, schedule, selected_profile_model, enabled, next_run_at, last_run_at, last_status, last_error, created_at, updated_at` — 13 columns.

| Column | Verdict |
| --- | --- |
| `id` | **drop** — it is written equal to `workspace_item_id` by construction (`Routine.id == workspace_item_id`). Keep one key: `workspace_item_id` as the primary key. |
| `description` | **drop** — a duplicate. `agent_configs.description` already holds the routine's description for the same item (migration 116 created it and copied the value; `PATCH /agent/routine` writes it, `agent_routines_get.zig:344` pins it). Two write paths for one label is a bug waiting to happen. |
| `last_run_at` | **drop** — `MAX(created_at)` of the run sessions. |
| `last_error` | **drop** — the latest failed run's `run_error`. |
| `last_status` | **keep as the fire mutex.** It is the atomic guard `claimForRun` already uses (one `UPDATE … WHERE last_status <> 'running'`, `changes()` decides), already covered by tests, and already honoured by `listDueWorkspaceRoutineIds`. Renaming it would be churn; it stops being a *reported outcome* and becomes a *lock*. |
| `instruction`, `schedule`, `enabled`, `next_run_at` | **keep** — this is the one thing neither other table can hold. `workspace_items` is shared by every item type and read on every sidebar query, so a cron expression does not belong on it; `agent_configs` is deliberately family-neutral (migration 116's whole design), so routine-only timing columns would break that symmetry. |
| `selected_profile_model` | **keep** (migration 124) until "which profile" moves to `agent_configs` for all three families — a separate change with its own blast radius. |

End state, 7 columns:

```sql
workspace_routines (
    workspace_item_id TEXT PRIMARY KEY REFERENCES workspace_items(id) ON DELETE CASCADE,
    instruction TEXT NOT NULL DEFAULT '',
    schedule TEXT NOT NULL DEFAULT '',
    enabled INTEGER NOT NULL DEFAULT 1,
    next_run_at TIMESTAMP,
    selected_profile_model TEXT NOT NULL DEFAULT '',
    last_status TEXT NOT NULL DEFAULT 'idle'      -- the fire lock, not a display value
)
```

One further finding, for a later task: the only thing `workspace_routines` is asked outside the scheduler is *"does this id belong to a routine?"* — `SELECT workspace_item_id FROM workspace_routines WHERE id = ?` in `workflow.zig:2621` and `prompts_make_agent_routine_system_prompt.zig:26`. `workspace_items.item_type = 'routine'` already answers that. It is not worth changing inside this task, and the table does not disappear either way.

### 3.4 Why a run is not a `workspace_item_tasks` row

The chain the reviewer asked about — workspace → workspace_item → workspace_item_task → session — is genuinely the right shape, and `workspace_item_tasks` already follows the same convention this design uses: **`t.id` is `s.id`**, which migration 52 enforced by *dropping* `workspace_item_tasks.session_id`. A run row there would be attributed to the routine item by the chat list's own subquery (`SELECT t.workspace_item_id FROM workspace_item_tasks t WHERE t.id = s.id`, `llm_history.zig:382`), and it would nest under the routine in the sidebar with no new list UI.

What it costs:

1. **`task_type` is decorative today, and the sweep is repo-wide.** A grep of `src` finds no `WHERE task_type = …` predicate anywhere. Every run would therefore appear as a task in the item's task list, in the workspace item counts (`workspaces_list.zig:147`), in `run_all_agents` / `stop_all_agents`, in `task_delete` / `task_update` / `tasks_reorder_pinned`, in the kanban joins (`kanban_model.zig`, 24 references) and in the agent's `kanban_list` tool (25 references). Making `task_type` load-bearing means adding an exclusion to ~15 query sites and to every future one, with no compiler help; the table is referenced by roughly 120 source files.
2. **Run-only state on a hot table.** `trigger`, `due_at`, `error` and `status` would become columns on the table that `llm_history.zig` alone touches 68 times — and the run's outcome would still come from `sessions.last_finish_reason` plus the `worker` row, so the truth would be spread across three tables instead of derived from two signals.
3. **No retention story.** Tasks are user data: nothing prunes them, `workspace_items` shows a count of them, and the sidebar renders them. Pruning runs would mean silently deleting rows the user can see. 288 rows a day per routine is not a rounding error.
4. **The task UI leaks onto runs.** Rename, pin, delete, drag between kanban columns, "start agent on task", tags — all of it would render for a run and be wrong for most of it, so every one of those affordances needs a conditional instead of the zero conditionals a separate concept needs.

So: the same id convention, the same workspace scoping, the same session — but the run is recorded on the session, not as a user-visible task.

---

## 4. The fire sequence (replaces `fireWorkspaceRoutine`)

```
fireWorkspaceRoutine(allocator, db, di, io, routine_id, trigger, due_at) !FireResult
 1  routine = model.loadWorkspaceRoutineById(...)          -- existing
    ctx     = model.loadRoutineContext(...)                -- NEW: workspace_id, item path, item name, owner
    if (!routine.enabled) return FireError.Disabled
 2  if (!model.claimForRun(allocator, db, routine.id)) return FireError.AlreadyRunning
                                                           -- unchanged atomic UPDATE; the run id is not known yet
 3  run_id = session_id = makeRunId(allocator, routine_id, now)   -- run_<secs>_<suffix>
 4  INSERT INTO sessions (id, name, status, cwd, workspace_id, created_at, updated_at,
                          selected_profile_model, is_auto_retry_until_stop, user_id,
                          routine_id, run_trigger, run_due_at)
       VALUES (?, ?, 'active', ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, '0', ?, ?, ?, ?)
    on_event_sent.onEventSendSessions(.{ .action = "created", .id = session_id, … })
                                                           -- the run is in the sidebar BEFORE the agent starts
 5  workspace_routines: last_run_at is gone; next_run_at = nextFireTime(now) when a schedule exists
 6  di.emit_run_agent(.{
        .session_id = session_id, .session_name = "<routine name> · HH:MM",
        .queue_message = formatRoutineMessage(...), .cwd = ctx.path,
        .selected_profile_model = routine.selected_profile_model,
        .is_auto_retry_until_stop = "0", .user_id = ctx.owner_user_id })
        └─ insert_worker: INSERT INTO sessions … ON CONFLICT DO NOTHING → no-op (no second broadcast)
                         INSERT INTO worker → "running" becomes observable through GET /api/workers
                         emit RunParamsNew  → workflow: worker slot, queue message, agent loop
 7  the loop finishes (emit is synchronous):
    reason = sessions.last_finish_reason of session_id
    UPDATE sessions SET run_error = ? WHERE id = ? AND reason NOT IN ('stop','awaiting_user')
    UPDATE workspace_routines SET last_status = 'success' | 'failed', updated_at = now
```

No new table, one insert added, one row updated on the way out. The `sessions` insert is **not** `ON CONFLICT DO NOTHING`: a collision is a bug and it should be loud.

Because the sessions insert happens first, `insert_worker`'s `INSERT … ON CONFLICT DO NOTHING` (`app.zig:236`) is a no-op and its `sessions.created` broadcast is skipped (`session_row_inserted = db.changes() > 0`) — one broadcast, one sidebar row, no fight. `emit_run_agent` also stamps `last_human_touched_at_nano = NULL` (`app.zig:129-141`), which is correct: an automated fire must not clear a human conversation's unread dot.

Two smaller changes in the same step:

- **`FireError.AlreadyRunning` carries the open session id**, so the endpoint answers `409 {"error":"routine is already running","session_id":"…"}` and the UI can offer *Open the run in progress*.
- **`markSuccess` after a successful *submit* is retired.** `last_status` becomes `success`/`failed` from `last_finish_reason`, so the pill stops lying (§1.6).

---

## 5. API

| Method | Path | Change |
| --- | --- | --- |
| `POST` | `/api/workspaces/:ws/items/:item/routines/:routine_id/run` | **202** `{ session_id, status: "queued" }` (was 200 `{success, session_id: <routine_id>, status:"firing"}`). `409` carries `session_id` of the run in flight. `run_id` is deliberately **not** a separate field: the run id is the session id. |
| `GET` | `/api/workspaces/:ws/routine-runs?status=live\|all&limit=50` | **New.** The workspace-wide Running list, straight off `sessions` + a `worker` existence check. |
| `GET` | `/api/workspaces/:ws/items/:item/routines/:routine_id/runs?limit=20` | **New.** One routine's history. |
| `POST` | `/api/routine-runs/:session_id/stop` | **New path, existing machinery**: cancels the worker and writes `sessions.status = 'cancelled'`. |
| `GET` | `/api/sessions` | Same shape plus `routine_id` and `routine_name` (from `sessions.routine_id` → `workspace_items.name`), and routine runs excluded unless `?include=routine_runs`. |

Row shape for both list endpoints (identical, so the two panels share one store):

```json
{
  "session_id": "run_1793556739_1793535810996950572",
  "routine_id": "item_1793535810996950572",
  "routine_name": "Collecting security Issuess",
  "workspace_item_id": "item_1793535810996950572",
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

`last_activity_description` comes from the `worker` row (`worker.last_activity_description`, already populated by the loop) and is `null` once the worker is gone — the panel then shows the finished duration instead of a stale activity line. The status column is computed in the use case, not in SQL string-building: one `CASE`, reviewed once.

`status=live` is the running list (`queued`, `running`), `status=all` the history. Both order `started_at DESC`.

---

## 6. State machine

```
no worker, < 60s old ───────────────► queued
worker row exists ──────────────────► running
   ├─ last_finish_reason = 'stop'          ─► success
   ├─ last_finish_reason = 'awaiting_user' ─► needs_you
   ├─ sessions.status = 'cancelled'        ─► cancelled
   ├─ no activity for 30 min (reclaim)     ─► stale ─► failed
   └─ any other ending                     ─► failed (+ run_error)
```

- **Nothing is stored twice.** Every arrow above is a read of the two signals the chat already trusts; the only writes are `last_finish_reason` (the loop), `sessions.status` (stop) and `run_error` (the fire, on a bad ending).
- **`stale`** uses `Scheduler.stale_run_timeout_seconds`, which already exists.
- **Boot** keeps `resetStuckRunning`: it clears `last_status = 'running'` (the lock) so a dead process cannot wedge a routine. Run rows need no repair — a session with no `stop` and no worker is `failed` by definition.
- **`needs_you` is the state this design exists for.** A routine that hits `ask_user` currently ends silently. With a real session it ends as a chat you can open and answer, and the running list says so before you look.

---

## 7. UI — three surfaces, one truth

### 7.1 The routine view (Routine tab)

The dead `Running now` block is replaced by a **Runs** section that is always mounted:

- **Live run, when there is one:** status dot, `started 18:09` + live elapsed, the worker's last activity line, and two actions — `Open chat` (primary) and `Stop`. The header pill becomes this run's status and is itself a link to the chat.
- **History, always:** the last 5 runs, one line each — status, started time, duration, trigger (`Scheduled` / `Manual`), and `Open` — with `Show all runs` opening the full list. A failed row carries its error on a second line, truncated, with the full text in the title. An empty history says so, once, in the panel: *"No runs yet. Run now fires it once; a schedule fires it on its own."*
- **Run now** navigates: `await runRoutineItem(...)` returns `{session_id}` → `router.replace(chat url)`. The old behaviour (stay on the form, refresh the pill) is what makes the feature feel broken.

### 7.2 The chat list (sidebar)

A **Running now** group above the regular chats, rendered only when non-empty, collapsible, one row per live run:

```
● Collecting security Issuess        0:41
  Routine · manual · Read src/httphandlers/worker_list.zig
```

- The dot pulses (reduced-motion: static); the elapsed chip is the same `WorkerElapsedChip` the task rows already use, so the vocabulary is not new.
- Click → that run's chat. A `Stop` action appears on row hover, never as a second always-visible control.
- Data: `GET /api/workspaces/:ws/routine-runs?status=live`, polled every 4s while the group is non-empty, plus the existing `sessions.created` SSE event for the instant insert. When the group empties it stops polling.
- Routine runs are **excluded** from the default chat list (§3.2) and reachable through this group and the routine's Runs section, with an "All chats / Routine runs" switch on the list for the history.

### 7.3 The run's chat

A run header strip sits above the message list, in the same place a sub-agent or PR badge already sits:

```
⟳ Collecting security Issuess · Scheduled 09:00 · started 18:09 · 0:41     [Stop]  [Routine ↗]
```

- `Scheduled 09:00` / `Manual` is the trigger. Time is in the user's locale, not UTC — UTC belongs on the cron field in the form, where the schedule is authored.
- The fire message keeps `formatRoutineMessage`'s text but is rendered as a **routine instruction** block (a distinct role treatment, monospace body, quoted) rather than a user bubble: the user did not type it, and pretending otherwise is what makes an automated run confusing to read back.
- For `needs_you`: a bar above the composer — *"The routine asked you a question. Your reply continues this run."*
- For `failed`: `run_error` is inline at the end of the transcript, with `Retry run` (re-fires the routine; new run, new session) and `Open routine`.

### 7.4 States the panels must each prove

`never run` · `queued` (worker not yet claimed) · `running` · `success` · `failed` (with error) · `cancelled` · `needs_you` · `stale`. The wireframe draws the five that change layout.

---

## 8. Files

**Backend**

| File | Work |
| --- | --- |
| `src/migrations/migration_125.zig` | four `addColumnIfMissing` on `sessions` + `idx_sessions_routine`, one replay test; register in `src/migrations/migration.zig` |
| `src/ai_workflow/tui/routines/model.zig` | `RunState` (derived), `makeRunId`, `insertRunSession`, `listRuns` (with the `worker` existence check), `finishRun` (writes `run_error` + `last_status`), `loadRoutineContext`; `pruneRuns` |
| `src/ai_workflow/tui/routines/fire.zig` | the §4 sequence; delete the direct `event_bus.emit` and the unconditional `markSuccess`; on return, read `last_finish_reason` |
| `src/ai_workflow/tui/routines/Scheduler.zig` | `resetStuckRunning` unchanged (clears the lock); stale run → the derived `failed`; `fireDueRoutines` passes `trigger="schedule"`, `due_at` |
| `src/http_handlers/workspace_routines_run.zig` | 202 + `{session_id}`; 409 carries the open session id |
| `src/http_handlers/workspace_routine_runs_list.zig` | **new** — both list endpoints' use case, workspace scoped, one `CASE` for the derived status |
| `src/http_handlers/routine_run_stop.zig` | **new** — worker cancel + `sessions.status = 'cancelled'` |
| `src/http_handlers/mod.zig`, `src/http_routes.zig` | exports + three routes |
| `src/agentic_loop/llm_history.zig` | `routine_id = ''` predicate + `include=routine_runs` opt-in in `getSessionListWithCursor`; `routine_id`/`routine_name` on the row type (name via `workspace_items`) |
| `src/ai_workflow/tui/routines/model.zig` (§3.3 prune) | optional follow-up migration 126: drop `id`, `description`, `last_run_at`, `last_error`; `workspace_item_id` becomes the PK |

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

1. *A fire creates the session row* — the regression test for this bug: after `fireWorkspaceRoutine`, `SELECT workspace_id, cwd, routine_id, run_trigger FROM sessions WHERE id = <returned id>` returns the workspace, the routine's path, the routine id and the trigger. Fails today.
2. *Each fire is a distinct session*, and the second fire while one is open returns `FireError.AlreadyRunning` carrying the open session id.
3. *State derives*: a session with a live `worker` row is `running`; delete the worker and write `stop` and it is `success`; `awaiting_user` is `needs_you`; a cancelled session is `cancelled`; no worker and no reason is `failed`.
4. *`run_error` is written only on a bad ending*, and left alone on `stop`.
5. *The chat list excludes runs*: `getSessionListWithCursor` for a workspace returns the human chat and not the run, and returns both with `include=routine_runs`.
6. *Boot* leaves no routine locked: `resetStuckRunning` clears `last_status = 'running'`.
7. *Retention*: the 201st run prunes the oldest session (and its messages), newest survives.
8. *Migration 125 replays* as a no-op (the `migration_124.zig` test shape).

**Zig functional (`zig build functional-test:zig`)**

9. `POST …/run` → 202 with a `session_id`; `GET …/routine-runs?status=live` lists it; `GET /api/sessions?workspace_id=…` includes the run's session id — the three assertions the bug broke, in one test.
10. A disabled routine still 409s; a non-routine id still 404s.
11. `POST /api/routine-runs/:session_id/stop` → `status=cancelled` and the row vanishes from `status=live`.

**Vitest (`cd src/apps/desktop && pnpm run test`)**

12. `RoutineView` renders a live run with `Open chat`; renders the empty history sentence when there are none; renders a failed run's `run_error`.
13. `Run now` navigates to the returned `session_id` (and does *not* navigate on a 409).
14. `RunningRunsGroup` is absent when empty, and polls only while non-empty.
15. `RunHeader` shows `Scheduled` vs `Manual`, and the `needs_you` bar.

---

## 10. Rollout, and what is deliberately out of scope

Ship in three commits, each green on its own:

1. **backend** — migration 125, the fire sequence, the three endpoints, the chat-list predicate, tests 1–11. Nothing in the UI changes yet; runs already become real sessions.
2. **routine view** — the Runs section, `Run now` navigation, tests 12–13.
3. **shared surfaces** — the sidebar group, the chat run header, tests 14–15.

Deliberately not in this design:

- **The `workspace_routines` prune (§3.3).** Dropping `id`, `description`, `last_run_at`, `last_error` is a migration-126 table rebuild with its own test; doing it in the same change would mix a schema cleanup into a behaviour fix. The four columns stay writable (and unused) until then.
- **Next-fire arithmetic.** `next_run_at` is still computed from completion time. Changing it to "next slot after `due_at`" changes scheduling semantics for every existing routine; it deserves its own task and its own proof.
- **Catch-up fires** missed while the server was down. Today they are silently dropped (PR #1114 made that visible, not repaired).
- **Retry policy** for a failed run. The run is visible and re-fireable; automatic retries are a separate decision (`is_auto_retry_until_stop` must stay `0` for routines).
- **Per-routine conversation continuity** (a "continue the previous run's chat" toggle). Fresh session per run is the honest default; with runs as sessions the toggle is one predicate, not a schema change.

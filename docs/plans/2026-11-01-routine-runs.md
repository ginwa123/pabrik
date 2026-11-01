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

Three questions came out of review: *can a run be a `workspace_item_tasks` row?*, *can a run be a session?*, and *do we need `workspace_routines` at all?* Each was measured against the tree. Answers: no, yes, and no.

### 3.1 Verdicts

| Piece | Verdict | Why |
| --- | --- | --- |
| `workspace_items` (`id, workspace_id, item_type, name, path, …`) | **reused as the routine's identity** | name and folder path already live here (`workspaces_list.zig:174`); a second copy is what §3.3 deletes |
| `sessions` (`id` is the chat id) | **reused as the run** | §3.2: four nullable-by-default columns, no new table |
| `workspace_item_tasks` (id **is** the session id) | **not used for runs** | §3.4 |
| `agent_configs` (`item_type='routine'`) | **unchanged** | already the routine's knowledge, tools and system prompts (migration 116) |
| `workspace_routines` | **dissolved into `workspace_items`** | §3.3: a routine **is** an item with `item_type='routine'`; its six settings belong on the item row, and its runs are `sessions` (1:N, §3.2). The table has no other job. |
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

### 3.3 `workspace_routines` is not a table we need at all

A routine **is** a `workspace_items` row with `item_type = 'routine'` — that is how the item tree, the sidebar, `/api/workspaces/:ws/items`, `workspaceSessionIds` and the agent's routine-config lookup already treat it. `workspace_items` carries the identity (`name`, `path`, `position`), the runs are `sessions` rows pointing back at it (1:N, §3.2), so the only thing `workspace_routines` adds is **six settings on that one item**. Store them on the item:

```sql
ALTER TABLE workspace_items ADD COLUMN routine_instruction   TEXT NOT NULL DEFAULT '';
ALTER TABLE workspace_items ADD COLUMN routine_schedule      TEXT NOT NULL DEFAULT '';
ALTER TABLE workspace_items ADD COLUMN routine_enabled       INTEGER NOT NULL DEFAULT 0;
ALTER TABLE workspace_items ADD COLUMN routine_next_run_at   TEXT NOT NULL DEFAULT '';
ALTER TABLE workspace_items ADD COLUMN routine_profile_model TEXT NOT NULL DEFAULT '';  -- '' = the backend cascade
ALTER TABLE workspace_items ADD COLUMN routine_run_lock      TEXT NOT NULL DEFAULT '';  -- the fire mutex

CREATE INDEX IF NOT EXISTS idx_workspace_items_routine_due
    ON workspace_items(routine_next_run_at) WHERE item_type = 'routine';
```

Adding columns to that table is safe, measured rather than assumed:

- **no query does `SELECT * FROM workspace_items`** (grep: zero matches), so the positional row readers cannot shift under an ALTER;
- `workspaces_list.zig:174`, `llm_history.zig:4202` and `agentic_loop/workspace_scope.zig` all select an explicit column list;
- the `routine_` prefix keeps the type-specificity visible in psql and in a diff, and `item_type = 'routine'` is already the discriminator on every read;
- the partial index means the scheduler scans only routine rows, not the folder/kanban/design/agent rows beside them.

What this deletes from `workspace_routines`, all 13 columns:

| Column | Fate |
| --- | --- |
| `id`, `workspace_item_id` | **gone** — the item id is the routine id; there is no second key to keep equal |
| `description` | **gone as a copy** — `agent_configs.description` already holds the routine family's description (migration 116), and one column with one writer is the whole point |
| `instruction`, `schedule`, `enabled`, `next_run_at`, `selected_profile_model` | **move to `workspace_items`** with the `routine_` prefix |
| `last_run_at`, `last_error` | **gone** — `MAX(created_at)` and the latest failed run's `run_error` (§3.2) |
| `last_status` | becomes **`routine_run_lock`** — still the atomic `claimForRun` mutex, no longer a reported outcome |
| `created_at`, `updated_at` | already on the item row |

Two consequences worth naming:

- **`workspace_items_create_routine.zig` goes from three inserts to two.** Today it inserts the item (`:122`), the routine row (`:131`) and an `agent_configs` row (`:141`); after this the item row carries the routine settings, and the `agent_configs` row remains only for the agent's description, knowledge, tools and prompts.
- **`GET …/routine` becomes one row read with no join**, and `PATCH …/routine` updates one row. Today both join `workspace_items` to `workspace_routines` for the same five values.

The trade-off, stated plainly: six routine-only columns on the table every item type shares. The textbook alternative is a side table, and §11 records the side table that would fit (`agent_configs`), why it does not fit as well, and the condition under which we should revisit this and move to side tables for real.

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
 5  workspace_items: routine_next_run_at = nextFireTime(now) when a schedule exists
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
    UPDATE workspace_items SET routine_run_lock = 'success' | 'failed'   the pill stops lying
```

No new table, one insert added, one row updated on the way out. The `sessions` insert is **not** `ON CONFLICT DO NOTHING`: a collision is a bug and it should be loud.

Because the sessions insert happens first, `insert_worker`'s `INSERT … ON CONFLICT DO NOTHING` (`app.zig:236`) is a no-op and its `sessions.created` broadcast is skipped (`session_row_inserted = db.changes() > 0`) — one broadcast, one sidebar row, no fight. `emit_run_agent` also stamps `last_human_touched_at_nano = NULL` (`app.zig:129-141`), which is correct: an automated fire must not clear a human conversation's unread dot.

Two smaller changes in the same step:

- **`FireError.AlreadyRunning` carries the open session id**, so the endpoint answers `409 {"error":"routine is already running","session_id":"…"}` and the UI can offer *Open the run in progress*.
- **`markSuccess` after a successful *submit* is retired.** `routine_run_lock` becomes `success`/`failed` from `last_finish_reason`, so the pill stops lying (§1.6).

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
- **Boot** keeps `resetStuckRunning`: it clears `routine_run_lock = 'running'` (the lock) so a dead process cannot wedge a routine. Run rows need no repair — a session with no `stop` and no worker is `failed` by definition.
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
| `src/ai_workflow/tui/routines/model.zig` | `RunState` (derived), `makeRunId`, `insertRunSession`, `listRuns` (with the `worker` existence check), `finishRun` (writes `run_error` + `routine_run_lock`), `loadRoutineContext`; `pruneRuns` |
| `src/ai_workflow/tui/routines/fire.zig` | the §4 sequence; delete the direct `event_bus.emit` and the unconditional `markSuccess`; on return, read `last_finish_reason` |
| `src/ai_workflow/tui/routines/Scheduler.zig` | `resetStuckRunning` unchanged (clears the lock); stale run → the derived `failed`; `fireDueRoutines` passes `trigger="schedule"`, `due_at` |
| `src/http_handlers/workspace_routines_run.zig` | 202 + `{session_id}`; 409 carries the open session id |
| `src/http_handlers/workspace_routine_runs_list.zig` | **new** — both list endpoints' use case, workspace scoped, one `CASE` for the derived status |
| `src/http_handlers/routine_run_stop.zig` | **new** — worker cancel + `sessions.status = 'cancelled'` |
| `src/http_handlers/mod.zig`, `src/http_routes.zig` | exports + three routes |
| `src/agentic_loop/llm_history.zig` | `routine_id = ''` predicate + `include=routine_runs` opt-in in `getSessionListWithCursor`; `routine_id`/`routine_name` on the row type (name via `workspace_items`) |
| `src/ai_workflow/tui/routines/model.zig`, `Scheduler.zig`, `workspace_routines_get/update.zig`, `workspace_items_create_routine.zig` (§3.3 / §11.3) | follow-up migration 126: six `routine_*` columns on `workspace_items`, backfill, `DROP TABLE workspace_routines` |

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
6. *Boot* leaves no routine locked: `resetStuckRunning` clears `routine_run_lock = 'running'`.
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

- **Dissolving `workspace_routines` into `workspace_items` (§3.3 / §11).** Six columns, a backfill and a `DROP TABLE` across the scheduler, the routine API and the item-create path: a six-file refactor with its own tests, and it must not ride on a behaviour fix. Until it lands, the table stays exactly as it is and the runs fix does not depend on it.
- **Next-fire arithmetic.** `next_run_at` is still computed from completion time. Changing it to "next slot after `due_at`" changes scheduling semantics for every existing routine; it deserves its own task and its own proof.
- **Catch-up fires** missed while the server was down. Today they are silently dropped (PR #1114 made that visible, not repaired).
- **Retry policy** for a failed run. The run is visible and re-fireable; automatic retries are a separate decision (`is_auto_retry_until_stop` must stay `0` for routines).
- **Per-routine conversation continuity** (a "continue the previous run's chat" toggle). Fresh session per run is the honest default; with runs as sessions the toggle is one predicate, not a schema change.

---

## 11. The merge review asked for, and the partner that fits

Asked in review: *"`workspace_routines` should be `workspace_item` → type routine, so it should have one-to-many running sessions."* That is the model this document now specifies, and it is right: **the routine is the item, the runs are sessions, 1:N.** What follows is why the other two homes for the config were rejected, so the choice is on the record.

### 11.1 Not `workspace_item_tasks`

| | a routine | `workspace_item_tasks` |
| --- | --- | --- |
| cardinality to the item | **1 : 1** — one config per routine item (`workspace_item_id … UNIQUE`, migration 84) | **1 : N** by design — many tasks per item |
| what `id` means | the routine item id | **the session id** (migration 052 *dropped* `session_id` for exactly this) |
| rows | one per routine | one per chat, thousands |

A config row dropped into that table has to impersonate a task: its `id` either claims the routine item id as a session id (that is the §1.2 bug), or it becomes a synthetic task that the sidebar renders and that every task query returns — rename, pin, delete, drag between kanban columns, "start agent on task" — with six routine-only columns `NULL` on every human chat. And there is no way to prune runs from it without deleting rows the user can see.

The runs do reuse that table's *convention* (`t.id` is `s.id`), they just do not reuse the table: a run is a session, and the routine it belongs to is `sessions.routine_id` (§3.2).

### 11.2 Not `agent_configs` either

The first draft of this section merged `workspace_routines` into `agent_configs` — same cardinality (1:1, `workspace_item_id UNIQUE`), same key, and already the routine's description, knowledge, tools and prompts. It is the closest side table there is, and it is still the wrong home:

- **Scheduling is not agent configuration.** `agent_configs` answers *how this item's agent behaves* (description, prompts, tools, knowledge). `schedule`, `enabled`, `next_run_at` answer *when the item fires*. Putting the cron in the agent's config table reads wrong in every future query and collapses two concepts that a reader needs to keep apart.
- **A different key.** `agent_configs.id` is its own id (e.g. `a1`); the routine's key everywhere else — `workspace_item_id`, `sessions.routine_id`, the tool allowlist lookups — is the item id. Keeping both in sync is a second invariant for no gain.
- **The row can be missing.** `agent_configs` rows are created **lazily** at six-plus call sites (`agent_tools_allowed.zig:65`, `agent_kanban_tools_allowed.zig:63`, `prompts_make_agent_routine_knowledge.zig:257`, `prompts_make_agent_routine_system_prompt.zig:219`, …). A routine whose config row does not exist would not error: it would silently stop firing. The item row cannot be missing.

### 11.3 The home that fits: the item row

§3.3 has the DDL. In one line: `workspace_items` already *is* the routine (`item_type='routine'`), it already holds the identity the UI and the workspace scoping read, and the six settings are the item's own settings — not a second row's, not the agent's.

Six files read those columns today, so the sweep is contained:

| File | Change |
| --- | --- |
| `routines/model.zig` | the loader and the insert read/write `workspace_items` with `item_type = 'routine'`; same key as today |
| `routines/Scheduler.zig` | the due-scan becomes `WHERE item_type='routine' AND routine_enabled=1 AND routine_next_run_at<=?` on the partial index |
| `routines/fire.zig` | loads the same record; no structural change |
| `http_handlers/workspace_routines_get.zig` | one row read, no join |
| `http_handlers/workspace_routines_update.zig` | one row update; `description` continues to go to `agent_configs.description` |
| `http_handlers/workspace_items_create_routine.zig` | three inserts → two |

### 11.4 Trade-off, and when to revisit

Six routine-only columns on the table every item type shares. That is the price of one row per routine, a guaranteed-present config, and a single key. It is worth revisiting — i.e. move to a side table after all — the moment a **second** item type needs type-specific settings of its own; two prefixed column groups is the signal that the identity table has become a config table, and at that point both should move out together.

### 11.5 Migration plan

```
125  sessions     += routine_id, run_trigger, run_due_at, run_error      this task
126  workspace_items += 6 routine_* columns, backfill from
     workspace_routines, DROP TABLE workspace_routines                   next task (§3.3/§11.3)
```

126 is its own PR because it is a six-file refactor across the scheduler, the routine API and the item-create path, and it must not be mixed into a behaviour fix.

### 11.6 The end state

```
workspace_items   identity + routine settings   id, workspace_id, item_type='routine',
                                                name, path, routine_instruction,
                                                routine_schedule, routine_enabled,
                                                routine_next_run_at, routine_profile_model,
                                                routine_run_lock
agent_configs     how the agent behaves         description, knowledge, tools, system prompts
sessions          every run, 1:N from the item  routine_id, run_trigger, run_due_at, run_error
```

Three tables, two of which every other item type already uses, and no routine-specific table anywhere.

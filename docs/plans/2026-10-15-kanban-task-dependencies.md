# Plan — kanban task dependencies (`depends_on`) + the move gate

- **Task**: `task_1792076174180_4` — "I want kanban task can have depedency task"
- **Worktree**: `~/.config/pabrik/.worktrees/i-want-kanban-task-can-have-depedency-1792076129438`
- **Branch**: `worktree/i-want-kanban-task-can-have-depedency-1792076129438` (base `main`)
- **Status**: DELIVERED — implemented as designed; see §9 for what shipped.

---

## 1. What was asked

> I want kanban task can have dependency task. So dependency task mean if this
> task not completed yet, do not move the task to other column for example,
> how to do that?

So: **task B depends on task A**. While A is not *completed*, B cannot change
column. The rule has to hold for the human (drag & drop) **and** for the AI
agent (the `kanban_move_task` tool), so the gate lives in the data layer, not in
the UI.

---

## 2. Two questions the requirement leaves open

### 2.1 What does "completed" mean?

A kanban task has no `completed` column — it only has a *position on a board*.
The board's columns are user-defined, and on the real board used to file this
task the columns are `todo / in_review_planning / in progress / in_review_task /
merged / on_hold / drop` — the **last** column is `drop`, so "the last column
completes a task" (the heuristic the kanban prompt uses today) is wrong here,
and "the column is named `done`" is wrong on any board that names it `merged`,
`shipped`, or `Selesai`.

**Decision:** completion is an explicit **per-column flag**.

- New column `kanban_columns.is_done INTEGER NOT NULL DEFAULT 0`.
- `is_done = 1` means "a card that lands here has finished the work it
  describes", so it no longer blocks its dependents.
- Migration 110 backfills the flag by a case-insensitive name match
  (`done`, `merged`, `complete`, `completed`, `closed`, `shipped`, `drop`,
  `dropped`, `cancelled`, `canceled`, `archive`, `archived`) so an existing
  board keeps working after the upgrade, and then, for any board where *no*
  column matched, marks its **last** column as done so a dependency can never
  deadlock the board.
- The user can flip the flag in the column editor.

### 2.2 Blocked on *any* move, or only forward?

**Decision:** a task with at least one incomplete dependency cannot change
column at all — that is what was asked, verbatim ("do not move the task to
other column"). Two deliberate relaxations:

1. **Reordering inside the current column is always allowed** — the card did
   not change column, so nothing was "advanced".
2. **`force: true`** on the move request bypasses the gate. Dropping an
   abandoned card, or moving a card whose dependency is genuinely obsolete,
   must stay possible without first deleting the dependency. The frontend shows
   a "Move anyway" confirmation; the agent tool documents it as a last resort
   that the agent must be able to justify in its reply.

---

## 3. Storage

A **join table**, not a column on `workspace_item_tasks`.

```sql
CREATE TABLE IF NOT EXISTS kanban_task_dependencies (
    task_id             TEXT NOT NULL,
    depends_on_task_id  TEXT NOT NULL,
    created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (task_id, depends_on_task_id)
);
CREATE INDEX ... ON kanban_task_dependencies(task_id);
CREATE INDEX ... ON kanban_task_dependencies(depends_on_task_id);
```

Why not a `depends_on` column on `workspace_item_tasks`, like `tags`?

- The shared task `SELECT` lives in `llm_history.zig` and is pinned by ~20 test
  fixtures that create the table with a literal `CREATE TABLE`; a new column in
  that SELECT breaks every one of them ("no such column"). A new table breaks
  none.
- A real edge list gives the reverse query — "what is waiting on this task?" —
  for free, and a composite primary key makes a duplicate edge impossible.
- Replacement is a `DELETE` + `INSERT` inside one transaction, so there is no
  JSON to parse back out for cycle detection.

`workspace_item_tasks` is **not touched at all**.

---

## 4. Wire contract (backend ↔ frontend ↔ agent tools)

### 4.1 Task payload (list + get + create)

`WorkspaceItemTaskResponse` gains three **always-present** fields:

```jsonc
{
  "depends_on": ["task_1791000000000_0"],   // ids of the tasks this task waits for
  "blocked_by": [                            // the SUBSET of depends_on that is NOT completed
    { "task_id": "task_1791000000000_0", "name": "Fix login", "column_id": "col_x", "column_name": "in progress" }
  ],
  "is_blocked": true                         // blocked_by.length > 0 — a convenience mirror for the UI
}
```

`blocked_by` is the *incomplete* subset: a dependency sitting in an `is_done`
column is resolved and never appears. A dependency whose column was deleted (the
task is unassigned) counts as **incomplete**.

### 4.2 Column payload

`KanbanColumnResponse` gains `"is_done": false`.

### 4.3 Move

`PATCH /api/workspaces/:ws/items/:item/tasks/:task_id/move`

```jsonc
// request
{ "column_id": "col_done", "position": 0, "force": false }   // force optional, default false
```

- **200** — unchanged: `{ "success": true, "task_id", "column_id", "position" }`
- **409** — the gate refused:

```jsonc
{
  "error": "Task is blocked by incomplete dependency tasks",
  "blockers": [ { "task_id", "name", "column_id", "column_name" } ]
}
```

The gate only runs when the target column differs from the current one, and only
when `force != true`.

### 4.4 Dependency edit

- `PUT /api/workspaces/tasks/:task_id` (and `.../items/:item/tasks/:task_id`)
  accepts `"depends_on": ["task_a", "task_b"]` — **replace-all** semantics.
  Omitted → unchanged. `[]` → clears.
- `POST .../items/:item/tasks` and `POST .../items/:item/kanban/tasks` accept an
  optional `"depends_on"` at create time.
- `PATCH .../kanban/columns/:column_id` accepts `"is_done": true|false`.

Rejected with **400** (see §5): self-dependency, a dependency that is not a task
of the same kanban item, and any edit that would create a cycle.

### 4.5 Agent tools

- `kanban_move_task` gains **`force`** (boolean, optional).
- `create_kanban_task` gains **`depends_on`** (array of task ids, optional).
- `kanban_list` prints each task's `depends_on` / `blocked_by` so the agent can
  see the constraint instead of discovering it via a 409.

---

## 5. Validation rules (all 400)

| rule | why |
|---|---|
| a task may not depend on itself | obvious, and it would deadlock the card |
| every dependency must be a task of the **same kanban item** | cross-board edges have no board to render and no column to check |
| no cycles (`B depends on A` while `A depends on B`) | both cards would be permanently frozen |
| at most 32 dependencies per task | keeps the list payload and the graph walk bounded |

Cycle check: build the edge list of the whole item, add the proposed edges, and
BFS from `task_id`; if it reaches `task_id` again, reject. Pure function, unit
tested without a DB.

---

## 6. Where the gate lives

`src/agentic_loop/kanban_model.zig`:

```zig
pub const MoveBlockedError = error{ TaskNotFound, OutOfMemory, ... };

/// Read the incomplete dependencies of `task_id`. Empty slice = not blocked.
pub fn incompleteDependencies(alloc, db, item_id, task_id) ![]kanban_deps.Blocker;

/// The gate. No-op when the target column equals the current one.
pub fn assertMoveAllowed(alloc, db, item_id, task_id, target_column_id) MoveBlockedError!void;

/// `assertMoveAllowed` (unless `force`) + `moveTask`.
pub fn moveTaskChecked(alloc, db, item_id, task_id, target_column_id, target_position, force) !void;
```

`moveTask` itself keeps its signature and stays the low-level primitive, so its
existing fixtures keep compiling; **both** real call sites
(`http_handlers/tasks_move.zig` and `modules/agent/tools/kanban_move_task.zig`)
switch to `moveTaskChecked`, and a test asserts the agent tool cannot bypass it.

---

## 7. Files

### Backend
| file | change |
|---|---|
| `src/migrations/migration_110.zig` | **new** — join table + `is_done` column + backfill |
| `src/migrations/migration.zig` | register ×3 (import / re-export / `allMigrations`) + tests |
| `src/agentic_loop/kanban_deps.zig` | **new** — types, id/graph validation, DB read + replace |
| `src/agentic_loop/test_runner.zig` | `_ = @import("kanban_deps.zig")` so its tests actually run |
| `src/agentic_loop/kanban_model.zig` | `is_done` on `KanbanColumn` + `listColumns`, the gate |
| `src/http_handlers/http_response.zig` | task + column response fields |
| `src/http_handlers/tasks_move.zig` | 409 + `blockers` + `force` |
| `src/http_handlers/tasks_list.zig`, `tasks_get.zig` | attach `depends_on` / `blocked_by` / `is_blocked` |
| `src/http_handlers/task_update.zig` | accept `depends_on` |
| `src/http_handlers/task_create.zig`, `kanban_tasks_create.zig` | accept `depends_on` |
| `src/http_handlers/kanban_columns_update.zig` | accept `is_done` |
| `src/modules/agent/tools/{kanban_list,kanban_move_task,create_kanban_task}.zig` | §4.5 |
| `src/agentic_loop/prompts_make_kanban_context.zig` | document the blocking rule |

### Frontend (`src/apps/desktop/src`)
| file | change |
|---|---|
| `api/index.ts` | `Task.depends_on/blocked_by/is_blocked`, `KanbanColumn.is_done`, `moveTask(..., force)`, `updateKanbanColumn({is_done})`, blocker type |
| `components/kanban/KanbanDependsInput.vue` | **new** — pick dependencies from the board's tasks |
| `components/kanban/KanbanTaskDetailDialog.vue` | host the picker (next to the tags input) |
| `components/kanban/KanbanCard.vue` (and row view) | "blocked by N" chip with the blocker names |
| `components/kanban/KanbanColumnEditor.vue` | "Completes tasks (unblocks dependents)" checkbox |
| `components/AppLayout.vue` | catch the 409, confirm "Move anyway", retry with `force: true` |
| `stores/workspaces.ts` | thread `force` through `moveTaskToColumn` |

---

## 8. Testing

- Migration 110: table + both columns exist; the flag is a no-op on replay; the
  name heuristic; the last-column fallback; `is_done` is registered.
- `kanban_deps`: normalization/dedupe, self-dep, foreign id, cap, cycle
  detection (direct + transitive + diamond), the blocked-subset classifier.
- `kanban_model`: `assertMoveAllowed` allows intra-column reorder, blocks a
  cross-column move, unblocks once the dependency reaches an `is_done` column,
  and `moveTaskChecked(force=true)` bypasses.
- `tasks_move`: 200 / 409 body / force.
- Frontend vitest: the picker emits ids, the chip renders, the 409 path offers
  "Move anyway" and retries with `force`.

---

## 9. What shipped (and where it deviated)

Delivered in one PR on `worktree/i-want-kanban-task-can-have-depedency-1792076129438`:
`src/agentic_loop/kanban_deps.zig` (new), `src/migrations/migration_110.zig` (new),
the gate in `kanban_model.zig`, the task/column payload fields, the move 409, the
`depends_on` plumbing on both create paths and the update path, the three agent-tool
changes, the kanban prompt rule, and the whole frontend slice (§7).

Deviations, all deliberate:

- **`TasksMoveResult.blocked` is pre-serialized JSON, not a struct of slices.** The
  blocker strings live in the edge list, which `useCase` must free before it returns,
  so handing back a struct would hand back dangling pointers (this was a real
  use-after-free caught by the test).
- **Frontend names the blocker type `TaskDependencyBlocker`** (the backend's is
  `TaskDependencyBlocker` in `http_response.zig`) — the wire shape is what matters.
- **Create-time dependencies are API/agent-only.** The frontend picker is edit-mode
  (a new card has no id yet); `POST .../tasks` and `POST .../kanban/tasks` still accept
  `depends_on`, and `create_kanban_task` exposes it.
- **Assigning an unassigned card is allowed** (§6) — otherwise the create-then-place
  flow would 409 on its own move.
- **The plugin-visible click path is unchanged**: designing the picker to also run at
  create time is follow-up work, not this PR.

Verification: `zig build test --summary all` → `28/28 steps succeeded; 4530/4540 tests
passed (10 skipped)`, exit 0, zero leak lines; test count +33 (15 `kanban_deps`,
8 gate, 6 Migration110, 4 `tasks_move`), measured against HEAD with
`grep -c '^test "'`. Frontend on the merged tree: `vue-tsc --noEmit` clean,
12 spec files / 231 tests pass, `eslint` clean on every touched file.

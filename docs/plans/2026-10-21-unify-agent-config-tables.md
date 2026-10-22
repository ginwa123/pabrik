# Plan — one agent-config table set instead of twelve

- **Task**: `task_1792600946692_1` — "i think we can simplify this table ? what do you thought ?"
- **Worktree**: `~/.config/pabrik/.worktrees/i-think-we-can-simplify-this-table-what-do-you-tho-1792600945391`
- **Branch**: `worktree/i-think-we-can-simplify-this-table-what-do-you-tho-1792600945391` (base `main`)
- **Status**: DELIVERED — Migrations 116 + 117, see §8. main claimed 115 (`add_workspace_is_vm`) while this was in review, so the pair renumbered.

---

## 1. The question

> "I think we can simplify this table? What do you think?"

The agent configuration for a workspace item lived in **twelve** tables: the
same four-table shape, copied three times — once for `item_type='agent'`,
once for `'kanban'`, once for `'routine'`.

```
agents               + agent_knowledge            + agent_tools            + agent_system_prompt
agent_kanbans        + agent_kanban_knowledges    + agent_kanban_tools     + agent_kanban_system_prompt
agent_routines       + agent_routine_knowledges   + agent_routine_tools    + agent_routine_system_prompt
```

**The answer is yes — and this branch does it.** Twelve tables become four.
`item_type` on the parent row is what tells the three families apart, which
is the only thing that actually differs between them.

---

## 2. The evidence

### 2.1 The three families are the same shape

The DDL of the twelve tables is the same four-table shape three times over.
The only differences are the table names, the owner column name
(`agent_id` / `kanban_id` / `routine_id`) and one cosmetic default
(`agent_knowledge.file_path` has no `DEFAULT ''`; the kanban and routine
copies do).

### 2.2 The code was the same code, three times

| Layer | Agent | Kanban | Routine | Lines each |
|---|---|---|---|---|
| Model | `src/models/agent.db.zig` | `src/models/agent_kanban.db.zig` | `src/models/agent_routine.db.zig` | 488 / 459 / 459 |
| HTTP handlers | 13 files | 13 files | 13 files | 198–570 each |
| Prompt builders | 2 files | 2 files | 2 files | ~400 each |

`diff` of the kanban model against the routine model, with the family name
normalised, is **54 lines** — all of them comments and the id prefixes
(`akn_` / `arn_`). The handler twins are the same story: the diff between
`agent_kanban_knowledge_create.zig` and `agent_routine_knowledge_create.zig`
is the name of the thing.

### 2.3 Two of the three families are nearly empty

Live database (`~/.config/pabrik/agent.db`, 4.7 GB):

| Table | Rows |
|---|---|
| `agents` | 4 659 |
| `agent_tools` | 153 223 |
| `agent_knowledge` | 1 |
| `agent_system_prompt` | 1 |
| `agent_kanbans` | 20 |
| `agent_kanban_tools` | 289 |
| `agent_kanban_knowledges` | 0 |
| `agent_kanban_system_prompt` | 1 |
| `agent_routines` | 2 |
| `agent_routine_tools` | 39 |
| `agent_routine_knowledges` | 0 |
| `agent_routine_system_prompt` | 0 |

Workspace items by type: agent 4 658, kanban 19, routine 1, design 3, folder 8.

So the twelve tables carry **two** live shapes: the agent family (which
carries all the weight) and two almost-empty copies of it. The 153 k tool
rows are the real cost — and they are the reason a shared table set is
worth having: one `uq_agent_config_tools_config_tool` index instead of
three, one `config_id` column instead of three spellings.

### 2.4 The three families never collide

`agents.id`, `agent_kanbans.id` and `agent_routines.id` are all workspace
item ids, so they are globally unique. Verified on the live database:

```sql
SELECT 'a-k', COUNT(*) FROM agents a JOIN agent_kanbans k ON a.id = k.id
UNION ALL SELECT 'a-r', COUNT(*) FROM agents a JOIN agent_routines r ON a.id = r.id
UNION ALL SELECT 'k-r', COUNT(*) FROM agent_kanbans k JOIN agent_routines r ON k.id = r.id;
-- a-k: 0   a-r: 0   k-r: 0
```

The same holds for `workspace_item_id`. That is what makes one table safe:
the primary key is still unique, so no row can be ambiguous.

Two rows in `agents` have `id <> workspace_item_id` (both point a
`workspace_item_id` at a *workspace* id — pre-existing broken rows). The
migration copies both columns verbatim, so nothing changes for them.

---

## 3. The target schema

Four tables. The parent carries `item_type`; the children point at the
parent with `config_id`.

```sql
CREATE TABLE IF NOT EXISTS agent_configs (
    id                TEXT PRIMARY KEY,
    workspace_item_id TEXT NOT NULL UNIQUE,
    item_type         TEXT NOT NULL,          -- 'agent' | 'kanban' | 'routine'
    description       TEXT NOT NULL DEFAULT '',
    created_at        DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at        DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_agent_configs_workspace_item_id ON agent_configs(workspace_item_id);
CREATE INDEX IF NOT EXISTS idx_agent_configs_item_type        ON agent_configs(item_type);

CREATE TABLE IF NOT EXISTS agent_config_knowledge (
    id         TEXT PRIMARY KEY,
    config_id  TEXT NOT NULL,
    file_path  TEXT NOT NULL DEFAULT '',
    label      TEXT NOT NULL DEFAULT '',
    content    TEXT NOT NULL DEFAULT '',
    position   INTEGER NOT NULL DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (config_id) REFERENCES agent_configs(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_agent_config_knowledge_config_id      ON agent_config_knowledge(config_id);
CREATE INDEX IF NOT EXISTS idx_agent_config_knowledge_config_position ON agent_config_knowledge(config_id, position DESC);

CREATE TABLE IF NOT EXISTS agent_config_tools (
    id         TEXT PRIMARY KEY,
    config_id  TEXT NOT NULL,
    tool_name  TEXT NOT NULL,
    enabled    INTEGER NOT NULL DEFAULT 1,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (config_id) REFERENCES agent_configs(id) ON DELETE CASCADE
);
CREATE INDEX       IF NOT EXISTS idx_agent_config_tools_config_id ON agent_config_tools(config_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_config_tools_config_tool ON agent_config_tools(config_id, tool_name);

CREATE TABLE IF NOT EXISTS agent_config_system_prompt (
    id         TEXT PRIMARY KEY,
    config_id  TEXT NOT NULL,
    title      TEXT NOT NULL DEFAULT '',
    content    TEXT NOT NULL DEFAULT '',
    position   INTEGER NOT NULL DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (config_id) REFERENCES agent_configs(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_agent_config_system_prompt_config_id      ON agent_config_system_prompt(config_id);
CREATE INDEX IF NOT EXISTS idx_agent_config_system_prompt_config_position ON agent_config_system_prompt(config_id, position DESC);
```

### 3.1 Why `item_type` is not optional

`workflow.zig` tries the three families **in sequence** for every session:

```zig
if (try maybeOverrideAllowedToolsForAgent(...)) {
} else if (try maybeOverrideAllowedToolsForKanban(...)) {
} else if (try maybeOverrideAllowedToolsForRoutine(...)) {
```

Today the agent branch cannot fire for a kanban-bound session, because
there is no `agents` row with that id. With one shared table, an
unfiltered lookup would find the *kanban's* config row and the agent
branch would fire — the wrong allowlist, silently. So the model layer
filters on `item_type`:

```sql
SELECT 1 FROM agent_configs WHERE id = ? AND item_type = 'agent'
```

That is the one behavioural trap in this refactor, and it is why the
`item_type` column is not "just a label".

---

## 4. The migration (Migration 116)

`src/migrations/migration_116.zig` — `unify_agent_config_tables`.

1. Create the four tables and their indexes (`IF NOT EXISTS`).
2. Backfill the three parents, one `INSERT OR IGNORE ... SELECT` each, with
   the family literal (`'agent'` / `'kanban'` / `'routine'`).
3. Backfill the three children of each kind, mapping the old owner column
   (`agent_id` / `kanban_id` / `routine_id`) onto `config_id`.
4. **Rename** the twelve old tables to `*_legacy_v116`.

### 4.1 Forward-only, and reversible — until 117

Migration 116 **renames** the old tables to `*_legacy_v116`; it does not
drop them. Between 116 and 117 a rollback is a rename back:

```sql
ALTER TABLE agent_configs_legacy_v116 RENAME TO agents;
-- …and the other eleven
```

**Migration 117** (`drop_legacy_agent_config_tables`) then drops the
twelve `*_legacy_v116` tables for good — the reviewer asked for the dead
tables to go, and they should not linger in every install's database.

The drop is **guarded**: a legacy table is only dropped once the unified
table that replaced it holds at least as many rows as the legacy copy
did. A partial backfill therefore leaves the legacy tables alone (and
logs why) instead of deleting the only copy of the data. The guard is
per table pair, and it is re-checked on every run, so the drop happens
on a later boot if the counts do not line up yet.

**What this costs:** the rename-back rollback window is now the length
of one boot (116 and 117 run back to back). After that, rolling back to
the previous binary means restoring the database from a backup — the
previous binary's migrations 78/80/81/87 would re-create the old tables
*empty*. If a real rollback window is wanted, hold 117 for a later
release.

### 4.2 Idempotent, because the runner has no transaction

`MigrationManager.runMigrations` calls `migration.up(db, allocator)` with
no transaction around it. A crash mid-migration leaves the version
un-recorded, and the migration runs again on the next boot. Every step is
therefore guarded:

- `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`
- each backfill is `INSERT OR IGNORE`
- each backfill only runs when its source table exists (a fresh install
  has none of the old tables — the copy is then a no-op, not an error)
- each rename only runs when the source exists *and* the legacy name does
  not

### 4.3 Measured on the real data

The migration was run against a **copy of the live 4.7 GB database**:

```
real    0m0.463s
```

| | before | after |
|---|---|---|
| `agent_configs` | — | 4 681 (4 659 agent + 20 kanban + 2 routine) |
| `agent_config_knowledge` | — | 1 |
| `agent_config_tools` | — | 153 551 |
| `agent_config_system_prompt` | — | 2 |
| orphan tool rows | — | 0 |

---

## 5. The wire contract does not change

**Not one byte of the HTTP responses changes.** The desktop app reads
`agent_id` / `kanban_id` / `routine_id` off the knowledge, system-prompt
and tool rows, and it keeps reading exactly those.

The model layer keeps its three per-family row types, so the JSON is
unchanged. The unified column is aliased back to the legacy name in the
`SELECT`:

```sql
-- src/models/agent.db.zig
SELECT id, config_id AS agent_id, file_path, label, content, position, ...
FROM agent_config_knowledge WHERE config_id = ?
```

The alias is what keeps the wire stable: the column is called `config_id`
in the table and `agent_id` on the wire. The row readers are positional
(`r.values[1]`), so nothing else had to move.

**Why not rename the field to `config_id` everywhere?** Because an old
installed webapp on Windows (`%LOCALAPPDATA%\pabrik\html`) talks to a
newer server. `KanbanKnowledgePanel.vue` maps `kanban_id → agent_id`; if
the server stopped sending `kanban_id`, that map would silently produce
`agent_id: undefined` and the knowledge dialog would open with the wrong
id. A refactor is not the place to break a deployed client.

---

## 6. Blast radius

### 6.1 Production code that had to change

| File | Change |
|---|---|
| `src/models/agent.db.zig` | SQL retargeted at the unified tables |
| `src/models/agent_kanban.db.zig` | same |
| `src/models/agent_routine.db.zig` | same |
| `src/agentic_loop/workflow.zig` | two raw-SQL lookups (`agent_kanbans` / `agent_routines` → `agent_configs`) |
| `src/agentic_loop/tools_equipped.zig` | the kanban tool seeding INSERTs |
| `src/http_handlers/workspace_items_create_kanban.zig` | the config-row seed |
| `src/http_handlers/workspace_items_create_routine.zig` | the config-row seed |

### 6.2 Test code

48 test setups created the old tables and inserted into them. They now
create the unified set (via `Migration116`) and insert into it. The
`Migration076` / `Migration080` / `Migration081` / `Migration087` calls in
those harnesses are replaced by `Migration116`; the `Migration079` call
(`agent_knowledge.content`) is dropped, because the unified table has the
column from the start.

### 6.3 What did NOT change

- The HTTP routes, request bodies, response bodies and status codes.
- `src/migrations/migration_78/79/80/81/87/99.zig` — applied migrations are
  never edited. They still create the old tables, which is exactly what
  makes the backfill work on an install that predates this branch.
- The frontend. Zero TypeScript changed.

---

## 7. Rollback

| Situation | What to do |
|---|---|
| A migration failed half-way | Fix the cause and restart — both migrations are idempotent and re-run cleanly. |
| The release is bad, before 117 has run | Rename the `*_legacy_v116` tables back and ship the previous binary. Rows written to the new set after the migration are lost, so this is a same-session rollback. |
| The release is bad, after 117 has run | Restore `agent.db` from a backup. The legacy copy is gone, and the previous binary's migrations would re-create the old tables empty. |
| The guard fired (the counts did not line up) | Nothing was dropped. The legacy tables are still there, and the drop happens on a later boot once the backfill is complete. |

---

## 8. What shipped in this branch

- `src/migrations/migration_116.zig` — the unification migration, with six tests.
- `src/migrations/migration_117.zig` — drops the twelve `*_legacy_v116` tables (guarded), with five tests.
- `src/migrations/migration.zig` — registers both.
- The three model files retargeted at the unified tables.
- The four production raw-SQL sites updated.
- The 48 test setups updated.

### 8.1 The follow-up this enables (not in this branch)

With the tables unified, the *code* duplication can go too — and that is
now a mechanical, low-risk follow-up:

- **One model file** instead of three. The blocker was the row-type field
  name (`agent_id` / `kanban_id` / `routine_id`); a single model can keep
  the three legacy row types as thin views over one neutral row, or the
  wire names can be unified in a later, deliberate wire change.
- **One handler set** instead of three (13 files instead of 39). The three
  families' handlers differ only in the name of the thing they configure,
  so they can become one implementation with a `kind` parameter.
- **`workflow.zig`'s three `maybeOverrideAllowedToolsFor*`** functions
  collapse into one.
- The four raw-SQL sites that live outside the model layer (the two
  `workspace_items_create_*` seeds and `tools_equipped.zig`) move into the
  model layer, which is where the repo's own convention says SQL belongs
  ("HTTP handlers and the agentic loop call it and never write SQL
  themselves").

That is roughly 12 000 lines of near-duplicate code that this change
makes collapsible — but it is a separate change, and it should be reviewed
on its own.

---

## 9. Open questions for the reviewer

1. **Drop the `*_legacy_v116` tables?** DONE — Migration 117 drops them
   (guarded by the row counts). The cost is the rename-back rollback
   window; see §4.1 and §7.
2. **One model file, or three thin views over one?** The follow-up in §8.1
   has to pick. The three-view option keeps the wire names; the
   single-model option needs a wire change.
3. **Should `item_type` be a real enum?** It is a free-text `TEXT` column
   with a `CHECK` nowhere. A `CHECK (item_type IN ('agent','kanban','routine'))`
   would be cheap insurance, but SQLite cannot add a CHECK to an existing
   table without a rebuild — so it would have to be a migration 118 that
   rebuilds `agent_configs`.

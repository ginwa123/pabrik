# Routines Parity — State

Status: IN_PROGRESS (run #3, T02 done, 2026-11-04)
Repo: pabrik (github.com/ginwa123/pabrik), main @ cda5c60ce
Vue app: `src/apps/desktop/` (Vue 3 + TS, Pinia, Vitest)
Android app: `src/apps/android_mobile/` (Kotlin, Compose Material 3, Navigation-Compose, Room, no DI framework — manual construction in MainActivity/PabrikNavGraph, cookie auth via AuthTransport, JUnit4 + Robolectric + Compose UI test, androidTest + functional harness)

## Stack detected (Android)

- Kotlin 2.0.21, AGP 8.7.3, compileSdk/targetSdk 35, minSdk 26, Java 17
- Compose BOM 2024.12.01, Material3, navigation-compose 2.8.5, lifecycle 2.8.7
- Room 2.6.1 (KSP) — PabrikCacheDatabase: AuthMe/Chat/Projects/Recents caches, Keystore-sealed names
- Networking: hand-rolled AuthTransport (HttpsAuthTransport), org.json parsing, no Retrofit/OkHttp, no WorkManager, no Hilt/Koin
- Tests: `app/src/test` (JUnit4, Robolectric, kotlinx-coroutines-test, Compose ui-test-junit4), `app/src/androidTest` (Espresso, functional harness with `-PpabrikBaseUrl=http://10.0.2.2:<port>`)
- testTags: `Modifier.testTag(...)` convention (e.g. `project_row_<id>`, `create_task_*`)
- No Maestro files found in repo; E2E is instrumented functional tests + planned Maestro suite

## Vue Routines feature (source of truth)

Files:
- `src/apps/desktop/src/api/agents.ts` — WorkspaceRoutine, createRoutineItem, getRoutineItem, updateRoutineItem
- `src/apps/desktop/src/api/taskRuns.ts` — runWorkspaceRoutine
- `src/apps/desktop/src/api/agentRoutines.ts` — agent_routine mirror (knowledge, system prompts, tools)
- `src/apps/desktop/src/api/workspaces.ts` — deleteWorkspaceItem
- `src/apps/desktop/src/components/views/RoutineView.vue` — config surface (Routine tab + Agent tab)
- `src/apps/desktop/src/components/dialogs/AddRoutineItemDialog.vue` — create dialog
- `src/apps/desktop/src/helpers/routinePresets.ts` — presets + cron field names
- `src/apps/desktop/src/components/appLayout/AppRoutineBranch.vue` — mounts RoutineView for item_type='routine'
- `src/apps/desktop/src/stores/workspaces/agentRuns.ts` — runRoutineItem wrapper
- Tests: `__tests__/RoutineView.spec.ts`, `components/views/RoutineView.spec.ts`, `components/dialogs/AddRoutineItemDialog.spec.ts`

Data model (WorkspaceRoutine):
```
id, workspace_item_id, description, instruction, schedule (5-field cron, '' = manual-only),
selected_profile_model ('' = active-profile cascade), enabled (bool),
last_run_at, next_run_at ('' when manual-only/disabled), last_status (''|running|success|failed),
last_error, created_at, updated_at
```

Flows:
- Create: AddRoutineItemDialog (name required, folder/cwd required, instruction, schedule + presets) → POST /api/workspaces/:ws/items/routine {name, path, description:'', instruction, schedule, enabled:true} → {item, routine}
- View/edit: RoutineView loads GET /api/workspaces/:ws/items/:item/routine on mount/itemId change; edits description/instruction/schedule/enabled; Save → PATCH same path; schedule validated client-side (exactly 5 fields, chars [0-9*,\-/]) and server-side (400); server recomputes next_run_at
- Schedule presets: Manual only (''), Every hour (0 * * * *), Daily 09:00 (0 9 * * *), Weekdays 09:00 (0 9 * * 1-5); cron evaluated in UTC
- Run now: POST /api/workspaces/:ws/items/:item/routines/:routineId/run → {session_id} (session_id == routine id; every fire appends to same session chat); disabled when !enabled; while last_status=='running', polls GET routine + GET /api/workers?session_id= every 5s; running sessions list opens chat
- Agent model picker: GET workspace config profiles → PATCH routine {selected_profile_model} immediately on pick (optimistic, revert on error)
- Agent tab: GET /api/workspaces/:ws/items/:item/agent_routine (404 = unconfigured, silent) → knowledge (POST/PATCH/DELETE /api/agent-routines/:id/knowledge, reorder), system prompts (POST/PATCH/DELETE /api/agent-routines/:id/system_prompt, reorder), tools (GET/POST/DELETE /api/agent-routines/:id/tools), local memories (WorkspaceItemMemoriesView, needs item.path)
- Delete: generic workspace item delete DELETE /api/workspaces/:ws/items/:item (optimistic remove + rollback on error in itemCrud store); no routine-specific delete UI in RoutineView
- States: loading ("Loading routine…"), load error (routine-error, no retry button), save/run errors inline, last_error banner, status pill (Never run/Running/Success/Failed), status line (last ran/next UTC or "manual only — no next fire"), empty agent-model list ("No agents configured"), no-path memories empty state. No offline queue, no history list (only last_run_at/last_status/last_error), no pull-to-refresh.

## Android Routines today

- `ProjectTypes.ROUTINE = "routine"` exists; glyph `Icons.Filled.Autorenew` in ProjectRows.kt
- Routine rows render in drawer (ProjectsApi.parseItems keeps unknown types), but:
  - `createTaskStartDecision(ROUTINE) = NotAllowed` (no task creation — correct, routines have no task list)
  - `projectsThatTakeAChat` filters ROUTINE out of New Chat sheet (correct)
  - Tapping a routine row expands it like a project and "See all chats" navigates to ProjectChatsScreen (tasks list) — wrong surface; Vue routes routine items to RoutineView instead
  - No RoutineApi/RoutineClient/RoutineViewModel/RoutineScreen, no create dialog, no cron validation, no run, no agent tab, no delete
  - No routine cache entity, no offline queue, no WorkManager, no sync triggers beyond existing ProjectsCache (projects + chats only)

## Parity table

| Feature | Vue | Android | Gap | Effort |
|---|---|---|---|---|
| List routine items in drawer | Yes (Sidebar, glyph) | Yes (glyph only) | Tap opens wrong screen (project chats) | S |
| Create routine (name, cwd, instruction, schedule) | AddRoutineItemDialog | No | Full dialog + folder picker + POST | M |
| View/edit description + instruction | RoutineView | No | Screen + GET/PATCH | M |
| Schedule cron edit + presets + validation | Yes (5-field, UTC) | No | Cron validator + presets + PATCH | M |
| Enabled toggle | Yes | No | Switch + PATCH | S |
| Run now (manual fire) | Yes (disabled when !enabled) | No | POST run + status poll | M |
| Status pill + last/next run + last_error | Yes | No | Display + poll | S |
| Running sessions list + open chat | Yes (GET /workers) | No | Workers fetch + nav | M |
| Agent model picker | Yes (immediate PATCH) | No | Config profiles + PATCH | M |
| Agent tab: knowledge CRUD + reorder | Yes | No | 5 endpoints + UI | L |
| Agent tab: system prompts CRUD + reorder | Yes | No | 5 endpoints + UI | L |
| Agent tab: tools toggle | Yes | No | 3 endpoints + UI | M |
| Agent tab: local memories | Yes (needs path) | No | Memories API + UI | M |
| Delete routine item | Generic item delete | No | DELETE + confirm + rollback | S |
| Loading / error / empty states | Partial (no retry) | N/A | Match + add retry | S |
| Offline queue + replay, idempotent writes | No (Vue has none) | No | New: Room outbox + replay | L |
| Sync on start/foreground/pull-refresh/reconnect + WorkManager | No | No | New: triggers + worker | L |
| Conflict policy LWW by updatedAt | N/A (server recomputes) | No | Document + implement on merge | M |
| Unit tests (VM, mappers, cron, sync) | Vitest (599 lines) | No routine tests | Port behavior tests | M |
| UI tests (Compose) | — | No | Robolectric Compose tests | M |
| Maestro E2E create→edit→run→delete, schedule variants, validation, offline→reconnect, process death | — | No | New suite + seed/reset + scripts/e2e.sh | L |
| Cross-platform sync E2E (Playwright + Maestro) | — | No | Separate suite | L |

## API contract mismatches (Android vs Vue/backend)

Android currently implements NONE of the routine endpoints, so every row below is "missing on Android" rather than a field mismatch. No invented endpoints needed — all exist in Vue:

1. POST /api/workspaces/:ws/items/routine — body {name, path, description, instruction, schedule, enabled} → {item, routine}. Android: missing.
2. GET /api/workspaces/:ws/items/:item/routine → {routine}. Android: missing.
3. PATCH /api/workspaces/:ws/items/:item/routine — partial {description, instruction, schedule, selected_profile_model, enabled} → {routine}; server recomputes next_run_at. Android: missing.
4. POST /api/workspaces/:ws/items/:item/routines/:routineId/run → {session_id} (session_id == routine id). Note plural `routines` in path vs singular `routine` elsewhere — must copy verbatim. Android: missing.
5. DELETE /api/workspaces/:ws/items/:item → {success}. Android: missing (no item delete at all).
6. GET /api/workspaces/:ws/items/:item/agent_routine → {agent_routine, knowledges, tools, system_prompts} | 404 silent. Android: missing.
7. PATCH /api/workspaces/:ws/items/:item/agent_routine {description}. Android: missing.
8. POST/PATCH/DELETE /api/agent-routines/:routineId/knowledge[/:knowledgeId], PATCH .../knowledge/reorder {ordered_ids}. Knowledge XOR: file_path XOR content, exactly one non-empty (backend 400 otherwise). Android: missing.
9. POST/PATCH/DELETE /api/agent-routines/:routineId/system_prompt[/:promptId], PATCH .../system_prompt/reorder {ordered_ids}. Android: missing.
10. GET/POST/DELETE /api/agent-routines/:routineId/tools[/:toolName] — POST validates tool against registry (400 unknown, 409 duplicate). Android: missing.
11. GET /api/workers?session_id= (running sessions for routine) and GET workspace config profiles (agent model picker). Android: WorkerApi exists for /api/workers (no session filter param yet — check), config profiles: missing.
12. Field notes: `enabled` is JSON boolean on routine (not 0/1 like is_default); timestamps are ISO strings (last_run_at/next_run_at/created_at/updated_at, UTC, '' = none); schedule '' = manual-only; last_status '' = never run; IDs are strings; no soft-delete flag on routine (delete is hard via item delete); cron is 5-field POSIX, UTC, server re-validates.

## Task checklist (one task = one PR = one run)

- [x] T01 RoutineApi + models + parsers (create/get/update/run/delete paths, WorkspaceRoutine, cron validator, presets) + unit tests — DONE run #2 (RoutineApi.kt + RoutineApiTest.kt, 21 tests)
- [x] T02 RoutineClient (cookie transport, status mapping) + unit tests — DONE run #3 (RoutineClient.kt + RoutineClientTest.kt, 12 tests)
- [ ] T03 Routine detail screen (Routine tab: load, edit description/instruction/schedule/enabled, save, status pill/line, last_error, loading/error+retry) + ViewModel + unit/UI tests
- [ ] T04 Run now + status polling + running sessions (workers) + open chat nav + unit/UI tests
- [ ] T05 Agent model picker (workspace config profiles, immediate PATCH, revert on error) + tests
- [ ] T06 Create routine dialog (name/cwd/instruction/schedule/presets/validation) + folder picker seam + tests
- [ ] T07 Drawer routing: routine tap → routine detail (not project chats); hide task creation for routines (already done) + tests
- [ ] T08 Delete routine item (confirm, optimistic remove, rollback) + tests
- [ ] T09 Agent tab: knowledge CRUD + reorder + tests
- [ ] T10 Agent tab: system prompts CRUD + reorder + tests
- [ ] T11 Agent tab: tools toggle + tests
- [ ] T12 Agent tab: local memories (path-gated) + tests
- [ ] T13 Routine cache (Room entity + DAO, paint-from-cache then revalidate) + tests
- [ ] T14 Offline outbox queue + replay + idempotent writes + LWW-by-updatedAt merge + tests
- [ ] T15 Sync triggers (app start, foreground, pull-to-refresh, reconnect) + WorkManager background sync + tests
- [ ] T16 Maestro E2E suite (create→edit→run→delete, schedule variants, validation, offline→reconnect, process death) + seed/reset + scripts/e2e.sh
- [ ] T17 Cross-platform sync E2E (Playwright Vue + Maestro Android, test backend/seeded account, env creds) + docs/routines-sync.md + COMPLETE

## Decisions

- Repo is pabrik (not ginwaaitoolbox clone); all work in /home/ginwa/pabrik on branch routines/*, PRs labeled routines-auto.
- Vue has no run-history list and no offline queue — parity means matching Vue's last_status/last_run_at/last_error surface; offline queue is additive (T14) per routine brief, not a Vue gap.
- Delete reuses generic DELETE item endpoint (Vue does the same); no routine-specific delete endpoint exists.
- Run path uses plural `routines` segment — copy verbatim, do not "fix" to singular.
- Folder picker on Android: reuse existing file/folder browsing seam if present, else text field with path validation (decide in T06, record here).
- Conflict policy: last-write-wins by updatedAt (per brief); server recomputes next_run_at on schedule/enabled change, so client never computes next fire.
- Local Gradle runs require JDK 17 (system JDK 27 breaks Kotlin 2.0.21); CI uses its own JDK. Recorded after T01 build failure.
- AuthTransport has no DELETE verb (only get/post/put/patch, patch/put default-throw). Routine delete (T08) needs a `delete` default-throw member on AuthTransport + HttpsAuthTransport override, mirroring the patch precedent — decide in T08, do not invent a POST alias.

## Last test results

- Run #1 (audit): no code changed; no tests run. Android unit tests not executed (audit only).
- Run #3 (T02): `JAVA_HOME=<gradle-jdk-17> ./gradlew :app:testDebugUnitTest` — BUILD SUCCESSFUL; 1271 tests, 0 skipped, 0 failures, 0 errors, incl. new RoutineClientTest (12 tests).
- Run #2 (T01): `JAVA_HOME=<gradle-jdk-17> ./gradlew :app:testDebugUnitTest` — BUILD SUCCESSFUL; 1259 tests, 0 skipped, 0 failures, 0 errors (97 classes), incl. new RoutineApiTest (21 tests). NOTE: system JDK is 27 (Kotlin 2.0.21 crashes: `IllegalArgumentException: 27.0.1.0.3`); must run Gradle with JDK 17 (`/home/ginwa/.gradle/jdks/jdk-17.0.20.1+1`).

## Blockers

- None yet. Maestro availability on CI host unknown — verify in T16; if unavailable, instrumented functional harness is the fallback (record in T16).
- Folder picker seam on Android unknown — verify in T06.

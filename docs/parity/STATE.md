# Full Parity — State

Status: IN_PROGRESS (run #1 audit, 2026-11-06)
Repo: pabrik (github.com/ginwa123/pabrik), main @ a1bb70364
Vue app: `src/apps/desktop/` (Vue 3 + TS, Pinia, Vitest, Playwright E2E)
Android app: `src/apps/android_mobile/` (Kotlin, Compose Material 3, Navigation-Compose, Room, no DI — manual construction in MainActivity/PabrikNavGraph, cookie auth via AuthTransport, JUnit4 + Robolectric + Compose UI test, androidTest functional harness)

## Stack detected (Android)

- Kotlin 2.0.21, AGP 8.7.3, compileSdk/targetSdk 35, minSdk 26, Java 17
- Compose BOM 2024.12.01, Material3, navigation-compose 2.8.5, lifecycle 2.8.7
- Room 2.6.1 (KSP) — PabrikCacheDatabase: AuthMe/Chat/Projects/Recents caches, Keystore-sealed names
- Networking: hand-rolled AuthTransport (HttpsAuthTransport), org.json parsing, no Retrofit/OkHttp, no WorkManager, no Hilt/Koin
- Tests: `app/src/test` (JUnit4, Robolectric, kotlinx-coroutines-test, Compose ui-test-junit4), `app/src/androidTest` (Espresso, functional harness with `-PpabrikBaseUrl=http://10.0.2.2:<port>`)
- testTags: `Modifier.testTag(...)` convention
- No Maestro files found; E2E is instrumented functional tests + planned Maestro suite
- JDK 17 required for Gradle (system JDK 27 breaks Kotlin 2.0.21)

## Stack detected (Vue)

- Vue 3 + TypeScript, Pinia stores, Vue Router (path-based), Vite
- Tests: Vitest (unit), Playwright (E2E)
- API: hand-rolled fetch client (`src/api/client.ts`), SSE via EventSource
- Styling: CSS variables, dark/light theme

## Feature matrix

Legend: Status = Missing / Partial / Complete / Android-only. Effort = S/M/L/XL.

| # | Feature | Vue entry points | Android status | Gaps | Sync needs | Depends on | Effort | Priority |
|---|---|---|---|---|---|---|---|---|
| 1 | Auth & session (login, /me, cookie, server URL) | LoginView, authMe, SessionCookieStore | Complete | — | cookie auth | — | S | P0 |
| 2 | Navigation shell (drawer, workspaces, recents preview) | AppLayout, Sidebar, RecentsDrawer | Complete | — | — | auth | S | P0 |
| 3 | Workspaces & items (list, create, rename, delete, folders) | workspaces store, WorkspaceItem, itemCrud | Partial | create/rename/delete workspace, folder CRUD, item move | sync | auth | L | P1 |
| 4 | Chat (standalone + standard task) | ChatView, ChatAppBar, chat store | Complete | minor: image attach, tool cards parity | SSE stream | auth, workspaces | M | P1 |
| 5 | Kanban board (columns, cards, drag, filters) | KanbanView, KanbanBoard*, KanbanColumn | Partial | board UI, drag-drop, column editor, filters, sort | sync | workspaces, items | XL | P1 |
| 6 | Kanban tasks (create, edit, detail, status, assignee, tags, deps) | KanbanTaskDetail, TaskDetail* | Partial | task detail full, comments, attachments, PR link, worktree | sync | kanban board | L | P1 |
| 7 | Kanban settings (columns, profiles, tools) | KanbanSettingsView | Missing | full screen | sync | kanban | M | P2 |
| 8 | Design (canvas, elements, pages, layers, properties) | DesignView, DesignCanvas, Design* | Missing | entire feature | sync | workspaces, items | XL | P2 |
| 9 | Agent (view, chat, knowledge, prompts, tools, memories) | AgentView, AgentChatView, Agent* | Missing | entire feature | sync | workspaces, items, LLM config | XL | P2 |
| 10 | Routine | RoutineView, AddRoutineItemDialog | Partial | T03-T17 (see routines-parity/STATE.md) | sync | workspaces, items | L | P1 |
| 11 | Documents (view, edit, tree) | DocumentsView, DocumentsList, AppDocumentsBranch | Missing | entire feature | sync | workspaces, items | L | P2 |
| 12 | Settings — user (appearance, security, general) | SettingsView, AppearanceSection, AccountSecuritySection | Partial | appearance (theme), security (password change) | — | auth | M | P2 |
| 13 | Settings — workspace (overview, secrets, skills, memories, profiles, MCP, tools, skill evals, runtime, members, usage) | WorkspaceSettingsView | Missing | entire feature | sync | workspaces | XL | P2 |
| 14 | Git (changes, commits, file viewer, diff) | GitChanges, GitCommits, GitFileViewer | Missing | entire feature | — | workspaces, items | L | P3 |
| 15 | Pull requests (list, create, status) | KanbanPrList, CreatePrDialog | Missing | entire feature | — | git, kanban | M | P3 |
| 16 | Worktrees (create, list, menu) | WorktreeMenu, CreateWorktreeDialog | Missing | entire feature | — | git | M | P3 |
| 17 | Memory (workspace item memories, local memories) | WorkspaceItemMemoriesView, LocalMemoryDetailView, MemoriesSettings | Missing | entire feature | sync | workspaces, items | M | P3 |
| 18 | Secrets (CRUD, reveal, rotate, describe) | SecretsSection, RotateSecretDialog | Missing | entire feature | sync | workspaces | M | P2 |
| 19 | Members & invitations | MembersSection, invitations store | Missing | entire feature | sync | workspaces | M | P3 |
| 20 | Skills (list, add, edit, remove, evals) | SkillsSettings, SkillDetail, AddSkill/EditSkill/RemoveSkill | Missing | entire feature | sync | workspaces | L | P3 |
| 21 | MCP servers (CRUD, headers) | McpServersSection, McpServerModal | Missing | entire feature | sync | workspaces, settings | M | P3 |
| 22 | LLM config / profiles (CRUD, model picker) | PabrikConfigEditor, LlmConfigModal | Missing | entire feature | sync | workspaces, settings | L | P2 |
| 23 | Tools (registry, toggle per agent) | ToolsSection, agentToolToggle | Missing | entire feature | sync | workspaces, settings | M | P3 |
| 24 | Notifications (in-app toast container) | NotificationContainer, notifications store | Missing | entire feature | — | — | S | P3 |
| 25 | Theme / appearance (dark/light, swatches) | AppearanceSection, ThemeSwatch, theme store | Partial | theme toggle exists; swatches, dark mode polish | — | — | S | P3 |
| 26 | Recents (list, pagination, search) | Chats, ChatsList, recents store | Complete | — | sync | workspaces | S | P1 |
| 27 | File picker / folder explorer | FilePicker*, FolderExplorer | Missing | entire feature | — | workspaces | L | P2 |
| 28 | Terminal / background commands | TerminalFooter, BackgroundCommandsPopup | Missing | entire feature | — | workspaces | M | P3 |
| 29 | Network inspector | NetworkInspectorScreen, NetworkLogStore | Complete | — | — | — | S | P3 |
| 30 | SSE / real-time (chat stream, kanban SSE, design SSE, documents SSE) | sseClient, sseBus, *Sse stores | Partial | chat SSE done; kanban/design/documents SSE missing | — | features | L | P2 |
| 31 | Sync engine (offline queue, outbox, LWW, triggers, WorkManager) | (Vue has none) | Missing | entire engine | core | all | XL | P1 |
| 32 | E2E tests (Maestro + Playwright cross-platform) | Playwright specs | Missing | entire suite | — | all | XL | P3 |

## API contract mismatches

Android implements only: auth (/api/auth/login, /api/auth/me), chat (/api/llm/session, messages, stream), projects/items (partial), recents (/api/session), kanban (partial), workers (/api/workers), files (partial), routines (RoutineApi/Client only). Everything else is missing.

Key mismatches / notes:
1. Android has no DELETE verb on AuthTransport (only get/post/put/patch) — routine delete (T08) and item delete need a `delete` member. Recorded in routines-parity decisions.
2. Android has no WorkManager dependency — sync triggers (T15) need it added.
3. Android has no Retrofit/OkHttp — all API clients are hand-rolled org.json parsers; new features follow the same pattern.
4. Android has no DI framework — manual construction in MainActivity/PabrikNavGraph; new ViewModels wired manually.
5. Field naming: Android uses camelCase Kotlin; Vue uses snake_case JSON; mappers handle conversion (existing pattern in ProjectsApi/ChatApi).
6. Timestamps: ISO strings UTC; Android stores as strings (no conversion). Consistent with existing.
7. IDs: strings everywhere. Consistent.
8. Soft deletes: none on backend (hard delete via DELETE item). Consistent.
9. Cron: 5-field POSIX UTC, server recomputes next_run_at. Android validates client-side (RoutineApi). Consistent.
10. `enabled` is JSON boolean on routine (not 0/1). Consistent with existing boolean handling.

## Task checklist (one task = one PR = one run)

### Phase A — Shared foundation (do first)

- [ ] F01 Add WorkManager dependency + sync trigger scaffolding (app start, foreground, reconnect) — skeleton only, no feature logic
- [ ] F02 Offline outbox queue (Room entity + DAO + replay) — generic, reusable by all features
- [ ] F03 Sync engine core (LWW by updatedAt, idempotent writes, delete handling, UTC storage + local rendering) — generic
- [x] F04 Design system audit: ensure all Material3 components, theme tokens, dark mode parity with Vue CSS vars (DONE 2026-11-07: Android is dark-only (Kanagawa Dragon tokens in Color.kt/Theme.kt); Vue supports 10+ themes (dark+light) via theme/themes.ts + style.css. Gap: no light theme, no theme picker, no theme persistence. Recorded as decision; full theme parity deferred to a dedicated task.)
- [ ] F05 Navigation: add routes for settings, workspace settings, kanban settings, documents, agent, design, routine detail, git, memory, secrets, members, skills, MCP, LLM config, tools, notifications
- [ ] F06 Test infrastructure: Maestro setup, seed/reset script, scripts/e2e.sh, Playwright cross-platform suite skeleton

### Phase B — Features by dependency and user value

#### Workspaces & items
- [ ] F07 Workspace CRUD (create, rename, delete) + UI + tests
- [ ] F08 Folder CRUD + move items + UI + tests
- [ ] F09 Item CRUD generic (rename, delete, move) + optimistic rollback + tests

#### Kanban
- [ ] F10 Kanban board UI (columns, cards, drag-drop) + ViewModel + tests
- [ ] F11 Kanban task detail (full: fields, comments, attachments, PR link, worktree) + tests
- [ ] F12 Kanban settings screen (columns, profiles, tools) + tests
- [ ] F13 Kanban SSE (real-time updates) + tests

#### Chat enhancements
- [ ] F14 Chat image attach parity + tests
- [ ] F15 Chat tool cards parity (all tool types) + tests

#### Routine (see routines-parity/STATE.md T03-T17)
- [ ] F16 Routine T03: detail screen (Routine tab) + ViewModel + tests
- [ ] F17 Routine T04: run now + polling + running sessions + open chat
- [ ] F18 Routine T05: agent model picker
- [ ] F19 Routine T06: create dialog + folder picker
- [ ] F20 Routine T07: drawer routing
- [ ] F21 Routine T08: delete item
- [ ] F22 Routine T09: agent tab knowledge
- [ ] F23 Routine T10: agent tab system prompts
- [ ] F24 Routine T11: agent tab tools
- [ ] F25 Routine T12: agent tab local memories
- [ ] F26 Routine T13: routine cache (Room)
- [ ] F27 Routine T14: offline outbox + LWW merge
- [ ] F28 Routine T15: sync triggers + WorkManager
- [ ] F29 Routine T16: Maestro E2E
- [ ] F30 Routine T17: cross-platform sync E2E + docs/routines-sync.md + COMPLETE (routines)

#### Design
- [ ] F31 Design canvas + elements + pages + layers + properties + tests

#### Agent
- [ ] F32 Agent view + chat + tests
- [ ] F33 Agent knowledge CRUD + reorder + tests
- [ ] F34 Agent system prompts CRUD + reorder + tests
- [ ] F35 Agent tools toggle + tests
- [ ] F36 Agent local memories + tests

#### Documents
- [ ] F37 Documents view + tree + edit + tests

#### Settings
- [ ] F38 User settings: appearance (theme toggle, swatches) + tests
- [ ] F39 User settings: security (password change) + tests
- [ ] F40 Workspace settings: overview + secrets + tests
- [ ] F41 Workspace settings: skills + tests
- [ ] F42 Workspace settings: memories + tests
- [ ] F43 Workspace settings: profiles (LLM config) + tests
- [ ] F44 Workspace settings: MCP servers + tests
- [ ] F45 Workspace settings: tools + tests
- [ ] F46 Workspace settings: skill evals + tests
- [ ] F47 Workspace settings: runtime (retry backoff) + tests
- [ ] F48 Workspace settings: members + invitations + tests
- [ ] F49 Workspace settings: usage charts + tests

#### Git / PRs / Worktrees
- [ ] F50 Git changes view + tests
- [ ] F51 Git commits view + tests
- [ ] F52 Git file viewer + diff + tests
- [ ] F53 Pull requests (list, create, status) + tests
- [ ] F54 Worktrees (create, list, menu) + tests

#### Memory / Secrets / Skills / MCP / Tools / Notifications
- [ ] F55 Memory (workspace item memories, local memories) + tests
- [ ] F56 Secrets (CRUD, reveal, rotate, describe) + tests
- [ ] F57 Skills (list, add, edit, remove, evals) + tests
- [ ] F58 MCP servers (CRUD, headers) + tests
- [ ] F59 Tools (registry, toggle per agent) + tests
- [ ] F60 Notifications (in-app toast container) + tests

#### SSE / Real-time
- [ ] F61 Kanban SSE + tests
- [ ] F62 Design SSE + tests
- [ ] F63 Documents SSE + tests

#### Sync (per feature, after F01-F03)
- [ ] F64 Sync: workspaces & items
- [ ] F65 Sync: kanban
- [ ] F66 Sync: chat
- [ ] F67 Sync: design
- [ ] F68 Sync: agent
- [ ] F69 Sync: routine
- [ ] F70 Sync: documents
- [ ] F71 Sync: settings/secrets/skills/members

#### E2E
- [ ] F72 Maestro E2E suite (per feature main journey, validation, error, offline→reconnect, process death)
- [ ] F73 Cross-platform sync E2E (Playwright Vue + Maestro Android) + docs/sync.md

### Phase C — Finish
- [ ] F74 Re-audit Vue app for new features since run #1; add any new ones to matrix
- [ ] F75 docs/sync.md (sync design, conflict policy, how to run tests, known limitations per feature)
- [ ] F76 Set STATE.md status to COMPLETE; final PR

## Decisions

- F04: Android ships only the default dark theme (Kanagawa Dragon). Vue supports 10+ themes including light. Full theme parity (light mode + picker + persistence) is a large task; recorded as a gap. Android theme tokens in Color.kt match Vue's default dark swatch (#181616 bg, #1D1C19 card, #c5c9c5 fg, #8992a7 accent).
- Repo is pabrik; all work in /home/ginwa/pabrik on branch parity/*, PRs labeled parity-auto.
- Vue is source of truth for behavior, data model, UX. Android follows Android conventions (Material 3, back navigation).
- Conflict policy: last-write-wins by updatedAt (per brief); server recomputes derived fields.
- No Maestro files exist yet; E2E is instrumented functional tests + planned Maestro suite.
- Auth/session foundation task (F01-related auth) must be labeled needs-human and left open per MERGE RULES (auth changes). Actually auth is already complete; new auth changes need needs-human.
- Tasks that change auth, secrets, signing, payments, build/release settings → needs-human label, not auto-merged.
- CI workflow creation → needs-human label, not auto-merged.
- Test credentials from env vars only; never commit secrets.

## Last test results

- Run #1 (audit): no code changed; no tests run.

## Blockers

- None yet.
- Maestro availability on CI host unknown — verify in F06/F72.
- Folder picker seam on Android unknown — verify when needed (routine T06).
- AuthTransport has no DELETE verb — needed for item delete tasks; add `delete` member mirroring patch precedent.

## Files touched

- docs/parity/STATE.md (created)

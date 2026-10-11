// src/http_routes.zig
//
// Every HTTP route pabrik serves, in the ONE place they are registered.
//
// Why this is not inline in `main`: the table is ~490 lines of
// `authed.get("/api/...", handler)` calls, and burying it between the
// signal-handler setup and the event-bus subscription made `main`
// unreadable and turned every route review into a diff of unrelated
// startup code. It is split by domain below so a change to, say, the
// kanban task routes touches one function and nothing else.
//
// REGISTRATION ORDER IS LOAD-BEARING. `authed` is
// `gs.router.group("")`, and kabelweb's `Group.router` is a `*Router` —
// groups and the root router share ONE ordered route table that
// `matchRoute` walks top-down, returning on the first hit. So:
//
//   * a literal registered after a `:param` sibling is captured as that
//     param (`/knowledge/reorder` after `/knowledge/:knowledge_id`),
//   * and `matchPathWithParams` writes each `:param` into the shared
//     `req.params` map WITHOUT unwinding when a later literal segment
//     fails, so an early param route can leave a bogus id behind that
//     `authMiddleware` then rejects (the `workspace_id = "tasks"` rename
//     404 — see `http_handlers/task_update.zig`).
//
// `registerAll` therefore calls the per-domain functions in exactly the
// order the routes used to be registered inline. Do not reorder them; add
// a new route at the END of its domain function instead.
//
// `registerAllOn` takes the `*Router` rather than the whole server so the
// table can be built and MATCHED in a unit test: the tests at the bottom of
// this file build the real table and ask `matchRoute` which handler and
// params a request path resolves to. Registration order is only observable
// through that resolution, never through the spelling of this file.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;

/// The `gs.router.group("")` handle. Every `/api` route registers here so
/// it picks up `authMiddleware`.
const Group = gserverz.router.Group;
const testing = std.testing;

/// Register every route pabrik serves on `gs`. Call this exactly once, after
/// `GinwaServer.init` and before `listen()`.
pub fn registerAll(gs: *gserverz.GinwaServer) !void {
    return registerAllOn(&gs.router);
}

/// The route table itself. Takes the bare `*Router` so a test can build the
/// exact production table on a stack arena and run `matchRoute` against it —
/// `GinwaServer` would drag in a listening socket, an SseManager pipe and a
/// WsManager for a table that never listens.
pub fn registerAllOn(router: *gserverz.router.Router) !void {
    // Opt-in `--auth`: all `/api` routes registered via `authed` run
    // `authMiddleware` (401 when no valid `pabrik_session` cookie).
    // Auth endpoints themselves stay on `router` (unprotected) and
    // are registered BEFORE any `:param` routes to avoid matchRoute
    // shadowing (`/api/auth/login` is a literal that must precede
    // `/api/session/:session_id`-style params).
    var authed = router.group("");
    try authed.use(ai_mod.http_handlers.authMiddleware);

    // Order is load-bearing — see the file header. Each function below
    // registers one domain's routes, verbatim and in the order they were
    // registered when this table lived inline in `main`.
    try registerAuthRoutes(router);
    try registerSessionRoutes(&authed);
    try registerWorkerRoutes(&authed);
    try registerTerminalRoutes(&authed, router);
    try registerStreamRoutes(&authed, router);
    try registerSystemRoutes(&authed, router);
    try registerMemoryRoutes(&authed);
    try registerConfigRoutes(&authed);
    try registerGitRoutes(&authed);
    try registerFileRoutes(&authed);
    try registerWorkspaceRoutes(&authed);
    try registerAgentRoutes(&authed);
    try registerAgentKanbanRoutes(&authed);
    try registerAgentRoutineRoutes(&authed);
    try registerWorkspaceDocumentRoutes(&authed);
    try registerKanbanRoutes(&authed);
    try registerDesignRoutes(&authed);
    try registerTestRoutes(&authed);
}

fn registerAuthRoutes(router: *gserverz.router.Router) !void {
    try router.post("/api/auth/login", ai_mod.http_handlers.authLoginHandler);
    try router.post("/api/auth/logout", ai_mod.http_handlers.authLogoutHandler);
    try router.get("/api/auth/me", ai_mod.http_handlers.authMeHandler);
    // // try authed.get("/api/stream/:session_id/disconnect", http_handlers.sseDisconnectHandler, .{});
    // // try authed.post("/api/stream/:session_id/disconnect", http_handlers.sseDisconnectHandler, .{});
    // // try authed.get("/api/stream/:session_id", http_handlers.streamHandler, .{});
    // // try router.options("/api/session", http_handlers.corsPreflightHandler, .{});
}

fn registerSessionRoutes(authed: *Group) !void {
    try authed.post("/api/session", ai_mod.http_handlers.sessionCreateHandler);
    try authed.put("/api/session/:session_id", ai_mod.http_handlers.sessionUpdateHandler);
    // Mark-as-seen (yellow stale-dot fix): stamping
    // `sessions.last_human_touched_at_nano` when the user opens a chat.
    // POST differs in method from the sibling PUT/GET on the overlapping
    // prefix, and the literal `touched` tail differs from `messages` —
    // no shadowing risk.
    try authed.post("/api/session/:session_id/touched", ai_mod.http_handlers.sessionMarkTouchedHandler);
    try authed.get("/api/session", ai_mod.http_handlers.sessionListHandler);
    //
    // // try authed.get("/api/session/stream", http_handlers.sessionStreamHandler, ctxParent);
    try authed.get("/api/session/:session_id/messages", ai_mod.http_handlers.sessionMessagesHandler);
    // try authed.get("/api/session/exists/:session_id", http_handlers.sessionExistHandler, ctxParent);
    // try authed.get("/api/session/latest", http_handlers.sessionLatestHandler, ctxParent);
    // try authed.post("/api/session/:session_id/cancel", http_handlers.sessionCancelHandler, ctxParent);
    // try authed.post("/api/session/:session_id/compact", http_handlers.sessionCompactHandler, ctxParent);
    // try authed.get("/api/session/:session_id/queue/messages", http_handlers.sessionQueueGetHandler, ctxParent);
    // try authed.delete("/api/session/:session_id/queue/message", http_handlers.sessionQueueDeleteHandler, ctxParent);
    // try authed.get("/api/ping/:session_id", http_handlers.pingHandler, ctxParent);
    //
    // // Worker API
}

fn registerWorkerRoutes(authed: *Group) !void {
    try authed.get("/api/workers", ai_mod.http_handlers.workerListHandler);
    //
    // // LLM API aliases (desktop app uses /api/llm/*)
    try authed.post("/api/llm/session", ai_mod.http_handlers.sessionCreateHandler);
    try authed.put("/api/llm/session/:session_id", ai_mod.http_handlers.sessionUpdateHandler);
    // Migration 104 - session pin for PINNED section above RECENT.
    // Literal-first ordering: `reorder_pinned` before `:session_id/pin`
    // so the literal never resolves as a param (route-order rule).
    try authed.post("/api/llm/session/reorder_pinned", ai_mod.http_handlers.sessionReorderPinnedHandler);
    try authed.post("/api/llm/session/:session_id/pin", ai_mod.http_handlers.sessionPinHandler);
    // LLM-alias prefix of the mark-as-seen endpoint above (desktop app
    // uses /api/llm/*). Same no-shadowing argument as above.
    try authed.post("/api/llm/session/:session_id/touched", ai_mod.http_handlers.sessionMarkTouchedHandler);
    try authed.post("/api/llm/session/:session/stop", ai_mod.http_handlers.sessionStopHandler);
    // `ask_user` answer route. Route order: the literal `answer` tail differs
    // from every sibling tail (messages, queue_messages, stream, stop,
    // touched), so there is no `matchRoute` shadowing risk — and it is
    // registered after the `/messages` + `/queue_messages` siblings anyway,
    // per the "longer, more-specific paths after their prefix sibling" rule.
    try authed.post("/api/llm/session/:session_id/answer", ai_mod.http_handlers.askUserAnswerHandler);

    // try authed.post("/api/llm/session", ai_mod.http_handlers.sessionCreateHandler);

    try authed.get("/api/llm/session", ai_mod.http_handlers.sessionListHandler);
    // Session detail incl. `workspace_id` (workspace-scoped sessions).
    // `:session_id` matches exactly ONE path segment, so this route can
    // neither shadow nor be shadowed by the sibling `/messages`,
    // `/queue_messages`, `/background_processes`, `/stream` routes —
    // matchPathWithParams requires the path to be exhausted after the
    // pattern, regardless of registration order.
    try authed.get("/api/llm/session/:session_id", ai_mod.http_handlers.sessionGetHandler);
    try authed.get("/api/llm/session/:session_id/messages", ai_mod.http_handlers.sessionMessagesHandler);
    try authed.get("/api/llm/session/:session_id/queue_messages", ai_mod.http_handlers.queueMessagesGetHandler);
    // Session background-process endpoints (bg-completion): list + log
    // tail for `command background=true` rows. Registered next to
    // queue_messages. No shadowing risk: the `background_processes`
    // literal segment differs from every sibling (`messages`,
    // `queue_messages`, `stream`), and the longer `:pid/log` route is
    // registered AFTER the list route (route-order rule — longer,
    // more-specific paths after their prefix sibling).
    try authed.get("/api/llm/session/:session_id/background_processes", ai_mod.http_handlers.backgroundProcessesListHandler);
    try authed.get("/api/llm/session/:session_id/background_processes/:pid/log", ai_mod.http_handlers.backgroundProcessLogGetHandler);
}

fn registerTerminalRoutes(authed: *Group, router: *gserverz.router.Router) !void {
    // Right-sidebar terminal (PTY over REST + poll). Fresh
    // `/api/terminal/` prefix — no `:param` siblings exist under it,
    // so no matchRoute shadowing risk (router walks registration
    // order). Literal `sessions` is registered before the `:id`
    // routes (route-order rule).
    try authed.post("/api/terminal/sessions", ai_mod.http_handlers.terminalCreateHandler);
    try authed.post("/api/terminal/sessions/:id/input", ai_mod.http_handlers.terminalInputHandler);
    try authed.get("/api/terminal/sessions/:id/output", ai_mod.http_handlers.terminalOutputHandler);
    try authed.post("/api/terminal/sessions/:id/resize", ai_mod.http_handlers.terminalResizeHandler);
    try authed.delete("/api/terminal/sessions/:id", ai_mod.http_handlers.terminalDeleteHandler);
    // Duplex PTY socket — attaches to a live session id (?id=) for
    // binary output frames + JSON control frames. First (and only) WS
    // route: fresh `/api/terminal/` prefix, literal `ws` segment, so
    // no matchRoute shadowing risk. HTTP/1.1 only (browsers use h1).
    try router.ws("/api/terminal/ws", ai_mod.http_handlers.terminalWsHandler);
}

fn registerStreamRoutes(authed: *Group, router: *gserverz.router.Router) !void {
    // In-flight stream snapshot (task_1787673548905_0 stream-resume-on-
    // reselect) — serves `{ active, content }` from the in-memory
    // stream_snapshot registry so a re-mounted ChatView can resume a
    // mid-stream session. Registered AFTER the sibling /messages +
    // /queue_messages routes (route-order rule).
    try authed.get("/api/llm/session/:session_id/stream", ai_mod.http_handlers.streamGetHandler);
    // Live spawn-batch snapshot (task_1788505292766_1
    // spawn-subagent-refresh-persist) — serves `{ tool_call_id,
    // progress[] }` from the in-memory subagent_progress registry so a
    // refreshed ChatView can rehydrate running rows for placeholder
    // spawn cards. Fresh `/api/subagent/...` prefix: no sibling
    // `:param` routes exist under it, so no shadowing risk.
    try authed.get("/api/subagent/progress/:tool_call_id", ai_mod.http_handlers.subAgentProgressGetHandler);
    // Unified SSE endpoint — single EventSource for all event families
    // (workers, sessions, kanban_column, kanban_task, per-session llm +
    // queue_messages). Replaces the 5 dedicated routes that previously
    // registered one EventSource per family. See
    // src/http_handlers/unified_events_sse.zig.
    try router.sse("/api/events", ai_mod.http_handlers.unifiedEventsStreamHandler);
    // Test-only SSE emit (dev_sse_emit.zig) — gated by PABRIK_TEST_SSE_EMIT=1,
    // 404 when off. Functional UI tests use it to drive the chatview's
    // SSE streaming path without a real LLM.
    try authed.post("/api/dev/sse/emit_llm", ai_mod.http_handlers.devSseEmitLlmHandler);
}

fn registerSystemRoutes(authed: *Group, router: *gserverz.router.Router) !void {
    // try authed.post("/api/llm/session/:session_id/cancel", http_handlers.sessionCancelHandler, ctxParent);
    //
    // // Desktop app routes (system, health, workspaces)
    try router.get("/health", ai_mod.http_handlers.healthHandler);
    // Skills are NOT registered here. They are workspace-scoped, so their
    // routes live in registerWorkspaceRoutes next to the documents routes:
    // `/api/workspaces/:workspace_id/skills…`. A bare `/api/skills` has no
    // source for a workspace id, and the store refuses to run without one —
    // which is why keeping it registered answered 400 "workspace_id
    // required" instead of 404, i.e. it advertised an endpoint that cannot
    // work.

    // Skill Evals — the READ surface for the eval the agent runs on itself.
    // A SIBLING prefix under /api/skill-evals/, and it stays one: the skills
    // routes are workspace-scoped now (see `registerWorkspaceRoutes`), which
    // means there IS a `:skill_name` param route on the table. `matchRoute`
    // walks routes in registration order and returns on the FIRST hit, so a
    // literal nested under that prefix — `/api/workspaces/:workspace_id/skills/evals`,
    // say — would be captured as skill_name="evals" and the evals handler would
    // never run, with no error to debug. Both routes here are literals with
    // query parameters, so there is no ordering hazard to remember.
    // Plan: docs/plans/2026-09-27-skill-evals.md §4.10.
    try authed.get("/api/skill-evals/runs", ai_mod.http_handlers.skillEvalsRunsHandler);
    try authed.get("/api/skill-evals/summary", ai_mod.http_handlers.skillEvalsSummaryHandler);
    // The apply endpoint. `result_id` is a QUERY parameter, not a path segment,
    // so this stays a literal and there is still no `:param` under this prefix
    // to shadow a later route.
    try authed.post("/api/skill-evals/results/apply", ai_mod.http_handlers.skillEvalsApplyHandler);
}

fn registerMemoryRoutes(authed: *Group) !void {
    // Memories routes
    try authed.get("/api/memories", ai_mod.http_handlers.memoriesListHandler);
    try authed.get("/api/memories/:name", ai_mod.http_handlers.memoryDetailHandler);
    try authed.post("/api/memories", ai_mod.http_handlers.memoryCreateHandler);
    try authed.put("/api/memories/:name", ai_mod.http_handlers.memoryUpdateHandler);
    try authed.delete("/api/memories/:name", ai_mod.http_handlers.memoryDeleteHandler);

    // Local Memories routes — scoped to <cwd>/.pabrik/memories/. The
    // `cwd` is provided in the request body (POST/PUT) or query
    // string (GET/DELETE); handlers fall back to the pabrik server's
    // own CWD via `io.realPath` when no explicit cwd is provided.
    try authed.get("/api/local-memories", ai_mod.http_handlers.localMemoriesListHandler);
    try authed.get("/api/local-memories/:name", ai_mod.http_handlers.localMemoryDetailHandler);
    try authed.post("/api/local-memories", ai_mod.http_handlers.localMemoryCreateHandler);
    try authed.put("/api/local-memories/:name", ai_mod.http_handlers.localMemoryUpdateHandler);
    try authed.delete("/api/local-memories/:name", ai_mod.http_handlers.localMemoryDeleteHandler);
}

fn registerConfigRoutes(authed: *Group) !void {
    // Pabrik config routes (reads/writes config.json as pabrik.json mapping)
    try authed.get("/api/config/pabrik", ai_mod.http_handlers.pabrikConfigGetHandler);
    try authed.put("/api/config/pabrik", ai_mod.http_handlers.pabrikConfigPutHandler);
    try authed.delete("/api/config/pabrik/profiles/:name", ai_mod.http_handlers.pabrikConfigProfileDeleteHandler);

    // OS notification test endpoint — fires a real OS notification so
    // the user can verify their system can display them.
    try authed.post("/api/notify/test", ai_mod.http_handlers.notifyTestHandler);

    // Browser-mode (web launch) status — read-only: reports the
    // `web_launch_enabled` flag + live bound port/URL for the settings
    // General tab pill. Literal path, no `:param` siblings — no
    // matchRoute shadowing risk (router.zig walks registration order).
    // Plan 2026-09-10-web-launch-toggle.
    try authed.get("/api/web/status", ai_mod.http_handlers.webStatusHandler);

    // MCP server "Test" probe — fires a tools/list request against a
    // candidate config without persisting anything. Used by the
    // Add/Edit MCP server modal's "Test" button so the user can
    // verify command + args + env + cwd (or URL + headers) actually
    // work before clicking Save.
    try authed.post("/api/mcp/test", ai_mod.http_handlers.mcpTestHandler);

    // LLM profile "Test" probe — fires one minimal non-streaming chat
    // call against a candidate profile without persisting anything.
    // Used by the Add/Edit profile modal's "Test" button so the user
    // can verify model + base_url + api_key + url_style actually work
    // before clicking Save. Literal path with no `:param` siblings —
    // no matchRoute shadowing risk (router.zig walks registration order).
    try authed.post("/api/llm/test", ai_mod.http_handlers.llmTestHandler);

    // Frontend error log endpoints — POST /api/logs is DISABLED (noisy:
    // the desktop log client spammed it on every console.error/warn).
    // GET /api/logs stays as a read-only debug endpoint for `curl`.
    // See docs/plans/2026-07-17-frontend-error-logs-design.md.
    // try authed.post("/api/logs", ai_mod.http_handlers.frontendLogPostHandler);
    try authed.get("/api/logs", ai_mod.http_handlers.frontendLogGetHandler);
}

fn registerGitRoutes(authed: *Group) !void {
    try authed.get("/api/git/status", ai_mod.http_handlers.gitStatusHandler);
    try authed.get("/api/git/changes", ai_mod.http_handlers.gitChangesHandler);
    try authed.get("/api/git/blame", ai_mod.http_handlers.gitBlameHandler);
    // No per-file diff route. Reading a diff is POST /api/git/file/diffs,
    // whose folder mode covers a folder (or the whole repo) in one request
    // and a fixed number of git spawns; the old GET /api/git/file/diff cost
    // one spawn per call, so a panel with N changed files asked N times.
    try authed.post("/api/git/file/diffs", ai_mod.http_handlers.gitFileDiffsHandler);
    try authed.get("/api/git/file/read", ai_mod.http_handlers.gitFileReadHandler);
    try authed.post("/api/git/stage", ai_mod.http_handlers.gitStageHandler);
    try authed.post("/api/git/unstage", ai_mod.http_handlers.gitUnstageHandler);
    // Commit the staged index. Literal `/create` suffix (not a `:param`
    // sibling of `/api/git/commit`) so matchRoute cannot confuse it with
    // the read-only GET /api/git/commit detail route registered below —
    // the router walks registration order.
    try authed.post("/api/git/commit/create", ai_mod.http_handlers.gitCommitCreateHandler);
    try authed.get("/api/git/worktree/info", ai_mod.http_handlers.gitWorktreeInfoHandler);
    try authed.get("/api/git/branches", ai_mod.http_handlers.gitBranchesListHandler);
    try authed.get("/api/git/commits", ai_mod.http_handlers.gitCommitsListHandler);
    try authed.get("/api/git/commit", ai_mod.http_handlers.gitCommitDetailHandler);
    try authed.get("/api/git/commit/file", ai_mod.http_handlers.gitCommitFileDiffHandler);
    try authed.post("/api/git/pr", ai_mod.http_handlers.gitPrCreateHandler);
    try authed.get("/api/git/pr/status", ai_mod.http_handlers.gitPrStatusHandler);
    // Literal path, no `:param` sibling under `/api/git/pr/` (asserted by a
    // test in git_pr_checks.zig), so matchRoute cannot shadow it.
    try authed.get("/api/git/pr/checks", ai_mod.http_handlers.gitPrChecksHandler);
    try authed.get("/api/git/pr/diff", ai_mod.http_handlers.gitPrDiffHandler);
    try authed.get("/api/git/pr/conflicts", ai_mod.http_handlers.gitPrConflictsHandler);
}

fn registerFileRoutes(authed: *Group) !void {
    try authed.get("/api/system/folder", ai_mod.http_handlers.systemFolderHandler);
    // File download for the `present_files` agent tool card
    // (PresentFiles.vue). Literal path under a fresh `/api/files/`
    // prefix — no `:param` siblings exist under it, so no matchRoute
    // shadowing risk (router walks registration order). Plan:
    // docs/plans/2026-09-14-agent-tool-present-files.md
    try authed.get("/api/files/download", ai_mod.http_handlers.filesDownloadHandler);
}

fn registerWorkspaceRoutes(authed: *Group) !void {
    try authed.get("/api/workspaces", ai_mod.http_handlers.workspacesListHandler);
    try authed.post("/api/workspaces", ai_mod.http_handlers.workspacesCreateHandler);
    try authed.post("/api/workspaces/reorder", ai_mod.http_handlers.workspacesReorderHandler);
    try authed.get("/api/workspaces/:id", ai_mod.http_handlers.workspaceGetHandler);
    try authed.put("/api/workspaces/:id", ai_mod.http_handlers.workspaceUpdateHandler);
    try authed.delete("/api/workspaces/:id", ai_mod.http_handlers.workspaceDeleteHandler);
    // Id-only task PUT — MUST stay ABOVE every `:workspace_id` route below.
    //
    // It is deliberately id-only: a chat rename must not have to carry a
    // workspace/item scope (task.id IS the session id, Migration 052), and
    // `api.updateTaskSimple` sends only `{"name": ...}`. The `tasks` segment
    // here is a LITERAL, so the route cannot shadow or be shadowed by the
    // `:workspace_id/items/...` family — both agree on that segment.
    //
    // Registration order is load-bearing for a second reason that has nothing
    // to do with matching: `matchRoute` walks the table top-down and
    // kabelweb's `matchPathWithParams` writes each `:param` into the shared
    // `req.params` map as it walks, WITHOUT unwinding when a later literal
    // segment fails to match. So a request to
    // `/api/workspaces/tasks/<id>` first tried
    // `PUT /api/workspaces/:workspace_id/items/:item_id` and left
    // `workspace_id = "tasks"` behind in `req.params`. authMiddleware's
    // per-user choke point then read that leftover, `canSeeWorkspace("tasks")`
    // was false, and the rename 404'd with `{"error": "Workspace not found"}`
    // before the handler ever ran — only when `--auth` was on.
    //
    // The ordering is asserted behaviourally at the bottom of THIS file —
    // it resolves `PUT /api/workspaces/tasks/<id>` through `matchRoute` and
    // requires `req.params` to carry NO `workspace_id`. The end-to-end one
    // is `tests/functional/task_rename_id_route_auth_test.py`.
    try authed.put("/api/workspaces/tasks/:task_id", ai_mod.http_handlers.tasksUpdateByIdHandler);
    // Idempotent: returns the workspace's default project, creating it
    // (item_type='agent', path=$HOME) when there is none.
    //
    // This is the COLD-START FALLBACK. GET /api/workspaces/:ws/items
    // already ensures the default on the normal path, so most clients never
    // call this. It exists for the one case the list cannot cover: the app
    // was open when Migration 094 ran, so its loaded list predates the
    // is_default column and a "New Chat" tap would otherwise be a no-op
    // until a manual refetch.
    //
    // Route order: 3 segments, with a LITERAL `default-project` in position
    // 4. Every other 3+ segment route under /api/workspaces starts with a
    // literal `items` in that same position, and no
    // `POST /api/workspaces/:workspace_id/:param` route exists, so a param
    // sibling cannot shadow this. The tests at the bottom of THIS file
    // assert both facts against the built route table, so a future sibling
    // cannot land unnoticed.
    try authed.post("/api/workspaces/:workspace_id/default-project", ai_mod.http_handlers.workspaceDefaultProjectHandler);
    try authed.post("/api/workspaces/:workspace_id/items", ai_mod.http_handlers.workspaceItemsCreateHandler);
    try authed.get("/api/workspaces/:workspace_id/items", ai_mod.http_handlers.workspaceItemsListHandler);
    try authed.post("/api/workspaces/:workspace_id/items/reorder", ai_mod.http_handlers.workspaceItemsReorderHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsGetHandler);
    try authed.put("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsDeleteHandler);

    // Kanban workspace-item endpoints (item_type='kanban').
    //   POST   /items/kanban                       — create a kanban + seed 3 default columns
    //   GET    /items/:item_id/kanban/columns      — list columns
    //   POST   /items/:item_id/kanban/columns      — add a column
    //   PATCH  /items/:item_id/kanban/columns/:cid — rename and/or reorder a column
    //   DELETE /items/:item_id/kanban/columns/:cid — delete a column
    //   PATCH  /items/:item_id/tasks/:task_id/move — move a task across columns
    // See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 3).
    try authed.post("/api/workspaces/:workspace_id/items/kanban", ai_mod.http_handlers.workspaceItemsCreateKanbanHandler);
    // Design workspace-item endpoint (item_type='design').
    //   POST   /items/design                       — create a design (path is required;
    //                                              see design_items_create.zig)
    // See docs/superpowers/plans/2026-07-08-design-mode-redesign.md
    //   Chunk 8 (AppLayout + Sidebar Wiring).
    try authed.post("/api/workspaces/:workspace_id/items/design", ai_mod.http_handlers.workspaceItemsCreateDesignHandler);
}

fn registerAgentRoutes(authed: *Group) !void {
    // Agent Mode workspace-item endpoint (item_type='agent') + sub-resources.
    // Plan: docs/superpowers/plans/2026-08-15-agent-mode.md
    // Task: task_1786962724740_0
    try authed.post("/api/workspaces/:workspace_id/items/agent", ai_mod.http_handlers.workspaceItemsCreateAgentHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/agent", ai_mod.http_handlers.agentsGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/agent", ai_mod.http_handlers.agentsUpdateHandler);
    try authed.post("/api/agents/:agent_id/knowledge", ai_mod.http_handlers.agentKnowledgeCreateHandler);
    // ORDER MATTERS: the literal `/knowledge/reorder` route MUST be
    // registered BEFORE `/knowledge/:knowledge_id` — matchRoute walks
    // routes in registration order, so the param route would otherwise
    // capture PATCH /knowledge/reorder with knowledge_id="reorder".
    try authed.patch("/api/agents/:agent_id/knowledge/reorder", ai_mod.http_handlers.agentKnowledgeReorderHandler);
    try authed.patch("/api/agents/:agent_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKnowledgeUpdateHandler);
    try authed.delete("/api/agents/:agent_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKnowledgeDeleteHandler);
    // Agent system-prompt CRUD (Migration 080). NOTE: `reorder` literal
    // MUST be registered BEFORE `:prompt_id` — the router walks routes in
    // registration order and `:prompt_id` would otherwise capture the
    // literal "reorder" segment (same shadowing trap as knowledge above).
    try authed.post("/api/agents/:agent_id/system_prompt", ai_mod.http_handlers.agentSystemPromptCreateHandler);
    try authed.patch("/api/agents/:agent_id/system_prompt/reorder", ai_mod.http_handlers.agentSystemPromptReorderHandler);
    try authed.patch("/api/agents/:agent_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentSystemPromptUpdateHandler);
    try authed.delete("/api/agents/:agent_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentSystemPromptDeleteHandler);
    try authed.get("/api/agent-tools/registry", ai_mod.http_handlers.agentToolsRegistryHandler);
    try authed.get("/api/agents/:agent_id/tools", ai_mod.http_handlers.agentToolsListHandler);
    try authed.post("/api/agents/:agent_id/tools", ai_mod.http_handlers.agentToolsCreateHandler);
    try authed.delete("/api/agents/:agent_id/tools/:tool_name", ai_mod.http_handlers.agentToolsDeleteHandler);
}

fn registerAgentKanbanRoutes(authed: *Group) !void {
    // Agent-Kanbans mirror CRUD (Migration 081) — mirrors the agent block
    // above onto kanban boards. Plan:
    // docs/superpowers/plans/2026-08-25-agent-kanbans-mirror.md
    // Task: task_1787597624259_2.
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/agent_kanban", ai_mod.http_handlers.agentKanbansGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/agent_kanban", ai_mod.http_handlers.agentKanbansUpdateHandler);
    try authed.post("/api/agent-kanbans/:kanban_id/knowledge", ai_mod.http_handlers.agentKanbanKnowledgeCreateHandler);
    // ORDER MATTERS: the literal `/knowledge/reorder` route MUST be
    // registered BEFORE `/knowledge/:knowledge_id` — matchRoute walks
    // routes in registration order (same shadowing trap as the agent
    // knowledge routes above).
    try authed.patch("/api/agent-kanbans/:kanban_id/knowledge/reorder", ai_mod.http_handlers.agentKanbanKnowledgeReorderHandler);
    try authed.patch("/api/agent-kanbans/:kanban_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKanbanKnowledgeUpdateHandler);
    try authed.delete("/api/agent-kanbans/:kanban_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKanbanKnowledgeDeleteHandler);
    // NOTE: `reorder` literal MUST be registered BEFORE `:prompt_id`
    // (same shadowing trap as knowledge above).
    try authed.post("/api/agent-kanbans/:kanban_id/system_prompt", ai_mod.http_handlers.agentKanbanSystemPromptCreateHandler);
    try authed.patch("/api/agent-kanbans/:kanban_id/system_prompt/reorder", ai_mod.http_handlers.agentKanbanSystemPromptReorderHandler);
    try authed.patch("/api/agent-kanbans/:kanban_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentKanbanSystemPromptUpdateHandler);
    try authed.delete("/api/agent-kanbans/:kanban_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentKanbanSystemPromptDeleteHandler);
    try authed.get("/api/agent-kanbans/:kanban_id/tools", ai_mod.http_handlers.agentKanbanToolsListHandler);
    try authed.post("/api/agent-kanbans/:kanban_id/tools", ai_mod.http_handlers.agentKanbanToolsCreateHandler);
    try authed.delete("/api/agent-kanbans/:kanban_id/tools/:tool_name", ai_mod.http_handlers.agentKanbanToolsDeleteHandler);
}

fn registerAgentRoutineRoutes(authed: *Group) !void {
    // Agent-Routines mirror CRUD (Migration 087) — mirrors the agent-kanbans
    // block above onto routines. Routine mode task_1789505553300_1.
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/agent_routine", ai_mod.http_handlers.agentRoutinesGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/agent_routine", ai_mod.http_handlers.agentRoutinesUpdateHandler);
    try authed.post("/api/agent-routines/:routine_id/knowledge", ai_mod.http_handlers.agentRoutineKnowledgeCreateHandler);
    // ORDER MATTERS: literal `/knowledge/reorder` BEFORE
    // `/knowledge/:knowledge_id` (route-order shadowing — see kanban block).
    try authed.patch("/api/agent-routines/:routine_id/knowledge/reorder", ai_mod.http_handlers.agentRoutineKnowledgeReorderHandler);
    try authed.patch("/api/agent-routines/:routine_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentRoutineKnowledgeUpdateHandler);
    try authed.delete("/api/agent-routines/:routine_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentRoutineKnowledgeDeleteHandler);
    // NOTE: `reorder` literal MUST be registered BEFORE `:prompt_id`.
    try authed.post("/api/agent-routines/:routine_id/system_prompt", ai_mod.http_handlers.agentRoutineSystemPromptCreateHandler);
    try authed.patch("/api/agent-routines/:routine_id/system_prompt/reorder", ai_mod.http_handlers.agentRoutineSystemPromptReorderHandler);
    try authed.patch("/api/agent-routines/:routine_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentRoutineSystemPromptUpdateHandler);
    try authed.delete("/api/agent-routines/:routine_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentRoutineSystemPromptDeleteHandler);
    try authed.get("/api/agent-routines/:routine_id/tools", ai_mod.http_handlers.agentRoutineToolsListHandler);
    try authed.post("/api/agent-routines/:routine_id/tools", ai_mod.http_handlers.agentRoutineToolsCreateHandler);
    try authed.delete("/api/agent-routines/:routine_id/tools/:tool_name", ai_mod.http_handlers.agentRoutineToolsDeleteHandler);
}

fn registerWorkspaceDocumentRoutes(authed: *Group) !void {
    // Workspace-level routines (Migration 084, plan
    // 2026-09-10-workspace-items-routines) — first-class
    // `item_type='routine'`. Replaces the deleted per-task routes
    // (`POST .../tasks/:task_id/run`, `GET /api/routines`).
    try authed.post("/api/workspaces/:workspace_id/items/routine", ai_mod.http_handlers.workspaceItemsCreateRoutineHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/routine", ai_mod.http_handlers.workspaceRoutinesGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/routine", ai_mod.http_handlers.workspaceRoutinesUpdateHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/routines/:routine_id/run", ai_mod.http_handlers.workspaceRoutinesRunHandler);
    // Workspace-scoped documents (Migration 098). NOT a `workspace_items`
    // child: a document belongs to the workspace directly and surfaces in
    // its own sidebar section below Projects, never in the project tree.
    //
    // Route order: no `GET /api/workspaces/:workspace_id/:param` route
    // exists (the only sibling with a literal 4th segment is
    // `POST .../default-project`, a different verb), so `documents`
    // cannot be captured as a workspace id or vice-versa. The
    // `:document_id` routes are registered last in the group for the
    // usual reason: matchRoute walks routes in registration order, and
    // a param route registered before a literal sibling would swallow it.
    try authed.get("/api/workspaces/:workspace_id/documents", ai_mod.http_handlers.documentsListHandler);
    try authed.post("/api/workspaces/:workspace_id/documents", ai_mod.http_handlers.documentsCreateHandler);
    try authed.get("/api/workspaces/:workspace_id/documents/:document_id", ai_mod.http_handlers.documentsGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/documents/:document_id", ai_mod.http_handlers.documentsUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/documents/:document_id", ai_mod.http_handlers.documentsDeleteHandler);

    // Workspace-scoped skills (Migration 101). Registered NEXT TO the
    // documents routes because they are the same shape: a row that belongs
    // to a workspace and is read through `skills_store`, whose every
    // function takes `workspace_id` as a parameter that lands in the SQL
    // `WHERE` clause. The old collection route had no workspace to scope
    // to, which is why it merged two directories on the way in.
    //
    // The COLLECTION route comes before the `:skill_name` routes for the
    // usual reason: `matchRoute` walks routes in registration order and
    // returns on the first hit, so a param route registered first would
    // swallow the collection. See the sibling-prefix note in
    // `registerSystemRoutes` for why the eval routes live outside this
    // prefix entirely.
    try authed.get("/api/workspaces/:workspace_id/skills", ai_mod.http_handlers.skillsListHandler);
    try authed.post("/api/workspaces/:workspace_id/skills", ai_mod.http_handlers.skillCreateHandler);
    try authed.get("/api/workspaces/:workspace_id/skills/:skill_name", ai_mod.http_handlers.skillDetailHandler);
    try authed.patch("/api/workspaces/:workspace_id/skills/:skill_name", ai_mod.http_handlers.skillUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/skills/:skill_name", ai_mod.http_handlers.skillDeleteHandler);

    // Workspace-scoped secrets (Migration 103). Same shape as documents and
    // skills: a row that belongs to a workspace, read through
    // `secrets_store`, whose every function takes `workspace_id` as a
    // parameter that lands in the SQL `WHERE` clause. The two literal
    // collection routes come before the `:secret_id` routes for the usual
    // reason: `matchRoute` walks routes in registration order, so a param
    // route registered first would swallow the collection.
    try authed.get("/api/workspaces/:workspace_id/secrets", ai_mod.http_handlers.secretsListHandler);
    try authed.post("/api/workspaces/:workspace_id/secrets", ai_mod.http_handlers.secretsCreateHandler);
    try authed.patch("/api/workspaces/:workspace_id/secrets/:secret_id", ai_mod.http_handlers.secretsUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/secrets/:secret_id", ai_mod.http_handlers.secretsDeleteHandler);

    // Per-workspace config overlay (Migration 105): the config sections that
    // moved out of the User-scope Pabrik page into Workspace settings. GET and
    // PUT only - the seeding is the migration, so there is no reset/copy route.
    //
    // Route order: `/config` is a literal at the same depth as `/items`,
    // `/documents`, `/skills` and `/secrets`, and there is NO
    // `GET /api/workspaces/:workspace_id/:param` route, so no sibling param
    // can capture it. Anything added one level deeper (`/config/...`) is safe
    // for the same reason today - every route at that depth starts with a
    // literal first segment (`/items/:item_id`, `/skills/:skill_name`, ...) -
    // but the ordering rule still binds it: a `:param` registered before a
    // literal nested under it wins, silently.
    try authed.get("/api/workspaces/:workspace_id/config", ai_mod.http_handlers.workspaceConfigGetHandler);
    try authed.put("/api/workspaces/:workspace_id/config", ai_mod.http_handlers.workspaceConfigPutHandler);
}

fn registerKanbanRoutes(authed: *Group) !void {
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/kanban/columns", ai_mod.http_handlers.kanbanColumnsListHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/kanban/columns", ai_mod.http_handlers.kanbanColumnsCreateHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id", ai_mod.http_handlers.kanbanColumnsUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id", ai_mod.http_handlers.kanbanColumnsDeleteHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id/run_all_agents", ai_mod.http_handlers.runAllAgentsHandler);
    // Copy a kanban spec (column structure) from one kanban to another
    // (Chunk 2 of copy-kanban plan). Body: `{mode: "replace" | "append"}`.
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/kanban/copy_spec_from/:source_item_id", ai_mod.http_handlers.kanbanCopySpecHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/move", ai_mod.http_handlers.tasksMoveHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/tasks", ai_mod.http_handlers.tasksListHandler);
    // Single-task GET for the kanban Task details dialog (plan:
    // docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md).
    // Registered AFTER the list route — matchRoute walks routes in
    // registration order (router.zig route-order rule).
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", ai_mod.http_handlers.tasksGetHandler);
    // Lazy media fetch (media-flags change) — full `image_urls` / `video_urls`
    // only when `is_have_image` / `is_have_video` is true. Longer path
    // (extra `/media` segment) so no shadowing vs the `:task_id` route.
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/media", ai_mod.http_handlers.tasksMediaHandler);
    // Kanban task tag autocomplete (Chunk 1 of plan
    // docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md).
    // Paginated suggestions for the kanban task detail dialog's tag chip
    // input. Ordered by frequency DESC, then last_used_at DESC. Query
    // params: ?limit=N (default 8, max 50) &offset=K. Response:
    // { tags: [{name,count,last_used_at}], has_more }.
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/kanban/tags", ai_mod.http_handlers.kanbanTagsListHandler);
    // Kanban-scoped task create endpoint with mode='create' | mode='create_and_run' discriminator.
    // Mirrors the generic /tasks POST but rejects 404 when the parent item is not a kanban.
    // Plan: docs/superpowers/plans/2026-08-14-kanban-task-create-endpoints.md
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/kanban/tasks", ai_mod.http_handlers.kanbanTasksCreateHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/tasks", ai_mod.http_handlers.tasksCreateHandler);
    // Migration 069 (2026-08-06) removed the filesystem-backed
    // kanban-task attachment endpoints (POST + GET wildcard). Task
    // images now live inline on `workspace_item_tasks.image_urls` as
    // `||`-delimited base64 data URLs — no upload path, no broken
    // `*` wildcard GET route, no `<path>/.pabrik/attachments/<task>/`
    // clutter on disk. The frontend reads each image via
    // `<img :src="task.imageUrls[i]">`.
    try authed.put("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", ai_mod.http_handlers.tasksUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", ai_mod.http_handlers.tasksDeleteHandler);
    // NOTE: the per-task routine fire route (`POST .../tasks/:task_id/run`)
    // was deleted with the per-task `routines` table (Migration 084, plan
    // 2026-09-10-workspace-items-routines). Workspace-level routines fire
    // via `POST .../items/:item_id/routines/:routine_id/run` (registered
    // with the routine block above).
    // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Trigger
    // an LLM worker on an existing task's session WITHOUT queueing a
    // new user message. Distinct from POST /api/llm/session (always
    // queues a message). See
    // http_handlers/start_agent.zig for the full contract.
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent", ai_mod.http_handlers.startAgentHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/pin", ai_mod.http_handlers.taskPinHandler);
    // Chunk 3 of kanban-task-notification-icon: stamp the
    // `last_human_touched_at` column so the kanban card UI flips the
    // "AI finished — awaiting review" dot to the green "reviewed"
    // checkmark the moment a user opens the task. PUT (idempotent
    // re-stamp is harmless — see plan docs/plans/2026-07-26-kanban-task-notification-icon.md).
    try authed.put("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/touched", ai_mod.http_handlers.taskMarkHumanTouchedHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/tasks/reorder_pinned", ai_mod.http_handlers.tasksReorderPinnedHandler);
    // NOTE: `GET /api/routines` (per-task global listing) was deleted with
    // the per-task `routines` table (Migration 084, plan
    // 2026-09-10-workspace-items-routines). It now 404s.
}

fn registerDesignRoutes(authed: *Group) !void {
    // Design workspace-item endpoints (item_type='design') — v6
    //   GET    /design/pages                                — list pages
    //   POST   /design/pages                                — create page
    //   GET    /design/pages/:pid                           — get page + elements
    //   PATCH  /design/pages/:pid                           — update page (resize)
    //   DELETE /design/pages/:pid                           — delete page + on-disk folder
    //   POST   /design/pages/:pid/elements                  — add element
    //   PUT    /design/pages/:pid/elements/:eid             — update element
    //   DELETE /design/pages/:pid/elements/:eid             — delete element
    //   GET    /design/pages/:pid/elements/:eid/html        — get HTML body
    //   PATCH  /design/pages/:pid/elements/:eid/html        — update HTML body
    //   PATCH  /design/pages/:pid/elements/:eid/geometry    — DEPRECATED, use /translate or /resize
    //   POST   /design/pages/:pid/elements/:eid/translate   — single-element move (cascades for groups)
    //   POST   /design/pages/:pid/elements/:eid/resize     — single-element resize (no cascade)
    // See docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Chunk 3.5)
    // and docs/superpowers/plans/2026-08-06-split-move-resize.md.
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/design/pages", ai_mod.http_handlers.designPagesListHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages", ai_mod.http_handlers.designPagesCreateHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesDeleteHandler); // 2026-07-25-design-page-delete-button (Chunk 1)
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements", ai_mod.http_handlers.designElementsCreateHandler);
    // Group 2+ elements into a new group/frame parent. Single
    // transactional endpoint that creates the parent + reparents
    // the children atomically. See docs/superpowers/plans/
    // 2026-07-28-grouped-layers.md (Chunk 3).
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/group", ai_mod.http_handlers.designElementsGroupHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/reorder", ai_mod.http_handlers.designElementsReorderHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/reparent-batch", ai_mod.http_handlers.designElementsReparentBatchHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/ungroup", ai_mod.http_handlers.designElementsUngroupHandler);
    try authed.put("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id", ai_mod.http_handlers.designElementsUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id", ai_mod.http_handlers.designElementsDeleteHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/html", ai_mod.http_handlers.designElementsHtmlGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/html", ai_mod.http_handlers.designElementsHtmlUpdateHandler);
    // DEPRECATED — see design_elements_translate.zig + design_elements_resize.zig.
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/geometry", ai_mod.http_handlers.designElementsGeometryUpdateHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/geometry-batch", ai_mod.http_handlers.designElementsGeometryBatchHandler);
    // NEW (2026-08-06) — replaces /geometry with two distinct endpoints:
    // /translate (move) and /resize.
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/translate", ai_mod.http_handlers.designElementsTranslateHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/resize", ai_mod.http_handlers.designElementsResizeHandler);
    // Server-side cascade move. Each item's (dx, dy) recursively applies
    // to every transitive descendant of that item's element in one
    // SQL transaction. See
    // docs/superpowers/plans/2026-08-06-move-element-with-descendants.md (Chunk 2, Task 2.2).
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/move-batch", ai_mod.http_handlers.designElementsMoveBatchHandler);
    // Cross-page element relocate. Changes the element's `page_id` from
    // `:page_id` (path) to a target page in the body. Cascades to
    // transitive descendants when `apply_to_children=true` (default).
    // Plan: docs/superpowers/plans/2026-08-06-move-element-to-page.md (Chunk 2).
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/move-to-page", ai_mod.http_handlers.designElementsMoveToPageHandler);
}

fn registerTestRoutes(authed: *Group) !void {
    // testing debug (gated by auth middleware when `--auth` is on)
    try authed.post("/test/shutdown", ai_mod.http_handlers.shutdownHandler);
    try authed.get("/test/sessions/client_ids", ai_mod.http_handlers.sessionToClientIdsHandler);
    try authed.get("/test/system-prompt/:session_id", ai_mod.http_handlers.systemPromptGetHandler);
}
// ---------------------------------------------------------------------------
// Behavioural route contracts.
//
// These build the REAL production table on a bare `Router` and ask kabelweb's
// `matchRoute` which handler a request path resolves to and which `:params`
// it wrote. Registration order is only observable through that resolution —
// never through how this file is spelled — so reordering two routes fails
// here, while renaming a helper or rewording a comment does not.
// ---------------------------------------------------------------------------

const HandlerFn = gserverz.router.HandlerFn;
const MiddlewareFn = gserverz.router.MiddlewareFn;

/// What `matchRoute` resolved: the handler it selected plus the `:params` it
/// wrote into the request. `params` carries the real signal — a literal that
/// got captured by a `:param` sibling shows up as an unexpected key.
const Resolved = struct {
    handler: HandlerFn,
    params: std.StringHashMap([]const u8),
};

/// Build the exact production table on `arena`.
fn buildRouteTable(arena: std.mem.Allocator) !gserverz.router.Router {
    var router = gserverz.router.Router.init(arena);
    try registerAllOn(&router);
    return router;
}

/// Resolve one (method, path) against a built table. Null when nothing
/// matched, or when the hit was an SSE / WS route rather than a request
/// handler.
fn resolve(arena: std.mem.Allocator, router: *gserverz.router.Router, method: []const u8, path: []const u8) !?Resolved {
    var req = gserverz.HttpRequest{
        .method = method,
        .path = path,
        .version = "HTTP/1.1",
        .headers = std.StringHashMap([]const u8).init(arena),
        .body = "",
        .raw = "",
        .params = std.StringHashMap([]const u8).init(arena),
        .query = std.StringHashMap([]const u8).init(arena),
        ._client_fd = -1,
    };
    const ctx = gserverz.HttpContext{ .allocator = arena, .io = testing.io };
    const result = router.matchRoute(method, path, &req, ctx) orelse return null;
    const resolved: ?Resolved = switch (result) {
        .handler => |h| Resolved{ .handler = h.chain.final_handler, .params = req.params },
        .sse, .websocket => null,
    };
    return resolved;
}

test "route table: every /knowledge/reorder literal wins over its :id sibling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var router = try buildRouteTable(a);

    // Three families register the same `.../knowledge/reorder` +
    // `.../knowledge/:knowledge_id` pair. `matchRoute` stops at the first
    // hit, so if the `:param` sibling came first it would capture the
    // literal: the reorder PATCH would run the update handler with
    // knowledge_id="reorder" and 404. Assert resolution, not spelling.
    const families = [_]struct { prefix: []const u8, param: []const u8 }{
        .{ .prefix = "/api/agents/ag_1/knowledge", .param = "agent_id" },
        .{ .prefix = "/api/agent-kanbans/kb_1/knowledge", .param = "kanban_id" },
        .{ .prefix = "/api/agent-routines/rt_1/knowledge", .param = "routine_id" },
    };
    const reorder_handlers = [_]HandlerFn{
        ai_mod.http_handlers.agentKnowledgeReorderHandler,
        ai_mod.http_handlers.agentKanbanKnowledgeReorderHandler,
        ai_mod.http_handlers.agentRoutineKnowledgeReorderHandler,
    };
    const update_handlers = [_]HandlerFn{
        ai_mod.http_handlers.agentKnowledgeUpdateHandler,
        ai_mod.http_handlers.agentKanbanKnowledgeUpdateHandler,
        ai_mod.http_handlers.agentRoutineKnowledgeUpdateHandler,
    };

    for (families, reorder_handlers, update_handlers) |family, want_reorder, want_update| {
        const literal_path = try std.fmt.allocPrint(a, "{s}/reorder", .{family.prefix});
        const reorder = (try resolve(a, &router, "PATCH", literal_path)) orelse {
            std.debug.print("\n!! no route matches PATCH {s} !!\n", .{literal_path});
            return error.ReorderRouteNotRegistered;
        };
        try testing.expect(reorder.handler == want_reorder);
        // The literal must not leave a half-matched knowledge_id behind.
        try testing.expect(reorder.params.get("knowledge_id") == null);
        const scope = reorder.params.get(family.param).?;
        try testing.expect(scope.len > 0);

        const detail_path = try std.fmt.allocPrint(a, "{s}/know_1", .{family.prefix});
        const detail = (try resolve(a, &router, "PATCH", detail_path)) orelse {
            std.debug.print("\n!! no route matches PATCH {s} !!\n", .{detail_path});
            return error.KnowledgeParamRouteNotRegistered;
        };
        try testing.expect(detail.handler == want_update);
        try testing.expectEqualStrings("know_1", detail.params.get("knowledge_id").?);
    }
}

test "route table: PUT /api/workspaces/tasks/:task_id resolves with no workspace_id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var router = try buildRouteTable(a);

    // `api.updateTaskSimple` (chat rename + kanban card rename) PUTs
    // /api/workspaces/tasks/<id> with no workspace scope. If any
    // `PUT /api/workspaces/:workspace_id/...` route were tried first,
    // `matchPathWithParams` would write workspace_id="tasks" into the shared
    // params map and leave it there after failing on the next literal —
    // `authMiddleware` then read it, `canSeeWorkspace("tasks")` was false,
    // and the rename 404'd with {"error": "Workspace not found"}. The
    // leftover key IS the bug, so assert its absence.
    const rename = (try resolve(a, &router, "PUT", "/api/workspaces/tasks/task_1")) orelse
        return error.IdOnlyTaskRouteNotRegistered;
    const want: HandlerFn = ai_mod.http_handlers.tasksUpdateByIdHandler;
    try testing.expect(rename.handler == want);
    try testing.expectEqualStrings("task_1", rename.params.get("task_id").?);
    try testing.expect(rename.params.get("workspace_id") == null);
    try testing.expect(rename.params.get("item_id") == null);

    // The workspace-scoped sibling still binds its own scope, so the
    // assertion above is about THIS literal not stealing anything.
    const scoped = (try resolve(a, &router, "PUT", "/api/workspaces/ws_1/items/item_1")) orelse
        return error.WorkspaceItemPutRouteNotRegistered;
    try testing.expectEqualStrings("ws_1", scoped.params.get("workspace_id").?);
    try testing.expectEqualStrings("item_1", scoped.params.get("item_id").?);
}

test "route table: POST /api/workspaces/:workspace_id/default-project keeps a literal segment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var router = try buildRouteTable(a);

    const hit = (try resolve(a, &router, "POST", "/api/workspaces/ws_1/default-project")) orelse
        return error.DefaultProjectRouteNotRegistered;
    const want: HandlerFn = ai_mod.http_handlers.workspaceDefaultProjectHandler;
    try testing.expect(hit.handler == want);
    try testing.expectEqualStrings("ws_1", hit.params.get("workspace_id").?);
}

test "route table: no POST /api/workspaces/:workspace_id/:param sibling exists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const router = try buildRouteTable(a);

    // The collision has to be IMPOSSIBLE, not merely absent today: a bare
    // `:param` in the 4th segment would swallow `default-project` (and any
    // future 4th-segment literal) whenever matchRoute reached it first.
    // `.../items`, `.../items/agent`, `.../documents` are all literals.
    const prefix = "/api/workspaces/:workspace_id/";
    for (router.routes.items) |route| {
        if (!std.mem.eql(u8, route.method, "POST")) continue;
        if (!std.mem.startsWith(u8, route.path, prefix)) continue;
        const tail = route.path[prefix.len..];
        const segment_end = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
        if (segment_end == 0 or tail[0] != ':') continue;
        std.debug.print(
            "\n!! POST {s} puts a bare :param in the 4th segment - it shadows literal siblings !!\n",
            .{route.path},
        );
        return error.ParamSiblingUnderWorkspaceId;
    }
}

test "route table: all five documents verbs resolve to their handlers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var router = try buildRouteTable(a);

    const expectations = [_]struct { method: []const u8, path: []const u8, handler: HandlerFn }{
        .{
            .method = "GET",
            .path = "/api/workspaces/ws_1/documents",
            .handler = ai_mod.http_handlers.documentsListHandler,
        },
        .{
            .method = "POST",
            .path = "/api/workspaces/ws_1/documents",
            .handler = ai_mod.http_handlers.documentsCreateHandler,
        },
        .{
            .method = "GET",
            .path = "/api/workspaces/ws_1/documents/doc_1",
            .handler = ai_mod.http_handlers.documentsGetHandler,
        },
        .{
            .method = "PATCH",
            .path = "/api/workspaces/ws_1/documents/doc_1",
            .handler = ai_mod.http_handlers.documentsUpdateHandler,
        },
        .{
            .method = "DELETE",
            .path = "/api/workspaces/ws_1/documents/doc_1",
            .handler = ai_mod.http_handlers.documentsDeleteHandler,
        },
    };
    for (expectations) |want| {
        const hit = (try resolve(a, &router, want.method, want.path)) orelse {
            std.debug.print("\n!! no route matches {s} {s} !!\n", .{ want.method, want.path });
            return error.DocumentsRouteNotRegistered;
        };
        try testing.expect(hit.handler == want.handler);
        try testing.expectEqualStrings("ws_1", hit.params.get("workspace_id").?);
        if (std.mem.endsWith(u8, want.path, "/doc_1")) {
            try testing.expectEqualStrings("doc_1", hit.params.get("document_id").?);
        } else {
            try testing.expect(hit.params.get("document_id") == null);
        }
    }
}

test "route table: the five skills verbs resolve to their handlers" {
    // Replaces four `@embedFile("http_routes.zig")` greps in skills_list.zig.
    // Those could only compare byte offsets; this asks `matchRoute` which
    // handler each path actually lands on, which is what a 404 depends on.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var router = try buildRouteTable(a);

    const expectations = [_]struct { method: []const u8, path: []const u8, handler: HandlerFn, param: []const u8 }{
        .{
            .method = "GET",
            .path = "/api/workspaces/ws_1/skills",
            .handler = ai_mod.http_handlers.skillsListHandler,
            .param = "",
        },
        .{
            .method = "POST",
            .path = "/api/workspaces/ws_1/skills",
            .handler = ai_mod.http_handlers.skillCreateHandler,
            .param = "",
        },
        .{
            .method = "GET",
            .path = "/api/workspaces/ws_1/skills/pdf",
            .handler = ai_mod.http_handlers.skillDetailHandler,
            .param = "pdf",
        },
        .{
            .method = "PATCH",
            .path = "/api/workspaces/ws_1/skills/pdf",
            .handler = ai_mod.http_handlers.skillUpdateHandler,
            .param = "pdf",
        },
        .{
            .method = "DELETE",
            .path = "/api/workspaces/ws_1/skills/pdf",
            .handler = ai_mod.http_handlers.skillDeleteHandler,
            .param = "pdf",
        },
    };
    for (expectations) |want| {
        const hit = (try resolve(a, &router, want.method, want.path)) orelse {
            std.debug.print("\n!! no route matches {s} {s} !!\n", .{ want.method, want.path });
            return error.SkillRouteNotRegistered;
        };
        try testing.expect(hit.handler == want.handler);
        try testing.expectEqualStrings("ws_1", hit.params.get("workspace_id").?);
        if (want.param.len == 0) {
            // The collection route must not be captured by `:skill_name`.
            try testing.expect(hit.params.get("skill_name") == null);
        } else {
            try testing.expectEqualStrings(want.param, hit.params.get("skill_name").?);
        }
    }
}

test "route table: the four secrets verbs resolve to their handlers" {
    // Mirrors the skills route test above: asks `matchRoute` which handler
    // each path actually lands on, which is what a 404 depends on.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var router = try buildRouteTable(a);

    const expectations = [_]struct { method: []const u8, path: []const u8, handler: HandlerFn, param: []const u8 }{
        .{
            .method = "GET",
            .path = "/api/workspaces/ws_1/secrets",
            .handler = ai_mod.http_handlers.secretsListHandler,
            .param = "",
        },
        .{
            .method = "POST",
            .path = "/api/workspaces/ws_1/secrets",
            .handler = ai_mod.http_handlers.secretsCreateHandler,
            .param = "",
        },
        .{
            .method = "PATCH",
            .path = "/api/workspaces/ws_1/secrets/sec_1",
            .handler = ai_mod.http_handlers.secretsUpdateHandler,
            .param = "sec_1",
        },
        .{
            .method = "DELETE",
            .path = "/api/workspaces/ws_1/secrets/sec_1",
            .handler = ai_mod.http_handlers.secretsDeleteHandler,
            .param = "sec_1",
        },
    };
    for (expectations) |want| {
        const hit = (try resolve(a, &router, want.method, want.path)) orelse {
            std.debug.print("\n!! no route matches {s} {s} !!\n", .{ want.method, want.path });
            return error.SecretRouteNotRegistered;
        };
        try testing.expect(hit.handler == want.handler);
        try testing.expectEqualStrings("ws_1", hit.params.get("workspace_id").?);
        if (want.param.len == 0) {
            // The collection route must not be captured by `:secret_id`.
            try testing.expect(hit.params.get("secret_id") == null);
        } else {
            try testing.expectEqualStrings(want.param, hit.params.get("secret_id").?);
        }
    }
}

test "route table: every /api route except the open ones carries authMiddleware" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const router = try buildRouteTable(a);

    // `use` only affects routes registered AFTER it, and every `/api` route
    // must carry authMiddleware. A second `group("")` — or a group created
    // after some of the routes — would silently serve an unauthenticated
    // table, which is what reading `Route.middlewares` proves cannot happen.
    // The auth endpoints (they ARE the credential check) plus the two
    // long-lived streams, which mount on the root router on purpose.
    const open = [_][]const u8{
        "/api/auth/login",
        "/api/auth/logout",
        "/api/auth/me",
        "/api/events",
        "/api/terminal/ws",
    };
    const want: MiddlewareFn = ai_mod.http_handlers.authMiddleware;

    var checked: usize = 0;
    for (router.routes.items) |route| {
        if (!std.mem.startsWith(u8, route.path, "/api/")) continue;
        var is_open = false;
        for (open) |o| {
            if (std.mem.eql(u8, route.path, o)) is_open = true;
        }
        if (is_open) continue;
        checked += 1;
        if (route.middlewares.len != 1 or route.middlewares[0] != want) {
            std.debug.print(
                "\n!! {s} {s} carries {d} middleware(s), want exactly authMiddleware !!\n",
                .{ route.method, route.path, route.middlewares.len },
            );
            return error.ApiRouteMissingAuthMiddleware;
        }
    }
    try testing.expect(checked > 0);
}

test "route table: POST /api/llm/session/reorder_pinned wins over :session_id/pin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var router = try buildRouteTable(a);

    // The literal reorder route must resolve to its own handler, not be
    // captured as session_id="reorder_pinned" by a param sibling.
    const reorder = (try resolve(a, &router, "POST", "/api/llm/session/reorder_pinned")) orelse {
        return error.ReorderRouteNotRegistered;
    };
    try testing.expect(reorder.handler == ai_mod.http_handlers.sessionReorderPinnedHandler);
    try testing.expect(reorder.params.get("session_id") == null);

    // The param route still resolves with the id intact.
    const pin = (try resolve(a, &router, "POST", "/api/llm/session/sess_1/pin")) orelse {
        return error.PinRouteNotRegistered;
    };
    try testing.expect(pin.handler == ai_mod.http_handlers.sessionPinHandler);
    try testing.expectEqualStrings("sess_1", pin.params.get("session_id").?);
}

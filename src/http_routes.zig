// src/http_routes.zig Every HTTP route pabrik serves, in the ONE place they
// are registered.

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

/// The route table itself.
pub fn registerAllOn(router: *gserverz.router.Router) !void {
    // Opt-in `--auth`: all `/api` routes registered via `authed` run
    // `authMiddleware` (401 when no valid `pabrik_session` cookie).
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
    try registerPreviewRoutes(&authed);
}

fn registerAuthRoutes(router: *gserverz.router.Router) !void {
    try router.post("/api/auth/login", ai_mod.http_handlers.authLoginHandler);
    try router.post("/api/auth/logout", ai_mod.http_handlers.authLogoutHandler);
    try router.get("/api/auth/me", ai_mod.http_handlers.authMeHandler);
    // // try authed.get("/api/stream/:session_id/disconnect",
    // http_handlers.sseDisconnectHandler, .{}); // try
    // authed.post("/api/stream/:session_id/disconnect",
}

fn registerSessionRoutes(authed: *Group) !void {
    try authed.post("/api/session", ai_mod.http_handlers.sessionCreateHandler);
    try authed.put("/api/session/:session_id", ai_mod.http_handlers.sessionUpdateHandler);
    // Mark-as-seen (yellow stale-dot fix): stamping
    // `sessions.last_human_touched_at_nano` when the user opens a chat.
    try authed.post("/api/session/:session_id/touched", ai_mod.http_handlers.sessionMarkTouchedHandler);
    try authed.get("/api/session", ai_mod.http_handlers.sessionListHandler);
    try authed.get("/api/session/:session_id/messages", ai_mod.http_handlers.sessionMessagesHandler);
    // Token usage + cache hit rate, derived from `llm_history` (the
    // `sessions` table stores no token column).
    try authed.get("/api/session/:session_id/usage", ai_mod.http_handlers.sessionUsageHandler);
    // try authed.get("/api/session/exists/:session_id",
    // http_handlers.sessionExistHandler, ctxParent); try
    // authed.get("/api/session/latest", http_handlers.sessionLatestHandler,
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
    // `ask_user` answer route.
    try authed.post("/api/llm/session/:session_id/answer", ai_mod.http_handlers.askUserAnswerHandler);

    try authed.get("/api/llm/session", ai_mod.http_handlers.sessionListHandler);
    // Session detail incl. `workspace_id` (workspace-scoped sessions).
    try authed.get("/api/llm/session/:session_id", ai_mod.http_handlers.sessionGetHandler);
    try authed.get("/api/llm/session/:session_id/messages", ai_mod.http_handlers.sessionMessagesHandler);
    // Token usage + cache hit rate (same handler as the `/api/session/` alias
    // above).
    try authed.get("/api/llm/session/:session_id/usage", ai_mod.http_handlers.sessionUsageHandler);
    try authed.get("/api/llm/session/:session_id/queue_messages", ai_mod.http_handlers.queueMessagesGetHandler);
    // Session background-process endpoints (bg-completion): list + log tail
    // for `command background=true` rows. Registered next to queue_messages.
    try authed.get("/api/llm/session/:session_id/background_processes", ai_mod.http_handlers.backgroundProcessesListHandler);
    try authed.get("/api/llm/session/:session_id/background_processes/:pid/log", ai_mod.http_handlers.backgroundProcessLogGetHandler);
}

fn registerTerminalRoutes(authed: *Group, router: *gserverz.router.Router) !void {
    // Right-sidebar terminal (PTY over REST + poll). Fresh `/api/terminal/`
    // prefix — no `:param` siblings exist under it, so no matchRoute
    // shadowing risk (router walks registration order).
    try authed.post("/api/terminal/sessions", ai_mod.http_handlers.terminalCreateHandler);
    // The live session list: a window-level footer reads it to show the
    // shells grouped per workspace. Registered before the `:id` routes so
    // the exact path is matched first.
    try authed.get("/api/terminal/sessions", ai_mod.http_handlers.terminalListHandler);
    try authed.post("/api/terminal/sessions/:id/input", ai_mod.http_handlers.terminalInputHandler);
    try authed.get("/api/terminal/sessions/:id/output", ai_mod.http_handlers.terminalOutputHandler);
    try authed.post("/api/terminal/sessions/:id/resize", ai_mod.http_handlers.terminalResizeHandler);
    try authed.delete("/api/terminal/sessions/:id", ai_mod.http_handlers.terminalDeleteHandler);
    // Duplex PTY socket — attaches to a live session id (?id=) for binary
    // output frames + JSON control frames.
    try router.ws("/api/terminal/ws", ai_mod.http_handlers.terminalWsHandler);
}

fn registerStreamRoutes(authed: *Group, router: *gserverz.router.Router) !void {
    // In-flight stream snapshot (task_1787673548905_0 stream-resume-on-
    // reselect) — serves `{ active, content }` from the in-memory
    // stream_snapshot registry so a re-mounted ChatView can resume a
    try authed.get("/api/llm/session/:session_id/stream", ai_mod.http_handlers.streamGetHandler);
    // Live spawn-batch snapshot (task_1788505292766_1
    // spawn-subagent-refresh-persist) — serves `{ tool_call_id, progress[] }`
    // from the in-memory subagent_progress registry so a refreshed ChatView
    try authed.get("/api/subagent/progress/:tool_call_id", ai_mod.http_handlers.subAgentProgressGetHandler);
    // Unified SSE endpoint — single EventSource for all event families
    // (workers, sessions, kanban_column, kanban_task, per-session llm +
    // queue_messages).
    try router.sse("/api/events", ai_mod.http_handlers.unifiedEventsStreamHandler);
    // Test-only SSE emit (dev_sse_emit.zig) — gated by PABRIK_TEST_SSE_EMIT=1,
    // 404 when off. Functional UI tests use it to drive the chatview's
    // SSE streaming path without a real LLM.
    try authed.post("/api/dev/sse/emit_llm", ai_mod.http_handlers.devSseEmitLlmHandler);
}

fn registerSystemRoutes(authed: *Group, router: *gserverz.router.Router) !void {
    try router.get("/health", ai_mod.http_handlers.healthHandler);
    // Skills are NOT registered here.

    // Skill Evals — the READ surface for the eval the agent runs on itself.
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

    // Local Memories routes — scoped to <cwd>/.pabrik/memories/.
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

    // models.dev model catalog (Migration 106).
    try authed.get("/api/models/catalog", ai_mod.http_handlers.modelsCatalogHandler);
    try authed.get("/api/models/resolve", ai_mod.http_handlers.modelsResolveHandler);
    try authed.post("/api/models/refresh", ai_mod.http_handlers.modelsRefreshHandler);

    // OS notification test endpoint — fires a real OS notification so
    // the user can verify their system can display them.
    try authed.post("/api/notify/test", ai_mod.http_handlers.notifyTestHandler);

    // Browser-mode (web launch) status — read-only: reports the
    // `web_launch_enabled` flag + live bound port/URL for the settings
    // General tab pill.
    try authed.get("/api/web/status", ai_mod.http_handlers.webStatusHandler);

    // MCP server "Test" probe — fires a tools/list request against a
    // candidate config without persisting anything.
    try authed.post("/api/mcp/test", ai_mod.http_handlers.mcpTestHandler);

    // LLM profile "Test" probe — fires one minimal non-streaming chat call
    // against a candidate profile without persisting anything.
    try authed.post("/api/llm/test", ai_mod.http_handlers.llmTestHandler);

    // Frontend error log endpoints — POST /api/logs is DISABLED (noisy: the
    // desktop log client spammed it on every console.error/warn). GET
    // /api/logs stays as a read-only debug endpoint for `curl`.
    try authed.get("/api/logs", ai_mod.http_handlers.frontendLogGetHandler);
}

fn registerGitRoutes(authed: *Group) !void {
    try authed.get("/api/git/status", ai_mod.http_handlers.gitStatusHandler);
    try authed.get("/api/git/changes", ai_mod.http_handlers.gitChangesHandler);
    try authed.get("/api/git/blame", ai_mod.http_handlers.gitBlameHandler);
    // No per-file diff route.
    try authed.post("/api/git/file/diffs", ai_mod.http_handlers.gitFileDiffsHandler);
    try authed.get("/api/git/file/read", ai_mod.http_handlers.gitFileReadHandler);
    try authed.post("/api/git/stage", ai_mod.http_handlers.gitStageHandler);
    try authed.post("/api/git/unstage", ai_mod.http_handlers.gitUnstageHandler);
    // Commit the staged index.
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
    // POST, and the only mutating forge endpoint: `gh pr merge` / `glab mr
    // merge` change a remote branch, so it is never reachable unauthenticated.
    try authed.post("/api/git/pr/merge", ai_mod.http_handlers.gitPrMergeHandler);
    // Literal paths under `/api/git/pr/` (no `:param` sibling exists, so
    // matchRoute cannot shadow them — the router walks registration order).
    try authed.get("/api/git/pr/list", ai_mod.http_handlers.gitPrListHandler);
    // The second mutating forge endpoint: `gh pr close` / `glab mr close`
    // write to a remote, so it is never reachable unauthenticated.
    try authed.post("/api/git/pr/close", ai_mod.http_handlers.gitPrCloseHandler);
}

fn registerFileRoutes(authed: *Group) !void {
    try authed.get("/api/system/folder", ai_mod.http_handlers.systemFolderHandler);
    // File download for the `present_files` agent tool card
    // (PresentFiles.vue).
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
    try authed.put("/api/workspaces/tasks/:task_id", ai_mod.http_handlers.tasksUpdateByIdHandler);
    // Idempotent: returns the workspace's default project, creating it
    // (item_type='agent', path=$HOME) when there is none. This is the
    // COLD-START FALLBACK.
    try authed.post("/api/workspaces/:workspace_id/default-project", ai_mod.http_handlers.workspaceDefaultProjectHandler);
    try authed.post("/api/workspaces/:workspace_id/items", ai_mod.http_handlers.workspaceItemsCreateHandler);
    try authed.get("/api/workspaces/:workspace_id/items", ai_mod.http_handlers.workspaceItemsListHandler);
    try authed.post("/api/workspaces/:workspace_id/items/reorder", ai_mod.http_handlers.workspaceItemsReorderHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsGetHandler);
    try authed.put("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsDeleteHandler);

    // Kanban workspace-item endpoints (item_type='kanban').
    try authed.post("/api/workspaces/:workspace_id/items/kanban", ai_mod.http_handlers.workspaceItemsCreateKanbanHandler);
    // Design workspace-item endpoint (item_type='design').
    try authed.post("/api/workspaces/:workspace_id/items/design", ai_mod.http_handlers.workspaceItemsCreateDesignHandler);
}

fn registerAgentRoutes(authed: *Group) !void {
    // Agent Mode workspace-item endpoint (item_type='agent') + sub-resources.
    // Task: task_1786962724740_0
    try authed.post("/api/workspaces/:workspace_id/items/agent", ai_mod.http_handlers.workspaceItemsCreateAgentHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/agent", ai_mod.http_handlers.agentsGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/agent", ai_mod.http_handlers.agentsUpdateHandler);
    try authed.post("/api/agents/:agent_id/knowledge", ai_mod.http_handlers.agentKnowledgeCreateHandler);
    // ORDER MATTERS: the literal `/knowledge/reorder` route MUST be
    // registered BEFORE `/knowledge/:knowledge_id` — matchRoute walks routes
    // in registration order, so the param route would otherwise capture PATCH
    try authed.patch("/api/agents/:agent_id/knowledge/reorder", ai_mod.http_handlers.agentKnowledgeReorderHandler);
    try authed.patch("/api/agents/:agent_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKnowledgeUpdateHandler);
    try authed.delete("/api/agents/:agent_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKnowledgeDeleteHandler);
    // Agent system-prompt CRUD (Migration 080).
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
    // above onto kanban boards.
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/agent_kanban", ai_mod.http_handlers.agentKanbansGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/agent_kanban", ai_mod.http_handlers.agentKanbansUpdateHandler);
    try authed.post("/api/agent-kanbans/:kanban_id/knowledge", ai_mod.http_handlers.agentKanbanKnowledgeCreateHandler);
    // ORDER MATTERS: the literal `/knowledge/reorder` route MUST be
    // registered BEFORE `/knowledge/:knowledge_id` — matchRoute walks routes
    // in registration order (same shadowing trap as the agent knowledge
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
    // `item_type='routine'`.
    try authed.post("/api/workspaces/:workspace_id/items/routine", ai_mod.http_handlers.workspaceItemsCreateRoutineHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/routine", ai_mod.http_handlers.workspaceRoutinesGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/routine", ai_mod.http_handlers.workspaceRoutinesUpdateHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/routines/:routine_id/run", ai_mod.http_handlers.workspaceRoutinesRunHandler);
    // Workspace-scoped documents (Migration 098).
    try authed.get("/api/workspaces/:workspace_id/documents", ai_mod.http_handlers.documentsListHandler);
    try authed.post("/api/workspaces/:workspace_id/documents", ai_mod.http_handlers.documentsCreateHandler);
    try authed.get("/api/workspaces/:workspace_id/documents/:document_id", ai_mod.http_handlers.documentsGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/documents/:document_id", ai_mod.http_handlers.documentsUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/documents/:document_id", ai_mod.http_handlers.documentsDeleteHandler);

    // Workspace-scoped skills (Migration 101).
    try authed.get("/api/workspaces/:workspace_id/skills", ai_mod.http_handlers.skillsListHandler);
    try authed.post("/api/workspaces/:workspace_id/skills", ai_mod.http_handlers.skillCreateHandler);
    try authed.get("/api/workspaces/:workspace_id/skills/:skill_name", ai_mod.http_handlers.skillDetailHandler);
    try authed.patch("/api/workspaces/:workspace_id/skills/:skill_name", ai_mod.http_handlers.skillUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/skills/:skill_name", ai_mod.http_handlers.skillDeleteHandler);

    // Workspace-scoped secrets (Migration 103).
    try authed.get("/api/workspaces/:workspace_id/secrets", ai_mod.http_handlers.secretsListHandler);
    try authed.post("/api/workspaces/:workspace_id/secrets", ai_mod.http_handlers.secretsCreateHandler);
    try authed.patch("/api/workspaces/:workspace_id/secrets/:secret_id", ai_mod.http_handlers.secretsUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/secrets/:secret_id", ai_mod.http_handlers.secretsDeleteHandler);

    // Per-workspace config overlay (Migration 105): the config sections that
    // moved out of the User-scope Pabrik page into Workspace settings.
    try authed.get("/api/workspaces/:workspace_id/config", ai_mod.http_handlers.workspaceConfigGetHandler);
    try authed.put("/api/workspaces/:workspace_id/config", ai_mod.http_handlers.workspaceConfigPutHandler);
    try authed.delete("/api/workspaces/:workspace_id/config/profiles/:name", ai_mod.http_handlers.workspaceConfigProfileDeleteHandler);
}

fn registerKanbanRoutes(authed: *Group) !void {
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/kanban/columns", ai_mod.http_handlers.kanbanColumnsListHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/kanban/columns", ai_mod.http_handlers.kanbanColumnsCreateHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id", ai_mod.http_handlers.kanbanColumnsUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id", ai_mod.http_handlers.kanbanColumnsDeleteHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id/run_all_agents", ai_mod.http_handlers.runAllAgentsHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id/stop_all_agents", ai_mod.http_handlers.stopAllAgentsHandler);
    // Copy a kanban spec (column structure) from one kanban to another
    // (Chunk 2 of copy-kanban plan). Body: `{mode: "replace" | "append"}`.
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/kanban/copy_spec_from/:source_item_id", ai_mod.http_handlers.kanbanCopySpecHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/move", ai_mod.http_handlers.tasksMoveHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/tasks", ai_mod.http_handlers.tasksListHandler);
    // Single-task GET for the kanban Task details dialog.
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", ai_mod.http_handlers.tasksGetHandler);
    // Lazy media fetch (media-flags change) — full `image_urls` / `video_urls`
    // only when `is_have_image` / `is_have_video` is true. Longer path
    // (extra `/media` segment) so no shadowing vs the `:task_id` route.
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/media", ai_mod.http_handlers.tasksMediaHandler);
    // Kanban task tag autocomplete.
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/kanban/tags", ai_mod.http_handlers.kanbanTagsListHandler);
    // Kanban-scoped task create endpoint with mode='create' | mode='create_and_run' discriminator.
    // Mirrors the generic /tasks POST but rejects 404 when the parent item is not a kanban.
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/kanban/tasks", ai_mod.http_handlers.kanbanTasksCreateHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/tasks", ai_mod.http_handlers.tasksCreateHandler);
    // Migration 069 (2026-08-06) removed the filesystem-backed kanban-task
    // attachment endpoints (POST + GET wildcard).
    try authed.put("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", ai_mod.http_handlers.tasksUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", ai_mod.http_handlers.tasksDeleteHandler);
    // NOTE: the per-task routine fire route (`POST .../tasks/:task_id/run`)
    // was deleted with the per-task `routines` table (Migration 084, plan
    // 2026-09-10-workspace-items-routines).
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent", ai_mod.http_handlers.startAgentHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/pin", ai_mod.http_handlers.taskPinHandler);
    // Chunk 3 of kanban-task-notification-icon: stamp the
    // `last_human_touched_at` column so the kanban card UI flips the "AI
    // finished — awaiting review" dot to the green "reviewed" checkmark the
    try authed.put("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/touched", ai_mod.http_handlers.taskMarkHumanTouchedHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/tasks/reorder_pinned", ai_mod.http_handlers.tasksReorderPinnedHandler);
    // NOTE: `GET /api/routines` (per-task global listing) was deleted with
    // the per-task `routines` table (Migration 084, plan
    // 2026-09-10-workspace-items-routines). It now 404s.
}

fn registerDesignRoutes(authed: *Group) !void {
    // Design workspace-item endpoints (item_type='design') — v6 GET
    // /design/pages — list pages POST /design/pages — create page GET
    // /design/pages/:pid — get page + elements PATCH /design/pages/:pid —
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/design/pages", ai_mod.http_handlers.designPagesListHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages", ai_mod.http_handlers.designPagesCreateHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesDeleteHandler); // 2026-07-25-design-page-delete-button (Chunk 1)
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements", ai_mod.http_handlers.designElementsCreateHandler);
    // Group 2+ elements into a new group/frame parent. Single transactional
    // endpoint that creates the parent + reparents the children atomically.
    // See docs/superpowers/plans/ 2026-07-28-grouped-layers.md (Chunk 3).
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
    // Server-side cascade move. Each item's (dx, dy) recursively applies to
    // every transitive descendant of that item's element in one SQL
    // transaction.
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/move-batch", ai_mod.http_handlers.designElementsMoveBatchHandler);
    // Cross-page element relocate. Changes the element's `page_id` from
    // `:page_id` (path) to a target page in the body.
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/move-to-page", ai_mod.http_handlers.designElementsMoveToPageHandler);
}

/// The preview proxy: the ONE route that reaches a port inside a workspace's
/// VM. It is a mutation-capable endpoint on purpose (a tenant dev server sees
/// POSTs), so it sits on `authed` like every other `/api` route.
fn registerPreviewRoutes(authed: *Group) !void {
    try authed.get("/api/preview", ai_mod.http_handlers.previewProxyHandler);
    try authed.post("/api/preview", ai_mod.http_handlers.previewProxyHandler);
    try authed.put("/api/preview", ai_mod.http_handlers.previewProxyHandler);
    try authed.delete("/api/preview", ai_mod.http_handlers.previewProxyHandler);
}

fn registerTestRoutes(authed: *Group) !void {
    // testing debug (gated by auth middleware when `--auth` is on)
    try authed.post("/test/shutdown", ai_mod.http_handlers.shutdownHandler);
    try authed.get("/test/sessions/client_ids", ai_mod.http_handlers.sessionToClientIdsHandler);
    try authed.get("/test/system-prompt/:session_id", ai_mod.http_handlers.systemPromptGetHandler);
}
// ---------------------------------------------------------------------------
// Behavioural route contracts.

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
    // `.../knowledge/:knowledge_id` pair.
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
    // /api/workspaces/tasks/<id> with no workspace scope.
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
    // must carry authMiddleware.
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

test "route table: GET session usage resolves on both prefixes and shadows no sibling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var router = try buildRouteTable(a);

    // Both prefixes the desktop app may use land on the usage handler, with
    // the id intact. `:session_id` matches exactly one segment, so the
    // `usage` tail can neither be captured by `/messages` nor capture it.
    const expectations = [_][]const u8{
        "/api/session/sess_1/usage",
        "/api/llm/session/sess_1/usage",
    };
    for (expectations) |path| {
        const hit = (try resolve(a, &router, "GET", path)) orelse {
            std.debug.print("\n!! no route matches GET {s} !!\n", .{path});
            return error.UsageRouteNotRegistered;
        };
        try testing.expect(hit.handler == ai_mod.http_handlers.sessionUsageHandler);
        try testing.expectEqualStrings("sess_1", hit.params.get("session_id").?);
    }

    // The `messages` sibling keeps its own handler on both prefixes — the
    // new route must not have taken over the prefix.
    const siblings = [_][]const u8{
        "/api/session/sess_1/messages",
        "/api/llm/session/sess_1/messages",
    };
    for (siblings) |path| {
        const hit = (try resolve(a, &router, "GET", path)) orelse {
            std.debug.print("\n!! no route matches GET {s} !!\n", .{path});
            return error.MessagesRouteNotRegistered;
        };
        try testing.expect(hit.handler == ai_mod.http_handlers.sessionMessagesHandler);
    }

    // And the detail route is untouched: `usage` must not have made the
    // bare `:session_id` pattern stop matching a single-segment path.
    const detail = (try resolve(a, &router, "GET", "/api/llm/session/sess_1")) orelse {
        return error.SessionDetailRouteNotRegistered;
    };
    try testing.expect(detail.handler == ai_mod.http_handlers.sessionGetHandler);
}

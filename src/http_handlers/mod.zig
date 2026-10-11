//! HTTP Handlers module - one file per endpoint for better organization
//!
//! This module exports all HTTP handlers used by the TUI HTTP server.
//! Each handler is in its own file for maintainability.

const std = @import("std");
pub const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const sqlite = pabrikcore.sqlite;
const ai_workflow = pabrikcore.ai_workflow;
const loggermod = pabrikcore.loggermod;

const config = pabrikcore.config;
pub const http_response = pabrikcore.http_response;

// =============================================================================
// Re-exports
// =============================================================================

// Re-export all handlers
pub const corsPreflightHandler = @import("cors.zig").corsPreflightHandler;
pub const sessionCreateHandler = @import("session_create.zig").sessionCreateHandler;
/// The session-create funnel without the transport. `pabrik headless run`
/// calls this so a CLI turn and a browser turn execute the same code —
/// see the doc comment on `useCase` for why that matters.
pub const sessionCreateUseCase = @import("session_create.zig").useCase;
pub const RequestSession = @import("session_create.zig").RequestSession;
pub const sessionUpdateHandler = @import("session_update.zig").sessionUpdateHandler;
pub const sessionPinHandler = @import("session_pin.zig").sessionPinHandler;
pub const sessionReorderPinnedHandler = @import("session_reorder_pinned.zig").sessionReorderPinnedHandler;
pub const sessionMarkTouchedHandler = @import("session_mark_touched.zig").sessionMarkTouchedHandler;
pub const sessionListHandler = @import("session_list.zig").sessionListHandler;
// GET /api/llm/session/:session_id — single-session detail incl.
// workspace_id (workspace-scoped sessions plan).
pub const sessionGetHandler = @import("session_get.zig").sessionGetHandler;
pub const sessionStopHandler = @import("session_stop.zig").sessionStopHandler;
// POST /api/llm/session/:session_id/answer — resolve a pending `ask_user`
// question (Migration 087), rewrite its tool-result row and resume the run.
pub const askUserAnswerHandler = @import("ask_user_answer.zig").askUserAnswerHandler;
pub const sessionExistHandler = @import("session_exist.zig").sessionExistHandler;
pub const sessionMessagesHandler = @import("session_messages_get.zig").sessionMessagesHandler;
// GET /api/llm/session/:session_id/stream — in-flight stream snapshot
// (task_1787673548905_0 stream-resume-on-reselect).
pub const streamGetHandler = @import("stream_get.zig").streamGetHandler;
// GET /api/subagent/progress/:tool_call_id — live spawn-batch snapshot
// (task_1788505292766_1 spawn-subagent-refresh-persist).
pub const subAgentProgressGetHandler = @import("subagent_progress_get.zig").subAgentProgressGetHandler;
pub const sessionLatestHandler = @import("session_latest.zig").sessionLatestHandler;
pub const sseDisconnectHandler = @import("sse_disconnect.zig").sseDisconnectHandler;
pub const pingHandler = @import("ping.zig").pingHandler;
pub const sessionCompactHandler = @import("session_compact.zig").sessionCompactHandler;
pub const systemFolderHandler = @import("system_folder.zig").systemFolderHandler;
pub const filesDownloadHandler = @import("files_download.zig").filesDownloadHandler;
pub const healthHandler = @import("health.zig").healthHandler;
pub const shutdownHandler = @import("shutdown.zig").shutdownHandler;
// Opt-in `--auth` (login page + session cookie + middleware).
pub const authLoginHandler = @import("auth_login.zig").authLoginHandler;
pub const authLogoutHandler = @import("auth_session.zig").authLogoutHandler;
pub const authMeHandler = @import("auth_session.zig").authMeHandler;
pub const authMiddleware = @import("auth_middleware.zig").authMiddleware;
pub const authIsAuthorized = @import("auth_middleware.zig").isAuthorized;

// Workspace handlers (stub implementations for desktop app compatibility)
pub const workspacesListHandler = @import("workspaces_list.zig").workspacesListHandler;
pub const workspacesCreateHandler = @import("workspaces_create.zig").workspacesCreateHandler;
// The single workspace-create path: id generation, the `position = MAX + 1`
// INSERT, the `workspace_members` grant and the attached default project.
// Exposed so `pabrik create-admin` (src/main.zig) and any future signup route
// can provision an account's "Default" workspace through the same code the
// POST /api/workspaces handler uses.
pub const workspace_provisioning = @import("workspace_provisioning.zig");
pub const workspacesReorderHandler = @import("workspaces_reorder.zig").workspacesReorderHandler;
pub const workspaceGetHandler = @import("workspace_get.zig").workspaceGetHandler;
pub const workspaceUpdateHandler = @import("workspace_update.zig").workspaceUpdateHandler;
pub const workspaceDeleteHandler = @import("workspace_delete.zig").workspaceDeleteHandler;
pub const workspaceItemsCreateHandler = @import("workspace_items_create.zig").workspaceItemsCreateHandler;
pub const workspaceItemsListHandler = @import("workspace_items_get.zig").workspaceItemsListHandler;
pub const workspaceItemsGetHandler = @import("workspace_items_get.zig").workspaceItemsGetHandler;
pub const workspaceDefaultProjectHandler = @import("workspace_items_default.zig").workspaceDefaultProjectHandler;

test {
    // The implementation file's OWN inline tests. This line is load-bearing and
    // its absence is invisible: `pub const workspaceDefaultProjectHandler =
    // @import("workspace_items_default.zig").workspaceDefaultProjectHandler;`
    // above makes the file reachable for its *value*, but that does NOT pull
    // its tests into the test binary. Only a `test { _ = @import(...) }` block
    // does.
    //
    // Nine tests (create, idempotence, per-workspace, alongside-ordinary,
    // bad-home, empty-id, race, useCaseGet, workspaceExists) were silently not
    // running for an entire review cycle because this block was missing, and a
    // freeing bug in that file shipped. Verified with `strings` on the test
    // binary: the test names were absent. Do not delete this import.
    //
    // The former `workspace_items_default_test.zig` (static route-contract
    // assertions) is now inline at the bottom of workspace_items_default.zig,
    // so this single import surfaces both halves.
    _ = @import("workspace_items_default.zig");

    // web_search_mask: key masking + provider validation for the config
    // handlers. Its tests only run if something imports it.
    _ = @import("web_search_mask.zig");
}
pub const workspaceItemsUpdateHandler = @import("workspace_items_update.zig").workspaceItemsUpdateHandler;
pub const workspaceItemsReorderHandler = @import("workspace_items_reorder.zig").workspaceItemsReorderHandler;
pub const workspaceItemsDeleteHandler = @import("workspace_items_delete.zig").workspaceItemsDeleteHandler;
pub const workspaceItemsCreateKanbanHandler = @import("workspace_items_create_kanban.zig").workspaceItemsCreateKanbanHandler;
pub const workspaceItemsCreateDesignHandler = @import("design_items_create.zig").workspaceItemsCreateDesignHandler;
// Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0) — 4th
// workspace-item type. See workspace_items_create_agent.zig.
pub const workspaceItemsCreateAgentHandler = @import("workspace_items_create_agent.zig").workspaceItemsCreateAgentHandler;
pub const agentsGetHandler = @import("agents_get.zig").agentsGetHandler;
pub const agentsUpdateHandler = @import("agents_update.zig").agentsUpdateHandler;
// Agent Mode knowledge CRUD (Task 6)
pub const agentKnowledgeCreateHandler = @import("agent_knowledge_create.zig").agentKnowledgeCreateHandler;
pub const agentKnowledgeUpdateHandler = @import("agent_knowledge_update.zig").agentKnowledgeUpdateHandler;
pub const agentKnowledgeDeleteHandler = @import("agent_knowledge_delete.zig").agentKnowledgeDeleteHandler;
pub const agentKnowledgeReorderHandler = @import("agent_knowledge_reorder.zig").agentKnowledgeReorderHandler;
// Test-only SSE emit (dev_sse_emit.zig) — gated by PABRIK_TEST_SSE_EMIT=1,
// returns 404 when the gate is off. Used by functional UI tests to drive
// the chatview's SSE streaming path without a real LLM.
pub const devSseEmitLlmHandler = @import("dev_sse_emit.zig").emitLlmHandler;
// MCP server "Test" probe — fires a tools/list request against a
// candidate config (without persisting anything) so the user can
// verify their command / args / env / cwd (or URL + headers) before
// clicking Save in the MCP server modal. `mcpTestHandler` is declared
// at the bottom of this file (merged from the former mcp_test.zig).
// LLM profile "Test" probe — fires one minimal non-streaming chat call
// against a candidate model + base_url + api_key + url_style (without
// persisting anything) so the user can verify the profile before
// clicking Save in the Add/Edit profile modal. `llmTestHandler` is
// declared at the bottom of this file (merged from the former
// llm_test.zig).
// Agent Mode tools CRUD (Tasks 7-8)
pub const agentToolsRegistryHandler = @import("agent_tools_registry.zig").agentToolsRegistryHandler;
pub const agentToolsListHandler = @import("agent_tools_list.zig").agentToolsListHandler;
pub const agentToolsCreateHandler = @import("agent_tools_create.zig").agentToolsCreateHandler;
pub const agentToolsDeleteHandler = @import("agent_tools_delete.zig").agentToolsDeleteHandler;
// Agent Mode system-prompt CRUD (Migration 080)
pub const agentSystemPromptCreateHandler = @import("agent_system_prompt_create.zig").agentSystemPromptCreateHandler;
pub const agentSystemPromptUpdateHandler = @import("agent_system_prompt_update.zig").agentSystemPromptUpdateHandler;
pub const agentSystemPromptDeleteHandler = @import("agent_system_prompt_delete.zig").agentSystemPromptDeleteHandler;
pub const agentSystemPromptReorderHandler = @import("agent_system_prompt_reorder.zig").agentSystemPromptReorderHandler;

// Agent-Kanbans mirror (Migration 081, plan 2026-08-25-agent-kanbans-mirror)
pub const agentKanbansGetHandler = @import("agent_kanbans_get.zig").agentKanbansGetHandler;
pub const agentKanbansUpdateHandler = @import("agent_kanbans_update.zig").agentKanbansUpdateHandler;
pub const agentKanbanKnowledgeCreateHandler = @import("agent_kanban_knowledge_create.zig").agentKanbanKnowledgeCreateHandler;
pub const agentKanbanKnowledgeUpdateHandler = @import("agent_kanban_knowledge_update.zig").agentKanbanKnowledgeUpdateHandler;
pub const agentKanbanKnowledgeDeleteHandler = @import("agent_kanban_knowledge_delete.zig").agentKanbanKnowledgeDeleteHandler;
pub const agentKanbanKnowledgeReorderHandler = @import("agent_kanban_knowledge_reorder.zig").agentKanbanKnowledgeReorderHandler;
pub const agentKanbanSystemPromptCreateHandler = @import("agent_kanban_system_prompt_create.zig").agentKanbanSystemPromptCreateHandler;
pub const agentKanbanSystemPromptUpdateHandler = @import("agent_kanban_system_prompt_update.zig").agentKanbanSystemPromptUpdateHandler;
pub const agentKanbanSystemPromptDeleteHandler = @import("agent_kanban_system_prompt_delete.zig").agentKanbanSystemPromptDeleteHandler;
pub const agentKanbanSystemPromptReorderHandler = @import("agent_kanban_system_prompt_reorder.zig").agentKanbanSystemPromptReorderHandler;
pub const agentKanbanToolsListHandler = @import("agent_kanban_tools_list.zig").agentKanbanToolsListHandler;
pub const agentKanbanToolsCreateHandler = @import("agent_kanban_tools_create.zig").agentKanbanToolsCreateHandler;
pub const agentKanbanToolsDeleteHandler = @import("agent_kanban_tools_delete.zig").agentKanbanToolsDeleteHandler;

// Agent-Routines mirror (Migration 087, Routine mode task_1789505553300_1
// option A — mirrors the agent-kanbans block above onto routines).
pub const agentRoutinesGetHandler = @import("agent_routines_get.zig").agentRoutinesGetHandler;
pub const agentRoutinesUpdateHandler = @import("agent_routines_update.zig").agentRoutinesUpdateHandler;
pub const agentRoutineKnowledgeCreateHandler = @import("agent_routine_knowledge_create.zig").agentRoutineKnowledgeCreateHandler;
pub const agentRoutineKnowledgeUpdateHandler = @import("agent_routine_knowledge_update.zig").agentRoutineKnowledgeUpdateHandler;
pub const agentRoutineKnowledgeDeleteHandler = @import("agent_routine_knowledge_delete.zig").agentRoutineKnowledgeDeleteHandler;
pub const agentRoutineKnowledgeReorderHandler = @import("agent_routine_knowledge_reorder.zig").agentRoutineKnowledgeReorderHandler;
pub const agentRoutineSystemPromptCreateHandler = @import("agent_routine_system_prompt_create.zig").agentRoutineSystemPromptCreateHandler;
pub const agentRoutineSystemPromptUpdateHandler = @import("agent_routine_system_prompt_update.zig").agentRoutineSystemPromptUpdateHandler;
pub const agentRoutineSystemPromptDeleteHandler = @import("agent_routine_system_prompt_delete.zig").agentRoutineSystemPromptDeleteHandler;
pub const agentRoutineSystemPromptReorderHandler = @import("agent_routine_system_prompt_reorder.zig").agentRoutineSystemPromptReorderHandler;
pub const agentRoutineToolsListHandler = @import("agent_routine_tools_list.zig").agentRoutineToolsListHandler;
pub const agentRoutineToolsCreateHandler = @import("agent_routine_tools_create.zig").agentRoutineToolsCreateHandler;
pub const agentRoutineToolsDeleteHandler = @import("agent_routine_tools_delete.zig").agentRoutineToolsDeleteHandler;

// Workspace-level routines (Migration 084, plan
// 2026-09-10-workspace-items-routines) — first-class
// `item_type='routine'` beside `agent`. Replaces the deleted
// per-task `routines` table (Migration 044).
pub const workspaceItemsCreateRoutineHandler = @import("workspace_items_create_routine.zig").workspaceItemsCreateRoutineHandler;
pub const workspaceRoutinesGetHandler = @import("workspace_routines_get.zig").workspaceRoutinesGetHandler;
pub const workspaceRoutinesUpdateHandler = @import("workspace_routines_update.zig").workspaceRoutinesUpdateHandler;
pub const workspaceRoutinesRunHandler = @import("workspace_routines_run.zig").workspaceRoutinesRunHandler;

// Workspace-scoped documents (Migration 098). One file per HTTP verb,
// each carrying its own private `useCase` + inline tests — the house
// shape (mirrors the routines block above).
pub const documentsListHandler = @import("documents_list.zig").documentsListHandler;
pub const documentsCreateHandler = @import("documents_create.zig").documentsCreateHandler;
pub const documentsGetHandler = @import("documents_get.zig").documentsGetHandler;
pub const documentsUpdateHandler = @import("documents_update.zig").documentsUpdateHandler;
pub const documentsDeleteHandler = @import("documents_delete.zig").documentsDeleteHandler;

// Workspace-scoped secrets (Migration 103). Same house shape as the
// documents block above: one file per HTTP verb, each carrying its own
// private `useCase` + inline tests. No handler reads a secret's value back —
// the response type has no field for one (Design Decision 9).
pub const secretsListHandler = @import("secrets_list.zig").secretsListHandler;
pub const secretsCreateHandler = @import("secrets_create.zig").secretsCreateHandler;
pub const secretsUpdateHandler = @import("secrets_update.zig").secretsUpdateHandler;
pub const secretsDeleteHandler = @import("secrets_delete.zig").secretsDeleteHandler;

// Kanban column CRUD handlers (item_type='kanban' sub-resources).
// See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 3).
pub const kanbanColumnsListHandler = @import("kanban_columns_list.zig").kanbanColumnsListHandler;
pub const kanbanColumnsCreateHandler = @import("kanban_columns_create.zig").kanbanColumnsCreateHandler;
// POST /api/workspaces/:workspace_id/items/:item_id/kanban/tasks with
// `mode` discriminator ('create' | 'create_and_run'). See
// docs/superpowers/plans/2026-08-13-kanban-task-create-endpoint.md (Task 1).
pub const kanbanTasksCreateHandler = @import("kanban_tasks_create.zig").kanbanTasksCreateHandler;
pub const kanbanColumnsUpdateHandler = @import("kanban_columns_update.zig").kanbanColumnsUpdateHandler;
pub const kanbanColumnsDeleteHandler = @import("kanban_columns_delete.zig").kanbanColumnsDeleteHandler;
// Copy a kanban's column spec (names + descriptions, preserving order)
// from a source kanban to a target kanban. Tasks are NOT copied.
// Body: `{mode: "replace" | "append"}`. See plan
// docs/superpowers/plans/2026-07-04-copy-kanban-spec.md (Chunk 2).
pub const kanbanCopySpecHandler = @import("kanban_copy_spec.zig").kanbanCopySpecHandler;
pub const tasksMoveHandler = @import("tasks_move.zig").tasksMoveHandler;
pub const tasksListHandler = @import("tasks_list.zig").tasksListHandler;
// Single-task GET endpoint (plan:
// docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md).
pub const tasksGetHandler = @import("tasks_get.zig").tasksGetHandler;
// Lazy media fetch (media-flags change) — full `image_urls` / `video_urls`
// only when `is_have_image` / `is_have_video` is true.
pub const tasksMediaHandler = @import("tasks_media.zig").tasksMediaHandler;
// Kanban tag autocomplete endpoint (Chunk 1 of plan
// docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md).
// Stub-only in this commit — Task 1.4 implements the useCase body.
pub const kanbanTagsListHandler = @import("kanban_tags_list.zig").kanbanTagsListHandler;
pub const tasksCreateHandler = @import("task_create.zig").tasksCreateHandler;
pub const tasksUpdateHandler = @import("task_update.zig").tasksUpdateHandler;
pub const tasksUpdateByIdHandler = @import("task_update.zig").tasksUpdateByIdHandler;
pub const tasksDeleteHandler = @import("task_delete.zig").tasksDeleteHandler;
// Use-case + outcome type live in the same file as the handler
// (DELETE /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id).
// The handler is a thin orchestrator over `deleteTaskUseCase`; both
// are scoped under `pabrikcore.http_handlers.*` per the project
// convention (see `pabrik_config_profile_delete.zig`'s re-exports).
pub const deleteTaskUseCase = @import("task_delete.zig").deleteTaskUseCase;
pub const TaskDeleteOutcome = @import("task_delete.zig").TaskDeleteOutcome;
pub const taskPinHandler = @import("task_pin.zig").taskPinHandler;
// Chunk 3 of kanban-task-notification-icon: thin handler that stamps
// `last_human_touched_at` and emits the `kanban_task.human_touched`
// SSE event. See docs/plans/2026-07-26-kanban-task-notification-icon.md.
pub const taskMarkHumanTouchedHandler = @import("task_mark_human_touched.zig").taskMarkHumanTouchedHandler;
pub const tasksReorderPinnedHandler = @import("tasks_reorder_pinned.zig").tasksReorderPinnedHandler;
// Task attachment upload/download handlers — REMOVED 2026-08-06
// (Migration 069 / kanban-image-urls-column plan). Replaced by the
// `workspace_item_tasks.image_urls` column (`||`-delimited base64
// data URLs) — see image_urls_validation.zig for the wire format
// and validation. No filesystem path lookup, no broken `*` GET
// wildcard route. The handler files task_attachment_post.zig and
// task_attachment_get.zig have been deleted.
// NOTE: routinesRunHandler deleted with the per-task `routines` table
// (Migration 084, plan 2026-09-10-workspace-items-routines).
// NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Dedicated
// endpoint for triggering an LLM worker on an existing task's
// session WITHOUT queueing a new user message. Distinct from
// `sessionCreateHandler` (POST /api/llm/session) which always
// inserts a queue message.
pub const startAgentHandler = @import("start_agent.zig").startAgentHandler;
// NEW (plan: 2026-08-18-kanban-task-detail-start-agent). The split
// use-case, re-exported so callers + tests can reach it as
// `pabrikcore.http_handlers.startAgentUseCase` (matches the
// `task_delete.zig::deleteTaskUseCase` re-export convention).
pub const startAgentUseCase = @import("start_agent.zig").startAgentUseCase;
pub const runAllAgentsHandler = @import("run_all_agents.zig").runAllAgentsHandler;
// NOTE: routinesListHandler deleted with the per-task `routines` table
// (Migration 084, plan 2026-09-10-workspace-items-routines).

// Worker API handlers
pub const workerGetHandler = @import("worker_get.zig").workerGetHandler;
pub const workerListHandler = @import("worker_list.zig").workerListHandler;

// Unified SSE handler — single endpoint that fans out all event families.
// Replaces the 5 dedicated routes registered in main.zig. See
// unified_events_sse.zig for the channel grammar (?channels=).
pub const unifiedEventsStreamHandler = @import("unified_events_sse.zig").unifiedEventsStreamHandler;

// Skills API handlers
// Workspace-scoped skills (Migration 101). All three read and write through
// `agentic_loop/skills_store.zig`, so the workspace scoping lives in SQL
// rather than in a check each handler has to remember. Wired at
// `/api/workspaces/:workspace_id/skills[/:skill_name]`.
pub const skillsListHandler = @import("skills_list.zig").skillsListHandler;
pub const skillCreateHandler = @import("skill_create.zig").skillCreateHandler;
pub const skillDetailHandler = @import("skill_detail.zig").skillDetailHandler;
pub const skillUpdateHandler = @import("skill_update.zig").skillUpdateHandler;
pub const skillDeleteHandler = @import("skill_delete.zig").skillDeleteHandler;
// Skill Evals — the read surface (see docs/plans/2026-09-27-skill-evals.md §4.10).
// A SIBLING prefix under /api/skill-evals/, deliberately outside the skills
// prefix above: `matchRoute` returns on the first registration-order hit, so
// a literal nested under a `:skill_name` route would be captured as the param.
pub const skillEvalsRunsHandler = @import("skill_evals.zig").skillEvalsRunsHandler;
pub const skillEvalsSummaryHandler = @import("skill_evals.zig").skillEvalsSummaryHandler;
pub const skillEvalsApplyHandler = @import("skill_evals.zig").skillEvalsApplyHandler;

// Memories API handlers
pub const memoriesListHandler = @import("memories_list.zig").memoriesListHandler;
pub const memoryDetailHandler = @import("memories_detail.zig").memoryDetailHandler;
pub const memoryCreateHandler = @import("memories_create.zig").memoryCreateHandler;
pub const memoryUpdateHandler = @import("memories_update.zig").memoryUpdateHandler;
pub const memoryDeleteHandler = @import("memories_delete.zig").memoryDeleteHandler;

// Local Memories API handlers — same CRUD shape as the global memories
// handlers above but operating on `<cwd>/.pabrik/memories/` instead of
// `~/.config/pabrik/memories/`. The `cwd` resolution prefers the body
// (for POST/PUT) or the query string (for GET/DELETE), falling back
// to the pabrik server's CWD via `io.realPath` when no explicit cwd
// is provided. See `docs/plans/2026-06-20-add-markdown-memory.md`.
pub const localMemoriesListHandler = @import("local_memories_list.zig").localMemoriesListHandler;
pub const localMemoryDetailHandler = @import("local_memories_detail.zig").localMemoryDetailHandler;
pub const localMemoryCreateHandler = @import("local_memories_create.zig").localMemoryCreateHandler;
pub const localMemoryUpdateHandler = @import("local_memories_update.zig").localMemoryUpdateHandler;
pub const localMemoryDeleteHandler = @import("local_memories_delete.zig").localMemoryDeleteHandler;

// Git API handlers
pub const gitStatusHandler = @import("git_status.zig").gitStatusHandler;
pub const gitChangesHandler = @import("git_changes.zig").gitChangesHandler;
pub const gitBlameHandler = @import("git_blame.zig").gitBlameHandler;
pub const gitFileReadHandler = @import("git_file_diff.zig").gitFileReadHandler;
pub const gitFileDiffsHandler = @import("git_file_diffs.zig").gitFileDiffsHandler;
pub const gitStageHandler = @import("git_file_stage.zig").gitStageHandler;
pub const gitUnstageHandler = @import("git_file_stage.zig").gitUnstageHandler;
pub const gitCommitCreateHandler = @import("git_commit.zig").gitCommitHandler;
pub const gitWorktreeInfoHandler = @import("git_worktree_info.zig").gitWorktreeInfoHandler;
pub const gitBranchesListHandler = @import("git_branches_list.zig").gitBranchesListHandler;
pub const gitCommitsListHandler = @import("git_commits.zig").gitCommitsListHandler;
pub const gitCommitDetailHandler = @import("git_commits.zig").gitCommitDetailHandler;
pub const gitCommitFileDiffHandler = @import("git_commits.zig").gitCommitFileDiffHandler;
pub const gitPrCreateHandler = @import("git_pr_create.zig").gitPrCreateHandler;
pub const gitPrDiffHandler = @import("git_pr_diff.zig").gitPrDiffHandler;
pub const gitPrStatusHandler = @import("git_pr_status.zig").gitPrStatusHandler;
pub const gitPrConflictsHandler = @import("git_pr_conflicts.zig").gitPrConflictsHandler;

/// POST /api/git/pr/merge — merge a PR/MR through the forge CLI. Returns the
/// status payload RE-READ after the command, because a zero exit code is not
/// proof that anything merged (see git_pr_merge.zig).
pub const gitPrMergeHandler = @import("git_pr_merge.zig").gitPrMergeHandler;

/// GET /api/git/pr/checks — CI jobs for a PR plus the steps inside each
/// failed one. Registered next to the status handler because the two
/// share provider resolution (`git_pr_status.resolveProvider`).
pub const gitPrChecksHandler = @import("git_pr_checks.zig").gitPrChecksHandler;

// Queue messages handlers
pub const queueMessagesGetHandler = @import("queue_messages_get.zig").queueMessagesGetHandler;
// Session background-process handlers — list + log tail for
// `command background=true` rows (no new SSE event, no migration).
pub const backgroundProcessesListHandler = @import("background_processes_list.zig").backgroundProcessesListHandler;
pub const backgroundProcessLogGetHandler = @import("background_process_log_get.zig").backgroundProcessLogGetHandler;

// Right-sidebar terminal (PTY over REST + poll — no WebSocket, no
// kabelweb changes). In-memory session registry, no migration.
pub const terminalCreateHandler = @import("terminal_create.zig").terminalCreateHandler;
pub const terminalInputHandler = @import("terminal_input.zig").terminalInputHandler;
pub const terminalOutputHandler = @import("terminal_output.zig").terminalOutputHandler;
pub const terminalResizeHandler = @import("terminal_resize.zig").terminalResizeHandler;
pub const terminalDeleteHandler = @import("terminal_delete.zig").terminalDeleteHandler;
pub const terminalWsHandler = @import("terminal_ws.zig").terminalWsHandler;

// Design-mode HTTP handlers (item_type='design') — v6 of the
// design-mode redesign. See
// docs/superpowers/plans/2026-07-08-design-mode-redesign.md
// (Chunk 3) for the full route table.
pub const designPagesListHandler = @import("design_pages_list.zig").designPagesListHandler;
pub const designPagesCreateHandler = @import("design_pages_create.zig").designPagesCreateHandler;
pub const designPagesGetHandler = @import("design_pages_get.zig").designPagesGetHandler;
pub const designPagesUpdateHandler = @import("design_pages_update.zig").designPagesUpdateHandler;
pub const designPagesDeleteHandler = @import("design_pages_delete.zig").designPagesDeleteHandler; // 2026-07-25-design-page-delete-button (Chunk 1)
pub const designElementsCreateHandler = @import("design_elements_create.zig").designElementsCreateHandler;
pub const designElementsUpdateHandler = @import("design_elements_update.zig").designElementsUpdateHandler;
pub const designElementsDeleteHandler = @import("design_elements_delete.zig").designElementsDeleteHandler;
pub const designElementsHtmlGetHandler = @import("design_elements_html_get.zig").designElementsHtmlGetHandler;
pub const designElementsHtmlUpdateHandler = @import("design_elements_html_update.zig").designElementsHtmlUpdateHandler;
// DEPRECATED — PATCH .../geometry. Use POST .../translate (move) or
// POST .../resize (resize) instead. Kept for back-compat with
// any client still wired to the old single endpoint.
pub const designElementsGeometryUpdateHandler = @import("design_elements_geometry_update.zig").designElementsGeometryUpdateHandler;
// DEPRECATED — POST .../geometry-batch. Replaced by POST .../move-batch
// (server-side cascade) for multi-element translation. Kept for
// back-compat with any client still wired to the old endpoint.
pub const designElementsGeometryBatchHandler = @import("design_elements_geometry_batch.zig").designElementsGeometryBatchHandler;
// NEW (2026-08-06) — POST .../translate. Single-element move with
// delta. Cascades to descendants when the element is a group/frame.
// See docs/superpowers/plans/2026-08-06-split-move-resize.md.
pub const designElementsTranslateHandler = @import("design_elements_translate.zig").designElementsTranslateHandler;
pub const designElementsTranslateUseCase = @import("design_elements_translate.zig").useCase;
pub const designElementsTranslateError = @import("design_elements_translate.zig").DesignElementTranslateError;
// NEW (2026-08-06) — POST .../resize. Single-element resize with
// absolute x/y/width/height/rotation. No cascade (resize is per-element
// by Figma convention).
// See docs/superpowers/plans/2026-08-06-split-move-resize.md.
pub const designElementsResizeHandler = @import("design_elements_resize.zig").designElementsResizeHandler;
pub const designElementsResizeUseCase = @import("design_elements_resize.zig").useCase;
pub const designElementsResizeError = @import("design_elements_resize.zig").DesignElementResizeError;
// Group 2+ elements into a new `group`/`frame` parent. POST
// /api/workspaces/:w/items/:i/design/pages/:p/elements/group — see
// docs/superpowers/plans/2026-07-28-grouped-layers.md (Chunk 3).
pub const designElementsGroupHandler = @import("design_elements_group.zig").designElementsGroupHandler;
pub const designElementsReorderHandler = @import("design_elements_reorder.zig").designElementsReorderHandler;
pub const designElementsReparentBatchHandler = @import("design_elements_reparent.zig").designElementsReparentBatchHandler;
// Server-side cascade move. POST /api/workspaces/:w/items/:i/design/pages/:p/elements/move-batch
// — see docs/superpowers/plans/2026-08-06-move-element-with-descendants.md (Chunk 2).
pub const designElementsMoveBatchHandler = @import("design_elements_move_batch.zig").designElementsMoveBatchHandler;
// Cross-page element relocate. POST /api/workspaces/:w/items/:i/design/pages/:p/elements/:eid/move-to-page
// — see docs/superpowers/plans/2026-08-06-move-element-to-page.md (Chunk 2).
pub const designElementsMoveToPageHandler = @import("design_elements_move_to_page.zig").designElementsMoveToPageHandler;
pub const designElementsUngroupHandler = @import("design_elements_ungroup.zig").designElementsUngroupHandler;

// Session to client IDs monitoring
pub const sessionToClientIdsHandler = @import("session_to_client_ids.zig").sessionToClientIdsHandler;

// Debug/inspection endpoint — returns the rendered system prompt for a
// session. See `system_prompt_get.zig` for the full contract.
pub const systemPromptGetHandler = @import("system_prompt_get.zig").systemPromptGetHandler;

// Pabrik config handlers
pub const pabrikConfigGetHandler = @import("pabrik_config_get.zig").pabrikConfigGetHandler;
pub const pabrikConfigPutHandler = @import("pabrik_config_put.zig").pabrikConfigPutHandler;
// Per-workspace config overlay (Migration 105).
pub const workspaceConfigGetHandler = @import("workspace_config.zig").workspaceConfigGetHandler;
pub const workspaceConfigPutHandler = @import("workspace_config.zig").workspaceConfigPutHandler;
pub const pabrikConfigProfileDeleteHandler = @import("pabrik_config_profile_delete.zig").pabrikConfigProfileDeleteHandler;
// Use-case + domain types live in the same file as the handler. The
// handler is a thin orchestrator over the use-case; both are scoped
// under `pabrikcore.http_handlers.*` (the convention for handler
// internals — see `pabrik_config_profile_delete_test.zig`'s header).
pub const removeProfileFromConfig = @import("pabrik_config_profile_delete.zig").removeProfileFromConfig;
pub const PabrikConfigJsonForDelete = @import("pabrik_config_profile_delete.zig").PabrikConfigJsonForDelete;
// `ConfigInput` is the wire format for `PUT /api/config/pabrik`. It is
// `pub` so the test file can re-parse the same body the handler would
// and lock in the parse-step tolerance (the on-disk object map vs the
// granular array-of-changes shape). Exposed alongside `parseConfigInput`
// for the same reason.
pub const ConfigInput = @import("pabrik_config_put.zig").ConfigInput;
pub const parseConfigInput = @import("pabrik_config_put.zig").parseConfigInput;

// OS notification test handler — fires a real OS notification so the
// user can verify their system can display them without running a
// full LLM stream. See /docs/superpowers/plans/2026-01-15-llm-completion-notification.md
// `notifyTestHandler` is declared at the bottom of this file (merged
// from the former notify_test.zig).

// Browser-mode (web launch) status — read-only report of the
// `web_launch_enabled` flag + live bound port/URL. Plan
// 2026-09-10-web-launch-toggle (lifecycle A: no server-side
// start/stop, the flag only drives the settings UI).
pub const webStatusHandler = @import("web_status.zig").webStatusHandler;

// Frontend error log handlers — persist and query the
// window.error / unhandledrejection / console.error / console.warn
// events in the `logs` table. See
// docs/plans/2026-07-17-frontend-error-logs-design.md.
pub const frontendLogPostHandler = @import("frontend_log_post.zig").frontendLogPostHandler;
pub const frontendLogGetHandler = @import("frontend_log_get.zig").frontendLogGetHandler;

// =============================================================================
// Shared Types & Helpers
// =============================================================================

/// Response format types
pub const ResponseFormat = enum { json, xml };

/// Determine response format from Accept header or query param
pub fn getResponseFormat(req: gserverz.HttpRequest) ResponseFormat {
    // First check Accept header (higher priority)
    if (req.header("accept")) |accept| {
        if (std.mem.indexOf(u8, accept, "text/xml") != null or
            std.mem.indexOf(u8, accept, "application/xml") != null)
        {
            return .xml;
        }
        if (std.mem.indexOf(u8, accept, "application/json") != null) {
            return .json;
        }
    }

    // Fallback to query parameter
    const query = req.query() catch return .json;
    const format_param = query.get("format") orelse return .json;

    if (std.mem.eql(u8, format_param, "xml")) {
        return .xml;
    }
    return .json;
}

/// Build error response based on format
pub fn buildErrorResponse(allocator: std.mem.Allocator, format: ResponseFormat, error_msg: []const u8) ![]u8 {
    if (format == .xml) {
        return std.fmt.allocPrint(allocator, "<error>{s}</error>", .{error_msg});
    } else {
        return http_response.makeErrorResponse(allocator, .{ .@"error" = error_msg });
    }
}

/// SSE stream context for persistent connections
pub const SseStreamCtx = struct {
    server: *pabrikcore.gserverz.GinwaServer,
    session_id: []const u8,
};

// ===== Tests merged from notify_test.zig (2026-09-29 flatten) =====
//
// This file held no `test` blocks — it is the OS-notification probe
// endpoint whose name merely ends in `_test`. Merged here so the module
// keeps a single source per handler; the `notifyTestHandler` re-export
// at the top of this file now resolves to the decl below.

const notifications = pabrikcore.notifications_mod;

/// POST /api/notify/test
///
/// Fires a fixed test OS notification so the user can verify their
/// system can display notifications without running a full LLM stream.
/// The request body is ignored — always uses the same test message.
///
/// On success:  200 {"ok": true}
/// On failure:  200 {"ok": false, "error": "<error name>"}
///
/// We return 200 on failure (not 500) because the typical failure
/// mode is "notify-send is not installed" — a 500 would make the
/// frontend think the backend is broken. The `ok: false` payload
/// gives the UI enough info to show a helpful hint.
pub fn notifyTestHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = req;
    const allocator = ctx.allocator;
    const io = ctx.io;

    notifications.notify(io, allocator, "pabrik notification test", "If you can read this, OS notifications work.") catch |err| {
        const err_msg = @errorName(err);
        const data = std.fmt.allocPrint(allocator, "{{\"ok\":false,\"error\":\"{s}\"}}", .{err_msg}) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
            });
        };
        return res.jsonResponse(.{ .status_code = 200, .data = data });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = "{\"ok\":true}" });
}

// ===== Tests merged from llm_test.zig (2026-09-29 flatten) =====

// HTTP handler + use-case for `POST /api/llm/test`.
//
// Purpose: let the user click "Test" inside the Add/Edit profile modal
// and verify their model + base_url + api_key + url_style actually work
// BEFORE they click Save. The existing flow only validates locally
// (name/model non-empty) and persists via `PUT /api/config/pabrik`, so a
// typo'd base_url or revoked key would only surface mid-workflow.
//
// This endpoint is INERT: it does NOT touch `config.json` or the DB —
// it fires ONE minimal non-streaming chat call against the candidate
// `base_url` and reports the result.
//
// Wire (request):
// ```json
// {
//   "model": "MiniMax-M2.7",
//   "base_url": "https://api.minimax.io/v1/chat/completions",
//   "api_key": "sk-...",
//   "url_style": "openai"
// }
// ```
// `url_style` is one of `"openai" | "openai-response" | "anthropic"`
// (defaults to `"openai"`). Unknown styles are rejected with a clear
// error — the frontend only sends the three known values.
//
// Wire (response): `{"ok": true, "model": "...", "reply": "ok",
// "latency_ms": 123}` on success; `{"ok": false, "error": "...",
// "details": "..."}` on failure. Both paths return HTTP 200 (matches
// the MCP probe / notify probe — the endpoint is a probe, and the
// modal wants to render the error inline, not as a 500).
//
// Probe bodies (minimal, non-streaming, no tools):
//   - openai:          `{"model","messages":[{"role":"user","content":
//                        "Reply with exactly: ok"}],"max_tokens":16,
//                        "temperature":0,"stream":false}`
//   - openai-response: `{"model","input":"Reply with exactly: ok",
//                        "max_output_tokens":16,"stream":false,
//                        "store":false}`
//   - anthropic:       `{"model","max_tokens":16,"messages":[{"role":
//                        "user","content":"Reply with exactly: ok"}]}`
//
// Auth: `openai*` styles send `Authorization: Bearer <api_key>`;
// `anthropic` sends `x-api-key: <api_key>` + `anthropic-version:
// 2023-06-01`. An EMPTY api_key is allowed (local Ollama-style
// endpoints, stub upstreams in tests) — the auth header is simply
// omitted in that case.
//
// Session: every probe sends `x-opencode-session: pabrik-llm-test-probe`
// so Console Go / OpenCode Zen gateways can route it. Without the
// header the gateway rejects the probe with 400
// `{"type":"error","error":{"type":"MissingSessionID",...}}` — the
// exact failure in the Edit-profile Test button for `url_style:
// "anthropic"`. The value is a fixed probe id (not a real
// conversation); extra headers are ignored by direct providers
// (OpenAI / Ollama / MiniMax), matching how `Agent.callStreaming`
// only omits the header when `sessionId` is empty.
//
// **Timeout model**: `custom_http_client`'s `timeout_ms` (libcurl
// handles cancellation at the OS level), 15s per probe.

// kabelweb is the unified web-framework package imported
// directly via `@import("kabelweb").client` (see root.zig:509),
// not a member of `pabrikcore`.
const custom_http_client = @import("kabelweb").client;
const helpers = @import("helpers");

/// Per-call deadline for the probe (libcurl has OS-level timeout
/// support). Generous vs the MCP 10s probe because LLM inference —
/// even for 16 tokens — routinely takes several seconds on a cold
/// model, and a premature timeout would read as "your key is broken".
const TEST_LLM_TIMEOUT_MS: u32 = 15_000;

/// The probe prompt. Short + deterministic so the modal can show the
/// reply verbatim as proof the model answered.
const PROBE_PROMPT: []const u8 = "Reply with exactly: ok";

/// Max reply bytes carried on the wire. The probe asks for 16 tokens;
/// 200 bytes is plenty and keeps the modal payload small.
const MAX_REPLY_LEN: usize = 200;

/// Stable session id sent as `x-opencode-session` on every Test probe.
/// Console Go / OpenCode Zen gateways require the header for routing
/// and prompt caching — see https://opencode.ai/docs/go/#where-can-i-use-it
/// and `Agent.sessionId`. The probe has no real conversation, so a fixed
/// id is enough to satisfy the gateway; direct providers ignore it.
const PROBE_SESSION_ID: []const u8 = "pabrik-llm-test-probe";

/// Candidate profile fields. Mirrors the frontend's `LlmTestRequest`
/// shape in `src/apps/desktop/src/api/index.ts`. Extra fields sent by
/// the form (thinking, temperature, ...) are ignored — the probe uses
/// fixed minimal values.
const LlmTestRequest = struct {
    model: []const u8 = "",
    base_url: []const u8 = "",
    api_key: []const u8 = "",
    url_style: []const u8 = "openai",
};

// ─── Error mapping ──────────────────────────────────────────────────────────

const LlmTestError = error{
    MissingModel,
    MissingBaseUrl,
    InvalidBaseUrl,
    UnsupportedStyle,
    SendFailed,
    Timeout,
    HttpError,
    JsonParseFailed,
    InvalidResponse,
    OutOfMemory,
};

const LlmTestOutcome = struct {
    model: []const u8,
    reply: []const u8,
    latency_ms: i64,
};

// ─── Pure helpers (unit-testable, no network) ───────────────────────────────

/// Validate the candidate without touching the network. Empty api_key
/// is ALLOWED (keyless local endpoints + stub upstreams in tests).
fn llmTestValidate(req: LlmTestRequest) LlmTestError!void {
    if (req.model.len == 0) return LlmTestError.MissingModel;
    if (req.base_url.len == 0) return LlmTestError.MissingBaseUrl;
    const has_http_scheme = std.mem.startsWith(u8, req.base_url, "http://") or
        std.mem.startsWith(u8, req.base_url, "https://");
    if (!has_http_scheme) return LlmTestError.InvalidBaseUrl;
    if (!(std.mem.eql(u8, req.url_style, "openai") or
        std.mem.eql(u8, req.url_style, "openai-response") or
        std.mem.eql(u8, req.url_style, "anthropic")))
        return LlmTestError.UnsupportedStyle;
}

/// Build the minimal probe body for the request's url_style. Caller
/// owns the returned slice.
fn llmTestBuildProbeBody(allocator: std.mem.Allocator, req: LlmTestRequest) LlmTestError![]u8 {
    if (std.mem.eql(u8, req.url_style, "anthropic")) {
        return std.fmt.allocPrint(
            allocator,
            "{{\"model\":{f},\"max_tokens\":16,\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}]}}",
            .{ std.json.fmt(req.model, .{}), PROBE_PROMPT },
        ) catch return LlmTestError.OutOfMemory;
    }
    if (std.mem.eql(u8, req.url_style, "openai-response")) {
        return std.fmt.allocPrint(
            allocator,
            "{{\"model\":{f},\"input\":\"{s}\",\"max_output_tokens\":16,\"stream\":false,\"store\":false}}",
            .{ std.json.fmt(req.model, .{}), PROBE_PROMPT },
        ) catch return LlmTestError.OutOfMemory;
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"model\":{f},\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}],\"max_tokens\":16,\"temperature\":0,\"stream\":false}}",
        .{ std.json.fmt(req.model, .{}), PROBE_PROMPT },
    ) catch return LlmTestError.OutOfMemory;
}

/// Extract the assistant reply text from a probe response body, per
/// url_style. Returns an owned slice truncated to MAX_REPLY_LEN.
fn llmTestExtractReply(
    allocator: std.mem.Allocator,
    url_style: []const u8,
    body: []const u8,
) LlmTestError![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return LlmTestError.JsonParseFailed;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return LlmTestError.InvalidResponse,
    };

    var reply: ?[]const u8 = null;
    if (std.mem.eql(u8, url_style, "anthropic")) {
        // `{"content": [{"type": "text", "text": "..."}]}`
        const content_v = root.get("content") orelse return LlmTestError.InvalidResponse;
        const blocks = switch (content_v) {
            .array => |a| a,
            else => return LlmTestError.InvalidResponse,
        };
        for (blocks.items) |block| {
            const obj = switch (block) {
                .object => |o| o,
                else => continue,
            };
            const t = obj.get("type") orelse continue;
            if (!std.mem.eql(u8, t.string, "text")) continue;
            const text_v = obj.get("text") orelse continue;
            reply = switch (text_v) {
                .string => |s| s,
                else => continue,
            };
            break;
        }
    } else if (std.mem.eql(u8, url_style, "openai-response")) {
        // `{"output": [{"type": "message", "content":
        // [{"type": "output_text", "text": "..."}]}]}`
        const output_v = root.get("output") orelse return LlmTestError.InvalidResponse;
        const items = switch (output_v) {
            .array => |a| a,
            else => return LlmTestError.InvalidResponse,
        };
        outer: for (items.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const content_v = obj.get("content") orelse continue;
            const parts = switch (content_v) {
                .array => |a| a,
                else => continue,
            };
            for (parts.items) |part| {
                const pobj = switch (part) {
                    .object => |o| o,
                    else => continue,
                };
                const t = pobj.get("type") orelse continue;
                if (!std.mem.eql(u8, t.string, "output_text")) continue;
                const text_v = pobj.get("text") orelse continue;
                reply = switch (text_v) {
                    .string => |s| s,
                    else => continue,
                };
                break :outer;
            }
        }
    } else {
        // `{"choices": [{"message": {"content": "..."}}]}`
        const choices_v = root.get("choices") orelse return LlmTestError.InvalidResponse;
        const choices = switch (choices_v) {
            .array => |a| a,
            else => return LlmTestError.InvalidResponse,
        };
        if (choices.items.len == 0) return LlmTestError.InvalidResponse;
        const first = switch (choices.items[0]) {
            .object => |o| o,
            else => return LlmTestError.InvalidResponse,
        };
        const msg_v = first.get("message") orelse return LlmTestError.InvalidResponse;
        const msg = switch (msg_v) {
            .object => |o| o,
            else => return LlmTestError.InvalidResponse,
        };
        const content_v = msg.get("content") orelse return LlmTestError.InvalidResponse;
        reply = switch (content_v) {
            .string => |s| s,
            else => return LlmTestError.InvalidResponse,
        };
    }

    const text = reply orelse return LlmTestError.InvalidResponse;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const capped = trimmed[0..@min(trimmed.len, MAX_REPLY_LEN)];
    return allocator.dupe(u8, capped) catch return LlmTestError.OutOfMemory;
}

// ─── Use-case (network) ─────────────────────────────────────────────────────

fn llmTestUseCase(
    allocator: std.mem.Allocator,
    logger: *loggermod.Logger,
    req: LlmTestRequest,
    out_err_detail: *?[]const u8,
) LlmTestError!LlmTestOutcome {
    try llmTestValidate(req);

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();

    const body = try llmTestBuildProbeBody(allocator, req);
    defer allocator.free(body);

    // Auth header buffer: only the Bearer/x-api-key value is owned;
    // names + static values are string literals.
    var auth_value: ?[]u8 = null;
    defer if (auth_value) |v| allocator.free(v);

    var header_buf: [8]custom_http_client.Header = undefined;
    var header_count: usize = 0;
    header_buf[header_count] = .{ .name = "Content-Type", .value = "application/json" };
    header_count += 1;
    if (std.mem.eql(u8, req.url_style, "anthropic")) {
        header_buf[header_count] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        header_count += 1;
        if (req.api_key.len > 0) {
            header_buf[header_count] = .{ .name = "x-api-key", .value = req.api_key };
            header_count += 1;
        }
    } else if (req.api_key.len > 0) {
        auth_value = std.fmt.allocPrint(allocator, "Bearer {s}", .{req.api_key}) catch
            return LlmTestError.OutOfMemory;
        header_buf[header_count] = .{ .name = "Authorization", .value = auth_value.? };
        header_count += 1;
    }
    // Console Go / Zen routing requires `x-opencode-session` on every
    // request (see PROBE_SESSION_ID). The chat path sends the real
    // conversation id via `Agent.sessionId`; the probe has none, so it
    // sends the fixed probe id. Harmless for direct providers.
    header_buf[header_count] = .{ .name = "x-opencode-session", .value = PROBE_SESSION_ID };
    header_count += 1;

    const start_ns = helpers.monotonicTimestampNanos();
    const result = custom_http_client.post(
        &client,
        req.base_url,
        body,
        header_buf[0..header_count],
        .{ .timeout_ms = TEST_LLM_TIMEOUT_MS },
    ) catch |err| {
        logger.warnFmt("[llm_test] probe POST failed for '{s}': {s}", .{ req.base_url, @errorName(err) });
        if (err == error.Timeout) return LlmTestError.Timeout;
        return LlmTestError.SendFailed;
    };
    defer result.deinit(allocator);
    const latency_ms: i64 = @intCast((helpers.monotonicTimestampNanos() - start_ns) / std.time.ns_per_ms);

    if (result.status_code != 200) {
        logger.warnFmt("[llm_test] upstream returned status {d}", .{result.status_code});
        // Surface the server's error body (e.g. 401 `{"error": ...}`)
        // so the modal shows WHY instead of a generic message.
        // Truncated to 200 bytes to keep the wire small.
        const snippet_len: usize = @min(result.body.len, 200);
        out_err_detail.* = std.fmt.allocPrint(
            allocator,
            "http {d}: {s}",
            .{ result.status_code, result.body[0..snippet_len] },
        ) catch null;
        return LlmTestError.HttpError;
    }

    const reply = llmTestExtractReply(allocator, req.url_style, result.body) catch |err| {
        logger.warnFmt("[llm_test] reply parse failed: {s}", .{@errorName(err)});
        if (err == error.JsonParseFailed) return LlmTestError.JsonParseFailed;
        // Include a body snippet so a wrong-style success (e.g. HTML
        // login page from a bad base_url) is diagnosable.
        const snippet_len: usize = @min(result.body.len, 200);
        out_err_detail.* = std.fmt.allocPrint(
            allocator,
            "unparseable body: {s}",
            .{result.body[0..snippet_len]},
        ) catch null;
        return LlmTestError.InvalidResponse;
    };

    return .{
        .model = req.model,
        .reply = reply,
        .latency_ms = latency_ms,
    };
}

// ─── Handler ────────────────────────────────────────────────────────────────

pub fn llmTestHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }),
        });
    };
    const logger = di.logger;

    const parsed = std.json.parseFromSliceLeaky(LlmTestRequest, allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"invalid JSON body\"}}", .{}),
        });
    };

    var err_detail: ?[]const u8 = null;
    defer if (err_detail) |d| allocator.free(d);
    const outcome = llmTestUseCase(allocator, logger, parsed, &err_detail) catch |err| {
        const message: []const u8 = switch (err) {
            error.MissingModel => "model is required",
            error.MissingBaseUrl => "base_url is required",
            error.InvalidBaseUrl => "base_url must start with http:// or https://",
            error.UnsupportedStyle => "url_style must be 'openai', 'openai-response' or 'anthropic'",
            error.SendFailed => "failed to reach the LLM server (check base_url)",
            error.Timeout => "LLM server did not respond within 15 seconds",
            error.HttpError => "LLM server returned an error status",
            error.JsonParseFailed => "LLM server response was not valid JSON",
            error.InvalidResponse => "LLM server response did not contain a reply",
            error.OutOfMemory => "out of memory",
        };
        const details: []const u8 = err_detail orelse @errorName(err);
        std.log.warn("[llm_test] error: {s} ({s})", .{ message, details });
        const data = std.fmt.allocPrint(
            allocator,
            "{{\"ok\":false,\"error\":{f},\"details\":{f}}}",
            .{ std.json.fmt(message, .{}), std.json.fmt(details, .{}) },
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
            });
        };
        return res.jsonResponse(.{ .status_code = 200, .data = data });
    };
    defer allocator.free(outcome.reply);

    const data = std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"model\":{f},\"reply\":{f},\"latency_ms\":{d}}}",
        .{ std.json.fmt(outcome.model, .{}), std.json.fmt(outcome.reply, .{}), outcome.latency_ms },
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Inline tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "llm_test validate: rejects empty model" {
    const req: LlmTestRequest = .{ .model = "", .base_url = "http://127.0.0.1:9/x" };
    try testing.expectError(LlmTestError.MissingModel, llmTestValidate(req));
}

test "llm_test validate: rejects empty base_url" {
    const req: LlmTestRequest = .{ .model = "m", .base_url = "" };
    try testing.expectError(LlmTestError.MissingBaseUrl, llmTestValidate(req));
}

test "llm_test validate: rejects base_url without http scheme" {
    const req: LlmTestRequest = .{ .model = "m", .base_url = "api.example.com/v1" };
    try testing.expectError(LlmTestError.InvalidBaseUrl, llmTestValidate(req));
}

test "llm_test validate: rejects unknown url_style" {
    const req: LlmTestRequest = .{ .model = "m", .base_url = "http://127.0.0.1:9/x", .url_style = "weird" };
    try testing.expectError(LlmTestError.UnsupportedStyle, llmTestValidate(req));
}

test "llm_test validate: allows empty api_key (keyless local / stub upstream)" {
    const req: LlmTestRequest = .{ .model = "m", .base_url = "http://127.0.0.1:9/x", .api_key = "" };
    try llmTestValidate(req);
}

test "llm_test validate: accepts all three known styles" {
    for ([_][]const u8{ "openai", "openai-response", "anthropic" }) |style| {
        const req: LlmTestRequest = .{ .model = "m", .base_url = "http://127.0.0.1:9/x", .url_style = style };
        try llmTestValidate(req);
    }
}

test "llm_test buildProbeBody: openai body carries model + probe prompt" {
    const req: LlmTestRequest = .{ .model = "MiniMax-M2.7", .base_url = "http://x", .url_style = "openai" };
    const body = try llmTestBuildProbeBody(testing.allocator, req);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "MiniMax-M2.7") != null);
    try testing.expect(std.mem.indexOf(u8, body, PROBE_PROMPT) != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
}

test "llm_test buildProbeBody: openai-response body uses input + max_output_tokens" {
    const req: LlmTestRequest = .{ .model = "gpt-5", .base_url = "http://x", .url_style = "openai-response" };
    const body = try llmTestBuildProbeBody(testing.allocator, req);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"input\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "max_output_tokens") != null);
}

test "llm_test buildProbeBody: anthropic body uses max_tokens + messages" {
    const req: LlmTestRequest = .{ .model = "claude-x", .base_url = "http://x", .url_style = "anthropic" };
    const body = try llmTestBuildProbeBody(testing.allocator, req);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":16") != null);
    try testing.expect(std.mem.indexOf(u8, body, PROBE_PROMPT) != null);
}

test "llm_test extractReply: parses openai choices content" {
    const raw =
        \\{"id":"chatcmpl-1","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}
    ;
    const reply = try llmTestExtractReply(testing.allocator, "openai", raw);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("ok", reply);
}

test "llm_test extractReply: parses anthropic content blocks" {
    const raw =
        \\{"id":"msg_1","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}
    ;
    const reply = try llmTestExtractReply(testing.allocator, "anthropic", raw);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("ok", reply);
}

test "llm_test extractReply: parses openai-response output items" {
    const raw =
        \\{"id":"resp_1","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}
    ;
    const reply = try llmTestExtractReply(testing.allocator, "openai-response", raw);
    defer testing.allocator.free(reply);
    try testing.expectEqualStrings("ok", reply);
}

test "llm_test extractReply: rejects empty choices" {
    const raw =
        \\{"choices":[]}
    ;
    try testing.expectError(LlmTestError.InvalidResponse, llmTestExtractReply(testing.allocator, "openai", raw));
}

test "llm_test extractReply: rejects non-JSON body" {
    try testing.expectError(
        LlmTestError.JsonParseFailed,
        llmTestExtractReply(testing.allocator, "openai", "<html>login</html>"),
    );
}

// ===== Tests merged from mcp_test.zig (2026-09-29 flatten) =====
// `POST /api/mcp/test` — try a candidate MCP server config WITHOUT saving.
//
// Purpose: let the user click "Test" inside the Add/Edit MCP server modal
// and verify their command + args + env + cwd (or URL + headers for the
// HTTP transport) actually work BEFORE they click Save. The existing
// flow only validates the config on disk at agent-loop time, which means
// a typo'd command or wrong path would only surface mid-workflow.
//
// This endpoint is INERT in the sense that it does NOT touch
// `config.json` or the DB — it just spawns the candidate child / fires
// the candidate HTTP request once and reports the result. Successful
// calls also leave the spawned child in the `StdioRegistry` cache
// keyed by a per-call preview name (so a subsequent Save with the same
// `server_name` reuses it, which is fine and matches the existing
// registry semantics).
//
// **Timeout model**: HTTP probes use `custom_http_client`'s
// `timeout_ms` (libcurl handles cancellation at the OS level).
// stdio probes have a 10s deadline (see `TEST_STDIO_TIMEOUT_MS`),
// implemented via the deadline plumbing in `mcp_stdio.StdioClient`
// (plan 2026-08-28-fix-mcp-stdio-blocking). On deadline, the recv
// returns `StdioError.RecvTimeout` and the preview entry is marked
// stale so the next /api/mcp/test doesn't reuse the hung child.
// `2026-08-28-fix-mcp-stdio-blocking` plan.
//
// Wire (request):
// ```json
// {
//   "transport": "stdio",
//   "command": "mcp-hello-world",
//   "args": ["--name", "alpha"],
//   "env": ["NODE_ENV=production"],
//   "cwd": "/abs/path"
// }
// ```
// OR
// ```json
// {
//   "transport": "http",
//   "url": "https://mcp.contextcontext.com://mcp",
//   "headers": {"X-Token": "secret"}
// }
// ```
//
// Wire (response): `{"ok": true, "transport": "...", "tools": [{"name", "description"}]}`
// on success; `{"ok": false, "error": "...", "details": "..."}` on failure.
// Both paths return HTTP 200 (matches the OS-notification probe's pattern — the
// endpoint is a probe, not a state mutation, and the user's UI wants
// to render the error message inline, not as a 500).

const builtin = @import("builtin");
const mcp_stdio = pabrikcore.mcp_stdio;
const tool_models = pabrikcore.tool_models;

/// Per-call deadline for HTTP probes (libcurl has OS-level timeout
/// support). See the "Timeout model" comment at the top.
const TEST_HTTP_TIMEOUT_MS: u32 = 10_000;

/// Per-call deadline for stdio probes (mcp_stdio.zig polls this
/// between bytes read). Tight enough to fail fast for the user
/// without burning a long test budget; long enough to absorb
/// slow process spawn + IPC roundtrip on a busy host.
const TEST_STDIO_TIMEOUT_MS: u64 = 10_000;

/// Maximum attempts for the stdio probe. The first attempt covers
/// the happy path; the retries handle the cold-start race where
/// `process.spawn` returns BEFORE the child (sh wrapper → exec
/// node → SDK connect → `_stdin.on('data', ...)`) has attached its
/// stdin listener. On macOS the race window is wider than on Linux;
/// on slow CI runners (Linux, Windows, macOS) the SDK bootstrap
/// can occasionally take longer than the inter-attempt sleep, so
/// each spawn has the race independently. Twenty covers the
/// observed ~once-per-100-runs CI failure rate on all three
/// platforms. Worst-case latency:
///   ~10s (first attempt) + 19 * (500ms sleep + 1s deadline) ≈ 38.5s.
/// On the happy path the first attempt succeeds in ~50ms so the
/// retry loop never executes.
const TEST_STDIO_MAX_ATTEMPTS: u8 = 20;

/// Sleep between cold-start retries. 500 ms gives the SDK enough
/// time to finish `mcp.connect(transport)` + attach its `'data'`
/// listener on the fresh spawn; small enough that the worst-case
/// user latency is ~2s (cold spawn + 500ms sleep + 4 retries),
/// well inside the 10s deadline budget.
const TEST_STDIO_RETRY_DELAY_MS: i64 = 500;

/// Tagged request body. Mirrors the frontend's `McpServerModalValue`
/// shape minus the `name` field (we don't persist anything here).
const McpTestRequest = struct {
    transport: []const u8 = "",
    /// stdio-only fields
    command: []const u8 = "",
    args: ?[]const []const u8 = null,
    env: ?[]const []const u8 = null,
    cwd: []const u8 = "",
    /// http-only fields
    url: []const u8 = "",
    headers: ?std.json.Value = null,
};

// ─── Error mapping ──────────────────────────────────────────────────────────

const McpTestError = error{
    MissingTransport,
    UnsupportedTransport,
    MissingCommand,
    MissingUrl,
    SpawnFailed,
    SendFailed,
    RecvFailed,
    Timeout,
    JsonParseFailed,
    InvalidResponse,
    OutOfMemory,
};

// ─── Use case ──────────────────────────────────────────────────────────────

const McpToolPreview = struct {
    name: []const u8,
    description: []const u8,
};

const McpTestOutcome = struct {
    transport: []const u8,
    tools: []const McpToolPreview,
};

/// Try a single MCP server candidate. Returns either the parsed
/// tools (on success) or a `McpTestError`. On error, `out_err_detail`
/// (if non-null) is set to a heap-allocated slice with the concrete
/// underlying error name (e.g. "UnexpectedEof") — useful for
/// surfacing in the response body without making the user dig
/// through server logs. Pure function — does NOT write to disk/DB.
fn mcpTestUseCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: *loggermod.Logger,
    req: McpTestRequest,
    out_err_detail: *?[]const u8,
) McpTestError!McpTestOutcome {
    // Transport dispatch.
    if (std.mem.eql(u8, req.transport, "stdio")) {
        return mcpTestStdio(allocator, io, logger, req, out_err_detail);
    } else if (std.mem.eql(u8, req.transport, "http")) {
        return mcpTestHttp(allocator, io, logger, req, out_err_detail);
    } else if (req.transport.len == 0) {
        return McpTestError.MissingTransport;
    } else {
        return McpTestError.UnsupportedTransport;
    }
}

// ─── stdio ────────────────────────────────────────────────────────────────

/// Try a stdio candidate: spawn the child, send `tools/list` as
/// raw NDJSON, parse the response.
///
/// **Deadline**: 10s via `TEST_STDIO_TIMEOUT_MS`, plumbed into
/// `client.recv(deadline_ns, null)`. A hung child returns
/// `StdioError.RecvTimeout` instead of blocking the handler; the
/// preview entry is marked stale so the next test doesn't reuse
/// the dead client. See plan 2026-08-28-fix-mcp-stdio-blocking.
fn mcpTestStdio(
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: *loggermod.Logger,
    req: McpTestRequest,
    out_err_detail: *?[]const u8,
) McpTestError!McpTestOutcome {
    if (req.command.len == 0) return McpTestError.MissingCommand;

    // Build argv from request fields.
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, try allocator.dupe(u8, req.command));
    if (req.args) |a| {
        for (a) |arg| {
            try argv_list.append(allocator, try allocator.dupe(u8, arg));
        }
    }
    const argv = try argv_list.toOwnedSlice(allocator);
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }

    // Stable preview name per config (hash of command + args). Keeps
    // the spawned child distinct from the user's eventual Save'd name,
    // but STABLE across consecutive Tests so the second click reuses
    // the same cached child instead of spawning a new Python process
    // (each holding the 9.4MB graph) and leaking the old one.
    // Previously this used a timestamp (new entry per click, never
    // cleaned up) — first Test worked, second Test spawned a second
    // child while the first was still alive → OOM/FD exhaustion → SEGV.
    const preview_name = blk: {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(req.command);
        if (req.args) |a| {
            for (a) |arg| {
                hasher.update(arg);
                hasher.update("|");
            }
        }
        if (req.cwd.len > 0) hasher.update(req.cwd);
        const h = hasher.final();
        break :blk std.fmt.allocPrint(
            allocator,
            "__mcp_test_preview_{x}",
            .{h},
        ) catch return McpTestError.OutOfMemory;
    };
    defer allocator.free(preview_name);

    // Via the singleton struct (see root.zig `mcpStdioRegistry`).
    const reg = pabrikcore.mcpStdioRegistry(allocator);

    // Build the MCP handshake + tools/list bodies once. The SDK
    // expects line-delimited JSON on stdin.
    //
    // Wire sequence (per MCP spec):
    //   1. `initialize` request  → server responds with capabilities
    //   2. `initialized` notification (no response expected)
    //   3. `tools/list` request  → server responds with tool list
    //
    // We use the proper handshake because on slow CI runners the
    // SDK's stdio bootstrap sometimes fails to attach the `'data'`
    // listener before the request is processed, surfacing as
    // UnexpectedEof. The handshake doubles the wire roundtrips but
    // makes the first read a guaranteed probe: if `initialize`
    // returns a response, the SDK is alive and `tools/list` will
    // succeed; if `initialize` returns EOF, the SDK is dead and we
    // retry with a fresh spawn.
    const init_body = std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"pabrik-mcp-test\",\"version\":\"0.0.1\"}}}}}}\n",
        .{},
    ) catch return McpTestError.OutOfMemory;
    defer allocator.free(init_body);
    const initialized_body = std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}}\n",
        .{},
    ) catch return McpTestError.OutOfMemory;
    defer allocator.free(initialized_body);
    const tools_list_body = std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"2\",\"method\":\"tools/list\",\"params\":{{}}}}\n",
        .{},
    ) catch return McpTestError.OutOfMemory;
    defer allocator.free(tools_list_body);

    // Cold-start race retry: CI (macOS, Linux, Windows) sees
    // intermittent `UnexpectedEof` because `process.spawn` returns
    // BEFORE the child (sh wrapper → exec node → SDK connect →
    // attach `_stdin.on('data')`) has finished bootstrapping. The
    // request sits in the kernel pipe buffer unread, the SDK never
    // sees it, and our deadline fires on an empty stdout → EOF.
    //
    // Twenty attempts covers the observed CI failure rate (every
    // spawn has the race independently; we need enough attempts to
    // land on a runner moment where the SDK bootstrap succeeds).
    //
    // Per-attempt deadline: 10s on the first attempt (covers normal
    // cold start), 1s on retries (SDK bootstrap is done by now).
    // Worst-case latency:
    //   ~10s + 19 × (500ms sleep + 1s deadline) ≈ 38.5s.
    //
    // Diagnostic capture: each attempt's stderr is drained
    // (non-blocking) so when the test fails the response body
    // includes the SDK's actual error message. CI runners swallow
    // server stderr; we surface it through the JSON wire.
    //
    // Storage: `stderrs_buf[i]` holds heap-allocated slices from
    // drainStderr (the @errorName(err) case uses allocator.dupe too,
    // so the buffer is uniformly heap-allocated). `freeStderrs`
    // releases them before the diagnostic string is copied into
    // `out_err_detail` (which is allocated via the mcpTestStdio
    // allocator param and freed by the caller).
    var attempts_codes: [20 * 8]u8 = undefined;
    var stderrs_buf: [20][]const u8 = .{""} ** 20;
    var attempts_used: usize = 0;

    // `recordAttempt` appends the attempt's outcome to the diagnostic
    // buffers. Called from each `catch` block; heap-allocates the
    // stderr slice if drainStderr captured any bytes.
    // Helper to append one attempt's outcome to the diagnostic
    // buffers. Returns false if the buffer is full (20 cap).
    const freeStderrs = struct {
        fn call(a: std.mem.Allocator, stderrs: []const []const u8, count: usize) void {
            for (stderrs[0..count]) |s| a.free(s);
        }
    }.call;

    var attempt: u8 = 1;
    while (true) : (attempt += 1) {
        // One lease per attempt, taken for the whole request/response
        // transaction so a concurrent session can't drive the same
        // child while we're mid-frame. The `defer` is scoped to the
        // loop body, so it runs on every exit from this attempt —
        // `return` on a hard failure AND `continue` on a retry.
        var lease = reg.acquire(preview_name, argv, .{}) catch |err| {
            logger.warnFmt("[mcp_test] stdio spawn failed for command '{s}': {s}", .{ req.command, @errorName(err) });
            const msg = std.fmt.allocPrint(allocator, "spawn:{s}", .{@errorName(err)}) catch null;
            freeStderrs(allocator, &stderrs_buf, attempts_used);
            out_err_detail.* = msg;
            return McpTestError.SpawnFailed;
        };
        defer lease.release();
        const client = lease.client();

        const stdin_file = client.stdin orelse {
            freeStderrs(allocator, &stderrs_buf, attempts_used);
            out_err_detail.* = std.fmt.allocPrint(allocator, "no_stdin", .{}) catch null;
            return McpTestError.SendFailed;
        };

        // Send ONLY `initialize` first. The MCP handshake is ordered:
        // client sends `initialize`, the server replies, and only THEN
        // may the client send `notifications/initialized` and issue
        // requests like `tools/list`. Pipelining all three lines into
        // one write (as this did) hands the SDK a `tools/list` request
        // that is already in the pipe buffer before it has finished
        // initializing — the SDK then drops it rather than answering,
        // and our reader waits out the full deadline on a response that
        // is never coming. Because every retry replayed the same
        // out-of-order sequence, the 19 remaining attempts could not
        // rescue it either.
        std.Io.File.writeStreamingAll(stdin_file, io, init_body) catch |err| {
            logger.warnFmt("[mcp_test] stdio send failed: {s}", .{@errorName(err)});
            if (attempts_used < 20) {
                const stderr_dup = allocator.dupe(u8, @errorName(err)) catch
                    allocator.dupe(u8, "OOM") catch unreachable;
                @memcpy(attempts_codes[attempts_used * 8 ..][0..2], "SF");
                @memset(attempts_codes[attempts_used * 8 + 2 ..][0..6], ' ');
                stderrs_buf[attempts_used] = stderr_dup;
                attempts_used += 1;
            }
            if (attempt >= TEST_STDIO_MAX_ATTEMPTS or err != error.SendFailed) {
                lease.markStale();
                const detail = formatAttemptsDetail(
                    allocator,
                    @errorName(err),
                    attempts_used,
                    &attempts_codes,
                    &stderrs_buf,
                ) catch null;
                freeStderrs(allocator, &stderrs_buf, attempts_used);
                out_err_detail.* = detail;
                return McpTestError.SendFailed;
            }
            lease.markStale();
            // Hand the child back before the backoff: `defer` alone
            // would keep the per-server lease for the whole sleep.
            lease.release();
            std.Io.Clock.Duration.sleep(
                .{ .raw = std.Io.Duration.fromMilliseconds(TEST_STDIO_RETRY_DELAY_MS), .clock = .real },
                io,
            ) catch {};
            continue;
        };

        // Read the initialize response (1st response). If we get
        // EOF, the SDK is dead → cold-start race → retry.
        const init_deadline_ns: u64 = if (attempt == 1)
            TEST_STDIO_TIMEOUT_MS * std.time.ns_per_ms
        else
            1_000 * std.time.ns_per_ms;
        const init_resp = client.recv(init_deadline_ns, null) catch |err| {
            if (attempts_used < 20) {
                const code: []const u8 = switch (err) {
                    error.UnexpectedEof => "EOF",
                    error.RecvTimeout => "TO",
                    else => "ERR",
                };
                const stderr_msg = drainStderr(allocator, io, client.stderr);
                @memcpy(attempts_codes[attempts_used * 8 ..][0..code.len], code);
                @memset(attempts_codes[attempts_used * 8 + code.len ..][0 .. 8 - code.len], ' ');
                stderrs_buf[attempts_used] = stderr_msg;
                attempts_used += 1;
            }
            if (attempt >= TEST_STDIO_MAX_ATTEMPTS or err != error.UnexpectedEof) {
                lease.markStale();
                const detail = formatAttemptsDetail(
                    allocator,
                    @errorName(err),
                    attempts_used,
                    &attempts_codes,
                    &stderrs_buf,
                ) catch null;
                freeStderrs(allocator, &stderrs_buf, attempts_used);
                out_err_detail.* = detail;
                // Silent-but-alive child (e.g. bare `python` with empty
                // args, waiting on stdin for EOF): it started fine but
                // never answered `initialize`. Report `Timeout` so the
                // modal shows "did not respond within 10 seconds"
                // instead of the generic receive-failure text — the
                // user almost certainly forgot the server's arguments.
                // Still `markStale`d above (next probe respawns) and
                // still HTTP 200 + `{ok:false}` (no backend crash).
                if (err == error.RecvTimeout) return McpTestError.Timeout;
                return McpTestError.RecvFailed;
            }
            logger.warnFmt(
                "[mcp_test] stdio initialize got {s} on attempt {d}/{d} — likely cold-start race; retrying",
                .{ @errorName(err), attempt, TEST_STDIO_MAX_ATTEMPTS },
            );
            lease.markStale();
            // Hand the child back before the backoff: `defer` alone
            // would keep the per-server lease for the whole sleep.
            lease.release();
            std.Io.Clock.Duration.sleep(
                .{ .raw = std.Io.Duration.fromMilliseconds(TEST_STDIO_RETRY_DELAY_MS), .clock = .real },
                io,
            ) catch {};
            continue;
        };
        // NOTE: no `defer free` — inside `while(true)`, defer runs at
        // function exit. Free explicitly on every path below.

        // The server has answered `initialize`, so the session is live.
        // NOW send `notifications/initialized` followed by the
        // `tools/list` request. These two ARE safe to batch — the
        // notification is what puts the SDK into its initialized state,
        // and the SDK processes stdin in order, so the request that
        // follows it is handled against a connected transport.
        const post_init_payload = std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ initialized_body, tools_list_body },
        ) catch {
            freeStderrs(allocator, &stderrs_buf, attempts_used);
            allocator.free(init_resp);
            return McpTestError.OutOfMemory;
        };
        // No `defer` — this is inside `while(true)`, so free explicitly
        // on every path below (success, error-return).
        std.Io.File.writeStreamingAll(stdin_file, io, post_init_payload) catch |err| {
            logger.warnFmt(
                "[mcp_test] stdio post-init send failed: {s}",
                .{@errorName(err)},
            );
            if (attempts_used < 20) {
                const stderr_dup = allocator.dupe(u8, @errorName(err)) catch
                    allocator.dupe(u8, "OOM") catch unreachable;
                @memcpy(attempts_codes[attempts_used * 8 ..][0..2], "SF");
                @memset(attempts_codes[attempts_used * 8 + 2 ..][0..6], ' ');
                stderrs_buf[attempts_used] = stderr_dup;
                attempts_used += 1;
            }
            if (attempt >= TEST_STDIO_MAX_ATTEMPTS or err != error.SendFailed) {
                lease.markStale();
                const detail = formatAttemptsDetail(
                    allocator,
                    @errorName(err),
                    attempts_used,
                    &attempts_codes,
                    &stderrs_buf,
                ) catch null;
                freeStderrs(allocator, &stderrs_buf, attempts_used);
                out_err_detail.* = detail;
                allocator.free(post_init_payload);
                allocator.free(init_resp);
                return McpTestError.SendFailed;
            }
            lease.markStale();
            // Hand the child back before the backoff: `defer` alone
            // would keep the per-server lease for the whole sleep.
            lease.release();
            allocator.free(post_init_payload);
            allocator.free(init_resp);
            std.Io.Clock.Duration.sleep(
                .{ .raw = std.Io.Duration.fromMilliseconds(TEST_STDIO_RETRY_DELAY_MS), .clock = .real },
                io,
            ) catch {};
            continue;
        };
        allocator.free(post_init_payload);

        // We got the initialize response — SDK is alive. Read the
        // tools/list response (2nd response). Same retry semantics.
        const tools_deadline_ns: u64 = if (attempt == 1)
            TEST_STDIO_TIMEOUT_MS * std.time.ns_per_ms
        else
            1_000 * std.time.ns_per_ms;
        const tools_resp = client.recv(tools_deadline_ns, null) catch |err| {
            if (attempts_used < 20) {
                const code: []const u8 = switch (err) {
                    error.UnexpectedEof => "EOF",
                    error.RecvTimeout => "TO",
                    else => "ERR",
                };
                const stderr_msg = drainStderr(allocator, io, client.stderr);
                @memcpy(attempts_codes[attempts_used * 8 ..][0..code.len], code);
                @memset(attempts_codes[attempts_used * 8 + code.len ..][0 .. 8 - code.len], ' ');
                stderrs_buf[attempts_used] = stderr_msg;
                attempts_used += 1;
            }
            if (attempt >= TEST_STDIO_MAX_ATTEMPTS or err != error.UnexpectedEof) {
                lease.markStale();
                const detail = formatAttemptsDetail(
                    allocator,
                    @errorName(err),
                    attempts_used,
                    &attempts_codes,
                    &stderrs_buf,
                ) catch null;
                freeStderrs(allocator, &stderrs_buf, attempts_used);
                out_err_detail.* = detail;
                allocator.free(init_resp);
                return McpTestError.RecvFailed;
            }
            logger.warnFmt(
                "[mcp_test] stdio tools/list got {s} on attempt {d}/{d} — cold-start race; retrying",
                .{ @errorName(err), attempt, TEST_STDIO_MAX_ATTEMPTS },
            );
            lease.markStale();
            // Hand the child back before the backoff: `defer` alone
            // would keep the per-server lease for the whole sleep.
            lease.release();
            allocator.free(init_resp);
            std.Io.Clock.Duration.sleep(
                .{ .raw = std.Io.Duration.fromMilliseconds(TEST_STDIO_RETRY_DELAY_MS), .clock = .real },
                io,
            ) catch {};
            continue;
        };

        // Parse result.tools[] from the 2nd response.
        const tools = parseToolsList(allocator, tools_resp) catch |err| {
            logger.warnFmt("[mcp_test] stdio response parse failed: {s}", .{@errorName(err)});
            freeStderrs(allocator, &stderrs_buf, attempts_used);
            allocator.free(init_resp);
            allocator.free(tools_resp);
            return McpTestError.JsonParseFailed;
        };
        // Success — both responses are no longer needed.
        allocator.free(init_resp);
        allocator.free(tools_resp);

        // Success — free the collected stderrs (diagnostic only).
        freeStderrs(allocator, &stderrs_buf, attempts_used);
        return .{ .transport = "stdio", .tools = tools };
    }
}

/// Drain whatever is available on the child's stderr pipe.
/// ALWAYS returns a HEAP-allocated slice (caller frees),
/// even when the pipe is empty or the read failed. Truncated at 4
/// KiB to keep the response body small.
///
/// NEVER BLOCKS (2026-09-03 empty-args hang fix): on POSIX the pipe
/// is polled for 200ms first — a live-but-silent child (e.g. bare
/// `python` waiting on stdin after a `RecvTimeout`) has no stderr
/// bytes and no EOF, so a bare `readSliceShort` would block forever
/// and hang the handler a second time, right after `recv` was fixed
/// to time out. No data within 200ms → return `""`. On Windows
/// (`std.posix.poll` is a `@compileError` there) the single read is
/// kept as-is: after `UnexpectedEof` the child is dead so the read
/// returns promptly; the live-silent shape keeps the old blocking
/// behavior (documented limitation, same as `waitReadable`).
fn drainStderr(allocator: std.mem.Allocator, io: std.Io, stderr: ?std.Io.File) []u8 {
    // Always heap-allocate so the caller can uniformly `free` the
    // returned slice. The empty fallback is also heap so `free` is
    // safe even when no bytes were captured.
    const empty = allocator.dupe(u8, "") catch allocator.dupe(u8, "") catch unreachable;
    const f = stderr orelse return empty;
    if (comptime builtin.os.tag != .windows) {
        var pfds = [_]std.posix.pollfd{.{
            .fd = f.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        // Fail-open: poll error → try the read (old behavior).
        const ready = std.posix.poll(&pfds, 200) catch 1;
        // Timeout (0): child alive but stderr-silent — do NOT block.
        if (ready == 0) return empty;
        // ready > 0: bytes OR EOF/HUP waiting — the read below returns
        // immediately either way.
    }
    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.reader(f, io, &buf);
    // Single-shot read: whatever is in the kernel pipe buffer RIGHT
    // NOW (up to 4 KiB). The `poll` above guarantees this never blocks:
    // after `UnexpectedEof` the child is dead (data + EOF waiting); after
    // `RecvTimeout` the child is alive but we only reach this read when
    // poll saw bytes waiting. If the child crashed, we get whatever was
    // in flight (1-2 lines of error message).
    const n = std.Io.Reader.readSliceShort(&reader.interface, &buf) catch return empty;
    if (n == 0) return empty;
    return allocator.dupe(u8, buf[0..n]) catch empty;
}

/// Build a JSON-formatted diagnostic string for the failed
/// response body. Format:
///   "<last-error>|attempts=N/M codes=[<8-char codes>]|last_stderr=<escaped>"
/// Compact, single-line, escaped for JSON embedding. The stderr
/// portion is sanitized — control characters are replaced with
/// `\\n`/`\\r`/`\\t` escape sequences (or stripped if non-printable)
/// so a child that writes a multi-line error with embedded TTY
/// control codes doesn't break the response body's JSON parser
/// (observed on macOS ARM64 CI: Node SDK's `mcp.connect` failure
/// path writes an ANSI-coloured stack trace to stderr, which
/// contains \\x1b ESC bytes that make `json.loads` raise
/// "Invalid control character").
fn formatAttemptsDetail(
    allocator: std.mem.Allocator,
    last_err: []const u8,
    attempts_used: usize,
    attempts_codes: []const u8,
    stderrs: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, last_err);
    try buf.appendSlice(allocator, "|attempts=");
    var n_buf: [16]u8 = undefined;
    const n_str = std.fmt.bufPrint(&n_buf, "{d}", .{attempts_used}) catch "?";
    try buf.appendSlice(allocator, n_str);
    try buf.appendSlice(allocator, "/");
    const m_str = std.fmt.bufPrint(&n_buf, "{d}", .{attempts_codes.len / 8}) catch "?";
    try buf.appendSlice(allocator, m_str);
    try buf.appendSlice(allocator, " codes=[");
    const codes_text = attempts_codes[0 .. attempts_used * 8];
    for (codes_text, 0..) |c, i| {
        if (i > 0 and i % 8 == 0) try buf.append(allocator, ' ');
        try buf.append(allocator, c);
    }
    try buf.appendSlice(allocator, "]");
    if (attempts_used > 0) {
        try buf.appendSlice(allocator, "|last_stderr=");
        const last = stderrs[attempts_used - 1];
        const truncated = if (last.len > 512) last[0..512] else last;
        // Sanitize: replace control chars with their backslash-escaped
        // form so the resulting JSON is parseable. Other bytes (high
        // UTF-8, ANSI ESC, etc.) pass through — Python's json.loads
        // accepts them as long as they're not C0 control chars
        // (< 0x20 except \t \n \r).
        var i: usize = 0;
        while (i < truncated.len) : (i += 1) {
            const c = truncated[i];
            switch (c) {
                0x08 => try buf.appendSlice(allocator, "\\b"), // backspace
                0x09 => try buf.appendSlice(allocator, "\\t"), // tab
                0x0A => try buf.appendSlice(allocator, "\\n"),
                0x0C => try buf.appendSlice(allocator, "\\f"), // form feed
                0x0D => try buf.appendSlice(allocator, "\\r"),
                0x22 => try buf.appendSlice(allocator, "\\\""), // quote
                0x5C => try buf.appendSlice(allocator, "\\\\"), // backslash
                0x00...0x07, 0x0B, 0x0E...0x1F => {
                    // Other C0 control chars: strip (they break JSON).
                    // Includes 0x1B (ESC), 0x07 (BEL), etc.
                },
                else => try buf.append(allocator, c),
            }
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Try an HTTP candidate: POST `tools/list` to the URL with the
/// headers, parse `result.tools[]`. Uses libcurl's built-in 10s
/// timeout via `timeout_ms`.
///
/// Body is intentionally MINIMAL (`{"params":{}}`, no `_meta` envelope):
/// real servers on protocol revision 2026-07-28 (e.g. context7) answer
/// the lenient path with `200 text/event-stream` for a bare body but
/// return `400 Invalid _meta envelope ... clientCapabilities: missing`
/// as soon as a 2025-11-25-shaped `_meta.protocolVersion` envelope is
/// present (bisected 2026-09-10 via curl). The `MCP-Protocol-Version`
/// + `Mcp-Method` headers below are tolerated (200) by those servers
/// and required by strict ones, so we send headers but not the body
/// envelope.
fn mcpTestHttp(
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: *loggermod.Logger,
    req: McpTestRequest,
    out_err_detail: *?[]const u8,
) McpTestError!McpTestOutcome {
    _ = io;
    if (req.url.len == 0) return McpTestError.MissingUrl;

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();

    const body = allocator.dupe(u8,
        \\{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}
    ) catch return McpTestError.OutOfMemory;
    defer allocator.free(body);

    var header_buf: [16]custom_http_client.Header = undefined;
    var header_count: usize = 0;
    header_buf[header_count] = .{ .name = "Accept", .value = "application/json, text/event-stream" };
    header_count += 1;
    header_buf[header_count] = .{ .name = "Content-Type", .value = "application/json" };
    header_count += 1;
    // Spec headers (tolerated 200 on context7 per 2026-09-10 bisect;
    // required by strict Streamable HTTP servers). Sent BEFORE user
    // headers so libcurl's first-match-wins prefers the spec value.
    header_buf[header_count] = .{ .name = "MCP-Protocol-Version", .value = "2025-11-25" };
    header_count += 1;
    header_buf[header_count] = .{ .name = "Mcp-Method", .value = "tools/list" };
    header_count += 1;

    if (req.headers) |hdrs_value| {
        const hdrs_obj = switch (hdrs_value) {
            .object => |obj| obj,
            else => return McpTestError.JsonParseFailed,
        };
        var it = hdrs_obj.iterator();
        while (it.next()) |entry| {
            if (header_count >= header_buf.len) break;
            const v_str = switch (entry.value_ptr.*) {
                .string => |s| s,
                else => continue,
            };
            header_buf[header_count] = .{ .name = entry.key_ptr.*, .value = v_str };
            header_count += 1;
        }
    }
    const header_slice = header_buf[0..header_count];

    const result = custom_http_client.post(
        &client,
        req.url,
        body,
        header_slice,
        .{ .timeout_ms = TEST_HTTP_TIMEOUT_MS },
    ) catch |err| {
        logger.warnFmt("[mcp_test] http POST failed for '{s}': {s}", .{ req.url, @errorName(err) });
        if (err == error.Timeout) return McpTestError.Timeout;
        return McpTestError.SendFailed;
    };
    defer result.deinit(allocator);

    if (result.status_code != 200) {
        logger.warnFmt("[mcp_test] http server returned status {d}", .{result.status_code});
        // Surface the server's error body (e.g. a 400 JSON-RPC envelope
        // error) so the modal shows WHY instead of a generic message.
        // Truncated to 200 bytes to keep the wire small.
        const snippet_len: usize = @min(result.body.len, 200);
        out_err_detail.* = std.fmt.allocPrint(
            allocator,
            "http {d}: {s}",
            .{ result.status_code, result.body[0..snippet_len] },
        ) catch null;
        return McpTestError.InvalidResponse;
    }

    const tools = parseToolsList(allocator, result.body) catch |err| {
        logger.warnFmt("[mcp_test] http response parse failed: {s}", .{@errorName(err)});
        return McpTestError.JsonParseFailed;
    };

    return .{ .transport = "http", .tools = tools };
}

/// Unwrap a Streamable HTTP response body to its JSON-RPC payload.
///
/// Handles BOTH shapes per the spec:
///   - `application/json` (single object, starts with `{`) → dup verbatim
///   - `text/event-stream` (SSE: `event:` / `data:` / `:` comment lines
///     grouped by blank-line boundaries) → last event's `data:` lines
///     joined with `\n` (per the SSE spec's multi-data rule)
///
/// Real servers (e.g. context7) answer `tools/list` as
/// `event: message\ndata: {"result":...}` — the old code only stripped
/// a leading `data:` prefix, so `event:`-prefixed bodies went to the
/// JSON parser verbatim → `JsonParseFailed` ("failed to parse MCP
/// server response as JSON"). Caller owns the returned slice.
fn unwrapSsePayload(allocator: std.mem.Allocator, body: []const u8) McpTestError![]const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, body) catch return McpTestError.OutOfMemory;
    // Fast path: plain JSON object — no SSE framing to strip.
    if (trimmed[0] == '{') return allocator.dupe(u8, trimmed) catch return McpTestError.OutOfMemory;

    // SSE path: walk `\n\n`-separated events, keep the LAST event that
    // carries at least one `data:` line. Field names are
    // case-insensitive; `:` comment lines are skipped.
    var last: ?[]const u8 = null;
    var owned_last: ?[]u8 = null;
    defer if (owned_last) |o| allocator.free(o);
    var blocks = std.mem.splitSequence(u8, body, "\n\n");
    while (blocks.next()) |raw_event| {
        const event = std.mem.trim(u8, raw_event, " \r\n");
        if (event.len == 0) continue;
        var data_buf: std.ArrayList(u8) = .empty;
        defer data_buf.deinit(allocator);
        var line_it = std.mem.splitScalar(u8, event, '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r");
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, ":")) continue; // comment
            if (std.ascii.startsWithIgnoreCase(line, "data:")) {
                var value = line["data:".len..];
                if (value.len > 0 and value[0] == ' ') value = value[1..];
                if (data_buf.items.len > 0) data_buf.append(allocator, '\n') catch return McpTestError.OutOfMemory;
                data_buf.appendSlice(allocator, value) catch return McpTestError.OutOfMemory;
            }
            // `event:` / `id:` / `retry:` lines are intentionally ignored.
        }
        if (data_buf.items.len > 0) {
            if (owned_last) |o| allocator.free(o);
            owned_last = data_buf.toOwnedSlice(allocator) catch return McpTestError.OutOfMemory;
            last = owned_last.?;
        }
    }
    if (last) |d| {
        const out = allocator.dupe(u8, d) catch return McpTestError.OutOfMemory;
        return out;
    }
    // No `data:` line found (e.g. legacy single-line `data: {...}`
    // without event framing is already covered above, but keep the
    // old prefix-strip as a last resort) — fall back to the trimmed
    // body so the JSON parser produces the authoritative error.
    if (std.mem.startsWith(u8, trimmed, "data:"))
        return allocator.dupe(u8, std.mem.trim(u8, trimmed["data:".len..], " \t")) catch return McpTestError.OutOfMemory;
    return allocator.dupe(u8, trimmed) catch return McpTestError.OutOfMemory;
}

/// Parse an MCP `tools/list` response into a preview list.
fn parseToolsList(allocator: std.mem.Allocator, body: []const u8) McpTestError![]const McpToolPreview {
    const json_text = try unwrapSsePayload(allocator, body);
    defer allocator.free(json_text);

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        parse_arena.allocator(),
        json_text,
        .{ .ignore_unknown_fields = true },
    ) catch return McpTestError.JsonParseFailed;

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return McpTestError.InvalidResponse,
    };
    const result_value = root.get("result") orelse return McpTestError.InvalidResponse;
    const result_obj = switch (result_value) {
        .object => |obj| obj,
        else => return McpTestError.InvalidResponse,
    };
    const tools_value = result_obj.get("tools") orelse return McpTestError.InvalidResponse;
    const tools_array = switch (tools_value) {
        .array => |a| a,
        else => return McpTestError.InvalidResponse,
    };

    var out: std.ArrayList(McpToolPreview) = .empty;
    errdefer out.deinit(allocator);
    for (tools_array.items) |tool_value| {
        const tool_obj = switch (tool_value) {
            .object => |obj| obj,
            else => continue,
        };
        const name_v = tool_obj.get("name") orelse continue;
        const name = switch (name_v) {
            .string => |s| s,
            else => continue,
        };
        const desc_v = tool_obj.get("description") orelse continue;
        const description = switch (desc_v) {
            .string => |s| s,
            else => continue,
        };
        out.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
        }) catch return McpTestError.OutOfMemory;
    }
    return out.toOwnedSlice(allocator) catch return McpTestError.OutOfMemory;
}

// ─── Handler ───────────────────────────────────────────────────────────────

pub fn mcpTestHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }),
        });
    };
    const logger = di.logger;

    const parsed = std.json.parseFromSliceLeaky(McpTestRequest, allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"invalid JSON body\"}}", .{}),
        });
    };

    var err_detail: ?[]const u8 = null;
    defer if (err_detail) |d| allocator.free(d);
    const outcome = mcpTestUseCase(allocator, io, logger, parsed, &err_detail) catch |err| {
        const message: []const u8 = switch (err) {
            error.MissingTransport => "transport is required (stdio or http)",
            error.UnsupportedTransport => "transport must be 'stdio' or 'http'",
            error.MissingCommand => "command is required for stdio transport",
            error.MissingUrl => "url is required for http transport",
            error.SpawnFailed => "failed to spawn child process (check the command exists and is executable)",
            error.SendFailed => "failed to send request to MCP server",
            error.RecvFailed => "failed to receive response from MCP server",
            error.Timeout => "MCP server did not respond within 10 seconds",
            error.JsonParseFailed => "failed to parse MCP server response as JSON",
            error.InvalidResponse => "MCP server response did not contain a valid tools list",
            error.OutOfMemory => "out of memory",
        };
        const details: []const u8 = err_detail orelse @errorName(err);
        std.log.warn("[mcp_test] error: {s} ({s})", .{ message, details });
        const data = std.fmt.allocPrint(
            allocator,
            "{{\"ok\":false,\"error\":\"{s}\",\"details\":\"{s}\"}}",
            .{ message, details },
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
            });
        };
        return res.jsonResponse(.{ .status_code = 200, .data = data });
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "{{\"ok\":true,\"transport\":\"{s}\",\"tools\":[", .{outcome.transport});
    for (outcome.tools, 0..) |tool, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.print(allocator, "{{\"name\":{f},\"description\":{f}}}", .{ std.json.fmt(tool.name, .{}), std.json.fmt(tool.description, .{}) });
    }
    try buf.appendSlice(allocator, "]}");
    const data = try buf.toOwnedSlice(allocator);

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Inline tests ──────────────────────────────────────────────────────────

test "formatAttemptsDetail: sanitizes C0 control chars from stderr (JSON-safe)" {
    // Regression guard for CI macOS ARM64 (commit 76d03d6d + this fix):
    // the SDK's mcp.connect failure path writes ANSI-coloured stack
    // traces to stderr containing \\x1b (ESC) and \\n bytes. If those
    // reach the JSON response body verbatim, `json.loads` on the
    // client raises "Invalid control character". The sanitizer must
    // \\n -> \\\\n, strip \\x1b, leave printable bytes alone.
    const allocator = testing.allocator;

    // Build a stderr blob with: ESC, newline, NUL, BEL, printable.
    const dirty_stderr = "\x1b[31mfatal\x1b[0m: \nmcp.connect failed\n\x00\x07";
    var stderrs = [_][]const u8{dirty_stderr};
    // Mirror production code: codes buffer is 8 bytes per attempt,
    // padded with SPACE (0x20) after the short code. Using NUL (0x00)
    // here would break the sanitizer's invariant that codes_text is
    // printable — the formatAttemptsDetail loop appends every byte,
    // so trailing NULs would land in the response body.
    var codes = [_]u8{' '} ** (1 * 8);
    @memcpy(codes[0..3], "EOF");

    const detail = try formatAttemptsDetail(
        allocator,
        "UnexpectedEof",
        1,
        &codes,
        &stderrs,
    );
    defer allocator.free(detail);

    // formatAttemptsDetail returns a custom format string, NOT JSON:
    //   "<err>|attempts=N/M codes=[<codes>]|last_stderr=<sanitized>"
    // The response handler then embeds this into the JSON response body
    // via `{s}`. Verify the sanitizer produced output that, once
    // embedded into a JSON document, parses cleanly.
    //
    // Verify specific sanitization: \\n appears as literal \\\\n, not raw \\n.
    try testing.expect(std.mem.indexOf(u8, detail, "\\n") != null);
    // ESC (0x1b) was stripped entirely (not even present in escape form).
    try testing.expect(std.mem.indexOf(u8, detail, "\x1b") == null);
    // Printable text preserved.
    try testing.expect(std.mem.indexOf(u8, detail, "fatal") != null);

    // CRITICAL: embed `detail` into a JSON document and parse it back.
    // If any control char survived, std.json will raise SyntaxError
    // (which on the Python test client is `json.loads: Invalid
    // control character`). This is the regression guard for the
    // commit-76d03d6d macOS CI failure.
    const wrapped = try std.fmt.allocPrint(
        allocator,
        "{{\"details\":\"{s}\"}}",
        .{detail},
    );
    defer allocator.free(wrapped);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        wrapped,
        .{},
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("details") != null);
}

//! HTTP Handlers module - one file per endpoint for better organization This
//! module exports all HTTP handlers used by the TUI HTTP server. Each handler
//! is in its own file for maintainability.

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
// GET /api/llm/session/:session_id/usage — token usage + cache hit rate,
// derived from one aggregate over `llm_history` (the `sessions` table
// stores no token column).
pub const sessionUsageHandler = @import("session_usage_get.zig").sessionUsageHandler;
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
pub const previewProxyHandler = @import("preview_proxy.zig").previewProxyHandler;
pub const preview_origin = @import("preview_origin.zig");
pub const healthHandler = @import("health.zig").healthHandler;
pub const shutdownHandler = @import("shutdown.zig").shutdownHandler;
pub const metricsGetHandler = @import("metrics_get.zig").metricsGetHandler;
pub const metricsMiddleware = @import("metrics_middleware.zig").metricsMiddleware;
pub const metricsSummaryHandler = @import("metrics_summary_get.zig").metricsSummaryHandler;
// Opt-in `--auth` (login page + session cookie + middleware).
pub const authLoginHandler = @import("auth_login.zig").authLoginHandler;
pub const authLogoutHandler = @import("auth_session.zig").authLogoutHandler;
pub const authMeHandler = @import("auth_session.zig").authMeHandler;
// `POST /api/auth/password` — the signed-in user rotates their own password.
pub const authChangePasswordHandler = @import("auth_password.zig").authChangePasswordHandler;
pub const authMiddleware = @import("auth_middleware.zig").authMiddleware;
pub const authIsAuthorized = @import("auth_middleware.zig").isAuthorized;

// Workspace handlers (stub implementations for desktop app compatibility)
pub const workspacesListHandler = @import("workspaces_list.zig").workspacesListHandler;
pub const workspacesCreateHandler = @import("workspaces_create.zig").workspacesCreateHandler;
// The single workspace-create path: id generation, the `position = MAX + 1`
// INSERT, the `workspace_members` grant and the attached default project.
pub const workspace_provisioning = @import("workspace_provisioning.zig");
pub const workspacesReorderHandler = @import("workspaces_reorder.zig").workspacesReorderHandler;
pub const workspaceGetHandler = @import("workspace_get.zig").workspaceGetHandler;
pub const workspaceUpdateHandler = @import("workspace_update.zig").workspaceUpdateHandler;
pub const workspaceDeleteHandler = @import("workspace_delete.zig").workspaceDeleteHandler;
// Membership of a workspace (Migration 100): who is in, with which role.
pub const workspaceMembersListHandler = @import("workspace_members_list.zig").workspaceMembersListHandler;
pub const workspaceMembersInviteHandler = @import("workspace_members_invite.zig").workspaceMembersInviteHandler;
pub const workspaceMembersUpdateHandler = @import("workspace_members_update.zig").workspaceMembersUpdateHandler;
pub const workspaceMembersRemoveHandler = @import("workspace_members_remove.zig").workspaceMembersRemoveHandler;
pub const workspaceItemsCreateHandler = @import("workspace_items_create.zig").workspaceItemsCreateHandler;
pub const workspaceItemsListHandler = @import("workspace_items_get.zig").workspaceItemsListHandler;
pub const workspaceItemsGetHandler = @import("workspace_items_get.zig").workspaceItemsGetHandler;
pub const workspaceDefaultProjectHandler = @import("workspace_items_default.zig").workspaceDefaultProjectHandler;

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
pub const benchSeedSessionsHandler = @import("bench_seed.zig").benchSeedSessionsHandler;
pub const benchSeedDocumentsHandler = @import("bench_seed.zig").benchSeedDocumentsHandler;
// MCP server "Test" probe — fires a tools/list request against a candidate
// config (without persisting anything) so the user can verify their command /
// args / env / cwd (or URL + headers) before clicking Save in the MCP server
pub const agentToolsRegistryHandler = @import("agent_tools_registry.zig").agentToolsRegistryHandler;
pub const agentToolsListHandler = @import("agent_tools_list.zig").agentToolsListHandler;
pub const agentProfileInUseHandler = @import("agent_profile_in_use.zig").agentProfileInUseHandler;
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
// 2026-09-10-workspace-items-routines) — first-class `item_type='routine'`
// beside `agent`.
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
pub const documentsReorderHandler = @import("documents_reorder.zig").documentsReorderHandler;

// Workspace-scoped secrets (Migration 103). Same house shape as the documents
// block above: one file per HTTP verb, each carrying its own private
// `useCase` + inline tests.
pub const secretsListHandler = @import("secrets_list.zig").secretsListHandler;
pub const secretsCreateHandler = @import("secrets_create.zig").secretsCreateHandler;
pub const secretsUpdateHandler = @import("secrets_update.zig").secretsUpdateHandler;
pub const secretsDeleteHandler = @import("secrets_delete.zig").secretsDeleteHandler;

// Kanban column CRUD handlers (item_type='kanban' sub-resources).
pub const kanbanColumnsListHandler = @import("kanban_columns_list.zig").kanbanColumnsListHandler;
pub const kanbanColumnsCreateHandler = @import("kanban_columns_create.zig").kanbanColumnsCreateHandler;
// POST /api/workspaces/:workspace_id/items/:item_id/kanban/tasks with
// `mode` discriminator ('create' | 'create_and_run').
pub const kanbanTasksCreateHandler = @import("kanban_tasks_create.zig").kanbanTasksCreateHandler;
pub const kanbanColumnsUpdateHandler = @import("kanban_columns_update.zig").kanbanColumnsUpdateHandler;
pub const kanbanColumnsDeleteHandler = @import("kanban_columns_delete.zig").kanbanColumnsDeleteHandler;
// Copy a kanban's column spec (names + descriptions, preserving order) from a
// source kanban to a target kanban. Tasks are NOT copied.
pub const kanbanCopySpecHandler = @import("kanban_copy_spec.zig").kanbanCopySpecHandler;
pub const tasksMoveHandler = @import("tasks_move.zig").tasksMoveHandler;
pub const tasksListHandler = @import("tasks_list.zig").tasksListHandler;
// Single-task GET endpoint.
pub const tasksGetHandler = @import("tasks_get.zig").tasksGetHandler;
// Lazy media fetch (media-flags change) — full `image_urls` / `video_urls`
// only when `is_have_image` / `is_have_video` is true.
pub const tasksMediaHandler = @import("tasks_media.zig").tasksMediaHandler;
// Kanban tag autocomplete endpoint.
// Stub-only in this commit — Task 1.4 implements the useCase body.
pub const kanbanTagsListHandler = @import("kanban_tags_list.zig").kanbanTagsListHandler;
pub const tasksCreateHandler = @import("task_create.zig").tasksCreateHandler;
pub const tasksUpdateHandler = @import("task_update.zig").tasksUpdateHandler;
pub const tasksUpdateByIdHandler = @import("task_update.zig").tasksUpdateByIdHandler;
pub const tasksDeleteHandler = @import("task_delete.zig").tasksDeleteHandler;
// Use-case + outcome type live in the same file as the handler (DELETE
// /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id).
pub const deleteTaskUseCase = @import("task_delete.zig").deleteTaskUseCase;
pub const TaskDeleteOutcome = @import("task_delete.zig").TaskDeleteOutcome;
pub const taskPinHandler = @import("task_pin.zig").taskPinHandler;
// Chunk 3 of kanban-task-notification-icon: thin handler that stamps
// `last_human_touched_at` and emits the `kanban_task.human_touched`
// SSE event.
pub const taskMarkHumanTouchedHandler = @import("task_mark_human_touched.zig").taskMarkHumanTouchedHandler;
pub const tasksReorderPinnedHandler = @import("tasks_reorder_pinned.zig").tasksReorderPinnedHandler;
// Task attachment upload/download handlers — REMOVED 2026-08-06 (Migration
// 069 / kanban-image-urls-column plan).
pub const startAgentHandler = @import("start_agent.zig").startAgentHandler;
// NEW (plan: 2026-08-18-kanban-task-detail-start-agent).
pub const startAgentUseCase = @import("start_agent.zig").startAgentUseCase;
pub const runAllAgentsHandler = @import("run_all_agents.zig").runAllAgentsHandler;
pub const stopAllAgentsHandler = @import("stop_all_agents.zig").stopAllAgentsHandler;
// NOTE: routinesListHandler deleted with the per-task `routines` table
// (Migration 084, plan 2026-09-10-workspace-items-routines).

// Worker API handlers
pub const workerGetHandler = @import("worker_get.zig").workerGetHandler;
pub const workerListHandler = @import("worker_list.zig").workerListHandler;

// Unified SSE handler — single endpoint that fans out all event families.
// Replaces the 5 dedicated routes registered in main.zig. See
// unified_events_sse.zig for the channel grammar (?channels=).
pub const unifiedEventsStreamHandler = @import("unified_events_sse.zig").unifiedEventsStreamHandler;

// Skills API handlers Workspace-scoped skills (Migration 101).
pub const skillsListHandler = @import("skills_list.zig").skillsListHandler;
pub const skillCreateHandler = @import("skill_create.zig").skillCreateHandler;
pub const skillDetailHandler = @import("skill_detail.zig").skillDetailHandler;
pub const skillUpdateHandler = @import("skill_update.zig").skillUpdateHandler;
pub const skillDeleteHandler = @import("skill_delete.zig").skillDeleteHandler;
// Skill Evals — the read surface.
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
// `~/.config/pabrik/memories/`.
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

/// GET /api/git/pr/conversation — the change request's body, its comments
/// and its review verdicts. Shares provider resolution with the status
/// endpoint.
pub const gitPrConversationHandler = @import("git_pr_conversation.zig").gitPrConversationHandler;
/// POST /api/git/pr/merge — merge a PR/MR through the forge CLI. Returns the
/// status payload RE-READ after the command, because a zero exit code is not
/// proof that anything merged (see git_pr_merge.zig).
pub const gitPrMergeHandler = @import("git_pr_merge.zig").gitPrMergeHandler;

/// GET /api/git/pr/checks — CI jobs for a PR plus the steps inside each
/// failed one. Registered next to the status handler because the two
/// share provider resolution (`git_pr_status.resolveProvider`).
pub const gitPrChecksHandler = @import("git_pr_checks.zig").gitPrChecksHandler;
/// GET /api/git/pr/list — the repo's change requests (the kanban board's PR
/// list). Shares provider resolution with the status endpoint.
pub const gitPrListHandler = @import("git_pr_list.zig").gitPrListHandler;
/// POST /api/git/pr/close — close a PR/MR through the forge CLI. Mutating,
/// so it is only ever reachable authenticated; the answer is a re-read of the
/// forge's status, never the CLI's exit code.
pub const gitPrCloseHandler = @import("git_pr_close.zig").gitPrCloseHandler;

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
pub const terminalListHandler = @import("terminal_list.zig").terminalListHandler;
pub const terminalWsHandler = @import("terminal_ws.zig").terminalWsHandler;

// Design-mode HTTP handlers (item_type='design') — v6 of the design-mode
// redesign.for the full route table.
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
pub const designElementsTranslateHandler = @import("design_elements_translate.zig").designElementsTranslateHandler;
pub const designElementsTranslateUseCase = @import("design_elements_translate.zig").useCase;
pub const designElementsTranslateError = @import("design_elements_translate.zig").DesignElementTranslateError;
// NEW (2026-08-06) — POST .../resize. Single-element resize with absolute
// x/y/width/height/rotation. No cascade (resize is per-element by Figma
// convention).
pub const designElementsResizeHandler = @import("design_elements_resize.zig").designElementsResizeHandler;
pub const designElementsResizeUseCase = @import("design_elements_resize.zig").useCase;
pub const designElementsResizeError = @import("design_elements_resize.zig").DesignElementResizeError;
// Group 2+ elements into a new `group`/`frame` parent. POST
// /api/workspaces/:w/items/:i/design/pages/:p/elements/group
pub const designElementsGroupHandler = @import("design_elements_group.zig").designElementsGroupHandler;
pub const designElementsReorderHandler = @import("design_elements_reorder.zig").designElementsReorderHandler;
pub const designElementsReparentBatchHandler = @import("design_elements_reparent.zig").designElementsReparentBatchHandler;
// Server-side cascade move. POST /api/workspaces/:w/items/:i/design/pages/:p/elements/move-batch
pub const designElementsMoveBatchHandler = @import("design_elements_move_batch.zig").designElementsMoveBatchHandler;
// Cross-page element relocate. POST /api/workspaces/:w/items/:i/design/pages/:p/elements/:eid/move-to-page
pub const designElementsMoveToPageHandler = @import("design_elements_move_to_page.zig").designElementsMoveToPageHandler;
pub const designElementsUngroupHandler = @import("design_elements_ungroup.zig").designElementsUngroupHandler;

// Session to client IDs monitoring
pub const sessionToClientIdsHandler = @import("session_to_client_ids.zig").sessionToClientIdsHandler;

// Debug/inspection endpoint — returns the rendered system prompt for a
// session. See `system_prompt_get.zig` for the full contract.
pub const systemPromptGetHandler = @import("system_prompt_get.zig").systemPromptGetHandler;

// Pabrik config handlers
pub const pabrikConfigGetHandler = @import("pabrik_config_get.zig").pabrikConfigGetHandler;

// models.dev catalog (Migration 106): the picker's data, the profile dialog's
// one resolve call, and a manual refresh.
pub const modelsCatalogHandler = @import("models_catalog.zig").modelsCatalogHandler;
pub const modelsResolveHandler = @import("models_catalog.zig").modelsResolveHandler;
pub const modelsRefreshHandler = @import("models_catalog.zig").modelsRefreshHandler;
pub const pabrikConfigPutHandler = @import("pabrik_config_put.zig").pabrikConfigPutHandler;
// Per-workspace config overlay (Migration 105).
pub const workspaceConfigGetHandler = @import("workspace_config.zig").workspaceConfigGetHandler;
pub const workspaceConfigPutHandler = @import("workspace_config.zig").workspaceConfigPutHandler;
pub const workspaceConfigProfileDeleteHandler = @import("workspace_config.zig").workspaceConfigProfileDeleteHandler;
pub const pabrikConfigProfileDeleteHandler = @import("pabrik_config_profile_delete.zig").pabrikConfigProfileDeleteHandler;
// Use-case + domain types live in the same file as the handler.
pub const removeProfileFromDocument = @import("pabrik_config_profile_delete.zig").removeProfileFromDocument;
pub const removeProfileFromUserConfig = @import("pabrik_config_profile_delete.zig").removeProfileFromUserConfig;
// `ConfigInput` is the wire format for `PUT /api/config/pabrik`.
pub const ConfigInput = @import("pabrik_config_put.zig").ConfigInput;
pub const parseConfigInput = @import("pabrik_config_put.zig").parseConfigInput;

// OS notification test handler — fires a real OS notification so the user can
// verify their system can display them without running a full LLM stream.

// Browser-mode (web launch) status — read-only report of the
// `web_launch_enabled` flag + live bound port/URL.
pub const webStatusHandler = @import("web_status.zig").webStatusHandler;

// Frontend error log handlers — persist and query the window.error /
// unhandledrejection / console.error / console.warn events in the `logs`
// table.
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

// ===== Tests merged from notify_test.zig (2026-09-29 flatten) ===== This
// file held no `test` blocks — it is the OS-notification probe endpoint whose
// name merely ends in `_test`.

const notifications = pabrikcore.notifications_mod;

/// POST /api/notify/test Fires a fixed test OS notification so the user can
/// verify their system can display notifications without running a full LLM
/// stream.
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

// kabelweb is the unified web-framework package imported
// directly via `@import("kabelweb").client` (see root.zig:509),
// not a member of `pabrikcore`.
const custom_http_client = @import("kabelweb").client;
const helpers = @import("helpers");
const claude_code = @import("../agentic_loop/claude_code.zig");
const opencode = @import("../agentic_loop/opencode.zig");

/// Per-call deadline for the probe (libcurl has OS-level timeout support).
const TEST_LLM_TIMEOUT_MS: u32 = 15_000;

/// Output budget for a probe.
const PROBE_MAX_OUTPUT_TOKENS: u32 = 2048;

/// Budget for the single retry after the provider says the first probe ran
/// out of output mid-reasoning.
const PROBE_MAX_OUTPUT_TOKENS_RETRY: u32 = 8192;

/// The probe prompt. Short + deterministic so the modal can show the
/// reply verbatim as proof the model answered.
const PROBE_PROMPT: []const u8 = "Reply with exactly: ok";

/// Max reply bytes carried on the wire. The probe asks for a one-word
/// answer; 200 bytes is plenty and keeps the modal payload small.
const MAX_REPLY_LEN: usize = 200;

/// Stable session id sent as `x-opencode-session` on every Test probe.
const PROBE_SESSION_ID: []const u8 = "pabrik-llm-test-probe";

/// Candidate profile fields. Mirrors the frontend's `LlmTestRequest` shape in
/// `src/apps/desktop/src/api/index.ts`.
const LlmTestRequest = struct {
    model: []const u8 = "",
    base_url: []const u8 = "",
    api_key: []const u8 = "",
    url_style: []const u8 = "openai",
    /// Transport discriminator, mirroring a profile's `backend` key: `"http"`
    /// (default) | `"claude-code"` | `"opencode"`.
    backend: []const u8 = "http",
    /// Claude Code only: `CLAUDE_CONFIG_DIR`, so the probe checks the same
    /// login the run would use.
    config_dir: []const u8 = "",
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
    /// The provider returned no visible text AND said it stopped because the
    /// output budget ran out.
    ReasoningBudgetExhausted,
    OutOfMemory,
};

const LlmTestOutcome = struct {
    model: []const u8,
    reply: []const u8,
    latency_ms: i64,
};

// ─── Pure helpers (unit-testable, no network) ───────────────────────────────

/// Validate the candidate without touching the network. Empty api_key is
/// ALLOWED (keyless local endpoints + stub upstreams in tests).
fn llmTestValidate(req: LlmTestRequest) LlmTestError!void {
    if (req.model.len == 0) return LlmTestError.MissingModel;

    if (std.mem.eql(u8, req.backend, "claude-code")) return;
    if (std.mem.eql(u8, req.backend, "opencode")) return;

    if (req.base_url.len == 0) return LlmTestError.MissingBaseUrl;
    const has_http_scheme = std.mem.startsWith(u8, req.base_url, "http://") or
        std.mem.startsWith(u8, req.base_url, "https://");
    if (!has_http_scheme) return LlmTestError.InvalidBaseUrl;
    if (!(std.mem.eql(u8, req.url_style, "openai") or
        std.mem.eql(u8, req.url_style, "openai-response") or
        std.mem.eql(u8, req.url_style, "anthropic")))
        return LlmTestError.UnsupportedStyle;
}

/// Build the minimal probe body for the request's url_style, asking for
/// `max_output_tokens` tokens. Caller owns the returned slice.
fn llmTestBuildProbeBody(
    allocator: std.mem.Allocator,
    req: LlmTestRequest,
    max_output_tokens: u32,
) LlmTestError![]u8 {
    if (std.mem.eql(u8, req.url_style, "anthropic")) {
        return std.fmt.allocPrint(
            allocator,
            "{{\"model\":{f},\"max_tokens\":{d},\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}]}}",
            .{ std.json.fmt(req.model, .{}), max_output_tokens, PROBE_PROMPT },
        ) catch return LlmTestError.OutOfMemory;
    }
    if (std.mem.eql(u8, req.url_style, "openai-response")) {
        return std.fmt.allocPrint(
            allocator,
            "{{\"model\":{f},\"input\":\"{s}\",\"max_output_tokens\":{d},\"stream\":false,\"store\":false}}",
            .{ std.json.fmt(req.model, .{}), PROBE_PROMPT, max_output_tokens },
        ) catch return LlmTestError.OutOfMemory;
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"model\":{f},\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}],\"max_tokens\":{d},\"temperature\":0,\"stream\":false}}",
        .{ std.json.fmt(req.model, .{}), PROBE_PROMPT, max_output_tokens },
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

    const reply = llmTestFindReplyText(root, url_style) orelse {
        // No text anywhere in the body.
        if (llmTestBudgetExhausted(root, url_style)) return LlmTestError.ReasoningBudgetExhausted;
        return LlmTestError.InvalidResponse;
    };

    const trimmed = std.mem.trim(u8, reply, " \t\r\n");
    // A truncated reasoning-only reply can still carry an empty text block
    // (`content: ""` on the chat-completions style), which is the same
    // failure wearing different JSON.
    if (trimmed.len == 0 and llmTestBudgetExhausted(root, url_style))
        return LlmTestError.ReasoningBudgetExhausted;
    const capped = trimmed[0..@min(trimmed.len, MAX_REPLY_LEN)];
    return allocator.dupe(u8, capped) catch return LlmTestError.OutOfMemory;
}

/// The assistant reply text in a probe response, or null when the body
/// carries none — a wrong url_style, an error envelope, or a reasoning-only
/// response where the model never produced a text item. anthropic:
fn llmTestFindReplyText(root: std.json.ObjectMap, url_style: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, url_style, "anthropic")) {
        const content_v = root.get("content") orelse return null;
        const blocks = switch (content_v) {
            .array => |a| a,
            else => return null,
        };
        for (blocks.items) |block| {
            const obj = switch (block) {
                .object => |o| o,
                else => continue,
            };
            const t = switch (obj.get("type") orelse continue) {
                .string => |str| str,
                else => continue,
            };
            if (!std.mem.eql(u8, t, "text")) continue;
            const text_v = obj.get("text") orelse continue;
            return switch (text_v) {
                .string => |str| str,
                else => continue,
            };
        }
        return null;
    }

    if (std.mem.eql(u8, url_style, "openai-response")) {
        const output_v = root.get("output") orelse return null;
        const items = switch (output_v) {
            .array => |a| a,
            else => return null,
        };
        for (items.items) |item| {
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
                const t = switch (pobj.get("type") orelse continue) {
                    .string => |str| str,
                    else => continue,
                };
                if (!std.mem.eql(u8, t, "output_text")) continue;
                const text_v = pobj.get("text") orelse continue;
                return switch (text_v) {
                    .string => |str| str,
                    else => continue,
                };
            }
        }
        return null;
    }

    const choices_v = root.get("choices") orelse return null;
    const choices = switch (choices_v) {
        .array => |a| a,
        else => return null,
    };
    if (choices.items.len == 0) return null;
    const first = switch (choices.items[0]) {
        .object => |o| o,
        else => return null,
    };
    const msg_v = first.get("message") orelse return null;
    const msg = switch (msg_v) {
        .object => |o| o,
        else => return null,
    };
    const content_v = msg.get("content") orelse return null;
    return switch (content_v) {
        .string => |str| str,
        else => null,
    };
}

/// True when the provider says it stopped because the output budget ran out,
/// i.e. the model may have spent every allowed token on hidden reasoning
/// before writing any visible text. openai-response: `"status": "incomplete"`
fn llmTestBudgetExhausted(root: std.json.ObjectMap, url_style: []const u8) bool {
    if (std.mem.eql(u8, url_style, "openai-response")) {
        const status = switch (root.get("status") orelse return false) {
            .string => |str| str,
            else => return false,
        };
        if (!std.mem.eql(u8, status, "incomplete")) return false;
        const details_v = root.get("incomplete_details") orelse return true;
        const details = switch (details_v) {
            .object => |o| o,
            else => return true,
        };
        const reason = switch (details.get("reason") orelse return true) {
            .string => |str| str,
            else => return true,
        };
        return std.mem.eql(u8, reason, "max_output_tokens");
    }

    if (std.mem.eql(u8, url_style, "anthropic")) {
        const stop = switch (root.get("stop_reason") orelse return false) {
            .string => |str| str,
            else => return false,
        };
        return std.mem.eql(u8, stop, "max_tokens");
    }

    const choices_v = root.get("choices") orelse return false;
    const choices = switch (choices_v) {
        .array => |a| a,
        else => return false,
    };
    if (choices.items.len == 0) return false;
    const first = switch (choices.items[0]) {
        .object => |o| o,
        else => return false,
    };
    const finish = switch (first.get("finish_reason") orelse return false) {
        .string => |str| str,
        else => return false,
    };
    return std.mem.eql(u8, finish, "length");
}

// ─── Use-case (network) ────────────────────────────────────────────────────

/// Probe a CLI backend profile by running `<binary> --version`. Goes through
/// `helpers.run_captured` — the only sanctioned spawn path in this codebase.
fn llmTestProbeCli(
    allocator: std.mem.Allocator,
    logger: *loggermod.Logger,
    io: std.Io,
    req: LlmTestRequest,
    backend_label: []const u8,
    binary: []const u8,
    argv: [][]const u8,
    describe: *const fn (
        std.mem.Allocator,
        []const u8,
        bool,
        bool,
        []const u8,
        []const u8,
    ) anyerror![]u8,
) LlmTestError!LlmTestOutcome {
    const start_ns = helpers.monotonicTimestampNanos();

    var result = helpers.run_captured.run(
        allocator,
        io,
        argv,
        .{ .timeout_ms = TEST_LLM_TIMEOUT_MS },
    ) catch |err| {
        // Spawn-level failure is the normal "not installed" case, not an
        // exceptional one: report it as a readable message rather than
        // surfacing a bare error name the modal cannot explain.
        logger.warnFmt("[llm_test] {s} probe could not spawn '{s}': {s}", .{ backend_label, binary, @errorName(err) });
        const reply = describe(allocator, binary, true, false, "", "") catch
            return LlmTestError.OutOfMemory;
        return .{ .model = req.model, .reply = reply, .latency_ms = 0 };
    };
    defer result.deinit(allocator);

    const latency_ms: i64 = @intCast((helpers.monotonicTimestampNanos() - start_ns) / std.time.ns_per_ms);
    const exited_zero = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    logger.infoFmt(
        "[llm_test] {s} probe binary='{s}' exited_zero={} latency={d}ms",
        .{ backend_label, binary, exited_zero, latency_ms },
    );

    const reply = describe(
        allocator,
        binary,
        false,
        exited_zero,
        result.stdout,
        result.stderr,
    ) catch return LlmTestError.OutOfMemory;

    return .{ .model = req.model, .reply = reply, .latency_ms = latency_ms };
}

/// Probe a Claude Code profile by running `claude --version`.
fn llmTestProbeClaudeCode(
    allocator: std.mem.Allocator,
    logger: *loggermod.Logger,
    io: std.Io,
    req: LlmTestRequest,
) LlmTestError!LlmTestOutcome {
    const binary = claude_code.resolveBinaryPath("");
    const argv = claude_code.buildVersionProbeArgs(allocator, binary) catch
        return LlmTestError.OutOfMemory;
    defer claude_code.freeArgs(allocator, argv);
    return llmTestProbeCli(
        allocator,
        logger,
        io,
        req,
        "claude-code",
        binary,
        argv,
        claude_code.describeVersionProbe,
    );
}

/// Probe an OpenCode profile by running `opencode --version`.
fn llmTestProbeOpencode(
    allocator: std.mem.Allocator,
    logger: *loggermod.Logger,
    io: std.Io,
    req: LlmTestRequest,
) LlmTestError!LlmTestOutcome {
    const binary = opencode.resolveBinaryPath("");
    const argv = opencode.buildVersionProbeArgs(allocator, binary) catch
        return LlmTestError.OutOfMemory;
    defer opencode.freeArgs(allocator, argv);
    return llmTestProbeCli(
        allocator,
        logger,
        io,
        req,
        "opencode",
        binary,
        argv,
        opencode.describeVersionProbe,
    );
}

/// Probe the candidate, retrying once with a bigger output budget when the
/// provider reports the first attempt was cut off mid-reasoning.
fn llmTestUseCase(
    allocator: std.mem.Allocator,
    logger: *loggermod.Logger,
    io: std.Io,
    req: LlmTestRequest,
    out_err_detail: *?[]const u8,
) LlmTestError!LlmTestOutcome {
    try llmTestValidate(req);

    // Claude Code is a local CLI backend, not an HTTP endpoint: there is no
    // POST to make.
    if (std.mem.eql(u8, req.backend, "claude-code")) {
        return llmTestProbeClaudeCode(allocator, logger, io, req);
    }
    if (std.mem.eql(u8, req.backend, "opencode")) {
        return llmTestProbeOpencode(allocator, logger, io, req);
    }

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();

    return llmTestProbeOnce(
        allocator,
        logger,
        &client,
        req,
        PROBE_MAX_OUTPUT_TOKENS,
        out_err_detail,
    ) catch |err| {
        if (err != LlmTestError.ReasoningBudgetExhausted) return err;
        logger.warnFmt(
            "[llm_test] output budget exhausted by reasoning; retrying with {d} tokens",
            .{PROBE_MAX_OUTPUT_TOKENS_RETRY},
        );
        // The first attempt left a body snippet in `out_err_detail`; it
        // describes an attempt we are about to supersede, and the retry owns
        // the outcome from here.
        if (out_err_detail.*) |detail| {
            allocator.free(detail);
            out_err_detail.* = null;
        }
        return llmTestProbeOnce(
            allocator,
            logger,
            &client,
            req,
            PROBE_MAX_OUTPUT_TOKENS_RETRY,
            out_err_detail,
        );
    };
}

/// One probe: build the body at `max_output_tokens`, POST it, decode the
/// reply. Owns nothing the caller must free except the outcome's reply.
fn llmTestProbeOnce(
    allocator: std.mem.Allocator,
    logger: *loggermod.Logger,
    client: *custom_http_client.Client,
    req: LlmTestRequest,
    max_output_tokens: u32,
    out_err_detail: *?[]const u8,
) LlmTestError!LlmTestOutcome {
    const body = try llmTestBuildProbeBody(allocator, req, max_output_tokens);
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
    // Console Go / Zen routing requires `x-opencode-session` on every request
    // (see PROBE_SESSION_ID).
    header_buf[header_count] = .{ .name = "x-opencode-session", .value = PROBE_SESSION_ID };
    header_count += 1;

    const start_ns = helpers.monotonicTimestampNanos();
    const result = custom_http_client.post(
        client,
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
        // Include a body snippet: both a wrong-style success (an HTML login
        // page from a bad base_url) and a reasoning-only truncation are
        // diagnosable from the bytes the provider actually sent.
        const snippet_len: usize = @min(result.body.len, 200);
        out_err_detail.* = std.fmt.allocPrint(
            allocator,
            "{s}: {s}",
            .{
                if (err == error.ReasoningBudgetExhausted) "body had no text" else "unparseable body",
                result.body[0..snippet_len],
            },
        ) catch null;
        return err;
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
    const outcome = llmTestUseCase(allocator, logger, di.io, parsed, &err_detail) catch |err| {
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
            // Not the same failure: the body WAS a valid reply, the model just
            // never got to write any text because its hidden reasoning used up
            // the whole output budget. "Your key is broken" would be a lie.
            error.ReasoningBudgetExhausted => "model returned only reasoning and no reply text — the output budget ran out",
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

test "llm_test validate: claude-code backend needs model only, no base_url" {
    const req: LlmTestRequest = .{ .model = "sonnet", .base_url = "", .backend = "claude-code" };
    try llmTestValidate(req);
    const missing: LlmTestRequest = .{ .model = "", .base_url = "", .backend = "claude-code" };
    try testing.expectError(LlmTestError.MissingModel, llmTestValidate(missing));
}

test "llm_test validate: url_style is irrelevant to the claude-code backend" {
    // Claude Code never builds a wire body, so a garbage url_style must not
    // fail the probe — the discriminator is `backend`, not `url_style`.
    const req: LlmTestRequest = .{
        .model = "sonnet",
        .base_url = "not-a-url",
        .url_style = "garbage",
        .backend = "claude-code",
    };
    try llmTestValidate(req);
}

test "llm_test validate: claude-code in url_style is just an unknown style" {
    // The old overload is gone: with backend=http (the default), a
    // "claude-code" url_style is an unsupported WIRE FORMAT, and base_url is
    // still required.
    const req: LlmTestRequest = .{
        .model = "m",
        .base_url = "http://127.0.0.1:9/x",
        .url_style = "claude-code",
    };
    try testing.expectError(LlmTestError.UnsupportedStyle, llmTestValidate(req));
}

test "llm_test validate: opencode backend needs model only, no base_url" {
    const req: LlmTestRequest = .{ .model = "opencode-go/deepseek-flash", .base_url = "", .backend = "opencode" };
    try llmTestValidate(req);
    const missing: LlmTestRequest = .{ .model = "", .base_url = "", .backend = "opencode" };
    try testing.expectError(LlmTestError.MissingModel, llmTestValidate(missing));
}

test "llm_test validate: url_style is irrelevant to the opencode backend" {
    // OpenCode never builds a wire body, so a garbage url_style must not
    // fail the probe — the discriminator is `backend`, not `url_style`.
    const req: LlmTestRequest = .{
        .model = "opencode-go/deepseek-flash",
        .base_url = "not-a-url",
        .url_style = "garbage",
        .backend = "opencode",
    };
    try llmTestValidate(req);
}

test "llm_test buildProbeBody: openai body carries model + probe prompt" {
    const req: LlmTestRequest = .{ .model = "MiniMax-M2.7", .base_url = "http://x", .url_style = "openai" };
    const body = try llmTestBuildProbeBody(testing.allocator, req, PROBE_MAX_OUTPUT_TOKENS);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "MiniMax-M2.7") != null);
    try testing.expect(std.mem.indexOf(u8, body, PROBE_PROMPT) != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
}

test "llm_test buildProbeBody: openai-response body uses input + max_output_tokens" {
    const req: LlmTestRequest = .{ .model = "gpt-5", .base_url = "http://x", .url_style = "openai-response" };
    const body = try llmTestBuildProbeBody(testing.allocator, req, PROBE_MAX_OUTPUT_TOKENS);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"input\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "max_output_tokens") != null);
}

test "llm_test buildProbeBody: anthropic body uses max_tokens + messages" {
    const req: LlmTestRequest = .{ .model = "claude-x", .base_url = "http://x", .url_style = "anthropic" };
    const body = try llmTestBuildProbeBody(testing.allocator, req, PROBE_MAX_OUTPUT_TOKENS);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, PROBE_PROMPT) != null);
}

// The budget is the fix for "Test says the profile is broken, the profile
// works in a chat turn": the output budget is shared with the model's hidden
// reasoning tokens, so a handful of them is spent thinking and the probe gets
test "llm_test buildProbeBody: the requested budget leaves room for reasoning (all styles)" {
    const styles = [_][]const u8{ "openai", "openai-response", "anthropic" };
    const budgets = [_]u32{ PROBE_MAX_OUTPUT_TOKENS, PROBE_MAX_OUTPUT_TOKENS_RETRY };
    for (styles) |style| {
        for (budgets) |budget| {
            const req: LlmTestRequest = .{ .model = "m", .base_url = "http://x", .url_style = style };
            const body = try llmTestBuildProbeBody(testing.allocator, req, budget);
            defer testing.allocator.free(body);

            var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
            defer parsed.deinit();
            const root = switch (parsed.value) {
                .object => |o| o,
                else => return error.TestUnexpectedResult,
            };
            const field = if (std.mem.eql(u8, style, "openai-response")) "max_output_tokens" else "max_tokens";
            const value = switch (root.get(field) orelse return error.TestUnexpectedResult) {
                .integer => |i| i,
                else => return error.TestUnexpectedResult,
            };
            // 16 was the old value; anything the model could spend entirely on
            // thinking reproduces the bug.
            try testing.expect(value > 100);
            try testing.expectEqual(@as(i64, @intCast(budget)), value);
        }
    }
}

// The retry only helps if it offers MORE room; a second identical probe is a
// second wasted call.
test "llm_test retry budget is bigger than the first probe's" {
    try testing.expect(PROBE_MAX_OUTPUT_TOKENS_RETRY > PROBE_MAX_OUTPUT_TOKENS);
}

// Regression, in the unit layer: the exact body the Test button got back from
// a Responses gateway whose model spent the whole 16-token budget thinking.
test "llm_test extractReply: reasoning-only truncation is a budget exhaustion, not a missing reply" {
    const raw =
        \\{"id":"resp_1","object":"response","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"id":"rs_1","type":"reasoning","summary":[]}]}
    ;
    try testing.expectError(
        LlmTestError.ReasoningBudgetExhausted,
        llmTestExtractReply(testing.allocator, "openai-response", raw),
    );
}

// An `incomplete` response with no stated reason is still a truncation: the
// signal we need to stay silent is a DIFFERENT reason, not an absent one.
test "llm_test extractReply: incomplete with no reason is still a budget exhaustion" {
    const raw =
        \\{"id":"resp_1","object":"response","status":"incomplete","output":[{"id":"rs_1","type":"reasoning"}]}
    ;
    try testing.expectError(
        LlmTestError.ReasoningBudgetExhausted,
        llmTestExtractReply(testing.allocator, "openai-response", raw),
    );
}

// A different incomplete reason (content filter) is NOT a budget problem, and
// must not be retried as one.
test "llm_test extractReply: incomplete from a content filter is not a budget exhaustion" {
    const raw =
        \\{"id":"resp_1","object":"response","status":"incomplete","incomplete_details":{"reason":"content_filter"},"output":[]}
    ;
    try testing.expectError(
        LlmTestError.InvalidResponse,
        llmTestExtractReply(testing.allocator, "openai-response", raw),
    );
}

// The chat-completions and Anthropic spellings of the same thing.
test "llm_test extractReply: truncated non-responses styles report a budget exhaustion" {
    const chat =
        \\{"id":"chatcmpl-1","choices":[{"message":{"role":"assistant","content":""},"finish_reason":"length"}]}
    ;
    try testing.expectError(
        LlmTestError.ReasoningBudgetExhausted,
        llmTestExtractReply(testing.allocator, "openai", chat),
    );
    const anthropic =
        \\{"id":"msg_1","content":[],"stop_reason":"max_tokens"}
    ;
    try testing.expectError(
        LlmTestError.ReasoningBudgetExhausted,
        llmTestExtractReply(testing.allocator, "anthropic", anthropic),
    );
}

// A plain "there is no reply in here" body is unchanged: an error envelope or
// a wrong-style success still reads as `InvalidResponse`.
test "llm_test extractReply: a body with no reply and no truncation stays InvalidResponse" {
    const raw =
        \\{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}
    ;
    try testing.expectError(
        LlmTestError.InvalidResponse,
        llmTestExtractReply(testing.allocator, "openai-response", raw),
    );
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

// ===== Tests merged from mcp_test.zig (2026-09-29 flatten) ===== `POST
// /api/mcp/test` — try a candidate MCP server config WITHOUT saving.

const builtin = @import("builtin");
const mcp_stdio = pabrikcore.mcp_stdio;
const tool_models = pabrikcore.tool_models;

/// Per-call deadline for HTTP probes (libcurl has OS-level timeout
/// support). See the "Timeout model" comment at the top.
const TEST_HTTP_TIMEOUT_MS: u32 = 10_000;

/// Per-call deadline for stdio probes (mcp_stdio.zig polls this between bytes
/// read).
const TEST_STDIO_TIMEOUT_MS: u64 = 10_000;

/// Maximum attempts for the stdio probe.
const TEST_STDIO_MAX_ATTEMPTS: u8 = 20;

/// Sleep between cold-start retries. 500 ms gives the SDK enough time to
/// finish `mcp.connect(transport)` + attach its `'data'` listener on the
/// fresh spawn; small enough that the worst-case user latency is ~2s (cold
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

/// Try a single MCP server candidate. Returns either the parsed tools (on
/// success) or a `McpTestError`.
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

/// Try a stdio candidate: spawn the child, send `tools/list` as raw NDJSON,
/// parse the response.
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

    // Stable preview name per config (hash of command + args).
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

    // Build the MCP handshake + tools/list bodies once. The SDK expects
    // line-delimited JSON on stdin. Wire sequence (per MCP spec): 1.
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

    // Cold-start race retry: CI (macOS, Linux, Windows) sees intermittent
    // `UnexpectedEof` because `process.spawn` returns BEFORE the child (sh
    // wrapper → exec node → SDK connect → attach `_stdin.on('data')`) has
    var attempts_codes: [20 * 8]u8 = undefined;
    var stderrs_buf: [20][]const u8 = .{""} ** 20;
    var attempts_used: usize = 0;

    // `recordAttempt` appends the attempt's outcome to the diagnostic
    // buffers.
    const freeStderrs = struct {
        fn call(a: std.mem.Allocator, stderrs: []const []const u8, count: usize) void {
            for (stderrs[0..count]) |s| a.free(s);
        }
    }.call;

    var attempt: u8 = 1;
    while (true) : (attempt += 1) {
        // Bounded + cancellable lease: one child per server, shared with the
        // agent sessions, and the retry loop below would multiply an unbounded
        // wait by TEST_STDIO_MAX_ATTEMPTS.
        var lease = reg.acquire(preview_name, argv, .{
            .wait_ns = 60 * std.time.ns_per_s,
        }) catch |err| {
            logger.warnFmt("[mcp_test] stdio lease failed for command '{s}': {s}", .{ req.command, @errorName(err) });
            const msg = std.fmt.allocPrint(allocator, "lease:{s}", .{@errorName(err)}) catch null;
            freeStderrs(allocator, &stderrs_buf, attempts_used);
            out_err_detail.* = msg;
            // Busy is NOT a spawn failure — retrying stacks the wait budget.
            if (err == error.LeaseTimeout) return McpTestError.Timeout;
            return McpTestError.SpawnFailed;
        };
        defer lease.release();
        const client = lease.client();

        const stdin_file = client.stdin orelse {
            freeStderrs(allocator, &stderrs_buf, attempts_used);
            out_err_detail.* = std.fmt.allocPrint(allocator, "no_stdin", .{}) catch null;
            return McpTestError.SendFailed;
        };

        // Send ONLY `initialize` first.
        std.Io.File.writeStreamingAll(stdin_file, io, init_body) catch |err| {
            logger.warnFmt("[mcp_test] stdio send failed: {s}", .{@errorName(err)});
            if (attempts_used < 20) {
                const stderr_dup = allocator.dupe(u8, @errorName(err)) catch
                    allocator.dupe(u8, "OOM") catch @panic("dupe failed for the mcp_test stderr error name");
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
                // Silent-but-alive child (e.g. bare `python` with empty args,
                // waiting on stdin for EOF): it started fine but never
                // answered `initialize`.
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

        // The server has answered `initialize`, so the session is live. NOW
        // send `notifications/initialized` followed by the `tools/list`
        // request.
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
                    allocator.dupe(u8, "OOM") catch @panic("dupe failed for the mcp_test stderr error name");
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

/// Drain whatever is available on the child's stderr pipe. ALWAYS returns a
/// HEAP-allocated slice (caller frees), even when the pipe is empty or the
/// read failed.
fn drainStderr(allocator: std.mem.Allocator, io: std.Io, stderr: ?std.Io.File) []u8 {
    // Always heap-allocate so the caller can uniformly `free` the
    // returned slice. The empty fallback is also heap so `free` is
    // safe even when no bytes were captured.
    const empty = allocator.dupe(u8, "") catch allocator.dupe(u8, "") catch @panic("dupe failed for the empty mcp_test stderr slot");
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
    // Single-shot read: whatever is in the kernel pipe buffer RIGHT NOW (up
    // to 4 KiB).
    const n = std.Io.Reader.readSliceShort(&reader.interface, &buf) catch return empty;
    if (n == 0) return empty;
    return allocator.dupe(u8, buf[0..n]) catch empty;
}

/// Build a JSON-formatted diagnostic string for the failed response body.
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
        // Sanitize: replace control chars with their backslash-escaped form
        // so the resulting JSON is parseable.
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

/// Try an HTTP candidate: POST `tools/list` to the URL with the headers,
/// parse `result.tools[]`. Uses libcurl's built-in 10s timeout via
/// `timeout_ms`.
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
    // No `data:` line found (e.g. legacy single-line `data: {...}` without
    // event framing is already covered above, but keep the old prefix-strip
    // as a last resort) — fall back to the trimmed body so the JSON parser
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
    // Regression guard for CI macOS ARM64 (commit 76d03d6d + this fix): the
    // SDK's mcp.connect failure path writes ANSI-coloured stack traces to
    // stderr containing \\x1b (ESC) and \\n bytes.
    const allocator = testing.allocator;

    // Build a stderr blob with: ESC, newline, NUL, BEL, printable.
    const dirty_stderr = "\x1b[31mfatal\x1b[0m: \nmcp.connect failed\n\x00\x07";
    var stderrs = [_][]const u8{dirty_stderr};
    // Mirror production code: codes buffer is 8 bytes per attempt, padded
    // with SPACE (0x20) after the short code.
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
    // "<err>|attempts=N/M codes=[<codes>]|last_stderr=<sanitized>" The
    // response handler then embeds this into the JSON response body via
    try testing.expect(std.mem.indexOf(u8, detail, "\\n") != null);
    // ESC (0x1b) was stripped entirely (not even present in escape form).
    try testing.expect(std.mem.indexOf(u8, detail, "\x1b") == null);
    // Printable text preserved.
    try testing.expect(std.mem.indexOf(u8, detail, "fatal") != null);

    // CRITICAL: embed `detail` into a JSON document and parse it back. If any
    // control char survived, std.json will raise SyntaxError (which on the
    // Python test client is `json.loads: Invalid control character`).
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

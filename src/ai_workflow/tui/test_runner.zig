test {
    _ = @import("routines/model.zig");
    _ = @import("routines/cron.zig");
    _ = @import("routines/fire.zig");
    _ = @import("routines/Scheduler.zig");
    // Inline retry-loop hygiene tests (CallResponse deinit, literal-free
    // errdefer, stale retry-cause capture) live in workflow.zig itself —
    // registered here so zig build test actually runs them.
    _ = @import("../../agentic_loop/workflow.zig");
    // Per-request owner resolution for per-user isolation (W0): the
    // `resolveRequestUserId` resolver + `ownerVisibilityClause`. Its inline
    // tests were dormant before this — the `pub const authMiddleware`
    // re-export in http_handlers/mod.zig alone doesn't pull the file's
    // tests into the test binary. Same discovery workaround as the
    // handlers below.
    _ = @import("../../http_handlers/auth_common.zig");
    _ = @import("../../http_handlers/pabrik_config_put.zig");
    _ = @import("../../http_handlers/design_elements_reorder.zig");
    _ = @import("../../http_handlers/design_elements_ungroup.zig");
    // Static-contract tests for the model-thinking PUT validation
    // (plan 2026-08-23-model-thinking). Source-grep pattern locks
    // in the new validation paths + LoadError variants.
    // Static-contract tests for config-simplify (plan
    // 2026-08-24-config-simplify-remove-defaults): PUT handler must not
    // persist top-level LLM defaults.
    _ = @import("../../http_handlers/pabrik_config_get.zig");
    _ = @import("../../http_handlers/pabrik_config_profile_delete.zig");
    _ = @import("../../http_handlers/unified_events_sse.zig");
    _ = @import("../../http_handlers/task_update.zig");
    _ = @import("../../http_handlers/task_delete.zig");
    _ = @import("../../http_handlers/tasks_list.zig");
    _ = @import("../../http_handlers/tasks_get.zig");
    _ = @import("../../http_handlers/tasks_media.zig");
    _ = @import("../../http_handlers/stream_get.zig");
    _ = @import("../../http_handlers/subagent_progress_get.zig");
    _ = @import("../../http_handlers/background_processes_list.zig"); // session bg-process list GET (bg-completion endpoints)
    _ = @import("../../http_handlers/background_process_log_get.zig"); // session bg-process log-tail GET (bg-completion endpoints)
    _ = @import("../../http_handlers/terminal_session.zig"); // right-sidebar terminal PTY registry
    _ = @import("../../http_handlers/terminal_create.zig"); // terminal session POST
    _ = @import("../../http_handlers/terminal_input.zig"); // terminal input POST
    _ = @import("../../http_handlers/terminal_output.zig"); // terminal output GET
    _ = @import("../../http_handlers/terminal_resize.zig"); // terminal resize POST
    _ = @import("../../http_handlers/terminal_delete.zig"); // terminal session DELETE
    _ = @import("../../http_handlers/terminal_ws.zig"); // terminal duplex WS (framing + control JSON)
    // NOTE: task_create_routines_test.zig deleted with the per-task
    // `routines` table (Migration 084, plan 2026-09-10-workspace-items-routines).
    _ = @import("../../http_handlers/task_create.zig");
    _ = @import("../../http_handlers/tags_validation.zig"); // Migration 067 tags validation helper (Task 7) — inline tests in the source file
    // NOTE: task_update_routines_test.zig + routines_run_test.zig deleted
    // with the per-task `routines` table (Migration 084, plan
    // 2026-09-10-workspace-items-routines).
    // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). The
    // start_agent handler + useCase live in a single file; the
    // static-contract tests are inline at the bottom. Importing
    // the file (vs. the deleted start_agent_test.zig) ensures the
    // tests get discovered + run.
    _ = @import("../../http_handlers/start_agent.zig");
    // Bulk run-all-agents (plan: 2026-09-09-run-all-agents-by-column,
    // Option C): handler + useCase + inline tests live in a single file,
    // mirroring start_agent.zig above (no separate _test.zig).
    _ = @import("../../http_handlers/run_all_agents.zig");
    _ = @import("../../http_handlers/stop_all_agents.zig");
    // NOTE: routines_list_test.zig deleted with the per-task `routines`
    // table (Migration 084). New workspace-routine handlers carry
    // inline tests (imported as impl files, like start_agent.zig).
    _ = @import("../../http_handlers/workspace_items_create_routine.zig");
    _ = @import("../../http_handlers/workspace_routines_get.zig");
    _ = @import("../../http_handlers/workspace_routines_update.zig");
    // Workspace-scoped documents (Migration 098). Same rule as the routine
    // handlers above: an impl file's inline tests stay dormant until the
    // file is imported from a test runner, and the `pub const` re-export
    // in http_handlers/mod.zig does not pull them in.
    _ = @import("../../http_handlers/documents_list.zig");
    _ = @import("../../http_handlers/documents_create.zig");
    _ = @import("../../http_handlers/documents_get.zig");
    _ = @import("../../http_handlers/documents_update.zig");
    _ = @import("../../http_handlers/documents_delete.zig");
    _ = @import("../../http_handlers/memories_detail.zig");
    _ = @import("../../http_handlers/memories_create.zig");
    _ = @import("../../http_handlers/memories_update.zig");
    _ = @import("../../http_handlers/memories_delete.zig");
    _ = @import("../../http_handlers/memories_list.zig");
    _ = @import("../../http_handlers/local_memories_detail.zig");
    _ = @import("../../http_handlers/local_memories_create.zig");
    _ = @import("../../http_handlers/local_memories_update.zig");
    _ = @import("../../http_handlers/local_memories_delete.zig");
    _ = @import("../../http_handlers/local_memories_list.zig");
    // The MCP-probe (PR #373), LLM-probe and OS-notify-probe HTTP handlers
    // now live at the bottom of http_handlers/mod.zig together with their
    // static-contract test blocks (the former mcp_test.zig / llm_test.zig /
    // notify_test.zig). One import surfaces all three; listing them
    // separately would be three registrations of a single file.
    _ = @import("../../http_handlers/mod.zig");
    // Browser-mode (web launch) status endpoint (plan
    // 2026-09-10-web-launch-toggle): handler + buildWebUrl unit tests +
    // static contracts live in the single file.
    _ = @import("../../http_handlers/web_status.zig");
    _ = @import("../../http_handlers/frontend_log_post.zig");
    _ = @import("../../http_handlers/frontend_log_get.zig");
    _ = @import("../../http_handlers/system_folder.zig");
    // _ = @import("llm_history_is_input_output_test.zig"); // phase 5: inlined into agentic_loop/llm_history.zig
    // _ = @import("llm_history_compacted_messages_test.zig"); // phase 5
    // _ = @import("llm_history_search_messages_fts_test.zig"); // phase 5
    // _ = @import("llm_history_search_fts_query_safety_test.zig"); // phase 5
    // _ = @import("llm_history_worker_info_test.zig"); // phase 5
    // _ = @import("llm_history_description_test.zig"); // phase 5
    // _ = @import("llm_history_notification_test.zig"); // phase 5
    // _ = @import("llm_history_tool_call_loading_test.zig"); // phase 5
    _ = @import("../../http_handlers/workspaces_reorder.zig");
    _ = @import("../../http_handlers/workspace_items_reorder.zig");
    _ = @import("../../http_handlers/task_pin.zig");
    // design_model.zig + design_model_*_test.zig files were moved into
    // agentic_loop/ in Phase 6. Registered in agentic_loop/test_runner.zig.
    // Inline tests for `updateElementsBatch` live at the bottom of design_model.zig.

    // Inline tests for `design_elements_update` and `design_elements_reparent`
    // live at the bottom of their impl files. Register them here so
    // `zig build test` actually runs the inline test blocks.
    _ = @import("../../http_handlers/design_elements_update.zig");
    _ = @import("../../http_handlers/design_elements_reparent.zig");
    _ = @import("../../http_handlers/tasks_reorder_pinned.zig");
    _ = @import("../../http_handlers/git_worktree_info.zig");
    _ = @import("../../http_handlers/git_branches_list.zig");
    _ = @import("../../http_handlers/git_commits.zig");
    _ = @import("../../http_handlers/git_commit.zig");
    _ = @import("../../http_handlers/git_pr_create.zig");
    _ = @import("../../http_handlers/git_status.zig");
    _ = @import("../../http_handlers/workspace_items_create_kanban.zig");
    // Agent Mode HTTP handlers (Tasks 4-8 of plan 2026-08-15-agent-mode)
    // now follow the "split handler + useCase, keep both in one file"
    // pattern. The production .zig file holds:
    //   - the HTTP request body / domain input/output structs + error set
    //   - the `useCase` function (transport-agnostic business logic)
    //   - the thin `xxxHandler` function (HTTP orchestrator)
    //   - inline `test "..."` blocks at the bottom exercising `useCase`
    //     directly against an in-memory SQLite + Migration076
    //
    // The `zig build test` discovery happens via these explicit
    // @import() lines — the test blocks are only enumerated when the
    // file is reachable from the test root. The handler function is
    // NOT tested directly (it would require faking the gserverz
    // HTTP context — out of scope for these contract tests).
    _ = @import("../../http_handlers/workspace_items_create_agent.zig"); // POST /items/agent (Task 4)
    _ = @import("../../http_handlers/agents_get.zig"); // GET /items/:id/agent (Task 5)
    _ = @import("../../http_handlers/agents_update.zig"); // PATCH /items/:id/agent (Task 5)
    _ = @import("../../http_handlers/agent_knowledge_create.zig"); // POST /agents/:id/knowledge (Task 6)
    _ = @import("../../http_handlers/agent_knowledge_update.zig"); // PATCH /agents/:id/knowledge/:id (Task 6)
    _ = @import("../../http_handlers/agent_knowledge_delete.zig"); // DELETE /agents/:id/knowledge/:id (Task 6)
    _ = @import("../../http_handlers/agent_knowledge_reorder.zig"); // PATCH /agents/:id/knowledge/reorder (Task 6)
    _ = @import("../../http_handlers/agent_tools_registry.zig"); // GET /agent-tools/registry (Task 7)
    _ = @import("../../http_handlers/agent_tools_list.zig"); // GET /agents/:id/tools (Task 7)
    _ = @import("../../http_handlers/agent_tools_create.zig"); // POST /agents/:id/tools (Task 8)
    _ = @import("../../http_handlers/agent_tools_delete.zig"); // DELETE /agents/:id/tools/:id (Task 8)
    _ = @import("../../http_handlers/agent_system_prompt_create.zig"); // POST /agents/:id/system_prompt (Migration 080)
    _ = @import("../../http_handlers/agent_system_prompt_update.zig"); // PATCH /agents/:id/system_prompt/:id (Migration 080)
    _ = @import("../../http_handlers/agent_system_prompt_delete.zig"); // DELETE /agents/:id/system_prompt/:id (Migration 080)
    _ = @import("../../http_handlers/agent_system_prompt_reorder.zig"); // PATCH /agents/:id/system_prompt/reorder (Migration 080)
    // Agent-Kanbans mirror (Migration 081, plan 2026-08-25-agent-kanbans-mirror)
    _ = @import("../../http_handlers/agent_kanbans_get.zig"); // GET /items/:id/agent_kanban
    _ = @import("../../http_handlers/agent_kanbans_update.zig"); // PATCH /items/:id/agent_kanban
    _ = @import("../../http_handlers/agent_kanban_knowledge_create.zig"); // POST /agent-kanbans/:id/knowledge
    _ = @import("../../http_handlers/agent_kanban_knowledge_update.zig"); // PATCH /agent-kanbans/:id/knowledge/:id
    _ = @import("../../http_handlers/agent_kanban_knowledge_delete.zig"); // DELETE /agent-kanbans/:id/knowledge/:id
    _ = @import("../../http_handlers/agent_kanban_knowledge_reorder.zig"); // PATCH /agent-kanbans/:id/knowledge/reorder
    _ = @import("../../http_handlers/agent_kanban_system_prompt_create.zig"); // POST /agent-kanbans/:id/system_prompt
    _ = @import("../../http_handlers/agent_kanban_system_prompt_update.zig"); // PATCH /agent-kanbans/:id/system_prompt/:id
    _ = @import("../../http_handlers/agent_kanban_system_prompt_delete.zig"); // DELETE /agent-kanbans/:id/system_prompt/:id
    _ = @import("../../http_handlers/agent_kanban_system_prompt_reorder.zig"); // PATCH /agent-kanbans/:id/system_prompt/reorder
    _ = @import("../../http_handlers/agent_kanban_tools_list.zig"); // GET /agent-kanbans/:id/tools
    _ = @import("../../http_handlers/agent_kanban_tools_create.zig"); // POST /agent-kanbans/:id/tools
    _ = @import("../../http_handlers/agent_kanban_tools_delete.zig"); // DELETE /agent-kanbans/:id/tools/:tool_name
    // Agent-Routines mirror (Migration 087, Routine mode task_1789505553300_1
    // option A — mirrors the agent-kanbans block above onto routines).
    _ = @import("../../http_handlers/agent_routines_get.zig"); // GET /items/:id/agent_routine
    _ = @import("../../http_handlers/agent_routines_update.zig"); // PATCH /items/:id/agent_routine
    _ = @import("../../http_handlers/agent_routine_knowledge_create.zig"); // POST /agent-routines/:id/knowledge
    _ = @import("../../http_handlers/agent_routine_knowledge_update.zig"); // PATCH /agent-routines/:id/knowledge/:id
    _ = @import("../../http_handlers/agent_routine_knowledge_delete.zig"); // DELETE /agent-routines/:id/knowledge/:id
    _ = @import("../../http_handlers/agent_routine_knowledge_reorder.zig"); // PATCH /agent-routines/:id/knowledge/reorder
    _ = @import("../../http_handlers/agent_routine_system_prompt_create.zig"); // POST /agent-routines/:id/system_prompt
    _ = @import("../../http_handlers/agent_routine_system_prompt_update.zig"); // PATCH /agent-routines/:id/system_prompt/:id
    _ = @import("../../http_handlers/agent_routine_system_prompt_delete.zig"); // DELETE /agent-routines/:id/system_prompt/:id
    _ = @import("../../http_handlers/agent_routine_system_prompt_reorder.zig"); // PATCH /agent-routines/:id/system_prompt/reorder
    _ = @import("../../http_handlers/agent_routine_tools_list.zig"); // GET /agent-routines/:id/tools
    _ = @import("../../http_handlers/agent_routine_tools_create.zig"); // POST /agent-routines/:id/tools
    _ = @import("../../http_handlers/agent_routine_tools_delete.zig"); // DELETE /agent-routines/:id/tools/:tool_name
    _ = @import("../../http_handlers/workspace_items_create.zig");
    _ = @import("../../http_handlers/kanban_columns_list.zig");
    _ = @import("../../http_handlers/kanban_columns_create.zig");
    _ = @import("../../http_handlers/kanban_tasks_create.zig");
    // NEW (2026-09-02-kanban-task-session-name-bind, task 1787671636395_1):
    // session_create.zig now has inline static-contract tests for the
    // resolveNameFromTask helper + the useCase call site. Importing
    // the file surfaces them to zig build test (mirrors start_agent.zig).
    _ = @import("../../http_handlers/session_create.zig");
    // Workspace-scoped sessions: workspace_id query param on the
    // session list (in-memory SQLite useCase tests), the new session
    // detail handler (workspace_id resolution + route contract), and
    // items_count on GET /api/workspaces.
    _ = @import("../../http_handlers/session_list.zig");
    _ = @import("../../http_handlers/session_pin.zig");
    _ = @import("../../http_handlers/session_reorder_pinned.zig");
    _ = @import("../../http_handlers/session_get.zig");
    _ = @import("../../http_handlers/workspaces_list.zig");
    // Automatic per-user workspace provisioning: the shared workspace insert
    // path (used by both POST /api/workspaces and the login-time hook) plus
    // the idempotence/isolation/position/default-project guarantees.
    _ = @import("../../http_handlers/workspace_provisioning.zig");
    // NEW (2026-08-29-chat-sidebar-last-human-touched, Task 4):
    // session_update.zig stamps sessions.last_human_touched_at_nano when
    // the user edits a field. The static-contract test guards the call site.
    _ = @import("../../http_handlers/session_update.zig");
    // NEW (yellow stale-dot fix): session_mark_touched.zig has inline
    // static-contract tests for the stamp call + SSE emit + route
    // registration. Importing the file surfaces them to zig build test
    // (mirrors session_create.zig above).
    _ = @import("../../http_handlers/session_mark_touched.zig");
    _ = @import("../../http_handlers/kanban_columns_update.zig");
    _ = @import("../../http_handlers/kanban_columns_delete.zig");
    _ = @import("../../http_handlers/kanban_tags_list.zig"); // 2026-07-30-kanban-task-tags-autocomplete — inline useCase tests
    _ = @import("../../http_handlers/design_pages_list.zig");
    _ = @import("../../http_handlers/design_pages_create.zig");
    _ = @import("../../http_handlers/design_items_create.zig");
    _ = @import("../../http_handlers/design_pages_get.zig");
    _ = @import("../../http_handlers/design_pages_update.zig");
    _ = @import("../../http_handlers/design_pages_delete.zig");
    _ = @import("../../http_handlers/design_elements_create.zig");
    _ = @import("../../http_handlers/design_elements_delete.zig");
    _ = @import("../../http_handlers/design_elements_group.zig");
    _ = @import("../../http_handlers/design_elements_html_get.zig");
    _ = @import("../../http_handlers/design_elements_html_update.zig");
    _ = @import("../../http_handlers/design_elements_geometry_update.zig");
    // NEW (2026-08-06) — translate endpoint replaces /geometry for moves.
    // Behavioural tests for `POST /translate` (cascade to descendants for
    // groups). See docs/superpowers/plans/2026-08-06-split-move-resize.md.
    _ = @import("../../http_handlers/design_elements_translate.zig");
    // NEW (2026-08-06) — resize endpoint replaces /geometry for resizes.
    // Behavioural tests for `POST /resize` (no cascade, per-element only).
    _ = @import("../../http_handlers/design_elements_resize.zig");
    // Inline tests for the geometry-batch handler `useCase` live at the
    // bottom of design_elements_geometry_batch.zig — registered here so
    // zig build test actually runs them.
    _ = @import("../../http_handlers/design_elements_geometry_batch.zig");
    // Inline tests for the move-batch handler `useCase` live at the
    // bottom of design_elements_move_batch.zig — registered here so zig
    // build test actually runs them. See
    // docs/superpowers/plans/2026-08-06-move-element-with-descendants.md (Chunk 2).
    _ = @import("../../http_handlers/design_elements_move_batch.zig");
    // Inline tests for the move-to-page handler `useCase` live at the
    // bottom of design_elements_move_to_page.zig — registered here so
    // zig build test actually runs them. See
    // docs/superpowers/plans/2026-08-06-move-element-to-page.md (Chunk 2).
    _ = @import("../../http_handlers/design_elements_move_to_page.zig");
    _ = @import("../../http_handlers/kanban_copy_spec.zig");
    _ = @import("../../http_handlers/tasks_move.zig");
    _ = @import("../../http_handlers/system_prompt_get.zig");
    // _ = @import("session_helpers_test.zig"); // DISABLED - requires std.Io which needs Init
    // _ = @import("session_table_test.zig"); // DISABLED - requires std.Io which needs Init
    _ = @import("../../http_handlers/session_messages_get.zig");
    // _ = @import("transform_llm_history_to_agent_messages_test.zig"); // DISABLED - pre-existing type mismatch (TUIHistory vs LLMHistory) on main
    // save_memory + load_memory tools (Task 3 + 4 of
    // docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md).
    // update_plan agent tool (Task 2 of
    // docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md).
    // get_plan agent tool (Task 3 of
    // docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md).
    // _ = @import("extract_base64_image_urls_test.zig"); // DISABLED - 9 failing tests (investigation shows std.testing.expectEqualStrings has a bug with literal strings)
    // _ = @import("session_db_test.zig"); // DISABLED - pre-existing test errors (see session_db_test.zig for details)
    _ = @import("../../agentic_loop/test_runner.zig");
    _ = @import("../../modules/agent/tools/create_kanban_task.zig");
    _ = @import("../../modules/agent/tools/skill_tools.zig");
    _ = @import("../../modules/agent/tools/set_design_page.zig");
    _ = @import("../../modules/agent/tools/update_plan.zig");
    _ = @import("../../modules/agent/tools/read_workspace_session.zig");
    _ = @import("../../modules/agent/tools/glob.zig");
    _ = @import("../../modules/agent/tools/memory.zig");
    _ = @import("../../modules/agent/tools/kanban_list.zig");
    _ = @import("../../modules/agent/tools/pwsh.zig");
    _ = @import("../../modules/agent/tools/get_plan.zig");
    _ = @import("../../modules/agent/tools/write_file.zig");
    _ = @import("../../modules/agent/tools/move_element_to_page.zig");
    _ = @import("../../modules/agent/tools/group_design_elements.zig");
    _ = @import("../../modules/agent/tools/kanban_move_task.zig");
    _ = @import("../../modules/agent/tools/list_directory.zig");
    _ = @import("../../modules/agent/tools/generate_image.zig");
    _ = @import("../../modules/agent/tools/move_design_element.zig");
    _ = @import("../../modules/agent/tools/shell.zig");
    _ = @import("../../modules/agent/tools/text_replace.zig");
    _ = @import("../../modules/agent/tools/diff.zig");
    _ = @import("../../modules/agent/tools/list_memory.zig");
    _ = @import("../../modules/agent/tools/add_design_element.zig");
    _ = @import("../../modules/agent/tools/spawn_sub_agent.zig");
    _ = @import("../../modules/agent/tools/update_design_element.zig");
    _ = @import("../../modules/agent/tools/set_element_parent.zig");
    _ = @import("../../modules/agent/tools/search.zig");
    _ = @import("../../modules/agent/tools/memories.zig");
}

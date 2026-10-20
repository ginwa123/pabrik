// Test runner for the `agentic_loop/` directory. IMPORTANT: Zig's test runner
// only auto-discovers `test "..." { ... }` blocks in files that are
// **directly `@import`ed** here.

test {
    // ─── Files with inline tests ──────────────────────────────────────────
    // web_search_config: per-session provider resolution.
    _ = @import("web_search_config.zig");

    _ = @import("sse.zig");
    _ = @import("llm_history.zig");
    _ = @import("session_skills.zig");
    _ = @import("is_session_kanban.zig");
    _ = @import("is_worker_running.zig");
    _ = @import("is_worker_cancelled.zig");
    _ = @import("has_queue_messagge.zig");
    _ = @import("get_queue_message.zig");
    _ = @import("update_worker.zig");
    _ = @import("delete_worker.zig");
    _ = @import("insert_queue_message.zig");
    _ = @import("background_process.zig"); // bg-completion queue Task 1 — pure completion message helpers (no DB)
    _ = @import("delete_queue_worker.zig");
    _ = @import("insert_llm_histories.zig");
    _ = @import("get_llm_histories.zig");
    _ = @import("sse_send_event_worker.zig");
    _ = @import("sse_on_event_send_llm_history.zig");
    _ = @import("sse_on_event_send_session.zig"); // task_1786507100896 — behavioural tests for wire-format event_type_name mapping
    _ = @import("parsing.zig");
    _ = @import("workflow.zig");
    _ = @import("save_agent.zig"); // Phase 1 — save_agent module imports smoke test (was save_agent_test.zig)
    _ = @import("on_event_sent.zig"); // Phase 2 — inlined 7 tests from on_event_sent_sanitize_test.zig
    _ = @import("on_event_sent_design.zig"); // Phase 2 — inlined 5 tests from on_event_sent_design_test.zig
    _ = @import("inherited_context.zig"); // Phase 3 — inlined tests from inherited_context_test.zig
    _ = @import("agent_memories.zig"); // Phase 3 — inlined tests from agent_memories_test.zig
    _ = @import("skill_evals_db.zig"); // Skill Evals — usage ledger writers + parsing
    _ = @import("skill_evals_drift.zig"); // Skill Evals — Tier-0 deterministic checks
    _ = @import("run_skill_eval.zig"); // Skill Evals — the run_skill_eval tool
    _ = @import("skill_eval_events.zig"); // Skill Evals — the skill_evals SSE channel
    _ = @import("git_file_stage_events.zig"); // git_file_stage SSE channel — surgical row move on +/-
    _ = @import("git_pr_state_events.zig"); // git_pr_state SSE channel — badges re-read after a merge/close
    _ = @import("sub_agent_batch.zig"); // the one sub-agent batch runner (tool + judge tier)
    _ = @import("skill_eval_judge.zig"); // Skill Evals — the LLM judge tier's prompt + parser
    _ = @import("session_plan.zig"); // 2026-08-19-session-plan-agent-tool — inlined 6 tests from session_plan_test.zig
    _ = @import("retry_delay_ms.zig"); // inlined 1 stress test from retry_delay_ms_race_test.zig
    _ = @import("prompts_make_plan_context.zig"); // inlined 3 live-DB tests from prompts_make_plan_context_test.zig
    _ = @import("../modules/agent/tools/get_plan.zig"); // inlined 2 tests from get_plan_test.zig
    _ = @import("../modules/agent/tools/list_sub_agent.zig"); // list_sub_agent exec adapter + registry static contracts
    _ = @import("tool_eligibility.zig"); // allowlist + item-type eligibility (shared leaf module)
    _ = @import("progressive_catalog.zig"); // progressive tool catalog + result renderers
    _ = @import("progressive_regex.zig"); // search_tool's in-process regex engine (Pike VM + python-`re` oracle table)
    _ = @import("../modules/agent/tools/update_plan.zig"); // inlined 3 tests from update_plan_test.zig
    _ = @import("../modules/agent/tools/update_plan_text_replace.zig"); // the surgical plan edit
    _ = @import("../modules/agent/tools/memory.zig"); // merged save/load/delete exec wrappers + inlined 2 delete tests
    _ = @import("../modules/agent/tools/add_mcp_server.zig"); // 2026-08-28-add-mcp-server-agent-tool — Step 3 (exec wrapper)
    _ = @import("kanban_model.zig"); // Phase 4 — inlined tests from 3 kanban_model_*_test.zig files
    _ = @import("kanban_deps.zig"); // kanban task dependencies — id/graph validation + the edge store (in-memory DB tests)
    _ = @import("design_io.zig"); // Phase 4 — inlined tests from design_io_test.zig
    _ = @import("design_model.zig"); // Phase 6 — inline updateElementsBatch + indexOf tests
    _ = @import("workflow_compact_message.zig"); // merged 2026-09-10 (ex-workflow_commpact_message.zig typo): url_style regression + envelope + prompt/envelope helpers
    _ = @import("handle_tool.zig"); // 2026-08-06-fix-refactor-zig-imports — 16 inline parseDiffViewFromResult tests
    // MCP tool dispatch: the bounded + cancellable lease contract (runs without
    // this line too; registration is the project convention).
    _ = @import("handle_mcp_tool.zig");
    // (on_event_sent.zig, workflow.zig and tools_wrap_output.zig are already
    // registered above; their tool_calls_json wire-shape lock, fetch-once MCP
    // cache contracts and JSON tool-output envelope contract now live inline
    _ = @import("workflow_compact_message.zig"); // merged single file — helpers + orchestration + all inline tests
    _ = @import("prompts_make_working_directory_context.zig"); // never-create-memory-md — makeWorkingDirectoryContext must never force-create AGENTS.md / CLAUDE.md / PABRIK.md (inline tests at the bottom of the impl file)
    _ = @import("prompts_make_cross_project_context.zig"); // sibling-cwd loop from workspace_items only (inline in-memory DB tests)
    _ = @import("prompts_make_kanban_context.zig"); // kanban prompt — renders all columns at tail (no cap) so kanban_move_task is 1-call; in-memory DB tests
    // impl + tests are in the same .zig file for Agent Mode helpers.

    // 2026-08-14 — list_directory exec wrapper (Task 5 of the same plan).
    _ = @import("../modules/agent/tools/list_directory.zig");

    // 2026-08-14 — inline `test "...relative path..."` blocks at the
    // bottom of every tool's exec wrapper (follow-up commit proving
    // the validator + resolver wiring end-to-end).
    _ = @import("../modules/agent/tools/read_file.zig");
    _ = @import("../modules/agent/tools/write_file.zig");
    _ = @import("../modules/agent/tools/text_replace.zig");
    // Windows absolute paths in tool-call `arguments`: models emit the
    // separators as raw `\`, which is invalid JSON.
    _ = @import("tools_args_repair.zig");
    _ = @import("../modules/agent/tools/remove_file.zig");
    _ = @import("../modules/agent/tools/glob.zig");
    _ = @import("../modules/agent/tools/search.zig");
    _ = @import("../modules/agent/tools/skill_tools.zig");
    _ = @import("slash_skill_expand.zig"); // send-time /skill token expansion for session_create
    _ = @import("../modules/agent/tools/list_directory.zig");

    // task_1787855066467_8 — bash/pwsh lenient JSON argument parser.
    _ = @import("../modules/agent/tools/exec_bash_args.zig");
    // Shared model-facing error explanations.
    _ = @import("tools_error_explain.zig");
    _ = @import("../modules/agent/tools/command.zig");
    _ = @import("../modules/agent/tools/command.zig");
    _ = @import("../modules/agent/tools/command.zig");
    _ = @import("background_watcher.zig"); // immediate bg-completion watcher — poll PID, notify on exit (no cron wait)
    _ = @import("background_process_events.zig"); // bg-process SSE push (created/completed) — replaces 5s list poll

    // 2026-08-23 spawn-subagent-live-progress — `subagent_progress.zig`
    // builds the wire payload that rides the EXISTING `llm_full` SSE channel
    // with a NEW `role="subagent_progress"` value.
    _ = @import("subagent_progress.zig");
    // Static-contract tests live inline at the bottom of
    // `spawn_sub_agent.zig` — they grep the impl source for the 3
    // lifecycle emission points (launched / completed / failed) and that
    _ = @import("../modules/agent/tools/spawn_sub_agent.zig");
    // present_files exec adapter — the sandbox root it resolves from the
    // session row is what keeps a card servable by /api/files/download
    // (docs/plans/2026-09-29-present-files-sandbox-parity.md).
    _ = @import("../modules/agent/tools/present_files.zig");
    // 2026-09-02 stream-resume-on-reselect (task_1787673548905_0) —
    // in-flight stream buffer registry + snapshot getter. Tests inline.
    _ = @import("stream_snapshot.zig");
    // Workspace-scoped chat history — read/search/list other sessions
    // in the caller's workspace (replaces the global history search).
    _ = @import("../modules/agent/tools/read_workspace_session.zig");
    _ = @import("document_events.zig"); // documents SSE channel — sidebar list + open editor refresh
    _ = @import("../modules/agent/tools/document.zig"); // add_document + edit_document + delete_document + search_documents exec wrappers (Migration 098)
    _ = @import("documents_search.zig"); // matching / paging / rendering for the search_documents tool
    // Workspace-scoped chat history — session-to-workspace resolution
    // (task link + cwd heuristic) with in-memory SQLite tests.
    _ = @import("workspace_scope.zig");
    // Claude Code CLI backend — Phase 1: style predicate, profile
    // validation, `claude -p` argv builder, stream-json line parser.
    _ = @import("claude_code.zig");
    // OpenCode CLI backend — Phase 1: style predicate, profile validation,
    // `opencode run` argv builder, `--format json` line parser.
    _ = @import("opencode.zig");
}

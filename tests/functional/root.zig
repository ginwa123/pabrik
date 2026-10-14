//! Test root for the PRIBRIK functional suite.
//!
//! Every `*_test.zig` in this package is listed in `suites` below.
//! Zig only compiles `test` blocks the analysis REACHES from the root
//! source file, so a ported suite that is neither imported nor
//! referenced here simply does not run - silently. That is the whole
//! reason this list is explicit rather than globbed: it is the single
//! place where "this suite exists" is asserted, so a forgotten suite
//! fails loudly (an empty `suites`) instead of vanishing.
//!
//! The Python suite relied on pytest's directory auto-discovery; Zig
//! has no equivalent. When you port a file, add it here.
//
//! REGENERATING: this file is fully derived from the `*_test.zig` files
//! present in this directory. If a ported suite is missing from `suites`,
//! it is not running - that is the failure mode this list exists to
//! prevent, so check here first when a port "passes" but its tests never
//! appear in the count.

const std = @import("std");

pub const harness = @import("harness.zig");

// -- Suites ----------------------------------------------------------------
// One `const` per ported suite. A bare `@import` expression on its own
// does NOT pull the file's file-scope `test` blocks into the build;
// naming it as a `const` and referencing that const inside a `test`
// block is what makes the file's tests reachable.
const agent_add_mcp_server_test = @import("agent_add_mcp_server_test.zig");
const agent_create_kanban_task_session_test = @import("agent_create_kanban_task_session_test.zig");
const agent_kanbans_test = @import("agent_kanbans_test.zig");
const agent_knowledge_edit_test = @import("agent_knowledge_edit_test.zig");
const agent_list_directory_relative_path_test = @import("agent_list_directory_relative_path_test.zig");
const agent_present_files_test = @import("agent_present_files_test.zig");
const agent_routines_test = @import("agent_routines_test.zig");
const agent_system_prompt_test = @import("agent_system_prompt_test.zig");
const agent_tools_defaults_test = @import("agent_tools_defaults_test.zig");
const agent_tools_toggle_test = @import("agent_tools_toggle_test.zig");
const agent_video_upload_test = @import("agent_video_upload_test.zig");
const agent_workspace_history_test = @import("agent_workspace_history_test.zig");
const chat_content_envelope_test = @import("chat_content_envelope_test.zig");
const android_chat_sse_contract_test = @import("android_chat_sse_contract_test.zig");
const android_sidebar_contract_test = @import("android_sidebar_contract_test.zig");
const android_workers_contract_test = @import("android_workers_contract_test.zig");
const anthropic_chat_headers_test = @import("anthropic_chat_headers_test.zig");
const openai_thinking_param_test = @import("openai_thinking_param_test.zig");
const ask_user_multi_question_test = @import("ask_user_multi_question_test.zig");
const ask_user_test = @import("ask_user_test.zig");
const auth_config_source_test = @import("auth_config_source_test.zig");
const auth_test = @import("auth_test.zig");
const background_command_completion_test = @import("background_command_completion_test.zig");
const background_process_sse_test = @import("background_process_sse_test.zig");
const background_processes_api_test = @import("background_processes_api_test.zig");
const chat_right_sidebar_git_test = @import("chat_right_sidebar_git_test.zig");
const command_tool_test = @import("command_tool_test.zig");
const config_simplify_test = @import("config_simplify_test.zig");
const config_tools_test = @import("config_tools_test.zig");
const cross_project_cwd_prompt_test = @import("cross_project_cwd_prompt_test.zig");
const default_workspace_provisioning_test = @import("default_workspace_provisioning_test.zig");
const design_advanced_test = @import("design_advanced_test.zig");
const design_lifecycle_test = @import("design_lifecycle_test.zig");
const desktop_app_icon_test = @import("desktop_app_icon_test.zig");
const desktop_webapp_404_test = @import("desktop_webapp_404_test.zig");
const static_serve_concurrency_test = @import("static_serve_concurrency_test.zig");
const desktop_webapp_stable_symlink_test = @import("desktop_webapp_stable_symlink_test.zig");
const document_agent_tools_test = @import("document_agent_tools_test.zig");
const fd_limit_reader_pool_test = @import("fd_limit_reader_pool_test.zig");
const frontend_log_dedup_test = @import("frontend_log_dedup_test.zig");
const git_commits_test = @import("git_commits_test.zig");
const git_file_diffs_test = @import("git_file_diffs_test.zig");
const git_file_stage_sse_test = @import("git_file_stage_sse_test.zig");
const git_folder_diffs_test = @import("git_folder_diffs_test.zig");
const git_file_relative_path_crash_test = @import("git_file_relative_path_crash_test.zig");
const git_pr_checks_test = @import("git_pr_checks_test.zig");
const git_pr_conflicts_test = @import("git_pr_conflicts_test.zig");
const git_pr_diff_test = @import("git_pr_diff_test.zig");
const git_pr_gitlab_test = @import("git_pr_gitlab_test.zig");
const git_pr_list_close_test = @import("git_pr_list_close_test.zig");
const git_pr_merge_test = @import("git_pr_merge_test.zig");
const git_pr_state_sse_test = @import("git_pr_state_sse_test.zig");
const git_pr_status_branch_test = @import("git_pr_status_branch_test.zig");
const git_pr_status_crash_test = @import("git_pr_status_crash_test.zig");
const git_pr_status_test = @import("git_pr_status_test.zig");
const graceful_shutdown_test = @import("graceful_shutdown_test.zig");
const harness_orphan_reap_test = @import("harness_orphan_reap_test.zig");
const harness_port_random_test = @import("harness_port_random_test.zig");
const harness_safety_test = @import("harness_safety_test.zig");
const headless_run_test = @import("headless_run_test.zig");
const hook_zig_fmt_test = @import("hook_zig_fmt_test.zig");
const hooks_lua_test = @import("hooks_lua_test.zig");
const http2_test = @import("http2_test.zig");
const http2_tls_test = @import("http2_tls_test.zig");
const install_browser_url_test = @import("install_browser_url_test.zig");
const kanban_advanced_test = @import("kanban_advanced_test.zig");
const kanban_column_run_all_agents_test = @import("kanban_column_run_all_agents_test.zig");
const kanban_column_stop_all_agents_test = @import("kanban_column_stop_all_agents_test.zig");
const kanban_create_session_user_message_test = @import("kanban_create_session_user_message_test.zig");
const kanban_lifecycle_test = @import("kanban_lifecycle_test.zig");
const kanban_task_create_message_format_test = @import("kanban_task_create_message_format_test.zig");
const kanban_task_auth_config_test = @import("kanban_task_auth_config_test.zig");
const kanban_task_get_test = @import("kanban_task_get_test.zig");
const kanban_task_image_urls_test = @import("kanban_task_image_urls_test.zig");
const kanban_task_long_description_test = @import("kanban_task_long_description_test.zig");
const kanban_task_session_name_test = @import("kanban_task_session_name_test.zig");
const list_sub_agent_test = @import("list_sub_agent_test.zig");
const llm_history_model_not_empty_test = @import("llm_history_model_not_empty_test.zig");
const llm_stream_get_test = @import("llm_stream_get_test.zig");
const llm_test_test = @import("llm_test_test.zig");
const model_catalog_test = @import("model_catalog_test.zig");
const mcp_http_test = @import("mcp_http_test.zig");
const mcp_server_toggle_test = @import("mcp_server_toggle_test.zig");
const mcp_stdio_hang_test = @import("mcp_stdio_hang_test.zig");
const mcp_stdio_test = @import("mcp_stdio_test.zig");
const mcp_test_test = @import("mcp_test_test.zig");
const memories_skills_test = @import("memories_skills_test.zig");
const model_thinking_test = @import("model_thinking_test.zig");
const new_chat_session_not_found_test = @import("new_chat_session_not_found_test.zig");
const notify_on_error_test = @import("notify_on_error_test.zig");
const pabrik_config_test = @import("pabrik_config_test.zig");
const platform_gates_test = @import("platform_gates_test.zig");
const progressive_tool_search_regex_test = @import("progressive_tool_search_regex_test.zig");
const progressive_tool_search_test = @import("progressive_tool_search_test.zig");
const read_file_raw_content_test = @import("read_file_raw_content_test.zig");
const responses_tool_output_sanitize_test = @import("responses_tool_output_sanitize_test.zig");
const server_port_bind_test = @import("server_port_bind_test.zig");
const session_auto_name_retry_test = @import("session_auto_name_retry_test.zig");
const session_created_sse_test = @import("session_created_sse_test.zig");
const session_detail_metadata_test = @import("session_detail_metadata_test.zig");
const session_human_touched_at_test = @import("session_human_touched_at_test.zig");
const session_list_workspace_test = @import("session_list_workspace_test.zig");
const session_mark_touched_test = @import("session_mark_touched_test.zig");
const session_pin_test = @import("session_pin_test.zig");
const session_skills_live_test = @import("session_skills_live_test.zig");
const session_wire_test = @import("session_wire_test.zig");
const sessions_and_llm_test = @import("sessions_and_llm_test.zig");
const sidebar_git_branch_test = @import("sidebar_git_branch_test.zig");
const sidebar_new_chat_default_project_test = @import("sidebar_new_chat_default_project_test.zig");
const skill_evals_api_test = @import("skill_evals_api_test.zig");
const skill_evals_config_toggle_test = @import("skill_evals_config_toggle_test.zig");
const skills_memories_boundary_test = @import("skills_memories_boundary_test.zig");
const skills_sqlite_test = @import("skills_sqlite_test.zig");
const skills_write_test = @import("skills_write_test.zig");
const smoke_boot_test = @import("smoke_boot_test.zig");
const spawn_sub_agent_tools_required_test = @import("spawn_sub_agent_tools_required_test.zig");
const sqlite_write_lock_test = @import("sqlite_write_lock_test.zig");
const sse_auth_test = @import("sse_auth_test.zig");
const sse_endtoend_test = @import("sse_endtoend_test.zig");
const sse_isolation_test = @import("sse_isolation_test.zig");
const subagent_identity_test = @import("subagent_identity_test.zig");
const subagent_peek_test = @import("subagent_peek_test.zig");
const subagent_refresh_test = @import("subagent_refresh_test.zig");
const subagent_selected_profile_test = @import("subagent_selected_profile_test.zig");
const subagents_per_profile_test = @import("subagents_per_profile_test.zig");
const system_folder_gitignore_test = @import("system_folder_gitignore_test.zig");
const system_folder_home_test = @import("system_folder_home_test.zig");
const system_folder_path_validation_test = @import("system_folder_path_validation_test.zig");
const system_folder_search_test = @import("system_folder_search_test.zig");
const task_lifecycle_test = @import("task_lifecycle_test.zig");
const task_rename_id_route_auth_test = @import("task_rename_id_route_auth_test.zig");
const terminal_isolation_test = @import("terminal_isolation_test.zig");
const terminal_limits_test = @import("terminal_limits_test.zig");
const terminal_session_test = @import("terminal_session_test.zig");
const terminal_ws_test = @import("terminal_ws_test.zig");
const tui_cwd_test = @import("tui_cwd_test.zig");
const tui_turn_streaming_test = @import("tui_turn_streaming_test.zig");
const used_tools_test = @import("used_tools_test.zig");
const user_config_test = @import("user_config_test.zig");
const web_launch_toggle_test = @import("web_launch_toggle_test.zig");
const web_search_config_test = @import("web_search_config_test.zig");
const worker_gate_queue_test = @import("worker_gate_queue_test.zig");
const workflow_mcp_snapshot_turn_lifetime_test = @import("workflow_mcp_snapshot_turn_lifetime_test.zig");
const workspace_config_test = @import("workspace_config_test.zig");
const workspace_default_profile_test = @import("workspace_default_profile_test.zig");
const workspace_isolation_test = @import("workspace_isolation_test.zig");
const workspace_items_test = @import("workspace_items_test.zig");
const workspace_lifecycle_test = @import("workspace_lifecycle_test.zig");
const workspace_members_sharing_test = @import("workspace_members_sharing_test.zig");
const workspace_routines_test = @import("workspace_routines_test.zig");
const workspace_secrets_test = @import("workspace_secrets_test.zig");

pub const suites = .{
    agent_add_mcp_server_test,
    agent_create_kanban_task_session_test,
    agent_kanbans_test,
    agent_knowledge_edit_test,
    agent_list_directory_relative_path_test,
    agent_present_files_test,
    agent_routines_test,
    agent_system_prompt_test,
    agent_tools_defaults_test,
    agent_tools_toggle_test,
    agent_video_upload_test,
    agent_workspace_history_test,
    chat_content_envelope_test,
    android_chat_sse_contract_test,
    android_sidebar_contract_test,
    android_workers_contract_test,
    anthropic_chat_headers_test,
    openai_thinking_param_test,
    ask_user_multi_question_test,
    ask_user_test,
    auth_config_source_test,
    auth_test,
    background_command_completion_test,
    background_process_sse_test,
    background_processes_api_test,
    chat_right_sidebar_git_test,
    command_tool_test,
    config_simplify_test,
    config_tools_test,
    cross_project_cwd_prompt_test,
    default_workspace_provisioning_test,
    design_advanced_test,
    design_lifecycle_test,
    desktop_app_icon_test,
    desktop_webapp_404_test,
    static_serve_concurrency_test,
    desktop_webapp_stable_symlink_test,
    document_agent_tools_test,
    fd_limit_reader_pool_test,
    frontend_log_dedup_test,
    git_commits_test,
    git_file_diffs_test,
    git_file_stage_sse_test,
    git_folder_diffs_test,
    git_file_relative_path_crash_test,
    git_pr_checks_test,
    git_pr_conflicts_test,
    git_pr_diff_test,
    git_pr_gitlab_test,
    git_pr_list_close_test,
    git_pr_merge_test,
    git_pr_state_sse_test,
    git_pr_status_branch_test,
    git_pr_status_crash_test,
    git_pr_status_test,
    graceful_shutdown_test,
    harness_orphan_reap_test,
    harness_port_random_test,
    harness_safety_test,
    headless_run_test,
    hook_zig_fmt_test,
    hooks_lua_test,
    http2_test,
    http2_tls_test,
    install_browser_url_test,
    kanban_advanced_test,
    kanban_column_run_all_agents_test,
    kanban_column_stop_all_agents_test,
    kanban_create_session_user_message_test,
    kanban_lifecycle_test,
    kanban_task_create_message_format_test,
    kanban_task_auth_config_test,
    kanban_task_get_test,
    kanban_task_image_urls_test,
    kanban_task_long_description_test,
    kanban_task_session_name_test,
    list_sub_agent_test,
    llm_history_model_not_empty_test,
    llm_stream_get_test,
    llm_test_test,
    model_catalog_test,
    mcp_http_test,
    mcp_server_toggle_test,
    mcp_stdio_hang_test,
    mcp_stdio_test,
    mcp_test_test,
    memories_skills_test,
    model_thinking_test,
    new_chat_session_not_found_test,
    notify_on_error_test,
    pabrik_config_test,
    platform_gates_test,
    progressive_tool_search_regex_test,
    progressive_tool_search_test,
    read_file_raw_content_test,
    responses_tool_output_sanitize_test,
    server_port_bind_test,
    session_auto_name_retry_test,
    session_created_sse_test,
    session_detail_metadata_test,
    session_human_touched_at_test,
    session_list_workspace_test,
    session_mark_touched_test,
    session_pin_test,
    session_skills_live_test,
    session_wire_test,
    sessions_and_llm_test,
    sidebar_git_branch_test,
    sidebar_new_chat_default_project_test,
    skill_evals_api_test,
    skill_evals_config_toggle_test,
    skills_memories_boundary_test,
    skills_sqlite_test,
    skills_write_test,
    smoke_boot_test,
    spawn_sub_agent_tools_required_test,
    sqlite_write_lock_test,
    sse_auth_test,
    sse_endtoend_test,
    sse_isolation_test,
    subagent_identity_test,
    subagent_peek_test,
    subagent_refresh_test,
    subagent_selected_profile_test,
    subagents_per_profile_test,
    system_folder_gitignore_test,
    system_folder_home_test,
    system_folder_path_validation_test,
    system_folder_search_test,
    task_lifecycle_test,
    task_rename_id_route_auth_test,
    terminal_isolation_test,
    terminal_limits_test,
    terminal_session_test,
    terminal_ws_test,
    tui_cwd_test,
    tui_turn_streaming_test,
    used_tools_test,
    user_config_test,
    web_launch_toggle_test,
    web_search_config_test,
    worker_gate_queue_test,
    workflow_mcp_snapshot_turn_lifetime_test,
    workspace_config_test,
    workspace_default_profile_test,
    workspace_isolation_test,
    workspace_items_test,
    workspace_lifecycle_test,
    workspace_members_sharing_test,
    workspace_routines_test,
    workspace_secrets_test,
};

test {
    // Referencing each suite here is what pulls its `test` blocks in.
    inline for (suites) |suite| {
        _ = suite;
    }
    // Plus the harness module's own decls, so a helper added to
    // `harness.zig` is analyzed even before a suite uses it. (Note this
    // forces DECLARATION analysis only - harness.zig carries its own
    // `comptime` block that forces BODY analysis of every public fn,
    // because a function body is otherwise never type-checked until
    // something calls it.)
    std.testing.refAllDecls(harness);
}

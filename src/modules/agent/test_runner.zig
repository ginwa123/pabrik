test {
    // 2026-09-29 flatten: the eight *_test.zig siblings below were merged
    // inline into Agent.zig (image content, callStreaming deadline /
    // network-disconnect, Anthropic /v1/messages SSE parser + raw-error
    _ = @import("Agent.zig");

    // LLMModels tests (14 existing getModelTokenCount/isDoCompact + 6 new wrappers)
    _ = @import("LLMModels.zig");

    // Prompt builder tests
    _ = @import("prompts.zig");

    // Tool tests
    _ = @import("tools/set_git_worktree.zig");

    // set_pull_request tool + pr_provider tests (colocated test blocks)
    _ = @import("tools/pr_provider.zig");
    _ = @import("tools/set_pull_request.zig");
    _ = @import("tools/status_pull_request.zig");

    // Bash tool cross-platform tests
    _ = @import("tools/bash.zig");

    // web_search_curl: the GET-only example_curl parser.
    _ = @import("tools/web_search_curl.zig");

    // web_search_request: host pinning + `{key}` substitution. The only
    // module in the feature that ever sees a credential, so its tests
    // matter more than most — registered for the same reason.
    _ = @import("tools/web_search_request.zig");

    // web_search: execute + untyped passthrough + the tool schemas.
    _ = @import("tools/web_search.zig");

    // tools/indexing_semantic_search.zig is NOT registered. Its `search` is
    // still a `!void` placeholder, and the suite that asserted its return
    // value could never have compiled — see the note on its inline block.

    // Shared file-sandbox rule shared by present_files + /api/files/download
    _ = @import("tools/file_sandbox.zig");

    // Shared shell core + pwsh tool tests (Task 1 + 3 of 2026-08-14-pwsh-tool.md)

    // Search tool edge cases (validation + behavioral + static-contract)

    // Write file tool edge cases (sanity + content shape + path shape +
    // ownership + XML serialization + tool schema contract)

    // generate_image tool tests (DALL-E 2/3, gpt-image-1 via OpenAI Images API)

    // update_activity helper tests — moved from tui/update_activity_test.zig
    // to modules/agent/tools/update_activity_test.zig in Phase 7

    // 2026-08-14 — list_directory agent tool tests (Task 5 of the same plan).
    _ = @import("tools/create_kanban_task.zig");
    _ = @import("tools/skill_tools.zig");
    _ = @import("tools/set_design_page.zig");
    _ = @import("tools/update_plan.zig");
    _ = @import("tools/read_workspace_session.zig");
    _ = @import("tools/run_session.zig");
    _ = @import("tools/view_session.zig");
    _ = @import("tools/document.zig"); // add_document / edit_document (Migration 098)
    _ = @import("tools/glob.zig");
    _ = @import("tools/memory.zig");
    _ = @import("tools/kanban_list.zig");
    _ = @import("tools/pwsh.zig");
    _ = @import("tools/command.zig");
    _ = @import("tools/get_plan.zig");
    _ = @import("tools/write_file.zig");
    _ = @import("tools/progressive_tools.zig");
    _ = @import("tools/move_element_to_page.zig");
    _ = @import("tools/group_design_elements.zig");
    _ = @import("tools/kanban_move_task.zig");
    _ = @import("tools/list_directory.zig");
    _ = @import("tools/generate_image.zig");
    _ = @import("tools/move_design_element.zig");
    _ = @import("tools/shell.zig");
    _ = @import("tools/text_replace.zig");
    _ = @import("tools/diff.zig");
    // These three carry real inline tests that were never discovered: a `pub
    // const` re-export (or nothing at all) does not pull a file's test blocks
    // into the test binary.
    _ = @import("tools/read_file.zig");
    _ = @import("tools/remove_file.zig");
    _ = @import("tools/present_files.zig");
    // Source-scanning contract that every path-taking tool validates its
    // model-supplied path before touching std.fs.
    _ = @import("tools/tools.zig");
    _ = @import("tools/list_memory.zig");
    _ = @import("tools/add_design_element.zig");
    _ = @import("tools/memory.zig");
    _ = @import("tools/add_mcp_server.zig"); // 2026-08-28-add-mcp-server-agent-tool (Step 2)
    _ = @import("tools/spawn_sub_agent.zig");
    _ = @import("tools/list_agents.zig");
    _ = @import("tools/update_design_element.zig");
    _ = @import("tools/set_element_parent.zig");
    _ = @import("tools/search.zig");
    _ = @import("tools/memories.zig");
    // present_files + its shared file_sandbox rule (the sandbox tests below
    // need the tool's own tests discoverable from one `--test-filter`).
    _ = @import("tools/present_files.zig");
    // Two exec adapters with no definition file (task_1791993404141_2):
    // `exec_bash_args` is a shared arg parser, `exec_list_web_search_providers` has no def.
    _ = @import("tools/exec_bash_args.zig");
    _ = @import("tools/exec_list_web_search_providers.zig");
}

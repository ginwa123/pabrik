const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const helpers = @import("helpers");
const agent_db = @import("../models/agent.db.zig");
const agent = pabrikcore.agent;
const AgentTool = pabrikcore.agent.AgentTool;

const read_file_mod = pabrikcore.read_file;
const text_replace_mod = pabrikcore.text_replace_tool;
const write_file_mod = pabrikcore.write_file;
const search_skills_mod = pabrikcore.skill_tools;
const memories_mod = pabrikcore.memories;
const list_memory_mod = pabrikcore.list_memory_tool;
const save_memory_mod = pabrikcore.memory;
const load_memory_mod = pabrikcore.memory;
const read_workspace_session_mod = pabrikcore.read_workspace_session_tool;
// `run_session` — start/resume a session agent, another workspace included.
const run_session_mod = pabrikcore.run_session;
const document_mod = pabrikcore.document_tool;
const use_skill_mod = pabrikcore.skill_tools;
const remove_skill_mod = pabrikcore.skill_tools;
const add_skill_mod = pabrikcore.skill_tools;
const edit_skill_mod = pabrikcore.skill_tools;
const set_git_worktree_mod = pabrikcore.set_git_worktree;
const set_pull_request_mod = pabrikcore.set_pull_request;
const status_pull_request_mod = pabrikcore.status_pull_request;
const kanban_list_mod = pabrikcore.kanban_list;
const kanban_move_task_mod = pabrikcore.kanban_move_task;
const set_design_page_mod = pabrikcore.set_design_page;
const add_design_element_mod = pabrikcore.add_design_element;
const update_design_element_mod = pabrikcore.update_design_element;
const group_design_elements_mod = pabrikcore.group_design_elements;
const set_element_parent_mod = pabrikcore.set_element_parent;
const move_design_element_mod = pabrikcore.move_design_element;
const move_element_to_page_mod = pabrikcore.move_element_to_page;
const present_files_mod = pabrikcore.ai_mod.present_files;
const get_design_context_mod = pabrikcore.get_design_context;
const preview_design_page_mod = pabrikcore.preview_design_page;
const remove_file_mod = pabrikcore.remove_file;
const web_search_mod = pabrikcore.web_search;
const generate_image_mod = pabrikcore.generate_image;
// Workspace credential discovery. Listed here so `filterAndMergeTools` can
// find it — that function iterates THIS list, not UNIFIED_TOOL_REGISTRY.
const list_secrets_mod = pabrikcore.list_secrets;
// 2026-08-19 — session_plan agent tools (Task 4 of 2026-08-19-session-plan-agent-tool.md).
// Markdown task plan with - [ ] / - [x] checklist, persisted across iterations.
const update_plan_mod = pabrikcore.update_plan;
const get_plan_mod = pabrikcore.get_plan;
const list_sub_agent_mod = pabrikcore.list_sub_agent;
const used_tools_mod = pabrikcore.used_tools;
const run_skill_eval_mod = @import("run_skill_eval.zig");
// 2026-08-28 — add_mcp_server agent tool (Step 5 of
// 2026-08-28-add-mcp-server-agent-tool.md).
const add_mcp_server_mod = pabrikcore.add_mcp_server;
// The edit + delete halves of the MCP-server trio. Registered alongside
// `add_mcp_server` so the agent can maintain the servers it registers.
const edit_mcp_server_mod = pabrikcore.edit_mcp_server;
const delete_mcp_server_mod = pabrikcore.delete_mcp_server;
const glob_tool_mod = pabrikcore.glob_tool;
const search_tool_mod = pabrikcore.search_tool;
// 2026-08-14 — list_directory tool (Task 5 of ban-absolute-paths plan).
const list_directory_mod = pabrikcore.list_directory;
const semantic_search_mod = pabrikcore.semantic_search;
const spawn_sub_agent_tool = pabrikcore.spawn_sub_agent;
// 2026-09-16 — ask_user: the interactive tool that ends the turn to ask the
// human a question.
const ask_user_mod = pabrikcore.ask_user;
const kanban_create_task_tool = pabrikcore.create_kanban_task;
const command_tool_mod = pabrikcore.command_tool;
// `process` — the read/stop/list half of the detached `mode`s.
const process_tool_mod = pabrikcore.process_tool;
// Progressive tool search: search_tool / view_tool / use_tool. Pure tool data
// lives in `pabrikcore.progressive_tools`; the catalog + renderers live in
// `src/agentic_loop/progressive_catalog.zig`.
const progressive_tools_mod = pabrikcore.progressive_tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;

pub fn equips(allocator: std.mem.Allocator) []const AgentTool {
    const tools_list = comptime &[_]AgentTool{
        spawn_sub_agent_tool.spawn_sub_agent_tool,
        // 2026-08-19 — session_plan tools (Task 4).
        update_plan_mod.update_plan_tool,
        get_plan_mod.get_plan_tool,
        list_sub_agent_mod.list_sub_agent_tool,
        // used_tools: read-only introspection over this very list ("what
        // tools do I have"). Sub-agent-safe (NOT main-agent-only).
        used_tools_mod.used_tools_tool,
        // 2026-08-28 — add_mcp_server agent tool (Task 5).
        add_mcp_server_mod.add_mcp_server_tool,
        // The edit + delete halves. `delete_mcp_server` is deliberately
        // NOT in DEFAULT_AGENT_TOOLS (irreversible, like delete_document)
        // but IS listed here so `filterAndMergeTools` can find it.
        edit_mcp_server_mod.edit_mcp_server_tool,
        delete_mcp_server_mod.delete_mcp_server_tool,
        search_skills_mod.search_skills_tool,

        // Web search.
        web_search_mod.list_web_search_providers_tool,
        web_search_mod.web_search_tool,
        // list_memory_mod.list_memory_tool,
        save_memory_mod.save_memory_tool,
        load_memory_mod.load_memory_tool,
        read_workspace_session_mod.read_workspace_session_tool,
        // run_session: start or resume a session agent, INCLUDING one in
        // another workspace.
        run_session_mod.run_session_tool,
        // Workspace secrets: the discovery half of `{{SECRETS:NAME}}`. Takes
        // no parameters and returns NAMES only — the value is substituted at
        // dispatch and never reaches a tool result.
        list_secrets_mod.list_secrets_tool,
        // Workspace-scoped documents (Migration 098).
        document_mod.add_document_tool,
        document_mod.edit_document_tool,
        document_mod.search_documents_tool,
        // NOT default-on.
        document_mod.delete_document_tool,
        use_skill_mod.use_skill_tool,
        remove_skill_mod.remove_skill_tool,
        add_skill_mod.add_skill_tool,
        edit_skill_mod.edit_skill_tool,
        // Skill Evals.
        run_skill_eval_mod.run_skill_eval_tool,
        command_tool_mod.command_tool,
        process_tool_mod.process_tool,
        read_file_mod.read_file_tool,
        write_file_mod.write_file_tool,
        text_replace_mod.text_replace_tool,
        remove_file_mod.remove_file_tool,
        glob_tool_mod.glob_tool,
        search_tool_mod.search_tool,
        // 2026-08-14 — first-level ls-like tool (Task 5).
        list_directory_mod.list_directory_tool,
        generate_image_mod.generate_image_tool,
        set_git_worktree_mod.set_git_worktree_tool,
        set_pull_request_mod.set_pull_request_tool,
        status_pull_request_mod.status_pull_request_tool,
        present_files_mod.present_files_tool,
        // Interactive: asks the human and ends the turn.
        ask_user_mod.ask_user_tool,

        // kanban only
        kanban_list_mod.kanban_list_tool,
        kanban_move_task_mod.kanban_move_task_tool,
        kanban_create_task_tool.create_kanban_task_tool,

        // design only
        set_design_page_mod.set_design_page_tool,
        add_design_element_mod.add_design_element_tool,
        update_design_element_mod.update_design_element_tool,
        group_design_elements_mod.group_design_element_tool,
        set_element_parent_mod.set_element_parent_tool,
        move_design_element_mod.move_design_element_tool,
        get_design_context_mod.get_design_context_tool,
        preview_design_page_mod.preview_design_page_tool,

        // progressive tool search — always present (the workflow appends them
        // only when the discoverable catalog is non-empty, so an item whose
        // allowlist covers every built-in and has no MCP servers never sees
        progressive_tools_mod.search_tool_tool,
        progressive_tools_mod.view_tool_tool,
        progressive_tools_mod.use_tool_tool,
    };
    return allocator.dupe(AgentTool, tools_list) catch return &.{};
}

pub const ToolExecFunc = *const fn (ctx: ToolExecContext, tc: agent.ToolCall) anyerror!ToolExecResult;

pub const ToolInfo = struct {
    name: []const u8,
    exec: ToolExecFunc,
    tool_def: AgentTool,
    auto_save_skill: bool = false,
    auto_save_agent: bool = false,
};

pub fn UNIFIED_TOOL_REGISTRY() []const ToolInfo {
    return &.{
        // === AGENT CONTROL (main agent only) ===
        .{ .name = "spawn_sub_agent", .exec = tools.execSpawnSubAgent, .tool_def = spawn_sub_agent_tool.spawn_sub_agent_tool },

        // === INTERACTIVE (main agent only) === ask_user ends the turn so the
        // human can answer in their own time.
        .{ .name = "ask_user", .exec = tools.execAskUser, .tool_def = ask_user_mod.ask_user_tool },

        // === PLAN TOOLS === 2026-08-19 — session_plan agent tools (Task 4 of
        // 2026-08-19-session-plan-agent-tool.md).
        .{ .name = "update_plan", .exec = tools.execUpdatePlan, .tool_def = update_plan_mod.update_plan_tool },
        .{ .name = "get_plan", .exec = tools.execGetPlan, .tool_def = get_plan_mod.get_plan_tool },
        .{ .name = "list_sub_agent", .exec = tools.execListSubAgent, .tool_def = list_sub_agent_mod.list_sub_agent_tool },
        // used_tools: read-only introspection ("what tools do I have").
        // Available in every mode; the exec adapter resolves the
        // session's effective list via the same helpers as the workflow.
        .{ .name = "used_tools", .exec = tools.execUsedTools, .tool_def = used_tools_mod.used_tools_tool },

        // === MCP MANAGEMENT === 2026-08-28 — add_mcp_server (Task 5 of
        // 2026-08-28-add-mcp-server-agent-tool.md).
        .{ .name = "add_mcp_server", .exec = tools.execAddMcpServer, .tool_def = add_mcp_server_mod.add_mcp_server_tool },
        // edit_mcp_server — PATCH an existing server. Every field except
        // `name` is optional, and a call may switch transports.
        .{ .name = "edit_mcp_server", .exec = tools.execEditMcpServer, .tool_def = edit_mcp_server_mod.edit_mcp_server_tool },
        // delete_mcp_server — remove a server. Registered here (so it is
        // dispatchable and appears in the Settings checklist) but
        // deliberately absent from DEFAULT_AGENT_TOOLS.
        .{ .name = "delete_mcp_server", .exec = tools.execDeleteMcpServer, .tool_def = delete_mcp_server_mod.delete_mcp_server_tool },

        // === PROGRESSIVE TOOL SEARCH === search_tool / view_tool / use_tool
        // browse and enable the catalog of tools this session does not
        // already have.
        .{ .name = "search_tool", .exec = tools.execSearchTool, .tool_def = progressive_tools_mod.search_tool_tool },
        .{ .name = "view_tool", .exec = tools.execViewTool, .tool_def = progressive_tools_mod.view_tool_tool },
        .{ .name = "use_tool", .exec = tools.execUseTool, .tool_def = progressive_tools_mod.use_tool_tool },

        // === AGENT MANAGEMENT (auto-save) ===

        // === SKILL MANAGEMENT ===
        .{ .name = "search_skills", .exec = tools.execSearchSkills, .tool_def = search_skills_mod.search_skills_tool },
        .{ .name = "use_skill", .exec = tools.execUseSkill, .tool_def = use_skill_mod.use_skill_tool, .auto_save_skill = true },
        .{ .name = "remove_skill", .exec = tools.execRemoveSkill, .tool_def = remove_skill_mod.remove_skill_tool },

        .{ .name = "add_skill", .exec = tools.execAddSkill, .tool_def = add_skill_mod.add_skill_tool, .auto_save_skill = true },
        .{ .name = "edit_skill", .exec = tools.execEditSkill, .tool_def = edit_skill_mod.edit_skill_tool },

        // === SKILL EVALS === run_skill_eval: the agent evaluates the skills
        // this session actually used.
        .{ .name = "run_skill_eval", .exec = run_skill_eval_mod.execRunSkillEval, .tool_def = run_skill_eval_mod.run_skill_eval_tool },

        // === MEMORY TOOLS ===
        // .{ .name = "list_memory", .exec = tools.execListMemory, .tool_def = list_memory_mod.list_memory_tool },
        .{ .name = "save_memory", .exec = tools.execSaveMemory, .tool_def = save_memory_mod.save_memory_tool },
        .{ .name = "load_memory", .exec = tools.execLoadMemory, .tool_def = load_memory_mod.load_memory_tool },
        .{ .name = "read_workspace_session", .exec = tools.execReadWorkspaceSession, .tool_def = read_workspace_session_mod.read_workspace_session_tool },
        // run_session — the WRITE sibling of read_workspace_session: it starts
        // a new session agent or resumes an existing one, and its target
        // workspace may be another one.
        .{ .name = "run_session", .exec = tools.execRunSession, .tool_def = run_session_mod.run_session_tool },
        // Workspace credential discovery. Without a registry entry here the
        // name reaches the model and dispatch misses with `error.UnknownTool`
        // — which the UI renders as a tool that is still running.
        .{ .name = "list_secrets", .exec = tools.execListSecrets, .tool_def = list_secrets_mod.list_secrets_tool },
        // Workspace-scoped documents (Migration 098).
        .{ .name = "add_document", .exec = tools.execAddDocument, .tool_def = document_mod.add_document_tool },
        .{ .name = "edit_document", .exec = tools.execEditDocument, .tool_def = document_mod.edit_document_tool },
        .{ .name = "search_documents", .exec = tools.execSearchDocuments, .tool_def = document_mod.search_documents_tool },
        // Irreversible.
        .{ .name = "delete_document", .exec = tools.execDeleteDocument, .tool_def = document_mod.delete_document_tool },

        // === FILE OPERATIONS ===
        .{ .name = "command", .exec = tools.execCommand, .tool_def = command_tool_mod.command_tool },
        .{ .name = "process", .exec = tools.execProcess, .tool_def = process_tool_mod.process_tool },
        .{ .name = "read_file", .exec = tools.execReadFile, .tool_def = read_file_mod.read_file_tool },
        .{ .name = "write_file", .exec = tools.execWriteFile, .tool_def = write_file_mod.write_file_tool },
        .{ .name = "text_replace", .exec = tools.execTextReplace, .tool_def = text_replace_mod.text_replace_tool },
        .{ .name = "remove_file", .exec = tools.execRemoveFile, .tool_def = remove_file_mod.remove_file_tool },

        // === GIT WORKTREE BINDING ===
        .{ .name = "set_git_worktree", .exec = tools.execSetGitWorktree, .tool_def = set_git_worktree_mod.set_git_worktree_tool },
        .{ .name = "set_pull_request", .exec = tools.execSetPullRequest, .tool_def = set_pull_request_mod.set_pull_request_tool },
        .{ .name = "status_pull_request", .exec = tools.execStatusPullRequest, .tool_def = status_pull_request_mod.status_pull_request_tool },

        // === KANBAN TOOLS === Both tools read directly from the DB
        // (kanban_model.listColumns + a new SELECT on workspace_item_tasks)
        // instead of going through the HTTP layer.
        .{ .name = "kanban_list", .exec = tools.execKanbanList, .tool_def = kanban_list_mod.kanban_list_tool },
        .{ .name = "kanban_move_task", .exec = tools.execKanbanMoveTask, .tool_def = kanban_move_task_mod.kanban_move_task_tool },
        .{ .name = "create_kanban_task", .exec = tools.execCreateKanbanTask, .tool_def = kanban_create_task_tool.create_kanban_task_tool },

        // === DESIGN TOOLS === Three tools cover the v6 design mode LLM
        // surface: set_design_page — idempotent create/update for a page,
        // returns page + elements (no HTML bodies). add_element — creates a
        .{ .name = "set_design_page", .exec = tools.execSetDesignPage, .tool_def = set_design_page_mod.set_design_page_tool },
        .{ .name = "add_element", .exec = tools.execAddElement, .tool_def = add_design_element_mod.add_design_element_tool },
        .{ .name = "update_element", .exec = tools.execUpdateElement, .tool_def = update_design_element_mod.update_design_element_tool },
        .{ .name = "group_elements", .exec = tools.execGroupElements, .tool_def = group_design_elements_mod.group_design_element_tool },
        .{ .name = "set_element_parent", .exec = tools.execSetElementParent, .tool_def = set_element_parent_mod.set_element_parent_tool },
        .{ .name = "move_design_element", .exec = tools.execMoveDesignElement, .tool_def = move_design_element_mod.move_design_element_tool },
        .{ .name = "move_element_to_page", .exec = tools.execMoveElementToPage, .tool_def = move_element_to_page_mod.move_element_to_page_tool },
        .{ .name = "get_design_context", .exec = tools.execGetDesignContext, .tool_def = get_design_context_mod.get_design_context_tool },
        .{ .name = "preview_design_page", .exec = tools.execPreviewDesignPage, .tool_def = preview_design_page_mod.preview_design_page_tool },

        // === PRESENTATION TOOLS ===
        .{ .name = "present_files", .exec = tools.execPresentFiles, .tool_def = present_files_mod.present_files_tool },

        // === IMAGE GENERATION TOOLS === generate_image calls OpenAI's
        // /v1/images/generations endpoint (DALL-E 2/3 + gpt-image-1).
        .{ .name = "generate_image", .exec = tools.execGenerateImage, .tool_def = generate_image_mod.generate_image_tool },

        // === LSP TOOLS ===

        // === WEB SEARCH TOOLS === 2026-10-02: the old `web_search` here was
        // a URL BROWSER that shelled out to `agent-browser snapshot` —
        // unreachable and commented out.
        .{ .name = "web_search", .exec = tools.execWebSearch, .tool_def = web_search_mod.web_search_tool },
        .{ .name = "list_web_search_providers", .exec = tools.execListWebSearchProviders, .tool_def = web_search_mod.list_web_search_providers_tool },

        // === FILE SEARCH TOOLS ===
        .{ .name = "glob", .exec = tools.execGlob, .tool_def = glob_tool_mod.glob_tool },
        .{ .name = "search", .exec = tools.execSearch, .tool_def = search_tool_mod.search_tool },
        // 2026-08-14 — first-level ls-like tool (Task 5 of ban-absolute-paths plan).
        .{ .name = "list_directory", .exec = tools.execListDirectory, .tool_def = list_directory_mod.list_directory_tool },
        // .{ .name = "semantic_search", .exec = execSemanticSearch, .tool_def = semantic_search_mod.semantic_search_tool },
        // .{ .name = "index_codebase", .exec = execIndexCodebase, .tool_def = semantic_search_mod.index_codebase_tool },
    };
}

// =====================================================================
// Default tools seeded at workspace-item creation (2026-09-06).

/// Canonical default toolset seeded on creation. Single source of truth —
/// both `workspace_items_create_agent.zig` and
/// `workspace_items_create_kanban.zig` seed exactly this list.
pub const DEFAULT_AGENT_TOOLS: []const []const u8 = &.{
    // basic tools
    command_tool_mod.command_tool.function.name,
    // Default-on, and it has to be: `mode="background_persistence"` is SILENT
    // by contract, so an agent that can start a dev server but cannot read or
    // stop it is strictly worse off than one that never started it.
    process_tool_mod.process_tool.function.name,
    read_file_mod.read_file_tool.function.name,
    write_file_mod.write_file_tool.function.name,
    text_replace_mod.text_replace_tool.function.name,
    remove_file_mod.remove_file_tool.function.name,
    present_files_mod.present_files_tool.function.name,
    list_directory_mod.list_directory_tool.function.name,
    search_tool_mod.search_tool.function.name,
    glob_tool_mod.glob_tool.function.name,

    // for context-aware tools
    update_plan_mod.update_plan_tool.function.name,
    get_plan_mod.get_plan_tool.function.name,

    // interactive — ask the human and end the turn
    ask_user_mod.ask_user_tool.function.name,

    // for memory tools // addon
    save_memory_mod.save_memory_tool.function.name,
    load_memory_mod.load_memory_tool.function.name,
    read_workspace_session_mod.read_workspace_session_tool.function.name,
    // Default-on, like `spawn_sub_agent`: delegating work to another session
    // or another workspace is core agent behaviour.
    run_session_mod.run_session_tool.function.name,
    // Credential discovery.
    list_secrets_mod.list_secrets_tool.function.name,
    // Workspace-scoped documents (Migration 098).
    document_mod.add_document_tool.function.name,
    document_mod.edit_document_tool.function.name,
    // Default-on: read-only, and an agent that cannot find the document it
    // wrote three turns ago has no way to revise it — `edit_document`
    // replaces the whole body, so finding the row is a prerequisite for every
    document_mod.search_documents_tool.function.name,
    // `delete_document` is deliberately NOT here.

    // skill tools
    use_skill_mod.use_skill_tool.function.name,
    remove_skill_mod.remove_skill_tool.function.name,
    add_skill_mod.add_skill_tool.function.name,
    edit_skill_mod.edit_skill_tool.function.name,
    search_skills_mod.search_skills_tool.function.name,

    // Web search.
    web_search_mod.list_web_search_providers_tool.function.name,
    web_search_mod.web_search_tool.function.name,

    // spawn
    spawn_sub_agent_tool.spawn_sub_agent_tool.function.name,
    list_sub_agent_mod.list_sub_agent_tool.function.name,

    // introspection — "what tools do I have" (read-only, sub-agent-safe).
    used_tools_mod.used_tools_tool.function.name,

    // progressive tool search — part of the default equipped set, seeded at
    // creation.
    progressive_tools_mod.search_tool_tool.function.name,
    progressive_tools_mod.view_tool_tool.function.name,
    progressive_tools_mod.use_tool_tool.function.name,
};

pub const DEFAULT_KANBAN_TOOLS: []const []const u8 = &.{
    kanban_list_mod.kanban_list_tool.function.name,
    kanban_move_task_mod.kanban_move_task_tool.function.name,
};

/// True when `name` exists in `UNIFIED_TOOL_REGISTRY()`. The PUT handler
/// and the seed derivation share this so validation and tolerance can
/// never disagree about what a "known tool" is.
pub fn isKnownToolName(name: []const u8) bool {
    for (UNIFIED_TOOL_REGISTRY()) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

// =====================================================================
// Tolerated tool names → current registry entry.
pub const TOOL_NAME_ALIASES = [_]struct { alias: []const u8, target: []const u8 }{
    .{ .alias = "run_command", .target = "command" },
};

/// Canonical registry name for a possibly-deprecated tool name, or null
/// when the name needs no translation. Never returns a name outside
/// `UNIFIED_TOOL_REGISTRY` (enforced by the test below).
pub fn resolveToolAlias(name: []const u8) ?[]const u8 {
    for (TOOL_NAME_ALIASES) |pair| {
        if (std.mem.eql(u8, name, pair.alias)) return pair.target;
    }
    return null;
}

// =====================================================================
// RETIRED tool names — refused, with the replacement named.
pub const RETIRED_TOOL_NAMES = [_]struct { name: []const u8, replacement: []const u8 }{
    .{ .name = "bash", .replacement = "command" },
    .{ .name = "pwsh", .replacement = "command" },
};

/// The registry entry that replaced a retired tool name, or null when
/// `name` was never retired. Turns an unknown-tool miss into a correction
/// instead of a dead end.
pub fn retiredToolSuggestion(name: []const u8) ?[]const u8 {
    for (RETIRED_TOOL_NAMES) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.replacement;
    }
    return null;
}

/// True when the name can be dispatched: a registry name, or a tolerated
/// alias of one. This is the gate handle_tool uses to decide whether to run a
/// call.
pub fn isDispatchableToolName(name: []const u8) bool {
    if (isKnownToolName(name)) return true;
    const target = resolveToolAlias(name) orelse return false;
    return isKnownToolName(target);
}

test "every tool alias points at a real registry entry" {
    try std.testing.expect(TOOL_NAME_ALIASES.len > 0);
    for (TOOL_NAME_ALIASES) |pair| {
        try std.testing.expect(isKnownToolName(pair.target));
        // An alias must never shadow a live registry name — otherwise the
        // alias table would silently rename a working tool.
        try std.testing.expect(!isKnownToolName(pair.alias));
        try std.testing.expectEqualStrings(pair.target, resolveToolAlias(pair.alias).?);
    }
}

test "retired shell names (bash/pwsh) are REFUSED, not aliased back to command" {
    // Banned 2026-10-12.
    for ([_][]const u8{ "bash", "pwsh" }) |retired| {
        try std.testing.expectEqual(@as(?[]const u8, null), resolveToolAlias(retired));
        try std.testing.expect(!isDispatchableToolName(retired));
        try std.testing.expectEqualStrings("command", retiredToolSuggestion(retired).?);
    }

    // `run_command` stays dispatchable: this product never advertised it, so
    // tolerating it corrects nothing and breaks nothing.
    try std.testing.expectEqualStrings("command", resolveToolAlias("run_command").?);
    try std.testing.expect(isDispatchableToolName("run_command"));

    // `command` itself is untouched, and a name nobody ever had is neither
    // dispatchable nor retired.
    try std.testing.expectEqual(@as(?[]const u8, null), resolveToolAlias("command"));
    try std.testing.expect(!isDispatchableToolName("definitely_not_a_tool"));
    try std.testing.expectEqual(@as(?[]const u8, null), retiredToolSuggestion("definitely_not_a_tool"));
}

test "every retired name names a live replacement, stays undispatchable, and is not also an alias" {
    try std.testing.expect(RETIRED_TOOL_NAMES.len > 0);
    for (RETIRED_TOOL_NAMES) |entry| {
        // The replacement must be a real registry entry, or the correction
        // would send the model to a second dead end.
        try std.testing.expect(isKnownToolName(entry.replacement));
        // A retired name must not shadow a live registry name either.
        try std.testing.expect(!isKnownToolName(entry.name));
        try std.testing.expect(!isDispatchableToolName(entry.name));
        // The two tables must not overlap — a name cannot be both tolerated
        // and retired, or which table gets consulted first would decide.
        for (TOOL_NAME_ALIASES) |pair| {
            try std.testing.expect(!std.mem.eql(u8, pair.alias, entry.name));
        }
    }
}

/// Filter a config-derived list to registry names, deduplicated, preserving
/// input order.
fn filterToRegistry(allocator: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);
    for (names) |name| {
        if (!isKnownToolName(name)) continue;
        var dup = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        try out.append(allocator, name);
    }
    return try out.toOwnedSlice(allocator);
}

/// Seed the `agent_tools` allowlist for `agent_id`.
pub fn seedDefaultAgentTools(
    allocator: std.mem.Allocator,
    db: pabrikcore.database.DbOrTx,
    agent_id: []const u8,
    config_tools: ?[]const []const u8,
) !void {
    const ts = helpers.unixTimestampNanos();

    var filtered_storage: ?[]const []const u8 = null;
    defer if (filtered_storage) |list| allocator.free(list);

    const list: []const []const u8 = blk: {
        const cfg = config_tools orelse break :blk DEFAULT_AGENT_TOOLS;
        const filtered = try filterToRegistry(allocator, cfg);
        filtered_storage = filtered;
        break :blk filtered;
    };

    for (list, 0..) |tool_name, i| {
        const id = try std.fmt.allocPrint(allocator, "at_{d}_{d}", .{ ts, i });
        defer allocator.free(id);
        try agent_db.insertToolIgnoreDuplicate(allocator, db, id, agent_id, tool_name);
    }
}

/// Seed the `agent_kanban_tools` allowlist for `kanban_id`.
pub fn seedDefaultKanbanTools(
    allocator: std.mem.Allocator,
    db: pabrikcore.database.DbOrTx,
    kanban_id: []const u8,
    config_tools: ?[]const []const u8,
) !void {
    const ts = helpers.unixTimestampNanos();

    if (config_tools) |cfg| {
        // Explicit `[]` → ZERO rows: an all-unchecked checklist beats the
        // mode floor (D2/D3). Only a non-empty list gets the floor union.
        if (cfg.len == 0) return;

        const base = try filterToRegistry(allocator, cfg);
        defer allocator.free(base);

        var idx: usize = 0;
        for (base) |tool_name| {
            const id = try std.fmt.allocPrint(allocator, "akt_{d}_{d}", .{ ts, idx });
            defer allocator.free(id);
            try db.exec(
                allocator,
                "INSERT OR IGNORE INTO agent_kanban_tools (id, kanban_id, tool_name, enabled, created_at) VALUES (?, ?, ?, 1, datetime('now'))",
                &.{ id, kanban_id, tool_name },
            );
            idx += 1;
        }

        // Mode floor: kanban_list / kanban_move_task always seed on a
        // configured board (the config list may already contain them —
        // `base` is deduped, so only genuinely new floor names insert).
        for (DEFAULT_KANBAN_TOOLS) |tool_name| {
            var present = false;
            for (base) |existing| {
                if (std.mem.eql(u8, existing, tool_name)) {
                    present = true;
                    break;
                }
            }
            if (present) continue;
            const id = try std.fmt.allocPrint(allocator, "akt_{d}_{d}", .{ ts, idx });
            defer allocator.free(id);
            try db.exec(
                allocator,
                "INSERT OR IGNORE INTO agent_kanban_tools (id, kanban_id, tool_name, enabled, created_at) VALUES (?, ?, ?, 1, datetime('now'))",
                &.{ id, kanban_id, tool_name },
            );
            idx += 1;
        }
        return;
    }

    // Legacy path (config key absent): agent defaults + kanban floor,
    // exactly as before the tools checklist existed.
    for (DEFAULT_AGENT_TOOLS, 0..) |tool_name, i| {
        const id = try std.fmt.allocPrint(allocator, "akt_{d}_{d}", .{ ts, i });
        defer allocator.free(id);
        try db.exec(
            allocator,
            "INSERT OR IGNORE INTO agent_kanban_tools (id, kanban_id, tool_name, enabled, created_at) VALUES (?, ?, ?, 1, datetime('now'))",
            &.{ id, kanban_id, tool_name },
        );
    }

    for (DEFAULT_KANBAN_TOOLS, 0..) |tool_name, i| {
        const id = try std.fmt.allocPrint(allocator, "akt_{d}_{d}", .{ ts, DEFAULT_AGENT_TOOLS.len + i });
        defer allocator.free(id);
        try db.exec(
            allocator,
            "INSERT OR IGNORE INTO agent_kanban_tools (id, kanban_id, tool_name, enabled, created_at) VALUES (?, ?, ?, 1, datetime('now'))",
            &.{ id, kanban_id, tool_name },
        );
    }
}

test "DEFAULT_AGENT_TOOLS ships the spawn pair and the progressive meta-tools" {
    var found_spawn = false;
    var found_list = false;
    for (DEFAULT_AGENT_TOOLS) |name| {
        if (std.mem.eql(u8, name, "spawn_sub_agent")) found_spawn = true;
        if (std.mem.eql(u8, name, "list_sub_agent")) found_list = true;
    }
    try std.testing.expect(found_spawn and found_list);

    // Progressive tool search is part of the default equipped set in every
    // mode: agent items seed DEFAULT_AGENT_TOOLS, kanban items seed it plus
    // DEFAULT_KANBAN_TOOLS, so both modes get the three.
    for (progressive_tools_mod.PROGRESSIVE_TOOL_NAMES) |name| {
        var found = false;
        for (DEFAULT_AGENT_TOOLS) |seeded| {
            if (std.mem.eql(u8, seeded, name)) found = true;
        }
        try std.testing.expect(found);
    }
}

// ─── Seed derivation tests (plan 2026-09-22-tools-menu) ────────────────────

const testing = std.testing;

const SeedTestCtx = struct {
    db: pabrikcore.sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupSeedDb() !SeedTestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: pabrikcore.sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(
        alloc,
        "CREATE TABLE agent_tools (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, UNIQUE(agent_id, tool_name))",
        &.{},
    );
    try db.exec(
        alloc,
        "CREATE TABLE agent_kanban_tools (id TEXT PRIMARY KEY, kanban_id TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, UNIQUE(kanban_id, tool_name))",
        &.{},
    );
    return .{ .db = db, .threaded = threaded };
}

/// Sorted tool names seeded for `owner_id` in `table`. Caller owns the
/// returned strings + header.
fn seededNames(
    ctx: *SeedTestCtx,
    alloc: std.mem.Allocator,
    table: []const u8,
    owner_id: []const u8,
) ![][]const u8 {
    var sql_buf: [256]u8 = undefined;
    const sql = try std.fmt.bufPrint(
        &sql_buf,
        "SELECT tool_name FROM {s} WHERE {s} = ? ORDER BY tool_name ASC",
        .{ table, if (std.mem.eql(u8, table, "agent_tools")) "agent_id" else "kanban_id" },
    );
    var q = try ctx.db.query(alloc, sql, &.{owner_id});
    defer q.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |n| alloc.free(n);
        out.deinit(alloc);
    }
    while ((q.next() catch null)) |row| {
        defer row.deinit(alloc);
        try out.append(alloc, try alloc.dupe(u8, row.values[0]));
    }
    return try out.toOwnedSlice(alloc);
}

fn freeNames(alloc: std.mem.Allocator, names: [][]const u8) void {
    for (names) |n| alloc.free(n);
    alloc.free(names);
}

test "seed: config absent (null) → agent gets exactly DEFAULT_AGENT_TOOLS" {
    const alloc = testing.allocator;
    var ctx = try setupSeedDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedDefaultAgentTools(alloc, .{ .db = &ctx.db }, "ag_legacy", null);

    const names = try seededNames(&ctx, alloc, "agent_tools", "ag_legacy");
    defer freeNames(alloc, names);
    try testing.expectEqual(DEFAULT_AGENT_TOOLS.len, names.len);
    // Sorted-ASC order must equal the sorted defaults (byte-identical set).
    const expected = try alloc.dupe([]const u8, DEFAULT_AGENT_TOOLS);
    defer alloc.free(expected);
    std.mem.sort([]const u8, expected, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    for (expected, names) |e, n| try testing.expectEqualStrings(e, n);
}

test "seed: config list replaces defaults (unknown names skipped)" {
    const alloc = testing.allocator;
    var ctx = try setupSeedDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const cfg = [_][]const u8{ "command", "read_file", "not_a_real_tool" };
    try seedDefaultAgentTools(alloc, .{ .db = &ctx.db }, "ag_list", &cfg);

    const names = try seededNames(&ctx, alloc, "agent_tools", "ag_list");
    defer freeNames(alloc, names);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("command", names[0]);
    try testing.expectEqualStrings("read_file", names[1]);
}

test "seed: config [] → zero agent rows (D2/D3 explicit-empty)" {
    const alloc = testing.allocator;
    var ctx = try setupSeedDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const cfg = [_][]const u8{};
    try seedDefaultAgentTools(alloc, .{ .db = &ctx.db }, "ag_zero", &cfg);

    const names = try seededNames(&ctx, alloc, "agent_tools", "ag_zero");
    defer freeNames(alloc, names);
    try testing.expectEqual(@as(usize, 0), names.len);
}

test "seed: kanban config list keeps the DEFAULT_KANBAN_TOOLS floor (deduped)" {
    const alloc = testing.allocator;
    var ctx = try setupSeedDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Includes one floor tool already — must not duplicate.
    const cfg = [_][]const u8{ "command", "kanban_list" };
    try seedDefaultKanbanTools(alloc, .{ .db = &ctx.db }, "kb_floor", &cfg);

    const names = try seededNames(&ctx, alloc, "agent_kanban_tools", "kb_floor");
    defer freeNames(alloc, names);
    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("command", names[0]);
    try testing.expectEqualStrings("kanban_list", names[1]);
    try testing.expectEqualStrings("kanban_move_task", names[2]);
}

test "seed: kanban config [] → zero rows (explicit-empty beats the floor)" {
    const alloc = testing.allocator;
    var ctx = try setupSeedDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const cfg = [_][]const u8{};
    try seedDefaultKanbanTools(alloc, .{ .db = &ctx.db }, "kb_zero", &cfg);

    const names = try seededNames(&ctx, alloc, "agent_kanban_tools", "kb_zero");
    defer freeNames(alloc, names);
    try testing.expectEqual(@as(usize, 0), names.len);
}

test "seed: kanban config absent (null) → legacy defaults + floor" {
    const alloc = testing.allocator;
    var ctx = try setupSeedDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedDefaultKanbanTools(alloc, .{ .db = &ctx.db }, "kb_legacy", null);

    const names = try seededNames(&ctx, alloc, "agent_kanban_tools", "kb_legacy");
    defer freeNames(alloc, names);
    try testing.expectEqual(DEFAULT_AGENT_TOOLS.len + DEFAULT_KANBAN_TOOLS.len, names.len);
    // The floor tools are present in the legacy seed.
    var saw_list = false;
    var saw_move = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "kanban_list")) saw_list = true;
        if (std.mem.eql(u8, n, "kanban_move_task")) saw_move = true;
    }
    try testing.expect(saw_list and saw_move);
}

// ─── registry parity guards (plan 2026-10-02-web-search-tool.md, row 67) ──

// Every tool the LLM is shown must be dispatchable.
test "every tool offered to the model resolves to a dispatchable registry entry" {
    const listed = equips(testing.allocator);
    defer testing.allocator.free(listed);

    for (listed) |t| {
        const name = t.function.name;
        testing.expect(isDispatchableToolName(name)) catch |err| {
            std.debug.print(
                "!! '{s}' is offered to the model but has no UNIFIED_TOOL_REGISTRY entry " ++
                    "-- the model can call it and dispatch will miss (renders as a hung tool)\n",
                .{name},
            );
            return err;
        };
    }
}

// The web-search pair must ship together in all three lists. A discovery tool
// the model cannot call is dead weight, and an action tool with no way to
// learn its arguments is just as broken — so neither half is useful alone.
test "web_search and list_web_search_providers appear in equips, the registry and the defaults" {
    const names = [_][]const u8{ "web_search", "list_web_search_providers" };

    const listed = equips(testing.allocator);
    defer testing.allocator.free(listed);
    for (names) |n| {
        try testing.expect(isDispatchableToolName(n));
        var in_equips = false;
        for (listed) |t| {
            if (std.mem.eql(u8, t.function.name, n)) in_equips = true;
        }
        try testing.expect(in_equips);

        var in_defaults = false;
        for (DEFAULT_AGENT_TOOLS) |d| {
            if (std.mem.eql(u8, d, n)) in_defaults = true;
        }
        try testing.expect(in_defaults);
    }

    // The default list is mirrored in the frontend's BUILTIN_DEFAULT_TOOLS;
    // a divergence there is what the comment at the top of this list warns
    // about, so assert the seed stays non-empty for both.
    try testing.expect(DEFAULT_AGENT_TOOLS.len > 0);
}

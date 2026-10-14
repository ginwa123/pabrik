const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const pabrikcore = @import("pabrikcore");
const mcp_stdio = pabrikcore.mcp_stdio;
const mcp_http = pabrikcore.mcp_http;
const mcp_types = pabrikcore.mcp_types;
const agent = pabrikcore.agent;
const llm_history = @import("llm_history.zig");
const session_helpers = llm_history;
const sqlite = pabrikcore.sqlite;
const TUIHistory = @import("models.zig").TUIHistory;
const tool_models = pabrikcore.tool_models;

// Inner prompt-template modules. Imported directly (not via
// `pabrikcore.prompt`) because the orchestrator-side file owns the
// `build_agent_prompt` rendering assembly as of the 2026-08-23 move.
const prompts_const = @import("../modules/agent/prompts/prompts.zig");
const memory_prompts = @import("../modules/agent/prompts/memory.zig");
const tool_memories_mod = @import("../modules/agent/tools/memories.zig");

// Per-file tool system prompts are now stored directly in each tool's
// `AgentTool.function.system_prompt` field (see schemas.zig). The aggregator
// below reads `tool.function.system_prompt` dynamically from `filtered_tools`
// without hardcoding names — the tool's own `.name` is the key.
const config_mod = pabrikcore.config;
const tool_eligibility = @import("tool_eligibility.zig");
const custom_http_client = @import("kabelweb").client;
const background_process = @import("background_process.zig");
const ProcessInfo = background_process.ProcessInfo;
const inherited_context = @import("inherited_context.zig");
const kanban_model = @import("kanban_model.zig");
const design_model = @import("design_model.zig");
const buildDesignCanvasPrompt = @import("prompts_make_design_context.zig").buildDesignCanvasPrompt;

const AgentTool = tool_models.AgentTool;
const AgentToolFunction = tool_models.AgentToolFunction;
const ToolParameters = tool_models.ToolParameters;
const ToolProperty = tool_models.ToolProperty;
const agentic_loop = @import("workflow.zig");

const bash_tool_mod = pabrikcore.bash_tool;
const read_file_mod = pabrikcore.read_file;
const text_replace_mod = pabrikcore.text_replace_tool;
const write_file_mod = pabrikcore.write_file;
const list_skills_mod = pabrikcore.skill_tools;
const memories_mod = pabrikcore.memories;
const list_memory_mod = pabrikcore.list_memory_tool;
const use_skill_mod = pabrikcore.skill_tools;
const remove_skill_mod = pabrikcore.skill_tools;
const add_skill_mod = pabrikcore.skill_tools;
const edit_skill_mod = pabrikcore.skill_tools;
const set_git_worktree_mod = pabrikcore.set_git_worktree;
const kanban_list_mod = pabrikcore.kanban_list;
const kanban_move_task_mod = pabrikcore.kanban_move_task;
const kanban_create_task_tool = pabrikcore.create_kanban_task;
const set_design_page_mod = pabrikcore.set_design_page;
const add_design_element_mod = pabrikcore.add_design_element;
const update_design_element_mod = pabrikcore.update_design_element;
const group_design_elements_mod = pabrikcore.group_design_elements;
const set_element_parent_mod = pabrikcore.set_element_parent;
const move_design_element_mod = pabrikcore.move_design_element;
const move_element_to_page_mod = pabrikcore.move_element_to_page;
const remove_file_mod = pabrikcore.remove_file;
const web_search_mod = pabrikcore.web_search;
const glob_tool_mod = pabrikcore.glob_tool;
const search_tool_mod = pabrikcore.search_tool;
const semantic_search_mod = pabrikcore.semantic_search;
const spawn_sub_agent_tool = pabrikcore.spawn_sub_agent;

pub fn buildMessages(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
    session_id: []const u8,
    parent_session_id: []const u8,
    historyMessages: []agentic_loop.LLMHistory,
    tools: []tool_models.AgentTool,
    inherited_context_mode: []const u8,
    activeAgentContent: []const u8,
) ![]agent.AgentMessage {
    // `environment` feeds only `loadGlobalKnowledge` below. Production
    // installs the singleton before any agent run (main.zig does it before
    // the server starts), so it is always present there; tolerating its
    // absence keeps the assembler callable from a unit test, which drives
    // it against a bare in-memory database. Without a process environment
    // there is simply no `## Global Knowledge` block.
    const environment: ?*const std.process.Environ.Map =
        if (pabrikcore.getSingleton()) |di| di.environment else |_| null;

    var final_system: std.ArrayList(u8) = .empty;
    defer final_system.deinit(allocator);

    const filtered_tools = try filteringTools(allocator, db, session_id, tools);

    // 1. Static prompts — inlined (no PROMPT_SECTIONS constant), gated on hasTool where needed
    try final_system.appendSlice(allocator, prompts_const.UniversalRules);
    try final_system.appendSlice(allocator, prompts_const.Agent);
    if (hasTool(filtered_tools, "command")) {
        try final_system.appendSlice(allocator, prompts_const.GitPrompt);
    }
    try final_system.appendSlice(allocator, prompts_const.ResponseFormatting);
    if (hasTool(filtered_tools, "update_plan")) {
        try final_system.appendSlice(allocator,
            \\## Task Planning
            \\
            \\For multi-step work, lay out a structured plan early with the `update_plan` tool, then
            \\keep it in sync by calling `update_plan` after completing each checklist item (flip
            \\`- [ ]` → `- [x]`). The plan is automatically re-injected into your system prompt on
            \\every iteration, so you always see the current state. Use `get_plan` to verify the
            \\current state explicitly.
            \\
        );
    }
    // The four "tools the agent must actually use" mandates: the special tool
    // (search the catalog for a tool), the special skills (load the skill a
    // task needs), memory (load prior context / persist new facts), and
    // workspace session history (the past is queryable, not guesswork).
    // Unconditional — never gated on hasTool, because a gate keyed on the tool
    // list is a per-agent bit in the cacheable prefix, and these rules must
    // stay byte-identical across every agent so the block is one cache hit
    // rather than N fragments.
    try final_system.appendSlice(allocator, prompts_const.ProgressiveToolRule);
    try final_system.appendSlice(allocator, prompts_const.SkillsToolRule);
    try final_system.appendSlice(allocator, prompts_const.MemoryToolRule);
    try final_system.appendSlice(allocator, prompts_const.ReadWorkspaceSessionToolRule);
    // Skill Evals. Self-gating: it tells the agent to call `run_skill_eval` if
    // that tool is in its list, and the tool is only injected when
    // `config.json`'s `skill_evals.enabled` is true (see `filterAndMergeTools`).
    // So the switch never changes these bytes — it changes what the agent can
    // do, which is what keeps the cacheable prefix one hit instead of N
    // fragments. Same reasoning as the four rules above.
    try final_system.appendSlice(allocator, prompts_const.SkillEvalToolRule);
    // The write half of the skills loop, after the eval rule it closes.
    // Unconditional for the same reason: `add_skill` / `edit_skill` are in
    // the default equipped set, so a gate on them would be a constant that
    // costs a cacheable-prefix fragment and buys nothing.
    try final_system.appendSlice(allocator, prompts_const.SkillWriteToolRule);
    // Session VCS binding: a worktree and a pull request. Unconditional like
    // the mandates above — and necessarily so, because these two tools are NOT
    // in `DEFAULT_AGENT_TOOLS`: a `hasTool` gate would show the rule only to
    // the agent that already has the tool, never to the one about to
    // hand-roll `git worktree add`. Each rule names its own `search_tool` →
    // `use_tool` hatch, so an unconditional append cannot teach a call that
    // dispatches to `error.UnknownTool`.
    try final_system.appendSlice(allocator, prompts_const.GitWorktreeToolRule);
    try final_system.appendSlice(allocator, prompts_const.PullRequestToolRule);
    // Workspace credentials. GATED, unlike the four rules above, and the
    // difference is the whole point: `list_secrets` is not in every agent's
    // tool list the way `read_workspace_session` is. It is injected past the
    // allowlist by `filterAndMergeTools`, and `filteringTools` here can still
    // drop it (a sub-agent session never gets it). Telling an agent about a
    // tool it cannot call is worse than a cacheable-prefix fragment — it
    // invites a call that dispatches to `error.UnknownTool`.
    if (hasTool(filtered_tools, "list_secrets")) {
        try final_system.appendSlice(allocator, prompts_const.SecretsToolRule);
    }
    _ = activeAgentContent;

    // 2. WorkingDirectoryContext — PABRIK.md / CLAUDE.md / AGENTS.md (right after static sections)
    const memoryMd = try agentic_loop.prompts_mod.makeWorkingDirectoryContext(allocator, io, cwd);
    defer allocator.free(memoryMd);
    if (memoryMd.len > 0) {
        try final_system.appendSlice(allocator, "\n\n");
        try final_system.appendSlice(allocator, memoryMd);
    }

    // 3. Local Knowledge → Global Knowledge ("most specific first")
    const local_knowledge = try loadLocalKnowledge(allocator, io, cwd);
    defer allocator.free(local_knowledge);
    if (local_knowledge.len > 0) {
        try final_system.appendSlice(allocator, "\n\n## Local Knowledge\n\n");
        try final_system.appendSlice(allocator,
            \\The following markdown files are this project's local memory,
            \\auto-loaded from `<cwd>/.pabrik/memories/`. Use `read_file` to
            \\load a specific memory on demand. To update, use `write_file`
            \\or `text_replace`; to delete, use `remove_file`.
            \\
        );
        try final_system.appendSlice(allocator, local_knowledge);
    }

    const knowledge = try loadGlobalKnowledge(allocator, io, environment);
    defer allocator.free(knowledge);
    if (knowledge.len > 0) {
        try final_system.appendSlice(allocator, "\n\n## Global Knowledge\n\n");
        try final_system.appendSlice(allocator,
            \\The following markdown files are your persistent global memory,
            \\auto-loaded from `~/.config/pabrik/memories/`. Use `list_memory` to
            \\see metadata (and any files truncated below the budget).
        );
        try final_system.appendSlice(allocator, knowledge);
    }

    // 4. cwd + OS — consistent with build_agent_prompt (cwd after knowledge, OS at end of static block)
    if (cwd.len > 0) {
        try final_system.appendSlice(allocator, "\n\n**Current working directory:** ");
        try final_system.appendSlice(allocator, cwd);
    }

    const os_name = getCurrentOs();
    try final_system.appendSlice(allocator, "\n\n**Operating System:** ");
    try final_system.appendSlice(allocator, os_name);
    try final_system.appendSlice(allocator,
        \\**Important:** Always use OS-specific commands. Check the current OS
        \\before running system commands or shell scripts.
    );

    // 5. workspaceContext → cross-project cwd → agentSystemPrompt → agentKnowledge → agentKanbanSystemPrompt → agentKanbanKnowledge
    const workspaceContext = try agentic_loop.prompts_mod.makeWorkspaceContext(allocator, db, session_id);
    defer allocator.free(workspaceContext);
    if (workspaceContext.len > 0) {
        try final_system.appendSlice(allocator, workspaceContext);
    }

    // Static, cache-friendly: encourages reading sibling project paths for context.
    try final_system.appendSlice(allocator, prompts_const.CrossProjectCwdRule);

    // Dynamic sibling-cwd loop (workspace_items only, excludes self, skips empty paths).
    const crossProjectCwd = try agentic_loop.prompts_mod.makeCrossProjectCwdContext(allocator, db, session_id);
    defer allocator.free(crossProjectCwd);
    if (crossProjectCwd.len > 0) {
        try final_system.appendSlice(allocator, crossProjectCwd);
    }

    const agentSystemPromptContent = try agentic_loop.prompts_mod.makeAgentSystemPrompt(allocator, io, db, session_id);
    defer allocator.free(agentSystemPromptContent);
    if (agentSystemPromptContent.len > 0) {
        try final_system.appendSlice(allocator, agentSystemPromptContent);
    }

    const agentKnowledgeContent = try agentic_loop.prompts_mod.makeAgentKnowledge(allocator, io, db, session_id);
    defer allocator.free(agentKnowledgeContent);
    if (agentKnowledgeContent.len > 0) {
        try final_system.appendSlice(allocator, agentKnowledgeContent);
    }

    const agentKanbanSystemPromptContent = try agentic_loop.prompts_mod.makeAgentKanbanSystemPrompt(allocator, io, db, session_id);
    defer allocator.free(agentKanbanSystemPromptContent);
    if (agentKanbanSystemPromptContent.len > 0) {
        try final_system.appendSlice(allocator, agentKanbanSystemPromptContent);
    }

    const agentKanbanKnowledgeContent = try agentic_loop.prompts_mod.makeAgentKanbanKnowledge(allocator, io, db, session_id);
    defer allocator.free(agentKanbanKnowledgeContent);
    if (agentKanbanKnowledgeContent.len > 0) {
        try final_system.appendSlice(allocator, agentKanbanKnowledgeContent);
    }

    // Agent-Routines mirror (Migration 087): routine system prompt +
    // knowledge resolve via workspace_routines (fire sessions) or
    // workspace_item_tasks (chats under a routine item). Empty for
    // non-routine sessions — same opt-out contract as the kanban pair.
    const agentRoutineSystemPromptContent = try agentic_loop.prompts_mod.makeAgentRoutineSystemPrompt(allocator, io, db, session_id);
    defer allocator.free(agentRoutineSystemPromptContent);
    if (agentRoutineSystemPromptContent.len > 0) {
        try final_system.appendSlice(allocator, agentRoutineSystemPromptContent);
    }

    const agentRoutineKnowledgeContent = try agentic_loop.prompts_mod.makeAgentRoutineKnowledge(allocator, io, db, session_id);
    defer allocator.free(agentRoutineKnowledgeContent);
    if (agentRoutineKnowledgeContent.len > 0) {
        try final_system.appendSlice(allocator, agentRoutineKnowledgeContent);
    }

    // 6. kanbanStatus → designStatus
    const kanbanStatusContent = try agentic_loop.prompts_mod.makeKanbanContext(allocator, db, session_id, filtered_tools);
    defer allocator.free(kanbanStatusContent);
    if (kanbanStatusContent.len > 0) {
        try final_system.appendSlice(allocator, kanbanStatusContent);
    }

    const designStatusContent = try buildDesignCanvasPrompt(allocator, db, session_id);
    defer allocator.free(designStatusContent);
    if (designStatusContent.len > 0) {
        try final_system.appendSlice(allocator, designStatusContent);
    }

    // 8. inherited_context → Current Plan
    const inherited_md = inherited_context.formatHistory(
        allocator,
        db,
        session_id,
        parent_session_id,
        inherited_context.parseMode(inherited_context_mode) catch .none,
    ) catch blk: {
        std.log.warn("buildMessages: failed to render inherited_context: mode={s}", .{inherited_context_mode});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(inherited_md);
    if (inherited_md.len > 0) {
        try final_system.appendSlice(allocator, "\n\n");
        try final_system.appendSlice(allocator, inherited_md);
    }

    const planContent = try agentic_loop.prompts_mod.makePlanContext(allocator, db, session_id);
    defer allocator.free(planContent);
    if (planContent.len > 0) {
        try final_system.appendSlice(allocator, planContent);
    }

    const final_system_content = try final_system.toOwnedSlice(allocator);

    const systemMessage = agent.AgentMessage{
        .role = .system,
        .content = final_system_content,
    };

    var allMessages: std.ArrayList(agent.AgentMessage) = .empty;
    try allMessages.append(allocator, systemMessage);
    for (historyMessages) |hist| {
        const agentMsgs = try agentic_loop.parsing_mod.transformLLMHistoryToAgentMessage(allocator, hist);
        for (agentMsgs) |msg| {
            try allMessages.append(allocator, msg);
        }
    }

    return try allMessages.toOwnedSlice(allocator);
}

/// Build activity info string for the agent prompt
/// Uses worker table as the SOLE source of active workers info
/// Filters out current session to avoid self-reference
fn buildActivityInfo(allocator: std.mem.Allocator, io: std.Io, db: *sqlite.SqliteBackend, current_session_id: []const u8) ![]const u8 {
    const workers = try llm_history.getActiveWorker(allocator, db);
    defer {
        for (workers) |*worker| worker.deinit(allocator);
        allocator.free(workers);
    }

    // Filter out current session and count remaining
    var filtered = std.ArrayList(llm_history.WorkerInfo).empty;
    defer filtered.deinit(allocator);
    for (workers) |worker| {
        if (!std.mem.eql(u8, worker.session_id, current_session_id)) {
            try filtered.append(allocator, worker);
        }
    }
    if (filtered.items.len == 0) {
        return try allocator.dupe(u8, "");
    }

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "The following workers are currently active:\n\n");

    for (filtered.items) |worker| {
        try result.appendSlice(allocator, "- **");
        try result.appendSlice(allocator, worker.session_id);
        try result.appendSlice(allocator, "**");
        if (worker.working_directory.len > 0) {
            try result.appendSlice(allocator, " @ ");
            try result.appendSlice(allocator, worker.working_directory);
        }

        if (worker.git_worktree_cwd.len > 0) {
            try result.appendSlice(allocator, " (git worktree: ");
            try result.appendSlice(allocator, worker.git_worktree_cwd);
            try result.appendSlice(allocator, ")");
        }

        if (worker.last_activity > 0) {
            const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
            const diff_secs = now - worker.last_activity;
            try result.appendSlice(allocator, " | last activity: ");
            try result.appendSlice(allocator, formatRelativeTime(diff_secs));
            if (worker.last_activity_description.len > 0) {
                try result.appendSlice(allocator, " (");
                try result.appendSlice(allocator, worker.last_activity_description);
                try result.appendSlice(allocator, ")");
            }
        }
        try result.appendSlice(allocator, "\n");
    }

    return try result.toOwnedSlice(allocator);
}

/// Format seconds into human-readable relative time
pub fn formatRelativeTime(seconds: i64) []const u8 {
    if (seconds < 60) {
        return "< 1m";
    } else if (seconds < 3600) {
        const mins = @divTrunc(seconds, 60);
        return if (mins == 1) "1m" else if (mins < 5) "2m" else "5m";
    } else if (seconds < 86400) {
        const hours = @divTrunc(seconds, 3600);
        return if (hours == 1) "1h" else if (hours < 12) "5h" else "12h+";
    } else {
        return "> 24h";
    }
}

/// Strip SSE "data:" prefix from response body if present
/// MCP servers may return responses in SSE format: "data: {...}\n\n"
fn stripSsePrefix(body: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "data:")) {
        const json_start = trimmed["data:".len..];
        const json_trimmed = std.mem.trim(u8, json_start, " \t");
        return json_trimmed;
    }
    return null;
}

/// Error types for MCP tool fetching
pub const McpToolError = error{
    ConfigLoadError,
    HttpRequestError,
    JsonParseError,
    InvalidResponse,
    OutOfMemory,
    /// MCP server config declares more than 16 custom headers; we
    /// stack-allocate the request header slice so there's a hard cap.
    TooManyHeaders,
};

/// Header struct for MCP requests
const McpHeader = struct {
    key: []const u8,
    value: []const u8,
};

/// MCP Tool response from server
const McpToolResponse = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: InputSchema,
};

const InputSchema = struct {
    type: []const u8,
    properties: json.Value,
    required: ?[]const []const u8 = null,
};

/// List tools response
const ListToolsResult = struct {
    tools: []const McpToolResponse,
};

/// Fetch MCP tools from all configured servers
///
/// `cancel_fn` (default null) — when set, polled between bytes read
/// from each MCP stdio child. The workflow's `isWorkerCancelled`
/// predicate is the canonical caller (see workflow.zig's
/// `mcp_cancel_thunk` helper that adapts it). When null, the
/// deadline becomes the only termination signal.
pub fn buildMCPToolsRun(
    allocator: std.mem.Allocator,
    mcpServers: std.json.Value,
    cancel_fn: ?*const fn () bool,
) !?[]tool_models.AgentTool {
    // Check if mcpServers is configured
    const mcp_servers = switch (mcpServers) {
        .object => |obj| obj,
        else => return null,
    };

    var all_tools: std.ArrayList(AgentTool) = .empty;
    defer all_tools.deinit(allocator);

    // Iterate over each MCP server
    var server_iter = mcp_servers.iterator();
    while (server_iter.next()) |entry| {
        const server_name = entry.key_ptr.*;
        const server_config = entry.value_ptr.*;

        const server_obj = switch (server_config) {
            .object => |obj| obj,
            else => continue,
        };

        // MCP server toggle: skip explicitly-disabled servers BEFORE any
        // spawn/connect. Only `.bool false` disables — a missing or
        // non-bool `enabled` means enabled (backward compat with configs
        // that predate the flag).
        if (server_obj.get("enabled")) |enabled_val| {
            if (enabled_val == .bool and !enabled_val.bool) continue;
        }

        // Transport dispatch: stdio (command) takes precedence over
        // HTTP (url). If the entry has a `command`, route to the stdio
        // helper; otherwise fall through to the existing HTTP path.
        if (server_obj.get("command")) |_| {
            // 30s default for tools/list — see mcp_stdio.zig's plan
            // for the per-call timeouts. We forward the workflow's
            // cancel-callback so the Stop button propagates within
            // one syscall of the cancel.
            const deadline_ns: u64 = 30 * std.time.ns_per_s;
            const stdio_tools = fetchToolsFromServerStdio(allocator, server_name, server_obj, deadline_ns, cancel_fn) catch |err| {
                std.log.info("Failed to fetch MCP tools from stdio server '{s}': {s}", .{ server_name, @errorName(err) });
                continue;
            };
            // `appendSlice` copies the structs (the name/description strings
            // stay shared); free the intermediate slice itself. Without this,
            // every successful in-process fetch leaks one slice allocation
            // (masked in production, where `allocator` is an arena).
            defer allocator.free(stdio_tools);
            try all_tools.appendSlice(allocator, stdio_tools);
            continue;
        }

        // Get URL
        const url_value = server_obj.get("url") orelse continue;
        const url = url_value.string;

        // Build headers
        var headers: std.ArrayList(McpHeader) = .empty;
        defer headers.deinit(allocator);

        if (server_obj.get("headers")) |headers_value| {
            const headers_obj = switch (headers_value) {
                .object => |obj| obj,
                else => continue,
            };
            var header_iter = headers_obj.iterator();
            while (header_iter.next()) |h_entry| {
                const key = h_entry.key_ptr.*;
                const value = switch (h_entry.value_ptr.*) {
                    .string => |s| s,
                    else => continue,
                };
                try headers.append(allocator, .{ .key = key, .value = value });
            }
        }

        // Fetch tools from this server via the new mcp_http client.
        // The HttpRegistry caches one HttpClient per server name; we
        // get a fresh list of tools for each buildMCPToolsRun call.
        const std_header_slice = blk: {
            var buf: [16]custom_http_client.Header = undefined;
            var count: usize = 0;
            for (headers.items) |h| {
                if (count >= buf.len) return error.TooManyHeaders;
                buf[count] = .{ .name = h.key, .value = h.value };
                count += 1;
            }
            break :blk buf[0..count];
        };
        // Via the singleton struct (see root.zig `mcpHttpRegistry`).
        const http_registry = pabrikcore.mcpHttpRegistry(allocator);
        const http_client = http_registry.getOrConnect(
            server_name,
            url,
            std_header_slice,
        ) catch |err| {
            std.log.warn("Failed to get HTTP client for MCP server {s}: {s}", .{ server_name, @errorName(err) });
            continue;
        };
        const mcp_tools = mcp_http.listTools(allocator, http_client) catch |err| {
            std.log.warn("Failed to fetch tools from MCP server {s}: {s}", .{ server_name, @errorName(err) });
            continue;
        };
        const tools = try convertMcpToolsToAgentTools(allocator, mcp_tools, server_name);
        // Same intermediate-slice ownership as the stdio branch above.
        defer allocator.free(tools);
        try all_tools.appendSlice(allocator, tools);
    }

    return try all_tools.toOwnedSlice(allocator);
}

/// Convert []mcp_types.McpTool to []tool_models.AgentTool. Each tool's
/// inputSchema.properties JSON object is walked: each property's name,
/// type, and description are extracted into a `ToolProperty`. The
/// `required` field is mirrored from the JSON Schema's `required`
/// array. All allocations come from `allocator`; the caller owns
/// the returned slice.
fn convertMcpToolsToAgentTools(
    allocator: std.mem.Allocator,
    mcp_tools: []const mcp_types.McpTool,
    server_name: []const u8,
) ![]tool_models.AgentTool {
    var out: std.ArrayList(tool_models.AgentTool) = .empty;
    defer out.deinit(allocator);
    for (mcp_tools) |t| {
        // Build the AgentTool name as "mcp_<server>_<tool>" — matches
        // the stdio path so dispatch in handle_mcp_tool.zig can parse
        // it back out.
        const full_name = try std.fmt.allocPrint(allocator, "mcp_{s}_{s}", .{ server_name, t.name });

        // Walk the inputSchema.properties (a std.json.Value object)
        // and build a []ToolProperty. The JSON schema looks like:
        //   { "type": "object", "properties": { "name": { "type": "string", "description": "..." } } }
        var properties: std.ArrayList(tool_models.ToolProperty) = .empty;
        defer properties.deinit(allocator);
        var required: std.ArrayList([]const u8) = .empty;
        defer required.deinit(allocator);

        if (t.inputSchema.properties == .object) {
            var prop_it = t.inputSchema.properties.object.iterator();
            while (prop_it.next()) |kv| {
                const prop_name = kv.key_ptr.*;
                const prop_val = kv.value_ptr.*;
                const type_str: []const u8 = if (prop_val == .object)
                    if (prop_val.object.get("type")) |tv|
                        switch (tv) {
                            .string => |s| s,
                            else => "string",
                        }
                    else
                        "string"
                else
                    "string";
                const desc_str: []const u8 = if (prop_val == .object)
                    if (prop_val.object.get("description")) |dv|
                        switch (dv) {
                            .string => |s| s,
                            else => "",
                        }
                    else
                        ""
                else
                    "";
                try properties.append(allocator, .{
                    .name = try allocator.dupe(u8, prop_name),
                    .type = try allocator.dupe(u8, type_str),
                    .description = try allocator.dupe(u8, desc_str),
                });
            }
        }

        // The mcp_types.McpTool.inputSchema struct has a `required`
        // field — pull it if present. (We stored it as null in
        // mcp_http.zig's parseToolsList; the SDK doesn't always send
        // it. We look at the raw JSON via a re-parse for the
        // required field, but in v1 we just default to empty.)
        // TODO: parse required from the raw JSON in mcp_http.zig.

        out.append(allocator, .{
            .type = "function",
            .function = .{
                .name = full_name,
                .description = try allocator.dupe(u8, t.description),
                .parameters = .{
                    .type = "object",
                    .properties = try properties.toOwnedSlice(allocator),
                    .required = try required.toOwnedSlice(allocator),
                },
            },
        }) catch continue;
    }
    return out.toOwnedSlice(allocator);
}

/// Fetch tools from a single MCP server over the stdio transport.
/// Builds argv from `server_name`'s `command` + `args` config fields,
/// spawns (or reuses) a child via `mcp_stdio.StdioRegistry`, sends
/// `tools/list` JSON-RPC, parses `result.tools[]` into AgentTool
/// records (same wire shape as the HTTP branch).
///
/// `deadline_ns` is forwarded to both the send and the recv — a
/// hung child (pipe-buffer deadlock, awaits-init forever) returns
/// `MCPServerSendFailed` / `MCPServerRecvFailed` instead of blocking
/// the workflow start indefinitely. `cancel_fn` (optional) is
/// forwarded to the recv cancel-callback so the workflow's Stop
/// button propagates within one syscall.
fn fetchToolsFromServerStdio(
    allocator: std.mem.Allocator,
    server_name: []const u8,
    server_obj: std.json.ObjectMap,
    deadline_ns: u64,
    cancel_fn: ?*const fn () bool,
) ![]tool_models.AgentTool {
    // Build argv from the config.
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    if (server_obj.get("command")) |cmd_field| {
        if (cmd_field == .string and cmd_field.string.len > 0) {
            try argv_list.append(allocator, try allocator.dupe(u8, cmd_field.string));
        }
    }
    if (server_obj.get("args")) |args_v| {
        if (args_v == .array) {
            for (args_v.array.items) |item| {
                if (item == .string) {
                    try argv_list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
        }
    }
    if (argv_list.items.len == 0) return error.MCPServerCommandNotFound;
    const argv = try argv_list.toOwnedSlice(allocator);
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }

    // Via the singleton struct (see root.zig `mcpStdioRegistry`).
    const reg = pabrikcore.mcpStdioRegistry(allocator);

    // Retry loop for cold-start race: process.spawn returns before the
    // child (python → SDK connect → _stdin.on('data')) has attached its
    // stdin listener. First attempt may get UnexpectedEof/RecvTimeout.
    // We retry with a sleep between attempts, matching the Test
    // handler's strategy (which uses 20 attempts x 500ms for CI
    // worst-case).
    //
    // The sleep used to be missing: this comment claimed "a short
    // sleep", the plan that added the loop specified 200ms, and
    // `git log -S Duration.sleep` on this file is empty — the three
    // attempts ran back-to-back inside the same cold window, so they
    // could not possibly have helped. The effect was that a slow
    // cold-start handshake silently yielded ZERO tools (the error is
    // swallowed into `continue` in the caller), which red the macOS
    // cell on the first run on a GitHub-hosted runner — a fresh VM
    // where the self-hosted MacBook Air always had a warm /bin/sh,
    // warm dyld cache and a warm page cache. Same bug bites production
    // on any slow host, not just CI.
    const retry_attempts: u8 = 10;
    const retry_delay_ms: i64 = 200;
    var last_err: anyerror = error.MCPServerSpawnFailed;
    var attempt: u8 = 0;
    while (attempt < retry_attempts) : (attempt += 1) {
        // One lease per attempt, released when this iteration's block
        // exits: a second session on the same server waits its turn
        // instead of driving the same `StdioClient` reader at once.
        var lease = reg.acquire(server_name, argv, .{}) catch {
            last_err = error.MCPServerSpawnFailed;
            if (attempt + 1 < retry_attempts) {
                std.Io.Clock.Duration.sleep(
                    .{ .raw = std.Io.Duration.fromMilliseconds(retry_delay_ms), .clock = .real },
                    reg.io,
                ) catch {};
                continue;
            }
            return error.MCPServerSpawnFailed;
        };
        defer lease.release();
        const client = lease.client();
        errdefer lease.markStale();

        // MCP handshake: initialize → initialized → tools/list
        // Many servers (Python SDK, Node SDK) require initialize before
        // responding to tools/list. We use NDJSON framing (JSON + '\n')
        // which is the SDK default for both transports.
        const init_body = "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"pabrik\",\"version\":\"0.0.1\"}}}";
        const initialized_body = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";
        const tools_list_body = "{\"jsonrpc\":\"2.0\",\"id\":\"2\",\"method\":\"tools/list\",\"params\":{}}";

        // Send all three as NDJSON in one go (like Test does)
        const do_handshake = struct {
            fn call(c: *mcp_stdio.StdioClient, deadline: u64, cancel: ?*const fn () bool) ![]u8 {
                // Send initialize + initialized + tools/list as NDJSON
                try c.sendNDJSON(init_body);
                try c.sendNDJSON(initialized_body);
                try c.sendNDJSON(tools_list_body);
                // Read initialize response
                const init_resp = try c.recv(deadline, cancel);
                defer c.allocator().free(init_resp);
                // Read tools/list response (the one we care about)
                return try c.recv(deadline, cancel);
            }
        }.call;

        const resp = do_handshake(client, deadline_ns, cancel_fn) catch |err| {
            last_err = err;
            const is_retryable = err == error.UnexpectedEof or err == error.RecvTimeout or err == error.BrokenPipe;
            if (is_retryable and attempt + 1 < retry_attempts) {
                lease.markStale();
                // Hand the child back before sleeping: `defer` alone
                // would hold the per-server lease for the whole backoff,
                // stalling every other session on this server.
                lease.release();
                std.Io.Clock.Duration.sleep(
                    .{ .raw = std.Io.Duration.fromMilliseconds(retry_delay_ms), .clock = .real },
                    reg.io,
                ) catch {};
                continue;
            }
            if (err == error.RecvTimeout) return error.MCPServerRecvFailed;
            if (err == error.UnexpectedEof) return error.MCPServerRecvFailed;
            return err;
        };
        // `resp` is owned by the client's allocator (its per-client
        // arena), not ours — free it there (matches the `init_resp`
        // handling in `do_handshake` above). Freeing via `allocator`
        // is an invalid free under DebugAllocator (surfaced by the
        // first in-process live-handshake unit test); under an arena it
        // was a silent no-op.
        defer client.allocator().free(resp);

        // Parse result.tools[] into AgentTool records (same parser the HTTP
        // branch uses after `body_to_parse` is read).
        var parse_arena = std.heap.ArenaAllocator.init(allocator);
        defer parse_arena.deinit();
        const parsed = json.parseFromSlice(json.Value, parse_arena.allocator(), resp, .{
            .ignore_unknown_fields = true,
            .duplicate_field_behavior = .use_last,
        }) catch return error.MCPJSONParseError;

        const root = parsed.value;
        const result_value = root.object.get("result") orelse return error.MCPInvalidResponse;
        const tools_value = result_value.object.get("tools") orelse return error.MCPInvalidResponse;
        const tools_array = switch (tools_value) {
            .array => |a| a,
            else => return error.MCPInvalidResponse,
        };

        var agent_tools: std.ArrayList(tool_models.AgentTool) = .empty;
        defer agent_tools.deinit(allocator);
        for (tools_array.items) |tool_value| {
            const tool_obj: ?std.json.ObjectMap = switch (tool_value) {
                .object => |o| o,
                else => null,
            };
            const tool_obj_inner = tool_obj orelse continue;
            const name_value = tool_obj_inner.get("name") orelse continue;
            const name: []const u8 = switch (name_value) {
                .string => |s| s,
                else => continue,
            };
            const desc_value = tool_obj_inner.get("description") orelse continue;
            const description: []const u8 = switch (desc_value) {
                .string => |s| s,
                else => continue,
            };
            const schema_value = tool_obj_inner.get("inputSchema") orelse continue;
            const schema_obj: ?std.json.ObjectMap = switch (schema_value) {
                .object => |o| o,
                else => null,
            };
            const schema_obj_inner = schema_obj orelse continue;
            const props_value = schema_obj_inner.get("properties") orelse continue;
            const properties = try parseProperties(allocator, props_value, server_name);
            var required: []const []const u8 = &[_][]const u8{};
            if (schema_obj_inner.get("required")) |req_value| {
                const req_array: ?[]const json.Value = switch (req_value) {
                    .array => |a| a.items,
                    else => null,
                };
                if (req_array) |items| {
                    var req_list: std.ArrayList([]const u8) = .empty;
                    defer req_list.deinit(allocator);
                    for (items) |req_item| {
                        const req_str: []const u8 = switch (req_item) {
                            .string => |x| x,
                            else => continue,
                        };
                        try req_list.append(allocator, try allocator.dupe(u8, req_str));
                    }
                    required = try req_list.toOwnedSlice(allocator);
                }
            }
            const agent_tool = tool_models.AgentTool{
                .type = "function",
                .function = tool_models.AgentToolFunction{
                    .name = try std.fmt.allocPrint(allocator, "mcp_{s}_{s}", .{ server_name, name }),
                    .description = try allocator.dupe(u8, description),
                    .parameters = tool_models.ToolParameters{
                        .type = "object",
                        .properties = properties,
                        .required = required,
                    },
                },
            };
            try agent_tools.append(allocator, agent_tool);
        }
        return try agent_tools.toOwnedSlice(allocator);
    }
    return last_err;
}

/// Fetch tools from a single MCP server
fn fetchToolsFromServer(
    allocator: std.mem.Allocator,
    url: []const u8,
    _headers: []const McpHeader,
    server_name: []const u8,
) ![]tool_models.AgentTool {
    const tools_url = url;

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();

    const request_body = try allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"tools/list\",\"params\":{}}");
    defer allocator.free(request_body);

    // Flatten the small bounded `_headers` slice + the Accept header into
    // a `[]const custom_http_client.Header` slice (the type the
    // custom_http_client.post() API takes). Stack-allocated; MCP headers
    // are bounded by the user's MCP server config so this never grows.
    var header_buf: [16]custom_http_client.Header = undefined;
    var header_count: usize = 0;
    header_buf[header_count] = .{ .name = "Accept", .value = "application/json, text/event-stream" };
    header_count += 1;
    for (_headers) |h| {
        if (header_count >= header_buf.len) return error.TooManyHeaders;
        header_buf[header_count] = .{ .name = h.key, .value = h.value };
        header_count += 1;
    }
    const header_slice = header_buf[0..header_count];

    const result = custom_http_client.post(
        &client,
        tools_url,
        request_body,
        header_slice,
        .{ .timeout_ms = 30_000 },
    ) catch |err| {
        std.log.info("Failed to fetch MCP tools from {s}: {s}", .{ server_name, @errorName(err) });
        return error.HttpRequestError;
    };
    defer result.deinit(allocator);

    if (result.status_code != 200) {
        std.log.warn("MCP server {s} returned status {d}", .{ server_name, result.status_code });
        return error.InvalidResponse;
    }

    const clean_body = stripSsePrefix(result.body);
    const body_to_parse = if (clean_body) |b| b else result.body;

    std.log.warn("MCP response from {s}: {d} bytes", .{ server_name, body_to_parse.len });

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();

    const parsed = json.parseFromSlice(json.Value, parse_arena.allocator(), body_to_parse, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    }) catch |err| {
        std.log.warn("Failed to parse MCP response from {s}: {s}", .{ server_name, @errorName(err) });
        return error.JsonParseError;
    };

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => {
            std.log.warn("Invalid MCP response from {s}: expected object", .{server_name});
            return error.InvalidResponse;
        },
    };

    const result_value = root.get("result") orelse {
        std.log.warn("Invalid MCP response from {s}: missing result", .{server_name});
        return error.InvalidResponse;
    };

    const result_obj = switch (result_value) {
        .object => |obj| obj,
        else => {
            std.log.warn("Invalid MCP response from {s}: result not an object", .{server_name});
            return error.InvalidResponse;
        },
    };

    const tools_value = result_obj.get("tools") orelse {
        std.log.warn("Invalid MCP response from {s}: missing tools", .{server_name});
        return error.InvalidResponse;
    };

    const tools_array = switch (tools_value) {
        .array => |arr| arr,
        else => {
            std.log.warn("Invalid MCP response from {s}: tools not an array", .{server_name});
            return error.InvalidResponse;
        },
    };

    var agent_tools: std.ArrayList(AgentTool) = .empty;
    defer agent_tools.deinit(allocator);

    for (tools_array.items) |tool_value| {
        const tool_obj: ?std.json.ObjectMap = switch (tool_value) {
            .object => |obj| obj,
            .null, .bool, .integer, .float, .string, .array, .number_string => null,
        };
        const tool_obj_inner = tool_obj orelse continue;

        const name_value = tool_obj_inner.get("name") orelse continue;
        const name: []const u8 = switch (name_value) {
            .string => |s| s,
            .null, .bool, .integer, .float, .array, .object, .number_string => continue,
        };

        const desc_value = tool_obj_inner.get("description") orelse continue;
        const description: []const u8 = switch (desc_value) {
            .string => |s| s,
            .null, .bool, .integer, .float, .array, .object, .number_string => continue,
        };

        const schema_value = tool_obj_inner.get("inputSchema") orelse continue;
        const schema_obj: ?std.json.ObjectMap = switch (schema_value) {
            .object => |obj| obj,
            .null, .bool, .integer, .float, .string, .array, .number_string => null,
        };
        const schema_obj_inner = schema_obj orelse continue;

        const props_value = schema_obj_inner.get("properties") orelse continue;
        const properties = try parseProperties(allocator, props_value, server_name);

        var required: []const []const u8 = &[_][]const u8{};
        if (schema_obj_inner.get("required")) |req_value| {
            const req_array: ?[]const json.Value = switch (req_value) {
                .array => |arr| arr.items,
                else => null,
            };
            if (req_array) |items| {
                var req_list: std.ArrayList([]const u8) = .empty;
                defer req_list.deinit(allocator);
                for (items) |req_item| {
                    const req_str: []const u8 = switch (req_item) {
                        .string => |s| s,
                        .null, .bool, .integer, .float, .array, .object, .number_string => continue,
                    };
                    try req_list.append(allocator, try allocator.dupe(u8, req_str));
                }
                required = try req_list.toOwnedSlice(allocator);
            }
        }

        const agent_tool = AgentTool{
            .type = "function",
            .function = AgentToolFunction{
                .name = try std.fmt.allocPrint(allocator, "mcp_{s}_{s}", .{ server_name, name }),
                .description = try allocator.dupe(u8, description),
                .parameters = ToolParameters{
                    .type = "object",
                    .properties = properties,
                    .required = required,
                },
            },
        };

        try agent_tools.append(allocator, agent_tool);
    }

    return try agent_tools.toOwnedSlice(allocator);
}

/// Parse JSON properties into ToolProperty array
pub fn parseProperties(
    allocator: std.mem.Allocator,
    props_value: json.Value,
    server_name: []const u8,
) ![]tool_models.ToolProperty {
    _ = server_name;
    const props_obj: ?std.json.ObjectMap = switch (props_value) {
        .object => |obj| obj,
        .null, .bool, .integer, .float, .string, .array, .number_string => null,
    };
    const props_obj_inner = props_obj orelse return &[_]ToolProperty{};

    var properties: std.ArrayList(ToolProperty) = .empty;
    defer properties.deinit(allocator);

    var prop_iter = props_obj_inner.iterator();
    while (prop_iter.next()) |entry| {
        const prop_name = entry.key_ptr.*;
        const prop_value = entry.value_ptr.*;

        const prop_obj: ?std.json.ObjectMap = switch (prop_value) {
            .object => |obj| obj,
            .null, .bool, .integer, .float, .string, .array, .number_string => null,
        };
        const prop_obj_inner = prop_obj orelse continue;

        const type_value = prop_obj_inner.get("type") orelse continue;
        const prop_type: []const u8 = switch (type_value) {
            .string => |s| s,
            .null, .bool, .integer, .float, .array, .object, .number_string => continue,
        };

        var prop_desc: []const u8 = "";
        if (prop_obj_inner.get("description")) |desc_value| {
            prop_desc = switch (desc_value) {
                .string => |s| s,
                .null, .bool, .integer, .float, .array, .object, .number_string => "",
            };
        }

        try properties.append(allocator, ToolProperty{
            .name = try allocator.dupe(u8, prop_name),
            .type = try allocator.dupe(u8, prop_type),
            .description = try allocator.dupe(u8, prop_desc),
        });
    }

    return try properties.toOwnedSlice(allocator);
}

/// Build background processes content string from database for system prompt
pub fn BuildBackgroundProcessPrompt(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) {
        return allocator.dupe(u8, "");
    }

    var processesBuilder: std.ArrayList(u8) = .empty;
    errdefer processesBuilder.deinit(allocator);

    // Get all background processes for this session
    const processes = try background_process.getBySession(db, allocator, session_id);
    // One helper instead of an inline loop: this block used to free three
    // fields by hand, so adding a fourth to `ProcessInfo` (the `kind` column,
    // migration 107) turned it into a leak that fails the whole suite.
    defer background_process.freeProcessInfos(allocator, processes);

    if (processes.len == 0) {
        return allocator.dupe(u8, "");
    }

    try processesBuilder.appendSlice(allocator, "## Background Processes For This Session\n\n");
    // `kind` is the load-bearing part of this block now. `service` means the
    // agent will NEVER be told this process exited — it has to look, and it
    // has to stop it when it is done. Without that distinction the model sees
    // a dev server and a build in the same list and cannot tell which one it
    // owes a follow-up to.
    try processesBuilder.appendSlice(allocator,
        \\`job` = a bounded command; you WILL be messaged when it exits.
        \\`service` (mode="background_persistence") = SILENT — no message, ever. Read its log
        \\(`tail -n 50 <log path>`) when you need to know something, and stop it yourself
        \\(it dies only if you kill it, or when pabrik shuts down). Status is the stored value
        \\and can lag; the log is the truth.
        \\
    );

    for (processes) |p| {
        try processesBuilder.appendSlice(allocator, "- **PID: ");
        const pid_str = try std.fmt.allocPrint(allocator, "{}", .{p.pid});
        defer allocator.free(pid_str);
        try processesBuilder.appendSlice(allocator, pid_str);
        try processesBuilder.appendSlice(allocator, "** | ");
        try processesBuilder.appendSlice(allocator, p.kind);
        try processesBuilder.appendSlice(allocator, " | Status: ");
        try processesBuilder.appendSlice(allocator, p.status);
        try processesBuilder.appendSlice(allocator, " | Command: `");
        try processesBuilder.appendSlice(allocator, p.command);
        try processesBuilder.appendSlice(allocator, "`\n");

        // Add log path info
        try processesBuilder.appendSlice(allocator, "  - Log: ");
        try processesBuilder.appendSlice(allocator, p.log_path);
        try processesBuilder.appendSlice(allocator, "\n");
    }

    try processesBuilder.appendSlice(allocator, "\nYou can check the status of these processes by reading their log files.\n");

    return processesBuilder.toOwnedSlice(allocator);
}

/// Build dynamic agents content string from database for persistence
pub fn BuildDynamicAgentContent(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) {
        return allocator.dupe(u8, "");
    }

    var agentsBuilder: std.ArrayList(u8) = .empty;
    errdefer agentsBuilder.deinit(allocator);

    const sql = "SELECT agent_name FROM session_agents WHERE session_id = ?";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    var hasAgents = false;
    while (try rows.next()) |row| {
        hasAgents = true;
        const agent_name = row.values[0];
        try agentsBuilder.appendSlice(allocator, "- ");
        try agentsBuilder.appendSlice(allocator, agent_name);
        try agentsBuilder.appendSlice(allocator, "\n");
        row.deinit(allocator);
    }

    if (!hasAgents) {
        return allocator.dupe(u8, "");
    }

    // Prepend the header to the existing content
    const header = "\n\n## Loaded Dynamic Agents\n\n";
    const result = try allocator.alloc(u8, header.len + agentsBuilder.items.len);
    @memcpy(result[0..header.len], header);
    @memcpy(result[header.len..], agentsBuilder.items);
    return result;
}

// Cap for how many design pages to enumerate in the Design Canvas status
// prompt. Pages beyond the cap are listed as a count footer. Small enough
// to keep the prompt compact, large enough to cover most multi-page designs.
const MAX_DESIGN_PAGES: u32 = 10;

/// Strip the item-type-forbidden tools (kanban ↔ design) from `tools`.
///
/// The policy itself lives in `tool_eligibility.itemTypeStrip` so that the
/// progressive-tool catalog applies exactly the same rule — if the two
/// drifted, the catalog could offer a tool the prompt path had stripped.
///
/// NOTE: this only affects the *prompt* (gating `hasTool` sections and the
/// tool-behavior text). The LLM's `tools[]` array comes from
/// `workflow.filterAndMergeTools`, which does not apply the item-type strip —
/// a pre-existing inconsistency, deliberately left alone here.
pub fn filteringTools(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8, tools: []tool_models.AgentTool) ![]tool_models.AgentTool {
    const ctx = (llm_history.getWorkspaceContext(allocator, db, session_id) catch |err| {
        std.log.warn("BuildDesignCanvasPrompt: getWorkspaceContext failed: {}", .{err});
        return tools;
    }) orelse return tools;
    defer ctx.deinit(allocator);

    return tool_eligibility.itemTypeStrip(tools, ctx.self_item_type);
}

// =============================================================================
// Moved from src/modules/agent/prompts.zig on 2026-08-23
// (plan: docs/superpowers/plans/2026-08-23-move-build-agent-prompt-body.md).
// The orchestrator-side prompt-assembly file now owns `build_agent_prompt`
// and every helper it depends on; `prompts.zig` shrinks to a thin re-export
// of static template constants only. See the plan §4.2 for rationale.
// =============================================================================

/// Get the current operating system as a human-readable string
fn getCurrentOs() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "Linux",
        .macos => "macOS",
        .windows => "Windows",
        .freebsd => "FreeBSD",
        .netbsd => "NetBSD",
        .openbsd => "OpenBSD",
        .dragonfly => "DragonFly",
        .ios => "iOS",
        else => @tagName(builtin.os.tag),
    };
}

// =============================================================================
// PROMPT BUILDERS
// =============================================================================

/// Append a section to the result with a leading "\n\n" separator.
/// Skips empty sections.
const appendSection = struct {
    fn func(a: std.mem.Allocator, r: *std.ArrayList(u8), section: []const u8) !void {
        if (section.len > 0) {
            try r.appendSlice(a, "\n\n");
            try r.appendSlice(a, section);
        }
    }
}.func;

/// A single prompt section in the main agent's system prompt.
///
/// `requires_tool` is an optional gate: if set, the section is only rendered
/// when a tool with that exact name is present in the runtime tool list.
/// This lets us ship section content (e.g. `set_agent_properties` guide)
/// without making it visible to agents that lack the tool.
const PromptSection = struct {
    name: []const u8,
    content: []const u8,
    requires_tool: ?[]const u8 = null,
};

/// Single source of truth for which prompt sections the main agent receives.
///
/// Order is meaningful: prompts earlier in the array are read first by the
/// model. The narrative is intentionally structured as:
///   1. LEAD — Orchestrator narrative (Philosophy B: spawn, delegate, orchestrate)
///   2. Skills system (so the agent knows about skills before being told workflows)
///   3. Tooling & research (how to use the tools)
///   4. Workflow (classify → plan → execute → escalate)
///   5. SECONDARY — "When you do work yourself" (Philosophy A: careful, surgical)
///   6. Memory & docs (project state)
///   7. Response formatting (applies to everything above)
///
/// To add/remove/reorder a section, edit this list — that's the only place
/// that needs to change. (For "I want the DynamicProperties section back
/// unconditionally" → just remove the `requires_tool` field.)
const PROMPT_SECTIONS: []const PromptSection = &.{
    .{ .name = "universal_rules", .content = prompts_const.UniversalRules },
    .{ .name = "search_tool_rule", .content = prompts_const.SearchToolRule },
    .{ .name = "memory_tool_rule", .content = prompts_const.MemoryToolRule, .requires_tool = "load_memory" },
    .{ .name = "read_workspace_session_rule", .content = prompts_const.ReadWorkspaceSessionToolRule, .requires_tool = "read_workspace_session" },
    // Documented here for discoverability. The live path appends this rule
    // unconditionally (see the append block in `buildMessages`); the
    // `requires_tool` here mirrors `read_workspace_session_rule` and is not
    // what gates it.
    .{ .name = "skill_eval_tool_rule", .content = prompts_const.SkillEvalToolRule, .requires_tool = "run_skill_eval" },
    .{ .name = "agent_directive", .content = prompts_const.Agent },
    .{ .name = "git_prompt", .content = prompts_const.GitPrompt },
    .{ .name = "response_formatting", .content = prompts_const.ResponseFormatting },
    .{
        .name = "task_planning",
        .content =
        \\## Task Planning
        \\
        \\For multi-step work, lay out a structured plan early with the `update_plan` tool, then
        \\keep it in sync by calling `update_plan` after completing each checklist item (flip
        \\`- [ ]` → `- [x]`). The plan is automatically re-injected into your system prompt on
        \\every iteration, so you always see the current state. Use `get_plan` to verify the
        \\current state explicitly.
        \\
        ,
        .requires_tool = "update_plan",
    },
};

/// Check if a tool with the given name is present in the runtime tool list.
fn hasTool(tools: []const tool_models.AgentTool, name: []const u8) bool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.function.name, name)) return true;
    }
    return false;
}

/// Load the contents of all memory files in `~/.config/pabrik/memories/` and
/// concatenate them as a single markdown blob. Each file is prefixed with a
/// `### <title>` heading derived from `MemoryInfo.title`.
///
/// Returns an empty string (allocated) when:
///   - environment is null
///   - the memories folder does not exist
///   - no `.md` files exist
///
/// **No cap — neither aggregate nor per-file.** Every memory that the
/// `listAllMemories` walk discovers is loaded in full. The de facto limit
/// is the LLM's context window (e.g. 200K tokens for the default model) —
/// if total memory content exceeds that, the LLM call will fail and the
/// user must trim. We trust users to keep their memories reasonable in
/// size.
// `pub` so the unit test in `prompts_test.zig` can call it directly. The
// function is still internal to the codebase — no external caller in
// the codebase imports it. Visibility widening is the standard Zig
// testability pattern for private helpers.
pub fn loadGlobalKnowledge(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
) ![]u8 {
    const env = environment orelse return allocator.dupe(u8, "");

    const list = tool_memories_mod.listAllMemories(allocator, io, env);
    defer tool_memories_mod.freeMemoriesList(allocator, list);

    if (list.len == 0) return allocator.dupe(u8, "");

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (list) |mem| {
        // Read the full file — no per-file cap. Pattern matches read_file.zig
        // and use_skill.zig which also use maxInt(usize) to mean "read all".
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            mem.path,
            allocator,
            std.Io.Limit.limited(std.math.maxInt(usize)),
        ) catch continue;
        defer allocator.free(content);

        try result.appendSlice(allocator, "### ");
        try result.appendSlice(allocator, mem.title);
        try result.appendSlice(allocator, " (`");
        try result.appendSlice(allocator, mem.name);
        try result.appendSlice(allocator, "`)\n\n");
        // Emit the absolute path as a separate code-span line right below
        // the heading so the agent can copy it verbatim into `read_file`,
        // `write_file`, `text_replace`, or `remove_file` without
        // reconstructing it from the basename. Mirrors how
        // `appendSkillsListing` emits `s.path` for each skill.
        try result.appendSlice(allocator, "`");
        try result.appendSlice(allocator, mem.path);
        try result.appendSlice(allocator, "`\n\n");
        try result.appendSlice(allocator, content);
        try result.appendSlice(allocator, "\n\n");
    }

    return result.toOwnedSlice(allocator);
}

/// Load the contents of all memory files in `<cwd>/.pabrik/memories/` and
/// concatenate them as a single markdown blob. Mirrors `loadGlobalKnowledge`
/// in shape, error handling, and output format (`### <title> (\`<name>\`)`)
/// so the rendered prompt has visual consistency across both knowledge
/// tiers.
///
/// Returns an empty string (allocated) when:
///   - `cwd` is empty
///   - `<cwd>/.pabrik/memories/` does not exist (first-run case)
///   - the directory exists but contains no `.md` files
///
/// Per-file errors (open, read, title extraction) skip the file and
/// continue — never break the prompt. **No cap** on aggregate or per-file
/// size; mirrors `loadGlobalKnowledge`'s trust-the-user policy.
// `pub` so the unit test in `prompts_test.zig` can call it directly.
// Mirrors the `pub` decision on `loadGlobalKnowledge` above.
pub fn loadLocalKnowledge(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
) ![]u8 {
    if (cwd.len == 0) return allocator.dupe(u8, "");

    const dir_path = tool_memories_mod.get_local_memories_path_for_dir(allocator, cwd) orelse return allocator.dupe(u8, "");
    defer allocator.free(dir_path);

    const list = tool_memories_mod.listMemoriesInDir(allocator, io, dir_path);
    defer tool_memories_mod.freeMemoriesList(allocator, list);

    if (list.len == 0) return allocator.dupe(u8, "");

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (list) |mem| {
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            mem.path,
            allocator,
            std.Io.Limit.limited(std.math.maxInt(usize)),
        ) catch continue;
        defer allocator.free(content);

        try result.appendSlice(allocator, "### ");
        try result.appendSlice(allocator, mem.title);
        try result.appendSlice(allocator, " (`");
        try result.appendSlice(allocator, mem.name);
        try result.appendSlice(allocator, "`)\n\n");
        // Emit the absolute path as a separate code-span line right below
        // the heading so the agent can copy it verbatim into `read_file`,
        // `write_file`, `text_replace`, or `remove_file` without
        // reconstructing it from the basename. Mirrors how
        // `appendSkillsListing` emits `s.path` for each skill and how
        // `loadGlobalKnowledge` does it above.
        try result.appendSlice(allocator, "`");
        try result.appendSlice(allocator, mem.path);
        try result.appendSlice(allocator, "`\n\n");
        try result.appendSlice(allocator, content);
        try result.appendSlice(allocator, "\n\n");
    }

    return result.toOwnedSlice(allocator);
}

/// Build main agent prompt with all components combined.
///
/// Prompt construction is data-driven via `PROMPT_SECTIONS`. To change
/// what the agent sees, edit that list — don't touch this function.
///
/// Sections are rendered in declaration order. Each section may be
/// conditionally gated on a tool being present (`requires_tool`).
///
/// After the static sections, the function appends dynamic session state:
/// loaded skills, project memory, global knowledge (memories from
/// `~/.config/pabrik/memories/`), tool listing, active agent configuration,
/// working directory, workspace context, OS info, background processes,
/// and active workers.
///
/// **Removed parameters (vs. previous version):**
///   - `io: std.Io` — never used; callers no longer need to thread an `io` instance.
///   - `treeDir: []const u8` — was a dead parameter (caller always passed `""`).
/// **Renamed parameters:**
///   - `agent` → `activeAgentContent` (avoids shadowing the `agents` namespace).
/// **New parameters:**
///   - `io: std.Io` — required to read memory files for the auto-loaded
///     "Global Knowledge" section.
///   - `environment: ?*const std.process.Environ.Map` — required to resolve
///     the global memories path (XDG-aware: $XDG_CONFIG_HOME or $HOME).
///     When null, the Global Knowledge section is omitted.
///   - `workspaceContext: []const u8` — pre-rendered "Workspace Context"
///     block (built by `BuildWorkspaceContext` in this file).
///     Empty string means "session not bound to any workspace task" (section
///     is silently omitted). Rendered between the cwd line and the OS info.
pub fn build_agent_prompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    usedSkills: []const u8,
    memoryMd: []const u8,
    backgroundProcessContent: []const u8,
    activeAgentContent: []const u8,
    tools: []const tool_models.AgentTool,
    activity_info: []const u8,
    environment: ?*const std.process.Environ.Map,
    sub_agents_listing: []const u8,
    workspaceContext: []const u8,
    kanbanStatusContent: []const u8,
    designStatusContent: []const u8,
) ![]const u8 {
    _ = usedSkills;
    _ = backgroundProcessContent;
    _ = activeAgentContent;
    _ = activity_info;
    _ = sub_agents_listing;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (PROMPT_SECTIONS) |section| {
        if (section.requires_tool) |tool_name| {
            if (!hasTool(tools, tool_name)) continue;
        }
        try appendSection(allocator, &result, section.content);
    }

    // Project memory (PABRIK.md / CLAUDE.md from cwd).
    if (memoryMd.len > 0) {
        try appendSection(allocator, &result, memoryMd);
    }

    // Local Knowledge — auto-loaded from <cwd>/.pabrik/memories/*.md.
    // Project-specific memories that ship with the codebase. Renders
    // BEFORE Global Knowledge so project context precedes cross-project
    // context ("most specific first" ordering).
    const local_knowledge = try loadLocalKnowledge(allocator, io, cwd);
    defer allocator.free(local_knowledge);
    if (local_knowledge.len > 0) {
        try result.appendSlice(allocator, "\n\n## Local Knowledge\n\n");
        try result.appendSlice(allocator,
            \\The following markdown files are this project's local memory,
            \\auto-loaded from `<cwd>/.pabrik/memories/`. Use `read_file` to
            \\load a specific memory on demand. To update, use `write_file`
            \\or `text_replace`; to delete, use `remove_file`.
            \\
        );
        try result.appendSlice(allocator, local_knowledge);
    }

    const knowledge = try loadGlobalKnowledge(allocator, io, environment);
    defer allocator.free(knowledge);
    if (knowledge.len > 0) {
        try result.appendSlice(allocator, "\n\n## Global Knowledge\n\n");
        try result.appendSlice(allocator,
            \\The following markdown files are your persistent global memory,
            \\auto-loaded from `~/.config/pabrik/memories/`. Use `list_memory` to
            \\see metadata (and any files truncated below the budget).
        );
        try result.appendSlice(allocator, knowledge);
    }

    // Working directory.
    if (cwd.len > 0) {
        try result.appendSlice(allocator, "\n\n**Current working directory:** ");
        try result.appendSlice(allocator, cwd);
    }

    if (workspaceContext.len > 0) {
        try result.appendSlice(allocator, workspaceContext);
    }

    // Static, cache-friendly: encourages reading sibling project paths for context.
    // Parity with buildMessages — same constant, same position (right after workspace).
    try result.appendSlice(allocator, prompts_const.CrossProjectCwdRule);

    if (kanbanStatusContent.len > 0) {
        try result.appendSlice(allocator, kanbanStatusContent);
    }

    if (designStatusContent.len > 0) {
        try result.appendSlice(allocator, designStatusContent);
    }

    // OS info.
    const os_name = getCurrentOs();
    try result.appendSlice(allocator, "\n\n**Operating System:** ");
    try result.appendSlice(allocator, os_name);
    try result.appendSlice(allocator,
        \\**Important:** Always use OS-specific commands. Check the current OS
        \\before running system commands or shell scripts.
    );

    return result.toOwnedSlice(allocator);
}

/// Append a tool listing to the result ArrayList.
///
/// Renders each tool's name and description so the model has semantic
/// context for tool selection — not just the JSON schema that the API
/// already sends in the request body. This is the single highest-leverage
/// piece of prompt content for tool-use accuracy: without it, the model
/// picks tools based on name-embedding similarity alone, which is unreliable
/// when tool names are short or ambiguous (e.g. `read_file` vs `text_replace`).
fn appendToolListing(allocator: std.mem.Allocator, result: *std.ArrayList(u8), tools: []const tool_models.AgentTool) !void {
    if (tools.len == 0) return;

    const header = "\n\n## Available Tools\n\nUse these exact tool names in your tool_calls:\n\n";
    try result.appendSlice(allocator, header);

    for (tools) |tool| {
        const name = tool.function.name;
        const desc = tool.function.description;

        // Guard against corrupted/uninitialized slices.
        if (name.len == 0) continue;
        if (desc.len == 0) continue;

        try result.appendSlice(allocator, "- **");
        try result.appendSlice(allocator, name);
        try result.appendSlice(allocator, "**: ");
        try result.appendSlice(allocator, desc);
        try result.appendSlice(allocator, "\n");
    }
}

// ---------------------------------------------------------------------------
// Available Sub-Agents listing
// ---------------------------------------------------------------------------

/// One row of the sub-agents listing. Borrowed slices from the
/// `SubAgentConfig` entry — they live as long as the parent
/// `LlmConfig`. Computed by the caller (typically
/// `buildMessages`); `appendSubAgentsListing` just renders the
/// rows passed to it.
pub const SubAgentListingRow = struct {
    name: []const u8,
    model: []const u8,
    /// First N chars of the sub-agent's `system_prompt`, used as
    /// a one-line description in the listing. Empty when the
    /// sub-agent has no system_prompt. Caller should pre-truncate
    /// (e.g. to 80 chars) to keep the prompt lean.
    description: []const u8,
    /// The profile name the row came from (per-profile-only;
    /// plan 2026-09-04-subagents-per-profile). Used for the source
    /// suffix in the listing.
    source: []const u8,
};

/// Append a "## Available Sub-Agents" section to the result
/// ArrayList. Mirrors `appendToolListing` / `appendSkillsListing`
/// in shape (markdown bullet list with a header that gates on
/// `spawn_sub_agent` being present in the tool list — the section
/// is only useful when the LLM can actually call it).
///
/// Format:
/// ```
/// ## Available Sub-Agents
///
/// You can use `spawn_sub_agent` with one of these `agent_name` values:
///
/// If you are unsure which agent_name values exist or which fits
/// the job, call list_sub_agent first — it shows full specs
/// (model, tuning, system prompt); absent optional tags mean
/// 'inherits the profile default'.
///
/// - **code-reviewer** — model: `gpt-4o` — "You are a strict code reviewer..."
/// - **frontend-helper** — model: `claude-3.5-sonnet` — "You are a frontend..."
///
/// (Loaded from the profile's `sub_agents` array in
/// `~/.config/pabrik/config.json` under `profiles_models`.)
/// ```
///
/// No-op when `rows.len == 0` so callers can pass an empty slice
/// to mean "no sub-agents configured" (matches the convention used
/// by `appendToolListing` for empty tool lists).
pub fn appendSubAgentsListing(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    rows: []const SubAgentListingRow,
) !void {
    if (rows.len == 0) return;

    try result.appendSlice(allocator,
        \\## Available Sub-Agents
        \\
        \\You can use the `spawn_sub_agent` tool with one of these
        \\`agent_name` values to delegate the task to a pre-configured
        \\specialized sub-agent:
        \\
        \\If you are unsure which agent_name values exist or which fits
        \\the job, call list_sub_agent first — it shows full specs
        \\(model, tuning, system prompt); absent optional tags mean
        \\'inherits the profile default'.
        \\
    );

    for (rows) |row| {
        // Skip rows with empty name (defensive — should never
        // happen since the LlmConfig rejects empty names at
        // load time, but be tolerant).
        if (row.name.len == 0) continue;
        try result.appendSlice(allocator, "- **");
        try result.appendSlice(allocator, row.name);
        try result.appendSlice(allocator, "**");
        if (row.model.len > 0) {
            try result.appendSlice(allocator, " (model: `");
            try result.appendSlice(allocator, row.model);
            try result.appendSlice(allocator, "`)");
        }
        if (row.description.len > 0) {
            try result.appendSlice(allocator, " — \"");
            try result.appendSlice(allocator, row.description);
            try result.appendSlice(allocator, "\"");
        }
        if (row.source.len > 0) {
            try result.appendSlice(allocator, " _(from profile `");
            try result.appendSlice(allocator, row.source);
            try result.appendSlice(allocator, "`)_");
        }
        try result.appendSlice(allocator, "\n");
    }

    try result.appendSlice(allocator,
        \\
        \\Loaded from the profile's `sub_agents` array in
        \\`~/.config/pabrik/config.json` under `profiles_models`.
        \\
    );
}

// ============================================================================
// Unit tests for buildMCPToolsRun (task_1788372445618_0 follow-up)
// ============================================================================
//
// These tests cover the pure dispatch logic without spawning real MCP
// servers. The stdio spawn-failure path is exercised with a bogus
// command (which fails fast with ChildSpawnFailed, caught and skipped
// by buildMCPToolsRun's `continue`). The happy-path stdio handshake
// is covered by the functional test (mcp_stdio_test.py) and the manual
// graphify verification — unit tests can't spawn Python reliably.

const testing = std.testing;

test "buildMCPToolsRun: null input returns null (no servers configured)" {
    const result = try buildMCPToolsRun(testing.allocator, .null, null);
    try testing.expect(result == null);
}

test "buildMCPToolsRun: non-object input returns null" {
    const arr = std.json.Value{ .array = std.json.Array.init(testing.allocator) };
    const result = try buildMCPToolsRun(testing.allocator, arr, null);
    try testing.expect(result == null);

    const str = std.json.Value{ .string = "not-an-object" };
    const result2 = try buildMCPToolsRun(testing.allocator, str, null);
    try testing.expect(result2 == null);
}

test "buildMCPToolsRun: empty object returns empty slice (not null)" {
    var obj = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer obj.deinit(testing.allocator);
    const result = try buildMCPToolsRun(testing.allocator, .{ .object = obj }, null);
    try testing.expect(result != null);
    defer testing.allocator.free(result.?);
    try testing.expectEqual(@as(usize, 0), result.?.len);
}

test "buildMCPToolsRun: non-object server entry is skipped" {
    var obj = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer obj.deinit(testing.allocator);
    // Server entry is a string, not an object — should be skipped
    try obj.put(testing.allocator, try testing.allocator.dupe(u8, "bad"), .{ .string = "not-an-object" });
    // Free the duped key (ObjectMap.deinit doesn't free keys)
    defer {
        var it = obj.iterator();
        while (it.next()) |kv| testing.allocator.free(kv.key_ptr.*);
    }
    const result = try buildMCPToolsRun(testing.allocator, .{ .object = obj }, null);
    try testing.expect(result != null);
    defer testing.allocator.free(result.?);
    try testing.expectEqual(@as(usize, 0), result.?.len);
}

test "buildMCPToolsRun: server with neither command nor url is skipped" {
    var server_obj = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer server_obj.deinit(testing.allocator);
    // Empty server object — no command, no url
    var outer = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer outer.deinit(testing.allocator);
    const key = try testing.allocator.dupe(u8, "empty");
    defer testing.allocator.free(key);
    try outer.put(testing.allocator, key, .{ .object = server_obj });
    const result = try buildMCPToolsRun(testing.allocator, .{ .object = outer }, null);
    try testing.expect(result != null);
    defer testing.allocator.free(result.?);
    try testing.expectEqual(@as(usize, 0), result.?.len);
}

test "buildMCPToolsRun: stdio server with bogus command is skipped (no crash)" {
    // Uses a non-existent binary — acquire fails with ChildSpawnFailed,
    // which buildMCPToolsRun catches and skips. Proves the spawn-failure
    // path doesn't crash or propagate the error.
    //
    // NOTE: this touches StdioRegistry.global (process-global singleton
    // backed by testing.allocator). Clean it up afterwards so the
    // DebugAllocator doesn't report the registry's arena as a leak.
    const json_text =
        \\{"bad": {"command": "/no/such/binary/should/exist/xyzzy", "args": []}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_text, .{});
    defer parsed.deinit();
    const result = try buildMCPToolsRun(testing.allocator, parsed.value, null);
    try testing.expect(result != null);
    defer testing.allocator.free(result.?);
    try testing.expectEqual(@as(usize, 0), result.?.len);
    mcp_stdio.StdioRegistry.deinitGlobal();
}

test "buildMCPToolsRun: stdio server with empty command is skipped" {
    const json_text =
        \\{"empty": {"command": "", "args": []}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_text, .{});
    defer parsed.deinit();
    const result = try buildMCPToolsRun(testing.allocator, parsed.value, null);
    try testing.expect(result != null);
    defer testing.allocator.free(result.?);
    // Empty command → MCPServerCommandNotFound → skipped
    try testing.expectEqual(@as(usize, 0), result.?.len);
}

test "buildMCPToolsRun: disabled servers are skipped (enabled server's tools only)" {
    // MCP server toggle: a server with explicit `"enabled": false` must
    // be skipped BEFORE any spawn/connect, so only the enabled server's
    // `mcp_<server>_<tool>` names reach the agent.
    //
    // Both entries point at the same tiny POSIX fake MCP server: a
    // `/bin/sh` loop that answers `initialize` + `tools/list` over NDJSON
    // and stays silent on `notifications/initialized` (which carries no
    // `params`, so the `*params*` branch only matches `initialize`).
    // Before the filter, both prefixes appear (len == 2) and this test
    // fails; after, only the enabled prefix remains (len == 1).
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const script =
        \\while read -r line; do case $line in *tools/list*) echo '{"jsonrpc":"2.0","id":"2","result":{"tools":[{"name":"hello","description":"says hi","inputSchema":{"type":"object","properties":{}}}]}}';; *params*) echo '{"jsonrpc":"2.0","id":"1","result":{"protocolVersion":"2024-11-05"}}';; esac; done
    ;
    var args_ena = std.json.Array.init(testing.allocator);
    var args_dis = std.json.Array.init(testing.allocator);
    var ena_obj = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    var dis_obj = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    var outer = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer {
        args_ena.deinit();
        args_dis.deinit();
        var oi = outer.iterator();
        while (oi.next()) |kv| testing.allocator.free(kv.key_ptr.*);
        outer.deinit(testing.allocator);
        var ei = ena_obj.iterator();
        while (ei.next()) |kv| testing.allocator.free(kv.key_ptr.*);
        ena_obj.deinit(testing.allocator);
        var di = dis_obj.iterator();
        while (di.next()) |kv| testing.allocator.free(kv.key_ptr.*);
        dis_obj.deinit(testing.allocator);
    }
    try args_ena.append(.{ .string = "-c" });
    try args_ena.append(.{ .string = script });
    try args_dis.append(.{ .string = "-c" });
    try args_dis.append(.{ .string = script });
    try ena_obj.put(testing.allocator, try testing.allocator.dupe(u8, "command"), .{ .string = "/bin/sh" });
    try ena_obj.put(testing.allocator, try testing.allocator.dupe(u8, "args"), .{ .array = args_ena });
    try ena_obj.put(testing.allocator, try testing.allocator.dupe(u8, "enabled"), .{ .bool = true });
    try dis_obj.put(testing.allocator, try testing.allocator.dupe(u8, "command"), .{ .string = "/bin/sh" });
    try dis_obj.put(testing.allocator, try testing.allocator.dupe(u8, "args"), .{ .array = args_dis });
    try dis_obj.put(testing.allocator, try testing.allocator.dupe(u8, "enabled"), .{ .bool = false });
    try outer.put(testing.allocator, try testing.allocator.dupe(u8, "ena"), .{ .object = ena_obj });
    try outer.put(testing.allocator, try testing.allocator.dupe(u8, "dis"), .{ .object = dis_obj });

    const result = try buildMCPToolsRun(testing.allocator, .{ .object = outer }, null);
    // Kills the spawned `sh` children + frees the registry arena (same
    // cleanup the bogus-command test does for its failed spawns).
    defer mcp_stdio.StdioRegistry.deinitGlobal();
    defer {
        if (result) |tools| {
            for (tools) |*t| {
                testing.allocator.free(t.function.name);
                testing.allocator.free(t.function.description);
                for (t.function.parameters.properties) |*p| {
                    testing.allocator.free(p.name);
                    testing.allocator.free(p.type);
                    testing.allocator.free(p.description);
                }
                if (t.function.parameters.properties.len > 0) testing.allocator.free(t.function.parameters.properties);
                if (t.function.parameters.required.len > 0) testing.allocator.free(t.function.parameters.required);
            }
            testing.allocator.free(tools);
        }
    }
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 1), result.?.len);
    try testing.expectEqualStrings("mcp_ena_hello", result.?[0].function.name);
}

// ============================================================================
// Agent-visibility wiring tests: prove the agent CAN see MCP tools
// ============================================================================
//
// These tests verify the contract that matters to the user: when MCP
// tools ARE fetched, they appear as `mcp_<server>_<tool>` in the
// agent's tool list. They use mock data (no child spawn) so they're
// fast and hermetic.

test "convertMcpToolsToAgentTools: names are mcp_<server>_<tool> (agent sees them)" {
    // Mock one MCP tool like graphify's query_graph
    const props_json =
        \\{"question": {"type": "string", "description": "Question to ask"}}
    ;
    var props_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, props_json, .{});
    defer props_parsed.deinit();
    const mcp_tools = [_]mcp_types.McpTool{.{
        .name = "query_graph",
        .description = "Search the knowledge graph",
        .inputSchema = .{
            .type = "object",
            .properties = props_parsed.value,
            .required = null,
        },
    }};
    const result = try convertMcpToolsToAgentTools(testing.allocator, &mcp_tools, "graphify");
    defer {
        for (result) |*t| {
            testing.allocator.free(t.function.name);
            testing.allocator.free(t.function.description);
            for (t.function.parameters.properties) |*p| {
                testing.allocator.free(p.name);
                testing.allocator.free(p.type);
                testing.allocator.free(p.description);
            }
            testing.allocator.free(t.function.parameters.properties);
            testing.allocator.free(t.function.parameters.required);
        }
        testing.allocator.free(result);
    }
    try testing.expectEqual(@as(usize, 1), result.len);
    // THE contract: agent sees mcp_graphify_query_graph
    try testing.expectEqualStrings("mcp_graphify_query_graph", result[0].function.name);
    try testing.expectEqualStrings("Search the knowledge graph", result[0].function.description);
    try testing.expectEqual(@as(usize, 1), result[0].function.parameters.properties.len);
    try testing.expectEqualStrings("question", result[0].function.parameters.properties[0].name);
}

test "fetchToolsFromServerStdio: empty command returns MCPServerCommandNotFound (no spawn)" {
    // Fast-failure path — no child spawned, no global registry touched.
    var empty_obj = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer empty_obj.deinit(testing.allocator);
    const err = fetchToolsFromServerStdio(testing.allocator, "srv", empty_obj, 1_000_000_000, null);
    try testing.expectError(error.MCPServerCommandNotFound, err);
}

test "fetchToolsFromServerStdio: missing command field returns MCPServerCommandNotFound" {
    var obj = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer obj.deinit(testing.allocator);
    // Has url but no command — fetchToolsFromServerStdio only looks at
    // command/args, so empty argv → CommandNotFound
    const err = fetchToolsFromServerStdio(testing.allocator, "srv", obj, 1_000_000_000, null);
    try testing.expectError(error.MCPServerCommandNotFound, err);
}

// ─── Cross-project cwd prompt ───────────────────────────────────────────
// Static intro + dynamic sibling-cwd loop (workspace_items only).
// Rendered in buildMessages right after the workspace listing;
// build_agent_prompt keeps the static intro (no db to loop).

test "CrossProjectCwdRule content encourages sibling reads without guardrails" {
    const rule = prompts_const.CrossProjectCwdRule;
    try testing.expect(std.mem.indexOf(u8, rule, "## Cross-Project Context") != null);
    try testing.expect(std.mem.indexOf(u8, rule, "workspace_items only") != null);
    try testing.expect(std.mem.indexOf(u8, rule, "read_file") != null);
    try testing.expect(std.mem.indexOf(u8, rule, "Guardrails") == null);
    try testing.expect(std.mem.indexOf(u8, rule, "do NOT modify") == null);
}

// -------------------------------------------------------------------------
// Cross-project cwd, live path. The static intro and the dynamic sibling
// loop are both emitted by buildMessages, so this drives the assembler
// and reads the prompt it returns rather than reading its source.
// `makeCrossProjectCwdContext` has its own unit tests for the SQL side
// (prompts_make_cross_project_context.zig); what only the assembled
// prompt can prove is that the block reaches the agent at all, and that
// it lands after the workspace listing.
// -------------------------------------------------------------------------

const migration = @import("../migrations/migration.zig");

fn setupPromptDb() !PromptDbCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

const PromptDbCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn insertWorkspaceItem(db: *sqlite.SqliteBackend, id: []const u8, workspace_id: []const u8, name: []const u8, path: []const u8) !void {
    try db.exec(testing.allocator,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES (?, ?, 'chat', ?, ?, 0)
    , &[_][]const u8{ id, workspace_id, name, path });
}

fn insertWorkspaceTask(db: *sqlite.SqliteBackend, task_id: []const u8, item_id: []const u8) !void {
    try db.exec(testing.allocator,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id, created_at, updated_at, task_type)
        \\VALUES (?, 'T', ?, datetime('now'), datetime('now'), 'standard')
    , &[_][]const u8{ task_id, item_id });
}

test "buildMessages: the cross-project block reaches the prompt, after the workspace, listing workspace_items siblings" {
    var ctx = try setupPromptDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx.db, "item_self", "ws_1", "Self", "/nowhere/self");
    try insertWorkspaceItem(&ctx.db, "item_sibling", "ws_1", "Sibling", "/nowhere/sibling");
    // A different workspace: a cwd the agent may know about, but which is
    // NOT reachable from this session's workspace, so it must not show up.
    try insertWorkspaceItem(&ctx.db, "item_other_ws", "ws_2", "Other", "/nowhere/other-workspace");
    try insertWorkspaceTask(&ctx.db, "sess_cross", "item_self");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const cwd = try testing.allocator.dupe(u8, path_buf[0..n]);
    defer testing.allocator.free(cwd);

    const messages = try buildMessages(
        testing.allocator,
        ctx.threaded.io(),
        &ctx.db,
        cwd,
        "sess_cross",
        "",
        &.{},
        &.{},
        "",
        "",
    );
    const prompt = try testing.allocator.dupe(u8, messages[0].content orelse "");
    for (messages) |*msg| msg.deinit(testing.allocator);
    testing.allocator.free(messages);
    defer testing.allocator.free(prompt);

    // The static intro reached the live prompt, and it reads AFTER the
    // workspace listing (the agent needs to know the workspace id first).
    const ws_at = std.mem.indexOf(u8, prompt, "## Workspace Context") orelse
        return error.WorkspaceBlockMissing;
    const cross_at = std.mem.indexOf(u8, prompt, "## Cross-Project Context") orelse
        return error.CrossProjectBlockMissing;
    try testing.expect(ws_at < cross_at);

    // The dynamic sibling loop ran and listed the sibling cwd. Its row
    // format ("- `<path>` (<name>) [item_id: `<id>`]") is distinct from the
    // workspace listing's, so this cannot be satisfied by that block alone.
    try testing.expect(std.mem.indexOf(u8, prompt, "Sibling project directories:") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "- `/nowhere/sibling` (Sibling) [item_id: `item_sibling`]") != null);

    // Source is workspace_items ONLY: the loop excludes the session's own
    // item, and a cwd from another workspace never reaches the prompt.
    // (The workspace block does print the self path as a cwd hint, so the
    // exclusion is asserted against the loop's own row format.)
    try testing.expect(std.mem.indexOf(u8, prompt, "[item_id: `item_self`]") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "/nowhere/other-workspace") == null);
}

test "build_agent_prompt renders CrossProject section after workspace" {
    const alloc = testing.allocator;
    const io = testing.io;
    const tools = [_]tool_models.AgentTool{};
    const workspaceContext =
        \\## Workspace Context
        \\
        \\This task is part of workspace `ws_x`.
        \\
    ;
    const prompt = try build_agent_prompt(
        alloc,
        io,
        "/tmp",
        "",
        "",
        "",
        "",
        &tools,
        "",
        null,
        "",
        workspaceContext,
        "",
        "",
    );
    defer alloc.free(prompt);
    try testing.expect(std.mem.indexOf(u8, prompt, "## Cross-Project Context") != null);
    const ws_pos = std.mem.indexOf(u8, prompt, "## Workspace Context") orelse
        return error.WorkspaceMissing;
    const cross_pos = std.mem.indexOf(u8, prompt, "## Cross-Project Context") orelse
        return error.CrossProjectMissing;
    try testing.expect(ws_pos < cross_pos);
}

//! Agent-callable tool: `used_tools` — list the tools currently equipped
//! for this session (the "what tools am I using" answer).
//!
//! Wire shape:
//!   input:  {} (no params — the session is implicit from
//!           `ToolExecContext` in the exec adapter)
//!   output: {"count":N,"tools":[{"name":...,"description":...}, ...]}
//!
//! The list mirrors `workflow.filterAndMergeTools` (the dispatch-time
//! truth): the allowlist-filtered built-ins for this session's mode
//! (agent / kanban / routine / design / plain chat) plus anything the
//! session equipped later via `use_tool` (built-ins and MCP tools).
//! The prompt-time item-type strip is deliberately NOT applied —
//! `handle_tool` dispatches by registry name without consulting it,
//! so the merge result is what the agent can actually call.
//!
//! Design choices (mirror `list_sub_agent.zig` / `get_plan.zig`):
//!   - The pure fn takes an explicit `[]const ToolSummary` slice (NOT
//!     the registry) so this file stays a leaf: it never imports
//!     `agentic_loop`, and unit tests feed it hand-built slices.
//!     The exec adapter maps `AgentTool` → `ToolSummary`.
//!   - Read-only, no side effects. Safe for sub-agents (NOT main-agent-only).

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

/// Input for `used_tools`. Empty struct — no params, the session is implicit.
pub const UsedToolsInput = struct {};

/// Top-level tool definition for the LLM. The description is the
/// agent's primary signal for WHEN to call this tool — it names the
/// sibling discovery tools so the agent knows `used_tools` answers
/// "what do I already have" while `search_tool` answers "what else exists".
pub const used_tools_tool_system_prompt =
    \\## Used Tools Tool — Behavior
    \\Use `used_tools` to list the tools currently equipped for this session.
    \\- No parameters. Returns each equipped tool's name and description.
    \\- Call this when you need to answer "what tools do I have" or to check whether a tool is available before calling it.
    \\- To discover tools you do NOT have yet, use `search_tool` / `view_tool`, then `use_tool` to equip one. Read-only, no side effects.
    \\
;

pub const used_tools_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "used_tools",
        .description =
        \\List the tools currently equipped for this session with their name and description, so you can check what you have before calling one. To find a tool you lack: search_tool → view_tool → use_tool. Read-only, no side effects.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
        .system_prompt = used_tools_tool_system_prompt,
    },
};

/// One equipped tool as the LLM sees it. The exec adapter builds these
/// from `AgentTool` defs (built-ins) and the MCP cache (equipped MCP tools).
pub const ToolSummary = struct {
    name: []const u8,
    description: []const u8,
};

/// Execute used_tools. Returns a JSON string for the LLM:
/// `{"count":N,"tools":[{"name":...,"description":...}]}`.
///
/// Caller owns the returned slice and must free it with `allocator.free()`.
/// The slice is passed explicitly (NOT via `ToolExecContext`) so this pure
/// fn is testable in isolation. The exec adapter resolves the session's
/// effective tool list and forwards it here.
pub fn executeUsedTools(
    allocator: std.mem.Allocator,
    equipped: []const ToolSummary,
) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .count = equipped.len,
        .tools = equipped,
    }, .{});
}

const testing = std.testing;

test "executeUsedTools: empty equipped list yields count 0 and empty tools" {
    const alloc = testing.allocator;
    const out = try executeUsedTools(alloc, &.{});
    defer alloc.free(out);
    try testing.expectEqualStrings("{\"count\":0,\"tools\":[]}", out);
}

test "executeUsedTools: populated list echoes names and descriptions" {
    const alloc = testing.allocator;
    const equipped = [_]ToolSummary{
        .{ .name = "read_file", .description = "Read a file." },
        .{ .name = "mcp_graphify_query_graph", .description = "Ask the graph." },
    };
    const out = try executeUsedTools(alloc, &equipped);
    defer alloc.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), obj.get("count").?.integer);
    const tools = obj.get("tools").?.array;
    try testing.expectEqual(@as(usize, 2), tools.items.len);
    try testing.expectEqualStrings("read_file", tools.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("Read a file.", tools.items[0].object.get("description").?.string);
    try testing.expectEqualStrings("mcp_graphify_query_graph", tools.items[1].object.get("name").?.string);
}

test "executeUsedTools: preserves input order" {
    const alloc = testing.allocator;
    const equipped = [_]ToolSummary{
        .{ .name = "write_file", .description = "w" },
        .{ .name = "command", .description = "c" },
        .{ .name = "ask_user", .description = "a" },
    };
    const out = try executeUsedTools(alloc, &equipped);
    defer alloc.free(out);
    const write_pos = std.mem.indexOf(u8, out, "\"write_file\"").?;
    const command_pos = std.mem.indexOf(u8, out, "\"command\"").?;
    const ask_pos = std.mem.indexOf(u8, out, "\"ask_user\"").?;
    try testing.expect(write_pos < command_pos);
    try testing.expect(command_pos < ask_pos);
}

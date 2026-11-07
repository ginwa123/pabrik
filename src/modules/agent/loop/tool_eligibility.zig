//! Pure tool-eligibility helpers shared by the agentic loop. Two independent
//! policies decide which built-in tools a *thing* may have: 1.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const agent = pabrikcore.agent;
const AgentTool = agent.AgentTool;

const kanban_list_mod = pabrikcore.kanban_list;
const kanban_move_task_mod = pabrikcore.kanban_move_task;
const kanban_create_task_tool = pabrikcore.create_kanban_task;
const main_agent_only = pabrikcore.main_agent_only;
const set_design_page_mod = pabrikcore.set_design_page;
const add_design_element_mod = pabrikcore.add_design_element;
const update_design_element_mod = pabrikcore.update_design_element;
const group_design_elements_mod = pabrikcore.group_design_elements;
const set_element_parent_mod = pabrikcore.set_element_parent;
const move_design_element_mod = pabrikcore.move_design_element;
const move_element_to_page_mod = pabrikcore.move_element_to_page;

/// Tools that only make sense inside a kanban item. Stripped for `design`
/// and `folder` items.
pub const KANBAN_ONLY_NAMES = [_][]const u8{
    kanban_list_mod.kanban_list_tool.function.name,
    kanban_move_task_mod.kanban_move_task_tool.function.name,
    kanban_create_task_tool.create_kanban_task_tool.function.name,
};

/// Tools that only make sense inside a design item. Stripped for `kanban`
/// and `folder` items.
pub const DESIGN_ONLY_NAMES = [_][]const u8{
    set_design_page_mod.set_design_page_tool.function.name,
    add_design_element_mod.add_design_element_tool.function.name,
    update_design_element_mod.update_design_element_tool.function.name,
    group_design_elements_mod.group_design_element_tool.function.name,
    set_element_parent_mod.set_element_parent_tool.function.name,
    move_design_element_mod.move_design_element_tool.function.name,
    move_element_to_page_mod.move_element_to_page_tool.function.name,
};

fn dupeToolList(allocator: std.mem.Allocator, tools: []const AgentTool) ![]AgentTool {
    const out = try allocator.alloc(AgentTool, tools.len);
    @memcpy(out, tools);
    return out;
}

fn nameInAny(name: []const u8, names: []const []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Apply the agent/kanban allowlist + the sub-agent anti-recursion strip.
/// `allowed_tools` semantics: - `""` (empty) → NO filtering (every tool
/// kept).
pub fn allowlistFilter(
    allocator: std.mem.Allocator,
    tools: []const AgentTool,
    allowed_tools: []const u8,
    is_sub_agent: bool,
) ![]AgentTool {
    // WHY: exact `none` is the explicit-empty sentinel and must mean ZERO
    // tools — distinct from the pre-existing `""` wart above ("no filtering →
    // keep everything").
    if (std.mem.eql(u8, allowed_tools, "none")) {
        return try allocator.alloc(AgentTool, 0);
    }

    var kept = try dupeToolList(allocator, tools);

    if (allowed_tools.len > 0 and !std.mem.eql(u8, allowed_tools, "all")) {
        var allowed_set: std.StringArrayHashMapUnmanaged(void) = .{};

        var it = std.mem.splitScalar(u8, allowed_tools, ',');
        while (it.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " ");
            if (trimmed.len > 0) {
                try allowed_set.put(allocator, trimmed, {});
            }
        }

        var count: usize = 0;
        for (kept) |tool| {
            if (allowed_set.contains(tool.function.name)) {
                kept[count] = tool;
                count += 1;
            }
        }
        kept = kept[0..count];
    }

    // Main-agent-only tools must not reach a sub-agent: `spawn_sub_agent`
    // would recurse, `run_session` and `run_skill_eval` start a whole new run.
    if (is_sub_agent) {
        var count: usize = 0;
        for (kept) |tool| {
            if (!main_agent_only.isMainAgentOnly(tool.function.name)) {
                kept[count] = tool;
                count += 1;
            }
        }
        kept = kept[0..count];
    }

    return kept;
}

/// Strip the tools the given workspace-item type must not carry: - `design` →
/// no kanban tools - `kanban` → no design tools - `folder` → neither -
/// anything else (`agent`, `chat`, empty, unknown) → unchanged Compacts in
pub fn itemTypeStrip(tools: []AgentTool, self_item_type: []const u8) []AgentTool {
    const strip_kanban = std.mem.eql(u8, self_item_type, "design") or
        std.mem.eql(u8, self_item_type, "folder");
    const strip_design = std.mem.eql(u8, self_item_type, "kanban") or
        std.mem.eql(u8, self_item_type, "folder");
    if (!strip_kanban and !strip_design) return tools;

    var count: usize = 0;
    for (tools) |tool| {
        const name = tool.function.name;
        if (strip_kanban and nameInAny(name, &KANBAN_ONLY_NAMES)) continue;
        if (strip_design and nameInAny(name, &DESIGN_ONLY_NAMES)) continue;
        tools[count] = tool;
        count += 1;
    }
    return tools[0..count];
}

/// Names of the tools that survive both policies. Convenience for callers
/// that only need membership (the progressive catalog) rather than the
/// tool definitions.
pub fn eligibleNames(
    allocator: std.mem.Allocator,
    tools: []const AgentTool,
    allowed_tools: []const u8,
    is_sub_agent: bool,
    self_item_type: []const u8,
) ![]const []const u8 {
    const after_allowlist = try allowlistFilter(allocator, tools, allowed_tools, is_sub_agent);
    const after_item_type = itemTypeStrip(after_allowlist, self_item_type);

    const out = try allocator.alloc([]const u8, after_item_type.len);
    for (after_item_type, 0..) |t, i| out[i] = t.function.name;
    return out;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn makeTools(allocator: std.mem.Allocator, names: []const []const u8) ![]AgentTool {
    const out = try allocator.alloc(AgentTool, names.len);
    for (names, 0..) |n, i| {
        out[i] = .{
            .type = "function",
            .function = .{
                .name = n,
                .description = "",
                .parameters = .{ .type = "object", .properties = &.{}, .required = &.{} },
            },
        };
    }
    return out;
}

fn collectNames(allocator: std.mem.Allocator, tools: []const AgentTool) ![][]const u8 {
    const out = try allocator.alloc([]const u8, tools.len);
    for (tools, 0..) |t, i| out[i] = t.function.name;
    return out;
}

/// Compare expected names against either a name list (`[]const []const u8`)
/// or a tool list (`[]AgentTool`). Chosen by the element type at comptime so
/// callers do not have to convert.
fn expectNames(expected: []const []const u8, actual: anytype) !void {
    const child = @typeInfo(@TypeOf(actual)).pointer.child;
    if (child == AgentTool) {
        try testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |e, t| try testing.expectEqualStrings(e, t.function.name);
    } else {
        try testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
    }
}

test "allowlistFilter: empty string keeps every tool (pre-existing semantics)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tools = try makeTools(a, &.{ "read_file", "glob", "search" });
    const kept = try allowlistFilter(a, tools, "", false);
    try expectNames(&.{ "read_file", "glob", "search" }, kept);
}

test "allowlistFilter: exact \"none\" yields an empty tool set (D3 sentinel)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Empty even for a main agent, where no sub-agent strip applies —
    // the sentinel short-circuits before name matching.
    const tools = try makeTools(a, &.{ "read_file", "glob", "search" });
    const kept = try allowlistFilter(a, tools, "none", false);
    try expectNames(&.{}, kept);

    // …and a CSV that merely CONTAINS the word "none" is an ordinary
    // allowlist (unknown names are ignored, the rest match).
    const kept2 = try allowlistFilter(a, tools, "none,read_file", false);
    try expectNames(&.{"read_file"}, kept2);
}

test "allowlistFilter: \"all\" keeps every tool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tools = try makeTools(a, &.{ "read_file", "glob" });
    const kept = try allowlistFilter(a, tools, "all", false);
    try expectNames(&.{ "read_file", "glob" }, kept);
}

test "allowlistFilter: CSV keeps only listed names, preserving registry order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tools = try makeTools(a, &.{ "read_file", "glob", "search", "bash" });
    // Note the reversed CSV order: output must follow the registry order,
    // exactly like the original inline filter did.
    const kept = try allowlistFilter(a, tools, "search, read_file", false);
    try expectNames(&.{ "read_file", "search" }, kept);
}

test "allowlistFilter: unknown names in the CSV are ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tools = try makeTools(a, &.{"read_file"});
    const kept = try allowlistFilter(a, tools, "read_file,does_not_exist", false);
    try expectNames(&.{"read_file"}, kept);
}

test "allowlistFilter: whitespace and empty CSV segments are tolerated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tools = try makeTools(a, &.{ "read_file", "glob" });
    const kept = try allowlistFilter(a, tools, "  read_file ,,", false);
    try expectNames(&.{"read_file"}, kept);
}

test "allowlistFilter: sub-agent strips spawn_sub_agent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tools = try makeTools(a, &.{ "spawn_sub_agent", "list_agents", "read_file" });
    const kept = try allowlistFilter(a, tools, "", true);
    try expectNames(&.{ "list_agents", "read_file" }, kept);
}

test "allowlistFilter: a main agent keeps every main-agent-only tool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tools = try makeTools(a, &.{ "spawn_sub_agent", "run_skill_eval", "read_file" });
    const kept = try allowlistFilter(a, tools, "", false);
    try expectNames(&.{ "spawn_sub_agent", "run_skill_eval", "read_file" }, kept);
}

test "allowlistFilter: sub-agent strip covers every MAIN_AGENT_ONLY_NAMES entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build a tool list from the list itself, so adding a member to
    // MAIN_AGENT_ONLY_NAMES without updating this strip fails here.
    var names_buf: [main_agent_only.MAIN_AGENT_ONLY_NAMES.len + 1][]const u8 = undefined;
    @memcpy(names_buf[0..main_agent_only.MAIN_AGENT_ONLY_NAMES.len], &main_agent_only.MAIN_AGENT_ONLY_NAMES);
    names_buf[main_agent_only.MAIN_AGENT_ONLY_NAMES.len] = "read_file";

    const tools = try makeTools(a, &names_buf);
    const kept = try allowlistFilter(a, tools, "", true);
    try expectNames(&.{"read_file"}, kept);
}

test "allowlistFilter: sub-agent strip applies AFTER the allowlist" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tools = try makeTools(a, &.{ "spawn_sub_agent", "read_file" });
    const kept = try allowlistFilter(a, tools, "spawn_sub_agent,read_file", true);
    try expectNames(&.{"read_file"}, kept);
}

test "itemTypeStrip: design item loses the 3 kanban tools" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tools = try makeTools(a, &.{ "read_file", "kanban_list", "kanban_move_task", "create_kanban_task", "set_design_page" });
    const kept = itemTypeStrip(tools, "design");
    try expectNames(&.{ "read_file", "set_design_page" }, kept);
}

test "itemTypeStrip: kanban item loses all 7 design tools" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var names_buf: [2 + DESIGN_ONLY_NAMES.len][]const u8 = undefined;
    names_buf[0] = "read_file";
    names_buf[1] = "kanban_list";
    @memcpy(names_buf[2..], &DESIGN_ONLY_NAMES);
    const tools = try makeTools(a, &names_buf);
    const kept = itemTypeStrip(tools, "kanban");
    try expectNames(&.{ "read_file", "kanban_list" }, kept);
}

test "itemTypeStrip: folder loses both kanban and design tools" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const total = 1 + KANBAN_ONLY_NAMES.len + DESIGN_ONLY_NAMES.len;
    var names_buf: [total][]const u8 = undefined;
    names_buf[0] = "read_file";
    @memcpy(names_buf[1 .. 1 + KANBAN_ONLY_NAMES.len], &KANBAN_ONLY_NAMES);
    @memcpy(names_buf[1 + KANBAN_ONLY_NAMES.len ..], &DESIGN_ONLY_NAMES);
    const tools = try makeTools(a, &names_buf);
    const kept = itemTypeStrip(tools, "folder");
    try expectNames(&.{"read_file"}, kept);
}

test "itemTypeStrip: agent/chat/empty/unknown item types are untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const names = &.{ "read_file", "kanban_list", "set_design_page" };
    for ([_][]const u8{ "agent", "chat", "", "workspace" }) |item_type| {
        const tools = try makeTools(a, names);
        const kept = itemTypeStrip(tools, item_type);
        try expectNames(names, kept);
    }
}

test "KANBAN_ONLY_NAMES / DESIGN_ONLY_NAMES match the wire tool names" {
    try expectNames(&.{ "kanban_list", "kanban_move_task", "create_kanban_task" }, &KANBAN_ONLY_NAMES);
    try expectNames(&.{
        "set_design_page",
        "add_element",
        "update_element",
        "group_elements",
        "set_element_parent",
        "move_design_element",
        "move_element_to_page",
    }, &DESIGN_ONLY_NAMES);
}

test "eligibleNames: both policies compose" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tools = try makeTools(a, &.{ "read_file", "glob", "kanban_list", "set_design_page", "spawn_sub_agent" });
    // Kanban item, allowlist of 4, sub-agent → spawn stripped by policy 1,
    // design stripped by policy 2.
    const names = try eligibleNames(a, tools, "read_file,glob,kanban_list,spawn_sub_agent", true, "kanban");
    try expectNames(&.{ "read_file", "glob", "kanban_list" }, names);
}

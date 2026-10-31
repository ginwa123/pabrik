//! `GET /api/agent-tools/registry`. Returns the canonical tool registry as
//! `{tools: [{name, description, parameters, kind}]}`. With `?include_mcp=1`
//! the tools the requested workspace's MCP servers advertise are appended.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const auth_common = @import("auth_common.zig");
const tools_equipped = @import("../modules/agent/tools/tools_equipped.zig");
const build_msg_prompt = @import("../agentic_loop/prompts_build_messages_for_agent_prompt.zig");
const tool_models = pabrikcore.tool_models;

/// `kind` of a compiled-in tool.
pub const KIND_BUILTIN = "builtin";
/// `kind` of a tool an MCP server advertised for this request.
pub const KIND_MCP = "mcp";

/// One parameter of a registry entry's schema.
pub const RegistryParameter = struct {
    /// Borrowed from the tool definition (static, lives forever).
    name: []const u8,
    type: []const u8,
    /// True when the JSON schema lists it in `required`. A REQUIRED `cwd` is
    /// what stops a path-taking call from silently inheriting the server's
    /// working directory instead of the one the model is editing.
    required: bool,
};

/// One entry in the registry response.
pub const RegistryEntry = struct {
    name: []const u8,
    /// Owned by the use-case (lifetime = request arena).
    description: []const u8,
    /// One row per schema property, in declaration order. Owned by the
    /// use-case (lifetime = request arena).
    parameters: []const RegistryParameter,
    /// `builtin` or `mcp` — the picker badges the second kind.
    kind: []const u8,
};

/// Domain-level error set for `useCase`.
pub const RegistryError = error{
    /// `allocator.dupe` failed while copying descriptions.
    OutOfMemory,
};

/// Output of the registry use-case.
pub const RegistryOutput = struct {
    entries: []const RegistryEntry,
};

// =====================================================================
// Use case
// =====================================================================

/// Transform the runtime registry into a slice of registry entries, plus one
/// entry per tool the configured MCP servers advertised.
fn useCase(allocator: std.mem.Allocator, mcp_tools: ?[]const tool_models.AgentTool) RegistryError!RegistryOutput {
    const registry = tools_equipped.UNIFIED_TOOL_REGISTRY();

    var list: std.ArrayList(RegistryEntry) = .empty;
    for (registry) |entry| {
        const fn_def = entry.tool_def.function;
        try list.append(allocator, .{
            .name = entry.name,
            .description = try allocator.dupe(u8, fn_def.description),
            .parameters = try parametersFor(allocator, fn_def.parameters),
            .kind = KIND_BUILTIN,
        });
    }
    if (mcp_tools) |tools| try appendMcpEntries(allocator, &list, tools);
    return .{ .entries = try list.toOwnedSlice(allocator) };
}

/// One row per declared property, in declaration order, with `required`
/// resolved against the schema's own name list.
fn parametersFor(
    allocator: std.mem.Allocator,
    params: tool_models.ToolParameters,
) RegistryError![]const RegistryParameter {
    const out = try allocator.alloc(RegistryParameter, params.properties.len);
    for (params.properties, 0..) |prop, i| {
        var is_required = false;
        for (params.required) |name| {
            if (std.mem.eql(u8, name, prop.name)) is_required = true;
        }
        out[i] = .{ .name = prop.name, .type = prop.type, .required = is_required };
    }
    return out;
}

/// The MCP entries follow the built-ins and are sorted by wire name, so a
/// server answering `tools/list` in its own order cannot reshuffle the picker.
fn appendMcpEntries(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(RegistryEntry),
    tools: []const tool_models.AgentTool,
) RegistryError!void {
    const first_mcp = list.items.len;
    for (tools) |tool| {
        try list.append(allocator, .{
            .name = tool.function.name,
            .description = try allocator.dupe(u8, tool.function.description),
            .parameters = try parametersFor(allocator, tool.function.parameters),
            .kind = KIND_MCP,
        });
    }
    std.mem.sort(RegistryEntry, list.items[first_mcp..], {}, struct {
        fn byName(_: void, a: RegistryEntry, b: RegistryEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.byName);
}

// =====================================================================
// Handler
// =====================================================================

/// `?include_mcp=1` (or `true`): list the workspace's MCP tools too.
fn wantsMcpTools(req: gserverz.HttpRequest) bool {
    const flag = req.query.get("include_mcp") orelse return false;
    return std.mem.eql(u8, flag, "1") or std.mem.eql(u8, flag, "true");
}

/// The tools the requested workspace's MCP servers advertise right now. Live
/// rather than cached: `mcp_servers` is workspace-scoped, and the picker asks
/// once per open, so a stale name is worse than one `tools/list` roundtrip.
fn mcpToolsForRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    req: gserverz.HttpRequest,
) ?[]const tool_models.AgentTool {
    const di = pabrikcore.getSingleton() catch return null;
    const workspace_id = req.query.get("workspace_id") orelse "";

    const config = auth_common.requestWorkspaceConfig(allocator, di, workspace_id, req.headers) orelse
        pabrikcore.getLlmConfig(di);
    const servers = config.mcpServers() orelse return null;

    const owner = auth_common.resolveRequestUserId(allocator, di.db, di.auth_enabled, req.headers) catch "";

    // No cancel hook: the picker has no Stop button, and a hook that fires
    // mid-fetch would deny the transport its own cold-start retry.
    return build_msg_prompt.buildMCPToolsRun(allocator, servers, null, .{
        .scope = .{ .owner = owner, .workspace_id = workspace_id },
        .db = di.db,
        .io = io,
    }) catch null;
}

/// Thin orchestrator over `useCase`. Delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentToolsRegistryHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Only the composer's picker asks for MCP tools; the Settings checklist and
    // the kanban tools panel keep the compiled-in registry and pay no roundtrip.
    const mcp_tools = if (wantsMcpTools(req)) mcpToolsForRequest(allocator, ctx.io, req) else null;

    const output = useCase(allocator, mcp_tools) catch |err| {
        const status: u16 = switch (err) {
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Pass the entries directly — std.json.Stringify flattens each struct
    // into a `{name, description, parameters, kind}` object.
    const data = try std.json.Stringify.valueAlloc(allocator, .{ .tools = output.entries }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
// impl + tests in one file (project convention for Agent Mode).

const testing = std.testing;

/// Free everything `useCase` allocated.
fn freeOutput(alloc: std.mem.Allocator, output: RegistryOutput) void {
    for (output.entries) |e| {
        alloc.free(e.description);
        alloc.free(e.parameters);
    }
    alloc.free(output.entries);
}

fn findEntry(output: RegistryOutput, name: []const u8) ?RegistryEntry {
    for (output.entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

fn findParam(entry: RegistryEntry, name: []const u8) ?RegistryParameter {
    for (entry.parameters) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

fn findIndex(output: RegistryOutput, name: []const u8) ?usize {
    for (output.entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.name, name)) return i;
    }
    return null;
}

/// One MCP tool as `buildMCPToolsRun` hands it over: the wire name
/// `mcp_<server>_<tool>`, the server's description, and the advertised schema.
fn mcpToolFixture(
    alloc: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
    required_param: []const u8,
) !tool_models.AgentTool {
    const props = try alloc.alloc(tool_models.ToolProperty, 1);
    props[0] = .{
        .name = required_param,
        .type = "string",
        .description = "what to look up",
    };
    const required = try alloc.alloc([]const u8, 1);
    required[0] = required_param;
    return .{
        .type = "function",
        .function = .{
            .name = name,
            .description = description,
            .parameters = .{ .type = "object", .properties = props, .required = required },
        },
    };
}

test "useCase: every path-taking tool REQUIRES an absolute cwd" {
    // This is the contract the 2026-10-14 change introduced: a call that
    // touches the filesystem must say which tree it works in, or it silently
    // acts on the SERVER's directory instead of the one the model is editing.
    const alloc = testing.allocator;
    const output = try useCase(alloc, null);
    defer freeOutput(alloc, output);

    const path_tools = [_][]const u8{
        "read_file",
        "write_file",
        "text_replace",
        "remove_file",
        "glob",
        "list_directory",
        "present_files",
        "search",
        "set_git_worktree",
    };
    for (path_tools) |tool_name| {
        const entry = findEntry(output, tool_name) orelse {
            std.debug.print("registry is missing path-taking tool '{s}'\n", .{tool_name});
            return error.TestUnexpectedResult;
        };
        const cwd = findParam(entry, "cwd") orelse {
            std.debug.print("'{s}' has no `cwd` parameter\n", .{tool_name});
            return error.TestUnexpectedResult;
        };
        if (!cwd.required) {
            std.debug.print("'{s}' does not REQUIRE `cwd`\n", .{tool_name});
            return error.TestUnexpectedResult;
        }
    }

    // Controls, so the loop above cannot pass vacuously: a tool with no
    // filesystem parameter must not carry a `cwd`, and the two tools whose
    // `cwd` was dropped the same day must not have kept one.
    const cwd_free = [_][]const u8{ "create_kanban_task", "add_mcp_server" };
    for (cwd_free) |tool_name| {
        const entry = findEntry(output, tool_name) orelse {
            std.debug.print("registry is missing '{s}'\n", .{tool_name});
            return error.TestUnexpectedResult;
        };
        try testing.expect(findParam(entry, "cwd") == null);
    }

    // The swept tools are gone from the published schema too — being absent
    // from the registry is what makes a name uncallable. `list_agents` is
    // no longer swept: it is the live tool that lists the configured agents.
    for ([_][]const u8{ "change_agent", "remove_agent" }) |tool_name| {
        try testing.expect(findEntry(output, tool_name) == null);
    }
}

test "useCase: returns a non-empty registry" {
    const alloc = testing.allocator;
    const output = try useCase(alloc, null);
    defer freeOutput(alloc, output);
    try testing.expect(output.entries.len > 0);
}

test "useCase: every entry has non-empty name and description" {
    const alloc = testing.allocator;
    const output = try useCase(alloc, null);
    defer freeOutput(alloc, output);
    for (output.entries) |e| {
        try testing.expect(e.name.len > 0);
        try testing.expect(e.description.len > 0);
    }
}

test "useCase: an advertised MCP tool is listed after the built-ins with its schema" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const builtin_count = tools_equipped.UNIFIED_TOOL_REGISTRY().len;
    const mcp = [_]tool_models.AgentTool{
        try mcpToolFixture(alloc, "mcp_ctx_query-docs", "Query library documentation.", "query"),
    };

    const output = try useCase(alloc, &mcp);

    try testing.expectEqual(builtin_count + 1, output.entries.len);
    const idx = findIndex(output, "mcp_ctx_query-docs") orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(builtin_count, idx);

    const entry = output.entries[idx];
    try testing.expectEqualStrings(KIND_MCP, entry.kind);
    try testing.expectEqualStrings("Query library documentation.", entry.description);
    const query = findParam(entry, "query") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("string", query.type);
    try testing.expect(query.required);
    // The built-ins keep their own kind, so the picker can tell them apart.
    try testing.expectEqualStrings(KIND_BUILTIN, output.entries[0].kind);
}

test "useCase: MCP entries are sorted by wire name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const builtin_count = tools_equipped.UNIFIED_TOOL_REGISTRY().len;
    const mcp = [_]tool_models.AgentTool{
        try mcpToolFixture(alloc, "mcp_zeta_b", "Zeta second.", "b"),
        try mcpToolFixture(alloc, "mcp_alpha_a", "Alpha first.", "a"),
    };

    const output = try useCase(alloc, &mcp);

    try testing.expectEqualStrings("mcp_alpha_a", output.entries[builtin_count].name);
    try testing.expectEqualStrings("mcp_zeta_b", output.entries[builtin_count + 1].name);
}

test "useCase: no advertised MCP tools leaves the built-in registry unchanged" {
    const alloc = testing.allocator;
    const without = try useCase(alloc, null);
    defer freeOutput(alloc, without);
    const empty = try useCase(alloc, &.{});
    defer freeOutput(alloc, empty);
    const builtins_only = tools_equipped.UNIFIED_TOOL_REGISTRY();

    try testing.expectEqual(builtins_only.len, without.entries.len);
    try testing.expectEqual(builtins_only.len, empty.entries.len);
    for (without.entries, builtins_only) |entry, expected| {
        try testing.expectEqualStrings(expected.name, entry.name);
        try testing.expectEqualStrings(KIND_BUILTIN, entry.kind);
    }
    for (empty.entries, 0..) |entry, i| {
        try testing.expectEqualStrings(without.entries[i].name, entry.name);
    }
}

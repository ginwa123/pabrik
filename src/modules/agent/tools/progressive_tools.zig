//! Agent-callable tools for progressive tool search: `search_tool`,
//! `view_tool`, `use_tool`. The agent does not receive every tool up front.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

/// Input for `search_tool`. Every field optional: no args returns the first
/// page of the whole catalog.
pub const SearchToolInput = struct {
    query: ?[]const u8 = null,
    literal: ?bool = null,
    limit: ?i64 = null,
    offset: ?i64 = null,
    server: ?[]const u8 = null,
};

/// Input for `view_tool`.
pub const ViewToolInput = struct {
    name: ?[]const u8 = null,
};

/// Input for `use_tool`.
pub const UseToolInput = struct {
    name: ?[]const u8 = null,
};

pub const search_tool_system_prompt =
    \\## Search Tool — Behavior
    \\Some tools are NOT loaded into your context by default. `search_tool` finds them.
    \\- `query` is a REGEX (case-insensitive, unanchored) matched against tool names and descriptions. A pattern finds tools a phrase cannot: `^mcp_.*_create` (MCP create-tools on any server), `doc|documentation` (either spelling, one call), `\bsearch\b` (the word, not "searcher"). A query with no metacharacters still behaves as a plain substring search.
    \\- Set `literal: true` when the query is literal text rather than a pattern (e.g. `fn(`, `*.zig`) — otherwise its metacharacters are interpreted.
    \\- Results are PAGED: `limit` (default 40, max 200) caps how many rows you get back, `total` is the real match count, and `offset` skips matches. A broad query on a big catalog is browsed page by page — the `<hint>` tells you the next offset instead of dumping everything into your context.
    \\- An invalid pattern is not a failure: it is matched as a literal substring and the result carries `<pattern_warning>` listing the supported syntax. Read it instead of retrying blindly.
    \\- `server` narrows the search to one MCP server.
    \\- Results show `kind` (builtin/mcp), `server` and whether the entry is already enabled for this session.
    \\- Tools you already have in your tool list are NOT listed — check your own tool definitions first before concluding a capability is missing.
    \\- After finding a candidate, call `view_tool` for its full parameters, then `use_tool` to enable it.
    \\
;

pub const search_tool_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "search_tool",
        .description =
        \\Search the catalog of tools NOT enabled for this session — MCP tools and built-ins this agent does not have. `query` is a case-insensitive REGEX over tool names and descriptions; results are PAGED (`limit`/`offset`). Returns name, kind, server, enabled state and a one-line summary — never the full schema; call view_tool for that. Tools already in your tool list are excluded.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "query",
                    .type = "string",
                    .description = "Regex, matched case-insensitively against tool names and descriptions. A pattern finds tools a phrase cannot: '^mcp_.*_create' = MCP create-tools, 'doc|docs|documentation' = one call instead of three, '\\bsearch\\b' = the word, not 'searcher'. Supported: literals, '.', '[...]', '\\d \\w \\s', '\\b', '* + ? {m,n}', '( )', '|', '^', '$'. A metacharacter-free query is still a plain substring search; an invalid pattern falls back to one, flagged in <pattern_warning>. Omit to list the start of the catalog.",
                },
                .{
                    .name = "literal",
                    .type = "boolean",
                    .description = "Treat `query` as a literal string: '.', '*', '[', '(' are matched verbatim. Set this for code-shaped queries ('fn(', '*.zig'). Default false (regex mode).",
                },
                .{
                    .name = "limit",
                    .type = "number",
                    .description = "Maximum matches in THIS response (default 40, max 200), paged to keep the context window small; the result always reports the true `<total>`.",
                },
                .{
                    .name = "offset",
                    .type = "number",
                    .description = "Skip the first N matches (default 0) when paging a broad query. The previous page's `<hint>` names the offset that continues it.",
                },
                .{
                    .name = "server",
                    .type = "string",
                    .description = "Optional exact MCP server name (e.g. 'context7'); ignored for built-in tools.",
                },
            },
            .required = &.{},
        },
        .system_prompt = search_tool_system_prompt,
    },
};

pub const view_tool_system_prompt =
    \\## View Tool — Behavior
    \\Use `view_tool` to inspect ONE catalog entry's full parameter schema before committing to it.
    \\- Read-only: it never enables anything and writes nothing.
    \\- Pass the exact `name` from `search_tool`.
    \\- Use it when you need the real argument names/types, or to confirm a tool does what you need.
    \\- If the name is unknown you get a did-you-mean list — do not guess a name twice.
    \\
;

pub const view_tool_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "view_tool",
        .description =
        \\Show one catalog tool's full definition (description + JSON parameter schema) WITHOUT enabling it. Read-only, no side effects.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Exact tool name from search_tool (e.g. 'mcp_context7_query-docs').",
                },
            },
            .required = &.{"name"},
        },
        .system_prompt = view_tool_system_prompt,
    },
};

pub const use_tool_system_prompt =
    \\## Use Tool — Behavior
    \\Use `use_tool` to ENABLE a catalog tool for the rest of this session.
    \\- It takes effect on your NEXT turn — the current turn's tool list was already sent. You already saw the full parameter schema via `view_tool`, so the result is just the equip outcome.
    \\- It is idempotent: enabling an already-enabled tool writes nothing and reports inserted=false.
    \\- You cannot invent a name: unknown names are rejected with suggestions and nothing is written.
    \\- This only affects THIS session. It never changes the user's saved tool configuration.
    \\
;

pub const use_tool_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "use_tool",
        .description =
        \\Enable a catalog tool for this session — it becomes callable from your next turn (this turn's tool list was already sent). Idempotent — enabling an already-enabled tool is a no-op reporting inserted=false. Unknown names are rejected with suggestions and nothing is written. Session-scoped only: the user's saved tool configuration is never modified.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Exact tool name to enable (from search_tool / view_tool).",
                },
            },
            .required = &.{"name"},
        },
        .system_prompt = use_tool_system_prompt,
    },
};

/// Every progressive tool name, in the order they should be appended to the
/// tools array. The workflow and the exec-registry static contracts both
/// reference this so a renamed tool cannot drift.
pub const PROGRESSIVE_TOOL_NAMES = [_][]const u8{
    search_tool_tool.function.name,
    view_tool_tool.function.name,
    use_tool_tool.function.name,
};

/// The three definitions as a slice, for callers that append them to the
/// eligible tool set.
pub const ALL_PROGRESSIVE_TOOLS = [_]AgentTool{
    search_tool_tool,
    view_tool_tool,
    use_tool_tool,
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "progressive tools: wire names are exactly search_tool/view_tool/use_tool" {
    try testing.expectEqualStrings("search_tool", search_tool_tool.function.name);
    try testing.expectEqualStrings("view_tool", view_tool_tool.function.name);
    try testing.expectEqualStrings("use_tool", use_tool_tool.function.name);
    try testing.expectEqual(@as(usize, 3), ALL_PROGRESSIVE_TOOLS.len);
    try testing.expectEqual(@as(usize, 3), PROGRESSIVE_TOOL_NAMES.len);
    for (ALL_PROGRESSIVE_TOOLS, PROGRESSIVE_TOOL_NAMES) |tool, name| {
        try testing.expectEqualStrings(name, tool.function.name);
    }
}

test "search_tool: every param optional; description points at view_tool/use_tool" {
    try testing.expectEqualStrings("function", search_tool_tool.type);
    try testing.expectEqual(@as(usize, 0), search_tool_tool.function.parameters.required.len);
    try testing.expectEqual(@as(usize, 5), search_tool_tool.function.parameters.properties.len);
    const d = search_tool_tool.function.description;
    try testing.expect(std.mem.indexOf(u8, d, "view_tool") != null);
    try testing.expect(std.mem.indexOf(u8, d, "MCP tools") != null);
    // The "already-enabled tools are not listed" caveat must be in the
    // description too, not only the system prompt — the description is the
    // signal the model reads when deciding whether to call.
    try testing.expect(std.mem.indexOf(u8, d, "already in your tool list are excluded") != null);
    // Paging is advertised at the top level too: the catalog can be big, and
    // the model must not assume one call returns everything.
    try testing.expect(std.mem.indexOf(u8, d, "PAGED") != null);
    try testing.expect(std.mem.indexOf(u8, d, "offset") != null);
}

test "search_tool: limit/offset are documented as the anti-context-flood paging pair" {
    const props = search_tool_tool.function.parameters.properties;
    var limit_desc: []const u8 = "";
    var offset_desc: []const u8 = "";
    var limit_type: []const u8 = "";
    var offset_type: []const u8 = "";
    for (props) |p| {
        if (std.mem.eql(u8, p.name, "limit")) {
            limit_desc = p.description;
            limit_type = p.type;
        }
        if (std.mem.eql(u8, p.name, "offset")) {
            offset_desc = p.description;
            offset_type = p.type;
        }
    }
    try testing.expectEqualStrings("number", limit_type);
    try testing.expectEqualStrings("number", offset_type);

    // WHY: the catalog grows with every MCP server, and the result rides in
    // the context window — so the description must say default + max + total.
    try testing.expect(std.mem.indexOf(u8, limit_desc, "default 40, max 200") != null);
    try testing.expect(std.mem.indexOf(u8, limit_desc, "context window") != null);
    try testing.expect(std.mem.indexOf(u8, limit_desc, "<total>") != null);
    try testing.expect(std.mem.indexOf(u8, offset_desc, "Skip the first N matches") != null);
    try testing.expect(std.mem.indexOf(u8, offset_desc, "<hint>") != null);
}

test "search_tool: `query` documents regex-by-default WITH the reason, plus the literal escape hatch" {
    const props = search_tool_tool.function.parameters.properties;
    var query_desc: []const u8 = "";
    var literal_desc: []const u8 = "";
    var literal_type: []const u8 = "";
    for (props) |p| {
        if (std.mem.eql(u8, p.name, "query")) query_desc = p.description;
        if (std.mem.eql(u8, p.name, "literal")) {
            literal_desc = p.description;
            literal_type = p.type;
        }
    }

    // The parameter starts with a plain substring search no more: it says
    // "Regex" and the escape hatch that goes with it.
    try testing.expect(std.mem.indexOf(u8, query_desc, "Regex") != null);
    try testing.expect(std.mem.indexOf(u8, query_desc, "case-insensitively") != null);
    // WHY a pattern language helps — the concrete "one call instead of N"
    // examples are the whole point of the description.
    try testing.expect(std.mem.indexOf(u8, query_desc, "A pattern finds tools a phrase cannot") != null);
    try testing.expect(std.mem.indexOf(u8, query_desc, "^mcp_.*_create") != null);
    try testing.expect(std.mem.indexOf(u8, query_desc, "doc|docs|documentation") != null);
    try testing.expect(std.mem.indexOf(u8, query_desc, "one call instead of three") != null);
    try testing.expect(std.mem.indexOf(u8, query_desc, "\\bsearch\\b") != null);
    // The supported subset and the graceful-failure contract.
    try testing.expect(std.mem.indexOf(u8, query_desc, "Supported:") != null);
    try testing.expect(std.mem.indexOf(u8, query_desc, "<pattern_warning>") != null);
    // Backwards compatible for the common case.
    try testing.expect(std.mem.indexOf(u8, query_desc, "plain substring search") != null);
    try testing.expect(std.mem.indexOf(u8, query_desc, "Omit to list the start of the catalog") != null);

    // `literal` mirrors the `search` agent tool's flag: same name, same
    // boolean type, same "matched verbatim" semantics.
    try testing.expectEqualStrings("boolean", literal_type);
    try testing.expect(std.mem.indexOf(u8, literal_desc, "literal string") != null);
    try testing.expect(std.mem.indexOf(u8, literal_desc, "verbatim") != null);
    try testing.expect(std.mem.indexOf(u8, literal_desc, "Default false (regex mode)") != null);
}

test "search_tool: the system prompt teaches the pattern syntax, the fallback and paging" {
    const p = search_tool_system_prompt;
    try testing.expect(std.mem.indexOf(u8, p, "REGEX") != null);
    try testing.expect(std.mem.indexOf(u8, p, "literal: true") != null);
    try testing.expect(std.mem.indexOf(u8, p, "^mcp_.*_create") != null);
    try testing.expect(std.mem.indexOf(u8, p, "<pattern_warning>") != null);
    try testing.expect(std.mem.indexOf(u8, p, "PAGED") != null);
    try testing.expect(std.mem.indexOf(u8, p, "<hint>") != null);
}

test "view_tool: name is required; description states read-only" {
    try testing.expectEqual(@as(usize, 1), view_tool_tool.function.parameters.required.len);
    try testing.expectEqualStrings("name", view_tool_tool.function.parameters.required[0]);
    try testing.expect(std.mem.indexOf(u8, view_tool_tool.function.description, "Read-only") != null);
}

test "use_tool: name is required; description states idempotence + session scope" {
    try testing.expectEqual(@as(usize, 1), use_tool_tool.function.parameters.required.len);
    try testing.expectEqualStrings("name", use_tool_tool.function.parameters.required[0]);
    const d = use_tool_tool.function.description;
    try testing.expect(std.mem.indexOf(u8, d, "Idempotent") != null);
    try testing.expect(std.mem.indexOf(u8, d, "inserted=false") != null);
    try testing.expect(std.mem.indexOf(u8, d, "Session-scoped only") != null);
}

test "every progressive tool carries a non-empty system_prompt" {
    for (ALL_PROGRESSIVE_TOOLS) |tool| {
        try testing.expect(tool.function.system_prompt.len > 0);
        try testing.expect(tool.function.description.len > 0);
    }
}

// Exec adapter — merged from `progressive_tools.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const tools_equipped = @import("../../../agentic_loop/tools_equipped.zig");
const llm_history = @import("../../../agentic_loop/llm_history.zig");
const progressive_catalog = @import("../../../agentic_loop/progressive_catalog.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const MAX_DID_YOU_MEAN = 3;
/// Everything the three adapters need to resolve the catalog. Built once per
/// dispatch (all allocations land on the per-request arena).
const Inputs = struct {
    registered: []const agent.AgentTool,
    mcp: ?[]const agent.AgentTool,
    equipped_names: []const []const u8,
};

fn loadInputs(ctx: ToolExecContext) !Inputs {
    const registered = tools_equipped.equips(ctx.allocator);

    // The live fetch-once MCP cache — the same source the workflow uses and
    // the same one `handle_mcp_tool` dispatches against. Never re-fetch from
    // the servers here.
    const di = pabrikcore.getSingleton() catch null;
    const mcp: ?[]const agent.AgentTool = if (di) |d| d.getMcpToolsCached(ctx.allocator) else null;

    const equipped = try llm_history.getProgressiveTools(ctx.allocator, ctx.db, ctx.session_id);
    const names = try ctx.allocator.alloc([]const u8, equipped.len);
    for (equipped, 0..) |e, i| names[i] = e.tool_name;

    return .{ .registered = registered, .mcp = mcp, .equipped_names = names };
}

/// The workspace item type for this session, or "" when unknown. Borrowed
/// then duped because `getWorkspaceContext` owns its strings.
fn selfItemType(ctx: ToolExecContext) []const u8 {
    const wctx = (llm_history.getWorkspaceContext(ctx.allocator, ctx.db, ctx.session_id) catch return "") orelse return "";
    defer wctx.deinit(ctx.allocator);
    return ctx.allocator.dupe(u8, wctx.self_item_type) catch "";
}

fn buildCatalog(ctx: ToolExecContext, inputs: Inputs) ![]progressive_catalog.Entry {
    return progressive_catalog.buildCatalog(
        ctx.allocator,
        inputs.registered,
        ctx.allowed_tools,
        ctx.is_sub_agent,
        inputs.mcp,
        inputs.equipped_names,
        selfItemType(ctx),
    );
}

/// Mirror `add_mcp_server`'s envelope semantics: an inner `"error"` key makes
/// the wrapper report success=false and surfaces the message as the error,
/// with the full inner JSON still available in `data`.
fn wrapMaybeError(
    ctx: ToolExecContext,
    tool_name: []const u8,
    args_json: []const u8,
    inner: []const u8,
) ![]const u8 {
    if (innerErrorOf(ctx.allocator, inner)) |msg| {
        return wrapToolOutput(ctx.allocator, tool_name, args_json, false, msg, inner);
    }
    return wrapToolOutput(ctx.allocator, tool_name, args_json, true, null, inner);
}

/// The `"error"` string of an inner JSON result, or null when the result
/// carries no error key. Never fails: unparseable output is not an error.
fn innerErrorOf(allocator: std.mem.Allocator, inner: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, inner, .{}) catch return null;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const err = obj.get("error") orelse return null;
    return switch (err) {
        .string => |s| s,
        else => return null,
    };
}

fn result(ctx: ToolExecContext, output: []const u8) ToolExecResult {
    _ = ctx;
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── search_tool ───

pub fn execSearchTool(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        SearchToolInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        const output = try wrapToolOutput(
            ctx.allocator,
            "search_tool",
            tc.function.arguments,
            false,
            "search_tool failed to parse input (expected {\"query\"?: string, \"literal\"?: bool, \"limit\"?: number, \"offset\"?: number, \"server\"?: string})",
            "",
        );
        return result(ctx, output);
    };
    defer parsed.deinit();

    const query = parsed.value.query orelse "";
    const literal = parsed.value.literal orelse false;
    const server = parsed.value.server orelse "";

    // ── Paging bounds ── Rejected, never silently clamped: the model pages
    // by offset from the `<total>` it was shown, so a quiet clamp would make
    // its next call land on the wrong window.
    const limit: usize = blk: {
        const raw = parsed.value.limit orelse @as(i64, @intCast(progressive_catalog.DEFAULT_SEARCH_LIMIT));
        if (raw < 1) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "search_tool: limit must be at least 1 (got {d})", .{raw});
            const output = try wrapToolOutput(ctx.allocator, "search_tool", tc.function.arguments, false, msg, "");
            return result(ctx, output);
        }
        if (raw > @as(i64, @intCast(progressive_catalog.MAX_SEARCH_LIMIT))) {
            const msg = try std.fmt.allocPrint(
                ctx.allocator,
                "search_tool: limit must be at most {d} (got {d})",
                .{ progressive_catalog.MAX_SEARCH_LIMIT, raw },
            );
            const output = try wrapToolOutput(ctx.allocator, "search_tool", tc.function.arguments, false, msg, "");
            return result(ctx, output);
        }
        break :blk @intCast(raw);
    };
    const offset: usize = blk: {
        const raw = parsed.value.offset orelse 0;
        if (raw < 0) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "search_tool: offset must not be negative (got {d})", .{raw});
            const output = try wrapToolOutput(ctx.allocator, "search_tool", tc.function.arguments, false, msg, "");
            return result(ctx, output);
        }
        break :blk @intCast(raw);
    };

    const inputs = try loadInputs(ctx);
    const catalog = try buildCatalog(ctx, inputs);

    // `matchQuery` returns every match (no cap); `pageSlice` + the renderer
    // apply `offset`/`limit`, and `total` is always the pre-page count so the
    // model can page deterministically.
    const outcome = try progressive_catalog.matchQuery(
        ctx.allocator,
        catalog,
        query,
        server,
        .{ .literal = literal },
    );
    const page = progressive_catalog.pageSlice(outcome.entries, offset, limit);
    const inner = try progressive_catalog.renderSearchResult(ctx.allocator, page, .{
        .total = outcome.entries.len,
        .offset = offset,
        .limit = limit,
        .query = query,
        .server = server,
        .mode = outcome.mode,
        .warning = outcome.warning,
    });

    const output = try wrapToolOutput(ctx.allocator, "search_tool", tc.function.arguments, true, null, inner);
    return result(ctx, output);
}

// ─── view_tool (read-only) ───

pub fn execViewTool(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        ViewToolInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        const output = try wrapToolOutput(
            ctx.allocator,
            "view_tool",
            tc.function.arguments,
            false,
            "view_tool failed to parse input (expected {\"name\": string})",
            "",
        );
        return result(ctx, output);
    };
    defer parsed.deinit();

    const name = std.mem.trim(u8, parsed.value.name orelse "", " ");
    if (name.len == 0) {
        const inner = try progressive_catalog.renderViewToolNotFound(ctx.allocator, "", &.{});
        const output = try wrapMaybeError(ctx, "view_tool", tc.function.arguments, inner);
        return result(ctx, output);
    }

    const inputs = try loadInputs(ctx);

    // 1. Discoverable candidate.
    const catalog = try buildCatalog(ctx, inputs);
    if (progressive_catalog.findByName(catalog, name)) |entry| {
        const inner = try progressive_catalog.renderViewTool(ctx.allocator, entry);
        const output = try wrapToolOutput(ctx.allocator, "view_tool", tc.function.arguments, true, null, inner);
        return result(ctx, output);
    }

    // 2. Already equipped for this session — show it rather than claiming it
    //    is unknown. Read-only either way.
    if (progressive_catalog.findAnyByNameFiltered(inputs.registered, inputs.mcp, name, inputs.equipped_names)) |entry| {
        const inner = try progressive_catalog.renderViewTool(ctx.allocator, entry);
        const output = try wrapToolOutput(ctx.allocator, "view_tool", tc.function.arguments, true, null, inner);
        return result(ctx, output);
    }

    // 3. Unknown → did-you-mean over the catalog. Nothing is written.
    const suggestions = try progressive_catalog.didYouMean(ctx.allocator, catalog, name, MAX_DID_YOU_MEAN);
    const inner = try progressive_catalog.renderViewToolNotFound(ctx.allocator, name, suggestions);
    const output = try wrapMaybeError(ctx, "view_tool", tc.function.arguments, inner);
    return result(ctx, output);
}

// ─── use_tool (equips for the session) ───

pub fn execUseTool(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        UseToolInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        const output = try wrapToolOutput(
            ctx.allocator,
            "use_tool",
            tc.function.arguments,
            false,
            "use_tool failed to parse input (expected {\"name\": string})",
            "",
        );
        return result(ctx, output);
    };
    defer parsed.deinit();

    const name = std.mem.trim(u8, parsed.value.name orelse "", " ");
    if (name.len == 0) {
        const inner = try progressive_catalog.renderUseToolNotFound(ctx.allocator, "", &.{});
        const output = try wrapMaybeError(ctx, "use_tool", tc.function.arguments, inner);
        return result(ctx, output);
    }

    const inputs = try loadInputs(ctx);

    // ── The validation rule, checked BEFORE anything else ── If it is
    // already equipped for this session there is nothing to insert; report it
    // and write nothing.
    if (progressive_catalog.findAnyByNameFiltered(inputs.registered, inputs.mcp, name, inputs.equipped_names)) |already| {
        const inner = try progressive_catalog.renderUseTool(ctx.allocator, already, false);
        const output = try wrapToolOutput(ctx.allocator, "use_tool", tc.function.arguments, true, null, inner);
        return result(ctx, output);
    }

    // Only a catalog hit may be equipped. An unknown name writes nothing.
    const catalog = try buildCatalog(ctx, inputs);
    const entry = progressive_catalog.findByName(catalog, name) orelse {
        const suggestions = try progressive_catalog.didYouMean(ctx.allocator, catalog, name, MAX_DID_YOU_MEAN);
        const inner = try progressive_catalog.renderUseToolNotFound(ctx.allocator, name, suggestions);
        const output = try wrapMaybeError(ctx, "use_tool", tc.function.arguments, inner);
        return result(ctx, output);
    };

    // `saveProgressiveTool` returns whether a row was really inserted; the
    // result's `inserted` flag is derived from that, never assumed.
    const inserted = try llm_history.saveProgressiveTool(
        ctx.allocator,
        ctx.db,
        ctx.logger,
        ctx.session_id,
        entry.name,
        entry.server,
    );

    const inner = try progressive_catalog.renderUseTool(ctx.allocator, entry, inserted);
    const output = try wrapToolOutput(ctx.allocator, "use_tool", tc.function.arguments, true, null, inner);

    var res = result(ctx, output);
    if (inserted) {
        res.progressive_tool_save = .{ .name = entry.name, .server_name = entry.server };
    }
    return res;
}

// ============================================================================
// Adapter integration: the real registry + a real (in-memory) DB
// ============================================================================

const test_sqlite = pabrikcore.sqlite;
const Migration085 = @import("../../../migrations/migration.zig").Migration085AddSessionProgressiveTool;

/// The `data.tools` rows of a rendered envelope result — the catalog rows
/// only, NOT the `"tool":"search_tool"` name in the `wrapToolOutput` envelope
/// around them.
fn catalogData(allocator: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    errdefer parsed.deinit();
    const data = parsed.value.object.get("data") orelse return error.NoData;
    if (data != .object) return error.NoData;
    return parsed;
}

/// Pull every tool row name out of a rendered envelope result, joined by ','.
fn namesJoined(allocator: std.mem.Allocator, out: []const u8) ![]const u8 {
    const parsed = try catalogData(allocator, out);
    defer parsed.deinit();
    const rows = parsed.value.object.get("data").?.object.get("tools").?.array.items;
    var list: std.ArrayList(u8) = .empty;
    for (rows) |t| {
        if (list.items.len > 0) try list.append(allocator, ',');
        try list.appendSlice(allocator, t.object.get("name").?.string);
    }
    return try list.toOwnedSlice(allocator);
}

fn totalOf(allocator: std.mem.Allocator, out: []const u8) !usize {
    const parsed = try catalogData(allocator, out);
    defer parsed.deinit();
    const total = parsed.value.object.get("data").?.object.get("total").?.integer;
    return std.math.cast(usize, total) orelse return error.BadTotal;
}

fn searchCall(args_json: []const u8) agent.ToolCall {
    return .{ .id = "call_regex", .type = "function", .function = .{
        .name = "search_tool",
        .arguments = args_json,
    } };
}

/// One `search_tool` dispatch against the REAL registry, with `read_file` and
/// `search_tool` enabled (so both are legitimately absent from the catalog) and
/// everything else discoverable.
fn searchToolOutput(a: std.mem.Allocator, db: *test_sqlite.SqliteBackend, io: std.Io, args_json: []const u8) ![]const u8 {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    const ctx = ToolExecContext{
        .allocator = a,
        .io = io,
        .db = db,
        .logger = undefined,
        .session_id = "sess_regex",
        .model = "test",
        .cwd = "/tmp",
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .allowed_tools = "read_file,search_tool",
        .is_sub_agent = false,
    };
    const res = try execSearchTool(ctx, searchCall(args_json));
    if (!res.output_allocated) return error.OutputNotOwned;
    return res.output;
}

test "execSearchTool: a regex finds tools a literal substring could not, end to end" {
    var arena = std.heap.ArenaAllocator.init(exec_testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = std.Io.Threaded.init(exec_testing.allocator, .{});
    defer threaded.deinit();
    var db: test_sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try Migration085.up(&db, exec_testing.allocator);

    // The literal text "^(list|load|save|search)_" appears in no tool name or
    // description, so a substring search would return nothing. The rows below
    // can only come from the pattern language.
    const args = "{\"query\":\"^(list|load|save|search)_\"}";
    const out = try searchToolOutput(a, &db, threaded.io(), args);

    try exec_testing.expect(std.mem.indexOf(u8, out, "\"pattern_mode\":\"regex\"") != null);
    try exec_testing.expect(std.mem.indexOf(u8, out, "\"pattern_warning\":null") != null);
    const total = try totalOf(a, out);
    try exec_testing.expect(total >= 5); // list_directory/search_skills/list_sub_agent + load_/save_memory at least
    try exec_testing.expect(std.mem.indexOf(u8, out, "\"name\":\"save_memory\"") != null);

    // Enabled tools are NOT discoverable (they are already in the tool list).
    try exec_testing.expect(std.mem.indexOf(u8, out, "\"name\":\"read_file\"") == null);
    // …nor are the browsing meta-tools themselves.
    try exec_testing.expect(std.mem.indexOf(u8, out, "\"name\":\"view_tool\"") == null);

    // `literal: true` over the same text finds nothing — the flag is honoured
    // through the adapter, not just in the pure matcher.
    const literal_out = try searchToolOutput(
        a,
        &db,
        threaded.io(),
        "{\"query\":\"^(list|load|save)_\",\"literal\":true}",
    );
    try exec_testing.expect(std.mem.indexOf(u8, literal_out, "\"pattern_mode\":\"literal\"") != null);
    try exec_testing.expect(std.mem.indexOf(u8, literal_out, "\"count\":0") != null);

    // A pattern the engine rejects degrades to a literal substring search and
    // says so — never a hard failure.
    const bad_out = try searchToolOutput(a, &db, threaded.io(), "{\"query\":\"^(list\"}");
    try exec_testing.expect(std.mem.indexOf(u8, bad_out, "\"pattern_mode\":\"literal_fallback\"") != null);
    try exec_testing.expect(std.mem.indexOf(u8, bad_out, "\"pattern_warning\":\"") != null);
    try exec_testing.expect(std.mem.indexOf(u8, bad_out, "not a valid regex") != null);
}

test "execSearchTool: limit/offset page the matches and report the true total" {
    var arena = std.heap.ArenaAllocator.init(exec_testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = std.Io.Threaded.init(exec_testing.allocator, .{});
    defer threaded.deinit();
    var db: test_sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try Migration085.up(&db, exec_testing.allocator);

    const page1 = try searchToolOutput(
        a,
        &db,
        threaded.io(),
        "{\"query\":\"^(list|load|save|search)_\",\"limit\":3,\"offset\":0}",
    );
    const total = try totalOf(a, page1);
    try exec_testing.expect(total >= 5); // list_directory/search_skills/list_sub_agent + load_/save_memory
    try exec_testing.expect(total > 3); // otherwise "page 2" would be empty
    try exec_testing.expect(std.mem.indexOf(u8, page1, "\"count\":3") != null);
    try exec_testing.expect(std.mem.indexOf(u8, page1, "\"offset\":0,\"limit\":3") != null);
    try exec_testing.expect(std.mem.indexOf(u8, page1, "\"truncated\":true") != null);
    try exec_testing.expect(std.mem.indexOf(u8, page1, "offset=3") != null);

    const page2 = try searchToolOutput(
        a,
        &db,
        threaded.io(),
        "{\"query\":\"^(list|load|save|search)_\",\"limit\":3,\"offset\":3}",
    );
    // Page 2 is a WINDOW of at most `limit` rows, so its count is `min(limit,
    // total - offset)` — NOT `total - offset`.
    const page2_expected = @min(@as(usize, 3), total - 3);
    const expect_page2_count = try std.fmt.allocPrint(a, "\"count\":{d}", .{page2_expected});
    try exec_testing.expect(std.mem.indexOf(u8, page2, expect_page2_count) != null);
    try exec_testing.expect(std.mem.indexOf(u8, page2, "\"offset\":3,\"limit\":3") != null);
    try exec_testing.expectEqual(total, try totalOf(a, page2));

    // The last page proves the windowing all the way out: it is the only page
    // that is NOT truncated, and its count is whatever is left.
    const page3 = try searchToolOutput(
        a,
        &db,
        threaded.io(),
        "{\"query\":\"^(list|load|save|search)_\",\"limit\":3,\"offset\":6}",
    );
    const page3_expected = if (total > 6) @min(@as(usize, 3), total - 6) else 0;
    const expect_page3_count = try std.fmt.allocPrint(a, "\"count\":{d}", .{page3_expected});
    try exec_testing.expect(std.mem.indexOf(u8, page3, expect_page3_count) != null);
    try exec_testing.expectEqual(total, try totalOf(a, page3));
    try exec_testing.expect(std.mem.indexOf(u8, page3, "\"truncated\":false") != null);

    // The two pages are disjoint windows — not the same rows twice.
    const first = try namesJoined(a, page1);
    const second = try namesJoined(a, page2);
    try exec_testing.expect(!std.mem.eql(u8, first, second));
    var it = std.mem.splitScalar(u8, second, ',');
    while (it.next()) |name| {
        try exec_testing.expect(std.mem.indexOf(u8, first, name) == null);
    }
    // Sanity: the extractor is reading the row block, not the envelope name
    // (`"tool":"search_tool"` wraps every result).
    try exec_testing.expect(std.mem.indexOf(u8, first, "search_tool") == null);

    // Out-of-range input is rejected with the accepted range, never clamped
    // (a clamp would desync the model's offset arithmetic).
    const too_big = try searchToolOutput(a, &db, threaded.io(), "{\"query\":\"a\",\"limit\":5000}");
    try exec_testing.expect(std.mem.indexOf(u8, too_big, "\"success\":false") != null);
    try exec_testing.expect(std.mem.indexOf(u8, too_big, "limit must be at most 200") != null);
    const zero = try searchToolOutput(a, &db, threaded.io(), "{\"query\":\"a\",\"limit\":0}");
    try exec_testing.expect(std.mem.indexOf(u8, zero, "limit must be at least 1") != null);
    const negative = try searchToolOutput(a, &db, threaded.io(), "{\"query\":\"a\",\"offset\":-1}");
    try exec_testing.expect(std.mem.indexOf(u8, negative, "offset must not be negative") != null);
}

const exec_testing = std.testing;

/// One `use_tool` dispatch against the REAL registry and a real (in-memory)
/// DB, on the same allowlist `searchToolOutput` uses — so the name under test
/// is registered but not enabled, i.e. discoverable, which is the only state
fn useToolResult(
    a: std.mem.Allocator,
    db: *test_sqlite.SqliteBackend,
    io: std.Io,
    logger: *pabrikcore.loggermod.Logger,
    args_json: []const u8,
) !ToolExecResult {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    const ctx = ToolExecContext{
        .allocator = a,
        .io = io,
        .db = db,
        .logger = logger,
        .session_id = "sess_regex",
        .model = "test",
        .cwd = "/tmp",
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .allowed_tools = "read_file,search_tool",
        .is_sub_agent = false,
    };
    return execUseTool(ctx, .{ .id = "call_use", .type = "function", .function = .{
        .name = "use_tool",
        .arguments = args_json,
    } });
}

test "the three progressive tools are offered to the model and resolve to dispatchable registry entries" {
    // `equips()` is the list the workflow hands the LLM;
    // UNIFIED_TOOL_REGISTRY() is the dispatcher's table.
    const equip = tools_equipped.equips(exec_testing.allocator);
    defer exec_testing.allocator.free(equip);

    for (PROGRESSIVE_TOOL_NAMES) |name| {
        var in_equips = false;
        for (equip) |t| {
            if (std.mem.eql(u8, t.function.name, name)) in_equips = true;
        }
        try exec_testing.expect(in_equips);

        // Exactly one dispatch entry, carrying the SAME tool def the model was
        // shown.
        var entries: usize = 0;
        for (tools_equipped.UNIFIED_TOOL_REGISTRY()) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            entries += 1;
            try exec_testing.expectEqualStrings(name, entry.tool_def.function.name);
        }
        try exec_testing.expectEqual(@as(usize, 1), entries);
        try exec_testing.expect(tools_equipped.isDispatchableToolName(name));
    }
}

test "execUseTool: equipping a catalog tool persists the row and reports it back" {
    var arena = std.heap.ArenaAllocator.init(exec_testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = std.Io.Threaded.init(exec_testing.allocator, .{});
    defer threaded.deinit();
    var db: test_sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try Migration085.up(&db, exec_testing.allocator);

    // `save_memory` is registered and not in the allowlist, so it is in the
    // discoverable catalog — proven independently by the regex search test
    // above, which finds it under `^(list|load|save|search)_`.
    var logger = pabrikcore.loggermod.Logger.init(a, threaded.io(), .{ .min_level = .err });
    const res = try useToolResult(a, &db, threaded.io(), &logger, "{\"name\":\"save_memory\"}");
    try exec_testing.expect(res.output_allocated);
    try exec_testing.expect(std.mem.indexOf(u8, res.output, "\"success\":true") != null);

    // The field `handle_tool` copies into its `progressive_tool_saved` event.
    try exec_testing.expect(res.progressive_tool_save != null);
    try exec_testing.expectEqualStrings("save_memory", res.progressive_tool_save.?.name);

    // …and the row really is in session_progressive_tool, which is what the
    // next turn's allowlist and the catalog both read back.
    const rows = try llm_history.getProgressiveTools(a, &db, "sess_regex");
    defer for (rows) |r| r.deinit(a);
    try exec_testing.expectEqual(@as(usize, 1), rows.len);
    try exec_testing.expectEqualStrings("save_memory", rows[0].tool_name);
}


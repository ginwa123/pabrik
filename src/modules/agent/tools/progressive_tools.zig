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

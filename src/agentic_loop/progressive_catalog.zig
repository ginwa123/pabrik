//! Progressive tool catalog. The agent does not receive every tool up front.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const agent = pabrikcore.agent;
const AgentTool = agent.AgentTool;
const tool_eligibility = @import("tool_eligibility.zig");
const progressive_regex = @import("progressive_regex.zig");
// `MAIN_AGENT_ONLY_NAMES` — the tools a sub-agent must never discover its
// way back to. Same list the strip uses.
const main_agent_only = pabrikcore.main_agent_only;

pub const Kind = enum { builtin, mcp };

/// Whether the entry is already enabled for this session. `no` means
/// `use_tool` would actually insert a row. A natively-enabled tool never
/// reaches the catalog, so it has no variant here.
pub const Equipped = enum { session, no };

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    /// MCP server id parsed from `mcp_<server>_<tool>` (same split as
    /// `handle_mcp_tool.zig`). Empty for built-ins.
    server: []const u8,
    equipped: Equipped,
    /// Borrowed from the registered tool definition.
    tool: AgentTool,
};

/// The server segment of an MCP tool name. Mirrors
/// `handle_mcp_tool.zig:35-43` exactly: everything between the `mcp_` prefix
/// and the FIRST underscore.
pub fn serverOf(name: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, name, "mcp_")) return "";
    const after_mcp = name["mcp_".len..];
    const idx = std.mem.indexOf(u8, after_mcp, "_") orelse return "";
    return after_mcp[0..idx];
}

pub fn isMcpName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "mcp_");
}

/// One-line summary for the search index: whitespace-collapsed and
/// truncated to `max` bytes on a word boundary where possible.
pub fn summaryOf(description: []const u8, max: usize) []const u8 {
    // Collapse leading whitespace/newlines so the summary is one line.
    var start: usize = 0;
    while (start < description.len and (description[start] == ' ' or
        description[start] == '\n' or description[start] == '\r' or description[start] == '\t')) : (start += 1)
    {}
    const trimmed = description[start..];
    if (trimmed.len <= max) return trimmed;

    // Cut at the last space inside the budget so words are not split.
    var cut = max;
    while (cut > 0 and trimmed[cut] != ' ') : (cut -= 1) {}
    if (cut == 0) cut = max;
    return trimmed[0..cut];
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// The meta-tools are infrastructure for browsing the catalog; offering them
/// AS catalog entries would let the agent "discover" search_tool with
/// search_tool.
fn isProgressiveMetaTool(name: []const u8) bool {
    return containsName(&pabrikcore.progressive_tools.PROGRESSIVE_TOOL_NAMES, name);
}

/// Build the catalog.
pub fn buildCatalog(
    allocator: std.mem.Allocator,
    registered: []const AgentTool,
    allowed_tools: []const u8,
    is_sub_agent: bool,
    mcp: ?[]const AgentTool,
    equipped_names: []const []const u8,
    self_item_type: []const u8,
) ![]Entry {
    const enabled = try tool_eligibility.allowlistFilter(allocator, registered, allowed_tools, is_sub_agent);

    // Candidates = registered but NOT enabled, i.e. the built-ins this
    // session could add. Enabled names are already in the LLM's tool list.
    var candidates: std.ArrayList(AgentTool) = .empty;
    for (registered) |tool| {
        var is_enabled = false;
        for (enabled) |e| {
            if (std.mem.eql(u8, e.function.name, tool.function.name)) {
                is_enabled = true;
                break;
            }
        }
        if (!is_enabled) try candidates.append(allocator, tool);
    }

    // Apply the same item-type policy the prompt filtering uses, so the
    // catalog can never offer a tool the item type is not allowed to have.
    const allowed_candidates = tool_eligibility.itemTypeStrip(candidates.items, self_item_type);

    var out: std.ArrayList(Entry) = .empty;
    for (allowed_candidates) |tool| {
        const name = tool.function.name;
        // Anti-recursion invariant: a sub-agent must not be able to
        // discover its way back to spawn_sub_agent.
        if (is_sub_agent and main_agent_only.isMainAgentOnly(name)) continue;
        // Never offer the browsing meta-tools as things to browse.
        if (isProgressiveMetaTool(name)) continue;
        if (containsName(equipped_names, name)) continue;
        try out.append(allocator, .{
            .name = name,
            .kind = .builtin,
            .server = "",
            .equipped = .no,
            .tool = tool,
        });
    }

    if (mcp) |mcp_tools| {
        for (mcp_tools) |tool| {
            const name = tool.function.name;
            if (is_sub_agent and main_agent_only.isMainAgentOnly(name)) continue;
            if (containsName(equipped_names, name)) continue;
            try out.append(allocator, .{
                .name = name,
                .kind = .mcp,
                .server = serverOf(name),
                .equipped = .no,
                .tool = tool,
            });
        }
    }

    // Names that are already session-equipped are excluded above, but mark
    // the ones that a previous iteration recorded so the agent does not
    // re-request them unnecessarily when they appear via another route.
    for (out.items) |*entry| {
        if (containsName(equipped_names, entry.name)) entry.equipped = .session;
    }

    return try out.toOwnedSlice(allocator);
}

/// How a query was interpreted. Rendered into the result so the model can tell
/// a real regex hit from a literal fallback without guessing.
pub const QueryMode = enum {
    /// No query given: the whole catalog (server filter only).
    all,
    /// Compiled and matched as a regex.
    regex,
    /// `literal: true` was passed: case-insensitive substring.
    literal,
    /// The query did not compile as a regex and was matched as a literal
    /// substring instead. `QueryResult.warning` says why.
    regex_fallback,
};

pub const MatchOptions = struct {
    /// Mirror of the `search` agent tool's flag: treat the query as opaque
    /// text instead of a pattern. The escape hatch for code-shaped queries
    /// (`fn(`, `*.zig`, `.json`).
    literal: bool = false,
};

pub const QueryResult = struct {
    entries: []const Entry,
    mode: QueryMode,
    /// Non-empty only when the query was reinterpreted or the match ran out of
    /// budget. Rendered as `pattern_warning`.
    warning: []const u8 = "",
};

/// Match the catalog.
pub fn matchQuery(
    allocator: std.mem.Allocator,
    entries: []const Entry,
    query: []const u8,
    server: []const u8,
    opts: MatchOptions,
) !QueryResult {
    var matched: std.ArrayList(Entry) = .empty;

    if (query.len == 0) {
        for (entries) |entry| {
            if (server.len > 0 and !std.mem.eql(u8, entry.server, server)) continue;
            try matched.append(allocator, entry);
        }
        return .{ .entries = try matched.toOwnedSlice(allocator), .mode = .all };
    }

    var regex: ?progressive_regex.Regex = null;
    defer {
        if (regex) |*re| re.deinit();
    }

    var mode: QueryMode = .literal;
    var warning: []const u8 = "";

    if (!opts.literal) {
        if (progressive_regex.compile(allocator, query, .{})) |re| {
            regex = re;
            mode = .regex;
        } else |err| {
            mode = .regex_fallback;
            warning = try std.fmt.allocPrint(
                allocator,
                "query is not a valid regex ({s}) — matched as a case-insensitive literal substring instead." ++ " Supported: literals, '.', '[...]', '\\d \\w \\s \\b', '*', '+', '?', '{{m,n}}' ranges, '( )' groups, '|', '^', '$'." ++ " Pass literal:true when the query is literal text.",
                .{@errorName(err)},
            );
        }
    }

    for (entries) |entry| {
        if (server.len > 0 and !std.mem.eql(u8, entry.server, server)) continue;
        const hit = if (regex) |*re|
            (re.isMatch(entry.name) or re.isMatch(entry.tool.function.description))
        else
            (containsIgnoreCase(entry.name, query) or
                containsIgnoreCase(entry.tool.function.description, query));
        if (hit) try matched.append(allocator, entry);
    }

    if (regex) |*re| {
        if (re.exhausted()) {
            warning = "the pattern was too expensive to finish matching, so some entries were skipped — anchor it with '^' or pass literal:true";
        }
    }

    return .{
        .entries = try matched.toOwnedSlice(allocator),
        .mode = mode,
        .warning = warning,
    };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn findByName(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Look up a tool definition by name across BOTH the registered built-ins and
/// the MCP catalog, regardless of whether it is enabled or already equipped.
pub fn findAnyByName(
    registered: []const AgentTool,
    mcp: ?[]const AgentTool,
    name: []const u8,
) ?Entry {
    for (registered) |tool| {
        if (std.mem.eql(u8, tool.function.name, name)) {
            return .{
                .name = tool.function.name,
                .kind = .builtin,
                .server = "",
                .equipped = .session,
                .tool = tool,
            };
        }
    }
    if (mcp) |mcp_tools| {
        for (mcp_tools) |tool| {
            if (std.mem.eql(u8, tool.function.name, name)) {
                return .{
                    .name = tool.function.name,
                    .kind = .mcp,
                    .server = serverOf(tool.function.name),
                    .equipped = .session,
                    .tool = tool,
                };
            }
        }
    }
    return null;
}

/// Drop any entry whose name is not in `names`. Used by the adapters to build
/// the "already equipped" lookup from the full registered+MCP set.
pub fn findAnyByNameFiltered(
    registered: []const AgentTool,
    mcp: ?[]const AgentTool,
    name: []const u8,
    names: []const []const u8,
) ?Entry {
    if (!containsName(names, name)) return null;
    return findAnyByName(registered, mcp, name);
}

/// Cheap "did you mean" candidates for an unknown name: ASCII
/// case-insensitive, separators (`_`/`-`) folded away, then a substring sweep
/// in both directions.
pub fn didYouMean(
    allocator: std.mem.Allocator,
    entries: []const Entry,
    name: []const u8,
    max: usize,
) ![]const []const u8 {
    var hits: std.ArrayList([]const u8) = .empty;

    // Pass 1: normalised equality (separators + case ignored).
    for (entries) |entry| {
        if (normalizedEqual(entry.name, name)) {
            try hits.append(allocator, entry.name);
            if (hits.items.len >= max) return try hits.toOwnedSlice(allocator);
        }
    }

    // Pass 2: one name contains a meaningful prefix of the other.
    const needle = normalize(allocator, name) catch return try hits.toOwnedSlice(allocator);
    if (needle.len >= 4) {
        for (entries) |entry| {
            if (containsName(hits.items, entry.name)) continue;
            const candidate = normalize(allocator, entry.name) catch continue;
            if (std.mem.indexOf(u8, candidate, needle) != null or
                std.mem.indexOf(u8, needle, candidate) != null)
            {
                try hits.append(allocator, entry.name);
                if (hits.items.len >= max) break;
            }
        }
    }

    return try hits.toOwnedSlice(allocator);
}

/// Lowercase with `_` and `-` removed, so `mcp_context7_query-docs` and
/// `mcp_context7_query_docs` compare equal.
fn normalize(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, name.len);
    var n: usize = 0;
    for (name) |c| {
        if (c == '_' or c == '-') continue;
        out[n] = std.ascii.toLower(c);
        n += 1;
    }
    return out[0..n];
}

fn normalizedEqual(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (true) {
        while (ai < a.len and (a[ai] == '_' or a[ai] == '-')) ai += 1;
        while (bi < b.len and (b[bi] == '_' or b[bi] == '-')) bi += 1;
        if (ai >= a.len and bi >= b.len) return true;
        if (ai >= a.len or bi >= b.len) return false;
        if (std.ascii.toLower(a[ai]) != std.ascii.toLower(b[bi])) return false;
        ai += 1;
        bi += 1;
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn makeTool(allocator: std.mem.Allocator, name: []const u8, description: []const u8) !AgentTool {
    return .{
        .type = "function",
        .function = .{
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
            .parameters = .{ .type = "object", .properties = &.{}, .required = &.{} },
        },
    };
}

fn makeToolList(allocator: std.mem.Allocator, specs: []const [2][]const u8) ![]AgentTool {
    const out = try allocator.alloc(AgentTool, specs.len);
    for (specs, 0..) |s, i| out[i] = try makeTool(allocator, s[0], s[1]);
    return out;
}

// "Nothing enabled" cannot be expressed with "" — an empty allowed_tools
// means NO FILTERING (every tool enabled), which is the pre-existing
// semantics tool_eligibility.allowlistFilter deliberately preserves.
const NONE_ENABLED = "zzz_nothing_enabled";

const registered_specs = [_][2][]const u8{
    .{ "read_file", "Read a file from disk." },
    .{ "glob", "Find files by pattern." },
    .{ "kanban_list", "List a kanban board." },
    .{ "set_design_page", "Set the active design page." },
    .{ "spawn_sub_agent", "Spawn a sub-agent." },
};

test "serverOf: mirrors the dispatch split (first underscore after mcp_)" {
    try testing.expectEqualStrings("context7", serverOf("mcp_context7_query-docs"));
    try testing.expectEqualStrings("graphify", serverOf("mcp_graphify_query_graph"));
    // Lossy by design — same answer dispatch would give.
    try testing.expectEqualStrings("my", serverOf("mcp_my_server_do_thing"));
    try testing.expectEqualStrings("", serverOf("read_file"));
    try testing.expectEqualStrings("", serverOf("mcp_nounderscore"));
}

test "summaryOf: collapses leading whitespace, truncates on a word boundary" {
    try testing.expectEqualStrings("Read a file.", summaryOf("\n   Read a file.", 120));
    try testing.expectEqualStrings("Read a", summaryOf("Read a file from disk", 8));
    // Short enough → unchanged (after leading-trim).
    try testing.expectEqualStrings("abc", summaryOf("abc", 120));
}

test "buildCatalog: enabled built-ins are excluded, disabled ones included" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const registered = try makeToolList(a, &registered_specs);
    // Only read_file + glob are enabled for this agent.
    const catalog = try buildCatalog(a, registered, "read_file,glob", false, null, &.{}, "agent");

    try testing.expectEqual(@as(usize, 3), catalog.len);
    try testing.expectEqualStrings("kanban_list", catalog[0].name);
    try testing.expectEqualStrings("set_design_page", catalog[1].name);
    try testing.expectEqualStrings("spawn_sub_agent", catalog[2].name);
    for (catalog) |e| {
        try testing.expectEqual(Kind.builtin, e.kind);
        try testing.expectEqual(Equipped.no, e.equipped);
        try testing.expectEqualStrings("", e.server);
    }
}

test "buildCatalog: allowlist \"all\" leaves nothing but MCP discoverable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const registered = try makeToolList(a, &registered_specs);
    const mcp_specs = [_][2][]const u8{.{ "mcp_ctx_query", "Query docs." }};
    const mcp = try makeToolList(a, &mcp_specs);

    const catalog = try buildCatalog(a, registered, "all", false, mcp, &.{}, "agent");
    try testing.expectEqual(@as(usize, 1), catalog.len);
    try testing.expectEqualStrings("mcp_ctx_query", catalog[0].name);
    try testing.expectEqual(Kind.mcp, catalog[0].kind);
    try testing.expectEqualStrings("ctx", catalog[0].server);
}

test "buildCatalog: session-equipped names are not offered again" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const registered = try makeToolList(a, &registered_specs);
    const catalog = try buildCatalog(a, registered, "read_file", false, null, &.{"glob"}, "agent");
    for (catalog) |e| {
        try testing.expect(!std.mem.eql(u8, e.name, "glob"));
    }
}

test "buildCatalog: item-type policy strips design tools for a kanban item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const registered = try makeToolList(a, &registered_specs);
    // kanban item with only read_file enabled → kanban_list is discoverable,
    // set_design_page must NOT be.
    const catalog = try buildCatalog(a, registered, "read_file", false, null, &.{}, "kanban");
    var found_design = false;
    var found_kanban = false;
    for (catalog) |e| {
        if (std.mem.eql(u8, e.name, "set_design_page")) found_design = true;
        if (std.mem.eql(u8, e.name, "kanban_list")) found_kanban = true;
    }
    try testing.expect(!found_design);
    try testing.expect(found_kanban);
}

test "buildCatalog: a sub-agent never discovers spawn_sub_agent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const registered = try makeToolList(a, &registered_specs);
    const catalog = try buildCatalog(a, registered, "read_file", true, null, &.{}, "agent");
    for (catalog) |e| {
        try testing.expect(!std.mem.eql(u8, e.name, "spawn_sub_agent"));
    }
}

test "buildCatalog: MCP tools are always candidates (they bypass the allowlist)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const registered = try makeToolList(a, &registered_specs);
    const mcp_specs = [_][2][]const u8{
        .{ "mcp_ctx_query-docs", "Query documentation." },
        .{ "mcp_ctx_resolve-library-id", "Resolve a library." },
    };
    const mcp = try makeToolList(a, &mcp_specs);

    // read_file enabled → the remaining 4 built-ins + 2 MCP.
    const catalog = try buildCatalog(a, registered, "read_file", false, mcp, &.{}, "agent");
    try testing.expectEqual(@as(usize, 6), catalog.len);
    try testing.expectEqualStrings("mcp_ctx_query-docs", catalog[4].name);
    try testing.expectEqual(Kind.mcp, catalog[4].kind);
    try testing.expectEqualStrings("mcp_ctx_resolve-library-id", catalog[5].name);
}

test "buildCatalog: the browsing meta-tools are never offered as catalog entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The real registry: it CONTAINS the three meta-tools (they are injected
    // by the workflow), so without an explicit exclusion they would show up
    // as things to discover — letting the agent find search_tool with
    const registered = @import("../modules/agent/tools/tools_equipped.zig").equips(a);
    const catalog = try buildCatalog(a, registered, NONE_ENABLED, false, null, &.{}, "agent");
    try testing.expect(catalog.len > 0);
    for (catalog) |entry| {
        for (@import("pabrikcore").progressive_tools.PROGRESSIVE_TOOL_NAMES) |meta| {
            try testing.expect(!std.mem.eql(u8, entry.name, meta));
        }
    }
}

test "matchQuery: name and description substring, case-insensitive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // MCP tools arrive via the `mcp` argument, never via `registered`.
    const reg_specs = [_][2][]const u8{
        .{ "kanban_list", "List a kanban board." },
        .{ "glob", "Find files by PATTERN." },
    };
    const mcp_specs = [_][2][]const u8{.{ "mcp_ctx_query-docs", "Query documentation." }};
    const reg = try makeToolList(a, &reg_specs);
    const mcp_list = try makeToolList(a, &mcp_specs);
    const entries = try buildCatalog(a, reg, NONE_ENABLED, false, mcp_list, &.{}, "agent");

    // A metacharacter-free query is still a plain substring search.
    const by_name = try matchQuery(a, entries, "KANBAN", "", .{});
    try testing.expectEqual(@as(usize, 1), by_name.entries.len);
    try testing.expectEqualStrings("kanban_list", by_name.entries[0].name);
    try testing.expectEqual(QueryMode.regex, by_name.mode);
    try testing.expectEqualStrings("", by_name.warning);

    const by_desc = try matchQuery(a, entries, "pattern", "", .{});
    try testing.expectEqual(@as(usize, 1), by_desc.entries.len);
    try testing.expectEqualStrings("glob", by_desc.entries[0].name);

    // Server filter.
    const by_server = try matchQuery(a, entries, "", "ctx", .{});
    try testing.expectEqual(@as(usize, 1), by_server.entries.len);
    try testing.expectEqualStrings("mcp_ctx_query-docs", by_server.entries[0].name);
    try testing.expectEqual(QueryMode.all, by_server.mode);

    const no_match = try matchQuery(a, entries, "zzzz", "", .{});
    try testing.expectEqual(@as(usize, 0), no_match.entries.len);
}

fn matchedNamesJoined(
    allocator: std.mem.Allocator,
    result: QueryResult,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (result.entries, 0..) |e, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, e.name);
    }
    return try out.toOwnedSlice(allocator);
}

fn catalogForRegexTests(allocator: std.mem.Allocator) ![]const Entry {
    const reg_specs = [_][2][]const u8{
        .{ "kanban_list", "Enumerate every card on a board." },
        .{ "kanban_move_task", "Move a card." },
        .{ "read_workspace_session", "Search and read past conversation history" },
        .{ "crawl_web", "Searcher index for external pages." },
        .{ "glob", "Find files by PATTERN." },
        .{ "read_file", "Read a file with line numbers." },
    };
    const mcp_specs = [_][2][]const u8{
        .{ "mcp_linear_create-issue", "Create an issue in Linear." },
        .{ "mcp_github_create-pr", "Open a pull request." },
        .{ "mcp_ctx_query-docs", "Query library documentation." },
    };
    const reg = try makeToolList(allocator, &reg_specs);
    const mcp_list = try makeToolList(allocator, &mcp_specs);
    return buildCatalog(allocator, reg, NONE_ENABLED, false, mcp_list, &.{}, "agent");
}

test "matchQuery: a regex query, not just a substring" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try catalogForRegexTests(a);

    // Anchored prefix + wildcard: every MCP tool from any server that creates.
    const creates = try matchQuery(a, entries, "^mcp_.*_create", "", .{});
    try testing.expectEqual(QueryMode.regex, creates.mode);
    try testing.expectEqualStrings("mcp_linear_create-issue,mcp_github_create-pr", try matchedNamesJoined(a, creates));

    // Alternation catches a capability under several spellings in ONE call —
    // the whole reason for the feature.
    const either = try matchQuery(a, entries, "docs|documentation", "", .{});
    try testing.expectEqualStrings("mcp_ctx_query-docs", try matchedNamesJoined(a, either));

    // Two concepts in one call (the substring equivalent was impossible).
    const both = try matchQuery(a, entries, "create.*(issue|pr)", "", .{});
    try testing.expectEqualStrings("mcp_linear_create-issue,mcp_github_create-pr", try matchedNamesJoined(a, both));

    // A word, not a fragment: \bsearch\b removes the "Searcher" noise that the
    // plain substring keeps — the A/B is the point.
    const word = try matchQuery(a, entries, "\\bsearch\\b", "", .{});
    try testing.expectEqualStrings("read_workspace_session", try matchedNamesJoined(a, word));
    const fragment = try matchQuery(a, entries, "search", "", .{});
    try testing.expectEqualStrings("read_workspace_session,crawl_web", try matchedNamesJoined(a, fragment));

    // `_` is a word byte, exactly like rg's -w: \blist\b cannot match the NAME
    // `kanban_list` (the underscore is a word byte on its left), and no
    // description in this fixture carries the standalone word either.
    const underscored = try matchQuery(a, entries, "\\blist\\b", "", .{});
    try testing.expectEqual(@as(usize, 0), underscored.entries.len);
    // The unanchored fragment does find it, which is the noise \b removes.
    const loose = try matchQuery(a, entries, "_list", "", .{});
    try testing.expectEqualStrings("kanban_list", try matchedNamesJoined(a, loose));

    // '.' is a wildcard, and `$` is strict end-of-text.
    const any_char = try matchQuery(a, entries, "kanban_.*", "", .{});
    try testing.expectEqual(@as(usize, 2), any_char.entries.len);
    const at_end = try matchQuery(a, entries, "_task$", "", .{});
    try testing.expectEqualStrings("kanban_move_task", try matchedNamesJoined(a, at_end));
}

test "matchQuery: literal:true disables the pattern language" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const reg_specs = [_][2][]const u8{.{ "add_element", "Add an element (design)." }};
    const reg = try makeToolList(a, &reg_specs);
    const entries = try buildCatalog(a, reg, NONE_ENABLED, false, null, &.{}, "agent");

    // The literal text IS in the description…
    const as_literal = try matchQuery(a, entries, "element (design)", "", .{ .literal = true });
    try testing.expectEqual(QueryMode.literal, as_literal.mode);
    try testing.expectEqual(@as(usize, 1), as_literal.entries.len);
    try testing.expectEqualStrings("", as_literal.warning);

    // …but as a regex the parens are a GROUP, so the pattern means
    // "element design" and finds nothing. This is exactly why the escape hatch
    // exists — and why regex-by-default must be documented.
    const as_regex = try matchQuery(a, entries, "element (design)", "", .{});
    try testing.expectEqual(QueryMode.regex, as_regex.mode);
    try testing.expectEqual(@as(usize, 0), as_regex.entries.len);

    // A bare '*' is not a regex at all → fallback; as a literal it matches only
    // a real asterisk (no tool has one).
    const star = try matchQuery(a, entries, "*", "", .{ .literal = true });
    try testing.expectEqual(@as(usize, 0), star.entries.len);
    const star_regex = try matchQuery(a, entries, "*", "", .{});
    try testing.expectEqual(QueryMode.regex_fallback, star_regex.mode);
}

test "matchQuery: an invalid pattern falls back to a literal substring and says why" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const reg_specs = [_][2][]const u8{
        .{ "kanban_list", "List a kanban board." },
        .{ "group_elements", "Group elements (design pages)." },
    };
    const reg = try makeToolList(a, &reg_specs);
    const entries = try buildCatalog(a, reg, NONE_ENABLED, false, null, &.{}, "agent");

    // Unbalanced '(' is not a regex — the call still works, as a substring.
    const result = try matchQuery(a, entries, "elements (design", "", .{});
    try testing.expectEqual(QueryMode.regex_fallback, result.mode);
    try testing.expectEqual(@as(usize, 1), result.entries.len);
    try testing.expectEqualStrings("group_elements", result.entries[0].name);
    try testing.expect(std.mem.indexOf(u8, result.warning, "not a valid regex") != null);
    try testing.expect(std.mem.indexOf(u8, result.warning, "literal:true") != null);

    // The warning survives rendering as JSON.
    const out = try renderSearchResult(a, result.entries, .{
        .total = result.entries.len,
        .offset = 0,
        .limit = DEFAULT_SEARCH_LIMIT,
        .query = "elements (design",
        .server = "",
        .mode = result.mode,
        .warning = result.warning,
    });
    const parsed = try parseResult(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("literal_fallback", obj.get("pattern_mode").?.string);
    try testing.expect(obj.get("pattern_warning").? != .null);
    try testing.expect(std.mem.indexOf(u8, obj.get("pattern_warning").?.string, "literal:true") != null);
}

test "matchQuery: regex mode ignores substring artifacts of the old implementation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try catalogForRegexTests(a);

    // Case-insensitive by default, like the substring search it replaces.
    const upper = try matchQuery(a, entries, "KANBAN", "", .{});
    try testing.expectEqual(@as(usize, 2), upper.entries.len);

    // `$` is strict end-of-text.
    const end = try matchQuery(a, entries, "history$", "", .{});
    try testing.expectEqualStrings("read_workspace_session", try matchedNamesJoined(a, end));

    // server filter still applies on top of a regex.
    const scoped = try matchQuery(a, entries, "create", "linear", .{});
    try testing.expectEqualStrings("mcp_linear_create-issue", try matchedNamesJoined(a, scoped));
}

test "findByName + didYouMean: fuzzy recovery for a mistyped name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const specs = [_][2][]const u8{
        .{ "kanban_list", "List a kanban board." },
        .{ "mcp_ctx_query-docs", "Query documentation." },
    };
    const entries_tools = try makeToolList(a, &specs);
    const entries = try buildCatalog(a, entries_tools, NONE_ENABLED, false, null, &.{}, "agent");

    try testing.expect(findByName(entries, "kanban_list") != null);
    try testing.expect(findByName(entries, "kanban_lst") == null);

    const hits = try didYouMean(a, entries, "kanban_listt", 3);
    try testing.expect(hits.len >= 1);
    try testing.expectEqualStrings("kanban_list", hits[0]);

    // Separator-folded match: the underscore variant resolves.
    const hits2 = try didYouMean(a, entries, "mcp_ctx_query_docs", 3);
    try testing.expect(hits2.len >= 1);
    try testing.expectEqualStrings("mcp_ctx_query-docs", hits2[0]);

    // Nothing close → empty, never a fabricated name.
    const none = try didYouMean(a, entries, "zzzzzzzzzz", 3);
    try testing.expectEqual(@as(usize, 0), none.len);
}

// ============================================================================
// Result renderers These produce the INNER body of each tool result; the
// standard `wrapToolOutput` envelope is applied by the exec adapter, exactly

pub const MAX_SEARCH_ROWS: usize = 40;
pub const SUMMARY_MAX: usize = 120;

/// Default page size (== the pre-paging cap) and the hard ceiling. The catalog
/// can be large once an MCP server is connected, and the result rides in the
/// context window, so a single call may never return the whole thing.
pub const DEFAULT_SEARCH_LIMIT: usize = MAX_SEARCH_ROWS;
pub const MAX_SEARCH_LIMIT: usize = 200;

/// Everything `renderSearchResult` needs beyond the page rows themselves.
pub const SearchPageParams = struct {
    /// Matches before paging, so the model can tell how much it is not seeing.
    total: usize,
    /// How many matches were skipped to produce `page`.
    offset: usize,
    /// The requested page size. The renderer still caps `page` at this.
    limit: usize,
    query: []const u8,
    server: []const u8,
    mode: QueryMode,
    warning: []const u8,
};

/// The `offset`/`limit` window of `entries`. Paging is applied HERE rather than
/// in `matchQuery` so the pre-page `total` stays available to the renderer.
pub fn pageSlice(entries: []const Entry, offset: usize, limit: usize) []const Entry {
    if (offset >= entries.len or limit == 0) return &.{};
    const end = if (limit > entries.len - offset) entries.len else offset + limit;
    return entries[offset..end];
}

fn jsonEscapeInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try out.appendSlice(allocator, "\\u00");
                    const hex = "0123456789abcdef";
                    try out.append(allocator, hex[c >> 4]);
                    try out.append(allocator, hex[c & 0xf]);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
}

/// The tool's parameter schema as compact JSON:
/// `{"type":"object","properties":{...},"required":[...]}`.
fn appendToolJsonSchema(out: *std.ArrayList(u8), allocator: std.mem.Allocator, tool: AgentTool) !void {
    const params = tool.function.parameters;
    try out.appendSlice(allocator, "{\"type\":");
    try out.append(allocator, '"');
    try jsonEscapeInto(out, allocator, params.type);
    try out.appendSlice(allocator, "\",\"properties\":{");

    for (params.properties, 0..) |prop, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.append(allocator, '"');
        try jsonEscapeInto(out, allocator, prop.name);
        try out.appendSlice(allocator, "\":{\"type\":\"");
        try jsonEscapeInto(out, allocator, prop.type);
        try out.appendSlice(allocator, "\",\"description\":\"");
        try jsonEscapeInto(out, allocator, prop.description);
        try out.appendSlice(allocator, "\"}");
    }

    try out.appendSlice(allocator, "},\"required\":[");
    for (params.required, 0..) |req, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.append(allocator, '"');
        try jsonEscapeInto(out, allocator, req);
        try out.append(allocator, '"');
    }
    try out.appendSlice(allocator, "]}");
}

fn kindStr(kind: Kind) []const u8 {
    return switch (kind) {
        .builtin => "builtin",
        .mcp => "mcp",
    };
}

fn equippedStr(equipped: Equipped) []const u8 {
    return switch (equipped) {
        .session => "session",
        .no => "no",
    };
}

fn modeStr(mode: QueryMode) []const u8 {
    return switch (mode) {
        .all => "all",
        .regex => "regex",
        .literal => "literal",
        .regex_fallback => "literal_fallback",
    };
}

const ToolRowJson = struct {
    name: []const u8,
    kind: []const u8,
    server: []const u8,
    equipped: []const u8,
    summary: []const u8,
};

fn toolRowJson(entry: Entry) ToolRowJson {
    return .{
        .name = entry.name,
        .kind = kindStr(entry.kind),
        .server = entry.server,
        .equipped = equippedStr(entry.equipped),
        .summary = summaryOf(entry.tool.function.description, SUMMARY_MAX),
    };
}

/// The tool's parameter schema as a JSON value:
/// `{"type":"object","properties":{...},"required":[...]}`.
fn schemaValue(allocator: std.mem.Allocator, tool: AgentTool) !std.json.Value {
    const params = tool.function.parameters;
    var props = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    for (params.properties) |prop| {
        var inner = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try inner.put(allocator, "type", .{ .string = prop.type });
        try inner.put(allocator, "description", .{ .string = prop.description });
        try props.put(allocator, prop.name, .{ .object = inner });
    }
    var required = std.json.Array.init(allocator);
    for (params.required) |req| try required.append(.{ .string = req });
    var schema = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try schema.put(allocator, "type", .{ .string = params.type });
    try schema.put(allocator, "properties", .{ .object = props });
    try schema.put(allocator, "required", .{ .array = required });
    return .{ .object = schema };
}

/// Parse a renderer result in tests.
fn parseResult(a: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, a, out, .{});
}

/// `search_tool` result as JSON.
pub fn renderSearchResult(
    allocator: std.mem.Allocator,
    page: []const Entry,
    params: SearchPageParams,
) ![]const u8 {
    const shown = @min(page.len, params.limit);
    const rows = try allocator.alloc(ToolRowJson, shown);
    defer allocator.free(rows);
    for (page[0..shown], 0..) |entry, k| rows[k] = toolRowJson(entry);

    const truncated = params.offset + shown < params.total;
    const next_offset: ?usize = if (truncated) params.offset + shown else null;
    const hint = if (truncated)
        try std.fmt.allocPrint(
            allocator,
            "Showing {d}-{d} of {d} matches — call again with offset={d} (same query) for the next page, or narrow the query.",
            .{ params.offset, params.offset + shown, params.total, params.offset + shown },
        )
    else
        try allocator.dupe(u8, "Call view_tool for the full parameter schema, then use_tool to enable it for this session. Tools you already have in your tool list are NOT listed here.");
    defer allocator.free(hint);

    const warning: ?[]const u8 = if (params.warning.len > 0) params.warning else null;
    const server: ?[]const u8 = if (params.server.len > 0) params.server else null;

    return try std.json.Stringify.valueAlloc(allocator, .{
        .query = params.query,
        .pattern_mode = modeStr(params.mode),
        .pattern_warning = warning,
        .server = server,
        .count = shown,
        .total = params.total,
        .offset = params.offset,
        .limit = params.limit,
        .tools = rows,
        .truncated = truncated,
        .next_offset = next_offset,
        .hint = hint,
    }, .{});
}

/// `view_tool` result for a found entry.
pub fn renderViewTool(allocator: std.mem.Allocator, entry: Entry) ![]const u8 {
    const note: ?[]const u8 = if (entry.equipped == .session)
        "Already enabled for this session — call it directly."
    else
        null;
    const hint: ?[]const u8 = if (entry.equipped == .session)
        null
    else
        "Call use_tool with this name to enable it for this session.";
    return try std.json.Stringify.valueAlloc(allocator, .{
        .name = entry.name,
        .kind = kindStr(entry.kind),
        .server = entry.server,
        .equipped = equippedStr(entry.equipped),
        .description = entry.tool.function.description,
        .parameters = try schemaValue(allocator, entry.tool),
        .note = note,
        .hint = hint,
    }, .{});
}

/// `view_tool` result for an unknown name. Never writes anything.
pub fn renderViewToolNotFound(
    allocator: std.mem.Allocator,
    name: []const u8,
    suggestions: []const []const u8,
) ![]const u8 {
    const msg = try std.fmt.allocPrint(
        allocator,
        "unknown tool '{s}' — not in this session's tool catalog",
        .{name},
    );
    defer allocator.free(msg);
    return try std.json.Stringify.valueAlloc(allocator, .{
        .name = name,
        .found = false,
        .@"error" = msg,
        .did_you_mean = suggestions,
        .hint = "Call search_tool to list candidates.",
    }, .{});
}

/// `use_tool` result. `inserted` must come from the caller's real DB outcome
/// (a `saveProgressiveTool` that returned true) — never guessed.
pub fn renderUseTool(
    allocator: std.mem.Allocator,
    entry: Entry,
    inserted: bool,
) ![]const u8 {
    const wait_next_turn: ?bool = if (inserted) true else null;
    const source: ?[]const u8 = if (inserted) null else @as([]const u8, "session");
    const note: []const u8 = if (inserted)
        "Enabled for this session. Call it directly from your next turn onward — the current turn's tool list was already sent."
    else
        "Already enabled for this session. Call it directly.";
    return try std.json.Stringify.valueAlloc(allocator, .{
        .name = entry.name,
        .kind = kindStr(entry.kind),
        .equipped = true,
        .inserted = inserted,
        .wait_next_turn = wait_next_turn,
        .source = source,
        .note = note,
        .hint = "If you need help with the spec, call view_tool with this name for the full parameter schema.",
    }, .{});
}

/// `use_tool` result for an unknown name. Never writes anything — this is
/// the "never fails open" guard.
pub fn renderUseToolNotFound(
    allocator: std.mem.Allocator,
    name: []const u8,
    suggestions: []const []const u8,
) ![]const u8 {
    const msg = try std.fmt.allocPrint(
        allocator,
        "unknown tool '{s}' — not in this session's tool catalog",
        .{name},
    );
    defer allocator.free(msg);
    return try std.json.Stringify.valueAlloc(allocator, .{
        .name = name,
        .equipped = false,
        .inserted = false,
        .@"error" = msg,
        .did_you_mean = suggestions,
        .hint = "Call search_tool, then view_tool, then use_tool with the exact name.",
    }, .{});
}

test "renderSearchResult: rows, chips and the not-listed hint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const reg_specs = [_][2][]const u8{.{ "kanban_list", "List a kanban board." }};
    const mcp_specs = [_][2][]const u8{.{ "mcp_ctx_query-docs", "Query documentation for a library." }};
    const reg = try makeToolList(a, &reg_specs);
    const mcp_list = try makeToolList(a, &mcp_specs);
    const entries = try buildCatalog(a, reg, NONE_ENABLED, false, mcp_list, &.{}, "agent");

    const q = try matchQuery(a, entries, "", "", .{});
    const out = try renderSearchResult(a, q.entries, .{
        .total = q.entries.len,
        .offset = 0,
        .limit = DEFAULT_SEARCH_LIMIT,
        .query = "",
        .server = "",
        .mode = q.mode,
        .warning = q.warning,
    });

    const parsed = try parseResult(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), obj.get("count").?.integer);
    try testing.expectEqual(@as(i64, 2), obj.get("total").?.integer);
    // The page window is always explicit, so a paging model can trust it.
    try testing.expectEqual(@as(i64, 0), obj.get("offset").?.integer);
    try testing.expectEqual(@as(i64, DEFAULT_SEARCH_LIMIT), obj.get("limit").?.integer);
    try testing.expectEqualStrings("all", obj.get("pattern_mode").?.string);
    try testing.expect(obj.get("pattern_warning").? == .null);
    try testing.expect(obj.get("server").? == .null);
    const tools = obj.get("tools").?.array.items;
    try testing.expectEqual(@as(usize, 2), tools.len);
    try testing.expectEqualStrings("kanban_list", tools[0].object.get("name").?.string);
    try testing.expectEqualStrings("builtin", tools[0].object.get("kind").?.string);
    try testing.expectEqualStrings("mcp", tools[1].object.get("kind").?.string);
    try testing.expectEqualStrings("ctx", tools[1].object.get("server").?.string);
    try testing.expectEqualStrings("no", tools[0].object.get("equipped").?.string);
    try testing.expectEqual(false, obj.get("truncated").?.bool);
    try testing.expect(std.mem.indexOf(u8, obj.get("hint").?.string, "NOT listed here") != null);
}

test "renderSearchResult: empty match count is not an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderSearchResult(a, &.{}, .{
        .total = 0,
        .offset = 0,
        .limit = DEFAULT_SEARCH_LIMIT,
        .query = "memory",
        .server = "",
        .mode = .all,
        .warning = "",
    });
    const parsed = try parseResult(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 0), obj.get("count").?.integer);
    try testing.expectEqual(@as(usize, 0), obj.get("tools").?.array.items.len);
    try testing.expect(obj.get("error") == null);
}

test "renderSearchResult: capped rows report truncated with the real total" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build MAX_SEARCH_ROWS + 2 entries.
    var specs: [MAX_SEARCH_ROWS + 2][2][]const u8 = undefined;
    var names: [MAX_SEARCH_ROWS + 2][]const u8 = undefined;
    for (0..MAX_SEARCH_ROWS + 2) |k| {
        names[k] = try std.fmt.allocPrint(a, "tool_{d}", .{k});
        specs[k] = .{ names[k], "desc" };
    }
    const tools_list = try makeToolList(a, &specs);
    const entries = try buildCatalog(a, tools_list, NONE_ENABLED, false, null, &.{}, "agent");
    try testing.expectEqual(MAX_SEARCH_ROWS + 2, entries.len);

    const q = try matchQuery(a, entries, "", "", .{});
    const out = try renderSearchResult(a, pageSlice(q.entries, 0, DEFAULT_SEARCH_LIMIT), .{
        .total = q.entries.len,
        .offset = 0,
        .limit = DEFAULT_SEARCH_LIMIT,
        .query = "",
        .server = "",
        .mode = q.mode,
        .warning = q.warning,
    });
    const parsed = try parseResult(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(true, obj.get("truncated").?.bool);
    try testing.expectEqual(@as(i64, MAX_SEARCH_ROWS), obj.get("count").?.integer);
    try testing.expectEqual(@as(i64, MAX_SEARCH_ROWS + 2), obj.get("total").?.integer);
    // The hint must name the offset that continues the listing, not merely say
    // "narrow it" — a big catalog is browsed page by page.
    try testing.expectEqual(@as(i64, MAX_SEARCH_ROWS), obj.get("next_offset").?.integer);
    const expect_next = try std.fmt.allocPrint(a, "offset={d}", .{MAX_SEARCH_ROWS});
    try testing.expect(std.mem.indexOf(u8, obj.get("hint").?.string, expect_next) != null);
}

test "pageSlice: window arithmetic, including past-the-end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var specs: [5][2][]const u8 = undefined;
    var names: [5][]const u8 = undefined;
    for (0..5) |i| {
        names[i] = try std.fmt.allocPrint(a, "tool_{d}", .{i});
        specs[i] = .{ names[i], "desc" };
    }
    const tools_list = try makeToolList(a, &specs);
    const entries = try buildCatalog(a, tools_list, NONE_ENABLED, false, null, &.{}, "agent");
    try testing.expectEqual(@as(usize, 5), entries.len);

    try testing.expectEqualStrings("tool_0,tool_1", try matchedNamesJoined(a, .{
        .entries = pageSlice(entries, 0, 2),
        .mode = .all,
    }));
    try testing.expectEqualStrings("tool_2,tool_3", try matchedNamesJoined(a, .{
        .entries = pageSlice(entries, 2, 2),
        .mode = .all,
    }));
    // limit past the end → short page, never out of range.
    try testing.expectEqualStrings("tool_4", try matchedNamesJoined(a, .{
        .entries = pageSlice(entries, 4, 40),
        .mode = .all,
    }));
    // offset == len → empty page (the caller still reports the real total).
    try testing.expectEqual(@as(usize, 0), pageSlice(entries, 5, 40).len);
    try testing.expectEqual(@as(usize, 0), pageSlice(entries, 99, 40).len);
    // limit == 0 → empty, never "everything".
    try testing.expectEqual(@as(usize, 0), pageSlice(entries, 0, 0).len);
}

test "renderSearchResult: paging walks the matches and ends without truncation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var specs: [5][2][]const u8 = undefined;
    var names: [5][]const u8 = undefined;
    for (0..5) |k| {
        names[k] = try std.fmt.allocPrint(a, "tool_{d}", .{k});
        specs[k] = .{ names[k], "desc" };
    }
    const tools_list = try makeToolList(a, &specs);
    const entries = try buildCatalog(a, tools_list, NONE_ENABLED, false, null, &.{}, "agent");

    // Page 1 of 2: two rows, real total, and the next offset in the hint.
    const p1 = try renderSearchResult(a, pageSlice(entries, 0, 2), .{
        .total = entries.len,
        .offset = 0,
        .limit = 2,
        .query = "",
        .server = "",
        .mode = .all,
        .warning = "",
    });
    {
        const parsed = try parseResult(a, p1);
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expectEqual(@as(i64, 2), obj.get("count").?.integer);
        try testing.expectEqual(@as(i64, 5), obj.get("total").?.integer);
        try testing.expectEqual(@as(i64, 0), obj.get("offset").?.integer);
        try testing.expectEqual(@as(i64, 2), obj.get("limit").?.integer);
        const tools = obj.get("tools").?.array.items;
        try testing.expectEqualStrings("tool_0", tools[0].object.get("name").?.string);
        try testing.expectEqual(@as(usize, 2), tools.len);
        try testing.expectEqual(true, obj.get("truncated").?.bool);
        try testing.expect(std.mem.indexOf(u8, obj.get("hint").?.string, "offset=2") != null);
    }

    // Page 3 (last): not truncated, and the enable-it hint is back.
    const p3 = try renderSearchResult(a, pageSlice(entries, 4, 2), .{
        .total = entries.len,
        .offset = 4,
        .limit = 2,
        .query = "",
        .server = "",
        .mode = .all,
        .warning = "",
    });
    {
        const parsed = try parseResult(a, p3);
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expectEqual(@as(i64, 1), obj.get("count").?.integer);
        try testing.expectEqual(@as(i64, 5), obj.get("total").?.integer);
        const tools = obj.get("tools").?.array.items;
        try testing.expectEqualStrings("tool_4", tools[0].object.get("name").?.string);
        try testing.expectEqual(false, obj.get("truncated").?.bool);
        try testing.expect(obj.get("next_offset").? == .null);
        try testing.expect(std.mem.indexOf(u8, obj.get("hint").?.string, "NOT listed here") != null);
    }

    // An offset past the end is an empty page that still reports the total,
    // so the model can recover instead of guessing.
    const past = try renderSearchResult(a, pageSlice(entries, 7, 2), .{
        .total = entries.len,
        .offset = 7,
        .limit = 2,
        .query = "",
        .server = "",
        .mode = .all,
        .warning = "",
    });
    {
        const parsed = try parseResult(a, past);
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expectEqual(@as(i64, 0), obj.get("count").?.integer);
        try testing.expectEqual(@as(i64, 5), obj.get("total").?.integer);
        try testing.expectEqual(@as(usize, 0), obj.get("tools").?.array.items.len);
        try testing.expect(obj.get("error") == null);
    }
}

test "renderViewTool: full schema as JSON, hint to enable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tool = try makeTool(a, "kanban_list", "List a kanban board.");
    const entry = Entry{ .name = "kanban_list", .kind = .builtin, .server = "", .equipped = .no, .tool = tool };
    const out = try renderViewTool(a, entry);

    const parsed = try parseResult(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("kanban_list", obj.get("name").?.string);
    try testing.expectEqualStrings("no", obj.get("equipped").?.string);
    const params = obj.get("parameters").?.object;
    try testing.expectEqualStrings("object", params.get("type").?.string);
    try testing.expect(obj.get("hint").? != .null);
    try testing.expect(std.mem.indexOf(u8, obj.get("hint").?.string, "Call use_tool") != null);
    try testing.expect(obj.get("note").? == .null);
}

test "renderViewToolNotFound / renderUseToolNotFound: found=false + did-you-mean, no writes implied" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const view = try renderViewToolNotFound(a, "kanban_lst", &.{"kanban_list"});
    {
        const parsed = try parseResult(a, view);
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expectEqual(false, obj.get("found").?.bool);
        const sug = obj.get("did_you_mean").?.array.items;
        try testing.expectEqual(@as(usize, 1), sug.len);
        try testing.expectEqualStrings("kanban_list", sug[0].string);
        try testing.expect(obj.get("error").? != .null);
    }

    const use = try renderUseToolNotFound(a, "kanban_lst", &.{"kanban_list"});
    {
        const parsed = try parseResult(a, use);
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expectEqual(false, obj.get("equipped").?.bool);
        try testing.expectEqual(false, obj.get("inserted").?.bool);
        try testing.expectEqual(@as(usize, 1), obj.get("did_you_mean").?.array.items.len);
    }
}

test "renderUseTool: inserted=true is just the equip signal, no repeated schema" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tool = try makeTool(a, "glob", "Find files.");
    const entry = Entry{ .name = "glob", .kind = .builtin, .server = "", .equipped = .no, .tool = tool };

    const inserted = try renderUseTool(a, entry, true);
    {
        const parsed = try parseResult(a, inserted);
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expectEqual(true, obj.get("inserted").?.bool);
        try testing.expectEqual(true, obj.get("wait_next_turn").?.bool);
        // The agent already saw the full spec via view_tool — no repeat here.
        try testing.expect(obj.get("parameters") == null);
        try testing.expect(obj.get("description") == null);
        // The equip signal still points at view_tool for spec help: the
        // agent may have skipped view (search -> use directly).
        try testing.expect(std.mem.indexOf(u8, obj.get("hint").?.string, "view_tool") != null);
        try testing.expect(std.mem.indexOf(u8, obj.get("hint").?.string, "spec") != null);
    }

    const already = try renderUseTool(a, entry, false);
    {
        const parsed = try parseResult(a, already);
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expectEqual(false, obj.get("inserted").?.bool);
        try testing.expect(obj.get("wait_next_turn").? == .null);
        try testing.expect(std.mem.indexOf(u8, obj.get("note").?.string, "Already enabled") != null);
        try testing.expect(std.mem.indexOf(u8, obj.get("hint").?.string, "view_tool") != null);
    }
}

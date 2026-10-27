//! Matching + rendering for the `search_skills` agent tool.

const std = @import("std");
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const progressive_regex = @import("progressive_regex.zig");
const skills_store = pabrikcore.skills_store;

/// Default page size and the hard ceiling. The result rides in the context
/// window, so a single call may never return the whole library.
pub const DEFAULT_SEARCH_LIMIT: usize = 40;
pub const MAX_SEARCH_LIMIT: usize = 200;

/// One skill, as the matcher sees it: name + description, borrowed from
/// the store row it came from. There is no tier and no path — see the
/// file header for why both are gone.
pub const SkillRow = struct {
    name: []const u8,
    description: []const u8,
    is_can_auto_improve: bool = true,
};

/// Project the store's rows into the borrowed shape the matcher wants.
pub fn collectRows(
    allocator: std.mem.Allocator,
    rows: []const skills_store.SkillRow,
) ![]SkillRow {
    var out: std.ArrayList(SkillRow) = .empty;
    errdefer out.deinit(allocator);

    for (rows) |row| {
        try out.append(allocator, .{
            .name = row.name,
            .description = row.description,
            .is_can_auto_improve = row.is_can_auto_improve,
        });
    }

    return out.toOwnedSlice(allocator);
}

/// How a query was interpreted. Rendered into the result so the model can
/// tell a real regex hit from a literal fallback without guessing.
pub const QueryMode = enum {
    /// No query given: every row.
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
    /// `literal: true`: case-insensitive substring, no metacharacters.
    literal: bool = false,
};

pub const QueryResult = struct {
    rows: []const SkillRow,
    mode: QueryMode,
    /// Non-empty only when the query was reinterpreted or the match ran out
    /// of budget. Rendered as `pattern_warning`. Always a STATIC string, so
    /// no result owns an allocation the caller can leak.
    warning: []const u8 = "",
};

const WARNING_SUFFIX =
    " Supported: literals, '.', '[...]', '\\d \\w \\s \\b', '*', '+', '?', '{m,n}' ranges," ++
    " '( )' groups, '|', '^', '$'. Pass literal:true when the query is literal text.";

/// Why a pattern was reinterpreted as a literal substring.
fn invalidPatternWarningFor(err: progressive_regex.Error) []const u8 {
    return switch (err) {
        error.InvalidPattern => "query is not a valid regex (InvalidPattern) — matched as a case-insensitive literal substring instead." ++ WARNING_SUFFIX,
        error.PatternTooLong => "query is too long for the pattern compiler (PatternTooLong) — matched as a case-insensitive literal substring instead." ++ WARNING_SUFFIX,
        error.OutOfMemory => "the pattern could not be compiled (OutOfMemory) — matched as a case-insensitive literal substring instead." ++ WARNING_SUFFIX,
    };
}

fn exhaustedWarning() []const u8 {
    return "the pattern was too expensive to finish matching, so some skills were skipped — anchor it with '^' or pass literal:true";
}

/// Match rows by `query`, a case-insensitive unanchored REGEX over the
/// skill's NAME and DESCRIPTION — the same contract `search_tool` uses, so
/// the model needs only one mental model for "search a catalog".
pub fn matchQuery(
    allocator: std.mem.Allocator,
    rows: []const SkillRow,
    query: []const u8,
    opts: MatchOptions,
) !QueryResult {
    var matched: std.ArrayList(SkillRow) = .empty;
    errdefer matched.deinit(allocator);

    if (query.len == 0) {
        for (rows) |row| try matched.append(allocator, row);
        return .{ .rows = try matched.toOwnedSlice(allocator), .mode = .all };
    }

    var regex: ?progressive_regex.Regex = null;
    defer if (regex) |*re| re.deinit();

    var mode: QueryMode = .literal;
    var warning: []const u8 = "";

    if (!opts.literal) {
        if (progressive_regex.compile(allocator, query, .{})) |re| {
            regex = re;
            mode = .regex;
        } else |err| {
            mode = .regex_fallback;
            warning = invalidPatternWarningFor(err);
        }
    }

    for (rows) |row| {
        const hit = if (regex) |*re|
            (re.isMatch(row.name) or re.isMatch(row.description))
        else
            (containsIgnoreCase(row.name, query) or containsIgnoreCase(row.description, query));
        if (hit) try matched.append(allocator, row);
    }

    if (regex) |*re| {
        if (re.exhausted()) warning = exhaustedWarning();
    }

    return .{
        .rows = try matched.toOwnedSlice(allocator),
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

/// Everything `renderSearchResult` needs beyond the page rows themselves.
pub const PageParams = struct {
    /// Matches before paging, so the model can tell how much it is not seeing.
    total: usize,
    /// How many matches were skipped to produce `page`.
    offset: usize,
    /// The requested page size. The renderer still caps `page` at this.
    limit: usize,
    query: []const u8,
    mode: QueryMode,
    warning: []const u8,
};

/// The `offset`/`limit` window of `rows`. Paging is applied HERE rather than
/// in `matchQuery` so the pre-page `total` stays available to the renderer.
pub fn pageSlice(rows: []const SkillRow, offset: usize, limit: usize) []const SkillRow {
    if (offset >= rows.len or limit == 0) return &.{};
    const end = if (limit > rows.len - offset) rows.len else offset + limit;
    return rows[offset..end];
}

const SkillRowJson = struct {
    name: []const u8,
    description: []const u8,
    is_can_auto_improve: bool,
};

fn modeStr(mode: QueryMode) []const u8 {
    return switch (mode) {
        .all => "all",
        .regex => "regex",
        .literal => "literal",
        .regex_fallback => "literal_fallback",
    };
}

/// `search_skills` result: `{"query","pattern_mode","pattern_warning",
/// "count","total","offset","limit","skills","truncated","next_offset",
/// "hint"}`.
pub fn renderSearchResult(
    allocator: std.mem.Allocator,
    page: []const SkillRow,
    params: PageParams,
) ![]const u8 {
    const shown = @min(page.len, params.limit);
    const rows = try allocator.alloc(SkillRowJson, shown);
    defer allocator.free(rows);
    for (page[0..shown], 0..) |row, i| {
        rows[i] = .{
            .name = row.name,
            .description = row.description,
            .is_can_auto_improve = row.is_can_auto_improve,
        };
    }

    const truncated = params.offset + shown < params.total;
    const next_offset: ?usize = if (truncated) params.offset + shown else null;
    const hint = if (truncated)
        try std.fmt.allocPrint(
            allocator,
            "Showing {d}-{d} of {d} matches — call again with offset={d} (same query) for the next page, or narrow the query.",
            .{ params.offset, params.offset + shown, params.total, params.offset + shown },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "Call use_skill with a row's exact `name` to load it. Widen `query` if you expected more.",
            .{},
        );
    defer allocator.free(hint);

    const warning: ?[]const u8 = if (params.warning.len > 0) params.warning else null;

    return try std.json.Stringify.valueAlloc(allocator, .{
        .query = params.query,
        .pattern_mode = modeStr(params.mode),
        .pattern_warning = warning,
        .count = shown,
        .total = params.total,
        .offset = params.offset,
        .limit = params.limit,
        .skills = rows,
        .truncated = truncated,
        .next_offset = next_offset,
        .hint = hint,
    }, .{});
}

// ───────────────────────── tests ───────────────────────── The regex /
// paging / warning machinery is unchanged, so those tests are unchanged too —
// only the row shape they build lost its tier and path.

/// Parsed shape of `renderSearchResult` output.
const RenderedSearch = struct {
    query: []const u8 = "",
    pattern_mode: []const u8 = "",
    pattern_warning: ?[]const u8 = null,
    count: usize = 0,
    total: usize = 0,
    offset: usize = 0,
    limit: usize = 0,
    skills: []const RenderedRow = &.{},
    truncated: bool = false,
    next_offset: ?usize = null,
    hint: []const u8 = "",
};

const RenderedRow = struct {
    name: []const u8,
    description: []const u8,
    is_can_auto_improve: bool = true,
};

fn parseRendered(alloc: std.mem.Allocator, out: []const u8) !std.json.Parsed(RenderedSearch) {
    return try std.json.parseFromSlice(RenderedSearch, alloc, out, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

const test_rows = [_]SkillRow{
    .{ .name = "zig-cross-platform", .description = "Prove Zig code compiles for Linux, macOS and Windows" },
    .{ .name = "vitest-alias-stub", .description = "Resolve a bare specifier in a Vue component test" },
    .{ .name = "brainstorming", .description = "Explore user intent before creative work" },
};

test "matchQuery with no query returns every row in mode=all" {
    const alloc = testing.allocator;
    const res = try matchQuery(alloc, &test_rows, "", .{});
    defer alloc.free(res.rows);

    try testing.expectEqual(QueryMode.all, res.mode);
    try testing.expectEqual(@as(usize, 3), res.rows.len);
    try testing.expectEqualStrings("", res.warning);
}

test "matchQuery regex matches name OR description, case-insensitively" {
    const alloc = testing.allocator;

    // name hit
    const by_name = try matchQuery(alloc, &test_rows, "zig-cross", .{});
    defer alloc.free(by_name.rows);
    try testing.expectEqual(QueryMode.regex, by_name.mode);
    try testing.expectEqual(@as(usize, 1), by_name.rows.len);
    try testing.expectEqualStrings("zig-cross-platform", by_name.rows[0].name);

    // description hit, different case on both sides
    const by_desc = try matchQuery(alloc, &test_rows, "VITEST", .{});
    defer alloc.free(by_desc.rows);
    try testing.expectEqual(@as(usize, 1), by_desc.rows.len);
    try testing.expectEqualStrings("vitest-alias-stub", by_desc.rows[0].name);

    // alternation reaches both in one call
    const alt = try matchQuery(alloc, &test_rows, "brainstorming|zig-cross", .{});
    defer alloc.free(alt.rows);
    try testing.expectEqual(@as(usize, 2), alt.rows.len);
}

test "matchQuery literal:true treats metacharacters verbatim" {
    const alloc = testing.allocator;

    // As a REGEX, "zig." is "zig" followed by any character, and matches the
    // skill named `zig-cross-platform`.
    const as_regex = try matchQuery(alloc, &test_rows, "zig.", .{});
    defer alloc.free(as_regex.rows);
    try testing.expectEqual(QueryMode.regex, as_regex.mode);
    try testing.expectEqual(@as(usize, 1), as_regex.rows.len);
    try testing.expectEqualStrings("zig-cross-platform", as_regex.rows[0].name);

    // As a LITERAL it is the 4-character text "zig.", which no row carries —
    // the flag is the only thing making those two answers differ.
    const as_literal = try matchQuery(alloc, &test_rows, "zig.", .{ .literal = true });
    defer alloc.free(as_literal.rows);
    try testing.expectEqual(QueryMode.literal, as_literal.mode);
    try testing.expectEqual(@as(usize, 0), as_literal.rows.len);

    // And a literal that IS present is still found.
    const desc_literal_hit = try matchQuery(alloc, &test_rows, "user intent", .{ .literal = true });
    defer alloc.free(desc_literal_hit.rows);
    try testing.expectEqual(@as(usize, 1), desc_literal_hit.rows.len);
    try testing.expectEqualStrings("brainstorming", desc_literal_hit.rows[0].name);
}

test "an invalid pattern degrades to a literal substring and says so" {
    const alloc = testing.allocator;

    // Unbalanced group — never a hard error.
    const res = try matchQuery(alloc, &test_rows, "zig(", .{});
    defer alloc.free(res.rows);

    try testing.expectEqual(QueryMode.regex_fallback, res.mode);
    try testing.expect(res.warning.len > 0);
    try testing.expect(std.mem.indexOf(u8, res.warning, "literal:true") != null);
    // Nothing matched: "zig(" is not a substring of any row.
    try testing.expectEqual(@as(usize, 0), res.rows.len);
}

test "pageSlice returns the requested window and clamps at the end" {
    try testing.expectEqual(@as(usize, 2), pageSlice(&test_rows, 0, 2).len);
    try testing.expectEqualStrings("brainstorming", pageSlice(&test_rows, 2, 2)[0].name);
    try testing.expectEqual(@as(usize, 0), pageSlice(&test_rows, 99, 2).len);
    try testing.expectEqual(@as(usize, 0), pageSlice(&test_rows, 0, 0).len);
    try testing.expectEqual(@as(usize, 1), pageSlice(&test_rows, 2, 99).len);
}

test "renderSearchResult reports the pre-page total and names the continuing offset" {
    const alloc = testing.allocator;

    const out = try renderSearchResult(alloc, &test_rows, .{
        .total = 3,
        .offset = 0,
        .limit = 2,
        .query = "skill",
        .mode = .regex,
        .warning = "",
    });
    defer alloc.free(out);

    const parsed = try parseRendered(alloc, out);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.value.count);
    try testing.expectEqual(@as(usize, 3), parsed.value.total);
    try testing.expect(parsed.value.truncated);
    try testing.expectEqual(@as(usize, 2), parsed.value.next_offset.?);
    try testing.expectEqualStrings("regex", parsed.value.pattern_mode);
    try testing.expect(parsed.value.pattern_warning == null);
    try testing.expectEqual(@as(usize, 2), parsed.value.skills.len);
    try testing.expectEqualStrings("zig-cross-platform", parsed.value.skills[0].name);
    try testing.expectEqualStrings(
        "Prove Zig code compiles for Linux, macOS and Windows",
        parsed.value.skills[0].description,
    );
    // The hint names the exact continuing offset.
    try testing.expect(std.mem.indexOf(u8, parsed.value.hint, "offset=2") != null);
}

test "renderSearchResult on the last page is not truncated and points at use_skill" {
    const alloc = testing.allocator;

    const out = try renderSearchResult(alloc, &test_rows, .{
        .total = 3,
        .offset = 1,
        .limit = 40,
        .query = "",
        .mode = .all,
        .warning = "",
    });
    defer alloc.free(out);

    const parsed = try parseRendered(alloc, out);
    defer parsed.deinit();

    try testing.expect(!parsed.value.truncated);
    try testing.expect(parsed.value.next_offset == null);
    try testing.expect(std.mem.indexOf(u8, parsed.value.hint, "use_skill") != null);
}

test "renderSearchResult surfaces a pattern_warning verbatim" {
    const alloc = testing.allocator;

    const res = try matchQuery(alloc, &test_rows, "zig(", .{});
    defer alloc.free(res.rows);

    const out = try renderSearchResult(alloc, res.rows, .{
        .total = res.rows.len,
        .offset = 0,
        .limit = 40,
        .query = "zig(",
        .mode = res.mode,
        .warning = res.warning,
    });
    defer alloc.free(out);

    const parsed = try parseRendered(alloc, out);
    defer parsed.deinit();
    try testing.expectEqualStrings("literal_fallback", parsed.value.pattern_mode);
    try testing.expect(parsed.value.pattern_warning != null);
}

test "renderSearchResult emits no tier and no path on any row" {
    const alloc = testing.allocator;

    const out = try renderSearchResult(alloc, &test_rows, .{
        .total = 3,
        .offset = 0,
        .limit = 40,
        .query = "",
        .mode = .all,
        .warning = "",
    });
    defer alloc.free(out);

    // Read the RAW string rather than the parsed struct: parsing with
    // `ignore_unknown_fields` would hide exactly the thing this asserts.
    try testing.expect(std.mem.indexOf(u8, out, "\"scope\"") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"is_global\"") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"path\"") == null);
    try testing.expect(std.mem.indexOf(u8, out, "SKILL.MD") == null);
}

// ---------------------------------------------------------------------------
// End-to-end against the store: the flattening must not widen the set.

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const migration = @import("../migrations/migration.zig");

const StoreTestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

/// Real Migration 101 tables. Seeded through the store, never with SQL —
/// a hand-written INSERT bypasses the `COALESCE(NULLIF(?, ''), '')` write
/// path and would pass while the real tool failed.
fn setupStoreDb() !StoreTestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try migration.Migration102CreateSkills.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

fn seedSkill(
    alloc: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    name: []const u8,
    description: []const u8,
) !void {
    const row = try skills_store.upsertSkill(alloc, db, .{
        .workspace_id = workspace_id,
        .name = name,
        .description = description,
        .content = "## body\n",
    });
    skills_store.freeSkillRow(alloc, row);
}

test "collectRows projects one workspace's rows and matches over them" {
    const alloc = testing.allocator;
    var ctx = try setupStoreDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSkill(alloc, &ctx.db, "ws_1", "search-fixture", "Fixture for the local tier");
    try seedSkill(alloc, &ctx.db, "ws_1", "another", "Also mine");
    try seedSkill(alloc, &ctx.db, "ws_2", "must-never-leak-in", "Another workspace's skill");

    const rows = try skills_store.listSkills(alloc, &ctx.db, "ws_1");
    defer skills_store.freeSkillRows(alloc, rows);
    try testing.expectEqual(@as(usize, 2), rows.len);

    const flat = try collectRows(alloc, rows);
    defer alloc.free(flat);

    // Exactly the two skills of ws_1, borrowed (no copies), and the other
    // workspace's name appears nowhere in the payload.
    try testing.expectEqual(@as(usize, 2), flat.len);
    try testing.expectEqualStrings("another", flat[0].name);
    try testing.expectEqualStrings("search-fixture", flat[1].name);
    try testing.expectEqualStrings("Fixture for the local tier", flat[1].description);

    const hit = try matchQuery(alloc, flat, "search-fixture", .{});
    defer alloc.free(hit.rows);
    try testing.expectEqual(@as(usize, 1), hit.rows.len);
    try testing.expectEqualStrings("search-fixture", hit.rows[0].name);

    const out = try renderSearchResult(alloc, hit.rows, .{
        .total = hit.rows.len,
        .offset = 0,
        .limit = 40,
        .query = "search-fixture",
        .mode = hit.mode,
        .warning = hit.warning,
    });
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "must-never-leak-in") == null);
}

test "renderSearchResult carries each row's auto-improve lock" {
    const alloc = testing.allocator;
    const rows = [_]SkillRow{
        .{ .name = "open", .description = "the agent may evolve this", .is_can_auto_improve = true },
        .{ .name = "pinned", .description = "the human locked this", .is_can_auto_improve = false },
    };

    const out = try renderSearchResult(alloc, &rows, .{
        .total = rows.len,
        .offset = 0,
        .limit = 40,
        .query = "",
        .mode = .all,
        .warning = "",
    });
    defer alloc.free(out);

    var parsed = try parseRendered(alloc, out);
    defer parsed.deinit();

    // Without this the model learns a skill is locked only by being
    // refused, which costs a round trip per attempt.
    try testing.expectEqual(@as(usize, 2), parsed.value.skills.len);
    try testing.expect(parsed.value.skills[0].is_can_auto_improve);
    try testing.expect(!parsed.value.skills[1].is_can_auto_improve);
}

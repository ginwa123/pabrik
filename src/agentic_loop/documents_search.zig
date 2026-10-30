//! Matching + rendering for the `search_documents` agent tool.

const std = @import("std");
const testing = std.testing;
const progressive_regex = @import("progressive_regex.zig");
const documents_store = @import("documents_store.zig");

/// Smaller than `skills_search`'s 40/200: a document excerpt is ~240 bytes
/// against a skill row's ~80, so the same page size costs several times more
/// context for a catalog where a single page is usually already the whole
pub const DEFAULT_SEARCH_LIMIT: usize = 20;
pub const MAX_SEARCH_LIMIT: usize = 100;

/// Longest `excerpt` a row may carry. Bounded because the excerpt exists
/// to disambiguate rows, not to be the body — a caller that needs the body
/// asks for `include_content` and gets a deliberate, accounted-for cost.
pub const EXCERPT_MAX_BYTES: usize = 240;

/// Characters that give a pattern meaning in `progressive_regex`.
pub const REGEX_METACHARS = ".^$*+?()[]{}|\\";

/// The needle to hand `documents_store.searchDocuments`, or `null` when SQL
/// must NOT be allowed to narrow the candidate set.
pub fn literalPrefilter(query: []const u8, literal: bool) ?[]const u8 {
    if (query.len == 0) return null;
    if (literal) return query;
    if (std.mem.indexOfAny(u8, query, REGEX_METACHARS) == null) return query;
    return null;
}

/// How a query was interpreted. Identical vocabulary to `QueryMode` in
/// `skills_search.zig`; the strings are the same on the wire so a model
/// that has read one `pattern_mode` has read all three.
pub const QueryMode = enum {
    /// No query given: every document (newest-updated first).
    all,
    /// Compiled and matched as a regex.
    regex,
    /// `literal: true` was passed: case-insensitive substring.
    literal,
    /// The query did not compile as a regex and was matched as a literal
    /// substring instead. `QueryResult.warning` says why.
    regex_fallback,
};

fn modeStr(mode: QueryMode) []const u8 {
    return switch (mode) {
        .all => "all",
        .regex => "regex",
        .literal => "literal",
        .regex_fallback => "literal_fallback",
    };
}

/// One matching document. Every string field BORROWSS from the
/// `documents_store.DocumentRow` the matcher was handed — the slice must
/// outlive these.
pub const Hit = struct {
    id: []const u8,
    title: []const u8,
    format: []const u8,
    updated_at: []const u8,
    /// Borrowed, NOT copied. The renderer slices a window out of it for
    /// the excerpt and only reads the whole of it when `include_content`
    /// was asked for.
    content: []const u8,
    /// Byte length of the body. Reported so the model can tell a 40-byte
    /// stub from a 4 MiB document before deciding to ask for the body.
    content_length: usize,
    /// Byte offset into `content` of the first hit, when it could be located.
    content_anchor: ?usize,
    /// True when the TITLE matched. The renderer excerpts the title in
    /// that case — it is short, it is what the model searched for, and it
    /// is the label the human will recognise in the sidebar.
    title_matched: bool,
};

pub const MatchOptions = struct {
    /// `literal: true`: case-insensitive substring, no metacharacters.
    literal: bool = false,
};

pub const QueryResult = struct {
    hits: []const Hit,
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
    return "the pattern was too expensive to finish matching, so some documents were skipped — anchor it with '^' or pass literal:true";
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

/// First case-insensitive occurrence of `needle`, for the excerpt anchor.
/// Null when absent or longer than the haystack.
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return null;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Match rows by `query`, a case-insensitive unanchored REGEX over each
/// document's TITLE and CONTENT — the same contract `search_tool` uses, so
/// the model needs only one mental model for "search a catalog".
pub fn matchQuery(
    allocator: std.mem.Allocator,
    rows: []const documents_store.DocumentRow,
    query: []const u8,
    opts: MatchOptions,
) !QueryResult {
    var matched: std.ArrayList(Hit) = .empty;
    errdefer matched.deinit(allocator);

    if (query.len == 0) {
        for (rows) |row| try matched.append(allocator, hitOf(row, null, false));
        return .{ .hits = try matched.toOwnedSlice(allocator), .mode = .all };
    }

    var regex: ?progressive_regex.Regex = null;
    defer if (regex) |*re| re.deinit();

    var mode: QueryMode = .literal;
    var warning: []const u8 = "";

    // A compiled pattern made only of literals matches exactly the strings
    // containing it, so the hit can be located for the excerpt.
    const anchorable = std.mem.indexOfAny(u8, query, REGEX_METACHARS) == null;

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
        if (regex) |*re| {
            const in_title = re.isMatch(row.title);
            const in_content = re.isMatch(row.content);
            if (!in_title and !in_content) continue;
            // A pattern with no metacharacters IS a substring, so the hit can
            // be located and the excerpt centred on it.
            const anchor = if (anchorable) indexOfIgnoreCase(row.content, query) else null;
            try matched.append(allocator, hitOf(row, anchor, in_title));
        } else {
            const in_title = containsIgnoreCase(row.title, query);
            const in_content = containsIgnoreCase(row.content, query);
            if (!in_title and !in_content) continue;
            try matched.append(allocator, hitOf(row, indexOfIgnoreCase(row.content, query), in_title));
        }
    }

    if (regex) |*re| {
        if (re.exhausted()) warning = exhaustedWarning();
    }

    return .{
        .hits = try matched.toOwnedSlice(allocator),
        .mode = mode,
        .warning = warning,
    };
}

/// Build a `Hit` that borrows every string from `row`. `anchor` may be null
/// when the matcher knows only THAT the row matched.
fn hitOf(
    row: documents_store.DocumentRow,
    anchor: ?usize,
    title_matched: bool,
) Hit {
    return .{
        .id = row.id,
        .title = row.title,
        .format = row.format,
        .updated_at = row.updated_at,
        .content = row.content,
        .content_length = row.content.len,
        .content_anchor = anchor,
        .title_matched = title_matched,
    };
}

/// The `offset`/`limit` window of `hits`. Paging is applied HERE rather than
/// in `matchQuery` so the pre-page `total` stays available to the renderer.
pub fn pageSlice(hits: []const Hit, offset: usize, limit: usize) []const Hit {
    if (offset >= hits.len or limit == 0) return &.{};
    const end = if (limit > hits.len - offset) hits.len else offset + limit;
    return hits[offset..end];
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
    /// `include_content: true` — put each row's whole body in `content`.
    include_content: bool,
};

/// Snap `i` forward to the next UTF-8 sequence boundary.
fn alignForwardToUtf8(text: []const u8, i: usize) usize {
    var j = @min(i, text.len);
    while (j < text.len and (text[j] & 0xC0) == 0x80) j += 1;
    return j;
}

/// Snap `i` back to the start of the codepoint it lands inside.
fn alignBackToUtf8(text: []const u8, i: usize) usize {
    var j = @min(i, text.len);
    while (j > 0 and (text[j] & 0xC0) == 0x80) j -= 1;
    return j;
}

/// A bounded window of `text` centred on `anchor`, with `…` where text was
/// cut. Always returns `text.len <= EXCERPT_MAX_BYTES` worth of payload.
fn excerptOf(allocator: std.mem.Allocator, text: []const u8, anchor: ?usize) ![]const u8 {
    if (text.len == 0) return "";

    const centre = anchor orelse 0;
    // Put the hit roughly a third in, so the model sees what follows it —
    // "release" in the middle of a sentence tells it more than the sentence
    // start does.
    const lead = EXCERPT_MAX_BYTES / 3;
    var start = if (centre > lead) centre - lead else 0;
    var end = @min(start + EXCERPT_MAX_BYTES, text.len);
    start = alignBackToUtf8(text, start);
    end = alignForwardToUtf8(text, end);

    const prefix: []const u8 = if (start > 0) "…" else "";
    const suffix: []const u8 = if (end < text.len) "…" else "";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, text[start..end], suffix });
}

const DocumentRowJson = struct {
    id: []const u8,
    title: []const u8,
    format: []const u8,
    updated_at: []const u8,
    content_length: usize,
    excerpt: []const u8,
    /// Present only when `include_content` was set.
    content: ?[]const u8,
};

/// `search_documents` result: `{"query","pattern_mode","pattern_warning",
/// "count","total","offset","limit","documents","truncated","next_offset",
/// "hint"}`.
pub fn renderSearchResult(
    allocator: std.mem.Allocator,
    page: []const Hit,
    params: PageParams,
) ![]const u8 {
    const shown = @min(page.len, params.limit);
    const rows = try allocator.alloc(DocumentRowJson, shown);
    defer allocator.free(rows);

    // Each excerpt is freed after the JSON is built, so a page of 100 rows
    // costs 100 short-lived allocations rather than 100 survivors.
    const excerpts = try allocator.alloc([]const u8, shown);
    defer {
        for (excerpts) |e| allocator.free(e);
        allocator.free(excerpts);
    }

    for (page[0..shown], 0..) |hit, i| {
        // Where the excerpt comes from, in order: - the TITLE matched: show
        // the title.
        const source: []const u8 = if (hit.title_matched)
            hit.title
        else if (hit.content.len > 0)
            hit.content
        else
            hit.title;
        const anchor = if (hit.title_matched) null else hit.content_anchor;
        excerpts[i] = try excerptOf(allocator, source, anchor);
        rows[i] = .{
            .id = hit.id,
            .title = hit.title,
            .format = hit.format,
            .updated_at = hit.updated_at,
            .content_length = hit.content_length,
            .excerpt = excerpts[i],
            .content = if (params.include_content) hit.content else null,
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
        try allocator.dupe(u8, "Pass a row's exact `id` to edit_document (which replaces the whole body) or delete_document. Widen `query` if you expected more matches.");
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
        .documents = rows,
        .truncated = truncated,
        .next_offset = next_offset,
        .hint = hint,
    }, .{});
}

// ───────────────────────── tests ─────────────────────────

const RenderedRow = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    format: []const u8 = "",
    updated_at: []const u8 = "",
    content_length: usize = 0,
    excerpt: []const u8 = "",
    content: ?[]const u8 = null,
};

const RenderedSearch = struct {
    query: []const u8 = "",
    pattern_mode: []const u8 = "",
    pattern_warning: ?[]const u8 = null,
    count: usize = 0,
    total: usize = 0,
    offset: usize = 0,
    limit: usize = 0,
    documents: []const RenderedRow = &.{},
    truncated: bool = false,
    next_offset: ?usize = null,
    hint: []const u8 = "",
};

fn parseRendered(alloc: std.mem.Allocator, out: []const u8) !std.json.Parsed(RenderedSearch) {
    return try std.json.parseFromSlice(RenderedSearch, alloc, out, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

/// A `DocumentRow` whose strings live for the whole test (they are comptime
/// literals), so the borrow the matcher hands out stays valid.
fn testRow(
    id: []const u8,
    title: []const u8,
    content: []const u8,
    updated_at: []const u8,
) documents_store.DocumentRow {
    return .{
        .id = id,
        .workspace_id = "ws_1",
        .title = title,
        .content = content,
        .format = "markdown",
        .created_at = updated_at,
        .updated_at = updated_at,
        .position = 0,
    };
}

const test_rows = [_]documents_store.DocumentRow{
    testRow("doc_1", "Release plan v2", "# Release plan\n\n- ship 095\n- add the frontend\n", "2026-09-01 10:00:00"),
    testRow("doc_2", "Meeting notes", "We agreed to LAUNCH in October.\nBudget: $4k\n", "2026-09-02 10:00:00"),
    testRow("doc_3", "Zebra crossing TODO", "Nothing relevant in the body here.\n", "2026-09-03 10:00:00"),
    testRow("doc_4", "Empty stub", "", "2026-09-04 10:00:00"),
};

// ─── literalPrefilter: the soundness guard ──────────────────────────────

test "literalPrefilter: a metacharacter-free query narrows in SQL" {
    // Sound: the pattern is a run of literals, so LIKE '%x%' returns exactly
    // the rows the regex matches.
    try testing.expectEqualStrings("release", literalPrefilter("release", false).?);
    try testing.expectEqualStrings("Release Plan v2", literalPrefilter("Release Plan v2", false).?);
    // Digits, spaces and dashes are not metacharacters.
    try testing.expectEqualStrings("Q3 2026 - plan", literalPrefilter("Q3 2026 - plan", false).?);
}

test "literalPrefilter: every metacharacter disables the SQL narrowing" {
    for (".^$*+?()[]{}|\\") |c| {
        const q = [_]u8{ 'a', c, 'b' };
        try testing.expect(
            literalPrefilter(&q, false) == null,
        );
    }
    // `.` is the quiet one: `foo.bar` as a regex matches `fooXbar`, and a
    // LIKE prefilter would keep only the literal `foo.bar`.
    try testing.expect(literalPrefilter("foo.bar", false) == null);
    try testing.expect(literalPrefilter("^Q3", false) == null);
    try testing.expect(literalPrefilter("release|launch", false) == null);
}

test "literalPrefilter: literal:true narrows even with metacharacters" {
    // The model TOLD us it means literal text, so substring semantics are
    // what it asked for and LIKE agrees with them exactly.
    try testing.expectEqualStrings("*.zig", literalPrefilter("*.zig", true).?);
    try testing.expectEqualStrings("fn(", literalPrefilter("fn(", true).?);
}

test "literalPrefilter: an empty query never narrows" {
    try testing.expect(literalPrefilter("", false) == null);
    try testing.expect(literalPrefilter("", true) == null);
}

// ─── matchQuery ─────────────────────────────────────────────────────────

test "matchQuery with no query returns every row in mode=all" {
    const alloc = testing.allocator;
    const res = try matchQuery(alloc, &test_rows, "", .{});
    defer alloc.free(res.hits);

    try testing.expectEqual(QueryMode.all, res.mode);
    try testing.expectEqual(@as(usize, 4), res.hits.len);
    try testing.expectEqualStrings("", res.warning);
}

test "matchQuery regex matches title OR content, case-insensitively" {
    const alloc = testing.allocator;

    const by_title = try matchQuery(alloc, &test_rows, "zebra", .{});
    defer alloc.free(by_title.hits);
    try testing.expectEqual(QueryMode.regex, by_title.mode);
    try testing.expectEqual(@as(usize, 1), by_title.hits.len);
    try testing.expectEqualStrings("doc_3", by_title.hits[0].id);
    try testing.expect(by_title.hits[0].title_matched);

    const by_content = try matchQuery(alloc, &test_rows, "LAUNCH", .{});
    defer alloc.free(by_content.hits);
    try testing.expectEqual(@as(usize, 1), by_content.hits.len);
    try testing.expectEqualStrings("doc_2", by_content.hits[0].id);
    try testing.expect(!by_content.hits[0].title_matched);

    // Alternation reaches both in one call.
    const alt = try matchQuery(alloc, &test_rows, "zebra|LAUNCH", .{});
    defer alloc.free(alt.hits);
    try testing.expectEqual(@as(usize, 2), alt.hits.len);
}

test "matchQuery: an empty body is matchable by title and never crashes" {
    const alloc = testing.allocator;
    // `doc_4` has a zero-length content column.
    const by_title = try matchQuery(alloc, &test_rows, "Empty stub", .{});
    defer alloc.free(by_title.hits);
    try testing.expectEqual(@as(usize, 1), by_title.hits.len);
    try testing.expectEqual(@as(usize, 0), by_title.hits[0].content_length);

    // A body query that genuinely appears nowhere must not pick doc_4 up
    // just because its content is empty.
    const nothing = try matchQuery(alloc, &test_rows, "hippopotamus", .{});
    defer alloc.free(nothing.hits);
    try testing.expectEqual(@as(usize, 0), nothing.hits.len);
}

test "matchQuery literal:true treats metacharacters verbatim" {
    const alloc = testing.allocator;

    // As a REGEX, `release.` is "release" + any character.
    const as_regex = try matchQuery(alloc, &test_rows, "release.", .{});
    defer alloc.free(as_regex.hits);
    try testing.expectEqual(QueryMode.regex, as_regex.mode);
    try testing.expectEqual(@as(usize, 1), as_regex.hits.len);

    // As a LITERAL it is the 8-character text `release.`, which no row
    // carries. The flag is the only thing making those two answers differ.
    const as_literal = try matchQuery(alloc, &test_rows, "release.", .{ .literal = true });
    defer alloc.free(as_literal.hits);
    try testing.expectEqual(QueryMode.literal, as_literal.mode);
    try testing.expectEqual(@as(usize, 0), as_literal.hits.len);

    // And a literal that IS present is still found.
    const hit = try matchQuery(alloc, &test_rows, "frontEND", .{ .literal = true });
    defer alloc.free(hit.hits);
    try testing.expectEqual(@as(usize, 1), hit.hits.len);
    try testing.expectEqualStrings("doc_1", hit.hits[0].id);
}

test "an invalid pattern degrades to a literal substring and says so" {
    const alloc = testing.allocator;

    // Unbalanced group — never a hard error.
    const res = try matchQuery(alloc, &test_rows, "relea(", .{});
    defer alloc.free(res.hits);

    try testing.expectEqual(QueryMode.regex_fallback, res.mode);
    try testing.expect(res.warning.len > 0);
    try testing.expect(std.mem.indexOf(u8, res.warning, "literal:true") != null);
    try testing.expectEqual(@as(usize, 0), res.hits.len);
}

test "matchQuery: literal mode locates the hit, and so does a metachar-free regex" {
    const alloc = testing.allocator;

    // Literal: the anchor is known, so the excerpt can be centred on it.
    const lit = try matchQuery(alloc, &test_rows, "budget", .{ .literal = true });
    defer alloc.free(lit.hits);
    try testing.expectEqualStrings("doc_2", lit.hits[0].id);
    try testing.expect(lit.hits[0].content_anchor != null);

    // A metacharacter-free query in REGEX mode takes the same path, because
    // it compiles to exactly "the substring budget" — the common case must
    // still show the model WHERE it matched.
    const re = try matchQuery(alloc, &test_rows, "budget", .{});
    defer alloc.free(re.hits);
    try testing.expectEqualStrings("doc_2", re.hits[0].id);
    try testing.expect(re.hits[0].content_anchor != null);

    // With a real metacharacter the engine only reports WHETHER, so no
    // anchor — and the renderer must not invent one.
    const anchored = try matchQuery(alloc, &test_rows, "budget|plan", .{});
    defer alloc.free(anchored.hits);
    try testing.expectEqual(@as(usize, 2), anchored.hits.len);
    try testing.expect(anchored.hits[0].content_anchor == null);
    try testing.expect(anchored.hits[1].content_anchor == null);
}

test "matchQuery: no matches is an empty list, never an error" {
    const alloc = testing.allocator;
    const res = try matchQuery(alloc, &test_rows, "nothing here at all", .{});
    defer alloc.free(res.hits);
    try testing.expectEqual(@as(usize, 0), res.hits.len);
    try testing.expectEqualStrings("", res.warning);
}

test "matchQuery: a query longer than the body never matches and never reads past the end" {
    const alloc = testing.allocator;
    // Longer than every test body, so the substring scan must bail on the
    // length check rather than walk off the end of a slice.
    const long_needle = "a" ** 1000;
    const res = try matchQuery(alloc, &test_rows, long_needle, .{ .literal = true });
    defer alloc.free(res.hits);
    try testing.expectEqual(@as(usize, 0), res.hits.len);
}

// ─── pageSlice ──────────────────────────────────────────────────────────

test "pageSlice returns the requested window and clamps at the end" {
    const alloc = testing.allocator;
    const res = try matchQuery(alloc, &test_rows, "", .{});
    defer alloc.free(res.hits);

    try testing.expectEqual(@as(usize, 2), pageSlice(res.hits, 0, 2).len);
    try testing.expectEqualStrings("doc_3", pageSlice(res.hits, 2, 2)[0].id);
    try testing.expectEqual(@as(usize, 0), pageSlice(res.hits, 99, 2).len);
    try testing.expectEqual(@as(usize, 0), pageSlice(res.hits, 0, 0).len);
    // A limit past the end clamps to what is left, it does not error.
    try testing.expectEqual(@as(usize, 2), pageSlice(res.hits, 2, 99).len);
}

// ─── excerpt ────────────────────────────────────────────────────────────

test "excerptOf: a short body comes back whole with no ellipsis" {
    const alloc = testing.allocator;
    const out = try excerptOf(alloc, "short body", 3);
    defer alloc.free(out);
    try testing.expectEqualStrings("short body", out);
}

test "excerptOf: a long body is windowed and marked on the cut side" {
    const alloc = testing.allocator;
    const body = "x" ** 1000 ++ "NEEDLE" ++ "y" ** 1000;
    const anchor = 1000 + 2;
    const out = try excerptOf(alloc, body, anchor);
    defer alloc.free(out);

    try testing.expect(out.len <= EXCERPT_MAX_BYTES + 8); // + the two ellipses
    try testing.expect(std.mem.indexOf(u8, out, "NEEDLE") != null);
    // Both sides were cut, so both markers are present.
    try testing.expect(std.mem.startsWith(u8, out, "…"));
    try testing.expect(std.mem.endsWith(u8, out, "…"));
}

test "excerptOf: an anchor in the first third does not invent a leading ellipsis" {
    const alloc = testing.allocator;
    const body = "NEEDLE" ++ "y" ** 1000;
    const out = try excerptOf(alloc, body, 0);
    defer alloc.free(out);
    try testing.expect(!std.mem.startsWith(u8, out, "…"));
    try testing.expect(std.mem.endsWith(u8, out, "…"));
}

test "excerptOf: an empty body yields an empty string, not a slice error" {
    const alloc = testing.allocator;
    const out = try excerptOf(alloc, "", 0);
    defer alloc.free(out);
    try testing.expectEqualStrings("", out);
}

test "excerptOf: window edges never split a multi-byte codepoint" {
    const alloc = testing.allocator;
    // "é" is two bytes; repeat it so the window lands mid-character no matter
    // where EXCERPT_MAX_BYTES happens to fall.
    var body: [1200]u8 = undefined;
    for (0..600) |i| {
        body[i * 2] = 0xC3;
        body[i * 2 + 1] = 0xA9;
    }
    const out = try excerptOf(alloc, &body, 400);
    defer alloc.free(out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    try testing.expect(out.len <= EXCERPT_MAX_BYTES + 8);
}

// ─── renderSearchResult ─────────────────────────────────────────────────

test "renderSearchResult carries id + excerpt on every row and reports the pre-page total" {
    const alloc = testing.allocator;
    const res = try matchQuery(alloc, &test_rows, "", .{});
    defer alloc.free(res.hits);

    const out = try renderSearchResult(alloc, pageSlice(res.hits, 0, 2), .{
        .total = res.hits.len,
        .offset = 0,
        .limit = 2,
        .query = "",
        .mode = .all,
        .warning = "",
        .include_content = false,
    });
    defer alloc.free(out);

    const parsed = try parseRendered(alloc, out);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.value.count);
    try testing.expectEqual(@as(usize, 4), parsed.value.total);
    try testing.expect(parsed.value.truncated);
    try testing.expectEqual(@as(usize, 2), parsed.value.next_offset.?);
    try testing.expectEqualStrings("all", parsed.value.pattern_mode);
    try testing.expect(parsed.value.pattern_warning == null);
    try testing.expectEqual(@as(usize, 2), parsed.value.documents.len);
    // Rows arrive in store order (test_rows is doc_1..doc_4), so the first
    // page is doc_1 and doc_2 — not "the last two".
    try testing.expectEqualStrings("doc_1", parsed.value.documents[0].id);
    try testing.expect(parsed.value.documents[0].content == null);
    // The hint names the exact continuing offset.
    try testing.expect(std.mem.indexOf(u8, parsed.value.hint, "offset=2") != null);
}

test "renderSearchResult: content is opt-in and absent means NOT REQUESTED" {
    const alloc = testing.allocator;
    const res = try matchQuery(alloc, &test_rows, "budget", .{});
    defer alloc.free(res.hits);

    const with = try renderSearchResult(alloc, res.hits, .{
        .total = res.hits.len,
        .offset = 0,
        .limit = 20,
        .query = "budget",
        .mode = .regex,
        .warning = "",
        .include_content = true,
    });
    defer alloc.free(with);
    const p_with = try parseRendered(alloc, with);
    defer p_with.deinit();
    try testing.expectEqualStrings(
        "We agreed to LAUNCH in October.\nBudget: $4k\n",
        p_with.value.documents[0].content.?,
    );

    const without = try renderSearchResult(alloc, res.hits, .{
        .total = res.hits.len,
        .offset = 0,
        .limit = 20,
        .query = "budget",
        .mode = .regex,
        .warning = "",
        .include_content = false,
    });
    defer alloc.free(without);
    const p_without = try parseRendered(alloc, without);
    defer p_without.deinit();
    try testing.expect(p_without.value.documents[0].content == null);
    // The excerpt still shows the hit — that is its job — but it is bounded,
    // so a 4 MiB body never rides along inside the excerpt.
    const ex = p_without.value.documents[0].excerpt;
    try testing.expect(std.mem.indexOf(u8, ex, "Budget") != null);
    try testing.expect(ex.len <= EXCERPT_MAX_BYTES + 8);
}

test "renderSearchResult on the last page is not truncated and points at the write tools" {
    const alloc = testing.allocator;
    const res = try matchQuery(alloc, &test_rows, "", .{});
    defer alloc.free(res.hits);

    const out = try renderSearchResult(alloc, pageSlice(res.hits, 3, 20), .{
        .total = res.hits.len,
        .offset = 3,
        .limit = 20,
        .query = "",
        .mode = .all,
        .warning = "",
        .include_content = false,
    });
    defer alloc.free(out);

    const parsed = try parseRendered(alloc, out);
    defer parsed.deinit();
    try testing.expect(!parsed.value.truncated);
    try testing.expect(parsed.value.next_offset == null);
    try testing.expect(std.mem.indexOf(u8, parsed.value.hint, "edit_document") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.value.hint, "delete_document") != null);
}

test "renderSearchResult surfaces a pattern_warning verbatim" {
    const alloc = testing.allocator;
    const res = try matchQuery(alloc, &test_rows, "relea(", .{});
    defer alloc.free(res.hits);

    const out = try renderSearchResult(alloc, res.hits, .{
        .total = res.hits.len,
        .offset = 0,
        .limit = 20,
        .query = "relea(",
        .mode = res.mode,
        .warning = res.warning,
        .include_content = false,
    });
    defer alloc.free(out);

    const parsed = try parseRendered(alloc, out);
    defer parsed.deinit();
    try testing.expectEqualStrings("literal_fallback", parsed.value.pattern_mode);
    try testing.expect(parsed.value.pattern_warning != null);
}

test "renderSearchResult: an empty result set is still a well-formed envelope" {
    const alloc = testing.allocator;
    const res = try matchQuery(alloc, &test_rows, "zzz-nothing", .{});
    defer alloc.free(res.hits);

    const out = try renderSearchResult(alloc, res.hits, .{
        .total = 0,
        .offset = 0,
        .limit = 20,
        .query = "zzz-nothing",
        .mode = .regex,
        .warning = "",
        .include_content = false,
    });
    defer alloc.free(out);

    const parsed = try parseRendered(alloc, out);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.count);
    try testing.expectEqual(@as(usize, 0), parsed.value.total);
    try testing.expect(!parsed.value.truncated);
    try testing.expect(parsed.value.next_offset == null);
}

test "renderSearchResult: a title hit excerpts the title, a body hit excerpts the body" {
    const alloc = testing.allocator;
    const res = try matchQuery(alloc, &test_rows, "zebra|plan", .{});
    defer alloc.free(res.hits);

    const out = try renderSearchResult(alloc, res.hits, .{
        .total = res.hits.len,
        .offset = 0,
        .limit = 20,
        .query = "zebra|plan",
        .mode = .regex,
        .warning = "",
        .include_content = false,
    });
    defer alloc.free(out);

    const parsed = try parseRendered(alloc, out);
    defer parsed.deinit();
    for (parsed.value.documents) |r| {
        if (std.mem.eql(u8, r.id, "doc_3")) {
            try testing.expectEqualStrings("Zebra crossing TODO", r.excerpt);
        } else if (std.mem.eql(u8, r.id, "doc_1")) {
            try testing.expect(std.mem.indexOf(u8, r.excerpt, "Release plan") != null);
        }
    }
}

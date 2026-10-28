//! Storage layer for the `save_memory` + `load_memory` agent tools.
//! Append-only: every `saveMemory` call inserts a NEW row with a fresh
//! `mem_<16-hex>` id and `CURRENT_TIMESTAMP` timestamps.

const std = @import("std");
const test_db = @import("pabrikcore").test_db;
const builtin = @import("builtin");
const sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;
const dialect = @import("pabrikcore").dialect;
const migration = @import("../migrations/migration.zig");
const llm_history = @import("llm_history.zig");

/// One row in `agent_memories`. All string fields are allocator-owned and
/// must be freed by the caller — use `freeMemoryRow` for a single row or
/// `freeMemoryRows` for a slice.
pub const MemoryRow = struct {
    id: []const u8,
    content: []const u8,
    tags: []const u8,
    /// Owning workspace (Migration 095). `''` = the "no workspace"
    /// bucket. The exec layer echoes this back to the LLM so a scoped
    /// tool result is never mistaken for a global one.
    workspace_id: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// One FTS5 search hit. `snippet` is the FTS5 10-token preview with `[match]`
/// markers around matched words.
pub const MemoryHit = struct {
    id: []const u8,
    tags: []const u8,
    snippet: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    total_count: u32,

    pub fn deinit(self: *const MemoryHit, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.tags);
        allocator.free(self.snippet);
        if (self.created_at.len > 0) allocator.free(self.created_at);
        if (self.updated_at.len > 0) allocator.free(self.updated_at);
    }
};

/// Arguments for `saveMemory`. Append-only: the caller supplies content
/// + tags; the id and both timestamps are always generated fresh.
pub const SaveMemoryArgs = struct {
    /// The note body. 1 KiB – 1 MiB. Empty string → `error.InvalidContent`.
    content: []const u8,
    /// Optional tags. Each tag is a non-empty string. Stored as
    /// `||`-joined (matches the project's `tags` / `image_urls` convention
    /// — see Migration 067 / 069).
    tags: []const []const u8,
    /// Owning workspace (Migration 095). Empty string = the "no
    /// workspace" bucket, written via the column DEFAULT so an empty
    /// bind never lands as SQL NULL.
    workspace_id: []const u8 = "",
};

/// Hard cap on the size of a single memory. 1 MiB is well above any
/// plausible note ("the user's preferred model is X" is ~50 bytes) and
/// prevents a runaway agent from filling the DB.
pub const MAX_CONTENT_BYTES: usize = 1 << 20; // 1 MiB

/// Save a memory. ALWAYS inserts a new row with a fresh `mem_<16-hex>` id and
/// `CURRENT_TIMESTAMP` for both `created_at` and `updated_at`.
pub fn saveMemory(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: SaveMemoryArgs,
) !MemoryRow {
    if (args.content.len == 0) return error.InvalidContent;
    if (args.content.len > MAX_CONTENT_BYTES) return error.ContentTooLarge;

    // Every save mints a fresh id — append-only, never overwrite.
    const id = try generateMemoryId(allocator);
    defer allocator.free(id);

    // Plain INSERT. The `agent_memories_ai` trigger keeps the FTS5 index in
    // sync.
    const tags_str: ?[]u8 = if (args.tags.len == 0) null else try joinTags(allocator, args.tags);
    defer if (tags_str) |t| allocator.free(t);

    var insert_sql: std.ArrayList(u8) = .empty;
    defer insert_sql.deinit(allocator);
    var binds: std.ArrayList([]const u8) = .empty;
    defer binds.deinit(allocator);

    try insert_sql.appendSlice(allocator, "INSERT INTO agent_memories (id, content");
    try binds.append(allocator, id);
    try binds.append(allocator, args.content);

    if (args.workspace_id.len > 0) {
        try insert_sql.appendSlice(allocator, ", workspace_id");
        try binds.append(allocator, args.workspace_id);
    }
    if (tags_str) |t| {
        try insert_sql.appendSlice(allocator, ", tags");
        try binds.append(allocator, t);
    }

    try insert_sql.appendSlice(allocator, ", created_at, updated_at) VALUES (?, ?");
    if (args.workspace_id.len > 0) try insert_sql.appendSlice(allocator, ", ?");
    if (tags_str != null) try insert_sql.appendSlice(allocator, ", ?");
    try insert_sql.appendSlice(allocator, ", CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)");

    try db.exec(allocator, insert_sql.items, binds.items);

    // Read the row back so the caller sees the canonical timestamps.
    // Scoped to the workspace we just stamped, so this read is the same
    // read a `load_memory {id}` from that workspace would perform.
    const row = (try getMemoryById(allocator, db, id, args.workspace_id)) orelse return error.RowNotFoundAfterInsert;
    return row;
}

/// Look up a memory by id, scoped to `workspace_id`.
pub fn getMemoryById(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    workspace_id: []const u8,
) !?MemoryRow {
    var created_buf: [128]u8 = undefined;
    var updated_buf: [128]u8 = undefined;
    const created_expr = try dialect.timestampText(&created_buf, "created_at");
    const updated_expr = try dialect.timestampText(&updated_buf, "updated_at");
    const select = try std.fmt.allocPrint(
        allocator,
        "SELECT id, content, tags, COALESCE(CAST(workspace_id AS TEXT), ''), COALESCE({s}, ''), COALESCE({s}, '') " ++
            "FROM agent_memories WHERE id = ? AND COALESCE(CAST(workspace_id AS TEXT), '') = COALESCE(CAST(? AS TEXT), '')",
        .{ created_expr, updated_expr },
    );
    defer allocator.free(select);
    var q = try db.query(allocator, select, &.{ id, workspace_id });
    defer q.deinit();

    const row = (try q.next()) orelse return null;
    defer row.deinit(allocator);

    return MemoryRow{
        .id = try allocator.dupe(u8, row.values[0]),
        .content = try allocator.dupe(u8, row.values[1]),
        .tags = try allocator.dupe(u8, row.values[2]),
        .workspace_id = try allocator.dupe(u8, row.values[3]),
        .created_at = try allocator.dupe(u8, row.values[4]),
        .updated_at = try allocator.dupe(u8, row.values[5]),
    };
}

/// Free a single MemoryRow's owned strings.
pub fn freeMemoryRow(allocator: std.mem.Allocator, row: MemoryRow) void {
    allocator.free(row.id);
    allocator.free(row.content);
    allocator.free(row.tags);
    if (row.workspace_id.len > 0) allocator.free(row.workspace_id);
    if (row.created_at.len > 0) allocator.free(row.created_at);
    if (row.updated_at.len > 0) allocator.free(row.updated_at);
}

/// Free a slice of MemoryRow. Each row's strings are freed by
/// `freeMemoryRow`; the slice itself is freed last.
pub fn freeMemoryRows(allocator: std.mem.Allocator, rows: []MemoryRow) void {
    for (rows) |row| freeMemoryRow(allocator, row);
    allocator.free(rows);
}

/// Free a slice of MemoryHit. Each hit's strings are freed by
/// `MemoryHit.deinit`; the slice itself is freed last.
pub fn freeMemoryHits(allocator: std.mem.Allocator, hits: []MemoryHit) void {
    for (hits) |h| {
        var copy = h;
        copy.deinit(allocator);
    }
    allocator.free(hits);
}

/// Options for `loadMemoriesByFts`.
pub const LoadOptions = struct {
    /// FTS5 phrase search. Must be non-empty.
    query: []const u8,
    /// AND filter: every tag must be present in the row's tags
    /// (substring match — `LIKE '%tag%'`). Empty array = no filter.
    tags: []const []const u8,
    /// Max rows to return. Caller caps at a sane upper bound (50 in
    /// the tool layer).
    limit: u32,
    /// Skip the first N rows of the ranked result set. 0 = start from
    /// the top.
    offset: u32,
    /// Owning workspace (Migration 095).
    workspace_id: []const u8,
};

/// FTS5 phrase search over `agent_memories_fts`. Returns ranked hits with
/// `snippet(..., 0, '[', ']', '…', 10)` (10-token window with `[match]`
/// markers around matches).
pub fn loadMemoriesByFts(
    allocator: std.mem.Allocator,
    db: *database.Db,
    opts: LoadOptions,
) ![]MemoryHit {
    if (opts.query.len == 0) return allocator.alloc(MemoryHit, 0);

    // Sanitize the query — same tokenizer the workspace history search uses.
    const sanitized_query = try llm_history.searchQueryText(allocator, opts.query);
    defer allocator.free(sanitized_query);
    // Empty after sanitization (query was all FTS5 operators) — bail
    // before FTS5 sees `MATCH ''` and throws "empty query".
    if (sanitized_query.len == 0) return allocator.alloc(MemoryHit, 0);

    // Build the SQL.
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);

    // The subquery is the only engine-specific part: sqlite reads the FTS5
    // index, postgres ranks `to_tsvector` and headlines it. Both wrap it
    // because sqlite's virtual tables reject `COUNT(*) OVER ()` directly.
    if (dialect.is_postgres) {
        try sql.appendSlice(allocator,
            \\SELECT
            \\    id, tags, snippet, created_at, updated_at,
            \\    COUNT(*) OVER () AS total_count
            \\FROM (
            \\    SELECT
            \\        m.id AS id, m.tags AS tags,
            \\        ts_headline('simple'::regconfig, m.content, q.tsq,
            \\                    'StartSel=[, StopSel=], MaxWords=10, MinWords=3') AS snippet,
            \\        COALESCE(to_char(m.created_at, 'YYYY-MM-DD HH24:MI:SS'), '') AS created_at,
            \\        COALESCE(to_char(m.updated_at, 'YYYY-MM-DD HH24:MI:SS'), '') AS updated_at,
            \\        -ts_rank(
            ++ comptime dialect.tsVectorText("COALESCE(CAST(m.content AS TEXT), '') || ' ' || COALESCE(CAST(m.tags AS TEXT), '')") ++
            \\, q.tsq) AS fts_rank
            \\    FROM agent_memories m, to_tsquery('simple'::regconfig, ?) AS q(tsq)
            \\    WHERE
            ++ " " ++ dialect.tsVectorText("COALESCE(CAST(m.content AS TEXT), '') || ' ' || COALESCE(CAST(m.tags AS TEXT), '')") ++
            \\ @@ q.tsq
            \\      AND COALESCE(CAST(m.workspace_id AS TEXT), '') = COALESCE(CAST(? AS TEXT), '')
        );
    } else {
        try sql.appendSlice(allocator,
            \\SELECT
            \\    id, tags, snippet, created_at, updated_at,
            \\    COUNT(*) OVER () AS total_count
            \\FROM (
            \\    SELECT
            \\        m.id AS id, m.tags AS tags,
            \\        snippet(agent_memories_fts, 0, '[', ']', '...', 10) AS snippet,
            \\        COALESCE(CAST(m.created_at AS TEXT), '') AS created_at,
            \\        COALESCE(CAST(m.updated_at AS TEXT), '') AS updated_at,
            \\        rank AS fts_rank
            \\    FROM agent_memories_fts
            \\    JOIN agent_memories m ON m.rowid = agent_memories_fts.rowid
            \\    WHERE agent_memories_fts MATCH ?
            \\      AND COALESCE(CAST(m.workspace_id AS TEXT), '') = COALESCE(CAST(? AS TEXT), '')
        );
    }

    var binds: std.ArrayList([]const u8) = .empty;
    var tag_patterns: std.ArrayList([]u8) = .empty;
    defer {
        for (tag_patterns.items) |p| allocator.free(p);
        tag_patterns.deinit(allocator);
        binds.deinit(allocator);
    }
    try binds.append(allocator, sanitized_query);
    // The workspace scope sits INSIDE the subquery, not in the outer wrapper:
    // `COUNT(*) OVER ()` is evaluated over the subquery's rows, so a filter
    // applied outside would report the GLOBAL match count next to a
    try binds.append(allocator, opts.workspace_id);

    // AND-filter by tags. Each tag adds a `LIKE '%tag%'` clause to the WHERE.
    for (opts.tags) |tag| {
        if (tag.len == 0) continue;
        try sql.appendSlice(allocator, " AND m.tags LIKE ?");
        // The pattern is heap-owned — free AFTER `db.query` reads it.
        // If we `defer free` inside this loop iteration, the defer
        // fires before `db.query` runs and the bind slice dangles.
        const pattern = try std.fmt.allocPrint(allocator, "%{s}%", .{tag});
        try tag_patterns.append(allocator, pattern);
        try binds.append(allocator, pattern);
    }

    // Close the subquery, then ORDER BY / LIMIT / OFFSET on the outer query.
    try sql.appendSlice(allocator, ") AS hits ORDER BY fts_rank");
    try sql.print(allocator, " LIMIT {d}", .{opts.limit});
    if (opts.offset > 0) {
        try sql.print(allocator, " OFFSET {d}", .{opts.offset});
    }

    var rows = db.query(allocator, sql.items, binds.items) catch |err| {
        return err;
    };
    defer rows.deinit();

    var hits: std.ArrayList(MemoryHit) = .empty;
    errdefer {
        for (hits.items) |h| {
            var copy = h;
            copy.deinit(allocator);
        }
        hits.deinit(allocator);
    }

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const total_count: u32 = std.fmt.parseInt(u32, row.values[5], 10) catch 0;
        try hits.append(allocator, MemoryHit{
            .id = try allocator.dupe(u8, row.values[0]),
            .tags = try allocator.dupe(u8, row.values[1]),
            .snippet = try allocator.dupe(u8, row.values[2]),
            .created_at = try allocator.dupe(u8, row.values[3]),
            .updated_at = try allocator.dupe(u8, row.values[4]),
            .total_count = total_count,
        });
    }

    return try hits.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Generate a fresh `mem_<16-hex>` id.
fn generateMemoryId(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [8]u8 = undefined;
    switch (builtin.os.tag) {
        .linux => {
            var filled: usize = 0;
            while (filled < 8) {
                const slice = bytes[filled..];
                const got = std.os.linux.getrandom(slice.ptr, slice.len, 0);
                if (got <= 0) return error.RandomFailed;
                filled += @intCast(got);
            }
        },
        .macos, .ios, .tvos, .watchos => {
            // arc4random_buf is declared in std.c private on Apple targets.
            // No loop needed — it always fills in one call.
            std.c.arc4random_buf(&bytes, bytes.len);
        },
        .windows => {
            // BCrypt.dll → BCRYPT_USE_SYSTEM_PREFERRED_RNG (0x00000002).
            // The docs guarantee it is suitable for cryptographic use and is
            // seeded from the OS entropy pool at boot.
            const status = bcrypt.BCryptGenRandom(
                null,
                &bytes,
                @intCast(bytes.len),
                0x00000002,
            );
            if (status != 0) return error.RandomFailed;
        },
        else => return error.UnsupportedPlatform,
    }

    // Format as 16 hex chars.
    var hex: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        hex[i * 2] = hex_chars[(b >> 4) & 0x0F];
        hex[i * 2 + 1] = hex_chars[b & 0x0F];
    }

    const out = try allocator.alloc(u8, 4 + 16);
    @memcpy(out[0..4], "mem_");
    @memcpy(out[4..][0..16], &hex);
    return out;
}

/// Join a slice of tags into a `||`-delimited string. Empty tags are
/// skipped (defensive — the tool layer should already filter).
fn joinTags(allocator: std.mem.Allocator, tags: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (tags) |t| {
        if (t.len == 0) continue;
        total += t.len + 2; // t + "||"
    }
    if (total >= 2) total -= 2; // trim trailing "||"

    const out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    var first = true;
    for (tags) |t| {
        if (t.len == 0) continue;
        if (!first) {
            @memcpy(out[pos..][0..2], "||");
            pos += 2;
        }
        @memcpy(out[pos..][0..t.len], t);
        pos += t.len;
        first = false;
    }
    return out;
}

/// Windows bcrypt.dll bindings.
const bcrypt = struct {
    extern "bcrypt" fn BCryptGenRandom(
        hAlgorithm: ?*const anyopaque,
        pbBuffer: [*]u8,
        cbBuffer: c_ulong,
        dwFlags: c_ulong,
    ) callconv(.c) c_long;
};

// ---------------------------------------------------------------------------
// Inline tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "generateMemoryId produces mem_<16-hex>" {
    const alloc = testing.allocator;
    const id = try generateMemoryId(alloc);
    defer alloc.free(id);

    try testing.expectEqual(@as(usize, 4 + 16), id.len);
    try testing.expect(std.mem.startsWith(u8, id, "mem_"));
    // Verify the 16 chars after the prefix are hex.
    for (id[4..]) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(is_hex);
    }
}

test "joinTags joins with || and skips empty tags" {
    const alloc = testing.allocator;

    // Empty slice → empty string.
    {
        const out = try joinTags(alloc, &.{});
        defer alloc.free(out);
        try testing.expectEqualStrings("", out);
    }

    // Single tag.
    {
        const out = try joinTags(alloc, &.{"foo"});
        defer alloc.free(out);
        try testing.expectEqualStrings("foo", out);
    }

    // Multiple tags.
    {
        const out = try joinTags(alloc, &.{ "foo", "bar", "baz" });
        defer alloc.free(out);
        try testing.expectEqualStrings("foo||bar||baz", out);
    }

    // Empty tags are skipped.
    {
        const out = try joinTags(alloc, &.{ "foo", "", "bar" });
        defer alloc.free(out);
        try testing.expectEqualStrings("foo||bar", out);
    }
}

// ─── Inline tests (formerly agent_memories_test.zig) ─────────────────────
// Behavioural tests for saveMemory / loadMemoriesByFts / getMemoryById.

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

test "saveMemory: inserts a new row with auto-generated mem_<16-hex> id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try saveMemory(alloc, &ctx.db, .{
        .content = "the user's preferred LLM is claude-sonnet-4-5",
        .tags = &.{ "preferences", "user" },
    });
    defer freeMemoryRow(alloc, row);

    // Auto-generated id matches the `mem_<16-hex>` shape (mem_ + 16 hex chars).
    try testing.expect(row.id.len == 20); // 4 ("mem_") + 16 (hex)
    try testing.expect(std.mem.startsWith(u8, row.id, "mem_"));
    try testing.expectEqualStrings("the user's preferred LLM is claude-sonnet-4-5", row.content);
    // Tags stored as ||-joined string (the project convention).
    try testing.expectEqualStrings("preferences||user", row.tags);
    // Timestamps are populated (non-empty).
    try testing.expect(row.created_at.len > 0);
    try testing.expect(row.updated_at.len > 0);

    // Verify the row is actually in the DB.
    var q = try ctx.db.query(alloc, "SELECT content, tags FROM agent_memories WHERE id = ?", &.{row.id});
    defer q.deinit();
    const db_row = (try q.next()) orelse return error.RowNotInserted;
    defer db_row.deinit(alloc);
    try testing.expectEqualStrings("the user's preferred LLM is claude-sonnet-4-5", db_row.values[0]);
    try testing.expectEqualStrings("preferences||user", db_row.values[1]);
}

test "saveMemory: appends a new row on every call (never overwrites)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // First insert.
    const first = try saveMemory(alloc, &ctx.db, .{
        .content = "original content",
        .tags = &.{"preferences"},
    });
    defer freeMemoryRow(alloc, first);

    // Saving the same content again appends a SECOND row (append-only:
    // corrections supersede by recency, they never replace in place).
    const second = try saveMemory(alloc, &ctx.db, .{
        .content = "original content",
        .tags = &.{"preferences"},
    });
    defer freeMemoryRow(alloc, second);

    // Different auto-generated ids.
    try testing.expect(!std.mem.eql(u8, first.id, second.id));
    try testing.expect(std.mem.startsWith(u8, second.id, "mem_"));
    // Same content stored twice.
    try testing.expectEqualStrings(first.content, second.content);

    // Verify TWO rows in the DB (append, not UPSERT).
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_memories WHERE content = ?", &.{"original content"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}

test "saveMemory: empty content returns InvalidContent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = saveMemory(alloc, &ctx.db, .{
        .content = "",
        .tags = &.{},
    });
    try testing.expectError(error.InvalidContent, result);
}

test "saveMemory: content > 1 MiB returns ContentTooLarge" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Allocate a 1 MiB + 1 byte buffer filled with 'x'.
    const oversize = alloc.alloc(u8, (1 << 20) + 1) catch @panic("alloc failed for the oversize agent-memories fixture");
    defer alloc.free(oversize);
    @memset(oversize, 'x');

    const result = saveMemory(alloc, &ctx.db, .{
        .content = oversize,
        .tags = &.{},
    });
    try testing.expectError(error.ContentTooLarge, result);
}

test "loadMemoriesByFts: returns ranked hits with snippets" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert 3 memories.
    const row1 = try saveMemory(alloc, &ctx.db, .{
        .content = "the user's preferred model is claude-sonnet for coding tasks",
        .tags = &.{"preferences"},
    });
    defer freeMemoryRow(alloc, row1);
    const row2 = try saveMemory(alloc, &ctx.db, .{
        .content = "the project's database is SQLite with FTS5 enabled",
        .tags = &.{"project"},
    });
    defer freeMemoryRow(alloc, row2);
    const row3 = try saveMemory(alloc, &ctx.db, .{
        .content = "claude-sonnet is also the user's preferred writing model",
        .tags = &.{"preferences"},
    });
    defer freeMemoryRow(alloc, row3);

    // Search for "preferred" — should return 2 hits (coding + writing).
    const hits = try loadMemoriesByFts(alloc, &ctx.db, .{
        .query = "preferred",
        .tags = &.{},
        .limit = 10,
        .offset = 0,
        .workspace_id = "",
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqual(@as(u32, 2), hits[0].total_count);

    // Every hit has a non-empty snippet that contains [match] markers
    // (the FTS5 snippet() convention).
    for (hits) |h| {
        try testing.expect(h.snippet.len > 0);
        try testing.expect(std.mem.indexOf(u8, h.snippet, "[") != null);
        try testing.expect(std.mem.indexOf(u8, h.snippet, "]") != null);
    }
}

test "loadMemoriesByFts: AND-filters by tags" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row1 = try saveMemory(alloc, &ctx.db, .{
        .content = "memory one with model preference",
        .tags = &.{ "preferences", "user" },
    });
    defer freeMemoryRow(alloc, row1);
    const row2 = try saveMemory(alloc, &ctx.db, .{
        .content = "memory two with project context",
        .tags = &.{ "preferences", "project" },
    });
    defer freeMemoryRow(alloc, row2);
    const row3 = try saveMemory(alloc, &ctx.db, .{
        .content = "memory three with project context",
        .tags = &.{"project"},
    });
    defer freeMemoryRow(alloc, row3);

    // Search for "context" + filter by tags=["project"] → should return
    // row2 + row3 (both have "project" tag) but NOT row1
    // (only has "preferences" + "user").
    const hits = try loadMemoriesByFts(alloc, &ctx.db, .{
        .query = "context",
        .tags = &.{"project"},
        .limit = 10,
        .offset = 0,
        .workspace_id = "",
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqual(@as(u32, 2), hits[0].total_count);

    // AND filter — tags=["preferences", "project"] → only row2 has BOTH.
    const hits2 = try loadMemoriesByFts(alloc, &ctx.db, .{
        .query = "context",
        .tags = &.{ "preferences", "project" },
        .limit = 10,
        .offset = 0,
        .workspace_id = "",
    });
    defer {
        for (hits2) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits2);
    }

    try testing.expectEqual(@as(usize, 1), hits2.len);
    try testing.expectEqualStrings(row2.id, hits2[0].id);
}

test "loadMemoriesByFts: paginates via limit + offset and reports total_count" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert 15 memories, each with a common word "match" (ids auto-generated).
    var i: u32 = 0;
    while (i < 15) : (i += 1) {
        const content = std.fmt.allocPrint(alloc, "match row number {d}", .{i}) catch @panic("allocPrint failed for the agent-memories match row");
        defer alloc.free(content);
        const row = try saveMemory(alloc, &ctx.db, .{
            .content = content,
            .tags = &.{},
        });
        freeMemoryRow(alloc, row);
    }

    // Page 1: limit=10 offset=0 → 10 rows, total=15.
    {
        const hits = try loadMemoriesByFts(alloc, &ctx.db, .{
            .query = "match",
            .tags = &.{},
            .limit = 10,
            .offset = 0,
            .workspace_id = "",
        });
        defer {
            for (hits) |h| {
                var copy = h;
                copy.deinit(alloc);
            }
            alloc.free(hits);
        }
        try testing.expectEqual(@as(usize, 10), hits.len);
        try testing.expectEqual(@as(u32, 15), hits[0].total_count);
    }

    // Page 2: limit=10 offset=10 → 5 rows, total=15.
    {
        const hits = try loadMemoriesByFts(alloc, &ctx.db, .{
            .query = "match",
            .tags = &.{},
            .limit = 10,
            .offset = 10,
            .workspace_id = "",
        });
        defer {
            for (hits) |h| {
                var copy = h;
                copy.deinit(alloc);
            }
            alloc.free(hits);
        }
        try testing.expectEqual(@as(usize, 5), hits.len);
        try testing.expectEqual(@as(u32, 15), hits[0].total_count);
    }

    // Page 3: limit=10 offset=20 → 0 rows, total=15 reported elsewhere. (We
    // can't read hits[0].total_count when hits.len==0 — would be an
    // out-of-bounds access.
    {
        const hits = try loadMemoriesByFts(alloc, &ctx.db, .{
            .query = "match",
            .tags = &.{},
            .limit = 10,
            .offset = 20,
            .workspace_id = "",
        });
        defer {
            for (hits) |h| {
                var copy = h;
                copy.deinit(alloc);
            }
            alloc.free(hits);
        }
        try testing.expectEqual(@as(usize, 0), hits.len);
    }
}

test "getMemoryById: returns the row when id exists, null otherwise" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row1 = try saveMemory(alloc, &ctx.db, .{
        .content = "the test memory content",
        .tags = &.{"test"},
    });
    defer freeMemoryRow(alloc, row1);

    // Existing id → returns the row.
    const found = (try getMemoryById(alloc, &ctx.db, row1.id, "")) orelse return error.GetReturnedNull;
    defer freeMemoryRow(alloc, found);
    try testing.expectEqualStrings(row1.id, found.id);
    try testing.expectEqualStrings("the test memory content", found.content);
    try testing.expectEqualStrings("test", found.tags);

    // Missing id → returns null (not error).
    const missing = try getMemoryById(alloc, &ctx.db, "no-such-id", "");
    try testing.expect(missing == null);
}

test "saveMemory: stamps workspace_id, and an empty one lands in the '' bucket" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const scoped = try saveMemory(alloc, &ctx.db, .{
        .content = "scoped note",
        .tags = &.{"test"},
        .workspace_id = "ws_alpha",
    });
    defer freeMemoryRow(alloc, scoped);
    try testing.expectEqualStrings("ws_alpha", scoped.workspace_id);

    // Empty workspace_id must NOT become SQL NULL — the column is
    // NOT NULL, and binding a zero-length slice lands as NULL. It goes
    // in through the column DEFAULT instead.
    const unscoped = try saveMemory(alloc, &ctx.db, .{
        .content = "workspace-less note",
        .tags = &.{"test"},
    });
    defer freeMemoryRow(alloc, unscoped);
    try testing.expectEqualStrings("", unscoped.workspace_id);

    // `rowid` is sqlite's; the question is what each row's workspace_id IS, so
    // ask per row instead of relying on insertion order.
    var q = try ctx.db.query(alloc,
        \\SELECT id, workspace_id FROM agent_memories WHERE id IN (?, ?)
    , &.{ scoped.id, unscoped.id });
    defer q.deinit();
    var seen_scoped = false;
    var seen_unscoped = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], scoped.id)) {
            try testing.expectEqualStrings("ws_alpha", row.values[1]);
            seen_scoped = true;
        } else {
            try testing.expectEqualStrings("", row.values[1]);
            seen_unscoped = true;
        }
    }
    try testing.expect(seen_scoped);
    try testing.expect(seen_unscoped);
}

test "loadMemoriesByFts: never returns another workspace's rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Two workspaces each hold a note matching the SAME query term.
    // Before Migration 095 both came back from either workspace.
    const alpha = try saveMemory(alloc, &ctx.db, .{
        .content = "deployment uses rsync for releases",
        .tags = &.{"ops"},
        .workspace_id = "ws_alpha",
    });
    defer freeMemoryRow(alloc, alpha);
    const beta = try saveMemory(alloc, &ctx.db, .{
        .content = "deployment uses ansible for releases",
        .tags = &.{"ops"},
        .workspace_id = "ws_beta",
    });
    defer freeMemoryRow(alloc, beta);

    const alpha_hits = try loadMemoriesByFts(alloc, &ctx.db, .{
        .query = "deployment",
        .tags = &.{},
        .limit = 10,
        .offset = 0,
        .workspace_id = "ws_alpha",
    });
    defer {
        for (alpha_hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(alpha_hits);
    }
    try testing.expectEqual(@as(usize, 1), alpha_hits.len);
    try testing.expectEqualStrings(alpha.id, alpha_hits[0].id);
    // total_count must be the SCOPED count. If the filter sat outside
    // the subquery this would read 2 and the agent would page with an
    // offset derived from a row it can never see.
    try testing.expectEqual(@as(u32, 1), alpha_hits[0].total_count);

    const beta_hits = try loadMemoriesByFts(alloc, &ctx.db, .{
        .query = "deployment",
        .tags = &.{},
        .limit = 10,
        .offset = 0,
        .workspace_id = "ws_beta",
    });
    defer {
        for (beta_hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(beta_hits);
    }
    try testing.expectEqual(@as(usize, 1), beta_hits.len);
    try testing.expectEqualStrings(beta.id, beta_hits[0].id);

    // A workspace with no rows of its own sees nothing, even though the
    // term matches two rows globally.
    const gamma_hits = try loadMemoriesByFts(alloc, &ctx.db, .{
        .query = "deployment",
        .tags = &.{},
        .limit = 10,
        .offset = 0,
        .workspace_id = "ws_gamma",
    });
    defer alloc.free(gamma_hits);
    try testing.expectEqual(@as(usize, 0), gamma_hits.len);
}

test "getMemoryById: a row owned by another workspace is indistinguishable from a missing one" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const alpha = try saveMemory(alloc, &ctx.db, .{
        .content = "alpha-only secret note body",
        .tags = &.{"test"},
        .workspace_id = "ws_alpha",
    });
    defer freeMemoryRow(alloc, alpha);

    // Owning workspace reads it.
    const own = (try getMemoryById(alloc, &ctx.db, alpha.id, "ws_alpha")) orelse return error.GetReturnedNull;
    defer freeMemoryRow(alloc, own);
    try testing.expectEqualStrings("alpha-only secret note body", own.content);

    // Another workspace gets null — NOT the 1 MiB body. The by-id path
    // is the one that would leak most (full content, no snippet cap), so
    // it is the one that must be scoped.
    const stolen = try getMemoryById(alloc, &ctx.db, alpha.id, "ws_beta");
    try testing.expect(stolen == null);

    // The '' bucket cannot read a workspace's rows either.
    const legacy = try getMemoryById(alloc, &ctx.db, alpha.id, "");
    try testing.expect(legacy == null);
}

test "legacy rows (pre-Migration-095, workspace_id '') are invisible to workspace sessions" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // A row written the old way — no workspace at all.
    const legacy = try saveMemory(alloc, &ctx.db, .{
        .content = "a note from before workspaces scoped memory",
        .tags = &.{"legacy"},
    });
    defer freeMemoryRow(alloc, legacy);

    const ws_hits = try loadMemoriesByFts(alloc, &ctx.db, .{
        .query = "workspaces",
        .tags = &.{},
        .limit = 10,
        .offset = 0,
        .workspace_id = "ws_alpha",
    });
    defer alloc.free(ws_hits);
    try testing.expectEqual(@as(usize, 0), ws_hits.len);

    // Workspace-less sessions still share their own '' bucket.
    const legacy_hits = try loadMemoriesByFts(alloc, &ctx.db, .{
        .query = "workspaces",
        .tags = &.{},
        .limit = 10,
        .offset = 0,
        .workspace_id = "",
    });
    defer {
        for (legacy_hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(legacy_hits);
    }
    try testing.expectEqual(@as(usize, 1), legacy_hits.len);
    try testing.expectEqualStrings(legacy.id, legacy_hits[0].id);
}

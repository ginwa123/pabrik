const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");
const frontmatter = @import("../agentic_loop/skill_frontmatter.zig");

const Backend = common.Backend;
const helpers = @import("helpers");
const dialect = common.dialect;

/// Migration 119 — `skill_metadata`: one row per non-column frontmatter key,
/// so metadata is a table instead of a block every reader re-scans out of
/// `skills.content`. Promoted keys stay columns: one fact, one home.
pub const Migration119CreateSkillMetadata = struct {
    pub const version: u32 = 119;
    pub const name = "create_skill_metadata";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS skill_metadata (
            \\    id TEXT PRIMARY KEY,
            \\    skill_id TEXT NOT NULL,
            \\    key TEXT NOT NULL,
            \\    value TEXT NOT NULL DEFAULT '',
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    UNIQUE (skill_id, key),
            ++ comptime dialect.foreignKey("FOREIGN KEY (skill_id) REFERENCES skills(id) ON DELETE CASCADE") ++
            \\)
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_skill_metadata_key ON skill_metadata(key)
        , &[_][]const u8{});

        try backfill(db, allocator);
    }

    /// Stored skills keep their frontmatter inside `content`, so adding the
    /// table late loses nothing. A body with no fence inserts no row: that is
    /// a legal skill, not an error.
    fn backfill(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        var q = try db.query(allocator, "SELECT id, COALESCE(content, '') FROM skills", &[_][]const u8{});
        defer q.deinit();

        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        var index: usize = 0;
        while (try q.next()) |row| {
            defer row.deinit(allocator);
            var parsed = try frontmatter.parse(allocator, row.values[1]);
            defer parsed.deinit(allocator);
            if (!parsed.has_fence) continue;

            for (parsed.pairs) |pair| {
                const id = try std.fmt.allocPrint(
                    allocator,
                    "sm_{d}_{d}",
                    .{ helpers.unixTimestampNanos(), index },
                );
                defer allocator.free(id);
                index += 1;

                const insert = try std.fmt.allocPrint(
                    allocator,
                    \\{s} INTO skill_metadata (id, skill_id, key, value, created_at, updated_at)
                    \\VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP){s}
                , .{ dialect.insert_ignore_prefix, dialect.conflict_ignore });
                defer allocator.free(insert);
                try tx.exec(allocator, insert, &[_][]const u8{ id, row.values[0], pair.key, pair.value });
            }
        }

        try tx.commit();
    }
};

const testing = std.testing;
const migration = @import("migration.zig");

const TestCtx = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try migration.Migration102CreateSkills.up(&db, testing.allocator);
    return .{ .db = db, .threaded = threaded };
}

fn insertSkill(ctx: *TestCtx, id: []const u8, name: []const u8, content: []const u8) !void {
    try ctx.db.exec(testing.allocator,
        \\INSERT INTO skills (id, workspace_id, name, content) VALUES (?, 'ws_1', ?, ?)
    , &[_][]const u8{ id, name, content });
}

fn metadataValue(ctx: *TestCtx, skill_id: []const u8, key: []const u8) !?[]const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT value FROM skill_metadata WHERE skill_id = ? AND key = ?",
        &[_][]const u8{ skill_id, key },
    );
    defer q.deinit();
    const row = (try q.next()) orelse return null;
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

test "Migration119 backfills the metadata of skills that are already stored" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertSkill(&ctx, "sk_1", "pdf",
        \\---
        \\name: pdf
        \\description: Work with PDFs.
        \\origin: ECC
        \\tags: [workflow, documents]
        \\---
        \\Run scripts/convert.py.
    );

    try Migration119CreateSkillMetadata.up(&ctx.db, alloc);

    const origin = (try metadataValue(&ctx, "sk_1", "origin")) orelse return error.MissingOrigin;
    defer alloc.free(origin);
    try testing.expectEqualStrings("ECC", origin);

    const tags = (try metadataValue(&ctx, "sk_1", "tags")) orelse return error.MissingTags;
    defer alloc.free(tags);
    try testing.expectEqualStrings("[workflow, documents]", tags);

    // The promoted keys are columns, not rows: one fact, one home.
    try testing.expect(try metadataValue(&ctx, "sk_1", "name") == null);
    try testing.expect(try metadataValue(&ctx, "sk_1", "description") == null);
}

test "Migration119 leaves a skill with no frontmatter with no metadata rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertSkill(&ctx, "sk_2", "bare", "## When to Use\n\nNo fence at all.\n");

    try Migration119CreateSkillMetadata.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM skill_metadata WHERE skill_id = 'sk_2'", &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRows;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "Migration119 replaying does not duplicate a skill's metadata rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertSkill(&ctx, "sk_3", "pdf", "---\nname: pdf\norigin: ECC\n---\nbody\n");

    try Migration119CreateSkillMetadata.up(&ctx.db, alloc);
    try Migration119CreateSkillMetadata.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM skill_metadata WHERE skill_id = 'sk_3'", &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRows;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration119 is registered in allMigrations" {
    for (migration.allMigrations) |m| {
        if (m.version == Migration119CreateSkillMetadata.version) return;
    }
    return error.Migration119NotRegistered;
}

const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");
const frontmatter = @import("../agentic_loop/skill_frontmatter.zig");

const Backend = common.Backend;
const dropColumnIfExists = common.dropColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

/// Migration 141 — a skill row is its body. `name` and `description` are
/// frontmatter keys inside `content`, so their columns go: the values they
/// held move into the fence and into `skill_metadata` before the drop.
pub const Migration141ContractSkillNameDescription = struct {
    pub const version: u32 = 141;
    pub const name = "contract_skill_name_description";

    const table = "skills";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        const has_name = try dialect.columnExists(.{ .db = db }, allocator, table, "name");
        const has_description = try dialect.columnExists(.{ .db = db }, allocator, table, "description");
        if (!has_name and !has_description) return;

        try backfill(db, allocator, has_name, has_description);

        if (dialect.is_postgres) {
            try dropColumnIfExists(.{ .db = db }, allocator, table, "description");
            try dropColumnIfExists(.{ .db = db }, allocator, table, "name");
        } else {
            try rebuildWithoutIdentityColumns(db, allocator);
        }

        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_skills_workspace ON skills(workspace_id)", &[_][]const u8{});
    }

    fn selectSql(has_name: bool, has_description: bool) []const u8 {
        if (has_name and has_description) {
            return "SELECT id, COALESCE(CAST(name AS TEXT), ''), COALESCE(CAST(description AS TEXT), ''), " ++
                "COALESCE(CAST(content AS TEXT), '') FROM skills";
        }
        if (has_name) {
            return "SELECT id, COALESCE(CAST(name AS TEXT), ''), '', COALESCE(CAST(content AS TEXT), '') FROM skills";
        }
        return "SELECT id, '', COALESCE(CAST(description AS TEXT), ''), COALESCE(CAST(content AS TEXT), '') FROM skills";
    }

    fn backfill(db: *Backend, allocator: std.mem.Allocator, has_name: bool, has_description: bool) anyerror!void {
        var q = try db.query(allocator, selectSql(has_name, has_description), &[_][]const u8{});
        defer q.deinit();

        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        var index: usize = 0;
        while (try q.next()) |row| {
            defer row.deinit(allocator);

            const id = row.values[0];
            const stored_name = if (row.values[1].len > 0) row.values[1] else "";
            const column_description = row.values[2];
            const content = row.values[3];

            var parsed = try frontmatter.parse(allocator, content);
            defer parsed.deinit(allocator);

            const header_name = if (stored_name.len > 0) stored_name else parsed.header.name;
            const header_description = if (column_description.len > 0) column_description else parsed.header.description;

            const body_carries_identity = parsed.has_fence and
                std.mem.eql(u8, parsed.header.name, header_name) and
                (column_description.len == 0 or std.mem.eql(u8, parsed.header.description, column_description));

            if (!body_carries_identity) {
                const rendered = try frontmatter.render(
                    allocator,
                    .{ .name = header_name, .description = header_description },
                    parsed.pairs,
                    parsed.body,
                );
                defer allocator.free(rendered);
                try tx.exec(allocator, "UPDATE skills SET content = ? WHERE id = ?", &[_][]const u8{ rendered, id });
            }

            const keys = [_][]const u8{ "name", "description" };
            const values = [_][]const u8{ header_name, header_description };
            for (keys, values) |key, value| {
                const metadata_id = try std.fmt.allocPrint(allocator, "sm_{d}_{d}", .{ helpers.unixTimestampNanos(), index });
                defer allocator.free(metadata_id);
                index += 1;

                const insert = try std.fmt.allocPrint(allocator,
                    \\{s} INTO skill_metadata (id, skill_id, key, value, created_at, updated_at)
                    \\VALUES (?, ?, ?, COALESCE(NULLIF(?, ''), ''), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP){s}
                , .{ dialect.insert_ignore_prefix, dialect.conflict_ignore });
                defer allocator.free(insert);
                try tx.exec(allocator, insert, &[_][]const u8{ metadata_id, id, key, value });
            }
        }

        try tx.commit();
    }

    /// sqlite cannot drop a column a UNIQUE constraint names, so the table is
    /// rebuilt. Its children reference `skills(id)` by name, which the rename
    /// restores before anything reads them.
    fn rebuildWithoutIdentityColumns(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        var pragma = try db.queryRow(allocator, "PRAGMA foreign_keys", &[_][]const u8{});
        const foreign_keys_on = std.mem.eql(u8, pragma.values[0], "1");
        pragma.deinit(allocator);

        if (foreign_keys_on) try db.exec(allocator, "PRAGMA foreign_keys = OFF", &[_][]const u8{});
        defer restoreForeignKeys(db, allocator, foreign_keys_on);

        try db.exec(allocator, "DROP TABLE IF EXISTS skills_rebuilt", &[_][]const u8{});
        try db.exec(allocator,
            \\CREATE TABLE skills_rebuilt (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_id TEXT NOT NULL,
            \\    content TEXT NOT NULL DEFAULT '',
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    is_can_auto_improve INTEGER NOT NULL DEFAULT 1,
        ++ comptime dialect.foreignKey("FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE") ++
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            \\INSERT INTO skills_rebuilt (id, workspace_id, content, is_can_auto_improve, created_at, updated_at)
            \\SELECT id, workspace_id, content, is_can_auto_improve, created_at, updated_at FROM skills
        , &[_][]const u8{});
        try db.exec(allocator, "DROP TABLE skills", &[_][]const u8{});
        try db.exec(allocator, "ALTER TABLE skills_rebuilt RENAME TO skills", &[_][]const u8{});
    }

    fn restoreForeignKeys(db: *Backend, allocator: std.mem.Allocator, was_on: bool) void {
        if (!was_on) return;
        db.exec(allocator, "PRAGMA foreign_keys = ON", &[_][]const u8{}) catch {};
    }
};

const testing = std.testing;
const migration = @import("migration.zig");

const TestCtx = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc, "CREATE TABLE workspaces (id TEXT PRIMARY KEY)", &[_][]const u8{});
    try migration.Migration102CreateSkills.up(&db, alloc);
    try migration.Migration119CreateSkillMetadata.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

fn insertSkill(ctx: *TestCtx, id: []const u8, name: []const u8, description: []const u8, content: []const u8) !void {
    try ctx.db.exec(testing.allocator,
        \\INSERT INTO skills (id, workspace_id, name, description, content)
        \\VALUES (?, 'ws_1', ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''))
    , &[_][]const u8{ id, name, description, content });
}

fn columnNames(ctx: *TestCtx) ![]const []const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT name FROM " ++ comptime dialect.tableColumns("skills"), &[_][]const u8{});
    defer q.deinit();

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |c| alloc.free(c);
        out.deinit(alloc);
    }
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try out.append(alloc, try alloc.dupe(u8, row.values[0]));
    }
    return out.toOwnedSlice(alloc);
}

fn freeColumnNames(names: []const []const u8) void {
    for (names) |c| testing.allocator.free(c);
    testing.allocator.free(names);
}

fn countRows(ctx: *TestCtx, sql: []const u8) !i64 {
    var row = try ctx.db.queryRow(testing.allocator, sql, &[_][]const u8{});
    defer row.deinit(testing.allocator);
    return std.fmt.parseInt(i64, row.values[0], 10);
}

fn contentOf(ctx: *TestCtx, id: []const u8) ![]const u8 {
    const alloc = testing.allocator;
    var row = try ctx.db.queryRow(alloc, "SELECT COALESCE(CAST(content AS TEXT), '') FROM skills WHERE id = ?", &[_][]const u8{id});
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

fn metadataOf(ctx: *TestCtx, skill_id: []const u8, key: []const u8) !?[]const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT COALESCE(CAST(value AS TEXT), '') FROM skill_metadata WHERE skill_id = ? AND key = ?",
        &[_][]const u8{ skill_id, key },
    );
    defer q.deinit();
    const row = (try q.next()) orelse return null;
    defer row.deinit(alloc);
    const value: []const u8 = try alloc.dupe(u8, row.values[0]);
    return value;
}

test "Migration141 drops the name and description columns" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration141ContractSkillNameDescription.up(&ctx.db, testing.allocator);

    const names = try columnNames(&ctx);
    defer freeColumnNames(names);

    var found_content = false;
    for (names) |column| {
        try testing.expect(!std.mem.eql(u8, column, "name"));
        try testing.expect(!std.mem.eql(u8, column, "description"));
        if (std.mem.eql(u8, column, "content")) found_content = true;
    }
    try testing.expect(found_content);
}

test "Migration141 writes a body with no fence its column values" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertSkill(&ctx, "sk_1", "pdf", "Work with PDFs.", "Run scripts/convert.py.");

    try Migration141ContractSkillNameDescription.up(&ctx.db, testing.allocator);

    const content = try contentOf(&ctx, "sk_1");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(
        "---\nname: pdf\ndescription: \"Work with PDFs.\"\n---\nRun scripts/convert.py.\n",
        content,
    );

    const name = (try metadataOf(&ctx, "sk_1", "name")) orelse return error.MissingName;
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("pdf", name);

    const description = (try metadataOf(&ctx, "sk_1", "description")) orelse return error.MissingDescription;
    defer testing.allocator.free(description);
    try testing.expectEqualStrings("Work with PDFs.", description);
}

test "Migration141 leaves a body that already carries the same identity byte for byte" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const body = "---\nname: pdf\ndescription: Work with PDFs.\norigin: ECC\n---\nRun scripts/convert.py.\n";
    try insertSkill(&ctx, "sk_2", "pdf", "Work with PDFs.", body);
    try ctx.db.exec(
        testing.allocator,
        "INSERT INTO skill_metadata (id, skill_id, key, value) VALUES ('sm_ecc', 'sk_2', 'origin', 'ECC')",
        &[_][]const u8{},
    );

    try Migration141ContractSkillNameDescription.up(&ctx.db, testing.allocator);

    const content = try contentOf(&ctx, "sk_2");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(body, content);

    const origin = (try metadataOf(&ctx, "sk_2", "origin")) orelse return error.MissingOrigin;
    defer testing.allocator.free(origin);
    try testing.expectEqualStrings("ECC", origin);
}

test "Migration141 takes a description the column holds and the body does not" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertSkill(&ctx, "sk_3", "pdf", "edited in the list", "---\nname: pdf\ndescription: stale\n---\nbody\n");

    try Migration141ContractSkillNameDescription.up(&ctx.db, testing.allocator);

    const content = try contentOf(&ctx, "sk_3");
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "edited in the list") != null);
    try testing.expect(std.mem.indexOf(u8, content, "stale") == null);
}

test "Migration141 keeps every row and its children when foreign keys are enforced" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(testing.allocator, "INSERT INTO workspaces (id) VALUES ('ws_1')", &[_][]const u8{});
    try insertSkill(&ctx, "sk_4", "pdf", "", "body");
    try ctx.db.exec(
        testing.allocator,
        "INSERT INTO skill_assets (id, skill_id, rel_path, content) VALUES ('sa_1', 'sk_4', 'a.py', '1')",
        &[_][]const u8{},
    );
    try ctx.db.exec(
        testing.allocator,
        "INSERT INTO skill_metadata (id, skill_id, key, value) VALUES ('sm_origin', 'sk_4', 'origin', 'ECC')",
        &[_][]const u8{},
    );
    try test_db.enableForeignKeys(testing.allocator, &ctx.db);

    try Migration141ContractSkillNameDescription.up(&ctx.db, testing.allocator);

    try testing.expectEqual(@as(i64, 1), try countRows(&ctx, "SELECT COUNT(*) FROM skills"));
    try testing.expectEqual(@as(i64, 1), try countRows(&ctx, "SELECT COUNT(*) FROM skill_assets WHERE skill_id = 'sk_4'"));
    try testing.expectEqual(
        @as(i64, 3),
        try countRows(&ctx, "SELECT COUNT(*) FROM skill_metadata WHERE skill_id = 'sk_4'"),
    );

    if (dialect.is_postgres) return;

    var check = try ctx.db.query(testing.allocator, "PRAGMA foreign_key_check", &[_][]const u8{});
    defer check.deinit();
    try testing.expect((try check.next()) == null);
}

test "Migration141 replaying is a no-op" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertSkill(&ctx, "sk_5", "pdf", "Work with PDFs.", "body");
    try Migration141ContractSkillNameDescription.up(&ctx.db, testing.allocator);
    try Migration141ContractSkillNameDescription.up(&ctx.db, testing.allocator);

    try testing.expectEqual(@as(i64, 1), try countRows(&ctx, "SELECT COUNT(*) FROM skills"));
    try testing.expectEqual(@as(i64, 2), try countRows(&ctx, "SELECT COUNT(*) FROM skill_metadata WHERE skill_id = 'sk_5'"));
}

test "Migration141 is registered in allMigrations" {
    for (migration.allMigrations) |m| {
        if (m.version == Migration141ContractSkillNameDescription.version) return;
    }
    return error.Migration141NotRegistered;
}

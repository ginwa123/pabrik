const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dialect = common.dialect;

/// Migration 148 — a document and a document folder can carry their own glyph,
/// the same way a project row does since Migration 147. NULL is "no override":
/// a document falls back to `file`, a folder to `folder` / `folder-open`.
pub const Migration148AddDocumentIcon = struct {
    pub const version: u32 = 148;
    pub const name = "add_document_icon";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "documents",
            "icon",
            "icon TEXT",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "document_folders",
            "icon",
            "icon TEXT",
        );
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
    try db.exec(alloc,
        \\CREATE TABLE documents (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    title TEXT NOT NULL DEFAULT '',
        \\    format TEXT NOT NULL DEFAULT 'markdown'
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE document_folders (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    parent_id TEXT DEFAULT NULL,
        \\    name TEXT NOT NULL DEFAULT ''
        \\)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn hasColumn(ctx: *TestCtx, table: []const u8, wanted: []const u8) !bool {
    const alloc = testing.allocator;
    const sql = try std.fmt.allocPrint(
        alloc,
        "SELECT COUNT(*) FROM " ++ comptime dialect.table_columns_of_bound_table ++ " WHERE name = ?",
        .{},
    );
    defer alloc.free(sql);
    var q = try ctx.db.query(alloc, sql, &[_][]const u8{ table, wanted });
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    return !std.mem.eql(u8, row.values[0], "0");
}

test "Migration148 gives documents and document folders an icon column" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration148AddDocumentIcon.up(&ctx.db, testing.allocator);

    try testing.expect(try hasColumn(&ctx, "documents", "icon"));
    try testing.expect(try hasColumn(&ctx, "document_folders", "icon"));
}

test "Migration148 leaves every pre-existing row with no override" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(testing.allocator,
        \\INSERT INTO documents (id, workspace_id, title) VALUES ('doc_a', 'ws_1', 'Plan')
    , &[_][]const u8{});
    try ctx.db.exec(testing.allocator,
        \\INSERT INTO document_folders (id, workspace_id, name) VALUES ('fld_a', 'ws_1', 'Design')
    , &[_][]const u8{});

    try Migration148AddDocumentIcon.up(&ctx.db, testing.allocator);

    // NULL, not '' and not a default glyph: the row must read back as "no
    // override" so the UI keeps deriving the fallback.
    var doc = try ctx.db.queryRow(testing.allocator, "SELECT COALESCE(icon, '<null>') FROM documents WHERE id = 'doc_a'", &[_][]const u8{});
    defer doc.deinit(testing.allocator);
    try testing.expectEqualStrings("<null>", doc.values[0]);

    var folder = try ctx.db.queryRow(testing.allocator, "SELECT COALESCE(icon, '<null>') FROM document_folders WHERE id = 'fld_a'", &[_][]const u8{});
    defer folder.deinit(testing.allocator);
    try testing.expectEqualStrings("<null>", folder.values[0]);
}

test "Migration148 round-trips a glyph on both tables and can clear it again" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration148AddDocumentIcon.up(&ctx.db, testing.allocator);
    try ctx.db.exec(testing.allocator,
        \\INSERT INTO documents (id, workspace_id, title, icon) VALUES ('doc_a', 'ws_1', 'Plan', 'note')
    , &[_][]const u8{});
    try ctx.db.exec(testing.allocator,
        \\INSERT INTO document_folders (id, workspace_id, name, icon) VALUES ('fld_a', 'ws_1', 'Design', 'palette')
    , &[_][]const u8{});

    {
        var doc = try ctx.db.queryRow(testing.allocator, "SELECT icon FROM documents WHERE id = 'doc_a'", &[_][]const u8{});
        defer doc.deinit(testing.allocator);
        try testing.expectEqualStrings("note", doc.values[0]);
        var folder = try ctx.db.queryRow(testing.allocator, "SELECT icon FROM document_folders WHERE id = 'fld_a'", &[_][]const u8{});
        defer folder.deinit(testing.allocator);
        try testing.expectEqualStrings("palette", folder.values[0]);
    }

    // "Reset to default" is an UPDATE to NULL, so both columns must accept it.
    try ctx.db.exec(testing.allocator, "UPDATE documents SET icon = NULL WHERE id = 'doc_a'", &[_][]const u8{});
    try ctx.db.exec(testing.allocator, "UPDATE document_folders SET icon = NULL WHERE id = 'fld_a'", &[_][]const u8{});

    var doc = try ctx.db.queryRow(testing.allocator, "SELECT COALESCE(icon, '<null>') FROM documents WHERE id = 'doc_a'", &[_][]const u8{});
    defer doc.deinit(testing.allocator);
    try testing.expectEqualStrings("<null>", doc.values[0]);
    var folder = try ctx.db.queryRow(testing.allocator, "SELECT COALESCE(icon, '<null>') FROM document_folders WHERE id = 'fld_a'", &[_][]const u8{});
    defer folder.deinit(testing.allocator);
    try testing.expectEqualStrings("<null>", folder.values[0]);
}

test "Migration148 replaying is a no-op" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration148AddDocumentIcon.up(&ctx.db, testing.allocator);
    try Migration148AddDocumentIcon.up(&ctx.db, testing.allocator);

    try testing.expect(try hasColumn(&ctx, "documents", "icon"));
    try testing.expect(try hasColumn(&ctx, "document_folders", "icon"));
}

test "Migration148 is registered in allMigrations" {
    for (migration.allMigrations) |m| {
        if (m.version == Migration148AddDocumentIcon.version) return;
    }
    return error.Migration148NotRegistered;
}

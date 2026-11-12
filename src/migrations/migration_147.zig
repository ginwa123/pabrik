const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dialect = common.dialect;

/// Migration 147 — a project row can carry its own glyph, a NAME from the
/// frontend's `ICON_PATHS` registry. NULL is "no override" (the row falls back
/// to `folder` / `folder-open`), so the column is nullable with no DEFAULT.
pub const Migration147AddWorkspaceItemIcon = struct {
    pub const version: u32 = 147;
    pub const name = "add_workspace_item_icon";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_items",
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
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL,
        \\    name TEXT,
        \\    path TEXT
        \\)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn columnNames(ctx: *TestCtx) ![]const []const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT name FROM " ++ comptime dialect.tableColumns("workspace_items"), &[_][]const u8{});
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

fn hasColumn(names: []const []const u8, wanted: []const u8) bool {
    for (names) |c| {
        if (std.mem.eql(u8, c, wanted)) return true;
    }
    return false;
}

test "Migration147 gives a project row an icon column" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration147AddWorkspaceItemIcon.up(&ctx.db, testing.allocator);

    const names = try columnNames(&ctx);
    defer freeColumnNames(names);
    try testing.expect(hasColumn(names, "icon"));
}

test "Migration147 leaves every pre-existing row with no override" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(testing.allocator,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name)
        \\VALUES ('item_a', 'ws_1', 'kanban', 'Board')
    , &[_][]const u8{});

    try Migration147AddWorkspaceItemIcon.up(&ctx.db, testing.allocator);

    // NULL, not '' and not 'folder': the row must read back as "no override"
    // so the UI keeps deriving the glyph from the expanded state.
    var row = try ctx.db.queryRow(testing.allocator, "SELECT COALESCE(icon, '<null>') FROM workspace_items WHERE id = 'item_a'", &[_][]const u8{});
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("<null>", row.values[0]);
}

test "Migration147 round-trips an icon name and can clear it again" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration147AddWorkspaceItemIcon.up(&ctx.db, testing.allocator);
    try ctx.db.exec(testing.allocator,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, icon)
        \\VALUES ('item_a', 'ws_1', 'kanban', 'Board', 'tree')
    , &[_][]const u8{});

    {
        var row = try ctx.db.queryRow(testing.allocator, "SELECT icon FROM workspace_items WHERE id = 'item_a'", &[_][]const u8{});
        defer row.deinit(testing.allocator);
        try testing.expectEqualStrings("tree", row.values[0]);
    }

    // "Reset to default" is an UPDATE to NULL, so the column has to accept it.
    try ctx.db.exec(testing.allocator, "UPDATE workspace_items SET icon = NULL WHERE id = 'item_a'", &[_][]const u8{});

    var row = try ctx.db.queryRow(testing.allocator, "SELECT COALESCE(icon, '<null>') FROM workspace_items WHERE id = 'item_a'", &[_][]const u8{});
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("<null>", row.values[0]);
}

test "Migration147 replaying is a no-op" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration147AddWorkspaceItemIcon.up(&ctx.db, testing.allocator);
    try Migration147AddWorkspaceItemIcon.up(&ctx.db, testing.allocator);

    const names = try columnNames(&ctx);
    defer freeColumnNames(names);
    var count: usize = 0;
    for (names) |c| {
        if (std.mem.eql(u8, c, "icon")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "Migration147 is registered in allMigrations" {
    for (migration.allMigrations) |m| {
        if (m.version == Migration147AddWorkspaceItemIcon.version) return;
    }
    return error.Migration147NotRegistered;
}

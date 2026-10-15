const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;

/// Build the dynamic sibling-cwd list for the cross-project prompt.
pub fn makeCrossProjectCwdContext(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");

    const anchor = (resolveAnchor(allocator, db, session_id) catch |err| {
        std.log.warn("makeCrossProjectCwdContext: anchor lookup failed: {}", .{err});
        return allocator.dupe(u8, "");
    }) orelse return allocator.dupe(u8, "");
    defer {
        allocator.free(anchor.workspace_id);
        allocator.free(anchor.self_item_id);
    }

    const items_sql =
        \\SELECT wi.id, wi.name, wi.path
        \\FROM workspace_items wi
        \\WHERE wi.workspace_id = ? AND wi.id != ?
        \\AND wi.path IS NOT NULL AND TRIM(wi.path) != ''
        \\ORDER BY wi.position DESC, wi.id ASC
    ;

    var q = db.query(allocator, items_sql, &.{ anchor.workspace_id, anchor.self_item_id }) catch |err| {
        std.log.warn("makeCrossProjectCwdContext: sibling lookup failed: {}", .{err});
        return allocator.dupe(u8, "");
    };
    defer q.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var count: usize = 0;
    while (q.next() catch null) |row| {
        const item_id = row.values[0];
        const name = row.values[1];
        const path = row.values[2];
        if (count == 0) {
            try out.appendSlice(allocator, "\n\nSibling project directories:\n\n");
        }
        try out.appendSlice(allocator, "- `");
        try out.appendSlice(allocator, path);
        try out.appendSlice(allocator, "`");
        if (name.len > 0) {
            try out.appendSlice(allocator, " (");
            try out.appendSlice(allocator, name);
            try out.appendSlice(allocator, ")");
        }
        try out.appendSlice(allocator, " [item_id: `");
        try out.appendSlice(allocator, item_id);
        try out.appendSlice(allocator, "`]\n");
        count += 1;
        row.deinit(allocator);
    }

    if (count == 0) return out.toOwnedSlice(allocator);
    return out.toOwnedSlice(allocator);
}

const Anchor = struct {
    workspace_id: []u8,
    self_item_id: []u8,
};

fn resolveAnchor(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?Anchor {
    var q = try db.query(allocator,
        \\SELECT wi.workspace_id, t.workspace_item_id
        \\FROM workspace_item_tasks t
        \\JOIN workspace_items wi ON wi.id = t.workspace_item_id
        \\WHERE t.id = ?
    , &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return null;
    const workspace_id = try allocator.dupe(u8, row.values[0]);
    errdefer allocator.free(workspace_id);
    const self_item_id = try allocator.dupe(u8, row.values[1]);
    row.deinit(allocator);
    return .{ .workspace_id = workspace_id, .self_item_id = self_item_id };
}

// ─── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const test_sqlite = @import("pabrikcore").sqlite;

const TestCtx = struct {
    db: test_sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: test_sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT,
        \\    item_type TEXT,
        \\    name TEXT,
        \\    path TEXT,
        \\    position INTEGER,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    workspace_item_id TEXT,
        \\    created_at DATETIME,
        \\    updated_at DATETIME,
        \\    task_type TEXT DEFAULT 'standard'
        \\)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

test "makeCrossProjectCwdContext: empty session_id returns empty" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const result = try makeCrossProjectCwdContext(alloc, &ctx.db, "");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeCrossProjectCwdContext: unbound session returns empty" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const result = try makeCrossProjectCwdContext(alloc, &ctx.db, "task_missing");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeCrossProjectCwdContext: lists sibling paths from workspace_items only" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('item_self', 'ws_1', 'kanban', 'Self', '/tmp/self', 2)",
        &[_][]const u8{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('item_a', 'ws_1', 'kanban', 'Alpha', '/tmp/alpha', 1)",
        &[_][]const u8{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('item_b', 'ws_1', 'agent', 'Beta', '/tmp/beta', 0)",
        &[_][]const u8{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('item_empty', 'ws_1', 'kanban', 'Empty', '', 3)",
        &[_][]const u8{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, created_at, updated_at, task_type) VALUES ('task_1', 'T', 'item_self', datetime('now'), datetime('now'), 'standard')",
        &[_][]const u8{});
    const result = try makeCrossProjectCwdContext(alloc, &ctx.db, "task_1");
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "Sibling project directories:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "`/tmp/alpha`") != null);
    try testing.expect(std.mem.indexOf(u8, result, "`/tmp/beta`") != null);
    try testing.expect(std.mem.indexOf(u8, result, "`/tmp/self`") == null);
}

test "makeCrossProjectCwdContext: renders every sibling path without a cap" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('item_self', 'ws_1', 'kanban', 'Self', '/tmp/self', 100)", &[_][]const u8{});

    var sql_buf: [256]u8 = undefined;
    for (0..25) |index| {
        const sql = try std.fmt.bufPrint(
            &sql_buf,
            "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('item_{d}', 'ws_1', 'chat', 'Sibling {d}', '/tmp/sibling_{d}', {d})",
            .{ index, index, index, index },
        );
        try ctx.db.exec(alloc, sql, &[_][]const u8{});
    }
    try ctx.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, created_at, updated_at, task_type) VALUES ('task_all', 'T', 'item_self', datetime('now'), datetime('now'), 'standard')", &[_][]const u8{});

    const result = try makeCrossProjectCwdContext(alloc, &ctx.db, "task_all");
    defer alloc.free(result);

    for (0..25) |index| {
        const expected = try std.fmt.allocPrint(alloc, "`/tmp/sibling_{d}`", .{index});
        defer alloc.free(expected);
        try testing.expect(std.mem.indexOf(u8, result, expected) != null);
    }
    try testing.expect(std.mem.indexOf(u8, result, "`/tmp/self`") == null);
}

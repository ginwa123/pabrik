const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const testing = std.testing;

pub fn isSessionKanban(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8) !bool {
    var is_kanban: bool = false;
    // Filter on `wit.id` (the canonical session id for kanban / routine tasks
    // per Migration 052's `task.id == session.id` convention), not on
    // `session_id` — that column was dropped by Migration 052 and would
    const sql =
        \\
        \\SELECT 1 FROM workspace_item_tasks wit
        \\JOIN workspace_items wi ON wit.workspace_item_id = wi.id
        \\WHERE wit.id = ? AND wi.item_type = 'kanban'
    ;

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        row.deinit(allocator);
        is_kanban = true;
    }

    return is_kanban;
}

/// Open a fresh in-memory sqlite DB with `test_db.openMemory(&db, io)`.
/// Tests call `s.db.exec(...)` to lay down their own schema.
fn setupDb() !struct { db: database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    return .{ .db = db, .threaded = threaded };
}

/// Lay down the two tables `isTaskKanban` joins on. No `session_id` column —
/// the schema matches post-Migration 052 production. The function filters on
/// `wit.id` which doubles as the session id for kanban / routine tasks.
fn seedSchema(alloc: std.mem.Allocator, db: *database.Db) !void {
    try db.exec(alloc, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT
        \\)
    , &.{});
}

// ─── Test: kanban task → true ─────────────────────────────────────────────

test "isTaskKanban returns true when the session_id maps to a kanban task" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try seedSchema(alloc, &s.db);
    try s.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_k1', 'ws_1', 'kanban')", &.{});
    // Per Migration 052: `task.id == session.id`. The kanban task
    // was created for a chat whose session id is 'session_abc', so
    // the task row carries that id directly.
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('session_abc', 'plan sprint', 'item_k1')", &.{});

    try testing.expect(try isSessionKanban(alloc, &s.db, "session_abc"));
}

// ─── Test: chat task (non-kanban item_type) → false ───────────────────────

test "isTaskKanban returns false when the parent item is not a kanban" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try seedSchema(alloc, &s.db);
    try s.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_c1', 'ws_1', 'chat')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('session_chat', 'free chat', 'item_c1')", &.{});

    try testing.expect(!try isSessionKanban(alloc, &s.db, "session_chat"));
}

// ─── Test: unknown session_id → false ─────────────────────────────────────

test "isTaskKanban returns false when the session_id has no matching task" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try seedSchema(alloc, &s.db);
    try s.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_k1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('session_other', 'plan', 'item_k1')", &.{});

    try testing.expect(!try isSessionKanban(alloc, &s.db, "session_does_not_exist"));
}

// ─── Test: empty tables → false (no error, no row) ────────────────────────

test "isTaskKanban returns false when both tables are empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try seedSchema(alloc, &s.db);

    try testing.expect(!try isSessionKanban(alloc, &s.db, "session_anything"));
}

// ─── Test: only kanban items, no tasks → false ───────────────────────────

test "isTaskKanban returns false when kanban items exist but no tasks" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try seedSchema(alloc, &s.db);
    try s.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_k1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_k2', 'ws_1', 'kanban')", &.{});

    try testing.expect(!try isSessionKanban(alloc, &s.db, "session_no_task"));
}

// ─── Test: mixed kanban + chat in the same DB ─────────────────────────────
// Regression guard for the JOIN semantics: a session_id bound to a non-kanban
// task must NOT be reported as a kanban even when other kanban tasks exist in

test "isTaskKanban returns false for a session_id bound to a non-kanban task" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try seedSchema(alloc, &s.db);
    try s.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_k1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_c1', 'ws_1', 'chat')", &.{});
    // Kanban task with one session_id (must match the JOIN's kanban filter).
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('session_kanban', 'plan', 'item_k1')", &.{});
    // Chat task with a different session_id (must NOT match the kanban filter).
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('session_chat', 'chat', 'item_c1')", &.{});

    try testing.expect(try isSessionKanban(alloc, &s.db, "session_kanban"));
    try testing.expect(!try isSessionKanban(alloc, &s.db, "session_chat"));
}

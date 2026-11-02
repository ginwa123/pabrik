const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

pub const Migration125IndexHygiene = struct {
    pub const version: u32 = 125;
    pub const name = "index_hygiene_logs_and_redundant_indexes";

    pub const logs_session_created_index = "idx_logs_session_created";
    pub const logs_kind_created_index = "idx_logs_kind_created";
    pub const redundant_session_agents = "idx_session_agents_session";
    pub const redundant_routines = "idx_workspace_routines_workspace_item_id";
    pub const redundant_documents = "idx_documents_workspace_id";
    pub const redundant_tasks = "idx_workspace_item_tasks_item";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_logs_session_created
            \\ON logs(session_id, created_at_nano DESC)
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_logs_kind_created
            \\ON logs(kind, created_at_nano DESC)
        , &[_][]const u8{});

        for ([_][]const u8{
            redundant_session_agents,
            redundant_routines,
            redundant_documents,
            redundant_tasks,
        }) |index_name| {
            var ddl_buf: [128]u8 = undefined;
            const ddl = std.fmt.bufPrint(&ddl_buf, "DROP INDEX IF EXISTS {s}", .{index_name}) catch
                return error.BufferTooSmall;
            try db.exec(allocator, ddl, &[_][]const u8{});
        }
    }
};

const testing = std.testing;

fn openDb(alloc: std.mem.Allocator) !struct { db: Backend, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    return .{ .db = db, .threaded = threaded };
}

fn seedSchema(alloc: std.mem.Allocator, db: *Backend) !void {
    try db.exec(alloc,
        \\CREATE TABLE logs (
        \\  id TEXT PRIMARY KEY,
        \\  created_at_nano INTEGER NOT NULL,
        \\  level TEXT NOT NULL,
        \\  kind TEXT NOT NULL,
        \\  message TEXT NOT NULL,
        \\  stack TEXT,
        \\  source TEXT,
        \\  line INTEGER,
        \\  route_path TEXT,
        \\  session_id TEXT,
        \\  count INTEGER NOT NULL DEFAULT 1
        \\)
    , &[_][]const u8{});
    try db.exec(alloc, "CREATE INDEX idx_logs_level ON logs(level)", &[_][]const u8{});
    try db.exec(alloc, "CREATE INDEX idx_logs_created_at_nano ON logs(created_at_nano DESC)", &[_][]const u8{});

    try db.exec(alloc,
        \\CREATE TABLE session_agents (
        \\  session_id TEXT PRIMARY KEY,
        \\  agent_name TEXT NOT NULL,
        \\  updated_at INTEGER
        \\)
    , &[_][]const u8{});
    try db.exec(alloc, "CREATE INDEX idx_session_agents_session ON session_agents(session_id)", &[_][]const u8{});

    try db.exec(alloc,
        \\CREATE TABLE workspace_routines (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT NOT NULL UNIQUE,
        \\  enabled INTEGER NOT NULL DEFAULT 1
        \\)
    , &[_][]const u8{});
    try db.exec(alloc, "CREATE INDEX idx_workspace_routines_workspace_item_id ON workspace_routines(workspace_item_id)", &[_][]const u8{});

    try db.exec(alloc,
        \\CREATE TABLE documents (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  title TEXT NOT NULL DEFAULT '',
        \\  updated_at TIMESTAMP
        \\)
    , &[_][]const u8{});
    try db.exec(alloc, "CREATE INDEX idx_documents_workspace_id ON documents(workspace_id)", &[_][]const u8{});
    try db.exec(alloc, "CREATE INDEX idx_documents_workspace_updated ON documents(workspace_id, updated_at DESC)", &[_][]const u8{});

    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT NOT NULL,
        \\  created_at TIMESTAMP
        \\)
    , &[_][]const u8{});
    try db.exec(alloc, "CREATE INDEX idx_workspace_item_tasks_item ON workspace_item_tasks(workspace_item_id)", &[_][]const u8{});
    try db.exec(alloc, "CREATE INDEX idx_workspace_item_tasks_item_created ON workspace_item_tasks(workspace_item_id, created_at DESC)", &[_][]const u8{});
}

fn indexExists(alloc: std.mem.Allocator, db: *Backend, index_name: []const u8) !bool {
    var row = try db.queryRow(
        alloc,
        "SELECT COUNT(*) FROM " ++ comptime dialect.indexes_source ++
            " WHERE type = 'index' AND name = ?",
        &[_][]const u8{index_name},
    );
    defer row.deinit(alloc);
    return !std.mem.eql(u8, row.values[0], "0");
}

fn planDetail(alloc: std.mem.Allocator, db: *Backend, sql: []const u8) ![]u8 {
    var rows = try db.query(alloc, sql, &[_][]const u8{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.NoPlanRow;
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[row.values.len - 1]);
}

test "Migration125 gives the session and kind log reads an index they can search" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try seedSchema(alloc, db);
    try Migration125IndexHygiene.up(db, alloc);

    try testing.expect(try indexExists(alloc, db, Migration125IndexHygiene.logs_session_created_index));
    try testing.expect(try indexExists(alloc, db, Migration125IndexHygiene.logs_kind_created_index));
}

test "Migration125 turns the session log read from a scan into an index search" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;
    if (dialect.is_postgres) return;

    try seedSchema(alloc, db);

    const read_sql = "SELECT id FROM logs WHERE 1=1 AND session_id = ? ORDER BY created_at_nano DESC LIMIT 50";

    const before = try planDetail(alloc, db, "EXPLAIN QUERY PLAN " ++ read_sql);
    defer alloc.free(before);
    try testing.expect(std.mem.indexOf(u8, before, "SCAN logs") != null);

    try Migration125IndexHygiene.up(db, alloc);

    const after = try planDetail(alloc, db, "EXPLAIN QUERY PLAN " ++ read_sql);
    defer alloc.free(after);
    try testing.expect(std.mem.indexOf(u8, after, Migration125IndexHygiene.logs_session_created_index) != null);
}

test "Migration125 drops only the indexes a narrower one already covers" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try seedSchema(alloc, db);
    try Migration125IndexHygiene.up(db, alloc);

    for ([_][]const u8{
        Migration125IndexHygiene.redundant_session_agents,
        Migration125IndexHygiene.redundant_routines,
        Migration125IndexHygiene.redundant_documents,
        Migration125IndexHygiene.redundant_tasks,
    }) |dropped| {
        try testing.expect(!try indexExists(alloc, db, dropped));
    }

    try testing.expect(try indexExists(alloc, db, "idx_documents_workspace_updated"));
    try testing.expect(try indexExists(alloc, db, "idx_workspace_item_tasks_item_created"));
    try testing.expect(try indexExists(alloc, db, "idx_logs_level"));
}

test "Migration125 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try seedSchema(alloc, db);
    try Migration125IndexHygiene.up(db, alloc);
    try Migration125IndexHygiene.up(db, alloc);

    try testing.expect(try indexExists(alloc, db, Migration125IndexHygiene.logs_session_created_index));
    try testing.expect(try indexExists(alloc, db, Migration125IndexHygiene.logs_kind_created_index));
    try testing.expect(!try indexExists(alloc, db, Migration125IndexHygiene.redundant_tasks));
}

test "Migration125 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration125IndexHygiene.version) return;
    }
    return error.Migration125NotRegistered;
}

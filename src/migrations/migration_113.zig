const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;

/// Migration 113 — a detached job can belong to a workspace VM. The table
/// recorded a HOST pid; a row for a job that ran inside a VM needs that VM and
/// the pid within it. The defaults say "not a guest job", so nothing rewrites.
pub const Migration113AddGuestJobColumns = struct {
    pub const version: u32 = 113;
    pub const name = "add_background_process_guest_columns";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try common.addColumnIfMissing(.{ .db = db }, allocator, "session_background_process", "vm_id", "vm_id TEXT NOT NULL DEFAULT ''");
        try common.addColumnIfMissing(.{ .db = db }, allocator, "session_background_process", "guest_pid", "guest_pid INTEGER NOT NULL DEFAULT 0");
    }
};

const testing = std.testing;

test "Migration113 adds the two guest columns and leaves host rows at the default" {
    const alloc = testing.allocator;

    var db: Backend = .{};
    defer db.deinit();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    try test_db.openMemory(&db, threaded.io());

    try db.exec(alloc,
        \\CREATE TABLE session_background_process (
        \\  session_id TEXT NOT NULL,
        \\  pid INTEGER NOT NULL,
        \\  command TEXT NOT NULL,
        \\  log_path TEXT NOT NULL,
        \\  started_at INTEGER NOT NULL,
        \\  status TEXT NOT NULL,
        \\  kind TEXT NOT NULL DEFAULT 'job',
        \\  last_read_offset INTEGER DEFAULT 0
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\INSERT INTO session_background_process
        \\  (session_id, pid, command, log_path, started_at, status)
        \\VALUES ('s1', 4242, 'zig build', '/tmp/bg_1.log', 1, 'running')
    , &[_][]const u8{});

    try Migration113AddGuestJobColumns.up(&db, alloc);

    var rows = try db.query(alloc,
        \\SELECT vm_id, guest_pid FROM session_background_process WHERE session_id = 's1'
    , &[_][]const u8{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    // The pre-existing row is a HOST job, and says so.
    try testing.expectEqualStrings("", row.values[0]);
    try testing.expectEqualStrings("0", row.values[1]);
}

test "Migration113 replaying is a no-op" {
    const alloc = testing.allocator;

    var db: Backend = .{};
    defer db.deinit();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    try test_db.openMemory(&db, threaded.io());

    try db.exec(alloc,
        \\CREATE TABLE session_background_process (
        \\  session_id TEXT NOT NULL,
        \\  pid INTEGER NOT NULL,
        \\  command TEXT NOT NULL,
        \\  log_path TEXT NOT NULL,
        \\  started_at INTEGER NOT NULL,
        \\  status TEXT NOT NULL DEFAULT 'running',
        \\  PRIMARY KEY (session_id, pid)
        \\)
    , &[_][]const u8{});

    try Migration113AddGuestJobColumns.up(&db, alloc);
    try Migration113AddGuestJobColumns.up(&db, alloc);

    var rows = try db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('session_background_process')
        \\WHERE name IN ('vm_id', 'guest_pid')
    , &[_][]const u8{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}

test "Migration113 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration113AddGuestJobColumns.version) return;
    }
    return error.Migration113NotRegistered;
}

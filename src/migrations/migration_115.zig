const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const addColumnIfMissing = common.addColumnIfMissing;

/// Migration 115 — a workspace records whether it is a microVM workspace.
/// A workspace created while the server ran in `--saas` mode is VM-backed
/// (is_vm = 1); one created on the host is not (is_vm = 0).
pub const Migration115AddWorkspaceIsVm = struct {
    pub const version: u32 = 115;
    pub const name = "add_workspace_is_vm";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspaces",
            "is_vm",
            "is_vm INTEGER NOT NULL DEFAULT 0",
        );

        // Rows that predate the column were already running in a Firecracker
        // on a `--saas` deployment, so an upgrade must not downgrade them.
        // Inert locally: the flag is only read in saas mode.
        try db.exec(
            allocator,
            "UPDATE workspaces SET is_vm = 1 WHERE is_vm = 0",
            &[_][]const u8{},
        );
    }
};

const testing = std.testing;

fn setupDb(alloc: std.mem.Allocator) !Backend {
    var db: Backend = .{};
    errdefer db.deinit();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL DEFAULT ''
        \\)
    , &[_][]const u8{});
    return db;
}

test "Migration115 marks a workspace VM-backed and leaves a new one host-backed" {
    const alloc = testing.allocator;
    var db = try setupDb(alloc);
    defer db.deinit();

    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_old', 'Old')", &[_][]const u8{});

    try Migration115AddWorkspaceIsVm.up(&db, alloc);

    var rows = try db.query(alloc, "SELECT is_vm FROM workspaces WHERE id = 'ws_old'", &[_][]const u8{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    // The workspace that existed before the column is VM-backed.
    try testing.expectEqualStrings("1", row.values[0]);

    // A workspace created after the migration is host-backed until its server
    // says otherwise.
    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_new', 'New')", &[_][]const u8{});
    var new_rows = try db.query(alloc, "SELECT is_vm FROM workspaces WHERE id = 'ws_new'", &[_][]const u8{});
    defer new_rows.deinit();
    const new_row = (try new_rows.next()) orelse return error.RowMissing;
    defer new_row.deinit(alloc);
    try testing.expectEqualStrings("0", new_row.values[0]);
}

test "Migration115 replaying is a no-op" {
    const alloc = testing.allocator;
    var db = try setupDb(alloc);
    defer db.deinit();

    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_old', 'Old')", &[_][]const u8{});
    try Migration115AddWorkspaceIsVm.up(&db, alloc);
    try Migration115AddWorkspaceIsVm.up(&db, alloc);

    var rows = try db.query(alloc,
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("workspaces") ++
        \\
        \\WHERE name = 'is_vm'
    , &[_][]const u8{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration115 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration115AddWorkspaceIsVm.version) return;
    }
    return error.Migration115NotRegistered;
}

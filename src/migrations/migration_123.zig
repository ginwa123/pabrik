const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

/// A pending invitation: the ask, not the membership. Accepting it inserts the
/// `workspace_members` row, so nothing here can put a workspace in somebody's
/// sidebar before they have said yes.
pub const Migration123AddWorkspaceInvitations = struct {
    pub const version: u32 = 123;
    pub const name = "add_workspace_invitations";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS workspace_invitations (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_id TEXT NOT NULL,
            \\    invitee_user_id TEXT NOT NULL,
            \\    role TEXT NOT NULL DEFAULT 'viewer' CHECK (role IN ('owner', 'admin', 'editor', 'viewer')),
            \\    invited_by TEXT NOT NULL DEFAULT '',
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        // One pending ask per (workspace, invitee): re-inviting the same person
        // is a 409, never a second row to answer twice.
        try db.exec(allocator,
            \\CREATE UNIQUE INDEX IF NOT EXISTS uq_workspace_invitations_pair
            \\ON workspace_invitations(workspace_id, invitee_user_id)
        , &[_][]const u8{});

        // The inbox reads the other direction: "what is waiting for me".
        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_workspace_invitations_invitee
            \\ON workspace_invitations(invitee_user_id, created_at)
        , &[_][]const u8{});
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

fn count(alloc: std.mem.Allocator, db: *Backend, sql: []const u8) !u64 {
    var row = try db.queryRow(alloc, sql, &[_][]const u8{});
    defer row.deinit(alloc);
    return std.fmt.parseInt(u64, row.values[0], 10) catch 0;
}

test "Migration123 creates the invitation row the accept flow needs" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration123AddWorkspaceInvitations.up(db, alloc);

    const cols = try count(alloc, db, "SELECT COUNT(*) FROM " ++
        comptime dialect.tableColumns("workspace_invitations") ++
        " WHERE name IN ('id','workspace_id','invitee_user_id','role','invited_by','created_at')");
    try testing.expectEqual(@as(u64, 6), cols);

    // An invitation with no workspace or no invitee is unroutable, so both
    // columns must be NOT NULL rather than merely empty.
    const nullable = try count(alloc, db, "SELECT COUNT(*) FROM " ++
        comptime dialect.tableColumns("workspace_invitations") ++
        " WHERE \"notnull\" = 0 AND name IN ('workspace_id','invitee_user_id')");
    try testing.expectEqual(@as(u64, 0), nullable);
}

test "Migration123 refuses a second pending invitation for the same pair" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration123AddWorkspaceInvitations.up(db, alloc);

    try db.exec(alloc,
        \\INSERT INTO workspace_invitations (id, workspace_id, invitee_user_id, role, invited_by)
        \\VALUES ('inv_1', 'ws_1', 'user_ben', 'editor', 'user_amy')
    , &[_][]const u8{});

    // The UNIQUE index is the guard the store relies on, so it is asserted at
    // the schema, not only in the store's own pre-checks.
    db.exec(alloc,
        \\INSERT INTO workspace_invitations (id, workspace_id, invitee_user_id, role, invited_by)
        \\VALUES ('inv_2', 'ws_1', 'user_ben', 'viewer', 'user_amy')
    , &[_][]const u8{}) catch {};

    try testing.expectEqual(@as(u64, 1), try count(alloc, db, "SELECT COUNT(*) FROM workspace_invitations"));

    // The same person may still be invited to a DIFFERENT workspace.
    try db.exec(alloc,
        \\INSERT INTO workspace_invitations (id, workspace_id, invitee_user_id, role, invited_by)
        \\VALUES ('inv_3', 'ws_2', 'user_ben', 'viewer', 'user_cid')
    , &[_][]const u8{});
    try testing.expectEqual(@as(u64, 2), try count(alloc, db, "SELECT COUNT(*) FROM workspace_invitations"));
}

test "Migration123 refuses a role the membership table could not hold" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration123AddWorkspaceInvitations.up(db, alloc);

    db.exec(alloc,
        \\INSERT INTO workspace_invitations (id, workspace_id, invitee_user_id, role)
        \\VALUES ('inv_bad', 'ws_1', 'user_ben', 'emperor')
    , &[_][]const u8{}) catch {};
    try testing.expectEqual(@as(u64, 0), try count(alloc, db, "SELECT COUNT(*) FROM workspace_invitations"));
}

test "Migration123 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration123AddWorkspaceInvitations.up(db, alloc);
    try Migration123AddWorkspaceInvitations.up(db, alloc);

    try testing.expectEqual(@as(u64, 2), try count(alloc, db, "SELECT COUNT(*) FROM " ++
        comptime dialect.indexes_source ++
        " WHERE type = 'index' AND name IN ('uq_workspace_invitations_pair','idx_workspace_invitations_invitee')"));
}

test "Migration123 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration123AddWorkspaceInvitations.version) return;
    }
    return error.Migration123NotRegistered;
}

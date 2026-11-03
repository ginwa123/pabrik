const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");
const migration_103 = @import("migration_103.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;

pub const Migration138AddWorkspaceSecretDescription = struct {
    pub const version: u32 = 138;
    pub const name = "add_workspace_secret_description";

    pub const description_column = "description";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "workspace_secrets",
            description_column,
            "description TEXT NOT NULL DEFAULT ''",
        );
    }
};

const testing = std.testing;

fn openDb(alloc: std.mem.Allocator) !struct { db: Backend, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try migration_103.Migration103CreateWorkspaceSecrets.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

fn column(alloc: std.mem.Allocator, db: *Backend, id: []const u8) ![]u8 {
    var q = try db.query(
        alloc,
        "SELECT COALESCE(description, '<null>') FROM workspace_secrets WHERE id = ?",
        &[_][]const u8{id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.SecretMissing;
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

test "Migration138 leaves an existing secret with an empty description rather than a NULL" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    // A row written before the column existed: it carries no description at
    // all, and the read projection must still produce a string.
    try db.exec(alloc,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value) VALUES ('sec_old', 'ws_1', 'GH', 'ghp_1')
    , &[_][]const u8{});

    try Migration138AddWorkspaceSecretDescription.up(db, alloc);

    const got = try column(alloc, db, "sec_old");
    defer alloc.free(got);
    try testing.expectEqualStrings("", got);
}

test "Migration138 lets a description be written and read back" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration138AddWorkspaceSecretDescription.up(db, alloc);

    try db.exec(alloc,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value, description) VALUES
        \\  ('sec_a', 'ws_1', 'GH', 'ghp_1', 'Read-only GitHub token for the PR bot')
    , &[_][]const u8{});

    const got = try column(alloc, db, "sec_a");
    defer alloc.free(got);
    try testing.expectEqualStrings("Read-only GitHub token for the PR bot", got);
}

test "Migration138 replaying keeps every stored description" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration138AddWorkspaceSecretDescription.up(db, alloc);
    try db.exec(alloc,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value, description) VALUES ('sec_a', 'ws_1', 'GH', 'ghp_1', 'kept')
    , &[_][]const u8{});

    try Migration138AddWorkspaceSecretDescription.up(db, alloc);

    const got = try column(alloc, db, "sec_a");
    defer alloc.free(got);
    try testing.expectEqualStrings("kept", got);
}

test "Migration138 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration138AddWorkspaceSecretDescription.version) return;
    }
    return error.Migration138NotRegistered;
}

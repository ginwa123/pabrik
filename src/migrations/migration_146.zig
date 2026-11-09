const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

pub const Migration146AddMcpOAuth = struct {
    pub const version: u32 = 146;
    pub const name = "add_mcp_oauth";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS mcp_oauth_tokens (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_id TEXT NOT NULL,
            \\    server_name TEXT NOT NULL,
            \\    resource TEXT NOT NULL DEFAULT '',
            \\    issuer TEXT NOT NULL DEFAULT '',
            \\    client_id TEXT NOT NULL DEFAULT '',
            \\    token_endpoint TEXT NOT NULL DEFAULT '',
            \\    token_type TEXT NOT NULL DEFAULT 'Bearer',
            \\    scope TEXT NOT NULL DEFAULT '',
            \\    expires_at INTEGER DEFAULT NULL,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    UNIQUE (workspace_id, server_name),
        ++ comptime dialect.foreignKey("FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE") ++
            \\)
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS mcp_oauth_pending (
            \\    state TEXT PRIMARY KEY,
            \\    workspace_id TEXT NOT NULL,
            \\    server_name TEXT NOT NULL,
            \\    resource TEXT NOT NULL DEFAULT '',
            \\    issuer TEXT NOT NULL DEFAULT '',
            \\    client_id TEXT NOT NULL DEFAULT '',
            \\    authorization_endpoint TEXT NOT NULL DEFAULT '',
            \\    token_endpoint TEXT NOT NULL DEFAULT '',
            \\    redirect_uri TEXT NOT NULL DEFAULT '',
            \\    scope TEXT NOT NULL DEFAULT '',
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        ++ comptime dialect.foreignKey("FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE") ++
            \\)
        , &[_][]const u8{});

        try db.exec(
            allocator,
            "CREATE INDEX IF NOT EXISTS idx_mcp_oauth_pending_workspace_server ON mcp_oauth_pending(workspace_id, server_name)",
            &[_][]const u8{},
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
    return .{ .db = db, .threaded = threaded };
}

fn countRows(alloc: std.mem.Allocator, db: *Backend, comptime table: []const u8) !usize {
    var q = try db.query(alloc, "SELECT COUNT(*) FROM " ++ table, &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    return try std.fmt.parseInt(usize, row.values[0], 10);
}

test "Migration146 stores one metadata row per workspace and server" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration146AddMcpOAuth.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        \\INSERT INTO mcp_oauth_tokens (id, workspace_id, server_name) VALUES ('t1', 'ws_1', 'files')
    , &[_][]const u8{});
    try ctx.db.exec(alloc,
        \\INSERT INTO mcp_oauth_tokens (id, workspace_id, server_name) VALUES ('t2', 'ws_1', 'search')
    , &[_][]const u8{});

    try testing.expectEqual(@as(usize, 2), try countRows(alloc, &ctx.db, "mcp_oauth_tokens"));
}

test "Migration146 rejects a second metadata row for the same workspace and server" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration146AddMcpOAuth.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        \\INSERT INTO mcp_oauth_tokens (id, workspace_id, server_name) VALUES ('t1', 'ws_1', 'files')
    , &[_][]const u8{});
    try testing.expectError(error.ExecuteFailed, ctx.db.exec(alloc,
        \\INSERT INTO mcp_oauth_tokens (id, workspace_id, server_name) VALUES ('t2', 'ws_1', 'files')
    , &[_][]const u8{}));
}

test "Migration146 keeps a pending authorization keyed by state" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration146AddMcpOAuth.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        \\INSERT INTO mcp_oauth_pending (state, workspace_id, server_name, redirect_uri) VALUES ('st_1', 'ws_1', 'files', 'http://127.0.0.1/cb')
    , &[_][]const u8{});

    var q = try ctx.db.query(alloc, "SELECT redirect_uri FROM mcp_oauth_pending WHERE state = 'st_1'", &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("http://127.0.0.1/cb", row.values[0]);
}

test "Migration146 keeps no credential column in either table" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration146AddMcpOAuth.up(&ctx.db, alloc);

    const forbidden = [_][]const u8{ "access_token", "refresh_token", "client_secret", "code_verifier" };
    for (forbidden) |column| {
        const token_sql = comptime blk: {
            break :blk "SELECT COUNT(*) FROM " ++ dialect.tableColumns("mcp_oauth_tokens") ++ " WHERE name = ?";
        };
        var q = try ctx.db.query(alloc, token_sql, &[_][]const u8{column});
        const row = (try q.next()) orelse return error.NoRow;
        try testing.expectEqualStrings("0", row.values[0]);
        row.deinit(alloc);
        q.deinit();

        const pending_sql = comptime blk: {
            break :blk "SELECT COUNT(*) FROM " ++ dialect.tableColumns("mcp_oauth_pending") ++ " WHERE name = ?";
        };
        var q2 = try ctx.db.query(alloc, pending_sql, &[_][]const u8{column});
        const row2 = (try q2.next()) orelse return error.NoRow;
        try testing.expectEqualStrings("0", row2.values[0]);
        row2.deinit(alloc);
        q2.deinit();
    }
}

test "Migration146 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration146AddMcpOAuth.up(&ctx.db, alloc);
    try Migration146AddMcpOAuth.up(&ctx.db, alloc);

    try testing.expectEqual(@as(usize, 0), try countRows(alloc, &ctx.db, "mcp_oauth_tokens"));
    try testing.expectEqual(@as(usize, 0), try countRows(alloc, &ctx.db, "mcp_oauth_pending"));
}

test "Migration146 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration146AddMcpOAuth.version) return;
    }
    return error.Migration146NotRegistered;
}

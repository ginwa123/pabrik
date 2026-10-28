const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const database = pabrikcore.database;
const mcp_scope = @import("../modules/agent/mcp/mcp/mcp_scope.zig");

pub const Scope = mcp_scope.Scope;

pub fn resolve(
    allocator: std.mem.Allocator,
    db: ?*database.Db,
    session_id: ?[]const u8,
) Scope {
    const backend = db orelse return .{};
    const sid = session_id orelse return .{};
    if (sid.len == 0) return .{};

    var q = backend.query(
        allocator,
        "SELECT COALESCE(user_id, ''), COALESCE(workspace_id, '') FROM sessions WHERE id = ?",
        &[_][]const u8{sid},
    ) catch return .{};
    defer q.deinit();
    const row = (q.next() catch null) orelse return .{};
    defer row.deinit(allocator);
    if (row.values.len < 2) return .{};

    const owner = allocator.dupe(u8, row.values[0]) catch return .{};
    const workspace_id = allocator.dupe(u8, row.values[1]) catch return .{};
    return .{ .owner = owner, .workspace_id = workspace_id };
}

const testing = std.testing;

fn setupDb(alloc: std.mem.Allocator) !database.Db {
    var db: database.Db = .{};
    errdefer db.deinit();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, user_id TEXT, workspace_id TEXT)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\INSERT INTO sessions (id, user_id, workspace_id) VALUES ('s_1', 'u_a', 'ws_1'), ('s_2', 'u_b', 'ws_1')
    , &[_][]const u8{});
    return db;
}

test "a session row resolves to its owner and workspace" {
    const alloc = testing.allocator;
    var db = try setupDb(alloc);
    defer db.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scope = resolve(arena.allocator(), &db, "s_1");
    try testing.expectEqualStrings("u_a", scope.owner);
    try testing.expectEqualStrings("ws_1", scope.workspace_id);
}

test "two users in one workspace resolve to different owners" {
    const alloc = testing.allocator;
    var db = try setupDb(alloc);
    defer db.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = try (resolve(arena.allocator(), &db, "s_1").key(arena.allocator(), "files"));
    const b = try (resolve(arena.allocator(), &db, "s_2").key(arena.allocator(), "files"));
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "no session id, no database, and an unknown session all resolve to the global scope" {
    const alloc = testing.allocator;
    var db = try setupDb(alloc);
    defer db.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try testing.expect(resolve(arena.allocator(), &db, null).isGlobal());
    try testing.expect(resolve(arena.allocator(), null, "s_1").isGlobal());
    try testing.expect(resolve(arena.allocator(), &db, "missing").isGlobal());
}

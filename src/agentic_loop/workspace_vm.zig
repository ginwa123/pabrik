//! Whether a workspace's work runs in a microVM. `workspaces.is_vm`
//! (Migration 115) records it per workspace, and the guest routes ask it
//! before they ask the manager for a Firecracker.

const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;
const runtime_mode = @import("../runtime_mode.zig");

/// What a refusal says when a workspace has no VM to run in.
pub const not_vm_message = "this workspace is not a VM workspace: it has no microVM to run in";

/// The flag a workspace created by a server in `mode` gets.
pub fn creationIsVm(mode: runtime_mode.Mode) bool {
    return mode == .saas;
}

/// The effective answer for a row's flag: a workspace runs in a microVM only
/// when the server is in saas mode, because that is the only mode with a
/// Firecracker at all.
pub fn runsInVm(mode: runtime_mode.Mode, stored_is_vm: bool) bool {
    return mode == .saas and stored_is_vm;
}

/// The `is_vm` flag of a workspace row. A row that is not there, or a schema
/// without the column, answers true: before Migration 115 every saas
/// workspace was a VM workspace.
pub fn storedIsVm(allocator: std.mem.Allocator, db: *database.Db, workspace_id: []const u8) bool {
    var q = db.query(allocator, "SELECT is_vm FROM workspaces WHERE id = ?", &[_][]const u8{workspace_id}) catch return true;
    defer q.deinit();
    const row = q.next() catch return true;
    defer if (row) |r| r.deinit(allocator);
    const r = row orelse return true;
    if (r.values.len == 0 or r.values[0].len == 0) return true;
    return r.values[0][0] == '1';
}

/// Whether this process may put the workspace in a VM.
pub fn isVmWorkspace(allocator: std.mem.Allocator, db: *database.Db, workspace_id: []const u8) bool {
    return runsInVm(runtime_mode.currentMode(), storedIsVm(allocator, db, workspace_id));
}

const testing = std.testing;

fn setupDb(alloc: std.mem.Allocator) !database.Db {
    var db: database.Db = .{};
    errdefer db.deinit();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    try db.init(threaded.io(), ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE workspaces (id TEXT PRIMARY KEY, is_vm INTEGER NOT NULL DEFAULT 0)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\INSERT INTO workspaces (id, is_vm) VALUES ('ws_vm', 1), ('ws_host', 0)
    , &[_][]const u8{});
    return db;
}

test "a row that says it is VM-backed is VM-backed" {
    const alloc = testing.allocator;
    var db = try setupDb(alloc);
    defer db.deinit();

    try testing.expect(storedIsVm(alloc, &db, "ws_vm"));
    try testing.expect(!storedIsVm(alloc, &db, "ws_host"));
}

test "a workspace the server has no row for is not one it may refuse" {
    const alloc = testing.allocator;
    var db = try setupDb(alloc);
    defer db.deinit();

    // No row: the server cannot say the workspace is host-backed.
    try testing.expect(storedIsVm(alloc, &db, "ws_missing"));
}

test "a schema without the column keeps the pre-Migration-115 behaviour" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    try db.init(threaded.io(), ":memory:");
    try db.exec(alloc, "CREATE TABLE workspaces (id TEXT PRIMARY KEY)", &[_][]const u8{});

    // Every workspace of a saas deployment was a VM workspace before the
    // column existed, so a missing column must not refuse them.
    try testing.expect(storedIsVm(alloc, &db, "ws_1"));
}

test "only saas mode has a Firecracker, so only saas mode has VM workspaces" {
    try testing.expect(!runsInVm(.local, true));
    try testing.expect(!runsInVm(.local, false));
    try testing.expect(runsInVm(.saas, true));
    try testing.expect(!runsInVm(.saas, false));
}

test "a workspace created by a saas server is VM-backed; one created on the host is not" {
    try testing.expect(creationIsVm(.saas));
    try testing.expect(!creationIsVm(.local));
}

test "a local server has no VM workspace at all" {
    const alloc = testing.allocator;
    var db = try setupDb(alloc);
    defer db.deinit();

    // The row says VM-backed, but this server has no Firecracker to run it in.
    try testing.expect(!isVmWorkspace(alloc, &db, "ws_vm"));
}

test "a saas server runs only its VM-backed workspaces" {
    const alloc = testing.allocator;
    var db = try setupDb(alloc);
    defer db.deinit();
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);

    try testing.expect(isVmWorkspace(alloc, &db, "ws_vm"));
    try testing.expect(!isVmWorkspace(alloc, &db, "ws_host"));
}

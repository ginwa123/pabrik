const std = @import("std");
const root_mod = @import("pabrikcore");
const gserverz = root_mod.gserverz;
const pabrikcore = root_mod;
const ai_workflow = pabrikcore.ai_workflow;
const auth_common = @import("auth_common.zig");

pub const WorkspaceDeleteError = error{
    OutOfMemory,
    DatabaseError,
    /// The workspace does not exist, or belongs to another user. The two
    /// cases are deliberately indistinguishable (404, never 403) so a
    /// caller cannot probe for the existence of someone else's ids.
    NotFound,
};

/// DELETE /api/workspaces/:id
pub fn workspaceDeleteHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const id = req.params.get("id") orelse "";
    if (id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"id required\"}" });
    }

    const result = useCase(allocator, sqlite_db, id, di.auth_enabled, req.headers) catch |err| {
        const message: []const u8 = switch (err) {
            error.DatabaseError => "Failed to delete workspace",
            error.OutOfMemory => "Out of memory",
            error.NotFound => "Workspace not found",
        };
        const status: u16 = switch (err) {
            error.NotFound => 404,
            else => 500,
        };
        return res.jsonResponse(.{ .status_code = status, .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message}) });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"id\":\"{s}\"}}", .{result.id}) });
}

const WorkspaceDeleteResult = struct {
    id: []const u8,
};

fn useCase(
    allocator: std.mem.Allocator,
    sqlite_db: *pabrikcore.database.Db,
    id: []const u8,
    auth_enabled: bool,
    headers: anytype,
) WorkspaceDeleteError!WorkspaceDeleteResult {
    // Resolve the owner server-side (cookie only — never the body/path) and
    // refuse to touch a workspace this request cannot see. Without this a
    // caller could destroy another user's workspace by guessing its id.
    const owner = auth_common.resolveRequestUserId(allocator, sqlite_db, auth_enabled, headers) catch {
        return error.OutOfMemory;
    };
    defer allocator.free(owner);

    {
        var q = sqlite_db.query(
            allocator,
            "SELECT 1 FROM workspaces WHERE id = ? AND " ++ comptime auth_common.workspaceVisibilityClause("workspaces"),
            &[_][]const u8{ id, owner, owner },
        ) catch {
            std.log.warn("workspaceDelete: visibility check failed for {s}", .{id});
            return error.DatabaseError;
        };
        defer q.deinit();
        const row = q.next() catch {
            return error.DatabaseError;
        };
        if (row == null) return error.NotFound;
        if (row) |r| r.deinit(allocator);
    }

    // `begin`/`commit` return the full sqlite error set, which is far wider
    // than this file's handler-facing set.
    var tx = sqlite_db.begin() catch {
        std.log.warn("workspaceDelete: BEGIN failed for {s}", .{id});
        return error.DatabaseError;
    };
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    // Workspace first, still visibility-gated — a foreign id matches nothing
    // and the tx rolls back, so a foreign caller can never strip a real
    // owner's members.
    tx.exec(
        allocator,
        "DELETE FROM workspaces WHERE id = ? AND " ++ comptime auth_common.workspaceVisibilityClause("workspaces"),
        &[_][]const u8{ id, owner, owner },
    ) catch {
        std.log.warn("workspaceDelete: DELETE failed for {s}", .{id});
        return error.DatabaseError;
    };

    tx.exec(
        allocator,
        "DELETE FROM workspace_members WHERE workspace_id = ?",
        &[_][]const u8{id},
    ) catch {
        std.log.warn("workspaceDelete: member cleanup failed for {s}", .{id});
        return error.DatabaseError;
    };

    // `ON DELETE CASCADE` on `workspace_secrets` is documentation only — this
    // project leaves `PRAGMA foreign_keys` off (Migration 072's tests), so
    // the child rows have to go explicitly or a deleted workspace would leave
    tx.exec(
        allocator,
        "DELETE FROM workspace_secrets WHERE workspace_id = ?",
        &[_][]const u8{id},
    ) catch {
        std.log.warn("workspaceDelete: secret cleanup failed for {s}", .{id});
        return error.DatabaseError;
    };

    // Same reason as the secrets above: `PRAGMA foreign_keys` is OFF, so
    // Migration 105's `ON DELETE CASCADE` never fires.
    tx.exec(
        allocator,
        "DELETE FROM workspace_settings WHERE workspace_id = ?",
        &[_][]const u8{id},
    ) catch {
        std.log.warn("workspaceDelete: config overlay cleanup failed for {s}", .{id});
        return error.DatabaseError;
    };

    tx.commit() catch {
        std.log.warn("workspaceDelete: COMMIT failed for {s}", .{id});
        return error.DatabaseError;
    };
    return .{ .id = id };
}

// ============================================================================
// useCase — membership cleanup
// ============================================================================

const testing = std.testing;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;

const DeleteCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDeleteDb() !DeleteCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  created_at DATETIME,
        \\  updated_at DATETIME,
        \\  position INTEGER,
        \\  user_id TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_members (
        \\  workspace_id TEXT NOT NULL,
        \\  user_id TEXT NOT NULL,
        \\  role TEXT NOT NULL DEFAULT 'viewer',
        \\  joined_at DATETIME,
        \\  invited_by TEXT,
        \\  PRIMARY KEY (workspace_id, user_id)
        \\)
    , &.{});
    // Mirrors Migration 103's `workspace_secrets` (the columns the delete
    // path touches). Kept as a literal here, like the two tables above, so
    // this fixture stays independent of the migration chain.
    try db.exec(alloc,
        \\CREATE TABLE workspace_secrets (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  value TEXT NOT NULL,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    // Mirrors Migration 105's `workspace_settings`.
    try db.exec(alloc,
        \\CREATE TABLE workspace_settings (
        \\  owner TEXT NOT NULL DEFAULT '',
        \\  workspace_id TEXT NOT NULL,
        \\  config_json TEXT,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  PRIMARY KEY (owner, workspace_id)
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn countRows(ctx: *DeleteCtx, sql: []const u8, params: []const []const u8) !u64 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, sql, params);
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(u64, row.values[0], 10);
}

/// A header bag with no Cookie, so `parseSessionToken` yields null and
/// `resolveRequestUserId` resolves the sentinel.
const NoCookie = struct {
    pub fn get(_: @This(), _: []const u8) ?[]const u8 {
        return null;
    }
};

test "workspaceDelete removes the membership rows, not just the workspace" {
    const alloc = testing.allocator;
    var ctx = try setupDeleteDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, name, user_id) VALUES ('ws_x', 'X', 'user_a')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ('ws_x', 'user_a', 'owner'), ('ws_x', 'user_b', 'viewer')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO workspace_secrets (id, workspace_id, name, value) VALUES ('sec_1', 'ws_x', 'GITHUB_TOKEN', 'ghp_x')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO workspace_settings (owner, workspace_id, config_json) VALUES ('', 'ws_x', '{\"active_profile\":\"claude\"}')", &.{});
    try testing.expectEqual(@as(u64, 2), try countRows(&ctx, "SELECT COUNT(*) FROM workspace_members WHERE workspace_id = 'ws_x'", &.{}));

    const r = try useCase(alloc, &ctx.db, "ws_x", true, NoCookie{});
    try testing.expectEqualStrings("ws_x", r.id);

    try testing.expectEqual(@as(u64, 0), try countRows(&ctx, "SELECT COUNT(*) FROM workspaces WHERE id = 'ws_x'", &.{}));
    // The assertion this whole use case was changed to make: `PRAGMA
    // foreign_keys` is OFF, so nothing else would ever remove these.
    try testing.expectEqual(@as(u64, 0), try countRows(&ctx, "SELECT COUNT(*) FROM workspace_members WHERE workspace_id = 'ws_x'", &.{}));
    // The secrets cleanup (Migration 103): a deleted workspace leaves no
    // credentials behind for a future workspace reusing the id.
    try testing.expectEqual(@as(u64, 0), try countRows(&ctx, "SELECT COUNT(*) FROM workspace_secrets WHERE workspace_id = 'ws_x'", &.{}));
    // The config-overlay cleanup (Migration 105) for the same reason, and
    // with a sharper edge: an orphaned overlay holds PROFILES, which hold API
    // keys, so a reused workspace id would come back pre-configured with a
    try testing.expectEqual(@as(u64, 0), try countRows(&ctx, "SELECT COUNT(*) FROM workspace_settings WHERE workspace_id = 'ws_x'", &.{}));
}

test "workspaceDelete refuses an unknown workspace and deletes nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDeleteDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, name, user_id) VALUES ('ws_x', 'X', 'user_a')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ('ws_x', 'user_a', 'owner')", &.{});

    try testing.expectError(error.NotFound, useCase(alloc, &ctx.db, "ws_nope", true, NoCookie{}));

    // The refused call must not have taken the real workspace's members with
    // it — the cleanup only runs after a visibility-gated DELETE.
    try testing.expectEqual(@as(u64, 1), try countRows(&ctx, "SELECT COUNT(*) FROM workspaces WHERE id = 'ws_x'", &.{}));
    try testing.expectEqual(@as(u64, 1), try countRows(&ctx, "SELECT COUNT(*) FROM workspace_members WHERE workspace_id = 'ws_x'", &.{}));
}

//! `DELETE /api/workspaces/:workspace_id/secrets/:secret_id`. Removes one
//! secret.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const secrets_store = @import("../agentic_loop/secrets_store.zig");
const gate = @import("workspace_members_gate.zig");

pub const SecretsDeleteError = error{
    WorkspaceIdRequired,
    SecretIdRequired,
    NotFound,
    DeleteFailed,
};

pub const SecretsDeleteInput = struct {
    workspace_id: []const u8,
    secret_id: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: SecretsDeleteInput,
) SecretsDeleteError!void {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (input.secret_id.len == 0) return error.SecretIdRequired;
    secrets_store.deleteSecret(allocator, db, input.workspace_id, input.secret_id) catch |err| switch (err) {
        error.IdsRequired => return error.SecretIdRequired,
        error.NotFound => return error.NotFound,
        error.DeleteFailed => return error.DeleteFailed,
        // The guards above already caught an empty workspace_id, so this
        // variant cannot reach the client from here — but the switch is
        // exhaustive over the store's shared error set on purpose, so a
        error.WorkspaceIdRequired => return error.WorkspaceIdRequired,
        error.NameRequired,
        error.ValueRequired,
        error.InvalidName,
        error.NameTaken,
        error.QueryFailed,
        error.InsertFailed,
        error.UpdateFailed,
        error.OutOfMemory,
        error.SealingUnavailable,
        => unreachable,
    };
}

// ===================================================================== Error
// mapping
// ===================================================================== Two

fn statusFor(err: SecretsDeleteError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired, error.SecretIdRequired => 400,
        error.NotFound => 404,
        error.DeleteFailed => 500,
    };
}

fn messageFor(err: SecretsDeleteError) []const u8 {
    return switch (err) {
        error.WorkspaceIdRequired => "workspace_id required",
        error.SecretIdRequired => "secret_id required",
        error.NotFound => "secret not found",
        error.DeleteFailed => "DB error",
    };
}

// =====================================================================
// Handler
// =====================================================================

pub fn secretsDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    const secret_id = req.params.get("secret_id") orelse "";
    // Writes need owner/admin: a viewer may read a workspace, not its credentials.
    gate.checkRequest(allocator, di.db, di.auth_enabled, req.headers, workspace_id, .manage) catch |err| {
        return res.jsonResponse(.{
            .status_code = gate.statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = gate.messageFor(err) }),
        });
    };

    useCase(allocator, sqlite_db, .{ .workspace_id = workspace_id, .secret_id = secret_id }) catch |err| {
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = messageFor(err) }),
        });
    };

    // The id comes back because the caller needs it to reconcile its local
    // list; the row's name and value are not part of the answer.
    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .id = secret_id,
        .success = true,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const testing = std.testing;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    try migration.Migration103CreateWorkspaceSecrets.up(&db, testing.allocator);
    try db.exec(testing.allocator,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value) VALUES
        \\  ('sec_a', 'ws_1', 'GITHUB_TOKEN', 'ghp_a_do_not_leak'),
        \\  ('sec_b', 'ws_2', 'GITHUB_TOKEN', 'ghp_b_do_not_leak')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn countRows(ctx: *TestCtx) !usize {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM workspace_secrets", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(usize, row.values[0], 10) catch 0;
}

test "useCase: deletes the secret and leaves the sibling alone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .secret_id = "sec_a" });

    try testing.expectError(
        error.NotFound,
        secrets_store.getSecret(alloc, &ctx.db, "ws_1", "sec_a"),
    );
    // The other workspace's identically named secret is untouched — the
    // scope lives in the WHERE clause, so a delete cannot reach across.
    const survivor = try secrets_store.getSecret(alloc, &ctx.db, "ws_2", "sec_b");
    defer secrets_store.freeSecretRow(alloc, survivor);
    try testing.expectEqualStrings("GITHUB_TOKEN", survivor.name);
    try testing.expectEqual(@as(usize, 1), try countRows(&ctx));
}

test "useCase: another workspace's secret id deletes nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_2", .secret_id = "sec_a" }),
    );
    // 404, never 403 — a 403 confirms the id exists.
    try testing.expectEqual(@as(u16, 404), statusFor(error.NotFound));
    try testing.expectEqualStrings("secret not found", messageFor(error.NotFound));
    try testing.expectEqual(@as(usize, 2), try countRows(&ctx));
}

test "useCase: deleting the same secret twice reports NotFound the second time" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .secret_id = "sec_a" });
    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .secret_id = "sec_a" }),
    );
    try testing.expectEqual(@as(usize, 1), try countRows(&ctx));
}

test "useCase: missing ids are 400s before the database is touched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "", .secret_id = "sec_a" }),
    );
    try testing.expectError(
        error.SecretIdRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .secret_id = "" }),
    );
    try testing.expectEqual(@as(usize, 2), try countRows(&ctx));

    try testing.expectEqual(@as(u16, 400), statusFor(error.WorkspaceIdRequired));
    try testing.expectEqualStrings("workspace_id required", messageFor(error.WorkspaceIdRequired));
    try testing.expectEqual(@as(u16, 400), statusFor(error.SecretIdRequired));
    try testing.expectEqualStrings("secret_id required", messageFor(error.SecretIdRequired));
}

test "useCase: an unknown secret id is NotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .secret_id = "sec_nope" }),
    );
    try testing.expectEqual(@as(usize, 2), try countRows(&ctx));
}

test "useCase: a store failure is a 500 DB error" {
    try testing.expectEqual(@as(u16, 500), statusFor(error.DeleteFailed));
    try testing.expectEqualStrings("DB error", messageFor(error.DeleteFailed));
}

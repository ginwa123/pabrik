//! `GET /api/workspaces/:workspace_id/secrets`. Returns `{secrets, count}`
//! for one workspace, ordered by name. NO VALUE APPEARS IN THIS RESPONSE —
//! not masked, not hinted, not truncated.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const secrets_store = @import("../agentic_loop/secrets_store.zig");

pub const SecretsListError = error{
    WorkspaceIdRequired,
    QueryFailed,
    OutOfMemory,
};

pub const SecretsListInput = struct {
    workspace_id: []const u8,
};

pub const SecretsListOutput = struct {
    /// Owned slice; the caller frees it with
    /// `secrets_store.freeSecretRows`.
    secrets: []secrets_store.SecretRow,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: SecretsListInput,
) SecretsListError!SecretsListOutput {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    const rows = secrets_store.listSecrets(allocator, db, input.workspace_id) catch |err| switch (err) {
        error.WorkspaceIdRequired => return error.WorkspaceIdRequired,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        // The rest of the store's shared error set belongs to the write
        // paths, which `listSecrets` cannot reach.
        error.IdsRequired,
        error.NameRequired,
        error.ValueRequired,
        error.InvalidName,
        error.NameTaken,
        error.NotFound,
        error.InsertFailed,
        error.UpdateFailed,
        error.DeleteFailed,
        => unreachable,
    };
    return .{ .secrets = rows };
}

// ===================================================================== Error
// mapping
// ===================================================================== Two

fn statusFor(err: SecretsListError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired => 400,
        error.QueryFailed, error.OutOfMemory => 500,
    };
}

fn messageFor(err: SecretsListError) []const u8 {
    return switch (err) {
        error.WorkspaceIdRequired => "workspace_id required",
        error.QueryFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

// =====================================================================
// Handler
// =====================================================================

pub fn secretsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = req.params.get("workspace_id") orelse "",
    }) catch |err| {
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = messageFor(err) }),
        });
    };
    defer secrets_store.freeSecretRows(allocator, output.secrets);

    const data = try http_response.makeSecretListResponse(allocator, output.secrets);
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
        \\  ('sec_a', 'ws_1', 'APPLE', 'v_apple_do_not_leak'),
        \\  ('sec_b', 'ws_1', 'ZEBRA', 'v_zebra_do_not_leak'),
        \\  ('sec_c', 'ws_2', 'MANGO', 'v_mango_do_not_leak')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "useCase: an empty workspace_id is WorkspaceIdRequired, a 400" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "" }),
    );
    try testing.expectEqual(@as(u16, 400), statusFor(error.WorkspaceIdRequired));
    try testing.expectEqualStrings("workspace_id required", messageFor(error.WorkspaceIdRequired));
}

test "useCase: returns one workspace's secrets, ordered by name" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" });
    defer secrets_store.freeSecretRows(alloc, output.secrets);

    try testing.expectEqual(@as(usize, 2), output.secrets.len);
    try testing.expectEqualStrings("APPLE", output.secrets[0].name);
    try testing.expectEqualStrings("ZEBRA", output.secrets[1].name);
    try testing.expectEqualStrings("sec_a", output.secrets[0].id);
    try testing.expect(output.secrets[0].created_at.len > 0);
    try testing.expect(output.secrets[0].updated_at.len > 0);
}

test "useCase: a workspace with no secrets lists empty rather than erroring" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_nobody" });
    defer secrets_store.freeSecretRows(alloc, output.secrets);
    try testing.expectEqual(@as(usize, 0), output.secrets.len);
}

test "useCase: never returns another workspace's secrets" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const ws1 = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" });
    defer secrets_store.freeSecretRows(alloc, ws1.secrets);
    const ws2 = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_2" });
    defer secrets_store.freeSecretRows(alloc, ws2.secrets);

    // No leak in either direction, and no "empty because mis-scoped" false
    // negative in the one workspace that does have secrets.
    try testing.expectEqual(@as(usize, 2), ws1.secrets.len);
    try testing.expectEqual(@as(usize, 1), ws2.secrets.len);
    try testing.expectEqualStrings("MANGO", ws2.secrets[0].name);
}

test "useCase: a failed query is a 500 DB error, never a silent empty list" {
    // Degrading a read failure into `[]` is what makes "nothing to show" and
    // "we could not look" indistinguishable, so the mapping is pinned.
    try testing.expectEqual(@as(u16, 500), statusFor(error.QueryFailed));
    try testing.expectEqualStrings("DB error", messageFor(error.QueryFailed));
    try testing.expectEqual(@as(u16, 500), statusFor(error.OutOfMemory));
}

test "the list response body carries no stored value" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" });
    defer secrets_store.freeSecretRows(alloc, output.secrets);

    const json = try http_response.makeSecretListResponse(alloc, output.secrets);
    defer alloc.free(json);

    // Names and timestamps travel; credentials do not.
    try testing.expect(std.mem.indexOf(u8, json, "APPLE") != null);
    try testing.expect(std.mem.indexOf(u8, json, "v_apple_do_not_leak") == null);
    try testing.expect(std.mem.indexOf(u8, json, "v_zebra_do_not_leak") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"count\":2") != null);
}


//! `PATCH /api/workspaces/:workspace_id/secrets/:secret_id`. Rotation.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const secrets_store = @import("../agentic_loop/secrets_store.zig");

/// PATCH body. Both fields default to `null` so an omitted field is
/// distinguishable from an explicit `""` — the latter is a real "send me an
/// empty credential" request, and it is refused.
const UpdateSecretBody = struct {
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
};

pub const SecretsUpdateError = error{
    WorkspaceIdRequired,
    SecretIdRequired,
    InvalidName,
    ValueRequired,
    NotFound,
    QueryFailed,
    UpdateFailed,
    OutOfMemory,
};

pub const SecretsUpdateInput = struct {
    workspace_id: []const u8,
    secret_id: []const u8,
    body: UpdateSecretBody,
};

pub const SecretsUpdateOutput = struct {
    secret: secrets_store.SecretRow,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: SecretsUpdateInput,
) SecretsUpdateError!SecretsUpdateOutput {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (input.secret_id.len == 0) return error.SecretIdRequired;

    // A `name` in the body is a claim about which row is being addressed, not
    // a rename instruction: renaming would silently break every prompt, skill
    // and saved tool call that references `{{SECRETS:OLD_NAME}}`.
    if (input.body.name) |name| {
        if (!secrets_store.isValidName(name)) return error.InvalidName;
        const current = try readRow(allocator, db, input.workspace_id, input.secret_id);
        defer secrets_store.freeSecretRow(allocator, current);
        if (!std.mem.eql(u8, current.name, name)) return error.NotFound;
    }

    // A PATCH with no value keeps the stored one, and the cheapest way to
    // keep a credential is not to write it: no UPDATE means the row is
    // returned as-is and `updated_at` does not advance either.
    const value = input.body.value orelse return .{
        .secret = try readRow(allocator, db, input.workspace_id, input.secret_id),
    };

    const row = secrets_store.updateSecret(allocator, db, .{
        .workspace_id = input.workspace_id,
        .secret_id = input.secret_id,
        .value = value,
    }) catch |err| switch (err) {
        error.WorkspaceIdRequired => return error.WorkspaceIdRequired,
        error.IdsRequired => return error.SecretIdRequired,
        error.ValueRequired => return error.ValueRequired,
        error.NotFound => return error.NotFound,
        error.QueryFailed => return error.QueryFailed,
        error.UpdateFailed => return error.UpdateFailed,
        error.OutOfMemory => return error.OutOfMemory,
        // The rest of the store's shared error set belongs to the create
        // path, which this handler never calls.
        error.NameRequired,
        error.InvalidName,
        error.NameTaken,
        error.InsertFailed,
        error.DeleteFailed,
        => unreachable,
    };
    return .{ .secret = row };
}

/// `secrets_store.getSecret` narrowed to this handler's error set. The read
/// projection has no `value` column, so nothing reaches this process that
/// holds a credential.
fn readRow(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    workspace_id: []const u8,
    secret_id: []const u8,
) SecretsUpdateError!secrets_store.SecretRow {
    return secrets_store.getSecret(allocator, db, workspace_id, secret_id) catch |err| switch (err) {
        error.WorkspaceIdRequired => return error.WorkspaceIdRequired,
        error.IdsRequired => return error.SecretIdRequired,
        error.NotFound => return error.NotFound,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        error.NameRequired,
        error.ValueRequired,
        error.InvalidName,
        error.NameTaken,
        error.InsertFailed,
        error.UpdateFailed,
        error.DeleteFailed,
        => unreachable,
    };
}

// ===================================================================== Error
// mapping
// ===================================================================== Two

fn statusFor(err: SecretsUpdateError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired, error.SecretIdRequired, error.InvalidName, error.ValueRequired => 400,
        // 404, never 403: a 403 would confirm the id exists, which is the
        // one thing workspace scoping exists to withhold.
        error.NotFound => 404,
        error.QueryFailed, error.UpdateFailed, error.OutOfMemory => 500,
    };
}

fn messageFor(err: SecretsUpdateError) []const u8 {
    return switch (err) {
        error.WorkspaceIdRequired => "workspace_id required",
        error.SecretIdRequired => "secret_id required",
        error.InvalidName => "name must match [A-Za-z0-9_-]{1,64}",
        error.ValueRequired => "value is required",
        error.NotFound => "secret not found",
        error.QueryFailed => "DB error",
        error.UpdateFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

// =====================================================================
// Handler
// =====================================================================

pub fn secretsUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const body = std.json.parseFromSliceLeaky(UpdateSecretBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = req.params.get("workspace_id") orelse "",
        .secret_id = req.params.get("secret_id") orelse "",
        .body = body,
    }) catch |err| {
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = messageFor(err) }),
        });
    };
    defer secrets_store.freeSecretRow(allocator, output.secret);

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .secret = http_response.makeSecretResponse(output.secret),
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = pabrikcore.sqlite;
const testing = std.testing;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try migration.Migration103CreateWorkspaceSecrets.up(&db, testing.allocator);
    try db.exec(testing.allocator,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value) VALUES
        \\  ('sec_a', 'ws_1', 'GITHUB_TOKEN', 'ghp_old_do_not_leak'),
        \\  ('sec_b', 'ws_2', 'GITHUB_TOKEN', 'ghp_ws2_do_not_leak')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

/// Read the stored value straight from SQL, bypassing the store, so an
/// assertion about what was persisted cannot be satisfied by the same code
/// path it is testing.
fn storedValue(ctx: *TestCtx, id: []const u8) ![]const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT value FROM workspace_secrets WHERE id = ?",
        &[_][]const u8{id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.SecretMissing;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

test "useCase: rotates the value and leaves the name alone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Backdate so a same-second CURRENT_TIMESTAMP write is still visible.
    try ctx.db.exec(
        alloc,
        "UPDATE workspace_secrets SET updated_at = '2000-01-01 00:00:00' WHERE id = 'sec_a'",
        &.{},
    );

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .secret_id = "sec_a",
        .body = .{ .value = "ghp_new_do_not_leak" },
    });
    defer secrets_store.freeSecretRow(alloc, output.secret);

    try testing.expectEqualStrings("sec_a", output.secret.id);
    try testing.expectEqualStrings("GITHUB_TOKEN", output.secret.name);
    try testing.expect(!std.mem.eql(u8, output.secret.updated_at, "2000-01-01 00:00:00"));

    const kept = try storedValue(&ctx, "sec_a");
    defer alloc.free(kept);
    try testing.expectEqualStrings("ghp_new_do_not_leak", kept);

    // The other workspace's identically named secret is a different row and
    // was not touched.
    const theirs = try storedValue(&ctx, "sec_b");
    defer alloc.free(theirs);
    try testing.expectEqualStrings("ghp_ws2_do_not_leak", theirs);
}

test "useCase: the response carries no value" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .secret_id = "sec_a",
        .body = .{ .value = "sk_rotated_do_not_leak" },
    });
    defer secrets_store.freeSecretRow(alloc, output.secret);

    const json = try std.json.Stringify.valueAlloc(alloc, .{
        .secret = http_response.makeSecretResponse(output.secret),
    }, .{});
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "GITHUB_TOKEN") != null);
    try testing.expect(std.mem.indexOf(u8, json, "sk_rotated_do_not_leak") == null);
    try testing.expect(std.mem.indexOf(u8, json, "value") == null);
}

test "useCase: a matching name in the body is accepted and changes nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .secret_id = "sec_a",
        .body = .{ .name = "GITHUB_TOKEN", .value = "ghp_rotated" },
    });
    defer secrets_store.freeSecretRow(alloc, output.secret);
    try testing.expectEqualStrings("GITHUB_TOKEN", output.secret.name);
}

test "useCase: a rename is refused, and the value is left as it was" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // A rename would break every `{{SECRETS:OLD_NAME}}` reference silently,
    // so the answer is "no such secret" rather than a quiet half-applied
    // edit — and the same answer a foreign workspace gets.
    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .secret_id = "sec_a",
            .body = .{ .name = "GITHUB_TOKEN_RENAMED", .value = "ghp_never_applied" },
        }),
    );

    const kept = try storedValue(&ctx, "sec_a");
    defer alloc.free(kept);
    try testing.expectEqualStrings("ghp_old_do_not_leak", kept);
}

test "useCase: a body with no value keeps the stored one, untouched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(
        alloc,
        "UPDATE workspace_secrets SET updated_at = '2000-01-01 00:00:00' WHERE id = 'sec_a'",
        &.{},
    );

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .secret_id = "sec_a",
        .body = .{},
    });
    defer secrets_store.freeSecretRow(alloc, output.secret);

    // "Omitted means keep" is only honest if nothing at all moved: the
    // value stays AND updated_at stays, because no write happened.
    try testing.expectEqualStrings("GITHUB_TOKEN", output.secret.name);
    try testing.expectEqualStrings("2000-01-01 00:00:00", output.secret.updated_at);

    const kept = try storedValue(&ctx, "sec_a");
    defer alloc.free(kept);
    try testing.expectEqualStrings("ghp_old_do_not_leak", kept);
}

test "useCase: value \"\" is ValueRequired, a 400 — never a 500 constraint error" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The empty slice would bind as SQL NULL and violate
    // `value TEXT NOT NULL`, turning a blank form field into a 500.
    try testing.expectError(
        error.ValueRequired,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .secret_id = "sec_a",
            .body = .{ .value = "" },
        }),
    );
    try testing.expectEqual(@as(u16, 400), statusFor(error.ValueRequired));
    try testing.expectEqualStrings("value is required", messageFor(error.ValueRequired));

    const kept = try storedValue(&ctx, "sec_a");
    defer alloc.free(kept);
    try testing.expectEqualStrings("ghp_old_do_not_leak", kept);
}

test "useCase: a name the grammar cannot spell is InvalidName, a 400" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.InvalidName,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .secret_id = "sec_a",
            .body = .{ .name = "has space", .value = "v" },
        }),
    );
    try testing.expectEqual(@as(u16, 400), statusFor(error.InvalidName));
}

test "useCase: missing ids are 400s before the database is touched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "", .secret_id = "sec_a", .body = .{ .value = "v" } }),
    );
    try testing.expectError(
        error.SecretIdRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .secret_id = "", .body = .{ .value = "v" } }),
    );

    try testing.expectEqual(@as(u16, 400), statusFor(error.WorkspaceIdRequired));
    try testing.expectEqualStrings("workspace_id required", messageFor(error.WorkspaceIdRequired));
    try testing.expectEqual(@as(u16, 400), statusFor(error.SecretIdRequired));
    try testing.expectEqualStrings("secret_id required", messageFor(error.SecretIdRequired));
}

test "useCase: another workspace's secret id is NotFound — 404, never 403" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_2",
            .secret_id = "sec_a",
            .body = .{ .value = "stolen" },
        }),
    );

    // A 403 would confirm the id exists, which is exactly what workspace
    // scoping exists to withhold.
    try testing.expectEqual(@as(u16, 404), statusFor(error.NotFound));
    try testing.expectEqualStrings("secret not found", messageFor(error.NotFound));

    const kept = try storedValue(&ctx, "sec_a");
    defer alloc.free(kept);
    try testing.expectEqualStrings("ghp_old_do_not_leak", kept);
}

test "useCase: an unknown secret id is NotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .secret_id = "sec_nope",
            .body = .{ .value = "v" },
        }),
    );
}

test "useCase: store failures are 500 DB errors" {
    try testing.expectEqual(@as(u16, 500), statusFor(error.UpdateFailed));
    try testing.expectEqualStrings("DB error", messageFor(error.UpdateFailed));
    try testing.expectEqual(@as(u16, 500), statusFor(error.QueryFailed));
    try testing.expectEqual(@as(u16, 500), statusFor(error.OutOfMemory));
}

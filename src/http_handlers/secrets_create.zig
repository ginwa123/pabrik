//! `POST /api/workspaces/:workspace_id/secrets`. Creates one workspace-scoped
//! secret and answers 201 with the stored row — id, name and timestamps, and
//! NO VALUE.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const secrets_store = @import("../agentic_loop/secrets_store.zig");

/// Request body. Both fields default to "" so an empty body parses and is
/// then refused by validation rather than answering "Invalid JSON body".
const CreateSecretBody = struct {
    name: []const u8 = "",
    value: []const u8 = "",
};

pub const SecretsCreateError = error{
    WorkspaceIdRequired,
    NameRequired,
    InvalidName,
    ValueRequired,
    NameTaken,
    InsertFailed,
    OutOfMemory,
};

pub const SecretsCreateInput = struct {
    workspace_id: []const u8,
    body: CreateSecretBody,
};

pub const SecretsCreateOutput = struct {
    secret: secrets_store.SecretRow,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: SecretsCreateInput,
) SecretsCreateError!SecretsCreateOutput {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    const row = secrets_store.createSecret(allocator, db, .{
        .workspace_id = input.workspace_id,
        .name = input.body.name,
        .value = input.body.value,
    }) catch |err| switch (err) {
        error.WorkspaceIdRequired => return error.WorkspaceIdRequired,
        error.NameRequired => return error.NameRequired,
        error.InvalidName => return error.InvalidName,
        error.ValueRequired => return error.ValueRequired,
        error.NameTaken => return error.NameTaken,
        error.InsertFailed => return error.InsertFailed,
        error.OutOfMemory => return error.OutOfMemory,
        // The rest of the store's shared error set belongs to the read and
        // update paths, which `createSecret` cannot reach.
        error.IdsRequired,
        error.NotFound,
        error.QueryFailed,
        error.UpdateFailed,
        error.DeleteFailed,
        => unreachable,
    };
    return .{ .secret = row };
}

// ===================================================================== Error
// mapping
// ===================================================================== Two

fn statusFor(err: SecretsCreateError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired, error.NameRequired, error.InvalidName, error.ValueRequired => 400,
        error.NameTaken => 409,
        error.InsertFailed, error.OutOfMemory => 500,
    };
}

/// `requested_name` is only read for the duplicate answer, which names the
/// offending key so the UI can say which row to change instead of "conflict".
fn messageFor(
    err: SecretsCreateError,
    allocator: std.mem.Allocator,
    requested_name: []const u8,
) ![]const u8 {
    return switch (err) {
        error.WorkspaceIdRequired => "workspace_id required",
        error.NameRequired => "name is required",
        error.InvalidName => "name must match [A-Za-z0-9_-]{1,64}",
        error.ValueRequired => "value is required",
        // The key name is not itself a secret — it is what the model types
        // into a placeholder — so echoing it here discloses nothing.
        error.NameTaken => try std.fmt.allocPrint(
            allocator,
            "a secret named '{s}' already exists in this workspace",
            .{std.mem.trim(u8, requested_name, " \t\n\r")},
        ),
        error.InsertFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

// =====================================================================
// Handler
// =====================================================================

pub fn secretsCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";

    // An empty body is legal on the wire so the validation errors below are
    // what a blank submission sees; only unparseable JSON is a 400 here.
    var body = CreateSecretBody{};
    if (req.body.len > 0) {
        body = std.json.parseFromSliceLeaky(CreateSecretBody, allocator, req.body, .{}) catch {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
            });
        };
    }

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .body = body,
    }) catch |err| {
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(
                allocator,
                .{ .@"error" = try messageFor(err, allocator, body.name) },
            ),
        });
    };
    defer secrets_store.freeSecretRow(allocator, output.secret);

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .secret = http_response.makeSecretResponse(output.secret),
    }, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = data });
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

/// Read the stored value straight from SQL, bypassing the store, so an
/// assertion about what was persisted cannot be satisfied by the same code
/// path it is testing.
fn storedValue(ctx: *TestCtx, name: []const u8) ![]const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT value FROM workspace_secrets WHERE name = ?",
        &[_][]const u8{name},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.SecretMissing;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

test "useCase: creates a secret and stamps both timestamps" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "  GITHUB_TOKEN  ", .value = "ghp_xxx" },
    });
    defer secrets_store.freeSecretRow(alloc, output.secret);

    try testing.expectEqualStrings("ws_1", output.secret.workspace_id);
    // Trimmed, so the sidebar row renders no leading padding and the name
    // matches what a `{{SECRETS:...}}` placeholder has to spell.
    try testing.expectEqualStrings("GITHUB_TOKEN", output.secret.name);
    try testing.expect(output.secret.id.len > 0);
    try testing.expect(output.secret.created_at.len > 0);
    try testing.expect(output.secret.updated_at.len > 0);
}

test "useCase: the created response carries no value" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "STRIPE_KEY", .value = "sk_live_do_not_leak" },
    });
    defer secrets_store.freeSecretRow(alloc, output.secret);

    const json = try std.json.Stringify.valueAlloc(alloc, .{
        .secret = http_response.makeSecretResponse(output.secret),
    }, .{});
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "STRIPE_KEY") != null);
    try testing.expect(std.mem.indexOf(u8, json, "sk_live_do_not_leak") == null);
    try testing.expect(std.mem.indexOf(u8, json, "value") == null);

    // ...while the value really was stored, so the absence above is the
    // response shape's doing and not a write that silently dropped it.
    const kept = try storedValue(&ctx, "STRIPE_KEY");
    defer alloc.free(kept);
    try testing.expectEqualStrings("sk_live_do_not_leak", kept);
}

test "useCase: an empty workspace_id is WorkspaceIdRequired, a 400" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "", .body = .{ .name = "GH", .value = "v" } }),
    );
    try testing.expectEqual(@as(u16, 400), statusFor(error.WorkspaceIdRequired));
    try testing.expectEqualStrings("workspace_id required", messageFor(
        error.WorkspaceIdRequired,
        alloc,
        "",
    ) catch @panic("allocPrint failed for the secrets_create message fixture"));
}

test "useCase: a blank name is NameRequired, a 400" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    for ([_][]const u8{ "", "   \t\n " }) |blank| {
        try testing.expectError(
            error.NameRequired,
            useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .body = .{ .name = blank, .value = "v" } }),
        );
    }
    try testing.expectEqual(@as(u16, 400), statusFor(error.NameRequired));
}

test "useCase: a name the placeholder grammar cannot spell is InvalidName, a 400" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    for ([_][]const u8{ "has space", "has.dot", "brace{", "slash/one", "a" ** 65 }) |bad| {
        try testing.expectError(
            error.InvalidName,
            useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .body = .{ .name = bad, .value = "v" } }),
        );
    }
    try testing.expectEqual(@as(u16, 400), statusFor(error.InvalidName));
    try testing.expectEqualStrings("name must match [A-Za-z0-9_-]{1,64}", messageFor(
        error.InvalidName,
        alloc,
        "x",
    ) catch @panic("allocPrint failed for the secrets_create message fixture"));
}

test "useCase: value \"\" is ValueRequired, a 400 — never a 500 constraint error" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // `Backend.exec` binds a zero-length slice as SQL NULL, and `value
    // TEXT NOT NULL` rejects NULL — so without the store's pre-check this
    // exact request would answer 500 "DB error" for what is really a blank
    try testing.expectError(
        error.ValueRequired,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .body = .{ .name = "GITHUB_TOKEN", .value = "" },
        }),
    );
    try testing.expectEqual(@as(u16, 400), statusFor(error.ValueRequired));
    try testing.expectEqualStrings("value is required", messageFor(
        error.ValueRequired,
        alloc,
        "GITHUB_TOKEN",
    ) catch @panic("allocPrint failed for the secrets_create message fixture"));

    // Nothing was written on the way to the error.
    try testing.expectEqual(@as(usize, 0), try countRows(&ctx));
}

test "useCase: a duplicate name in one workspace is NameTaken, a 409" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const first = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "GITHUB_TOKEN", .value = "ghp_first" },
    });
    defer secrets_store.freeSecretRow(alloc, first.secret);

    try testing.expectError(
        error.NameTaken,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .body = .{ .name = "GITHUB_TOKEN", .value = "ghp_second" },
        }),
    );
    try testing.expectEqual(@as(u16, 409), statusFor(error.NameTaken));

    // The duplicate must not have overwritten the stored credential — a
    // 409 that half-applied would be worse than no answer at all.
    const kept = try storedValue(&ctx, "GITHUB_TOKEN");
    defer alloc.free(kept);
    try testing.expectEqualStrings("ghp_first", kept);

    // The conflict names the key, so the UI can say which row to change.
    const message = try messageFor(error.NameTaken, alloc, "GITHUB_TOKEN");
    defer alloc.free(message);
    try testing.expectEqualStrings(
        "a secret named 'GITHUB_TOKEN' already exists in this workspace",
        message,
    );
}

test "useCase: the same name in a second workspace is not a duplicate" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const in_ws1 = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "GITHUB_TOKEN", .value = "ghp_a" },
    });
    defer secrets_store.freeSecretRow(alloc, in_ws1.secret);

    // Names are unique per workspace, not per database — two workspaces
    // are two different tenants and each keeps its own GITHUB_TOKEN.
    const in_ws2 = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_2",
        .body = .{ .name = "GITHUB_TOKEN", .value = "ghp_b" },
    });
    defer secrets_store.freeSecretRow(alloc, in_ws2.secret);

    try testing.expectEqualStrings("ws_2", in_ws2.secret.workspace_id);
    try testing.expect(!std.mem.eql(u8, in_ws1.secret.id, in_ws2.secret.id));
    try testing.expectEqual(@as(usize, 2), try countRows(&ctx));
}

test "useCase: a store failure is a 500 DB error" {
    try testing.expectEqual(@as(u16, 500), statusFor(error.InsertFailed));
    try testing.expectEqualStrings("DB error", messageFor(error.InsertFailed, testing.allocator, "x") catch @panic("allocPrint failed for the secrets_create message fixture"));
    try testing.expectEqual(@as(u16, 500), statusFor(error.OutOfMemory));
}

//! `GET /api/workspaces/:workspace_id/secrets/:secret_id/reveal` — the only route that returns a
//! credential: one plaintext, unsealed per request, to a MEMBER of that workspace; 404 for everyone
//! else, including a signed-in user who may see other workspaces.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const gate = @import("workspace_members_gate.zig");
const secrets_store = @import("../agentic_loop/secrets_store.zig");

pub const SecretRevealError = error{
    WorkspaceIdRequired,
    WorkspaceNotFound,
    Forbidden,
    IdsRequired,
    NotFound,
    QueryFailed,
    ValueUnreadable,
    OutOfMemory,
};

pub const SecretRevealInput = struct {
    workspace_id: []const u8,
    secret_id: []const u8,
};

pub const SecretRevealOutput = struct {
    /// Owned; the caller frees it with `secrets_store.freeRevealedSecret`.
    secret: secrets_store.RevealedSecret,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: SecretRevealInput,
    auth_enabled: bool,
    headers: anytype,
) SecretRevealError!SecretRevealOutput {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;

    // Membership, not mere visibility: a shared `user_system` workspace is
    // visible to everybody, and its credentials are not.
    const caller = gate.callerFor(allocator, db, auth_enabled, headers) catch |err| return err;
    defer allocator.free(caller);
    gate.check(allocator, db, input.workspace_id, caller, .read) catch |err| return err;

    if (input.secret_id.len == 0) return error.IdsRequired;

    const revealed = secrets_store.revealSecret(
        allocator,
        db,
        input.workspace_id,
        input.secret_id,
    ) catch |err| switch (err) {
        error.IdsRequired => return error.IdsRequired,
        error.NotFound => return error.NotFound,
        error.QueryFailed => return error.QueryFailed,
        error.ValueUnreadable => return error.ValueUnreadable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .secret = revealed };
}

fn statusFor(err: SecretRevealError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired, error.IdsRequired => 400,
        error.WorkspaceNotFound, error.NotFound => 404,
        error.Forbidden => 403,
        error.QueryFailed, error.ValueUnreadable, error.OutOfMemory => 500,
    };
}

fn messageFor(err: SecretRevealError) []const u8 {
    return switch (err) {
        error.WorkspaceIdRequired => "workspace_id required",
        error.IdsRequired => "secret_id required",
        error.WorkspaceNotFound, error.NotFound => "Secret not found",
        error.Forbidden => "Only a workspace member can reveal a secret",
        error.QueryFailed => "DB error",
        error.ValueUnreadable => "The stored value cannot be opened on this host",
        error.OutOfMemory => "Out of memory",
    };
}

pub fn secretsRevealHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();

    const output = useCase(
        allocator,
        di.db,
        .{
            .workspace_id = req.params.get("workspace_id") orelse "",
            .secret_id = req.params.get("secret_id") orelse "",
        },
        di.auth_enabled,
        req.headers,
    ) catch |err| {
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = messageFor(err) }),
        });
    };
    defer secrets_store.freeRevealedSecret(allocator, output.secret);

    // `no-store`: a credential in a browser cache outlives the tab.
    const data = try std.json.Stringify.valueAlloc(
        allocator,
        .{ .secret = http_response.makeSecretRevealResponse(output.secret) },
        .{},
    );
    return res.jsonResponse(.{ .status_code = 200, .data = data })
        .withHeader("Cache-Control", "no-store");
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const database = pabrikcore.database;
const auth_core = @import("auth_core");

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

/// A cookie-carrying requester, parsed exactly like a real one: the handler
/// only sees header names.
const Cookie = struct {
    token: []const u8,

    pub fn get(self: @This(), name: []const u8) ?[]const u8 {
        if (!std.mem.eql(u8, name, "Cookie")) return null;
        return self.token;
    }
};

/// No Cookie header, so `resolveRequestUserId` answers the installation owner —
/// the auth-off deployment this route must also serve.
const NoCookie = struct {
    pub fn get(_: @This(), _: []const u8) ?[]const u8 {
        return null;
    }
};

/// Cookie headers carrying each user's session, built the way the login route
/// builds them (SHA-256 of the raw token, stored in `auth_sessions`).
fn cookieFor(allocator: std.mem.Allocator, raw_token: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "theme=dark; {s}={s}", .{ auth_core.cookie_name, raw_token });
}

fn sessionRow(user_id: []const u8, raw_token: []const u8) struct { hash: [64]u8, user_id: []const u8 } {
    var hash: [64]u8 = undefined;
    auth_core.sha256Hex(raw_token, &hash);
    return .{ .hash = hash, .user_id = user_id };
}

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  user_id TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE users (
        \\  id TEXT PRIMARY KEY,
        \\  email TEXT NOT NULL,
        \\  name TEXT NOT NULL DEFAULT '',
        \\  role TEXT NOT NULL DEFAULT 'user',
        \\  is_active INTEGER NOT NULL DEFAULT 1
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE auth_sessions (
        \\  token_hash TEXT PRIMARY KEY,
        \\  user_id TEXT NOT NULL,
        \\  expires_at TIMESTAMP
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_members (
        \\  workspace_id TEXT NOT NULL,
        \\  user_id TEXT NOT NULL,
        \\  role TEXT NOT NULL DEFAULT 'viewer',
        \\  joined_at TIMESTAMP,
        \\  invited_by TEXT,
        \\  PRIMARY KEY (workspace_id, user_id)
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_secrets (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  value TEXT NOT NULL,
        \\  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_one', 'One'), ('ws_two', 'Two')", &.{});
    try db.exec(alloc,
        \\INSERT INTO users (id, email, name) VALUES
        \\  ('user_amy', 'amy@example.com', 'Amy'),
        \\  ('user_ben', 'ben@example.com', 'Ben')
    , &.{});
    // Amy is a member of ws_one only; Ben of ws_two only.
    try db.exec(alloc,
        \\INSERT INTO workspace_members (workspace_id, user_id, role) VALUES
        \\  ('ws_one', 'user_amy', 'owner'),
        \\  ('ws_two', 'user_ben', 'owner')
    , &.{});

    for ([_][]const u8{ "raw_token_amy", "raw_token_ben" }) |token| {
        const row = sessionRow(if (std.mem.eql(u8, token, "raw_token_amy")) "user_amy" else "user_ben", token);
        try db.exec(alloc,
            \\INSERT INTO auth_sessions (token_hash, user_id, expires_at)
            \\VALUES (?, ?, datetime('now', '+1 day'))
        , &[_][]const u8{ &row.hash, row.user_id });
    }
    return .{ .db = db, .threaded = threaded };
}

fn seedSecret(ctx: *TestCtx, id: []const u8, workspace_id: []const u8, name: []const u8, value: []const u8) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value) VALUES (?, ?, ?, ?)
    , &[_][]const u8{ id, workspace_id, name, value });
}

test "reveal: a member of the workspace gets the plaintext" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSecret(&ctx, "sec_1", "ws_one", "STRIPE", "sk_live_plain");
    const cookie = try cookieFor(alloc, "raw_token_amy");
    defer alloc.free(cookie);

    const out = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_one", .secret_id = "sec_1" }, true, Cookie{ .token = cookie });
    defer secrets_store.freeRevealedSecret(alloc, out.secret);

    try testing.expectEqualStrings("sec_1", out.secret.id);
    try testing.expectEqualStrings("STRIPE", out.secret.name);
    try testing.expectEqualStrings("sk_live_plain", out.secret.value);
}

test "reveal: a signed-in non-member gets 404, and cannot tell the id exists" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSecret(&ctx, "sec_1", "ws_one", "STRIPE", "sk_live_plain");
    const cookie = try cookieFor(alloc, "raw_token_ben");
    defer alloc.free(cookie);

    // Ben is signed in and owns ws_two. Asking for ws_one is "not found"...
    try testing.expectError(
        error.WorkspaceNotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_one", .secret_id = "sec_1" }, true, Cookie{ .token = cookie }),
    );
    // ...and asking for his OWN workspace with a foreign secret id is the same
    // answer, so this route cannot be used to probe for secret ids.
    try testing.expectError(
        error.NotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_two", .secret_id = "sec_1" }, true, Cookie{ .token = cookie }),
    );
}

test "reveal: with auth off the installation owner may read any workspace" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedSecret(&ctx, "sec_1", "ws_one", "STRIPE", "sk_live_plain");

    const out = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_one", .secret_id = "sec_1" }, false, NoCookie{});
    defer secrets_store.freeRevealedSecret(alloc, out.secret);
    try testing.expectEqualStrings("sk_live_plain", out.secret.value);
}

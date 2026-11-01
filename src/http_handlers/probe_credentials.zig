//! Credential placeholders in a "Test" probe request body: `{` `{SECRETS:NAME}` `}`
//! resolved against the workspace's secrets BEFORE the probe leaves the
//! process, so a saved placeholder is tested the way a run would use it.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gate = @import("workspace_members_gate.zig");
const credential_resolver = @import("../agentic_loop/credential_resolver.zig");
const secrets_substitution = @import("../agentic_loop/secrets_substitution.zig");

const placeholder_prefix = "{" ++ "{SECRETS:";

pub const Error = error{
    /// A credential carried a placeholder and the request named no workspace.
    WorkspaceIdRequired,
    /// The caller cannot see the workspace, or it does not exist.
    WorkspaceNotFound,
    /// The caller can see the workspace but is not a member of it.
    Forbidden,
    /// The placeholder named a secret this workspace does not store.
    UnknownSecretName,
    /// The body is not a JSON object, so it has no credential position.
    InvalidBody,
    OutOfMemory,
};

/// What the probe should send instead: `body` owns that document, and
/// `resolved` names every value inside it so the probe's own output can be
/// redacted back to the placeholder.
pub const Credentials = struct {
    body: []u8,
    resolved: []const secrets_substitution.ResolvedSecret,

    pub fn deinit(self: *const Credentials, allocator: std.mem.Allocator) void {
        for (self.resolved) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        allocator.free(self.resolved);
        allocator.free(self.body);
    }
};

/// Rewrite the ROOT fields of `body` named by `fields` with the values stored
/// in `workspace_id`, after a membership check. A body with no placeholder
/// comes back as a copy and reads no secret.
pub fn resolve(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    auth_enabled: bool,
    headers: anytype,
    workspace_id: []const u8,
    body: []const u8,
    fields: []const []const u8,
    out_missing_name: *?[]const u8,
) Error!Credentials {
    if (std.mem.indexOf(u8, body, placeholder_prefix) == null) {
        return .{ .body = try allocator.dupe(u8, body), .resolved = &.{} };
    }

    // `out_missing_name` is filled only on UnknownSecretName.
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;

    // Membership, not mere visibility: a shared workspace is visible to
    // everybody and its credentials are not.
    gate.checkRequest(allocator, db, auth_enabled, headers, workspace_id, .read) catch |err| switch (err) {
        error.WorkspaceIdRequired => return error.WorkspaceIdRequired,
        error.WorkspaceNotFound => return error.WorkspaceNotFound,
        error.Forbidden => return error.Forbidden,
        error.QueryFailed => return error.WorkspaceNotFound,
        error.OutOfMemory => return error.OutOfMemory,
    };

    var resolver = credential_resolver.StoreResolver.init(allocator, db, workspace_id);
    defer resolver.deinit();

    var resolved: std.ArrayList(secrets_substitution.ResolvedSecret) = .empty;
    errdefer {
        for (resolved.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        resolved.deinit(allocator);
    }

    const substituted = secrets_substitution.substituteRootCredentialFields(
        allocator,
        body,
        fields,
        credential_resolver.StoreResolver.lookup,
        &resolver,
        &resolved,
    ) catch |err| switch (err) {
        error.UnknownSecretName => {
            if (resolver.missing_name) |name| {
                out_missing_name.* = allocator.dupe(u8, name) catch null;
            }
            return error.UnknownSecretName;
        },
        error.InvalidArguments => return error.InvalidBody,
        error.OutOfMemory => return error.OutOfMemory,
    };

    return .{ .body = substituted, .resolved = try resolved.toOwnedSlice(allocator) };
}

/// Why a probe could not resolve its credentials, in words the modal can show.
pub fn describe(
    allocator: std.mem.Allocator,
    err: Error,
    missing_name: ?[]const u8,
) Error![]u8 {
    return switch (err) {
        error.WorkspaceIdRequired => allocator.dupe(u8, "the credential uses a workspace secret, but the request named no workspace to resolve it against"),
        error.WorkspaceNotFound => allocator.dupe(u8, "workspace not found"),
        error.Forbidden => allocator.dupe(u8, "only a member of that workspace can use its secrets"),
        error.UnknownSecretName => std.fmt.allocPrint(
            allocator,
            "this workspace stores no secret named '{s}'",
            .{missing_name orelse ""},
        ),
        error.InvalidBody => allocator.dupe(u8, "the request body is not a JSON object"),
        error.OutOfMemory => allocator.dupe(u8, "out of memory"),
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const database = pabrikcore.database;
const auth_core = @import("auth_core");
const migration = @import("../migrations/migration.zig");
const secrets_store = @import("../agentic_loop/secrets_store.zig");
const workspace_settings_store = @import("../agentic_loop/workspace_settings_store.zig");

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

/// A cookie-carrying requester, parsed exactly like a real one: the gate sees
/// header names only.
const Cookie = struct {
    token: []const u8,

    pub fn get(self: @This(), name: []const u8) ?[]const u8 {
        if (!std.mem.eql(u8, name, "Cookie")) return null;
        return self.token;
    }
};

/// No cookie, so identity falls back to the installation owner — the
/// auth-off deployment these routes also serve.
const NoCookie = struct {
    pub fn get(_: @This(), _: []const u8) ?[]const u8 {
        return null;
    }
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    workspace_settings_store.installTestKey();
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn seedWorkspace(db: *database.Db, id: []const u8) !void {
    try db.exec(
        testing.allocator,
        "INSERT INTO workspaces (id, name) VALUES (?, ?)",
        &[_][]const u8{ id, id },
    );
}

fn seedMember(db: *database.Db, workspace_id: []const u8, user_id: []const u8) !void {
    try db.exec(
        testing.allocator,
        "INSERT INTO workspace_members (workspace_id, user_id, role) VALUES (?, ?, 'owner')",
        &[_][]const u8{ workspace_id, user_id },
    );
}

fn seedUserSession(db: *database.Db, user_id: []const u8, raw_token: []const u8) !void {
    const alloc = testing.allocator;
    try db.exec(
        alloc,
        "INSERT INTO users (id, email, password_hash) VALUES (?, ?, 'h')",
        &[_][]const u8{ user_id, user_id },
    );
    var hash: [64]u8 = undefined;
    auth_core.sha256Hex(raw_token, &hash);
    try db.exec(
        alloc,
        "INSERT INTO auth_sessions (token_hash, user_id, expires_at) VALUES (?, ?, datetime('now', '+1 day'))",
        &[_][]const u8{ &hash, user_id },
    );
}

fn seedSecret(db: *database.Db, workspace_id: []const u8, name: []const u8, value: []const u8) !void {
    const row = try secrets_store.createSecret(testing.allocator, db, .{
        .workspace_id = workspace_id,
        .name = name,
        .value = value,
    });
    secrets_store.freeSecretRow(testing.allocator, row);
}

fn placeholder(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ "{", "{SECRETS:", name, "}" ++ "}" });
}

fn cookieFor(allocator: std.mem.Allocator, raw_token: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "theme=dark; {s}={s}", .{ auth_core.cookie_name, raw_token });
}

test "probe credentials: a stored secret replaces the placeholder before the probe leaves" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedWorkspace(&ctx.db, "ws_a");
    try seedSecret(&ctx.db, "ws_a", "API_KEY", "sk-live-value");

    const key_ph = try placeholder(alloc, "API_KEY");
    defer alloc.free(key_ph);
    const body = try std.fmt.allocPrint(
        alloc,
        "{{\"model\":\"deepseek-v4\",\"base_url\":\"https://api.example.com\",\"api_key\":\"{s}\"}}",
        .{key_ph},
    );
    defer alloc.free(body);

    var missing: ?[]const u8 = null;
    defer if (missing) |name| alloc.free(name);
    const creds = try resolve(alloc, &ctx.db, false, NoCookie{}, "ws_a", body, &.{"api_key"}, &missing);
    defer creds.deinit(alloc);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, creds.body, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("sk-live-value", parsed.value.object.get("api_key").?.string);
    try testing.expectEqualStrings("deepseek-v4", parsed.value.object.get("model").?.string);
    try testing.expect(missing == null);

    // The value is named in `resolved`, which is what lets the probe's own
    // output be redacted back to the placeholder.
    try testing.expectEqual(@as(usize, 1), creds.resolved.len);
    try testing.expectEqualStrings("API_KEY", creds.resolved[0].name);
    try testing.expectEqualStrings("sk-live-value", creds.resolved[0].value);
}

test "probe credentials: a placeholder with no workspace is refused, never sent as text" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedWorkspace(&ctx.db, "ws_a");
    try seedSecret(&ctx.db, "ws_a", "API_KEY", "sk-live-value");

    const key_ph = try placeholder(alloc, "API_KEY");
    defer alloc.free(key_ph);
    const body = try std.fmt.allocPrint(alloc, "{{\"api_key\":\"{s}\"}}", .{key_ph});
    defer alloc.free(body);

    var missing: ?[]const u8 = null;
    defer if (missing) |name| alloc.free(name);
    try testing.expectError(
        error.WorkspaceIdRequired,
        resolve(alloc, &ctx.db, false, NoCookie{}, "", body, &.{"api_key"}, &missing),
    );

    const message = try describe(alloc, error.WorkspaceIdRequired, null);
    defer alloc.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "no workspace") != null);
}

test "probe credentials: an unknown name is reported by name, not as a bare failure" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedWorkspace(&ctx.db, "ws_a");

    const missing_ph = try placeholder(alloc, "NOT_STORED");
    defer alloc.free(missing_ph);
    const body = try std.fmt.allocPrint(alloc, "{{\"api_key\":\"{s}\"}}", .{missing_ph});
    defer alloc.free(body);

    var missing: ?[]const u8 = null;
    defer if (missing) |name| alloc.free(name);
    try testing.expectError(
        error.UnknownSecretName,
        resolve(alloc, &ctx.db, false, NoCookie{}, "ws_a", body, &.{"api_key"}, &missing),
    );
    try testing.expectEqualStrings("NOT_STORED", missing.?);

    const message = try describe(alloc, error.UnknownSecretName, missing);
    defer alloc.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "NOT_STORED") != null);
    // The message names the secret; it must never carry a value.
    try testing.expect(std.mem.indexOf(u8, message, "sk-") == null);
}

test "probe credentials: a non-member cannot resolve another workspace's secret" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedWorkspace(&ctx.db, "ws_ben");
    try seedSecret(&ctx.db, "ws_ben", "API_KEY", "sk-ben-only");
    try seedWorkspace(&ctx.db, "ws_amy");
    try seedUserSession(&ctx.db, "user_amy", "raw_token_amy");
    try seedMember(&ctx.db, "ws_amy", "user_amy");

    const key_ph = try placeholder(alloc, "API_KEY");
    defer alloc.free(key_ph);
    const body = try std.fmt.allocPrint(alloc, "{{\"api_key\":\"{s}\"}}", .{key_ph});
    defer alloc.free(body);

    const cookie = try cookieFor(alloc, "raw_token_amy");
    defer alloc.free(cookie);

    var missing: ?[]const u8 = null;
    defer if (missing) |name| alloc.free(name);
    try testing.expectError(
        error.WorkspaceNotFound,
        resolve(alloc, &ctx.db, true, Cookie{ .token = cookie }, "ws_ben", body, &.{"api_key"}, &missing),
    );

    // Positive control: the same caller DOES resolve in their own workspace,
    // so the refusal above is membership and not a broken lookup.
    try seedSecret(&ctx.db, "ws_amy", "API_KEY", "sk-amy");
    const own = try resolve(alloc, &ctx.db, true, Cookie{ .token = cookie }, "ws_amy", body, &.{"api_key"}, &missing);
    defer own.deinit(alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, own.body, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("sk-amy", parsed.value.object.get("api_key").?.string);
}

test "probe credentials: a body without a placeholder needs no workspace and reads no secret" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const body = "{\"model\":\"m\",\"base_url\":\"https://api.example.com\",\"api_key\":\"sk-plain\"}";
    var missing: ?[]const u8 = null;
    defer if (missing) |name| alloc.free(name);
    const creds = try resolve(alloc, &ctx.db, false, NoCookie{}, "", body, &.{"api_key"}, &missing);
    defer creds.deinit(alloc);

    try testing.expectEqualStrings(body, creds.body);
    try testing.expectEqual(@as(usize, 0), creds.resolved.len);
}

test "probe credentials: only the named fields are rewritten, and a stray placeholder elsewhere is left literal" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedWorkspace(&ctx.db, "ws_a");
    try seedSecret(&ctx.db, "ws_a", "API_KEY", "sk-live-value");

    const key_ph = try placeholder(alloc, "API_KEY");
    defer alloc.free(key_ph);
    const body = try std.fmt.allocPrint(
        alloc,
        "{{\"command\":\"npx\",\"args\":[\"{s}\"],\"api_key\":\"{s}\"}}",
        .{ key_ph, key_ph },
    );
    defer alloc.free(body);

    var missing: ?[]const u8 = null;
    defer if (missing) |name| alloc.free(name);
    const creds = try resolve(alloc, &ctx.db, false, NoCookie{}, "ws_a", body, &.{"api_key"}, &missing);
    defer creds.deinit(alloc);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, creds.body, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("sk-live-value", parsed.value.object.get("api_key").?.string);
    // `args` is not a credential position, and a run does not resolve it
    // either: a probe that did would pass where the run fails.
    try testing.expectEqualStrings(key_ph, parsed.value.object.get("args").?.array.items[0].string);
}

test "probe credentials: a body that is not a JSON object is reported, not forwarded" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedWorkspace(&ctx.db, "ws_a");
    try seedSecret(&ctx.db, "ws_a", "API_KEY", "sk-live-value");

    const key_ph = try placeholder(alloc, "API_KEY");
    defer alloc.free(key_ph);
    const body = try std.fmt.allocPrint(alloc, "[\"{s}\"]", .{key_ph});
    defer alloc.free(body);

    var missing: ?[]const u8 = null;
    defer if (missing) |name| alloc.free(name);
    try testing.expectError(
        error.InvalidBody,
        resolve(alloc, &ctx.db, false, NoCookie{}, "ws_a", body, &.{"api_key"}, &missing),
    );
}

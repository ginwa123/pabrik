const std = @import("std");
const pabrikcore = @import("pabrikcore");
const database = pabrikcore.database;
const secrets_store = pabrikcore.secrets_store;
const helpers = @import("helpers");

pub const StoreError = error{
    WorkspaceIdRequired,
    ServerNameRequired,
    StateRequired,
    QueryFailed,
    InsertFailed,
    DeleteFailed,
    SealingUnavailable,
    ValueUnreadable,
    OutOfMemory,
};

pub const Credential = enum {
    access_token,
    refresh_token,
    client_secret,
    code_verifier,

    fn suffix(self: Credential) []const u8 {
        return switch (self) {
            .access_token => "ACCESS_TOKEN",
            .refresh_token => "REFRESH_TOKEN",
            .client_secret => "CLIENT_SECRET",
            .code_verifier => "CODE_VERIFIER",
        };
    }
};

pub const name_prefix = "MCP_OAUTH_";
const max_name_len = secrets_store.MAX_NAME_LEN;
const max_slug_len = max_name_len - name_prefix.len - "_REFRESH_TOKEN".len;

pub fn secretName(allocator: std.mem.Allocator, server_name: []const u8, kind: Credential) ![]u8 {
    var slug_buf: [max_slug_len]u8 = undefined;
    var n: usize = 0;
    for (server_name) |c| {
        if (n >= max_slug_len) break;
        const up = std.ascii.toUpper(c);
        const allowed = (up >= 'A' and up <= 'Z') or (up >= '0' and up <= '9') or up == '_' or up == '-';
        slug_buf[n] = if (allowed) up else '_';
        n += 1;
    }
    if (n == 0) {
        slug_buf[0] = 'X';
        n = 1;
    }
    if (server_name.len > max_slug_len) {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(server_name, &digest, .{});
        const hex = std.fmt.bytesToHex(digest[0..4].*, .lower);
        const keep = max_slug_len - 9;
        @memcpy(slug_buf[keep..][0..8], &hex);
        slug_buf[keep + 8] = '_';
        n = max_slug_len;
    }
    return std.fmt.allocPrint(allocator, "{s}{s}_{s}", .{ name_prefix, slug_buf[0..n], kind.suffix() });
}

pub const TokenRecord = struct {
    workspace_id: []const u8,
    server_name: []const u8,
    resource: []const u8 = "",
    issuer: []const u8 = "",
    client_id: []const u8 = "",
    client_secret: []const u8 = "",
    token_endpoint: []const u8 = "",
    access_token: []const u8,
    refresh_token: []const u8 = "",
    token_type: []const u8 = "Bearer",
    scope: []const u8 = "",
    expires_at: ?i64 = null,

    pub fn deinit(self: *const TokenRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.server_name);
        allocator.free(self.resource);
        allocator.free(self.issuer);
        allocator.free(self.client_id);
        allocator.free(self.client_secret);
        allocator.free(self.token_endpoint);
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
        allocator.free(self.token_type);
        allocator.free(self.scope);
    }
};

pub const PendingRecord = struct {
    state: []const u8,
    workspace_id: []const u8,
    server_name: []const u8,
    resource: []const u8 = "",
    issuer: []const u8 = "",
    client_id: []const u8 = "",
    authorization_endpoint: []const u8 = "",
    token_endpoint: []const u8 = "",
    redirect_uri: []const u8 = "",
    code_verifier: []const u8 = "",
    scope: []const u8 = "",

    pub fn deinit(self: *const PendingRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.state);
        allocator.free(self.workspace_id);
        allocator.free(self.server_name);
        allocator.free(self.resource);
        allocator.free(self.issuer);
        allocator.free(self.client_id);
        allocator.free(self.authorization_endpoint);
        allocator.free(self.token_endpoint);
        allocator.free(self.redirect_uri);
        allocator.free(self.code_verifier);
        allocator.free(self.scope);
    }
};

fn tokenRowId(allocator: std.mem.Allocator, workspace_id: []const u8, server_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "moat:{d}:{s}:{s}", .{ workspace_id.len, workspace_id, server_name });
}

fn findSecretId(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    name: []const u8,
) StoreError!?[]u8 {
    var q = db.query(
        allocator,
        "SELECT id FROM workspace_secrets WHERE workspace_id = ? AND name = ?",
        &[_][]const u8{ workspace_id, name },
    ) catch return error.QueryFailed;
    defer q.deinit();
    const row = (q.next() catch return error.QueryFailed) orelse return null;
    defer row.deinit(allocator);
    return try allocator.dupe(u8, row.values[0]);
}

fn putSecret(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    name: []const u8,
    value: []const u8,
    description: []const u8,
) StoreError!void {
    if (value.len == 0) return deleteSecretByName(allocator, db, workspace_id, name);

    if (try findSecretId(allocator, db, workspace_id, name)) |id| {
        defer allocator.free(id);
        const row = secrets_store.updateSecret(allocator, db, .{
            .workspace_id = workspace_id,
            .secret_id = id,
            .value = value,
        }) catch |err| return mapSecretsError(err);
        secrets_store.freeSecretRow(allocator, row);
        return;
    }

    const row = secrets_store.createSecret(allocator, db, .{
        .workspace_id = workspace_id,
        .name = name,
        .value = value,
        .description = description,
    }) catch |err| return mapSecretsError(err);
    secrets_store.freeSecretRow(allocator, row);
}

fn getSecretValue(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    name: []const u8,
) StoreError!?[]u8 {
    const names = [_][]const u8{name};
    const rows = secrets_store.loadSecretValues(allocator, db, workspace_id, &names) catch |err| switch (err) {
        error.ValueUnreadable => return error.ValueUnreadable,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.QueryFailed,
    };
    defer secrets_store.freeSecretValueRows(allocator, rows);
    if (rows.len == 0) return null;
    return try allocator.dupe(u8, rows[0].value);
}

fn deleteSecretByName(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    name: []const u8,
) StoreError!void {
    const id = (try findSecretId(allocator, db, workspace_id, name)) orelse return;
    defer allocator.free(id);
    secrets_store.deleteSecret(allocator, db, workspace_id, id) catch |err| switch (err) {
        error.NotFound => {},
        else => return error.DeleteFailed,
    };
}

fn mapSecretsError(err: anyerror) StoreError {
    return switch (err) {
        error.SealingUnavailable => error.SealingUnavailable,
        error.OutOfMemory => error.OutOfMemory,
        error.ValueUnreadable => error.ValueUnreadable,
        error.QueryFailed => error.QueryFailed,
        error.DeleteFailed => error.DeleteFailed,
        else => error.InsertFailed,
    };
}

fn credentialDescription(
    allocator: std.mem.Allocator,
    server_name: []const u8,
    kind: Credential,
) ![]u8 {
    const label = switch (kind) {
        .access_token => "access token",
        .refresh_token => "refresh token",
        .client_secret => "client secret",
        .code_verifier => "PKCE code verifier",
    };
    const shown = server_name[0..@min(server_name.len, 120)];
    return std.fmt.allocPrint(allocator, "MCP OAuth {s} for server '{s}' (managed by pabrik)", .{ label, shown });
}

fn putCredential(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    server_name: []const u8,
    kind: Credential,
    value: []const u8,
) StoreError!void {
    const name = try secretName(allocator, server_name, kind);
    defer allocator.free(name);
    const description = try credentialDescription(allocator, server_name, kind);
    defer allocator.free(description);
    try putSecret(allocator, db, workspace_id, name, value, description);
}

fn getCredential(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    server_name: []const u8,
    kind: Credential,
) StoreError!?[]u8 {
    const name = try secretName(allocator, server_name, kind);
    defer allocator.free(name);
    return getSecretValue(allocator, db, workspace_id, name);
}

fn deleteCredential(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    server_name: []const u8,
    kind: Credential,
) StoreError!void {
    const name = try secretName(allocator, server_name, kind);
    defer allocator.free(name);
    try deleteSecretByName(allocator, db, workspace_id, name);
}

fn expiresAtText(buf: *[24]u8, expires_at: ?i64) []const u8 {
    const at = expires_at orelse return "";
    return std.fmt.bufPrint(buf, "{d}", .{at}) catch "";
}

pub fn saveToken(allocator: std.mem.Allocator, db: *database.Db, rec: TokenRecord) StoreError!void {
    if (rec.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (rec.server_name.len == 0) return error.ServerNameRequired;
    if (rec.access_token.len == 0) return error.InsertFailed;

    try putCredential(allocator, db, rec.workspace_id, rec.server_name, .access_token, rec.access_token);
    try putCredential(allocator, db, rec.workspace_id, rec.server_name, .refresh_token, rec.refresh_token);
    try putCredential(allocator, db, rec.workspace_id, rec.server_name, .client_secret, rec.client_secret);

    const id = try tokenRowId(allocator, rec.workspace_id, rec.server_name);
    defer allocator.free(id);

    var buf: [24]u8 = undefined;
    const expires_text = expiresAtText(&buf, rec.expires_at);

    db.exec(allocator,
        \\INSERT INTO mcp_oauth_tokens
        \\  (id, workspace_id, server_name, resource, issuer, client_id, token_endpoint,
        \\   token_type, scope, expires_at, created_at, updated_at)
        \\VALUES (?, ?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\        COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\        COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\        CAST(NULLIF(?, '') AS BIGINT), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        \\ON CONFLICT (workspace_id, server_name) DO UPDATE SET
        \\  resource = excluded.resource,
        \\  issuer = excluded.issuer,
        \\  client_id = excluded.client_id,
        \\  token_endpoint = excluded.token_endpoint,
        \\  token_type = excluded.token_type,
        \\  scope = excluded.scope,
        \\  expires_at = excluded.expires_at,
        \\  updated_at = CURRENT_TIMESTAMP
    , &[_][]const u8{
        id,
        rec.workspace_id,
        rec.server_name,
        rec.resource,
        rec.issuer,
        rec.client_id,
        rec.token_endpoint,
        rec.token_type,
        rec.scope,
        expires_text,
    }) catch return error.InsertFailed;
}

pub fn loadToken(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    server_name: []const u8,
) StoreError!?TokenRecord {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (server_name.len == 0) return error.ServerNameRequired;

    var q = db.query(allocator,
        \\SELECT resource, issuer, client_id, token_endpoint, token_type, scope,
        \\       COALESCE(CAST(expires_at AS TEXT), '')
        \\FROM mcp_oauth_tokens WHERE workspace_id = ? AND server_name = ?
    , &[_][]const u8{ workspace_id, server_name }) catch return error.QueryFailed;
    defer q.deinit();

    const row = (q.next() catch return error.QueryFailed) orelse return null;
    defer row.deinit(allocator);

    const access = (try getCredential(allocator, db, workspace_id, server_name, .access_token)) orelse return null;
    errdefer allocator.free(access);
    const refresh = (try getCredential(allocator, db, workspace_id, server_name, .refresh_token)) orelse
        try allocator.dupe(u8, "");
    errdefer allocator.free(refresh);
    const secret = (try getCredential(allocator, db, workspace_id, server_name, .client_secret)) orelse
        try allocator.dupe(u8, "");
    errdefer allocator.free(secret);

    const expires_at: ?i64 = if (row.values[6].len == 0)
        null
    else
        std.fmt.parseInt(i64, row.values[6], 10) catch null;

    return .{
        .workspace_id = try allocator.dupe(u8, workspace_id),
        .server_name = try allocator.dupe(u8, server_name),
        .resource = try allocator.dupe(u8, row.values[0]),
        .issuer = try allocator.dupe(u8, row.values[1]),
        .client_id = try allocator.dupe(u8, row.values[2]),
        .client_secret = secret,
        .token_endpoint = try allocator.dupe(u8, row.values[3]),
        .access_token = access,
        .refresh_token = refresh,
        .token_type = try allocator.dupe(u8, row.values[4]),
        .scope = try allocator.dupe(u8, row.values[5]),
        .expires_at = expires_at,
    };
}

pub fn deleteToken(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    server_name: []const u8,
) StoreError!void {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (server_name.len == 0) return error.ServerNameRequired;

    try deleteCredential(allocator, db, workspace_id, server_name, .access_token);
    try deleteCredential(allocator, db, workspace_id, server_name, .refresh_token);
    try deleteCredential(allocator, db, workspace_id, server_name, .client_secret);

    db.exec(
        allocator,
        "DELETE FROM mcp_oauth_tokens WHERE workspace_id = ? AND server_name = ?",
        &[_][]const u8{ workspace_id, server_name },
    ) catch return error.DeleteFailed;
}

pub fn savePending(allocator: std.mem.Allocator, db: *database.Db, rec: PendingRecord) StoreError!void {
    if (rec.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (rec.server_name.len == 0) return error.ServerNameRequired;
    if (rec.state.len == 0) return error.StateRequired;

    try putCredential(allocator, db, rec.workspace_id, rec.server_name, .code_verifier, rec.code_verifier);

    db.exec(allocator,
        \\INSERT INTO mcp_oauth_pending
        \\  (state, workspace_id, server_name, resource, issuer, client_id,
        \\   authorization_endpoint, token_endpoint, redirect_uri, scope, created_at)
        \\VALUES (?, ?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\        COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\        COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\        COALESCE(NULLIF(?, ''), ''), CURRENT_TIMESTAMP)
        \\ON CONFLICT (state) DO UPDATE SET
        \\  workspace_id = excluded.workspace_id,
        \\  server_name = excluded.server_name,
        \\  resource = excluded.resource,
        \\  issuer = excluded.issuer,
        \\  client_id = excluded.client_id,
        \\  authorization_endpoint = excluded.authorization_endpoint,
        \\  token_endpoint = excluded.token_endpoint,
        \\  redirect_uri = excluded.redirect_uri,
        \\  scope = excluded.scope
    , &[_][]const u8{
        rec.state,
        rec.workspace_id,
        rec.server_name,
        rec.resource,
        rec.issuer,
        rec.client_id,
        rec.authorization_endpoint,
        rec.token_endpoint,
        rec.redirect_uri,
        rec.scope,
    }) catch return error.InsertFailed;
}

pub fn takePending(
    allocator: std.mem.Allocator,
    db: *database.Db,
    state: []const u8,
) StoreError!?PendingRecord {
    if (state.len == 0) return error.StateRequired;

    var q = db.query(allocator,
        \\SELECT workspace_id, server_name, resource, issuer, client_id,
        \\       authorization_endpoint, token_endpoint, redirect_uri, scope
        \\FROM mcp_oauth_pending WHERE state = ?
    , &[_][]const u8{state}) catch return error.QueryFailed;
    defer q.deinit();

    const row = (q.next() catch return error.QueryFailed) orelse return null;
    defer row.deinit(allocator);

    const verifier = (try getCredential(allocator, db, row.values[0], row.values[1], .code_verifier)) orelse
        try allocator.dupe(u8, "");
    errdefer allocator.free(verifier);

    const out = PendingRecord{
        .state = try allocator.dupe(u8, state),
        .workspace_id = try allocator.dupe(u8, row.values[0]),
        .server_name = try allocator.dupe(u8, row.values[1]),
        .resource = try allocator.dupe(u8, row.values[2]),
        .issuer = try allocator.dupe(u8, row.values[3]),
        .client_id = try allocator.dupe(u8, row.values[4]),
        .authorization_endpoint = try allocator.dupe(u8, row.values[5]),
        .token_endpoint = try allocator.dupe(u8, row.values[6]),
        .redirect_uri = try allocator.dupe(u8, row.values[7]),
        .code_verifier = verifier,
        .scope = try allocator.dupe(u8, row.values[8]),
    };
    errdefer out.deinit(allocator);

    db.exec(allocator, "DELETE FROM mcp_oauth_pending WHERE state = ?", &[_][]const u8{state}) catch
        return error.DeleteFailed;
    try deleteCredential(allocator, db, out.workspace_id, out.server_name, .code_verifier);
    return out;
}

pub fn deletePendingForServer(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    server_name: []const u8,
) StoreError!void {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (server_name.len == 0) return error.ServerNameRequired;

    db.exec(
        allocator,
        "DELETE FROM mcp_oauth_pending WHERE workspace_id = ? AND server_name = ?",
        &[_][]const u8{ workspace_id, server_name },
    ) catch return error.DeleteFailed;
    try deleteCredential(allocator, db, workspace_id, server_name, .code_verifier);
}

pub fn nowSeconds() i64 {
    return @intCast(@divTrunc(helpers.unixTimestampNanos(), std.time.ns_per_s));
}

const testing = std.testing;
const test_db = pabrikcore.test_db;

const TestCtx = struct {
    db: database.Db = .{},
    threaded: std.Io.Threaded,

    fn open() !TestCtx {
        var threaded = std.Io.Threaded.init(testing.allocator, .{});
        errdefer threaded.deinit();
        var ctx = TestCtx{ .threaded = threaded };
        try test_db.openMemory(&ctx.db, ctx.threaded.io());
        try pabrikcore.migrations_mod.migration.Migration146AddMcpOAuth.up(&ctx.db, testing.allocator);
        try ctx.db.exec(testing.allocator,
            \\CREATE TABLE IF NOT EXISTS workspace_secrets (
            \\  id TEXT PRIMARY KEY,
            \\  workspace_id TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  value TEXT NOT NULL DEFAULT '',
            \\  description TEXT DEFAULT NULL,
            \\  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});
        return ctx;
    }

    fn deinit(self: *TestCtx) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

fn sampleToken(access: []const u8) TokenRecord {
    return .{
        .workspace_id = "ws_1",
        .server_name = "files",
        .resource = "https://mcp.example.com/mcp",
        .issuer = "https://as.example.com",
        .client_id = "client-1",
        .client_secret = "cs-1",
        .token_endpoint = "https://as.example.com/token",
        .access_token = access,
        .refresh_token = "rt-1",
        .token_type = "Bearer",
        .scope = "files:read",
        .expires_at = 1_800_000_000,
    };
}

fn rawSecretValue(allocator: std.mem.Allocator, db: *database.Db, name: []const u8) ![]u8 {
    var q = try db.query(allocator, "SELECT value FROM workspace_secrets WHERE name = ?", &[_][]const u8{name});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(allocator);
    return try allocator.dupe(u8, row.values[0]);
}

test "a saved token reads back with its access token and metadata" {
    var ctx = try TestCtx.open();
    defer ctx.deinit();

    try saveToken(testing.allocator, &ctx.db, sampleToken("at-1"));

    const loaded = (try loadToken(testing.allocator, &ctx.db, "ws_1", "files")) orelse return error.TestUnexpectedResult;
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings("at-1", loaded.access_token);
    try testing.expectEqualStrings("rt-1", loaded.refresh_token);
    try testing.expectEqualStrings("cs-1", loaded.client_secret);
    try testing.expectEqualStrings("https://as.example.com/token", loaded.token_endpoint);
    try testing.expectEqualStrings("files:read", loaded.scope);
    try testing.expectEqual(@as(?i64, 1_800_000_000), loaded.expires_at);
}

test "every credential is stored as a sealed workspace secret" {
    var ctx = try TestCtx.open();
    defer ctx.deinit();

    try saveToken(testing.allocator, &ctx.db, sampleToken("at-secret-value"));

    const cases = [_]struct { kind: Credential, plaintext: []const u8 }{
        .{ .kind = .access_token, .plaintext = "at-secret-value" },
        .{ .kind = .refresh_token, .plaintext = "rt-1" },
        .{ .kind = .client_secret, .plaintext = "cs-1" },
    };
    for (cases) |case| {
        const name = try secretName(testing.allocator, "files", case.kind);
        defer testing.allocator.free(name);
        const stored = try rawSecretValue(testing.allocator, &ctx.db, name);
        defer testing.allocator.free(stored);
        try testing.expect(std.mem.indexOf(u8, stored, case.plaintext) == null);
        try testing.expect(pabrikcore.secrets_at_rest.isSealed(stored));
    }
}

test "the metadata table holds no credential value" {
    var ctx = try TestCtx.open();
    defer ctx.deinit();

    try saveToken(testing.allocator, &ctx.db, sampleToken("at-secret-value"));

    var q = try ctx.db.query(testing.allocator,
        \\SELECT resource || issuer || client_id || token_endpoint || token_type || scope FROM mcp_oauth_tokens
    , &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "at-secret-value") == null);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "rt-1") == null);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "cs-1") == null);
}

test "the pkce verifier is stored as a sealed workspace secret" {
    var ctx = try TestCtx.open();
    defer ctx.deinit();

    try savePending(testing.allocator, &ctx.db, .{
        .state = "st_1",
        .workspace_id = "ws_1",
        .server_name = "files",
        .code_verifier = "verifier-secret-value",
    });

    const name = try secretName(testing.allocator, "files", .code_verifier);
    defer testing.allocator.free(name);
    const stored = try rawSecretValue(testing.allocator, &ctx.db, name);
    defer testing.allocator.free(stored);
    try testing.expect(std.mem.indexOf(u8, stored, "verifier-secret-value") == null);
    try testing.expect(pabrikcore.secrets_at_rest.isSealed(stored));
}

test "a sealed credential cannot be opened from another secret row" {
    var ctx = try TestCtx.open();
    defer ctx.deinit();

    try saveToken(testing.allocator, &ctx.db, sampleToken("at-1"));

    const source = try secretName(testing.allocator, "files", .access_token);
    defer testing.allocator.free(source);
    const stolen = try rawSecretValue(testing.allocator, &ctx.db, source);
    defer testing.allocator.free(stolen);

    try ctx.db.exec(testing.allocator,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value) VALUES ('sec_other', 'ws_1', 'OTHER_TOKEN', ?)
    , &[_][]const u8{stolen});

    const names = [_][]const u8{"OTHER_TOKEN"};
    try testing.expectError(
        error.ValueUnreadable,
        secrets_store.loadSecretValues(testing.allocator, &ctx.db, "ws_1", &names),
    );
}

test "saving a second token for the same server replaces the first" {
    var ctx = try TestCtx.open();
    defer ctx.deinit();

    try saveToken(testing.allocator, &ctx.db, sampleToken("at-1"));
    try saveToken(testing.allocator, &ctx.db, sampleToken("at-2"));

    const loaded = (try loadToken(testing.allocator, &ctx.db, "ws_1", "files")) orelse return error.TestUnexpectedResult;
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings("at-2", loaded.access_token);

    var q = try ctx.db.query(testing.allocator, "SELECT COUNT(*) FROM mcp_oauth_tokens", &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "two workspaces keep their own token for the same server name" {
    var ctx = try TestCtx.open();
    defer ctx.deinit();

    var a = sampleToken("at-a");
    a.workspace_id = "ws_a";
    var b = sampleToken("at-b");
    b.workspace_id = "ws_b";
    try saveToken(testing.allocator, &ctx.db, a);
    try saveToken(testing.allocator, &ctx.db, b);

    const loaded_a = (try loadToken(testing.allocator, &ctx.db, "ws_a", "files")) orelse return error.TestUnexpectedResult;
    defer loaded_a.deinit(testing.allocator);
    const loaded_b = (try loadToken(testing.allocator, &ctx.db, "ws_b", "files")) orelse return error.TestUnexpectedResult;
    defer loaded_b.deinit(testing.allocator);
    try testing.expectEqualStrings("at-a", loaded_a.access_token);
    try testing.expectEqualStrings("at-b", loaded_b.access_token);
}

test "a token with no expiry reads back with a null expiry" {
    var ctx = try TestCtx.open();
    defer ctx.deinit();

    var rec = sampleToken("at-1");
    rec.expires_at = null;
    try saveToken(testing.allocator, &ctx.db, rec);

    const loaded = (try loadToken(testing.allocator, &ctx.db, "ws_1", "files")) orelse return error.TestUnexpectedResult;
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(?i64, null), loaded.expires_at);
}

test "a token with no refresh token reads back with an empty refresh token" {
    var ctx = try TestCtx.open();
    defer ctx.deinit();

    var rec = sampleToken("at-1");
    rec.refresh_token = "";
    rec.client_secret = "";
    try saveToken(testing.allocator, &ctx.db, rec);

    const loaded = (try loadToken(testing.allocator, &ctx.db, "ws_1", "files")) orelse return error.TestUnexpectedResult;
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings("", loaded.refresh_token);
    try testing.expectEqualStrings("", loaded.client_secret);
}

test "an unknown server has no token" {
    var ctx = try TestCtx.open();
    defer ctx.deinit();

    try testing.expectEqual(@as(?TokenRecord, null), try loadToken(testing.allocator, &ctx.db, "ws_1", "missing"));
}

test "deleting a token removes the metadata row and every credential" {
    var ctx = try TestCtx.open();
    defer ctx.deinit();

    try saveToken(testing.allocator, &ctx.db, sampleToken("at-1"));
    try deleteToken(testing.allocator, &ctx.db, "ws_1", "files");

    try testing.expectEqual(@as(?TokenRecord, null), try loadToken(testing.allocator, &ctx.db, "ws_1", "files"));

    var q = try ctx.db.query(testing.allocator, "SELECT COUNT(*) FROM workspace_secrets", &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "a pending authorization is consumed exactly once" {
    var ctx = try TestCtx.open();
    defer ctx.deinit();

    try savePending(testing.allocator, &ctx.db, .{
        .state = "st_1",
        .workspace_id = "ws_1",
        .server_name = "files",
        .resource = "https://mcp.example.com/mcp",
        .issuer = "https://as.example.com",
        .client_id = "client-1",
        .authorization_endpoint = "https://as.example.com/authorize",
        .token_endpoint = "https://as.example.com/token",
        .redirect_uri = "http://127.0.0.1:9999/callback",
        .code_verifier = "verifier-1",
        .scope = "files:read",
    });

    const first = (try takePending(testing.allocator, &ctx.db, "st_1")) orelse return error.TestUnexpectedResult;
    defer first.deinit(testing.allocator);
    try testing.expectEqualStrings("verifier-1", first.code_verifier);
    try testing.expectEqualStrings("https://as.example.com/token", first.token_endpoint);

    try testing.expectEqual(@as(?PendingRecord, null), try takePending(testing.allocator, &ctx.db, "st_1"));

    var q = try ctx.db.query(testing.allocator, "SELECT COUNT(*) FROM workspace_secrets", &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "deleting the pending authorizations of a server leaves other servers alone" {
    var ctx = try TestCtx.open();
    defer ctx.deinit();

    try savePending(testing.allocator, &ctx.db, .{ .state = "st_a", .workspace_id = "ws_1", .server_name = "files" });
    try savePending(testing.allocator, &ctx.db, .{ .state = "st_b", .workspace_id = "ws_1", .server_name = "search" });

    try deletePendingForServer(testing.allocator, &ctx.db, "ws_1", "files");

    try testing.expectEqual(@as(?PendingRecord, null), try takePending(testing.allocator, &ctx.db, "st_a"));
    const other = (try takePending(testing.allocator, &ctx.db, "st_b")) orelse return error.TestUnexpectedResult;
    defer other.deinit(testing.allocator);
    try testing.expectEqualStrings("search", other.server_name);
}

test "a server name maps to a valid secret name" {
    const name = try secretName(testing.allocator, "my.files-server", .access_token);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("MCP_OAUTH_MY_FILES-SERVER_ACCESS_TOKEN", name);
    try testing.expect(secrets_store.isValidName(name));
}

test "a long server name still maps to a valid secret name" {
    const long = "a-very-long-mcp-server-name-that-would-overflow-the-secret-name-limit.example.com";
    const name = try secretName(testing.allocator, long, .refresh_token);
    defer testing.allocator.free(name);
    try testing.expect(name.len <= secrets_store.MAX_NAME_LEN);
    try testing.expect(secrets_store.isValidName(name));
}

test "two long server names that share a prefix map to different secret names" {
    const a = "a-very-long-mcp-server-name-that-would-overflow-the-secret-name-limit.example.com";
    const b = "a-very-long-mcp-server-name-that-would-overflow-the-secret-name-limit.example.org";
    const name_a = try secretName(testing.allocator, a, .access_token);
    defer testing.allocator.free(name_a);
    const name_b = try secretName(testing.allocator, b, .access_token);
    defer testing.allocator.free(name_b);
    try testing.expect(!std.mem.eql(u8, name_a, name_b));
}

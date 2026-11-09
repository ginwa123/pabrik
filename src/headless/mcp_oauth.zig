const std = @import("std");
const pabrikcore = @import("pabrikcore");
const helpers = @import("helpers");

const args = @import("args.zig");
const boot_mod = @import("boot.zig");

const mcp_oauth = pabrikcore.mcp_oauth;
const mcp_oauth_flow = pabrikcore.mcp_oauth_flow;
const mcp_oauth_store = pabrikcore.mcp_oauth_store;

pub const Error = error{
    UrlRequired,
    WorkspaceRequired,
    ServerRequired,
    StateRequired,
    CodeRequired,
    NoRefreshToken,
    NoPendingAuthorization,
    NoClientId,
    RandomFailed,
    OutOfMemory,
} || mcp_oauth_flow.FlowError || mcp_oauth_store.StoreError;

fn randomSource() Error!std.Random.DefaultPrng {
    var seed_bytes: [8]u8 = undefined;
    helpers.random.fillRandom(&seed_bytes) catch return error.RandomFailed;
    return std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed_bytes, .little));
}

fn serverName(allocator: std.mem.Allocator, a: args.McpOAuthArgs) Error![]u8 {
    if (a.server_name.len > 0) return allocator.dupe(u8, a.server_name);
    const parsed = mcp_oauth.parseUrl(a.url) catch return error.UrlRequired;
    return std.fmt.allocPrint(allocator, "{s}", .{parsed.host});
}

fn requireUrl(a: args.McpOAuthArgs) Error!void {
    if (a.url.len == 0) return error.UrlRequired;
}

fn requireWorkspace(a: args.McpOAuthArgs) Error!void {
    if (a.workspace_id.len == 0) return error.WorkspaceRequired;
}

pub fn run(
    allocator: std.mem.Allocator,
    backend: *boot_mod.Backend,
    a: args.McpOAuthArgs,
) Error![]const u8 {
    var http = mcp_oauth_flow.HttpTransport.init(allocator);
    defer http.deinit();
    return runWithDb(allocator, backend.ctx.db, http.transport(), a);
}

pub fn runWithDb(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    transport: mcp_oauth_flow.Transport,
    a: args.McpOAuthArgs,
) Error![]const u8 {
    return switch (a.op) {
        .discover => discover(allocator, transport, a),
        .authorize_url => authorizeUrl(allocator, db, transport, a),
        .exchange => exchange(allocator, db, transport, a),
        .status => status(allocator, db, a),
        .refresh => refresh(allocator, db, transport, a),
        .logout => logout(allocator, db, a),
    };
}

fn discover(
    allocator: std.mem.Allocator,
    transport: mcp_oauth_flow.Transport,
    a: args.McpOAuthArgs,
) Error![]const u8 {
    try requireUrl(a);
    const found = try mcp_oauth_flow.discover(allocator, transport, a.url);
    defer found.deinit(allocator);

    return std.json.Stringify.valueAlloc(allocator, .{
        .resource = found.resource,
        .authorization_servers = found.authorization_servers,
        .scopes_supported = found.scopes_supported,
        .issuer = found.as_metadata.issuer,
        .authorization_endpoint = found.as_metadata.authorization_endpoint,
        .token_endpoint = found.as_metadata.token_endpoint,
        .registration_endpoint = found.as_metadata.registration_endpoint,
        .pkce = "S256",
    }, .{});
}

fn authorizeUrl(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    transport: mcp_oauth_flow.Transport,
    a: args.McpOAuthArgs,
) Error![]const u8 {
    try requireUrl(a);
    try requireWorkspace(a);

    const server = try serverName(allocator, a);
    defer allocator.free(server);

    const found = try mcp_oauth_flow.discover(allocator, transport, a.url);
    defer found.deinit(allocator);

    const client_id = try resolveClientId(allocator, transport, found, a);
    defer allocator.free(client_id);

    var prng = try randomSource();
    const random = prng.random();
    const verifier = try mcp_oauth.generateCodeVerifier(allocator, random);
    defer allocator.free(verifier);
    const challenge = try mcp_oauth.codeChallengeS256(allocator, verifier);
    defer allocator.free(challenge);
    const state = try mcp_oauth.generateState(allocator, random);
    defer allocator.free(state);

    const scope = if (a.scope.len > 0) a.scope else try joinScopes(allocator, found.scopes_supported);
    defer if (a.scope.len == 0) allocator.free(scope);

    const url = try mcp_oauth.buildAuthorizationUrl(allocator, .{
        .authorization_endpoint = found.as_metadata.authorization_endpoint,
        .client_id = client_id,
        .redirect_uri = a.redirect_uri,
        .code_challenge = challenge,
        .state = state,
        .scope = scope,
        .resource = found.resource,
    });
    defer allocator.free(url);

    try mcp_oauth_store.savePending(allocator, db, .{
        .state = state,
        .workspace_id = a.workspace_id,
        .server_name = server,
        .resource = found.resource,
        .issuer = found.as_metadata.issuer,
        .client_id = client_id,
        .authorization_endpoint = found.as_metadata.authorization_endpoint,
        .token_endpoint = found.as_metadata.token_endpoint,
        .redirect_uri = a.redirect_uri,
        .code_verifier = verifier,
        .scope = scope,
    });

    return std.json.Stringify.valueAlloc(allocator, .{
        .authorization_url = url,
        .state = state,
        .redirect_uri = a.redirect_uri,
        .client_id = client_id,
        .resource = found.resource,
        .scope = scope,
    }, .{});
}

fn joinScopes(allocator: std.mem.Allocator, scopes: []const []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (scopes, 0..) |s, i| {
        if (i > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, s);
    }
    return out.toOwnedSlice(allocator);
}

fn resolveClientId(
    allocator: std.mem.Allocator,
    transport: mcp_oauth_flow.Transport,
    found: mcp_oauth_flow.Discovery,
    a: args.McpOAuthArgs,
) Error![]u8 {
    if (a.client_id.len > 0) return allocator.dupe(u8, a.client_id);
    const endpoint = found.as_metadata.registration_endpoint orelse return error.NoClientId;

    const redirects = [_][]const u8{a.redirect_uri};
    const reg = try mcp_oauth_flow.registerClient(allocator, transport, endpoint, .{
        .client_name = "pabrik",
        .redirect_uris = &redirects,
        .scope = a.scope,
    });
    defer reg.deinit(allocator);
    return allocator.dupe(u8, reg.client_id);
}

fn exchange(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    transport: mcp_oauth_flow.Transport,
    a: args.McpOAuthArgs,
) Error![]const u8 {
    try requireWorkspace(a);
    if (a.state.len == 0) return error.StateRequired;
    if (a.code.len == 0) return error.CodeRequired;

    const pending = (try mcp_oauth_store.takePending(allocator, db, a.state)) orelse
        return error.NoPendingAuthorization;
    defer pending.deinit(allocator);

    const token = try mcp_oauth_flow.exchangeCode(allocator, transport, .{
        .token_endpoint = pending.token_endpoint,
        .code = a.code,
        .redirect_uri = pending.redirect_uri,
        .client_id = pending.client_id,
        .code_verifier = pending.code_verifier,
        .resource = pending.resource,
    });
    defer token.deinit(allocator);

    const now = mcp_oauth_store.nowSeconds();
    const expires_at = mcp_oauth.expiresAt(now, token.expires_in);

    try mcp_oauth_store.saveToken(allocator, db, .{
        .workspace_id = pending.workspace_id,
        .server_name = pending.server_name,
        .resource = pending.resource,
        .issuer = pending.issuer,
        .client_id = pending.client_id,
        .token_endpoint = pending.token_endpoint,
        .access_token = token.access_token,
        .refresh_token = token.refresh_token orelse "",
        .token_type = token.token_type,
        .scope = token.scope orelse pending.scope,
        .expires_at = expires_at,
    });

    return std.json.Stringify.valueAlloc(allocator, .{
        .authorized = true,
        .server = pending.server_name,
        .resource = pending.resource,
        .issuer = pending.issuer,
        .token_type = token.token_type,
        .scope = token.scope orelse pending.scope,
        .expires_at = expires_at,
        .has_refresh_token = token.refresh_token != null,
    }, .{});
}

fn status(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    a: args.McpOAuthArgs,
) Error![]const u8 {
    try requireUrl(a);
    try requireWorkspace(a);

    const server = try serverName(allocator, a);
    defer allocator.free(server);

    const token = try mcp_oauth_store.loadToken(allocator, db, a.workspace_id, server);
    if (token == null) {
        return std.json.Stringify.valueAlloc(allocator, .{
            .authorized = false,
            .server = server,
        }, .{});
    }
    defer token.?.deinit(allocator);

    const now = mcp_oauth_store.nowSeconds();
    return std.json.Stringify.valueAlloc(allocator, .{
        .authorized = true,
        .server = server,
        .resource = token.?.resource,
        .issuer = token.?.issuer,
        .token_type = token.?.token_type,
        .scope = token.?.scope,
        .expires_at = token.?.expires_at,
        .expired = mcp_oauth.isExpired(token.?.expires_at, now, 0),
        .has_refresh_token = token.?.refresh_token.len > 0,
    }, .{});
}

fn refresh(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    transport: mcp_oauth_flow.Transport,
    a: args.McpOAuthArgs,
) Error![]const u8 {
    try requireUrl(a);
    try requireWorkspace(a);

    const server = try serverName(allocator, a);
    defer allocator.free(server);

    const current = (try mcp_oauth_store.loadToken(allocator, db, a.workspace_id, server)) orelse
        return error.NoPendingAuthorization;
    defer current.deinit(allocator);
    if (current.refresh_token.len == 0) return error.NoRefreshToken;

    const token = try mcp_oauth_flow.refreshToken(allocator, transport, .{
        .token_endpoint = current.token_endpoint,
        .refresh_token = current.refresh_token,
        .client_id = current.client_id,
        .resource = current.resource,
        .scope = current.scope,
    });
    defer token.deinit(allocator);

    const now = mcp_oauth_store.nowSeconds();
    const expires_at = mcp_oauth.expiresAt(now, token.expires_in);

    try mcp_oauth_store.saveToken(allocator, db, .{
        .workspace_id = current.workspace_id,
        .server_name = current.server_name,
        .resource = current.resource,
        .issuer = current.issuer,
        .client_id = current.client_id,
        .client_secret = current.client_secret,
        .token_endpoint = current.token_endpoint,
        .access_token = token.access_token,
        .refresh_token = token.refresh_token orelse current.refresh_token,
        .token_type = token.token_type,
        .scope = token.scope orelse current.scope,
        .expires_at = expires_at,
    });

    return std.json.Stringify.valueAlloc(allocator, .{
        .refreshed = true,
        .server = server,
        .expires_at = expires_at,
        .scope = token.scope orelse current.scope,
    }, .{});
}

fn logout(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    a: args.McpOAuthArgs,
) Error![]const u8 {
    try requireUrl(a);
    try requireWorkspace(a);

    const server = try serverName(allocator, a);
    defer allocator.free(server);

    try mcp_oauth_store.deleteToken(allocator, db, a.workspace_id, server);
    try mcp_oauth_store.deletePendingForServer(allocator, db, a.workspace_id, server);

    return std.json.Stringify.valueAlloc(allocator, .{
        .removed = true,
        .server = server,
    }, .{});
}

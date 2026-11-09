const std = @import("std");
const mcp_oauth = @import("mcp_oauth.zig");
const custom_http_client_mod = @import("kabelweb").client;

pub const Method = enum { GET, POST };

pub const Request = struct {
    method: Method,
    url: []const u8,
    body: []const u8 = "",
    content_type: []const u8 = "",
};

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *const Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub const Transport = struct {
    ctx: *anyopaque,
    sendFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, req: Request) anyerror!Response,

    pub fn send(self: Transport, allocator: std.mem.Allocator, req: Request) anyerror!Response {
        return self.sendFn(self.ctx, allocator, req);
    }
};

pub const HttpTransport = struct {
    client: custom_http_client_mod.Client,

    pub fn init(allocator: std.mem.Allocator) HttpTransport {
        return .{ .client = custom_http_client_mod.Client{ .allocator = allocator } };
    }

    pub fn deinit(self: *HttpTransport) void {
        self.client.deinit();
    }

    pub fn transport(self: *HttpTransport) Transport {
        return .{ .ctx = @ptrCast(self), .sendFn = sendOverHttp };
    }

    fn sendOverHttp(ctx: *anyopaque, allocator: std.mem.Allocator, req: Request) anyerror!Response {
        const self: *HttpTransport = @ptrCast(@alignCast(ctx));
        const result = switch (req.method) {
            .GET => custom_http_client_mod.get(&self.client, req.url, .{ .timeout_ms = 30_000 }),
            .POST => blk: {
                const headers = [_]custom_http_client_mod.Header{
                    .{ .name = "Content-Type", .value = req.content_type },
                    .{ .name = "Accept", .value = "application/json" },
                };
                break :blk custom_http_client_mod.post(
                    &self.client,
                    req.url,
                    req.body,
                    &headers,
                    .{ .timeout_ms = 30_000 },
                );
            },
        } catch return error.TransportFailed;
        defer result.deinit(allocator);
        return .{ .status = result.status_code, .body = try allocator.dupe(u8, result.body) };
    }
};

pub const FlowError = error{
    DiscoveryFailed,
    MetadataInvalid,
    RegistrationFailed,
    TokenRequestFailed,
    TokenError,
    NoAuthorizationServer,
    PkceUnsupported,
    OutOfMemory,
};

pub const Discovery = struct {
    resource: []const u8,
    authorization_servers: []const []const u8,
    scopes_supported: []const []const u8,
    as_metadata: mcp_oauth.AuthorizationServerMetadata,

    pub fn deinit(self: *const Discovery, allocator: std.mem.Allocator) void {
        allocator.free(self.resource);
        mcp_oauth.freeStringList(allocator, self.authorization_servers);
        mcp_oauth.freeStringList(allocator, self.scopes_supported);
        self.as_metadata.deinit(allocator);
    }
};

fn fetchMetadata(
    allocator: std.mem.Allocator,
    transport: Transport,
    url: []const u8,
) FlowError!?[]u8 {
    var resp = transport.send(allocator, .{ .method = .GET, .url = url }) catch return error.DiscoveryFailed;
    defer resp.deinit(allocator);
    if (resp.status != 200) return null;
    return allocator.dupe(u8, resp.body) catch return error.OutOfMemory;
}

fn fetchAuthorizationServerMetadata(
    allocator: std.mem.Allocator,
    transport: Transport,
    issuer: []const u8,
) FlowError!mcp_oauth.AuthorizationServerMetadata {
    const candidates = mcp_oauth.authorizationServerMetadataUrls(allocator, issuer) catch return error.DiscoveryFailed;
    defer mcp_oauth.freeStringList(allocator, candidates);

    for (candidates) |url| {
        const body = (try fetchMetadata(allocator, transport, url)) orelse continue;
        defer allocator.free(body);
        const meta = mcp_oauth.parseAuthorizationServerMetadata(allocator, body) catch continue;
        if (!mcp_oauth.resourceMatches(meta.issuer, issuer)) {
            meta.deinit(allocator);
            continue;
        }
        return meta;
    }
    return error.DiscoveryFailed;
}

pub fn discover(
    allocator: std.mem.Allocator,
    transport: Transport,
    mcp_url: []const u8,
) FlowError!Discovery {
    const prm_url = mcp_oauth.protectedResourceMetadataUrl(allocator, mcp_url) catch return error.DiscoveryFailed;
    defer allocator.free(prm_url);

    var resource: []const u8 = undefined;
    var servers: []const []const u8 = undefined;
    var scopes: []const []const u8 = undefined;

    if (try fetchMetadata(allocator, transport, prm_url)) |prm_json| {
        defer allocator.free(prm_json);
        const prm = mcp_oauth.parseProtectedResourceMetadata(allocator, prm_json) catch return error.MetadataInvalid;
        if (!mcp_oauth.resourceMatches(prm.resource, mcp_url)) {
            prm.deinit(allocator);
            return error.MetadataInvalid;
        }
        if (prm.authorization_servers.len == 0) {
            prm.deinit(allocator);
            return error.NoAuthorizationServer;
        }
        resource = prm.resource;
        servers = prm.authorization_servers;
        scopes = prm.scopes_supported;
    } else {
        const parsed = mcp_oauth.parseUrl(mcp_url) catch return error.DiscoveryFailed;
        const origin = mcp_oauth.origin(allocator, parsed) catch return error.OutOfMemory;
        defer allocator.free(origin);

        const server_list = allocator.alloc([]const u8, 1) catch return error.OutOfMemory;
        errdefer allocator.free(server_list);
        server_list[0] = allocator.dupe(u8, origin) catch return error.OutOfMemory;

        resource = allocator.dupe(u8, mcp_url) catch return error.OutOfMemory;
        servers = server_list;
        scopes = allocator.alloc([]const u8, 0) catch return error.OutOfMemory;
    }
    errdefer {
        allocator.free(resource);
        mcp_oauth.freeStringList(allocator, servers);
        mcp_oauth.freeStringList(allocator, scopes);
    }

    const meta = try fetchAuthorizationServerMetadata(allocator, transport, servers[0]);
    errdefer meta.deinit(allocator);
    if (!mcp_oauth.supportsS256(meta)) return error.PkceUnsupported;

    return .{
        .resource = resource,
        .authorization_servers = servers,
        .scopes_supported = scopes,
        .as_metadata = meta,
    };
}

pub const CodeExchange = struct {
    token_endpoint: []const u8,
    code: []const u8,
    redirect_uri: []const u8,
    client_id: []const u8,
    code_verifier: []const u8,
    resource: []const u8 = "",
};

fn postForm(
    allocator: std.mem.Allocator,
    transport: Transport,
    url: []const u8,
    body: []const u8,
) FlowError!Response {
    return transport.send(allocator, .{
        .method = .POST,
        .url = url,
        .body = body,
        .content_type = "application/x-www-form-urlencoded",
    }) catch error.TokenRequestFailed;
}

fn tokenFromResponse(allocator: std.mem.Allocator, resp: *const Response) FlowError!mcp_oauth.TokenResponse {
    if (resp.status == 200) {
        return mcp_oauth.parseTokenResponse(allocator, resp.body) catch error.TokenRequestFailed;
    }
    return error.TokenError;
}

pub fn exchangeCode(
    allocator: std.mem.Allocator,
    transport: Transport,
    req: CodeExchange,
) FlowError!mcp_oauth.TokenResponse {
    const body = mcp_oauth.buildTokenRequestBody(allocator, .{
        .grant_type = "authorization_code",
        .code = req.code,
        .redirect_uri = req.redirect_uri,
        .client_id = req.client_id,
        .code_verifier = req.code_verifier,
        .resource = req.resource,
    }) catch return error.OutOfMemory;
    defer allocator.free(body);

    var resp = try postForm(allocator, transport, req.token_endpoint, body);
    defer resp.deinit(allocator);
    return tokenFromResponse(allocator, &resp);
}

pub const RefreshRequest = struct {
    token_endpoint: []const u8,
    refresh_token: []const u8,
    client_id: []const u8,
    resource: []const u8 = "",
    scope: []const u8 = "",
};

pub fn refreshToken(
    allocator: std.mem.Allocator,
    transport: Transport,
    req: RefreshRequest,
) FlowError!mcp_oauth.TokenResponse {
    const body = mcp_oauth.buildTokenRequestBody(allocator, .{
        .grant_type = "refresh_token",
        .refresh_token = req.refresh_token,
        .client_id = req.client_id,
        .resource = req.resource,
        .scope = req.scope,
    }) catch return error.OutOfMemory;
    defer allocator.free(body);

    var resp = try postForm(allocator, transport, req.token_endpoint, body);
    defer resp.deinit(allocator);
    return tokenFromResponse(allocator, &resp);
}

pub fn registerClient(
    allocator: std.mem.Allocator,
    transport: Transport,
    registration_endpoint: []const u8,
    req: mcp_oauth.ClientRegistrationRequest,
) FlowError!mcp_oauth.ClientRegistration {
    const body = mcp_oauth.buildClientRegistrationBody(allocator, req) catch return error.OutOfMemory;
    defer allocator.free(body);

    var resp = transport.send(allocator, .{
        .method = .POST,
        .url = registration_endpoint,
        .body = body,
        .content_type = "application/json",
    }) catch return error.RegistrationFailed;
    defer resp.deinit(allocator);

    if (resp.status != 200 and resp.status != 201) return error.RegistrationFailed;
    return mcp_oauth.parseClientRegistration(allocator, resp.body) catch error.RegistrationFailed;
}

const testing = std.testing;

const Canned = struct {
    url: []const u8,
    status: u16,
    body: []const u8,
};

const Call = struct {
    method: Method,
    url: []u8,
    body: []u8,
    content_type: []u8,
};

const FakeTransport = struct {
    responses: []const Canned,
    calls: std.ArrayList(Call) = .empty,

    fn deinit(self: *FakeTransport, allocator: std.mem.Allocator) void {
        for (self.calls.items) |c| {
            allocator.free(c.url);
            allocator.free(c.body);
            allocator.free(c.content_type);
        }
        self.calls.deinit(allocator);
    }

    fn transport(self: *FakeTransport) Transport {
        return .{ .ctx = @ptrCast(self), .sendFn = send };
    }

    fn send(ctx: *anyopaque, allocator: std.mem.Allocator, req: Request) anyerror!Response {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx));
        try self.calls.append(allocator, .{
            .method = req.method,
            .url = try allocator.dupe(u8, req.url),
            .body = try allocator.dupe(u8, req.body),
            .content_type = try allocator.dupe(u8, req.content_type),
        });
        for (self.responses) |canned| {
            if (std.mem.eql(u8, canned.url, req.url)) {
                return .{ .status = canned.status, .body = try allocator.dupe(u8, canned.body) };
            }
        }
        return .{ .status = 404, .body = try allocator.dupe(u8, "") };
    }
};

const prm_body =
    \\{"resource":"https://mcp.example.com/mcp","authorization_servers":["https://as.example.com"],"scopes_supported":["files:read"]}
;

const as_body =
    \\{"issuer":"https://as.example.com","authorization_endpoint":"https://as.example.com/authorize","token_endpoint":"https://as.example.com/token","registration_endpoint":"https://as.example.com/register","code_challenge_methods_supported":["S256"]}
;

test "discovery reads the protected resource metadata and the authorization server metadata" {
    var fake = FakeTransport{ .responses = &.{
        .{ .url = "https://mcp.example.com/.well-known/oauth-protected-resource/mcp", .status = 200, .body = prm_body },
        .{ .url = "https://as.example.com/.well-known/oauth-authorization-server", .status = 200, .body = as_body },
    } };
    defer fake.deinit(testing.allocator);

    const found = try discover(testing.allocator, fake.transport(), "https://mcp.example.com/mcp");
    defer found.deinit(testing.allocator);

    try testing.expectEqualStrings("https://mcp.example.com/mcp", found.resource);
    try testing.expectEqual(@as(usize, 1), found.authorization_servers.len);
    try testing.expectEqualStrings("https://as.example.com", found.authorization_servers[0]);
    try testing.expectEqualStrings("https://as.example.com/token", found.as_metadata.token_endpoint);
    try testing.expectEqualStrings("files:read", found.scopes_supported[0]);
}

test "discovery falls back to the resource origin when the metadata document is missing" {
    var fake = FakeTransport{ .responses = &.{
        .{ .url = "https://as.example.com/.well-known/oauth-authorization-server", .status = 200, .body = as_body },
    } };
    defer fake.deinit(testing.allocator);

    const found = try discover(testing.allocator, fake.transport(), "https://as.example.com/mcp");
    defer found.deinit(testing.allocator);

    try testing.expectEqualStrings("https://as.example.com/mcp", found.resource);
    try testing.expectEqualStrings("https://as.example.com", found.authorization_servers[0]);
    try testing.expectEqual(@as(usize, 0), found.scopes_supported.len);
}

test "discovery rejects a protected resource metadata document for another resource" {
    var fake = FakeTransport{ .responses = &.{
        .{ .url = "https://mcp.example.com/.well-known/oauth-protected-resource/mcp", .status = 200, .body =
        \\{"resource":"https://evil.example.com/mcp","authorization_servers":["https://as.example.com"]}
        },
    } };
    defer fake.deinit(testing.allocator);

    try testing.expectError(error.MetadataInvalid, discover(testing.allocator, fake.transport(), "https://mcp.example.com/mcp"));
}

test "discovery rejects an authorization server that offers no S256" {
    var fake = FakeTransport{ .responses = &.{
        .{ .url = "https://mcp.example.com/.well-known/oauth-protected-resource/mcp", .status = 200, .body = prm_body },
        .{ .url = "https://as.example.com/.well-known/oauth-authorization-server", .status = 200, .body =
        \\{"issuer":"https://as.example.com","authorization_endpoint":"https://as.example.com/authorize","token_endpoint":"https://as.example.com/token","code_challenge_methods_supported":["plain"]}
        },
    } };
    defer fake.deinit(testing.allocator);

    try testing.expectError(error.PkceUnsupported, discover(testing.allocator, fake.transport(), "https://mcp.example.com/mcp"));
}

test "discovery tries the next candidate when the first metadata url is missing" {
    var fake = FakeTransport{ .responses = &.{
        .{ .url = "https://mcp.example.com/.well-known/oauth-protected-resource/mcp", .status = 200, .body = prm_body },
        .{ .url = "https://as.example.com/.well-known/openid-configuration", .status = 200, .body = as_body },
    } };
    defer fake.deinit(testing.allocator);

    const found = try discover(testing.allocator, fake.transport(), "https://mcp.example.com/mcp");
    defer found.deinit(testing.allocator);
    try testing.expectEqualStrings("https://as.example.com/token", found.as_metadata.token_endpoint);
}

test "discovery rejects an authorization server whose issuer does not match" {
    var fake = FakeTransport{ .responses = &.{
        .{ .url = "https://mcp.example.com/.well-known/oauth-protected-resource/mcp", .status = 200, .body = prm_body },
        .{ .url = "https://as.example.com/.well-known/oauth-authorization-server", .status = 200, .body =
        \\{"issuer":"https://other.example.com","authorization_endpoint":"https://as.example.com/authorize","token_endpoint":"https://as.example.com/token"}
        },
    } };
    defer fake.deinit(testing.allocator);

    try testing.expectError(error.DiscoveryFailed, discover(testing.allocator, fake.transport(), "https://mcp.example.com/mcp"));
}

test "the code exchange posts a form body and returns the token" {
    var fake = FakeTransport{ .responses = &.{
        .{ .url = "https://as.example.com/token", .status = 200, .body =
        \\{"access_token":"at-1","token_type":"Bearer","expires_in":3600,"refresh_token":"rt-1"}
        },
    } };
    defer fake.deinit(testing.allocator);

    const token = try exchangeCode(testing.allocator, fake.transport(), .{
        .token_endpoint = "https://as.example.com/token",
        .code = "code-1",
        .redirect_uri = "http://127.0.0.1:9999/callback",
        .client_id = "client-1",
        .code_verifier = "verifier-1",
        .resource = "https://mcp.example.com/mcp",
    });
    defer token.deinit(testing.allocator);

    try testing.expectEqualStrings("at-1", token.access_token);
    try testing.expectEqualStrings("rt-1", token.refresh_token.?);
    try testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    try testing.expectEqual(Method.POST, fake.calls.items[0].method);
    try testing.expectEqualStrings("application/x-www-form-urlencoded", fake.calls.items[0].content_type);
    try testing.expect(std.mem.indexOf(u8, fake.calls.items[0].body, "grant_type=authorization_code") != null);
    try testing.expect(std.mem.indexOf(u8, fake.calls.items[0].body, "code_verifier=verifier-1") != null);
}

test "a rejected code exchange surfaces the oauth error" {
    var fake = FakeTransport{ .responses = &.{
        .{ .url = "https://as.example.com/token", .status = 400, .body =
        \\{"error":"invalid_grant","error_description":"code expired"}
        },
    } };
    defer fake.deinit(testing.allocator);

    try testing.expectError(error.TokenError, exchangeCode(testing.allocator, fake.transport(), .{
        .token_endpoint = "https://as.example.com/token",
        .code = "code-1",
        .redirect_uri = "http://127.0.0.1:9999/callback",
        .client_id = "client-1",
        .code_verifier = "verifier-1",
    }));
}

test "the refresh posts the refresh token grant" {
    var fake = FakeTransport{ .responses = &.{
        .{ .url = "https://as.example.com/token", .status = 200, .body =
        \\{"access_token":"at-2","token_type":"Bearer","expires_in":60}
        },
    } };
    defer fake.deinit(testing.allocator);

    const token = try refreshToken(testing.allocator, fake.transport(), .{
        .token_endpoint = "https://as.example.com/token",
        .refresh_token = "rt-1",
        .client_id = "client-1",
        .resource = "https://mcp.example.com/mcp",
    });
    defer token.deinit(testing.allocator);

    try testing.expectEqualStrings("at-2", token.access_token);
    try testing.expect(std.mem.indexOf(u8, fake.calls.items[0].body, "grant_type=refresh_token") != null);
    try testing.expect(std.mem.indexOf(u8, fake.calls.items[0].body, "refresh_token=rt-1") != null);
}

test "client registration posts a public client and returns the client id" {
    var fake = FakeTransport{ .responses = &.{
        .{ .url = "https://as.example.com/register", .status = 201, .body =
        \\{"client_id":"client-9"}
        },
    } };
    defer fake.deinit(testing.allocator);

    const reg = try registerClient(testing.allocator, fake.transport(), "https://as.example.com/register", .{
        .client_name = "pabrik",
        .redirect_uris = &.{"http://127.0.0.1:9999/callback"},
    });
    defer reg.deinit(testing.allocator);

    try testing.expectEqualStrings("client-9", reg.client_id);
    try testing.expectEqualStrings("application/json", fake.calls.items[0].content_type);
    try testing.expect(std.mem.indexOf(u8, fake.calls.items[0].body, "\"token_endpoint_auth_method\":\"none\"") != null);
}

test "a registration endpoint that refuses the client surfaces a registration failure" {
    var fake = FakeTransport{ .responses = &.{
        .{ .url = "https://as.example.com/register", .status = 400, .body =
        \\{"error":"invalid_redirect_uri"}
        },
    } };
    defer fake.deinit(testing.allocator);

    try testing.expectError(error.RegistrationFailed, registerClient(testing.allocator, fake.transport(), "https://as.example.com/register", .{
        .client_name = "pabrik",
        .redirect_uris = &.{"http://127.0.0.1:9999/callback"},
    }));
}

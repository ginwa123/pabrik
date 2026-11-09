const std = @import("std");
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const database = pabrikcore.database;
const test_db = pabrikcore.test_db;
const secrets_at_rest = pabrikcore.secrets_at_rest;

const mcp_oauth = @import("mcp_oauth.zig");
const mcp_oauth_flow = @import("mcp_oauth_flow.zig");
const mcp_oauth_store = @import("mcp_oauth_store.zig");

const Io = std.Io;
const gpa = testing.allocator;

const Stub = struct {
    threaded: std.Io.Threaded,
    io: Io,
    port: u16,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    token_bodies: std.ArrayList([]u8) = .empty,
    mcp_heads: std.ArrayList([]u8) = .empty,

    fn start(self: *Stub) !void {
        self.threaded = std.Io.Threaded.init(gpa, .{});
        self.io = self.threaded.io();
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.server = try addr.listen(self.io, .{ .reuse_address = true });
        self.port = self.server.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn stopStub(self: *Stub) void {
        self.stop.store(true, .release);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (addr.connect(self.io, .{ .mode = .stream })) |conn| {
            var c = conn;
            c.close(self.io);
        } else |_| {}
        self.thread.join();
        self.server.deinit(self.io);
        self.threaded.deinit();
        for (self.token_bodies.items) |b| gpa.free(b);
        self.token_bodies.deinit(gpa);
        for (self.mcp_heads.items) |b| gpa.free(b);
        self.mcp_heads.deinit(gpa);
    }

    fn base(self: *Stub, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.port});
    }
};

fn serve(stub: *Stub) void {
    while (!stub.stop.load(.acquire)) {
        var stream = stub.server.accept(stub.io) catch break;
        defer stream.close(stub.io);
        if (stub.stop.load(.acquire)) break;
        handle(stub, stream) catch {};
    }
}

const Request = struct {
    method: []u8,
    path: []u8,
    head: []u8,
    body: []u8,
};

fn readRequest(stub: *Stub, stream: Io.net.Stream) !Request {
    var rbuf: [16 * 1024]u8 = undefined;
    var sr = stream.reader(stub.io, &rbuf);
    const r = &sr.interface;

    var acc: Io.Writer.Allocating = .init(gpa);
    defer acc.deinit();

    var head_len: usize = 0;
    while (head_len == 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        try acc.writer.writeAll(b);
        r.toss(b.len);
        if (acc.written().len > 16 * 1024) break;
        if (std.mem.indexOf(u8, acc.written(), "\r\n\r\n")) |i| head_len = i + 4;
    }
    if (head_len == 0) return error.NoHead;

    const head = acc.written()[0..head_len];
    var it = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = it.next() orelse return error.NoHead;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.NoHead;
    const path = parts.next() orelse return error.NoHead;

    const want = contentLength(head);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    if (acc.written().len > head_len) {
        const already = acc.written()[head_len..];
        try body.appendSlice(gpa, already[0..@min(already.len, want)]);
    }
    while (body.items.len < want) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        const take = @min(b.len, want - body.items.len);
        try body.appendSlice(gpa, b[0..take]);
        r.toss(take);
    }

    return .{
        .method = try gpa.dupe(u8, method),
        .path = try gpa.dupe(u8, path),
        .head = try gpa.dupe(u8, head),
        .body = try gpa.dupe(u8, body.items),
    };
}

fn contentLength(head: []const u8) usize {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "content-length")) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch 0;
    }
    return 0;
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn handle(stub: *Stub, stream: Io.net.Stream) !void {
    const req = try readRequest(stub, stream);
    defer gpa.free(req.method);
    defer gpa.free(req.path);
    defer gpa.free(req.head);
    defer gpa.free(req.body);

    const base = try stub.base(gpa);
    defer gpa.free(base);

    var status: u16 = 200;
    var reason: []const u8 = "OK";
    var extra: []u8 = &.{};
    defer if (extra.len > 0) gpa.free(extra);
    var body: []u8 = &.{};
    defer if (body.len > 0) gpa.free(body);

    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/.well-known/oauth-protected-resource/mcp")) {
        body = try std.fmt.allocPrint(gpa,
            \\{{"resource":"{s}/mcp","authorization_servers":["{s}"],"scopes_supported":["files:read","files:write"]}}
        , .{ base, base });
    } else if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/.well-known/oauth-authorization-server")) {
        body = try std.fmt.allocPrint(gpa,
            \\{{"issuer":"{s}","authorization_endpoint":"{s}/authorize","token_endpoint":"{s}/token","registration_endpoint":"{s}/register","scopes_supported":["files:read","files:write"],"code_challenge_methods_supported":["S256"]}}
        , .{ base, base, base, base });
    } else if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/register")) {
        status = 201;
        reason = "Created";
        body = try gpa.dupe(u8,
            \\{"client_id":"client-test","token_endpoint_auth_method":"none"}
        );
    } else if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/token")) {
        stub.mutex.lockUncancelable(stub.io);
        stub.token_bodies.append(gpa, try gpa.dupe(u8, req.body)) catch {};
        stub.mutex.unlock(stub.io);
        body = try gpa.dupe(u8,
            \\{"access_token":"at-test","token_type":"Bearer","expires_in":3600,"refresh_token":"rt-test","scope":"files:read"}
        );
    } else if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/mcp")) {
        stub.mutex.lockUncancelable(stub.io);
        stub.mcp_heads.append(gpa, try gpa.dupe(u8, req.head)) catch {};
        stub.mutex.unlock(stub.io);
        const auth = headerValue(req.head, "authorization");
        if (auth != null and std.mem.eql(u8, auth.?, "Bearer at-test")) {
            body = try gpa.dupe(u8,
                \\{"jsonrpc":"2.0","id":"1","result":{"tools":[]}}
            );
        } else {
            status = 401;
            reason = "Unauthorized";
            extra = try std.fmt.allocPrint(
                gpa,
                "WWW-Authenticate: Bearer resource_metadata=\"{s}/.well-known/oauth-protected-resource/mcp\", scope=\"files:read\"\r\n",
                .{base},
            );
        }
    } else {
        status = 404;
        reason = "Not Found";
        body = try gpa.dupe(u8, "{}");
    }

    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n{s}Connection: close\r\n\r\n{s}",
        .{ status, reason, body.len, extra, body },
    );
    defer gpa.free(response);

    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(stub.io, &wbuf);
    try sw.interface.writeAll(response);
    try sw.interface.flush();
}

const Ctx = struct {
    db: database.Db = .{},
    threaded: std.Io.Threaded,

    fn open() !Ctx {
        var threaded = std.Io.Threaded.init(gpa, .{});
        errdefer threaded.deinit();
        var ctx = Ctx{ .threaded = threaded };
        try test_db.openMemory(&ctx.db, ctx.threaded.io());
        try pabrikcore.migrations_mod.migration.Migration146AddMcpOAuth.up(&ctx.db, gpa);
        try ctx.db.exec(gpa,
            \\CREATE TABLE IF NOT EXISTS workspaces (
            \\  id TEXT PRIMARY KEY,
            \\  name TEXT NOT NULL DEFAULT ''
            \\)
        , &[_][]const u8{});
        try ctx.db.exec(gpa,
            \\CREATE TABLE IF NOT EXISTS workspace_secrets (
            \\  id TEXT PRIMARY KEY,
            \\  workspace_id TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  value TEXT NOT NULL DEFAULT '',
            \\  description TEXT NOT NULL DEFAULT '',
            \\  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});
        try ctx.db.exec(gpa, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'test')", &[_][]const u8{});
        return ctx;
    }

    fn deinit(self: *Ctx) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

fn rawSecret(allocator: std.mem.Allocator, db: *database.Db, name: []const u8) ![]u8 {
    var q = try db.query(allocator, "SELECT value FROM workspace_secrets WHERE name = ?", &[_][]const u8{name});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(allocator);
    return allocator.dupe(u8, row.values[0]);
}

test "the oauth flow authorizes a real mcp server over http and stores a sealed token" {
    var ctx = try Ctx.open();
    defer ctx.deinit();

    var stub = Stub{ .threaded = undefined, .io = undefined, .port = 0, .server = undefined, .thread = undefined };
    try stub.start();
    defer stub.stopStub();

    const mcp_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/mcp", .{stub.port});
    defer gpa.free(mcp_url);

    var http = mcp_oauth_flow.HttpTransport.init(gpa);
    defer http.deinit();
    const transport = http.transport();

    const found = try mcp_oauth_flow.discover(gpa, transport, mcp_url);
    defer found.deinit(gpa);
    try testing.expectEqualStrings(mcp_url, found.resource);
    try testing.expectEqualStrings("S256", "S256");
    try testing.expect(mcp_oauth.supportsS256(found.as_metadata));

    const redirect_uri = "http://127.0.0.1:9999/callback";
    const redirects = [_][]const u8{redirect_uri};
    const reg = try mcp_oauth_flow.registerClient(gpa, transport, found.as_metadata.registration_endpoint.?, .{
        .client_name = "pabrik",
        .redirect_uris = &redirects,
    });
    defer reg.deinit(gpa);
    try testing.expectEqualStrings("client-test", reg.client_id);

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const verifier = try mcp_oauth.generateCodeVerifier(gpa, random);
    defer gpa.free(verifier);
    const challenge = try mcp_oauth.codeChallengeS256(gpa, verifier);
    defer gpa.free(challenge);
    const state = try mcp_oauth.generateState(gpa, random);
    defer gpa.free(state);

    const authorization_url = try mcp_oauth.buildAuthorizationUrl(gpa, .{
        .authorization_endpoint = found.as_metadata.authorization_endpoint,
        .client_id = reg.client_id,
        .redirect_uri = redirect_uri,
        .code_challenge = challenge,
        .state = state,
        .scope = "files:read",
        .resource = found.resource,
    });
    defer gpa.free(authorization_url);
    try testing.expect(std.mem.indexOf(u8, authorization_url, "code_challenge_method=S256") != null);
    try testing.expect(std.mem.indexOf(u8, authorization_url, "resource=") != null);

    try mcp_oauth_store.savePending(gpa, &ctx.db, .{
        .state = state,
        .workspace_id = "ws_1",
        .server_name = "files",
        .resource = found.resource,
        .issuer = found.as_metadata.issuer,
        .client_id = reg.client_id,
        .authorization_endpoint = found.as_metadata.authorization_endpoint,
        .token_endpoint = found.as_metadata.token_endpoint,
        .redirect_uri = redirect_uri,
        .code_verifier = verifier,
        .scope = "files:read",
    });

    const pending = (try mcp_oauth_store.takePending(gpa, &ctx.db, state)) orelse return error.TestUnexpectedResult;
    defer pending.deinit(gpa);
    try testing.expectEqualStrings(verifier, pending.code_verifier);

    const token = try mcp_oauth_flow.exchangeCode(gpa, transport, .{
        .token_endpoint = pending.token_endpoint,
        .code = "code-1",
        .redirect_uri = pending.redirect_uri,
        .client_id = pending.client_id,
        .code_verifier = pending.code_verifier,
        .resource = pending.resource,
    });
    defer token.deinit(gpa);
    try testing.expectEqualStrings("at-test", token.access_token);
    try testing.expectEqualStrings("rt-test", token.refresh_token.?);

    const now = mcp_oauth_store.nowSeconds();
    try mcp_oauth_store.saveToken(gpa, &ctx.db, .{
        .workspace_id = "ws_1",
        .server_name = "files",
        .resource = pending.resource,
        .issuer = pending.issuer,
        .client_id = pending.client_id,
        .token_endpoint = pending.token_endpoint,
        .access_token = token.access_token,
        .refresh_token = token.refresh_token.?,
        .token_type = token.token_type,
        .scope = token.scope.?,
        .expires_at = mcp_oauth.expiresAt(now, token.expires_in),
    });

    const stored = (try mcp_oauth_store.loadToken(gpa, &ctx.db, "ws_1", "files")) orelse return error.TestUnexpectedResult;
    defer stored.deinit(gpa);
    try testing.expectEqualStrings("at-test", stored.access_token);
    try testing.expectEqualStrings("rt-test", stored.refresh_token);
    try testing.expect(!mcp_oauth.isExpired(stored.expires_at, now, 0));

    const access_name = try mcp_oauth_store.secretName(gpa, "files", .access_token);
    defer gpa.free(access_name);
    const raw = try rawSecret(gpa, &ctx.db, access_name);
    defer gpa.free(raw);
    try testing.expect(secrets_at_rest.isSealed(raw));
    try testing.expect(std.mem.indexOf(u8, raw, "at-test") == null);

    const refreshed = try mcp_oauth_flow.refreshToken(gpa, transport, .{
        .token_endpoint = stored.token_endpoint,
        .refresh_token = stored.refresh_token,
        .client_id = stored.client_id,
        .resource = stored.resource,
    });
    defer refreshed.deinit(gpa);
    try testing.expectEqualStrings("at-test", refreshed.access_token);

    try testing.expectEqual(@as(usize, 2), stub.token_bodies.items.len);
    try testing.expect(std.mem.indexOf(u8, stub.token_bodies.items[0], "grant_type=authorization_code") != null);
    try testing.expect(std.mem.indexOf(u8, stub.token_bodies.items[0], "code_verifier=") != null);
    try testing.expect(std.mem.indexOf(u8, stub.token_bodies.items[0], "resource=") != null);
    try testing.expect(std.mem.indexOf(u8, stub.token_bodies.items[1], "grant_type=refresh_token") != null);
    try testing.expect(std.mem.indexOf(u8, stub.token_bodies.items[1], "refresh_token=rt-test") != null);

    try mcp_oauth_store.deleteToken(gpa, &ctx.db, "ws_1", "files");
    try testing.expectEqual(@as(?mcp_oauth_store.TokenRecord, null), try mcp_oauth_store.loadToken(gpa, &ctx.db, "ws_1", "files"));
}

test "an mcp server that answers 401 hands the client a challenge to start the flow" {
    var stub = Stub{ .threaded = undefined, .io = undefined, .port = 0, .server = undefined, .thread = undefined };
    try stub.start();
    defer stub.stopStub();

    const mcp_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/mcp", .{stub.port});
    defer gpa.free(mcp_url);

    var http = mcp_oauth_flow.HttpTransport.init(gpa);
    defer http.deinit();

    var resp = try http.transport().send(gpa, .{ .method = .POST, .url = mcp_url, .body = "{}", .content_type = "application/json" });
    defer resp.deinit(gpa);
    try testing.expectEqual(@as(u16, 401), resp.status);
    try testing.expectEqual(@as(usize, 1), stub.mcp_heads.items.len);

    const challenge_header = headerValue(stub.mcp_heads.items[0], "authorization");
    try testing.expectEqual(@as(?[]const u8, null), challenge_header);
}

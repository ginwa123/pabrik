//! End-to-end functional test for pabrik's MCP OAuth client.
//!
//! Boots the real `mcp-oauth-hello-world` fixture (an OAuth-protected MCP
//! server that also plays the authorization server) and drives the real
//! `pabrik` binary through the whole flow with `pabrik headless mcp-oauth`:
//!
//!   discover → authorize-url → (browser) → exchange → status → refresh → logout
//!
//! The "browser" step is a plain GET of the authorization URL: the fixture
//! auto-approves and answers 302 with `?code=…&state=…`, which is exactly
//! what a consent page would hand back.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const builtin = @import("builtin");
const Io = std.Io;

const gpa = testing.allocator;
const io = testing.io;

const FIXTURE_STARTUP_TIMEOUT_MS: i64 = 20_000;
const POLL_INTERVAL_MS: u64 = 100;

const Fixture = struct {
    child: std.process.Child,
    port: u16,
    stderr_path: []u8,

    fn base(self: *const Fixture, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.port});
    }

    fn mcpUrl(self: *const Fixture, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/mcp", .{self.port});
    }
};

fn whichOnPath(name: []const u8) ?[]u8 {
    const path = std.process.getEnvVarOwned(gpa, "PATH") catch return null;
    defer gpa.free(path);
    var it = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(gpa, &.{ dir, name }) catch continue;
        defer gpa.free(candidate);
        std.Io.Dir.cwd().access(io, candidate, .{}) catch continue;
        return gpa.dupe(u8, candidate) catch null;
    }
    return null;
}

fn fixtureArgv(bin: []const u8, port: u16, port_buf: *[8]u8) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(gpa);

    if (builtin.os.tag != .windows) {
        try argv.append(gpa, bin);
        try argv.append(gpa, try std.fmt.bufPrint(port_buf, "{d}", .{port}));
        return argv;
    }

    const node = whichOnPath("node") orelse return error.SkipZigTest;
    defer gpa.free(node);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(io, bin, &buf) catch 0;
    const dir = if (len == 0) std.fs.path.dirname(bin) orelse "." else std.fs.path.dirname(buf[0..len]) orelse ".";
    const bin_dir = std.fs.path.dirname(dir) orelse ".";
    const zig_out = std.fs.path.dirname(bin_dir) orelse ".";
    const repo_root = std.fs.path.dirname(zig_out) orelse ".";
    const js = try std.fs.path.join(gpa, &.{
        repo_root, "src", "apps", "mcp_oauth_hello_world", "dist", "index.js",
    });
    defer gpa.free(js);
    std.Io.Dir.cwd().access(io, js, .{}) catch return error.SkipZigTest;

    try argv.append(gpa, try gpa.dupe(u8, node));
    try argv.append(gpa, try gpa.dupe(u8, js));
    try argv.append(gpa, try std.fmt.bufPrint(port_buf, "{d}", .{port}));
    return argv;
}

fn startFixture(home: []const u8) !Fixture {
    const bin = harness.mcpOAuthHelloWorldBin(io, gpa) catch |err| switch (err) {
        error.BinaryNotFound => {
            std.debug.print("mcp-oauth-hello-world is not built (run `zig build mcp-oauth-hello-world`); skipping\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer gpa.free(bin);

    const port = try harness.findFreePortRandom(gpa);
    var port_buf: [8]u8 = undefined;
    var argv = try fixtureArgv(bin, port, &port_buf);
    defer {
        for (argv.items) |a| {
            if (a.ptr != bin.ptr and a.ptr != port_buf[0..].ptr) gpa.free(a);
        }
        argv.deinit(gpa);
    }

    const stderr_path = try std.fs.path.join(gpa, &.{ home, ".fixture-stderr" });
    errdefer gpa.free(stderr_path);
    var stderr_file = try std.Io.Dir.cwd().createFile(io, stderr_path, .{});
    defer stderr_file.close(io);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .ignore,
        .stderr = .{ .file = stderr_file },
    });
    errdefer child.kill(io);

    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + FIXTURE_STARTUP_TIMEOUT_MS;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        const log = std.Io.Dir.cwd().readFileAlloc(io, stderr_path, gpa, .limited(1 << 16)) catch "";
        defer if (log.len > 0) gpa.free(log);
        if (std.mem.indexOf(u8, log, "listening on") != null) {
            return .{ .child = child, .port = port, .stderr_path = stderr_path };
        }
        Io.sleep(io, .fromMilliseconds(POLL_INTERVAL_MS), .awake) catch {};
    }
    return error.FixtureNotReady;
}

fn stopFixture(fixture: *Fixture) void {
    fixture.child.kill(io);
    gpa.free(fixture.stderr_path);
}

const Run = struct {
    result: harness.RunResult,
    parsed: ?std.json.Parsed(std.json.Value) = null,

    fn json(self: *Run) !*const std.json.Value {
        if (self.parsed == null) {
            self.parsed = try std.json.parseFromSlice(std.json.Value, gpa, self.result.stdout, .{});
        }
        return &self.parsed.?.value;
    }

    fn deinit(self: *Run) void {
        if (self.parsed) |*p| p.deinit();
        self.result.deinit(gpa);
    }
};

fn mcpOAuth(h: *Harness, argv: []const []const u8) !Run {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &.{ "headless", "mcp-oauth" });
    try full.appendSlice(gpa, argv);

    const result = try harness.runPabrikCommand(io, gpa, h.temp_dir, full.items, 120_000);
    if (result.exit_code != 0) {
        std.debug.print(
            "headless mcp-oauth failed ({?d})\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.exit_code, result.stdout, result.stderr },
        );
        var failed = Run{ .result = result };
        failed.deinit();
        return error.TestUnexpectedResult;
    }
    return .{ .result = result };
}

fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse return error.TestUnexpectedResult;
    return gpa.dupe(u8, id);
}

fn str(doc: *const std.json.Value, key: []const u8) ?[]const u8 {
    const obj = switch (doc.*) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn boolean(doc: *const std.json.Value, key: []const u8) ?bool {
    const obj = switch (doc.*) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

test "headless mcp-oauth authorizes against a real oauth-protected mcp server" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var fixture = try startFixture(h.temp_dir);
    defer stopFixture(&fixture);

    const ws = try createWorkspace(&h, "mcp-oauth-fixture");
    defer gpa.free(ws);

    const mcp_url = try fixture.mcpUrl(gpa);
    defer gpa.free(mcp_url);

    {
        var run = try mcpOAuth(&h, &.{ "discover", "--url", mcp_url });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqualStrings(mcp_url, str(doc, "resource").?);
        try testing.expectEqualStrings("S256", str(doc, "pkce").?);
        try testing.expectEqualStrings("hello:read", str(doc, "scopes_supported") orelse "");
    }

    var state: []u8 = undefined;
    var authorization_url: []u8 = undefined;
    {
        var run = try mcpOAuth(&h, &.{
            "authorize-url",
            "--url",
            mcp_url,
            "--workspace",
            ws,
            "--server",
            "hello",
            "--redirect-uri",
            "http://127.0.0.1:9999/callback",
        });
        defer run.deinit();
        const doc = try run.json();
        authorization_url = try gpa.dupe(u8, str(doc, "authorization_url").?);
        state = try gpa.dupe(u8, str(doc, "state").?);
        try testing.expect(std.mem.indexOf(u8, authorization_url, "code_challenge_method=S256") != null);
        try testing.expect(std.mem.indexOf(u8, authorization_url, "resource=") != null);
    }
    defer gpa.free(state);
    defer gpa.free(authorization_url);

    const code = try approveAuthorization(authorization_url, state);
    defer gpa.free(code);

    {
        var run = try mcpOAuth(&h, &.{
            "exchange",
            "--url",
            mcp_url,
            "--workspace",
            ws,
            "--server",
            "hello",
            "--state",
            state,
            "--code",
            code,
        });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqual(true, boolean(doc, "authorized").?);
        try testing.expectEqual(true, boolean(doc, "has_refresh_token").?);
        try testing.expect(std.mem.indexOf(u8, run.result.stdout, "access_token") == null);
    }

    {
        var run = try mcpOAuth(&h, &.{ "status", "--url", mcp_url, "--workspace", ws, "--server", "hello" });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqual(true, boolean(doc, "authorized").?);
        try testing.expectEqual(false, boolean(doc, "expired").?);
    }

    {
        var run = try mcpOAuth(&h, &.{ "refresh", "--url", mcp_url, "--workspace", ws, "--server", "hello" });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqual(true, boolean(doc, "refreshed").?);
    }

    {
        var run = try mcpOAuth(&h, &.{ "logout", "--url", mcp_url, "--workspace", ws, "--server", "hello" });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqual(true, boolean(doc, "removed").?);
    }

    {
        var run = try mcpOAuth(&h, &.{ "status", "--url", mcp_url, "--workspace", ws, "--server", "hello" });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqual(false, boolean(doc, "authorized").?);
    }
}

/// The "browser" step: GET the authorization URL without following the
/// redirect, and pull `code` out of the `Location` header. The fixture
/// auto-approves, so this is the whole consent interaction.
fn approveAuthorization(authorization_url: []const u8, expected_state: []const u8) ![]u8 {
    var reply = try httpGetNoRedirect(authorization_url);
    defer reply.deinit();
    try testing.expectEqual(@as(u16, 302), reply.status);
    const location = reply.location orelse return error.NoLocation;

    const code_at = std.mem.indexOf(u8, location, "code=") orelse return error.NoCode;
    const rest = location[code_at + "code=".len ..];
    const end = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
    const code = rest[0..end];
    try testing.expect(code.len > 0);

    const state_at = std.mem.indexOf(u8, location, "state=") orelse return error.NoState;
    const state_rest = location[state_at + "state=".len ..];
    const state_end = std.mem.indexOfScalar(u8, state_rest, '&') orelse state_rest.len;
    try testing.expectEqualStrings(expected_state, state_rest[0..state_end]);

    return gpa.dupe(u8, code);
}

const Reply = struct {
    status: u16,
    location: ?[]u8 = null,

    fn deinit(self: *Reply) void {
        if (self.location) |l| gpa.free(l);
    }
};

fn httpGetNoRedirect(url: []const u8) !Reply {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.BadUrl;
    const rest = url[scheme_end + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.BadUrl;
    const authority = rest[0..slash];
    const path = rest[slash..];

    const colon = std.mem.indexOfScalar(u8, authority, ':') orelse return error.BadUrl;
    const host = authority[0..colon];
    const port = try std.fmt.parseInt(u16, authority[colon + 1 ..], 10);

    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    _ = host;
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [4096]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    try sw.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{ path, port });
    try sw.interface.flush();

    var rbuf: [16 * 1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const r = &sr.interface;

    var acc: Io.Writer.Allocating = .init(gpa);
    defer acc.deinit();
    while (true) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        try acc.writer.writeAll(b);
        r.toss(b.len);
        if (acc.written().len > 16 * 1024) break;
        if (std.mem.indexOf(u8, acc.written(), "\r\n\r\n") != null) break;
    }

    const head = acc.written();
    const first_line_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.BadResponse;
    const first_line = head[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    _ = parts.next();
    const status_text = parts.next() orelse return error.BadResponse;
    const status = try std.fmt.parseInt(u16, status_text, 10);

    var location: ?[]u8 = null;
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) break;
        const c = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..c], " \t"), "location")) continue;
        location = try gpa.dupe(u8, std.mem.trim(u8, line[c + 1 ..], " \t"));
    }

    return .{ .status = status, .location = location };
}

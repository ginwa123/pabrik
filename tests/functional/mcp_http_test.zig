// End-to-end functional test for the MCP Streamable HTTP transport (plan
// 2026-08-28-mcp-streamable-http, Task 5 / PR #TBD).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;

const gpa = testing.allocator;
const io = testing.io;

/// Generous, exactly as the Python comment explains: the full `zig build
/// functional-test` run saturates the box (zig compiling + parallel pnpm),
/// and cold node + MCP-SDK import can exceed 5s with an alive-but-silent
const MCP_STARTUP_TIMEOUT_MS: i64 = 15_000;

/// The spec revision `@modelcontextprotocol/sdk` v1.30.0 implements.
const PROTOCOL_VERSION = "2025-11-25";

/// The three tools `mcp-http-hello-world` must advertise, SORTED —
/// Python compared a `sorted(...)` list for equality, so the order is part
/// of the assertion.
const EXPECTED_TOOLS = [_][]const u8{ "print_exit", "print_hello", "print_name" };

// ============================================================================
// Helpers — the fixture server
// ============================================================================

/// The resolved argv for the fixture server. OWNED slice of OWNED strings.
const McpArgv = struct {
    items: [][]u8,

    fn deinit(self: *McpArgv) void {
        for (self.items) |s| gpa.free(s);
        gpa.free(self.items);
        self.* = undefined;
    }
};

/// Resolve the fixture's argv, or SKIP. POSIX:
/// `zig-out/bin/mcp-http-hello-world` is a `#!/bin/sh` + `exec node
/// …/dist/index.js` wrapper and is directly executable.
fn resolveMcpHttpArgv() !McpArgv {
    const bin = harness.mcpHttpHelloWorldBin(io, gpa) catch |err| switch (err) {
        error.BinaryNotFound => {
            std.debug.print("mcp-http-hello-world is not built (run `zig build mcp-http-hello-world`); skipping\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    errdefer gpa.free(bin);

    if (builtin.os.tag != .windows) {
        const items = try gpa.alloc([]u8, 1);
        items[0] = bin;
        return .{ .items = items };
    }

    const node = whichOnPath("node") orelse {
        gpa.free(bin);
        std.debug.print("node not on PATH; cannot run mcp-http-hello-world on Windows\n", .{});
        return error.SkipZigTest;
    };
    defer gpa.free(node);

    // Repo root is two levels above zig-out/bin (bin → zig-out → repo root),
    // mirroring the wrapper's own `$SCRIPT_DIR/../../` lookup.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().realPathFile(io, bin, &buf) catch 0;
    const dir = if (len == 0) std.fs.path.dirname(bin) orelse "." else std.fs.path.dirname(buf[0..len]) orelse ".";
    const bin_dir = std.fs.path.dirname(dir) orelse ".";
    const zig_out = std.fs.path.dirname(bin_dir) orelse ".";
    const repo_root = std.fs.path.dirname(zig_out) orelse ".";
    const js = try std.fs.path.join(gpa, &.{
        repo_root, "src", "apps", "mcp_http_hello_world", "dist", "index.js",
    });
    defer gpa.free(js);
    std.Io.Dir.cwd().access(io, js, .{}) catch {
        std.debug.print("mcp-http-hello-world dist/index.js missing: {s}\n", .{js});
        return error.SkipZigTest;
    };

    const items = try gpa.alloc([]u8, 2);
    items[0] = node;
    items[1] = js;
    return .{ .items = items };
}

/// The first `name` on PATH that is executable, duped. Owned.
fn whichOnPath(name: []const u8) ?[]u8 {
    const path_env = std.process.Environ.getAlloc(std.testing.environ, gpa, "PATH") catch return null;
    defer gpa.free(path_env);
    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const cand = std.fs.path.join(gpa, &.{ dir, name }) catch continue;
        defer gpa.free(cand);
        std.Io.Dir.cwd().access(io, cand, .{ .execute = true }) catch continue;
        return gpa.dupe(u8, cand) catch null;
    }
    return null;
}

/// A spawned fixture server plus the scratch dir holding its stderr.
const McpServer = struct {
    child: std.process.Child,
    scratch: []u8,
    stderr_path: []u8,
    port: u16,
    /// Set once `waitpid` reaped the child, so `deinit` does not `kill` a
    /// pid the kernel may already have recycled.
    reaped: bool = false,
    /// True once `spawn` returned.
    spawned: bool = false,

    fn deinit(self: *McpServer) void {
        if (self.spawned and !self.reaped and self.child.id != null) {
            // `Child.kill` already reaps; there is deliberately no `wait`
            // after it — `wait` asserts `child.id != null` and would panic.
            self.child.kill(io);
        }
        // Registered BEFORE the free below, so the delete runs while the
        // path is still valid (defers are LIFO).
        harness.cleanupExtraDir(io, gpa, self.scratch);
        gpa.free(self.scratch);
        gpa.free(self.stderr_path);
        gpa.destroy(self);
    }
};

fn nowMs() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn sleepMs(ms: i64) void {
    Io.sleep(io, .fromMilliseconds(ms), .awake) catch {};
}

/// Spawn the fixture on `port` and wait for its "listening on" line.
fn spawnMcpHttpHelloWorld(argv: *const McpArgv, port: u16, timeout_ms: i64) !*McpServer {
    const s = try gpa.create(McpServer);

    // Registered FIRST so it runs LAST: `errdefer`s are LIFO, and the
    // order below must be kill → free paths → cleanup dir → destroy.
    errdefer gpa.destroy(s);

    s.reaped = false;
    s.spawned = false;
    s.port = port;

    s.scratch = try harness.makeScratchDir(gpa);
    errdefer gpa.free(s.scratch);
    errdefer harness.cleanupExtraDir(io, gpa, s.scratch);

    s.stderr_path = try std.fs.path.join(gpa, &.{ s.scratch, "mcp-http.err" });
    errdefer gpa.free(s.stderr_path);

    // THE SPACER IS LOAD-BEARING, AND IT FAILS SILENTLY.
    const spacer_path = try std.fs.path.join(gpa, &.{ s.scratch, "fd-spacer" });
    defer gpa.free(spacer_path);
    var spacer = try std.Io.Dir.cwd().createFile(io, spacer_path, .{});
    defer spacer.close(io);

    var log = try std.Io.Dir.cwd().createFile(io, s.stderr_path, .{});
    defer log.close(io);

    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, argv.items);
    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{port});
    defer gpa.free(port_str);
    try full.append(gpa, port_str);

    s.child = try std.process.spawn(io, .{
        .argv = full.items,
        .stdin = .ignore,
        .stdout = .ignore,
        // `.file` hands the CHILD its own dup of the descriptor, so the
        // handle must stay open across the spawn — hence the `defer`
        // above, which fires after this function returns, not before.
        .stderr = .{ .file = log },
    });
    s.spawned = true;
    errdefer if (s.spawned) s.child.kill(io);

    const deadline = nowMs() + timeout_ms;
    while (true) {
        const text = std.Io.Dir.cwd().readFileAlloc(io, s.stderr_path, gpa, .limited(1 << 16)) catch "";
        defer if (text.len > 0) gpa.free(text);
        if (std.mem.indexOf(u8, text, "listening on") != null) return s;

        if (hasExited(s)) {
            std.debug.print(
                "mcp-http-hello-world exited before listening on port {d}\nstderr:\n{s}\n",
                .{ port, text },
            );
            return error.TestUnexpectedResult;
        }
        if (nowMs() >= deadline) {
            std.debug.print(
                "mcp-http-hello-world did not print 'listening on' within {d}ms\nstderr:\n{s}\n",
                .{ timeout_ms, text },
            );
            return error.TestUnexpectedResult;
        }
        sleepMs(50);
    }
}

/// True iff the child has already exited — and remember that it did, so the
/// pid is never `wait`ed twice.
fn hasExited(s: *McpServer) bool {
    if (s.reaped or s.child.id == null) return true;
    if (comptime builtin.os.tag == .windows) return false;
    const pid: std.posix.pid_t = @intCast(s.child.id.?);
    // `std.posix` exposes no `waitpid` wrapper in 0.16 — only the raw
    // system layer — so this is `waitpid(2)` by hand, which is the whole
    // of Python's `proc.poll()` under the hood.
    var status: u32 = 0;
    const got = posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
    if (got == pid) {
        s.reaped = true;
        return true;
    }
    return false;
}

/// A free port for the fixture. The harness's picker skips the reserved
/// 8081 and probes with SO_REUSEADDR, which is exactly what
/// `_find_free_port`'s bind-port-0 dance achieved.
fn findFreePort() !u16 {
    return harness.findFreePortRandom(gpa);
}

// ============================================================================
// Helpers — the JSON-RPC wire
// ============================================================================

/// One raw MCP HTTP exchange. Caller owns every field.
const McpExchange = struct {
    status: u16 = 0,
    content_type: []u8 = &.{},
    body: []u8 = &.{},

    fn deinit(self: *McpExchange) void {
        gpa.free(self.content_type);
        gpa.free(self.body);
        self.* = undefined;
    }
};

/// POST a JSON-RPC body to `<port>/mcp` and capture (status, content type,
/// body) WITHOUT asserting anything about them.
fn postMcp(port: u16, payload: []const u8, headers: []const std.http.Header, out: *McpExchange) !void {
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/mcp", .{port});
    defer gpa.free(url);

    var all: std.ArrayList(std.http.Header) = .empty;
    defer all.deinit(gpa);
    try all.append(gpa, .{ .name = "Content-Type", .value = "application/json" });
    try all.append(gpa, .{ .name = "Accept", .value = "application/json, text/event-stream" });
    try all.appendSlice(gpa, headers);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var req = try client.request(
        .POST,
        try std.Uri.parse(url),
        .{ .redirect_behavior = .unhandled, .extra_headers = all.items },
    );
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    try req.connection.?.flush();

    var resp = try req.receiveHead(&.{});
    out.status = @intFromEnum(resp.head.status);

    // Headers BEFORE the body: `resp.reader()` calls
    // `head.invalidateStrings()`, so reading `head` afterwards is a
    // use-after-free.
    {
        var hit = resp.head.iterateHeaders();
        while (hit.next()) |kv| {
            if (std.ascii.eqlIgnoreCase(kv.name, "content-type")) {
                out.content_type = try gpa.dupe(u8, kv.value);
                break;
            }
        }
    }

    var sink: std.Io.Writer.Allocating = .init(gpa);
    errdefer sink.deinit();
    _ = try resp.reader(&.{}).streamRemaining(&sink.writer);
    try sink.writer.flush();
    out.body = try sink.toOwnedSlice();
}

/// The LAST event's `data:` payload of an SSE body.
fn sseLastData(body: []const u8) ![]u8 {
    // NO `defer` here: the returned slice IS `last`, so a deferred free would
    // hand the caller 0xaa-poisoned memory the moment it returned — and the
    // JSON parse two frames later then fails with a SyntaxError that reads
    var last: ?[]u8 = null;
    errdefer if (last) |l| gpa.free(l);

    var events = std.mem.splitSequence(u8, body, "\n\n");
    while (events.next()) |raw_event| {
        if (std.mem.trim(u8, raw_event, " \t\r\n").len == 0) continue;
        var lines: std.ArrayList([]u8) = .empty;
        defer {
            for (lines.items) |l| gpa.free(l);
            lines.deinit(gpa);
        }
        var line_it = std.mem.splitScalar(u8, raw_event, '\n');
        while (line_it.next()) |line| {
            if (std.mem.startsWith(u8, line, ":")) continue; // SSE comment
            if (!std.mem.startsWith(u8, line, "data:")) continue;
            var value = line["data:".len..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            try lines.append(gpa, try gpa.dupe(u8, value));
        }
        if (lines.items.len > 0) {
            const joined = try std.mem.join(gpa, "\n", lines.items);
            if (last) |l| gpa.free(l);
            last = @constCast(joined);
        }
    }

    const result = last orelse {
        std.debug.print(
            "SSE stream with no data: events\nbody:\n{s}\n",
            .{body[0..@min(500, body.len)]},
        );
        return error.TestUnexpectedResult;
    };
    return result;
}

/// The parsed JSON-RPC response, from JSON or from an SSE stream.
/// `.alloc_always`: the caller deinits the `McpExchange` before it is done
/// with the parsed document, so nothing may borrow the response buffer.
fn parseMcpResponse(x: *const McpExchange) !std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, x.content_type, " \t\r\n");

    if (std.mem.startsWith(u8, trimmed, "text/event-stream")) {
        // The extracted payload is OWNED here, so it is freed on every
        // exit below — and the returned `Parsed` does not borrow it
        // (`.alloc_always`).
        const payload = try sseLastData(x.body);
        defer gpa.free(payload);
        return parseAllocAlways(payload);
    }
    if (std.mem.startsWith(u8, trimmed, "application/json")) {
        return parseAllocAlways(x.body);
    }
    std.debug.print(
        "unexpected content-type: {s}\nbody: {s}\n",
        .{ x.content_type, x.body[0..@min(500, x.body.len)] },
    );
    return error.TestUnexpectedResult;
}

/// `.alloc_always` — the caller deinits the `McpExchange` before it is
/// done with the document, so nothing may borrow the response buffer.
fn parseAllocAlways(payload: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, payload, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print(
            "MCP response is not JSON ({s}): {s}\n",
            .{ @errorName(err), payload[0..@min(500, payload.len)] },
        );
        return error.TestUnexpectedResult;
    };
}

/// A required object field — Python's `d["x"]["y"]`, which RAISED.
fn wantObject(doc: *const std.json.Parsed(std.json.Value), key: []const u8) !std.json.ObjectMap {
    const v = doc.value.object.get(key) orelse {
        std.debug.print("missing key `{s}` in the MCP response\n", .{key});
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .object => |o| o,
        else => {
            std.debug.print("`{s}` is not an object in the MCP response\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
}

fn wantStr(doc: *const std.json.Parsed(std.json.Value), key: []const u8) ![]const u8 {
    const v = doc.value.object.get(key) orelse {
        std.debug.print("missing key `{s}` in the MCP response\n", .{key});
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .string => |s| s,
        else => {
            std.debug.print("`{s}` is not a string in the MCP response\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
}

/// `result.content[0].text` — the exact indexing Python did, so a missing
/// link fails here instead of degrading to "".
fn contentText(result: std.json.ObjectMap) ![]const u8 {
    const content_val = result.get("content") orelse {
        std.debug.print("MCP response has no `result.content`\n", .{});
        return error.TestUnexpectedResult;
    };
    const content = switch (content_val) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    if (content.items.len == 0) return error.TestUnexpectedResult;
    const first = switch (content.items[0]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    return switch (first.get("text") orelse return error.TestUnexpectedResult) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
}

/// One JSON-RPC exchange: POST, then parse. The exchange is deinited
/// before this returns, so the caller owns only the `Parsed`.
fn roundTrip(port: u16, payload: []const u8, headers: []const std.http.Header) !std.json.Parsed(std.json.Value) {
    var x: McpExchange = .{};
    defer x.deinit();
    try postMcp(port, payload, headers, &x);
    return parseMcpResponse(&x);
}

// ============================================================================
// Helpers — the PabrikConfig layer
// ============================================================================

/// `GET /api/config/pabrik`, re-parsed into an OWNING `std.json.Parsed` the
/// caller can MUTATE and re-serialize.
fn fetchConfig(h: *Harness) !std.json.Parsed(std.json.Value) {
    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    return std.json.parseFromSlice(std.json.Value, gpa, r.body, .{ .allocate = .alloc_always });
}

/// `PUT /api/config/pabrik` with a whole config document as the body.
fn putConfig(h: *Harness, cfg: *const std.json.Parsed(std.json.Value)) !void {
    const body = try std.json.Stringify.valueAlloc(gpa, cfg.value, .{});
    defer gpa.free(body);
    var r = try h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = &.{200} });
    r.deinit();
}

/// One `mcp_servers.http_test` entry: `url` plus optional `headers`.
fn putHttpServer(
    h: *Harness,
    name: []const u8,
    url: []const u8,
    headers: ?[]const HeaderPair,
) !void {
    var cfg = try fetchConfig(h);
    defer cfg.deinit();
    const a = cfg.arena.allocator();

    var entry: std.json.ObjectMap = .{};
    try entry.put(a, "url", .{ .string = url });
    if (headers) |pairs| {
        var hdrs: std.json.ObjectMap = .{};
        for (pairs) |p| try hdrs.put(a, p.key, .{ .string = p.value });
        try entry.put(a, "headers", .{ .object = hdrs });
    }
    var outer: std.json.ObjectMap = .{};
    try outer.put(a, name, .{ .object = entry });

    switch (cfg.value) {
        .object => |*o| try o.put(a, "mcp_servers", .{ .object = outer }),
        else => {
            std.debug.print("GET /api/config/pabrik did not return a JSON object\n", .{});
            return error.TestUnexpectedResult;
        },
    }
    try putConfig(h, &cfg);
}

const HeaderPair = struct { key: []const u8, value: []const u8 };

// ============================================================================
// Tests
// ============================================================================

// Direct MCP wire roundtrip — no pabrik involved. Spawn the
// mcp-http-hello-world binary, POST a tools/list + a tools/call, assert the
// responses match what the SDK server would return.
test "http_mcp_direct_roundtrip_no_pabrik" {
    var argv = try resolveMcpHttpArgv();
    defer argv.deinit();

    const port = try findFreePort();
    const server = try spawnMcpHttpHelloWorld(&argv, port, MCP_STARTUP_TIMEOUT_MS);
    defer server.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "MCP-Protocol-Version", .value = PROTOCOL_VERSION },
    };

    // 1. tools/list — assert all 3 tools advertised.
    {
        var list = try roundTrip(port,
            \\{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}
        , &headers);
        defer list.deinit();

        try testing.expectEqualStrings("2.0", try wantStr(&list, "jsonrpc"));
        try testing.expectEqualStrings("1", try wantStr(&list, "id"));

        const result = try wantObject(&list, "result");
        const tools_val = result.get("tools") orelse {
            std.debug.print("tools/list has no `result.tools`\n", .{});
            return error.TestUnexpectedResult;
        };
        const tools = switch (tools_val) {
            .array => |a| a,
            else => return error.TestUnexpectedResult,
        };

        // Python: `sorted(t["name"] for t in tools) == [...]` — a set
        // comparison in disguise, so BOTH the count and the order after
        // sorting are asserted here.
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        for (tools.items) |t| {
            const o = switch (t) {
                .object => |m| m,
                else => continue,
            };
            const n = switch (o.get("name") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            try names.append(gpa, n);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);

        if (names.items.len != EXPECTED_TOOLS.len) {
            std.debug.print("expected {d} tools, got {d}\n", .{ EXPECTED_TOOLS.len, names.items.len });
            return error.TestUnexpectedResult;
        }
        for (names.items, EXPECTED_TOOLS) |got, want| {
            if (!std.mem.eql(u8, got, want)) {
                std.debug.print("tool name mismatch: got {s}, want {s}\n", .{ got, want });
                return error.TestUnexpectedResult;
            }
        }
    }

    // 2. tools/call print_hello with name="world" — assert "Hello world".
    {
        var hello = try roundTrip(port,
            \\{"jsonrpc":"2.0","id":"2","method":"tools/call","params":{"name":"print_hello","arguments":{"name":"world"}}}
        , &headers);
        defer hello.deinit();
        try testing.expectEqualStrings("2", try wantStr(&hello, "id"));
        const text = try contentText(try wantObject(&hello, "result"));
        if (!std.mem.eql(u8, text, "Hello world")) {
            std.debug.print("unexpected print_hello text: {s}\n", .{text});
            return error.TestUnexpectedResult;
        }
    }

    // 3. tools/call print_name — assert server identity.
    {
        var named = try roundTrip(port,
            \\{"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"print_name","arguments":{}}}
        , &headers);
        defer named.deinit();
        try testing.expectEqualStrings("3", try wantStr(&named, "id"));
        const text = try contentText(try wantObject(&named, "result"));
        if (!std.mem.eql(u8, text, "i am mcp-http-hello-world v0.0.1")) {
            std.debug.print("unexpected server identity: {s}\n", .{text});
            return error.TestUnexpectedResult;
        }
    }
}

// Spec (revision 2025-11-25) says: 'A server that supports clients
// implementing protocol versions earlier than 2025-06-18 (which did not
// define the MCP-Protocol-Version header) MAY treat a request that omits the
test "http_mcp_missing_protocol_version_is_lenient" {
    var argv = try resolveMcpHttpArgv();
    defer argv.deinit();

    const port = try findFreePort();
    const server = try spawnMcpHttpHelloWorld(&argv, port, MCP_STARTUP_TIMEOUT_MS);
    defer server.deinit();

    // NO headers at all beyond Content-Type + Accept.
    var x: McpExchange = .{};
    defer x.deinit();
    try postMcp(port,
        \\{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}
    , &.{}, &x);

    // Server treats missing header as 2025-03-26 → request SUCCEEDS (200 OK),
    // same as a spec-compliant request.
    try testing.expectEqual(@as(u16, 200), x.status);

    var parsed = try parseMcpResponse(&x);
    defer parsed.deinit();
    try testing.expectEqualStrings("2.0", try wantStr(&parsed, "jsonrpc"));
    try testing.expectEqualStrings("1", try wantStr(&parsed, "id"));
}

// Targeting a protocol revision the server doesn't support must
// return 400 with an UnsupportedProtocolVersion error. We send
// "1999-01-01" (a deliberately bogus version) and expect 400.
test "http_mcp_unsupported_protocol_version_returns_400" {
    var argv = try resolveMcpHttpArgv();
    defer argv.deinit();

    const port = try findFreePort();
    const server = try spawnMcpHttpHelloWorld(&argv, port, MCP_STARTUP_TIMEOUT_MS);
    defer server.deinit();

    var x: McpExchange = .{};
    defer x.deinit();
    try postMcp(port,
        \\{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}
    , &.{.{ .name = "MCP-Protocol-Version", .value = "1999-01-01" }}, &x);

    try testing.expectEqual(@as(u16, 400), x.status);

    // Python: `json.loads(excinfo.value.read())`.
    var err_body = std.json.parseFromSlice(std.json.Value, gpa, x.body, .{ .allocate = .alloc_always }) catch |e| {
        std.debug.print("400 body is not JSON ({s}): {s}\n", .{ @errorName(e), x.body });
        return error.TestUnexpectedResult;
    };
    defer err_body.deinit();
    try testing.expectEqualStrings("2.0", try wantStr(&err_body, "jsonrpc"));
    if (err_body.value.object.get("error") == null) {
        std.debug.print("400 body has no `error` member: {s}\n", .{x.body});
        return error.TestUnexpectedResult;
    }
}

// Boot pabrik, configure mcp_servers with a real url pointing at a live
// mcp-http-hello-world server, fetch the config back, assert the url
// round-trips.
test "pabrik_config_round_trips_http_mcp_server" {
    var argv = try resolveMcpHttpArgv();
    defer argv.deinit();

    const port = try findFreePort();
    const server = try spawnMcpHttpHelloWorld(&argv, port, MCP_STARTUP_TIMEOUT_MS);
    defer server.deinit();

    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/mcp", .{port});
    defer gpa.free(url);
    try putHttpServer(&h, "http_test", url, &.{.{ .key = "X-Trace-Id", .value = "test-roundtrip" }});

    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // Python: `servers = got.get("mcp_servers") or {}` then a named
    // lookup — a missing block and a missing server both end at the same
    // assert, so both land in `serverEntry`.
    const servers = doc.object("mcp_servers") orelse {
        std.debug.print("http MCP servers missing from the GET response (no `mcp_servers` block)\n", .{});
        return error.TestUnexpectedResult;
    };
    const entry_val = servers.get("http_test") orelse {
        std.debug.print("http MCP server missing from GET: mcp_servers has no `http_test`\n", .{});
        return error.TestUnexpectedResult;
    };
    const entry = switch (entry_val) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };

    const got_url = switch (entry.get("url") orelse return error.TestUnexpectedResult) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    if (!std.mem.eql(u8, got_url, url)) {
        std.debug.print("url mismatch: got {s}, want {s}\n", .{ got_url, url });
        return error.TestUnexpectedResult;
    }

    // Python: `entry.get("headers") == {"X-Trace-Id": "test-roundtrip"}` —
    // a dict equality, so the map is compared by its single key AND its
    // length (an extra header would fail the Python assert too).
    const hdrs_val = entry.get("headers") orelse {
        std.debug.print("http entry lost its headers: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const hdrs = switch (hdrs_val) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    if (hdrs.count() != 1) {
        std.debug.print("expected exactly one header, got {d}\n", .{hdrs.count()});
        return error.TestUnexpectedResult;
    }
    const trace = switch (hdrs.get("X-Trace-Id") orelse {
        std.debug.print("headers lost X-Trace-Id\n", .{});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    if (!std.mem.eql(u8, trace, "test-roundtrip")) {
        std.debug.print("X-Trace-Id mismatch: {s}\n", .{trace});
        return error.TestUnexpectedResult;
    }

    if (entry.get("command") != null) {
        std.debug.print("http entry unexpectedly has command\n", .{});
        return error.TestUnexpectedResult;
    }
}

// End-to-end:hee we're not driving the agent loop (no real LLM).
test "pabrik_http_client_calls_real_mcp_server" {
    var argv = try resolveMcpHttpArgv();
    defer argv.deinit();

    const port = try findFreePort();
    const server = try spawnMcpHttpHelloWorld(&argv, port, MCP_STARTUP_TIMEOUT_MS);
    defer server.deinit();

    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/mcp", .{port});
    defer gpa.free(url);
    try putHttpServer(&h, "http_test", url, null);

    // TODO(port): the agent-loop invocation the Python docstring describes
    // (`initial["active_workspace_id"]` + `active_agent_id` driving a chat
    // turn through `handle_mcp_tool.zig`) was NOT implemented in the Python
    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const servers = doc.object("mcp_servers") orelse {
        std.debug.print("no `mcp_servers` block after the PUT\n", .{});
        return error.TestUnexpectedResult;
    };
    const entry_val = servers.get("http_test") orelse {
        std.debug.print("`http_test` missing after the PUT\n", .{});
        return error.TestUnexpectedResult;
    };
    const entry = switch (entry_val) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const got_url = switch (entry.get("url") orelse return error.TestUnexpectedResult) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    if (!std.mem.eql(u8, got_url, url)) {
        std.debug.print("url mismatch after PUT: got {s}, want {s}\n", .{ got_url, url });
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier: an unreferenced helper is never type-checked, so a
// stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = resolveMcpHttpArgv;
    _ = whichOnPath;
    _ = spawnMcpHttpHelloWorld;
    _ = hasExited;
    _ = findFreePort;
    _ = postMcp;
    _ = sseLastData;
    _ = parseMcpResponse;
    _ = parseAllocAlways;
    _ = roundTrip;
    _ = wantObject;
    _ = wantStr;
    _ = contentText;
    _ = fetchConfig;
    _ = putConfig;
    _ = putHttpServer;
    _ = nowMs;
    _ = sleepMs;
    _ = McpServer.deinit;
    _ = McpArgv.deinit;
    _ = McpExchange.deinit;
    _ = Harness.boot;
}

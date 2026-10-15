// End-to-end functional test for the MCP stdio transport (plan
// 2026-08-27-mcp-stdio, Task 5 / PR #365).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

const builtin = @import("builtin");

// ============================================================================
// Helpers
// ============================================================================

/// The three tools `mcp-hello-world` must advertise.
const EXPECTED_TOOLS = [_][]const u8{ "print_hello", "print_name", "print_exit" };

/// `_send_jsonrpc(..., timeout_s=5.0)`'s budget, in ms.
const JSONRPC_TIMEOUT_MS: u32 = 5_000;

/// Locate the `mcp-hello-world` binary, or skip. The Python wrapper turned
/// `harness.mcp_hello_world_bin`'s raise into `pytest.skip`; the Zig idiom is
/// `error.SkipZigTest`.
fn requireMcpBin() ![]u8 {
    if (builtin.os.tag == .windows) {
        // Python: `if sys.platform == "win32": pytest.skip("mcp-hello-world
        // shell wrapper requires POSIX sh")`.
        return error.SkipZigTest;
    }
    return harness.mcpHelloWorldBin(io, gpa) catch |err| switch (err) {
        error.BinaryNotFound => return error.SkipZigTest,
        else => return err,
    };
}

/// The canonical MCP stdio `tools/list` frame, plus the extra newline the
/// Python wrote.
fn frameRpc(body: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    // LF separator is what the SDK accepts; CRLF works but is one extra
    // byte we do not need.
    try out.writer.print("Content-Length: {d}\n\n", .{body.len});
    try out.writer.writeAll(body);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// Spawn `binary`, feed it ONE Content-Length-framed JSON-RPC body, read ONE
/// response, terminate. Returns the PARSED JSON-RPC response.
fn sendJsonRpc(binary: []const u8, body: []const u8, timeout_ms: u32) !std.json.Parsed(std.json.Value) {
    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch); // LAST
    defer harness.cleanupExtraDir(io, gpa, scratch); // before the free

    const framed = try frameRpc(body);
    defer gpa.free(framed);

    const stdin_path = try std.fs.path.join(gpa, &.{ scratch, "rpc-stdin" });
    defer gpa.free(stdin_path);
    // `defer`, not `errdefer`: the function RETURNS a value, so the
    // success path is the common one and an `errdefer` would leak the
    // path on every passing call.
    const stdout_path = try std.fs.path.join(gpa, &.{ scratch, "rpc-stdout" });
    defer gpa.free(stdout_path);
    const stderr_path = try std.fs.path.join(gpa, &.{ scratch, "rpc-stderr" });
    defer gpa.free(stderr_path);

    // THE SPACER IS LOAD-BEARING, AND IT FIXES A HAZARD THAT IS INVISIBLE
    // UNTIL IT BITES.
    const spacer_path = try std.fs.path.join(gpa, &.{ scratch, "rpc-fd-spacer" });
    defer gpa.free(spacer_path);
    var spacer = try std.Io.Dir.cwd().createFile(io, spacer_path, .{});
    defer spacer.close(io);

    // The frame is on disk BEFORE the spawn, so the child's first read
    // returns immediately rather than racing the parent's write — the
    // ordering guarantee `communicate(input=...)` gave for free.
    var in_file = try std.Io.Dir.cwd().createFile(io, stdin_path, .{ .read = true });
    defer in_file.close(io);
    try in_file.writePositionalAll(io, framed, 0);

    var out_file = try std.Io.Dir.cwd().createFile(io, stdout_path, .{});
    defer out_file.close(io);
    var err_file = try std.Io.Dir.cwd().createFile(io, stderr_path, .{});
    defer err_file.close(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{binary},
        .stdin = .{ .file = in_file },
        .stdout = .{ .file = out_file },
        .stderr = .{ .file = err_file },
    });
    // `Child.kill` ALREADY reaps, so there is deliberately no `wait`
    // after it — `wait` opens with `assert(child.id != null)` and would
    // panic on the second reap.
    defer child.kill(io);

    var timed_out = std.atomic.Value(bool).init(false);
    const watchdog = try std.Thread.spawn(.{}, struct {
        fn killAfter(c: *std.process.Child, ms: u32, flag: *std.atomic.Value(bool)) void {
            std.Io.sleep(io, .fromMilliseconds(ms), .awake) catch return;
            flag.store(true, .release);
            c.kill(io);
        }
    }.killAfter, .{ &child, timeout_ms, &timed_out });
    const term = child.wait(io) catch {
        watchdog.join();
        return error.RunFailed;
    };
    watchdog.join();

    // A clean exit is a clean exit even if the watchdog woke during it.
    const exited_normally = switch (term) {
        .exited => true,
        else => false,
    };
    if (!exited_normally and timed_out.load(.acquire)) {
        const stderr_bytes = std.Io.Dir.cwd().readFileAlloc(io, stderr_path, gpa, .limited(1 << 18)) catch
            try gpa.dupe(u8, "<none>");
        defer gpa.free(stderr_bytes);
        std.debug.print(
            "mcp-hello-world timed out after {d}ms reading response. stderr: {s}\n",
            .{ timeout_ms, stderr_bytes },
        );
        return error.TestUnexpectedResult;
    }

    const stdout_bytes = try std.Io.Dir.cwd().readFileAlloc(io, stdout_path, gpa, .limited(1 << 20));
    defer gpa.free(stdout_bytes);
    const stderr_bytes = try std.Io.Dir.cwd().readFileAlloc(io, stderr_path, gpa, .limited(1 << 18));
    defer gpa.free(stderr_bytes);

    // The @modelcontextprotocol/sdk v1.x writes NEWLINE-DELIMITED JSON
    // (`JSON.stringify(msg) + "\n"`), NOT Content-Length framed responses —
    // see `src/apps/mcp_hello_world/node_modules/@modelcontextprotocol/sdk/
    var payload = stdout_bytes;
    if (std.mem.startsWith(u8, stdout_bytes, "Content-Length:")) {
        const sep = std.mem.indexOf(u8, stdout_bytes, "\n\n") orelse {
            std.debug.print("no \\n\\n separator in framed response: {s}\n", .{stdout_bytes[0..@min(200, stdout_bytes.len)]});
            return error.TestUnexpectedResult;
        };
        payload = stdout_bytes[sep + 2 ..];
    }

    // `.alloc_always`: the parsed strings must not borrow the captured
    // stdout buffer, which is freed at the end of this function.
    return std.json.parseFromSlice(std.json.Value, gpa, payload, .{ .allocate = .alloc_always }) catch |err| {
        const quoted = harness.debugString(gpa, payload[0..@min(300, payload.len)]) catch return err;
        defer gpa.free(quoted);
        std.debug.print(
            "failed to parse mcp-hello-world response as JSON: {s}\nbody: {s}\nstderr: {s}\n",
            .{ @errorName(err), quoted, stderr_bytes[0..@min(200, stderr_bytes.len)] },
        );
        return error.TestUnexpectedResult;
    };
}

/// `GET /api/config/pabrik`, re-parsed into an OWNED `std.json.Parsed` the
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

/// One `"K": "V"` header pair.
const HeaderPair = struct { key: []const u8, value: []const u8 };

/// One `mcp_servers.<name>` entry, in the shape Python's dict literal used.
const ServerSpec = struct {
    name: []const u8,
    command: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
    env: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    url: ?[]const u8 = null,
    headers: ?[]const HeaderPair = null,
};

/// Build the `mcp_servers` object for a PUT body.
fn buildServers(a: std.mem.Allocator, specs: []const ServerSpec) !std.json.Value {
    var outer: std.json.ObjectMap = .{};
    for (specs) |spec| {
        var entry: std.json.ObjectMap = .{};
        if (spec.command) |c| try entry.put(a, "command", .{ .string = c });
        if (spec.args) |v| try entry.put(a, "args", try strArray(a, v));
        if (spec.env) |v| try entry.put(a, "env", try strArray(a, v));
        if (spec.cwd) |v| try entry.put(a, "cwd", .{ .string = v });
        if (spec.url) |v| try entry.put(a, "url", .{ .string = v });
        if (spec.headers) |pairs| {
            var hdrs: std.json.ObjectMap = .{};
            for (pairs) |p| try hdrs.put(a, p.key, .{ .string = p.value });
            try entry.put(a, "headers", .{ .object = hdrs });
        }
        try outer.put(a, spec.name, .{ .object = entry });
    }
    return .{ .object = outer };
}

fn strArray(a: std.mem.Allocator, vals: []const []const u8) !std.json.Value {
    // `std.json.Array` is `array_list.Managed(Value)`: it CARRIES its
    // allocator, so `append` takes only the item (the unmanaged
    // `std.ArrayList` spelling takes the allocator per call).
    var arr: std.json.Array = try .initCapacity(a, vals.len);
    for (vals) |v| try arr.append(.{ .string = v });
    return .{ .array = arr };
}

/// Overwrite `mcp_servers` on a fetched config with `specs`, then PUT it.
fn putServers(h: *Harness, specs: []const ServerSpec) !void {
    var cfg = try fetchConfig(h);
    defer cfg.deinit();
    const a = cfg.arena.allocator();
    const servers = try buildServers(a, specs);
    switch (cfg.value) {
        .object => |*o| try o.put(a, "mcp_servers", servers),
        else => {
            std.debug.print("GET /api/config/pabrik did not return a JSON object\n", .{});
            return error.TestUnexpectedResult;
        },
    }
    try putConfig(h, &cfg);
}

/// The `mcp_servers` object of a GET response, or an error. Python: `servers
/// = got.get("mcp_servers") or {}` then a named lookup. A missing block and a
/// missing server both ended at the same assert, so both land here.
fn serversOf(doc: *const harness.Json) !std.json.ObjectMap {
    return doc.object("mcp_servers") orelse {
        std.debug.print("stdio MCP servers missing from the GET response (no `mcp_servers` block)\n", .{});
        return error.TestUnexpectedResult;
    };
}

fn serverEntry(servers: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    const entry = servers.get(name) orelse {
        var names: std.Io.Writer.Allocating = .init(gpa);
        defer names.deinit();
        var it = servers.iterator();
        while (it.next()) |kv| {
            names.writer.print("{s} ", .{kv.key_ptr.*}) catch break;
        }
        std.debug.print("server `{s}` missing from GET; have: {s}\n", .{ name, names.written() });
        return error.TestUnexpectedResult;
    };
    return switch (entry) {
        .object => |o| o,
        else => {
            std.debug.print("mcp_servers.{s} is not an object\n", .{name});
            return error.TestUnexpectedResult;
        },
    };
}

/// The `args` array of an entry, or null when absent / not an array.
fn argsOf(entry: std.json.ObjectMap) ?[]const std.json.Value {
    const v = entry.get("args") orelse return null;
    return switch (v) {
        .array => |a| a.items,
        else => null,
    };
}

/// True iff `args` is exactly `want` (Python: `== ["--some-flag"]`).
fn argsEqual(entry: std.json.ObjectMap, want: []const []const u8) bool {
    const arr = argsOf(entry) orelse return false;
    if (arr.len != want.len) return false;
    for (arr, want) |got, expected| {
        if (got != .string) return false;
        if (!std.mem.eql(u8, got.string, expected)) return false;
    }
    return true;
}

// ============================================================================
// Test 1: direct MCP stdio roundtrip
// ============================================================================

// mcp-hello-world responds to tools/list with 3 tools.
test "mcp_hello_world_lists_tools" {
    const binary = try requireMcpBin();
    defer gpa.free(binary);

    var resp = try sendJsonRpc(binary,
        \\{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}
    , JSONRPC_TIMEOUT_MS);
    defer resp.deinit();

    const result = resp.value.object.get("result") orelse {
        std.debug.print("unexpected response shape: {any}\n", .{resp.value});
        return error.TestUnexpectedResult;
    };
    const result_obj = switch (result) {
        .object => |o| o,
        else => {
            std.debug.print("`result` is not an object: {any}\n", .{result});
            return error.TestUnexpectedResult;
        },
    };
    // Python: `resp["result"].get("tools", [])` — a missing list is an
    // empty list, which then fails the NAME check below with a
    // readable message.
    const tools: []const std.json.Value = switch (result_obj.get("tools") orelse std.json.Value{ .null = {} }) {
        .array => |a| a.items,
        else => &.{},
    };

    // Python built a SET and compared for equality, so the count and
    // every name must match — an extra tool fails just as a missing one
    // does.
    var seen: usize = 0;
    for (EXPECTED_TOOLS) |want| {
        var found = false;
        for (tools) |t| {
            const o = switch (t) {
                .object => |oo| oo,
                else => continue,
            };
            const n = switch (o.get("name") orelse std.json.Value{ .null = {} }) {
                .string => |s| s,
                else => continue,
            };
            if (std.mem.eql(u8, n, want)) found = true;
        }
        if (!found) {
            std.debug.print("expected tool `{s}` in the tools/list response\n", .{want});
            return error.TestUnexpectedResult;
        }
        seen += 1;
    }
    if (tools.len != seen) {
        std.debug.print("expected exactly {d} tools, got {d}\n", .{ seen, tools.len });
        return error.TestUnexpectedResult;
    }
}

// mcp-hello-world tools/call print_hello('MCP') returns 'Hello MCP'.
test "mcp_hello_world_call_print_hello" {
    const binary = try requireMcpBin();
    defer gpa.free(binary);

    var resp = try sendJsonRpc(binary,
        \\{"jsonrpc":"2.0","id":"2","method":"tools/call","params":{"name":"print_hello","arguments":{"name":"MCP"}}}
    , JSONRPC_TIMEOUT_MS);
    defer resp.deinit();

    const result_obj = switch (resp.value.object.get("result") orelse {
        std.debug.print("unexpected response shape: {any}\n", .{resp.value});
        return error.TestUnexpectedResult;
    }) {
        .object => |o| o,
        else => {
            std.debug.print("`result` is not an object\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    // Python: `resp["result"].get("content", [])` then
    // `assert content` — an empty list is the failure, reported with the
    // whole response for context.
    const content: []const std.json.Value = switch (result_obj.get("content") orelse std.json.Value{ .null = {} }) {
        .array => |a| a.items,
        else => &.{},
    };
    if (content.len == 0) {
        std.debug.print("empty content: {any}\n", .{resp.value});
        return error.TestUnexpectedResult;
    }
    const first = switch (content[0]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const text = switch (first.get("text") orelse std.json.Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };
    if (!std.mem.eql(u8, text, "Hello MCP")) {
        std.debug.print("unexpected reply text: {s}\n", .{text});
        return error.TestUnexpectedResult;
    }
}

// mcp-hello-world tools/call print_name() returns server identity.
test "mcp_hello_world_call_print_name" {
    const binary = try requireMcpBin();
    defer gpa.free(binary);

    var resp = try sendJsonRpc(binary,
        \\{"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"print_name","arguments":{}}}
    , JSONRPC_TIMEOUT_MS);
    defer resp.deinit();

    const result_obj = switch (resp.value.object.get("result") orelse {
        std.debug.print("unexpected response shape: {any}\n", .{resp.value});
        return error.TestUnexpectedResult;
    }) {
        .object => |o| o,
        else => {
            std.debug.print("`result` is not an object\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    // Python: `resp["result"].get("content", [])` then
    // `assert content` — an empty list is the failure, reported with the
    // whole response for context.
    const content: []const std.json.Value = switch (result_obj.get("content") orelse std.json.Value{ .null = {} }) {
        .array => |a| a.items,
        else => &.{},
    };
    if (content.len == 0) {
        std.debug.print("empty content: {any}\n", .{resp.value});
        return error.TestUnexpectedResult;
    }
    const first = switch (content[0]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const text = switch (first.get("text") orelse std.json.Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };
    // Python indexed `resp["result"]["content"][0]["text"]` DIRECTLY, so a
    // missing key raised rather than degrading to "" — `text` here is never
    // empty for a well-formed reply and the prefix test catches that.
    if (!std.mem.startsWith(u8, text, "i am ")) {
        std.debug.print("unexpected server identity: {s}\n", .{text});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, text, "mcp-hello-world") == null) {
        std.debug.print("server identity does not name mcp-hello-world: {s}\n", .{text});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: pabrik accepts stdio mcp_servers config
// ============================================================================

// PUT a PabrikConfig with stdio mcp_servers -> GET preserves the entry.
test "pabrik_config_round_trips_stdio_mcp_servers" {
    const binary = try requireMcpBin();
    defer gpa.free(binary);
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try putServers(&h, &.{.{ .name = "hello", .command = binary, .args = &.{"--some-flag"} }});

    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const servers = try serversOf(&doc);
    const hello = try serverEntry(servers, "hello");
    const cmd = switch (hello.get("command") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => {
            std.debug.print("command mismatch: not a string\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, cmd, binary)) {
        std.debug.print("command mismatch: got {s}\n", .{cmd});
        return error.TestUnexpectedResult;
    }
    if (!argsEqual(hello, &.{"--some-flag"})) {
        std.debug.print("args mismatch\n", .{});
        return error.TestUnexpectedResult;
    }
    // Legacy http entries must NOT have leaked into the stdio entry.
    if (hello.get("url") != null) {
        std.debug.print("stdio entry unexpectedly has a url field\n", .{});
        return error.TestUnexpectedResult;
    }
    if (hello.get("headers") != null) {
        std.debug.print("stdio entry unexpectedly has a headers field\n", .{});
        return error.TestUnexpectedResult;
    }
}

// Two stdio MCP servers with different commands round-trip independently.
// Proves the mcp_servers map is keyed by name (each entry is its own
// child-spawn config) — not by a global single-child assumption.
test "pabrik_config_round_trips_multiple_stdio_mcp_servers" {
    const binary = try requireMcpBin();
    defer gpa.free(binary);
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try putServers(&h, &.{
        .{ .name = "alpha", .command = binary, .args = &.{ "--name", "alpha" } },
        .{ .name = "beta", .command = binary, .args = &.{ "--name", "beta" }, .env = &.{"FOO=bar"}, .cwd = "/tmp" },
    });

    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const servers = try serversOf(&doc);
    const alpha = try serverEntry(servers, "alpha");
    const beta = try serverEntry(servers, "beta");

    if (!argsEqual(alpha, &.{ "--name", "alpha" })) {
        std.debug.print("alpha args mismatch\n", .{});
        return error.TestUnexpectedResult;
    }
    if (!argsEqual(beta, &.{ "--name", "beta" })) {
        std.debug.print("beta args mismatch\n", .{});
        return error.TestUnexpectedResult;
    }
    const env: []const std.json.Value = switch (beta.get("env") orelse std.json.Value{ .null = {} }) {
        .array => |a| a.items,
        else => &.{},
    };
    if (env.len != 1 or env[0] != .string or !std.mem.eql(u8, env[0].string, "FOO=bar")) {
        std.debug.print("beta env mismatch\n", .{});
        return error.TestUnexpectedResult;
    }
    const cwd = switch (beta.get("cwd") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => "",
    };
    if (!std.mem.eql(u8, cwd, "/tmp")) {
        std.debug.print("beta cwd mismatch: got {s}\n", .{cwd});
        return error.TestUnexpectedResult;
    }
}

// A config with both HTTP and stdio servers round-trips correctly. Proves the
// discriminator (presence of `command` => stdio, presence of `url` => http)
// is honored through the wire — neither branch collides with the other.
test "pabrik_config_mixes_http_and_stdio_mcp_servers" {
    const binary = try requireMcpBin();
    defer gpa.free(binary);
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try putServers(&h, &.{
        .{
            .name = "context7",
            .url = "https://mcp.context7.com/mcp",
            .headers = &.{.{ .key = "X-Token", .value = "secret123" }},
        },
        .{ .name = "hello", .command = binary, .args = &.{} },
    });

    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const servers = try serversOf(&doc);

    // HTTP entry preserved.
    const ctx = servers.get("context7") orelse std.json.Value{ .object = .{} };
    const ctx_obj = switch (ctx) {
        .object => |o| o,
        else => std.json.ObjectMap{},
    };
    const ctx_url = switch (ctx_obj.get("url") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => "",
    };
    if (!std.mem.eql(u8, ctx_url, "https://mcp.context7.com/mcp")) {
        std.debug.print("context7 url mismatch: got {s}\n", .{ctx_url});
        return error.TestUnexpectedResult;
    }
    const ctx_headers_val = ctx_obj.get("headers") orelse std.json.Value{ .object = .{} };
    const ctx_headers = switch (ctx_headers_val) {
        .object => |o| o,
        else => std.json.ObjectMap{},
    };
    const token = switch (ctx_headers.get("X-Token") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => "",
    };
    if (!std.mem.eql(u8, token, "secret123")) {
        std.debug.print("context7 headers mismatch: X-Token = {s}\n", .{token});
        return error.TestUnexpectedResult;
    }
    if (ctx_obj.get("command") != null) {
        std.debug.print("http entry unexpectedly gained a command field\n", .{});
        return error.TestUnexpectedResult;
    }

    // stdio entry preserved.
    const hello = try serverEntry(servers, "hello");
    const cmd = switch (hello.get("command") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => "",
    };
    if (!std.mem.eql(u8, cmd, binary)) {
        std.debug.print("stdio entry command mismatch: got {s}\n", .{cmd});
        return error.TestUnexpectedResult;
    }
    if (hello.get("url") != null) {
        std.debug.print("stdio entry unexpectedly has a url field\n", .{});
        return error.TestUnexpectedResult;
    }
    if (hello.get("headers") != null) {
        std.debug.print("stdio entry unexpectedly has a headers field\n", .{});
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = frameRpc;
    _ = sendJsonRpc;
    _ = fetchConfig;
    _ = putConfig;
    _ = buildServers;
    _ = strArray;
    _ = putServers;
    _ = serversOf;
    _ = serverEntry;
    _ = argsOf;
    _ = argsEqual;
    _ = requireMcpBin;
    _ = Harness.boot;
}

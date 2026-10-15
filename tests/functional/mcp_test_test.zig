// End-to-end functional tests for `POST /api/mcp/test` (the "Test" button on
// the Add/Edit MCP server modal).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

// ============================================================================
// Helpers
// ============================================================================

fn bootStubProfile() !Harness {
    return Harness.boot(io, gpa, .{ .stub_llm_profile = true });
}

/// Locate the `mcp-hello-world` binary, or skip.
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

/// `POST /api/mcp/test` → the parsed body (OWNED).
fn postTest(h: *Harness, body: []const u8) !std.json.Parsed(std.json.Value) {
    var r = try h.http(io, .POST, "/api/mcp/test", .{
        .json_body = body,
        .expect = &.{200},
        .timeout_s = 30.0,
    });
    defer r.deinit();
    return std.json.parseFromSlice(std.json.Value, gpa, r.body, .{ .allocate = .alloc_always });
}

fn rootObject(doc: *const std.json.Parsed(std.json.Value)) !std.json.ObjectMap {
    return switch (doc.value) {
        .object => |o| o,
        else => {
            std.debug.print("[mcp_test] response is not a JSON object\n", .{});
            return error.TestUnexpectedResult;
        },
    };
}

/// The `ok` boolean — the probe's own verdict.
fn okOf(doc: *const std.json.Parsed(std.json.Value)) !bool {
    const obj = try rootObject(doc);
    return switch (obj.get("ok") orelse std.json.Value{ .null = {} }) {
        .bool => |b| b,
        else => {
            std.debug.print("[mcp_test] response has no boolean `ok`\n", .{});
            return error.TestUnexpectedResult;
        },
    };
}

/// Python's `result.get("error", "")` — absent degrades to `""`.
fn errorOf(doc: *const std.json.Parsed(std.json.Value)) ![]const u8 {
    const obj = try rootObject(doc);
    return switch (obj.get("error") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => "",
    };
}

/// Python's `result.get("details", "")` — absent degrades to `""`.
fn detailsOf(doc: *const std.json.Parsed(std.json.Value)) []const u8 {
    const obj = switch (doc.value) {
        .object => |o| o,
        else => return "",
    };
    return switch (obj.get("details") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => "",
    };
}

fn transportOf(doc: *const std.json.Parsed(std.json.Value)) ![]const u8 {
    const obj = try rootObject(doc);
    return switch (obj.get("transport") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => {
            std.debug.print("[mcp_test] response has no string `transport`\n", .{});
            return error.TestUnexpectedResult;
        },
    };
}

/// The tool names in a successful probe response (owned, wire order).
fn toolNames(doc: *const std.json.Parsed(std.json.Value)) ![][]const u8 {
    const obj = try rootObject(doc);
    const arr = switch (obj.get("tools") orelse std.json.Value{ .null = {} }) {
        .array => |a| a,
        else => {
            std.debug.print("[mcp_test] response has no `tools` array\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    for (arr.items) |item| {
        const o = switch (item) {
            .object => |oo| oo,
            else => continue,
        };
        const n = switch (o.get("name") orelse std.json.Value{ .null = {} }) {
            .string => |s| s,
            else => continue,
        };
        try out.append(gpa, try gpa.dupe(u8, n));
    }
    return out.toOwnedSlice(gpa);
}

fn freeNames(names: [][]const u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

/// Assert `names` is exactly `want`, as a SET — Python built a set, so
/// an extra tool fails exactly like a missing one.
fn expectNameSet(got: [][]const u8, want: []const []const u8, what: []const u8) !void {
    if (got.len != want.len) {
        std.debug.print("{s}: expected {d} tools, got {d}\n", .{ what, want.len, got.len });
        return error.TestUnexpectedResult;
    }
    for (want) |w| {
        var found = false;
        for (got) |g| {
            if (std.mem.eql(u8, g, w)) found = true;
        }
        if (!found) {
            std.debug.print("{s}: missing tool `{s}`\n", .{ what, w });
            return error.TestUnexpectedResult;
        }
    }
}

/// Print the failing probe body the way Python's `_post_test` did — the
/// harness wipes the server log on teardown, so the body is the only
/// diagnostic a failure has.
fn dumpBody(doc: *const std.json.Parsed(std.json.Value)) void {
    const rendered = std.json.Stringify.valueAlloc(gpa, doc.value, .{}) catch {
        std.debug.print("[mcp_test] body: <unrenderable>\n", .{});
        return;
    };
    defer gpa.free(rendered);
    std.debug.print("[mcp_test] body: {s}\n", .{rendered});
}

fn monotonicMs() i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// `fchmod 0755` on POSIX; a no-op on Windows (which has no execute
/// bit, and where every test that needs a shell script skips anyway).
fn makeExecutable(f: std.Io.File) !void {
    if (builtin.os.tag == .windows) return;
    try f.setPermissions(io, @enumFromInt(0o755));
}

/// Write `contents` to `<scratch>/<name>`, make it executable, and
/// return its absolute path (owned).
fn writeExecutableScript(scratch: []const u8, name: []const u8, contents: []const u8) ![]u8 {
    const path = try std.fs.path.join(gpa, &.{ scratch, name });
    errdefer gpa.free(path);
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
    try makeExecutable(f);
    return path;
}

// ============================================================================
// Stub SSE upstream (Test 8)
// ============================================================================

/// The JSON-RPC payload the stub answers with.
const SSE_TOOLS_JSON =
    \\{"jsonrpc":"2.0","id":"1","result":{"tools":[{"name":"resolve-library-id","description":"Resolves a lib id"},{"name":"query-docs","description":"Queries docs"}]}}
;

/// Byte-for-byte the context7 shape: an `event:` line, then a `data:` line,
/// then the SSE terminator.
const SSE_PAYLOAD = "event: message\n" ++
    \\data: {"jsonrpc":"2.0","id":"1","result":{"tools":[{"name":"resolve-library-id","description":"Resolves a lib id"},{"name":"query-docs","description":"Queries docs"}]}}
++ "\n\n";

/// One-shot HTTP stub that records the probe's request and answers with a
/// fixed `text/event-stream` body.
const SseStub = struct {
    port: u16,
    payload: []const u8,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    /// Guards `req_head` / `req_body`; the serve thread writes while the
    /// test reads.
    mutex: Io.Mutex = .init,
    req_head: ?[]u8 = null,
    req_body: ?[]u8 = null,

    fn start(stub: *SseStub, payload: []const u8) !void {
        stub.* = .{
            .port = 0,
            .payload = payload,
            .server = undefined,
            .thread = undefined,
        };
        // `Io.net` has no getsockname, so the port is picked the way
        // `Harness.boot` picks one for the child and then bound.
        stub.port = try harness.findFreePortRandom(gpa);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
        stub.server = try addr.listen(io, .{ .reuse_address = true });
        errdefer stub.server.deinit(io);
        stub.thread = try std.Thread.spawn(.{}, serve, .{stub});
    }

    fn deinit(stub: *SseStub) void {
        stub.stop.store(true, .release);
        // Wake the blocked `accept`.
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
        if (addr.connect(io, .{ .mode = .stream })) |conn| {
            var c = conn;
            c.close(io);
        } else |_| {}
        stub.thread.join();
        stub.server.deinit(io);
        if (stub.req_head) |s| gpa.free(s);
        if (stub.req_body) |s| gpa.free(s);
        stub.req_head = null;
        stub.req_body = null;
    }

    /// The recorded request head (borrowed; valid until `deinit`).
    fn head(stub: *SseStub) ?[]const u8 {
        stub.mutex.lockUncancelable(io);
        defer stub.mutex.unlock(io);
        return stub.req_head;
    }

    /// The recorded request body (borrowed; valid until `deinit`).
    fn bodyOf(stub: *SseStub) ?[]const u8 {
        stub.mutex.lockUncancelable(io);
        defer stub.mutex.unlock(io);
        return stub.req_body;
    }
};

fn serve(stub: *SseStub) void {
    while (!stub.stop.load(.acquire)) {
        var stream = stub.server.accept(io) catch break;
        defer stream.close(io);
        if (stub.stop.load(.acquire)) break;
        handleStubRequest(stub, stream) catch {};
    }
}

fn handleStubRequest(stub: *SseStub, stream: Io.net.Stream) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const r = &sr.interface;

    // Head and body overlap in the socket buffer: one `fill` typically
    // returns both, so accumulate and cut at the first `\r\n\r\n`.
    var head_acc: Io.Writer.Allocating = .init(gpa);
    defer head_acc.deinit();
    var head_len: usize = 0;
    while (head_len == 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        head_acc.writer.writeAll(b) catch break;
        r.toss(b.len);
        if (std.mem.indexOf(u8, head_acc.written(), "\r\n\r\n")) |i| head_len = i + 4;
    }
    if (head_len == 0) return;

    var body_acc: Io.Writer.Allocating = .init(gpa);
    defer body_acc.deinit();
    var remaining = contentLength(head_acc.written()[0..head_len]);
    if (head_acc.written().len > head_len) {
        const already = head_acc.written()[head_len..];
        try body_acc.writer.writeAll(already);
        remaining -|= already.len;
    }
    while (remaining > 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        const take = @min(b.len, remaining);
        try body_acc.writer.writeAll(b[0..take]);
        r.toss(take);
        remaining -= take;
    }

    stub.mutex.lockUncancelable(io);
    defer stub.mutex.unlock(io);
    if (stub.req_head) |s| gpa.free(s);
    if (stub.req_body) |s| gpa.free(s);
    stub.req_head = try gpa.dupe(u8, head_acc.written()[0..head_len]);
    stub.req_body = try gpa.dupe(u8, body_acc.written());

    // `Content-Length` counts the WHOLE SSE payload (`event:` line,
    // `data:` line and the blank-line terminator), not just the JSON.
    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
        .{ stub.payload.len, stub.payload },
    );
    defer gpa.free(response);

    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    try sw.interface.writeAll(response);
    try sw.interface.flush();
}

fn contentLength(head: []const u8) usize {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // request line
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "content-length")) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch 0;
    }
    return 0;
}

/// The value of `name` in a recorded request head, or null.
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

// ============================================================================
// Test 1: stdio success — fires tools/list against mcp-hello-world
// ============================================================================

// mcp-hello-world responds to tools/list with 3 tools well inside the
// 10s probe timeout. Proves the happy path: spawn child + framed
// send/recv + parse + return the tools list.
test "mcp_test_stdio_success_lists_hello_world_tools" {
    const binary = try requireMcpBin();
    defer gpa.free(binary);
    try harness.requirePabrikBin(io, gpa);

    var h = try bootStubProfile();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const command_body = try std.fmt.allocPrint(
        gpa,
        "{{\"transport\":\"stdio\",\"command\":{f},\"args\":[]}}",
        .{std.json.fmt(binary, .{})},
    );
    defer gpa.free(command_body);

    const start = monotonicMs();
    var result = try postTest(&h, command_body);
    defer result.deinit();
    const elapsed_ms = monotonicMs() - start;

    if (!(try okOf(&result))) {
        dumpBody(&result);
        return error.TestUnexpectedResult;
    }
    const transport = try transportOf(&result);
    if (!std.mem.eql(u8, transport, "stdio")) {
        std.debug.print("expected transport=stdio, got \"{s}\"\n", .{transport});
        return error.TestUnexpectedResult;
    }
    const names = try toolNames(&result);
    defer freeNames(names);
    try expectNameSet(names, &.{ "print_hello", "print_name", "print_exit" }, "mcp-hello-world tools/list");

    // The whole probe must finish well inside the 10s timeout.
    if (elapsed_ms >= 10_000) {
        std.debug.print("probe took {d}ms (>10s timeout!)\n", .{elapsed_ms});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: stdio bad command
// ============================================================================

// A non-existent command binary returns `{ok: false, ...}` rather than
// hanging — proves the spawn-failed path is reachable from the probe.
test "mcp_test_stdio_bad_command_returns_spawn_failure" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootStubProfile();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const start = monotonicMs();
    var result = try postTest(&h,
        \\{"transport":"stdio","command":"/no/such/binary/should/exist/xyzzy","args":[]}
    );
    defer result.deinit();
    const elapsed_ms = monotonicMs() - start;

    if (try okOf(&result)) {
        dumpBody(&result);
        std.debug.print("expected the probe to FAIL for a missing command\n", .{});
        return error.TestUnexpectedResult;
    }
    const msg = try errorOf(&result);
    const lowered = msg;
    if (std.mem.indexOf(u8, lowered, "spawn") == null and std.mem.indexOf(u8, lowered, "child") == null) {
        // Case-insensitive on both sides: the message the backend emits
        // is "failed to spawn child process …".
        var matched = false;
        for ([_][]const u8{ "spawn", "child" }) |needle| {
            if (containsIgnoreCase(msg, needle)) matched = true;
        }
        if (!matched) {
            std.debug.print("error message should reference spawn/child, got \"{s}\"\n", .{msg});
            return error.TestUnexpectedResult;
        }
    }
    if (elapsed_ms >= 10_000) {
        std.debug.print("probe took {d}ms (>10s timeout!)\n", .{elapsed_ms});
        return error.TestUnexpectedResult;
    }
}

/// Case-insensitive `in`, for a message whose exact casing the test does
/// not pin.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ============================================================================
// Test 3: http unreachable — a closed port
// ============================================================================

// An HTTP URL with no server listening returns `{ok: false, …}`.
// Port 1 is used because the kernel refuses connections there — and it
// is never the reserved dev port 8081.
test "mcp_test_http_unreachable_returns_send_failure" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootStubProfile();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const start = monotonicMs();
    var result = try postTest(&h,
        \\{"transport":"http","url":"http://127.0.0.1:1/invalid"}
    );
    defer result.deinit();
    const elapsed_ms = monotonicMs() - start;

    if (try okOf(&result)) {
        dumpBody(&result);
        return error.TestUnexpectedResult;
    }
    // The message comes from the libcurl client ("Connection refused",
    // "Couldn't connect to server", …) — we only assert that SOMETHING
    // failed, and that it failed fast.
    const msg = try errorOf(&result);
    if (msg.len == 0) {
        dumpBody(&result);
        std.debug.print("expected a non-empty error, got none\n", .{});
        return error.TestUnexpectedResult;
    }
    if (elapsed_ms >= 30_000) {
        std.debug.print("probe took {d}ms (>30s timeout!)\n", .{elapsed_ms});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 4: invalid transport discriminator
// ============================================================================

// A transport other than `stdio` / `http` returns a readable error
// rather than a 500 — this guards the catch block's exhaustive switch.
test "mcp_test_invalid_transport_returns_clear_error" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootStubProfile();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var result = try postTest(&h,
        \\{"transport":"weird-thing","command":"doesn't-matter"}
    );
    defer result.deinit();

    if (try okOf(&result)) {
        dumpBody(&result);
        return error.TestUnexpectedResult;
    }
    const msg = try errorOf(&result);
    if (!containsIgnoreCase(msg, "transport")) {
        std.debug.print("error message should reference `transport`, got \"{s}\"\n", .{msg});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 5: stdio with no command
// ============================================================================

// stdio without `command` returns a clean error rather than a 500 or a
// spawn attempt with an empty argv.
test "mcp_test_missing_command_for_stdio_returns_clear_error" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootStubProfile();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var result = try postTest(&h,
        \\{"transport":"stdio","command":""}
    );
    defer result.deinit();

    if (try okOf(&result)) {
        dumpBody(&result);
        return error.TestUnexpectedResult;
    }
    const msg = try errorOf(&result);
    if (!containsIgnoreCase(msg, "command")) {
        std.debug.print("error message should reference `command`, got \"{s}\"\n", .{msg});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Regression: spawned MCP children must inherit the parent environment
// ============================================================================
const SHIM_SERVER =
    \\#!/bin/sh
    \\IFS= read -r l1
    \\printf '%s\n' '{"jsonrpc":"2.0","id":"1","result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"shim","version":"1.0"}}}'
    \\sleep 0.2
    \\IFS= read -r l2
    \\IFS= read -r l3
    \\printf '%s\n' '{"jsonrpc":"2.0","id":"2","result":{"tools":[{"name":"shim_tool","description":"env-inheritance regression guard"}]}}'
;

/// Unique name, NOT present in `/bin:/usr/bin`.
const SHIM_COMMAND = "mcp-test-env-shim-server";

test "mcp_test_stdio_child_inherits_parent_path" {
    if (builtin.os.tag == .windows) {
        // Python: "shim server requires /bin/sh, not available on Windows".
        return error.SkipZigTest;
    }
    // TODO(port): see the block comment above — needs
    // `Harness.BootOptions.extra_env` before the bare-name command below
    // can be exercised. Skipped rather than weakened.
    _ = SHIM_SERVER;
    _ = SHIM_COMMAND;
    return error.SkipZigTest;
}

// ============================================================================
// Test 6: diagnostic details on child death
// ============================================================================

// A child that exits immediately (no MCP protocol) produces a diagnostic
// `details` string containing the attempt count, per-attempt outcome codes,
// and the child's stderr.
test "mcp_test_stdio_diagnostic_on_child_death" {
    if (builtin.os.tag == .windows) {
        // Python: "false command not available on Windows".
        return error.SkipZigTest;
    }
    try harness.requirePabrikBin(io, gpa);
    var h = try bootStubProfile();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const start = monotonicMs();
    var result = try postTest(&h,
        \\{"transport":"stdio","command":"false","args":[]}
    );
    defer result.deinit();
    const elapsed_ms = monotonicMs() - start;

    if (try okOf(&result)) {
        dumpBody(&result);
        std.debug.print("expected the probe to FAIL for an immediate-exit child\n", .{});
        return error.TestUnexpectedResult;
    }

    // BOTH the write and the read leg can lose the race against a child that
    // is already dead: the pipe may close before the request goes out
    // (SendFailed) or after it lands but before the reply is read
    const msg = try errorOf(&result);
    const recv = "failed to receive response from MCP server";
    const send = "failed to send request to MCP server";
    if (!std.mem.eql(u8, msg, recv) and !std.mem.eql(u8, msg, send)) {
        dumpBody(&result);
        std.debug.print("unexpected error message: \"{s}\"\n", .{msg});
        return error.TestUnexpectedResult;
    }

    // The DIAGNOSTIC details should include the per-attempt trace so WHY
    // is visible in the CI log. Format:
    //   "<err>|attempts=N/M codes=[<3-char codes>...]|last_stderr=<...>"
    const details = detailsOf(&result);
    if (std.mem.indexOf(u8, details, "attempts=") == null) {
        std.debug.print("diagnostic missing the attempts count; details=\"{s}\"\n", .{details});
        return error.TestUnexpectedResult;
    }
    // The underlying error name must still be there (back-compat).
    const has_error_name = std.mem.indexOf(u8, details, "UnexpectedEof") != null or
        std.mem.indexOf(u8, details, "BrokenPipe") != null or
        std.mem.indexOf(u8, details, "SendFailed") != null;
    if (!has_error_name) {
        std.debug.print("diagnostic missing the underlying error name; details=\"{s}\"\n", .{details});
        return error.TestUnexpectedResult;
    }

    // The whole probe must finish inside the 20 × 10s budget (30s to be safe).
    if (elapsed_ms >= 30_000) {
        std.debug.print("probe took {d}ms (>30s budget!)\n", .{elapsed_ms});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 7: silent child with empty args returns Timeout, not a hang
// ============================================================================

/// Consumes every line the probe writes, never writes to stdout, and
/// only exits when stdin reaches EOF.
const SILENT_CHILD =
    \\#!/bin/sh
    \\i=0
    \\while [ "$i" -lt 1000 ]; do
    \\  IFS= read -r line || exit 0
    \\  i=$((i + 1))
    \\done
;

// A bare interpreter with no args stays silent → {ok:false} Timeout within
// ~10s per probe, and the backend stays alive across both probes.
test "mcp_test_stdio_empty_args_silent_child_returns_timeout" {
    if (builtin.os.tag == .windows) {
        // The shim needs /bin/sh. Python had no explicit guard here
        // because `sys.executable` always existed on Windows.
        return error.SkipZigTest;
    }
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const child = try writeExecutableScript(scratch, "silent-child.sh", SILENT_CHILD);
    defer gpa.free(child);

    var h = try bootStubProfile();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const body = try std.fmt.allocPrint(
        gpa,
        // The exact body the modal sends for an empty Arguments
        // textarea: `argsText "" → []`.
        "{{\"transport\":\"stdio\",\"command\":{f},\"args\":[]}}",
        .{std.json.fmt(child, .{})},
    );
    defer gpa.free(body);

    for (1..3) |probe_no| {
        const start = monotonicMs();
        var result = try postTest(&h, body);
        defer result.deinit();
        const elapsed_ms = monotonicMs() - start;

        if (try okOf(&result)) {
            dumpBody(&result);
            std.debug.print("probe {d}: expected failure, got ok=true\n", .{probe_no});
            return error.TestUnexpectedResult;
        }
        const msg = try errorOf(&result);
        if (!std.mem.eql(u8, msg, "MCP server did not respond within 10 seconds")) {
            dumpBody(&result);
            std.debug.print("probe {d}: unexpected error message: \"{s}\"\n", .{ probe_no, msg });
            return error.TestUnexpectedResult;
        }
        const details = detailsOf(&result);
        if (std.mem.indexOf(u8, details, "RecvTimeout") == null) {
            dumpBody(&result);
            std.debug.print("probe {d}: details should name RecvTimeout; got \"{s}\"\n", .{ probe_no, details });
            return error.TestUnexpectedResult;
        }
        // ~10s deadline + 200ms stderr poll + spawn overhead. A 30s
        // bound proves the deadline fired (pre-fix: infinite).
        if (elapsed_ms >= 30_000) {
            std.debug.print("probe {d} took {d}ms (>30s — the deadline regressed!)\n", .{ probe_no, elapsed_ms });
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 8: http SSE `event:`-prefixed body parses (context7 shape)
// ============================================================================
test "mcp_test_http_sse_event_prefix_parses_tools" {
    try harness.requirePabrikBin(io, gpa);

    var stub: SseStub = undefined;
    try stub.start(SSE_PAYLOAD);
    defer stub.deinit();

    var h = try bootStubProfile();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/mcp", .{stub.port});
    defer gpa.free(url);
    const body = try std.fmt.allocPrint(gpa, "{{\"transport\":\"http\",\"url\":{f}}}", .{std.json.fmt(url, .{})});
    defer gpa.free(body);

    var result = try postTest(&h, body);
    defer result.deinit();

    if (!(try okOf(&result))) {
        dumpBody(&result);
        return error.TestUnexpectedResult;
    }
    const names = try toolNames(&result);
    defer freeNames(names);
    try expectNameSet(names, &.{ "resolve-library-id", "query-docs" }, "SSE tools/list");

    const head = stub.head() orelse {
        std.debug.print("the SSE stub never received a request\n", .{});
        return error.TestUnexpectedResult;
    };
    const version = headerValue(head, "MCP-Protocol-Version") orelse {
        std.debug.print("probe did not send the MCP-Protocol-Version header\n", .{});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, version, "2025-11-25")) {
        std.debug.print("MCP-Protocol-Version = \"{s}\", expected \"2025-11-25\"\n", .{version});
        return error.TestUnexpectedResult;
    }
    const method = headerValue(head, "Mcp-Method") orelse {
        std.debug.print("probe did not send the Mcp-Method header\n", .{});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, method, "tools/list")) {
        std.debug.print("Mcp-Method = \"{s}\", expected \"tools/list\"\n", .{method});
        return error.TestUnexpectedResult;
    }
    // The `_meta` envelope 400s against a 2026-07-28 server, so the
    // probe must NOT send one.
    const sent_body = stub.bodyOf() orelse "";
    if (std.mem.indexOf(u8, sent_body, "_meta") != null) {
        std.debug.print("probe body must NOT carry the _meta envelope; got \"{s}\"\n", .{sent_body});
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = bootStubProfile;
    _ = requireMcpBin;
    _ = postTest;
    _ = rootObject;
    _ = okOf;
    _ = errorOf;
    _ = detailsOf;
    _ = transportOf;
    _ = toolNames;
    _ = freeNames;
    _ = expectNameSet;
    _ = dumpBody;
    _ = monotonicMs;
    _ = makeExecutable;
    _ = writeExecutableScript;
    _ = containsIgnoreCase;
    _ = headerValue;
    _ = contentLength;
    _ = serve;
    _ = handleStubRequest;
    _ = SseStub.start;
    _ = SseStub.deinit;
    _ = SseStub.head;
    _ = SseStub.bodyOf;
    _ = Harness.boot;
}

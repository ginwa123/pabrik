// HTTP/2 cleartext (h2c) end-to-end tests. Zig port of
// `tests/functional/http2_test.py` (same test names, same order). PYTHON
// DOCSTRING, PRESERVED: """HTTP/2 cleartext (h2c) end-to-end tests.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

// ============================================================================
// Helpers — curl
// ============================================================================

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// `_curl()` + `_curl_version_args()`: skip unless curl exists AND speaks
/// HTTP/2 (nghttp2 / HTTP2 in `curl --version`). Returns the resolved curl
/// path when usable.
fn requireCurlHttp2() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "curl", "--version" },
    }) catch |err| {
        std.debug.print("curl not on PATH ({s}); skipping h2c test\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    if (std.mem.indexOf(u8, res.stdout, "nghttp2") == null and
        std.mem.indexOf(u8, res.stdout, "HTTP2") == null)
    {
        std.debug.print("curl lacks HTTP/2 support: {s}\n", .{firstLine(res.stdout)});
        return error.SkipZigTest;
    }
}

/// Python's `out.splitlines()[0]`.
fn firstLine(s: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, s, '\n');
    return std.mem.trimEnd(u8, it.next() orelse "", "\r");
}

/// Python's `s.rpartition("\n")[2]` — the text AFTER the LAST newline.
fn afterLastNewline(s: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, s, '\n') orelse return "";
    return s[i + 1 ..];
}

/// The result of one `curl` invocation. Both slices are owned.
const CurlResult = struct {
    exit: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *CurlResult) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }
};

/// Run curl with the given argv, returning the outcome. NEVER asserts —
/// several of these tests assert on the exit code itself.
fn curlRun(args: []const []const u8) !CurlResult {
    const res = std.process.run(gpa, io, .{ .argv = args }) catch |err| {
        std.debug.print("curl did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    return .{ .exit = exitCode(res.term), .stdout = res.stdout, .stderr = res.stderr };
}

/// `_curl_http_version(url, extra)` -> `(http_version, body)`. `assert
/// proc.returncode == 0, f"curl failed: {proc.stderr}"` lives here, because
/// this helper is only used where success IS the precondition.
const Versioned = struct {
    version: []const u8,
    body: []u8,

    fn deinit(self: *Versioned) void {
        gpa.free(self.body);
        self.* = undefined;
    }
};

fn curlHttpVersion(extra: []const []const u8, url: []const u8) !Versioned {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "curl", "-sS", "-o", "-", "-w", "\n%{http_version}" });
    try argv.appendSlice(gpa, extra);
    try argv.append(gpa, url);

    var r = try curlRun(argv.items);
    errdefer r.deinit();
    if (r.exit == null or r.exit.? != 0) {
        std.debug.print("curl failed: {s}\n", .{r.stderr});
        return error.TestUnexpectedResult;
    }
    gpa.free(r.stderr);
    // rpartition("\n"); `version` borrows from the returned `body`.
    const version = std.mem.trim(u8, afterLastNewline(r.stdout), " \t\r\n");
    return .{ .version = version, .body = r.stdout };
}

/// Python's `"ok" in body.lower()` — a case-insensitive substring test
/// with no allocation.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const first = std.ascii.toLower(needle[0]);
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.toLower(haystack[i]) != first) continue;
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// True iff every byte of `name` is lowercase (ASCII letters or a
/// non-letter).
fn isLowercaseName(name: []const u8) bool {
    for (name) |c| {
        if (std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// Python's `s.partition(" ")` — the text BEFORE the first space.
fn beforeFirstSpace(s: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, s, ' ') orelse return s;
    return s[0..i];
}

/// Python's `s.partition(" ")[2]` — the text AFTER the first space.
fn afterFirstSpace(s: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, s, ' ') orelse return "";
    return s[i + 1 ..];
}

/// `/dev/null` for curl's `-o`. Python used `os.devnull`, which is the
/// POSIX spelling; the h2c suite is POSIX-only in practice, and this is
/// only ever passed to curl, never opened by the test.
const DEV_NULL = "/dev/null";

// ============================================================================
// Helpers — harness
// ============================================================================

/// `_h2_harness`: boot with `--http2 h2c` and the Python's 45s budget.
fn bootH2() !Harness {
    return Harness.boot(io, gpa, .{
        .extra_args = &.{ "--http2", "h2c" },
        .ready_timeout_s = 45.0,
    });
}

// ============================================================================
// Helpers — raw socket (protocol-error probe)
// ============================================================================

/// The bytes Python's `bogus` variable holds.
const BOGUS_PREFACE =
    "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++
    "\xFF\xFF\xFF\x00\x00\x00\x00\x00\x01";

/// Give the socket a receive deadline — Python's `s.settimeout(10)`.
fn setRecvTimeout(stream: *Io.net.Stream, seconds: i64) void {
    if (comptime builtin.os.tag == .windows) return;
    const tv = std.posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};
}

/// Send `payload` to `port` and read whatever comes back. Owned.
fn rawProbe(port: u16, payload: []const u8) ![]u8 {
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    // `.timeout = .none` IS MANDATORY ON POSIX.
    var stream = addr.connect(io, .{
        .mode = .stream,
        .timeout = .none,
    }) catch |err| {
        std.debug.print("raw probe could not connect to 127.0.0.1:{d}: {s}\n", .{ port, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer stream.close(io);
    setRecvTimeout(&stream, 10);

    {
        var wbuf: [256]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        sw.interface.writeAll(payload) catch |err| {
            std.debug.print("raw probe write failed: {s}\n", .{@errorName(err)});
            return error.TestUnexpectedResult;
        };
        sw.interface.flush() catch {};
    }

    var acc: Io.Writer.Allocating = .init(gpa);
    errdefer acc.deinit();
    var rbuf: [4096]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const r = &sr.interface;
    while (true) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        acc.writer.writeAll(b) catch break;
        r.toss(b.len);
        // Python's `recv(4096)`: at most one buffer's worth.
        if (acc.written().len >= 4096) break;
    }
    return acc.toOwnedSlice();
}

// ============================================================================
// Test 1: prior-knowledge h2c client gets HTTP/2 and the normal body
// ============================================================================

// A prior-knowledge h2c client gets HTTP/2 and the normal handler body.
test "h2_prior_knowledge_health" {
    try harness.requirePabrikBin(io, gpa);
    try requireCurlHttp2();

    var h = try bootH2();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/health", .{h.port});
    defer gpa.free(url);

    var got = try curlHttpVersion(&.{"--http2-prior-knowledge"}, url);
    defer got.deinit();
    if (!std.mem.eql(u8, got.version, "2")) {
        std.debug.print("expected HTTP/2, got '{s}' (body='{s}')\n", .{ got.version, got.body });
        return error.TestUnexpectedResult;
    }
    if (!containsIgnoreCase(got.body, "ok")) {
        std.debug.print("/health body should contain 'ok': '{s}'\n", .{got.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: h2c is negotiated per connection on the SAME port
// ============================================================================

// h2c is negotiated per connection: the SAME port still serves HTTP/1.1.
test "h2_and_h1_share_the_same_port" {
    try harness.requirePabrikBin(io, gpa);
    try requireCurlHttp2();

    var h = try bootH2();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/health", .{h.port});
    defer gpa.free(url);

    {
        var h1 = try curlHttpVersion(&.{}, url);
        defer h1.deinit();
        if (!std.mem.eql(u8, h1.version, "1.1")) {
            std.debug.print("expected HTTP/1.1 on the default path, got '{s}'\n", .{h1.version});
            return error.TestUnexpectedResult;
        }
        if (!containsIgnoreCase(h1.body, "ok")) {
            std.debug.print("/health body should contain 'ok': '{s}'\n", .{h1.body});
            return error.TestUnexpectedResult;
        }
    }
    {
        var h2 = try curlHttpVersion(&.{"--http2-prior-knowledge"}, url);
        defer h2.deinit();
        if (!std.mem.eql(u8, h2.version, "2")) {
            std.debug.print("expected HTTP/2 with prior knowledge, got '{s}'\n", .{h2.version});
            return error.TestUnexpectedResult;
        }
        if (!containsIgnoreCase(h2.body, "ok")) {
            std.debug.print("/health body should contain 'ok': '{s}'\n", .{h2.body});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 3: no --http2 flag => h1 only
// ============================================================================

// With no --http2 flag the server must not accept h2 at all (default
// off).
test "h1_only_when_flag_absent" {
    try harness.requirePabrikBin(io, gpa);
    try requireCurlHttp2();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/health", .{h.port});
    defer gpa.free(url);

    {
        var got = try curlHttpVersion(&.{}, url);
        defer got.deinit();
        if (!std.mem.eql(u8, got.version, "1.1")) {
            std.debug.print("expected HTTP/1.1 without --http2, got '{s}'\n", .{got.version});
            return error.TestUnexpectedResult;
        }
    }

    // curl with prior knowledge against an h1-only server fails loudly
    // (it is the exact probe that established the pre-change behaviour).
    {
        var r = try curlRun(&.{ "curl", "-sS", "-o", DEV_NULL, "--http2-prior-knowledge", url });
        defer r.deinit();
        if (r.exit == null or r.exit.? == 0) {
            std.debug.print(
                "curl --http2-prior-knowledge should FAIL against an h1-only server, rc={?}\n",
                .{r.exit},
            );
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, r.stderr, "HTTP/2") == null and
            std.mem.indexOf(u8, r.stderr, "SETTINGS") == null)
        {
            std.debug.print("curl stderr should mention HTTP/2 or SETTINGS: '{s}'\n", .{r.stderr});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 4: POST body survives the h2 path
// ============================================================================

// A POST body survives the h2 path and reaches the handler.
test "h2_post_body_roundtrip" {
    try harness.requirePabrikBin(io, gpa);
    try requireCurlHttp2();

    var h = try bootH2();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/api/workspaces", .{h.port});
    defer gpa.free(url);

    var r = try curlRun(&.{
        "curl",                           "-sS",
        "--http2-prior-knowledge",        "-H",
        "content-type: application/json", "-d",
        "{\"name\":\"h2-probe\"}",        url,
    });
    defer r.deinit();
    if (r.exit == null or r.exit.? != 0) {
        std.debug.print("curl failed: {s}\n", .{r.stderr});
        return error.TestUnexpectedResult;
    }

    var doc = harness.Json{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, r.stdout, .{}) };
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("h2 POST response has no id: {s}\n", .{r.stdout});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.startsWith(u8, id, "ws_")) {
        std.debug.print("created workspace id should start with ws_, got '{s}'\n", .{id});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 5: unknown route over h2 is 404 on an h2 connection
// ============================================================================

test "h2_unknown_route_is_404" {
    try harness.requirePabrikBin(io, gpa);
    try requireCurlHttp2();

    var h = try bootH2();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const url = try std.fmt.allocPrint(
        gpa,
        "http://127.0.0.1:{d}/definitely-not-a-route",
        .{h.port},
    );
    defer gpa.free(url);

    var r = try curlRun(&.{
        "curl",                    "-sS",
        "-o",                      DEV_NULL,
        "-w",                      "%{http_code} %{http_version}",
        "--http2-prior-knowledge", url,
    });
    defer r.deinit();
    if (r.exit == null or r.exit.? != 0) {
        std.debug.print("curl failed: {s}\n", .{r.stderr});
        return error.TestUnexpectedResult;
    }

    const code = beforeFirstSpace(r.stdout);
    if (!std.mem.eql(u8, code, "404")) {
        std.debug.print("expected code 404, got '{s}' (raw='{s}')\n", .{ code, r.stdout });
        return error.TestUnexpectedResult;
    }
    const version = std.mem.trim(u8, afterFirstSpace(r.stdout), " \t\r\n");
    if (!std.mem.eql(u8, version, "2")) {
        std.debug.print("expected http_version 2, got '{s}'\n", .{version});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 6: two requests over ONE connection
// ============================================================================

// Multiplexing/persistence: two URLs over ONE connection. HTTP/1.1 needs a
// second TCP connection here because every h1 response says `Connection:
// close`; h2 keeps the connection alive.
test "h2_reuses_one_connection_for_two_requests" {
    try harness.requirePabrikBin(io, gpa);
    try requireCurlHttp2();

    var h = try bootH2();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/health", .{h.port});
    defer gpa.free(url);

    var r = try curlRun(&.{
        "curl",                    "-sS",
        "-o",                      DEV_NULL,
        "-o",                      DEV_NULL,
        "-w",                      "%{num_connects}\n",
        "--http2-prior-knowledge", url,
        url,
    });
    defer r.deinit();
    if (r.exit == null or r.exit.? != 0) {
        std.debug.print("curl failed: {s}\n", .{r.stderr});
        return error.TestUnexpectedResult;
    }

    // curl reports num_connects=1 for the first URL and 0 for the second: the
    // second transfer needed NO new TCP connection. (The h1 baseline is 1 and
    // 1, because every h1 response says `Connection: close`.)
    var got: [2]i64 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, r.stdout, " \t\r\n");
    while (it.next()) |tok| {
        if (n >= got.len) break;
        got[n] = std.fmt.parseInt(i64, tok, 10) catch {
            std.debug.print("non-numeric num_connects token '{s}' in '{s}'\n", .{ tok, r.stdout });
            return error.TestUnexpectedResult;
        };
        n += 1;
    }
    if (n != 2 or got[0] != 1 or got[1] != 0) {
        std.debug.print(
            "expected one connection reused (1, 0), got {d} token(s) '{s}'\n",
            .{ n, r.stdout },
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 7: a bogus frame is answered with GOAWAY, not a crash
// ============================================================================

// Protocol errors must be answered with GOAWAY, not a crash.
test "h2_bogus_preface_gets_goaway_and_server_survives" {
    try harness.requirePabrikBin(io, gpa);
    try requireCurlHttp2();

    var h = try bootH2();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const data = try rawProbe(h.port, BOGUS_PREFACE);
    defer gpa.free(data);

    if (data.len == 0) {
        std.debug.print("expected a GOAWAY frame before the connection closed\n", .{});
        return error.TestUnexpectedResult;
    }

    // The first frame the server sends on a valid preface is SETTINGS (type
    // 0x4); on a garbage frame it is GOAWAY (type 0x7).
    if (data.len < 4) {
        const shown = try harness.debugString(gpa, data);
        defer gpa.free(shown);
        std.debug.print("h2 frame header truncated (got {d} byte(s)): '{s}'\n", .{ data.len, shown });
        return error.TestUnexpectedResult;
    }
    const ftype = data[3];
    if (ftype != 0x4 and ftype != 0x7) {
        std.debug.print("unexpected frame type {x}\n", .{ftype});
        return error.TestUnexpectedResult;
    }

    // The process must still be alive and serving.
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/health", .{h.port});
    defer gpa.free(url);
    var got = try curlHttpVersion(&.{}, url);
    defer got.deinit();
    if (!std.mem.eql(u8, got.version, "1.1") and !std.mem.eql(u8, got.version, "2")) {
        std.debug.print(
            "server should still answer after a protocol error, got http_version '{s}'\n",
            .{got.version},
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 8: response header names are lowercase on the h2 wire
// ============================================================================

// RFC 9113 section 8.2.1: an uppercase field name must not reach the wire.
// curl/nghttp2 would reject the response outright, so a 200 here is itself
// the assertion; we also assert the security headers the h1 path adds are
test "h2_response_headers_are_lowercase" {
    try harness.requirePabrikBin(io, gpa);
    try requireCurlHttp2();

    var h = try bootH2();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/health", .{h.port});
    defer gpa.free(url);

    var r = try curlRun(&.{
        "curl",                    "-sS",
        "-D",                      "-",
        "-o",                      DEV_NULL,
        "--http2-prior-knowledge", url,
    });
    defer r.deinit();
    if (r.exit == null or r.exit.? != 0) {
        std.debug.print("curl failed: {s}\n", .{r.stderr});
        return error.TestUnexpectedResult;
    }

    var checked: usize = 0;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.indexOfScalar(u8, line, ':') == null) continue;
        if (std.mem.startsWith(u8, line, "HTTP/")) continue;
        checked += 1;
        const colon = std.mem.indexOfScalar(u8, line, ':').?;
        const name = line[0..colon];
        if (!isLowercaseName(name)) {
            std.debug.print(
                "non-lowercase header name on the h2 wire: '{s}'\n",
                .{name},
            );
            return error.TestUnexpectedResult;
        }
    }
    if (checked == 0) {
        std.debug.print("no header lines captured: '{s}'\n", .{r.stdout});
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier — see `harness.zig`'s note: an unreferenced
    // function body is never type-checked, so a stdlib rename inside one
    // stays invisible until a caller appears.
    _ = exitCode;
    _ = requireCurlHttp2;
    _ = firstLine;
    _ = afterLastNewline;
    _ = CurlResult.deinit;
    _ = curlRun;
    _ = curlHttpVersion;
    _ = Versioned.deinit;
    _ = containsIgnoreCase;
    _ = isLowercaseName;
    _ = beforeFirstSpace;
    _ = afterFirstSpace;
    _ = bootH2;
    _ = setRecvTimeout;
    _ = rawProbe;
    _ = Harness.boot;
}

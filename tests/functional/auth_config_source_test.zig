// Functional test: WHICH config does a chat turn run on when `--auth` is on?
// Zig port of `tests/functional/auth_config_source_test.py` (same order; test
// names drop the `test_` prefix).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

const PROFILE_NAME = "stub";
const USER_MODEL = "user-config-model";
const USER_KEY = "sk-user-config-key";
const GLOBAL_ENDPOINT = "127.0.0.1:1";

const MAX_HEAD_BYTES = 1 << 18;

// SSE body the stub answers with. The model is baked in because the
// payload is a `const` — the test asserts the REQUEST carried USER_MODEL,
// not the reply.
const SSE_OK =
    "data: {\"id\":\"chatcmpl-authcfg\",\"object\":\"chat.completion.chunk\"," ++
    "\"model\":\"user-config-model\",\"choices\":[{\"index\":0," ++
    "\"delta\":{\"role\":\"assistant\",\"content\":\"hello from the per-user stub\"}," ++
    "\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-authcfg\",\"object\":\"chat.completion.chunk\"," ++
    "\"model\":\"user-config-model\",\"choices\":[{\"index\":0,\"delta\":{}," ++
    "\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

// ============================================================================
// Stub upstream
// ============================================================================

const Recorded = struct {
    head: []u8,
    body: []u8,

    fn deinit(self: *Recorded) void {
        gpa.free(self.head);
        gpa.free(self.body);
    }
};

const Stub = struct {
    io: Io,
    port: u16,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    reqs: std.ArrayList(Recorded) = .empty,

    fn start(stub: *Stub) !void {
        stub.* = .{
            .io = io,
            .port = 0,
            .server = undefined,
            .thread = undefined,
        };
        stub.port = try harness.findFreePortRandom(gpa);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
        stub.server = try addr.listen(io, .{ .reuse_address = true });
        errdefer stub.server.deinit(io);
        stub.thread = try std.Thread.spawn(.{}, serve, .{stub});
    }

    fn deinit(self: *Stub) void {
        self.stop.store(true, .release);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (addr.connect(self.io, .{ .mode = .stream })) |conn| {
            var c = conn;
            c.close(self.io);
        } else |_| {}
        self.thread.join();
        self.server.deinit(self.io);
        for (self.reqs.items) |*r| r.deinit();
        self.reqs.deinit(gpa);
    }

    fn count(self: *Stub) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.reqs.items.len;
    }

    fn snapshot(self: *Stub) !std.ArrayList(Recorded) {
        var out: std.ArrayList(Recorded) = .empty;
        errdefer {
            for (out.items) |*r| r.deinit();
            out.deinit(gpa);
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.reqs.items) |r| {
            try out.append(gpa, .{
                .head = try gpa.dupe(u8, r.head),
                .body = try gpa.dupe(u8, r.body),
            });
        }
        return out;
    }
};

fn serve(stub: *Stub) void {
    while (!stub.stop.load(.acquire)) {
        var stream = stub.server.accept(stub.io) catch break;
        defer stream.close(stub.io);
        if (stub.stop.load(.acquire)) break;
        handleRequest(stub, stream) catch {};
    }
}

fn handleRequest(stub: *Stub, stream: Io.net.Stream) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(stub.io, &rbuf);
    const r = &sr.interface;

    var head_acc: Io.Writer.Allocating = .init(gpa);
    defer head_acc.deinit();
    var head_len: usize = 0;
    while (head_len == 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        head_acc.writer.writeAll(b) catch break;
        r.toss(b.len);
        if (head_acc.written().len > MAX_HEAD_BYTES) break;
        if (std.mem.indexOf(u8, head_acc.written(), "\r\n\r\n")) |i| head_len = i + 4;
    }
    if (head_len == 0) return;
    const head = head_acc.written()[0..head_len];

    var body_acc: Io.Writer.Allocating = .init(gpa);
    defer body_acc.deinit();
    var remaining = contentLength(head);
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

    stub.mutex.lockUncancelable(stub.io);
    defer stub.mutex.unlock(stub.io);
    try stub.reqs.append(gpa, .{
        .head = try gpa.dupe(u8, head),
        .body = try gpa.dupe(u8, body_acc.written()),
    });

    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
        .{ SSE_OK.len, SSE_OK },
    );
    defer gpa.free(response);

    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(stub.io, &wbuf);
    try sw.interface.writeAll(response);
    try sw.interface.flush();
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // request line
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn contentLength(head: []const u8) usize {
    const v = headerValue(head, "content-length") orelse return 0;
    return std.fmt.parseInt(usize, v, 10) catch 0;
}

// ============================================================================
// Auth-mode wire helpers (mirrors auth_test.zig)
// ============================================================================

fn rawHttp(
    h: *Harness,
    method: harness.HttpMethod,
    path: []const u8,
    body: ?[]const u8,
    cookie: ?[]const u8,
) !harness.Response {
    var extra: [1]harness.Header = undefined;
    const n: usize = if (cookie) |c| blk: {
        extra[0] = .{ .name = "Cookie", .value = c };
        break :blk 1;
    } else 0;
    return h.http(io, method, path, .{
        .json_body = body,
        .extra_headers = extra[0..n],
        .assert_status = false,
    });
}

fn createAdmin(home: []const u8, email: []const u8, password: []const u8) !void {
    var r = try harness.runPabrikCommand(io, gpa, home, &.{
        "create-admin", "--email", email, "--password", password,
    }, 30_000);
    defer r.deinit(gpa);
    if (r.exit_code == null or r.exit_code.? != 0) {
        std.debug.print("create-admin failed (rc={?}): {s}\n", .{ r.exit_code, r.stderr });
        return error.TestUnexpectedResult;
    }
}

/// Log in and return the owned `pabrik_session=<token>` cookie header value.
fn login(h: *Harness, email: []const u8, password: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"email\":\"{s}\",\"password\":\"{s}\"}}",
        .{ email, password },
    );
    defer gpa.free(body);
    var r = try rawHttp(h, .POST, "/api/auth/login", body, null);
    defer r.deinit();
    if (r.status != 200) {
        std.debug.print("login failed: {d} {s}\n", .{ r.status, r.body });
        return error.TestUnexpectedResult;
    }
    const set_cookie = r.header("Set-Cookie") orelse {
        std.debug.print("login returned no Set-Cookie\n", .{});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, set_cookie, "pabrik_session=") == null) {
        std.debug.print("Set-Cookie has no session: {s}\n", .{set_cookie});
        return error.TestUnexpectedResult;
    }
    var attrs = std.mem.splitSequence(u8, set_cookie, ";");
    const first = attrs.next() orelse return error.TestUnexpectedResult;
    const token = std.mem.trim(
        u8,
        harness.afterFirst(first, "pabrik_session=") orelse return error.TestUnexpectedResult,
        " \t\r\n",
    );
    return std.fmt.allocPrint(gpa, "pabrik_session={s}", .{token});
}

// ============================================================================
// Tests
// ============================================================================

// A `--auth` chat turn must call the profile saved in `users.config_json`.
test "auth_chat_turn_runs_on_the_users_config_not_config_json" {
    try harness.requirePabrikBin(io, gpa);

    var stub: Stub = undefined;
    try stub.start();
    defer stub.deinit();

    var h = try Harness.boot(io, gpa, .{
        .extra_args = &.{"--auth"},
        .stub_llm_profile = true,
    });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "admin@example.com", "supersecret123");
    const cookie = try login(&h, "admin@example.com", "supersecret123");
    defer gpa.free(cookie);

    const stub_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1/chat/completions", .{stub.port});
    defer gpa.free(stub_url);

    // 1. The user saves their profile through the real Settings wire.
    {
        const put_body = try std.fmt.allocPrint(
            gpa,
            "{{\"profiles\":{{\"{s}\":{{\"model\":\"{s}\",\"base_url\":\"{s}\"," ++
                "\"api_key\":\"{s}\",\"url_style\":\"openai\",\"thinking\":\"auto\"," ++
                "\"temperature\":\"auto\"}}}},\"active_profile\":\"{s}\"}}",
            .{ PROFILE_NAME, USER_MODEL, stub_url, USER_KEY, PROFILE_NAME },
        );
        defer gpa.free(put_body);
        var r = try rawHttp(&h, .PUT, "/api/config/pabrik", put_body, cookie);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print("PUT /api/config/pabrik failed: {d} {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }

    // Positive control: the SAVE half already works per-user.
    {
        var r = try rawHttp(&h, .GET, "/api/config/pabrik", null, cookie);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print("GET /api/config/pabrik failed: {d} {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
        var doc = try r.json();
        defer doc.deinit();
        const profiles = doc.object("profiles") orelse return error.TestUnexpectedResult;
        const entry = profiles.get(PROFILE_NAME) orelse {
            std.debug.print("saved config has no profile {s}\n", .{PROFILE_NAME});
            return error.TestUnexpectedResult;
        };
        const base = switch (entry) {
            .object => |o| switch (o.get("base_url") orelse return error.TestUnexpectedResult) {
                .string => |s| s,
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqualStrings(stub_url, base);
    }

    // 2. Send the exact sendChatMessage wire body the chatview sends.
    {
        const sid = try std.fmt.allocPrint(gpa, "sess_auth_cfg_{d}", .{std.Io.Timestamp.now(io, .awake).toMilliseconds()});
        defer gpa.free(sid);
        const post_body = try std.fmt.allocPrint(
            gpa,
            "{{\"session_id\":\"{s}\",\"queue_message\":\"say hi\",\"cwd_session\":\"\"," ++
                "\"allowed_tools\":\"all\",\"image_urls\":\"\"," ++
                "\"selected_profile_model\":\"{s}\",\"is_auto_retry_until_stop\":\"\"}}",
            .{ sid, PROFILE_NAME },
        );
        defer gpa.free(post_body);
        const cookie_hdr = [1]harness.Header{.{ .name = "Cookie", .value = cookie }};
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = post_body,
            .extra_headers = &cookie_hdr,
            .expect = &.{ 200, 201, 500 },
            .timeout_s = 30.0,
        });
        defer r.deinit();
    }

    // 3. Poll for the turn's dispatch. The stub can only be hit if the
    //    per-user profile won.
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 25_000;
    while (stub.count() == 0 and std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        std.Io.sleep(io, .fromMilliseconds(250), .awake) catch {};
    }

    const log_tail = try h.tailLog(io, gpa, 2000);
    defer gpa.free(log_tail);
    const stream_at = std.mem.indexOf(u8, log_tail, "[STREAM START] model=");
    if (stream_at == null) {
        const tail = if (log_tail.len > 4000) log_tail[log_tail.len - 4000 ..] else log_tail;
        std.debug.print("the turn never reached a streaming LLM call:\n{s}\n", .{tail});
        return error.TestUnexpectedResult;
    }

    var seen = try stub.snapshot();
    defer {
        for (seen.items) |*rec| rec.deinit();
        seen.deinit(gpa);
    }
    if (seen.items.len == 0) {
        const tail = if (log_tail.len > 4000) log_tail[log_tail.len - 4000 ..] else log_tail;
        if (std.mem.indexOf(u8, log_tail, GLOBAL_ENDPOINT) == null) {
            std.debug.print("turn dispatched but endpoint is neither stub nor {s}:\n{s}\n", .{ GLOBAL_ENDPOINT, tail });
            return error.TestUnexpectedResult;
        }
        std.debug.print(
            "chat turn went to config.json's endpoint {s}; per-user stub got nothing:\n{s}\n",
            .{ GLOBAL_ENDPOINT, tail },
        );
        return error.TestUnexpectedResult;
    }

    for (seen.items, 0..) |rec, i| {
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, rec.body, .{}) catch {
            std.debug.print("stub request {d}: body is not JSON\n", .{i});
            return error.TestUnexpectedResult;
        };
        defer parsed.deinit();
        const model = switch (parsed.value) {
            .object => |o| switch (o.get("model") orelse {
                std.debug.print("stub request {d}: no model\n", .{i});
                return error.TestUnexpectedResult;
            }) {
                .string => |s| s,
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqualStrings(USER_MODEL, model);
        const auth = headerValue(rec.head, "authorization") orelse "";
        if (std.mem.indexOf(u8, auth, USER_KEY) == null) {
            std.debug.print("stub request {d}: wire api_key not from user config: {s}\n", .{ i, rec.head });
            return error.TestUnexpectedResult;
        }
    }
}

// The request-scoped half: `web_launch_enabled` is per-user too.
test "auth_web_status_reports_the_users_web_launch_flag" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{
        .extra_args = &.{"--auth"},
        .stub_llm_profile = true,
    });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "admin@example.com", "supersecret123");
    const cookie = try login(&h, "admin@example.com", "supersecret123");
    defer gpa.free(cookie);

    // Positive control: before the user saves anything the flag is off.
    {
        var r = try rawHttp(&h, .GET, "/api/web/status", null, cookie);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print("GET /api/web/status failed: {d} {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
        var doc = try r.json();
        defer doc.deinit();
        if (doc.boolean("enabled") != false) {
            std.debug.print("flag should start off: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    // Turn it on in Settings — auth mode persists to users.config_json.
    {
        const put_body = try std.fmt.allocPrint(
            gpa,
            "{{\"profiles\":{{\"{s}\":{{\"model\":\"{s}\"," ++
                "\"base_url\":\"http://127.0.0.1:1\",\"api_key\":\"{s}\"," ++
                "\"url_style\":\"openai\"}}}},\"active_profile\":\"{s}\"," ++
                "\"web_launch_enabled\":true}}",
            .{ PROFILE_NAME, USER_MODEL, USER_KEY, PROFILE_NAME },
        );
        defer gpa.free(put_body);
        var r = try rawHttp(&h, .PUT, "/api/config/pabrik", put_body, cookie);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print("PUT /api/config/pabrik failed: {d} {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
        var doc = try r.json();
        defer doc.deinit();
        const msg = doc.str("error") orelse "";
        if (!std.mem.eql(u8, msg, "Config saved successfully")) {
            std.debug.print("settings PUT did not report success: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    {
        var r = try rawHttp(&h, .GET, "/api/web/status", null, cookie);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print("GET /api/web/status failed: {d} {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
        var doc = try r.json();
        defer doc.deinit();
        if (doc.boolean("enabled") != true) {
            std.debug.print("web status must report the caller's flag: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
}

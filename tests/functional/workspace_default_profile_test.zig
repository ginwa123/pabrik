//! Functional test: a chat's DEFAULT model is the ACTIVE PROFILE OF ITS
//! WORKSPACE (Settings -> Workspace -> "Set active"), not the user-level one.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

const USER_DEFAULT = "user-default";
const WS_DEFAULT = "ws-default";
const EXPLICIT = "explicit";

const USER_DEFAULT_MODEL = "user-level-default-model";
const WS_DEFAULT_MODEL = "workspace-active-model";
const EXPLICIT_MODEL = "explicit-pick-model";
const USER_KEY = "sk-user-level-key-not-real";

/// Port 1 is never answered, so a turn dispatched to the user-level default
/// cannot produce a stub hit. That is what makes "the stub recorded nothing"
/// a usable red signal instead of a timing artefact.
const DEAD_ENDPOINT = "http://127.0.0.1:1";

const MAX_HEAD_BYTES = 1 << 18;

// The reply is a `const`, so its `model` is baked in; every assertion is on the
// REQUEST the stub recorded, never on this body.
const SSE_OK =
    "data: {\"id\":\"chatcmpl-wsdefault\",\"object\":\"chat.completion.chunk\"," ++
    "\"model\":\"stub-reply\",\"choices\":[{\"index\":0," ++
    "\"delta\":{\"role\":\"assistant\",\"content\":\"hello from the stub\"}," ++
    "\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-wsdefault\",\"object\":\"chat.completion.chunk\"," ++
    "\"model\":\"stub-reply\",\"choices\":[{\"index\":0,\"delta\":{}," ++
    "\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

// ============================================================================
// Stub upstream (same shape as kanban_task_auth_config_test.zig)
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

/// The `model` field of a recorded request body.
fn recordedModel(body: []const u8) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get("model") orelse return null;
    return switch (v) {
        .string => |s| gpa.dupe(u8, s) catch null,
        else => null,
    };
}

// ============================================================================
// Auth-mode wire helpers (mirrors kanban_task_auth_config_test.zig)
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

fn authed(
    h: *Harness,
    method: harness.HttpMethod,
    path: []const u8,
    body: ?[]const u8,
    cookie: []const u8,
    expect: []const u16,
) !harness.Response {
    const hdr = [1]harness.Header{.{ .name = "Cookie", .value = cookie }};
    return h.http(io, method, path, .{
        .json_body = body,
        .extra_headers = &hdr,
        .expect = expect,
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
    var attrs = std.mem.splitSequence(u8, set_cookie, ";");
    const first = attrs.next() orelse return error.TestUnexpectedResult;
    const token = std.mem.trim(
        u8,
        harness.afterFirst(first, "pabrik_session=") orelse return error.TestUnexpectedResult,
        " \t\r\n",
    );
    return std.fmt.allocPrint(gpa, "pabrik_session={s}", .{token});
}

/// `GET /api/llm/session/:id` -> `selected_profile_model` (owned).
fn sessionProfile(h: *Harness, cookie: []const u8, session_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);
    var r = try authed(h, .GET, path, null, cookie, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const raw = doc.str("selected_profile_model") orelse "";
    return gpa.dupe(u8, raw);
}

/// Create a card in `kanban_id` and return the new task id (== session id).
fn createTask(
    h: *Harness,
    cookie: []const u8,
    ws_id: []const u8,
    kanban_id: []const u8,
    body: []const u8,
) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tasks",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(path);
    var r = try authed(h, .POST, path, body, cookie, &.{201});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const task = doc.object("task") orelse {
        std.debug.print("kanban task create has no task: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id_val = task.get("id") orelse {
        std.debug.print("kanban task create has no task.id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return switch (id_val) {
        .string => |s| gpa.dupe(u8, s),
        else => error.TestUnexpectedResult,
    };
}

fn createWorkspace(h: *Harness, cookie: []const u8, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);
    var r = try authed(h, .POST, "/api/workspaces", body, cookie, &.{201});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("workspace create has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

fn createKanban(h: *Harness, cookie: []const u8, ws_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/kanban", .{ws_id});
    defer gpa.free(path);
    var r = try authed(h, .POST, path, body, cookie, &.{201});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const item = doc.object("item") orelse {
        std.debug.print("kanban create has no item: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id_val = item.get("id") orelse {
        std.debug.print("kanban create has no item.id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return switch (id_val) {
        .string => |s| gpa.dupe(u8, s),
        else => error.TestUnexpectedResult,
    };
}

/// Poll the stub until `count()` reaches `want` or the deadline passes.
fn waitForRequests(stub: *Stub, want: usize, timeout_ms: i64) bool {
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + timeout_ms;
    while (stub.count() < want and std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        std.Io.sleep(io, .fromMilliseconds(250), .awake) catch {};
    }
    return stub.count() >= want;
}

fn logTail(h: *Harness) ![]u8 {
    return h.tailLog(io, gpa, 4000);
}

// ============================================================================
// Test
// ============================================================================

test "a chat's default model is its workspace's active profile" {
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

    // 1. The user saves their profiles through the real Settings wire. The
    //    user-level ACTIVE profile points at the dead endpoint: if any turn
    //    below runs on it, the stub records nothing.
    {
        const put_body = try std.fmt.allocPrint(
            gpa,
            "{{\"profiles\":{{" ++
                "\"{s}\":{{\"model\":\"{s}\",\"base_url\":\"{s}\",\"api_key\":\"{s}\"," ++
                "\"url_style\":\"openai\",\"thinking\":\"auto\",\"temperature\":\"auto\"}}," ++
                "\"{s}\":{{\"model\":\"{s}\",\"base_url\":\"{s}\",\"api_key\":\"{s}\"," ++
                "\"url_style\":\"openai\",\"thinking\":\"auto\",\"temperature\":\"auto\"}}," ++
                "\"{s}\":{{\"model\":\"{s}\",\"base_url\":\"{s}\",\"api_key\":\"{s}\"," ++
                "\"url_style\":\"openai\",\"thinking\":\"auto\",\"temperature\":\"auto\"}}" ++
                "}},\"active_profile\":\"{s}\"}}",
            .{
                USER_DEFAULT, USER_DEFAULT_MODEL, DEAD_ENDPOINT, USER_KEY,
                WS_DEFAULT,   WS_DEFAULT_MODEL,   stub_url,      USER_KEY,
                EXPLICIT,     EXPLICIT_MODEL,     stub_url,      USER_KEY,
                USER_DEFAULT,
            },
        );
        defer gpa.free(put_body);
        var r = try rawHttp(&h, .PUT, "/api/config/pabrik", put_body, cookie);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print("PUT /api/config/pabrik failed: {d} {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }

    // 2. Workspace + kanban board, owned by the same user.
    const ws_id = try createWorkspace(&h, cookie, "ws-default-scope");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, cookie, ws_id, "sprint-default");
    defer gpa.free(kanban_id);

    // 3. THE SETTING UNDER TEST — Settings -> Workspace -> "Set active", which
    //    writes the workspace's own copy. The exact body the settings page PUTs:
    //    the whole workspace-scoped config it loaded, `active_profile` moved.
    {
        const body = try std.fmt.allocPrint(
            gpa,
            "{{\"profiles\":{{" ++
                "\"{s}\":{{\"model\":\"{s}\",\"base_url\":\"{s}\",\"api_key\":\"{s}\",\"url_style\":\"openai\",\"thinking\":\"auto\",\"temperature\":\"auto\"}}," ++
                "\"{s}\":{{\"model\":\"{s}\",\"base_url\":\"{s}\",\"api_key\":\"{s}\",\"url_style\":\"openai\",\"thinking\":\"auto\",\"temperature\":\"auto\"}}," ++
                "\"{s}\":{{\"model\":\"{s}\",\"base_url\":\"{s}\",\"api_key\":\"{s}\",\"url_style\":\"openai\",\"thinking\":\"auto\",\"temperature\":\"auto\"}}" ++
                "}},\"active_profile\":\"{s}\"}}",
            .{
                USER_DEFAULT, USER_DEFAULT_MODEL, DEAD_ENDPOINT, USER_KEY,
                WS_DEFAULT,   WS_DEFAULT_MODEL,   stub_url,      USER_KEY,
                EXPLICIT,     EXPLICIT_MODEL,     stub_url,      USER_KEY,
                WS_DEFAULT,
            },
        );
        defer gpa.free(body);
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/config", .{ws_id});
        defer gpa.free(path);
        var r = try authed(&h, .PUT, path, body, cookie, &.{200});
        defer r.deinit();
    }

    // 4. A card created the way the dialog creates one — with NO profile
    //    picker value ("Default" in the dialog), which is the exact body the
    //    frontend's `create_session` mode sends.
    const card_body =
        "{\"mode\":\"create_session\",\"name\":\"default card\"," ++
        "\"description\":\"which model am I on?\"}";
    const session_id = try createTask(&h, cookie, ws_id, kanban_id, card_body);
    defer gpa.free(session_id);

    {
        const stored = try sessionProfile(&h, cookie, session_id);
        defer gpa.free(stored);
        if (!std.mem.eql(u8, stored, WS_DEFAULT)) {
            const log_tail = try logTail(&h);
            defer gpa.free(log_tail);
            std.debug.print(
                "the new session's row stored profile '{s}', not the workspace's active '{s}' " ++
                    "(the user-level default is '{s}'):\n{s}\n",
                .{ stored, WS_DEFAULT, USER_DEFAULT, log_tail },
            );
            return error.TestUnexpectedResult;
        }
    }

    // 5. The composer's "Default" send: `selected_profile_model` omitted, which
    //    is what `api.sendChatMessage` puts on the wire when the chip has no
    //    per-session pick.
    {
        const body = try std.fmt.allocPrint(
            gpa,
            "{{\"session_id\":\"{s}\",\"queue_message\":\"which model am I on?\"}}",
            .{session_id},
        );
        defer gpa.free(body);
        var r = try rawHttp(&h, .POST, "/api/llm/session", body, cookie);
        defer r.deinit();
        if (r.status != 201) {
            std.debug.print("POST /api/llm/session failed: {d} {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }

    if (!waitForRequests(&stub, 1, 30_000)) {
        const log_tail = try logTail(&h);
        defer gpa.free(log_tail);
        const at = std.mem.indexOf(u8, log_tail, "[STREAM START] model=");
        if (at == null) {
            std.debug.print("the turn never reached a streaming LLM call:\n{s}\n", .{log_tail});
            return error.TestUnexpectedResult;
        }
        std.debug.print(
            "the turn did not reach the workspace's active profile endpoint " ++
                "(the stub). '[STREAM START]' says: {s}\n--- log tail ---\n{s}\n",
            .{ log_tail[at.?..@min(log_tail.len, at.? + 120)], log_tail },
        );
        return error.TestUnexpectedResult;
    }

    // The recorded request is the witness: model + credential.
    {
        var seen = try stub.snapshot();
        defer {
            for (seen.items) |*rec| rec.deinit();
            seen.deinit(gpa);
        }
        const rec = seen.items[0];
        const model = recordedModel(rec.body) orelse {
            std.debug.print("stub request 0: body is not JSON: {s}\n", .{rec.body});
            return error.TestUnexpectedResult;
        };
        defer gpa.free(model);
        if (!std.mem.eql(u8, model, WS_DEFAULT_MODEL)) {
            const log_tail = try logTail(&h);
            defer gpa.free(log_tail);
            std.debug.print(
                "the wire model was '{s}', not the workspace's active profile's '{s}':\n{s}\n",
                .{ model, WS_DEFAULT_MODEL, log_tail },
            );
            return error.TestUnexpectedResult;
        }
        // Positive control on the other half of the merge: the overlay only
        // named the active profile, so the credential still comes from the
        // user config.
        const auth = headerValue(rec.head, "authorization") orelse "";
        try testing.expect(std.mem.indexOf(u8, auth, USER_KEY) != null);
    }

    // 6. An EXPLICIT per-session pick still wins over the workspace default —
    //    the fix must not flatten the cascade into "always the workspace's".
    {
        const body = try std.fmt.allocPrint(
            gpa,
            "{{\"session_id\":\"{s}\",\"queue_message\":\"and now?\",\"selected_profile_model\":\"{s}\"}}",
            .{ session_id, EXPLICIT },
        );
        defer gpa.free(body);
        var r = try rawHttp(&h, .POST, "/api/llm/session", body, cookie);
        defer r.deinit();
        if (r.status != 201) {
            std.debug.print("POST /api/llm/session (explicit) failed: {d} {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }

    if (!waitForRequests(&stub, 2, 30_000)) {
        const log_tail = try logTail(&h);
        defer gpa.free(log_tail);
        std.debug.print("the explicit-profile turn never reached the stub:\n{s}\n", .{log_tail});
        return error.TestUnexpectedResult;
    }

    {
        var seen = try stub.snapshot();
        defer {
            for (seen.items) |*rec| rec.deinit();
            seen.deinit(gpa);
        }
        var saw_explicit = false;
        for (seen.items) |rec| {
            const model = recordedModel(rec.body) orelse continue;
            defer gpa.free(model);
            if (std.mem.eql(u8, model, USER_DEFAULT_MODEL)) {
                std.debug.print(
                    "a turn ran on the USER-level default ({s}) even though the workspace's " ++
                        "active profile is '{s}' and one turn asked for '{s}' explicitly\n",
                    .{ USER_DEFAULT_MODEL, WS_DEFAULT, EXPLICIT },
                );
                return error.TestUnexpectedResult;
            }
            if (std.mem.eql(u8, model, EXPLICIT_MODEL)) saw_explicit = true;
        }
        if (!saw_explicit) {
            std.debug.print(
                "the explicit per-session pick ('{s}' -> {s}) never reached the wire\n",
                .{ EXPLICIT, EXPLICIT_MODEL },
            );
            return error.TestUnexpectedResult;
        }
    }
}

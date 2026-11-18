// Functional proof: every `llm_history` row of a turn carries that turn's speaker (task_1794933840587_1).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;
const Io = std.Io;

const OWN_AGENT = "deepseek auto";
const OWN_MODEL = "stub-own-model";
const GROUP_AGENT = "Simple Engineer";
const GROUP_MODEL = "stub-group-model";
const PLACEHOLDER = "Agent";

const SESSION_ID = "sess_turn_attribution_1";
const CALL_ID = "call_attribution_1";

const MAX_HEAD_BYTES = 1 << 18;

// ─── Stub upstream ──────────────────────────────────────────────────────────

const Stub = struct {
    io: Io,
    port: u16,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    cwd: []const u8,
    agent_calls: usize = 0,

    fn start(stub: *Stub, cwd: []const u8) !void {
        stub.* = .{ .io = io, .port = 0, .server = undefined, .thread = undefined, .cwd = cwd };
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
    }

    fn agentCallCount(self: *Stub) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.agent_calls;
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
    const body = body_acc.written();

    // The session-name call carries no `tools` array; answering it keeps the round counter honest.
    const is_name = std.mem.indexOf(u8, body, "\"tools\"") == null and
        std.mem.indexOf(u8, body, "SessionName") != null;

    var payload: []u8 = &.{};
    defer if (payload.len > 0) gpa.free(payload);

    if (is_name) {
        payload = try textSse("attribution-probe");
    } else {
        stub.mutex.lockUncancelable(stub.io);
        stub.agent_calls += 1;
        const round_index = stub.agent_calls;
        stub.mutex.unlock(stub.io);

        if (round_index == 1) {
            const args = try std.fmt.allocPrint(
                gpa,
                "{{\"command\":\"echo attribution-probe\",\"cwd\":{f},\"timeout\":30}}",
                .{std.json.fmt(stub.cwd, .{})},
            );
            defer gpa.free(args);
            payload = try toolCallSse("command", args, CALL_ID);
        } else {
            payload = try textSse("done");
        }
    }

    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .{payload.len},
    );
    defer gpa.free(response);

    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(stub.io, &wbuf);
    try sw.interface.writeAll(response);
    try sw.interface.writeAll(payload);
    try sw.interface.flush();
}

fn textSse(text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "data: {{\"id\":\"chatcmpl-stub-text\",\"object\":\"chat.completion.chunk\",\"model\":\"stub-model\",\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":\"{s}\"}},\"finish_reason\":null}}]}}\n\n" ++
            "data: {{\"id\":\"chatcmpl-stub-text\",\"object\":\"chat.completion.chunk\",\"model\":\"stub-model\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\n" ++
            "data: [DONE]\n\n",
        .{text},
    );
}

fn toolCallSse(tool: []const u8, args: []const u8, call_id: []const u8) ![]u8 {
    const args_json = try jsonStringEscape(gpa, args);
    defer gpa.free(args_json);

    return std.fmt.allocPrint(
        gpa,
        "data: {{\"id\":\"chatcmpl-stub-tool\",\"object\":\"chat.completion.chunk\",\"model\":\"stub-model\",\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{{\"index\":0,\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"{s}\"}}}}]}},\"finish_reason\":null}}]}}\n\n" ++
            "data: {{\"id\":\"chatcmpl-stub-tool\",\"object\":\"chat.completion.chunk\",\"model\":\"stub-model\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"tool_calls\"}}]}}\n\n" ++
            "data: [DONE]\n\n",
        .{ call_id, tool, args_json },
    );
}

fn jsonStringEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        else => try buf.append(allocator, c),
    };
    return buf.toOwnedSlice(allocator);
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

fn contentLength(head: []const u8) usize {
    const v = headerValue(head, "content-length") orelse return 0;
    return std.fmt.parseInt(usize, v, 10) catch 0;
}

// ─── Helpers ────────────────────────────────────────────────────────────────

fn nowMs() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn sleepMs(ms: i64) void {
    std.Io.sleep(io, .fromMilliseconds(ms), .awake) catch {};
}

fn requireSqlite3Cli() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-json", ":memory:", "SELECT 1 AS probe;" },
    }) catch {
        std.debug.print("sqlite3 CLI unavailable; skipping\n", .{});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const ok = switch (res.term) {
        .exited => |c| c == 0 and std.mem.indexOf(u8, res.stdout, "probe") != null,
        else => false,
    };
    if (!ok) {
        std.debug.print("sqlite3 CLI lacks -json support; skipping\n", .{});
        return error.SkipZigTest;
    }
}

/// Point BOTH agents at this run's stub, each with its own model id.
fn useStubProfiles(h: *Harness, stub_port: u16) !void {
    const stub_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1/chat/completions", .{stub_port});
    defer gpa.free(stub_url);
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"api_endpoint\":\"{s}\",\"api_key\":\"sk-stub-test\",\"model\":\"{s}\",\"url_style\":\"openai\"," ++
            "\"profiles\":{{" ++
            "\"{s}\":{{\"model\":\"{s}\",\"base_url\":\"{s}\",\"api_key\":\"sk-stub-test\",\"url_style\":\"openai\"}}," ++
            "\"{s}\":{{\"model\":\"{s}\",\"base_url\":\"{s}\",\"api_key\":\"sk-stub-test\",\"url_style\":\"openai\"}}" ++
            "}},\"active_profile\":\"{s}\"}}",
        .{ stub_url, OWN_MODEL, OWN_AGENT, OWN_MODEL, stub_url, GROUP_AGENT, GROUP_MODEL, stub_url, OWN_AGENT },
    );
    defer gpa.free(body);

    var r = try h.http(io, .PUT, "/api/config/pabrik", .{
        .json_body = body,
        .expect = &.{200},
    });
    defer r.deinit();
}

fn sendTurn(h: *Harness, message: []const u8) !void {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"session_id\":\"{s}\",\"queue_message\":\"{s}\",\"cwd_session\":\"{s}\"," ++
            "\"allowed_tools\":\"\",\"image_urls\":\"\",\"selected_profile_model\":\"{s}\"," ++
            "\"is_auto_retry_until_stop\":\"\"}}",
        .{ SESSION_ID, message, h.temp_dir, OWN_AGENT },
    );
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/llm/session", .{
        .json_body = body,
        .expect = &.{ 200, 201, 500 },
        .timeout_s = 30.0,
    });
    defer r.deinit();
}

fn dbPath(h: *Harness) ![]u8 {
    return harness.harnessPath(gpa, h.temp_dir, &.{ ".config", "pabrik", "agent.db" });
}

fn sqlRun(db_path: []const u8, sql: []const u8) ![]u8 {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-cmd", ".timeout 5000", "-json", db_path, sql },
    }) catch |err| {
        std.debug.print("sqlite3 did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("sqlite3 exited {d} for sql: {s}\n", .{ code, sql });
            gpa.free(res.stdout);
            return error.TestUnexpectedResult;
        },
        else => {
            gpa.free(res.stdout);
            return error.TestUnexpectedResult;
        },
    }
    return res.stdout;
}

fn firstCell(db_path: []const u8, sql: []const u8) !?[]u8 {
    const out = try sqlRun(db_path, sql);
    defer gpa.free(out);
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) return null;

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{});
    defer parsed.deinit();
    const rows = switch (parsed.value) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    if (rows.items.len == 0) return null;
    const row = switch (rows.items[0]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    var it = row.iterator();
    const entry = it.next() orelse return null;
    return switch (entry.value_ptr.*) {
        .string => |s| try gpa.dupe(u8, s),
        .integer => |i| try std.fmt.allocPrint(gpa, "{d}", .{i}),
        .null => null,
        else => error.TestUnexpectedResult,
    };
}

fn scalarCount(db_path: []const u8, sql: []const u8) !i64 {
    const cell = (try firstCell(db_path, sql)) orelse return 0;
    defer gpa.free(cell);
    return std.fmt.parseInt(i64, cell, 10);
}

fn waitForTurnEnd(h: *Harness, db_path: []const u8, timeout_ms: i64) !void {
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        const n = try scalarCount(db_path, "SELECT COUNT(*) AS n FROM worker WHERE id = '" ++ SESSION_ID ++ "';");
        if (n == 0) return;
        sleepMs(100);
    }
    const tail = try h.tailLog(io, gpa, 40);
    defer gpa.free(tail);
    std.debug.print("the turn never ended (worker row still present). log tail:\n{s}\n", .{tail});
    return error.TestUnexpectedResult;
}

/// Count the rows of `role` in this session that do NOT name `agent`.
fn rowsNotNaming(db_path: []const u8, role: []const u8, agent: []const u8) !i64 {
    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT COUNT(*) AS n FROM llm_history WHERE session_id = '{s}' AND role = '{s}' AND COALESCE(agent,'') <> '{s}';",
        .{ SESSION_ID, role, agent },
    );
    defer gpa.free(sql);
    return scalarCount(db_path, sql);
}

/// Count the turns whose tool rows disagree with the assistant row that called them.
fn turnsWithMismatchedToolAgent(db_path: []const u8) !i64 {
    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT COUNT(*) AS n FROM llm_history t JOIN llm_history a " ++
            "ON a.session_id = t.session_id AND a.loop_index = t.loop_index AND a.role = 'assistant' " ++
            "WHERE t.session_id = '{s}' AND t.role = 'tool' AND COALESCE(t.agent,'') <> COALESCE(a.agent,'');",
        .{SESSION_ID},
    );
    defer gpa.free(sql);
    return scalarCount(db_path, sql);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "a chat with no roster names its own agent on every assistant and tool row" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var stub: Stub = undefined;
    try stub.start(h.temp_dir);
    defer stub.deinit();

    try useStubProfiles(&h, stub.port);
    try sendTurn(&h, "run the probe");

    const db_path = try dbPath(&h);
    defer gpa.free(db_path);
    try waitForTurnEnd(&h, db_path, 60_000);
    sleepMs(1500);

    const tool_rows = try scalarCount(db_path, "SELECT COUNT(*) AS n FROM llm_history WHERE session_id = '" ++ SESSION_ID ++ "' AND role = 'tool';");
    if (tool_rows == 0) {
        std.debug.print("no tool row was persisted (model_calls={d}) — the test proves nothing\n", .{stub.agentCallCount()});
        return error.TestUnexpectedResult;
    }

    const assistant_wrong = try rowsNotNaming(db_path, "assistant", OWN_AGENT);
    try testing.expectEqual(@as(i64, 0), assistant_wrong);
    const tool_wrong = try rowsNotNaming(db_path, "tool", OWN_AGENT);
    try testing.expectEqual(@as(i64, 0), tool_wrong);

    const placeholder_tools = try scalarCount(db_path, "SELECT COUNT(*) AS n FROM llm_history WHERE session_id = '" ++ SESSION_ID ++ "' AND role = 'tool' AND agent = '" ++ PLACEHOLDER ++ "';");
    try testing.expectEqual(@as(i64, 0), placeholder_tools);

    const mismatched = try turnsWithMismatchedToolAgent(db_path);
    try testing.expectEqual(@as(i64, 0), mismatched);

    const tool_model = (try firstCell(db_path, "SELECT model AS m FROM llm_history WHERE session_id = '" ++ SESSION_ID ++ "' AND role = 'tool' LIMIT 1;")) orelse return error.TestUnexpectedResult;
    defer gpa.free(tool_model);
    try testing.expectEqualStrings(OWN_MODEL, tool_model);
}

test "a group turn's tool rows carry the turn's speaker, not the previous row's" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var stub: Stub = undefined;
    try stub.start(h.temp_dir);
    defer stub.deinit();

    try useStubProfiles(&h, stub.port);

    const db_path = try dbPath(&h);
    defer gpa.free(db_path);

    // The roster the reported chat had: one member, made the lead.
    const roster_sql = try std.fmt.allocPrint(
        gpa,
        "INSERT OR REPLACE INTO sessions (id, name, status, cwd, selected_profile_model, group_lead) " ++
            "VALUES ('{s}', 'attribution probe', 'active', '{s}', '{s}', '{s}'); " ++
            "INSERT OR REPLACE INTO session_group_members (session_id, agent_name, role, position) " ++
            "VALUES ('{s}', '{s}', 'lead', 1);",
        .{ SESSION_ID, h.temp_dir, OWN_AGENT, GROUP_AGENT, SESSION_ID, GROUP_AGENT },
    );
    defer gpa.free(roster_sql);
    const seeded = try sqlRun(db_path, roster_sql);
    gpa.free(seeded);

    try sendTurn(&h, "run the probe");
    try waitForTurnEnd(&h, db_path, 60_000);
    sleepMs(1500);

    const assistant_rows = try scalarCount(db_path, "SELECT COUNT(*) AS n FROM llm_history WHERE session_id = '" ++ SESSION_ID ++ "' AND role = 'assistant';");
    const tool_rows = try scalarCount(db_path, "SELECT COUNT(*) AS n FROM llm_history WHERE session_id = '" ++ SESSION_ID ++ "' AND role = 'tool';");
    if (assistant_rows == 0 or tool_rows == 0) {
        std.debug.print(
            "the routed turn wrote no assistant+tool pair (assistant={d} tool={d} model_calls={d})\n",
            .{ assistant_rows, tool_rows, stub.agentCallCount() },
        );
        return error.TestUnexpectedResult;
    }

    // THE ASSERTION THIS FILE EXISTS FOR.
    const assistant_wrong = try rowsNotNaming(db_path, "assistant", GROUP_AGENT);
    try testing.expectEqual(@as(i64, 0), assistant_wrong);
    const tool_wrong = try rowsNotNaming(db_path, "tool", GROUP_AGENT);
    try testing.expectEqual(@as(i64, 0), tool_wrong);

    const mismatched = try turnsWithMismatchedToolAgent(db_path);
    try testing.expectEqual(@as(i64, 0), mismatched);

    const placeholder_tools = try scalarCount(db_path, "SELECT COUNT(*) AS n FROM llm_history WHERE session_id = '" ++ SESSION_ID ++ "' AND role = 'tool' AND agent = '" ++ PLACEHOLDER ++ "';");
    try testing.expectEqual(@as(i64, 0), placeholder_tools);

    // The speaker's own configuration ran the turn: same model on both rows.
    const tool_model = (try firstCell(db_path, "SELECT model AS m FROM llm_history WHERE session_id = '" ++ SESSION_ID ++ "' AND role = 'tool' LIMIT 1;")) orelse return error.TestUnexpectedResult;
    defer gpa.free(tool_model);
    try testing.expectEqualStrings(GROUP_MODEL, tool_model);
}

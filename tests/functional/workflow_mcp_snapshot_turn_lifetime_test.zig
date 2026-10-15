// Wire test: the agent loop must not read a PER-TURN-ARENA MCP snapshot on a
// turn that no longer owns it.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;
const Io = std.Io;

/// The MCP server name in the config, the tool the python stub advertises,
/// and the name the model actually sees: pabrik namespaces MCP tools as
/// `mcp_<server>_<tool>` (see `convertMcpToolsToAgentTools`), and that wire
const MCP_SERVER_NAME = "stub";
const MCP_TOOL_NAME = "stub_tool_0";
const MCP_WIRE_NAME = "mcp_" ++ MCP_SERVER_NAME ++ "_" ++ MCP_TOOL_NAME;

/// Tool offered by the python stub. `MCP_TOOL_COUNT` is asserted through the
/// resolution checkpoint log, so a stub that answered `tools/list` with nothing
/// cannot let this test pass vacuously.
const MCP_TOOL_COUNT = 3;

/// Tool-bearing requests answered with a tool call before the config mutation,
/// and in total. The gap (here 3 turns) is the number of turns that run AFTER
/// the refresh, which is what the regression assertion needs to observe.
const TOOL_TURNS_BEFORE_CLEAR: usize = 2;
const TOOL_TURNS_TOTAL: usize = 7;

/// Per-turn pacing for the stub upstream.
const TURN_PACING_MS: i64 = 400;

/// Python stdio MCP server, written into the harness tmpdir.
const MCP_STUB_PY =
    \\#!/usr/bin/env python3
    \\"""Minimal stdio MCP server: initialize + tools/list, 3 tools."""
    \\import json
    \\import os
    \\import sys
    \\
    \\LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mcp_stub.log")
    \\
    \\def note(msg):
    \\    try:
    \\        with open(LOG, "a", buffering=1) as fh:
    \\            fh.write(msg + "\n")
    \\    except Exception:
    \\        pass
    \\
    \\note("=== stub start ===")
    \\TOOLS = [{"name": "stub_tool_%d" % i,
    \\          "description": "Stub MCP tool %d." % i,
    \\          "inputSchema": {"type": "object", "properties": {}}}
    \\         for i in range(3)]
    \\
    \\for line in sys.stdin:
    \\    note("IN " + line.strip())
    \\    line = line.strip()
    \\    if not line:
    \\        continue
    \\    try:
    \\        msg = json.loads(line)
    \\    except Exception:
    \\        note("PARSE-FAIL")
    \\        continue
    \\    mid = msg.get("id")
    \\    if mid is None:
    \\        continue  # notification (notifications/initialized)
    \\    method = msg.get("method", "")
    \\    if method == "initialize":
    \\        result = {"protocolVersion": "2024-11-05",
    \\                  "capabilities": {"tools": {}},
    \\                  "serverInfo": {"name": "pabrik-test-mcp-stub",
    \\                                 "version": "0.0.1"}}
    \\    elif method == "tools/list":
    \\        result = {"tools": TOOLS}
    \\    else:
    \\        result = {}
    \\    sys.stdout.write(json.dumps({"jsonrpc": "2.0",
    \\                                 "id": mid,
    \\                                 "result": result}) + "\n")
    \\    sys.stdout.flush()
    \\    note("OUT " + method)
    \\note("=== stub eof ===")
    \\
;

/// Tool call the stub upstream returns for a tool-bearing request.
fn toolCallSse(alloc: std.mem.Allocator, turn: usize) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\data: {{"id": "chatcmpl-stub-toolcall", "object": "chat.completion.chunk", "model": "stub-model", "choices": [{{"index": 0, "delta": {{"role": "assistant", "content": null, "tool_calls": [{{"index": 0, "id": "call_stub_{d}", "type": "function", "function": {{"name": "used_tools", "arguments": "{{}}"}}}}]}}, "finish_reason": null}}]}}
        \\
        \\data: {{"id": "chatcmpl-stub-toolcall", "object": "chat.completion.chunk", "model": "stub-model", "choices": [{{"index": 0, "delta": {{}}, "finish_reason": "tool_calls"}}]}}
        \\
        \\data: [DONE]
        \\
    , .{turn});
}

/// True when `body` (a chat-completion request) lists `name` in its `tools`
/// array. Parsed rather than substring-matched so a mention of the name in the
/// prompt cannot make the assertion pass vacuously.
fn bodyListsTool(body: []const u8, name: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const tools_v = parsed.value.object.get("tools") orelse return false;
    if (tools_v != .array) return false;
    for (tools_v.array.items) |entry| {
        if (entry != .object) continue;
        const fn_v = entry.object.get("function") orelse continue;
        if (fn_v != .object) continue;
        const name_v = fn_v.object.get("name") orelse continue;
        if (name_v != .string) continue;
        if (std.mem.eql(u8, name_v.string, name)) return true;
    }
    return false;
}

/// Plain assistant message, for the request that ends the run.
const TEXT_SSE =
    \\data: {"id": "chatcmpl-stub-text", "object": "chat.completion.chunk", "model": "stub-model", "choices": [{"index": 0, "delta": {"role": "assistant", "content": "done"}, "finish_reason": null}]}
    \\
    \\data: {"id": "chatcmpl-stub-text", "object": "chat.completion.chunk", "model": "stub-model", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
    \\
    \\data: [DONE]
    \\
;

const MAX_HEAD_BYTES = 1 << 18;

/// Markers that only appear in the process log if the worker died.
const CRASH_MARKERS = [_][]const u8{
    "received signal",
    "panic:",
    "reached unreachable code",
    "Invalid free",
    "use after free",
    "Segmentation fault",
};

// ============================================================================
// Stub upstream (OpenAI-shaped SSE)
// ============================================================================

/// One `pabrik` chat-completion request per accepted connection, answered from
/// the tool-turn counter. The assertions read the counters from the test
/// thread, so they are atomics.
const Stub = struct {
    port: u16,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    /// Tool-bearing requests answered so far. The session auto-name call carries
    /// no `tools` array and is not counted.
    tool_turns: std.atomic.Value(usize) = .init(0),
    /// Set by the test once the config mutation has been sent.
    clear_sent: std.atomic.Value(bool) = .init(false),
    /// The regression flag: a tool-bearing request that arrived after the
    /// mutation AND still carried the equipped MCP tool.
    mcp_tool_after_clear: std.atomic.Value(bool) = .init(false),
    /// Positive control: the equipped MCP tool WAS in the tool list on a
    /// pre-mutation turn, so its absence afterwards is the snapshot and not a
    /// seeding mistake.
    turn_before_clear_has_tool: std.atomic.Value(bool) = .init(false),
    /// A tool-bearing request that arrived after the mutation at all — the
    /// positive control that the post-refresh turns really ran.
    turn_after_clear: std.atomic.Value(bool) = .init(false),

    fn start(stub: *Stub) !void {
        stub.port = try harness.findFreePortRandom(gpa);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
        stub.server = try addr.listen(io, .{ .reuse_address = true });
        errdefer stub.server.deinit(io);
        stub.thread = try std.Thread.spawn(.{}, serveStub, .{stub});
    }

    /// Wake the blocked `accept`, join, free.
    fn shutdown(stub: *Stub) void {
        stub.stop.store(true, .release);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
        if (addr.connect(io, .{ .mode = .stream })) |conn| {
            var c = conn;
            c.close(io);
        } else |_| {}
        stub.thread.join();
        stub.server.deinit(io);
    }
};

fn serveStub(stub: *Stub) void {
    while (!stub.stop.load(.acquire)) {
        var stream = stub.server.accept(io) catch break;
        defer stream.close(io);
        if (stub.stop.load(.acquire)) break;
        handleRequest(stub, stream) catch {};
    }
}

/// Read one request, decide the reply, send it.
fn handleRequest(stub: *Stub, stream: Io.net.Stream) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const r = &sr.interface;

    var acc: Io.Writer.Allocating = .init(gpa);
    defer acc.deinit();

    var head_len: usize = 0;
    while (head_len == 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        acc.writer.writeAll(b) catch break;
        r.toss(b.len);
        if (acc.written().len > MAX_HEAD_BYTES) break;
        if (std.mem.indexOf(u8, acc.written(), "\r\n\r\n")) |i| head_len = i + 4;
    }
    if (head_len == 0) return;
    const head = acc.written()[0..head_len];

    var remaining = contentLength(head);
    if (acc.written().len > head_len) remaining -|= acc.written().len - head_len;
    while (remaining > 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        const take = @min(b.len, remaining);
        acc.writer.writeAll(b[0..take]) catch break;
        remaining -= take;
        r.toss(take);
    }

    const body = acc.written()[head_len..];
    const tool_bearing = std.mem.indexOf(u8, body, "\"tools\"") != null;

    var owned_sse: ?[]u8 = null;
    defer if (owned_sse) |s| gpa.free(s);
    var sse: []const u8 = TEXT_SSE;
    if (tool_bearing) {
        // Pace the loop so the test's config mutation lands BETWEEN turns (see
        // TURN_PACING_MS).
        Io.sleep(io, .fromMilliseconds(TURN_PACING_MS), .awake) catch {};
        const n = stub.tool_turns.fetchAdd(1, .monotonic);
        if (n < TOOL_TURNS_TOTAL) {
            owned_sse = try toolCallSse(gpa, n);
            sse = owned_sse.?;
        }
        const has_tool = bodyListsTool(body, MCP_WIRE_NAME);
        if (stub.clear_sent.load(.acquire)) {
            stub.turn_after_clear.store(true, .release);
            if (has_tool) stub.mcp_tool_after_clear.store(true, .release);
        } else if (has_tool) {
            // Positive control for the assertion below: the equipped MCP tool IS
            // in the tool list on the pre-mutation turns, so a missing one
            // afterwards is the snapshot and not a seeding mistake.
            stub.turn_before_clear_has_tool.store(true, .release);
        }
    }

    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
        .{ sse.len, sse },
    );
    defer gpa.free(response);

    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    try sw.interface.writeAll(response);
    try sw.interface.flush();
}

fn headerLines(head: []const u8) std.mem.SplitIterator(u8, .sequence) {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // request line
    return it;
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = headerLines(head);
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
// Helpers
// ============================================================================

/// Absolute path of an executable `name`, looked up on PATH.
fn findOnPath(name: []const u8) ?[]u8 {
    const path: []u8 = std.testing.environ.getAlloc(gpa, "PATH") catch return null;
    defer gpa.free(path);
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(gpa, &.{ dir, name }) catch return null;
        if (std.Io.Dir.cwd().access(io, candidate, .{ .execute = true })) |_| {
            return candidate;
        } else |_| {
            gpa.free(candidate);
        }
    }
    return null;
}

/// Agent DB inside the isolated tmpdir HOME (Linux layout).
fn dbPath(temp_dir: []const u8) ![]u8 {
    return harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
}

/// Run one statement against `db_path` through the sqlite3 CLI, returning the
/// CLI's stdout (caller owns it).
fn sqliteRunOut(alloc: std.mem.Allocator, db_path: []const u8, sql: []const u8) ![]u8 {
    const res = std.process.run(alloc, io, .{
        .argv = &.{ "sqlite3", "-cmd", ".timeout 5000", db_path, sql },
    }) catch |err| {
        std.debug.print("sqlite3 did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer alloc.free(res.stderr);

    const code = switch (res.term) {
        .exited => |c| c,
        else => {
            alloc.free(res.stdout);
            std.debug.print("sqlite3 was killed by a signal: {any}\n", .{res.term});
            return error.TestUnexpectedResult;
        },
    };
    if (code != 0) {
        defer alloc.free(res.stdout);
        std.debug.print("sqlite3 exited {d}: {s}\nsql: {s}\n", .{ code, res.stderr, sql });
        return error.TestUnexpectedResult;
    }
    return res.stdout;
}

/// `sqliteRunOut` for statements whose output is not needed.
fn sqliteRun(db_path: []const u8, sql: []const u8) !void {
    const out = try sqliteRunOut(gpa, db_path, sql);
    gpa.free(out);
}

/// The whole process log (the resolution checkpoints must be counted across
/// every turn, and `tailLog` windows by line count).
fn readLog(h: *Harness) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, h.log_path, gpa, .limited(1 << 22)) catch |err| switch (err) {
        error.FileNotFound => gpa.dupe(u8, ""),
        else => err,
    };
}

/// Set by the test to `<tempdir>/mcp_stub.log` — the python MCP stub's trace.
/// Best-effort: diagnostics only.
var mcp_stub_log_path: []const u8 = "";

fn readStubLog() []u8 {
    if (mcp_stub_log_path.len == 0) return gpa.dupe(u8, "") catch @panic("oom");
    return std.Io.Dir.cwd().readFileAlloc(io, mcp_stub_log_path, gpa, .limited(1 << 20)) catch
        gpa.dupe(u8, "") catch @panic("oom");
}

/// Count non-overlapping occurrences of `needle` in `haystack`.
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var n: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, idx, needle)) |at| {
        n += 1;
        idx = at + needle.len;
    }
    return n;
}

/// Poll until the stub has answered `want` tool-bearing requests, failing with
/// the log if the server dies first.
fn waitForToolTurns(stub: *Stub, want: usize, h: *Harness) !void {
    const deadline = Io.Timestamp.now(io, .awake).toMilliseconds() + 60_000;
    while (Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        if (stub.tool_turns.load(.acquire) >= want) return;
        if (!h.health(io)) {
            const log = try readLog(h);
            defer gpa.free(log);
            const trace = readStubLog();
            defer gpa.free(trace);
            std.debug.print("pabrik died while waiting for tool turn {d}.\n--- mcp stub trace ---\n{s}\n--- log ---\n{s}\n", .{ want, trace, log });
            return error.TestUnexpectedResult;
        }
        Io.sleep(io, .fromMilliseconds(250), .awake) catch {};
    }
    const log = try readLog(h);
    defer gpa.free(log);
    const trace = readStubLog();
    defer gpa.free(trace);
    std.debug.print(
        "timed out waiting for {d} tool turns (seen {d}).\n--- mcp stub trace ---\n{s}\n--- log ---\n{s}\n",
        .{ want, stub.tool_turns.load(.acquire), trace, log },
    );
    return error.TestUnexpectedResult;
}

// ============================================================================
// Test
// ============================================================================

test "mcp snapshot survives a mid-run config mutation" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try harness.requirePabrikBin(io, gpa);

    const python3 = findOnPath("python3") orelse {
        std.debug.print("python3 not on PATH; skipping the MCP snapshot test\n", .{});
        return error.SkipZigTest;
    };
    defer gpa.free(python3);

    var stub: Stub = .{ .port = 0, .server = undefined, .thread = undefined };
    try stub.start();
    defer stub.shutdown();

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // 0. The python stdio MCP stub, written into the harness HOME.
    const script = try harness.harnessPath(gpa, h.temp_dir, &.{"mcp_stub.py"});
    defer gpa.free(script);
    {
        var f = try std.Io.Dir.cwd().createFile(io, script, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, MCP_STUB_PY);
    }
    // Stub trace path for the failure diagnostics (owned by this frame, aliased
    // by the global the diagnostics read).
    const stub_log = try harness.harnessPath(gpa, h.temp_dir, &.{"mcp_stub.log"});
    defer gpa.free(stub_log);
    mcp_stub_log_path = stub_log;

    const stub_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1/chat/completions", .{stub.port});
    defer gpa.free(stub_url);

    // 1. Profile → our SSE upstream, plus one stdio MCP server.
    const cfg_body = try std.fmt.allocPrint(gpa,
        \\{{"api_endpoint":"{s}","api_key":"sk-stub-test","model":"stub-model","url_style":"openai","profiles":{{"mcp-snap-stub":{{"model":"stub-model","base_url":"{s}","api_key":"sk-stub-test","url_style":"openai"}}}},"active_profile":"mcp-snap-stub","mcp_servers":{{"stub":{{"command":"{s}","args":["{s}"]}}}}}}
    , .{ stub_url, stub_url, python3, script });
    defer gpa.free(cfg_body);
    {
        var r = try h.http(io, .PUT, "/api/config/pabrik", .{
            .json_body = cfg_body,
            .expect = &.{200},
        });
        defer r.deinit();
    }

    // 2. Session row + the equipped MCP tool, both seeded BEFORE the run: the
    //    tool list is resolved on the first turn.
    const session_id = try std.fmt.allocPrint(gpa, "sess_mcp_snap_{d}", .{
        Io.Timestamp.now(io, .real).toSeconds(),
    });
    defer gpa.free(session_id);

    const db = try dbPath(h.temp_dir);
    defer gpa.free(db);

    const seed_session = try std.fmt.allocPrint(gpa, "INSERT OR IGNORE INTO sessions (id, name, status) VALUES ('{s}', 'mcp snapshot', 'active');", .{session_id});
    defer gpa.free(seed_session);
    try sqliteRun(db, seed_session);

    // The equipped name is the WIRE name: pabrik namespaces MCP tools as
    // `mcp_<server>_<tool>`, and that is what the catalog and the model see.
    const seed_equip = try std.fmt.allocPrint(gpa, "INSERT OR IGNORE INTO session_progressive_tool (session_id, tool_name, server_name, loaded_at_nano) VALUES ('{s}', '{s}', '{s}', 1);", .{ session_id, MCP_WIRE_NAME, MCP_SERVER_NAME });
    defer gpa.free(seed_equip);
    try sqliteRun(db, seed_equip);

    // Read the row back: `INSERT OR IGNORE` swallows a constraint violation
    // silently, and a missing row would make the assertion below pass for the
    // wrong reason (an unseeded equip set fails on EVERY turn, not just the
    {
        const check = try std.fmt.allocPrint(gpa, "SELECT COUNT(*) FROM session_progressive_tool WHERE session_id = '{s}' AND tool_name = '{s}';", .{ session_id, MCP_WIRE_NAME });
        defer gpa.free(check);
        const out = try sqliteRunOut(gpa, db, check);
        defer gpa.free(out);
        if (std.mem.trim(u8, out, " \t\r\n").len == 0 or std.mem.eql(u8, std.mem.trim(u8, out, " \t\r\n"), "0")) {
            std.debug.print("the equip row for `{s}` is not in the DB (seed did not take)\n", .{MCP_WIRE_NAME});
            return error.TestUnexpectedResult;
        }
    }

    // 3. Start the real worker turn.
    const session_body = try std.json.Stringify.valueAlloc(gpa, .{
        .session_id = session_id,
        .queue_message = "keep using the tool",
        .cwd_session = h.temp_dir,
        .allowed_tools = "read_file,used_tools",
        .image_urls = "",
        .selected_profile_model = "mcp-snap-stub",
        .is_auto_retry_until_stop = "",
    }, .{});
    defer gpa.free(session_body);
    {
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = session_body,
            .expect = &.{ 200, 201, 500 },
        });
        defer r.deinit();
    }

    // 4. Wait for the pre-mutation tool turns.
    try waitForToolTurns(&stub, TOOL_TURNS_BEFORE_CLEAR, &h);

    // 5. THE TRIGGER: a config write while the run is live. `PUT
    //    /api/config/pabrik` calls `clearMcpToolsCache()`, so the next turn
    //    takes the in-loop refresh branch.
    {
        var r = try h.http(io, .PUT, "/api/config/pabrik", .{
            .json_body = cfg_body,
            .expect = &.{200},
        });
        defer r.deinit();
    }
    stub.clear_sent.store(true, .release);

    // 6. Let the loop run on past the mutation.
    try waitForToolTurns(&stub, TOOL_TURNS_TOTAL, &h);
    // Give the loop a moment to finish the turn that follows the last tool call
    // (the stub serves text from here) so that request is recorded too.
    Io.sleep(io, .fromMilliseconds(1500), .awake) catch {};

    // ── Assertions ────────────────────────────────────────────────────────
    const log = try readLog(&h);
    defer gpa.free(log);

    if (!h.health(io)) {
        std.debug.print("pabrik died during the run (per-turn MCP snapshot).\n--- log ---\n{s}\n", .{log});
        return error.TestUnexpectedResult;
    }
    for (CRASH_MARKERS) |marker| {
        if (std.mem.indexOf(u8, log, marker) != null) {
            std.debug.print("log contains crash marker `{s}`:\n{s}\n", .{ marker, log });
            return error.TestUnexpectedResult;
        }
    }

    // Positive control 1: the MCP cache really was populated AND refetched
    // after the mutation.
    const resolved_marker = try std.fmt.allocPrint(gpa, "mcp_count={d} ", .{MCP_TOOL_COUNT});
    defer gpa.free(resolved_marker);
    const resolved_hits = countOccurrences(log, resolved_marker);
    if (resolved_hits < 2) {
        std.debug.print(
            "expected >=2 `{s}` checkpoint lines (pre- and post-mutation MCP fetch), found {d}.\n--- log ---\n{s}\n",
            .{ resolved_marker, resolved_hits, log },
        );
        return error.TestUnexpectedResult;
    }

    // Positive control 2: turns really ran after the mutation.
    if (!stub.turn_after_clear.load(.acquire)) {
        std.debug.print(
            "no tool-bearing turn ran after the config mutation, so the refresh path was not exercised.\n--- log ---\n{s}\n",
            .{log},
        );
        return error.TestUnexpectedResult;
    }

    // Positive control 3: the equipped MCP tool WAS in the tool list on a
    // pre-mutation turn.
    if (!stub.turn_before_clear_has_tool.load(.acquire)) {
        std.debug.print(
            "the equipped MCP tool `{s}` never appeared in a pre-mutation tool list, so this run did not exercise the path (check the equip seed + the MCP fetch).\n--- log ---\n{s}\n",
            .{ MCP_WIRE_NAME, log },
        );
        return error.TestUnexpectedResult;
    }

    // THE REGRESSION: the equipped MCP tool must still be in the model's tool
    // list on a turn that ran after the refresh.
    if (!stub.mcp_tool_after_clear.load(.acquire)) {
        std.debug.print(
            "the equipped MCP tool `{s}` is missing from the tool list of every turn after the config mutation — the loop is reading a stale per-turn snapshot.\n--- log ---\n{s}\n",
            .{ MCP_WIRE_NAME, log },
        );
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so a
// stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = Stub.start;
    _ = Stub.shutdown;
    _ = serveStub;
    _ = handleRequest;
    _ = toolCallSse;
    _ = bodyListsTool;
    _ = headerLines;
    _ = headerValue;
    _ = contentLength;
    _ = findOnPath;
    _ = dbPath;
    _ = sqliteRun;
    _ = sqliteRunOut;
    _ = readLog;
    _ = readStubLog;
    _ = countOccurrences;
    _ = waitForToolTurns;
    _ = Harness.boot;
}

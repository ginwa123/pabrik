// ! Functional service-level verification for single-file Lua hooks. Branch:
// ! worktree/hook2312maspodmp2131 (plan
// !).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const builtin = @import("builtin");

/// The shipped example, relative to the repo root.
const EXAMPLE_HOOK_REL = "examples/hooks/register_hook.lua";

/// A hook that denies EVERY `pre_tool_use`. Installed to prove that a
/// hook wrapping tool dispatch cannot reach the non-tool paths.
const DENY_ALL_HOOK =
    \\function init(event, data)
    \\  if event == 'pre_tool_use' then
    \\    return { deny = 'blocked by functional test hook' }
    \\  end
    \\  return nil
    \\end
    \\
;

/// Deliberately unparseable Lua: `function init(((` never closes. The
/// BOOT-SAFE point is that a file the Lua runtime cannot even compile must
/// not stop the SERVICE from serving.
const BROKEN_HOOK = "function init(((\n";

/// Mirror the binary's `getDefaultConfigDir` per OS (see
/// `config_simplify_test.py::_platform_config_dir`).
fn configDir(temp_dir: []const u8) ![]u8 {
    const parts: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "Library", "Application Support", "pabrik" },
        .windows => &.{ "AppData", "Roaming", "pabrik" },
        else => &.{ ".config", "pabrik" },
    };
    return harness.harnessPath(gpa, temp_dir, parts);
}

/// `_hooks_dir` — `<config>/hooks`, created. Owned.
fn hooksDir(temp_dir: []const u8) ![]u8 {
    const cfg = try configDir(temp_dir);
    defer gpa.free(cfg);
    const dir = try std.fs.path.join(gpa, &.{ cfg, "hooks" });
    errdefer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

/// `_write_hook` — `<config>/hooks/register_hook.lua`. Returns its path,
/// owned.
fn writeHook(temp_dir: []const u8, content: []const u8) ![]u8 {
    const dir = try hooksDir(temp_dir);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "register_hook.lua" });
    errdefer gpa.free(path);
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, content);
    return path;
}

/// The header's PATH CONVENTION claim, asserted rather than assumed:
/// the file really does land where the loader looks for it.
fn assertHookPathConvention(temp_dir: []const u8, hook_path: []const u8) !void {
    const cfg = try configDir(temp_dir);
    defer gpa.free(cfg);
    const expected = try std.fs.path.join(gpa, &.{ cfg, "hooks", "register_hook.lua" });
    defer gpa.free(expected);
    if (!std.mem.eql(u8, expected, hook_path)) {
        std.debug.print(
            "hook was written to {s}, expected {s} (the loader's path)\n",
            .{ hook_path, expected },
        );
        return error.TestUnexpectedResult;
    }
}

/// `_service_healthy` — `/health` says ok AND the tool registry has at
/// least one tool.
fn serviceHealthy(h: *Harness) !void {
    if (!h.health(io)) {
        const tail = try h.tailLog(io, gpa, 30);
        defer gpa.free(tail);
        std.debug.print("service unhealthy:\n{s}\n", .{tail});
        return error.TestUnexpectedResult;
    }
    var r = try h.http(io, .GET, "/api/agent-tools/registry", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const tools = doc.array("tools") orelse {
        std.debug.print("registry has no `tools` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (tools.items.len < 1) {
        std.debug.print("registry returned 0 tools — fixture broken?\n", .{});
        return error.TestUnexpectedResult;
    }
}

/// Render `s` as a Lua SHORT-STRING literal (double-quoted), for
/// embedding a filesystem path in the `-e` driver below.
fn luaString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    out.writer.writeByte('"') catch return error.OutOfMemory;
    for (s) |c| switch (c) {
        '\\' => out.writer.writeAll("\\\\") catch return error.OutOfMemory,
        '"' => out.writer.writeAll("\\\"") catch return error.OutOfMemory,
        '\n' => out.writer.writeAll("\\n") catch return error.OutOfMemory,
        '\r' => out.writer.writeAll("\\r") catch return error.OutOfMemory,
        '\t' => out.writer.writeAll("\\t") catch return error.OutOfMemory,
        else => out.writer.writeByte(c) catch return error.OutOfMemory,
    };
    out.writer.writeByte('"') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Absolute path of a repo-root-relative file. Owned.
fn repoFileAbs(rel: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(io, rel, &buf) catch |err| switch (err) {
        error.FileNotFound, error.NameTooLong => {
            std.debug.print("example missing: {s}\n", .{rel});
            return error.TestUnexpectedResult;
        },
        else => return err,
    };
    return gpa.dupe(u8, buf[0..n]);
}

/// Exit code of a finished child, or null if a signal stopped it.
fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// `shutil.which("lua5.4") or shutil.which("lua")`, or null.
fn whichLua() ?[]const u8 {
    for ([_][]const u8{ "lua5.4", "lua" }) |name| {
        const res = std.process.run(gpa, io, .{ .argv = &.{ name, "-v" } }) catch continue;
        gpa.free(res.stdout);
        gpa.free(res.stderr);
        return name;
    }
    return null;
}

// A valid hook file must not disturb boot or the tool registry.
test "service_healthy_with_valid_hook" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const p = try writeHook(h.temp_dir, DENY_ALL_HOOK);
    defer gpa.free(p);
    try assertHookPathConvention(h.temp_dir, p);

    try serviceHealthy(&h);
}

// A syntactically broken hook must fail open, never break serving.
test "service_healthy_with_broken_hook" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const p = try writeHook(h.temp_dir, BROKEN_HOOK);
    defer gpa.free(p);

    try serviceHealthy(&h);
}

// Baseline: no hooks dir at all serves normally.
test "service_healthy_without_hook" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try serviceHealthy(&h);
}

// Deny-all hook installed, but workspace/agent creation (which runs
// no tools) must still succeed — hooks wrap dispatch only.
test "non_tool_paths_unaffected_by_deny_all_hook" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const p = try writeHook(h.temp_dir, DENY_ALL_HOOK);
    defer gpa.free(p);

    var ws_r = try h.http(io, .POST, "/api/workspaces", .{
        .json_body = "{\"name\":\"hook-ws\"}",
        .expect = &.{201},
    });
    defer ws_r.deinit();
    var ws_doc = try ws_r.json();
    defer ws_doc.deinit();
    const ws_id = ws_doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{ws_r.body});
        return error.TestUnexpectedResult;
    };

    // The agent's `path`.
    const agent_path = try harness.harnessPath(gpa, h.temp_dir, &.{"hook-test"});
    defer gpa.free(agent_path);

    const agent_url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/agent", .{ws_id});
    defer gpa.free(agent_url);
    const agent_body = try std.fmt.allocPrint(gpa,
        \\{{"name":"hook-agent","path":"{s}"}}
    , .{agent_path});
    defer gpa.free(agent_body);

    var r = try h.http(io, .POST, agent_url, .{
        .json_body = agent_body,
        .expect = &.{201},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    // Python: `assert body.get("item") is not None`.
    if (doc.object("item") == null) {
        std.debug.print("missing 'item' envelope: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// The shipped example must parse. Needs a system lua; skipped without.
test "example_hook_is_valid_lua" {
    // Python asserted the file exists BEFORE looking for an
    // interpreter: a missing example is a repo regression, not a
    // reason to skip.
    const hook = try repoFileAbs(EXAMPLE_HOOK_REL);
    defer gpa.free(hook);

    const lua = whichLua() orelse {
        std.debug.print("no system lua available\n", .{});
        return error.SkipZigTest;
    };

    const src = try std.Io.Dir.cwd().readFileAlloc(io, hook, gpa, .limited(1 << 20));
    defer gpa.free(src);
    if (std.mem.indexOf(u8, src, "function init(event, data)") == null) {
        std.debug.print("example must define init(event, data)\n", .{});
        return error.TestUnexpectedResult;
    }

    const hook_lit = try luaString(gpa, hook);
    defer gpa.free(hook_lit);
    const driver = try std.fmt.allocPrint(gpa, "assert(loadfile({s}))", .{hook_lit});
    defer gpa.free(driver);

    const res = try std.process.run(gpa, io, .{
        .argv = &.{ lua, "-e", driver },
        // Python: `timeout=15`.
        .timeout = .{ .duration = .{
            .raw = .{ .nanoseconds = 15 * std.time.ns_per_ms },
            .clock = .awake,
        } },
    });
    const code = exitCode(res.term);
    if (code == null or code.? != 0) {
        std.debug.print("example failed to parse (rc={?}): {s}\n", .{ code, res.stderr });
    }
    gpa.free(res.stdout);
    gpa.free(res.stderr);
    if (code == null or code.? != 0) return error.TestUnexpectedResult;
}

// ============================================================================
// Lifecycle events, end to end: a real server, a real turn, a real hook.
// ============================================================================

const LIFECYCLE_SESSION_ID = "sess_hook_lifecycle_1";

/// An OpenAI-compatible upstream that always answers with a plain `stop`.
/// Enough to make the loop reach `finish_reason` and end the turn.
const Stub = struct {
    port: u16,
    server: std.Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),

    fn start(stub: *Stub) !void {
        stub.* = .{ .port = 0, .server = undefined, .thread = undefined };
        stub.port = try harness.findFreePortRandom(gpa);
        const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
        stub.server = try addr.listen(io, .{ .reuse_address = true });
        errdefer stub.server.deinit(io);
        stub.thread = try std.Thread.spawn(.{}, serve, .{stub});
    }

    fn deinit(self: *Stub) void {
        self.stop.store(true, .release);
        const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (addr.connect(io, .{ .mode = .stream })) |conn| {
            var c = conn;
            c.close(io);
        } else |_| {}
        self.thread.join();
        self.server.deinit(io);
    }
};

fn serve(stub: *Stub) void {
    while (!stub.stop.load(.acquire)) {
        var stream = stub.server.accept(io) catch break;
        defer stream.close(io);
        if (stub.stop.load(.acquire)) break;
        answer(stream) catch {};
    }
}

fn answer(stream: std.Io.net.Stream) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const r = &sr.interface;

    var head: std.Io.Writer.Allocating = .init(gpa);
    defer head.deinit();
    var head_len: usize = 0;
    while (head_len == 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        head.writer.writeAll(b) catch break;
        r.toss(b.len);
        if (head.written().len > (1 << 18)) break;
        if (std.mem.indexOf(u8, head.written(), "\r\n\r\n")) |i| head_len = i + 4;
    }
    if (head_len == 0) return;

    var remaining = contentLength(head.written()[0..head_len]);
    if (head.written().len > head_len) remaining -|= head.written().len - head_len;
    while (remaining > 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        const take = @min(b.len, remaining);
        r.toss(take);
        remaining -= take;
    }

    const payload = try textSse("hook probe done");
    defer gpa.free(payload);
    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{payload.len},
    );
    defer gpa.free(response);

    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    try sw.interface.writeAll(response);
    try sw.interface.writeAll(payload);
    try sw.interface.flush();
}

fn contentLength(head: []const u8) usize {
    const needle = "content-length:";
    var i: usize = 0;
    while (i + needle.len <= head.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(head[i .. i + needle.len], needle)) continue;
        var j = i + needle.len;
        while (j < head.len and (head[j] == ' ' or head[j] == '\t')) j += 1;
        var end = j;
        while (end < head.len and head[end] >= '0' and head[end] <= '9') end += 1;
        return std.fmt.parseInt(usize, head[j..end], 10) catch 0;
    }
    return 0;
}

fn textSse(text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "data: {{\"id\":\"chatcmpl-hook\",\"object\":\"chat.completion.chunk\",\"model\":\"stub-model\",\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":\"{s}\"}},\"finish_reason\":null}}]}}\n\n" ++
            "data: {{\"id\":\"chatcmpl-hook\",\"object\":\"chat.completion.chunk\",\"model\":\"stub-model\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\n" ++
            "data: [DONE]\n\n",
        .{text},
    );
}

fn useStubProfile(h: *Harness, stub_port: u16, profile: []const u8) !void {
    const stub_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1/chat/completions", .{stub_port});
    defer gpa.free(stub_url);
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"api_endpoint\":\"{s}\",\"api_key\":\"sk-stub-test\",\"model\":\"stub-model\",\"url_style\":\"openai\"," ++
            "\"profiles\":{{\"{s}\":{{\"model\":\"stub-model\",\"base_url\":\"{s}\",\"api_key\":\"sk-stub-test\",\"url_style\":\"openai\"}}}}," ++
            "\"active_profile\":\"{s}\"}}",
        .{ stub_url, profile, stub_url, profile },
    );
    defer gpa.free(body);

    var r = try h.http(io, .PUT, "/api/config/pabrik", .{
        .json_body = body,
        .expect = &.{200},
    });
    defer r.deinit();
}

fn sendTurn(h: *Harness, message: []const u8, profile: []const u8) !void {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"session_id\":\"{s}\",\"queue_message\":\"{s}\",\"cwd_session\":\"{s}\"," ++
            "\"allowed_tools\":\"\",\"image_urls\":\"\",\"selected_profile_model\":\"{s}\"," ++
            "\"is_auto_retry_until_stop\":\"\"}}",
        .{ LIFECYCLE_SESSION_ID, message, h.temp_dir, profile },
    );
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/llm/session", .{
        .json_body = body,
        .expect = &.{ 200, 201, 500 },
        .timeout_s = 30.0,
    });
    defer r.deinit();
}

/// Poll the hook's own log until `session_end` lands, or the deadline passes.
/// The hook writes that line from the run's `defer`, so its presence IS the
/// "the run finished" signal — no database needed.
fn waitForSessionEnd(log_path: []const u8, timeout_ms: i64) ![]u8 {
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + timeout_ms;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        const text = std.Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => {
                std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
                continue;
            },
            else => return err,
        };
        if (std.mem.indexOf(u8, text, "session_end:") != null) return text;
        gpa.free(text);
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

fn assertLifecycleLines(text: []const u8) !void {
    const start_at = std.mem.indexOf(u8, text, "session_start") orelse {
        std.debug.print("no session_start line in hook log:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    };
    const reason_at = std.mem.indexOf(u8, text, "finish_reason:stop") orelse {
        std.debug.print("no finish_reason:stop line in hook log:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    };
    const end_at = std.mem.indexOf(u8, text, "session_end:stop") orelse {
        std.debug.print("no session_end:stop line in hook log:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    };
    if (!(start_at < reason_at and reason_at < end_at)) {
        std.debug.print("lifecycle events out of order:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
}

fn writePythonHook(temp_dir: []const u8, content: []const u8) ![]u8 {
    const dir = try hooksDir(temp_dir);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "register_hook.py" });
    errdefer gpa.free(path);
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, content);
    return path;
}

fn pyString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    out.writer.writeByte('"') catch return error.OutOfMemory;
    for (s) |c| switch (c) {
        '\\' => out.writer.writeAll("\\\\") catch return error.OutOfMemory,
        '"' => out.writer.writeAll("\\\"") catch return error.OutOfMemory,
        '\n' => out.writer.writeAll("\\n") catch return error.OutOfMemory,
        else => out.writer.writeByte(c) catch return error.OutOfMemory,
    };
    out.writer.writeByte('"') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn lifecycleLogPath(temp_dir: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ temp_dir, "hook-events.log" });
}

test "lifecycle: a lua hook sees session_start, finish_reason and session_end in order" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var stub: Stub = undefined;
    try stub.start();
    defer stub.deinit();

    const log_path = try lifecycleLogPath(h.temp_dir);
    defer gpa.free(log_path);
    const log_lit = try luaString(gpa, log_path);
    defer gpa.free(log_lit);
    const source = try std.fmt.allocPrint(gpa,
        \\local log = {s}
        \\local function w(line)
        \\  local f = io.open(log, "a")
        \\  if f then f:write(line .. "\n") f:close() end
        \\end
        \\function init(event, data)
        \\  if event == "session_start" then w("session_start") end
        \\  if event == "finish_reason" then w("finish_reason:" .. data.finish_reason) end
        \\  if event == "session_end" then w("session_end:" .. data.end_reason) end
        \\  return nil
        \\end
        \\
    , .{log_lit});
    defer gpa.free(source);

    const hook_path = try writeHook(h.temp_dir, source);
    defer gpa.free(hook_path);

    const profile = "hook-lifecycle-lua";
    try useStubProfile(&h, stub.port, profile);
    try sendTurn(&h, "say something", profile);

    const text = try waitForSessionEnd(log_path, 60_000);
    defer gpa.free(text);
    try assertLifecycleLines(text);
}

test "lifecycle: a python hook sees the same three events in the same order" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var stub: Stub = undefined;
    try stub.start();
    defer stub.deinit();

    const log_path = try lifecycleLogPath(h.temp_dir);
    defer gpa.free(log_path);
    const log_lit = try pyString(gpa, log_path);
    defer gpa.free(log_lit);
    const source = try std.fmt.allocPrint(gpa,
        \\LOG = {s}
        \\
        \\def _w(line):
        \\    with open(LOG, "a") as f:
        \\        f.write(line + "\n")
        \\
        \\def init(event, data):
        \\    if event == "session_start":
        \\        _w("session_start")
        \\    elif event == "finish_reason":
        \\        _w("finish_reason:" + data["finish_reason"])
        \\    elif event == "session_end":
        \\        _w("session_end:" + data["end_reason"])
        \\    return None
        \\
    , .{log_lit});
    defer gpa.free(source);

    const hook_path = try writePythonHook(h.temp_dir, source);
    defer gpa.free(hook_path);

    const profile = "hook-lifecycle-py";
    try useStubProfile(&h, stub.port, profile);
    try sendTurn(&h, "say something", profile);

    const text = try waitForSessionEnd(log_path, 60_000);
    defer gpa.free(text);
    try assertLifecycleLines(text);
}

comptime {
    // Body-analysis barrier: an unreferenced function is never
    // type-checked, so a stdlib rename inside one would stay invisible
    // until some caller appeared.
    _ = configDir;
    _ = hooksDir;
    _ = writeHook;
    _ = assertHookPathConvention;
    _ = serviceHealthy;
    _ = luaString;
    _ = repoFileAbs;
    _ = exitCode;
    _ = whichLua;
    _ = Stub;
    _ = serve;
    _ = answer;
    _ = contentLength;
    _ = textSse;
    _ = useStubProfile;
    _ = sendTurn;
    _ = waitForSessionEnd;
    _ = assertLifecycleLines;
    _ = writePythonHook;
    _ = pyString;
    _ = lifecycleLogPath;
}

//! Python hooks: the same `init(event, data)` contract as the Lua hooks, run
//! in a child interpreter with the payload as JSON on stdin.

const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("helpers");
const pabrik = @import("pabrikcore");

const Logger = pabrik.loggermod.Logger;

pub const HOOK_PY_TIMEOUT_MS: u32 = 5000;

/// Tried in order when neither the workspace setting nor the environment
/// names an interpreter. `py` is the Windows launcher; the other two cover
/// POSIX and macOS.
pub const CANDIDATES = [_][]const u8{ "python", "python3", "py" };

const PY3_PROBE = "import sys;sys.exit(0 if sys.version_info[0]==3 else 1)";

/// `python3 -c <this> <hook_file> <event>`: import the hook file, call
/// `init(event, data)`, print the returned dict as JSON. A dict-valued
/// `arguments` is serialized so both languages hand back the same shape.
const BOOTSTRAP =
    \\import json,sys,importlib.util
    \\path,event=sys.argv[1],sys.argv[2]
    \\data=json.load(sys.stdin)
    \\spec=importlib.util.spec_from_file_location("pabrik_hook",path)
    \\mod=importlib.util.module_from_spec(spec)
    \\spec.loader.exec_module(mod)
    \\fn=getattr(mod,"init",None)
    \\result=fn(event,data) if fn else None
    \\if isinstance(result,dict):
    \\    if isinstance(result.get("arguments"),dict):
    \\        result["arguments"]=json.dumps(result["arguments"])
    \\    json.dump(result,sys.stdout)
;

var warned_missing_interpreter = std.atomic.Value(bool).init(false);

fn warnMissingInterpreterOnce(logger: *Logger, interpreter: []const u8) void {
    if (warned_missing_interpreter.swap(true, .monotonic)) return;
    logger.warnFmt(
        "[hooks] no Python 3 interpreter found (tried {s}) — .py hooks are skipped. Set hook_python_bin in settings or PABRIK_HOOK_PYTHON.",
        .{interpreter},
    );
}

fn defaultName() []const u8 {
    return if (builtin.os.tag == .windows) "python" else "python3";
}

pub fn isPython3(io: std.Io, name: []const u8) bool {
    var res = helpers.run_captured.run(std.heap.page_allocator, io, &.{ name, "-c", PY3_PROBE }, .{
        .timeout_ms = 10_000,
    }) catch return false;
    defer res.deinit(std.heap.page_allocator);
    return switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// The scan result is a process-lifetime cache: probing costs one spawn per
/// candidate, and a hook event already costs one spawn. A settings change
/// takes effect on the next boot.
var cached_interpreter: ?[]const u8 = null;
var cache_lock: std.Io.Mutex = .init;

fn scanForPython3(io: std.Io) ![]const u8 {
    cache_lock.lockUncancelable(io);
    defer cache_lock.unlock(io);
    if (cached_interpreter) |cached| return cached;

    for (CANDIDATES) |name| {
        if (!isPython3(io, name)) continue;
        const owned = try std.heap.page_allocator.dupe(u8, name);
        cached_interpreter = owned;
        return owned;
    }
    const fallback = try std.heap.page_allocator.dupe(u8, defaultName());
    cached_interpreter = fallback;
    return fallback;
}

/// `configured` (the workspace setting) wins, then `PABRIK_HOOK_PYTHON`, then
/// the first of `python`, `python3`, `py` that is a Python 3. Caller frees.
pub fn resolveInterpreter(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
    configured: []const u8,
) ![]u8 {
    if (configured.len > 0) return allocator.dupe(u8, configured);
    if (environment) |env| {
        if (env.get("PABRIK_HOOK_PYTHON")) |value| {
            if (value.len > 0) return allocator.dupe(u8, value);
        }
    }
    return allocator.dupe(u8, try scanForPython3(io));
}

/// Run one Python hook. Returns the hook's JSON return value (caller frees),
/// or null when the hook produced nothing usable. Every failure mode — no
/// interpreter, non-zero exit, timeout, empty stdout — is a null, never an
/// error: a broken hook must not break the run.
pub fn runPythonHook(
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: *Logger,
    environment: ?*const std.process.Environ.Map,
    configured_interpreter: []const u8,
    hook_file: []const u8,
    event: []const u8,
    data_json: []const u8,
) !?[]u8 {
    const interpreter = try resolveInterpreter(allocator, io, environment, configured_interpreter);
    defer allocator.free(interpreter);

    const argv = [_][]const u8{ interpreter, "-c", BOOTSTRAP, hook_file, event };
    var res = helpers.run_captured.run(allocator, io, &argv, .{
        .stdin_data = data_json,
        .timeout_ms = HOOK_PY_TIMEOUT_MS,
        .kill_process_group = true,
    }) catch |err| {
        if (err == error.FileNotFound) {
            warnMissingInterpreterOnce(logger, interpreter);
        } else {
            logger.warnFmt(
                "[hooks] python hook {s} could not start with '{s}': {s}",
                .{ hook_file, interpreter, @errorName(err) },
            );
        }
        return null;
    };
    defer res.deinit(allocator);

    if (res.timed_out) {
        logger.warnFmt(
            "[hooks] python hook {s} timed out after {d}ms",
            .{ hook_file, HOOK_PY_TIMEOUT_MS },
        );
        return null;
    }

    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                logger.warnFmt(
                    "[hooks] python hook {s} exited {d}: {s}",
                    .{ hook_file, code, std.mem.trim(u8, res.stderr, " \r\n\t") },
                );
                return null;
            }
        },
        else => {
            logger.warnFmt("[hooks] python hook {s} was killed before it finished", .{hook_file});
            return null;
        },
    }

    const out = std.mem.trim(u8, res.stdout, " \r\n\t");
    if (out.len == 0) return null;
    return try allocator.dupe(u8, out);
}

const testing = std.testing;

fn testLogger(allocator: std.mem.Allocator) Logger {
    return Logger.init(allocator, testing.io, .{});
}

fn writeHook(dir: std.Io.Dir, io: std.Io, name: []const u8, content: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = name, .data = content });
}

fn hookPath(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, name: []const u8) ![]u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(io, &path_buf);
    return try std.fs.path.join(allocator, &.{ path_buf[0..n], name });
}

fn interpreterAvailable(allocator: std.mem.Allocator) bool {
    const py = resolveInterpreter(allocator, testing.io, null, "") catch return false;
    defer allocator.free(py);
    return isPython3(testing.io, py);
}

test "python hook: a dict return reaches the caller as JSON" {
    const allocator = testing.allocator;
    if (!interpreterAvailable(allocator)) return error.SkipZigTest;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHook(tmp.dir, testing.io, "deny.py",
        \\def init(event, data):
        \\    return {"deny": "no bash for you"}
        \\
    );
    const path = try hookPath(allocator, tmp.dir, testing.io, "deny.py");
    defer allocator.free(path);

    const out = try runPythonHook(allocator, testing.io, &lg, null, "", path, "pre_tool_use", "{\"tool_name\":\"bash\"}");
    defer if (out) |o| allocator.free(o);
    try testing.expect(out != null);
    try testing.expect(std.mem.indexOf(u8, out.?, "no bash for you") != null);
}

test "python hook: the event and data reach init" {
    const allocator = testing.allocator;
    if (!interpreterAvailable(allocator)) return error.SkipZigTest;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHook(tmp.dir, testing.io, "echo.py",
        \\def init(event, data):
        \\    return {"output": event + ":" + data["tool_name"]}
        \\
    );
    const path = try hookPath(allocator, tmp.dir, testing.io, "echo.py");
    defer allocator.free(path);

    const out = try runPythonHook(allocator, testing.io, &lg, null, "", path, "post_tool_use", "{\"tool_name\":\"read_file\"}");
    defer if (out) |o| allocator.free(o);
    try testing.expect(out != null);
    try testing.expect(std.mem.indexOf(u8, out.?, "post_tool_use:read_file") != null);
}

test "python hook: a dict-valued arguments field is serialized to a JSON string" {
    const allocator = testing.allocator;
    if (!interpreterAvailable(allocator)) return error.SkipZigTest;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHook(tmp.dir, testing.io, "args.py",
        \\def init(event, data):
        \\    return {"arguments": {"command": "echo hi"}}
        \\
    );
    const path = try hookPath(allocator, tmp.dir, testing.io, "args.py");
    defer allocator.free(path);

    const out = try runPythonHook(allocator, testing.io, &lg, null, "", path, "pre_tool_use", "{}");
    defer if (out) |o| allocator.free(o);
    try testing.expect(out != null);
    try testing.expect(std.mem.indexOf(u8, out.?, "\\\"command\\\": \\\"echo hi\\\"") != null);
}

test "python hook: a file without init returns nothing" {
    const allocator = testing.allocator;
    if (!interpreterAvailable(allocator)) return error.SkipZigTest;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHook(tmp.dir, testing.io, "no_init.py", "x = 1\n");
    const path = try hookPath(allocator, tmp.dir, testing.io, "no_init.py");
    defer allocator.free(path);

    const out = try runPythonHook(allocator, testing.io, &lg, null, "", path, "pre_tool_use", "{}");
    try testing.expect(out == null);
}

test "python hook: a syntax error returns nothing instead of failing the run" {
    const allocator = testing.allocator;
    if (!interpreterAvailable(allocator)) return error.SkipZigTest;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHook(tmp.dir, testing.io, "broken.py", "def init(((\n");
    const path = try hookPath(allocator, tmp.dir, testing.io, "broken.py");
    defer allocator.free(path);

    const out = try runPythonHook(allocator, testing.io, &lg, null, "", path, "pre_tool_use", "{}");
    try testing.expect(out == null);
}

test "python hook: a missing interpreter returns nothing instead of failing the run" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PABRIK_HOOK_PYTHON", "/nonexistent/pabrik-python-that-is-not-there");

    const out = try runPythonHook(allocator, testing.io, &lg, &env_map, "", "/tmp/whatever.py", "pre_tool_use", "{}");
    try testing.expect(out == null);
}

test "python hook: the workspace setting wins over the environment" {
    const allocator = testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PABRIK_HOOK_PYTHON", "/from/the/environment");

    const resolved = try resolveInterpreter(allocator, testing.io, &env_map, "/from/the/settings");
    defer allocator.free(resolved);
    try testing.expectEqualStrings("/from/the/settings", resolved);
}

test "python hook: the environment wins over the scan" {
    const allocator = testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PABRIK_HOOK_PYTHON", "/from/the/environment");

    const resolved = try resolveInterpreter(allocator, testing.io, &env_map, "");
    defer allocator.free(resolved);
    try testing.expectEqualStrings("/from/the/environment", resolved);
}

test "python hook: with no setting and no environment the scan finds a Python 3" {
    const allocator = testing.allocator;
    if (!interpreterAvailable(allocator)) return error.SkipZigTest;

    const resolved = try resolveInterpreter(allocator, testing.io, null, "");
    defer allocator.free(resolved);
    try testing.expect(isPython3(testing.io, resolved));
}

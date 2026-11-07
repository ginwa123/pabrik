//! Lua hooks: global + per-project single-file hooks.

const std = @import("std");
const pabrik = @import("pabrikcore");
const helpers = @import("helpers");

const logger_mod = pabrik.loggermod;
const config_mod = pabrik.config;
const lua = @import("lua_bindings.zig");

const Logger = logger_mod.Logger;

pub const HOOK_FILENAME = "register_hook.lua";
pub const PRE_EVENT = "pre_tool_use";
pub const POST_EVENT = "post_tool_use";

pub const PreResult = union(enum) {
    allow,
    deny: []const u8,
    modify: []const u8,
    mock: []const u8,

    pub fn deinit(self: PreResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .allow => {},
            .deny => |s| allocator.free(s),
            .modify => |s| allocator.free(s),
            .mock => |s| allocator.free(s),
        }
    }
};

pub const PostResult = union(enum) {
    keep,
    replace: []const u8,
    deny: []const u8,

    pub fn deinit(self: PostResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .keep => {},
            .replace => |s| allocator.free(s),
            .deny => |s| allocator.free(s),
        }
    }
};

/// Extra hook context passed inside every `data` table.
pub const HookContext = struct {
    session_id: []const u8 = "",
    cwd: []const u8 = "",
    model: []const u8 = "",
};

/// Resolve `<config_dir>/hooks` (caller frees). Returns null when there is
/// no environment to read a home directory from.
pub fn getHooksDir(allocator: std.mem.Allocator, environment: ?*const std.process.Environ.Map) !?[]u8 {
    const env = environment orelse return null;
    const config_dir = try config_mod.getDefaultConfigDir(allocator, @constCast(env));
    defer allocator.free(config_dir);
    return try std.fs.path.join(allocator, &.{ config_dir, "hooks" });
}

/// Resolve the global hook file path (caller frees). Returns null when
/// there is no environment or the file does not exist. Never errors on
/// a missing file — absence is normal.
pub fn resolveHookFile(allocator: std.mem.Allocator, environment: ?*const std.process.Environ.Map) !?[]u8 {
    const hooks_dir = try getHooksDir(allocator, environment) orelse return null;
    defer allocator.free(hooks_dir);
    const full = try std.fs.path.join(allocator, &.{ hooks_dir, HOOK_FILENAME });
    errdefer allocator.free(full);
    if (!helpers.fileExists(full)) {
        allocator.free(full);
        return null;
    }
    return full;
}

/// Resolve the per-project hook file `<cwd>/.pabrik/hooks/register_hook.lua`
/// (caller frees). Returns null when cwd is empty or the file does not
/// exist. No directory walk: the path is exact and predictable.
pub fn resolveProjectHookFile(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    if (cwd.len == 0) return null;
    const full = try std.fs.path.join(allocator, &.{ cwd, ".pabrik", "hooks", HOOK_FILENAME });
    errdefer allocator.free(full);
    if (!helpers.fileExists(full)) {
        allocator.free(full);
        return null;
    }
    return full;
}

/// Run the pre-tool hooks: global first, then project (which sees the global
/// hook's modifications). First `deny` or `mock` stops the chain.
pub fn runPreHook(
    allocator: std.mem.Allocator,
    logger: *Logger,
    environment: ?*const std.process.Environ.Map,
    tool_name: []const u8,
    arguments: []const u8,
    ctx: HookContext,
) !PreResult {
    var cur_args: []const u8 = arguments;
    var owned_args: ?[]u8 = null;
    defer if (owned_args) |o| allocator.free(o);

    const files: [2]?[]u8 = .{
        resolveHookFile(allocator, environment) catch |err| blk: {
            logger.warnFmt("[hooks] global resolve failed, skipping: {s}", .{@errorName(err)});
            break :blk null;
        },
        resolveProjectHookFile(allocator, ctx.cwd) catch |err| blk: {
            logger.warnFmt("[hooks] project resolve failed, skipping: {s}", .{@errorName(err)});
            break :blk null;
        },
    };
    defer {
        for (files) |f| if (f) |p| allocator.free(p);
    }

    for (files) |hook_file_opt| {
        const hook_file = hook_file_opt orelse continue;
        const r = callPreHook(allocator, logger, hook_file, tool_name, cur_args, ctx) catch |err| {
            logger.debugFmt("[hooks] pre hook {s} failed open: {s}", .{ hook_file, @errorName(err) });
            continue;
        };
        switch (r) {
            .allow => {},
            .deny => |reason| return .{ .deny = reason },
            .modify => |new_args| {
                if (owned_args) |o| allocator.free(o);
                owned_args = @constCast(new_args);
                cur_args = new_args;
            },
            .mock => |out| return .{ .mock = out },
        }
    }

    if (owned_args) |o| {
        owned_args = null;
        return .{ .modify = o };
    }
    return .allow;
}

/// Run the post-tool hooks: same global-then-project chain as `runPreHook`.
/// First `deny` stops the chain; `replace` outputs chain forward.
pub fn runPostHook(
    allocator: std.mem.Allocator,
    logger: *Logger,
    environment: ?*const std.process.Environ.Map,
    tool_name: []const u8,
    arguments: []const u8,
    output: []const u8,
    ctx: HookContext,
) !PostResult {
    var cur_output: []const u8 = output;
    var owned_output: ?[]u8 = null;
    defer if (owned_output) |o| allocator.free(o);

    const files: [2]?[]u8 = .{
        resolveHookFile(allocator, environment) catch |err| blk: {
            logger.warnFmt("[hooks] global resolve failed, skipping: {s}", .{@errorName(err)});
            break :blk null;
        },
        resolveProjectHookFile(allocator, ctx.cwd) catch |err| blk: {
            logger.warnFmt("[hooks] project resolve failed, skipping: {s}", .{@errorName(err)});
            break :blk null;
        },
    };
    defer {
        for (files) |f| if (f) |p| allocator.free(p);
    }

    for (files) |hook_file_opt| {
        const hook_file = hook_file_opt orelse continue;
        const r = callPostHook(allocator, logger, hook_file, tool_name, arguments, cur_output, ctx) catch |err| {
            logger.debugFmt("[hooks] post hook {s} failed open: {s}", .{ hook_file, @errorName(err) });
            continue;
        };
        switch (r) {
            .keep => {},
            .deny => |reason| return .{ .deny = reason },
            .replace => |new_output| {
                if (owned_output) |o| allocator.free(o);
                owned_output = @constCast(new_output);
                cur_output = new_output;
            },
        }
    }

    if (owned_output) |o| {
        owned_output = null;
        return .{ .replace = o };
    }
    return .keep;
}

/// Load `hook_file`, call `init("pre_tool_use", data)`, parse the return.
/// Errors (load/run/init failures) propagate to `runPreHook`, which maps
/// them to `.allow`. A missing `init` function is NOT an error.
fn callPreHook(
    allocator: std.mem.Allocator,
    logger: *Logger,
    hook_file: []const u8,
    tool_name: []const u8,
    arguments: []const u8,
    ctx: HookContext,
) !PreResult {
    const L = lua.luaL_newstate() orelse return error.HookNoState;
    defer lua.lua_close(L);
    lua.luaL_openlibs(L);

    try loadHookFile(allocator, logger, L, hook_file);
    if (!pushInitFn(L)) return .allow;

    _ = lua.lua_pushstring(L, PRE_EVENT);
    try pushDataTable(L, allocator, tool_name, arguments, null, ctx);
    if (lua.lua_pcallk(L, 2, 1, 0, 0, null) != lua.LUA_OK) {
        logLuaError(logger, L, hook_file, "init(pre_tool_use)");
        return error.HookInitFailed;
    }
    defer lua.lua_settop(L, 0);
    return parsePreReturn(allocator, logger, L);
}

/// Same as `callPreHook` for the `"post_tool_use"` event.
fn callPostHook(
    allocator: std.mem.Allocator,
    logger: *Logger,
    hook_file: []const u8,
    tool_name: []const u8,
    arguments: []const u8,
    output: []const u8,
    ctx: HookContext,
) !PostResult {
    const L = lua.luaL_newstate() orelse return error.HookNoState;
    defer lua.lua_close(L);
    lua.luaL_openlibs(L);

    try loadHookFile(allocator, logger, L, hook_file);
    if (!pushInitFn(L)) return .keep;

    _ = lua.lua_pushstring(L, POST_EVENT);
    try pushDataTable(L, allocator, tool_name, arguments, output, ctx);
    if (lua.lua_pcallk(L, 2, 1, 0, 0, null) != lua.LUA_OK) {
        logLuaError(logger, L, hook_file, "init(post_tool_use)");
        return error.HookInitFailed;
    }
    defer lua.lua_settop(L, 0);
    return parsePostReturn(allocator, logger, L);
}

/// `luaL_loadfilex` + `pcall` the chunk so its globals (incl. `init`)
/// exist. Logs the Lua message and errors on any failure.
fn loadHookFile(allocator: std.mem.Allocator, logger: *Logger, L: ?*lua.LuaState, hook_file: []const u8) !void {
    const zpath = try allocator.dupeZ(u8, hook_file);
    defer allocator.free(zpath);
    if (lua.luaL_loadfilex(L, zpath, null) != lua.LUA_OK) {
        logLuaError(logger, L, hook_file, "load");
        return error.HookLoadFailed;
    }
    if (lua.lua_pcallk(L, 0, 0, 0, 0, null) != lua.LUA_OK) {
        logLuaError(logger, L, hook_file, "run");
        return error.HookRunFailed;
    }
}

/// Push the global `init` onto the stack. Returns false (leaving a clean
/// stack) when it doesn't exist or isn't a function.
fn pushInitFn(L: ?*lua.LuaState) bool {
    _ = lua.lua_getglobal(L, "init");
    if (lua.lua_type(L, -1) != lua.LUA_TFUNCTION) {
        lua.lua_settop(L, 0);
        return false;
    }
    return true;
}

/// Push the `data` table for one hook call. Stack: [..., fn, event] →
/// [..., fn, event, table]. `output` is present for post hooks only.
fn pushDataTable(
    L: ?*lua.LuaState,
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    arguments: []const u8,
    output: ?[]const u8,
    ctx: HookContext,
) !void {
    lua.lua_createtable(L, 0, 6);
    try pushField(L, allocator, "tool_name", tool_name);
    try pushField(L, allocator, "arguments", arguments);
    if (output) |o| try pushField(L, allocator, "output", o);
    try pushField(L, allocator, "session_id", ctx.session_id);
    try pushField(L, allocator, "cwd", ctx.cwd);
    try pushField(L, allocator, "model", ctx.model);
}

fn pushField(L: ?*lua.LuaState, allocator: std.mem.Allocator, key: [*:0]const u8, value: []const u8) !void {
    const z = try allocator.dupeZ(u8, value);
    defer allocator.free(z);
    _ = lua.lua_pushstring(L, z);
    lua.lua_setfield(L, -2, key);
}

/// Parse the `init` return value at the stack top. Priority: deny, then
/// arguments (must be valid JSON), then output. Anything else is `.allow`.
fn parsePreReturn(allocator: std.mem.Allocator, logger: *Logger, L: ?*lua.LuaState) !PreResult {
    const t = lua.lua_type(L, -1);
    if (t == lua.LUA_TNIL or t == lua.LUA_TNONE) return .allow;
    if (t != lua.LUA_TTABLE) {
        logger.warnFmt("[hooks] pre init returned non-table, ignoring", .{});
        return .allow;
    }
    if (try getStringField(allocator, L, "deny")) |reason| {
        if (reason.len > 0) return .{ .deny = reason };
        allocator.free(reason);
    }
    if (try getStringField(allocator, L, "arguments")) |new_args| {
        errdefer allocator.free(new_args);
        if (isValidJson(allocator, new_args)) return .{ .modify = new_args };
        logger.warnFmt("[hooks] pre init returned invalid arguments JSON, ignoring modify", .{});
        allocator.free(new_args);
    }
    if (try getStringField(allocator, L, "output")) |mock_output| {
        return .{ .mock = mock_output };
    }
    return .allow;
}

/// Parse the post `init` return value. Priority: deny, then output.
fn parsePostReturn(allocator: std.mem.Allocator, logger: *Logger, L: ?*lua.LuaState) !PostResult {
    const t = lua.lua_type(L, -1);
    if (t == lua.LUA_TNIL or t == lua.LUA_TNONE) return .keep;
    if (t != lua.LUA_TTABLE) {
        logger.warnFmt("[hooks] post init returned non-table, ignoring", .{});
        return .keep;
    }
    if (try getStringField(allocator, L, "deny")) |reason| {
        if (reason.len > 0) return .{ .deny = reason };
        allocator.free(reason);
    }
    if (try getStringField(allocator, L, "output")) |replacement| {
        return .{ .replace = replacement };
    }
    return .keep;
}

/// Read a string field from the table at the stack top. Returns an owned
/// copy or null when missing/wrong-typed. Only OOM errors.
fn getStringField(allocator: std.mem.Allocator, L: ?*lua.LuaState, key: [*:0]const u8) !?[]u8 {
    _ = lua.lua_getfield(L, -1, key);
    defer lua.lua_settop(L, -2);
    if (lua.lua_type(L, -1) != lua.LUA_TSTRING) return null;
    var len: usize = 0;
    const ptr = lua.lua_tolstring(L, -1, &len) orelse return null;
    return try allocator.dupe(u8, ptr[0..len]);
}

fn isValidJson(allocator: std.mem.Allocator, text: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return false;
    defer parsed.deinit();
    return true;
}

fn logLuaError(logger: *Logger, L: ?*lua.LuaState, hook_file: []const u8, phase: []const u8) void {
    var len: usize = 0;
    const msg: []const u8 = if (lua.lua_tolstring(L, -1, &len)) |p| p[0..len] else "(no message)";
    logger.warnFmt("[hooks] {s} {s} failed: {s}", .{ hook_file, phase, msg });
    lua.lua_settop(L, 0);
}

// ============================================================================
// Tests (Lua is vendored for every target, so these run everywhere).
// ============================================================================

const testing = std.testing;

fn testLogger(allocator: std.mem.Allocator) Logger {
    return Logger.init(allocator, testing.io, .{});
}

fn writeHookFile(dir: std.Io.Dir, io: std.Io, name: []const u8, content: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = name, .data = content });
}

fn hookPath(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, name: []const u8) ![]u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(io, &path_buf);
    const root_abs = path_buf[0..n];
    return try std.fs.path.join(allocator, &.{ root_abs, name });
}

test "hooks: missing file resolves to null (disabled)" {
    const allocator = testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    try env_map.put("HOME", path_buf[0..n]);
    // %APPDATA% backs the config dir on Windows: without it resolveHookFile
    // errors instead of resolving to null.
    const appdata_abs = try std.fs.path.join(allocator, &.{ path_buf[0..n], "appdata" });
    defer allocator.free(appdata_abs);
    try env_map.put("APPDATA", appdata_abs);

    const resolved = try resolveHookFile(allocator, &env_map);
    try testing.expect(resolved == null);
}

test "hooks: existing register_hook.lua resolves" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    var env_map = try globalHookEnvForTest(allocator, testing.io, tmp.dir, path_buf[0..n], "function init(event, data) return nil end\n");
    defer env_map.deinit();

    const resolved = try resolveHookFile(allocator, &env_map);
    defer if (resolved) |p| allocator.free(p);
    try testing.expect(resolved != null);
    try testing.expect(std.mem.endsWith(u8, resolved.?, HOOK_FILENAME));
}

test "hooks: file without init is allow/keep" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHookFile(tmp.dir, testing.io, "no_init.lua", "x = 1\n");
    const path = try hookPath(allocator, tmp.dir, testing.io, "no_init.lua");
    defer allocator.free(path);

    const pre = try callPreHook(allocator, &lg, path, "bash", "{}", .{});
    defer pre.deinit(allocator);
    try testing.expect(pre == .allow);
    const post = try callPostHook(allocator, &lg, path, "bash", "{}", "out", .{});
    defer post.deinit(allocator);
    try testing.expect(post == .keep);
}

test "hooks: nil return is allow/keep" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHookFile(tmp.dir, testing.io, "nil.lua", "function init(event, data) return nil end\n");
    const path = try hookPath(allocator, tmp.dir, testing.io, "nil.lua");
    defer allocator.free(path);

    const pre = try callPreHook(allocator, &lg, path, "bash", "{}", .{});
    defer pre.deinit(allocator);
    try testing.expect(pre == .allow);
}

test "hooks: pre deny returns reason" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHookFile(tmp.dir, testing.io, "deny.lua", "function init(event, data) if event == 'pre_tool_use' then return { deny = 'no bash for you' } end return nil end\n");
    const path = try hookPath(allocator, tmp.dir, testing.io, "deny.lua");
    defer allocator.free(path);

    const pre = try callPreHook(allocator, &lg, path, "bash", "{}", .{});
    defer pre.deinit(allocator);
    try testing.expect(pre == .deny);
    try testing.expectEqualStrings("no bash for you", pre.deny);
}

test "hooks: pre modify with valid JSON" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHookFile(tmp.dir, testing.io, "modify.lua", "function init(event, data) return { arguments = '{\"command\":\"echo hi\"}' } end\n");
    const path = try hookPath(allocator, tmp.dir, testing.io, "modify.lua");
    defer allocator.free(path);

    const pre = try callPreHook(allocator, &lg, path, "bash", "{\"command\":\"rm -rf /\"}", .{});
    defer pre.deinit(allocator);
    try testing.expect(pre == .modify);
    try testing.expectEqualStrings("{\"command\":\"echo hi\"}", pre.modify);
}

test "hooks: pre modify with invalid JSON fails open to allow" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHookFile(tmp.dir, testing.io, "badjson.lua", "function init(event, data) return { arguments = 'not json{{' } end\n");
    const path = try hookPath(allocator, tmp.dir, testing.io, "badjson.lua");
    defer allocator.free(path);

    const pre = try callPreHook(allocator, &lg, path, "bash", "{}", .{});
    defer pre.deinit(allocator);
    try testing.expect(pre == .allow);
}

test "hooks: pre mock output skips exec" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHookFile(tmp.dir, testing.io, "mock.lua", "function init(event, data) return { output = 'mocked!' } end\n");
    const path = try hookPath(allocator, tmp.dir, testing.io, "mock.lua");
    defer allocator.free(path);

    const pre = try callPreHook(allocator, &lg, path, "bash", "{}", .{});
    defer pre.deinit(allocator);
    try testing.expect(pre == .mock);
    try testing.expectEqualStrings("mocked!", pre.mock);
}

test "hooks: post replace swaps output" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHookFile(tmp.dir, testing.io, "replace.lua", "function init(event, data) if event == 'post_tool_use' then return { output = 'redacted' } end return nil end\n");
    const path = try hookPath(allocator, tmp.dir, testing.io, "replace.lua");
    defer allocator.free(path);

    const post = try callPostHook(allocator, &lg, path, "bash", "{}", "secret=abc", .{});
    defer post.deinit(allocator);
    try testing.expect(post == .replace);
    try testing.expectEqualStrings("redacted", post.replace);
}

test "hooks: broken syntax fails open" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHookFile(tmp.dir, testing.io, "broken.lua", "function init(((\n");
    const path = try hookPath(allocator, tmp.dir, testing.io, "broken.lua");
    defer allocator.free(path);

    const pre = try runPreHook(allocator, &lg, null, "bash", "{}", .{});
    _ = pre;
    // runPreHook with null env resolves to allow without touching the file;
    // the broken file itself must error at the call level (fail-open above it).
    if (callPreHook(allocator, &lg, path, "bash", "{}", .{})) |r| {
        r.deinit(allocator);
        return error.TestUnexpectedSuccess;
    } else |_| {}
}

test "hooks: non-table return is ignored" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHookFile(tmp.dir, testing.io, "num.lua", "function init(event, data) return 42 end\n");
    const path = try hookPath(allocator, tmp.dir, testing.io, "num.lua");
    defer allocator.free(path);

    const pre = try callPreHook(allocator, &lg, path, "bash", "{}", .{});
    defer pre.deinit(allocator);
    try testing.expect(pre == .allow);
}

test "hooks: data table reaches Lua (tool_name visible)" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHookFile(tmp.dir, testing.io, "echo.lua", "function init(event, data) return { output = 'saw:' .. data.tool_name .. ':' .. event } end\n");
    const path = try hookPath(allocator, tmp.dir, testing.io, "echo.lua");
    defer allocator.free(path);

    const pre = try callPreHook(allocator, &lg, path, "read_file", "{}", .{});
    defer pre.deinit(allocator);
    try testing.expect(pre == .mock);
    try testing.expectEqualStrings("saw:read_file:pre_tool_use", pre.mock);
}

/// Write a per-project hook at <proj>/.pabrik/hooks/register_hook.lua.
/// Returns the project root absolute path (owned).
fn writeProjectHook(allocator: std.mem.Allocator, proj: std.Io.Dir, io: std.Io, content: []const u8) ![]u8 {
    try proj.createDirPath(io, ".pabrik/hooks");
    var hooks_dir = try proj.openDir(io, ".pabrik/hooks", .{});
    defer hooks_dir.close(io);
    try writeHookFile(hooks_dir, io, HOOK_FILENAME, content);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try proj.realPath(io, &path_buf);
    return try allocator.dupe(u8, path_buf[0..n]);
}

fn emptyHomeEnv(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) !std.process.Environ.Map {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const home = path_buf[0..n];
    var env_map = std.process.Environ.Map.init(allocator);
    errdefer env_map.deinit();
    try env_map.put("HOME", home);
    // %APPDATA% backs the config dir on Windows; point it inside the tmp
    // home so tests stay hermetic there too (unused on POSIX/macOS).
    const appdata = try std.fs.path.join(allocator, &.{ home, "appdata" });
    defer allocator.free(appdata);
    try env_map.put("APPDATA", appdata);
    return env_map;
}

/// Test helper: fake-HOME env map with the REAL global hooks dir populated.
pub fn globalHookEnvForTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    home_tmp: std.Io.Dir,
    home_abs: []const u8,
    lua_source: []const u8,
) !std.process.Environ.Map {
    const appdata_abs = try std.fs.path.join(allocator, &.{ home_abs, "appdata" });
    defer allocator.free(appdata_abs);
    try home_tmp.createDirPath(io, "appdata");
    var env_map = std.process.Environ.Map.init(allocator);
    errdefer env_map.deinit();
    try env_map.put("HOME", home_abs);
    try env_map.put("APPDATA", appdata_abs);
    const dir = try getHooksDir(allocator, &env_map) orelse return error.TestNoHome;
    defer allocator.free(dir);
    // dir is always under home_abs here (APPDATA itself lives there).
    if (dir.len <= home_abs.len or !std.mem.startsWith(u8, dir, home_abs)) return error.TestHookDirOutsideTmp;
    var rel = dir[home_abs.len..];
    if (rel.len > 0 and (rel[0] == '/' or rel[0] == '\\')) rel = rel[1..];
    if (rel.len == 0) return error.TestHookDirOutsideTmp;
    try home_tmp.createDirPath(io, rel);
    var d = try home_tmp.openDir(io, rel, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = HOOK_FILENAME, .data = lua_source });
    return env_map;
}

test "hooks: project-only hook denies without global" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var home_tmp = testing.tmpDir(.{});
    defer home_tmp.cleanup();
    var env_map = try emptyHomeEnv(allocator, &home_tmp);
    defer env_map.deinit();

    var proj_tmp = testing.tmpDir(.{});
    defer proj_tmp.cleanup();
    const proj_root = try writeProjectHook(allocator, proj_tmp.dir, testing.io, "function init(event, data) if event == 'pre_tool_use' then return { deny = 'project says no' } end return nil end\n");
    defer allocator.free(proj_root);

    const pre = try runPreHook(allocator, &lg, &env_map, "bash", "{}", .{ .cwd = proj_root });
    defer pre.deinit(allocator);
    try testing.expect(pre == .deny);
    try testing.expectEqualStrings("project says no", pre.deny);
}

test "hooks: global modify chains into project" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var home_tmp = testing.tmpDir(.{});
    defer home_tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try home_tmp.dir.realPath(testing.io, &path_buf);
    var env_map = try globalHookEnvForTest(allocator, testing.io, home_tmp.dir, path_buf[0..n], "function init(event, data) return { arguments = '{\"v\":\"global\"}' } end\n");
    defer env_map.deinit();

    var proj_tmp = testing.tmpDir(.{});
    defer proj_tmp.cleanup();
    // Project echoes the args it RECEIVED — proves it saw the global edit.
    const proj_root = try writeProjectHook(allocator, proj_tmp.dir, testing.io, "function init(event, data) return { output = 'proj saw:' .. data.arguments } end\n");
    defer allocator.free(proj_root);

    const pre = try runPreHook(allocator, &lg, &env_map, "bash", "{\"v\":\"orig\"}", .{ .cwd = proj_root });
    defer pre.deinit(allocator);
    try testing.expect(pre == .mock);
    try testing.expectEqualStrings("proj saw:{\"v\":\"global\"}", pre.mock);
}

test "hooks: global deny stops project" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var home_tmp = testing.tmpDir(.{});
    defer home_tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try home_tmp.dir.realPath(testing.io, &path_buf);
    var env_map = try globalHookEnvForTest(allocator, testing.io, home_tmp.dir, path_buf[0..n], "function init(event, data) return { deny = 'global block' } end\n");
    defer env_map.deinit();

    var proj_tmp = testing.tmpDir(.{});
    defer proj_tmp.cleanup();
    // Would mock if it ran — the deny must win instead.
    const proj_root = try writeProjectHook(allocator, proj_tmp.dir, testing.io, "function init(event, data) return { output = 'project ran' } end\n");
    defer allocator.free(proj_root);

    const pre = try runPreHook(allocator, &lg, &env_map, "bash", "{}", .{ .cwd = proj_root });
    defer pre.deinit(allocator);
    try testing.expect(pre == .deny);
    try testing.expectEqualStrings("global block", pre.deny);
}

test "hooks: broken project fails open" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var home_tmp = testing.tmpDir(.{});
    defer home_tmp.cleanup();
    var env_map = try emptyHomeEnv(allocator, &home_tmp);
    defer env_map.deinit();

    var proj_tmp = testing.tmpDir(.{});
    defer proj_tmp.cleanup();
    const proj_root = try writeProjectHook(allocator, proj_tmp.dir, testing.io, "function init(((\n");
    defer allocator.free(proj_root);

    const pre = try runPreHook(allocator, &lg, &env_map, "bash", "{}", .{ .cwd = proj_root });
    defer pre.deinit(allocator);
    try testing.expect(pre == .allow);
}

test "hooks: post replace chains, project wins" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var home_tmp = testing.tmpDir(.{});
    defer home_tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try home_tmp.dir.realPath(testing.io, &path_buf);
    var env_map = try globalHookEnvForTest(allocator, testing.io, home_tmp.dir, path_buf[0..n], "function init(event, data) if event == 'post_tool_use' then return { output = 'GLOBAL' } end return nil end\n");
    defer env_map.deinit();

    var proj_tmp = testing.tmpDir(.{});
    defer proj_tmp.cleanup();
    const proj_root = try writeProjectHook(allocator, proj_tmp.dir, testing.io, "function init(event, data) if event == 'post_tool_use' then return { output = 'PROJECT:' .. data.output } end return nil end\n");
    defer allocator.free(proj_root);

    const post = try runPostHook(allocator, &lg, &env_map, "bash", "{}", "orig", .{ .cwd = proj_root });
    defer post.deinit(allocator);
    try testing.expect(post == .replace);
    try testing.expectEqualStrings("PROJECT:GLOBAL", post.replace);
}

test "hooks: empty cwd skips project tier" {
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var home_tmp = testing.tmpDir(.{});
    defer home_tmp.cleanup();
    var env_map = try emptyHomeEnv(allocator, &home_tmp);
    defer env_map.deinit();

    const pre = try runPreHook(allocator, &lg, &env_map, "bash", "{}", .{ .cwd = "" });
    defer pre.deinit(allocator);
    try testing.expect(pre == .allow);
    const post = try runPostHook(allocator, &lg, &env_map, "bash", "{}", "out", .{ .cwd = "" });
    defer post.deinit(allocator);
    try testing.expect(post == .keep);
}

test "hooks: long-bracket args with backslashes survive verbatim" {
    // Windows paths (`C:\...`) inside Lua short strings break on escape
    // processing (`\U` is invalid).
    const allocator = testing.allocator;
    var lg = testLogger(allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeHookFile(tmp.dir, testing.io, "brackets.lua", "function init(event, data) return { arguments = [[{\"path\":\"C:\\\\Users\\\\x\\\\f.txt\"}]] } end\n");
    const path = try hookPath(allocator, tmp.dir, testing.io, "brackets.lua");
    defer allocator.free(path);

    const pre = try callPreHook(allocator, &lg, path, "read_file", "{}", .{});
    defer pre.deinit(allocator);
    try testing.expect(pre == .modify);
    try testing.expectEqualStrings("{\"path\":\"C:\\\\Users\\\\x\\\\f.txt\"}", pre.modify);
}

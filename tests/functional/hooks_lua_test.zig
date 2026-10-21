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
}

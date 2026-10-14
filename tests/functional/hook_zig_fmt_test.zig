//! The project hook runs zig fmt on edited Zig files. The hook itself
//! (.pabrik/hooks/register_hook.lua) is the deliverable, and it runs INSIDE
//! pabrik's vendored Lua interpreter, on every tool dispatch.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// The project hook under test, relative to the repo root. See header note 1.
const HOOK_REL = ".pabrik/hooks/register_hook.lua";

/// Python's `subprocess.run(..., timeout=60)` on the hook driver.
const HOOK_RUN_TIMEOUT_MS: i64 = 60_000;

/// Python's `subprocess.run(..., timeout=30)` on `zig fmt --check`.
const FMT_CHECK_TIMEOUT_MS: i64 = 30_000;

/// Python's `_lua()`: `shutil.which("lua5.4") or shutil.which("lua")`, and
/// `pytest.skip` when neither is present.
fn luaExe() ![]u8 {
    for ([_][]const u8{ "lua5.4", "lua" }) |name| {
        // The probe's captured streams are still owned by the caller:
        // `RunResult` hands over `stdout` / `stderr` buffers whether or not
        // the test looks at them, and the DebugAllocator reports them at the
        const res = std.process.run(gpa, io, .{ .argv = &.{ name, "-v" } }) catch continue;
        gpa.free(res.stdout);
        gpa.free(res.stderr);
        return gpa.dupe(u8, name);
    }
    std.debug.print("no system lua available to run the project hook\n", .{});
    return error.SkipZigTest;
}

/// Absolute path of a repo-root-relative file. Owned.
fn repoFileAbs(rel: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(io, rel, &buf) catch |err| switch (err) {
        error.FileNotFound, error.NameTooLong => {
            std.debug.print("project hook missing: {s}\n", .{rel});
            return error.TestUnexpectedResult;
        },
        else => return err,
    };
    return gpa.dupe(u8, buf[0..n]);
}

/// Render `s` as a Lua SHORT-STRING literal (double-quoted).
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

/// Drive the REAL hook: load it, call init("post_tool_use", data).
fn runHook(lua: []const u8, hook_path: []const u8, cwd: []const u8, tool_name: []const u8, arguments: []const u8) !std.process.RunResult {
    const hook_lit = try luaString(gpa, hook_path);
    defer gpa.free(hook_lit);
    const tool_lit = try luaString(gpa, tool_name);
    defer gpa.free(tool_lit);
    const args_lit = try luaString(gpa, arguments);
    defer gpa.free(args_lit);
    const cwd_lit = try luaString(gpa, cwd);
    defer gpa.free(cwd_lit);

    const driver = try std.fmt.allocPrint(gpa,
        \\local hook = assert(loadfile({s}))
        \\hook()
        \\local data = {{
        \\  tool_name = {s},
        \\  arguments = {s},
        \\  session_id = "sess_test",
        \\  cwd = {s},
        \\  model = "test",
        \\}}
        \\local ret = init("post_tool_use", data)
        \\assert(ret == nil, "hook must return nil, got " .. tostring(ret))
        \\
    , .{ hook_lit, tool_lit, args_lit, cwd_lit });
    defer gpa.free(driver);

    return std.process.run(gpa, io, .{
        .argv = &.{ lua, "-e", driver },
        .cwd = .{ .path = cwd },
        .timeout = timeoutMs(HOOK_RUN_TIMEOUT_MS),
    });
}

/// `subprocess.run(timeout=<ms>)` — Python's wall-clock-free "give the child
/// N ms" budget, as `std.process.RunOptions.timeout`.
fn timeoutMs(ms: i64) std.Io.Timeout {
    return .{ .duration = .{
        .raw = .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms },
        .clock = .awake,
    } };
}

/// Exit code of a finished child, or null if a signal stopped it.
fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// `_fmt_clean(path)` — `zig fmt --check <path>` exits 0. Python let a
/// missing `zig` CLI raise out of the helper.
fn fmtClean(path: []const u8) !bool {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "zig", "fmt", "--check", path },
        .timeout = timeoutMs(FMT_CHECK_TIMEOUT_MS),
    }) catch |err| {
        std.debug.print("`zig fmt --check` could not run ({s})\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    return exitCode(res.term) == 0;
}

/// Read a fixture file. Owned.
fn readFile(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
}

fn writeFile(path: []const u8, content: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, content);
}

/// Python's `workdir` fixture: a scratch dir holding one fmt-clean and one
/// not-fmt-clean .zig file.
const Fixture = struct {
    scratch: []u8,
    proj: []u8,

    /// Delete the scratch tree, then the two path buffers.
    fn deinit(self: *Fixture) void {
        harness.cleanupExtraDir(io, gpa, self.scratch);
        gpa.free(self.proj);
        gpa.free(self.scratch);
    }

    /// An ABSOLUTE path inside the fixture project. Owned by the caller.
    fn path(self: *Fixture, rel: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.proj, rel });
    }
};

fn makeWorkdir() !Fixture {
    const scratch = try harness.makeScratchDir(gpa);
    errdefer gpa.free(scratch);
    const proj = try std.fs.path.join(gpa, &.{ scratch, "proj" });
    errdefer gpa.free(proj);
    const src = try std.fs.path.join(gpa, &.{ proj, "src" });
    defer gpa.free(src);
    try std.Io.Dir.cwd().createDirPath(io, src);

    const clean = try std.fs.path.join(gpa, &.{ src, "clean.zig" });
    defer gpa.free(clean);
    try writeFile(clean, "pub fn main() void {\n    const x = 1;\n}\n");

    // Multi-line call args that zig fmt collapses onto one long line.
    const legacy = try std.fs.path.join(gpa, &.{ src, "legacy.zig" });
    defer gpa.free(legacy);
    try writeFile(legacy,
        \\pub fn main() void {
        \\    call(veryLongArgumentName,
        \\        anotherRatherLongArgument,
        \\        &.{});
        \\}
        \\
    );

    return .{ .scratch = scratch, .proj = proj };
}

/// Assert the hook driver exited 0, printing stderr when it did not. Python
/// repeated `assert r.returncode == 0, f"hook errored: {r.stderr}"` seven
/// times.
fn expectHookOk(res: std.process.RunResult) !void {
    const code = exitCode(res.term);
    if (code == null or code.? != 0) {
        std.debug.print("hook errored (rc={?}): {s}\n", .{ code, res.stderr });
    }
    gpa.free(res.stdout);
    gpa.free(res.stderr);
    if (code == null or code.? != 0) return error.TestUnexpectedResult;
}

/// `re.search(r"&\.\{\s*1,\s*2\s*\}", text)`.
fn survivesFmtEdit(text: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, "&.{")) |hit| {
        if (brace12At(text, hit)) return true;
        at = hit + 1;
    }
    return false;
}

fn brace12At(text: []const u8, start: usize) bool {
    var p = skipSpace(text, start + "&.{".len);
    if (p >= text.len or text[p] != '1') return false;
    p = skipSpace(text, p + 1);
    if (p >= text.len or text[p] != ',') return false;
    p = skipSpace(text, p + 1);
    if (p >= text.len or text[p] != '2') return false;
    p = skipSpace(text, p + 1);
    return p < text.len and text[p] == '}';
}

/// `\s` in the pattern above: the Python regex class is `[ \t\r\n\f\v]`, and
/// the fixture files never contain the last two, but matching them costs
/// nothing and keeps the port honest.
fn skipSpace(text: []const u8, from: usize) usize {
    var p = from;
    while (p < text.len) : (p += 1) {
        switch (text[p]) {
            ' ', '\t', '\r', '\n', '\x0c', '\x0b' => {},
            else => break,
        }
    }
    return p;
}

// The shipped hook must parse under the same Lua pabrik embeds.
test "hook_file_is_valid_lua" {
    const lua = try luaExe();
    defer gpa.free(lua);

    // Python: `assert HOOK.exists()`.
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    const hook_lit = try luaString(gpa, hook);
    defer gpa.free(hook_lit);
    const driver = try std.fmt.allocPrint(gpa, "assert(loadfile({s}))", .{hook_lit});
    defer gpa.free(driver);

    const res = try std.process.run(gpa, io, .{
        .argv = &.{ lua, "-e", driver },
        .timeout = timeoutMs(FMT_CHECK_TIMEOUT_MS),
    });
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    if (code == null or code.? != 0) {
        std.debug.print("hook failed to parse (rc={?}): {s}\n", .{ code, res.stderr });
        return error.TestUnexpectedResult;
    }
}

// The headline behaviour: an edit lands canonically formatted. Without the
// hook the edit sits in whatever shape the model wrote it and the file is
// left dirty.
test "formats_the_edited_region" {
    const lua = try luaExe();
    defer gpa.free(lua);
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    var fx = try makeWorkdir();
    defer fx.deinit();

    const target = try fx.path("src/clean.zig");
    defer gpa.free(target);
    try writeFile(target, "pub fn main() void {\n    const x    =    1;\n    const y = 2;\n}\n");
    // Python: `assert not _fmt_clean(target)` — the precondition, and it must
    // stay an assertion rather than a comment, or a `zig fmt` that silently
    // started accepting the dirty file would make the rest of the test
    if (try fmtClean(target)) {
        std.debug.print("precondition: the edit did not make the file dirty\n", .{});
        return error.TestUnexpectedResult;
    }

    const res = try runHook(lua, hook, fx.proj, "text_replace", "{\"path\": \"src/clean.zig\"}");
    try expectHookOk(res);

    if (!try fmtClean(target)) {
        const text = try readFile(target);
        defer gpa.free(text);
        std.debug.print("hook left an edited file unformatted:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
    // The read is hoisted out of the assertion so it can be freed: an
    // owned buffer cannot be handed straight to `expectEqualStrings`
    // AND deferred at the same time.
    const formatted = try readFile(target);
    defer gpa.free(formatted);
    try testing.expectEqualStrings(
        "pub fn main() void {\n    const x = 1;\n    const y = 2;\n}\n",
        formatted,
    );
}

// Pre-existing unformatted lines are normalised too — by design. `zig fmt` is
// a whole-file rewriter.
test "formats_whole_file_not_just_the_edit" {
    const lua = try luaExe();
    defer gpa.free(lua);
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    var fx = try makeWorkdir();
    defer fx.deinit();

    const target = try fx.path("src/legacy.zig");
    defer gpa.free(target);
    try writeFile(target,
        \\pub fn main() void {
        \\    call(veryLongArgumentName,
        \\        anotherRatherLongArgument,
        \\        &.{1, 2});
        \\}
        \\
    );
    if (try fmtClean(target)) {
        std.debug.print("precondition: file started out not-fmt-clean\n", .{});
        return error.TestUnexpectedResult;
    }

    const res = try runHook(lua, hook, fx.proj, "text_replace", "{\"path\": \"src/legacy.zig\"}");
    try expectHookOk(res);

    const text = try readFile(target);
    defer gpa.free(text);

    if (!try fmtClean(target)) {
        std.debug.print("hook did not bring the whole file to canonical form:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
    // The edit must survive the reformat.
    if (!survivesFmtEdit(text)) {
        std.debug.print("the actual edit did not survive formatting:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, text, "veryLongArgumentName") == null) {
        std.debug.print("existing code was lost:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
}

// A mid-edit file that does not parse must be left byte-for-byte alone. zig
// fmt exits non-zero without writing on a parse error, so a half-typed file
// is never mangled.
test "syntax_broken_file_is_not_corrupted" {
    const lua = try luaExe();
    defer gpa.free(lua);
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    var fx = try makeWorkdir();
    defer fx.deinit();

    const target = try fx.path("src/clean.zig");
    defer gpa.free(target);
    const broken = "pub fn main() void {\n    const x = ;\n}\n";
    try writeFile(target, broken);

    const res = try runHook(lua, hook, fx.proj, "text_replace", "{\"path\": \"src/clean.zig\"}");
    try expectHookOk(res);

    const text = try readFile(target);
    defer gpa.free(text);
    if (!std.mem.eql(u8, broken, text)) {
        std.debug.print("hook corrupted a syntactically broken file:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
}

// A brand-new .zig file is formatted like any other.
test "new_file_is_formatted" {
    const lua = try luaExe();
    defer gpa.free(lua);
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    var fx = try makeWorkdir();
    defer fx.deinit();

    const target = try fx.path("src/fresh.zig");
    defer gpa.free(target);
    try writeFile(target, "pub fn f() void {\n    const a    =    1;\n}\n");

    const res = try runHook(lua, hook, fx.proj, "write_file", "{\"path\": \"src/fresh.zig\", \"content\": \"x\"}");
    try expectHookOk(res);

    if (!try fmtClean(target)) {
        const text = try readFile(target);
        defer gpa.free(text);
        std.debug.print("a newly created .zig did not come out canonical:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
}

// Tool arguments can carry an absolute path.
test "absolute_path_is_handled" {
    const lua = try luaExe();
    defer gpa.free(lua);
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    var fx = try makeWorkdir();
    defer fx.deinit();

    const target = try fx.path("src/clean.zig");
    defer gpa.free(target);
    try writeFile(target, "pub fn main() void {\n    const q    =    3;\n}\n");

    const args = try std.fmt.allocPrint(gpa, "{{\"path\": \"{s}\"}}", .{target});
    defer gpa.free(args);

    const res = try runHook(lua, hook, fx.proj, "text_replace", args);
    try expectHookOk(res);

    if (!try fmtClean(target)) {
        std.debug.print("absolute-path edit was not formatted\n", .{});
        return error.TestUnexpectedResult;
    }
}

// Only .zig and the prettier set are handled; other paths/tools change nothing.
test "non_zig_and_unknown_tools_are_noops" {
    const lua = try luaExe();
    defer gpa.free(lua);
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    var fx = try makeWorkdir();
    defer fx.deinit();

    const target = try fx.path("src/notes.txt");
    defer gpa.free(target);
    const notes = "const    x=1\n";
    try writeFile(target, notes);

    {
        const res = try runHook(lua, hook, fx.proj, "write_file", "{\"path\": \"src/notes.txt\", \"content\": \"x\"}");
        try expectHookOk(res);
    }
    {
        const text = try readFile(target);
        defer gpa.free(text);
        if (!std.mem.eql(u8, notes, text)) {
            std.debug.print("hook touched a non-.zig file:\n{s}\n", .{text});
            return error.TestUnexpectedResult;
        }
    }

    // A read-only tool that happens to carry a .zig path must not format.
    const z = try fx.path("src/clean.zig");
    defer gpa.free(z);
    const before = try readFile(z);
    defer gpa.free(before);
    {
        const res = try runHook(lua, hook, fx.proj, "read_file", "{\"path\": \"src/clean.zig\"}");
        try expectHookOk(res);
    }
    {
        const text = try readFile(z);
        defer gpa.free(text);
        if (!std.mem.eql(u8, before, text)) {
            std.debug.print("hook formatted on a non-edit tool:\n{s}\n", .{text});
            return error.TestUnexpectedResult;
        }
    }
}

// A deleted or never-written target must fail open, not raise.
test "missing_file_does_not_error" {
    const lua = try luaExe();
    defer gpa.free(lua);
    const hook = try repoFileAbs(HOOK_REL);
    defer gpa.free(hook);

    var fx = try makeWorkdir();
    defer fx.deinit();

    const res = try runHook(lua, hook, fx.proj, "text_replace", "{\"path\": \"src/gone.zig\"}");
    const code = exitCode(res.term);
    if (code == null or code.? != 0) {
        std.debug.print("hook errored on a missing file (rc={?}): {s}\n", .{ code, res.stderr });
    }
    gpa.free(res.stdout);
    gpa.free(res.stderr);
    if (code == null or code.? != 0) return error.TestUnexpectedResult;
}

comptime {
    // Body-analysis barrier: an unreferenced function is never
    // type-checked, so a stdlib rename inside one would stay invisible
    // until some caller appeared.
    _ = luaExe;
    _ = repoFileAbs;
    _ = luaString;
    _ = runHook;
    _ = timeoutMs;
    _ = exitCode;
    _ = fmtClean;
    _ = readFile;
    _ = writeFile;
    _ = Fixture;
    _ = Fixture.deinit;
    _ = Fixture.path;
    _ = makeWorkdir;
    _ = expectHookOk;
    _ = survivesFmtEdit;
    _ = brace12At;
    _ = skipSpace;
    _ = Harness.boot;
}

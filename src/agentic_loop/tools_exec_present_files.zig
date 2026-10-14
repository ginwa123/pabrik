const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const present_files_mod = pabrikcore.ai_mod.present_files;
const file_sandbox = pabrikcore.ai_mod.file_sandbox;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
const path_validate = @import("helpers").path_validate;

pub fn execPresentFiles(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        present_files_mod.PresentFilesInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "present_files", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // `cwd` is REQUIRED on every path-taking tool (see
    // helpers/path_validate.validateCwd).
    path_validate.validateCwd(parsed.value.cwd) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "present_files", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // Resolve every entry against the call's `cwd` BEFORE the sandbox check:
    // the download endpoint is handed absolute paths, and an unresolved
    // relative one would be rejected there as "not absolute".
    var resolved_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (resolved_paths.items) |p| ctx.allocator.free(p);
        resolved_paths.deinit(ctx.allocator);
    }
    const files_abs = try ctx.allocator.alloc(present_files_mod.PresentFileRef, parsed.value.files.len);
    defer ctx.allocator.free(files_abs);
    for (parsed.value.files, 0..) |entry, i| {
        const abs = try path_validate.resolveAgainstCwd(ctx.allocator, parsed.value.cwd, entry.path);
        try resolved_paths.append(ctx.allocator, abs);
        files_abs[i] = .{ .path = abs, .label = entry.label, .caption = entry.caption };
    }
    var input = parsed.value;
    input.files = files_abs;

    // The sandbox root, resolved through the SAME helper the download
    // endpoint uses (`git_worktree_cwd ?? cwd`).
    const root = file_sandbox.resolveSessionRoot(ctx.allocator, ctx.db, ctx.session_id) catch |err| switch (err) {
        // No `sessions` row at all: a TUI / routine dispatch. It renders no
        // card (there is no session id to build the download URL from), so
        // keep the un-sandboxed behaviour instead of disabling the tool.
        error.SessionNotFound => null,
        // A session WITH a row but no usable working directory: fail closed.
        // The endpoint 403s every path for such a session, so presenting
        // anything would only produce a dead card.
        error.NoWorkingDirectory, error.QueryFailed, error.OutOfMemory => {
            const err_msg = "present_files: this session has no accessible working directory, so no file can be presented in the chat. Tell the user the full path instead.";
            const output = try wrapToolOutput(ctx.allocator, "present_files", tc.function.arguments, false, err_msg, "");
            return ToolExecResult{ .output = output, .output_allocated = true };
        },
    };
    defer if (root) |r| ctx.allocator.free(r);

    // executePresentFilesToString returns a JSON string.
    const inner = present_files_mod.executePresentFilesToString(
        ctx.allocator,
        ctx.io,
        input,
        root,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "present_files", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the {"status":null,"error":...} shape and surface it as a tool
    // failure (so the LLM sees `success=false` rather than a successful
    // wrapper around an error body).
    const inner_failed: bool = blk: {
        const parsed_inner = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch break :blk true;
        defer parsed_inner.deinit();
        if (parsed_inner.value != .object) break :blk true;
        const status = parsed_inner.value.object.get("status") orelse break :blk true;
        if (status != .string) break :blk true;
        break :blk !std.mem.eql(u8, status.string, "presented");
    };
    if (inner_failed) {
        // The message must be COPIED out of the parse tree: returning
        // `e.string` from a block that defers `parsed_inner.deinit()` hands
        // `wrapToolOutput` a slice into freed memory.
        const err_msg: ?[]const u8 = blk: {
            const parsed_inner = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch break :blk null;
            defer parsed_inner.deinit();
            if (parsed_inner.value != .object) break :blk null;
            const e = parsed_inner.value.object.get("error") orelse break :blk null;
            if (e != .string) break :blk null;
            break :blk try ctx.allocator.dupe(u8, e.string);
        };
        defer if (err_msg) |m| ctx.allocator.free(m);
        const output = try wrapToolOutput(ctx.allocator, "present_files", tc.function.arguments, false, err_msg orelse inner, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "present_files", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
// ─── Exec-layer tests ────────────────────────────────────────────────────
// The tool-level tests in `present_files.zig` prove the RULE.

const testing = std.testing;

/// In-memory `sessions` table + two sibling temp dirs, so "inside the
/// working directory" and "outside it" are real paths on every CI OS.
const ExecEnv = struct {
    threaded: std.Io.Threaded,
    db: pabrikcore.sqlite.SqliteBackend,
    inside: std.testing.TmpDir,
    outside: std.testing.TmpDir,
    inside_abs: []const u8,
    outside_abs: []const u8,
    session_id: []const u8 = "task_present_1",
    dangle_f32: f32 = 0,
    dangle_bool: bool = false,

    fn deinit(self: *ExecEnv, allocator: std.mem.Allocator) void {
        allocator.free(self.inside_abs);
        allocator.free(self.outside_abs);
        self.inside.cleanup();
        self.outside.cleanup();
        self.db.deinit();
        self.threaded.deinit();
    }

    fn minimalCtx(self: *ExecEnv, allocator: std.mem.Allocator) ToolExecContext {
        return .{
            .allocator = allocator,
            .io = self.threaded.io(),
            .db = &self.db,
            .logger = undefined,
            .session_id = self.session_id,
            .model = "test_model",
            .cwd = self.inside_abs,
            .api_key = "test_key",
            .base_url = "test_base",
            .config = undefined,
            .agent_temperature = &self.dangle_f32,
            .is_thinking = &self.dangle_bool,
            .environment = null,
        };
    }

    fn writeInside(self: *ExecEnv, allocator: std.mem.Allocator, rel: []const u8, body: []const u8) ![]u8 {
        return writeFixture(allocator, self.inside.dir, self.threaded.io(), self.inside_abs, rel, body);
    }

    fn writeOutside(self: *ExecEnv, allocator: std.mem.Allocator, rel: []const u8, body: []const u8) ![]u8 {
        return writeFixture(allocator, self.outside.dir, self.threaded.io(), self.outside_abs, rel, body);
    }

    fn setSessionCwd(self: *ExecEnv, cwd: []const u8) !void {
        try self.db.exec(testing.allocator, "UPDATE sessions SET cwd = ? WHERE id = ?", &.{ cwd, self.session_id });
    }

    fn setSessionWorktree(self: *ExecEnv, worktree: []const u8) !void {
        try self.db.exec(testing.allocator, "UPDATE sessions SET git_worktree_cwd = ? WHERE id = ?", &.{ worktree, self.session_id });
    }
};

fn writeFixture(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    abs: []const u8,
    rel: []const u8,
    body: []const u8,
) ![]u8 {
    if (std.fs.path.dirname(rel)) |parent| try dir.createDirPath(io, parent);
    var file = try dir.createFile(io, rel, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, body);
    return std.fs.path.join(allocator, &.{ abs, rel });
}

fn realPathOf(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(testing.io, &buf);
    return allocator.dupe(u8, buf[0..n]);
}

fn setupExecEnv(allocator: std.mem.Allocator) !ExecEnv {
    var threaded = std.Io.Threaded.init(allocator, .{});
    errdefer threaded.deinit();
    var db: pabrikcore.sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    // Only the two columns the sandbox root resolver reads; nullable, like
    // production (Migration 046), so the unbound-worktree shape is real.
    try db.exec(allocator,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  status TEXT NOT NULL DEFAULT 'active',
        \\  cwd TEXT,
        \\  git_worktree_cwd TEXT
        \\)
    , &.{});
    try db.exec(allocator, "INSERT INTO sessions (id, name) VALUES (?, ?)", &.{ "task_present_1", "present-files" });

    var inside = testing.tmpDir(.{});
    errdefer inside.cleanup();
    var outside = testing.tmpDir(.{});
    errdefer outside.cleanup();
    const inside_abs = try realPathOf(allocator, inside.dir);
    errdefer allocator.free(inside_abs);
    const outside_abs = try realPathOf(allocator, outside.dir);
    // A real session always has a working directory; tests that care about
    // the other shapes override it below.
    try db.exec(allocator, "UPDATE sessions SET cwd = ? WHERE id = ?", &.{ inside_abs, "task_present_1" });
    return .{
        .threaded = threaded,
        .db = db,
        .inside = inside,
        .outside = outside,
        .inside_abs = inside_abs,
        .outside_abs = outside_abs,
    };
}

fn runPresentFiles(allocator: std.mem.Allocator, env: *ExecEnv, path: []const u8) ![]const u8 {
    var ctx = env.minimalCtx(allocator);
    return runPresentFilesWith(allocator, &ctx, path);
}

/// Build the tool-call arguments with `std.json` — a hand-formatted string
/// would emit `C:\Users\…` unescaped, which is not valid JSON on Windows and
/// would make these tests pass on Linux and fail on the Windows CI.
fn runPresentFilesWith(allocator: std.mem.Allocator, ctx: *ToolExecContext, path: []const u8) ![]const u8 {
    // `cwd` is required by the tool. These tests pass absolute paths, so the
    // only thing that matters is that it is absolute — the file's own
    // directory is the honest value.
    const args = try std.json.Stringify.valueAlloc(allocator, .{
        .files = &[_]present_files_mod.PresentFileRef{.{ .path = path }},
        .cwd = std.fs.path.dirname(path) orelse "/",
    }, .{});
    defer allocator.free(args);
    const result = try execPresentFiles(ctx.*, .{ .id = "tc_1", .function = .{ .name = "present_files", .arguments = args } });
    return result.output;
}

test "execPresentFiles: a file inside the session working directory succeeds" {
    const a = testing.allocator;
    var env = try setupExecEnv(a);
    defer env.deinit(a);

    const path = try env.writeInside(a, "report.html", "<h1>hi</h1>");
    defer a.free(path);

    const output = try runPresentFiles(a, &env, path);
    defer a.free(output);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("success").?.bool);
    try testing.expectEqualStrings("presented", obj.get("data").?.object.get("status").?.string);
}

test "execPresentFiles: a file outside the session working directory fails the call" {
    // The whole point of the fix: the tool must not hand the model a
    // "presented" card whose bytes the download endpoint refuses to serve.
    const a = testing.allocator;
    var env = try setupExecEnv(a);
    defer env.deinit(a);

    const path = try env.writeOutside(a, "report.html", "<h1>hi</h1>");
    defer a.free(path);

    const output = try runPresentFiles(a, &env, path);
    defer a.free(output);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(!obj.get("success").?.bool);
    const err = obj.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, err, "outside the session working directory") != null);
    try testing.expect(std.mem.indexOf(u8, err, path) != null);
}

test "execPresentFiles: the sandbox root is git_worktree_cwd when bound, like the endpoint" {
    // Parity test for the rule that drifted: the download endpoint resolves
    // the root as `git_worktree_cwd ?? cwd`. If the tool resolved `cwd` only,
    // a file in the worktree would present fine and then 403 in the card.
    const a = testing.allocator;
    var env = try setupExecEnv(a);
    defer env.deinit(a);
    try env.setSessionCwd(env.inside_abs);
    try env.setSessionWorktree(env.outside_abs);

    const in_worktree = try env.writeOutside(a, "report.html", "<h1>hi</h1>");
    defer a.free(in_worktree);
    const out_worktree = try env.writeInside(a, "notes.txt", "ok");
    defer a.free(out_worktree);

    const ok_output = try runPresentFiles(a, &env, in_worktree);
    defer a.free(ok_output);
    const ok_parsed = try std.json.parseFromSlice(std.json.Value, a, ok_output, .{});
    defer ok_parsed.deinit();
    try testing.expect(ok_parsed.value.object.get("success").?.bool);

    const bad_output = try runPresentFiles(a, &env, out_worktree);
    defer a.free(bad_output);
    const bad_parsed = try std.json.parseFromSlice(std.json.Value, a, bad_output, .{});
    defer bad_parsed.deinit();
    try testing.expect(!bad_parsed.value.object.get("success").?.bool);
}

test "execPresentFiles: a session with no working directory fails closed" {
    const a = testing.allocator;
    var env = try setupExecEnv(a);
    defer env.deinit(a);
    try env.setSessionCwd("");
    try env.setSessionWorktree("");

    const path = try env.writeInside(a, "report.html", "<h1>hi</h1>");
    defer a.free(path);

    const output = try runPresentFiles(a, &env, path);
    defer a.free(output);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(!obj.get("success").?.bool);
    try testing.expect(std.mem.indexOf(u8, obj.get("error").?.string, "working directory") != null);
}

test "execPresentFiles: an unknown session keeps the un-sandboxed legacy path" {
    // TUI / routine dispatches run with a session id that has no `sessions`
    // row. They render no card (there is no session id to build the download
    // URL from), so the guard must not disable present_files for them.
    const a = testing.allocator;
    var env = try setupExecEnv(a);
    defer env.deinit(a);

    const path = try env.writeOutside(a, "report.html", "<h1>hi</h1>");
    defer a.free(path);

    var ctx = env.minimalCtx(a);
    ctx.session_id = "no_such_session";
    const output = try runPresentFilesWith(a, &ctx, path);
    defer a.free(output);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, output, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("success").?.bool);
}

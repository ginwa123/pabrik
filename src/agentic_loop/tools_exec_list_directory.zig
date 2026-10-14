const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const list_directory_mod = pabrikcore.list_directory;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
const path_validate = @import("helpers").path_validate;
const testing = std.testing;

const ListDirectoryInput = struct {
    path: []const u8 = ".",
    hidden: bool = false,
    respect_ignore_files: bool = true,
    /// REQUIRED on the wire. Absolute directory this call works in; a
    /// relative `path` resolves against it. Empty by default so this struct
    /// stays constructible, but the exec rejects an empty value.
    cwd: []const u8 = "",
};

pub fn execListDirectory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // 1. Parse JSON (path/hidden/respect_ignore_files; all optional).
    const parsed = std.json.parseFromSlice(
        ListDirectoryInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_directory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // 2. `cwd` is required (see helpers/path_validate.validateCwd), and the
    //    model's directory resolves against it.
    path_validate.validateCwd(parsed.value.cwd) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_directory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // 2b. Resolve the model-supplied path against the call's `cwd`.
    // `execute_list_directory` reaches `std.Io.Dir.openDirAbsolute`, whose
    // precondition is `assert(path.isAbsolute(...))` — in a Debug build that
    // becomes `unreachable`, which panics and aborts the WHOLE worker instead
    // of returning an error. Passing the raw relative path straight through
    // (what this wrapper used to do) crashed the process for the documented
    // `path: "frontend/src"` call.
    const dir_path_abs = try path_validate.resolveAgainstCwd(ctx.allocator, parsed.value.cwd, parsed.value.path);
    defer ctx.allocator.free(dir_path_abs);

    // 3. Execute the listing.
    const entries = list_directory_mod.execute_list_directory(
        ctx.allocator,
        ctx.io,
        dir_path_abs,
        parsed.value.hidden,
        parsed.value.respect_ignore_files,
    ) catch |err| {
        // The resolved absolute path is the one thing the model can act on
        // here, so it rides along as the explanation's context.
        const err_msg = try error_explain.explain(ctx.allocator, err, dir_path_abs);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_directory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer list_directory_mod.freeEntries(ctx.allocator, entries);

    // 4. Serialise to JSON and wrap. The reported `path` is the resolved
    // absolute path, so the LLM (and the tool-output panel) can see which
    // directory `frontend/src` actually meant.
    const inner = try list_directory_mod.toJSON(ctx.allocator, entries, dir_path_abs);
    const output = try wrapToolOutput(ctx.allocator, "list_directory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// End-to-end proof that the list_directory exec wrapper resolves its
// input BEFORE reaching the underlying tool. Absolute input is used
// as-is; relative input is joined onto the call's required `cwd` (the
// shared rule in helpers/path_validate.zig — see the "resolves against
// the call's cwd" test below).
test "execListDirectory: absolute path passes through and lists entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = try a.dupe(u8, path_buf[0..n]);

    {
        const f = try tmp.dir.createFile(testing.io, "alpha.txt", .{});
        defer f.close(testing.io);
        try tmp.dir.createDirPath(testing.io, "beta");
    }

    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    const ctx = ToolExecContext{
        .allocator = a,
        .io = testing.io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test",
        .model = "test",
        .cwd = root_abs,
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
    };
    // Build JSON with the absolute path embedded. The previous
    // `std.fmt.allocPrint` template did NOT escape backslashes, so on
    // Windows hosts (where root_abs contains `\` chars) the resulting
    // JSON was malformed (`{"path":"C:\Users\foo\bar"}` — `\U` and
    // `\f` are invalid JSON escapes) and `execListDirectory`'s
    // `std.json.parseFromSlice` rejected it, surfacing an error
    // envelope instead of the directory listing. Escape `\` → `\\`
    // (and `"` → `\"`) before splicing the path into the JSON template.
    var escaped_path: std.ArrayList(u8) = .empty;
    defer escaped_path.deinit(a);
    for (root_abs) |c| {
        if (c == '\\' or c == '"') {
            try escaped_path.append(a, '\\');
        }
        try escaped_path.append(a, c);
    }
    const args_json = try std.fmt.allocPrint(
        a,
        "{{\"path\":\"{s}\",\"cwd\":\"{s}\",\"respect_ignore_files\":false}}",
        .{ escaped_path.items, escaped_path.items },
    );
    const tc = agent.ToolCall{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = "list_directory", .arguments = args_json },
    };

    const result = try execListDirectory(ctx, tc);
    defer if (result.output_allocated) a.free(result.output);

    // Success JSON envelope + both entries visible in data.entries.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("success").?.bool);
    const data = obj.get("data").?.object;
    // Absolute input is used as-is (no prefixing, no normalization).
    try testing.expectEqualStrings(root_abs, data.get("path").?.string);
    const entries = data.get("entries").?.array.items;
    try testing.expectEqual(@as(usize, 2), entries.len);
    var saw_alpha = false;
    var saw_beta = false;
    for (entries) |e| {
        const name = e.object.get("name").?.string;
        if (std.mem.eql(u8, name, "alpha.txt")) saw_alpha = true;
        if (std.mem.eql(u8, name, "beta")) saw_beta = true;
    }
    try testing.expect(saw_alpha);
    try testing.expect(saw_beta);
    // No validator error (the validator was removed by the revert).
    try testing.expect(obj.get("error").? == .null);
}

test "execListDirectory: absolute path returns success envelope without validator error" {
    // Absolute paths are used as-is (never joined onto ctx.cwd).
    // Calling with a real absolute directory MUST produce a success
    // envelope containing that same path, and MUST NOT contain a
    // relative-path resolution error.
    //
    // The path comes from a tmpDir `realPath`, NOT a hardcoded `/tmp`:
    // `/tmp` is rooted-but-driveless on Windows, so `resolveAgainstCwd`
    // treats it as relative, joins it onto `ctx.cwd`, and the tool then
    // returns `PathNotAbsolute` — an error envelope, which is the
    // opposite of the assertion below. `std.fs.path.isAbsolute`
    // dispatches to `isAbsoluteWindows` on a Windows host, so only a
    // drive-anchored path passes through untouched.
    //
    // Uses an arena to paper over the current `execListDirectory`
    // implementation allocating an intermediate `inner` XML string
    // (from `list_directory.toJSON`) that is never explicitly freed
    // by the wrapper — `wrapToolOutput` borrows the slice into its
    // own output, so the leak is benign and the arena cleans it up
    // at test teardown.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(std.testing.io, &tmp_buf);
    const abs_dir = tmp_buf[0..tmp_len];

    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    const ctx = ToolExecContext{
        .allocator = a,
        .io = std.testing.io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test_session",
        .model = "test",
        // A DIFFERENT absolute base, so "used as-is" stays observable: had
        // the wrapper joined onto ctx.cwd, the reported path would not
        // match `abs_dir`.
        .cwd = "/home/user/proj",
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
    };

    // `std.json.Stringify` escapes the Windows separators for us (a raw
    // `C:\Users\...` inside a JSON string is malformed). `cwd` is a
    // DIFFERENT absolute base on purpose: absolute input is used as-is, so a
    // wrapper that joined `path` onto `cwd` would fail the assertion below.
    const args = try std.json.Stringify.valueAlloc(a, .{
        .path = abs_dir,
        .cwd = "/home/user/proj",
    }, .{});

    const tool_call = agent.ToolCall{
        .id = "call_1",
        .type = "function",
        .function = .{
            .name = "list_directory",
            .arguments = args,
        },
    };

    const result = try execListDirectory(ctx, tool_call);
    defer if (result.output_allocated) a.free(result.output);

    try testing.expect(result.output_allocated);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    defer parsed2.deinit();
    const obj2 = parsed2.value.object;
    try testing.expect(obj2.get("success").?.bool);
    try testing.expectEqualStrings(abs_dir, obj2.get("data").?.object.get("path").?.string);
    try testing.expect(obj2.get("error").? == .null);
}

// =====================================================================
// Relative-path regression tests (crash: task_1790256349339_0)
//
// The LLM called `list_directory` with `{"path":"frontend/src"}` and the
// wrapper forwarded that relative string straight into
// `std.Io.Dir.openDirAbsolute`, whose precondition is
// `assert(path.isAbsolute(...))`. In a Debug build the assert is
// `unreachable` → panic → abort(), so the ENTIRE worker died (the
// sub-agent thread included) instead of the tool returning an error.
//
// Every test below drives `execListDirectory` with the wire body the
// model actually sends.
// =====================================================================

/// Build a ToolExecContext for the wrapper tests. `session_cwd` stands in
/// for the session's (or worktree's) directory: the tests pass it in the
/// call's own required `cwd` argument, which is what a relative `path` now
/// resolves against.
fn testCtx(
    a: std.mem.Allocator,
    session_cwd: []const u8,
    temperature: *f32,
    thinking: *bool,
) ToolExecContext {
    return .{
        .allocator = a,
        .io = testing.io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test_session",
        .model = "test",
        .cwd = session_cwd,
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = temperature,
        .is_thinking = thinking,
        .environment = null,
    };
}

fn listDirectoryCall(id: []const u8, args: []const u8) agent.ToolCall {
    return .{
        .id = id,
        .type = "function",
        .function = .{ .name = "list_directory", .arguments = args },
    };
}

test "execListDirectory: relative 'frontend/src' resolves against the call's cwd (crash regression)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = try a.dupe(u8, path_buf[0..n]);

    // <root>/frontend/src/index.ts — the layout the crashed session had.
    try tmp.dir.createDirPath(testing.io, "frontend/src");
    {
        const f = try tmp.dir.createFile(testing.io, "frontend/src/index.ts", .{});
        defer f.close(testing.io);
    }

    var temperature: f32 = 0.0;
    var thinking: bool = false;
    const ctx = testCtx(a, root_abs, &temperature, &thinking);

    // The EXACT arguments the model emitted when the worker aborted, plus the
    // `cwd` the tool now requires. `std.json.Stringify` handles the Windows
    // separators in `root_abs`.
    const call_a = try std.json.Stringify.valueAlloc(a, .{
        .path = "frontend/src",
        .cwd = root_abs,
        .hidden = false,
        .respect_ignore_files = true,
    }, .{});
    const result = try execListDirectory(ctx, listDirectoryCall("call_crash", call_a));
    defer if (result.output_allocated) a.free(result.output);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    // Success envelope — BEFORE the fix this line never ran: the process
    // aborted inside openDirAbsolute's assertion.
    try testing.expect(obj.get("success").?.bool);
    try testing.expect(obj.get("error").? == .null);

    const data = obj.get("data").?.object;
    const expected_dir = try std.fs.path.join(a, &.{ root_abs, "frontend/src" });
    // The reported path is the resolved ABSOLUTE path, so the LLM can see
    // which directory its relative path meant.
    try testing.expectEqualStrings(expected_dir, data.get("path").?.string);
    // NB: `count` may legitimately be 0 on this call — `tmpDir` creates the
    // fixture under `.zig-cache/tmp/<rand>`, which lives INSIDE the repo and
    // is covered by the repo's `.gitignore`, so `git check-ignore` filters
    // every entry. That is the gitignore feature working, not a resolution
    // failure. The second call below turns filtering off and asserts the
    // resolved directory really was walked.
    const entries = data.get("entries").?.array.items;
    try testing.expectEqual(data.get("count").?.integer, @as(i64, @intCast(entries.len)));

    // Same relative path, gitignore filtering off — proves `frontend/src`
    // resolved to <cwd>/frontend/src (and not the server process cwd).
    const call_b = try std.json.Stringify.valueAlloc(a, .{
        .path = "frontend/src",
        .cwd = root_abs,
        .hidden = false,
        .respect_ignore_files = false,
    }, .{});
    const result2 = try execListDirectory(ctx, listDirectoryCall("call_crash_no_ignore", call_b));
    defer if (result2.output_allocated) a.free(result2.output);

    const parsed2 = try std.json.parseFromSlice(std.json.Value, a, result2.output, .{});
    defer parsed2.deinit();
    const obj2 = parsed2.value.object;
    try testing.expect(obj2.get("success").?.bool);
    const data2 = obj2.get("data").?.object;
    try testing.expectEqualStrings(expected_dir, data2.get("path").?.string);
    try testing.expectEqual(@as(i64, 1), data2.get("count").?.integer);

    const entries2 = data2.get("entries").?.array.items;
    try testing.expectEqual(@as(usize, 1), entries2.len);
    try testing.expectEqualStrings("index.ts", entries2[0].object.get("name").?.string);
    try testing.expect(!entries2[0].object.get("is_directory").?.bool);
}

test "execListDirectory: omitted path lists the call's cwd (not the process cwd)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = try a.dupe(u8, path_buf[0..n]);
    {
        const f = try tmp.dir.createFile(testing.io, "only_here.txt", .{});
        defer f.close(testing.io);
    }

    var temperature: f32 = 0.0;
    var thinking: bool = false;
    const ctx = testCtx(a, root_abs, &temperature, &thinking);

    const call = try std.json.Stringify.valueAlloc(a, .{
        .cwd = root_abs,
        .respect_ignore_files = false,
    }, .{});
    const result = try execListDirectory(ctx, listDirectoryCall("call_default", call));
    defer if (result.output_allocated) a.free(result.output);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("success").?.bool);

    // The default `"."` means the session cwd itself — NOT the server
    // process cwd, and never an abort.
    const data = obj.get("data").?.object;
    try testing.expectEqualStrings(root_abs, data.get("path").?.string);
    const entries = data.get("entries").?.array.items;
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("only_here.txt", entries[0].object.get("name").?.string);
}

test "execListDirectory: an empty path resolves to the call's cwd" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = try a.dupe(u8, path_buf[0..n]);

    var temperature: f32 = 0.0;
    var thinking: bool = false;
    const ctx = testCtx(a, root_abs, &temperature, &thinking);

    // Some providers emit `"path":""` for an optional string instead of
    // omitting the field (same class of bug as the migrations' empty-slice
    // binding). `std.fs.path.isAbsolute("")` is false, so this used to be
    // another route into the same assertion.
    const call = try std.json.Stringify.valueAlloc(a, .{
        .path = "",
        .cwd = root_abs,
        .respect_ignore_files = false,
    }, .{});
    const result = try execListDirectory(ctx, listDirectoryCall("call_empty", call));
    defer if (result.output_allocated) a.free(result.output);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("success").?.bool);
    try testing.expectEqualStrings(root_abs, obj.get("data").?.object.get("path").?.string);
}

test "execListDirectory: non-existent relative path returns an error envelope, not a crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = path_buf[0..n];
    const missing_dir = try std.fs.path.join(a, &.{ root_abs, "definitely/not/here" });

    var temperature: f32 = 0.0;
    var thinking: bool = false;
    const ctx = testCtx(a, root_abs, &temperature, &thinking);

    const call = try std.json.Stringify.valueAlloc(a, .{
        .path = "definitely/not/here",
        .cwd = root_abs,
        .respect_ignore_files = false,
    }, .{});
    const result = try execListDirectory(ctx, listDirectoryCall("call_missing", call));
    defer if (result.output_allocated) a.free(result.output);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(!obj.get("success").?.bool);
    try testing.expect(obj.get("data").? == .null);
    // The error names the resolved native path so the LLM can self-correct.
    try testing.expect(std.mem.indexOf(u8, obj.get("error").?.string, missing_dir) != null);
}

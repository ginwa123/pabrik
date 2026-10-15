const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const text_replace_mod = pabrikcore.text_replace_tool;
const wrapToolOutput = tools.wrapToolOutput;
const args_repair = @import("tools_args_repair.zig");
const error_explain = @import("tools_error_explain.zig");
const path_validate = @import("helpers").path_validate;
const testing = std.testing;

/// The tool's contract, in the words we want the model to read back when it
/// gets the arguments wrong. Kept next to the parse site so adding a field
/// to `TextReplaceInput` and adding it here stay the same edit.
const required_field_help = "text_replace takes exactly four fields: `path`, `old_str`, `new_str`, `cwd`.";

/// Build the tool-facing message for arguments that did not decode into
/// `TextReplaceInput`.
fn describeArgsFailure(allocator: std.mem.Allocator, args: []const u8, err: anyerror) ![]u8 {
    if (err != error.MissingField) {
        return std.fmt.allocPrint(
            allocator,
            "text_replace arguments are not valid JSON. " ++
                "The usual cause is a Windows path written with single backslashes " ++
                "(write `C:\\Users\\me` as `C:\\\\Users\\\\me` inside the JSON string). " ++
                "Also check that the call was not cut off mid-object and that no " ++
                "```json fence wrapped it. Re-send the arguments as one valid JSON object. " ++
                "({s}: {s})",
            .{ @errorName(err), if (args.len > 200) args[0..200] else args },
        );
    }

    // Valid JSON, but not all three fields.
    const required = [_][]const u8{ "path", "old_str", "new_str", "cwd" };
    const near_misses = [_][]const u8{ "new_string", "old_string", "file_path", "filepath", "path_str" };

    var missing: std.ArrayList(u8) = .empty;
    errdefer missing.deinit(allocator);
    var unknown_hint: ?[]const u8 = null;

    if (std.json.parseFromSlice(std.json.Value, allocator, args, .{})) |p| {
        defer p.deinit();
        if (p.value == .object) {
            const obj = &p.value.object;
            for (required) |field| {
                if (obj.get(field) == null) {
                    if (missing.items.len > 0) try missing.appendSlice(allocator, ", ");
                    try missing.appendSlice(allocator, field);
                }
            }
            for (near_misses) |near| {
                if (unknown_hint == null and obj.get(near) != null) unknown_hint = near;
            }
        }
    } else |_| {}

    if (missing.items.len == 0) try missing.appendSlice(allocator, "path, old_str, new_str");

    if (unknown_hint) |near| {
        defer missing.deinit(allocator);
        return std.fmt.allocPrint(
            allocator,
            "text_replace is missing required field(s): {s}. " ++
                "You sent `{s}`, which is not a field of this tool — rename it to the " ++
                "exact field name. {s}",
            .{ missing.items, near, required_field_help },
        );
    }
    defer missing.deinit(allocator);
    return std.fmt.allocPrint(
        allocator,
        "text_replace is missing required field(s): {s}. {s}",
        .{ missing.items, required_field_help },
    );
}

pub fn execTextReplace(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // A Windows path is the one argument string a tool call cannot avoid, and
    // it is full of backslashes.
    const repaired_args = (try args_repair.repairToolCallArguments(ctx.allocator, tc.function.arguments));
    defer if (repaired_args) |r| r.deinit(ctx.allocator);
    const args = if (repaired_args) |r| r.slice() else tc.function.arguments;

    const parsed = std.json.parseFromSlice(
        text_replace_mod.TextReplaceInput,
        ctx.allocator,
        args,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try describeArgsFailure(ctx.allocator, tc.function.arguments, err);
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // The repair cannot leave a legal escape alone, so `…\.config\pabrik`
    // decodes to a real newline in the middle of the path.
    var owned_path: ?[]u8 = null;
    defer if (owned_path) |p| ctx.allocator.free(p);
    const path = if (try args_repair.reexpandPathControlChars(ctx.allocator, parsed.value.path)) |fixed| blk: {
        owned_path = fixed;
        break :blk fixed;
    } else parsed.value.path;

    // `cwd` is a path as well, so it needs the SAME re-expansion the block
    // above gives `path`.
    var owned_cwd: ?[]u8 = null;
    defer if (owned_cwd) |c| ctx.allocator.free(c);
    const cwd = if (try args_repair.reexpandPathControlChars(ctx.allocator, parsed.value.cwd)) |fixed| blk: {
        owned_cwd = fixed;
        break :blk fixed;
    } else parsed.value.cwd;

    // Same rule as every other path-taking tool: `cwd` is REQUIRED (the
    // directory this call works in — see helpers/path_validate.zig) and a
    // relative `path` is resolved against it BEFORE any file is touched (an
    path_validate.validateCwd(cwd) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const path_abs = try path_validate.resolveAgainstCwd(ctx.allocator, cwd, path);
    defer ctx.allocator.free(path_abs);

    var tr_result = text_replace_mod.executeTextReplace(
        ctx.allocator,
        ctx.io,
        path_abs,
        parsed.value.old_str,
        parsed.value.new_str,
    ) catch |err| {
        const inner = try text_replace_mod.toJSONError(
            ctx.allocator,
            err,
            path_abs,
            parsed.value.old_str,
        );
        const err_msg = try text_replace_mod.errorMessageFor(ctx.allocator, err, path_abs);
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    defer tr_result.deinit(ctx.allocator);

    const inner = try text_replace_mod.toJSONSuccess(ctx.allocator, tr_result, path_abs);
    const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

test "execTextReplace: a missing cwd is refused with an actionable message" {
    // `cwd` is required, and the refusal is the only thing that teaches the
    // model the field exists — so the message must NAME it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const env = try runTr(a, "{\"path\":\"/tmp/x.go\",\"old_str\":\"a\",\"new_str\":\"b\"}");
    try testing.expect(!env.object.get("success").?.bool);
    const msg = env.object.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, msg, "cwd") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "required") != null);
    // The raw Zig error name never reaches the model.
    try testing.expect(std.mem.indexOf(u8, msg, "MandatoryCwdMissing") == null);
}

// ---------------------------------------------------------------------------
// Overwrite-contract regression tests (added 2026-08-15) text_replace
// internally writes the modified content back to disk via

fn minimalCtxTr(allocator: std.mem.Allocator) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = testing.io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test_session",
        .model = "test_model",
        .cwd = "/tmp",
        .api_key = "test_key",
        .base_url = "test_base",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
    };
}

/// Helper: assert the exec output is a success JSON envelope whose
/// `data.path` equals the expected path.
fn expectTextReplaceSuccess(output: []const u8, expected_path: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("success").?.bool);
    try testing.expectEqualStrings(expected_path, obj.get("data").?.object.get("path").?.string);
}

/// Args JSON for one `text_replace` call.
fn trArgs(a: std.mem.Allocator, target_path: []const u8, old_str: []const u8, new_str: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .path = target_path,
        .old_str = old_str,
        .new_str = new_str,
        .cwd = std.fs.path.dirname(target_path) orelse target_path,
    }, .{});
}

fn readAllTr(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(4 << 20));
}

// CONTRACT: execTextReplace must overwrite the target file (truncate + write
// new content), not append.
test "execTextReplace: writes back the full modified file (truncates + overwrites, no append)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = path_buf[0..n];

    const target_name = "tr_overwrite.txt";
    const target_path = try std.fs.path.join(a, &.{ root_abs, target_name });

    // Pre-seed with a long string containing the marker we'll replace
    const original = "<<<REPLACE_ME>>> then keep this trailing junk after the marker to detect any append-mode corruption";
    {
        const f = try tmp.dir.createFile(testing.io, target_name, .{});
        defer f.close(testing.io);
        try std.Io.File.writeStreamingAll(f, testing.io, original);
    }

    // Build args: replace the marker with a SHORTER string. If createFile
    // appended instead of truncating, the trailing junk would still be
    // visible AFTER the new short content.
    {
        const args = try trArgs(a, target_path, "<<<REPLACE_ME>>>", "[OK]");
        const tc = agent.ToolCall{
            .id = "call_tr_ow1",
            .type = "function",
            .function = .{ .name = "text_replace", .arguments = args },
        };

        const result = try execTextReplace(minimalCtxTr(a), tc);
        defer if (result.output_allocated) a.free(result.output);

        try expectTextReplaceSuccess(result.output, target_path);

        // Read back — file must be EXACTLY "[OK] then keep this trailing junk
        // after the marker to detect any append-mode corruption"
        const expected = "[OK] then keep this trailing junk after the marker to detect any append-mode corruption";
        const read = try readAllTr(a, target_path);
        try testing.expectEqualStrings(expected, read);
        // File size must match the new length (not original.len) — proves
        // truncation happened, not append.
        try testing.expectEqual(@as(usize, expected.len), read.len);
        try testing.expect(read.len != original.len); // sanity: the two really differ
    }
}

// CONTRACT: execTextReplace must OVERWRITE, not fail or skip, when called
// on an existing file with content that exactly matches old_str.
test "execTextReplace: existing file with matching content is modified in place" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = path_buf[0..n];

    const target_name = "tr_match.txt";
    const target_path = try std.fs.path.join(a, &.{ root_abs, target_name });

    {
        const f = try tmp.dir.createFile(testing.io, target_name, .{});
        defer f.close(testing.io);
        try std.Io.File.writeStreamingAll(f, testing.io, "Hello World\n");
    }

    {
        const args2 = try trArgs(a, target_path, "Hello", "Goodbye");
        const tc = agent.ToolCall{
            .id = "call_tr_match",
            .type = "function",
            .function = .{ .name = "text_replace", .arguments = args2 },
        };

        const result = try execTextReplace(minimalCtxTr(a), tc);
        defer if (result.output_allocated) a.free(result.output);

        try expectTextReplaceSuccess(result.output, target_path);
        const read = try readAllTr(a, target_path);
        try testing.expectEqualStrings("Goodbye World\n", read);
    }
}

// ---------------------------------------------------------------------------
// Windows: absolute paths are the one string a tool call cannot avoid, and on
// Windows they are full of `\` separators.

/// Runs `execTextReplace` and returns the parsed envelope.
fn runTr(a: std.mem.Allocator, args: []const u8) !std.json.Value {
    const tc = agent.ToolCall{
        .id = "call_tr_win",
        .type = "function",
        .function = .{ .name = "text_replace", .arguments = args },
    };
    const result = try execTextReplace(minimalCtxTr(a), tc);
    defer if (result.output_allocated) a.free(result.output);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    return parsed.value;
}

fn errorTextOf(env: std.json.Value) []const u8 {
    return env.object.get("error").?.string;
}

// A Windows path arriving with RAW backslashes must still replace text. This
// has to be provable on Linux too, or the bug stays invisible until a Windows
// user hits it.
test "execTextReplace: Windows path with raw backslashes is repaired, not rejected" {
    const builtin = @import("builtin");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root = path_buf[0..n];

    const file_name = if (builtin.os.tag == .windows) "win_raw.txt" else "win\\raw.txt";
    {
        const f = try tmp.dir.createFile(testing.io, file_name, .{});
        defer f.close(testing.io);
        try std.Io.File.writeStreamingAll(f, testing.io, "Hello World\n");
    }
    // `/` on both hosts: on Windows the tmpdir path already carries the
    // backslashes that matter, and `std.fs` accepts `/` there too, so the
    // file is still found.
    const target_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, file_name });

    // `cwd` must be exercised on BOTH hosts, not just Windows.
    const cwd_rel: []const u8 = if (builtin.os.tag == .windows) "" else "win\\tcwd";
    if (cwd_rel.len > 0) try tmp.dir.createDirPath(testing.io, cwd_rel);
    const cwd_abs = if (cwd_rel.len == 0)
        root
    else
        try std.fmt.allocPrint(a, "{s}/{s}", .{ root, cwd_rel });

    // The arguments a model writes when it pastes the path verbatim: every
    // separator is a single `\`, which is what RFC 8259 §7 rejects.
    const args = try std.fmt.allocPrint(
        a,
        "{{\"path\":\"{s}\",\"cwd\":\"{s}\",\"old_str\":\"Hello\",\"new_str\":\"Goodbye\"}}",
        .{ target_path, cwd_abs },
    );
    try testing.expect(std.mem.indexOf(u8, args, "\\") != null);

    const env = try runTr(a, args);
    if (!env.object.get("success").?.bool) {
        std.debug.print("text_replace said: {s}\n", .{errorTextOf(env)});
    }
    try testing.expect(env.object.get("success").?.bool);
    try testing.expectEqualStrings(target_path, env.object.get("data").?.object.get("path").?.string);

    const read = try readAllTr(a, target_path);
    try testing.expectEqualStrings("Goodbye World\n", read);
}

// The reported failure mode: the arguments are the ones a model emitted on
// Windows, and the model also mis-keyed the replacement field.
test "execTextReplace: wrong field name is reported as a named, actionable error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Shape lifted from the reported call: `new_string` instead of
    // `new_str`, and no `old_str` at all.
    const args =
        \\{"path":"C:\\Users\\gilang.trisetya\\.config\\pabrik\\.worktrees\\sb02\\internal\\domain\\sales_invoice\\test.go","new_string":"x"}
    ;

    const env = try runTr(a, args);
    try testing.expect(!env.object.get("success").?.bool);

    const err = errorTextOf(env);
    // Names the fields, not the Zig error.
    try testing.expect(std.mem.indexOf(u8, err, "old_str") != null);
    try testing.expect(std.mem.indexOf(u8, err, "new_str") != null);
    // Spells out the near-miss key the model actually sent.
    try testing.expect(std.mem.indexOf(u8, err, "new_string") != null);
    // Must not leak a raw Zig error name at the model.
    try testing.expect(std.mem.indexOf(u8, err, "MissingField") == null);
}

test "execTextReplace: unparseable arguments report the real problem, not MissingField" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Truncated mid-call (max_tokens ran out) — nothing to repair.
    const env = try runTr(a, "{\"path\":\"/tmp/a.go\",\"old_str\":\"x\"");
    try testing.expect(!env.object.get("success").?.bool);
    const err = errorTextOf(env);
    try testing.expect(std.mem.indexOf(u8, err, "valid JSON") != null);
    try testing.expect(std.mem.indexOf(u8, err, "MissingField") == null);
}

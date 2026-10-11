const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const write_file_mod = pabrikcore.write_file;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
const testing = std.testing;

/// Escape a string for inclusion as a JSON string literal value (between
/// the quotes — caller supplies the surrounding `"..."` template).
/// Escapes `\` → `\\` and `"` → `\"` (RFC 8259 §7). Other characters
/// (including control codes / non-ASCII) are passed through verbatim;
/// the test fixtures only contain ASCII so we don't bother with
/// `\u00XX` sequences here. Caller must `deinit` the returned slice.
fn jsonEscapeInto(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        if (c == '\\' or c == '"') {
            try out.append(allocator, '\\');
        }
        try out.append(allocator, c);
    }
    return out;
}

pub fn execWriteFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        write_file_mod.WriteFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "write_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const write_result = write_file_mod.writeFile(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const inner = try write_file_mod.toJSONError(ctx.allocator, err, parsed.value.path);
        const err_msg = try error_explain.explain(ctx.allocator, err, parsed.value.path);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "write_file", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const inner = try write_file_mod.toJSONSuccess(ctx.allocator, write_result);
    write_result.deinit(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "write_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ---------------------------------------------------------------------------
// Overwrite-contract regression tests (added 2026-08-15)
//
// PR #261 reverted the absolute-path ban from PR #259. After the revert the
// underlying `writeFile` is still expected to OVERWRITE existing files (the
// default `truncate: bool = true` on `std.Io.Dir.CreateFileOptions` is what
// guarantees this). These tests pin that contract end-to-end through the
// exec wrapper — the same path the agentic loop invokes when the LLM calls
// `write_file` with an already-existing target.
//
// Why the exec wrapper (not just writeFile): the underlying function had 3
// overwrite tests already (write_file_test.zig lines 91, 118, 296), and all
// pass — so the contract was already pinned at the function level. But after
// the revert removed the `tools_exec_write_file.zig` inline tests, there was
// NO coverage for the path that the LLM actually exercises (parse JSON →
// call writeFile → wrap XML). A future refactor that swaps `createFile` for
// `openFile` or drops `truncate: true` would slip through silently. These
// tests close that gap.
// ---------------------------------------------------------------------------

/// Helper: build a minimal ToolExecContext whose fields execWriteFile
/// doesn't actually read (db, logger, config, etc.). Mirrors the pattern
/// used by `tools_exec_list_directory.zig` test (the only surviving
/// inline exec-wrapper test after the revert).
fn minimalCtx(allocator: std.mem.Allocator) ToolExecContext {
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

/// Helper: read the full content of a file into a freshly-allocated slice.
fn readAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(4 << 20));
}

/// Helper: assert the exec output is a success JSON envelope whose
/// `data.file_write` equals the expected path.
fn expectWriteFileSuccess(output: []const u8, expected_path: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("success").?.bool);
    try testing.expectEqualStrings(expected_path, obj.get("data").?.object.get("file_write").?.string);
}

/// Helper: return the on-disk size of a file (0 if missing).
fn fileSize(path: []const u8) u64 {
    var f = std.Io.Dir.cwd().openFile(testing.io, path, .{}) catch return 0;
    defer f.close(testing.io);
    return std.Io.File.length(f, testing.io) catch 0;
}

// CONTRACT: execWriteFile must overwrite an existing file with shorter
// content — the OLD tail bytes must be GONE after the call.
test "execWriteFile: overwrites existing file (truncates to shorter content)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = path_buf[0..n];

    const target_name = "overwrite_short.txt";
    const target_path = try std.fs.path.join(a, &.{ root_abs, target_name });

    // Pre-seed with 100 'A' bytes
    {
        const f = try tmp.dir.createFile(testing.io, target_name, .{});
        defer f.close(testing.io);
        var buf: [100]u8 = undefined;
        @memset(&buf, 'A');
        try std.Io.File.writeStreamingAll(f, testing.io, &buf);
    }
    try testing.expectEqual(@as(u64, 100), fileSize(target_path));

    // Call execWriteFile with a 5-byte payload. Escape `\` and `"`
    // in the path so the resulting JSON parses on Windows hosts (where
    // `realPath()` returns backslash-separated paths). Otherwise
    // `std.json.parseFromSlice` rejects the malformed `{"path":"C:\..."}`.
    {
        var escaped = try jsonEscapeInto(a, target_path);
        defer escaped.deinit(a);
        const args = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\",\"content\":\"BBBBB\"}}", .{escaped.items});
        const tc = agent.ToolCall{
            .id = "call_ow1",
            .type = "function",
            .function = .{ .name = "write_file", .arguments = args },
        };

        const result = try execWriteFile(minimalCtx(a), tc);
        defer if (result.output_allocated) a.free(result.output);

        // The wrapper must report success
        try expectWriteFileSuccess(result.output, target_path);
    }

    // The file must be TRUNCATED to the new length, NOT appended/appended
    try testing.expectEqual(@as(u64, 5), fileSize(target_path));
    const read = try readAll(a, target_path);
    try testing.expectEqualStrings("BBBBB", read);
}

// CONTRACT: execWriteFile must overwrite an existing file with LONGER
// content — the file must extend to the new length and contain ONLY the
// new bytes (no leftover tail from the original shorter file).
test "execWriteFile: overwrites existing file (extends to longer content)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = path_buf[0..n];

    const target_name = "overwrite_long.txt";
    const target_path = try std.fs.path.join(a, &.{ root_abs, target_name });

    // Pre-seed with 5 'X' bytes
    {
        const f = try tmp.dir.createFile(testing.io, target_name, .{});
        defer f.close(testing.io);
        try std.Io.File.writeStreamingAll(f, testing.io, "XXXXX");
    }
    try testing.expectEqual(@as(u64, 5), fileSize(target_path));

    const longer_payload = "this is a much longer string than before";
    // Escape `\` and `"` in the path (Windows JSON-parse fix).
    {
        var escaped = try jsonEscapeInto(a, target_path);
        defer escaped.deinit(a);
        const args = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\",\"content\":\"{s}\"}}", .{ escaped.items, longer_payload });
        const tc = agent.ToolCall{
            .id = "call_ow2",
            .type = "function",
            .function = .{ .name = "write_file", .arguments = args },
        };

        const result = try execWriteFile(minimalCtx(a), tc);
        defer if (result.output_allocated) a.free(result.output);

        try expectWriteFileSuccess(result.output, target_path);
        try testing.expectEqual(@as(u64, longer_payload.len), fileSize(target_path));
        const read = try readAll(a, target_path);
        try testing.expectEqualStrings(longer_payload, read);
        // CRITICAL: no leftover 'X' bytes — would prove the file was APPENDED,
        // not truncated-and-overwritten.
        try testing.expect(std.mem.indexOf(u8, read, "X") == null);
    }
}

// CONTRACT: execWriteFile must OVERWRITE, not append, when called twice in
// a row with the same path. The second call's content must fully REPLACE
// the first — not be appended.
test "execWriteFile: two consecutive calls — second content wins, no append" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = path_buf[0..n];

    const target_name = "consecutive.txt";
    const target_path = try std.fs.path.join(a, &.{ root_abs, target_name });

    // First call: 13 bytes. Escape the path (Windows JSON-parse fix).
    {
        var escaped = try jsonEscapeInto(a, target_path);
        defer escaped.deinit(a);
        const args1 = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\",\"content\":\"first version\"}}", .{escaped.items});
        const tc1 = agent.ToolCall{
            .id = "call_seq1",
            .type = "function",
            .function = .{ .name = "write_file", .arguments = args1 },
        };
        const r1 = try execWriteFile(minimalCtx(a), tc1);
        defer if (r1.output_allocated) a.free(r1.output);
        try expectWriteFileSuccess(r1.output, target_path);
    }

    // Second call: longer, DIFFERENT content.
    {
        var escaped = try jsonEscapeInto(a, target_path);
        defer escaped.deinit(a);
        const args2 = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\",\"content\":\"second version wins\"}}", .{escaped.items});
        const tc2 = agent.ToolCall{
            .id = "call_seq2",
            .type = "function",
            .function = .{ .name = "write_file", .arguments = args2 },
        };
        const r2 = try execWriteFile(minimalCtx(a), tc2);
        defer if (r2.output_allocated) a.free(r2.output);
        try expectWriteFileSuccess(r2.output, target_path);
    }

    // File must contain ONLY the second call's content — not "first version" + tail
    const read = try readAll(a, target_path);
    try testing.expectEqualStrings("second version wins", read);
    try testing.expectEqual(@as(usize, "second version wins".len), read.len);
}

// CONTRACT: execWriteFile must overwrite with empty content too — the
// file must end up at exactly 0 bytes (not "the old content minus the
// new content size" — i.e. not partial truncation).
test "execWriteFile: overwriting with empty content truncates to zero bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = path_buf[0..n];

    const target_name = "empty_overwrite.txt";
    const target_path = try std.fs.path.join(a, &.{ root_abs, target_name });

    // Pre-seed
    {
        const f = try tmp.dir.createFile(testing.io, target_name, .{});
        defer f.close(testing.io);
        try std.Io.File.writeStreamingAll(f, testing.io, "this content will be wiped");
    }
    try testing.expectEqual(@as(u64, 26), fileSize(target_path));

    // Escape `\` and `"` in the path (Windows JSON-parse fix).
    {
        var escaped = try jsonEscapeInto(a, target_path);
        defer escaped.deinit(a);
        const args2 = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\",\"content\":\"\"}}", .{escaped.items});
        const tc = agent.ToolCall{
            .id = "call_empty",
            .type = "function",
            .function = .{ .name = "write_file", .arguments = args2 },
        };

        const result = try execWriteFile(minimalCtx(a), tc);
        defer if (result.output_allocated) a.free(result.output);
        try expectWriteFileSuccess(result.output, target_path);

        try testing.expectEqual(@as(u64, 0), fileSize(target_path));
    }
}

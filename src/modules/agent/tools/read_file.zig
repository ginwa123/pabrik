const std = @import("std");
const posix = std.posix;
const schemas = @import("schemas.zig");
const path_validate = @import("helpers").path_validate;
const invalidPathReason = path_validate.invalidPathReason;
const text_normalize = @import("helpers").text_normalize;
const normalizeLineEndings = text_normalize.normalizeLineEndings;
const BashInput = schemas.BashInput;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

pub const ReadFileResult = struct {
    content: []u8,
    total_lines: usize,
    start_line: usize,
    end_line: usize,

    pub fn deinit(self: ReadFileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const ReadFileOptions = struct {
    offset: ?usize = null, // line number to start from (0-indexed)
    limit: ?usize = null, // max number of lines to return
};

pub fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    opts: ReadFileOptions,
) !ReadFileResult {
    // The LLM chooses this path. On Windows a malformed NT name makes std's
    // Io backend `ntstatusBug()` — a panic that kills the process, not just
    // this call. See helpers/path_validate.zig.
    if (invalidPathReason(path)) |reason| {
        std.log.debug("read_file rejected path: {s}", .{reason});
        return error.InvalidPathReason;
    }

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer std.Io.File.close(file, io);

    const on_disk = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(std.math.maxInt(usize)));
    defer allocator.free(on_disk);

    // Hand the model the LF form. `text_replace` normalizes the target file
    // to LF BEFORE it searches for `old_str` (see its `had_crlf` branch), so
    // returning the raw CRLF bytes here guarantees that anything the model
    // copies out of this read fails to match on a Windows-authored file.
    // The bytes on disk are untouched — this only changes what the model
    // sees, and a bare `\r` (a Mac Classic line ending) is preserved by
    // `normalizeLineEndings` rather than being silently eaten.
    const normalized = if (std.mem.indexOf(u8, on_disk, "\r\n") != null)
        try normalizeLineEndings(allocator, on_disk)
    else
        null;
    defer if (normalized) |n| allocator.free(n);
    const raw = normalized orelse on_disk;

    // count lines
    var total_lines: usize = 0;
    for (raw) |c| {
        if (c == '\n') total_lines += 1;
    }
    // handle no trailing newline
    if (raw.len > 0 and raw[raw.len - 1] != '\n') total_lines += 1;

    const offset = opts.offset orelse 0;
    const limit = opts.limit orelse total_lines;

    if (offset >= total_lines and total_lines > 0) {
        return error.OffsetOutOfRange;
    }

    // collect lines in [offset, offset+limit)
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var line_idx: usize = 0;
    var line_start: usize = 0;
    var captured: usize = 0;
    var end_line: usize = offset;

    for (raw, 0..) |c, i| {
        if (c == '\n' or i == raw.len - 1) {
            const line_end = if (c == '\n') i + 1 else i + 1;
            if (line_idx >= offset and captured < limit) {
                // Raw content only — no per-line number prefix. Callers derive
                // absolute 1-indexed line numbers as start_line + 1 + index.
                try out.appendSlice(allocator, raw[line_start..line_end]);
                captured += 1;
                end_line = line_idx;
            }
            line_idx += 1;
            line_start = line_end;
            if (captured >= limit) break;
        }
    }

    return ReadFileResult{
        .content = try out.toOwnedSlice(allocator),
        .total_lines = total_lines,
        .start_line = offset,
        .end_line = end_line,
    };
}

/// JSON payload for a successful read: mirrors the old `<path>` /
/// `<content>` / `<total_lines>` / `<start_line>` / `<end_line>` tags 1:1.
/// `content` is raw file text — `<`/`&` need no escaping in JSON.
pub const ReadFileJSON = struct {
    path: []const u8,
    content: []const u8,
    total_lines: usize,
    start_line: usize,
    end_line: usize,
};

pub fn toJSONSuccess(allocator: std.mem.Allocator, result: ReadFileResult, path: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, ReadFileJSON{
        .path = path,
        .content = result.content,
        .total_lines = result.total_lines,
        .start_line = result.start_line,
        .end_line = result.end_line,
    }, .{});
}

pub const read_file_tool_system_prompt =
    \\## Read File Tool — Behavior
    \\Use `read_file` to read file contents.
    \\- `cwd` is REQUIRED: the absolute directory this call works in. A relative `path` resolves against it; an absolute `path` is used as-is.
    \\- For large files, use `offset` + `limit` to paginate (500 lines per page). Check `total_lines` first.
    \\- Content is raw (no per-line number prefixes). Derive absolute 1-indexed line numbers as `start_line + 1 + index`.
    \\- Never guess offsets — read sequentially.
    \\
;

pub const read_file_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "read_file",
        .description =
        \\Read a file by path. Returns content, total_lines, start_line, end_line.
        \\
        \\Omit offset/limit to read the whole file; paginate large files with offset + limit (recommended page: 500 lines), checking total_lines from a prior call first — never guess offsets. Content is raw, with no line-number prefixes: absolute 1-indexed line numbers are start_line + 1 + index.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Path to the file. Absolute, or relative to `cwd`.",
                },
                .{
                    .name = "offset",
                    .type = "number",
                    .description = "Line to start from (0-indexed). Default: 0.",
                },
                .{
                    .name = "limit",
                    .type = "number",
                    .description = "Max lines to return. Default: entire file.",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "REQUIRED. Absolute directory this call works in; a relative `path` resolves against it. Pass the tree you are editing (your worktree root, NOT the server's directory).",
                },
            },
            .required = &.{ "path", "cwd" },
        },
        .system_prompt = read_file_tool_system_prompt,
    },
};

// ─── Raw-content contract tests ─────────────────────────────────────────
// Content is raw (no per-line number prefixes). Positioning comes from
// start_line/end_line/total_lines; absolute 1-indexed line numbers are
// start_line + 1 + index.

test "read_file returns raw content without line-number prefixes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "raw.txt", .data = "alpha\nbeta\ngamma\n" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const abs = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..n], "raw.txt" });
    defer std.testing.allocator.free(abs);

    var result = try readFile(std.testing.allocator, std.testing.io, abs, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\n", result.content);
    try std.testing.expectEqual(@as(usize, 3), result.total_lines);
    try std.testing.expectEqual(@as(usize, 0), result.start_line);
    try std.testing.expectEqual(@as(usize, 2), result.end_line);
}

test "read_file paginated slice is raw with correct start/end lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "page.txt", .data = "l1\nl2\nl3\nl4\n" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const abs = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..n], "page.txt" });
    defer std.testing.allocator.free(abs);

    var result = try readFile(std.testing.allocator, std.testing.io, abs, .{ .offset = 1, .limit = 2 });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("l2\nl3\n", result.content);
    try std.testing.expectEqual(@as(usize, 4), result.total_lines);
    try std.testing.expectEqual(@as(usize, 1), result.start_line);
    try std.testing.expectEqual(@as(usize, 2), result.end_line);
}

// ─── CRLF contract ───────────────────────────────────────────────────────
// `text_replace` normalizes the file to LF *before* it searches for
// `old_str` (text_replace.zig: `had_crlf` → `normalizeLineEndings` →
// `indexOf`). So the string the model copies out of `read_file` has to be
// the LF form, or every exact-match edit against a Windows-authored file
// fails with OldStrNotFound. That makes this a correctness contract
// between the two tools, not a cosmetic one.
const text_replace = @import("text_replace.zig");

fn writeTmp(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8, data: []const u8) ![]const u8 {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..n], name });
}

test "read_file strips CR from a CRLF file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try writeTmp(std.testing.allocator, &tmp, "crlf.txt", "alpha\r\nbeta\r\ngamma\r\n");
    defer std.testing.allocator.free(abs);

    var result = try readFile(std.testing.allocator, std.testing.io, abs, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOfScalar(u8, result.content, '\r') == null);
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\n", result.content);
    // Pagination metadata must be untouched by the normalization: CRLF has
    // exactly one '\n' per line, so the counts cannot move.
    try std.testing.expectEqual(@as(usize, 3), result.total_lines);
    try std.testing.expectEqual(@as(usize, 0), result.start_line);
    try std.testing.expectEqual(@as(usize, 2), result.end_line);
}

test "read_file CRLF paginated slice is LF and correctly bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try writeTmp(std.testing.allocator, &tmp, "crlf_page.txt", "l1\r\nl2\r\nl3\r\nl4\r\n");
    defer std.testing.allocator.free(abs);

    var result = try readFile(std.testing.allocator, std.testing.io, abs, .{ .offset = 1, .limit = 2 });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("l2\nl3\n", result.content);
    try std.testing.expectEqual(@as(usize, 4), result.total_lines);
    try std.testing.expectEqual(@as(usize, 1), result.start_line);
    try std.testing.expectEqual(@as(usize, 2), result.end_line);
}

// THE end-to-end contract: whatever read_file hands the model must be
// directly usable as `old_str` by text_replace. Before the fix this failed
// with OldStrNotFound on every CRLF file, because the model echoed the
// '\r' it had been shown and text_replace searches LF-normalized content.
test "read_file output is directly usable as text_replace old_str (CRLF round trip)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try writeTmp(std.testing.allocator, &tmp, "roundtrip.txt", "package main\r\n\r\nfunc main() {}\r\n");
    defer std.testing.allocator.free(abs);

    var result = try readFile(std.testing.allocator, std.testing.io, abs, .{});
    defer result.deinit(std.testing.allocator);

    var applied = text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        abs,
        result.content,
        "package main\n\nfunc main() { }\n",
    ) catch |err| {
        std.debug.print("text_replace rejected what read_file returned: {s}\n", .{@errorName(err)});
        return err;
    };
    defer applied.deinit(std.testing.allocator);

    const final = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        abs,
        std.testing.allocator,
        std.Io.Limit.limited(1 << 20),
    );
    defer std.testing.allocator.free(final);
    // The contract under test is that the exact string read_file handed the
    // model was ACCEPTED by text_replace. What text_replace then writes back
    // (LF here) is its own concern and deliberately not asserted here.
    try std.testing.expectEqualStrings("package main\n\nfunc main() { }\n", final);
}

// Guard against over-normalizing: a bare CR is a Mac Classic line ending,
// not a CRLF artefact, and must survive. Same for an LF file.
test "read_file leaves LF files and bare-CR content alone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const lf = try writeTmp(std.testing.allocator, &tmp, "lf.txt", "a\nb\n");
    defer std.testing.allocator.free(lf);
    {
        var r = try readFile(std.testing.allocator, std.testing.io, lf, .{});
        defer r.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("a\nb\n", r.content);
    }

    const bare = try writeTmp(std.testing.allocator, &tmp, "bare_cr.txt", "a\rb");
    defer std.testing.allocator.free(bare);
    {
        var r = try readFile(std.testing.allocator, std.testing.io, bare, .{});
        defer r.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("a\rb", r.content);
    }
}

test "toJSONSuccess payload carries raw content and line range" {
    const content = try std.testing.allocator.dupe(u8, "foo\nbar\n");
    const result = ReadFileResult{ .content = content, .total_lines = 2, .start_line = 0, .end_line = 1 };
    defer result.deinit(std.testing.allocator);

    const payload = try toJSONSuccess(std.testing.allocator, result, "/x.txt");
    defer std.testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("/x.txt", obj.get("path").?.string);
    try std.testing.expectEqualStrings("foo\nbar\n", obj.get("content").?.string);
    try std.testing.expectEqual(@as(i64, 2), obj.get("total_lines").?.integer);
    try std.testing.expectEqual(@as(i64, 0), obj.get("start_line").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("end_line").?.integer);
}

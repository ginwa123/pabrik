const std = @import("std");
const posix = std.posix;
const schemas = @import("schemas.zig");
const path_validate = @import("helpers").path_validate;
const invalidPathReason = path_validate.invalidPathReason;
const text_normalize = @import("helpers").text_normalize;
const normalizeLineEndings = text_normalize.normalizeLineEndings;
const helpers_image = @import("helpers").image;
const BashInput = schemas.BashInput;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

pub const ReadFileImage = struct {
    mime: []const u8,
    url: []u8,
    byte_len: usize,
};

pub const ReadFileResult = struct {
    content: []u8,
    total_lines: usize,
    start_line: usize,
    end_line: usize,
    image: ?ReadFileImage = null,

    pub fn deinit(self: ReadFileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.image) |img| allocator.free(img.url);
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

    return shapeContent(allocator, on_disk, opts);
}

/// The file's bytes, shaped into the paginated result. Shared by the host read
/// above and the guest read in `execReadFile`, so a read answers with the same
/// shape whichever substrate produced the bytes.
pub fn shapeContent(allocator: std.mem.Allocator, on_disk: []const u8, opts: ReadFileOptions) !ReadFileResult {
    // An image is answered with the image, not with its bytes as text: a
    // screenshot handed to a model as mojibake costs context and says nothing.
    if (helpers_image.sniffImageMime(on_disk)) |mime| return shapeImage(allocator, on_disk, mime);
    if (helpers_image.looksBinary(on_disk)) return error.BinaryFileNotText;

    // Hand the model the LF form.
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

fn shapeImage(allocator: std.mem.Allocator, bytes: []const u8, mime: []const u8) !ReadFileResult {
    if (bytes.len > helpers_image.max_inline_bytes) return error.ImageTooLarge;
    return ReadFileResult{
        .content = try allocator.dupe(u8, ""),
        .total_lines = 0,
        .start_line = 0,
        .end_line = 0,
        .image = .{
            .mime = mime,
            .url = try helpers_image.toDataUrl(allocator, mime, bytes),
            .byte_len = bytes.len,
        },
    };
}

/// JSON payload for an image read. The image itself rides on the tool result's
/// `image_url`, so this text stays small enough to keep forever.
pub const ReadFileImageJSON = struct {
    path: []const u8,
    mime: []const u8,
    bytes: usize,
    attached_as: []const u8,
};

pub fn toJSONImage(allocator: std.mem.Allocator, image: ReadFileImage, path: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, ReadFileImageJSON{
        .path = path,
        .mime = image.mime,
        .bytes = image.byte_len,
        .attached_as = "image_url",
    }, .{});
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
    \\- An image (png/jpeg/gif/webp) is attached to you as a picture you can see; the text is `{path,mime,bytes,attached_as}` and offset/limit do not apply. Look at the picture before describing what it shows.
    \\- Any other binary is refused with `BinaryFileNotText` — do not retry it as text.
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
        \\
        \\An IMAGE (png/jpeg/gif/webp) is attached to you as a picture you can see; the text payload is {path,mime,bytes,attached_as} and offset/limit do not apply. Any other binary file is refused with BinaryFileNotText instead of being returned as garbled text.
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
// Content is raw (no per-line number prefixes).

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
// `text_replace` normalizes the file to LF *before* it searches for `old_str`
// (text_replace.zig: `had_crlf` → `normalizeLineEndings` → `indexOf`).
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
// directly usable as `old_str` by text_replace.
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

/// The bytes of `path_abs`, shaped into the tool's result. Under `--saas` they
/// come from the guest agent and the host opens no tenant file at all; every
/// other mode keeps today's read, because `forSession` installs nothing.
fn readThrough(ctx: ToolExecContext, path_abs: []const u8, opts: ReadFileOptions) !ReadFileResult {
    const guest = try workspace_fs.forSession(ctx.allocator, ctx.db, ctx.session_id);
    if (guest) |handle| {
        var fs = handle;
        defer fs.deinit();
        const bytes = try fs.readAll(path_abs);
        defer ctx.allocator.free(bytes);
        return shapeContent(ctx.allocator, bytes, opts);
    }
    return exec_readFile(ctx.allocator, ctx.io, path_abs, opts);
}

// Exec adapter — merged from `read_file.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const ReadFileInput = pabrikcore.tool_models.ReadFileInput;
const exec_ReadFileOptions = pabrikcore.read_file.ReadFileOptions;
const exec_readFile = pabrikcore.read_file.readFile;
const exec_toJSONSuccess = pabrikcore.read_file.toJSONSuccess;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
const workspace_fs = @import("../../../agentic_loop/workspace_fs.zig");
const exec_path_validate = @import("helpers").path_validate;
pub fn execReadFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = ctx.db;
    _ = ctx.session_id;

    // Parse arguments JSON to ReadFileInput
    const parsed = std.json.parseFromSlice(
        ReadFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // `cwd` is REQUIRED on every path-taking tool: it is the directory this
    // call works in, and the base a relative `path` resolves against. See
    // helpers/exec_path_validate.zig for the one implementation of that rule.
    exec_path_validate.validateCwd(parsed.value.cwd) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const path_abs = try exec_path_validate.resolveAgainstCwd(ctx.allocator, parsed.value.cwd, parsed.value.path);
    defer ctx.allocator.free(path_abs);

    const read_opts = exec_ReadFileOptions{
        .offset = parsed.value.offset,
        .limit = parsed.value.limit,
    };

    const read_result = readThrough(ctx, path_abs, read_opts) catch |err| {
        // The path is the one thing the model can act on here, so it is
        // passed as the explanation's context.
        const err_msg = try error_explain.explain(ctx.allocator, err, path_abs);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer read_result.deinit(ctx.allocator);

    // Single allocation: combines path and content into the JSON result
    const inner = if (read_result.image) |img|
        try toJSONImage(ctx.allocator, img, path_abs)
    else
        try exec_toJSONSuccess(ctx.allocator, read_result, path_abs);
    defer ctx.allocator.free(inner);
    const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{
        .output = output,
        .output_allocated = true,
        .image_url = if (read_result.image) |img| try ctx.allocator.dupe(u8, img.url) else null,
    };
}

// ─── An image is answered with the picture ─────────────────────────────────

const png_bytes = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR";
const jpeg_bytes = "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01";
const webp_bytes = "RIFF\x24\x00\x00\x00WEBPVP8 ";
const gif_bytes = "GIF89a\x01\x00\x01\x00";
const elf_bytes = "\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00";

test "read_file answers a png with the picture, not with its bytes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try writeTmp(allocator, &tmp, "shot.png", png_bytes);
    defer allocator.free(abs);

    var result = try readFile(allocator, std.testing.io, abs, .{});
    defer result.deinit(allocator);

    const image = result.image orelse return error.TestExpectedImage;
    try std.testing.expectEqualStrings("image/png", image.mime);
    try std.testing.expectEqual(png_bytes.len, image.byte_len);
    try std.testing.expect(std.mem.startsWith(u8, image.url, "data:image/png;base64,"));
    try std.testing.expectEqualStrings("", result.content);
}

test "read_file takes the image format from the bytes, not from the file name" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try writeTmp(allocator, &tmp, "liar.png", jpeg_bytes);
    defer allocator.free(abs);

    var result = try readFile(allocator, std.testing.io, abs, .{});
    defer result.deinit(allocator);

    const image = result.image orelse return error.TestExpectedImage;
    try std.testing.expectEqualStrings("image/jpeg", image.mime);
    try std.testing.expect(std.mem.startsWith(u8, image.url, "data:image/jpeg;base64,"));
}

test "read_file recognises every image format a provider accepts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_][2][]const u8{
        .{ "a.webp", webp_bytes },
        .{ "a.gif", gif_bytes },
        .{ "a.jpeg", jpeg_bytes },
    }) |fixture| {
        const abs = try writeTmp(allocator, &tmp, fixture[0], fixture[1]);
        defer allocator.free(abs);
        var result = try readFile(allocator, std.testing.io, abs, .{});
        defer result.deinit(allocator);
        try std.testing.expect(result.image != null);
    }
}

test "read_file ignores offset and limit on an image instead of refusing the range" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try writeTmp(allocator, &tmp, "one-shot.png", png_bytes);
    defer allocator.free(abs);

    var result = try readFile(allocator, std.testing.io, abs, .{ .offset = 99, .limit = 1 });
    defer result.deinit(allocator);

    try std.testing.expect(result.image != null);
}

test "read_file refuses a binary file instead of handing the model mojibake" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try writeTmp(allocator, &tmp, "app.elf", elf_bytes);
    defer allocator.free(abs);

    try std.testing.expectError(error.BinaryFileNotText, readFile(allocator, std.testing.io, abs, .{}));
}

test "read_file refuses an image past the inline size cap" {
    const allocator = std.testing.allocator;
    const big = try allocator.alloc(u8, helpers_image.max_inline_bytes + 1);
    defer allocator.free(big);
    @memset(big, 0);
    @memcpy(big[0..png_bytes.len], png_bytes);

    try std.testing.expectError(error.ImageTooLarge, shapeContent(allocator, big, .{}));
}

test "the image payload names the path, the mime and the byte count" {
    const allocator = std.testing.allocator;
    const image = ReadFileImage{
        .mime = "image/png",
        .url = try allocator.dupe(u8, "data:image/png;base64,AAA"),
        .byte_len = 42,
    };
    defer allocator.free(image.url);

    const payload = try toJSONImage(allocator, image, "/a/shot.png");
    defer allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("/a/shot.png", obj.get("path").?.string);
    try std.testing.expectEqualStrings("image/png", obj.get("mime").?.string);
    try std.testing.expectEqual(@as(i64, 42), obj.get("bytes").?.integer);
    try std.testing.expectEqualStrings("image_url", obj.get("attached_as").?.string);
}

test "shapeContent: the guest read and the host read answer with one shape" {
    const allocator = std.testing.allocator;
    // Whatever produced the bytes — a host open or a guest RPC — the tool's
    // contract is the same: LF, raw, no prefixes, absolute 1-indexed lines.
    const shaped = try shapeContent(allocator, "l1\r\nl2\r\nl3\r\n", .{ .offset = 1, .limit = 1 });
    defer shaped.deinit(allocator);
    try std.testing.expectEqualStrings("l2\n", shaped.content);
    try std.testing.expectEqual(@as(usize, 3), shaped.total_lines);
    try std.testing.expectEqual(@as(usize, 1), shaped.start_line);
    try std.testing.expectEqual(@as(usize, 1), shaped.end_line);
}

test "shapeContent: an offset past the end is refused, not answered empty" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.OffsetOutOfRange, shapeContent(allocator, "one\ntwo\n", .{ .offset = 9 }));
}

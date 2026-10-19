const std = @import("std");
const builtin = @import("builtin");
const schemas = @import("schemas.zig");
/// The NTSTATUS guard is shared: the LLM controls `path` for EVERY
/// path-taking tool, not just this one, and on Windows a malformed NT name
/// panics the process inside std's Io backend rather than failing the call.
const path_validate = @import("helpers").path_validate;
const invalidPathReason = path_validate.invalidPathReason;
const isSep = path_validate.isSep;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

/// Input structure for remove_file tool
pub const RemoveFileInput = struct {
    /// Path to the file or directory to delete. Absolute, or relative to
    /// `cwd`.
    path: []const u8,
    /// If true, recursively delete directory and all contents inside
    recursive: bool = false,
    /// REQUIRED on the wire. Absolute directory this call works in; a
    /// relative `path` resolves against it.
    cwd: []const u8 = "",
};

/// Tool definition for remove_file
pub const remove_file_tool_system_prompt =
    \\## Remove File Tool — Behavior
    \\Use `remove_file` to delete a file or directory.
    \\- `cwd` is REQUIRED: the absolute directory this call works in. A relative `path` resolves against it; an absolute `path` is used as-is.
    \\- Set `recursive=true` to delete directories with contents. This cannot be undone.
    \\- Verify the path is correct before deleting.
    \\
;

pub const remove_file_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "remove_file",
        .description = "Delete a file or directory from the filesystem. Use recursive=true to delete a folder with its contents. Warning: this cannot be undone!",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Path to the file or directory to delete. Absolute, or relative to `cwd`.",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "REQUIRED. Absolute directory this call works in; a relative `path` resolves against it. Pass the tree you are editing (your worktree root, NOT the server's directory).",
                },

                .{
                    .name = "recursive",
                    .type = "boolean",
                    .description = "If true, delete the directory and everything inside it. Default: false.",
                },
            },
            .required = &.{ "path", "cwd" },
        },
        .system_prompt = remove_file_tool_system_prompt,
    },
};

/// Strip trailing separators so `C:\foo\` never reaches NT as a
/// trailing-separator name. Never strips the root itself (`X:\`, `\\`, `\`).
fn stripTrailingSeps(path: []const u8) []const u8 {
    var end = path.len;
    const floor: usize = floor: {
        if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and isSep(path[2])) break :floor 3;
        if (path.len >= 2 and isSep(path[0]) and isSep(path[1])) break :floor 2;
        break :floor 1;
    };
    while (end > floor and isSep(path[end - 1])) end -= 1;
    return path[0..end];
}

/// Refusing to delete a filesystem root (`C:\`, `\`, `\\server\share`) with
/// recursive=true would wipe the drive/share. Fail closed. Windows only;
/// call with the normalized (trailing-sep-stripped) path.
fn isWindowsRoot(norm_path: []const u8) bool {
    var rest: []const u8 = norm_path;
    if (rest.len > 4 and (std.mem.startsWith(u8, rest, "\\\\?\\") or std.mem.startsWith(u8, rest, "\\\\.\\"))) {
        rest = rest[4..];
    }
    // Drive root `X:\` / `X:/`, or current-drive root `\`.
    if (rest.len == 3 and std.ascii.isAlphabetic(rest[0]) and rest[1] == ':' and isSep(rest[2])) return true;
    if (rest.len == 1 and isSep(rest[0])) return true;
    // UNC share root `\\server\share` (exactly two non-empty components).
    if (norm_path.len >= 2 and isSep(norm_path[0]) and isSep(norm_path[1]) and
        !std.mem.startsWith(u8, norm_path, "\\\\?\\") and !std.mem.startsWith(u8, norm_path, "\\\\.\\"))
    {
        const body = norm_path[2..];
        var count: usize = 0;
        var k: usize = 0;
        var seg_start: usize = 0;
        while (k <= body.len) : (k += 1) {
            const at_end = k == body.len;
            if (!at_end and !isSep(body[k])) continue;
            if (k - seg_start > 0) {
                count += 1;
            } else {
                return false; // empty segment -> not a clean share root
            }
            seg_start = k + 1;
        }
        if (count == 2) return true;
    }
    return false;
}

/// Check if path is a directory.
/// Callers must validate via invalidPathReason() first: on Windows an
/// unchecked name panics inside openDir (OBJECT_NAME_INVALID -> ntstatusBug).
fn isDirectory(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    return true;
}

/// Execute the remove_file tool - deletes a file or directory
/// Returns an XML string with result
pub fn executeRemoveFileToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: RemoveFileInput,
) ![]const u8 {
    if (input.path.len == 0) {
        return xmlError(allocator, "", "path cannot be empty");
    }

    // Panic guard: reject malformed NT names BEFORE any syscall.
    // (Windows Threaded backend turns them into ntstatusBug panics.)
    if (invalidPathReason(input.path)) |reason| {
        return xmlError(allocator, input.path, reason);
    }
    const norm_path = stripTrailingSeps(input.path);
    if (builtin.os.tag == .windows and isWindowsRoot(norm_path)) {
        return xmlError(allocator, input.path, "refusing to delete filesystem root");
    }

    const path_exists = blk: {
        std.Io.Dir.cwd().access(io, norm_path, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!path_exists) {
        return xmlError(allocator, input.path, "Path not found");
    }

    // Check if it's a directory by trying to open as dir
    const is_directory = isDirectory(io, norm_path);

    if (is_directory) {
        // It's a directory
        if (!input.recursive) {
            return xmlError(allocator, input.path, "Path is a directory. Use recursive=true to delete directories with contents.");
        }

        // Recursive delete using deleteTree
        std.Io.Dir.cwd().deleteTree(io, norm_path) catch {
            return xmlError(allocator, input.path, "Failed to delete directory");
        };

        return try std.fmt.allocPrint(allocator,
            \\<path>{s}</path>
            \\<deleted>true</deleted>
            \\<recursive>true</recursive>
        , .{input.path});
    }

    // It's a file - delete it
    std.Io.Dir.cwd().deleteFile(io, norm_path) catch {
        return xmlError(allocator, input.path, "Failed to delete file");
    };

    return try std.fmt.allocPrint(allocator,
        \\<path>{s}</path>
        \\<deleted>true</deleted>
    , .{input.path});
}

/// Generate error XML response
pub fn xmlError(allocator: std.mem.Allocator, path: []const u8, error_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<path>{s}</path>
        \\<deleted>false</deleted>
        \\<error>{s}</error>
    , .{ path, error_msg }) catch "<path></path><deleted>false</deleted><error>UnknownError</error>";
}

/// Generate error XML response for parse failures (no path available)
pub fn xmlErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<path></path>
        \\<deleted>false</deleted>
        \\<error>{s}</error>
    , .{error_msg}) catch "<path></path><deleted>false</deleted><error>UnknownError</error>";
}

// --- Regression tests: malformed names must return error XML, never panic
// --- (Windows Threaded backend maps OBJECT_NAME_INVALID / INVALID_PARAMETER
// / OBJECT_PATH_SYNTAX_BAD to ntstatusBug -> process abort.

test "remove_file validator rejects empty and NUL paths on all platforms" {
    try std.testing.expect(invalidPathReason("") != null);
    try std.testing.expect(invalidPathReason("a\x00b") != null);
    try std.testing.expect(invalidPathReason("a\x07b") != null);
}

test "remove_file validator accepts sane paths on all platforms" {
    if (builtin.os.tag == .windows) {
        try std.testing.expect(invalidPathReason("C:\\Users\\ginwa\\file.txt") == null);
        try std.testing.expect(invalidPathReason("C:/Users/ginwa/file.txt") == null);
        try std.testing.expect(invalidPathReason("\\\\server\\share\\file.txt") == null);
    } else {
        try std.testing.expect(invalidPathReason("/tmp/some-file.txt") == null);
        try std.testing.expect(invalidPathReason("relative/path.txt") == null);
    }
}

test "remove_file validator rejects Windows-malformed names" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // NOTE: single-rooted `/unix/style/path` IS valid NT syntax (it resolves
    // against the current drive root and safely yields FileNotFound), so it
    // must NOT be rejected — only names that panic NtQueryAttributesFile are.
    try std.testing.expect(invalidPathReason("/unix/style/path") == null);
    // Bare names and drive-relative `C:foo` are not absolute.
    try std.testing.expect(invalidPathReason("relative\\path.txt") != null);
    try std.testing.expect(invalidPathReason("C:foo\\bar.txt") != null);
    // Wildcards / reserved chars -> OBJECT_NAME_INVALID.
    try std.testing.expect(invalidPathReason("C:\\foo*.txt") != null);
    try std.testing.expect(invalidPathReason("C:\\foo?.txt") != null);
    try std.testing.expect(invalidPathReason("C:\\foo<bar.txt") != null);
    try std.testing.expect(invalidPathReason("C:\\foo|bar.txt") != null);
    try std.testing.expect(invalidPathReason("C:\\foo\"bar.txt") != null);
    // ADS suffix / stray colon.
    try std.testing.expect(invalidPathReason("C:\\foo:stream") != null);
    // Empty segment, dot-dot escape, trailing dot/space, device names.
    try std.testing.expect(invalidPathReason("C:\\foo\\\\bar.txt") != null);
    try std.testing.expect(invalidPathReason("C:\\foo\\..\\bar.txt") != null);
    try std.testing.expect(invalidPathReason("C:\\foo.") != null);
    try std.testing.expect(invalidPathReason("C:\\foo ") != null);
    try std.testing.expect(invalidPathReason("C:\\NUL") != null);
    try std.testing.expect(invalidPathReason("C:\\dir\\COM1.txt") != null);
    // Incomplete UNC.
    try std.testing.expect(invalidPathReason("\\\\server") != null);
}

test "remove_file refuses filesystem roots" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(isWindowsRoot(stripTrailingSeps("C:\\")));
    try std.testing.expect(isWindowsRoot(stripTrailingSeps("C:\\\\")));
    try std.testing.expect(isWindowsRoot(stripTrailingSeps("\\\\server\\share")));
    try std.testing.expect(isWindowsRoot(stripTrailingSeps("\\\\server\\share\\")));
    try std.testing.expect(!isWindowsRoot(stripTrailingSeps("C:\\Users")));
    try std.testing.expect(!isWindowsRoot(stripTrailingSeps("\\\\server\\share\\dir")));
}

test "remove_file stripTrailingSeps keeps roots intact" {
    try std.testing.expectEqualStrings("C:\\foo", stripTrailingSeps("C:\\foo\\"));
    try std.testing.expectEqualStrings("C:\\foo", stripTrailingSeps("C:\\foo///"));
    try std.testing.expectEqualStrings("C:\\", stripTrailingSeps("C:\\"));
    try std.testing.expectEqualStrings("/tmp/x", stripTrailingSeps("/tmp/x/"));
}

test "remove_file execute returns error XML on invalid path without touching FS" {
    // Empty path and validator/root rejections return before `io` is ever
    // used, so `undefined` is safe for those. Anything that passes validation
    // gets a real Io (Threaded) — the point is it must not panic.
    const bad_io: std.Io = undefined;
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const out = try executeRemoveFileToString(fba.allocator(), bad_io, .{ .path = "" });
    try std.testing.expect(std.mem.indexOf(u8, out, "<deleted>false</deleted>") != null);
    if (builtin.os.tag == .windows) {
        // Validator rejection (wildcard): never reaches the syscall.
        var buf1: [1024]u8 = undefined;
        var fba1 = std.heap.FixedBufferAllocator.init(&buf1);
        const out1 = try executeRemoveFileToString(fba1.allocator(), bad_io, .{ .path = "C:\\definitely\\missing\\*.txt" });
        try std.testing.expect(std.mem.indexOf(u8, out1, "<deleted>false</deleted>") != null);
        try std.testing.expect(std.mem.indexOf(u8, out1, "invalid character") != null);

        // Root guard: never reaches the syscall.
        var buf3: [1024]u8 = undefined;
        var fba3 = std.heap.FixedBufferAllocator.init(&buf3);
        const out3 = try executeRemoveFileToString(fba3.allocator(), bad_io, .{ .path = "C:\\", .recursive = true });
        try std.testing.expect(std.mem.indexOf(u8, out3, "<deleted>false</deleted>") != null);
        try std.testing.expect(std.mem.indexOf(u8, out3, "filesystem root") != null);

        // Valid NT syntax, missing on disk: goes through access() and must
        // come back as error XML (FileNotFound), NOT an ntstatusBug panic.
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var buf2: [1024]u8 = undefined;
        var fba2 = std.heap.FixedBufferAllocator.init(&buf2);
        const out2 = try executeRemoveFileToString(fba2.allocator(), io, .{ .path = "C:\\definitely\\missing\\pabrik-test-file.txt" });
        try std.testing.expect(std.mem.indexOf(u8, out2, "<deleted>false</deleted>") != null);
        try std.testing.expect(std.mem.indexOf(u8, out2, "Path not found") != null);
    }
}

// Exec adapter — merged from `remove_file.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
const exec_path_validate = @import("helpers").path_validate;
const workspace_fs = @import("../../../agentic_loop/workspace_fs.zig");

/// Delete in whichever substrate owns the tree. Under `--saas` the guest does
/// it — and the guest refuses to take the workspace root with it, which the
/// host's own `deleteTree` has no reason to guard against.
fn removeThrough(ctx: ToolExecContext, input: RemoveFileInput) ![]const u8 {
    const guest = try workspace_fs.forSession(ctx.allocator, ctx.db, ctx.session_id);
    if (guest) |handle| {
        var fs = handle;
        defer fs.deinit();
        return removeInGuest(ctx.allocator, &fs, input);
    }
    return executeRemoveFileToString(ctx.allocator, ctx.io, input);
}

/// The answers the host path gives, asked of the guest: a directory without
/// `recursive` is refused with the message that names the fix, and a path that
/// is not there says so instead of succeeding quietly.
fn removeInGuest(
    allocator: std.mem.Allocator,
    fs: *workspace_fs.Fs,
    input: RemoveFileInput,
) ![]const u8 {
    const info = fs.stat(input.path) catch |err| switch (err) {
        workspace_fs.Error.GuestFileMissing, workspace_fs.Error.GuestPathOutsideWorkspace => {
            return xmlError(allocator, input.path, "Path not found");
        },
        else => return err,
    };
    if (info.missing) return xmlError(allocator, input.path, "Path not found");

    if (info.kind != .dir) {
        fs.remove(input.path) catch return xmlError(allocator, input.path, "Failed to delete file");
        return std.fmt.allocPrint(allocator,
            \\<path>{s}</path>
            \\<deleted>true</deleted>
        , .{input.path});
    }

    if (!input.recursive) {
        return xmlError(allocator, input.path, "Path is a directory. Use recursive=true to delete directories with contents.");
    }
    fs.removeAll(input.path) catch |err| switch (err) {
        workspace_fs.Error.GuestWorkspaceRoot => {
            return xmlError(allocator, input.path, "refusing to delete the workspace root");
        },
        workspace_fs.Error.GuestWalkTruncated => {
            return xmlError(allocator, input.path, "the tree is larger than one walk can list");
        },
        else => return xmlError(allocator, input.path, "Failed to delete directory"),
    };
    return std.fmt.allocPrint(allocator,
        \\<path>{s}</path>
        \\<deleted>true</deleted>
        \\<recursive>true</recursive>
    , .{input.path});
}

pub fn execRemoveFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        RemoveFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // `cwd` is REQUIRED on every path-taking tool: it is the directory this
    // call works in, and the base a relative `path` resolves against. See
    // helpers/exec_path_validate.zig for the one implementation of that rule.
    exec_path_validate.validateCwd(parsed.value.cwd) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const path_abs = try exec_path_validate.resolveAgainstCwd(ctx.allocator, parsed.value.cwd, parsed.value.path);
    defer ctx.allocator.free(path_abs);

    // Delete the RESOLVED path — a relative one would otherwise resolve
    // against the server's directory instead of the model's `cwd`.
    var input = parsed.value;
    input.path = path_abs;

    const inner = removeThrough(ctx, input) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse (inner.len - err_start);
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}


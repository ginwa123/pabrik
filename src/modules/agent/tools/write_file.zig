const std = @import("std");
const schemas = @import("schemas.zig");
const path_validate = @import("helpers").path_validate;
const invalidPathReason = path_validate.invalidPathReason;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

pub const WriteFileInput = struct {
    path: []const u8,
    content: []const u8,
    create_with_dir: bool = false,
};

pub const WriteFileResult = struct {
    path: []const u8,

    pub fn deinit(self: WriteFileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

/// Parent directory to create for `path`, or null when there is nothing to
/// create.
///
/// This replaces a hand-rolled "index of the last separator" scan. That
/// scan was separator-aware but not *root*-aware: for `C:\notes.txt` it
/// cut at index 2 and produced `"C:"`, which is a DRIVE-RELATIVE name and
/// not a directory, so `createDirPath` failed on a file that was plainly
/// writable. On POSIX the same input shape is `/notes.txt`, where the index
/// is 0 and the old `> 0` guard skipped the call entirely — which is why
/// the bug only ever appeared on Windows.
///
/// `std.fs.path.dirname` is the one answer that is correct on every
/// platform: it knows about volumes, UNC shares, and both separators, and
/// it returns null when the parent is a root that already exists.
pub fn parentDirToCreate(path: []const u8) ?[]const u8 {
    return std.fs.path.dirname(path);
}

/// Create `dir_path`, unless it is already there.
///
/// `createDirPath` reports an EXISTING directory as an error, and on Windows
/// that includes a drive root: `create_with_dir = true` for a file sitting
/// directly in `C:\` walks into `createDirPath(io, "C:\\")` and dies, even
/// though there is provably nothing to create. Probing first makes every
/// platform agree on the "already there" case, and turns the common
/// already-exists path into a single stat instead of a walk plus a failed
/// create.
///
/// Any error other than "not there" is still surfaced: a permission problem
/// on an existing parent should not be silently reinterpreted as "create it".
fn ensureDir(io: std.Io, dir_path: []const u8) !void {
    if (std.Io.Dir.cwd().access(io, dir_path, .{})) |_| {
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
}

pub fn writeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: WriteFileInput,
) !WriteFileResult {
    const path = input.path;
    // See helpers/path_validate.zig — a malformed NT name panics the
    // process rather than failing this call.
    if (invalidPathReason(path)) |reason| {
        std.log.debug("write_file rejected path: {s}", .{reason});
        return error.InvalidPathReason;
    }

    // If create_with_dir is true, proactively create parent directories with makePath
    if (input.create_with_dir) {
        if (parentDirToCreate(path)) |dir_path| {
            try ensureDir(io, dir_path);
        }
    }

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            const path_copy = try allocator.dupe(u8, path);
            defer allocator.free(path_copy);

            if (parentDirToCreate(path_copy)) |dir_path| {
                try ensureDir(io, dir_path);
                const file = try std.Io.Dir.cwd().createFile(io, path, .{});
                defer std.Io.File.close(file, io);

                try std.Io.File.writeStreamingAll(file, io, input.content);
                return WriteFileResult{
                    .path = try allocator.dupe(u8, path),
                };
            }
        }
        return err;
    };
    defer std.Io.File.close(file, io);

    try std.Io.File.writeStreamingAll(file, io, input.content);
    return WriteFileResult{
        .path = try allocator.dupe(u8, path),
    };
}

/// JSON payload for a write result: mirrors the old `<file_write>` tag
/// 1:1. The old success envelope omitted `<error>`; that becomes an
/// explicit null. `std.json` handles all escaping — no manual layer.
pub const WriteFileJSON = struct {
    file_write: []const u8,
    @"error": ?[]const u8 = null,
};

pub fn toJSONSuccess(allocator: std.mem.Allocator, result: WriteFileResult) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, WriteFileJSON{
        .file_write = result.path,
    }, .{});
}

pub fn toJSONError(allocator: std.mem.Allocator, err: anyerror, path: []const u8) ![]u8 {
    const message: []const u8 = switch (err) {
        error.PathNotFound => try std.fmt.allocPrint(allocator, "Directory for path '{s}' not found. Check if the parent directory exists.", .{path}),
        error.InputOutput => try std.fmt.allocPrint(allocator, "Failed to write file '{s}'. Check write permissions.", .{path}),
        else => try std.fmt.allocPrint(allocator, "Unexpected error: {s}", .{@errorName(err)}),
    };
    defer allocator.free(message);
    return try std.json.Stringify.valueAlloc(allocator, WriteFileJSON{
        .file_write = path,
        .@"error" = message,
    }, .{});
}

pub const write_file_tool_system_prompt =
    \\## Write File Tool — Behavior
    \\Use `write_file` to create or overwrite a file.
    \\- Provide absolute `path` and full `content`. Set `create_with_dir=true` to auto-create parent directories.
    \\- For partial edits, prefer `text_replace` over rewriting the whole file.
    \\
;

pub const write_file_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "write_file",
        .description =
        \\Write content to a new file. Creates file if it doesn't exist, overwrites if it does.
        \\For partial file updates, use text_replace tool instead.
        \\Set create_with_dir to true to automatically create parent directories.
        \\return {"file_write": <path>, "error": null}
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Absolute path to the file.",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "Content to write.",
                },
                .{
                    .name = "create_with_dir",
                    .type = "boolean",
                    .description = "If true, automatically create parent directories if they don't exist. Default: false.",
                },
            },
            .required = &.{ "path", "content" },
        },
        .system_prompt = write_file_tool_system_prompt,
    },
};

const write_file = @import("write_file.zig");
const testing = std.testing;
const absPath = @import("helpers").test_path.absPath;

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn deleteFile(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
}

fn deleteDir(path: []const u8) void {
    std.Io.Dir.cwd().deleteDir(testing.io, path) catch {};
}

// Best-effort cleanup for a test's full directory tree. Deletes the
// leaf file, then each parent directory in DEEPEST-FIRST order so each
// rmdir sees an empty directory.
//
// Why no `openDir().iterate()` walk: the Zig 0.16 Io runtime is flaky
// when iterating from the cwd Dir handle after a createDir/createDirPath
// syscall (it can return BADF). Since the test is the SOLE creator of
// the tree, the caller spells the parent list out and we avoid the
// iteration. The list is a runtime slice, not a comptime literal,
// because each entry is now a slice of its own `absPath` buffer.
// All errors are swallowed — the goal is "leave no residue", not
// "assert cleanup succeeded".
fn deleteTestTree(parents_deep_first: []const []const u8, leaf_file: []const u8) void {
    deleteFile(leaf_file);
    for (parents_deep_first) |dir| {
        deleteDir(dir);
    }
}

/// Read back a file's full contents into a freshly allocated slice.
/// Limit is 4 MiB so tests that write up to 1 MiB (e.g. the large-content
/// test) can read back the full content without hitting StreamTooLong.
fn readFileContents(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(4 << 20));
}

/// Return the on-disk size of a file (0 if missing).
fn fileSize(path: []const u8) u64 {
    var f = std.Io.Dir.cwd().openFile(testing.io, path, .{}) catch return 0;
    defer f.close(testing.io);
    return std.Io.File.length(f, testing.io) catch 0;
}

// ===========================================================================
// Section 1: Happy path (sanity baseline)
// ===========================================================================

test "writeFile - writes ASCII content to a new file in cwd" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_basic.txt");
    defer deleteFile(path);

    var result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "Hello, World!",
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings(path, result.path);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("Hello, World!", read);
}

test "writeFile - file on disk has exact size equal to content length" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_size.txt");
    defer deleteFile(path);

    const content = "0123456789";
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, content.len), fileSize(path));
}

test "writeFile - overwrites existing file (truncates)" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_overwrite.txt");
    defer deleteFile(path);

    // First write: 50 bytes of 'A'
    var first_buf: [50]u8 = undefined;
    for (&first_buf) |*b| b.* = 'A';
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = &first_buf,
    });
    defer _wf_r.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 50), fileSize(path));

    // Second write: 5 bytes of 'B' — must truncate the old content
    var result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "BBBBB",
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 5), fileSize(path));
    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("BBBBB", read);
}

test "writeFile - overwrites with larger content (extends)" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_extend.txt");
    defer deleteFile(path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "small",
    });
    defer _wf_r.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 5), fileSize(path));

    const bigger = "this is a much longer string than before";
    var _wf_r2 = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = bigger,
    });
    defer _wf_r2.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, bigger.len), fileSize(path));

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings(bigger, read);
}

test "writeFile - writing same path twice leaves only the second contents" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_idempotent.txt");
    defer deleteFile(path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "first version",
    });
    defer _wf_r.deinit(testing.allocator);
    var r2 = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "second version wins",
    });
    defer r2.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("second version wins", read);
}

// ===========================================================================
// Section 2: create_with_dir = true (proactive parent-dir creation)
// ===========================================================================

test "writeFile - create_with_dir=true creates missing parent directory" {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try absPath(&dir_buf, "test_wf_create_dir_parent");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_create_dir_parent/inner.txt");
    defer {
        deleteFile(path);
        deleteDir(dir);
    }

    var result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "in a fresh dir",
        .create_with_dir = true,
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings(path, result.path);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("in a fresh dir", read);
}

test "writeFile - create_with_dir=true creates deeply nested parent dirs" {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try absPath(&root_buf, "test_wf_deeply_nested");
    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    const a = try absPath(&a_buf, "test_wf_deeply_nested/a");
    var b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const b = try absPath(&b_buf, "test_wf_deeply_nested/a/b");
    var c_buf: [std.fs.max_path_bytes]u8 = undefined;
    const c = try absPath(&c_buf, "test_wf_deeply_nested/a/b/c");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_deeply_nested/a/b/c/deep.txt");
    defer deleteTestTree(&.{ c, b, a, root }, path);

    var result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "deep content",
        .create_with_dir = true,
    });
    defer result.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("deep content", read);
}

test "writeFile - create_with_dir=true on existing parent dir is a no-op (idempotent)" {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try absPath(&dir_buf, "test_wf_existing_parent");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_existing_parent/file.txt");
    defer {
        deleteFile(path);
        deleteDir(dir);
    }

    // Create the parent dir first
    try std.Io.Dir.cwd().createDir(testing.io, dir, .default_dir);

    // Now write — create_with_dir=true must succeed without erroring on the
    // already-existing parent (createDirPath is idempotent on POSIX).
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "into existing parent",
        .create_with_dir = true,
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("into existing parent", read);
}

// ===========================================================================
// Section 3: create_with_dir = false (the FileNotFound fallback branch)
// ===========================================================================

test "writeFile - create_with_dir=false auto-creates parent on FileNotFound fallback" {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try absPath(&dir_buf, "test_wf_fallback");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_fallback/inner.txt");
    defer {
        deleteFile(path);
        deleteDir(dir);
    }

    // create_with_dir defaults to false → the function should still
    // succeed by hitting the FileNotFound catch-all path which calls
    // createDirPath and re-creates the file.
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "fallback worked",
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("fallback worked", read);
}

test "writeFile - create_with_dir=false auto-creates deeply nested missing parents" {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try absPath(&root_buf, "test_wf_fallback_deep");
    var x_buf: [std.fs.max_path_bytes]u8 = undefined;
    const x = try absPath(&x_buf, "test_wf_fallback_deep/x");
    var y_buf: [std.fs.max_path_bytes]u8 = undefined;
    const y = try absPath(&y_buf, "test_wf_fallback_deep/x/y");
    var z_buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try absPath(&z_buf, "test_wf_fallback_deep/x/y/z");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_fallback_deep/x/y/z/deep.txt");
    defer deleteTestTree(&.{ z, y, x, root }, path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "fallback deep",
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("fallback deep", read);
}

// ===========================================================================
// Section 4: Empty content
// ===========================================================================

test "writeFile - empty content produces a zero-byte file" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_empty.txt");
    defer deleteFile(path);

    var result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "",
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings(path, result.path);
    try testing.expectEqual(@as(u64, 0), fileSize(path));
}

test "writeFile - overwriting with empty content truncates to zero bytes" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_empties_old.txt");
    defer deleteFile(path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "this content will be wiped",
    });
    defer _wf_r.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 26), fileSize(path)); // "this content will be wiped" = 26 chars

    var _wf_r2 = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "",
    });
    defer _wf_r2.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), fileSize(path));
}

// ===========================================================================
// Section 5: Content shape edge cases
// ===========================================================================

test "writeFile - multibyte UTF-8 content preserved byte-for-byte" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_unicode.txt");
    defer deleteFile(path);

    // 2-byte (é), 3-byte (中), 4-byte (🚀) UTF-8 sequences
    const content = "café 中文 🚀 émoji";
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings(content, read);
    try testing.expectEqual(@as(u64, content.len), fileSize(path));
}

test "writeFile - binary content with NUL bytes preserved" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_binary.bin");
    defer deleteFile(path);

    // Content with NUL bytes, control chars, and other binary noise
    const content = "\x00\x01\x02hello\x00world\xFF\xFE\xFD";
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, content.len), fileSize(path));

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualSlices(u8, content, read);
}

test "writeFile - content with all printable ASCII whitespace preserved" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_whitespace.txt");
    defer deleteFile(path);

    const content = "tab\there\nnewline\r\ncrlf\ttab2   spaces";
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings(content, read);
}

test "writeFile - content containing XML special chars preserved in file" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_xml_chars.txt");
    defer deleteFile(path);

    // The file on disk stores RAW bytes — escaping is handled by std.json in toJSONSuccess.
    const content = "<tag attr=\"value\">&entity;'apos'</tag>";
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings(content, read);
}

test "writeFile - single-byte content" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_single_byte.txt");
    defer deleteFile(path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "x",
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 1), fileSize(path));
    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("x", read);
}

test "writeFile - large content (1 MiB) written completely" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_large.bin");
    defer deleteFile(path);

    // Allocate a 1 MiB buffer of 'A' bytes
    const size: usize = 1 << 20; // 1 MiB
    const content = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(content);
    @memset(content, 'A');

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, size), fileSize(path));

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqual(@as(usize, size), read.len);
    // Spot-check first/last bytes
    try testing.expectEqual(@as(u8, 'A'), read[0]);
    try testing.expectEqual(@as(u8, 'A'), read[read.len - 1]);
    // Spot-check middle
    try testing.expectEqual(@as(u8, 'A'), read[size / 2]);
}

// ===========================================================================
// Section 5b: Large content — overwrite semantics + edge cases (added 2026-08-15)
//
// These tests pin the write_file contract on LARGE payloads (multi-MiB,
// multi-byte UTF-8, binary with NULs, overwriting existing files of
// different sizes). The base `writeFile` function uses
// `writeStreamingAll`, which is allowed to chunk internally — these
// tests verify the byte stream is preserved end-to-end regardless of
// chunk boundaries, and that overwrite-mode (truncate) is honoured even
// when the file size delta is huge.
// ===========================================================================

/// Fill a buffer with a deterministic repeating pattern (NOT a single
/// byte). Lets tests detect "buffer got the wrong prefix / wrong
/// suffix" errors that a uniform-fill test would miss.
fn fillPattern(buf: []u8, seed: u8) void {
    var s: u32 = seed;
    for (buf) |*b| {
        s = s *% 1103515245 +% 12345; // LCG, matches glibc rand()
        b.* = @truncate(s & 0xFF);
    }
}

test "writeFile - large content (10 MiB) with random pattern preserved byte-for-byte" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_large_10mb.bin");
    defer deleteFile(path);

    // 10 MiB = 10x the previous 1 MiB test, exercises multiple
    // writeStreamingAll chunk boundaries on most std.Io implementations.
    const size: usize = 10 * (1 << 20);
    const content = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(content);
    fillPattern(content, 42);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, size), fileSize(path));

    const read = try readFileContentsLarge(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqual(@as(usize, size), read.len);
    // Byte-exact equality across the full 10 MiB — most thorough check.
    try testing.expectEqualSlices(u8, content, read);
    // Spot-check a few indices known to be at chunk boundaries on
    // typical 4 KiB page-sized writes (0, 4K, 8K, 1M, 5M, 9.9M).
    const spot_indices = [_]usize{ 0, 4096, 8192, (1 << 20), 5 * (1 << 20), 9_900_000 };
    for (spot_indices) |i| {
        try testing.expectEqual(content[i], read[i]);
    }
}

/// Read the test file at any size up to a generous ceiling (16 MiB).
/// The base `readFileContents` is capped at 4 MiB, which is too small
/// for the 10 MiB test above.
fn readFileContentsLarge(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(16 << 20));
}

test "writeFile - large content OVERWRITES smaller existing file (truncate)" {
    // Pre-seed with 1 MiB of a unique 8-byte sentinel pattern (the
    // "dead beef cafe babe f0 0d fa ce" magic), then overwrite with 5 MiB
    // of LCG pattern data. The 8-byte sentinel is astronomically
    // unlikely to appear in random LCG output (~2^-64 chance per
    // 8-byte window), so detecting it in the final file proves
    // append-mode corruption.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_large_overwrite.bin");
    defer deleteFile(path);

    const sentinel = "\xDE\xAD\xBE\xEF\xCA\xFE\xBA\xBE\xF0\x0D\xFA\xCE\x12\x34\x56\x78";
    {
        const seed_size: usize = 1 << 20;
        const seed = try testing.allocator.alloc(u8, seed_size);
        defer testing.allocator.free(seed);
        var p: usize = 0;
        while (p + sentinel.len <= seed_size) : (p += sentinel.len) {
            @memcpy(seed[p..][0..sentinel.len], sentinel);
        }
        while (p < seed_size) : (p += 1) {
            seed[p] = sentinel[p % sentinel.len];
        }
        const seed_r = try write_file.writeFile(testing.allocator, testing.io, .{
            .path = path,
            .content = seed,
        });
        defer seed_r.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(u64, 1 << 20), fileSize(path));

    const new_size: usize = 5 * (1 << 20);
    const content = try testing.allocator.alloc(u8, new_size);
    defer testing.allocator.free(content);
    fillPattern(content, 7);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, new_size), fileSize(path));
    const read = try readFileContentsLarge(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualSlices(u8, content, read);
    // CRITICAL: no sentinel pattern anywhere — would prove append-mode
    try testing.expect(std.mem.indexOf(u8, read, sentinel) == null);
}

test "writeFile - large content overwritten by much SMALLER content (truncate)" {
    // Pre-seed with 8 MiB of pattern data, then overwrite with just 1 KiB.
    // Verifies the file shrinks to EXACTLY 1 KiB, not "8 MiB minus 1 KiB".
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_large_truncate.bin");
    defer deleteFile(path);

    const big_size: usize = 8 * (1 << 20);
    {
        const big = try testing.allocator.alloc(u8, big_size);
        defer testing.allocator.free(big);
        fillPattern(big, 99);
        const r = try write_file.writeFile(testing.allocator, testing.io, .{
            .path = path,
            .content = big,
        });
        defer r.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(u64, big_size), fileSize(path));

    const small_payload = "small replacement after a large file";
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = small_payload,
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, small_payload.len), fileSize(path));
    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings(small_payload, read);
    try testing.expectEqual(@as(usize, small_payload.len), read.len);
}

test "writeFile - large content with multi-byte UTF-8 (byte count preserved)" {
    // 1 MiB of 4-byte UTF-8 emojis (🚀 = F0 9F 9A 80). Each "char" is 4
    // bytes, so 1 MiB = 262_144 emojis. This stresses the
    // writeStreamingAll path on byte-aligned UTF-8 boundaries.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_large_utf8.bin");
    defer deleteFile(path);

    const size: usize = 1 << 20;
    const content = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(content);
    const emoji = "🚀"; // 4 bytes
    var i: usize = 0;
    while (i + emoji.len <= size) : (i += emoji.len) {
        @memcpy(content[i..][0..emoji.len], emoji);
    }
    // Any leftover bytes (<4) — fill with 'U' as a sentinel.
    while (i < size) : (i += 1) {
        content[i] = 'U';
    }

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, size), fileSize(path));
    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualSlices(u8, content, read);
    // Validate UTF-8 boundary integrity — no malformed sequences.
    // Walk through and assert every 4 bytes match the emoji pattern
    // (except the final <4-byte tail of 'U's).
    const full_emoji_bytes = (size / 4) * 4;
    var j: usize = 0;
    while (j < full_emoji_bytes) : (j += 4) {
        try testing.expectEqual(@as(u8, 0xF0), read[j]); // 🚀 byte 0
        try testing.expectEqual(@as(u8, 0x9F), read[j + 1]); // 🚀 byte 1
        try testing.expectEqual(@as(u8, 0x9A), read[j + 2]); // � byte 2
        try testing.expectEqual(@as(u8, 0x80), read[j + 3]); // 🚀 byte 3
    }
    // Tail (the 'U' sentinels)
    while (j < size) : (j += 1) {
        try testing.expectEqual(@as(u8, 'U'), read[j]);
    }
}

test "writeFile - large content with embedded NUL bytes (binary stream preserved)" {
    // 2 MiB of every 5th byte being NUL. The writeFile path must NOT
    // treat content as a C string — `writeStreamingAll` takes a slice
    // with explicit length, so this should "just work", but pinning
    // the contract catches a future refactor that switches to
    // null-terminated string APIs (writeC, file.write(... \0), etc.).
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_large_nul.bin");
    defer deleteFile(path);

    const size: usize = 2 * (1 << 20);
    const content = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(content);
    for (content, 0..) |*b, idx| {
        b.* = if (idx % 5 == 0) 0 else @as(u8, @truncate(idx & 0xFF));
    }

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, size), fileSize(path));
    const read = try readFileContentsLarge(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualSlices(u8, content, read);
    // Spot-check NUL positions (every 5th byte from 0 — choose indices
    // that are multiples of 5 so we know they're NUL by construction).
    try testing.expectEqual(@as(u8, 0), read[0]);
    try testing.expectEqual(@as(u8, 0), read[5]);
    try testing.expectEqual(@as(u8, 0), read[(1 << 20) - 1]); // 1048575 = 5 * 209715
    try testing.expectEqual(@as(u8, 0), read[size - 1 - ((size - 1) % 5)]); // last multiple of 5 in [0, size)
    // And spot-check a NON-NUL position (idx % 5 == 1) to prove the
    // pattern is preserved (not all bytes set to NUL).
    try testing.expectEqual(@as(u8, 1), read[1]); // idx 1 → (idx & 0xFF) == 1
}

test "writeFile - large content with mixed line endings (\\n + \\r\\n + \\r)" {
    // 256 KiB cycling through \n, \r\n, \r — verifies the write path
    // doesn't rewrite line endings (would silently break Windows files
    // written from a Unix agent).
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_large_line_endings.bin");
    defer deleteFile(path);

    const size: usize = 256 * 1024;
    const content = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(content);
    const endings = [_][]const u8{ "\n", "\r\n", "\r" };
    var pos: usize = 0;
    var e: usize = 0;
    while (pos < size) {
        const end = endings[e % endings.len];
        e += 1;
        if (pos + end.len > size) {
            content[pos] = 'X'; // tail fill sentinel
            pos += 1;
            continue;
        }
        @memcpy(content[pos..][0..end.len], end);
        pos += end.len;
    }

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = content,
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, size), fileSize(path));
    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualSlices(u8, content, read);
    // Spot-check exact line-ending sequences at known offsets
    try testing.expectEqual(@as(u8, '\n'), read[0]);
    try testing.expectEqual(@as(u8, '\r'), read[1]);
    try testing.expectEqual(@as(u8, '\n'), read[2]);
    try testing.expectEqual(@as(u8, '\r'), read[3]);
}

test "writeFile - large content overwrite preserves file size exactly (no padding)" {
    // Pre-seed with 2 MiB of 'A', overwrite with 2 MiB of 'B'. The file
    // MUST stay at exactly 2 MiB — neither shrunk nor grew. Catches a
    // hypothetical regression where the truncate happens but then the
    // write extends past the original size due to an off-by-one in the
    // truncate+write path.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_large_same_size.bin");
    defer deleteFile(path);

    const size: usize = 2 * (1 << 20);
    const a_buf = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(a_buf);
    @memset(a_buf, 'A');

    const b_buf = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(b_buf);
    @memset(b_buf, 'B');

    // First write: 2 MiB of 'A'
    {
        const r = try write_file.writeFile(testing.allocator, testing.io, .{
            .path = path,
            .content = a_buf,
        });
        defer r.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(u64, size), fileSize(path));

    // Second write: same size, different byte ('B')
    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = b_buf,
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, size), fileSize(path));
    const read = try readFileContentsLarge(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqual(@as(usize, size), read.len);
    try testing.expectEqualSlices(u8, b_buf, read);
    // CRITICAL: no 'A' bytes — would prove the old content survived
    try testing.expect(std.mem.indexOfScalar(u8, read, 'A') == null);
}

// ===========================================================================
// Section 6: Path shape edge cases
// ===========================================================================

test "writeFile - a single-component filename under an absolute path works" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_no_slash.txt");
    defer deleteFile(path);

    var result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "no slash here",
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings(path, result.path);
    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("no slash here", read);
}

test "writeFile - single-character filename works" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "x");
    defer deleteFile(path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "tiny name",
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 9), fileSize(path));
    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("tiny name", read);
}

test "writeFile - dotfile (hidden file) works" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, ".test_wf_hidden");
    defer deleteFile(path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "hidden content",
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("hidden content", read);
}

test "writeFile - path with directory containing spaces" {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try absPath(&dir_buf, "test_wf dir with spaces");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf dir with spaces/file.txt");
    defer {
        deleteFile(path);
        deleteDir(dir);
    }

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "spaces work too",
        .create_with_dir = true,
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("spaces work too", read);
}

test "writeFile - a .. segment is refused on Windows and resolved by the OS on POSIX" {
    // POSIX resolves `a/../a/inside.txt` like any other path. Windows does
    // NOT get that far: `invalidPathReason` rejects every path containing a
    // `..` segment, because it is a root escape that the NT layer would
    // resolve against a different volume than the caller meant. So the two
    // platforms are asserting two different contracts, and both are correct.
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try absPath(&dir_buf, "test_wf_dotdot_target");
    var inside_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inside = try absPath(&inside_buf, "test_wf_dotdot_target/inside.txt");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_dotdot_target/../test_wf_dotdot_target/inside.txt");
    defer {
        deleteFile(inside);
        deleteDir(dir);
    }

    std.Io.Dir.cwd().createDir(testing.io, dir, .default_dir) catch {}; // idempotent

    if (@import("builtin").os.tag == .windows) {
        try testing.expectError(error.InvalidPathReason, write_file.writeFile(
            testing.allocator,
            testing.io,
            .{ .path = path, .content = "via dotdot" },
        ));
        return;
    }

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "via dotdot",
    });
    defer _wf_r.deinit(testing.allocator);

    const read = try readFileContents(testing.allocator, inside);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("via dotdot", read);
}

test "writeFile - a 255-char filename (POSIX max length) succeeds" {
    // Build a 255-char filename
    var name_buf: [255]u8 = undefined;
    for (&name_buf, 0..) |*b, i| b.* = if (i < 250) 'a' else if (i == 250) '.' else 'x';
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, name_buf[0..]);
    defer deleteFile(path);

    var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "long name",
    });
    defer _wf_r.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 9), fileSize(path));
}

// ===========================================================================
// Section 7: WriteFileResult ownership + deinit
// ===========================================================================

test "writeFileResult.deinit frees the path (no leak)" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_deinit.txt");
    defer deleteFile(path);

    var result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "deinit me",
    });

    // Capture the path's pointer before deinit so we can verify it's
    // been freed afterwards. After deinit, reading from that pointer
    // would be use-after-free — we can't safely assert anything here
    // other than that deinit() doesn't crash.
    result.deinit(testing.allocator);
}

test "writeFileResult.path is heap-allocated (independent of input.slice)" {
    // The returned path must be a fresh allocation (not aliased to the
    // caller's input slice) — otherwise freeing one would corrupt the other.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_path_alloc.txt");
    defer deleteFile(path);

    const result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "owned path",
    });
    defer result.deinit(testing.allocator);

    // The two pointers must differ
    try testing.expect(result.path.ptr != path.ptr);
    try testing.expectEqualStrings(path, result.path);
    try testing.expectEqual(@as(usize, path.len), result.path.len);
}

test "writeFileResult.path has same bytes as input path" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_path_bytes.txt");
    defer deleteFile(path);

    const result = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path,
        .content = "x",
    });
    defer result.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, path, result.path);
}

// ===========================================================================
// Section 8: toJSONSuccess
// ===========================================================================

test "toJSONSuccess carries the file_write path with null error" {
    const wf_path = try testing.allocator.dupe(u8, "/abs/path/to/file.txt");
    defer testing.allocator.free(wf_path);
    const payload = try write_file.toJSONSuccess(testing.allocator, .{ .path = wf_path });
    defer testing.allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("/abs/path/to/file.txt", obj.get("file_write").?.string);
    try testing.expect(obj.get("error").? == .null);
}

test "toJSONSuccess keeps special characters raw (JSON needs no XML escaping)" {
    const wf_path = try testing.allocator.dupe(u8, "/x/with & < > \" ' chars.txt");
    defer testing.allocator.free(wf_path);
    const payload = try write_file.toJSONSuccess(testing.allocator, .{ .path = wf_path });
    defer testing.allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("/x/with & < > \" ' chars.txt", obj.get("file_write").?.string);
    try testing.expect(obj.get("error").? == .null);
}

// ===========================================================================
// Section 9: toJSONError
// ===========================================================================

test "toJSONError for PathNotFound contains descriptive message" {
    const payload = try write_file.toJSONError(
        testing.allocator,
        error.PathNotFound,
        "/abs/missing/file.txt",
    );
    defer testing.allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("/abs/missing/file.txt", obj.get("file_write").?.string);
    const msg = obj.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, msg, "Directory") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "parent directory") != null);
}

test "toJSONError for InputOutput contains permission-related message" {
    const payload = try write_file.toJSONError(
        testing.allocator,
        error.InputOutput,
        "/readonly/file.txt",
    );
    defer testing.allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const msg = parsed.value.object.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, msg, "permission") != null or
        std.mem.indexOf(u8, msg, "Permission") != null or
        std.mem.indexOf(u8, msg, "write permissions") != null);
}

test "toJSONError for generic error uses Unexpected error fallback" {
    const payload = try write_file.toJSONError(
        testing.allocator,
        error.AccessDenied,
        "/some/path",
    );
    defer testing.allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("/some/path", obj.get("file_write").?.string);
    const msg = obj.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, msg, "AccessDenied") != null or
        std.mem.indexOf(u8, msg, "Unexpected") != null);
}

test "toJSONError keeps an empty path without crashing" {
    const payload = try write_file.toJSONError(testing.allocator, error.PathNotFound, "");
    defer testing.allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("", obj.get("file_write").?.string);
    try testing.expect(obj.get("error").? == .string);
}

// Section 10: Tool schema contract
// ===========================================================================

test "write_file_tool - type is function" {
    try testing.expectEqualStrings("function", write_file.write_file_tool.type);
}

test "write_file_tool - function name is 'write_file'" {
    try testing.expectEqualStrings("write_file", write_file.write_file_tool.function.name);
}

test "write_file_tool - parameters require 'path' and 'content'" {
    const params = write_file.write_file_tool.function.parameters;
    try testing.expectEqualStrings("object", params.type);

    var found_path = false;
    var found_content = false;
    for (params.required) |req| {
        if (std.mem.eql(u8, req, "path")) found_path = true;
        if (std.mem.eql(u8, req, "content")) found_content = true;
    }
    try testing.expect(found_path);
    try testing.expect(found_content);
}

test "write_file_tool - declares path, content, create_with_dir properties" {
    const params = write_file.write_file_tool.function.parameters;

    var found_path = false;
    var found_content = false;
    var found_create_with_dir = false;
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "path")) {
            found_path = true;
            try testing.expectEqualStrings("string", prop.type);
        }
        if (std.mem.eql(u8, prop.name, "content")) {
            found_content = true;
            try testing.expectEqualStrings("string", prop.type);
        }
        if (std.mem.eql(u8, prop.name, "create_with_dir")) {
            found_create_with_dir = true;
            try testing.expectEqualStrings("boolean", prop.type);
        }
    }
    try testing.expect(found_path);
    try testing.expect(found_content);
    try testing.expect(found_create_with_dir);
}

test "write_file_tool - description mentions text_replace as the partial-edit alternative" {
    const desc = write_file.write_file_tool.function.description;
    try testing.expect(std.mem.indexOf(u8, desc, "text_replace") != null);
}

test "write_file_tool - description mentions create_with_dir semantics" {
    const desc = write_file.write_file_tool.function.description;
    try testing.expect(std.mem.indexOf(u8, desc, "create_with_dir") != null or
        std.mem.indexOf(u8, desc, "parent directories") != null);
}

test "write_file_tool - create_with_dir is NOT required (has default false)" {
    const params = write_file.write_file_tool.function.parameters;
    for (params.required) |req| {
        try testing.expect(!std.mem.eql(u8, req, "create_with_dir"));
    }
}

// ===========================================================================
// Section 11: WriteFileInput defaults
// ===========================================================================

test "WriteFileInput.create_with_dir defaults to false" {
    const input: write_file.WriteFileInput = .{
        .path = "/x",
        .content = "y",
    };
    try testing.expectEqual(false, input.create_with_dir);
}

// ===========================================================================
// Section 12: Realistic shape — repeated writes to the same dir
// ===========================================================================

test "writeFile - 5 sequential writes to files in same dir all succeed" {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try absPath(&dir_buf, "test_wf_many_files");
    const names_buf: [5][]const u8 = .{ "f1.txt", "f2.txt", "f3.txt", "f4.txt", "f5.txt" };
    // One buffer per joined path: each slice must borrow its own buffer,
    // so they cannot share a single scratch buffer across the loop.
    var path_bufs: [5][std.fs.max_path_bytes]u8 = undefined;
    var paths: [5][]const u8 = undefined;
    for (names_buf, &path_bufs, &paths) |name, *pb, *p| {
        p.* = std.fmt.bufPrint(pb, "{f}", .{std.fs.path.fmtJoin(&.{ dir, name })}) catch @panic("bufPrint failed formatting the joined write_file path");
    }
    defer {
        for (paths) |p| deleteFile(p);
        deleteDir(dir);
    }

    for (paths, 0..) |p, i| {
        const content_owned = try std.fmt.allocPrint(testing.allocator, "file {d}", .{i});
        defer testing.allocator.free(content_owned);
        var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
            .path = p,
            .content = content_owned,
            .create_with_dir = true,
        });
        defer _wf_r.deinit(testing.allocator);
    }

    // Verify each file exists with the right contents
    for (paths, 0..) |full, i| {
        const read = try readFileContents(testing.allocator, full);
        defer testing.allocator.free(read);
        var expected_buf: [16]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "file {d}", .{i}) catch @panic("bufPrint failed formatting the write_file expectation label");
        try testing.expectEqualStrings(expected, read);
    }
}

// ===========================================================================
// Section 13: Stress / concurrency-shape (single-threaded but many ops)
// ===========================================================================

test "writeFile - 20 alternating-size overwrites all leave correct final state" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absPath(&path_buf, "test_wf_stress.bin");
    defer deleteFile(path);

    // Pattern: write 100-byte block, then 1000-byte block, alternating.
    // The file size should track the LAST write in the pattern.
    var small: [100]u8 = undefined;
    var large: [1000]u8 = undefined;
    @memset(&small, 's');
    @memset(&large, 'L');

    var last_was_large = false;
    for (0..20) |_| {
        const content: []const u8 = if (last_was_large) &small else &large;
        var _wf_r = try write_file.writeFile(testing.allocator, testing.io, .{
            .path = path,
            .content = content,
        });
        defer _wf_r.deinit(testing.allocator);
        last_was_large = !last_was_large;
    }

    // After 20 iterations starting with `false` (writes 100-byte first),
    // the last iteration writes `small` (since even iterations are small).
    try testing.expectEqual(@as(u64, 100), fileSize(path));
    const read = try readFileContents(testing.allocator, path);
    defer testing.allocator.free(read);
    try testing.expectEqualSlices(u8, &small, read);
}

// ===========================================================================
// Section 14: Returned result independent across calls
// ===========================================================================

test "writeFile - two consecutive calls return independent path allocations" {
    var path_a_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_a = try absPath(&path_a_buf, "test_wf_indep_a.txt");
    var path_b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_b = try absPath(&path_b_buf, "test_wf_indep_b.txt");
    defer {
        deleteFile(path_a);
        deleteFile(path_b);
    }

    var r1 = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path_a,
        .content = "aaa",
    });
    var r2 = try write_file.writeFile(testing.allocator, testing.io, .{
        .path = path_b,
        .content = "bbb",
    });

    // Independent heap allocations
    try testing.expect(r1.path.ptr != r2.path.ptr);
    try testing.expectEqualStrings(path_a, r1.path);
    try testing.expectEqualStrings(path_b, r2.path);

    // Freeing one must not corrupt the other
    r1.deinit(testing.allocator);
    try testing.expectEqualStrings(path_b, r2.path);
    r2.deinit(testing.allocator);
}

// ─── Parent-directory resolution ─────────────────────────────────────────
// The bug this pins: the previous "index of the last separator" scan cut
// `C:\notes.txt` at index 2 and handed `"C:"` — a drive-RELATIVE name, not
// a directory — to `createDirPath`, which then failed on a file that was
// perfectly writable. On POSIX the equivalent path is `/notes.txt`, whose
// separator index is 0, so the old `> 0` guard skipped the call and the bug
// was invisible off Windows.
// The hand-rolled scan and `std.fs.path.dirname` AGREE on POSIX, so there
// is no Linux-observable behaviour change here — this test is a guard that
// documents the agreement rather than a regression test. The regression
// itself is Windows-only and lives in the two Windows-gated tests below,
// plus the static contract that `write_file` no longer hand-rolls dirname.
test "parentDirToCreate: nested paths resolve normally (guard, not a regression test)" {
    // True on every platform: std.fs.path.dirname treats both separators
    // as separators, so a `/`-joined path has the same parent on Windows.
    try std.testing.expectEqualStrings("/a/b", parentDirToCreate("/a/b/c.txt").?);
    // POSIX-only, and the difference IS the point. On a POSIX host
    // `D:/notes.txt` has parent `D:` — the correct POSIX answer, and
    // exactly what the old hand-rolled scan produced, which is why the
    // drive-root bug never reproduced off Windows. On Windows the same
    // input is `D:/`, because a drive root keeps its separator. So this
    // line is POSIX-only by construction, and asserting the POSIX value
    // on Windows would be asserting the bug back into existence.
    if (@import("builtin").os.tag == .windows) return;
    try std.testing.expectEqualStrings("D:", parentDirToCreate("D:/notes.txt").?);
}

test "parentDirToCreate: normal nested paths are unchanged" {
    try std.testing.expectEqualStrings("/a/b", parentDirToCreate("/a/b/c.txt").?);
    try std.testing.expectEqualStrings("/a", parentDirToCreate("/a/b").?);
    // A bare name has no parent to create.
    try std.testing.expect(parentDirToCreate("notes.txt") == null);
    try std.testing.expect(parentDirToCreate("") == null);
}

// Windows-only: the drive-root case can only be observed on a host whose
// `std.fs.path.dirname` understands volumes, so the value is asserted here
// and the `[Windows]` CI cell is what runs it. On POSIX the same input
// legitimately has no parent.
test "parentDirToCreate: a drive-root file resolves to the drive root on Windows" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectEqualStrings("C:\\", parentDirToCreate("C:\\notes.txt").?);
    try std.testing.expectEqualStrings("C:\\a\\b", parentDirToCreate("C:\\a\\b\\c.txt").?);
    // Forward slashes are what git and Zig's own path.join emit.
    try std.testing.expectEqualStrings("C:/a/b", parentDirToCreate("C:/a/b/c.txt").?);
}

// End-to-end on the platform that has the bug: create_with_dir against a
// drive-root path must succeed rather than fail inside createDirPath.
test "writeFile: create_with_dir succeeds for a file in the drive root on Windows" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    // Whether a drive ROOT is writable is a property of the machine, not of
    // this code, and a GitHub-hosted Windows runner says no: `C:\`'s DACL
    // grants Authenticated Users "Create folders" but not "Create files", so
    // the write below dies with AccessDenied and says nothing at all about
    // the bug under test. Probe with the same call shape first and skip with
    // the reason, rather than reporting a red that a maintainer has to
    // reverse-engineer from a return trace.
    //
    // The parent-dir logic is still pinned on this platform even when this
    // skips: the tests above assert `parentDirToCreate` directly with no
    // I/O at all.
    const probe = "C:\\pabrik_wf_probe.txt";
    std.Io.Dir.cwd().deleteFile(std.testing.io, probe) catch {};
    if (std.Io.Dir.cwd().createFile(std.testing.io, probe, .{})) |probe_file| {
        // `std.Io.File.close(value, io)` — the exact form the helpers above
        // already use, rather than a method call, so this compiles on the one
        // platform that ever sees it without me having a Windows compiler to
        // check the signature against.
        std.Io.File.close(probe_file, std.testing.io);
    } else |err| {
        std.debug.print("skipping: drive root is not writable ({s})\n", .{@errorName(err)});
        return error.SkipZigTest;
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, probe) catch {};

    // `std.Io.Timestamp.nanoseconds` is `i96`, and `@truncate` refuses a
    // signed source ("expected unsigned integer type, found 'i96'"), so
    // reinterpret it unsigned first and keep the low 32 bits.
    const now_ns = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;
    const unique = @as(u32, @truncate(@as(u96, @bitCast(now_ns))));
    const target = try std.fmt.allocPrint(std.testing.allocator, "C:\\pabrik_wf_test_{d}.txt", .{unique});
    defer std.testing.allocator.free(target);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, target) catch {};

    var result = try writeFile(std.testing.allocator, std.testing.io, .{
        .path = target,
        .content = "root file",
        .create_with_dir = true,
    });
    defer result.deinit(std.testing.allocator);

    const read = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, target, std.testing.allocator, std.Io.Limit.limited(1 << 16));
    defer std.testing.allocator.free(read);
    try std.testing.expectEqualStrings("root file", read);
}

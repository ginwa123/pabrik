// Wire test: a relative `path` query/body value no longer ABORTS the server
// in the git file handlers.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// Substrings that only appear in the process log if the worker aborted.
const CRASH_MARKERS = [_][]const u8{
    "received signal ABRT",
    "reached unreachable code",
    "openFileAbsolute",
    "panic:",
};

/// The frontend's cwd, downgraded to a relative path — the malicious/buggy
/// client case.
const RELATIVE_PATH = "relative/repo";
const FILE = "src/main.zig";

/// pytest's `tmp_path`: a scratch directory outside the harness HOME, gone on
/// the way out whatever the test's outcome.
const Scratch = struct {
    tmp: std.testing.TmpDir,
    root: []u8,

    fn init() !Scratch {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(io, &buf);
        return .{ .tmp = tmp, .root = try gpa.dupe(u8, buf[0..len]) };
    }

    fn deinit(self: *Scratch) void {
        self.tmp.cleanup();
        gpa.free(self.root);
    }
};

/// The last `n` lines of the server log. Owned by the caller (free, or leak
/// into a `defer if (len > 0)` as the call sites below do).
fn logTail(h: *Harness, n: usize) ![]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, h.log_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return gpa.dupe(u8, ""),
        else => return err,
    };
    defer gpa.free(data);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(gpa, line);
    }
    const start = if (lines.items.len > n) lines.items.len - n else 0;
    return std.mem.join(gpa, "\n", lines.items[start..]);
}

/// The server is STILL answering, and its log carries no crash marker. This
/// is the whole assertion.
fn assertAlive(h: *Harness, what: []const u8) !void {
    const log_tail = logTail(h, 4000) catch "";
    defer if (log_tail.len > 0) gpa.free(log_tail);

    if (!h.health(io)) {
        std.debug.print(
            "pabrik died while handling {s} — the relative-path abort is back.\n--- log tail ---\n{s}\n",
            .{ what, log_tail },
        );
        return error.TestUnexpectedResult;
    }
    for (CRASH_MARKERS) |marker| {
        if (std.mem.indexOf(u8, log_tail, marker) != null) {
            std.debug.print(
                "{s}: log contains crash marker \"{s}\":\n{s}\n",
                .{ what, marker, log_tail },
            );
            return error.TestUnexpectedResult;
        }
    }
}

/// `POST /api/git/file/diffs` body — the `SidebarDiffPanel.vue` payload with a
/// relative `path`.
const BatchBody = struct {
    path: []const u8,
    files: []const BatchFile,
};

const BatchFile = struct { file: []const u8, staged: bool };

// `?path=<relative>` must 400, not abort the process.
test "file_read_rejects_relative_path" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/file/read", .{
        .params = &.{
            .{ .name = "path", .value = RELATIVE_PATH },
            .{ .name = "file", .value = FILE },
        },
        .expect = &.{400},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const message = doc.str("error") orelse {
        std.debug.print("400 body should carry an `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, message, "absolute") == null) {
        std.debug.print("400 should name the absoluteness requirement, got: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }

    try assertAlive(&h, "GET /api/git/file/read with a relative path");
}

// The batch endpoint's `path` reaches the same API via syntheticFallback.
test "file_diffs_batch_rejects_relative_body_path" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const body = try std.json.Stringify.valueAlloc(gpa, BatchBody{
        .path = RELATIVE_PATH,
        .files = &.{.{ .file = FILE, .staged = false }},
    }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/git/file/diffs", .{
        .json_body = body,
        .expect = &.{400},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const message = doc.str("error") orelse {
        std.debug.print("400 body should carry an `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, message, "absolute") == null) {
        std.debug.print("400 should name the absoluteness requirement, got: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }

    try assertAlive(&h, "POST /api/git/file/diffs with a relative body path");
}

// An absolute `file` escapes `path`; the sibling handler rejects it too.
test "file_read_rejects_absolute_file" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var scratch = try Scratch.init();
    defer scratch.deinit();

    const escaping_file = try std.fmt.allocPrint(
        gpa,
        "{s}{s}..{s}escaped.txt",
        .{ scratch.root, std.fs.path.sep_str, std.fs.path.sep_str },
    );
    defer gpa.free(escaping_file);

    var r = try h.http(io, .GET, "/api/git/file/read", .{
        .params = &.{
            .{ .name = "path", .value = scratch.root },
            .{ .name = "file", .value = escaping_file },
        },
        .expect = &.{400},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const message = doc.str("error") orelse {
        std.debug.print("400 body should carry an `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, message, "relative") == null) {
        std.debug.print("400 should say the file must be relative to path, got: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }

    try assertAlive(&h, "GET /api/git/file/read with an absolute file");
}

// Positive control: the guard must not break the normal (absolute) call. If
// the 400s above were a blanket failure this test would not reach a real file
// read. Reads a fixture under the scratch tmpdir and asserts its bytes.
test "file_read_still_works_for_absolute_paths" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var scratch = try Scratch.init();
    defer scratch.deinit();

    const notes = try std.fs.path.join(gpa, &.{ scratch.root, "notes.txt" });
    defer gpa.free(notes);
    {
        var f = try std.Io.Dir.cwd().createFile(io, notes, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "hello from the wire test\n");
    }

    var r = try h.http(io, .GET, "/api/git/file/read", .{
        .params = &.{
            .{ .name = "path", .value = scratch.root },
            .{ .name = "file", .value = "notes.txt" },
        },
        .expect = &.{200},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const content = doc.str("content") orelse {
        std.debug.print("200 body should carry a `content` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, content, "hello from the wire test") == null) {
        std.debug.print("file read returned the wrong bytes: {s}\n", .{content});
        return error.TestUnexpectedResult;
    }

    try assertAlive(&h, "GET /api/git/file/read with an absolute path");
}

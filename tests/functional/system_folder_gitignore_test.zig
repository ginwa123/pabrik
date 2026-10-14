// Functional wire tests for .gitignore filtering on GET /api/system/folder.
// Zig port of `tests/functional/system_folder_gitignore_test.py` (same test
// names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

// QUERY STRINGS RIDE IN `path`, NOT IN `HttpOptions.params`.

/// A scratch directory to hold the fixture repo, mirroring pytest's
/// `tmp_path`. Removed on the way out, whatever the test's outcome.
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

    /// An absolute path inside the scratch dir.
    fn path(self: *Scratch, parts: []const []const u8) ![]u8 {
        var all = try gpa.alloc([]const u8, parts.len + 1);
        defer gpa.free(all);
        all[0] = self.root;
        for (parts, 0..) |p, i| all[i + 1] = p;
        return std.fs.path.join(gpa, all);
    }
};

/// Write `contents` to `path` (absolute), creating/truncating it.
fn writeFileAt(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// `git init --initial-branch=main --quiet <path>`. `git init` is what makes
/// `git check-ignore` evaluate rules at all: without a repository, git
/// refuses the pathspec and the batched helper has nothing to report.
fn gitInit(path: []const u8) !void {
    var argv: [5][]const u8 = .{ "git", "init", "--initial-branch=main", "--quiet", path };
    const res = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| {
        std.debug.print("git init did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    if (res.term.exited != 0) {
        std.debug.print("git init exited {d}: {s}\n", .{ res.term.exited, res.stderr });
        return error.TestUnexpectedResult;
    }
}

/// Build the `gitignore-proj` fixture inside `s`.
fn buildGitignoreRepo(s: *Scratch) ![]u8 {
    const cwd = try s.path(&.{"gitignore-proj"});
    errdefer gpa.free(cwd);

    try std.Io.Dir.cwd().createDirPath(io, cwd);
    try gitInit(cwd);

    {
        const p = try std.fs.path.join(gpa, &.{ cwd, ".gitignore" });
        defer gpa.free(p);
        try writeFileAt(p, "*.log\nignored_dir/\n");
    }
    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "visible.txt" });
        defer gpa.free(p);
        try writeFileAt(p, "visible\n");
    }
    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "debug.log" });
        defer gpa.free(p);
        try writeFileAt(p, "ignored via *.log\n");
    }
    // The nested file inside the ignored directory — it must not leak
    // into `search` results even though `debug.log` did not.
    {
        const dir = try std.fs.path.join(gpa, &.{ cwd, "ignored_dir" });
        defer gpa.free(dir);
        try std.Io.Dir.cwd().createDirPath(io, dir);
        const p = try std.fs.path.join(gpa, &.{ dir, "secret.txt" });
        defer gpa.free(p);
        try writeFileAt(p, "ignored via dir rule\n");
    }

    return cwd;
}

/// Does the entry array carry an entry named exactly `name`? Python's
/// `[e["name"] for e in r.json()["entries"]]` reduced to a membership test.
fn entriesHaveName(entries: std.json.Array, name: []const u8) bool {
    for (entries.items) |v| {
        const o = switch (v) {
            .object => |o| o,
            else => continue,
        };
        const n = switch (o.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

// Batched check-ignore still filters *.log + ignored_dir/ on search.
test "search_respects_gitignore_rules" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const gitignore_cwd = try buildGitignoreRepo(&s);
    defer gpa.free(gitignore_cwd);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // `q=` is the empty search term — `action=search` with no filter
    // is the "what would this panel show on open" probe.
    const url = try std.fmt.allocPrint(gpa, "/api/system/folder?action=search&path={s}&q=&limit=50", .{gitignore_cwd});
    defer gpa.free(url);

    var r = try h.http(io, .GET, url, .{
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const entries = doc.array("entries") orelse {
        std.debug.print("GET /api/system/folder should return entries, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    if (!entriesHaveName(entries, "visible.txt")) {
        std.debug.print("visible.txt missing: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (entriesHaveName(entries, "debug.log")) {
        std.debug.print("*.log rule violated: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (entriesHaveName(entries, "ignored_dir")) {
        std.debug.print("dir rule violated: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (entriesHaveName(entries, "secret.txt")) {
        std.debug.print("nested ignored file leaked: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// Batched check-ignore still filters on single-level list.
test "list_respects_gitignore_rules" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const gitignore_cwd = try buildGitignoreRepo(&s);
    defer gpa.free(gitignore_cwd);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const url = try std.fmt.allocPrint(gpa, "/api/system/folder?action=list&path={s}", .{gitignore_cwd});
    defer gpa.free(url);

    var r = try h.http(io, .GET, url, .{
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const entries = doc.array("entries") orelse {
        std.debug.print("GET /api/system/folder should return entries, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    if (!entriesHaveName(entries, "visible.txt")) {
        std.debug.print("visible.txt missing: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (entriesHaveName(entries, "debug.log")) {
        std.debug.print("*.log rule violated: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (entriesHaveName(entries, "ignored_dir")) {
        std.debug.print("dir rule violated: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// Functional wire tests for the ChatView-embedded git-diff sidebar. Zig port
// of `tests/functional/chat_right_sidebar_git_test.py` (same test names, same
// order).

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

/// Run `git` with the fixture identity baked in, in `cwd`.
fn git(cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        "git",         "-C",             cwd,
        "-c",          "user.email=t@t", "-c",
        "user.name=t",
        // A machine-wide `commit.gpgsign=true` would make every
        // fixture commit fail for a reason that has nothing to do with
        // the code under test.
        "-c",             "commit.gpgsign=false",
    });
    try argv.appendSlice(gpa, args);

    const res = std.process.run(gpa, io, .{ .argv = argv.items }) catch |err| {
        std.debug.print("git {s} did not spawn: {s}\n", .{ args[0], @errorName(err) });
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    if (res.term.exited != 0) {
        std.debug.print("git {s} exited {d}: {s}\n", .{ args[0], res.term.exited, res.stderr });
        return error.TestUnexpectedResult;
    }
}

/// `git init --initial-branch=main --quiet <path>` — the Python fixture
/// ran this as a separate subprocess before the `_git` helper existed.
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

/// Build the `sidebar-diff-proj` fixture inside `s`.
fn buildDiffRepo(s: *Scratch) ![]u8 {
    const cwd = try s.path(&.{"sidebar-diff-proj"});
    errdefer gpa.free(cwd);

    try std.Io.Dir.cwd().createDirPath(io, cwd);
    try gitInit(cwd);

    // Base commit: two files with the same two-line body, so the
    // staged/unstaged distinction is visible in BOTH files' diffs.
    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "committed.txt" });
        defer gpa.free(p);
        try writeFileAt(p, "keep\nold\n");
    }
    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "staged.txt" });
        defer gpa.free(p);
        try writeFileAt(p, "keep\nold\n");
    }
    try git(cwd, &.{ "add", "-A" });
    try git(cwd, &.{ "commit", "--quiet", "-m", "base" });

    // Unstaged modification: written after the commit, never `git add`ed.
    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "committed.txt" });
        defer gpa.free(p);
        try writeFileAt(p, "keep\nnew\n");
    }
    // Staged modification: written, then `git add`ed.
    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "staged.txt" });
        defer gpa.free(p);
        try writeFileAt(p, "keep\nnew\n");
    }
    try git(cwd, &.{ "add", "staged.txt" });

    // Untracked file: never `git add`ed.
    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "new.txt" });
        defer gpa.free(p);
        try writeFileAt(p, "hello\n");
    }

    return cwd;
}

/// Does the file-object array `arr` contain an entry whose `path` is
/// exactly `want`?
fn arrayHasPath(arr: std.json.Array, want: []const u8) bool {
    for (arr.items) |v| {
        const o = switch (v) {
            .object => |o| o,
            else => continue,
        };
        const p = switch (o.get("path") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, p, want)) return true;
    }
    return false;
}

/// The number of entries in the file-object array `arr`.
fn arrayLen(arr: std.json.Array) usize {
    return arr.items.len;
}

// GET /api/git/changes splits staged / modified / untracked for the panel.
test "changes_groups_files" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const diff_cwd = try buildDiffRepo(&s);
    defer gpa.free(diff_cwd);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const changes_url = try std.fmt.allocPrint(gpa, "/api/git/changes?path={s}", .{diff_cwd});
    defer gpa.free(changes_url);

    var r = try h.http(io, .GET, changes_url, .{
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    try testing.expectEqual(true, doc.boolean("is_git_repo").?);
    try testing.expectEqualStrings("main", doc.str("branch").?);

    const staged = doc.array("staged_files").?;
    const modified = doc.array("modified_files").?;
    const untracked = doc.array("untracked_files").?;

    // Python asserted EXACT list equality; in Zig that is the length
    // plus a membership check, with the body dumped when it fails.
    if (arrayLen(staged) != 1 or !arrayHasPath(staged, "staged.txt")) {
        std.debug.print("staged_files should be exactly [staged.txt], got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (arrayLen(modified) != 1 or !arrayHasPath(modified, "committed.txt")) {
        std.debug.print("modified_files should be exactly [committed.txt], got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (arrayLen(untracked) != 1 or !arrayHasPath(untracked, "new.txt")) {
        std.debug.print("untracked_files should be exactly [new.txt], got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// FOLDER mode returns the unified hunk the inline view renders, and says
// which side it came from. This used to be GET /api/git/file/diff, one git
// spawn per file; it is now one POST for the whole repo.
test "folder_diff_content" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const diff_cwd = try buildDiffRepo(&s);
    defer gpa.free(diff_cwd);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const diff_body = try std.fmt.allocPrint(gpa, "{{\"path\":\"{s}\",\"folder\":\"\"}}", .{diff_cwd});
    defer gpa.free(diff_body);

    var r = try h.http(io, .POST, "/api/git/file/diffs", .{
        .json_body = diff_body,
        .expect = &.{200},
        .timeout_s = 30.0,
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    // The whole repo comes back in one response, each row tagged with the
    // side it belongs to.
    const diffs = doc.array("diffs") orelse return error.TestUnexpectedResult;
    var found: ?[]const u8 = null;
    var found_staged: ?bool = null;
    for (diffs.items) |row| {
        if (!std.mem.eql(u8, row.object.get("path").?.string, "committed.txt")) continue;
        found = row.object.get("diff_content").?.string;
        found_staged = row.object.get("staged").?.bool;
        break;
    }
    const diff_content = found orelse {
        std.debug.print("committed.txt missing from folder diff: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    // committed.txt is modified in the worktree only, so it is NOT staged.
    try testing.expectEqual(false, found_staged.?);
    try testing.expect(std.mem.indexOf(u8, diff_content, "-old") != null);
    try testing.expect(std.mem.indexOf(u8, diff_content, "+new") != null);
    try testing.expect(std.mem.indexOf(u8, diff_content, "@@") != null);
}

// The per-file diff route is gone: asking for it must 404, not fall through
// to some other handler that happens to match the path.
test "per_file_diff_route_is_gone" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const diff_cwd = try buildDiffRepo(&s);
    defer gpa.free(diff_cwd);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/file/diff", .{
        .params = &.{
            .{ .name = "path", .value = diff_cwd },
            .{ .name = "file", .value = "committed.txt" },
            .{ .name = "staged", .value = "false" },
        },
        // assert_status = false: THE STATUS IS THE ASSERTION. A hard-coded
        // `.expect` would make the harness raise before we can look.
        .assert_status = false,
        .timeout_s = 15.0,
    });
    defer r.deinit();
    try testing.expectEqual(@as(u16, 404), r.status);
}

// POST /stage|/unstage move committed.txt between groups on the wire.
test "stage_unstage_round_trip" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const diff_cwd = try buildDiffRepo(&s);
    defer gpa.free(diff_cwd);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Stage committed.txt — it moves modified → staged.
    {
        const stage_url = try std.fmt.allocPrint(gpa, "/api/git/stage?path={s}&files=committed.txt", .{diff_cwd});
        defer gpa.free(stage_url);

        var stage = try h.http(io, .POST, stage_url, .{
            .expect = &.{200},
            .timeout_s = 15.0,
        });
        defer stage.deinit();
    }
    {
        const url = try std.fmt.allocPrint(gpa, "/api/git/changes?path={s}", .{diff_cwd});
        defer gpa.free(url);

        var after_stage = try h.http(io, .GET, url, .{
            .expect = &.{200},
            .timeout_s = 15.0,
        });
        defer after_stage.deinit();

        var doc = try after_stage.json();
        defer doc.deinit();
        if (!arrayHasPath(doc.array("staged_files").?, "committed.txt")) {
            std.debug.print("committed.txt missing from staged_files: {s}\n", .{after_stage.body});
            return error.TestUnexpectedResult;
        }
    }

    // Unstage it — it moves back to modified and leaves staged.
    {
        const unstage_url = try std.fmt.allocPrint(gpa, "/api/git/unstage?path={s}&files=committed.txt", .{diff_cwd});
        defer gpa.free(unstage_url);

        var unstage = try h.http(io, .POST, unstage_url, .{
            .expect = &.{200},
            .timeout_s = 15.0,
        });
        defer unstage.deinit();
    }
    {
        const url = try std.fmt.allocPrint(gpa, "/api/git/changes?path={s}", .{diff_cwd});
        defer gpa.free(url);

        var after_unstage = try h.http(io, .GET, url, .{
            .expect = &.{200},
            .timeout_s = 15.0,
        });
        defer after_unstage.deinit();

        var doc = try after_unstage.json();
        defer doc.deinit();
        if (!arrayHasPath(doc.array("modified_files").?, "committed.txt")) {
            std.debug.print("committed.txt missing from modified_files: {s}\n", .{after_unstage.body});
            return error.TestUnexpectedResult;
        }
        if (arrayHasPath(doc.array("staged_files").?, "committed.txt")) {
            std.debug.print("committed.txt still staged after unstage: {s}\n", .{after_unstage.body});
            return error.TestUnexpectedResult;
        }
    }
}

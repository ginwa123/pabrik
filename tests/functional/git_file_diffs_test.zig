// Functional wire tests for POST /api/git/file/diffs (batch endpoint). Zig
// port of `tests/functional/git_file_diffs_test.py` (same test names).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// Run `git` with a fixed identity so the fixture never depends on the
/// machine's global git config (which CI does not set).
fn git(cwd: []const u8, args: []const []const u8) !void {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.append(gpa, "git");
    try full.append(gpa, "-c");
    try full.append(gpa, "user.email=t@t");
    try full.append(gpa, "-c");
    try full.append(gpa, "user.name=t");
    try full.appendSlice(gpa, args);

    var child = try std.process.spawn(io, .{ .argv = full.items, .cwd = .{ .path = cwd } });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("git {s} failed with rc={d}\n", .{ args[args.len - 1], code });
            return error.TestUnexpectedResult;
        },
        else => {
            std.debug.print("git {s} died by signal\n", .{args[args.len - 1]});
            return error.TestUnexpectedResult;
        },
    }
}

/// Run `git` and return its stdout, for use as an ORACLE the handler is
/// checked against.
fn gitCapture(cwd: []const u8, args: []const []const u8) ![]u8 {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.append(gpa, "git");
    try full.appendSlice(gpa, args);

    // Same (allocator, io, opts) shape the handlers themselves use.
    const out = try std.process.run(gpa, io, .{ .argv = full.items, .cwd = .{ .path = cwd } });
    if (out.term != .exited or out.term.exited != 0) return error.TestUnexpectedResult;
    return out.stdout;
}

fn writeFileAt(dir: std.Io.Dir, name: []const u8, contents: []const u8) !void {
    var f = try dir.createFile(io, name, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// The fixture repo, built inside `scratch`. Returns the owned repo path;
/// the caller frees it and cleans `scratch` via `cleanupExtraDir`.
fn buildDiffCwd(scratch: []const u8) ![]u8 {
    const repo = try std.fs.path.join(gpa, &.{ scratch, "batch-diff-proj" });
    errdefer gpa.free(repo);

    try std.Io.Dir.cwd().createDirPath(io, repo);
    var repo_dir = try std.Io.Dir.cwd().openDir(io, repo, .{});
    defer repo_dir.close(io);

    // `--initial-branch=main` is what makes the fixture deterministic
    // across git versions.
    try git(scratch, &.{ "init", "--initial-branch=main", "--quiet", repo });

    try writeFileAt(repo_dir, "committed.txt", "keep\nold\n");
    try writeFileAt(repo_dir, "staged.txt", "keep\nold\n");
    try git(repo, &.{ "add", "-A" });
    try git(repo, &.{ "commit", "--quiet", "-m", "base" });

    try writeFileAt(repo_dir, "committed.txt", "keep\nnew\n");
    try writeFileAt(repo_dir, "staged.txt", "keep\nnew\n");
    try git(repo, &.{ "add", "staged.txt" });
    try writeFileAt(repo_dir, "new.txt", "hello\n");

    return repo;
}

/// Boot a harness plus a fixture repo, with both cleaned up on the way
/// out. The repo path is returned; `*h` and `*scratch` are for the caller's
/// `defer`s.
fn bootWithRepo(h: *Harness, scratch: *[]u8, repo: *[]u8) !void {
    try harness.requirePabrikBin(io, gpa);
    h.* = try Harness.boot(io, gpa, .{});

    scratch.* = harness.makeScratchDir(gpa) catch |err| {
        h.deinit(io) catch {};
        return err;
    };
    repo.* = buildDiffCwd(scratch.*) catch |err| {
        harness.cleanupExtraDir(io, gpa, scratch.*);
        h.deinit(io) catch {};
        return err;
    };
}

/// A `{"file": ..., "staged": bool}` entry for the batch body.
fn fileEntry(name: []const u8, staged: bool) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{{\"file\":\"{s}\",\"staged\":{s}}}", .{
        name, if (staged) "true" else "false",
    });
}

// One POST returns staged + unstaged + untracked diffs, in order.
test "batch_returns_all_three_groups" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    // DEFER ORDER IS LIFO AND LOADS-BEARING HERE.
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(repo);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const e1 = try fileEntry("staged.txt", true);
    defer gpa.free(e1);
    const e2 = try fileEntry("committed.txt", false);
    defer gpa.free(e2);
    const e3 = try fileEntry("new.txt", false);
    defer gpa.free(e3);

    const body = try std.fmt.allocPrint(gpa, "{{\"path\":\"{s}\",\"files\":[{s},{s},{s}]}}", .{
        repo, e1, e2, e3,
    });
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/git/file/diffs", .{
        .json_body = body,
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const diffs = doc.array("diffs") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), diffs.items.len);

    // Order preserved: staged, committed (unstaged), new (untracked).
    const want_names = [_][]const u8{ "staged.txt", "committed.txt", "new.txt" };
    const want_staged = [_]bool{ true, false, false };
    for (diffs.items, 0..) |row, i| {
        const obj = switch (row) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqualStrings(want_names[i], obj.get("path").?.string);
        const flag = switch (obj.get("staged").?) {
            .bool => |b| b,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(want_staged[i], flag);
    }

    // Staged + unstaged carry the unified hunk.
    for (diffs.items[0..2]) |row| {
        const content = row.object.get("diff_content").?.string;
        try testing.expect(std.mem.indexOf(u8, content, "-old") != null);
        try testing.expect(std.mem.indexOf(u8, content, "+new") != null);
        try testing.expect(std.mem.indexOf(u8, content, "@@") != null);
    }

    // Untracked falls back to a synthetic new-file diff.
    const untracked = diffs.items[2].object.get("diff_content").?.string;
    try testing.expect(std.mem.indexOf(u8, untracked, "+hello") != null);
}

// Batch content for one file is byte-identical to `git diff` itself.
test "batch_matches_git_diff_output" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    // DEFER ORDER IS LIFO AND LOADS-BEARING HERE.
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(repo);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    // There is no per-file endpoint to compare against any more — it is
    // deleted.
    const git_out = try gitCapture(repo, &.{ "diff", "--", "committed.txt" });
    defer gpa.free(git_out);

    const entry = try fileEntry("committed.txt", false);
    defer gpa.free(entry);
    const body = try std.fmt.allocPrint(gpa, "{{\"path\":\"{s}\",\"files\":[{s}]}}", .{ repo, entry });
    defer gpa.free(body);

    var batch = try h.http(io, .POST, "/api/git/file/diffs", .{
        .json_body = body,
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer batch.deinit();
    var batch_doc = try batch.json();
    defer batch_doc.deinit();

    const diffs = batch_doc.array("diffs") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), diffs.items.len);
    const got = diffs.items[0].object.get("diff_content").?.string;
    try testing.expectEqualStrings(git_out, got);
    // …and the row carries the side it was asked for, which is how the
    // client tells a staged diff from a worktree one.
    try testing.expectEqual(false, diffs.items[0].object.get("staged").?.bool);
    try testing.expectEqualStrings("committed.txt", diffs.items[0].object.get("path").?.string);
}

// An empty files list is a 400, not a 500.
test "batch_validation" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    // DEFER ORDER IS LIFO AND LOADS-BEARING HERE.
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(repo);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const body = try std.fmt.allocPrint(gpa, "{{\"path\":\"{s}\",\"files\":[]}}", .{repo});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/git/file/diffs", .{
        .json_body = body,
        .expect = &.{400},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    try testing.expectEqual(@as(u16, 400), r.status);
}

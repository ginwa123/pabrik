// Functional wire tests for FOLDER mode of POST /api/git/file/diffs. LIST
// mode (`git_file_diffs_test.zig`) still needs the caller to fetch `GET
// /api/git/changes` first and then post the file list.

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

fn writeFileAt(dir: std.Io.Dir, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(io, parent);
    }
    var f = try dir.createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

fn buildFolderCwd(scratch: []const u8) ![]u8 {
    const repo = try std.fs.path.join(gpa, &.{ scratch, "folder-diff-proj" });
    errdefer gpa.free(repo);

    try std.Io.Dir.cwd().createDirPath(io, repo);
    var repo_dir = try std.Io.Dir.cwd().openDir(io, repo, .{});
    defer repo_dir.close(io);

    try git(scratch, &.{ "init", "--initial-branch=main", "--quiet", repo });

    for ([_]struct { []const u8, []const u8 }{
        .{ "src/committed.txt", "keep\nold\n" },
        .{ "src/staged.txt", "keep\nold\n" },
        .{ "src/both.txt", "keep\nold\n" },
        .{ "docs/readme.txt", "keep\nold\n" },
        .{ "top.txt", "keep\nold\n" },
        .{ "clean/untouched.txt", "never touched\n" },
    }) |seed| {
        try writeFileAt(repo_dir, seed[0], seed[1]);
    }
    try git(repo, &.{ "add", "-A" });
    try git(repo, &.{ "commit", "--quiet", "-m", "base" });

    try writeFileAt(repo_dir, "src/committed.txt", "keep\nnew\n");
    try writeFileAt(repo_dir, "src/staged.txt", "keep\nnew\n");
    try git(repo, &.{ "add", "src/staged.txt" });
    // Staged AND THEN modified again -> porcelain `MM`.
    try writeFileAt(repo_dir, "src/both.txt", "keep\nstaged\n");
    try git(repo, &.{ "add", "src/both.txt" });
    try writeFileAt(repo_dir, "src/both.txt", "keep\nnew\n");
    try writeFileAt(repo_dir, "docs/readme.txt", "keep\nnew\n");
    try writeFileAt(repo_dir, "top.txt", "keep\nnew\n");
    try writeFileAt(repo_dir, "src/fresh.txt", "brand new\n");

    return repo;
}

fn bootWithRepo(h: *Harness, scratch: *[]u8, repo: *[]u8) !void {
    try harness.requirePabrikBin(io, gpa);
    h.* = try Harness.boot(io, gpa, .{});

    scratch.* = harness.makeScratchDir(gpa) catch |err| {
        h.deinit(io) catch {};
        return err;
    };
    repo.* = buildFolderCwd(scratch.*) catch |err| {
        harness.cleanupExtraDir(io, gpa, scratch.*);
        h.deinit(io) catch {};
        return err;
    };
}

/// Boot + the LIFO `defer` ladder that owns the buffers.
const Fixture = struct {
    h: Harness,
    scratch: []u8,
    repo: []u8,

    fn init() !Fixture {
        var f: Fixture = undefined;
        try bootWithRepo(&f.h, &f.scratch, &f.repo);
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
        gpa.free(self.repo);
        harness.cleanupExtraDir(io, gpa, self.scratch);
        gpa.free(self.scratch);
    }
};

/// `{"path": ..., "folder": <folder>}` — folder mode, no file list.
fn folderBody(repo: []const u8, folder: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"path\":\"{s}\",\"folder\":\"{s}\"}}", .{ repo, folder });
}

fn postFolder(h: *Harness, body: []const u8, expect: []const u16) !harness.Response {
    return h.http(io, .POST, "/api/git/file/diffs", .{
        .json_body = body,
        .expect = expect,
        .timeout_s = 30.0,
    });
}

/// A borrowed-key index over a parsed `diffs` array, plus the OWNED keys it
/// points into.
const OwnedIndex = struct {
    map: std.StringHashMap([]const u8),
    owned: std.ArrayList([]u8),

    fn deinit(self: *OwnedIndex) void {
        for (self.owned.items) |k| gpa.free(k);
        self.owned.deinit(gpa);
        self.map.deinit();
    }
};

fn initIndex() OwnedIndex {
    return .{ .map = std.StringHashMap([]const u8).init(gpa), .owned = .empty };
}

/// `(staged, path) -> diff_content`. The python used `{d["staged"],
/// d["path"]: d["diff_content"] ...}`. A `std.json.Value` cannot be a map
/// key, so this keys on the FORMATTED `"{staged}:{path}"` string instead.
fn indexBySideAndPath(diffs: []const std.json.Value) !OwnedIndex {
    var ix = initIndex();
    errdefer ix.deinit();
    for (diffs) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const path = obj.get("path") orelse return error.TestUnexpectedResult;
        const staged = obj.get("staged") orelse return error.TestUnexpectedResult;
        const flag = switch (staged) {
            .bool => |b| b,
            else => return error.TestUnexpectedResult,
        };
        const key = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ if (flag) "1" else "0", path.string });
        errdefer gpa.free(key);
        // First row wins; duplicates should not happen within one side.
        if (ix.map.contains(key)) {
            gpa.free(key);
            continue;
        }
        try ix.owned.append(gpa, key);
        try ix.map.put(key, obj.get("diff_content").?.string);
    }
    return ix;
}

/// The set of paths a response reported.
fn indexPaths(diffs: []const std.json.Value) !OwnedIndex {
    var ix = initIndex();
    errdefer ix.deinit();
    for (diffs) |row| {
        const path = row.object.get("path") orelse return error.TestUnexpectedResult;
        const key = try gpa.dupe(u8, path.string);
        errdefer gpa.free(key);
        if (ix.map.contains(key)) {
            gpa.free(key);
            continue;
        }
        try ix.owned.append(gpa, key);
        try ix.map.put(key, "");
    }
    return ix;
}

fn expectRow(map: *const std.StringHashMap([]const u8), staged: bool, path: []const u8) ![]const u8 {
    const key = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ if (staged) "1" else "0", path });
    defer gpa.free(key);
    return map.get(key) orelse error.TestUnexpectedResult;
}

/// Collect the set of paths a response reported, as an owned StringHashMap.
fn pathSet(gpa_: std.mem.Allocator, diffs: []const std.json.Value) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(gpa_);
    errdefer {
        var it = set.keyIterator();
        while (it.next()) |k| gpa_.free(k.*);
        set.deinit();
    }
    for (diffs) |row| {
        const path = row.object.get("path") orelse return error.TestUnexpectedResult;
        try set.put(try gpa_.dupe(u8, path.string), {});
    }
    return set;
}

fn expectSameSet(got: *const OwnedIndex, want: []const []const u8) !void {
    try testing.expectEqual(want.len, got.map.count());
    for (want) |w| try testing.expect(got.map.contains(w));
}

// One POST on `folder: "src"` returns staged + unstaged + untracked.
test "folder_mode_returns_every_changed_file_under_the_folder_in_one_call" {
    var f = try Fixture.init();
    defer f.deinit();

    const body = try folderBody(f.repo, "src");
    defer gpa.free(body);

    var r = try postFolder(&f.h, body, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const diffs = doc.array("diffs") orelse return error.TestUnexpectedResult;
    var by_key = try indexBySideAndPath(diffs.items);
    defer by_key.deinit();

    // The two sides the caller would otherwise have had to enumerate itself.
    try testing.expect(std.mem.indexOf(u8, try expectRow(&by_key.map, false, "src/committed.txt"), "+new") != null);
    try testing.expect(std.mem.indexOf(u8, try expectRow(&by_key.map, true, "src/staged.txt"), "+new") != null);
    // Untracked under src/ — `git diff` shows nothing for it, so this only
    // works if the server enumerated the path AND fell back to the synthetic
    // new-file diff.
    try testing.expect(std.mem.indexOf(u8, try expectRow(&by_key.map, false, "src/fresh.txt"), "+brand new") != null);
}

// `folder: "src"` must not leak sibling or root-level changes.
test "folder_mode_excludes_files_outside_the_folder" {
    var f = try Fixture.init();
    defer f.deinit();

    const body = try folderBody(f.repo, "src");
    defer gpa.free(body);

    var r = try postFolder(&f.h, body, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const diffs = doc.array("diffs") orelse return error.TestUnexpectedResult;
    var got = try indexPaths(diffs.items);
    defer got.deinit();
    try expectSameSet(&got, &.{ "src/committed.txt", "src/staged.txt", "src/fresh.txt", "src/both.txt" });
}

// `folder: ""` is the whole repo, and reaches docs/ and the root.
test "empty_folder_string_means_the_whole_repo" {
    var f = try Fixture.init();
    defer f.deinit();

    const body = try folderBody(f.repo, "");
    defer gpa.free(body);

    var r = try postFolder(&f.h, body, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const diffs = doc.array("diffs") orelse return error.TestUnexpectedResult;
    var got = try indexPaths(diffs.items);
    defer got.deinit();
    try expectSameSet(&got, &.{
        "src/committed.txt",
        "src/staged.txt",
        "src/both.txt",
        "src/fresh.txt",
        "docs/readme.txt",
        "top.txt",
    });
}

// A folder with no changes is a real answer. A 400 would push the client into
// its per-file fallback and restart the request flood.
test "clean_folder_is_an_empty_list_not_a_400" {
    var f = try Fixture.init();
    defer f.deinit();

    const body = try folderBody(f.repo, "clean");
    defer gpa.free(body);

    var r = try postFolder(&f.h, body, &.{200});
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);

    var doc = try r.json();
    defer doc.deinit();
    const diffs = doc.array("diffs") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), diffs.items.len);
}

// The same file through both modes must produce byte-identical content.
test "folder_mode_matches_list_mode_content" {
    var f = try Fixture.init();
    defer f.deinit();

    const whole = try folderBody(f.repo, "");
    defer gpa.free(whole);
    var r = try postFolder(&f.h, whole, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    var folder_side = try indexBySideAndPath(doc.array("diffs").?.items);
    defer folder_side.deinit();

    const list_body = try std.fmt.allocPrint(
        gpa,
        "{{\"path\":\"{s}\",\"files\":[" ++
            "{{\"file\":\"src/committed.txt\",\"staged\":false}}," ++
            "{{\"file\":\"docs/readme.txt\",\"staged\":false}}," ++
            "{{\"file\":\"top.txt\",\"staged\":false}}]}}",
        .{f.repo},
    );
    defer gpa.free(list_body);

    var lr = try postFolder(&f.h, list_body, &.{200});
    defer lr.deinit();
    var ldoc = try lr.json();
    defer ldoc.deinit();

    const rows = ldoc.array("diffs").?.items;
    try testing.expectEqual(@as(usize, 3), rows.len);
    for (rows) |row| {
        const path = row.object.get("path").?.string;
        try testing.expectEqualStrings(
            row.object.get("diff_content").?.string,
            try expectRow(&folder_side.map, false, path),
        );
    }
}

// `folder` becomes a git pathspec; `..` would diff outside the repo.
test "folder_mode_rejects_a_parent_escaping_path" {
    var f = try Fixture.init();
    defer f.deinit();

    for ([_][]const u8{ "../..", "/etc" }) |bad| {
        const body = try folderBody(f.repo, bad);
        defer gpa.free(body);
        var r = try postFolder(&f.h, body, &.{400});
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.status);
    }
}

// The response is a LIST of files, each tagged with the side it came from.
// A path that is both staged and modified appears TWICE — once `staged:true`,
// once `staged:false` — because those are two different diffs.
test "folder_response_lists_each_file_with_its_staged_state" {
    var f = try Fixture.init();
    defer f.deinit();

    const body = try folderBody(f.repo, "src");
    defer gpa.free(body);

    var r = try postFolder(&f.h, body, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const diffs = doc.array("diffs") orelse return error.TestUnexpectedResult;

    // Count the rows per (path, side). `expectRow` cannot express "appears
    // twice", so count directly.
    var staged_both: usize = 0;
    var unstaged_both: usize = 0;
    for (diffs.items) |row| {
        const path = row.object.get("path").?.string;
        const flag = row.object.get("staged").?.bool;
        if (std.mem.eql(u8, path, "src/both.txt")) {
            if (flag) staged_both += 1 else unstaged_both += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), staged_both);
    try testing.expectEqual(@as(usize, 1), unstaged_both);

    // Every row carries all three fields, so a client can render the list
    // without a second request to find out what a row means.
    for (diffs.items) |row| {
        try testing.expect(row.object.get("path") != null);
        try testing.expect(row.object.get("diff_content") != null);
        try testing.expect(row.object.get("staged") != null);
    }

    // And the two sides of `src/both.txt` are genuinely DIFFERENT diffs.
    var by_key = try indexBySideAndPath(diffs.items);
    defer by_key.deinit();
    const staged_diff = try expectRow(&by_key.map, true, "src/both.txt");
    const unstaged_diff = try expectRow(&by_key.map, false, "src/both.txt");
    try testing.expect(std.mem.indexOf(u8, staged_diff, "+staged") != null);
    try testing.expect(std.mem.indexOf(u8, unstaged_diff, "+new") != null);
    try testing.expect(std.mem.indexOf(u8, staged_diff, "+new") == null);
    try testing.expect(std.mem.indexOf(u8, unstaged_diff, "+staged") == null);
}

// Sending neither `files` nor `folder` is a 400, not a silent "no changes".
test "sending_neither_files_nor_folder_is_a_400" {
    var f = try Fixture.init();
    defer f.deinit();

    const body = try std.fmt.allocPrint(gpa, "{{\"path\":\"{s}\"}}", .{f.repo});
    defer gpa.free(body);

    var r = try postFolder(&f.h, body, &.{400});
    defer r.deinit();
    try testing.expectEqual(@as(u16, 400), r.status);
}

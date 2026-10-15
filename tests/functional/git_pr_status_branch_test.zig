// Branch-name round-trip for GET /api/git/pr/status. Zig port of
// `tests/functional/git_pr_status_branch_test.py` (same test name).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

// THE QUERY STRING RIDES IN `path`, NOT IN `HttpOptions.params`.

/// What the fake `gh` prints on stdout: a realistic `gh pr view --json`
/// payload for a MERGED pull request, authored by a human, on a
/// worktree branch. Every field the handler reads back is present.
const GH_PAYLOAD =
    \\{"number":577,"title":"Color git icon","url":"https://github.com/acme/app/pull/577","state":"MERGED","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"worktree/feature-x-123","baseRefName":"main","createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-02T00:00:00Z","mergedAt":"2026-09-03T00:00:00Z","closedAt":"","author":{"login":"alice"},"additions":1,"deletions":0,"changedFiles":1}
;

/// The fake `gh`: record every argv entry, one per line, then print the
/// payload. `{0}` is the absolute path of the args file, `{1}` the payload.
const FAKE_GH_SCRIPT =
    \\#!/bin/sh
    \\for a in "$@"; do printf '%s\n' "$a"; done > '{s}'
    \\cat <<'EOF'
    \\{s}
    \\EOF
    \\
;

/// The branch the test sends, in the two spellings that matter: the
/// DECODED value `gh` must receive, and the PERCENT-ENCODED value that
/// is what the frontend actually puts on the query string.
const BRANCH = "worktree/feature-x-123";
const BRANCH_ENCODED = "worktree%2Ffeature-x-123";

/// A scratch directory to hold the fixture repo + fake bin, mirroring
/// pytest's `tmp_path`. Removed on the way out.
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

/// Prepend `prefix` to `PATH` in `std.testing.environ` — the exact block
/// `Harness.boot` copies into the child env — so the booted `pabrik` resolves
/// `gh` to the fixture script.
const PathShadow = struct {
    gpa: std.mem.Allocator,
    saved: std.process.Environ,
    entries: [:null]const ?[*:0]const u8,

    fn install(alloc: std.mem.Allocator, prefix: []const u8) !PathShadow {
        // `Environ`'s block is a raw `KEY=VALUE` slice on POSIX.
        if (comptime @import("builtin").os.tag != .windows) {
            const saved = std.testing.environ;
            const orig = saved.block.slice;

            const entries = try alloc.allocSentinel(?[*:0]const u8, orig.len, null);
            errdefer alloc.free(entries);

            var owned: std.ArrayList([:0]u8) = .empty;
            defer owned.deinit(alloc);
            errdefer for (owned.items) |o| alloc.free(o);

            for (orig, 0..) |maybe, i| {
                const s = std.mem.span(maybe.?);
                if (std.mem.startsWith(u8, s, "PATH=")) {
                    try owned.append(alloc, try std.fmt.allocPrintSentinel(alloc, "PATH={s}{c}{s}", .{
                        prefix,
                        std.fs.path.delimiter,
                        s["PATH=".len..],
                    }, 0));
                } else {
                    try owned.append(alloc, try alloc.dupeZ(u8, s));
                }
                entries[i] = owned.items[owned.items.len - 1].ptr;
            }

            std.testing.environ = .{ .block = .{ .slice = entries } };
            return .{ .gpa = alloc, .saved = saved, .entries = entries };
        } else {
            return error.SkipZigTest;
        }
    }

    fn restore(self: PathShadow) void {
        std.testing.environ = self.saved;
        for (self.entries) |e| self.gpa.free(std.mem.span(e.?));
        self.gpa.free(self.entries);
    }
};

/// Write `contents` to `path` (absolute), creating/truncating it.
fn writeFileAt(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// Write an executable `/bin/sh` script at `path`.
fn writeExecScript(path: []const u8, contents: []const u8) !void {
    try writeFileAt(path, contents);
    try std.Io.Dir.cwd().setFilePermissions(io, path, .executable_file, .{});
}

/// `git init --initial-branch=main --quiet <path>`.
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

/// Run `git` in `cwd` with the fixture identity baked in.
fn git(cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        "git", "-C", cwd,
        "-c", "user.email=t@t",
        "-c", "user.name=t",
        "-c", "commit.gpgsign=false",
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

/// Build the `pr-branch-proj` fixture: one committed file on `main`.
fn buildRepo(s: *Scratch) ![]u8 {
    const cwd = try s.path(&.{"pr-branch-proj"});
    errdefer gpa.free(cwd);

    try std.Io.Dir.cwd().createDirPath(io, cwd);
    try gitInit(cwd);

    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "a.txt" });
        defer gpa.free(p);
        try writeFileAt(p, "hi\n");
    }
    try git(cwd, &.{ "add", "-A" });
    try git(cwd, &.{ "commit", "--quiet", "-m", "base" });

    return cwd;
}

// `pr=worktree/feature-x-123` must arrive at `gh` as one intact arg.
test "branch_with_slashes_reaches_gh_intact" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();

    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    // The fake `gh` lives in its own bindir so prepending that
    // directory to PATH cannot shadow any other command the server
    // needs (`git` in particular — the repo gate runs it).
    const bindir = try s.path(&.{"fakebin"});
    defer gpa.free(bindir);
    try std.Io.Dir.cwd().createDirPath(io, bindir);

    // The args file is BAKED into the script rather than passed via
    // `GH_ARGS_FILE`: a second env var the server would have to inherit is a
    // second thing that can go wrong, and the script already has to be
    const args_file = try s.path(&.{"gh-args.txt"});
    defer gpa.free(args_file);

    {
        const gh_path = try std.fs.path.join(gpa, &.{ bindir, "gh" });
        defer gpa.free(gh_path);
        const script = try std.fmt.allocPrint(gpa, FAKE_GH_SCRIPT, .{ args_file, GH_PAYLOAD });
        defer gpa.free(script);
        try writeExecScript(gh_path, script);
    }

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // `BRANCH_ENCODED` is written literally rather than left to a URL
    // builder: this IS the bytes the frontend's `URLSearchParams` put
    // on the wire, and decoding them is the behaviour under test.
    const url = try std.fmt.allocPrint(gpa, "/api/git/pr/status?path={s}&pr={s}", .{ repo, BRANCH_ENCODED });
    defer gpa.free(url);

    var r = try h.http(io, .GET, url, .{
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    // 200 alone is not enough: a fixture that never ran would 404/502.
    // `status`/`head_ref` come from the fake `gh`'s stdout, so both
    // prove the payload round-tripped.
    try testing.expectEqualStrings("merged", doc.str("status").?);
    try testing.expectEqualStrings(BRANCH, doc.str("head_ref").?);

    const argv_text = std.Io.Dir.cwd().readFileAlloc(io, args_file, gpa, .limited(1 << 16)) catch |err| {
        std.debug.print("gh never recorded its argv ({s})\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(argv_text);

    // Every argv entry, one per line.
    var saw_intact = false;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, argv_text, "\n"), '\n');
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, BRANCH)) saw_intact = true;
        if (std.mem.indexOf(u8, arg, "%2F") != null or std.mem.indexOf(u8, arg, "%2f") != null) {
            std.debug.print("gh received percent-encoded branch: {s}\n", .{argv_text});
            return error.TestUnexpectedResult;
        }
    }
    if (!saw_intact) {
        std.debug.print("gh received mangled argv: {s}\n", .{argv_text});
        return error.TestUnexpectedResult;
    }
}

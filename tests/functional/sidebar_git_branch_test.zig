// Sidebar git branch badge wire contract (kanban parity). Zig port of
// `tests/functional/sidebar_git_branch_test.py` (same test names, same
// order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// The branch the fixture repo is parked on. Deliberately a `worktree/...`
/// name with a slash — that is the shape the kanban card sends as
/// `?pr=<branch>`, so the fixture is realistic rather than a bare `main`.
const BRANCH = "worktree/sidebar-badge-test";

/// A scratch directory to hold fixture repos, mirroring pytest's `tmp_path`.
/// Removed on the way out.
const Scratch = struct {
    dir: std.Io.Dir,
    root: []u8,

    fn init() !Scratch {
        const root = try harness.tmpRoot(gpa);
        defer gpa.free(root);

        // A unique-ish name so two concurrent runs do not collide.
        // `std.testing.tmpDir` cannot be used (see above), so derive
        // the suffix from the monotonic clock.
        const stamp = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        const name = try std.fmt.allocPrint(gpa, "zigtest-sidebar-branch-{x}", .{@as(u64, @bitCast(stamp))});
        defer gpa.free(name);

        // A plain `defer`, not `errdefer`: on the SUCCESS path this function
        // still owns `dir_path` (the caller gets the `real_path` dupe, not
        // this buffer), so it must be freed unconditionally.
        const dir_path = try std.fs.path.join(gpa, &.{ root, name });
        defer gpa.free(dir_path);
        try std.Io.Dir.cwd().createDirPath(io, dir_path);

        // `realPath(dir, io, out_buffer)` — the path is the DIR's, not
        // an argument, so resolve through a just-opened handle.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var opened = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        defer opened.close(io);
        const real_len = try opened.realPath(io, &buf);

        // Ownership of the dupe transfers to the returned Scratch.
        return .{
            .dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{}),
            .root = try gpa.dupe(u8, buf[0..real_len]),
        };
    }

    fn deinit(self: *Scratch) void {
        self.dir.close(io);
        // The dir was created by this struct at a path this struct
        // owns, so removing it is bounded — no `isSafeTmp` gate needed
        // (that gate exists for paths derived from ambient state).
        std.Io.Dir.cwd().deleteTree(io, self.root) catch {};
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

/// Run `git` with the fixture identity baked in, in `cwd`, returning its
/// trimmed stdout (`check=True` in the Python `_git`).
fn gitOut(cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        "git", "-C", cwd,
        "-c", "user.email=t@t",
        "-c", "user.name=t",
        // A machine-wide `commit.gpgsign=true` would make every
        // fixture commit fail for a reason that has nothing to do with
        // the code under test.
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
    return gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

/// `git init --initial-branch=main --quiet <path>` — the Python fixture
/// ran this as a bare `subprocess.run` before the `_git` helper existed.
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

/// Build the `sidebar-branch-proj` fixture inside `s`: a real git repo
/// on `worktree/sidebar-badge-test` (NOT the harness HOME — the Python
/// fixture comment says so explicitly).
fn buildBranchRepo(s: *Scratch) ![]u8 {
    const cwd = try s.path(&.{"sidebar-branch-proj"});
    errdefer gpa.free(cwd);

    try std.Io.Dir.cwd().createDirPath(io, cwd);
    try gitInit(cwd);

    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "readme.txt" });
        defer gpa.free(p);
        try writeFileAt(p, "hi\n");
    }
    _ = try gitOut(cwd, &.{ "add", "-A" });
    _ = try gitOut(cwd, &.{ "commit", "--quiet", "-m", "base" });
    _ = try gitOut(cwd, &.{ "checkout", "--quiet", "-b", BRANCH });

    // The fixture asserted the branch really landed before returning.
    const head = try gitOut(cwd, &.{ "symbolic-ref", "--short", "HEAD" });
    defer gpa.free(head);
    if (!std.mem.eql(u8, head, BRANCH)) {
        std.debug.print("fixture branch is {s}, expected {s}\n", .{ head, BRANCH });
        return error.TestUnexpectedResult;
    }

    return cwd;
}

/// `POST /api/llm/session` with a caller-chosen id, then poll until the
/// session is readable.
fn createSession(h: *Harness, session_id: []const u8, name: []const u8, cwd: []const u8) !void {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .session_id = session_id,
        .session_name = name,
        .cwd_session = cwd,
    }, .{});
    defer gpa.free(body);

    var create = try h.http(io, .POST, "/api/llm/session", .{
        .json_body = body,
        .expect = &.{201},
    });
    defer create.deinit();

    var doc = try create.json();
    defer doc.deinit();
    const echoed = doc.str("id") orelse {
        std.debug.print("session create returned no id: {s}\n", .{create.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, echoed, session_id)) {
        std.debug.print("create echoed {s}, expected {s}: {s}\n", .{ echoed, session_id, create.body });
        return error.TestUnexpectedResult;
    }

    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);

    const deadline = nowMs() + 5_000;
    while (nowMs() < deadline) {
        var r = try h.http(io, .GET, path, .{ .expect = &.{ 200, 404 } });
        defer r.deinit();
        if (r.status == 200) return;
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }
    std.debug.print("session {s} did not appear within 5s\n", .{session_id});
    return error.TestUnexpectedResult;
}

/// Monotonic milliseconds (`.awake`, not `.real`).
fn nowMs() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// `GET /api/llm/session?limit=50` → the row for `session_id`. Python's
/// `_list_sessions` asserted the list shape, then both tests did `next(s for
/// s in body["sessions"] if s["session_id"] == sid)`.
fn sessionRow(h: *Harness, session_id: []const u8) !harness.Json {
    var r = try h.http(io, .GET, "/api/llm/session", .{
        .params = &.{.{ .name = "limit", .value = "50" }},
        .expect = &.{200},
    });
    defer r.deinit();

    var doc = try r.json();
    errdefer doc.deinit();

    const rows = doc.array("sessions") orelse {
        std.debug.print("bad list shape, no `sessions` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    for (rows.items) |row| {
        const o = switch (row) {
            .object => |o| o,
            else => continue,
        };
        const id = switch (o.get("session_id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, id, session_id)) return doc;
    }

    std.debug.print("session {s} not in list response: {s}\n", .{ session_id, r.body });
    return error.TestUnexpectedResult;
}

/// The string field `key` on the session-list row `session_id`, or an
/// empty slice when the key is absent.
fn rowStr(row: harness.Json, session_id: []const u8, key: []const u8) []const u8 {
    const rows = row.array("sessions") orelse return "";
    for (rows.items) |r| {
        const o = switch (r) {
            .object => |o| o,
            else => continue,
        };
        const id = switch (o.get("session_id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, id, session_id)) continue;
        return switch (o.get(key) orelse return "") {
            .string => |s| s,
            else => "",
        };
    }
    return "";
}

// Session whose cwd is a git checkout exposes its branch on the wire.
test "session_list_carries_git_branch_for_git_cwd" {
    try harness.requirePabrikBin(io, gpa);

    var scratch = try Scratch.init();
    defer scratch.deinit();
    const branch_repo = try buildBranchRepo(&scratch);
    defer gpa.free(branch_repo);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "sess_test_sidebar_branch_0000000000000001";
    try createSession(&h, session_id, "branched chat", branch_repo);

    var row = try sessionRow(&h, session_id);
    defer row.deinit();

    const got_branch = rowStr(row, session_id, "git_branch");
    if (!std.mem.eql(u8, got_branch, BRANCH)) {
        std.debug.print("git_branch is '{s}', expected '{s}'\n", .{ got_branch, BRANCH });
        return error.TestUnexpectedResult;
    }

    const got_worktree = rowStr(row, session_id, "git_worktree_cwd");
    if (!std.mem.eql(u8, got_worktree, "")) {
        std.debug.print("unbound worktree must be '', got '{s}'\n", .{got_worktree});
        return error.TestUnexpectedResult;
    }

    const got_cwd = rowStr(row, session_id, "cwd");
    if (!std.mem.eql(u8, got_cwd, branch_repo)) {
        std.debug.print("cwd must round-trip: got '{s}', expected '{s}'\n", .{ got_cwd, branch_repo });
        return error.TestUnexpectedResult;
    }
}

// Non-repo cwd resolves to empty branch (badge omitted, keys present).
test "session_list_empty_branch_for_non_git_cwd" {
    try harness.requirePabrikBin(io, gpa);

    var scratch = try Scratch.init();
    defer scratch.deinit();
    const plain = try scratch.path(&.{"not-a-repo"});
    defer gpa.free(plain);
    try std.Io.Dir.cwd().createDirPath(io, plain);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "sess_test_sidebar_branch_0000000000000002";
    try createSession(&h, session_id, "plain chat", plain);

    var row = try sessionRow(&h, session_id);
    defer row.deinit();

    const got_branch = rowStr(row, session_id, "git_branch");
    if (!std.mem.eql(u8, got_branch, "")) {
        std.debug.print("non-repo must be '', got '{s}'\n", .{got_branch});
        return error.TestUnexpectedResult;
    }

    const got_worktree = rowStr(row, session_id, "git_worktree_cwd");
    if (!std.mem.eql(u8, got_worktree, "")) {
        std.debug.print("unbound worktree must be '', got '{s}'\n", .{got_worktree});
        return error.TestUnexpectedResult;
    }
}
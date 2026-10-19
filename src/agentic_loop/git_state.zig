//! Live git facts for a working directory: worktree root, repository root,
//! branch, head and dirty files. Used by the compaction envelope so the next
//! agent knows which checkout it is in without paying for an LLM summary.

const std = @import("std");
const builtin = @import("builtin");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const run_captured = @import("helpers").run_captured;
const host_fixture = @import("helpers").host_fixture;
const xml_escape = @import("helpers").xml_escape;
const git_hardening = @import("helpers").git_hardening;
const workspace_fs = @import("workspace_fs.zig");
const runtime_mode = @import("../runtime_mode.zig");

pub const MAX_DIRTY_FILES: usize = 20;
pub const DETACHED_BRANCH = "(detached)";

const GIT_TIMEOUT_MS: u32 = 5_000;
const MAX_GIT_OUTPUT_BYTES: usize = 256 * 1024;

const TOPLEVEL_ARGS = [_][]const u8{ "rev-parse", "--show-toplevel" };
const BRANCH_ARGS = [_][]const u8{ "branch", "--show-current" };
const HEAD_ARGS = [_][]const u8{ "rev-parse", "--short", "HEAD" };
const STATUS_ARGS = [_][]const u8{ "status", "--porcelain" };
const COMMON_DIR_ARGS = [_][]const u8{ "rev-parse", "--path-format=absolute", "--git-common-dir" };

pub const DirtyFile = struct {
    status: []const u8,
    path: []const u8,
};

pub const GitState = struct {
    worktree_root: []const u8,
    repo_root: []const u8,
    branch: []const u8,
    head: []const u8,
    dirty_files: []DirtyFile,
    dirty_total: usize,
    is_linked_worktree: bool,

    pub fn deinit(self: GitState, allocator: std.mem.Allocator) void {
        allocator.free(self.worktree_root);
        allocator.free(self.repo_root);
        allocator.free(self.branch);
        allocator.free(self.head);
        for (self.dirty_files) |f| {
            allocator.free(f.status);
            allocator.free(f.path);
        }
        allocator.free(self.dirty_files);
    }
};

/// One `git` invocation in `dir`, trimmed stdout or null on any failure. Tests
/// substitute a fake so none of them needs a repository or a git binary.
pub const GitRunner = *const fn (std.mem.Allocator, std.Io, []const u8, []const []const u8) ?[]u8;

pub fn runGit(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, args: []const []const u8) ?[]u8 {
    if (dir.len == 0) return null;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    git_hardening.appendGit(&argv, allocator) catch return null;
    argv.append(allocator, "-C") catch return null;
    argv.append(allocator, dir) catch return null;
    argv.appendSlice(allocator, args) catch return null;

    var result = run_captured.run(allocator, io, argv.items, .{
        .max_output_bytes = MAX_GIT_OUTPUT_BYTES,
        .timeout_ms = GIT_TIMEOUT_MS,
    }) catch return null;
    defer result.deinit(allocator);
    if (result.timed_out) return null;

    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => return null,
    };
    if (code != 0) return null;

    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n")) catch null;
}

/// One `git` invocation for the tree at `dir`, from whichever side of the seam
/// this run is on: the guest's git over the exec RPC, the host's, or a test's
/// fake. Every question this module asks goes through one of these.
const Ask = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    guest: ?*const workspace_fs.Fs = null,
    fake: ?GitRunner = null,

    fn of(self: Ask, dir: []const u8, args: []const []const u8) ?[]u8 {
        if (self.fake) |fake| return fake(self.allocator, self.io, dir, args);
        if (self.guest) |fs| return guestRunGit(self.allocator, fs, dir, args);
        return runGit(self.allocator, self.io, dir, args);
    }
};

/// The guest's answer in the host runner's own shape: trimmed stdout, or null
/// on any failure — a git that could not be asked is not a git that said no.
fn guestRunGit(
    allocator: std.mem.Allocator,
    fs: *const workspace_fs.Fs,
    dir: []const u8,
    args: []const []const u8,
) ?[]u8 {
    const exec = fs.runGit(dir, args, GIT_TIMEOUT_MS, MAX_GIT_OUTPUT_BYTES) catch return null;
    defer exec.deinit(allocator);
    if (exec.timed_out or exec.truncated) return null;
    if (exec.code != 0) return null;
    return allocator.dupe(u8, std.mem.trim(u8, exec.stdout, " \t\r\n")) catch null;
}

/// Git facts for `dir`, or null when `dir` is not inside a repository.
pub fn fetchGitState(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !?GitState {
    return fetchGitStateWith(allocator, io, dir, runGit);
}

/// Git facts for a session's directory. Under `--saas` the questions go to the
/// workspace's VM, and a workspace whose VM cannot answer is an error — the
/// host's git is never spawned on a tenant tree (criterion 9).
pub fn fetchGitStateFor(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    dir: []const u8,
) !?GitState {
    var route = workspace_fs.routeForSession(allocator, db, session_id);
    defer route.deinit();
    const guest: ?*const workspace_fs.Fs = switch (route) {
        .guest => |*fs| fs,
        // No VM to ask: the ask fails, and the caller's log says why. The
        // host's git is emphatically not the fallback.
        .unavailable => |err| return err,
        .host => null,
    };
    return fetchGitStateAsk(allocator, dir, .{ .allocator = allocator, .io = io, .guest = guest });
}

pub fn fetchGitStateWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    runner: GitRunner,
) !?GitState {
    return fetchGitStateAsk(allocator, dir, .{ .allocator = allocator, .io = io, .fake = runner });
}

fn fetchGitStateAsk(
    allocator: std.mem.Allocator,
    dir: []const u8,
    ask: Ask,
) !?GitState {
    const toplevel_raw = ask.of(dir, &TOPLEVEL_ARGS) orelse return null;
    defer allocator.free(toplevel_raw);
    if (toplevel_raw.len == 0) return null;

    const common_raw = ask.of(dir, &COMMON_DIR_ARGS);
    defer if (common_raw) |c| allocator.free(c);
    const repo_root_raw: []const u8 = if (common_raw) |c| std.fs.path.dirname(c) orelse toplevel_raw else toplevel_raw;

    const head_raw = ask.of(dir, &HEAD_ARGS);
    defer if (head_raw) |h| allocator.free(h);

    const worktree_root = try allocator.dupe(u8, toplevel_raw);
    errdefer allocator.free(worktree_root);
    const repo_root = try allocator.dupe(u8, repo_root_raw);
    errdefer allocator.free(repo_root);
    const branch = try fetchBranch(allocator, dir, ask);
    errdefer allocator.free(branch);
    const head = try allocator.dupe(u8, head_raw orelse "");
    errdefer allocator.free(head);
    const dirty = try fetchDirtyFiles(allocator, dir, ask);
    errdefer {
        for (dirty.files) |f| {
            allocator.free(f.status);
            allocator.free(f.path);
        }
        allocator.free(dirty.files);
    }

    return .{
        .worktree_root = worktree_root,
        .repo_root = repo_root,
        .branch = branch,
        .head = head,
        .dirty_files = dirty.files,
        .dirty_total = dirty.total,
        .is_linked_worktree = !std.mem.eql(u8, worktree_root, repo_root),
    };
}

fn fetchBranch(
    allocator: std.mem.Allocator,
    dir: []const u8,
    ask: Ask,
) ![]u8 {
    const raw = ask.of(dir, &BRANCH_ARGS);
    defer if (raw) |r| allocator.free(r);
    const branch = raw orelse "";
    if (branch.len > 0) return allocator.dupe(u8, branch);
    return allocator.dupe(u8, DETACHED_BRANCH);
}

const DirtyResult = struct {
    files: []DirtyFile,
    total: usize,
};

fn fetchDirtyFiles(
    allocator: std.mem.Allocator,
    dir: []const u8,
    ask: Ask,
) !DirtyResult {
    const raw = ask.of(dir, &STATUS_ARGS);
    defer if (raw) |r| allocator.free(r);

    var files: std.ArrayList(DirtyFile) = .empty;
    errdefer {
        for (files.items) |f| {
            allocator.free(f.status);
            allocator.free(f.path);
        }
        files.deinit(allocator);
    }

    var total: usize = 0;
    if (raw) |status| {
        var lines = std.mem.splitScalar(u8, status, '\n');
        while (lines.next()) |line| {
            if (line.len < 3) continue;
            total += 1;
            if (files.items.len >= MAX_DIRTY_FILES) continue;
            const path = std.mem.trim(u8, line[3..], " \t\r");
            if (path.len == 0) continue;
            const code = std.mem.trim(u8, line[0..2], " \t\r");
            try files.append(allocator, .{
                .status = try allocator.dupe(u8, code),
                .path = try allocator.dupe(u8, path),
            });
        }
    }

    return .{ .files = try files.toOwnedSlice(allocator), .total = total };
}

/// Write the `<working_directory>` section. The session's own cwd and the
/// bound worktree are named separately: the worktree is where the file and
/// command tools actually run, and the two differ for every isolated session.
pub fn appendWorkingDirectoryXml(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    session_cwd: []const u8,
    git_worktree_cwd: []const u8,
    state: ?GitState,
) !void {
    const active_dir = if (git_worktree_cwd.len > 0) git_worktree_cwd else session_cwd;

    try out.appendSlice(allocator, "  <working_directory>\n");
    try appendTextElement(allocator, out, "   ", "active_dir", active_dir);
    try appendTextElement(allocator, out, "   ", "session_cwd", session_cwd);
    try appendTextElement(allocator, out, "   ", "git_worktree_cwd", git_worktree_cwd);

    if (state) |s| {
        try appendTextElement(allocator, out, "   ", "worktree_root", s.worktree_root);
        try appendTextElement(allocator, out, "   ", "repo_root", s.repo_root);
        try out.print(allocator, "    <is_linked_worktree>{s}</is_linked_worktree>\n", .{if (s.is_linked_worktree) "true" else "false"});
        try appendTextElement(allocator, out, "   ", "branch", s.branch);
        try appendTextElement(allocator, out, "   ", "head", s.head);
        try out.print(allocator, "    <dirty_files count=\"{d}\" total=\"{d}\">\n", .{ s.dirty_files.len, s.dirty_total });
        for (s.dirty_files) |f| {
            const path_escaped = try xml_escape(allocator, f.path);
            defer allocator.free(path_escaped);
            const status_escaped = try xml_escape(allocator, f.status);
            defer allocator.free(status_escaped);
            try out.print(allocator, "      <file status=\"{s}\">{s}</file>\n", .{ status_escaped, path_escaped });
        }
        try out.appendSlice(allocator, "    </dirty_files>\n");
    } else {
        try out.appendSlice(allocator, "    <is_git_repo>false</is_git_repo>\n");
    }

    try out.appendSlice(allocator, "  </working_directory>\n");
}

fn appendTextElement(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    name: []const u8,
    value: []const u8,
) !void {
    const escaped = try xml_escape(allocator, value);
    defer allocator.free(escaped);
    try out.print(allocator, "{s}<{s}>{s}</{s}>\n", .{ indent, name, escaped, name });
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const FakeGit = struct {
    toplevel: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    head: ?[]const u8 = null,
    status: ?[]const u8 = null,
    common_dir: ?[]const u8 = null,
};

var fake_git: FakeGit = .{};

fn argEq(args: []const []const u8, expected: []const []const u8) bool {
    if (args.len != expected.len) return false;
    for (args, expected) |a, e| {
        if (!std.mem.eql(u8, a, e)) return false;
    }
    return true;
}

fn fakeGitRunner(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, args: []const []const u8) ?[]u8 {
    _ = io;
    _ = dir;
    const canned: ?[]const u8 = blk: {
        if (argEq(args, &TOPLEVEL_ARGS)) break :blk fake_git.toplevel;
        if (argEq(args, &BRANCH_ARGS)) break :blk fake_git.branch;
        if (argEq(args, &HEAD_ARGS)) break :blk fake_git.head;
        if (argEq(args, &STATUS_ARGS)) break :blk fake_git.status;
        if (argEq(args, &COMMON_DIR_ARGS)) break :blk fake_git.common_dir;
        break :blk null;
    };
    const value = canned orelse return null;
    return allocator.dupe(u8, value) catch null;
}

fn fetchWithFake(dir: []const u8) !?GitState {
    return fetchGitStateWith(std.testing.allocator, std.testing.io, dir, fakeGitRunner);
}

test "fetchGitStateWith returns null when the directory is not a git repository" {
    fake_git = .{ .toplevel = null };
    const state = try fetchWithFake("/not/a/repo");
    try std.testing.expect(state == null);
}

test "fetchGitStateWith reports a linked worktree and the checkout it belongs to as distinct roots" {
    fake_git = .{
        .toplevel = "/repo/.worktrees/fix-login",
        .common_dir = "/repo/.git",
        .branch = "worktree/fix-login",
        .head = "abc1234",
    };
    const state = (try fetchWithFake("/repo/.worktrees/fix-login")).?;
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(state.is_linked_worktree);
    try std.testing.expectEqualStrings("/repo/.worktrees/fix-login", state.worktree_root);
    try std.testing.expectEqualStrings("/repo", state.repo_root);
}

test "fetchGitStateWith reports the checkout's own root as repository root when it is not a linked worktree" {
    fake_git = .{
        .toplevel = "/repo",
        .common_dir = "/repo/.git",
        .branch = "main",
        .head = "7716508",
    };
    const state = (try fetchWithFake("/repo")).?;
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(!state.is_linked_worktree);
    try std.testing.expectEqualStrings("/repo", state.worktree_root);
    try std.testing.expectEqualStrings("/repo", state.repo_root);
}

test "fetchGitStateWith reports the branch and short head" {
    fake_git = .{
        .toplevel = "/repo",
        .common_dir = "/repo/.git",
        .branch = "feat/compaction",
        .head = "1a2b3c4",
    };
    const state = (try fetchWithFake("/repo")).?;
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("feat/compaction", state.branch);
    try std.testing.expectEqualStrings("1a2b3c4", state.head);
}

test "fetchGitStateWith marks a detached head when git reports no branch name" {
    fake_git = .{
        .toplevel = "/repo",
        .common_dir = "/repo/.git",
        .branch = "",
        .head = "deadbee",
    };
    const state = (try fetchWithFake("/repo")).?;
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(DETACHED_BRANCH, state.branch);
}

test "fetchGitStateWith parses porcelain status into a worktree code and a path" {
    fake_git = .{
        .toplevel = "/repo",
        .common_dir = "/repo/.git",
        .status = " M src/agentic_loop/workflow.zig\n?? src/new.zig\nA  staged.zig\n",
    };
    const state = (try fetchWithFake("/repo")).?;
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), state.dirty_files.len);
    try std.testing.expectEqualStrings("M", state.dirty_files[0].status);
    try std.testing.expectEqualStrings("src/agentic_loop/workflow.zig", state.dirty_files[0].path);
    try std.testing.expectEqualStrings("??", state.dirty_files[1].status);
    try std.testing.expectEqualStrings("src/new.zig", state.dirty_files[1].path);
    try std.testing.expectEqualStrings("A", state.dirty_files[2].status);
    try std.testing.expectEqualStrings("staged.zig", state.dirty_files[2].path);
}

test "fetchGitStateWith reports a clean tree as no dirty files" {
    fake_git = .{ .toplevel = "/repo", .common_dir = "/repo/.git", .status = "" };
    const state = (try fetchWithFake("/repo")).?;
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), state.dirty_files.len);
    try std.testing.expectEqual(@as(usize, 0), state.dirty_total);
}

test "fetchGitStateWith caps the listed dirty files and still counts every one" {
    const alloc = std.testing.allocator;
    var status: std.ArrayList(u8) = .empty;
    defer status.deinit(alloc);
    for (0..MAX_DIRTY_FILES + 7) |_| {
        try status.appendSlice(alloc, " M file.zig\n");
    }
    fake_git = .{
        .toplevel = "/repo",
        .common_dir = "/repo/.git",
        .status = status.items,
    };
    const state = (try fetchWithFake("/repo")).?;
    defer state.deinit(alloc);

    try std.testing.expectEqual(MAX_DIRTY_FILES, state.dirty_files.len);
    try std.testing.expectEqual(MAX_DIRTY_FILES + 7, state.dirty_total);
}

test "appendWorkingDirectoryXml names the session cwd and the bound worktree separately" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    fake_git = .{
        .toplevel = "/repo/.worktrees/fix-login",
        .common_dir = "/repo/.git",
        .branch = "worktree/fix-login",
        .head = "abc1234",
        .status = " M src/a.zig\n",
    };
    const state = (try fetchWithFake("/repo/.worktrees/fix-login")).?;
    defer state.deinit(alloc);

    try appendWorkingDirectoryXml(
        alloc,
        &out,
        "/repo",
        "/repo/.worktrees/fix-login",
        state,
    );

    const xml = out.items;
    try std.testing.expect(std.mem.indexOf(u8, xml, "<session_cwd>/repo</session_cwd>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<git_worktree_cwd>/repo/.worktrees/fix-login</git_worktree_cwd>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<active_dir>/repo/.worktrees/fix-login</active_dir>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<repo_root>/repo</repo_root>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<is_linked_worktree>true</is_linked_worktree>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<branch>worktree/fix-login</branch>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<file status=\"M\">src/a.zig</file>") != null);
}

test "appendWorkingDirectoryXml falls back to the session cwd when no worktree is bound" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try appendWorkingDirectoryXml(alloc, &out, "/repo", "", null);

    const xml = out.items;
    try std.testing.expect(std.mem.indexOf(u8, xml, "<active_dir>/repo</active_dir>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<git_worktree_cwd></git_worktree_cwd>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<is_git_repo>false</is_git_repo>") != null);
}

test "appendWorkingDirectoryXml escapes xml specials in a branch name" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    fake_git = .{
        .toplevel = "/repo",
        .common_dir = "/repo/.git",
        .branch = "feat<a>&b",
        .head = "abc1234",
    };
    const state = (try fetchWithFake("/repo")).?;
    defer state.deinit(alloc);

    try appendWorkingDirectoryXml(alloc, &out, "/repo", "", state);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "<branch>feat&lt;a&gt;&amp;b</branch>") != null);
}

// ─── Criterion 9: a tenant tree's git is the GUEST's ───────────────────────

/// A throwaway repository whose `core.fsmonitor` runs a fixture program that
/// creates a sentinel file. Anything on this host that runs `git status` in it
/// makes the file appear — the fsmonitor RCE, as a test.
const CanaryRepo = struct {
    fx: host_fixture.Fixture,
    repo: []u8,
    sentinel: []u8,
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,

    fn deinit(self: *CanaryRepo) void {
        self.threaded.deinit();
        self.db.deinit();
        self.fx.allocator.free(self.sentinel);
        self.fx.allocator.free(self.repo);
        self.fx.deinit();
    }

    fn fired(self: *const CanaryRepo) bool {
        std.Io.Dir.cwd().access(std.testing.io, self.sentinel, .{}) catch return false;
        return true;
    }

    /// `git status` under the hardening the seam's own prefix applies.
    fn statusHardened(self: *const CanaryRepo) !void {
        const off = git_hardening.configValue("core.fsmonitor").?;
        const setting = try std.fmt.allocPrint(std.testing.allocator, "core.fsmonitor={s}", .{off});
        defer std.testing.allocator.free(setting);
        try runGitOrFail(std.testing.allocator, &.{ "git", "-c", setting, "-C", self.repo, "status", "--porcelain" });
    }

    /// `git status` the way a tenant's own tooling would run it: no prefix.
    fn statusPlain(self: *const CanaryRepo) !void {
        try runGitOrFail(std.testing.allocator, &.{ "git", "-C", self.repo, "status", "--porcelain" });
    }
};

fn runGitOrFail(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var r = run_captured.run(allocator, std.testing.io, argv, .{ .timeout_ms = 30_000 }) catch
        return error.GitUnavailable;
    defer r.deinit(allocator);
    if (r.term.exited != 0) return error.GitUnavailable;
}

/// The canary repository, registered as workspace `w1` / session `s1`, so the
/// seam resolves it exactly as it would a real tenant's checkout.
fn canaryRepo() !CanaryRepo {
    const allocator = std.testing.allocator;
    var fx = try host_fixture.Fixture.init(allocator);
    errdefer fx.deinit();
    const repo = try fx.subDir("repo");
    errdefer allocator.free(repo);
    const sentinel = try std.fmt.allocPrint(allocator, "{s}/SENTINEL", .{fx.root});
    errdefer allocator.free(sentinel);
    const canary = try fx.writeProgram("fsmonitor", .{ .touch_file = sentinel });
    defer allocator.free(canary);

    try runGitOrFail(allocator, &.{ "git", "init", "-q", repo });
    try runGitOrFail(allocator, &.{ "git", "-C", repo, "config", "core.fsmonitor", canary });

    var threaded = std.Io.Threaded.init(allocator, .{});
    errdefer threaded.deinit();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try db.exec(allocator,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT, cwd TEXT, workspace_id TEXT)
    , &.{});
    try db.exec(allocator,
        \\CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER)
    , &.{});
    try db.exec(allocator,
        \\CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL)
    , &.{});
    const item = try std.fmt.allocPrint(allocator,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('i1','w1','kanban','A','{s}',1)
    , .{repo});
    defer allocator.free(item);
    try db.exec(allocator, item, &.{});
    try db.exec(allocator, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('s1','T1','i1')", &.{});
    const sess = try std.fmt.allocPrint(allocator,
        \\INSERT INTO sessions (id, name, status, cwd) VALUES ('s1','T1','active','{s}')
    , .{repo});
    defer allocator.free(sess);
    try db.exec(allocator, sess, &.{});

    return .{ .fx = fx, .repo = repo, .sentinel = sentinel, .db = db, .threaded = threaded };
}

test "fetchGitStateFor: local mode asks the host's git, and the hardening keeps the hook out" {
    var canary = try canaryRepo();
    defer canary.deinit();
    const allocator = std.testing.allocator;

    // The prefix the seam's own git argv carries is what neutralises the repo.
    try canary.statusHardened();
    try std.testing.expect(!canary.fired());

    try std.testing.expectEqual(runtime_mode.Mode.local, runtime_mode.currentMode());
    const state = (try fetchGitStateFor(allocator, std.testing.io, &canary.db, "s1", canary.repo)).?;
    defer state.deinit(allocator);
    try std.testing.expect(std.mem.endsWith(u8, state.worktree_root, "repo"));
    try std.testing.expect(!canary.fired());

    // The control that makes those absences mean something: WITHOUT the
    // prefix this host really does execute the repository's own command.
    if (builtin.os.tag != .windows) {
        try canary.statusPlain();
        try std.testing.expect(canary.fired());
    }
}

test "fetchGitStateFor: saas never spawns the host's git — the canary stays silent" {
    var canary = try canaryRepo();
    defer canary.deinit();
    const allocator = std.testing.allocator;

    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    if (!runtime_mode.vm_backend_available) return;
    runtime_mode.setManagerSocket(null);
    defer runtime_mode.setManagerSocket(null);

    // The tree is right there and the canary WOULD fire; the workspace's VM is
    // not answering, and the ask fails closed rather than falling back.
    try std.testing.expectError(
        workspace_fs.Error.GuestManagerUnavailable,
        fetchGitStateFor(allocator, std.testing.io, &canary.db, "s1", canary.repo),
    );
    try std.testing.expect(!canary.fired());
}

test "fetchGitStateFor: saas answers nothing outside the workspace, and runs nothing" {
    var canary = try canaryRepo();
    defer canary.deinit();
    const allocator = std.testing.allocator;

    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    if (!runtime_mode.vm_backend_available) return;
    runtime_mode.setManagerSocket("/nonexistent/pabrik-vmd.sock");
    defer runtime_mode.setManagerSocket(null);

    // A worktree the host keeps OUTSIDE the tenant's root (a session's own
    // worktree lives there). It has no guest path, so there is no question to
    // ask — and the host's git is still not the fallback.
    const outside = (try fetchGitStateFor(allocator, std.testing.io, &canary.db, "s1", canary.fx.root));
    try std.testing.expect(outside == null);
    try std.testing.expect(!canary.fired());
}

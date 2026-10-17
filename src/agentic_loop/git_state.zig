//! Live git facts for a working directory: worktree root, repository root,
//! branch, head and dirty files. Used by the compaction envelope so the next
//! agent knows which checkout it is in without paying for an LLM summary.

const std = @import("std");
const run_captured = @import("helpers").run_captured;
const xml_escape = @import("helpers").xml_escape;
const git_hardening = @import("helpers").git_hardening;

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

/// Git facts for `dir`, or null when `dir` is not inside a repository.
pub fn fetchGitState(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !?GitState {
    return fetchGitStateWith(allocator, io, dir, runGit);
}

pub fn fetchGitStateWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    runner: GitRunner,
) !?GitState {
    const toplevel_raw = runner(allocator, io, dir, &TOPLEVEL_ARGS) orelse return null;
    defer allocator.free(toplevel_raw);
    if (toplevel_raw.len == 0) return null;

    const common_raw = runner(allocator, io, dir, &COMMON_DIR_ARGS);
    defer if (common_raw) |c| allocator.free(c);
    const repo_root_raw: []const u8 = if (common_raw) |c| std.fs.path.dirname(c) orelse toplevel_raw else toplevel_raw;

    const head_raw = runner(allocator, io, dir, &HEAD_ARGS);
    defer if (head_raw) |h| allocator.free(h);

    const worktree_root = try allocator.dupe(u8, toplevel_raw);
    errdefer allocator.free(worktree_root);
    const repo_root = try allocator.dupe(u8, repo_root_raw);
    errdefer allocator.free(repo_root);
    const branch = try fetchBranch(allocator, io, dir, runner);
    errdefer allocator.free(branch);
    const head = try allocator.dupe(u8, head_raw orelse "");
    errdefer allocator.free(head);
    const dirty = try fetchDirtyFiles(allocator, io, dir, runner);
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
    io: std.Io,
    dir: []const u8,
    runner: GitRunner,
) ![]u8 {
    const raw = runner(allocator, io, dir, &BRANCH_ARGS);
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
    io: std.Io,
    dir: []const u8,
    runner: GitRunner,
) !DirtyResult {
    const raw = runner(allocator, io, dir, &STATUS_ARGS);
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

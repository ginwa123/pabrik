//! The current branch of a directory, read off disk. Answers the same question
//! as `git -C <dir> symbolic-ref --short HEAD` without spawning a process.

const std = @import("std");

pub const max_ancestor_depth: usize = 32;

const max_head_bytes = 4096;
const git_entry_name = ".git";
const head_name = "HEAD";
const head_ref_prefix = "ref: ";
const head_branch_prefix = "refs/heads/";
const gitdir_prefix = "gitdir:";

const DirProbe = union(enum) {
    branch: []u8,
    no_branch,
    not_a_repo,
};

/// Branch `dir` is checked out on, or null when it has none — detached HEAD,
/// not a repository, or a relative path. Caller owns a non-null result.
pub fn resolve(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) ?[]u8 {
    if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) return null;

    var head_buf: [max_head_bytes]u8 = undefined;
    var path: []const u8 = dir;
    var depth: usize = 0;
    while (depth <= max_ancestor_depth) : (depth += 1) {
        switch (probeDir(allocator, io, path, &head_buf)) {
            .branch => |branch| return branch,
            .no_branch => return null,
            .not_a_repo => {},
        }
        const parent = std.fs.path.dirname(path) orelse return null;
        if (parent.len >= path.len) return null;
        path = parent;
    }
    return null;
}

fn probeDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    head_buf: *[max_head_bytes]u8,
) DirProbe {
    var git_entry_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const git_entry = childPath(&git_entry_buf, dir, git_entry_name) orelse return .not_a_repo;

    var head_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (childPath(&head_path_buf, git_entry, head_name)) |head_path| {
        if (readSmall(io, head_path, head_buf)) |content| {
            const branch = branchFromHead(allocator, content) orelse return .no_branch;
            return .{ .branch = branch };
        }
    }

    const entry = readSmall(io, git_entry, head_buf) orelse return .not_a_repo;
    const git_dir = gitDirFromEntry(allocator, dir, entry) orelse return .no_branch;
    defer allocator.free(git_dir);

    if (childPath(&head_path_buf, git_dir, head_name)) |head_path| {
        const content = readSmall(io, head_path, head_buf) orelse return .no_branch;
        const branch = branchFromHead(allocator, content) orelse return .no_branch;
        return .{ .branch = branch };
    }
    return .no_branch;
}

/// One separator, never two: a Windows `\\?\` path is rejected outright when a
/// component is empty, and a drive root already ends with the separator.
fn childPath(buf: []u8, parent: []const u8, name: []const u8) ?[]const u8 {
    if (parent.len > 0 and parent[parent.len - 1] == std.fs.path.sep) {
        return std.fmt.bufPrint(buf, "{s}{s}", .{ parent, name }) catch null;
    }
    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ parent, std.fs.path.sep, name }) catch null;
}

fn readSmall(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const len = file.readPositionalAll(io, buf, 0) catch return null;
    return buf[0..len];
}

/// `.git` as a file points at the real git dir of a linked worktree or a
/// submodule; a relative target resolves against the directory holding it.
fn gitDirFromEntry(allocator: std.mem.Allocator, dir: []const u8, entry: []const u8) ?[]u8 {
    const line = std.mem.trim(u8, entry, " \t\r\n");
    if (!std.mem.startsWith(u8, line, gitdir_prefix)) return null;
    const target = std.mem.trim(u8, line[gitdir_prefix.len..], " \t\r\n");
    if (target.len == 0) return null;
    if (std.fs.path.isAbsolute(target)) return allocator.dupe(u8, target) catch null;
    return std.fs.path.resolve(allocator, &.{ dir, target }) catch null;
}

fn branchFromHead(allocator: std.mem.Allocator, content: []const u8) ?[]u8 {
    const line = std.mem.trim(u8, content, " \t\r\n");
    if (!std.mem.startsWith(u8, line, head_ref_prefix)) return null;
    const ref = std.mem.trim(u8, line[head_ref_prefix.len..], " \t\r\n");
    if (!std.mem.startsWith(u8, ref, head_branch_prefix)) return null;
    const name = ref[head_branch_prefix.len..];
    if (name.len == 0) return null;
    return allocator.dupe(u8, name) catch null;
}

/// Per-request memo: a page repeats a handful of directories across dozens of
/// rows, so each distinct one is read once. Nothing outlives the request — a
/// `git checkout` shows up on the next list load.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        dir: []const u8,
        branch: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Cache {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.dir);
            if (entry.branch.len > 0) self.allocator.free(entry.branch);
        }
        self.entries.deinit(self.allocator);
    }

    /// Number of directories this cache has read from disk.
    pub fn lookups(self: *const Cache) usize {
        return self.entries.items.len;
    }

    /// Branch of `dir`, borrowed from the cache and valid until `deinit`.
    /// "" when the directory is on no branch.
    pub fn branch(self: *Cache, dir: []const u8) []const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.dir, dir)) return entry.branch;
        }
        const resolved: []const u8 = resolve(self.allocator, self.io, dir) orelse "";
        const dir_copy = self.allocator.dupe(u8, dir) catch {
            if (resolved.len > 0) self.allocator.free(resolved);
            return "";
        };
        self.entries.append(self.allocator, .{ .dir = dir_copy, .branch = resolved }) catch {
            self.allocator.free(dir_copy);
            if (resolved.len > 0) self.allocator.free(resolved);
            return "";
        };
        return resolved;
    }
};

// ===================================================================== Tests

const testing = std.testing;

const Sandbox = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,

    fn init(allocator: std.mem.Allocator) !Sandbox {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &buf);
        return .{ .tmp = tmp, .root = try allocator.dupe(u8, buf[0..len]) };
    }

    fn deinit(self: *Sandbox, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn write(self: *Sandbox, sub_path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |parent| try self.tmp.dir.createDirPath(testing.io, parent);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn at(self: *Sandbox, allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.root, sub_path });
    }
};

test "a checkout's branch is the ref its HEAD names" {
    const allocator = testing.allocator;
    var sandbox = try Sandbox.init(allocator);
    defer sandbox.deinit(allocator);

    try sandbox.write(".git/HEAD", "ref: refs/heads/main\n");

    const branch = resolve(allocator, testing.io, sandbox.root);
    defer if (branch) |b| allocator.free(b);

    try testing.expectEqualStrings("main", branch.?);
}

test "a directory below the checkout reports the checkout's branch" {
    const allocator = testing.allocator;
    var sandbox = try Sandbox.init(allocator);
    defer sandbox.deinit(allocator);

    try sandbox.write(".git/HEAD", "ref: refs/heads/feature/sidebar\n");
    try sandbox.write("src/app/deep/keep.txt", "");

    const dir = try sandbox.at(allocator, "src/app/deep");
    defer allocator.free(dir);

    const branch = resolve(allocator, testing.io, dir);
    defer if (branch) |b| allocator.free(b);

    try testing.expectEqualStrings("feature/sidebar", branch.?);
}

test "a linked worktree reports its own branch, not the main checkout's" {
    const allocator = testing.allocator;
    var sandbox = try Sandbox.init(allocator);
    defer sandbox.deinit(allocator);

    try sandbox.write("main/.git/HEAD", "ref: refs/heads/main\n");
    try sandbox.write(
        "main/.git/worktrees/wt1/HEAD",
        "ref: refs/heads/worktree/fix-sidebar\n",
    );
    try sandbox.write("wt1/.git", "gitdir: ../main/.git/worktrees/wt1\n");

    const dir = try sandbox.at(allocator, "wt1");
    defer allocator.free(dir);

    const branch = resolve(allocator, testing.io, dir);
    defer if (branch) |b| allocator.free(b);

    try testing.expectEqualStrings("worktree/fix-sidebar", branch.?);
}

test "an absolute gitdir in a worktree file is followed" {
    const allocator = testing.allocator;
    var sandbox = try Sandbox.init(allocator);
    defer sandbox.deinit(allocator);

    try sandbox.write("elsewhere/HEAD", "ref: refs/heads/pinned\n");
    const git_dir = try sandbox.at(allocator, "elsewhere");
    defer allocator.free(git_dir);
    const gitfile = try std.fmt.allocPrint(allocator, "gitdir: {s}\n", .{git_dir});
    defer allocator.free(gitfile);
    try sandbox.write("wt2/.git", gitfile);

    const dir = try sandbox.at(allocator, "wt2");
    defer allocator.free(dir);

    const branch = resolve(allocator, testing.io, dir);
    defer if (branch) |b| allocator.free(b);

    try testing.expectEqualStrings("pinned", branch.?);
}

test "a detached HEAD has no branch" {
    const allocator = testing.allocator;
    var sandbox = try Sandbox.init(allocator);
    defer sandbox.deinit(allocator);

    try sandbox.write(".git/HEAD", "3f2a1b4c5d6e7f8091a2b3c4d5e6f708192a3b4c\n");

    try testing.expect(resolve(allocator, testing.io, sandbox.root) == null);
}

test "a HEAD pointing outside refs/heads has no branch" {
    const allocator = testing.allocator;
    var sandbox = try Sandbox.init(allocator);
    defer sandbox.deinit(allocator);

    try sandbox.write(".git/HEAD", "ref: refs/tags/v1.0.0\n");

    try testing.expect(resolve(allocator, testing.io, sandbox.root) == null);
}

test "an unreadable .git stops the walk instead of borrowing an ancestor's branch" {
    const allocator = testing.allocator;
    var sandbox = try Sandbox.init(allocator);
    defer sandbox.deinit(allocator);

    try sandbox.write(".git/HEAD", "ref: refs/heads/outer\n");
    try sandbox.write("inner/.git", "not a gitdir line\n");
    try sandbox.write("inner/sub/keep.txt", "");

    const dir = try sandbox.at(allocator, "inner/sub");
    defer allocator.free(dir);

    try testing.expect(resolve(allocator, testing.io, dir) == null);
}

test "a relative or empty directory has no branch" {
    const allocator = testing.allocator;

    try testing.expect(resolve(allocator, testing.io, "") == null);
    try testing.expect(resolve(allocator, testing.io, "some/relative/path") == null);
}

test "the cache answers a repeated directory from the first lookup" {
    const allocator = testing.allocator;
    var sandbox = try Sandbox.init(allocator);
    defer sandbox.deinit(allocator);

    try sandbox.write(".git/HEAD", "ref: refs/heads/main\n");

    var cache = Cache.init(allocator, testing.io);
    defer cache.deinit();

    try testing.expectEqualStrings("main", cache.branch(sandbox.root));

    try sandbox.write(".git/HEAD", "ref: refs/heads/renamed\n");

    try testing.expectEqualStrings("main", cache.branch(sandbox.root));

    const fresh = resolve(allocator, testing.io, sandbox.root);
    defer if (fresh) |b| allocator.free(b);
    try testing.expectEqualStrings("renamed", fresh.?);
}

test "a branch switched on disk is what the next request reports" {
    const allocator = testing.allocator;
    var sandbox = try Sandbox.init(allocator);
    defer sandbox.deinit(allocator);

    try sandbox.write(".git/HEAD", "ref: refs/heads/main\n");

    const before = try freshRequestBranch(allocator, sandbox.root);
    defer allocator.free(before);

    try sandbox.write(".git/HEAD", "ref: refs/heads/feature/sidebar\n");

    const after = try freshRequestBranch(allocator, sandbox.root);
    defer allocator.free(after);

    try testing.expectEqualStrings("main", before);
    try testing.expectEqualStrings("feature/sidebar", after);
}

fn freshRequestBranch(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    var cache = Cache.init(allocator, testing.io);
    defer cache.deinit();
    return allocator.dupe(u8, cache.branch(dir));
}

test "the cache reports a directory with no branch as empty and keeps it" {
    const allocator = testing.allocator;
    var sandbox = try Sandbox.init(allocator);
    defer sandbox.deinit(allocator);

    try sandbox.write("plain/.git", "not a gitdir line\n");
    const dir = try sandbox.at(allocator, "plain");
    defer allocator.free(dir);

    var cache = Cache.init(allocator, testing.io);
    defer cache.deinit();

    try testing.expectEqualStrings("", cache.branch(dir));
    try testing.expectEqualStrings("", cache.branch(dir));
}

test "a page of twenty rows over two directories reads each directory once" {
    const allocator = testing.allocator;
    var sandbox = try Sandbox.init(allocator);
    defer sandbox.deinit(allocator);

    try sandbox.write("alpha/.git/HEAD", "ref: refs/heads/alpha\n");
    try sandbox.write("beta/.git/HEAD", "ref: refs/heads/beta\n");
    const alpha = try sandbox.at(allocator, "alpha");
    defer allocator.free(alpha);
    const beta = try sandbox.at(allocator, "beta");
    defer allocator.free(beta);

    var cache = Cache.init(allocator, testing.io);
    defer cache.deinit();

    var names: [20][]const u8 = undefined;
    for (0..20) |row| {
        names[row] = cache.branch(if (row % 2 == 0) alpha else beta);
    }

    try testing.expectEqual(@as(usize, 2), cache.lookups());
    try testing.expectEqualStrings("alpha", names[0]);
    try testing.expectEqualStrings("beta", names[1]);
    try testing.expectEqualStrings("alpha", names[18]);
}

test "the same twenty rows read one directory per row without the memo" {
    const allocator = testing.allocator;
    var sandbox = try Sandbox.init(allocator);
    defer sandbox.deinit(allocator);

    try sandbox.write("alpha/.git/HEAD", "ref: refs/heads/alpha\n");
    try sandbox.write("beta/.git/HEAD", "ref: refs/heads/beta\n");
    const alpha = try sandbox.at(allocator, "alpha");
    defer allocator.free(alpha);
    const beta = try sandbox.at(allocator, "beta");
    defer allocator.free(beta);

    var reads: usize = 0;
    for (0..20) |row| {
        var per_row = Cache.init(allocator, testing.io);
        _ = per_row.branch(if (row % 2 == 0) alpha else beta);
        reads += per_row.lookups();
        per_row.deinit();
    }

    try testing.expectEqual(@as(usize, 20), reads);
}

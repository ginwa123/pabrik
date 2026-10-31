//! Repository config can make `git` execute code: `core.fsmonitor`, hooks, and
//! `diff.external` / `diff.<driver>.textconv`. A command-line `-c` outranks every
//! config file, so the argv prefix is policy.

const std = @import("std");

/// Global options that disable the repo-controlled exec paths. Order matters
/// only in that each `-c` owns the token after it; git reads them before the
/// subcommand, so callers append these directly after the program name.
const args_tuple = .{
    "-c", "core.fsmonitor=false",
    "-c", "core.hooksPath=/dev/null",
    "-c", "core.pager=cat",
    "-c", "core.sshCommand=",
    "-c", "protocol.ext.allow=never",
};

/// Slice view, for `ArrayList.appendSlice` call sites.
pub const CONFIG_ARGS: [args_tuple.len][]const u8 = args_tuple;

/// Tuple view, for call sites that build their argv as a literal.
pub const git_prefix = .{"git"} ++ args_tuple;

pub const program = "git";

/// Per-invocation opt-outs that keep `diff`, `log` and `show` on git's own
/// engine. They cannot be `-c <key>=`: `-c diff.external=` sets the EMPTY
/// string, which git runs as a program named "" — every diff then dies.
pub const diff_no_exec = [_][]const u8{ "--no-ext-diff", "--no-textconv" };

/// Subcommands that can print a patch, and so consult those settings.
const diff_subcommands = [_][]const u8{ "diff", "log", "show", "whatchanged", "format-patch" };

/// True when `subcommand` can emit a diff.
pub fn emitsPatch(subcommand: []const u8) bool {
    for (diff_subcommands) |known| {
        if (std.mem.eql(u8, known, subcommand)) return true;
    }
    return false;
}

/// `args` plus `diff_no_exec` after the subcommand — an owned copy either way.
/// The flags are options, so they land before any later `--`; after it git
/// would read them as pathspecs.
pub fn hardenArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    if (args.len == 0 or !emitsPatch(args[0])) return try allocator.dupe([]const u8, args);
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, args[0]);
    try out.appendSlice(allocator, &diff_no_exec);
    try out.appendSlice(allocator, args[1..]);
    return try out.toOwnedSlice(allocator);
}

/// Append `git` plus the hardening options. The caller appends `-C <dir>` and
/// the subcommand, since every call site already builds those itself.
pub fn appendGit(argv: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    try argv.append(allocator, program);
    try argv.appendSlice(allocator, &CONFIG_ARGS);
}

/// Value of `-c <key>=<value>` for `key`, or null when this prefix does not
/// set it. Exposed so a caller can assert its own site is covered.
pub fn configValue(key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < CONFIG_ARGS.len) : (i += 2) {
        const pair = CONFIG_ARGS[i + 1];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

const testing = std.testing;

test "every option is a -c pair whose right-hand side neutralises a setting" {
    try testing.expect(CONFIG_ARGS.len % 2 == 0);
    var i: usize = 0;
    while (i < CONFIG_ARGS.len) : (i += 2) {
        try testing.expectEqualStrings("-c", CONFIG_ARGS[i]);
        try testing.expect(std.mem.indexOfScalar(u8, CONFIG_ARGS[i + 1], '=') != null);
        try testing.expect(std.mem.indexOfScalar(u8, CONFIG_ARGS[i + 1], ' ') == null);
    }
}

test "the prefix disables fsmonitor, hooks and sshCommand" {
    try testing.expectEqualStrings("false", configValue("core.fsmonitor").?);
    try testing.expectEqualStrings("/dev/null", configValue("core.hooksPath").?);
    try testing.expectEqualStrings("", configValue("core.sshCommand").?);
    try testing.expectEqual(@as(?[]const u8, null), configValue("difftool.prompt"));
}

test "appendGit leaves the program first and the subcommand last" {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(testing.allocator);
    try appendGit(&argv, testing.allocator);
    try argv.append(testing.allocator, "status");
    try testing.expectEqualStrings(program, argv.items[0]);
    try testing.expectEqualStrings("status", argv.items[argv.items.len - 1]);
    try testing.expectEqual(CONFIG_ARGS.len + 2, argv.items.len);
    try testing.expectEqualStrings("-c", argv.items[1]);
}

// ─── Behaviour ────────────────────────────────────────────────────────────
// A repository whose single file is committed as "one" and then changed to
// "two" in the work tree: a diff of it MUST report that hunk.

const Repo = struct {
    dir: testing.TmpDir,
    abs: []u8,

    fn deinit(self: *Repo, allocator: std.mem.Allocator) void {
        allocator.free(self.abs);
        self.dir.cleanup();
    }
};

fn writeAt(repo: *Repo, name: []const u8, body: []const u8) !void {
    var file = try repo.dir.dir.createFile(testing.io, name, .{});
    defer file.close(testing.io);
    try file.writeStreamingAll(testing.io, body);
}

/// `git` plus `CONFIG_ARGS` in `repo` — the argv the guest seam spawns.
fn gitHardened(allocator: std.mem.Allocator, repo: []const u8, args: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, program);
    try argv.appendSlice(allocator, &CONFIG_ARGS);
    try argv.appendSlice(allocator, &.{ "-C", repo });
    try argv.appendSlice(allocator, args);
    return std.process.run(allocator, testing.io, .{ .argv = argv.items, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) });
}

/// Plain `git -C <repo> <args>`, for arranging the fixture.
fn git(allocator: std.mem.Allocator, repo: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, program);
    try argv.appendSlice(allocator, &.{ "-C", repo });
    try argv.appendSlice(allocator, args);
    const res = try std.process.run(allocator, testing.io, .{ .argv = argv.items, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.term.exited != 0) return error.FixtureGitFailed;
}

fn repoWithOneChange(allocator: std.mem.Allocator) !Repo {
    var dir = testing.tmpDir(.{});
    errdefer dir.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try dir.dir.realPath(testing.io, &buf);
    var repo = Repo{ .dir = dir, .abs = try allocator.dupe(u8, buf[0..n]) };
    errdefer {
        allocator.free(repo.abs);
        repo.dir.cleanup();
    }

    try writeAt(&repo, "a.txt", "one\n");
    try git(allocator, repo.abs, &.{ "init", "-q", "-b", "main" });
    try git(allocator, repo.abs, &.{ "config", "user.email", "harness@example.com" });
    try git(allocator, repo.abs, &.{ "config", "user.name", "harness" });
    try git(allocator, repo.abs, &.{ "add", "a.txt" });
    try git(allocator, repo.abs, &.{ "commit", "-qm", "first" });
    try writeAt(&repo, "a.txt", "two\n");
    return repo;
}

test "a diff under the hardening prefix reports the change the work tree holds" {
    const allocator = testing.allocator;
    var repo = try repoWithOneChange(allocator);
    defer repo.deinit(allocator);

    const res = try gitHardened(allocator, repo.abs, &.{"diff"});
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    try testing.expectEqual(@as(u32, 0), res.term.exited);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "+two") != null);
}

test "a repository's external diff cannot replace what a hardened diff reports" {
    const allocator = testing.allocator;
    var repo = try repoWithOneChange(allocator);
    defer repo.deinit(allocator);
    // A repository is free to name a command here; a hardened diff must not run it.
    try git(allocator, repo.abs, &.{ "config", "diff.external", "/bin/false" });

    const hardened = try hardenArgs(allocator, &.{ "diff", "--", "a.txt" });
    defer allocator.free(hardened);

    const res = try gitHardened(allocator, repo.abs, hardened);
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    try testing.expectEqual(@as(u32, 0), res.term.exited);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "+two") != null);
}

test "a subcommand that takes no diff options is handed the caller's argv unchanged" {
    const allocator = testing.allocator;
    var repo = try repoWithOneChange(allocator);
    defer repo.deinit(allocator);

    const hardened = try hardenArgs(allocator, &.{ "check-ignore", "--", "a.txt" });
    defer allocator.free(hardened);

    const res = try gitHardened(allocator, repo.abs, hardened);
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    // 1 = "not ignored". An injected `--no-ext-diff` would make git reject the
    // argv instead (check-ignore parses no diff options).
    try testing.expectEqual(@as(u32, 1), res.term.exited);
}

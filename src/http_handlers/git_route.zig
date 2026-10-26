//! git_route — one answer to "which git may answer about this path?".
//!
//! The git REST surface is many endpoints but only two substrates. In local
//! mode the repository is a directory on this host; under `--saas` it is the
//! tenant's microVM and the host holds no copy of it at all (`workspace_fs`
//! keeps the guest the only reader and the only writer). An endpoint that
//! spawned `git -C <path>` itself therefore answered "not a git repository"
//! for every VM workspace, because `<path>` does not exist here — the Changes
//! panel's "Not a git repository" for a live VM was exactly that.
//!
//! This module is the seam those endpoints now go through. It resolves the
//! route with `workspace_fs.routeForPath` — the same decision the file tools
//! and the agent's own `git` already take — and then runs `git <args>` on
//! whichever side owns the tree. The forge CLI (`gh`, `glab`) is deliberately
//! NOT routed: it is a host concern with host credentials, which is why
//! `git_pr_status` already keeps its `gh` spawns local and sends only git to
//! the guest.
//!
//! Fail-closed is inherited, not re-invented: a `--saas` process whose VM
//! cannot be reached returns the route's error. It never falls back to the
//! host, because "the host has no such repository" is not an answer a tenant
//! endpoint may give.

const std = @import("std");
const pabrik_core = @import("pabrikcore");
const run_captured = @import("helpers").run_captured;
const workspace_fs = @import("../agentic_loop/workspace_fs.zig");

/// The program every arm runs. One name, so a stray literal cannot reintroduce
/// a host spawn this module does not route.
pub const program = "git";

/// Matches the host spawns the routed call sites replace.
pub const default_timeout_ms: u32 = 20_000;

/// Per-stream capture cap. Deliberately NOT `run_captured`'s 64 KiB default:
/// the call sites this replaced read git unbounded, and 64 KiB silently cuts
/// a `status --porcelain` for a 25k-file checkout (the Changes panel would
/// drop files) or a large `blame`. Endpoints with a cap of their own pass it.
pub const default_max_output_bytes: usize = 4 * 1024 * 1024;

pub const Options = struct {
    timeout_ms: u32 = default_timeout_ms,
    max_output_bytes: usize = default_max_output_bytes,
};

/// Output + exit status of one `git` invocation, whoever ran it. Shaped like
/// `run_captured.Result` on purpose: a call site that used to spawn the host's
/// git swaps one line for `git_route.run(...)` and keeps reading `.term`,
/// `.stdout`, `.stderr`, `.timed_out`.
pub const Run = struct {
    term: std.process.Child.Term,
    /// Owned by the caller; release both with `deinit`.
    stdout: []u8,
    stderr: []u8,
    /// True when the invocation was killed at its deadline. The output is
    /// partial, and `term` is not git's own report.
    timed_out: bool,

    pub fn deinit(self: *Run, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.stdout = &.{};
        self.stderr = &.{};
    }

    /// The exit code as the `u8` a term reports. A signal is not 0 or 1, so
    /// every caller still sees a failed git.
    pub fn code(self: Run) u8 {
        return switch (self.term) {
            .exited => |c| c,
            else => 255,
        };
    }

    pub fn ok(self: Run) bool {
        return !self.timed_out and self.code() == 0;
    }

    /// stdout without the trailing newline git always adds.
    pub fn trimmedStdout(self: Run) []const u8 {
        return std.mem.trim(u8, self.stdout, " \n\r\t");
    }
};

/// Which git may answer about `abs_path` — the same route the file tools take.
pub fn routeFor(allocator: std.mem.Allocator, abs_path: []const u8) workspace_fs.Route {
    const di = pabrik_core.getSingleton() catch null;
    return workspace_fs.routeForPath(allocator, if (di) |d| d.db else null, abs_path);
}

/// `git <args>` with `abs_dir` as its working directory, run by whichever side
/// owns the tree. `args` is the subcommand and its arguments — never the
/// program and never `-C`: neither is the caller's to name when the guest may
/// be the one running it.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    abs_dir: []const u8,
    args: []const []const u8,
    opts: Options,
) !Run {
    var route = routeFor(allocator, abs_dir);
    defer route.deinit();

    switch (route) {
        // FIRST, and before the guest arm: a `--saas` route that could not
        // reach the workspace is an error the caller must report, never a
        // quiet "let the host's git look".
        .unavailable => |err| return err,
        .guest => |*fs| {
            const exec = try fs.runGit(abs_dir, args, opts.timeout_ms, opts.max_output_bytes);
            return .{
                .term = termFor(exec.code, exec.timed_out),
                .stdout = exec.stdout,
                .stderr = exec.stderr,
                .timed_out = exec.timed_out,
            };
        },
        .host => {},
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendHostArgv(&argv, allocator, abs_dir, args);

    const res = try run_captured.run(allocator, io, argv.items, .{
        .max_output_bytes = opts.max_output_bytes,
        .timeout_ms = opts.timeout_ms,
    });
    return .{
        .term = res.term,
        .stdout = res.stdout,
        .stderr = res.stderr,
        .timed_out = res.timed_out,
    };
}

/// The host argv this seam builds: exactly `git -C <dir> <args...>`, the form
/// every routed call site used to spell out for itself. Split out so the local
/// answer can be asserted without spawning anything.
pub fn appendHostArgv(
    argv: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    abs_dir: []const u8,
    args: []const []const u8,
) !void {
    try argv.append(allocator, program);
    try argv.append(allocator, "-C");
    try argv.append(allocator, abs_dir);
    try argv.appendSlice(allocator, args);
}

/// The guest's exit code as the term shape `run_captured` reports, so a call
/// site cannot tell which side answered.
fn termFor(code: i64, timed_out: bool) std.process.Child.Term {
    // We killed it, so there is no report of git's own to relay.
    if (timed_out) return .{ .unknown = 0 };
    if (code < 0 or code > 255) return .{ .unknown = 0 };
    return .{ .exited = @intCast(code) };
}

const testing = std.testing;
const runtime_mode = @import("../runtime_mode.zig");
const open_descriptors = @import("helpers").open_descriptors;

/// One throwaway work tree. `git init` succeeds inside an existing repository
/// (it makes a nested one), so the fixture does not care where the build cache
/// sits — a test that read the ambient repository would pass for the wrong
/// reason.
const Repo = struct {
    dir: testing.TmpDir,
    abs: []u8,

    fn init(allocator: std.mem.Allocator) !Repo {
        var dir = testing.tmpDir(.{});
        errdefer dir.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try dir.dir.realPath(testing.io, &buf);
        const abs = try allocator.dupe(u8, buf[0..n]);
        errdefer allocator.free(abs);
        const argv = [_][]const u8{ "git", "-C", abs, "init", "-q", "-b", "main" };
        var init_run = try run_captured.run(allocator, testing.io, &argv, .{ .timeout_ms = 30_000 });
        defer init_run.deinit(allocator);
        if (init_run.term.exited != 0) return error.SkipZigTest;
        return .{ .dir = dir, .abs = abs };
    }

    fn deinit(self: *Repo, allocator: std.mem.Allocator) void {
        allocator.free(self.abs);
        self.dir.cleanup();
    }
};

test "local mode routes every path to the host, with no database and no VM" {
    var route = routeFor(testing.allocator, "/tmp/pabrik-git-route-local");
    defer route.deinit();
    try testing.expect(route == .host);
    try testing.expect(route.guestFs() == null);
}

test "local mode hands git exactly the -C argv the call sites used to build" {
    // The argv IS the contract with the other process: a local-mode caller must
    // see `git -C <dir> <args...>`, byte for byte what it spawned before.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try appendHostArgv(&argv, testing.allocator, "/work/repo", &.{ "rev-parse", "--git-dir" });
    try testing.expectEqual(@as(usize, 5), argv.items.len);
    try testing.expectEqualStrings("git", argv.items[0]);
    try testing.expectEqualStrings("-C", argv.items[1]);
    try testing.expectEqualStrings("/work/repo", argv.items[2]);
    try testing.expectEqualStrings("rev-parse", argv.items[3]);
    try testing.expectEqualStrings("--git-dir", argv.items[4]);
}

test "a run in a work tree reports git's own answer" {
    const allocator = testing.allocator;
    var repo = try Repo.init(allocator);
    defer repo.deinit(allocator);

    var res = try run(allocator, testing.io, repo.abs, &.{ "rev-parse", "--is-inside-work-tree" }, .{});
    defer res.deinit(allocator);

    try testing.expect(res.ok());
    try testing.expectEqualStrings("true", res.trimmedStdout());
}

test "a failing subcommand reaches the caller as a code plus git's complaint" {
    const allocator = testing.allocator;
    var repo = try Repo.init(allocator);
    defer repo.deinit(allocator);

    // A ref that cannot exist: the answer does not depend on the ambient
    // repository or on which directory the test happens to run in.
    var res = try run(allocator, testing.io, repo.abs, &.{ "rev-parse", "--verify", "refs/heads/pabrik-no-such-branch" }, .{});
    defer res.deinit(allocator);

    try testing.expect(res.term == .exited);
    try testing.expect(res.code() != 0);
    try testing.expect(res.stderr.len > 0);
}

test "outside any work tree the refusal is not dressed up as a repository" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    // `/proc` can never be inside a work tree. The pre-seam handlers turned
    // this same failure into `is_git_repo: false`, which is exactly the answer
    // a VM workspace also got — so the distinction is the behaviour here.
    var res = try run(allocator, testing.io, "/proc", &.{ "rev-parse", "--git-dir" }, .{});
    defer res.deinit(allocator);

    try testing.expect(!res.ok());
    try testing.expect(std.mem.indexOf(u8, res.stderr, "not a git repository") != null);
}

test "a dangling directory never answers as a repository" {
    const allocator = testing.allocator;

    // Some libcs validate the working directory inside `spawn` and return an
    // error there; glibc does not, so git itself exits 128 with "cannot
    // change to ...". Both are refusals, and the behaviour under test is the
    // refusal: the pre-seam handlers turned this same failure into
    // `is_git_repo: false`, which is the answer a VM workspace also got.
    if (run(allocator, testing.io, "/pabrik/no/such/repo/xyzzy", &.{ "rev-parse", "--git-dir" }, .{})) |value| {
        var res = value;
        defer res.deinit(allocator);
        try testing.expect(!res.ok());
    } else |_| {}
}

test "an argument list crosses the seam verbatim, so a flag-shaped value stays a value" {
    const allocator = testing.allocator;
    var repo = try Repo.init(allocator);
    defer repo.deinit(allocator);

    var res = try run(allocator, testing.io, repo.abs, &.{ "--definitely-not-a-git-option" }, .{});
    defer res.deinit(allocator);

    // git rejected OUR option: proof it received the argv as the caller wrote
    // it, rather than the seam re-parsing or reordering it.
    try testing.expect(!res.ok());
    try testing.expect(std.mem.indexOf(u8, res.stderr, "--definitely-not-a-git-option") != null);
}

test "saas mode never answers from the host, even when the host holds that repository" {
    const allocator = testing.allocator;
    var repo = try Repo.init(allocator);
    defer repo.deinit(allocator);

    // Control: in local mode this very path answers from this host.
    var local = try run(allocator, testing.io, repo.abs, &.{ "rev-parse", "--is-inside-work-tree" }, .{});
    defer local.deinit(allocator);
    try testing.expectEqualStrings("true", local.trimmedStdout());

    // Under `--saas` the same call must refuse rather than read the host's own
    // checkout. A unit test has no workspace database, so the route finds no
    // workspace and fails closed; on a host with no VM backend compiled in the
    // refusal is the manager's. Both are refusals, and pre-seam both were the
    // host's "true" — the bug this module exists to close.
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);

    const expected: anyerror = if (runtime_mode.vm_backend_available)
        error.GuestWorkspaceUnknown
    else
        error.GuestManagerUnavailable;
    try testing.expectError(expected, run(allocator, testing.io, repo.abs, &.{ "rev-parse", "--is-inside-work-tree" }, .{}));
}

test "repeated runs cost no descriptors" {
    const allocator = testing.allocator;
    var repo = try Repo.init(allocator);
    defer repo.deinit(allocator);

    // One call is two pipes; a server path that leaks them dies at the fd
    // limit, not at a wrong answer. Count the delta, so a long-lived fixture
    // does not fail the test.
    const before = try open_descriptors.count();
    for (0..8) |_| {
        var res = try run(allocator, testing.io, repo.abs, &.{ "rev-parse", "--git-dir" }, .{});
        res.deinit(allocator);
    }
    try testing.expectEqual(before, try open_descriptors.count());
}

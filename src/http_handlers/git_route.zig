//! Which git may answer a path. `/api/git/*` spawned `git -C <path>` on the
//! HOST and said "not a git repository" for every VM workspace; this seam
//! routes to the owner, fails closed, and leaves `gh`/`glab` host-side.

const std = @import("std");
const pabrik_core = @import("pabrikcore");
const run_captured = @import("helpers").run_captured;
const workspace_fs = @import("../agentic_loop/workspace_fs.zig");

/// The program every arm runs. One name, so a stray literal cannot reintroduce
/// a host spawn this module does not route.
pub const program = "git";

/// Matches the host spawns the routed call sites replace.
pub const default_timeout_ms: u32 = 20_000;

/// Deliberately NOT `run_captured`'s 64 KiB: the call sites this replaced read
/// git unbounded, and 64 KiB silently cuts a `status --porcelain` on a 25k-file
/// checkout or a large `blame`. Endpoints with a cap of their own pass it.
pub const default_max_output_bytes: usize = 4 * 1024 * 1024;

pub const Options = struct {
    timeout_ms: u32 = default_timeout_ms,
    max_output_bytes: usize = default_max_output_bytes,
};

/// One git invocation's output, whoever ran it. Shaped like
/// `run_captured.Result` so a routed call site keeps reading `.term`,
/// `.stdout`, `.stderr` and `.timed_out`.
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

/// `git <args>` with `abs_dir` as its working directory, on whichever side owns
/// the tree. `args` never carries the program or `-C`: the guest names neither,
/// and a tenant path must not cross the boundary.
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

/// One throwaway work tree. `git init` nests inside an existing repository, so
/// the cache's location cannot change the answer — reading the ambient
/// checkout is the mistake this fixture exists to prevent.
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
        if (init_run.term.exited != 0) return error.GitInitFailed;
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

test "a dangling directory never answers as a repository" {
    const allocator = testing.allocator;

    // Some libcs fail inside `spawn`; glibc does not, so git itself exits 128.
    // Both are refusals — the pre-seam handlers turned this into
    // `is_git_repo: false`, the same answer a VM workspace got.
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

test "a local run delivers a capture past the guest wire's ceiling, whole" {
    const allocator = testing.allocator;
    var repo = try Repo.init(allocator);
    defer repo.deinit(allocator);

    const blob_bytes = 3 * 1024 * 1024;
    const blob = try allocator.alloc(u8, blob_bytes);
    defer allocator.free(blob);
    for (blob, 0..) |*byte, i| byte.* = @intCast('a' + i % 26);
    try repo.dir.dir.writeFile(testing.io, .{ .sub_path = "big.bin", .data = blob });

    var hashed = try run(allocator, testing.io, repo.abs, &.{ "hash-object", "-w", "big.bin" }, .{});
    defer hashed.deinit(allocator);
    try testing.expect(hashed.ok());

    var read = try run(allocator, testing.io, repo.abs, &.{ "cat-file", "blob", hashed.trimmedStdout() }, .{});
    defer read.deinit(allocator);

    try testing.expect(read.ok());
    try testing.expectEqual(blob_bytes, read.stdout.len);
    try testing.expectEqualSlices(u8, blob, read.stdout);
}

test "saas mode never answers from the host, even when the host holds that repository" {
    const allocator = testing.allocator;
    var repo = try Repo.init(allocator);
    defer repo.deinit(allocator);

    // Control: in local mode this very path answers from this host.
    var local = try run(allocator, testing.io, repo.abs, &.{ "rev-parse", "--is-inside-work-tree" }, .{});
    defer local.deinit(allocator);
    try testing.expectEqualStrings("true", local.trimmedStdout());

    // Under `--saas` the same call must refuse rather than read this host's
    // checkout: a unit test has no workspace DB, so the route fails closed (a
    // build with no VM backend refuses via the manager). Both refusals.
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

//! The host side of a tenant file: map an absolute host path onto the guest's
//! `/workspace` and read it through `pabrik-vmd`. Local mode installs nothing —
//! a caller asks `forSession` and keeps today's behaviour on a null answer.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const runtime_mode = @import("../runtime_mode.zig");
const workspace_scope = @import("workspace_scope.zig");
const workspace_vm = @import("workspace_vm.zig");
const vmd = @import("../vmd/vmd_client.zig");
const vm_wire = @import("vm_wire");
const proxy_rpc = @import("../vmd/proxy_rpc.zig");
const policy = @import("../vmd/policy.zig");
const fs_policy = @import("../vmd/fs_policy.zig");
const git_hardening = @import("helpers").git_hardening;

pub const Error = error{
    GuestWorkspaceUnknown,
    /// The workspace is not VM-backed: no Firecracker, no host fallback.
    GuestWorkspaceNotVm,
    GuestPathOutsideWorkspace,
    GuestManagerUnavailable,
    GuestManagerRefused,
    GuestFileMissing,
    GuestNotDirectory,
    GuestWriteFailed,
    GuestWriteTooLarge,
    GuestWalkTruncated,
    GuestWorkspaceRoot,
};

/// What a walk said a path is. The guest names four kinds; nothing above this
/// seam has to know which syscall told it.
pub const Kind = enum { file, dir, link, other };

fn kindFromGuest(text: []const u8) Kind {
    if (std.mem.eql(u8, text, "dir")) return .dir;
    if (std.mem.eql(u8, text, "file")) return .file;
    if (std.mem.eql(u8, text, "link")) return .link;
    return .other;
}

/// One path the guest reported, named the way the caller names paths: absolute,
/// under the workspace root. There is still no host filesystem behind it — the
/// string is a key for this seam, not a file the host may open.
pub const Entry = struct {
    abs: []u8,
    kind: Kind,
};

/// A bounded walk. `truncated` is the guest saying the tree was larger than
/// the ceilings allowed, which is not the same as a tree that ended.
pub const Walk = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    truncated: bool,

    pub fn deinit(self: Walk) void {
        for (self.entries) |entry| self.allocator.free(entry.abs);
        self.allocator.free(self.entries);
    }
};

/// One path's kind and size, as the guest sees it.
pub const Stat = struct {
    kind: Kind,
    size: i64,
    missing: bool,
};

/// A program's answer from inside the guest. The host spawned nothing: this is
/// the only way a scan or a git check runs against a tenant tree.
pub const Exec = struct {
    code: i64,
    timed_out: bool,
    truncated: bool,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: Exec, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// How long a guest `git check-ignore` may take, and how much of it is kept.
const git_check_timeout_ms: u32 = 20_000;
const git_check_output_bytes: usize = 64 * 1024;

/// Which guest file an absolute host path names. There is no host filesystem
/// behind this: `root` is only the string the DB records, and every byte comes
/// back over the RPC.
pub const Fs = struct {
    allocator: std.mem.Allocator,
    workspace_id: []u8,
    root: []u8,
    socket: []u8,
    /// Whether answers are spelled in the guest's vocabulary. A `--saas` caller
    /// gets `/workspace/...`; local mode keeps the host's own paths.
    guest_paths: bool = false,

    pub fn deinit(self: *Fs) void {
        self.allocator.free(self.workspace_id);
        self.allocator.free(self.root);
        self.allocator.free(self.socket);
    }

    /// The path relative to the workspace root, or null when `abs` is not under
    /// it. Borrows from `abs`, so the caller keeps owning its own string.
    pub fn relative(self: *const Fs, abs: []const u8) ?[]const u8 {
        const rel = policy.relativeWorkspace(self.root, abs) orelse return null;
        if (!fs_policy.pathRelValid(rel)) return null;
        return rel;
    }

    /// The whole file, read in bounded pieces until the guest says `eof`. The
    /// host never opens it, so the only copy is the one in this allocation.
    pub fn readAll(self: *const Fs, abs: []const u8) ![]u8 {
        return self.readUpTo(self.allocator, abs, fs_policy.max_read_bytes);
    }

    /// The same read under the caller's own ceiling, for a copy that is allowed
    /// to be larger than a tool's answer may be. Over the ceiling is a refusal,
    /// never a truncation — the caller asked for all of it.
    pub fn readUpTo(self: *const Fs, allocator: std.mem.Allocator, abs: []const u8, max_bytes: usize) ![]u8 {
        const rel = self.relative(abs) orelse return Error.GuestPathOutsideWorkspace;
        var client = vmd.Client.init(allocator, self.socket);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var offset: i64 = 0;
        while (true) {
            const chunk = client.readFile(self.workspace_id, rel, offset, vmd_read_chunk) catch |err| {
                return managerError(err);
            };
            defer chunk.deinit(allocator);
            if (chunk.missing) return Error.GuestFileMissing;
            try out.appendSlice(allocator, chunk.bytes);
            if (chunk.eof or chunk.bytes.len == 0) break;
            offset += @intCast(chunk.bytes.len);
            if (out.items.len > max_bytes) return error.FileTooBig;
        }
        return out.toOwnedSlice(allocator);
    }

    /// The directory form of `relative`: a listing or a walk may start at the
    /// workspace root, which is the one path no file op may name.
    pub fn relativeDir(self: *const Fs, abs: []const u8) ?[]const u8 {
        const rel = policy.relativeWorkspace(self.root, abs) orelse return null;
        if (!fs_policy.dirRelValid(rel)) return null;
        return rel;
    }

    /// The absolute path a guest-relative one names, in the caller's own
    /// vocabulary. The reverse of `relative`, and the only place a walk's
    /// relative answer becomes a path a tool can hand back to a model.
    pub fn hostPath(self: *const Fs, rel: []const u8) ![]u8 {
        if (!fs_policy.dirRelValid(rel)) return Error.GuestPathOutsideWorkspace;
        if (self.guest_paths) return policy.guestCwd(self.allocator, policy.guest_root, rel);
        const root = std.mem.trimEnd(u8, self.root, "/");
        if (rel.len == 0) return self.allocator.dupe(u8, root);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, rel });
    }

    /// The kind and size of one path, as the guest sees it. The workspace root
    /// itself has no stat: a caller that needs it should list, or walk, there.
    pub fn stat(self: *const Fs, abs: []const u8) !Stat {
        const rel = self.relative(abs) orelse return Error.GuestPathOutsideWorkspace;
        var client = vmd.Client.init(self.allocator, self.socket);
        const answer = client.statFile(self.workspace_id, rel) catch |err| return managerError(err);
        defer answer.deinit(self.allocator);
        return .{
            .kind = kindFromGuest(answer.kind),
            .size = answer.size,
            .missing = answer.missing,
        };
    }

    /// The whole file, written BY THE GUEST. The bytes are the caller's and the
    /// file is the guest's; the host creates nothing and opens nothing, which
    /// is what makes the guest the only writer.
    pub fn writeAll(self: *const Fs, abs: []const u8, bytes: []const u8, create_dirs: bool) !void {
        const rel = self.relative(abs) orelse return Error.GuestPathOutsideWorkspace;
        if (bytes.len > fs_policy.max_write_bytes) return Error.GuestWriteTooLarge;
        var client = vmd.Client.init(self.allocator, self.socket);
        client.writeFile(self.workspace_id, rel, bytes, create_dirs) catch |err| {
            if (refusedByRequest(&client)) {
                // The tools tell "the directory is not there" apart from every
                // other write failure, so one ask — and only after a refusal —
                // decides which of the two this was.
                if (!create_dirs and self.parentMissing(abs)) return error.PathNotFound;
                return Error.GuestWriteFailed;
            }
            return managerError(err);
        };
    }

    /// A bounded walk of the workspace beneath `abs`. `max_depth` 1 is one
    /// directory's own entries; the guest enforces both ceilings, and a walk it
    /// had to cut short says so.
    pub fn walkAll(self: *const Fs, abs: []const u8, max_depth: u32) !Walk {
        const rel = self.relativeDir(abs) orelse return Error.GuestPathOutsideWorkspace;
        var client = vmd.Client.init(self.allocator, self.socket);
        var walked = client.walk(self.workspace_id, rel, max_depth, fs_policy.max_walk_entries) catch |err| {
            if (refusedByRequest(&client)) return Error.GuestNotDirectory;
            return managerError(err);
        };
        defer walked.deinit(self.allocator);

        const entries = try self.allocator.alloc(Entry, walked.entries.len);
        var filled: usize = 0;
        errdefer {
            for (entries[0..filled]) |entry| self.allocator.free(entry.abs);
            self.allocator.free(entries);
        }
        for (walked.entries, 0..) |entry, i| {
            entries[i] = .{
                .abs = try self.hostPath(entry.path),
                .kind = kindFromGuest(entry.kind),
            };
            filled = i + 1;
        }
        return .{
            .allocator = self.allocator,
            .entries = entries,
            .truncated = walked.truncated,
        };
    }

    /// One directory's own entries — a walk of depth one, named for what it is.
    pub fn listDir(self: *const Fs, abs: []const u8) !Walk {
        return self.walkAll(abs, 1);
    }

    /// Remove one file, or one empty directory. A missing path is an error, not
    /// a silent success: the tool reports "nothing there" from its own answer.
    pub fn remove(self: *const Fs, abs: []const u8) !void {
        const rel = self.relative(abs) orelse return Error.GuestPathOutsideWorkspace;
        var client = vmd.Client.init(self.allocator, self.socket);
        client.removeFile(self.workspace_id, rel) catch |err| return managerError(err);
    }

    /// Remove a directory and everything under it, leaves first. The guest's
    /// `fs.remove` takes one entry by design, so the loop is here — and a tree
    /// the walk had to cut short is refused rather than half deleted.
    pub fn removeAll(self: *const Fs, abs: []const u8) !void {
        const rel = self.relativeDir(abs) orelse return Error.GuestPathOutsideWorkspace;
        // The workspace itself is not a caller's to delete: everything the
        // tenant owns lives under it.
        if (rel.len == 0) return Error.GuestWorkspaceRoot;

        var walked = try self.walkAll(abs, fs_policy.max_walk_depth);
        defer walked.deinit();
        if (walked.truncated) return Error.GuestWalkTruncated;

        const order = try self.allocator.alloc(usize, walked.entries.len);
        defer self.allocator.free(order);
        for (order, 0..) |*slot, i| slot.* = i;
        // Deepest first: a directory can only go once its children have.
        std.mem.sort(usize, order, walked.entries, struct {
            fn less(entries: []const Entry, a: usize, b: usize) bool {
                const depth_a = std.mem.count(u8, entries[a].abs, "/");
                const depth_b = std.mem.count(u8, entries[b].abs, "/");
                if (depth_a != depth_b) return depth_a > depth_b;
                return entries[a].abs.len > entries[b].abs.len;
            }
        }.less);

        for (order) |i| try self.remove(walked.entries[i].abs);
        try self.remove(abs);
    }

    /// Run a program inside the guest, in a directory of the workspace. No
    /// shell is involved: the argv is the caller's.
    pub fn run(
        self: *const Fs,
        argv: []const []const u8,
        abs_cwd: []const u8,
        timeout_ms: u32,
        max_output_bytes: usize,
    ) !Exec {
        const cwd_rel = self.relativeDir(abs_cwd) orelse return Error.GuestPathOutsideWorkspace;
        var client = vmd.Client.init(self.allocator, self.socket);
        const outcome = client.exec(.{
            .workspace_id = self.workspace_id,
            .argv = argv,
            .cwd_rel = cwd_rel,
            .timeout_ms = timeout_ms,
            .max_output_bytes = max_output_bytes,
        }) catch |err| return managerError(err);
        return .{
            .code = outcome.code,
            .timed_out = outcome.timed_out,
            .truncated = outcome.truncated,
            .stdout = outcome.stdout,
            .stderr = outcome.stderr,
        };
    }

    /// `git`, with the same hardening prefix the host uses, running INSIDE the
    /// guest with `abs_dir` as its working directory. No `-C` is passed: the
    /// host path never crosses, so no tenant path is named to the guest's git.
    pub fn runGit(
        self: *const Fs,
        abs_dir: []const u8,
        args: []const []const u8,
        timeout_ms: u32,
        max_output_bytes: usize,
    ) !Exec {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, policy.guest_git);
        try argv.appendSlice(self.allocator, &git_hardening.CONFIG_ARGS);
        try argv.appendSlice(self.allocator, args);
        return self.run(argv.items, abs_dir, timeout_ms, max_output_bytes);
    }

    /// The absolute path a host path names inside the guest — the guest's own
    /// vocabulary, for the argv of a program that will run there. The reverse
    /// of `relative`, and a refusal for anything outside the workspace.
    pub fn guestAbs(self: *const Fs, abs: []const u8) ![]u8 {
        const rel = self.relativeDir(abs) orelse return Error.GuestPathOutsideWorkspace;
        return policy.guestCwd(self.allocator, policy.guest_root, rel);
    }

    /// Which of `names` git ignores in `abs_dir`, answered by the GUEST's git
    /// under the same hardening prefix the host uses. A git that cannot answer
    /// leaves every name unignored, which is what the host's check does too.
    pub fn gitCheckIgnore(
        self: *const Fs,
        abs_dir: []const u8,
        names: []const []const u8,
    ) ![]bool {
        const ignored = try self.allocator.alloc(bool, names.len);
        errdefer self.allocator.free(ignored);
        @memset(ignored, false);
        if (names.len == 0) return ignored;

        const args = try self.allocator.alloc([]const u8, 2 + names.len);
        defer self.allocator.free(args);
        args[0] = "check-ignore";
        args[1] = "--";
        @memcpy(args[2..], names);

        const exec = try self.runGit(abs_dir, args, git_check_timeout_ms, git_check_output_bytes);
        defer exec.deinit(self.allocator);
        // Exit 0 means at least one name was ignored, 1 means none was, and
        // anything else is not an answer this seam may invent one for.
        if (exec.code != 0) return ignored;
        var lines = std.mem.splitScalar(u8, exec.stdout, '\n');
        while (lines.next()) |line| {
            const named = std.mem.trimEnd(u8, line, "\r");
            if (named.len == 0) continue;
            for (names, 0..) |name, i| {
                if (std.mem.eql(u8, named, name)) ignored[i] = true;
            }
        }
        return ignored;
    }

    /// Whether the directory a path's parent names is there. Only asked after a
    /// write was refused, so a successful write never pays for it.
    fn parentMissing(self: *const Fs, abs: []const u8) bool {
        const parent = std.fs.path.dirname(abs) orelse return false;
        const answer = self.stat(parent) catch return false;
        return answer.missing or answer.kind != .dir;
    }
};

const vmd_read_chunk: usize = vm_wire.max_reply_chunk;

/// The substrate a workspace tree has on this build. A `--saas` process runs a
/// tenant tree in its VM or not at all: a host with no VM backend compiled in
/// has no third answer (`runtime_mode.vm_backend_available`).
pub const Substrate = enum { host, guest, none };

/// Pure, so every platform can test the `--saas` refusal without a VM — the
/// seam `runtime_mode.decide` takes a `Probe` for.
pub fn substrate(mode: runtime_mode.Mode, backend_available: bool) Substrate {
    if (mode != .saas) return .host;
    return if (backend_available) .guest else .none;
}

/// The guest filesystem for a session, or null when files belong on the host.
/// Fails closed: `--saas` is a guest or an error, never a quiet fall back to
/// reading the host — including when this build has no VM backend at all.
pub fn forSession(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !?Fs {
    switch (substrate(runtime_mode.currentMode(), runtime_mode.vm_backend_available)) {
        .host => return null,
        .none => return Error.GuestManagerUnavailable,
        .guest => {},
    }

    const workspace_id = (try workspace_scope.resolveWorkspaceId(allocator, db, session_id)) orelse
        return Error.GuestWorkspaceUnknown;
    errdefer allocator.free(workspace_id);
    if (!workspace_vm.isVmWorkspace(allocator, db, workspace_id)) return Error.GuestWorkspaceNotVm;
    const root = (try workspace_scope.resolveWorkspaceRoot(allocator, db, session_id)) orelse
        return Error.GuestWorkspaceUnknown;
    errdefer allocator.free(root);
    const socket = runtime_mode.socketPath() orelse return Error.GuestManagerUnavailable;
    const socket_copy = try allocator.dupe(u8, socket);
    return .{
        .allocator = allocator,
        .workspace_id = workspace_id,
        .root = root,
        .socket = socket_copy,
        .guest_paths = true,
    };
}

pub fn forWorkspace(allocator: std.mem.Allocator, db: *database.Db, workspace_id: []const u8) !Fs {
    if (!policy.workspaceIdValid(workspace_id)) return Error.GuestWorkspaceUnknown;
    if (substrate(runtime_mode.currentMode(), runtime_mode.vm_backend_available) != .guest) {
        return Error.GuestManagerUnavailable;
    }
    if (!workspace_vm.isVmWorkspace(allocator, db, workspace_id)) return Error.GuestWorkspaceNotVm;
    const socket = runtime_mode.socketPath() orelse return Error.GuestManagerUnavailable;
    return .{
        .allocator = allocator,
        .workspace_id = try allocator.dupe(u8, workspace_id),
        .root = try allocator.dupe(u8, ""),
        .socket = try allocator.dupe(u8, socket),
        .guest_paths = true,
    };
}

/// The guest filesystem for a directory named by an ABSOLUTE host path: the
/// call sites that have a path and no session. Same contract as `forSession`,
/// and the same failure — `--saas` with an unowned path is an error, never the host.
pub fn forPath(
    allocator: std.mem.Allocator,
    db: ?*database.Db,
    abs_path: []const u8,
) !?Fs {
    switch (substrate(runtime_mode.currentMode(), runtime_mode.vm_backend_available)) {
        .host => return null,
        .none => return Error.GuestManagerUnavailable,
        .guest => {},
    }

    const db_handle = db orelse return Error.GuestWorkspaceUnknown;
    const match = (try workspace_scope.resolveWorkspaceForPath(allocator, db_handle, abs_path)) orelse
        return Error.GuestWorkspaceUnknown;
    errdefer match.deinit(allocator);
    if (!workspace_vm.isVmWorkspace(allocator, db_handle, match.workspace_id)) return Error.GuestWorkspaceNotVm;
    const socket = runtime_mode.socketPath() orelse return Error.GuestManagerUnavailable;
    const socket_copy = try allocator.dupe(u8, socket);
    return .{
        .allocator = allocator,
        .workspace_id = match.workspace_id,
        .root = match.root,
        .socket = socket_copy,
        .guest_paths = true,
    };
}

/// Who may touch a session's tree: the GUEST under `--saas`, the host in local
/// mode, or nobody at all when `--saas` cannot reach the workspace's VM. There
/// is no fourth answer: `unavailable` is never the host.
pub const Route = union(enum) {
    host,
    guest: Fs,
    unavailable: anyerror,

    pub fn deinit(self: *Route) void {
        switch (self.*) {
            .guest => |*fs| fs.deinit(),
            else => {},
        }
    }

    /// The guest to ask, or null when the host is the answer. A caller that
    /// must fail closed matches `unavailable` FIRST — see `fetchGitStateFor`.
    pub fn guestFs(self: *Route) ?*const Fs {
        return switch (self.*) {
            .guest => |*fs| fs,
            else => null,
        };
    }
};

/// The route for a session's tree. Local mode is the host, byte-identical to
/// the days before the seam existed; `--saas` is the guest or a refusal.
pub fn routeForSession(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) Route {
    if (runtime_mode.currentMode() != .saas) return .host;
    const found = forSession(allocator, db, session_id) catch |err| return .{ .unavailable = err };
    return .{ .guest = found orelse return .{ .unavailable = Error.GuestWorkspaceUnknown } };
}

/// The route for a directory named by absolute host path, for the call sites
/// that have a path and no session.
pub fn routeForPath(
    allocator: std.mem.Allocator,
    db: ?*database.Db,
    abs_path: []const u8,
) Route {
    if (runtime_mode.currentMode() != .saas) return .host;
    const found = forPath(allocator, db, abs_path) catch |err| return .{ .unavailable = err };
    return .{ .guest = found orelse return .{ .unavailable = Error.GuestWorkspaceUnknown } };
}

/// One preview exchange through the manager, for the route that reaches a
/// tenant's dev server. Local mode has no guest to reach, so it fails closed
/// exactly like every other guest call here.
pub fn previewExchange(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    port: u16,
    request_bytes: []const u8,
) !proxy_rpc.Reply {
    if (!runtime_mode.vm_backend_available) return Error.GuestManagerUnavailable;
    if (runtime_mode.currentMode() != .saas) return Error.GuestManagerUnavailable;
    if (!workspace_vm.isVmWorkspace(allocator, db, workspace_id)) return Error.GuestWorkspaceNotVm;
    const socket = runtime_mode.socketPath() orelse return Error.GuestManagerUnavailable;
    return proxy_rpc.exchange(allocator, socket, workspace_id, port, request_bytes);
}

/// Whether the manager refused the CALLER'S OWN request — a path it will not
/// open, a directory it will not enter — rather than failing because the
/// workspace or the VM is not there. Only the first is the tool's to explain.
fn refusedByRequest(client: *const vmd.Client) bool {
    const failure = client.lastFailure() orelse return false;
    return failure.code == .bad_request;
}

fn managerError(err: anyerror) anyerror {
    return switch (err) {
        error.ConnectFailed, error.SocketFailed, error.IoFailed, error.Timeout => Error.GuestManagerUnavailable,
        error.ServerFailure => Error.GuestManagerRefused,
        else => err,
    };
}

// ============================================================================
// Behaviour tests — the pure half. A live VM is the smoke scripts' job.
// ============================================================================

const testing = std.testing;

const GuestTestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,

    fn deinit(self: *GuestTestCtx) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

fn guestTestCtx() !GuestTestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");

    try db.exec(testing.allocator,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT, cwd TEXT, workspace_id TEXT)
    , &.{});
    try db.exec(testing.allocator,
        \\CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER)
    , &.{});
    try db.exec(testing.allocator,
        \\CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL)
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('i1','w1','kanban','A','/proj/a',1)
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('s1','T1','i1')
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO sessions (id, name, status, cwd) VALUES ('s1','Task one','active','/proj/a')
    , &.{});

    // Migration 115: which workspaces are VM-backed. `w1` is (it belongs to
    // the session above), `w_host` is not.
    try db.exec(testing.allocator,
        \\CREATE TABLE workspaces (id TEXT PRIMARY KEY, is_vm INTEGER NOT NULL DEFAULT 0)
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO workspaces (id, is_vm) VALUES ('w1', 1), ('w_host', 0)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

fn testFs(root: []const u8) Fs {
    return .{
        .allocator = testing.allocator,
        .workspace_id = @constCast("w1"),
        .root = @constCast(root),
        .socket = @constCast("/nonexistent.sock"),
    };
}

test "relative: a path under the root maps, anything else is refused" {
    const fs = testFs("/proj/a");
    try testing.expectEqualStrings("src/main.zig", fs.relative("/proj/a/src/main.zig").?);
    try testing.expectEqualStrings("a.txt", fs.relative("/proj/a/a.txt").?);

    try testing.expect(fs.relative("/proj/a") == null);
    try testing.expect(fs.relative("/proj/ab/a.txt") == null);
    try testing.expect(fs.relative("/etc/passwd") == null);
    try testing.expect(fs.relative("/proj/a/../b") == null);
}

test "relative: a host path is never handed to the guest absolute" {
    const fs = testFs("/proj/a/");
    const rel = fs.relative("/proj/a/deep/file.txt").?;
    try testing.expect(!std.mem.startsWith(u8, rel, "/"));
    try testing.expect(std.mem.indexOf(u8, rel, "proj") == null);
}

test "forWorkspace: a workspace id alone builds the guest fs, and its paths are the guest's" {
    const a = testing.allocator;
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    runtime_mode.setManagerSocket("/run/user/1000/pabrik-vmd.sock");
    defer runtime_mode.setManagerSocket(null);

    var ctx = try guestTestCtx();
    defer ctx.deinit();

    if (!runtime_mode.vm_backend_available) {
        try testing.expectError(Error.GuestManagerUnavailable, forWorkspace(a, &ctx.db, "ws_1"));
        return;
    }

    var fs = try forWorkspace(a, &ctx.db, "ws_1");
    defer fs.deinit();
    try testing.expect(fs.guest_paths);
    try testing.expectEqualStrings("ws_1", fs.workspace_id);
    try testing.expectEqualStrings("src", fs.relative("/workspace/src").?);

    const listed = try fs.hostPath("src");
    defer a.free(listed);
    try testing.expectEqualStrings("/workspace/src", listed);
}

test "forWorkspace: an id that is not inert is refused before any socket is asked" {
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    var ctx = try guestTestCtx();
    defer ctx.deinit();
    try testing.expectError(Error.GuestWorkspaceUnknown, forWorkspace(testing.allocator, &ctx.db, "../../etc"));
}

test "forWorkspace: a workspace that is not VM-backed gets no Firecracker" {
    const a = testing.allocator;
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    runtime_mode.setManagerSocket("/run/user/1000/pabrik-vmd.sock");
    defer runtime_mode.setManagerSocket(null);

    var ctx = try guestTestCtx();
    defer ctx.deinit();

    if (!runtime_mode.vm_backend_available) {
        // No VM backend on this host: there is no Firecracker to spawn at all,
        // so the refusal is "no manager" and no VM is spawned either way.
        try testing.expectError(Error.GuestManagerUnavailable, forWorkspace(a, &ctx.db, "w_host"));
        return;
    }

    // The refusal comes BEFORE the manager is asked, so no VM is spawned for
    // a workspace that has none.
    try testing.expectError(Error.GuestWorkspaceNotVm, forWorkspace(a, &ctx.db, "w_host"));

    var fs = try forWorkspace(a, &ctx.db, "w1");
    defer fs.deinit();
    try testing.expectEqualStrings("w1", fs.workspace_id);
}

test "forWorkspace: local mode has no guest to hand out" {
    var ctx = try guestTestCtx();
    defer ctx.deinit();
    try testing.expectError(Error.GuestManagerUnavailable, forWorkspace(testing.allocator, &ctx.db, "ws_1"));
}

test "hostPath: a --saas caller is answered in the guest's vocabulary" {
    const a = testing.allocator;
    var fs = Fs{
        .allocator = a,
        .workspace_id = try a.dupe(u8, "ws"),
        .root = try a.dupe(u8, "/home/you/proj"),
        .socket = try a.dupe(u8, "/run/user/1000/pabrik-vmd.sock"),
        .guest_paths = true,
    };
    defer fs.deinit();

    const at_root = try fs.hostPath("");
    defer a.free(at_root);
    try testing.expectEqualStrings("/workspace", at_root);

    const nested = try fs.hostPath("src/agent");
    defer a.free(nested);
    try testing.expectEqualStrings("/workspace/src/agent", nested);

    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.hostPath("../etc"));
}

test "hostPath: local mode still spells the host path" {
    const a = testing.allocator;
    var fs = Fs{
        .allocator = a,
        .workspace_id = try a.dupe(u8, "ws"),
        .root = try a.dupe(u8, "/home/you/proj"),
        .socket = try a.dupe(u8, "/tmp/s.sock"),
    };
    defer fs.deinit();

    const nested = try fs.hostPath("src");
    defer a.free(nested);
    try testing.expectEqualStrings("/home/you/proj/src", nested);
}

test "substrate: local is the host, --saas is the guest or nobody" {
    try testing.expectEqual(Substrate.host, substrate(.local, true));
    try testing.expectEqual(Substrate.host, substrate(.local, false));
    try testing.expectEqual(Substrate.guest, substrate(.saas, true));
    try testing.expectEqual(Substrate.none, substrate(.saas, false));
}

test "forSession: local mode installs no guest filesystem at all" {
    try testing.expectEqual(runtime_mode.Mode.local, runtime_mode.currentMode());
    var ctx = try guestTestCtx();
    defer ctx.deinit();
    try testing.expect((try forSession(testing.allocator, &ctx.db, "s1")) == null);
}

test "forSession: saas with a workspace but no manager refuses rather than falls back" {
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    var ctx = try guestTestCtx();
    defer ctx.deinit();
    runtime_mode.setManagerSocket(null);
    defer runtime_mode.setManagerSocket(null);
    try testing.expectError(Error.GuestManagerUnavailable, forSession(testing.allocator, &ctx.db, "s1"));
}

test "forSession: saas with no resolvable workspace fails closed" {
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    if (!runtime_mode.vm_backend_available) return;

    var ctx = try guestTestCtx();
    defer ctx.deinit();
    try testing.expectError(Error.GuestWorkspaceUnknown, forSession(testing.allocator, &ctx.db, "no-such-session"));
}

test "the guest read chunk is the wire's reply budget, so one reply is one frame" {
    try std.testing.expectEqual(vm_wire.max_reply_chunk, vmd_read_chunk);
    try std.testing.expect(vm_wire.encodedReplyFits(vmd_read_chunk));
    try std.testing.expect(!vm_wire.encodedReplyFits(64 * 1024));
}

test "readAll: a path outside the workspace is refused before any RPC" {
    const fs = testFs("/proj/a");
    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.readAll("/etc/passwd"));
    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.remove("/etc/passwd"));
}

test "every op refuses a path outside the workspace before any RPC" {
    const fs = testFs("/proj/a");
    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.writeAll("/etc/passwd", "x", false));
    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.stat("/etc/passwd"));
    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.walkAll("/etc", 2));
    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.listDir("/etc"));
    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.removeAll("/etc"));
    try testing.expectError(
        Error.GuestPathOutsideWorkspace,
        fs.run(&.{"rg"}, "/etc", 1000, 4096),
    );
    // The root's parent is outside it too, so the escape is refused on the way
    // out as well as on the way in.
    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.listDir("/proj"));
    try testing.expect(fs.relativeDir("/proj/a") != null);
    try testing.expect(fs.relativeDir("/proj") == null);
}

test "hostPath: a walk's answer comes back in the caller's own vocabulary" {
    const fs = testFs("/proj/a");
    const at_root = try fs.hostPath("");
    defer testing.allocator.free(at_root);
    try testing.expectEqualStrings("/proj/a", at_root);

    const nested = try fs.hostPath("src/main.zig");
    defer testing.allocator.free(nested);
    try testing.expectEqualStrings("/proj/a/src/main.zig", nested);

    // A trailing slash in the recorded root must not double.
    const trailing = testFs("/proj/a/");
    const joined = try trailing.hostPath("x");
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("/proj/a/x", joined);

    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.hostPath("../etc"));
    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.hostPath("/etc"));
}

test "writeAll: a body the frame could not carry is refused, not truncated" {
    const fs = testFs("/proj/a");
    // One byte over the RPC's own ceiling, so the refusal comes from the seam
    // rather than from a half-written file in the guest.
    const big = try testing.allocator.alloc(u8, fs_policy.max_write_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try testing.expectError(Error.GuestWriteTooLarge, fs.writeAll("/proj/a/big.txt", big, false));
}

test "gitCheckIgnore: naming nothing asks the guest nothing" {
    const fs = testFs("/proj/a");
    const none = try fs.gitCheckIgnore("/proj/a", &.{});
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "guestAbs: a host path becomes the guest's own, and nothing else does" {
    const fs = testFs("/proj/a");
    const at_root = try fs.guestAbs("/proj/a");
    defer testing.allocator.free(at_root);
    try testing.expectEqualStrings("/workspace", at_root);

    const nested = try fs.guestAbs("/proj/a/src/main.zig");
    defer testing.allocator.free(nested);
    try testing.expectEqualStrings("/workspace/src/main.zig", nested);

    // The guest's own vocabulary: no host path crosses whole.
    try testing.expect(std.mem.indexOf(u8, nested, "proj") == null);

    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.guestAbs("/etc/passwd"));
    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.guestAbs("/proj/ab"));
}

test "runGit: an outside directory is refused before any RPC" {
    const fs = testFs("/proj/a");
    try testing.expectError(
        Error.GuestPathOutsideWorkspace,
        fs.runGit("/etc", &.{"status"}, 1000, 4096),
    );
}

test "forPath: local mode installs no guest for a path either" {
    try testing.expectEqual(runtime_mode.Mode.local, runtime_mode.currentMode());
    var ctx = try guestTestCtx();
    defer ctx.deinit();
    try testing.expect((try forPath(testing.allocator, &ctx.db, "/proj/a/src")) == null);
}

test "forPath: saas refuses a path no workspace owns, and one with no manager" {
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    if (!runtime_mode.vm_backend_available) return;

    var ctx = try guestTestCtx();
    defer ctx.deinit();

    // A path under no recorded root is NOT an invitation to run on the host.
    try testing.expectError(
        Error.GuestWorkspaceUnknown,
        forPath(testing.allocator, &ctx.db, "/etc"),
    );
    // No database at all is the same answer, not a host fall back.
    try testing.expectError(
        Error.GuestWorkspaceUnknown,
        forPath(testing.allocator, null, "/proj/a"),
    );
    // The workspace resolves, so the only thing missing is the manager.
    runtime_mode.setManagerSocket(null);
    defer runtime_mode.setManagerSocket(null);
    try testing.expectError(
        Error.GuestManagerUnavailable,
        forPath(testing.allocator, &ctx.db, "/proj/a/src"),
    );
}

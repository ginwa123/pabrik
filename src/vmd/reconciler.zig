//! The reconciler: the only writer of a workspace's VM state. `decide` is a
//! pure function of the record plus three probes, so the state machine is
//! testable without a VMM, a clock or a socket.

const std = @import("std");
const linux = std.os.linux;
const policy = @import("policy.zig");
const spec_store = @import("spec_store.zig");
const vm_client = @import("vm_client.zig");

pub const State = enum(u8) {
    absent,
    starting,
    ready,
    failed,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .absent => "absent",
            .starting => "starting",
            .ready => "ready",
            .failed => "failed",
        };
    }

    pub fn parse(text: []const u8) ?State {
        inline for (@typeInfo(State).@"enum".fields) |field| {
            const value: State = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, value.name())) return value;
        }
        return null;
    }
};

pub const default_sweep_interval_ms: u32 = 15_000;
pub const default_backoff_base_ms: i64 = 1_000;

pub const Config = struct {
    root: []const u8,
    base_image: []const u8,
    kernel: []const u8,
    fc_bin: []const u8 = "firecracker",
    mem_mib: u32 = vm_client.default_mem_mib,
    vcpus: u32 = vm_client.default_vcpus,
    boot_timeout_ms: u32 = vm_client.boot_timeout_ms,
    /// A VMM that has not answered `hello` within this window is `failed`, so
    /// a guest that never comes up cannot read as `starting` forever.
    hello_deadline_ms: i64 = 30_000,
    backoff_base_ms: i64 = default_backoff_base_ms,
    backoff_max_ms: i64 = 60_000,
    stop_timeout_ms: u32 = 5_000,
};

/// The retry delay after `attempts` consecutive failures: exponential from the
/// base, capped. `attempts` is 1-based, so the first failure waits one base.
pub fn backoffMs(attempts: u32, config: Config) i64 {
    if (attempts == 0) return 0;
    var delay = config.backoff_base_ms;
    var n: u32 = 1;
    while (n < attempts and delay < config.backoff_max_ms) : (n += 1) {
        delay = @min(delay * 2, config.backoff_max_ms);
    }
    return delay;
}

pub const Observation = struct {
    pid: i64 = 0,
    pid_alive: bool = false,
    socket_owned: bool = false,
    hello_answered: bool = false,
    recorded: State = .absent,
    attempts: u32 = 0,
    retry_at_ms: i64 = 0,
    /// When the current attempt started, so the hello deadline has an origin.
    since_ms: i64 = 0,
    now_ms: i64 = 0,
};

pub const Reason = enum {
    /// A VMM the daemon has no pid for is listening on `api.sock`. Unlinking
    /// it would put a second VMM on one disk, so this is refused, not repaired.
    socket_owned_by_unrecorded_vmm,
    guest_never_answered_hello,
    backing_off,
};

pub const Refusal = struct {
    reason: Reason,
    message: []const u8,
    retry_at_ms: i64,
};

pub const Decision = union(enum) {
    absent,
    adopt: i64,
    await_hello: i64,
    boot,
    reclaim_then_boot,
    refuse: Refusal,
};

/// A live socket nobody recorded outranks every other reading: it is the one
/// state where acting would corrupt a workspace.
pub fn decide(obs: Observation, config: Config) Decision {
    const live_pid = obs.pid != 0 and obs.pid_alive;
    if (obs.socket_owned and !live_pid) {
        return refuse(.socket_owned_by_unrecorded_vmm, obs, config, "api.sock is owned by a VMM this daemon has no pid for");
    }
    if (live_pid) {
        if (obs.hello_answered) return .{ .adopt = obs.pid };
        if (obs.since_ms != 0 and obs.now_ms - obs.since_ms >= config.hello_deadline_ms) {
            return refuse(.guest_never_answered_hello, obs, config, "the guest never answered hello");
        }
        return .{ .await_hello = obs.pid };
    }
    if (obs.recorded == .failed and obs.now_ms < obs.retry_at_ms) {
        return refuse(.backing_off, obs, config, "the last attempt failed; waiting before the next");
    }
    if (obs.pid != 0) return .reclaim_then_boot;
    return .boot;
}

fn refuse(reason: Reason, obs: Observation, config: Config, message: []const u8) Decision {
    const retry_at = if (reason == .backing_off)
        obs.retry_at_ms
    else
        obs.now_ms + backoffMs(obs.attempts + 1, config);
    return .{ .refuse = .{ .reason = reason, .message = message, .retry_at_ms = retry_at } };
}

/// One workspace's state, as the daemon persists it under the workspace dir.
pub const Record = struct {
    state: State = .absent,
    pid: i64 = 0,
    last_error: []const u8 = "",
    attempts: u32 = 0,
    retry_at_ms: i64 = 0,
    since_ms: i64 = 0,

    /// Every `Record` owns `last_error`, empty or not, so a caller can always
    /// free it and a static string is never passed to the allocator.
    pub fn deinit(self: *const Record, allocator: std.mem.Allocator) void {
        allocator.free(self.last_error);
    }
};

/// The state file is one `key=value` per line, and every key is optional: a
/// truncated or unknown file degrades to `absent` instead of failing a lookup.
pub fn parseRecord(allocator: std.mem.Allocator, text: []const u8) !Record {
    var record = Record{ .last_error = try allocator.dupe(u8, "") };
    errdefer allocator.free(record.last_error);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t\r");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (std.mem.eql(u8, key, "state")) {
            record.state = State.parse(value) orelse .absent;
        } else if (std.mem.eql(u8, key, "pid")) {
            record.pid = std.fmt.parseInt(i64, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "error")) {
            const replaced = try allocator.dupe(u8, value);
            allocator.free(record.last_error);
            record.last_error = replaced;
        } else if (std.mem.eql(u8, key, "attempts")) {
            record.attempts = std.fmt.parseInt(u32, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "retry_at_ms")) {
            record.retry_at_ms = std.fmt.parseInt(i64, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "since_ms")) {
            record.since_ms = std.fmt.parseInt(i64, value, 10) catch 0;
        }
    }
    return record;
}

/// A newline inside an error message would forge a second line, so the writer
/// folds every control character into a space.
pub fn renderRecord(allocator: std.mem.Allocator, record: Record) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "state={s}\n", .{record.state.name()});
    try out.print(allocator, "pid={d}\n", .{record.pid});
    try out.print(allocator, "attempts={d}\n", .{record.attempts});
    try out.print(allocator, "retry_at_ms={d}\n", .{record.retry_at_ms});
    try out.print(allocator, "since_ms={d}\n", .{record.since_ms});
    try out.appendSlice(allocator, "error=");
    for (record.last_error) |ch| {
        try out.append(allocator, if (ch < 0x20 or ch == 0x7f) ' ' else ch);
    }
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

// ─── the effectful shell: real time, real pids, real sockets ────────────

/// Every non-deterministic input the shell uses is a field here, so a test can
/// replace one and leave the rest real.
pub const Env = struct {
    ctx: *anyopaque = undefined,
    nowMs: *const fn (ctx: *anyopaque) i64 = realNowMs,
    pidAlive: *const fn (ctx: *anyopaque, pid: i64) bool = realPidAlive,
    socketOwned: *const fn (ctx: *anyopaque, path: []const u8) bool = realSocketOwned,
    helloAnswered: *const fn (ctx: *anyopaque, layout: vm_client.Layout) bool = realHelloAnswered,
    kill: *const fn (ctx: *anyopaque, pid: i64) void = realKill,
    waitGone: *const fn (ctx: *anyopaque, pid: i64, timeout_ms: u32) bool = realWaitGone,
    boot: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, spec: vm_client.Spec) anyerror!i64 = realBoot,
    waitReady: *const fn (ctx: *anyopaque, layout: vm_client.Layout, timeout_ms: u32) anyerror!void = realWaitReady,
    /// Blocking `flock` on the workspace directory: two callers must not bind
    /// one disk. `tryLock` is the sweeper's, and skips a workspace in flight.
    lock: *const fn (ctx: *anyopaque, dir: []const u8) anyerror!i64 = realLock,
    tryLock: *const fn (ctx: *anyopaque, dir: []const u8) ?i64 = realTryLock,
    unlock: *const fn (ctx: *anyopaque, fd: i64) void = realUnlock,
};

pub const Error = error{ StateFileFailed, ReadDirFailed };

pub const Reconciler = struct {
    allocator: std.mem.Allocator,
    config: Config,
    env: Env = .{},

    pub fn init(allocator: std.mem.Allocator, config: Config) Reconciler {
        return .{ .allocator = allocator, .config = config };
    }

    /// The size this workspace boots with: its own record when it has one,
    /// the manager's defaults otherwise.
    pub fn specFor(self: *const Reconciler, workspace_id: []const u8) vm_client.Spec {
        const override = spec_store.read(self.config.root, workspace_id);
        return .{
            .workspace_id = workspace_id,
            .base_image = self.config.base_image,
            .kernel = self.config.kernel,
            .fc_bin = self.config.fc_bin,
            .root = self.config.root,
            .mem_mib = override.mem_mib orelse self.config.mem_mib,
            .vcpus = override.vcpus orelse self.config.vcpus,
        };
    }

    pub fn layoutFor(self: *const Reconciler, allocator: std.mem.Allocator, workspace_id: []const u8) !vm_client.Layout {
        return vm_client.layoutFor(allocator, self.specFor(workspace_id));
    }

    /// The persisted record, without probing anything.
    pub fn read(self: *const Reconciler, allocator: std.mem.Allocator, workspace_id: []const u8) !Record {
        const layout = try self.layoutFor(allocator, workspace_id);
        defer layout.deinit(allocator);
        return readRecord(allocator, layout);
    }

    /// What the workspace's VM is doing right now, repairing only what is
    /// provably dead. A workspace somebody else is booting is reported as it
    /// stands rather than fought over.
    pub fn observe(self: *const Reconciler, allocator: std.mem.Allocator, workspace_id: []const u8) !Record {
        const layout = try self.layoutFor(allocator, workspace_id);
        defer layout.deinit(allocator);
        try vm_client.ensureWorkspaceDir(layout);

        const fd = self.env.tryLock(self.env.ctx, layout.dir) orelse return readRecord(allocator, layout);
        defer self.env.unlock(self.env.ctx, fd);
        return self.observeLocked(allocator, layout);
    }

    /// A workspace whose VM is up and ready, booted only when the decision says
    /// nothing is running and no backoff is in force.
    pub fn request(self: *const Reconciler, allocator: std.mem.Allocator, workspace_id: []const u8) !Record {
        const layout = try self.layoutFor(allocator, workspace_id);
        defer layout.deinit(allocator);
        try vm_client.ensureWorkspaceDir(layout);

        const fd = try self.env.lock(self.env.ctx, layout.dir);
        defer self.env.unlock(self.env.ctx, fd);

        const observed = try self.observeLocked(allocator, layout);
        defer observed.deinit(allocator);
        const attempts = observed.attempts;
        const since = observed.since_ms;
        switch (observed.state) {
            .ready, .failed => return copy(allocator, observed),
            .starting => return self.awaitHello(allocator, layout, attempts, since, observed.pid),
            .absent => {
                const started = try self.boot(allocator, workspace_id, layout, attempts + 1);
                if (started.state == .failed) return started;
                defer started.deinit(allocator);
                return self.awaitHello(allocator, layout, started.attempts, started.since_ms, started.pid);
            },
        }
    }

    /// Stop-on-request. The sockets go only once nothing owns them, so a VMM
    /// the daemon cannot account for keeps its workspace.
    pub fn stop(self: *const Reconciler, allocator: std.mem.Allocator, workspace_id: []const u8) !Record {
        const layout = try self.layoutFor(allocator, workspace_id);
        defer layout.deinit(allocator);
        try vm_client.ensureWorkspaceDir(layout);

        const fd = try self.env.lock(self.env.ctx, layout.dir);
        defer self.env.unlock(self.env.ctx, fd);

        const pid = vm_client.readPid(layout) orelse 0;
        var ended = true;
        if (pid != 0 and self.env.pidAlive(self.env.ctx, pid)) {
            vm_client.clearPid(layout);
            self.env.kill(self.env.ctx, pid);
            ended = self.env.waitGone(self.env.ctx, pid, self.config.stop_timeout_ms);
        }
        const record = if (self.env.socketOwned(self.env.ctx, layout.api_sock))
            try self.fail(allocator, layout, 0, 0, if (ended)
                "a VMM this daemon has no pid for still owns api.sock"
            else
                "the VMM did not exit within the stop timeout; its sockets were left alone")
        else blk: {
            reclaim(layout);
            break :blk try absentRecord(allocator);
        };
        try self.writeRecord(layout, record);
        return record;
    }

    /// Every workspace under this root, by id.
    pub fn workspaceIds(self: *const Reconciler, allocator: std.mem.Allocator) ![][]u8 {
        const root = try std.fmt.allocPrint(allocator, "{s}/workspaces", .{self.config.root});
        defer allocator.free(root);

        var names: std.ArrayList([]u8) = .empty;
        defer freeNames(allocator, &names);
        listDirs(allocator, root, &names) catch |err| switch (err) {
            error.FileNotFound => return try allocator.alloc([]u8, 0),
            else => return err,
        };

        var ids: std.ArrayList([]u8) = .empty;
        errdefer freeNames(allocator, &ids);
        for (names.items) |name| {
            if (!policy.workspaceIdValid(name)) continue;
            try ids.append(allocator, try allocator.dupe(u8, name));
        }
        return ids.toOwnedSlice(allocator);
    }

    /// Every workspace VM under this root, stopped. A manager that is going
    /// down takes the VMs it owns with it.
    pub fn stopAll(self: *const Reconciler, allocator: std.mem.Allocator) !u32 {
        const ids = try self.workspaceIds(allocator);
        defer freeWorkspaceIds(allocator, ids);
        var stopped: u32 = 0;
        for (ids) |id| {
            const layout = try self.layoutFor(allocator, id);
            defer layout.deinit(allocator);
            const was_running = vm_client.readPid(layout) != null;
            const record = try self.stop(allocator, id);
            defer record.deinit(allocator);
            if (was_running and record.state == .absent) stopped += 1;
        }
        return stopped;
    }

    /// One pass over every workspace on this box: reclaim the dead, mark the
    /// ones that failed, leave the busy alone.
    pub fn sweep(self: *const Reconciler, allocator: std.mem.Allocator) !Sweep {
        const root = try std.fmt.allocPrint(allocator, "{s}/workspaces", .{self.config.root});
        defer allocator.free(root);

        var names: std.ArrayList([]u8) = .empty;
        defer freeNames(allocator, &names);
        listDirs(allocator, root, &names) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };

        var report = Sweep{};
        for (names.items) |name| {
            if (!policy.workspaceIdValid(name)) continue;
            const record = self.observe(allocator, name) catch continue;
            defer record.deinit(allocator);
            report.count(record.state);
        }
        return report;
    }

    fn observeLocked(self: *const Reconciler, allocator: std.mem.Allocator, layout: vm_client.Layout) !Record {
        const prior = try readRecord(allocator, layout);
        defer prior.deinit(allocator);

        const pid = vm_client.readPid(layout) orelse 0;
        const alive = pid != 0 and self.env.pidAlive(self.env.ctx, pid);
        var obs = Observation{
            .pid = pid,
            .pid_alive = alive,
            .socket_owned = self.env.socketOwned(self.env.ctx, layout.api_sock),
            .recorded = prior.state,
            .attempts = prior.attempts,
            .retry_at_ms = prior.retry_at_ms,
            .since_ms = prior.since_ms,
            .now_ms = self.env.nowMs(self.env.ctx),
        };
        if (alive) obs.hello_answered = self.env.helloAnswered(self.env.ctx, layout);

        const decision = decide(obs, self.config);
        if (decision == .reclaim_then_boot) reclaim(layout);

        const record = switch (decision) {
            .absent, .boot, .reclaim_then_boot => Record{
                .state = .absent,
                .pid = pid,
                .attempts = prior.attempts,
                .retry_at_ms = prior.retry_at_ms,
                .since_ms = prior.since_ms,
                .last_error = try allocator.dupe(u8, prior.last_error),
            },
            .adopt => |live| Record{
                .state = .ready,
                .pid = live,
                .attempts = prior.attempts,
                .since_ms = prior.since_ms,
                .last_error = try allocator.dupe(u8, ""),
            },
            .await_hello => |live| Record{
                .state = .starting,
                .pid = live,
                .attempts = prior.attempts,
                .since_ms = if (prior.since_ms != 0) prior.since_ms else obs.now_ms,
                .last_error = try allocator.dupe(u8, ""),
            },
            .refuse => |r| Record{
                .state = .failed,
                .pid = pid,
                .last_error = try allocator.dupe(u8, r.message),
                .attempts = prior.attempts + 1,
                .retry_at_ms = r.retry_at_ms,
                .since_ms = prior.since_ms,
            },
        };
        try self.writeRecord(layout, record);
        return record;
    }

    fn awaitHello(self: *const Reconciler, allocator: std.mem.Allocator, layout: vm_client.Layout, attempts: u32, since_ms: i64, pid: i64) !Record {
        self.env.waitReady(self.env.ctx, layout, self.config.boot_timeout_ms) catch
            return self.fail(allocator, layout, attempts, since_ms, "the guest never answered hello");
        const record = Record{
            .state = .ready,
            .pid = pid,
            .attempts = attempts,
            .since_ms = since_ms,
            .last_error = try allocator.dupe(u8, ""),
        };
        try self.writeRecord(layout, record);
        return record;
    }

    fn boot(self: *const Reconciler, allocator: std.mem.Allocator, workspace_id: []const u8, layout: vm_client.Layout, attempts: u32) !Record {
        const now = self.env.nowMs(self.env.ctx);
        const pid = self.env.boot(self.env.ctx, allocator, self.specFor(workspace_id)) catch |err|
            return self.fail(allocator, layout, attempts, now, @errorName(err));
        const record = Record{
            .state = .starting,
            .pid = pid,
            .attempts = attempts,
            .since_ms = now,
            .last_error = try allocator.dupe(u8, ""),
        };
        try self.writeRecord(layout, record);
        return record;
    }

    fn fail(self: *const Reconciler, allocator: std.mem.Allocator, layout: vm_client.Layout, attempts: u32, since_ms: i64, message: []const u8) !Record {
        const record = Record{
            .state = .failed,
            .pid = vm_client.readPid(layout) orelse 0,
            .last_error = try allocator.dupe(u8, message),
            .attempts = attempts,
            .retry_at_ms = self.env.nowMs(self.env.ctx) + backoffMs(attempts, self.config),
            .since_ms = since_ms,
        };
        try self.writeRecord(layout, record);
        return record;
    }

    fn readRecord(allocator: std.mem.Allocator, layout: vm_client.Layout) !Record {
        const path = try statePath(allocator, layout);
        defer allocator.free(path);
        var buf: [4096]u8 = undefined;
        const n = readFile(path, &buf) orelse return absentRecord(allocator);
        return parseRecord(allocator, buf[0..n]);
    }

    fn writeRecord(self: *const Reconciler, layout: vm_client.Layout, record: Record) !void {
        const path = try statePath(self.allocator, layout);
        defer self.allocator.free(path);
        const staged = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(staged);
        const text = try renderRecord(self.allocator, record);
        defer self.allocator.free(text);
        if (!writeFile(staged, text)) return Error.StateFileFailed;
        if (!renameFile(staged, path)) return Error.StateFileFailed;
    }

    fn statePath(allocator: std.mem.Allocator, layout: vm_client.Layout) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/vmd.state", .{layout.dir});
    }
};

pub const Sweep = struct {
    workspaces: u32 = 0,
    ready: u32 = 0,
    starting: u32 = 0,
    absent: u32 = 0,
    failed: u32 = 0,

    pub fn count(self: *Sweep, state: State) void {
        self.workspaces += 1;
        switch (state) {
            .ready => self.ready += 1,
            .starting => self.starting += 1,
            .absent => self.absent += 1,
            .failed => self.failed += 1,
        }
    }
};

fn absentRecord(allocator: std.mem.Allocator) !Record {
    return .{ .state = .absent, .last_error = try allocator.dupe(u8, "") };
}

fn copy(allocator: std.mem.Allocator, record: Record) !Record {
    var out = record;
    out.last_error = try allocator.dupe(u8, record.last_error);
    return out;
}

/// Only the sockets of a VMM proven dead: the pid is gone and nothing accepts
/// on `api.sock`. Firecracker refuses to rebind an existing socket file.
fn reclaim(layout: vm_client.Layout) void {
    remove(layout.api_sock);
    remove(layout.vsock_sock);
    vm_client.clearPid(layout);
}

// ─── raw file access: the daemon carries no Io to borrow ────────────────

fn readFile(path: []const u8, buf: []u8) ?usize {
    var path_buf: [4096]u8 = undefined;
    const z = vm_client.cstr(path, &path_buf) orelse return null;
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < buf.len) {
        const n = linux.read(fd, buf.ptr + off, buf.len - off);
        if (linux.errno(n) != .SUCCESS) return null;
        if (n == 0) break;
        off += n;
    }
    return off;
}

fn writeFile(path: []const u8, bytes: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const z = vm_client.cstr(path, &path_buf) orelse return false;
    const rc = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return false;
        off += n;
    }
    return true;
}

/// `rename(2)` inside one directory, so a reader sees the old record or the new
/// one and never a half-written file.
fn renameFile(from: []const u8, to: []const u8) bool {
    var from_buf: [4096]u8 = undefined;
    var to_buf: [4096]u8 = undefined;
    const a = vm_client.cstr(from, &from_buf) orelse return false;
    const b = vm_client.cstr(to, &to_buf) orelse return false;
    return linux.errno(linux.rename(a, b)) == .SUCCESS;
}

fn remove(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    const z = vm_client.cstr(path, &buf) orelse return;
    _ = linux.unlink(z);
}

fn openDirFd(dir: []const u8) ?linux.fd_t {
    var buf: [4096]u8 = undefined;
    const z = vm_client.cstr(dir, &buf) orelse return null;
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// `getdents64`, because the daemon carries no `Io` for `std.Io.Dir`. Only the
/// directory names come back.
fn listDirs(allocator: std.mem.Allocator, dir: []const u8, out: *std.ArrayList([]u8)) !void {
    const fd = openDirFd(dir) orelse return error.FileNotFound;
    defer _ = linux.close(fd);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return Error.ReadDirFailed;
        if (n == 0) return;
        var off: usize = 0;
        while (off < n) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&buf[off]);
            const reclen = entry.reclen;
            if (reclen == 0) return;
            if (entry.type == dt_dir) {
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
                if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                    try out.append(allocator, try allocator.dupe(u8, name));
                }
            }
            off += reclen;
        }
    }
}

fn freeNames(allocator: std.mem.Allocator, names: *std.ArrayList([]u8)) void {
    for (names.items) |name| allocator.free(name);
    names.deinit(allocator);
}

pub fn freeWorkspaceIds(allocator: std.mem.Allocator, ids: [][]u8) void {
    for (ids) |id| allocator.free(id);
    allocator.free(ids);
}

const dt_dir: u8 = 4;

// ─── the real inputs ─────────────────────────────────────────────────────

fn realNowMs(_: *anyopaque) i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn realPidAlive(_: *anyopaque, pid: i64) bool {
    const err = linux.errno(linux.syscall2(.kill, @intCast(pid), 0));
    return err == .SUCCESS or err == .PERM;
}

/// A connect that succeeds is the only evidence a socket has an owner: the
/// socket file itself outlives the VMM that made it.
fn realSocketOwned(_: *anyopaque, path: []const u8) bool {
    const fd = vm_client.connectUnix(path) catch return false;
    _ = linux.close(fd);
    return true;
}

fn realHelloAnswered(_: *anyopaque, layout: vm_client.Layout) bool {
    return vm_client.helloOnce(layout);
}

fn realKill(_: *anyopaque, pid: i64) void {
    _ = linux.kill(@intCast(pid), linux.SIG.KILL);
}

fn realWaitGone(_: *anyopaque, pid: i64, timeout_ms: u32) bool {
    return vm_client.waitGone(@intCast(pid), timeout_ms);
}

fn realBoot(_: *anyopaque, allocator: std.mem.Allocator, spec: vm_client.Spec) anyerror!i64 {
    var vm = try vm_client.boot(allocator, spec);
    const pid = vm.pid;
    vm.deinit();
    return pid;
}

fn realWaitReady(_: *anyopaque, layout: vm_client.Layout, timeout_ms: u32) anyerror!void {
    return vm_client.waitReady(layout, timeout_ms);
}

fn realLock(_: *anyopaque, dir: []const u8) anyerror!i64 {
    const fd = openDirFd(dir) orelse return Error.StateFileFailed;
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.flock(fd, std.posix.LOCK.EX)) != .SUCCESS) return Error.StateFileFailed;
    return fd;
}

fn realTryLock(_: *anyopaque, dir: []const u8) ?i64 {
    const fd = openDirFd(dir) orelse return null;
    if (linux.errno(linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB)) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

fn realUnlock(_: *anyopaque, fd: i64) void {
    _ = linux.close(@intCast(fd));
}

// ─── tests: the decision table, then the shell over a real directory ─────

const Fake = struct {
    now: i64 = 1_000_000,
    alive: bool = false,
    owned: bool = false,
    hello: bool = false,
    kills: u32 = 0,
    boots: u32 = 0,
    ready: bool = true,
    boot_error: bool = false,
    boot_pid: i64 = 777,
    /// The pids the fake reports as running. Empty means "every pid runs",
    /// which is what the single-workspace cases want.
    live: [8]i64 = .{0} ** 8,
    live_count: usize = 0,

    fn markLive(self: *Fake, pid: i64) void {
        self.live[self.live_count] = pid;
        self.live_count += 1;
    }

    fn me(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }
    fn nowMs(ctx: *anyopaque) i64 {
        return me(ctx).now;
    }
    fn pidAlive(ctx: *anyopaque, pid: i64) bool {
        const fake = me(ctx);
        if (fake.live_count == 0) return fake.alive;
        for (fake.live[0..fake.live_count]) |live| {
            if (live == pid) return true;
        }
        return false;
    }
    fn socketOwned(ctx: *anyopaque, _: []const u8) bool {
        return me(ctx).owned;
    }
    fn helloAnswered(ctx: *anyopaque, _: vm_client.Layout) bool {
        return me(ctx).hello;
    }
    fn kill(ctx: *anyopaque, pid: i64) void {
        const fake = me(ctx);
        fake.kills += 1;
        fake.alive = false;
        for (fake.live[0..fake.live_count], 0..) |live, i| {
            if (live != pid) continue;
            fake.live[i] = fake.live[fake.live_count - 1];
            fake.live_count -= 1;
            break;
        }
    }
    fn waitGone(_: *anyopaque, _: i64, _: u32) bool {
        return true;
    }
    fn boot(ctx: *anyopaque, _: std.mem.Allocator, _: vm_client.Spec) anyerror!i64 {
        me(ctx).boots += 1;
        if (me(ctx).boot_error) return error.SpawnFailed;
        return me(ctx).boot_pid;
    }
    fn waitReady(ctx: *anyopaque, _: vm_client.Layout, _: u32) anyerror!void {
        if (!me(ctx).ready) return error.Timeout;
    }
};

fn testReconciler(fake: *Fake, root: []const u8) Reconciler {
    var rec = Reconciler.init(std.testing.allocator, .{
        .root = root,
        .base_image = "/img/base.ext4",
        .kernel = "/img/vmlinux",
    });
    rec.env = .{
        .ctx = @ptrCast(fake),
        .nowMs = Fake.nowMs,
        .pidAlive = Fake.pidAlive,
        .socketOwned = Fake.socketOwned,
        .helloAnswered = Fake.helloAnswered,
        .kill = Fake.kill,
        .waitGone = Fake.waitGone,
        .boot = Fake.boot,
        .waitReady = Fake.waitReady,
        .lock = realLock,
        .tryLock = realTryLock,
        .unlock = realUnlock,
    };
    return rec;
}

/// A workspace on the real filesystem, because the pid file, the state file and
/// the socket files ARE the reconciler's inputs. Named per test, so two tests
/// in one binary cannot share it.
const Scratch = struct {
    allocator: std.mem.Allocator,
    root: []u8,

    fn init(comptime name: []const u8) !Scratch {
        const allocator = std.testing.allocator;
        const base = "/tmp";
        const root = try std.fmt.allocPrint(allocator, "{s}/pabrik-vmd-{d}-{s}", .{ base, linux.getpid(), name });
        try mkdirOne(root);
        const workspaces = try std.fmt.allocPrint(allocator, "{s}/workspaces", .{root});
        defer allocator.free(workspaces);
        try mkdirOne(workspaces);
        return .{ .allocator = allocator, .root = root };
    }

    fn deinit(self: *Scratch) void {
        removeTree(self.allocator, self.root);
        self.allocator.free(self.root);
    }

    fn workspaceDir(self: *Scratch, id: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/workspaces/{s}", .{ self.root, id });
    }

    fn write(self: *Scratch, id: []const u8, name: []const u8, text: []const u8) !void {
        const base = try self.workspaceDir(id);
        defer self.allocator.free(base);
        mkdirOne(base) catch {};
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base, name });
        defer self.allocator.free(path);
        try std.testing.expect(writeFile(path, text));
    }

    fn exists(self: *Scratch, id: []const u8, name: []const u8) !bool {
        const base = try self.workspaceDir(id);
        defer self.allocator.free(base);
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base, name });
        defer self.allocator.free(path);
        var buf: [16]u8 = undefined;
        return readFile(path, &buf) != null;
    }
};

fn mkdirOne(path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const z = vm_client.cstr(path, &buf) orelse return Error.StateFileFailed;
    const rc = linux.mkdir(z, 0o755);
    if (linux.errno(rc) != .SUCCESS and linux.errno(rc) != .EXIST) return Error.StateFileFailed;
}

fn removeTree(allocator: std.mem.Allocator, path: []const u8) void {
    var names: std.ArrayList([]u8) = .empty;
    defer freeNames(allocator, &names);
    listDirs(allocator, path, &names) catch return;
    for (names.items) |name| {
        const child = std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name }) catch continue;
        defer allocator.free(child);
        removeTree(allocator, child);
    }
    var buf: [4096]u8 = undefined;
    if (vm_client.cstr(path, &buf)) |z| _ = linux.rmdir(z);
}

test "a workspace nobody booted is absent, and boots on request" {
    var scratch = try Scratch.init("absent");
    defer scratch.deinit();
    var fake = Fake{};
    const rec = testReconciler(&fake, scratch.root);
    const alloc = std.testing.allocator;

    const observed = try rec.observe(alloc, "demo");
    defer observed.deinit(alloc);
    try std.testing.expectEqual(State.absent, observed.state);
    try std.testing.expectEqual(@as(u32, 0), fake.boots);

    const requested = try rec.request(alloc, "demo");
    defer requested.deinit(alloc);
    try std.testing.expectEqual(State.ready, requested.state);
    try std.testing.expectEqual(@as(i64, 777), requested.pid);
    try std.testing.expectEqual(@as(u32, 1), fake.boots);
}

test "a dead VMM's sockets are reclaimed, so the next boot can bind" {
    var scratch = try Scratch.init("reclaim");
    defer scratch.deinit();
    try scratch.write("demo", "api.sock", "");
    try scratch.write("demo", "vsock.sock", "");
    try scratch.write("demo", "fc.pid", "4242\n");
    var fake = Fake{};
    const rec = testReconciler(&fake, scratch.root);
    const alloc = std.testing.allocator;

    const record = try rec.observe(alloc, "demo");
    defer record.deinit(alloc);
    try std.testing.expectEqual(State.absent, record.state);
    try std.testing.expect(!try scratch.exists("demo", "api.sock"));
    try std.testing.expect(!try scratch.exists("demo", "vsock.sock"));
    try std.testing.expect(!try scratch.exists("demo", "fc.pid"));
}

test "a socket an unrecorded VMM owns is refused, never unlinked" {
    var scratch = try Scratch.init("owned");
    defer scratch.deinit();
    try scratch.write("demo", "api.sock", "");
    var fake = Fake{ .owned = true };
    const rec = testReconciler(&fake, scratch.root);
    const alloc = std.testing.allocator;

    const record = try rec.observe(alloc, "demo");
    defer record.deinit(alloc);
    try std.testing.expectEqual(State.failed, record.state);
    try std.testing.expectEqualStrings("api.sock is owned by a VMM this daemon has no pid for", record.last_error);
    try std.testing.expect(try scratch.exists("demo", "api.sock"));
}

test "a live VMM that answers hello is adopted without a boot" {
    var scratch = try Scratch.init("adopt");
    defer scratch.deinit();
    try scratch.write("demo", "fc.pid", "4242\n");
    var fake = Fake{ .alive = true, .hello = true };
    const rec = testReconciler(&fake, scratch.root);
    const alloc = std.testing.allocator;

    const record = try rec.request(alloc, "demo");
    defer record.deinit(alloc);
    try std.testing.expectEqual(State.ready, record.state);
    try std.testing.expectEqual(@as(i64, 4242), record.pid);
    try std.testing.expectEqual(@as(u32, 0), fake.boots);
    try std.testing.expectEqual(@as(u32, 0), fake.kills);
}

test "a live VMM whose guest is still coming up is starting" {
    var scratch = try Scratch.init("starting");
    defer scratch.deinit();
    try scratch.write("demo", "fc.pid", "4242\n");
    var fake = Fake{ .alive = true, .now = 1_000_000 };
    const rec = testReconciler(&fake, scratch.root);
    const alloc = std.testing.allocator;

    const record = try rec.observe(alloc, "demo");
    defer record.deinit(alloc);
    try std.testing.expectEqual(State.starting, record.state);
    try std.testing.expectEqual(@as(i64, 4242), record.pid);
    try std.testing.expectEqual(@as(i64, 1_000_000), record.since_ms);
}

test "a guest that never answers hello fails after its deadline" {
    var scratch = try Scratch.init("deadline");
    defer scratch.deinit();
    try scratch.write("demo", "fc.pid", "4242\n");
    var fake = Fake{ .alive = true, .now = 1_000_000 };
    const rec = testReconciler(&fake, scratch.root);
    const alloc = std.testing.allocator;

    const first = try rec.observe(alloc, "demo");
    defer first.deinit(alloc);
    try std.testing.expectEqual(State.starting, first.state);

    fake.now += 31_000;
    const second = try rec.observe(alloc, "demo");
    defer second.deinit(alloc);
    try std.testing.expectEqual(State.failed, second.state);
    try std.testing.expectEqualStrings("the guest never answered hello", second.last_error);
    try std.testing.expect(second.retry_at_ms > fake.now);
}

test "a failed workspace is not booted again before its backoff elapses" {
    var scratch = try Scratch.init("backoff");
    defer scratch.deinit();
    var fake = Fake{ .now = 5_000_000 };
    const rec = testReconciler(&fake, scratch.root);
    const alloc = std.testing.allocator;

    const first = try rec.request(alloc, "demo");
    defer first.deinit(alloc);
    try std.testing.expectEqual(State.ready, first.state);

    fake.ready = false;
    fake.alive = true;
    fake.boot_pid = 900;
    const failed = try rec.request(alloc, "demo");
    defer failed.deinit(alloc);
    try std.testing.expectEqual(State.failed, failed.state);
    try std.testing.expectEqual(@as(u32, 2), fake.boots);
    try std.testing.expect(failed.retry_at_ms > fake.now);

    const held = try rec.request(alloc, "demo");
    defer held.deinit(alloc);
    try std.testing.expectEqual(State.failed, held.state);
    try std.testing.expectEqual(@as(u32, 2), fake.boots);
}

test "the decision names why a workspace is refused" {
    const config = Config{ .root = "/vm", .base_image = "b", .kernel = "k" };

    const owned = decide(.{ .socket_owned = true, .now_ms = 10 }, config);
    try std.testing.expectEqual(Reason.socket_owned_by_unrecorded_vmm, owned.refuse.reason);

    const late = decide(.{ .pid = 7, .pid_alive = true, .since_ms = 1, .now_ms = 40_000 }, config);
    try std.testing.expectEqual(Reason.guest_never_answered_hello, late.refuse.reason);

    const held = decide(.{ .recorded = .failed, .retry_at_ms = 99, .now_ms = 10 }, config);
    try std.testing.expectEqual(Reason.backing_off, held.refuse.reason);
}

test "backoff doubles per attempt and stops at the cap" {
    const config = Config{ .root = "/vm", .base_image = "b", .kernel = "k", .backoff_base_ms = 1_000, .backoff_max_ms = 8_000 };
    try std.testing.expectEqual(@as(i64, 0), backoffMs(0, config));
    try std.testing.expectEqual(@as(i64, 1_000), backoffMs(1, config));
    try std.testing.expectEqual(@as(i64, 2_000), backoffMs(2, config));
    try std.testing.expectEqual(@as(i64, 4_000), backoffMs(3, config));
    try std.testing.expectEqual(@as(i64, 8_000), backoffMs(4, config));
    try std.testing.expectEqual(@as(i64, 8_000), backoffMs(99, config));
}

test "a boot failure's backoff grows with every attempt" {
    var scratch = try Scratch.init("boot-backoff");
    defer scratch.deinit();
    var fake = Fake{ .now = 1_000, .boot_error = true };
    const rec = testReconciler(&fake, scratch.root);
    const alloc = std.testing.allocator;

    const first = try rec.request(alloc, "demo");
    defer first.deinit(alloc);
    try std.testing.expectEqual(State.failed, first.state);
    try std.testing.expectEqualStrings("SpawnFailed", first.last_error);
    try std.testing.expectEqual(@as(i64, 1_000), first.retry_at_ms - fake.now);

    fake.now = first.retry_at_ms;
    const second = try rec.request(alloc, "demo");
    defer second.deinit(alloc);
    try std.testing.expectEqual(State.failed, second.state);
    try std.testing.expectEqual(@as(i64, 2_000), second.retry_at_ms - fake.now);
    try std.testing.expectEqual(@as(u32, 2), fake.boots);
}

test "stop ends the VMM, clears its sockets and reports absent" {
    var scratch = try Scratch.init("stop");
    defer scratch.deinit();
    try scratch.write("demo", "fc.pid", "4242\n");
    try scratch.write("demo", "api.sock", "");
    var fake = Fake{ .alive = true };
    const rec = testReconciler(&fake, scratch.root);
    const alloc = std.testing.allocator;

    const record = try rec.stop(alloc, "demo");
    defer record.deinit(alloc);
    try std.testing.expectEqual(State.absent, record.state);
    try std.testing.expectEqual(@as(u32, 1), fake.kills);
    try std.testing.expect(!try scratch.exists("demo", "api.sock"));
    try std.testing.expect(!try scratch.exists("demo", "fc.pid"));
}

test "stop keeps a workspace whose socket an unaccounted VMM owns" {
    var scratch = try Scratch.init("stop-owned");
    defer scratch.deinit();
    try scratch.write("demo", "api.sock", "");
    var fake = Fake{ .owned = true };
    const rec = testReconciler(&fake, scratch.root);
    const alloc = std.testing.allocator;

    const record = try rec.stop(alloc, "demo");
    defer record.deinit(alloc);
    try std.testing.expectEqual(State.failed, record.state);
    try std.testing.expect(try scratch.exists("demo", "api.sock"));
}

test "a manager that is going down stops every workspace VM it owns" {
    var scratch = try Scratch.init("stop-all");
    defer scratch.deinit();
    try scratch.write("alpha", "fc.pid", "4242\n");
    try scratch.write("beta", "fc.pid", "4343\n");
    var fake = Fake{};
    fake.markLive(4242);
    fake.markLive(4343);
    const rec = testReconciler(&fake, scratch.root);
    const alloc = std.testing.allocator;

    const stopped = try rec.stopAll(alloc);
    try std.testing.expectEqual(@as(u32, 2), stopped);
    try std.testing.expectEqual(@as(u32, 2), fake.kills);
    try std.testing.expect(!try scratch.exists("alpha", "fc.pid"));
    try std.testing.expect(!try scratch.exists("beta", "fc.pid"));
}

test "a recorded state survives a restart, and an unknown one reads absent" {
    var scratch = try Scratch.init("state-file");
    defer scratch.deinit();
    var fake = Fake{};
    const rec = testReconciler(&fake, scratch.root);
    const alloc = std.testing.allocator;

    const text = try renderRecord(alloc, .{
        .state = .failed,
        .pid = 31,
        .last_error = "boot failed: SpawnFailed",
        .attempts = 3,
        .retry_at_ms = 99,
        .since_ms = 12,
    });
    defer alloc.free(text);
    try scratch.write("demo", "vmd.state", text);

    const read = try rec.read(alloc, "demo");
    defer read.deinit(alloc);
    try std.testing.expectEqual(State.failed, read.state);
    try std.testing.expectEqual(@as(i64, 31), read.pid);
    try std.testing.expectEqualStrings("boot failed: SpawnFailed", read.last_error);
    try std.testing.expectEqual(@as(u32, 3), read.attempts);
    try std.testing.expectEqual(@as(i64, 99), read.retry_at_ms);
    try std.testing.expectEqual(@as(i64, 12), read.since_ms);

    try scratch.write("other", "vmd.state", "state=who knows\npid=oops\n");
    const unknown = try rec.read(alloc, "other");
    defer unknown.deinit(alloc);
    try std.testing.expectEqual(State.absent, unknown.state);
    try std.testing.expectEqual(@as(i64, 0), unknown.pid);
}

test "a newline in an error message cannot forge a state line" {
    const alloc = std.testing.allocator;
    const text = try renderRecord(alloc, .{ .state = .failed, .last_error = "bad\nstate=ready", .pid = 5 });
    defer alloc.free(text);

    const record = try parseRecord(alloc, text);
    defer record.deinit(alloc);
    try std.testing.expectEqual(State.failed, record.state);
    try std.testing.expectEqualStrings("bad state=ready", record.last_error);
}

test "a sweep counts every workspace and skips names that are not ids" {
    var scratch = try Scratch.init("sweep");
    defer scratch.deinit();
    try scratch.write("live", "fc.pid", "11\n");
    try scratch.write("dead", "fc.pid", "12\n");
    try scratch.write("not a workspace id", "fc.pid", "13\n");
    var fake = Fake{};
    const rec = testReconciler(&fake, scratch.root);
    const alloc = std.testing.allocator;

    const report = try rec.sweep(alloc);
    try std.testing.expectEqual(@as(u32, 2), report.workspaces);
    try std.testing.expectEqual(@as(u32, 2), report.absent);
    try std.testing.expectEqual(@as(u32, 0), report.ready);
}

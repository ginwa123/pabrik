//! What a workspace's VM has been asked to do, as THIS daemon remembers it.
//! Memory-only on purpose: a fresh daemon that guessed would reap work it has
//! never seen, and a workspace with no entry here is never idle.

// The terminal needs no counter of its own: the guest pump asks the VM every
// 50 ms (`terminal_ws.zig`), so an attached tab already keeps `last_work_ms`
// fresh. Re-add an `open_ttys` count only if that pump becomes event-driven.

const std = @import("std");
const linux = std.os.linux;

/// How many workspaces may be tracked at once. Past the cap the least recently
/// used reading is dropped, and a dropped reading means "unknown", which means
/// "not idle": the reaper keeps a VM it cannot describe.
pub const max_entries: usize = 256;

/// Detached jobs remembered per workspace. More than this and the least
/// recently seen job is forgotten, which can only make a VM live longer.
pub const max_jobs: usize = 16;

/// The daemon's clock, the same one the reconciler reads: monotonic
/// milliseconds, so a wall-clock jump can neither stall nor force a reap.
pub fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// One detached job: the pid the GUEST reported for it, and when this daemon
/// last had news of it. `spawn` mints it, `probe` refreshes it.
pub const Job = struct {
    pid: i64 = 0,
    seen_ms: i64 = 0,
};

pub const Entry = struct {
    /// When the workspace was last asked for work. 0 means "nothing yet".
    last_work_ms: i64 = 0,
    /// Requests inside the daemon for this workspace right now.
    in_flight: u32 = 0,
    /// The VMM this workspace is running, as last seen. A new pid is a new
    /// guest, and every reading about the old one is void.
    last_pid: i64 = 0,
    jobs: [max_jobs]Job = [_]Job{.{}} ** max_jobs,
    job_count: usize = 0,
    /// The VMM's CPU clock at the last sample, so a sweep can take a delta.
    cpu_ticks: u64 = 0,
    cpu_seen: bool = false,
};

/// A reading for the reaper. Every field is something the daemon measured;
/// nothing here is inferred.
pub const Snapshot = struct {
    last_work_ms: i64,
    in_flight: u32,
    live_jobs: u32,
    /// Null when there is no earlier CPU sample to subtract, or when the VMM's
    /// clock went backwards (a recycled pid). Null is "cannot tell", never 0.
    cpu_delta_ms: ?u64,
};

fn trackJob(entry: *Entry, pid: i64, seen_ms: i64) void {
    for (entry.jobs[0..entry.job_count]) |*job| {
        if (job.pid != pid) continue;
        job.seen_ms = seen_ms;
        return;
    }
    if (entry.job_count < max_jobs) {
        entry.jobs[entry.job_count] = .{ .pid = pid, .seen_ms = seen_ms };
        entry.job_count += 1;
        return;
    }
    // Full: forget the job nobody has looked at longest. Forgetting can only
    // keep a VM up for longer than it must, never take one down early.
    var oldest: usize = 0;
    for (entry.jobs[0..entry.job_count], 0..) |job, i| {
        if (job.seen_ms < entry.jobs[oldest].seen_ms) oldest = i;
    }
    entry.jobs[oldest] = .{ .pid = pid, .seen_ms = seen_ms };
}

fn dropJob(entry: *Entry, pid: i64) void {
    var i: usize = 0;
    while (i < entry.job_count) : (i += 1) {
        if (entry.jobs[i].pid != pid) continue;
        entry.jobs[i] = entry.jobs[entry.job_count - 1];
        entry.job_count -= 1;
        return;
    }
}

fn dropJobAt(entry: *Entry, index: usize) void {
    if (index >= entry.job_count) return;
    entry.jobs[index] = entry.jobs[entry.job_count - 1];
    entry.job_count -= 1;
}

/// Every mutable reading for all workspaces this daemon serves. Allocated once
/// and shared by pointer: `Manager` is copied per connection (`daemon.zig`,
/// `serveConnection`), so a field that lived inside it would be per-caller.
pub const Activity = struct {
    allocator: std.mem.Allocator,
    /// A spin lock, like the rest of this daemon's shared registries: every
    /// critical section here is a hash-map lookup or a few integer store, so a
    /// waiter never spins for long enough to deserve a blocking primitive.
    lock: std.atomic.Mutex = .unlocked,
    map: std.StringHashMap(Entry),
    /// How many readings were dropped to stay under `max_entries`.
    evicted: u32 = 0,

    fn lockIt(self: *Activity) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlockIt(self: *Activity) void {
        self.lock.unlock();
    }

    pub fn init(allocator: std.mem.Allocator) Activity {
        return .{ .allocator = allocator, .map = std.StringHashMap(Entry).init(allocator) };
    }

    pub fn deinit(self: *Activity) void {
        var it = self.map.iterator();
        while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.map.deinit();
    }

    /// The map owns its keys, so the caller's arena can end with the request.
    fn findOrCreate(self: *Activity, workspace_id: []const u8) ?*Entry {
        if (self.map.getPtr(workspace_id)) |entry| return entry;
        if (self.map.count() >= max_entries) self.evictOldest();
        const key = self.allocator.dupe(u8, workspace_id) catch return null;
        self.map.put(key, .{}) catch {
            self.allocator.free(key);
            return null;
        };
        return self.map.getPtr(key);
    }

    fn evictOldest(self: *Activity) void {
        var oldest_key: ?[]const u8 = null;
        var oldest: i64 = std.math.maxInt(i64);
        var it = self.map.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.last_work_ms >= oldest) continue;
            oldest = kv.value_ptr.last_work_ms;
            oldest_key = kv.key_ptr.*;
        }
        const key = oldest_key orelse return;
        if (self.map.fetchRemove(key)) |removed| self.allocator.free(removed.key);
        self.evicted += 1;
    }

    /// A request that carries work has started.
    pub fn enter(self: *Activity, workspace_id: []const u8, now_ms: i64) void {
        self.lockIt();
        defer self.unlockIt();
        const entry = self.findOrCreate(workspace_id) orelse return;
        entry.last_work_ms = now_ms;
        entry.in_flight += 1;
    }

    /// …and has finished, answered or not: a failed call is still a call, and
    /// the sweep right after it must not read the VM as abandoned.
    pub fn leave(self: *Activity, workspace_id: []const u8, now_ms: i64) void {
        self.lockIt();
        defer self.unlockIt();
        const entry = self.findOrCreate(workspace_id) orelse return;
        if (entry.in_flight > 0) entry.in_flight -= 1;
        entry.last_work_ms = now_ms;
    }

    /// A detached job was started in the workspace's guest.
    pub fn addJob(self: *Activity, workspace_id: []const u8, pid: i64, now_ms: i64) void {
        if (pid <= 0) return;
        self.lockIt();
        defer self.unlockIt();
        const entry = self.findOrCreate(workspace_id) orelse return;
        entry.last_work_ms = now_ms;
        trackJob(entry, pid, now_ms);
    }

    /// A `probe` said the job is gone. The VM may now be idle because of it.
    pub fn jobExited(self: *Activity, workspace_id: []const u8, pid: i64) void {
        self.lockIt();
        defer self.unlockIt();
        const entry = self.map.getPtr(workspace_id) orelse return;
        dropJob(entry, pid);
    }

    /// A fresh VMM: every tty and every spawned pid died with the old one, so
    /// the readings start from zero. False when the pid did not change, which
    /// is the warm path. `in_flight` is balanced by enter/leave, never here.
    pub fn notePid(self: *Activity, workspace_id: []const u8, pid: i64, now_ms: i64) bool {
        self.lockIt();
        defer self.unlockIt();
        const entry = self.findOrCreate(workspace_id) orelse return false;
        if (entry.last_pid == pid) return false;
        entry.last_pid = pid;
        entry.last_work_ms = now_ms;
        entry.job_count = 0;
        entry.cpu_ticks = 0;
        entry.cpu_seen = false;
        return true;
    }

    /// The workspace's VM is gone on purpose: its readings die with it.
    pub fn forget(self: *Activity, workspace_id: []const u8) void {
        self.lockIt();
        defer self.unlockIt();
        if (self.map.fetchRemove(workspace_id)) |removed| self.allocator.free(removed.key);
    }

    /// One workspace's reading, taking the fresh CPU clock in the same pass.
    /// Null means "this daemon knows nothing", which is never idle. A job
    /// nobody has watched for `job_trust_ms` is dropped before it is counted.
    pub fn sample(
        self: *Activity,
        workspace_id: []const u8,
        now_ms: i64,
        cpu_ticks: ?u64,
        job_trust_ms: i64,
    ) ?Snapshot {
        self.lockIt();
        defer self.unlockIt();
        const entry = self.map.getPtr(workspace_id) orelse return null;

        var i: usize = 0;
        while (i < entry.job_count) {
            if (now_ms - entry.jobs[i].seen_ms > job_trust_ms) {
                dropJobAt(entry, i);
                continue;
            }
            i += 1;
        }

        var delta: ?u64 = null;
        if (cpu_ticks) |ticks| {
            // USER_HZ is 100 on every Linux ABI — a frozen constant, not a
            // setting — so one tick is 10 ms and needs no sysconf.
            if (entry.cpu_seen and ticks >= entry.cpu_ticks) delta = (ticks - entry.cpu_ticks) * 10;
            entry.cpu_ticks = ticks;
            entry.cpu_seen = true;
        }

        if (entry.last_work_ms == 0) return null;
        return .{
            .last_work_ms = entry.last_work_ms,
            .in_flight = entry.in_flight,
            .live_jobs = @intCast(entry.job_count),
            .cpu_delta_ms = delta,
        };
    }
};

const testing = std.testing;

test "a request in flight moves the last-work clock and counts itself" {
    var act = Activity.init(testing.allocator);
    defer act.deinit();

    act.enter("ws_1", 1_000);
    const running = act.sample("ws_1", 1_000, null, 60_000).?;
    try testing.expectEqual(@as(i64, 1_000), running.last_work_ms);
    try testing.expectEqual(@as(u32, 1), running.in_flight);

    act.leave("ws_1", 1_500);
    const settled = act.sample("ws_1", 1_500, null, 60_000).?;
    try testing.expectEqual(@as(u32, 0), settled.in_flight);
    try testing.expectEqual(@as(i64, 1_500), settled.last_work_ms);
}

test "a leave without an enter cannot drive the counter below zero" {
    var act = Activity.init(testing.allocator);
    defer act.deinit();

    act.enter("ws_1", 10);
    act.leave("ws_1", 11);
    act.leave("ws_1", 12);
    try testing.expectEqual(@as(u32, 0), act.sample("ws_1", 12, null, 60_000).?.in_flight);
}

test "a detached job keeps the workspace live until it is reported gone" {
    var act = Activity.init(testing.allocator);
    defer act.deinit();

    act.addJob("ws_1", 900, 1_000);
    try testing.expectEqual(@as(u32, 1), act.sample("ws_1", 1_000, null, 60_000).?.live_jobs);

    act.jobExited("ws_1", 900);
    try testing.expectEqual(@as(u32, 0), act.sample("ws_1", 1_000, null, 60_000).?.live_jobs);
}

test "a job nobody has watched for a whole trust window is forgotten" {
    var act = Activity.init(testing.allocator);
    defer act.deinit();

    act.addJob("ws_1", 900, 1_000);
    try testing.expectEqual(@as(u32, 1), act.sample("ws_1", 2_000, null, 10_000).?.live_jobs);
    try testing.expectEqual(@as(u32, 0), act.sample("ws_1", 12_000, null, 10_000).?.live_jobs);
}

test "a boot forgets the jobs and the CPU sample it inherited" {
    var act = Activity.init(testing.allocator);
    defer act.deinit();

    act.addJob("ws_1", 900, 1_000);
    try testing.expectEqual(@as(?u64, null), act.sample("ws_1", 1_000, 5_000, 60_000).?.cpu_delta_ms);

    _ = act.notePid("ws_1", 4242, 2_000);
    const after = act.sample("ws_1", 2_000, 6_000, 60_000).?;
    try testing.expectEqual(@as(u32, 0), after.live_jobs);
    // The first sample after a reset has nothing to subtract, even though a
    // sample was taken before the boot.
    try testing.expectEqual(@as(?u64, null), after.cpu_delta_ms);
}

test "two CPU samples read as milliseconds of guest work" {
    var act = Activity.init(testing.allocator);
    defer act.deinit();

    act.enter("ws_1", 1_000);
    _ = act.sample("ws_1", 1_000, 1_000, 60_000);
    // 120 ticks = 1.2 s of CPU across the window, i.e. a busy guest.
    try testing.expectEqual(@as(?u64, 1_200), act.sample("ws_1", 16_000, 1_120, 60_000).?.cpu_delta_ms);
}

test "a pid whose clock went backwards is not a delta" {
    var act = Activity.init(testing.allocator);
    defer act.deinit();

    act.enter("ws_1", 1_000);
    _ = act.sample("ws_1", 1_000, 9_000, 60_000);
    // A recycled pid: the VMM restarted under the same number. Reporting the
    // difference would be a huge negative or a lie; "cannot tell" is neither.
    try testing.expectEqual(@as(?u64, null), act.sample("ws_1", 16_000, 40, 60_000).?.cpu_delta_ms);
}

test "an unreadable CPU clock is unknown, not zero" {
    var act = Activity.init(testing.allocator);
    defer act.deinit();

    act.enter("ws_1", 1_000);
    _ = act.sample("ws_1", 1_000, 1_000, 60_000);
    try testing.expectEqual(@as(?u64, null), act.sample("ws_1", 16_000, null, 60_000).?.cpu_delta_ms);
}

test "a workspace this daemon never served has no reading at all" {
    var act = Activity.init(testing.allocator);
    defer act.deinit();

    try testing.expect(act.sample("ws_never", 1_000, 10, 60_000) == null);
}

test "the map stays bounded and drops the least recently used reading" {
    var act = Activity.init(testing.allocator);
    defer act.deinit();

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < max_entries) : (i += 1) {
        const id = try std.fmt.bufPrint(&buf, "ws_{d}", .{i});
        act.enter(id, @intCast(1_000 + i));
    }
    // One more: the oldest reading (ws_0) makes room, and reads as unknown.
    act.enter("ws_new", 9_999);
    try testing.expect(act.sample("ws_0", 9_999, null, 60_000) == null);
    try testing.expect(act.sample("ws_new", 9_999, null, 60_000) != null);
    try testing.expectEqual(@as(u32, 1), act.evicted);
}

test "keys are copied, so the caller's arena may end with the request" {
    var act = Activity.init(testing.allocator);
    defer act.deinit();

    const scratch = try testing.allocator.alloc(u8, "ws_1234".len);
    defer testing.allocator.free(scratch);
    @memcpy(scratch, "ws_1234");
    act.enter(scratch, 1_000);
    @memset(scratch, 'x');

    try testing.expect(act.sample("ws_1234", 1_000, null, 60_000) != null);
}

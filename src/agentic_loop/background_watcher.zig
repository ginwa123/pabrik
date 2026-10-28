//! Immediate background-command completion watcher.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const logger_mod = pabrikcore.loggermod;
const event_bus_mod = pabrikcore.event_bus;
const bg_proc = pabrikcore.ai_mod.background_process;
const cleanup = pabrikcore.cleanup_stale_background_process;
const guest_jobs = @import("guest_jobs.zig");
// NOTE: neither `process_status` nor `shell_tool` is imported here any more —
// this module asks `bg_proc.isAlive`, which owns the reap-then-probe liveness
// question for every caller (the watcher, the boot sweep, the `process`
const migration = @import("../migrations/migration.zig");
const testing = std.testing;

/// Poll interval between `isProcessRunning` checks (production).
pub const watcher_poll_interval_ns: u64 = 2 * std.time.ns_per_s;
/// Cap on poll iterations (~24h at the default 2s interval). On expiry the
/// task exits silently — the cron is the fallback.
pub const watcher_max_iters: usize = 43200;

/// Cap for the SERVICE reaper.
pub const service_reaper_max_iters: usize = std.math.maxInt(usize);

/// Liveness that also REAPS.
fn stillRunning(pid: u32) bool {
    // Delegates to the registry's single implementation so the watcher, the
    // boot sweep and the `process` tool cannot drift on what "alive" means.
    return bg_proc.isAlive(pid);
}

/// One liveness answer, in the shape the guest loop consumes.
pub const GuestOutcome = struct {
    verdict: guest_jobs.Verdict,
    boot_pid: i64,
};

/// The guest probe, injectable so the loop below is proven without a manager.
pub const GuestProbeFn = *const fn (std.mem.Allocator, guest_jobs.GuestJob, ?i64) GuestOutcome;

fn defaultGuestProbe(allocator: std.mem.Allocator, job: guest_jobs.GuestJob, boot: ?i64) GuestOutcome {
    const reading = guest_jobs.probe(allocator, job, boot);
    return .{ .verdict = reading.verdict, .boot_pid = reading.boot_pid };
}

/// Testable core args — explicit handles (no singleton) so unit tests stay
/// hermetic (own :memory: DB, event_bus=null).
pub const WatchCoreArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    logger: ?*logger_mod.Logger,
    event_bus: ?*event_bus_mod.EventBus,
    session_id: []const u8,
    pid_num: u32,
    pid_str: []const u8,
    command: []const u8,
    log_path: []const u8,
    poll_interval_ns: u64 = watcher_poll_interval_ns,
    max_iters: usize = watcher_max_iters,
    /// true — `mode="background"`: queue the log and wake the session on
    /// exit. false — `mode="background_persistence"`: SILENT.
    notify: bool = true,
    /// Set for a job that runs in a workspace VM: its pid and its log are the
    /// guest's, so liveness is asked of the manager that owns that VM.
    guest: ?guest_jobs.GuestJob = null,
    /// Overrides the manager probe (test seam).
    probe: ?GuestProbeFn = null,
};

/// Poll a job through the manager until it ends or the cap hits. `ended` is
/// false only when the cap ran out — a job nobody could observe keeps its row.
fn watchGuestJob(args: *const WatchCoreArgs, job: guest_jobs.GuestJob) struct { ended: bool, note: ?[]const u8 } {
    const probe = args.probe orelse defaultGuestProbe;
    var known_boot: ?i64 = null;
    var i: usize = 0;
    while (i < args.max_iters) : (i += 1) {
        const outcome = probe(args.allocator, job, known_boot);
        if (known_boot == null and outcome.boot_pid > 0) known_boot = outcome.boot_pid;
        if (guest_jobs.isFinished(outcome.verdict)) {
            return .{ .ended = true, .note = guest_jobs.noteFor(outcome.verdict) };
        }
        std.Io.sleep(args.io, .{ .nanoseconds = args.poll_interval_ns }, .real) catch {};
    }
    return .{ .ended = false, .note = null };
}

/// Poll a host pid until it dies or the cap hits.
fn watchHostPid(args: *const WatchCoreArgs) bool {
    var i: usize = 0;
    while (i < args.max_iters) : (i += 1) {
        if (!stillRunning(args.pid_num)) return true;
        std.Io.sleep(args.io, .{ .nanoseconds = args.poll_interval_ns }, .real) catch {};
    }
    return !stillRunning(args.pid_num);
}

/// Poll until the PID dies (or the cap hits), then notify + delete. Returns
/// true iff notified AND the row was deleted (caller wakes).
pub fn watchAndNotify(args: WatchCoreArgs) bool {
    var note: ?[]const u8 = null;
    const ended = if (args.guest) |job| blk: {
        const outcome = watchGuestJob(&args, job);
        note = outcome.note;
        break :blk outcome.ended;
    } else watchHostPid(&args);
    // Cap hit with the process still alive — exit silently, cron covers it
    // (which only ever happens for a `job`; the service cap is unbounded).
    if (!ended) return false;

    // ── silent service path ────────────────────────────────────────────────
    // The process exited.
    if (!args.notify) {
        bg_proc.updateStatus(args.db, args.allocator, args.session_id, args.pid_num, "exited") catch |err| {
            if (args.logger) |log| {
                log.errFmt(
                    "[background_watcher] service status update failed for session {s} pid {s}: {s}\n",
                    .{ args.session_id, args.pid_str, @errorName(err) },
                );
            }
        };
        // List-change signal only: the frontend refetches on it and renders no
        // message. Emitting it keeps the popup honest without a queue row.
        pabrikcore.ai_mod.background_process_events.emitCompleted(
            args.allocator,
            args.event_bus,
            args.session_id,
            args.pid_num,
            args.command,
        );
        return false;
    }

    // Per-call arena for the notify buffers (same as the cron pass-1.5:
    // insertQueueMessage binds synchronously, so arena lifetime covering the
    // call is enough; the arena frees log_content + message in one shot so
    var arena = std.heap.ArenaAllocator.init(args.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A guest log is inside the VM, so it is fetched HERE: the notify helper
    // reads a host file, and a tenant log is not one.
    var log_override: ?[]const u8 = null;
    var log_total: ?usize = null;
    if (args.guest) |job| {
        if (guest_jobs.readDelta(a, job, args.log_path, 0, bg_proc.completion_log_cap_bytes)) |delta| {
            log_override = delta.bytes;
            log_total = @intCast(@max(delta.total_bytes, 0));
        } else |_| {
            // Unreadable (the VM is gone, or the log with it): the note already
            // says why the job ended, and the helper reports the missing log.
        }
    }

    const notified = cleanup.notifySingleBackgroundCompletion(.{
        .allocator = a,
        .io = args.io,
        .db = args.db,
        .logger = args.logger,
        .event_bus = args.event_bus,
        .session_id = args.session_id,
        .pid_num = args.pid_num,
        .pid_str = args.pid_str,
        .command = args.command,
        .log_path = args.log_path,
        .log_content = log_override,
        .log_total_bytes = log_total,
        .home = if (args.guest) |job| bg_proc.JobHome.guest(job.vm_id, job.guest_pid) else bg_proc.JobHome.host(),
        .note = note orelse "",
    });
    if (!notified) return false;

    bg_proc.delete(args.db, a, args.session_id, args.pid_num) catch |err| {
        if (args.logger) |log| {
            log.errFmt(
                "[background_watcher] delete failed for session {s} pid {s}: {s} — cron fallback retries\n",
                .{ args.session_id, args.pid_str, @errorName(err) },
            );
        }
        return false;
    };
    return true;
}

/// Io-task-owned args — every slice is heap-duped with `di.allocator` at
/// schedule time and freed by the task on exit.
const WatchArgs = struct {
    di: *pabrikcore.App,
    session_id: []u8,
    pid: u32,
    pid_str: []u8,
    command: []u8,
    log_path: []u8,
    poll_interval_ns: u64,
    max_iters: usize,
    /// Mirrors `WatchCoreArgs.notify` — see that field.
    notify: bool,
    /// Owned copy of the workspace VM id for a guest job, or null for a host
    /// pid.
    guest_vm_id: ?[]u8,
    guest_pid: u32,
};

/// Io-task entry — owns the dupes, frees them on exit. Never panics.
/// Top-level `fn(args: WatchArgs) void` so `group.concurrent` can schedule
/// it (single-struct tuple is passed through as the one param).
fn watchFn(args: WatchArgs) void {
    const di = args.di;
    const gpa = di.allocator;
    defer gpa.free(args.session_id);
    defer gpa.free(args.pid_str);
    defer gpa.free(args.command);
    defer gpa.free(args.log_path);
    defer if (args.guest_vm_id) |vm_id| gpa.free(vm_id);

    // Per-watch arena for the notify buffers (insertQueueMessage binds
    // synchronously, so arena lifetime covering the call is enough).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const done = watchAndNotify(.{
        .allocator = a,
        .io = di.io,
        .db = di.db,
        .logger = di.logger,
        .event_bus = di.event_bus,
        .session_id = args.session_id,
        .pid_num = args.pid,
        .pid_str = args.pid_str,
        .command = args.command,
        .log_path = args.log_path,
        .poll_interval_ns = args.poll_interval_ns,
        .max_iters = args.max_iters,
        .notify = args.notify,
        .guest = if (args.guest_vm_id) |vm_id| guest_jobs.GuestJob{
            .vm_id = vm_id,
            .guest_pid = args.guest_pid,
        } else null,
    });
    // A service is deliberately silent, so there is nobody to wake: the loop
    // exists to reap the child and record that it exited.
    if (!done or !args.notify) return;
    cleanup.wakeSessionForCompletion(di, a, args.session_id);
}

/// Schedule the fire-and-forget watcher task.
pub fn spawnCompletionWatcher(
    di: *pabrikcore.App,
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
) void {
    spawnWatcherWithPoll(di, session_id, pid, command, log_path, watcher_poll_interval_ns, watcher_max_iters, true, null);
}

/// Schedule the SILENT reaper for a `mode="background_persistence"` process.
pub fn spawnServiceReaper(
    di: *pabrikcore.App,
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
) void {
    spawnWatcherWithPoll(di, session_id, pid, command, log_path, watcher_poll_interval_ns, service_reaper_max_iters, false, null);
}

/// Schedule the watcher for a job that runs in a workspace VM. `pid` is the
/// GUEST pid, and the loop asks the manager about it — never the host.
pub fn spawnGuestWatcher(
    di: *pabrikcore.App,
    session_id: []const u8,
    guest: guest_jobs.GuestJob,
    command: []const u8,
    log_path: []const u8,
    notify: bool,
) void {
    const max_iters = if (notify) watcher_max_iters else service_reaper_max_iters;
    spawnWatcherWithPoll(di, session_id, guest.guest_pid, command, log_path, watcher_poll_interval_ns, max_iters, notify, guest);
}

/// Schedule with an explicit poll interval / cap (test hook; production passes
/// the defaults via `spawnCompletionWatcher` / `spawnServiceReaper`).
pub fn spawnCompletionWatcherWithPoll(
    di: *pabrikcore.App,
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
    poll_interval_ns: u64,
    max_iters: usize,
) void {
    spawnWatcherWithPoll(di, session_id, pid, command, log_path, poll_interval_ns, max_iters, true, null);
}

fn spawnWatcherWithPoll(
    di: *pabrikcore.App,
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
    poll_interval_ns: u64,
    max_iters: usize,
    notify: bool,
    guest: ?guest_jobs.GuestJob,
) void {
    const gpa = di.allocator;
    const sid = gpa.dupe(u8, session_id) catch return;
    errdefer gpa.free(sid);
    const cmd = gpa.dupe(u8, command) catch return;
    errdefer gpa.free(cmd);
    const lp = gpa.dupe(u8, log_path) catch return;
    errdefer gpa.free(lp);
    const pid_str = std.fmt.allocPrint(gpa, "{d}", .{pid}) catch return;
    errdefer gpa.free(pid_str);
    const guest_vm_id: ?[]u8 = if (guest) |job| (gpa.dupe(u8, job.vm_id) catch return) else null;
    errdefer if (guest_vm_id) |vm_id| gpa.free(vm_id);

    const args = WatchArgs{
        .di = di,
        .session_id = sid,
        .pid = pid,
        .pid_str = pid_str,
        .command = cmd,
        .log_path = lp,
        .poll_interval_ns = poll_interval_ns,
        .max_iters = max_iters,
        .notify = notify,
        .guest_vm_id = guest_vm_id,
        .guest_pid = if (guest) |job| job.guest_pid else 0,
    };
    // Fire-and-forget on the process-lifetime group (same as
    // `group_emit_session_create` — never awaited or cancelled).
    di.group_bg_watchers.concurrent(di.io, watchFn, .{args}) catch {
        gpa.free(sid);
        gpa.free(cmd);
        gpa.free(lp);
        gpa.free(pid_str);
        if (guest_vm_id) |vm_id| gpa.free(vm_id);
        return;
    };
}

// ─── Tests (inline, project convention) ──────────────────────────────────────

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,

    fn deinit(self: *TestCtx) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

fn setupCtx() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{
        .db = db,
        .threaded = threaded,
    };
}

test "watchAndNotify notifies a dead PID immediately then deletes the row" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bg.log", .data = "watcher saw exit" });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const log_path = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "bg.log" });
    defer testing.allocator.free(log_path);

    // 999_999_999 is virtually guaranteed to NOT exist — the first
    // isProcessRunning check breaks immediately, no sleep.
    const dead_pid: u32 = 999_999_999;
    try bg_proc.save(&ctx.db, testing.allocator, "s_watch", dead_pid, "sleep 30", log_path, 1, bg_proc.KIND_JOB, .{});

    const done = watchAndNotify(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .session_id = "s_watch",
        .pid_num = dead_pid,
        .pid_str = "999999999",
        .command = "sleep 30",
        .log_path = log_path,
        .poll_interval_ns = 10 * std.time.ns_per_ms,
        .max_iters = 500,
    });
    try testing.expect(done);

    // Queue envelope present.
    var q = try ctx.db.query(testing.allocator, "SELECT message FROM session_queue_messages WHERE session_id = ?", &.{"s_watch"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    const msg = row.values[0];
    try testing.expect(std.mem.indexOf(u8, msg, "\"pid\":999999999") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "\"command\":\"sleep 30\"") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "watcher saw exit") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "\"\"\"\"\"") == null);

    // Bg row deleted.
    var r = try ctx.db.query(testing.allocator, "SELECT 1 FROM session_background_process WHERE session_id = ?", &.{"s_watch"});
    defer r.deinit();
    try testing.expect((try r.next()) == null);
}

// The silence contract of `mode="background_persistence"`, in the one place
// it is decidable: the watcher is the ONLY thing that could tell the agent a
// service exited, so `notify = false` must leave the queue untouched.
test "watchAndNotify: notify=false writes NO queue message and marks the row exited" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "svc.log", .data = "dev server output" });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const log_path = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "svc.log" });
    defer testing.allocator.free(log_path);

    const dead_pid: u32 = 999_999_999;
    try bg_proc.save(&ctx.db, testing.allocator, "s_svc", dead_pid, "pnpm run dev", log_path, 1, bg_proc.KIND_SERVICE, .{});

    const done = watchAndNotify(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .session_id = "s_svc",
        .pid_num = dead_pid,
        .pid_str = "999999999",
        .command = "pnpm run dev",
        .log_path = log_path,
        .poll_interval_ns = 10 * std.time.ns_per_ms,
        .max_iters = 500,
        .notify = false,
    });
    // `watchAndNotify` returns "notified AND deleted"; a service does neither.
    try testing.expect(!done);

    // THE ASSERTION: the model is told nothing. This is the whole mode.
    var q = try ctx.db.query(testing.allocator, "SELECT COUNT(*) FROM session_queue_messages WHERE session_id = ?", &.{"s_svc"});
    defer q.deinit();
    const qrow = (try q.next()) orelse return error.RowMissing;
    defer qrow.deinit(testing.allocator);
    try testing.expectEqualStrings("0", qrow.values[0]);

    // ...but the row is kept and marked, so the popup can still say the
    // process is gone. Deleting it would erase the only record it existed.
    var r = try ctx.db.query(testing.allocator, "SELECT status, kind FROM session_background_process WHERE session_id = ?", &.{"s_svc"});
    defer r.deinit();
    const rrow = (try r.next()) orelse return error.RowMissing;
    defer rrow.deinit(testing.allocator);
    try testing.expectEqualStrings("exited", rrow.values[0]);
    try testing.expectEqualStrings("service", rrow.values[1]);
}

// Positive control for the test above: the SAME dead PID, the same log, the
// same watcher — only `notify` differs. A `job` MUST queue, or the test above
// would pass on a watcher that never does anything.
test "watchAndNotify: the same run with notify=true DOES queue — the control" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "job.log", .data = "build finished" });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const log_path = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "job.log" });
    defer testing.allocator.free(log_path);

    const dead_pid: u32 = 999_999_998;
    try bg_proc.save(&ctx.db, testing.allocator, "s_job", dead_pid, "zig build", log_path, 1, bg_proc.KIND_JOB, .{});

    const done = watchAndNotify(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .session_id = "s_job",
        .pid_num = dead_pid,
        .pid_str = "999999998",
        .command = "zig build",
        .log_path = log_path,
        .poll_interval_ns = 10 * std.time.ns_per_ms,
        .max_iters = 500,
        .notify = true,
    });
    try testing.expect(done);

    var q = try ctx.db.query(testing.allocator, "SELECT COUNT(*) FROM session_queue_messages WHERE session_id = ?", &.{"s_job"});
    defer q.deinit();
    const qrow = (try q.next()) orelse return error.RowMissing;
    defer qrow.deinit(testing.allocator);
    try testing.expectEqualStrings("1", qrow.values[0]);
}

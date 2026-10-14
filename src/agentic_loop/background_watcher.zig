//! Immediate background-command completion watcher.
//!
//! A `command background=true` completion is otherwise only noticed by the
//! per-minute `cleanup_stale_background_process` cron (notify-then-delete +
//! wake). This module schedules a fire-and-forget Io-task watcher at exec
//! time on `di.group_bg_watchers` that polls `isProcessRunning(pid)` every
//! 2s and inserts the queue message the moment the command exits — no cron
//! wait. The group is process-lifetime and never awaited or cancelled
//! (same as `group_emit_session_create`).
//!
//! True event-driven wait is impossible: the bg PID is a grandchild
//! (`nohup cmd &` inside a shell that exits — not our child, no waitpid).
//! A shell-wrapper+HTTP-callback alternative is rejected (new endpoint +
//! auth surface). Polling is the only option; the cron remains as fallback
//! (cap expiry, spawn failure, crash between save and spawn).
//!
//! Concurrency: the cron already uses `di.db` + `emit_run_agent`
//! concurrently with request handlers, so watcher-task DB/emit use is the
//! same class. The task never panics — every failure is caught and logged.
//!
//! Ownership (per-request arena rule): the spawn call dupes
//! session_id/command/log_path/pid_str with `di.allocator` (process
//! lifetime — NEVER the request ctx allocator). The Io task frees them on
//! exit. Notify buffers live in a per-watch arena.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const logger_mod = pabrikcore.loggermod;
const event_bus_mod = pabrikcore.event_bus;
const bg_proc = pabrikcore.ai_mod.background_process;
const cleanup = pabrikcore.cleanup_stale_background_process;
// NOTE: do NOT use `bg_proc.isProcessRunning` — `background_process.zig`
// resolves it via `root_mod.helpers.process_status`, but root dropped the
// `helpers` re-export (root.zig:637), so that decl no longer compiles when
// referenced. Use the supported `@import("helpers")` route directly (same
// as cleanup_stale_background_process.zig).
const process_status = @import("helpers").process_status;
const shell_tool = pabrikcore.shell_tool;
const migration = @import("../migrations/migration.zig");
const testing = std.testing;

/// Poll interval between `isProcessRunning` checks (production).
pub const watcher_poll_interval_ns: u64 = 2 * std.time.ns_per_s;
/// Cap on poll iterations (~24h at the default 2s interval). On expiry the
/// task exits silently — the cron is the fallback.
pub const watcher_max_iters: usize = 43200;

/// Cap for the SERVICE reaper. Effectively unbounded, and that is deliberate:
/// a `background_persistence` process is defined by running for the life of
/// the session, so a 24h cap would retire the reaper and leave the eventual
/// corpse unreaped — and a zombie answers `kill(pid, 0)` with SUCCESS, so the
/// process would then read as "running" until the next boot. The cron does not
/// cover services (it filters `kind = 'job'`), so nothing else would either.
pub const service_reaper_max_iters: usize = std.math.maxInt(usize);

/// Liveness that also REAPS.
///
/// For a child of THIS process `waitpid(WNOHANG)` answers "is it alive" AND
/// collects the zombie in one call — which matters because the alternative
/// probe, `kill(pid, 0)`, returns SUCCESS for a zombie. Without this, a
/// `background_persistence` process that exited would look alive forever.
///
/// `.not_our_child` is the honest answer for a row from before a restart, and
/// for the `nohup` grandchild that `mode="background"` produces; there the
/// signal probe is all that is available.
fn stillRunning(pid: u32) bool {
    return switch (shell_tool.reap_pid_nohang(pid)) {
        .exited => false,
        .running => true,
        .not_our_child => process_status.isProcessRunning(@intCast(pid)),
    };
}

/// Testable core args — explicit handles (no singleton) so unit tests stay
/// hermetic (own :memory: DB, event_bus=null).
pub const WatchCoreArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    event_bus: ?*event_bus_mod.EventBus,
    session_id: []const u8,
    pid_num: u32,
    pid_str: []const u8,
    command: []const u8,
    log_path: []const u8,
    poll_interval_ns: u64 = watcher_poll_interval_ns,
    max_iters: usize = watcher_max_iters,
    /// true  — `mode="background"`: queue the log and wake the session on exit.
    /// false — `mode="background_persistence"`: SILENT. Mark the row `exited`
    ///         and refresh the list; write no queue message, wake nobody.
    ///         This flag is the watcher half of that mode's contract, and the
    ///         cron's `kind = 'job'` filter is the other half.
    notify: bool = true,
};

/// Poll until the PID dies (or the cap hits), then notify + delete.
/// Returns true iff notified AND the row was deleted (caller wakes).
/// Never panics — notify/delete failures are caught, logged, return false
/// (cron fallback retries next tick).
pub fn watchAndNotify(args: WatchCoreArgs) bool {
    var i: usize = 0;
    while (i < args.max_iters) : (i += 1) {
        if (!stillRunning(args.pid_num)) break;
        std.Io.sleep(args.io, .{ .nanoseconds = args.poll_interval_ns }, .real) catch {};
    }
    // Cap hit with the process still alive — exit silently, cron covers it
    // (which only ever happens for a `job`; the service cap is unbounded).
    if (stillRunning(args.pid_num)) return false;

    // ── silent service path ────────────────────────────────────────────────
    // The process exited. For a service that is worth reflecting in the DB and
    // in the popup, and worth NOT telling the model: the whole point of
    // `background_persistence` is that the agent decides when to look.
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
    // insertQueueMessage binds synchronously, so arena lifetime covering
    // the call is enough; the arena frees log_content + message in one
    // shot so DebugAllocator tests don't leak).
    var arena = std.heap.ArenaAllocator.init(args.allocator);
    defer arena.deinit();
    const a = arena.allocator();

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
    });
    // A service is deliberately silent, so there is nobody to wake: the loop
    // exists to reap the child and record that it exited.
    if (!done or !args.notify) return;
    cleanup.wakeSessionForCompletion(di, a, args.session_id);
}

/// Schedule the fire-and-forget watcher task. Returns void — every failure
/// (dupe OOM, concurrent() error such as error.ConcurrencyUnavailable on a
/// bare blocking Io) is silent (cron fallback covers production; unit tests
/// cover the watcher core directly via `watchAndNotify`).
/// Must be called AFTER `background_process.save` succeeds, with the
/// borrowed slices still alive (they are duped synchronously here).
pub fn spawnCompletionWatcher(
    di: *pabrikcore.App,
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
) void {
    spawnWatcherWithPoll(di, session_id, pid, command, log_path, watcher_poll_interval_ns, watcher_max_iters, true);
}

/// Schedule the SILENT reaper for a `mode="background_persistence"` process.
///
/// Same poll loop as the watcher, minus everything that talks to the model: it
/// reaps the child (so `kill(pid, 0)` stops reporting a corpse as alive) and
/// marks the row `exited`. No queue message, no wake — that is the mode.
///
/// Must be called AFTER `background_process.save` succeeds, with the borrowed
/// slices still alive (they are duped synchronously inside).
pub fn spawnServiceReaper(
    di: *pabrikcore.App,
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
) void {
    spawnWatcherWithPoll(di, session_id, pid, command, log_path, watcher_poll_interval_ns, service_reaper_max_iters, false);
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
    spawnWatcherWithPoll(di, session_id, pid, command, log_path, poll_interval_ns, max_iters, true);
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
    };
    // Fire-and-forget on the process-lifetime group (same as
    // `group_emit_session_create` — never awaited or cancelled). On
    // concurrent() error (notably error.ConcurrencyUnavailable on a bare
    // blocking Io, same as tools_exec_spawn_sub_agent.zig) free the dupes
    // here (the task never started, so it cannot free them); on success
    // the task owns them.
    di.group_bg_watchers.concurrent(di.io, watchFn, .{args}) catch {
        gpa.free(sid);
        gpa.free(cmd);
        gpa.free(lp);
        gpa.free(pid_str);
        return;
    };
}

// ─── Tests (inline, project convention) ──────────────────────────────────────

const TestCtx = struct {
    db: sqlite.SqliteBackend,
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

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

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
    try bg_proc.save(&ctx.db, testing.allocator, "s_watch", dead_pid, "sleep 30", log_path, 1, bg_proc.KIND_JOB);

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
//
// Paired with its positive control in the next test — "no queue message" is
// also what a watcher that crashed before it did anything looks like.
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
    try bg_proc.save(&ctx.db, testing.allocator, "s_svc", dead_pid, "pnpm run dev", log_path, 1, bg_proc.KIND_SERVICE);

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
    try bg_proc.save(&ctx.db, testing.allocator, "s_job", dead_pid, "zig build", log_path, 1, bg_proc.KIND_JOB);

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

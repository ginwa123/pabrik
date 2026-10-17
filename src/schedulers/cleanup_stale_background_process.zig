//! Cronjob — delete stale rows from `session_background_process` whose PID is
//! no longer alive.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const process_status = @import("helpers").process_status;
const logger_mod = pabrikcore.loggermod;
const event_bus_mod = pabrikcore.event_bus;
// Route the bg-completion helpers + queue insert through `pabrikcore` (the
// `root` module) instead of @import'ing the agentic_loop files directly —
// same pattern as cleanup_stale_worker.zig's
const bg_proc = pabrikcore.ai_mod.background_process;
const ai_workflow = pabrikcore.ai_mod.ai_workflow;
const guest_jobs = pabrikcore.ai_mod.guest_jobs;
// `migration.zig` lives in `src/migrations/` — one `..` up from
// `src/schedulers/`.
const migration = @import("../migrations/migration.zig");
const testing = std.testing;

pub const CleanupStaleBackgroundProcessInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    event_bus: ?*event_bus_mod.EventBus,
};

pub const CleanupResult = struct {
    checked_count: usize = 0,
    kept_count: usize = 0,
    notified_count: usize = 0,
    deleted_count: usize = 0,
    /// Deduped session_ids that were successfully notified this tick (one
    /// entry per session, even if several of its PIDs completed).
    notified_sessions: [][]const u8 = &.{},
};

/// Pure seam for the Task 3 wake decision: wake the session iff no worker is
/// currently running on it.
pub fn shouldWake(is_running: bool) bool {
    return !is_running;
}

/// Release `result.notified_sessions` (each sid + the outer slice).
/// No-op when empty. Idempotent — resets the field to `&.{}`.
pub fn freeNotifiedSessions(allocator: std.mem.Allocator, result: *CleanupResult) void {
    for (result.notified_sessions) |sid| allocator.free(sid);
    if (result.notified_sessions.len > 0) allocator.free(result.notified_sessions);
    result.notified_sessions = &.{};
}

// ─── Production helper ────────────────────────────────────────────────────
// Three-phase notify-then-delete.

/// Args for `notifySingleBackgroundCompletion` — one dead (session_id, pid)
/// pair plus the shared request-scoped handles.
pub const NotifySingleBackgroundCompletionArgs = struct {
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
    /// Bytes the CALLER already fetched, for a log the host cannot open (a
    /// guest job's log lives inside its VM). Null keeps the host read.
    log_content: ?[]const u8 = null,
    /// That log's full size, so truncation is reported the same way.
    log_total_bytes: ?usize = null,
    /// Where the pid lives: this host, or a workspace VM.
    home: bg_proc.JobHome = .{},
    /// One extra sentence for the envelope, e.g. that the VM stopped.
    note: []const u8 = "",
};

/// Notify one dead background pair: read the log (capped), build the
/// completion envelope, queue it with `is_emit_sse=true`.
pub fn notifySingleBackgroundCompletion(args: NotifySingleBackgroundCompletionArgs) bool {
    const allocator = args.allocator;
    const io = args.io;
    const db = args.db;
    const logger = args.logger;
    const event_bus = args.event_bus;

    // Read the log head. FileNotFound → not-found marker (still
    // notify + delete). Any OTHER read error → skip notify for
    // this pair; it stays for the next tick to retry.
    var log_content: []const u8 = "";
    var was_truncated: bool = false;
    var total_bytes: usize = 0;
    if (args.log_content) |fetched| {
        log_content = fetched;
        total_bytes = args.log_total_bytes orelse fetched.len;
        was_truncated = total_bytes > fetched.len;
    } else if (bg_proc.readLogTruncated(allocator, io, args.log_path, bg_proc.completion_log_cap_bytes)) |tlog| {
        // `tlog.content` is allocator-owned — no free (arena rule).
        log_content = tlog.content;
        was_truncated = tlog.truncated;
        total_bytes = tlog.total_bytes;
    } else |err| {
        if (err == error.FileNotFound) {
            log_content = std.fmt.allocPrint(
                allocator,
                "(log file not found: {s})",
                .{args.log_path},
            ) catch {
                if (logger) |log| {
                    log.errFmt(
                        "[cleanup_stale_background_process] not-found marker alloc failed for session {s} pid {s}\n",
                        .{ args.session_id, args.pid_str },
                    );
                }
                return false;
            };
            was_truncated = false;
            total_bytes = 0;
        } else {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] log read failed for session {s} pid {s} ({s}): {s} — retry next tick\n",
                    .{ args.session_id, args.pid_str, args.log_path, @errorName(err) },
                );
            }
            return false;
        }
    }

    const message = bg_proc.buildCompletionMessage(
        allocator,
        args.command,
        args.pid_num,
        log_content,
        was_truncated,
        total_bytes,
        args.log_path,
        args.home,
        args.note,
    ) catch |err| {
        if (logger) |log| {
            log.errFmt(
                "[cleanup_stale_background_process] completion message build failed for session {s} pid {s}: {s} — retry next tick\n",
                .{ args.session_id, args.pid_str, @errorName(err) },
            );
        }
        return false;
    };

    ai_workflow.insertQueueMessage(.{
        .allocator = allocator,
        .db = db,
        .logger = logger,
        .session_id = args.session_id,
        .message = message,
        .image_url = "",
        .event_bus = event_bus,
        .is_emit_sse = true,
    }) catch |err| {
        if (logger) |log| {
            log.errFmt(
                "[cleanup_stale_background_process] queue insert failed for session {s} pid {s}: {s} — retry next tick\n",
                .{ args.session_id, args.pid_str, @errorName(err) },
            );
        }
        return false;
    };

    // Push the list change so the frontend drops its 5s poll and relies on
    // SSE.
    pabrikcore.ai_mod.background_process_events.emitCompleted(
        allocator,
        event_bus,
        args.session_id,
        args.pid_num,
        args.command,
    );

    return true;
}

/// Wake one notified session: if no worker is running on it, resolve the
/// session row (safe defaults on miss) and kick an agent run via
/// `emit_run_agent` with `skip_initial_queue_message=true` so the run drains
pub fn wakeSessionForCompletion(di: *pabrikcore.App, allocator: std.mem.Allocator, sid: []const u8) void {
    const logger = di.logger;

    const running = ai_workflow.isWorkerRunning(allocator, di.db, sid);
    if (!shouldWake(running)) return;

    // Resolve the session row for the emit fields (same shape as
    // `startAgentUseCase` step 3).
    var sname: []const u8 = "";
    var scwd: []const u8 = "";
    var sprofile: []const u8 = "";
    var sretry: []const u8 = "0";
    var sowner: []const u8 = "";
    if (di.db.query(allocator, "SELECT name, COALESCE(cwd, ''), COALESCE(selected_profile_model, ''), COALESCE(is_auto_retry_until_stop, '0'), COALESCE(user_id, '') FROM sessions WHERE id = ?", &.{sid})) |rows| {
        var q = rows;
        defer q.deinit();
        if (q.next() catch null) |row| {
            defer row.deinit(allocator);
            if (row.values.len >= 5) {
                sname = allocator.dupe(u8, row.values[0]) catch "";
                scwd = allocator.dupe(u8, row.values[1]) catch "";
                sprofile = allocator.dupe(u8, row.values[2]) catch "";
                sretry = allocator.dupe(u8, row.values[3]) catch "0";
                sowner = allocator.dupe(u8, row.values[4]) catch "";
            }
        }
    } else |_| {
        // Query failed (e.g. transient DB blip) — fall through with
        // defaults; the emit below still wakes the worker.
    }

    di.emit_run_agent(.{
        .session_id = sid,
        .session_name = sname,
        .queue_message = "",
        .cwd = scwd,
        .body_message = "",
        .allowed_tools = "",
        .image_urls = "",
        .selected_profile_model = sprofile,
        .is_auto_retry_until_stop = sretry,
        .skip_initial_queue_message = true,
        // Preserve the session's owner so the worker's upsert keeps the
        // row owned under `--auth` (plan 2026-09-25).
        .user_id = sowner,
    }) catch |err| {
        logger.errFmt(
            "[cleanup_stale_background_process] wake emit failed for session {s}: {s}\n",
            .{ sid, @errorName(err) },
        );
        return;
    };
}

/// Max (session_id, pid) pairs per single DELETE statement.
/// `SQLITE_MAX_VARIABLE_NUMBER` defaults to 999; each pair = 2 params.
const max_pairs_per_stmt: usize = 499;

pub fn cleanupStaleBackgroundProcesses(input: CleanupStaleBackgroundProcessInput) anyerror!CleanupResult {
    const allocator = input.allocator;
    const io = input.io;
    const db = input.db;
    const logger = input.logger;
    const event_bus = input.event_bus;

    var result = CleanupResult{};

    // Per-call arena for the dead-rows collection.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Pass 1: SELECT every (session_id, pid, command, log_path) row.
    // For each row, ask the OS whether the process is alive. Dead rows
    // get collected for the notify + batch DELETE in passes 1.5 / 2.
    const DeadPair = struct {
        session_id: []const u8,
        pid: []const u8,
        pid_num: u32,
        command: []const u8,
        log_path: []const u8,
        home: bg_proc.JobHome = .{},
        note: []const u8 = "",
        log_content: ?[]const u8 = null,
        log_total_bytes: ?usize = null,
        notified: bool = false,
    };
    var dead: std.ArrayListUnmanaged(DeadPair) = .empty;
    defer dead.deinit(a);

    // `kind = 'job'` is not an optimization — it is the OTHER HALF of
    // `mode="background_persistence"`'s contract.
    const select_sql =
        \\SELECT session_id, pid, command, log_path, COALESCE(vm_id, ''), COALESCE(guest_pid, 0)
        \\FROM session_background_process
        \\WHERE kind = 'job'
    ;

    var rows = try db.query(a, select_sql, &.{});
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(a);

        if (row.values.len < 4) continue;
        const session_id = row.values[0];
        const pid_str = row.values[1];
        const command = row.values[2];
        const log_path = row.values[3];
        const vm_id = if (row.values.len > 4) row.values[4] else "";
        const guest_pid = if (row.values.len > 5)
            std.fmt.parseInt(u32, row.values[5], 10) catch 0
        else
            0;

        result.checked_count += 1;

        // Defensive: skip rows with malformed PIDs rather than panic.
        // A row with a non-numeric PID is unrecoverable corruption.
        const pid = std.fmt.parseInt(i32, pid_str, 10) catch continue;

        var home = bg_proc.JobHome.host();
        var note: []const u8 = "";
        var log_content: ?[]const u8 = null;
        var log_total: ?usize = null;

        if (vm_id.len > 0) {
            // A guest row's pid is the GUEST's: asking this host about it would
            // answer a different question, and the log is not on this host at
            // all.
            home = bg_proc.JobHome.guest(vm_id, guest_pid);
            const job = guest_jobs.GuestJob{ .vm_id = vm_id, .guest_pid = guest_pid };
            const reading = guest_jobs.probe(a, job, null);
            if (!guest_jobs.isFinished(reading.verdict)) {
                result.kept_count += 1;
                continue;
            }
            note = guest_jobs.noteFor(reading.verdict) orelse "";
            if (guest_jobs.readDelta(a, job, log_path, 0, bg_proc.completion_log_cap_bytes)) |delta| {
                log_content = delta.bytes;
                log_total = @intCast(@max(delta.total_bytes, 0));
            } else |_| {}
        } else if (process_status.isProcessRunning(pid)) {
            // The single source of truth: is the process actually alive?
            // Cross-platform — uses kill(pid, 0) on POSIX, OpenProcess
            // with QUERY_LIMITED on Windows.
            result.kept_count += 1;
            continue;
        }

        // Process is dead — collect the row for the notify (pass 1.5) + batch
        // DELETE (pass 2).
        const sid_copy = a.dupe(u8, session_id) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] arena dupe(session_id) failed: {s}\n",
                    .{@errorName(err)},
                );
            }
            return result;
        };
        const pid_copy = a.dupe(u8, pid_str) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] arena dupe(pid) failed: {s}\n",
                    .{@errorName(err)},
                );
            }
            return result;
        };
        const cmd_copy = a.dupe(u8, command) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] arena dupe(command) failed: {s}\n",
                    .{@errorName(err)},
                );
            }
            return result;
        };
        const log_copy = a.dupe(u8, log_path) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] arena dupe(log_path) failed: {s}\n",
                    .{@errorName(err)},
                );
            }
            return result;
        };
        dead.append(a, .{
            .session_id = sid_copy,
            .pid = pid_copy,
            .pid_num = @intCast(pid),
            .command = cmd_copy,
            .log_path = log_copy,
            .home = home,
            .note = note,
            .log_content = log_content,
            .log_total_bytes = log_total,
        }) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] dead-list append failed: {s}\n",
                    .{@errorName(err)},
                );
            }
            return result;
        };
    }

    if (dead.items.len == 0) return result;

    // Pass 1.5 (notify): for each dead pair, read the log + queue the
    // completion message.
    for (dead.items) |*pair| {
        if (notifySingleBackgroundCompletion(.{
            .allocator = a,
            .io = io,
            .db = db,
            .logger = logger,
            .event_bus = event_bus,
            .session_id = pair.session_id,
            .pid_num = pair.pid_num,
            .pid_str = pair.pid,
            .command = pair.command,
            .log_path = pair.log_path,
            .log_content = pair.log_content,
            .log_total_bytes = pair.log_total_bytes,
            .home = pair.home,
            .note = pair.note,
        })) {
            pair.notified = true;
            result.notified_count += 1;
        }
    }

    // Task 3: expose the deduped notified session_ids for the wake loop in
    // `handle()`.
    {
        var uniq: std.ArrayListUnmanaged([]const u8) = .empty;
        defer uniq.deinit(allocator);
        for (dead.items) |pair| {
            if (!pair.notified) continue;
            var seen = false;
            for (uniq.items) |sid| {
                if (std.mem.eql(u8, sid, pair.session_id)) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            const sid_copy = allocator.dupe(u8, pair.session_id) catch |err| {
                if (logger) |log| {
                    log.errFmt(
                        "[cleanup_stale_background_process] notified_sessions dupe failed: {s}\n",
                        .{@errorName(err)},
                    );
                }
                freeNotifiedSessions(allocator, &result);
                // `uniq` holds caller-owned dupes not yet moved into the
                // result — free them here (result was just reset to empty
                // so the helper above did NOT touch them).
                for (uniq.items) |sid| allocator.free(sid);
                return result;
            };
            uniq.append(allocator, sid_copy) catch |err| {
                allocator.free(sid_copy);
                if (logger) |log| {
                    log.errFmt(
                        "[cleanup_stale_background_process] notified_sessions append failed: {s}\n",
                        .{@errorName(err)},
                    );
                }
                freeNotifiedSessions(allocator, &result);
                for (uniq.items) |sid| allocator.free(sid);
                return result;
            };
        }
        if (uniq.items.len > 0) {
            result.notified_sessions = uniq.toOwnedSlice(allocator) catch |err| {
                if (logger) |log| {
                    log.errFmt(
                        "[cleanup_stale_background_process] notified_sessions seal failed: {s}\n",
                        .{@errorName(err)},
                    );
                }
                for (uniq.items) |sid| allocator.free(sid);
                return result;
            };
        }
    }

    // Collect only the notified pairs for the DELETE. Failed-notify
    // pairs stay in the table for the next tick to retry.
    var doomed: std.ArrayListUnmanaged(DeadPair) = .empty;
    defer doomed.deinit(a);
    for (dead.items) |pair| {
        if (!pair.notified) continue;
        doomed.append(a, pair) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] delete-list append failed: {s}\n",
                    .{@errorName(err)},
                );
            }
            return result;
        };
    }

    if (doomed.items.len == 0) return result;

    // Pass 2: batch DELETE all successfully-notified rows in chunks. Each
    // chunk builds ONE statement of the form DELETE FROM
    // session_background_process WHERE (session_id = ?
    var chunk_start: usize = 0;
    while (chunk_start < doomed.items.len) {
        const chunk_end = @min(chunk_start + max_pairs_per_stmt, doomed.items.len);
        const chunk = doomed.items[chunk_start..chunk_end];

        // Build SQL + params in the arena — both are scoped to this
        // chunk iteration so the arena frees them when chunk_start
        // advances.
        var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer sql_buf.deinit(a);
        sql_buf.appendSlice(a, "DELETE FROM session_background_process WHERE ") catch continue;

        var params: std.ArrayListUnmanaged([]const u8) = .empty;
        defer params.deinit(a);

        var ok = true;
        for (chunk, 0..) |pair, i| {
            if (i > 0) {
                sql_buf.appendSlice(a, " OR ") catch {
                    ok = false;
                    break;
                };
            }
            sql_buf.appendSlice(a, "(session_id = ? AND pid = ?)") catch {
                ok = false;
                break;
            };
            params.append(a, pair.session_id) catch {
                ok = false;
                break;
            };
            params.append(a, pair.pid) catch {
                ok = false;
                break;
            };
        }
        if (!ok) {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] SQL build failed at chunk offset {d}\n",
                    .{chunk_start},
                );
            }
            continue;
        }

        db.exec(a, sql_buf.items, params.items) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] batch DELETE failed at chunk offset {d} (size={d}): {s}\n",
                    .{ chunk_start, chunk.len, @errorName(err) },
                );
            }
            continue;
        };

        result.deleted_count += chunk.len;
        chunk_start = chunk_end;
    }

    return result;
}

/// Cron callback.
pub fn handle(ctx: ?*anyopaque, now_unix: i64) void {
    _ = ctx;
    _ = now_unix;

    const di = pabrikcore.getSingleton() catch return;
    const allocator = di.allocator;
    const logger = di.logger;

    // Per-tick arena — all SQL string allocations live for the duration of
    // the cleanupStaleBackgroundProcesses call. Cheaper than per-row
    // alloc/free and the arena frees them in one shot when this scope exits.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = cleanupStaleBackgroundProcesses(.{
        .allocator = a,
        .io = di.io,
        .db = di.db,
        .logger = logger,
        .event_bus = di.event_bus,
    }) catch |err| {
        logger.errFmt("[cleanup_stale_background_process] tick failed: {s}\n", .{@errorName(err)});
        return;
    };

    // Task 3: wake idle workers so the queued completion actually triggers an
    // agent run.
    var woken_count: usize = 0;
    for (result.notified_sessions) |sid| {
        const running = ai_workflow.isWorkerRunning(a, di.db, sid);
        if (!shouldWake(running)) continue;
        wakeSessionForCompletion(di, a, sid);
        woken_count += 1;
    }

    logger.infoFmt(
        "[cleanup_stale_background_process] tick summary: checked={d} kept={d} notified={d} deleted={d} woken={d}",
        .{ result.checked_count, result.kept_count, result.notified_count, result.deleted_count, woken_count },
    );
}

// ─── Tests ───────────────────────────────────────────────────────────────
// Inline tests, matching the project convention for files that have impl +
// tests (delete_worker.zig, cleanup_stale_worker.zig).

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

    // Walk every production migration (001 → latest).
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{
        .db = db,
        .threaded = threaded,
    };
}

/// Insert a background-process row. `pid` is passed as an `i64` so SQLite can
/// coerce it to INTEGER (matching the production column type).
fn seedRow(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    session_id: []const u8,
    pid: i64,
    status: []const u8,
) !void {
    const sql =
        \\INSERT INTO session_background_process
        \\    (session_id, pid, command, log_path, started_at, status)
        \\VALUES (?, ?, 'echo hi', '/tmp/log', 1, ?)
    ;
    var pid_buf: [32]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}", .{pid});
    try db.exec(alloc, sql, &.{ session_id, pid_str, status });
}

/// Insert a background-process row with an explicit command + log_path (for
/// the notify-then-delete tests, which need a real temp log file or a
/// deliberately missing path).
fn seedRowFull(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    session_id: []const u8,
    pid: i64,
    command: []const u8,
    log_path: []const u8,
    status: []const u8,
) !void {
    const sql =
        \\INSERT INTO session_background_process
        \\    (session_id, pid, command, log_path, started_at, status)
        \\VALUES (?, ?, ?, ?, 1, ?)
    ;
    var pid_buf: [32]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}", .{pid});
    try db.exec(alloc, sql, &.{ session_id, pid_str, command, log_path, status });
}

/// Fetch the single queue message for a session. Errors with
/// `error.RowMissing` when the notify step never queued one.
fn queueMessageForSession(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    session_id: []const u8,
) ![]u8 {
    var q = try db.query(alloc, "SELECT message FROM session_queue_messages WHERE session_id = ?", &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

/// Count rows for a given session_id. Returns 0 when none.
fn rowCountForSession(
    db: *sqlite.SqliteBackend,
    arena_alloc: std.mem.Allocator,
    session_id: []const u8,
) !usize {
    var rows = try db.query(arena_alloc, "SELECT 1 FROM session_background_process WHERE session_id = ?", &.{session_id});
    defer rows.deinit();
    var count: usize = 0;
    while (try rows.next()) |row| {
        defer row.deinit(arena_alloc);
        count += 1;
    }
    return count;
}

test "cleanupStaleBackgroundProcesses deletes a row whose PID is no longer running" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    // 999_999_999 is virtually guaranteed to NOT exist on any sane system.
    try seedRow(&ctx.db, testing.allocator, "s_dead", 999_999_999, "running");

    var result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
        .io = testing.io,
        .event_bus = null,
    });
    // notified_sessions is caller-owned (testing.allocator) — free or leak.
    defer freeNotifiedSessions(testing.allocator, &result);

    try testing.expectEqual(@as(usize, 1), result.checked_count);
    try testing.expectEqual(@as(usize, 1), result.notified_count);
    try testing.expectEqual(@as(usize, 1), result.deleted_count);
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_dead"));
}

test "cleanupStaleBackgroundProcesses notifies with log content then deletes the dead row" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bg.log", .data = "build finished ok" });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const log_path = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "bg.log" });
    defer testing.allocator.free(log_path);

    // 999_999_999 is virtually guaranteed to NOT exist on any sane system.
    try seedRowFull(&ctx.db, testing.allocator, "s_done", 999_999_999, "make all", log_path, "running");

    var result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
    });
    // notified_sessions is caller-owned (testing.allocator) — free or leak.
    defer freeNotifiedSessions(testing.allocator, &result);

    try testing.expectEqual(@as(usize, 1), result.checked_count);
    try testing.expectEqual(@as(usize, 1), result.notified_count);
    try testing.expectEqual(@as(usize, 1), result.deleted_count);
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_done"));

    const msg = try queueMessageForSession(&ctx.db, testing.allocator, "s_done");
    defer testing.allocator.free(msg);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, msg, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 999999999), obj.get("pid").?.integer);
    try testing.expectEqualStrings("make all", obj.get("command").?.string);
    try testing.expectEqualStrings("build finished ok", obj.get("stdout").?.string);
    try testing.expect(!obj.get("truncated").?.bool);
    try testing.expect(std.mem.indexOf(u8, msg, "\"\"\"\"\"") == null);
}

test "cleanupStaleBackgroundProcesses notifies with a not-found marker and still deletes when the log is missing" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    const missing = "/tmp/pabrik-bg-test-never-exists-xyz.log";
    try seedRowFull(&ctx.db, testing.allocator, "s_gone", 999_999_998, "sleep 30", missing, "running");

    var result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
    });
    // notified_sessions is caller-owned (testing.allocator) — free or leak.
    defer freeNotifiedSessions(testing.allocator, &result);

    try testing.expectEqual(@as(usize, 1), result.checked_count);
    try testing.expectEqual(@as(usize, 1), result.notified_count);
    try testing.expectEqual(@as(usize, 1), result.deleted_count);
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_gone"));

    const msg = try queueMessageForSession(&ctx.db, testing.allocator, "s_gone");
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "log file not found") != null);
    try testing.expect(std.mem.indexOf(u8, msg, missing) != null);
    try testing.expect(std.mem.indexOf(u8, msg, "999999998") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "sleep 30") != null);
}

test "cleanupStaleBackgroundProcesses keeps a row whose PID is still running (self)" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    // Self PID — guaranteed alive for the lifetime of this test process.
    const self_pid = process_status.getCurrentProcessIdInt();
    try seedRow(&ctx.db, testing.allocator, "s_alive", @intCast(self_pid), "stopped"); // status column is irrelevant per user spec

    var result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
        .io = testing.io,
        .event_bus = null,
    });
    // notified_sessions is caller-owned (testing.allocator) — free or leak.
    defer freeNotifiedSessions(testing.allocator, &result);

    try testing.expectEqual(@as(usize, 1), result.checked_count);
    try testing.expectEqual(@as(usize, 0), result.deleted_count);
    try testing.expectEqual(@as(usize, 1), result.kept_count);
    try testing.expectEqual(@as(usize, 1), try rowCountForSession(&ctx.db, testing.allocator, "s_alive"));
}

test "cleanupStaleBackgroundProcesses ignores the status column: keeps an alive row even when status='failed'" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    const self_pid = process_status.getCurrentProcessIdInt();
    // Status 'failed' is stale — but the PID is alive, so we keep it.
    try seedRow(&ctx.db, testing.allocator, "s_alive_failed", @intCast(self_pid), "failed");

    var result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
        .io = testing.io,
        .event_bus = null,
    });
    // notified_sessions is caller-owned (testing.allocator) — free or leak.
    defer freeNotifiedSessions(testing.allocator, &result);

    try testing.expectEqual(@as(usize, 1), result.kept_count);
    try testing.expectEqual(@as(usize, 0), result.deleted_count);
    try testing.expectEqual(@as(usize, 1), try rowCountForSession(&ctx.db, testing.allocator, "s_alive_failed"));
}

test "cleanupStaleBackgroundProcesses ignores the status column: deletes a dead row even when status='running'" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    // Status 'running' is stale (e.g. kill -9 left the row) — but the PID is dead, so we delete it.
    try seedRow(&ctx.db, testing.allocator, "s_dead_running", 999_999_998, "running");

    var result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
        .io = testing.io,
        .event_bus = null,
    });
    // notified_sessions is caller-owned (testing.allocator) — free or leak.
    defer freeNotifiedSessions(testing.allocator, &result);

    try testing.expectEqual(@as(usize, 1), result.deleted_count);
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_dead_running"));
}

test "cleanupStaleBackgroundProcesses processes a mixed batch and reports kept vs deleted correctly" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    const self_pid = process_status.getCurrentProcessIdInt();

    try seedRow(&ctx.db, testing.allocator, "s_alive_a", @intCast(self_pid), "running");
    try seedRow(&ctx.db, testing.allocator, "s_alive_b", @intCast(self_pid), "stopped");
    try seedRow(&ctx.db, testing.allocator, "s_dead_a", 999_999_997, "running");
    try seedRow(&ctx.db, testing.allocator, "s_dead_b", 999_999_996, "stopped");
    try seedRow(&ctx.db, testing.allocator, "s_dead_c", 999_999_995, "failed");

    var result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
        .io = testing.io,
        .event_bus = null,
    });
    // notified_sessions is caller-owned (testing.allocator) — free or leak.
    defer freeNotifiedSessions(testing.allocator, &result);

    try testing.expectEqual(@as(usize, 5), result.checked_count);
    try testing.expectEqual(@as(usize, 2), result.kept_count);
    try testing.expectEqual(@as(usize, 3), result.deleted_count);

    try testing.expectEqual(@as(usize, 1), try rowCountForSession(&ctx.db, testing.allocator, "s_alive_a"));
    try testing.expectEqual(@as(usize, 1), try rowCountForSession(&ctx.db, testing.allocator, "s_alive_b"));
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_dead_a"));
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_dead_b"));
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_dead_c"));
}

test "cleanupStaleBackgroundProcesses is a no-op when the table is empty" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    var result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
        .io = testing.io,
        .event_bus = null,
    });
    // notified_sessions is caller-owned (testing.allocator) — free or leak.
    defer freeNotifiedSessions(testing.allocator, &result);

    try testing.expectEqual(@as(usize, 0), result.checked_count);
    try testing.expectEqual(@as(usize, 0), result.kept_count);
    try testing.expectEqual(@as(usize, 0), result.deleted_count);
}

test "cleanupStaleBackgroundProcesses keeps a row whose PID is running even with malformed status string" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    const self_pid = process_status.getCurrentProcessIdInt();
    // 'banana' is a garbage status value — but since we ignore status entirely,
    // the row is kept as long as the PID is alive.
    try seedRow(&ctx.db, testing.allocator, "s_alive_garbage_status", @intCast(self_pid), "banana");

    var result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
        .io = testing.io,
        .event_bus = null,
    });
    // notified_sessions is caller-owned (testing.allocator) — free or leak.
    defer freeNotifiedSessions(testing.allocator, &result);

    try testing.expectEqual(@as(usize, 1), result.kept_count);
    try testing.expectEqual(@as(usize, 1), try rowCountForSession(&ctx.db, testing.allocator, "s_alive_garbage_status"));
}

test "cleanupStaleBackgroundProcesses returns the DB error when the session_background_process table is missing" {
    // Build a DB WITHOUT the table — the helper must propagate the
    // error rather than panic. The cron wrapper (handle) is responsible
    // for catching + logging.
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");
    // NO CREATE TABLE — the query will fail with "no such table".

    const result = cleanupStaleBackgroundProcesses(.{
        .allocator = alloc,
        .db = &db,
        .logger = null,
        .io = testing.io,
        .event_bus = null,
    });

    // We don't pin the exact error variant — SqliteBackend maps
    // missing-table to PrepareFailed (Sqlite.zig:568) which the helper
    // propagates verbatim.
    try testing.expectError(error.PrepareFailed, result);
}

test "cleanupStaleBackgroundProcesses batch-chunks deletes when more than max_pairs_per_stmt dead rows exist" {
    // Verify the chunking logic at the 499-pair boundary.
    var ctx = try setupCtx();
    defer ctx.deinit();

    const self_pid = process_status.getCurrentProcessIdInt();

    // 600 dead rows
    var i: i64 = 0;
    while (i < 600) : (i += 1) {
        // Use i64 PID 999_999_990 + i to stay below max i32 (≈2.1B).
        try seedRow(&ctx.db, testing.allocator, "s_dead", 999_999_990 + i, "running");
    }

    // 2 live rows under different session_ids (composite PK is
    // (session_id, pid); the same PID CAN appear under multiple
    // sessions, so this is a valid setup).
    try seedRow(&ctx.db, testing.allocator, "s_alive_a", @intCast(self_pid), "running");
    try seedRow(&ctx.db, testing.allocator, "s_alive_b", @intCast(self_pid), "running");

    var result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
        .io = testing.io,
        .event_bus = null,
    });
    // notified_sessions is caller-owned (testing.allocator) — free or leak.
    defer freeNotifiedSessions(testing.allocator, &result);

    try testing.expectEqual(@as(usize, 602), result.checked_count);
    try testing.expectEqual(@as(usize, 2), result.kept_count);
    try testing.expectEqual(@as(usize, 600), result.notified_count);
    try testing.expectEqual(@as(usize, 600), result.deleted_count);

    // All 600 dead rows gone
    var q = try ctx.db.query(testing.allocator, "SELECT COUNT(*) FROM session_background_process WHERE session_id = 's_dead'", &.{});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(testing.allocator);
        var count_buf: [32]u8 = undefined;
        const count_str = try std.fmt.bufPrint(&count_buf, "{s}", .{row.values[0]});
        try testing.expectEqualStrings("0", count_str);
    } else {
        return error.TestExpectedRow;
    }

    // Both alive rows still present
    try testing.expectEqual(@as(usize, 1), try rowCountForSession(&ctx.db, testing.allocator, "s_alive_a"));
    try testing.expectEqual(@as(usize, 1), try rowCountForSession(&ctx.db, testing.allocator, "s_alive_b"));
}

// ─── Task 3: notified_sessions + shouldWake ───────────────────────────────
// The wake loop in `handle()` needs the deduped session_ids that were
// notified this tick.

test "shouldWake wakes idle sessions and skips running ones" {
    try testing.expect(shouldWake(false));
    try testing.expect(!shouldWake(true));
}

test "cleanupStaleBackgroundProcesses exposes each notified session once (dedupe)" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    // Two dead PIDs under the SAME session + one dead PID under another.
    // 999_999_99x PIDs are virtually guaranteed to NOT exist.
    try seedRow(&ctx.db, testing.allocator, "s_dup", 999_999_991, "running");
    try seedRow(&ctx.db, testing.allocator, "s_dup", 999_999_992, "running");
    try seedRow(&ctx.db, testing.allocator, "s_other", 999_999_993, "running");

    var result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
        .io = testing.io,
        .event_bus = null,
    });
    defer freeNotifiedSessions(testing.allocator, &result);

    try testing.expectEqual(@as(usize, 3), result.checked_count);
    try testing.expectEqual(@as(usize, 3), result.notified_count);
    try testing.expectEqual(@as(usize, 3), result.deleted_count);

    // Deduped: 2 sessions, not 3 rows.
    try testing.expectEqual(@as(usize, 2), result.notified_sessions.len);

    var saw_dup = false;
    var saw_other = false;
    for (result.notified_sessions) |sid| {
        if (std.mem.eql(u8, sid, "s_dup")) {
            try testing.expect(!saw_dup); // exactly once
            saw_dup = true;
        } else if (std.mem.eql(u8, sid, "s_other")) {
            try testing.expect(!saw_other); // exactly once
            saw_other = true;
        } else {
            return error.TestUnexpectedSession;
        }
    }
    try testing.expect(saw_dup);
    try testing.expect(saw_other);
}

test "cleanupStaleBackgroundProcesses leaves notified_sessions empty when nothing is notified" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    // Only a live row (self PID) — nothing to notify.
    const self_pid = process_status.getCurrentProcessIdInt();
    try seedRow(&ctx.db, testing.allocator, "s_alive", @intCast(self_pid), "running");

    var result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
        .io = testing.io,
        .event_bus = null,
    });
    defer freeNotifiedSessions(testing.allocator, &result);

    try testing.expectEqual(@as(usize, 0), result.notified_count);
    try testing.expectEqual(@as(usize, 0), result.notified_sessions.len);
}

test "freeNotifiedSessions is idempotent and safe on empty results" {
    var empty = CleanupResult{};
    // No-op on the default empty slice (must NOT free static memory).
    freeNotifiedSessions(testing.allocator, &empty);
    try testing.expectEqual(@as(usize, 0), empty.notified_sessions.len);
    // Second call still safe.
    freeNotifiedSessions(testing.allocator, &empty);

    // Caller-owned list frees cleanly and resets.
    var owned = CleanupResult{};
    const s = try testing.allocator.dupe(u8, "s_x");
    const outer = try testing.allocator.alloc([]const u8, 1);
    outer[0] = s;
    owned.notified_sessions = outer;
    freeNotifiedSessions(testing.allocator, &owned);
    try testing.expectEqual(@as(usize, 0), owned.notified_sessions.len);
}

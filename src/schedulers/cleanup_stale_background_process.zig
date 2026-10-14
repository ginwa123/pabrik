//! Cronjob — delete stale rows from `session_background_process` whose PID
//! is no longer alive.
//!
//! Per the user spec, the only criterion for "stale" is "is the process
//! actually running?". The `status` column is deliberately ignored — it
//! can be stale (e.g. a `kill -9` left the row at `status='running'`
//! because the defer that updates it never ran), and a process can be
//! alive while the row says otherwise. The cross-platform
//! `helpers.process_status.isProcessRunning(pid)` helper is the source
//! of truth.
//!
//! Architecture: pure helper `cleanupStaleBackgroundProcesses(input) !CleanupResult`
//! does the work; thin `handle(ctx, now_unix) void` wrapper pulls
//! `*App` from the singleton and calls the helper. Per row:
//! parse (session_id, pid, command, log_path), call `isProcessRunning`,
//! keep if alive, otherwise queue the completion message via
//! `insertQueueMessage` (notify) and DELETE (only if notified).
//!
//! Cron registration is in `src/main.zig` right after the
//! `cleanup_stale_worker` registration, fired every minute on the minute.
//!
//! Schema (mirrors migration 014 — `src/migrations/migration.zig:218`):
//! ```sql
//! CREATE TABLE session_background_process (
//!     session_id TEXT NOT NULL,
//!     pid INTEGER NOT NULL,
//!     command TEXT NOT NULL,
//!     log_path TEXT NOT NULL,
//!     started_at INTEGER NOT NULL,
//!     status TEXT NOT NULL DEFAULT 'running',
//!     PRIMARY KEY (session_id, pid)
//! )
//! ```
//!
//! The DELETE must use BOTH (session_id, pid) because the PRIMARY KEY
//! is composite.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const process_status = @import("helpers").process_status;
const logger_mod = pabrikcore.loggermod;
const event_bus_mod = pabrikcore.event_bus;
// Route the bg-completion helpers + queue insert through `pabrikcore`
// (the `root` module) instead of @import'ing the agentic_loop files
// directly — same pattern as cleanup_stale_worker.zig's
// `pabrikcore.ai_mod.delete_worker`. The exe module compiles `main.zig`
// which reaches this file via the `pabrikcore` re-export; a direct
// relative @import here would put those files in TWO modules and fire
// Zig's "file exists in two modules" error. `insertQueueMessage` is
// re-exported by workflow.zig so no mod.zig change is needed for it;
// `background_process` has its own `pub const` in ai_workflow/tui/mod.zig.
const bg_proc = pabrikcore.ai_mod.background_process;
const ai_workflow = pabrikcore.ai_mod.ai_workflow;
// `migration.zig` lives in `src/migrations/` — one `..` up from
// `src/schedulers/`. Per project memory `project-test-use-migrations-module`:
// test setupDb MUST use `MigrationManager.registerAllMigrations +
// runMigrations()` to spin up an in-memory DB that walks ALL migrations
// from 001 → latest, never hand-roll CREATE TABLE bodies. The migration
// chain is the single source of truth; hand-rolled schemas drift from
// production the moment a new column or trigger lands.
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
    /// Deduped session_ids that were successfully notified this tick
    /// (one entry per session, even if several of its PIDs completed).
    /// Caller-owned: allocated with `input.allocator` (the per-tick arena
    /// in `handle`, `testing.allocator` in tests). Free with
    /// `freeNotifiedSessions` when done — or let the tick arena drop it.
    /// Empty (`&.{}`) when nothing was notified; never free the empty case.
    notified_sessions: [][]const u8 = &.{},
};

/// Pure seam for the Task 3 wake decision: wake the session iff no worker
/// is currently running on it. A running worker will drain the queued
/// completion message on its own loop iteration (`hasQueuedMessages ->
/// continue` in workflow.zig); an idle session needs an explicit
/// `emit_run_agent` kick or the queue row sits forever.
///
/// Kept as a named function (rather than inlining `!running` at the call
/// site) so the decision is unit-testable without a DB/singleton — the
/// live `emit_run_agent` path itself is covered by the Task 4 functional
/// test, which boots a real binary + tmpdir HOME.
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
//
// Three-phase notify-then-delete. Pass 1: SELECT every
// (session_id, pid, command, log_path) row and check the actual OS
// process via `helpers.process_status.isProcessRunning`. Dead processes
// are collected. Pass 1.5 (notify): for each dead pair, read the log
// (capped at `bg_proc.completion_log_cap_bytes`), build the completion
// envelope via `bg_proc.buildCompletionMessage`, and queue it with
// `insertQueueMessage` (SSE `queue_queued`, same as any queued user
// message — no new event name). Pass 2: batch DELETE only the pairs
// that were successfully notified. A pair whose notify fails (log
// unreadable for a reason OTHER than FileNotFound, or queue INSERT
// error) is left in the table for the next tick to retry. A missing
// log file is NOT a failure — the queue message carries a
// `(log file not found: {path})` marker and the row is still deleted.
//
// The `status` column is deliberately IGNORED — it can drift from
// reality (a `kill -9` leaves it at `'running'` because the defer that
// updates it never ran; or a process can be alive while the row says
// otherwise).
//
// Batching is chunked at `max_pairs_per_stmt` pairs per DELETE
// statement because SQLite's default `SQLITE_MAX_VARIABLE_NUMBER` is
// 999 and each pair binds 2 params — 499 pairs max per statement.
// Anything more becomes a second DELETE.
//
// Per-row isolation: if one row's log read / queue insert fails, log
// via `logger.?errFmt` and continue to the next row — the cron tick
// must NOT abort the whole cleanup on a single bad row. Per-chunk
// isolation for the DELETEs likewise: one bad batch logs and the tick
// continues to the next chunk.

/// Args for `notifySingleBackgroundCompletion` — one dead
/// (session_id, pid) pair plus the shared request-scoped handles.
/// All slices are borrowed (caller-owned); all message buffers are
/// allocated with `allocator` and only need to live for the call
/// (`insertQueueMessage` binds/copies synchronously — per-request
/// arena rule, no defer-free here).
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
};

/// Notify one dead background pair: read the log (capped), build the
/// completion envelope, queue it with `is_emit_sse=true`.
///
/// Moved verbatim out of the `cleanupStaleBackgroundProcesses` pass-1.5
/// loop so the immediate watcher thread (`background_watcher.zig`) can
/// reuse the exact same path. Returns true iff notified (caller deletes).
/// FileNotFound on the log → not-found marker (still notify). Any OTHER
/// log-read error, message-build error, or queue-INSERT error → false
/// (caller leaves the row for the next tick to retry). Never panics —
/// every failure is caught and logged via `logger.?errFmt`.
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
    if (bg_proc.readLogTruncated(allocator, io, args.log_path, bg_proc.completion_log_cap_bytes)) |tlog| {
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

    // Push the list change so the frontend drops its 5s poll and relies
    // on SSE. Emitted AFTER the queue insert succeeds (same tick that
    // deletes the row) — covers both the immediate watcher thread and
    // the per-minute cron fallback, which share this function.
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
/// `emit_run_agent` with `skip_initial_queue_message=true` so the run
/// drains the queued completion without duplicating a user message.
///
/// Moved verbatim out of the `handle()` wake loop so the immediate
/// watcher thread can reuse the exact same path. All errors are caught
/// and logged — never panics, never propagates.
pub fn wakeSessionForCompletion(di: *pabrikcore.App, allocator: std.mem.Allocator, sid: []const u8) void {
    const logger = di.logger;

    const running = ai_workflow.isWorkerRunning(allocator, di.db, sid);
    if (!shouldWake(running)) return;

    // Resolve the session row for the emit fields (same shape as
    // `startAgentUseCase` step 3). Missing row → safe defaults;
    // `emit_run_agent.insert_worker` upserts the session anyway.
    // Slices are duped into `allocator` BEFORE the row is released so they
    // outlive `row.deinit`.
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

    // Per-call arena for the dead-rows collection. The slice pointers
    // we collect from `row.values[0]` / `row.values[1]` are owned by
    // the row and freed on `row.deinit`; without the arena, we'd have
    // to dupe each one (or worse, use-after-free). Using a per-call
    // arena gives us "borrow the row's slice memory" semantics with
    // zero per-row alloc/free overhead — the arena frees everything
    // in one shot when this function returns.
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
        notified: bool = false,
    };
    var dead: std.ArrayListUnmanaged(DeadPair) = .empty;
    defer dead.deinit(a);

    // `kind = 'job'` is not an optimization — it is the OTHER HALF of
    // `mode="background_persistence"`'s contract. The immediate watcher is not
    // scheduled for a service, so this cron is the only remaining thing that
    // could notify one; without the filter it would queue "your dev server
    // exited" a month later, which is exactly the message the mode exists to
    // suppress. A row whose `kind` is NULL or anything else matches NOTHING and
    // would leak, so the column is NOT NULL DEFAULT 'job' (migration 107).
    const select_sql =
        \\SELECT session_id, pid, command, log_path
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

        result.checked_count += 1;

        // Defensive: skip rows with malformed PIDs rather than panic.
        // A row with a non-numeric PID is unrecoverable corruption.
        const pid = std.fmt.parseInt(i32, pid_str, 10) catch continue;

        // The single source of truth: is the process actually alive?
        // Cross-platform — uses kill(pid, 0) on POSIX, OpenProcess
        // with QUERY_LIMITED on Windows.
        if (process_status.isProcessRunning(pid)) {
            result.kept_count += 1;
            continue;
        }

        // Process is dead — collect the row for the notify (pass 1.5)
        // + batch DELETE (pass 2).
        //
        // CRITICAL: row.values[i] is freed by `row.deinit(a)` (which
        // fires at the end of this iteration block). Without duping,
        // the slices stored in `dead` would dangle by the time passes
        // 1.5 / 2 run. Duping into the arena gives us stable copies
        // that outlive every row.deinit() and live until arena.deinit()
        // at the end of this function.
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
    // completion message. Per-row isolation — one bad log or failed
    // INSERT logs and leaves that pair un-notified (it stays in the
    // table for the next tick); the loop always continues.
    //
    // All message buffers are arena-allocated (`a`): `insertQueueMessage`
    // binds/copies them into SQLite synchronously, so they only need to
    // live for the duration of the call. No defer-free of arena memory
    // here per the per-request arena rule.
    //
    // Body lives in `notifySingleBackgroundCompletion` (shared with the
    // immediate watcher thread) — this loop is just the per-pair call.
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
        })) {
            pair.notified = true;
            result.notified_count += 1;
        }
    }

    // Task 3: expose the deduped notified session_ids for the wake loop in
    // `handle()`. Built from `dead` (not `doomed`) so a session is woken
    // even if its DELETE chunk below fails — the queue message already
    // exists, so the agent run must still drain it.
    //
    // Ownership: duped into `input.allocator` (NOT the per-call arena `a`,
    // which is freed on return and would dangle the slices). In `handle()`
    // that allocator IS the per-tick arena, so the list lives exactly as
    // long as the wake loop needs it. In tests it is `testing.allocator`,
    // so each test must `freeNotifiedSessions` (DebugAllocator leaks
    // otherwise).
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

    // Pass 2: batch DELETE all successfully-notified rows in chunks.
    // Each chunk builds ONE statement of the form
    //   DELETE FROM session_background_process
    //   WHERE (session_id = ? AND pid = ?)
    //      OR (session_id = ? AND pid = ?)
    //      OR ...
    // The OR-chain form is the simplest portable SQLite pattern; it
    // binds exactly 2 params per pair and avoids the version-fuss of
    // row-value `IN ((?, ?), ...)` syntax. Composite PK means we MUST
    // match both session_id AND pid — the same PID can exist under
    // multiple sessions and deleting only by pid would clobber
    // unrelated rows.
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

/// Cron callback. Signature is fixed by
/// `cronjob_manager.register` (`kabelweb repo src/server/cronjob_manager.zig:87`):
/// `*const fn (ctx: ?*anyopaque, now_unix: i64) void`.
///
/// Returns `void` (not `!void`) — DB errors are caught and logged
/// inside, never propagated. The cron thread MUST NOT panic.
pub fn handle(ctx: ?*anyopaque, now_unix: i64) void {
    _ = ctx;
    _ = now_unix;

    const di = pabrikcore.getSingleton() catch return;
    const allocator = di.allocator;
    const logger = di.logger;

    // Per-tick arena — all SQL string allocations live for the
    // duration of the cleanupStaleBackgroundProcesses call. Cheaper
    // than per-row alloc/free and the arena frees them in one shot
    // when this scope exits.
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

    // Task 3: wake idle workers so the queued completion actually triggers
    // an agent run. `workflow.zig` drains `session_queue_messages` only
    // while a worker is running (`hasQueuedMessages -> continue`); when the
    // background job outlived the agent run, the queue row would sit idle
    // forever. For each notified session with NO running worker, kick one
    // via `emit_run_agent` with `skip_initial_queue_message=true` (the
    // kanban Start-agent pattern in `start_agent.zig`) so the run starts
    // and drains the completion output without duplicating a user message.
    // A session that already has a worker needs nothing — its loop will
    // drain the queue on the next iteration.
    //
    // Never crashes the tick: every per-session failure (worker check is
    // infallible by design; session lookup + emit are caught) is logged
    // and the loop continues. `result.notified_sessions` is arena-owned
    // (`a`) — no free needed (per-request arena rule).
    //
    // Body lives in `wakeSessionForCompletion` (shared with the immediate
    // watcher thread) — this loop is just the per-session call. `woken`
    // counts attempted wakes (emit failures are logged inside and still
    // count — they are rare and the next tick retries via cron fallback).
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
//
// Inline tests, matching the project convention for files that have
// impl + tests (delete_worker.zig, cleanup_stale_worker.zig).
// Aggregated into the test module graph via src/root.zig's test block.

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

    // Walk every production migration (001 → latest). After this returns,
    // the schema is exactly what a production DB looks like — including
    // the `session_background_process` table created by Migration 014.
    // No hand-rolled CREATE TABLE — that's the project convention
    // (see project-test-use-migrations-module memory; reviewer note on
    // PR #172: "when setup db, use from migrations module, migrations
    // module will load all table").
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{
        .db = db,
        .threaded = threaded,
    };
}

/// Insert a background-process row. `pid` is passed as an `i64` so SQLite
/// can coerce it to INTEGER (matching the production column type).
///
/// Uses `bufPrint` with a stack buffer so the test doesn't leak through
/// the DebugAllocator (PIDs fit easily in 32 bytes — i64 max is 19 chars).
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

/// Insert a background-process row with an explicit command + log_path
/// (for the notify-then-delete tests, which need a real temp log file
/// or a deliberately missing path). `seedRow` delegates with the
/// historical `'echo hi'` / `'/tmp/log'` defaults.
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
    // Verify the chunking logic at the 499-pair boundary. We seed 600
    // dead rows (PID 999_999_990..999_999_999 is more than enough
    // distinct dead PIDs at i64 magnitudes no real system would have).
    // 600 > 499 means the helper MUST issue at least 2 batch DELETEs
    // — the first 499-pair statement + a 101-pair statement. If the
    // chunking regressed to a single unbounded statement, SQLite would
    // either accept it (newer SQLite, variable limit 32766) or reject
    // it (older SQLite, limit 999). Either way, the externally
    // observable contract — "every dead row is gone, every alive row
    // stays, counts are accurate" — must still hold.
    //
    // We also seed 2 live rows (self PID × 2 distinct sessions) and
    // confirm they survive the cleanup.
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
//
// The wake loop in `handle()` needs the deduped session_ids that were
// notified this tick. The live `emit_run_agent` kick itself is NOT
// unit-tested here — it needs the process singleton (`getSingleton`) and
// an Io group, which only exist in a running binary. That path is covered
// by the Task 4 functional test (fresh binary + tmpdir HOME, real cron
// tick, assert the agent run drains the queued completion).

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

//! `pabrik db <subcommand>` — the operations that need the database to itself.
//! Peeking at argv[1] and returning false when it is not `db`, so `main` falls
//! through to the regular server boot (same shape as `pabrik service`).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const db_config = @import("db_config.zig");
const db_target = @import("db_target.zig");
const server_boot = @import("server_boot.zig");
const reclaim = pabrikcore.boot_db_reclaim;
const prune_logs = pabrikcore.prune_logs;
const archive_transcripts = pabrikcore.archive_transcripts;

pub const usage =
    \\usage: pabrik db reclaim [--database=sqlite|postgres] [--database-path=PATH]
    \\
    \\  reclaim   the maintenance window, in order: prune logs older than 30 days,
    \\            archive transcripts whose newest message is older than 90 days,
    \\            then leave WAL, set PRAGMA auto_vacuum = INCREMENTAL, VACUUM the
    \\            file back to the pages it actually uses, and return to WAL.
    \\
    \\ Stop the server first: the VACUUM needs the file to itself, and the
    \\ journal-mode switch needs an exclusive lock.
    \\
;

/// `archiveTranscripts` moves `sessions_per_tick` chats per call. A maintenance
/// run works the whole backlog down, this many calls deep, so it stays bounded
/// instead of opening an unbounded loop over a 5 GB database.
pub const archive_rounds: usize = 64;

/// Exit code the command uses for "ran, and the file is not in the state asked
/// for" — distinct from a crashed run, which Zig's own error return produces.
pub const drift_exit_code: u8 = 1;

pub fn dispatchDbSubcommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *std.process.Environ.Map,
    init: std.process.Init,
) !bool {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    _ = it.next();

    const arg1 = it.next() orelse return false;
    if (!std.mem.eql(u8, arg1, "db")) return false;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    while (it.next()) |arg| try argv.append(allocator, arg);

    const verb: []const u8 = if (argv.items.len == 0) "" else argv.items[0];
    if (verb.len == 0 or std.mem.eql(u8, verb, "help") or
        std.mem.eql(u8, verb, "--help") or std.mem.eql(u8, verb, "-h"))
    {
        if (verb.len == 0) std.log.err("db: a subcommand is required", .{});
        std.log.info("{s}", .{usage});
        return true;
    }

    if (!std.mem.eql(u8, verb, "reclaim")) {
        std.log.err("db: unknown subcommand {s}", .{verb});
        std.log.info("{s}", .{usage});
        return true;
    }

    if (comptime !reclaim.supported) {
        std.log.err("db reclaim: free pages are a sqlite concept, and this build opens postgres", .{});
        return true;
    }

    var request: db_target.Request = .{};
    {
        var leftover: std.ArrayList([]const u8) = .empty;
        defer leftover.deinit(allocator);
        db_target.parseArgs(allocator, argv.items, &request, &leftover) catch |err| {
            db_target.reportArgError(argv.items, err);
            return true;
        };
    }

    var overrides: std.ArrayList(db_config.Override) = .empty;
    defer overrides.deinit(allocator);
    db_config.parseOverrides(allocator, argv.items, &overrides) catch |err| {
        for (argv.items) |arg| {
            if (std.mem.startsWith(u8, arg, "--db-") or std.mem.startsWith(u8, arg, "--db_")) {
                db_config.reportOverrideError(arg, err);
            }
        }
        return true;
    };

    // The reclaim switches the journal mode, and sqlite refuses that while ANY
    // other connection has the file open — idle or not. The pooled readers are
    // the other connections, so this run opens with none. It is why the command
    // must be run with the server stopped: that server's readers are not ours to
    // close.
    overrides.append(allocator, .{ .knob = .read_conns, .raw = "0", .value = 0 }) catch
        return error.OutOfMemory;

    // The same open the server uses, so the file is migrated to the current
    // schema before anything is rewritten.
    const now_unix = std.Io.Clock.now(.real, io).toSeconds();

    var handles = server_boot.openDatabase(allocator, io, environment, request, overrides.items) catch |err| {
        if (db_target.isResolveError(err)) {
            db_target.reportResolveError(request, @errorCast(err));
            return true;
        }
        return err;
    };
    defer handles.deinit();

    const pruned = prune_logs.pruneLogs(.{
        .allocator = allocator,
        .db = &handles.db,
        .logger = null,
        .now_unix = now_unix,
    }) catch |err| {
        std.log.err("db reclaim: log prune failed: {s}", .{@errorName(err)});
        return err;
    };
    std.log.info("db reclaim: logs pruned={d} batches={d}", .{ pruned.deleted, pruned.batches });

    const archive_path = archive_transcripts.archivePathNear(allocator, handles.target.sqlite_path) catch |err| {
        std.log.err("db reclaim: no archive path: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(archive_path);

    var archived = archive_transcripts.ArchiveResult{};
    for (0..archive_rounds) |_| {
        const round = archive_transcripts.archiveTranscripts(.{
            .allocator = allocator,
            .db = &handles.db,
            .logger = null,
            .now_unix = now_unix,
            .archive_path = archive_path,
        }) catch |err| {
            std.log.err("db reclaim: transcript archive failed: {s}", .{@errorName(err)});
            return err;
        };
        if (round.sessions == 0) break;
        archived.sessions += round.sessions;
        archived.rows += round.rows;
    }
    std.log.info("db reclaim: transcripts archived sessions={d} rows={d} to {s}", .{
        archived.sessions, archived.rows, archive_path,
    });

    const report = reclaim.reclaim(&handles.db, allocator);
    if (report) |result| {
        defer allocator.free(result.journal_mode_after);

        std.log.info("db reclaim: auto_vacuum {s} -> {s}, journal_mode={s}", .{
            result.mode_before.text(),
            result.mode_after.text(),
            result.journal_mode_after,
        });
        std.log.info("db reclaim: {d} pages ({d} MiB) -> {d} pages ({d} MiB)", .{
            result.size_before.pages,
            result.size_before.mib(),
            result.size_after.pages,
            result.size_after.mib(),
        });

        if (result.mode_after != .incremental) {
            std.log.err("db reclaim: auto_vacuum is still {s}, so the VACUUM did not take", .{result.mode_after.text()});
            return error.AutoVacuumNotIncremental;
        }
        if (!std.mem.eql(u8, result.journal_mode_after, "wal")) {
            std.log.err("db reclaim: journal_mode is {s}, not wal — another connection holds the file", .{result.journal_mode_after});
            return error.JournalModeNotRestored;
        }
    } else |err| {
        std.log.err("db reclaim: {s}", .{@errorName(err)});
        return err;
    }

    return true;
}

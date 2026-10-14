const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;

/// Migration 107 — tag each background process with its KIND.
///
/// `session_background_process` (migration 014) recorded one thing: a
/// detached command, its log, and whether it was still alive. That was enough
/// while the only detached command was a long build. It is not enough now
/// that `command` has a 3-way `mode`, because the two detached modes differ
/// in an obligation the table cannot currently express:
///
///   * `background`             — a bounded JOB. The agent must be TOLD when
///                                it exits, so its log is queued and the
///                                session is woken.
///   * `background_persistence` — a SERVICE (a dev server, a watcher). It is
///                                deliberately SILENT: no message, ever. The
///                                agent reads its log when it wants to know
///                                something, and the only things that end it
///                                are an explicit stop or pabrik shutting
///                                down.
///
/// WHY A COLUMN, AND NOT A COMMAND-STRING HEURISTIC
///
/// "No queue message" has to hold in TWO independent places — the immediate
/// watcher must not be scheduled, and the per-minute cron must skip the row
/// (it notifies any dead PID it can see, so a dev server that finally exits a
/// month later would otherwise queue a message then). Without a recorded
/// kind, the second place has nothing to filter on. Inferring it from the
/// command text (`does it look like a server?`) would be a guess about a
/// string, in the one place where being wrong means the user is told their dev
/// server died, or is never told their build failed.
///
/// WHY `NOT NULL DEFAULT 'job'`
///
/// Every pre-107 row IS a job: only the `background` mode existed when it was
/// written, so the default is the correct backfill rather than a placeholder.
/// NOT NULL matters — a NULL would match NEITHER `kind = 'job'` nor
/// `kind = 'service'`, so the row would fall out of the cron AND out of the
/// service sweep at once and leak silently. `background_process.save` also
/// coerces an empty bind to 'job', because this backend binds an empty slice
/// as SQL NULL and NOT NULL would reject it.
pub const Migration107AddBackgroundProcessKind = struct {
    pub const version: u32 = 107;
    pub const name = "add_background_process_kind";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\ALTER TABLE session_background_process
            \\    ADD COLUMN kind TEXT NOT NULL DEFAULT 'job'
        , &[_][]const u8{});
    }
};

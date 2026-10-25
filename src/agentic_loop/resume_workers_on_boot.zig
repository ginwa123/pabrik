//! Restart the turns a previous process left mid-flight: a `worker` row is a
//! session whose run was cut off. Sub-agent workers, live owners and cleanly
//! finished turns are skipped — see `decide`, which is the whole policy.

const std = @import("std");
const pabrikcore = @import("pabrikcore");

const sqlite = pabrikcore.sqlite;
const session_lock = @import("session_lock.zig");
const testing = std.testing;

/// A `worker` row plus the session fields a resumed run needs.
pub const Candidate = struct {
    session_id: []const u8,
    name: []const u8,
    cwd: []const u8,
    selected_profile_model: []const u8,
    is_auto_retry_until_stop: []const u8,
    user_id: []const u8,
    last_finish_reason: []const u8,
    parent_session_id: []const u8,
    sub_agent_name: []const u8,
    has_queued_message: bool,
    run_token: []const u8,
};

/// A sub-agent session names its parent (Migration 091). The parent row in the
/// `worker` table is touched on behalf of a sub-agent too, so the parent's own
/// session is NOT a sub-agent — only a row whose session carries the marker is.
pub fn isSubAgentWorker(parent_session_id: []const u8, sub_agent_name: []const u8, session_id: []const u8) bool {
    if (sub_agent_name.len > 0) return true;
    if (parent_session_id.len == 0) return false;
    return !std.mem.eql(u8, parent_session_id, session_id);
}

/// A turn that finished without being interrupted: the row is a leftover.
pub fn isCleanTurnEnd(last_finish_reason: []const u8) bool {
    return std.mem.eql(u8, last_finish_reason, "stop") or
        std.mem.eql(u8, last_finish_reason, "awaiting_user");
}

pub const Decision = enum {
    /// The previous owner is gone and the turn was cut off: restart it.
    restart,
    /// Another live process still owns the lease — leave the session alone.
    skip_live_owner,
    skip_sub_agent,
    skip_finished,
};

/// What boot should do with one row. `owner_alive` comes from the pid embedded
/// in the lease (`session_lock.isOwnerAlive`): a second pabrik on another port
/// must NOT steal a session the first one is still running.
pub fn decide(candidate: Candidate, owner_alive: bool) Decision {
    if (isSubAgentWorker(candidate.parent_session_id, candidate.sub_agent_name, candidate.session_id)) return .skip_sub_agent;
    if (owner_alive) return .skip_live_owner;
    if (candidate.has_queued_message) return .restart;
    if (isCleanTurnEnd(candidate.last_finish_reason)) return .skip_finished;
    return .restart;
}

const select_sql =
    \\SELECT w.id,
    \\       COALESCE(s.name, ''),
    \\       COALESCE(s.cwd, ''),
    \\       COALESCE(s.selected_profile_model, ''),
    \\       COALESCE(s.is_auto_retry_until_stop, '0'),
    \\       COALESCE(s.user_id, ''),
    \\       COALESCE(s.last_finish_reason, ''),
    \\       COALESCE(s.parent_session_id, ''),
    \\       COALESCE(s.sub_agent_name, ''),
    \\       EXISTS (SELECT 1 FROM session_queue_messages q WHERE q.session_id = w.id),
    \\       COALESCE(w.run_token, '')
    \\FROM worker w
    \\LEFT JOIN sessions s ON s.id = w.session_id
    \\ORDER BY w.last_activity_nano DESC;
;

/// Wake every session a previous process left mid-turn. Never fails: a boot
/// sequence has nothing useful to do with the error.
pub fn resumeWorkersOnBoot(di: *pabrikcore.App) void {
    const logger = di.logger;
    var arena = std.heap.ArenaAllocator.init(di.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const candidates = readCandidates(allocator, di.db) catch |err| {
        logger.warnFmt("[resume_workers_on_boot] reading worker rows failed: {s}", .{@errorName(err)});
        return;
    };

    for (candidates) |candidate| {
        switch (decide(candidate, session_lock.isOwnerAlive(candidate.run_token))) {
            .skip_live_owner => {
                logger.infoFmt(
                    "[resume_workers_on_boot] session {s} is owned by a live run_token={s} — leaving it",
                    .{ candidate.session_id, candidate.run_token },
                );
                continue;
            },
            .skip_sub_agent => {
                clearWorkerRow(di, allocator, candidate.session_id);
                continue;
            },
            .skip_finished => {
                clearWorkerRow(di, allocator, candidate.session_id);
                continue;
            },
            .restart => {},
        }

        logger.infoFmt(
            "[resume_workers_on_boot] resuming session_id={s} last_finish_reason='{s}' queued={}",
            .{ candidate.session_id, candidate.last_finish_reason, candidate.has_queued_message },
        );

        clearWorkerRow(di, allocator, candidate.session_id);

        di.emit_run_agent(.{
            .session_id = candidate.session_id,
            .session_name = candidate.name,
            .queue_message = "",
            .cwd = candidate.cwd,
            .body_message = "",
            .allowed_tools = "",
            .image_urls = "",
            .selected_profile_model = candidate.selected_profile_model,
            .is_auto_retry_until_stop = candidate.is_auto_retry_until_stop,
            .skip_initial_queue_message = true,
            .user_id = candidate.user_id,
        }) catch |err| {
            logger.errFmt(
                "[resume_workers_on_boot] emit failed for session {s}: {s}",
                .{ candidate.session_id, @errorName(err) },
            );
        };
    }
}

/// The `worker` rows as resume candidates — the query half, so the SQL is
/// testable without a booted app.
pub fn readCandidates(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) ![]Candidate {
    var rows = try db.query(allocator, select_sql, &.{});
    defer rows.deinit();

    var out: std.ArrayList(Candidate) = .empty;
    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        try out.append(allocator, .{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .cwd = try allocator.dupe(u8, row.values[2]),
            .selected_profile_model = try allocator.dupe(u8, row.values[3]),
            .is_auto_retry_until_stop = try allocator.dupe(u8, row.values[4]),
            .user_id = try allocator.dupe(u8, row.values[5]),
            .last_finish_reason = try allocator.dupe(u8, row.values[6]),
            .parent_session_id = try allocator.dupe(u8, row.values[7]),
            .sub_agent_name = try allocator.dupe(u8, row.values[8]),
            .has_queued_message = std.mem.eql(u8, row.values[9], "1"),
            .run_token = try allocator.dupe(u8, row.values[10]),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Drop the row the previous process wrote. Its lease belongs to a process that
/// no longer exists, so it must not block the run this boot is about to emit.
fn clearWorkerRow(di: *pabrikcore.App, allocator: std.mem.Allocator, session_id: []const u8) void {
    di.db.exec(allocator, "DELETE FROM worker WHERE id = ?", &.{session_id}) catch |err| {
        di.logger.warnFmt(
            "[resume_workers_on_boot] clearing worker row failed session_id={s}: {s}",
            .{ session_id, @errorName(err) },
        );
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb(alloc: std.mem.Allocator) !TestCtx {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    last_activity_nano INTEGER,
        \\    run_token TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    cwd TEXT,
        \\    selected_profile_model TEXT,
        \\    is_auto_retry_until_stop TEXT,
        \\    user_id TEXT,
        \\    last_finish_reason TEXT,
        \\    parent_session_id TEXT,
        \\    sub_agent_name TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE session_queue_messages (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, message TEXT NOT NULL)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn plain(session_id: []const u8, last_finish_reason: []const u8) Candidate {
    return .{
        .session_id = session_id,
        .name = "",
        .cwd = "/tmp",
        .selected_profile_model = "",
        .is_auto_retry_until_stop = "0",
        .user_id = "",
        .last_finish_reason = last_finish_reason,
        .parent_session_id = "",
        .sub_agent_name = "",
        .has_queued_message = false,
        .run_token = "",
    };
}

test "an interrupted turn is resumed" {
    try testing.expectEqual(Decision.restart, decide(plain("s1", "tool_calls"), false));
}

test "a cleanly finished turn with nothing queued is left alone" {
    try testing.expectEqual(Decision.skip_finished, decide(plain("s1", "stop"), false));
}

test "a cleanly finished turn waiting on the user is left alone" {
    try testing.expectEqual(Decision.skip_finished, decide(plain("s1", "awaiting_user"), false));
}

test "a cleanly finished turn with a queued message is resumed" {
    var c = plain("s1", "stop");
    c.has_queued_message = true;
    try testing.expectEqual(Decision.restart, decide(c, false));
}

test "a sub-agent worker is never resumed" {
    var c = plain("child", "tool_calls");
    c.parent_session_id = "parent";
    c.sub_agent_name = "researcher";
    c.has_queued_message = true;
    try testing.expectEqual(Decision.skip_sub_agent, decide(c, false));
}

test "a session a live process still owns is left alone" {
    var c = plain("shared", "tool_calls");
    c.run_token = "run-4242-1-2";
    c.has_queued_message = true;
    try testing.expectEqual(Decision.skip_live_owner, decide(c, true));
}

test "the same session is resumed once its owner is gone" {
    var c = plain("shared", "tool_calls");
    c.run_token = "run-4242-1-2";
    try testing.expectEqual(Decision.restart, decide(c, false));
}

test "a session pointing at itself is a parent, not a sub-agent" {
    try testing.expect(!isSubAgentWorker("s1", "", "s1"));
    try testing.expect(isSubAgentWorker("parent", "", "child"));
    try testing.expect(isSubAgentWorker("", "researcher", "child"));
}

test "readCandidates returns the session fields a resumed run needs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try setupDb(alloc);
    defer teardown(&ctx);

    try ctx.db.exec(alloc,
        \\INSERT INTO sessions (id, name, cwd, selected_profile_model, is_auto_retry_until_stop, user_id, last_finish_reason, parent_session_id, sub_agent_name)
        \\VALUES ('s1', 'Fix login', '/work', 'claude', '1', 'u1', 'tool_calls', '', '')
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO worker (id, session_id, last_activity_nano, run_token) VALUES ('s1', 's1', 1, 'stale-token')
    , &.{});

    const got = try readCandidates(alloc, &ctx.db);

    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("s1", got[0].session_id);
    try testing.expectEqualStrings("Fix login", got[0].name);
    try testing.expectEqualStrings("/work", got[0].cwd);
    try testing.expectEqualStrings("claude", got[0].selected_profile_model);
    try testing.expectEqualStrings("1", got[0].is_auto_retry_until_stop);
    try testing.expectEqualStrings("u1", got[0].user_id);
    try testing.expectEqualStrings("tool_calls", got[0].last_finish_reason);
    try testing.expect(!got[0].has_queued_message);
    try testing.expectEqualStrings("stale-token", got[0].run_token);
    try testing.expectEqual(Decision.restart, decide(got[0], false));
}

test "readCandidates reports a pending queued message for the session" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try setupDb(alloc);
    defer teardown(&ctx);

    try ctx.db.exec(alloc,
        \\INSERT INTO sessions (id, last_finish_reason) VALUES ('s1', 'stop')
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO worker (id, session_id, last_activity_nano) VALUES ('s1', 's1', 1)
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO session_queue_messages (id, session_id, message) VALUES ('q1', 's1', 'next')
    , &.{});

    const got = try readCandidates(alloc, &ctx.db);

    try testing.expect(got[0].has_queued_message);
    try testing.expectEqual(Decision.restart, decide(got[0], false));
}

test "readCandidates falls back to defaults when the session row is gone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var ctx = try setupDb(alloc);
    defer teardown(&ctx);

    try ctx.db.exec(alloc,
        \\INSERT INTO worker (id, session_id, last_activity_nano) VALUES ('gone', 'gone', 1)
    , &.{});

    const got = try readCandidates(alloc, &ctx.db);

    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("", got[0].name);
    try testing.expectEqualStrings("0", got[0].is_auto_retry_until_stop);
    try testing.expectEqualStrings("", got[0].last_finish_reason);
}

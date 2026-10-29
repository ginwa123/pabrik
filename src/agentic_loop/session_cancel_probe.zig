//! "Has this session been cancelled?" for a tool that blocks its thread: one
//! throttled, LATCHING read of `worker.cancelled` — `workflow` resets that
//! column each turn, so re-reading it would un-cancel a Stop already seen.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const database = pabrikcore.database;
const shell = pabrikcore.shell_tool;

const is_worker_cancelled_mod = @import("is_worker_cancelled.zig");

pub const Probe = struct {
    db: *database.Db,
    session_id: []const u8,
    io: std.Io,
    /// 50 ms: two orders of magnitude below the shortest `command` timeout, so
    /// Stop feels immediate, and low enough that a long build does not hammer
    /// the database with reads.
    poll_interval_ns: i96 = 50 * std.time.ns_per_ms,
    last_poll_ns: i96 = 0,
    latched: bool = false,

    pub fn init(db: *database.Db, session_id: []const u8, io: std.Io) Probe {
        return .{ .db = db, .session_id = session_id, .io = io };
    }

    /// True once the session has been cancelled. Cheap to call in a poll loop.
    pub fn cancelled(self: *Probe) bool {
        if (self.latched) return true;
        if (self.session_id.len == 0) return false;

        const now_ns = std.Io.Clock.now(.real, self.io).nanoseconds;
        if (self.last_poll_ns != 0 and now_ns - self.last_poll_ns < self.poll_interval_ns) {
            return false;
        }
        self.last_poll_ns = now_ns;

        // `page_allocator`, like the MCP lease probe: this runs on a waiting
        // path that has no arena of its own, and the allocation is one short
        // row per poll.
        const was_cancelled = is_worker_cancelled_mod.isWorkerCancelled(.{
            .allocator = std.heap.page_allocator,
            .db = self.db,
            .session_id = self.session_id,
        });
        if (was_cancelled) self.latched = true;
        return was_cancelled;
    }

    /// Erase the probe into the `fn (ctx) bool` shape the shell polls. The
    /// returned hook borrows `self`, so it must not outlive the dispatch.
    pub fn hook(self: *Probe) shell.CancelHook {
        return .{ .ctx = @ptrCast(self), .is_cancelled = probe };
    }

    fn probe(context: *const anyopaque) bool {
        // `ctx` is const only because the hook's signature says so; the
        // probe's own throttle/latch state is genuinely mutated.
        const self: *Probe = @ptrCast(@alignCast(@constCast(context)));
        return self.cancelled();
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const test_db = pabrikcore.test_db;
const testing = std.testing;

fn setupDb() !struct { db: database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc,
        \\CREATE TABLE worker (id TEXT PRIMARY KEY, cancelled INTEGER DEFAULT 0)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Probe: a live session is not cancelled" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO worker (id, cancelled) VALUES ('live', 0)", &.{});

    var p = Probe.init(&s.db, "live", s.threaded.io());
    p.poll_interval_ns = 0;
    try testing.expect(!p.cancelled());
    try testing.expect(!p.cancelled());
}

test "Probe: flips to true when the Stop button sets the row" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO worker (id, cancelled) VALUES ('s1', 0)", &.{});

    var p = Probe.init(&s.db, "s1", s.threaded.io());
    p.poll_interval_ns = 0;
    try testing.expect(!p.cancelled());

    try s.db.exec(testing.allocator, "UPDATE worker SET cancelled = 1 WHERE id = 's1'", &.{});
    try testing.expect(p.cancelled());
}

test "Probe: latches, so the row being reset by the next iteration does not un-cancel it" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO worker (id, cancelled) VALUES ('s2', 1)", &.{});

    var p = Probe.init(&s.db, "s2", s.threaded.io());
    p.poll_interval_ns = 0;
    try testing.expect(p.cancelled());

    // `session_lock.beginIteration`/`updateWorker` reset the column for the
    // next turn. The probe already answered — it must keep answering true.
    try s.db.exec(testing.allocator, "UPDATE worker SET cancelled = 0 WHERE id = 's2'", &.{});
    try testing.expect(p.cancelled());
}

test "Probe: the throttle skips the query, but never the latch" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO worker (id, cancelled) VALUES ('s3', 0)", &.{});

    var p = Probe.init(&s.db, "s3", s.threaded.io());
    p.poll_interval_ns = std.time.ns_per_s * 60;
    try testing.expect(!p.cancelled());
    try s.db.exec(testing.allocator, "UPDATE worker SET cancelled = 1 WHERE id = 's3'", &.{});
    // Inside the window: no query, so the fresh flag is not observed yet …
    try testing.expect(!p.cancelled());
    // … and once the window passes it is.
    p.last_poll_ns = 0;
    try testing.expect(p.cancelled());
}

test "Probe: a session with no id never queries" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    var p = Probe.init(&s.db, "", s.threaded.io());
    p.poll_interval_ns = 0;
    try testing.expect(!p.cancelled());
}

test "Probe: the hook erases the pointer and reports the same answer" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO worker (id, cancelled) VALUES ('s4', 1)", &.{});

    var p = Probe.init(&s.db, "s4", s.threaded.io());
    p.poll_interval_ns = 0;
    const hook = p.hook();
    try testing.expect(hook.requested());
}

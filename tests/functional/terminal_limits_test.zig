// Functional wire test for terminal max-20 cap + 429. Zig port of
// `tests/functional/terminal_limits_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// The server's own cap (`terminal_session.max_sessions`). Both tests
/// fill exactly this many sessions before probing the 21st.
const MAX_SESSIONS: usize = 20;

/// `POST /api/terminal/sessions` with the frontend's exact body shape,
/// spawning a shell rooted at the harness's isolated tempdir.
fn createTerminal(h: *Harness, expect: []const u16) !harness.Response {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .cwd = h.temp_dir,
        .cols = 80,
        .rows = 24,
    }, .{});
    defer gpa.free(body);

    return h.http(io, .POST, "/api/terminal/sessions", .{
        .json_body = body,
        .expect = expect,
    });
}

/// `DELETE /api/terminal/sessions/<id>` — 200 when it was live, 404 when
/// the server already reaped it (either status is fine for cleanup).
fn deleteTerminal(h: *Harness, id: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/terminal/sessions/{s}", .{id});
    defer gpa.free(path);
    var r = try h.http(io, .DELETE, path, .{ .expect = &.{ 200, 404 } });
    defer r.deinit();
}

/// Python's `try/finally` cleanup block: every id the test created is torn
/// down whether the assertions passed or not. Zig spells that as a `defer`
/// that owns the id list.
const SessionBag = struct {
    h: *Harness,
    ids: std.ArrayList([]u8) = .empty,

    fn init(h: *Harness) SessionBag {
        return .{ .h = h };
    }

    fn track(self: *SessionBag, id: []const u8) !void {
        try self.ids.append(gpa, try gpa.dupe(u8, id));
    }

    /// Hand back the most-recently-added id, freeing the copy.
    /// The Python original used `ids.pop()` on the same list.
    fn popNewest(self: *SessionBag) ![]u8 {
        const last = self.ids.pop().?;
        return last;
    }

    fn deinit(self: *SessionBag) void {
        for (self.ids.items) |id| {
            deleteTerminal(self.h, id) catch {};
            gpa.free(id);
        }
        self.ids.deinit(gpa);
    }
};

/// Create `n` sessions, tracking every id. Fails the test if any
/// create does not answer 201.
fn fillTerminals(h: *Harness, bag: *SessionBag, n: usize) !void {
    for (0..n) |_| {
        var r = try createTerminal(h, &.{201});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const id = doc.str("id") orelse {
            std.debug.print("terminal create returned no id: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        try testing.expect(id.len > 0);
        try bag.track(id);
    }
}

// 20 live sessions fill the cap; the 21st is rejected with 429.
test "21st_terminal_returns_429" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var bag = SessionBag.init(&h);
    defer bag.deinit();

    try fillTerminals(&h, &bag, MAX_SESSIONS);

    var rejected = try createTerminal(&h, &.{429});
    defer rejected.deinit();
    var doc = try rejected.json();
    defer doc.deinit();

    // makeErrorResponse shape: { error: <message> }. Python accepted
    // the substring anywhere in the rendered body; the contract under
    // test is that the cap is NAMED in the error.
    const message = doc.str("error") orelse {
        std.debug.print("429 body should carry an `error` field, got: {s}\n", .{rejected.body});
        return error.TestUnexpectedResult;
    };
    if (std.ascii.indexOfIgnoreCase(message, "max 20") == null) {
        std.debug.print("429 error should name the cap, got: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }
}

// After DELETE, a new create succeeds again (slot freed).
test "delete_frees_a_slot" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var bag = SessionBag.init(&h);
    defer bag.deinit();

    try fillTerminals(&h, &bag, MAX_SESSIONS);

    // The cap really is full — probe it before freeing anything, so a
    // later "the slot was free all along" cannot explain the pass.
    {
        var rejected = try createTerminal(&h, &.{429});
        defer rejected.deinit();
    }

    // Free one slot.
    const freed = try bag.popNewest();
    defer gpa.free(freed);
    try deleteTerminal(&h, freed);

    // The 21st create now succeeds.
    var recreated = try createTerminal(&h, &.{201});
    defer recreated.deinit();
    var doc = try recreated.json();
    defer doc.deinit();

    const id = doc.str("id") orelse {
        std.debug.print("recreate returned no id: {s}\n", .{recreated.body});
        return error.TestUnexpectedResult;
    };
    try testing.expect(id.len > 0);
    try bag.track(id);
}

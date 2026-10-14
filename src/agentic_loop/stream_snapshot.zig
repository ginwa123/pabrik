//! Stream snapshot registry — in-flight LLM stream buffer per session.
//! 2026-09-02 stream-resume-on-reselect (task_1787673548905_0): When the user
//! closes/re-selects a chat session mid-stream, ChatView drops its

const std = @import("std");

const State = enum {
    idle,
    streaming,
};

pub const Snapshot = struct {
    active: bool,
    content: []const u8,
};

/// Zig 0.16 removed `std.Thread.Mutex` — use `std.atomic.Mutex` (an
/// enum with tryLock/unlock) wrapped in a spinlock, matching the
/// pattern in kabelweb server/security.zig:114.
var mutex: std.atomic.Mutex = .unlocked;

fn mutexLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}
var registry: ?std.StringHashMap(*Entry) = null;

pub const Entry = struct {
    allocator: std.mem.Allocator,
    state: State = .idle,
    /// Accumulated content for the in-flight turn. Owned by this entry.
    content: std.ArrayList(u8) = .empty,

    fn deinit(self: *Entry) void {
        self.content.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

fn ensureInit() void {
    if (registry == null) {
        // The registry is a process-global singleton — it MUST NOT live in a
        // caller's arena (each test / request passes a different arena that
        // dies at scope exit). page_allocator gives it process lifetime.
        registry = std.StringHashMap(*Entry).init(std.heap.page_allocator);
    }
}

/// Mark a stream as started for `session_id` (clears any stale buffer).
pub fn beginStream(allocator: std.mem.Allocator, session_id: []const u8) void {
    _ = allocator;
    mutexLock(&mutex);
    defer mutex.unlock();
    ensureInit();

    const gop = registry.?.getOrPut(session_id) catch return;
    if (!gop.found_existing) {
        const key = std.heap.page_allocator.dupe(u8, session_id) catch return;
        gop.key_ptr.* = key;
        const entry = std.heap.page_allocator.create(Entry) catch return;
        entry.* = .{ .allocator = std.heap.page_allocator };
        gop.value_ptr.* = entry;
    }
    const entry = gop.value_ptr.*;
    entry.content.clearRetainingCapacity();
    entry.state = .streaming;
}

/// Append one content delta to the in-flight buffer.
pub fn appendContent(allocator: std.mem.Allocator, session_id: []const u8, delta: []const u8) void {
    if (delta.len == 0) return;
    _ = allocator;
    mutexLock(&mutex);
    defer mutex.unlock();
    ensureInit();

    const gop = registry.?.getOrPut(session_id) catch return;
    if (!gop.found_existing) {
        // Defensive: append without beginStream still works.
        const key = std.heap.page_allocator.dupe(u8, session_id) catch return;
        gop.key_ptr.* = key;
        const entry = std.heap.page_allocator.create(Entry) catch return;
        entry.* = .{ .allocator = std.heap.page_allocator };
        gop.value_ptr.* = entry;
    }
    gop.value_ptr.*.content.appendSlice(std.heap.page_allocator, delta) catch {};
}

/// Mark the stream as finished. Content stays readable until the next
/// `beginStream` so a late poll right after finish still sees the text,
/// but `active` becomes false.
pub fn endStream(allocator: std.mem.Allocator, session_id: []const u8) void {
    _ = allocator;
    mutexLock(&mutex);
    defer mutex.unlock();
    if (registry) |*reg| {
        if (reg.getPtr(session_id)) |entry_ptr| {
            entry_ptr.*.state = .idle;
        }
    }
}

/// Read the current snapshot. `content` is duped into `allocator`
/// (the caller's arena); the registry keeps its own copy.
pub fn getSnapshot(allocator: std.mem.Allocator, session_id: []const u8) !Snapshot {
    mutexLock(&mutex);
    defer mutex.unlock();
    if (registry) |*reg| {
        if (reg.getPtr(session_id)) |entry_ptr| {
            const e = entry_ptr.*;
            return .{
                .active = e.state == .streaming,
                .content = try allocator.dupe(u8, e.content.items),
            };
        }
    }
    return .{ .active = false, .content = "" };
}

// ─── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "stream_snapshot idle session returns inactive empty snapshot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const snap = try getSnapshot(a, "session-does-not-exist");
    try testing.expectEqual(false, snap.active);
    try testing.expectEqualStrings("", snap.content);
}

test "stream_snapshot begin + append accumulates deltas" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    beginStream(a, "session-accum");
    appendContent(a, "session-accum", "Hello, ");
    appendContent(a, "session-accum", "world!");

    const snap = try getSnapshot(a, "session-accum");
    try testing.expectEqual(true, snap.active);
    try testing.expectEqualStrings("Hello, world!", snap.content);
}

test "stream_snapshot endStream flips active but keeps content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    beginStream(a, "session-end");
    appendContent(a, "session-end", "partial text");
    endStream(a, "session-end");

    const snap = try getSnapshot(a, "session-end");
    try testing.expectEqual(false, snap.active);
    try testing.expectEqualStrings("partial text", snap.content);
}

test "stream_snapshot beginStream clears stale buffer from previous turn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    beginStream(a, "session-reuse");
    appendContent(a, "session-reuse", "old turn content");
    endStream(a, "session-reuse");

    // New turn begins → buffer must be empty again.
    beginStream(a, "session-reuse");
    const snap = try getSnapshot(a, "session-reuse");
    try testing.expectEqual(true, snap.active);
    try testing.expectEqualStrings("", snap.content);
}

test "stream_snapshot sessions are isolated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    beginStream(a, "session-a");
    beginStream(a, "session-b");
    appendContent(a, "session-a", "AAA");
    appendContent(a, "session-b", "BBB");

    const snap_a = try getSnapshot(a, "session-a");
    const snap_b = try getSnapshot(a, "session-b");
    try testing.expectEqualStrings("AAA", snap_a.content);
    try testing.expectEqualStrings("BBB", snap_b.content);
}

test "stream_snapshot empty delta append is a no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    beginStream(a, "session-empty-delta");
    appendContent(a, "session-empty-delta", "");
    const snap = try getSnapshot(a, "session-empty-delta");
    try testing.expectEqual(true, snap.active);
    try testing.expectEqualStrings("", snap.content);
}

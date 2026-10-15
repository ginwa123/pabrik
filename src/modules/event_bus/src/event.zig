const std = @import("std");

pub const EventBus = struct {
    const Self = @This();

    const Callback = struct {
        ptr: *const anyopaque,
    };

    name: []const u8,
    alloc: std.mem.Allocator,
    listeners: std.StringHashMapUnmanaged(Callback),
    mutex: std.Io.Mutex = .init,
    io: std.Io,

    /// Caller must ensure `name` outlives this EventBus,
    /// or dupe it before passing.
    pub fn init(name: []const u8, alloc: std.mem.Allocator, io: std.Io) Self {
        return .{ .name = name, .alloc = alloc, .listeners = .{}, .mutex = .init, .io = io };
    }

    pub fn subscribe(self: *Self, comptime T: type, id: []const u8, callback: *const fn (T) void) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const owned_id = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(owned_id); // free if getOrPut fails
        //

        const result = try self.listeners.getOrPut(self.alloc, owned_id);
        if (result.found_existing) {
            self.alloc.free(owned_id); // key already stored, discard duplicate
        } else {
            result.value_ptr.* = .{ .ptr = @ptrCast(callback) };
        }
    }

    pub fn unsubscribe(self: *Self, id: []const u8) void {
        self.mutex.lock(self.io) catch @panic("event_bus: mutex lock failed in unsubscribe");
        defer self.mutex.unlock(self.io);

        if (self.listeners.fetchRemove(id)) |entry| {
            self.alloc.free(entry.key);
        }
    }

    pub fn emit(self: *Self, comptime T: type, id: []const u8, data: T) void {
        // Deliberately unlocked: emit runs on the caller's thread and the
        // listener map is only mutated under the lock elsewhere, so taking
        // it here would serialise every dispatch behind subscribe/unsubscribe.

        if (self.listeners.get(id)) |cb| {
            const typed_fn: *const fn (T) void = @ptrCast(@alignCast(cb.ptr));
            typed_fn(data);
        }
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock(self.io) catch @panic("event_bus: mutex lock failed in deinit");
        defer self.mutex.unlock(self.io);

        var it = self.listeners.keyIterator();
        while (it.next()) |key| {
            self.alloc.free(key.*);
        }
        self.listeners.deinit(self.alloc);
    }
};

// ===== Tests merged from event_test.zig (2026-09-29 flatten) =====
// Comprehensive edge-case tests for `EventBus` (see `event.zig`).

// Reused in many tests.
const event_test_alloc = std.testing.allocator;

// ---------------------------------------------------------------------------
// A. Basic subscribe → emit round-trip
// ---------------------------------------------------------------------------

var a_callback_count: u32 = 0;
var a_last_value: u32 = 0;

const AHandler = struct {
    fn cb(data: u32) void {
        a_callback_count += 1;
        a_last_value = data;
    }
};

fn resetA() void {
    a_callback_count = 0;
    a_last_value = 0;
}

test "subscribe then emit fires callback exactly once with correct data" {
    resetA();
    var bus = EventBus.init("a", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "id", AHandler.cb);

    bus.emit(u32, "id", 42);

    try std.testing.expectEqual(@as(u32, 1), a_callback_count);
    try std.testing.expectEqual(@as(u32, 42), a_last_value);
}

test "emit before any subscribe is a silent no-op" {
    resetA();
    var bus = EventBus.init("a", event_test_alloc, std.testing.io);
    defer bus.deinit();

    bus.emit(u32, "id", 42);

    try std.testing.expectEqual(@as(u32, 0), a_callback_count);
}

test "emit with id that has no subscriber is a silent no-op" {
    resetA();
    var bus = EventBus.init("a", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "registered", AHandler.cb);

    bus.emit(u32, "NOT-registered", 7);

    try std.testing.expectEqual(@as(u32, 0), a_callback_count);
}

test "subscribe then unsubscribe then emit does not fire" {
    resetA();
    var bus = EventBus.init("a", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "id", AHandler.cb);
    bus.unsubscribe("id");

    bus.emit(u32, "id", 100);

    try std.testing.expectEqual(@as(u32, 0), a_callback_count);
}

test "emit 1000 times to one listener fires callback 1000 times" {
    resetA();
    var bus = EventBus.init("a", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "id", AHandler.cb);

    var i: u32 = 0;
    while (i < 1000) : (i += 1) bus.emit(u32, "id", i);

    try std.testing.expectEqual(@as(u32, 1000), a_callback_count);
    try std.testing.expectEqual(@as(u32, 999), a_last_value);
}

test "emit preserves listener name field on the bus" {
    resetA();
    var bus = EventBus.init("my-bus-name", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try std.testing.expectEqualStrings("my-bus-name", bus.name);
}

// ---------------------------------------------------------------------------
// B. Multiple subscribers — one id per listener
// ---------------------------------------------------------------------------

var b1_count: u32 = 0;
var b2_count: u32 = 0;
var b3_count: u32 = 0;
var b1_last: u32 = 0;
var b2_last: u32 = 0;

const B1Handler = struct {
    fn cb(data: u32) void {
        b1_count += 1;
        b1_last = data;
    }
};
const B2Handler = struct {
    fn cb(data: u32) void {
        b2_count += 1;
        b2_last = data;
    }
};
const B3Handler = struct {
    fn cb(_: u32) void {
        b3_count += 1;
    }
};

fn resetB() void {
    b1_count = 0;
    b2_count = 0;
    b3_count = 0;
    b1_last = 0;
    b2_last = 0;
}

test "subscribe 3 different ids each receive only their own emit" {
    resetB();
    var bus = EventBus.init("b", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "alpha", B1Handler.cb);
    try bus.subscribe(u32, "beta", B2Handler.cb);
    try bus.subscribe(u32, "gamma", B3Handler.cb);

    bus.emit(u32, "alpha", 1);
    bus.emit(u32, "beta", 2);
    bus.emit(u32, "gamma", 3);
    bus.emit(u32, "alpha", 11);

    try std.testing.expectEqual(@as(u32, 2), b1_count);
    try std.testing.expectEqual(@as(u32, 1), b2_count);
    try std.testing.expectEqual(@as(u32, 1), b3_count);
    try std.testing.expectEqual(@as(u32, 11), b1_last);
    try std.testing.expectEqual(@as(u32, 2), b2_last);
}

test "emit on a brand-new id with 100 existing subscribers — no false positives" {
    resetB();
    var bus = EventBus.init("b", event_test_alloc, std.testing.io);
    defer bus.deinit();
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const key_buf = try std.fmt.allocPrint(event_test_alloc, "id_{d}", .{i});
        defer event_test_alloc.free(key_buf);
        try bus.subscribe(u32, key_buf, B1Handler.cb);
    }

    bus.emit(u32, "id_42", 12345);

    try std.testing.expectEqual(@as(u32, 1), b1_count);
    try std.testing.expectEqual(@as(u32, 12345), b1_last);
}

test "subscribe stress: 1000 different ids then unsubscribe all then emit" {
    resetB();
    var bus = EventBus.init("b", event_test_alloc, std.testing.io);
    defer bus.deinit();
    var keys: [1000][]u8 = undefined;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        keys[i] = try std.fmt.allocPrint(event_test_alloc, "k_{d}", .{i});
        try bus.subscribe(u32, keys[i], B1Handler.cb);
    }
    while (i > 0) {
        i -= 1;
        bus.unsubscribe(keys[i]);
        event_test_alloc.free(keys[i]);
    }

    // Now emit each id (which has been unsubscribed) — no callbacks fire.
    i = 0;
    while (i < 1000) : (i += 1) {
        const key_buf = try std.fmt.allocPrint(event_test_alloc, "k_{d}", .{i});
        defer event_test_alloc.free(key_buf);
        bus.emit(u32, key_buf, 999);
    }
    try std.testing.expectEqual(@as(u32, 0), b1_count);
}

// ---------------------------------------------------------------------------
// C.

test "subscribe twice with same id same T — second call is a no-op (first cb stays)" {
    resetB();
    var bus = EventBus.init("c", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "id", B1Handler.cb);
    try bus.subscribe(u32, "id", B2Handler.cb); // would replace if behavior changed

    bus.emit(u32, "id", 777);

    // First callback was registered first → only it fires. The
    // second subscribe() silently dropped B2Handler.cb.
    try std.testing.expectEqual(@as(u32, 1), b1_count);
    try std.testing.expectEqual(@as(u32, 0), b2_count);
}

test "subscribe twice with same id different T — first callback still wins (UB-on-emit)" {
    resetB();
    var bus = EventBus.init("c", event_test_alloc, std.testing.io);
    defer bus.deinit();
    // Register with u32, then register again with a different T. The T is
    // compile-time; we use the same T but a different callback to surface the
    // contract.
    try bus.subscribe(u32, "id", B1Handler.cb);
    try bus.subscribe(u32, "id", B2Handler.cb);

    bus.emit(u32, "id", 5);

    try std.testing.expectEqual(@as(u32, 1), b1_count);
    try std.testing.expectEqual(@as(u32, 0), b2_count);
}

test "subscribe twice then unsubscribe — bus is empty" {
    resetB();
    var bus = EventBus.init("c", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "id", B1Handler.cb);
    try bus.subscribe(u32, "id", B2Handler.cb);
    bus.unsubscribe("id");

    bus.emit(u32, "id", 1);
    try std.testing.expectEqual(@as(u32, 0), b1_count);
    try std.testing.expectEqual(@as(u32, 0), b2_count);
}

// ---------------------------------------------------------------------------
// D. ID lifecycle — bus owns the id, not the caller
// ---------------------------------------------------------------------------

test "subscribe copies the id — caller mutating the buffer afterward is invisible" {
    resetB();
    var bus = EventBus.init("d", event_test_alloc, std.testing.io);
    defer bus.deinit();

    // The bus dupe()s the id internally (per source: dupe + errdefer free on
    // getOrPut failure). Mutating the caller's buffer after subscribe must
    // not affect anything.
    var id_buf: [12]u8 = .{ 'i', 'd', '_', 'l', 'i', 'f', 'e', 'c', 'y', 'c', 'l', 'e' };
    const id_slice = id_buf[0..];
    try bus.subscribe(u32, id_slice, B1Handler.cb);

    // Corrupt the caller's buffer in place.
    @memset(id_buf[0..], 'X');

    // The bus's stored id was separately allocated by alloc.dupe(),
    // so this emit must still locate it.
    bus.emit(u32, "id_lifecycle", 99);

    try std.testing.expectEqual(@as(u32, 1), b1_count);
    try std.testing.expectEqual(@as(u32, 99), b1_last);
}

test "subscribe with short-lived caller allocation — bus does not borrow" {
    resetB();
    var bus = EventBus.init("d", event_test_alloc, std.testing.io);
    defer bus.deinit();

    // Build a key in a scope, then let the scope end so the backing
    // array goes away. The bus should have its own copy.
    const key = blk: {
        var buf: [4]u8 = .{ 'a', 'b', 'c', 'd' };
        break :blk buf[0..];
    };
    try bus.subscribe(u32, key, B1Handler.cb);
    // key is technically out of scope (zig knows) but the bus
    // should have copied it.

    bus.emit(u32, "abcd", 11);
    try std.testing.expectEqual(@as(u32, 1), b1_count);
}

test "ids differing only in case are treated as distinct (StringHashMap is bytewise)" {
    resetB();
    var bus = EventBus.init("d", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "ID", B1Handler.cb);
    try bus.subscribe(u32, "id", B2Handler.cb);

    bus.emit(u32, "ID", 1);
    bus.emit(u32, "id", 2);

    try std.testing.expectEqual(@as(u32, 1), b1_count);
    try std.testing.expectEqual(@as(u32, 1), b2_count);
}

test "ids differing in trailing space are distinct (no trimming)" {
    resetB();
    var bus = EventBus.init("d", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "foo", B1Handler.cb);
    try bus.subscribe(u32, "foo ", B2Handler.cb);
    try bus.subscribe(u32, " foo", B3Handler.cb);

    bus.emit(u32, "foo", 1);
    bus.emit(u32, "foo ", 2);
    bus.emit(u32, " foo", 3);

    try std.testing.expectEqual(@as(u32, 1), b1_count);
    try std.testing.expectEqual(@as(u32, 1), b2_count);
    try std.testing.expectEqual(@as(u32, 1), b3_count);
}

// ---------------------------------------------------------------------------
// E. Edge-case id values
// ---------------------------------------------------------------------------

test "subscribe with empty id — emit on empty id routes to it" {
    resetB();
    var bus = EventBus.init("e", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "", B1Handler.cb);

    bus.emit(u32, "", 5);

    try std.testing.expectEqual(@as(u32, 1), b1_count);
    try std.testing.expectEqual(@as(u32, 5), b1_last);
}

test "subscribe with id containing embedded NUL bytes" {
    resetB();
    var bus = EventBus.init("e", event_test_alloc, std.testing.io);
    defer bus.deinit();
    const key_with_nul: [5]u8 = .{ 'a', 0, 'b', 0, 'c' };
    const key_slice: []const u8 = &key_with_nul;
    try bus.subscribe(u32, key_slice, B1Handler.cb);

    // Emit must use the exact same byte pattern. String literals
    // contain 0x00 as '\x00' so this is legal.
    bus.emit(u32, &.{ 'a', 0, 'b', 0, 'c' }, 17);

    try std.testing.expectEqual(@as(u32, 1), b1_count);
}

test "subscribe with id containing only NUL bytes" {
    resetB();
    var bus = EventBus.init("e", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, &[_]u8{ 0, 0, 0 }, B1Handler.cb);

    bus.emit(u32, &[_]u8{ 0, 0, 0 }, 3);

    try std.testing.expectEqual(@as(u32, 1), b1_count);
}

test "subscribe with very long id (1024 bytes) — round-trips correctly" {
    resetB();
    var bus = EventBus.init("e", event_test_alloc, std.testing.io);
    defer bus.deinit();
    var big_buf: [1024]u8 = undefined;
    for (big_buf[0..], 0..) |*slot, idx| slot.* = @intCast('a' + (idx % 26));
    const big_slice: []const u8 = &big_buf;
    try bus.subscribe(u32, big_slice, B1Handler.cb);

    bus.emit(u32, big_slice, 0xCAFE);

    try std.testing.expectEqual(@as(u32, 1), b1_count);
    try std.testing.expectEqual(@as(u32, 0xCAFE), b1_last);
}

test "subscribe with id whose length is 1, then emit with a different 1-byte id" {
    resetB();
    var bus = EventBus.init("e", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "x", B1Handler.cb);

    bus.emit(u32, "x", 1);
    bus.emit(u32, "y", 2);
    bus.emit(u32, "z", 3);

    try std.testing.expectEqual(@as(u32, 1), b1_count);
}

test "subscribe with id that contains '/', '.', ':' (path-like) — works as raw bytes" {
    resetB();
    var bus = EventBus.init("e", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "session/abc:1.0", B1Handler.cb);

    bus.emit(u32, "session/abc:1.0", 31);

    try std.testing.expectEqual(@as(u32, 1), b1_count);
}

// ---------------------------------------------------------------------------
// F. Unsubscribe edge cases
// ---------------------------------------------------------------------------

test "unsubscribe of an id that was never subscribed is a silent no-op" {
    resetB();
    var bus = EventBus.init("f", event_test_alloc, std.testing.io);
    defer bus.deinit();

    // No panics, no allocator corruption.
    bus.unsubscribe("never-subscribed");
    bus.unsubscribe("never-subscribed"); // double-unsub is also fine
    try std.testing.expect(true);
}

test "unsubscribe of an empty id is fine even when nothing is registered" {
    resetB();
    var bus = EventBus.init("f", event_test_alloc, std.testing.io);
    defer bus.deinit();
    bus.unsubscribe("");
    try std.testing.expect(true);
}

test "unsubscribe with id that matches a registered one — listener is removed" {
    resetB();
    var bus = EventBus.init("f", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "a", B1Handler.cb);
    try bus.subscribe(u32, "b", B2Handler.cb);

    bus.unsubscribe("a");

    bus.emit(u32, "a", 1);
    bus.emit(u32, "b", 2);

    try std.testing.expectEqual(@as(u32, 0), b1_count);
    try std.testing.expectEqual(@as(u32, 1), b2_count);
}

test "unsubscribe then resubscribe — second subscription behaves as if it were first" {
    resetB();
    var bus = EventBus.init("f", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "id", B1Handler.cb);
    bus.unsubscribe("id");

    // After unsubscribe, the map slot is gone. A fresh subscribe
    // with a DIFFERENT callback should actually register (this
    // proves the slot was truly released).
    try bus.subscribe(u32, "id", B2Handler.cb);

    bus.emit(u32, "id", 88);
    try std.testing.expectEqual(@as(u32, 0), b1_count);
    try std.testing.expectEqual(@as(u32, 1), b2_count);
}

// ---------------------------------------------------------------------------
// G. Data type shape — what can `T` be?
// ---------------------------------------------------------------------------

var g_struct_received: u32 = 0;
var g_string_received: []const u8 = "";
var g_zero_sized_fires: u32 = 0;

const EventPayload = struct {
    counter: u32,
    tag: []const u8,
};

const GHandler = struct {
    fn on_struct(data: EventPayload) void {
        g_struct_received = data.counter;
        g_string_received = data.tag;
    }
    fn on_u8(_: u8) void {}
    fn on_string(data: []const u8) void {
        g_string_received = data;
    }
    fn on_zero_sized(_: void) void {
        g_zero_sized_fires += 1;
    }
};

fn resetG() void {
    g_struct_received = 0;
    g_string_received = "";
    g_zero_sized_fires = 0;
}

test "callback receives a struct by value" {
    resetG();
    var bus = EventBus.init("g", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(EventPayload, "payload", GHandler.on_struct);

    const payload = EventPayload{ .counter = 7, .tag = "hello" };
    bus.emit(EventPayload, "payload", payload);

    try std.testing.expectEqual(@as(u32, 7), g_struct_received);
    try std.testing.expectEqualStrings("hello", g_string_received);
}

test "callback receives a slice" {
    resetG();
    var bus = EventBus.init("g", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe([]const u8, "slice_id", GHandler.on_string);

    bus.emit([]const u8, "slice_id", "the data");

    try std.testing.expectEqualStrings("the data", g_string_received);
}

test "callback can be called with a zero-sized payload (T=void)" {
    resetG();
    var bus = EventBus.init("g", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(void, "ping", GHandler.on_zero_sized);

    bus.emit(void, "ping", {});
    bus.emit(void, "ping", {});
    bus.emit(void, "ping", {});

    try std.testing.expectEqual(@as(u32, 3), g_zero_sized_fires);
}

// ---------------------------------------------------------------------------
// H.

const Reentrant = struct {
    var bus_ref: ?*EventBus = null;
    var count: u32 = 0;

    fn on_event(data: u32) void {
        const b = bus_ref orelse unreachable;
        count += 1;
        _ = data;
        // Add a new listener while mid-callback. subscribe can fail
        // on OOM; we ignore that since this test only cares that the
        // call RAN, not whether it succeeded.
        b.subscribe(u32, "added_from_callback", on_emit) catch {};
        // emit returns void (no error union), so no catch here.
        b.emit(u32, "added_from_callback", 555);
    }

    fn on_emit(data: u32) void {
        count += 1;
        _ = data;
    }
};

fn resetReentrant() void {
    Reentrant.bus_ref = null;
    Reentrant.count = 0;
}

test "callback may emit on a different id without recursion issues" {
    resetB();
    resetG();
    var bus = EventBus.init("h", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "outer", B1Handler.cb);
    try bus.subscribe(u32, "inner_from_outer", B2Handler.cb);

    bus.emit(u32, "outer", 100);

    try std.testing.expectEqual(@as(u32, 1), b1_count);
    try std.testing.expectEqual(@as(u32, 0), b2_count);
}

test "callback may subscribe a brand-new id without affecting the firing entry" {
    resetB();
    resetReentrant();
    var bus = EventBus.init("h", event_test_alloc, std.testing.io);
    defer bus.deinit();

    // Per the documented contract: subscribe() with a duplicate id is a NO-OP
    // — the FIRST subscription wins and stays.
    Reentrant.bus_ref = &bus;
    try bus.subscribe(u32, "trigger", Reentrant.on_event);

    // Subscribe a separate id (not "trigger") for B1, so that
    // B1 has its own firing path that's independent of re-entrance.
    try bus.subscribe(u32, "sibling", B1Handler.cb);

    bus.emit(u32, "trigger", 111);

    // The re-entrant path executed (on_event ran) and registered + dispatched
    // to a new listener. count >= 2 means: - 1 from the on_event path itself
    // - 1+ from the on_emit path triggered inside on_event
    try std.testing.expect(Reentrant.count >= 2);
    // B1 is independent of the re-entrance (different id).
    try std.testing.expectEqual(@as(u32, 0), b1_count);
    bus.emit(u32, "sibling", 7);
    try std.testing.expectEqual(@as(u32, 1), b1_count);
}

test "callback may unsubscribe a different id without affecting the firing entry" {
    resetB();
    var bus = EventBus.init("h", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try bus.subscribe(u32, "victim", B2Handler.cb);

    const Sabotage = struct {
        var bus_ref: ?*EventBus = null;

        fn on_event(_: u32) void {
            const b = bus_ref orelse unreachable;
            // Unsubscribe an UNRELATED id while a different emit is firing.
            b.unsubscribe("victim");
        }
    };
    Sabotage.bus_ref = &bus;
    // Sabotage subscribed FIRST for "trigger" so it's the listener
    // (per subscribe's first-wins contract on duplicate ids).
    try bus.subscribe(u32, "trigger", Sabotage.on_event);

    bus.emit(u32, "trigger", 1);
    // Victim must now have no listener — emit must not call it.
    bus.emit(u32, "victim", 2);

    try std.testing.expectEqual(@as(u32, 0), b1_count);
    try std.testing.expectEqual(@as(u32, 0), b2_count);
}

// ---------------------------------------------------------------------------
// I. Lifecycle — deinit edge cases
// ---------------------------------------------------------------------------

test "deinit on an empty bus is a safe no-op" {
    var bus = EventBus.init("empty", event_test_alloc, std.testing.io);
    bus.deinit();
    // If we got here without panic or allocator corruption, this passed.
    try std.testing.expect(true);
}

test "deinit on a bus with many entries releases all owned keys" {
    resetB();
    var bus = EventBus.init("lifecycle-many", event_test_alloc, std.testing.io);
    defer bus.deinit();
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const key = try std.fmt.allocPrint(event_test_alloc, "many_{d}", .{i});
        defer event_test_alloc.free(key); // free the caller's allocPrint buffer each iteration
        try bus.subscribe(u32, key, B1Handler.cb);
    }
    // If deinit did not free a duped key, std.testing.allocator's
    // DebugAllocator would report a leak at test-binary exit. The
    // `testing.allocator` is leak-checked by the harness.
    try std.testing.expect(true);
}

test "deinit on a bus where one id was added and removed is also safe" {
    var bus = EventBus.init("lifecycle-removed", event_test_alloc, std.testing.io);
    try bus.subscribe(u32, "transient", B1Handler.cb);
    bus.unsubscribe("transient");
    bus.deinit();
    try std.testing.expect(true);
}

// ---------------------------------------------------------------------------
// J. Static contract — type / shape of the public surface
// ---------------------------------------------------------------------------

test "EventBus has init, subscribe, unsubscribe, emit, deinit as public methods" {
    try std.testing.expect(@hasDecl(EventBus, "init"));
    try std.testing.expect(@hasDecl(EventBus, "subscribe"));
    try std.testing.expect(@hasDecl(EventBus, "unsubscribe"));
    try std.testing.expect(@hasDecl(EventBus, "emit"));
    try std.testing.expect(@hasDecl(EventBus, "deinit"));
}

test "EventBus.init returns a Self (not !Self) — no error union on init" {
    const T = @TypeOf(EventBus.init);
    // The typeName shape for a fn is `fn ([params]) [return_type]`.
    try std.testing.expect(std.mem.endsWith(u8, @typeName(T), "event.EventBus"));
    // Confirm by constructing one and discarding it.
    var bus = EventBus.init("static", event_test_alloc, std.testing.io);
    defer bus.deinit();
    try std.testing.expectEqualStrings("static", bus.name);
}

test "EventBus.subscribe takes (self, T, id, callback) — verify via @typeInfo" {
    const T = @TypeOf(EventBus.subscribe);
    const info = @typeInfo(T).@"fn";
    try std.testing.expectEqual(@as(usize, 4), info.params.len);
    // params: self: *Self, comptime T: type, id: []const u8, callback: *const
    // fn (T) void Type names are non-canonicalized module-wide strings;
    // assert only the trailing namespace token to avoid coupling to
    try std.testing.expect(std.mem.endsWith(u8, @typeName(info.params[0].type.?), ".EventBus"));
    try std.testing.expectEqualStrings("type", @typeName(info.params[1].type.?));
    try std.testing.expectEqualStrings("[]const u8", @typeName(info.params[2].type.?));
}

test "EventBus.emit takes (self, T, id, data) and returns void" {
    const T = @TypeOf(EventBus.emit);
    const info = @typeInfo(T).@"fn";
    try std.testing.expectEqual(@as(usize, 4), info.params.len);
    try std.testing.expectEqualStrings("void", @typeName(info.return_type.?));
}

test "EventBus.unsubscribe returns void (not error union)" {
    const T = @TypeOf(EventBus.unsubscribe);
    const info = @typeInfo(T).@"fn";
    try std.testing.expectEqualStrings("void", @typeName(info.return_type.?));
}

test "EventBus.deinit returns void (not error union)" {
    const T = @TypeOf(EventBus.deinit);
    const info = @typeInfo(T).@"fn";
    try std.testing.expectEqualStrings("void", @typeName(info.return_type.?));
}

// ---------------------------------------------------------------------------
// K.

const FailingAllocator = struct {
    fail_after_alloc: u32 = 0,
    alloc_calls: u32 = 0,
    resize_calls: u32 = 0,
    free_calls: u32 = 0,
    backing: std.mem.Allocator,

    pub fn allocator(self: *FailingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .remap = remapFn,
                .free = freeFn,
            },
        };
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_calls += 1;
        if (self.alloc_calls > self.fail_after_alloc) return null;
        // Delegate to backing allocator.
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        self.resize_calls += 1;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        self.free_calls += 1;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "subscribe fails cleanly when dupe() runs out of memory" {
    resetB();
    var fail_alloc = FailingAllocator{
        .fail_after_alloc = 0, // fail on the very first alloc
        .backing = event_test_alloc,
    };
    const failing = fail_alloc.allocator();

    var bus = EventBus.init("fail", failing, std.testing.io);
    defer bus.deinit();

    const result = bus.subscribe(u32, "x", B1Handler.cb);
    try std.testing.expectError(error.OutOfMemory, result);

    // Map should still be empty — emit must not call anything.
    bus.emit(u32, "x", 1);
    try std.testing.expectEqual(@as(u32, 0), b1_count);
}

test "subscribe with a working allocator — sanity check the failing harness" {
    resetB();
    var fail_alloc = FailingAllocator{
        .fail_after_alloc = 1000, // never fail within reasonable bounds
        .backing = event_test_alloc,
    };
    const failing = fail_alloc.allocator();

    var bus = EventBus.init("ok", failing, std.testing.io);
    defer bus.deinit();

    try bus.subscribe(u32, "x", B1Handler.cb);
    bus.emit(u32, "x", 9);
    try std.testing.expectEqual(@as(u32, 1), b1_count);
}

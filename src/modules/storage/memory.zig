//! In-memory backend. A working implementation, not a mock: it stores real
//! bytes and reports real sizes, so a test can assert on resulting state
//! instead of on which methods were called.

const std = @import("std");
const storage = @import("storage.zig");

pub const MemoryStorage = struct {
    allocator: std.mem.Allocator,
    objects: std.StringHashMap([]u8),

    pub fn init(allocator: std.mem.Allocator) MemoryStorage {
        return .{ .allocator = allocator, .objects = std.StringHashMap([]u8).init(allocator) };
    }

    pub fn deinit(self: *MemoryStorage) void {
        var it = self.objects.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.objects.deinit();
    }

    pub fn asStorage(self: *MemoryStorage) storage.Storage {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// How many objects the store holds. Lets a test assert that a failed
    /// write left nothing behind.
    pub fn count(self: *const MemoryStorage) usize {
        return self.objects.count();
    }

    const vtable = storage.Storage.VTable{
        .put = put,
        .get = get,
        .delete = delete,
        .stat = stat,
    };

    fn put(ptr: *anyopaque, key: []const u8, body: []const u8) storage.Error!void {
        const self: *MemoryStorage = @ptrCast(@alignCast(ptr));
        if (storage.invalidKeyReason(key) != null) return error.InvalidKey;
        if (body.len > storage.MAX_OBJECT_BYTES) return error.IoFailed;

        const owned_body = self.allocator.dupe(u8, body) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_body);

        if (self.objects.getEntry(key)) |entry| {
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = owned_body;
            return;
        }

        const owned_key = self.allocator.dupe(u8, key) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_key);
        self.objects.put(owned_key, owned_body) catch return error.OutOfMemory;
    }

    fn get(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) storage.Error![]u8 {
        const self: *MemoryStorage = @ptrCast(@alignCast(ptr));
        if (storage.invalidKeyReason(key) != null) return error.InvalidKey;
        const body = self.objects.get(key) orelse return error.NotFound;
        return allocator.dupe(u8, body) catch return error.OutOfMemory;
    }

    fn delete(ptr: *anyopaque, key: []const u8) storage.Error!void {
        const self: *MemoryStorage = @ptrCast(@alignCast(ptr));
        if (storage.invalidKeyReason(key) != null) return error.InvalidKey;
        const entry = self.objects.fetchRemove(key) orelse return error.NotFound;
        self.allocator.free(entry.key);
        self.allocator.free(entry.value);
    }

    fn stat(ptr: *anyopaque, key: []const u8) storage.Error!storage.Stat {
        const self: *MemoryStorage = @ptrCast(@alignCast(ptr));
        if (storage.invalidKeyReason(key) != null) return error.InvalidKey;
        const body = self.objects.get(key) orelse return error.NotFound;
        return .{ .bytes = body.len };
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "memory put then get returns the same bytes" {
    const alloc = testing.allocator;
    var store = MemoryStorage.init(alloc);
    defer store.deinit();
    const s = store.asStorage();

    try s.put("ws/ws_1/documents/doc_a/abc.md", "# Plan\n");

    const body = try s.get(alloc, "ws/ws_1/documents/doc_a/abc.md");
    defer alloc.free(body);
    try testing.expectEqualStrings("# Plan\n", body);
}

test "memory get on a key that was never written is NotFound" {
    const alloc = testing.allocator;
    var store = MemoryStorage.init(alloc);
    defer store.deinit();
    try testing.expectError(error.NotFound, store.asStorage().get(alloc, "nope.md"));
}

test "memory put replaces an existing object and keeps the object count at one" {
    const alloc = testing.allocator;
    var store = MemoryStorage.init(alloc);
    defer store.deinit();
    const s = store.asStorage();

    try s.put("k.md", "first version");
    try s.put("k.md", "second");

    const body = try s.get(alloc, "k.md");
    defer alloc.free(body);
    try testing.expectEqualStrings("second", body);
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "memory stat reports the byte length" {
    var store = MemoryStorage.init(testing.allocator);
    defer store.deinit();

    try store.asStorage().put("k.md", "twelve bytes");

    const info = try store.asStorage().stat("k.md");
    try testing.expectEqual(@as(u64, 12), info.bytes);
}

test "memory delete removes the object and a second delete is NotFound" {
    const alloc = testing.allocator;
    var store = MemoryStorage.init(alloc);
    defer store.deinit();
    const s = store.asStorage();

    try s.put("k.md", "body");
    try s.delete("k.md");

    try testing.expectError(error.NotFound, s.get(alloc, "k.md"));
    try testing.expectError(error.NotFound, s.delete("k.md"));
    try testing.expectEqual(@as(usize, 0), store.count());
}

test "memory rejects a traversal key and stores nothing" {
    const alloc = testing.allocator;
    var store = MemoryStorage.init(alloc);
    defer store.deinit();

    try testing.expectError(error.InvalidKey, store.asStorage().put("../escape.md", "x"));
    try testing.expectError(error.InvalidKey, store.asStorage().get(alloc, "../escape.md"));
    try testing.expectEqual(@as(usize, 0), store.count());
}

test "memory rejects a body larger than the cap and stores nothing" {
    const alloc = testing.allocator;
    var store = MemoryStorage.init(alloc);
    defer store.deinit();

    const big = try alloc.alloc(u8, storage.MAX_OBJECT_BYTES + 1);
    defer alloc.free(big);
    @memset(big, 'x');

    try testing.expectError(error.IoFailed, store.asStorage().put("big.md", big));
    try testing.expectEqual(@as(usize, 0), store.count());
}

test "memory deinit releases every object it holds" {
    var store = MemoryStorage.init(testing.allocator);
    const s = store.asStorage();
    try s.put("a.md", "one");
    try s.put("b.md", "two");
    try s.put("c.md", "three");
    store.deinit();
}

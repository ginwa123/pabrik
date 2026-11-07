//! Filesystem backend: the root directory IS the bucket, and a key is a
//! relative path under it. This is the shape rustfs itself puts on disk, so
//! moving to the S3 backend later is a config change, not a data migration.

const std = @import("std");
const storage = @import("storage.zig");

pub const FsStorage = struct {
    dir: std.Io.Dir,
    io: std.Io,
    max_bytes: usize = storage.MAX_OBJECT_BYTES,

    /// Open `root` as the store, creating it (and its parents) when missing.
    pub fn open(io: std.Io, root: []const u8) storage.Error!FsStorage {
        if (root.len == 0) return error.InvalidKey;
        std.Io.Dir.cwd().createDirPath(io, root) catch return error.IoFailed;
        const dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return error.IoFailed;
        return .{ .dir = dir, .io = io };
    }

    /// Wrap an already-open directory. Tests use this with a temp dir.
    pub fn init(dir: std.Io.Dir, io: std.Io) FsStorage {
        return .{ .dir = dir, .io = io };
    }

    pub fn deinit(self: *FsStorage) void {
        self.dir.close(self.io);
    }

    pub fn asStorage(self: *FsStorage) storage.Storage {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = storage.Storage.VTable{
        .put = put,
        .get = get,
        .delete = delete,
        .stat = stat,
    };

    fn put(ptr: *anyopaque, key: []const u8, body: []const u8) storage.Error!void {
        const self: *FsStorage = @ptrCast(@alignCast(ptr));
        if (storage.invalidKeyReason(key) != null) return error.InvalidKey;
        if (body.len > self.max_bytes) return error.IoFailed;

        if (std.fs.path.dirname(key)) |parent| {
            self.dir.createDirPath(self.io, parent) catch return error.IoFailed;
        }

        // Atomic: the object appears whole or not at all, so a crash mid-write
        // can never leave a half body behind a key the row already points at.
        var atomic = self.dir.createFileAtomic(self.io, key, .{ .replace = true }) catch return error.IoFailed;
        defer atomic.deinit(self.io);
        atomic.file.writeStreamingAll(self.io, body) catch return error.IoFailed;
        atomic.replace(self.io) catch return error.IoFailed;
    }

    fn get(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) storage.Error![]u8 {
        const self: *FsStorage = @ptrCast(@alignCast(ptr));
        if (storage.invalidKeyReason(key) != null) return error.InvalidKey;
        return self.dir.readFileAlloc(self.io, key, allocator, .limited(self.max_bytes)) catch |err| switch (err) {
            error.FileNotFound => error.NotFound,
            error.OutOfMemory => error.OutOfMemory,
            else => error.IoFailed,
        };
    }

    fn delete(ptr: *anyopaque, key: []const u8) storage.Error!void {
        const self: *FsStorage = @ptrCast(@alignCast(ptr));
        if (storage.invalidKeyReason(key) != null) return error.InvalidKey;
        self.dir.deleteFile(self.io, key) catch |err| return switch (err) {
            error.FileNotFound => error.NotFound,
            else => error.IoFailed,
        };
    }

    fn stat(ptr: *anyopaque, key: []const u8) storage.Error!storage.Stat {
        const self: *FsStorage = @ptrCast(@alignCast(ptr));
        if (storage.invalidKeyReason(key) != null) return error.InvalidKey;
        const info = self.dir.statFile(self.io, key, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return error.IoFailed,
        };
        return .{ .bytes = info.size };
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    store: FsStorage,

    fn init() !Fixture {
        const tmp = testing.tmpDir(.{});
        return .{ .tmp = tmp, .store = FsStorage.init(tmp.dir, testing.io) };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }
};

test "fs put then get returns the same bytes" {
    const alloc = testing.allocator;
    var fx = try Fixture.init();
    defer fx.deinit();
    const s = fx.store.asStorage();

    try s.put("ws/ws_1/documents/doc_a/abc.md", "# Release plan\n");

    const body = try s.get(alloc, "ws/ws_1/documents/doc_a/abc.md");
    defer alloc.free(body);
    try testing.expectEqualStrings("# Release plan\n", body);
}

test "fs put creates the parent directories a nested key needs" {
    const alloc = testing.allocator;
    var fx = try Fixture.init();
    defer fx.deinit();
    const s = fx.store.asStorage();

    try s.put("a/b/c/d.md", "deep");

    const body = try s.get(alloc, "a/b/c/d.md");
    defer alloc.free(body);
    try testing.expectEqualStrings("deep", body);
}

test "fs get on a key that was never written is NotFound" {
    const alloc = testing.allocator;
    var fx = try Fixture.init();
    defer fx.deinit();
    try testing.expectError(error.NotFound, fx.store.asStorage().get(alloc, "nope.md"));
}

test "fs put replaces an existing object rather than appending" {
    const alloc = testing.allocator;
    var fx = try Fixture.init();
    defer fx.deinit();
    const s = fx.store.asStorage();

    try s.put("k.md", "first version");
    try s.put("k.md", "second");

    const body = try s.get(alloc, "k.md");
    defer alloc.free(body);
    try testing.expectEqualStrings("second", body);
}

test "fs put accepts an empty body and get returns it as empty" {
    const alloc = testing.allocator;
    var fx = try Fixture.init();
    defer fx.deinit();
    const s = fx.store.asStorage();

    try s.put("empty.md", "");

    const body = try s.get(alloc, "empty.md");
    defer alloc.free(body);
    try testing.expectEqual(@as(usize, 0), body.len);
}

test "fs stat reports the byte length without reading the body" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const s = fx.store.asStorage();

    try s.put("k.md", "twelve bytes");

    const info = try s.stat("k.md");
    try testing.expectEqual(@as(u64, 12), info.bytes);
}

test "fs stat on a missing key is NotFound" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try testing.expectError(error.NotFound, fx.store.asStorage().stat("nope.md"));
}

test "fs delete removes the object and a second delete is NotFound" {
    const alloc = testing.allocator;
    var fx = try Fixture.init();
    defer fx.deinit();
    const s = fx.store.asStorage();

    try s.put("k.md", "body");
    try s.delete("k.md");

    try testing.expectError(error.NotFound, s.get(alloc, "k.md"));
    try testing.expectError(error.NotFound, s.delete("k.md"));
}

test "fs delete on a key that was never written is NotFound" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try testing.expectError(error.NotFound, fx.store.asStorage().delete("nope.md"));
}

test "fs rejects a traversal key and writes nothing outside the root" {
    const alloc = testing.allocator;
    var fx = try Fixture.init();
    defer fx.deinit();
    const s = fx.store.asStorage();

    try testing.expectError(error.InvalidKey, s.put("../escape.md", "x"));
    try testing.expectError(error.InvalidKey, s.get(alloc, "../escape.md"));
    try testing.expectError(error.InvalidKey, s.delete("../escape.md"));
    try testing.expectError(error.InvalidKey, s.stat("../escape.md"));
}

test "fs rejects an absolute key" {
    const alloc = testing.allocator;
    var fx = try Fixture.init();
    defer fx.deinit();
    try testing.expectError(error.InvalidKey, fx.store.asStorage().get(alloc, "/etc/passwd"));
}

test "fs rejects a body larger than the cap and leaves no object behind" {
    const alloc = testing.allocator;
    var fx = try Fixture.init();
    defer fx.deinit();
    fx.store.max_bytes = 8;
    const s = fx.store.asStorage();

    try testing.expectError(error.IoFailed, s.put("big.md", "more than eight bytes"));
    try testing.expectError(error.NotFound, s.get(alloc, "big.md"));
}

test "fs open creates a missing root and round-trips through it" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(testing.io, &path_buf);
    const root = try std.fs.path.join(alloc, &.{ path_buf[0..base_len], "objects", "nested" });
    defer alloc.free(root);

    var store = try FsStorage.open(testing.io, root);
    defer store.deinit();

    try store.asStorage().put("k.md", "through the root");
    const body = try store.asStorage().get(alloc, "k.md");
    defer alloc.free(body);
    try testing.expectEqualStrings("through the root", body);
}

test "fs open rejects an empty root" {
    try testing.expectError(error.InvalidKey, FsStorage.open(testing.io, ""));
}

test "fs repeated get does not grow live bytes" {
    const alloc = testing.allocator;
    var fx = try Fixture.init();
    defer fx.deinit();
    const s = fx.store.asStorage();

    try s.put("k.md", "a body that is read many times");

    var counting = CountingAllocator{ .parent = alloc };
    const counting_alloc = counting.allocator();

    const before = counting.live_bytes;
    for (0..16) |_| {
        const body = try s.get(counting_alloc, "k.md");
        counting_alloc.free(body);
    }
    try testing.expectEqual(before, counting.live_bytes);
}

/// A pass-through allocator that tracks the bytes it is currently holding.
/// `testing.allocator` only reports a leak when the test ends, so a per-call
/// leak inside a loop is invisible without this.
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    live_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        const result = self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr) orelse return null;
        self.live_bytes += len;
        return result;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        if (!self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr)) return false;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        const result = self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr) orelse return null;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return result;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
        self.live_bytes -= memory.len;
    }
};

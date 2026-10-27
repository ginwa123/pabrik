//! Where a presented file's bytes live: this host in local mode, the
//! workspace's VM under `--saas`. `present_files` and `GET /api/files/download`
//! both ask this seam, so the card's size and its bytes cannot come from two places.

const std = @import("std");
const workspace_fs = @import("../../../agentic_loop/workspace_fs.zig");
const file_sandbox = @import("file_sandbox.zig");

const testing = std.testing;

pub const Kind = enum { file, dir, other };

/// One path's answer. `missing` is its own answer, never a zero-byte file.
pub const Probe = struct {
    kind: Kind = .other,
    size: u64 = 0,
    missing: bool = false,
};

/// The two questions a presented file raises — may it be shown, and how big is
/// it — plus the bytes the browser is handed. Every substrate answers the same
/// three, so nothing above this line knows which one it is talking to.
pub const Source = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        admit: *const fn (ptr: *const anyopaque, allocator: std.mem.Allocator, root: []const u8, abs: []const u8) file_sandbox.ResolveError![]u8,
        probe: *const fn (ptr: *const anyopaque, abs: []const u8) anyerror!Probe,
        readAll: *const fn (ptr: *const anyopaque, allocator: std.mem.Allocator, abs: []const u8, max: usize) anyerror![]u8,
    };

    /// The path the other two ops name, or the reason there is none.
    pub fn admit(self: Source, allocator: std.mem.Allocator, root: []const u8, abs: []const u8) file_sandbox.ResolveError![]u8 {
        return self.vtable.admit(self.ptr, allocator, root, abs);
    }

    pub fn probe(self: Source, abs: []const u8) anyerror!Probe {
        return self.vtable.probe(self.ptr, abs);
    }

    /// The whole file, bounded by `max`: over it is a refusal, not a truncation.
    pub fn readAll(self: Source, allocator: std.mem.Allocator, abs: []const u8, max: usize) anyerror![]u8 {
        return self.vtable.readAll(self.ptr, allocator, abs, max);
    }
};

/// The tenant tree on this host, opened by this process.
pub const Host = struct {
    io: std.Io,

    pub fn source(self: *const Host) Source {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Source.VTable{ .admit = admit, .probe = probe, .readAll = readAll };

    fn admit(ptr: *const anyopaque, allocator: std.mem.Allocator, root: []const u8, abs: []const u8) file_sandbox.ResolveError![]u8 {
        const self: *const Host = @ptrCast(@alignCast(ptr));
        return file_sandbox.resolveInsideRoot(self.io, allocator, root, abs, file_sandbox.nativeStyle());
    }

    fn probe(ptr: *const anyopaque, abs: []const u8) anyerror!Probe {
        const self: *const Host = @ptrCast(@alignCast(ptr));
        const file = std.Io.Dir.cwd().openFile(self.io, abs, .{ .allow_directory = false }) catch |err| switch (err) {
            error.IsDir => return .{ .kind = .dir },
            else => return .{ .missing = true },
        };
        defer std.Io.File.close(file, self.io);
        const stat = std.Io.File.stat(file, self.io) catch return .{ .missing = true };
        return .{ .kind = .file, .size = stat.size };
    }

    fn readAll(ptr: *const anyopaque, allocator: std.mem.Allocator, abs: []const u8, max: usize) anyerror![]u8 {
        const self: *const Host = @ptrCast(@alignCast(ptr));
        return std.Io.Dir.cwd().readFileAlloc(self.io, abs, allocator, .limited(max));
    }
};

/// The tenant tree inside a workspace's VM. The host opens nothing: every
/// answer comes back over the fs RPC.
pub const Guest = struct {
    fs: *const workspace_fs.Fs,

    pub fn source(self: *const Guest) Source {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Source.VTable{ .admit = admitPath, .probe = probe, .readAll = readAll };

    fn probe(ptr: *const anyopaque, abs: []const u8) anyerror!Probe {
        const self: *const Guest = @ptrCast(@alignCast(ptr));
        const stat = try self.fs.stat(abs);
        if (stat.missing) return .{ .missing = true };
        return .{
            .kind = switch (stat.kind) {
                .file => .file,
                .dir => .dir,
                else => .other,
            },
            .size = if (stat.size > 0) @intCast(stat.size) else 0,
        };
    }

    fn readAll(ptr: *const anyopaque, allocator: std.mem.Allocator, abs: []const u8, max: usize) anyerror![]u8 {
        const self: *const Guest = @ptrCast(@alignCast(ptr));
        return self.fs.readUpTo(allocator, abs, max);
    }
};

/// A Source over an in-memory tree: the bytes exist only here and never on this
/// host, which is the `--saas` shape a test can hold without a VM.
pub const Memory = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(Entry) = .empty,

    pub const Entry = struct {
        kind: Kind,
        size: u64,
        bytes: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Memory {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Memory) void {
        var it = self.files.iterator();
        while (it.next()) |row| self.allocator.free(row.key_ptr.*);
        self.files.deinit(self.allocator);
    }

    pub fn put(self: *Memory, path: []const u8, bytes: []const u8) !void {
        try self.files.put(self.allocator, try self.allocator.dupe(u8, path), .{
            .kind = .file,
            .size = bytes.len,
            .bytes = bytes,
        });
    }

    pub fn putSized(self: *Memory, path: []const u8, size: u64) !void {
        try self.files.put(self.allocator, try self.allocator.dupe(u8, path), .{
            .kind = .file,
            .size = size,
            .bytes = "",
        });
    }

    pub fn putDir(self: *Memory, path: []const u8) !void {
        try self.files.put(self.allocator, try self.allocator.dupe(u8, path), .{
            .kind = .dir,
            .size = 0,
            .bytes = "",
        });
    }

    pub fn source(self: *const Memory) Source {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Source.VTable{ .admit = admitPath, .probe = probe, .readAll = readAll };

    fn probe(ptr: *const anyopaque, abs: []const u8) anyerror!Probe {
        const self: *const Memory = @ptrCast(@alignCast(ptr));
        const row = self.files.get(abs) orelse return .{ .missing = true };
        return .{ .kind = row.kind, .size = row.size };
    }

    fn readAll(ptr: *const anyopaque, allocator: std.mem.Allocator, abs: []const u8, max: usize) anyerror![]u8 {
        const self: *const Memory = @ptrCast(@alignCast(ptr));
        const row = self.files.get(abs) orelse return error.FileNotFound;
        if (row.size > max) return error.FileTooBig;
        return allocator.dupe(u8, row.bytes);
    }
};

/// Containment for a tree that has no host paths: the same string rule the host
/// applies after canonicalization, and the path itself is already canonical.
fn admitPath(_: *const anyopaque, allocator: std.mem.Allocator, root: []const u8, abs: []const u8) file_sandbox.ResolveError![]u8 {
    if (!file_sandbox.isAbsoluteFor(abs, .posix)) return error.NotAbsolute;
    if (file_sandbox.hasParentSegment(abs)) return error.PathTraversal;
    if (!file_sandbox.isAbsoluteFor(root, .posix)) return error.RootNotAbsolute;
    if (root.len > 0 and !file_sandbox.isInsideRoot(root, abs, .posix)) return error.OutsideRoot;
    return allocator.dupe(u8, abs) catch return error.OutOfMemory;
}

// ─── Behaviour tests ─────────────────────────────────────────────────────

test "a file that exists only where a VM keeps it is admitted, sized and read" {
    const alloc = testing.allocator;
    var memory = Memory.init(alloc);
    defer memory.deinit();
    try memory.put("/workspace/report.html", "<h1>hi</h1>");
    const source = memory.source();

    const canon = try source.admit(alloc, "/workspace", "/workspace/report.html");
    defer alloc.free(canon);
    try testing.expectEqualStrings("/workspace/report.html", canon);

    const probe = try source.probe("/workspace/report.html");
    try testing.expect(!probe.missing);
    try testing.expectEqual(Kind.file, probe.kind);
    try testing.expectEqual(@as(u64, 11), probe.size);
}

test "a path the VM does not have reports missing, not empty" {
    const alloc = testing.allocator;
    var memory = Memory.init(alloc);
    defer memory.deinit();
    const source = memory.source();

    const probe = try source.probe("/workspace/nope.txt");
    try testing.expect(probe.missing);
}

test "the host and the VM agree on which paths may be shown" {
    const alloc = testing.allocator;
    var memory = Memory.init(alloc);
    defer memory.deinit();
    const source = memory.source();

    try testing.expectError(error.OutsideRoot, source.admit(alloc, "/workspace", "/etc/passwd"));
    try testing.expectError(error.OutsideRoot, source.admit(alloc, "/workspace/proj", "/workspace/proj-backup/a.txt"));
    try testing.expectError(error.PathTraversal, source.admit(alloc, "/workspace", "/workspace/../etc/passwd"));
    try testing.expectError(error.NotAbsolute, source.admit(alloc, "/workspace", "report.html"));
}

test "a read over the ceiling is refused, never truncated" {
    const alloc = testing.allocator;
    var memory = Memory.init(alloc);
    defer memory.deinit();
    try memory.put("/workspace/big.bin", "0123456789");
    const source = memory.source();

    try testing.expectError(error.FileTooBig, source.readAll(alloc, "/workspace/big.bin", 5));
}

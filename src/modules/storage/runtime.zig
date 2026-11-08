//! Builds the object store the environment asks for, and owns it for the life
//! of the process. `null` means "no object store configured", which keeps every
//! body in the `documents.content` column.

const std = @import("std");
const storage = @import("storage.zig");
const fs_backend = @import("fs.zig");
const s3_backend = @import("s3.zig");
const http_transport = @import("http_transport.zig");

/// Where objects live when neither a flag nor `PABRIK_STORAGE_ROOT` says.
pub const DEFAULT_ROOT_SUFFIX = ".local/share/pabrik/objects";

pub const Backend = enum { fs, s3 };

/// Resolve the backend: the flag, then `PABRIK_STORAGE_BACKEND`, then `fs`.
pub fn resolveBackend(
    environment: *const std.process.Environ.Map,
    flag: ?[]const u8,
) !Backend {
    const name = flag orelse environment.get("PABRIK_STORAGE_BACKEND") orelse return .fs;
    if (std.mem.eql(u8, name, "fs")) return .fs;
    if (std.mem.eql(u8, name, "s3")) return .s3;
    return error.UnknownBackend;
}

/// Resolve the store root: the flag, then `PABRIK_STORAGE_ROOT`, then `$HOME`.
pub fn resolveRoot(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    flag: ?[]const u8,
) ![]u8 {
    if (flag) |root| {
        if (root.len == 0) return error.RootRequired;
        return allocator.dupe(u8, root);
    }
    if (environment.get("PABRIK_STORAGE_ROOT")) |root| {
        if (root.len > 0) return allocator.dupe(u8, root);
    }
    const home = environment.get("HOME") orelse return error.RootRequired;
    return std.fs.path.join(allocator, &.{ home, DEFAULT_ROOT_SUFFIX });
}

/// S3 settings from the environment. Every slice borrows from `environment`,
/// which outlives the store.
pub fn resolveS3Config(environment: *const std.process.Environ.Map) !s3_backend.Config {
    return .{
        .endpoint = environment.get("PABRIK_S3_ENDPOINT") orelse return error.S3EndpointRequired,
        .bucket = environment.get("PABRIK_S3_BUCKET") orelse return error.S3BucketRequired,
        .region = environment.get("PABRIK_S3_REGION") orelse "us-east-1",
        .access_key = environment.get("PABRIK_S3_ACCESS_KEY") orelse return error.S3AccessKeyRequired,
        .secret_key = environment.get("PABRIK_S3_SECRET_KEY") orelse return error.S3SecretKeyRequired,
    };
}

/// A live backend. Heap-allocated because the `Storage` handle points INTO it,
/// so it must not move after construction.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    kind: Kind,

    pub const Kind = union(enum) {
        fs: fs_backend.FsStorage,
        s3: S3,
    };

    pub const S3 = struct {
        http: http_transport.HttpTransport,
        store: s3_backend.S3Storage,
    };

    /// Build the store the environment asks for. `PABRIK_STORAGE_BACKEND`
    /// unset means `fs` at the default root: the body is not a column any
    /// more, so an install with no store would have nowhere to put one.
    pub fn fromEnvironment(
        allocator: std.mem.Allocator,
        io: std.Io,
        environment: *const std.process.Environ.Map,
    ) !?*Runtime {
        const runtime = try allocator.create(Runtime);
        errdefer allocator.destroy(runtime);

        switch (try resolveBackend(environment, null)) {
            .fs => {
                const root = try resolveRoot(allocator, environment, null);
                defer allocator.free(root);
                runtime.* = .{
                    .allocator = allocator,
                    .kind = .{ .fs = try fs_backend.FsStorage.open(io, root) },
                };
            },
            .s3 => {
                const config = try resolveS3Config(environment);
                runtime.* = .{
                    .allocator = allocator,
                    .kind = .{ .s3 = .{
                        .http = http_transport.HttpTransport.init(allocator, io),
                        .store = undefined,
                    } },
                };
                // Wired AFTER the runtime is in its final heap slot, so the
                // transport's back-pointer stays valid.
                runtime.kind.s3.store = s3_backend.S3Storage.init(
                    allocator,
                    io,
                    config,
                    runtime.kind.s3.http.asTransport(),
                );
            },
        }
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        switch (self.kind) {
            .fs => |*f| f.deinit(),
            .s3 => |*s| s.http.deinit(),
        }
        self.allocator.destroy(self);
    }

    pub fn asStorage(self: *Runtime) storage.Storage {
        return switch (self.kind) {
            .fs => |*f| f.asStorage(),
            .s3 => |*s| s.store.asStorage(),
        };
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "runtime: no PABRIK_STORAGE_BACKEND defaults to the filesystem store" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(testing.io, &path_buf);
    const root = try std.fs.path.join(alloc, &.{ path_buf[0..base_len], "objects" });
    defer alloc.free(root);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("PABRIK_STORAGE_ROOT", root);

    const runtime = (try Runtime.fromEnvironment(alloc, testing.io, &env)).?;
    defer runtime.deinit();

    try runtime.asStorage().put("k.md", "default store");
    const body = try runtime.asStorage().get(alloc, "k.md");
    defer alloc.free(body);
    try testing.expectEqualStrings("default store", body);
}

test "runtime: an fs backend round-trips a body through the store" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(testing.io, &path_buf);
    const root = try std.fs.path.join(alloc, &.{ path_buf[0..base_len], "objects" });
    defer alloc.free(root);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("PABRIK_STORAGE_BACKEND", "fs");
    try env.put("PABRIK_STORAGE_ROOT", root);

    const runtime = (try Runtime.fromEnvironment(alloc, testing.io, &env)).?;
    defer runtime.deinit();

    try runtime.asStorage().put("k.md", "through the runtime");
    const body = try runtime.asStorage().get(alloc, "k.md");
    defer alloc.free(body);
    try testing.expectEqualStrings("through the runtime", body);
}

test "runtime: an unknown backend name is refused" {
    const alloc = testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("PABRIK_STORAGE_BACKEND", "gcs");

    try testing.expectError(error.UnknownBackend, Runtime.fromEnvironment(alloc, testing.io, &env));
}

test "runtime: s3 without an endpoint is refused" {
    const alloc = testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("PABRIK_STORAGE_BACKEND", "s3");

    try testing.expectError(error.S3EndpointRequired, Runtime.fromEnvironment(alloc, testing.io, &env));
}

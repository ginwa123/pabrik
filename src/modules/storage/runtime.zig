//! Builds the object store the environment asks for, and owns it for the life
//! of the process. `null` means "no object store configured", which keeps every
//! body in the `documents.content` column.

const std = @import("std");
const storage = @import("storage.zig");
const fs_backend = @import("fs.zig");
const s3_backend = @import("s3.zig");
const http_transport = @import("http_transport.zig");
const rustfs_mod = @import("rustfs.zig");
const rustfs_binary = @import("rustfs_binary.zig");

/// Where objects live when neither a flag nor `PABRIK_STORAGE_ROOT` says.
pub const DEFAULT_ROOT_SUFFIX = ".local/share/pabrik/objects";

pub const Backend = enum { fs, s3, rustfs };

/// Resolve the backend: the flag, then `PABRIK_STORAGE_BACKEND`, then `fs`.
pub fn resolveBackend(
    environment: *const std.process.Environ.Map,
    flag: ?[]const u8,
) !Backend {
    const name = flag orelse environment.get("PABRIK_STORAGE_BACKEND") orelse return .fs;
    if (std.mem.eql(u8, name, "fs")) return .fs;
    if (std.mem.eql(u8, name, "s3")) return .s3;
    if (std.mem.eql(u8, name, "rustfs")) return .rustfs;
    return error.UnknownBackend;
}

/// The backend to use when nothing is configured: the supervised rustfs when
/// its binary is there, the filesystem otherwise. An explicit `rustfs` with no
/// binary is an error, never a silent downgrade.
pub fn chooseBackend(
    environment: *const std.process.Environ.Map,
    rustfs_available: bool,
) !Backend {
    const name = environment.get("PABRIK_STORAGE_BACKEND") orelse
        return if (rustfs_available) .rustfs else .fs;
    if (std.mem.eql(u8, name, "fs")) return .fs;
    if (std.mem.eql(u8, name, "s3")) return .s3;
    if (std.mem.eql(u8, name, "rustfs")) {
        if (!rustfs_available) return error.RustfsBinaryMissing;
        return .rustfs;
    }
    return error.UnknownBackend;
}

/// `$PABRIK_DATA_DIR`, then `$XDG_DATA_HOME/pabrik`, then
/// `$HOME/.local/share/pabrik`.
pub fn resolveDataDir(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
) ![]u8 {
    if (environment.get("PABRIK_DATA_DIR")) |dir| {
        if (dir.len > 0) return allocator.dupe(u8, dir);
    }
    if (environment.get("XDG_DATA_HOME")) |base| {
        if (base.len > 0) return std.fs.path.join(allocator, &.{ base, "pabrik" });
    }
    const home = environment.get("HOME") orelse return error.RootRequired;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "pabrik" });
}

/// `PABRIK_RUSTFS_PORT`, else a free loopback port so two pabrik instances
/// never fight over 9000.
pub fn pickPort(io: std.Io, environment: *const std.process.Environ.Map) !u16 {
    if (environment.get("PABRIK_RUSTFS_PORT")) |raw| {
        if (std.fmt.parseInt(u16, raw, 10)) |port| {
            if (port != 0) return port;
        } else |_| {}
    }
    return freeLoopbackPort(io);
}

fn freeLoopbackPort(io: std.Io) !u16 {
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .mode = .stream });
    defer server.deinit(io);
    return server.socket.address.getPort();
}

/// rustfs answers HTTP before its IAM and storage quorum are up, and returns
/// 503 until they are. Retry the bucket probe until it stops saying so.
fn waitUntilServing(io: std.Io, store: *s3_backend.S3Storage) !void {
    var waited: u32 = 0;
    while (waited < rustfs_mod.READY_TIMEOUT_MS) : (waited += rustfs_mod.READY_POLL_MS) {
        s3_backend.ensureBucket(store) catch |err| switch (err) {
            error.ServiceNotReady => {
                const pause = std.Io.Timeout{ .duration = .{
                    .raw = std.Io.Duration.fromMilliseconds(rustfs_mod.READY_POLL_MS),
                    .clock = .awake,
                } };
                pause.sleep(io) catch return error.RustfsNotServing;
                continue;
            },
            else => return err,
        };
        return;
    }
    return error.RustfsNotServing;
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

pub const Credentials = struct {
    access_key: []u8,
    secret_key: []u8,
};

/// Start a supervised rustfs. Credentials are generated once and kept in the
/// data dir, so a restart keeps the same bucket owner.
pub fn startRustfs(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
) !*rustfs_mod.Supervisor {
    const found = try rustfs_binary.resolveDefault(allocator, io);
    defer found.deinit(allocator);

    const data_root = try resolveDataDir(allocator, environment);
    defer allocator.free(data_root);
    std.Io.Dir.cwd().createDirPath(io, data_root) catch {};

    const data_dir = try std.fs.path.join(allocator, &.{ data_root, "rustfs" });
    defer allocator.free(data_dir);

    const pid_file = try std.fs.path.join(allocator, &.{ data_root, rustfs_mod.PID_FILE });
    defer allocator.free(pid_file);

    const port = try pickPort(io, environment);

    const creds = try resolveRustfsCredentials(allocator, io, environment, data_root);
    defer allocator.free(creds.access_key);
    defer allocator.free(creds.secret_key);

    return rustfs_mod.Supervisor.start(allocator, io, .{
        .binary = found.path,
        .data_dir = data_dir,
        .pid_file = pid_file,
        .port = port,
        .access_key = creds.access_key,
        .secret_key = creds.secret_key,
        .environment = environment,
    });
}

/// `PABRIK_RUSTFS_ACCESS_KEY`/`_SECRET_KEY`, else the pair persisted in the
/// data dir, else a fresh random pair written there.
pub fn resolveRustfsCredentials(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    data_root: []const u8,
) !Credentials {
    if (environment.get("PABRIK_RUSTFS_ACCESS_KEY")) |access| {
        if (environment.get("PABRIK_RUSTFS_SECRET_KEY")) |secret| {
            if (access.len > 0 and secret.len > 0) {
                return .{
                    .access_key = try allocator.dupe(u8, access),
                    .secret_key = try allocator.dupe(u8, secret),
                };
            }
        }
    }

    const path = try std.fs.path.join(allocator, &.{ data_root, "rustfs-credentials" });
    defer allocator.free(path);

    if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096))) |text| {
        defer allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        const access = lines.next() orelse "";
        const secret = lines.next() orelse "";
        if (access.len > 0 and secret.len > 0) {
            return .{
                .access_key = try allocator.dupe(u8, access),
                .secret_key = try allocator.dupe(u8, secret),
            };
        }
    } else |_| {}

    var access_bytes: [16]u8 = undefined;
    var secret_bytes: [32]u8 = undefined;
    std.Io.random(io, &access_bytes);
    std.Io.random(io, &secret_bytes);
    const access = try std.fmt.allocPrint(allocator, "pabrik-{x}", .{&access_bytes});
    errdefer allocator.free(access);
    const secret = try std.fmt.allocPrint(allocator, "{x}", .{&secret_bytes});
    errdefer allocator.free(secret);

    const body = try std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{ access, secret });
    defer allocator.free(body);
    if (std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true })) |file| {
        defer file.close(io);
        file.writeStreamingAll(io, body) catch {};
    } else |_| {}

    return .{ .access_key = access, .secret_key = secret };
}

/// A live backend. Heap-allocated because the `Storage` handle points INTO it,
/// so it must not move after construction.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    kind: Kind,

    pub const Kind = union(enum) {
        fs: fs_backend.FsStorage,
        s3: S3,
        rustfs: Rustfs,
    };

    pub const S3 = struct {
        http: http_transport.HttpTransport,
        store: s3_backend.S3Storage,
    };

    /// A rustfs this process started and owns. The supervisor is a pointer so
    /// the S3 store's transport back-pointer stays valid.
    pub const Rustfs = struct {
        supervisor: *rustfs_mod.Supervisor,
        http: http_transport.HttpTransport,
        store: s3_backend.S3Storage,
    };

    /// Build the store the environment asks for. With nothing configured the
    /// supervised rustfs wins when its binary is installed, and the filesystem
    /// store is the fallback.
    pub fn fromEnvironment(
        allocator: std.mem.Allocator,
        io: std.Io,
        environment: *const std.process.Environ.Map,
    ) !?*Runtime {
        const available = rustfs_binary.available(allocator, io);
        return fromBackend(allocator, io, environment, try chooseBackend(environment, available));
    }

    /// Build one specific backend, bypassing the default choice.
    pub fn fromBackend(
        allocator: std.mem.Allocator,
        io: std.Io,
        environment: *const std.process.Environ.Map,
        backend: Backend,
    ) !?*Runtime {
        const runtime = try allocator.create(Runtime);
        errdefer allocator.destroy(runtime);

        switch (backend) {
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
            .rustfs => {
                const supervisor = try startRustfs(allocator, io, environment);
                errdefer supervisor.deinit();

                runtime.* = .{
                    .allocator = allocator,
                    .kind = .{ .rustfs = .{
                        .supervisor = supervisor,
                        .http = http_transport.HttpTransport.init(allocator, io),
                        .store = undefined,
                    } },
                };
                runtime.kind.rustfs.store = s3_backend.S3Storage.init(
                    allocator,
                    io,
                    .{
                        .endpoint = supervisor.endpoint,
                        .bucket = environment.get("PABRIK_S3_BUCKET") orelse "pabrik",
                        .region = environment.get("PABRIK_S3_REGION") orelse "us-east-1",
                        .access_key = supervisor.access_key,
                        .secret_key = supervisor.secret_key,
                    },
                    runtime.kind.rustfs.http.asTransport(),
                );
                // A fresh rustfs has no buckets, so the first write would fail
                // with NoSuchBucket.
                try waitUntilServing(io, &runtime.kind.rustfs.store);
            },
        }
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        switch (self.kind) {
            .fs => |*f| f.deinit(),
            .s3 => |*s| s.http.deinit(),
            .rustfs => |*r| {
                r.http.deinit();
                r.supervisor.deinit();
            },
        }
        self.allocator.destroy(self);
    }

    pub fn asStorage(self: *Runtime) storage.Storage {
        return switch (self.kind) {
            .fs => |*f| f.asStorage(),
            .s3 => |*s| s.store.asStorage(),
            .rustfs => |*r| r.store.asStorage(),
        };
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "chooseBackend: nothing configured picks rustfs when the binary is there" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    try testing.expectEqual(Backend.rustfs, try chooseBackend(&env, true));
}

test "chooseBackend: nothing configured falls back to fs without a binary" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    try testing.expectEqual(Backend.fs, try chooseBackend(&env, false));
}

test "chooseBackend: an explicit fs wins over an installed rustfs" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PABRIK_STORAGE_BACKEND", "fs");

    try testing.expectEqual(Backend.fs, try chooseBackend(&env, true));
}

test "chooseBackend: an explicit rustfs without a binary is refused" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PABRIK_STORAGE_BACKEND", "rustfs");

    try testing.expectError(error.RustfsBinaryMissing, chooseBackend(&env, false));
}

test "chooseBackend: an unknown name is refused" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PABRIK_STORAGE_BACKEND", "gcs");

    try testing.expectError(error.UnknownBackend, chooseBackend(&env, true));
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
    try env.put("PABRIK_STORAGE_ROOT", root);

    const runtime = (try Runtime.fromBackend(alloc, testing.io, &env, .fs)).?;
    defer runtime.deinit();

    try runtime.asStorage().put("k.md", "through the runtime");
    const body = try runtime.asStorage().get(alloc, "k.md");
    defer alloc.free(body);
    try testing.expectEqualStrings("through the runtime", body);
}

test "runtime: s3 without an endpoint is refused" {
    const alloc = testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();

    try testing.expectError(error.S3EndpointRequired, Runtime.fromBackend(alloc, testing.io, &env, .s3));
}

test "runtime: the data dir follows XDG_DATA_HOME, then HOME" {
    const alloc = testing.allocator;

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", "/xdg");
    try env.put("HOME", "/home/u");

    // Built with `path.join` so the assertion holds on Windows too.
    const want_xdg = try std.fs.path.join(alloc, &.{ "/xdg", "pabrik" });
    defer alloc.free(want_xdg);
    const xdg = try resolveDataDir(alloc, &env);
    defer alloc.free(xdg);
    try testing.expectEqualStrings(want_xdg, xdg);

    _ = env.orderedRemove("XDG_DATA_HOME");
    const want_home = try std.fs.path.join(alloc, &.{ "/home/u", ".local", "share", "pabrik" });
    defer alloc.free(want_home);
    const home = try resolveDataDir(alloc, &env);
    defer alloc.free(home);
    try testing.expectEqualStrings(want_home, home);
}

test "runtime: PABRIK_RUSTFS_PORT is honoured, and a free port is picked otherwise" {
    const alloc = testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();

    try env.put("PABRIK_RUSTFS_PORT", "9123");
    try testing.expectEqual(@as(u16, 9123), try pickPort(testing.io, &env));

    _ = env.orderedRemove("PABRIK_RUSTFS_PORT");
    const picked = try pickPort(testing.io, &env);
    try testing.expect(picked != 0);
    try testing.expect(picked != 9123);
}

test "runtime: rustfs credentials are generated once and reused" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(root);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();

    const first = try resolveRustfsCredentials(alloc, testing.io, &env, root);
    defer alloc.free(first.access_key);
    defer alloc.free(first.secret_key);

    const second = try resolveRustfsCredentials(alloc, testing.io, &env, root);
    defer alloc.free(second.access_key);
    defer alloc.free(second.secret_key);

    try testing.expect(first.access_key.len > 0);
    try testing.expect(first.secret_key.len > 0);
    try testing.expectEqualStrings(first.access_key, second.access_key);
    try testing.expectEqualStrings(first.secret_key, second.secret_key);
}

test "runtime: rustfs credentials come from the environment when both are set" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(root);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("PABRIK_RUSTFS_ACCESS_KEY", "given-access");
    try env.put("PABRIK_RUSTFS_SECRET_KEY", "given-secret");

    const creds = try resolveRustfsCredentials(alloc, testing.io, &env, root);
    defer alloc.free(creds.access_key);
    defer alloc.free(creds.secret_key);

    try testing.expectEqualStrings("given-access", creds.access_key);
    try testing.expectEqualStrings("given-secret", creds.secret_key);
}

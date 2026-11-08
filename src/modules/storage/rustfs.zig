//! Supervises a local rustfs process so an install needs no separate service:
//! it starts `rustfs server <data_dir> --address 127.0.0.1:<port>`, waits for
//! the port, and terminates it on shutdown.

const std = @import("std");
const builtin = @import("builtin");

/// How long to wait for the port to answer before giving up.
pub const READY_TIMEOUT_MS: u32 = 15_000;
/// How often to retry while waiting.
pub const READY_POLL_MS: u32 = 100;

pub const StartError = error{
    DataDirFailed,
    SpawnFailed,
    NotReady,
    OutOfMemory,
};

pub const Options = struct {
    /// Absolute path to the rustfs executable.
    binary: []const u8,
    /// Directory rustfs keeps its objects in.
    data_dir: []const u8,
    /// Loopback port the S3 API listens on.
    port: u16,
    access_key: []const u8,
    secret_key: []const u8,
    /// The parent environment, cloned so rustfs inherits PATH and friends.
    environment: *const std.process.Environ.Map,
};

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    /// `http://127.0.0.1:<port>`, owned.
    endpoint: []u8,
    access_key: []u8,
    secret_key: []u8,
    data_dir: []u8,

    /// Start rustfs and wait until its S3 port answers.
    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        opts: Options,
    ) StartError!*Supervisor {
        if (opts.data_dir.len == 0) return error.DataDirFailed;
        std.Io.Dir.cwd().createDirPath(io, opts.data_dir) catch return error.DataDirFailed;

        const self = allocator.create(Supervisor) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);

        const endpoint = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{opts.port}) catch
            return error.OutOfMemory;
        errdefer allocator.free(endpoint);

        const access_key = allocator.dupe(u8, opts.access_key) catch return error.OutOfMemory;
        errdefer allocator.free(access_key);
        const secret_key = allocator.dupe(u8, opts.secret_key) catch return error.OutOfMemory;
        errdefer allocator.free(secret_key);
        const data_dir = allocator.dupe(u8, opts.data_dir) catch return error.OutOfMemory;
        errdefer allocator.free(data_dir);

        var address_buf: [64]u8 = undefined;
        const address = std.fmt.bufPrint(&address_buf, "127.0.0.1:{d}", .{opts.port}) catch
            return error.SpawnFailed;

        var env = opts.environment.clone(allocator) catch return error.OutOfMemory;
        defer env.deinit();
        env.put("RUSTFS_ACCESS_KEY", opts.access_key) catch return error.OutOfMemory;
        env.put("RUSTFS_SECRET_KEY", opts.secret_key) catch return error.OutOfMemory;
        // The console is a second listener on a second port; pabrik never uses
        // it, and leaving it on would collide with a second pabrik instance.
        env.put("RUSTFS_CONSOLE_ENABLE", "false") catch return error.OutOfMemory;

        const log_path = std.fs.path.join(allocator, &.{ opts.data_dir, "rustfs.log" }) catch
            return error.OutOfMemory;
        defer allocator.free(log_path);
        const log_file: ?std.Io.File = std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true }) catch null;
        defer if (log_file) |file| file.close(io);

        const argv = [_][]const u8{ opts.binary, "server", opts.data_dir, "--address", address };
        const child = std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = if (log_file) |file| .{ .file = file } else .ignore,
            .stderr = if (log_file) |file| .{ .file = file } else .ignore,
            .environ_map = &env,
        }) catch return error.SpawnFailed;

        self.* = .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .endpoint = endpoint,
            .access_key = access_key,
            .secret_key = secret_key,
            .data_dir = data_dir,
        };

        if (!waitUntilReady(io, opts.port, READY_TIMEOUT_MS)) {
            self.deinit();
            return error.NotReady;
        }
        return self;
    }

    /// Terminate the process and release everything. Safe to call twice.
    pub fn deinit(self: *Supervisor) void {
        // `kill` reaps the child itself; a following `wait` would assert.
        self.child.kill(self.io);
        self.allocator.free(self.endpoint);
        self.allocator.free(self.access_key);
        self.allocator.free(self.secret_key);
        self.allocator.free(self.data_dir);
        self.allocator.destroy(self);
    }
};

/// Poll the loopback port until it answers HTTP, or the budget runs out. A
/// bare TCP connect is not enough: rustfs binds the listener before it can
/// serve, and a restart on an existing volume answers 503 while it recovers.
pub fn waitUntilReady(io: std.Io, port: u16, timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += READY_POLL_MS) {
        if (answersHttp(io, port)) return true;
        const pause = std.Io.Timeout{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(READY_POLL_MS),
            .clock = .awake,
        } };
        pause.sleep(io) catch return false;
    }
    return false;
}

/// One unauthenticated request; any HTTP status line means the server is up.
fn answersHttp(io: std.Io, port: u16) bool {
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    const stream = address.connect(io, .{ .mode = .stream }) catch return false;
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n") catch
        return false;
    writer.interface.flush() catch return false;

    var read_buf: [256]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var head: [5]u8 = undefined;
    reader.interface.readSliceAll(&head) catch return false;
    return std.mem.eql(u8, &head, "HTTP/");
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "waitUntilReady: a port nothing listens on is not ready" {
    // Port 1 on loopback is never bound, so the whole budget is spent and the
    // answer is false. A short budget keeps the test fast.
    try testing.expect(!waitUntilReady(testing.io, 1, 200));
}

test "supervisor: an empty data dir is refused before anything is spawned" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    try testing.expectError(error.DataDirFailed, Supervisor.start(testing.allocator, testing.io, .{
        .binary = "/nonexistent/rustfs",
        .data_dir = "",
        .port = 1,
        .access_key = "a",
        .secret_key = "s",
        .environment = &env,
    }));
}

test "supervisor: a binary that does not exist is SpawnFailed, not a hang" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    try testing.expectError(error.SpawnFailed, Supervisor.start(testing.allocator, testing.io, .{
        .binary = "/nonexistent/rustfs",
        .data_dir = dir,
        .port = 1,
        .access_key = "a",
        .secret_key = "s",
        .environment = &env,
    }));
}

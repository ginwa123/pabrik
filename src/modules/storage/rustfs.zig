//! Supervises a local rustfs process so an install needs no separate service:
//! it starts `rustfs server <data_dir> --address 127.0.0.1:<port>`, waits for
//! the port, and terminates it on shutdown.

const std = @import("std");
const builtin = @import("builtin");

/// How long to wait for the port to answer before giving up.
pub const READY_TIMEOUT_MS: u32 = 15_000;
/// How often to retry while waiting.
pub const READY_POLL_MS: u32 = 100;
/// How long a stale instance gets to honour SIGTERM before SIGKILL.
pub const STALE_GRACE_MS: u32 = 2_000;

/// Written after a successful spawn, removed on a clean shutdown.
pub const PID_FILE = "pabrik-fs.pid";

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
    /// Where the child pid is recorded, so a hard-killed run can be reaped.
    pid_file: []const u8,
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
    pid_file: []u8,

    /// Start rustfs and wait until its S3 port answers.
    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        opts: Options,
    ) StartError!*Supervisor {
        if (opts.data_dir.len == 0) return error.DataDirFailed;
        std.Io.Dir.cwd().createDirPath(io, opts.data_dir) catch return error.DataDirFailed;

        // A previous run killed hard (SIGKILL, a crash, the OOM killer) left
        // rustfs behind, and a second instance on the same volume is a
        // corruption risk. Reap it before starting a new one.
        stopStale(io, allocator, opts.pid_file);

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
        const pid_file = allocator.dupe(u8, opts.pid_file) catch return error.OutOfMemory;
        errdefer allocator.free(pid_file);

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
            .pid_file = pid_file,
        };

        // POSIX only: `child.id` is a HANDLE on Windows, and the sweep below
        // is the POSIX half of the hard-kill story (Windows needs a Job
        // Object, which is a separate change).
        if (comptime builtin.os.tag != .windows) {
            writePidFile(io, allocator, opts.pid_file, child.id orelse 0);
        }

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
        std.Io.Dir.cwd().deleteFile(self.io, self.pid_file) catch {};
        self.allocator.free(self.endpoint);
        self.allocator.free(self.access_key);
        self.allocator.free(self.secret_key);
        self.allocator.free(self.data_dir);
        self.allocator.free(self.pid_file);
        self.allocator.destroy(self);
    }
};

/// This process's id, as an i32 on every host.
fn currentPid() i32 {
    if (comptime builtin.os.tag == .windows) {
        return @intCast(std.os.windows.GetCurrentProcessId());
    }
    return @intCast(std.c.getpid());
}

fn writePidFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, pid: i32) void {
    if (pid <= 0) return;
    const body = std.fmt.allocPrint(allocator, "{d}\n", .{pid}) catch return;
    defer allocator.free(body);
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, body) catch {};
}

/// Stop the process named by a pid file left behind by a hard-killed run.
/// The name check is what makes this safe: a reused pid belongs to something
/// else and is left alone. Windows has no pid file, so the sweep is a no-op.
const stopStale = if (builtin.os.tag == .windows) stopStaleNoop else stopStalePosix;

fn stopStaleNoop(io: std.Io, allocator: std.mem.Allocator, pid_file: []const u8) void {
    _ = io;
    _ = allocator;
    _ = pid_file;
}

fn stopStalePosix(io: std.Io, allocator: std.mem.Allocator, pid_file: []const u8) void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, pid_file, allocator, .limited(32)) catch return;
    defer allocator.free(text);

    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, text, " \t\r\n"), 10) catch return;
    if (pid <= 0 or pid == currentPid()) return;
    if (!isOurRustfs(io, pid)) return;

    std.posix.kill(pid, .TERM) catch return;
    var waited: u32 = 0;
    while (waited < STALE_GRACE_MS) : (waited += READY_POLL_MS) {
        if (!isOurRustfs(io, pid)) return;
        sleepMillis(io, READY_POLL_MS);
    }
    std.posix.kill(pid, .KILL) catch {};
}

/// Whether `pid` is a rustfs/pabrik-fs process. False for a dead pid, and
/// false for a live pid that is something else.
fn isOurRustfs(io: std.Io, pid: i32) bool {
    if (comptime builtin.os.tag == .linux) {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return false;
        // Not `readFileAlloc`: /proc reports size 0, and the alloc path then
        // returns an empty slice without reading.
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
        defer file.close(io);
        var read_buf: [64]u8 = undefined;
        var out: [64]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        const n = reader.interface.readSliceShort(&out) catch return false;
        const name = std.mem.trimEnd(u8, out[0..n], "\n");
        return std.mem.eql(u8, name, "pabrik-fs") or std.mem.eql(u8, name, "rustfs");
    }
    if (comptime builtin.os.tag == .macos) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = macos.proc_pidpath(pid, &buf, buf.len);
        if (n <= 0) return false;
        const path = buf[0..@intCast(n)];
        const name = std.fs.path.basename(path);
        return std.mem.eql(u8, name, "pabrik-fs") or std.mem.eql(u8, name, "rustfs");
    }
    return false;
}

const macos = if (builtin.os.tag == .macos) struct {
    extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
} else struct {};

fn sleepMillis(io: std.Io, ms: u32) void {
    const pause = std.Io.Timeout{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(ms),
        .clock = .awake,
    } };
    pause.sleep(io) catch {};
}

/// Poll the loopback port until it answers HTTP, or the budget runs out. A
/// bare TCP connect is not enough: rustfs binds the listener before it can
/// serve, and a restart on an existing volume answers 503 while it recovers.
pub fn waitUntilReady(io: std.Io, port: u16, timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += READY_POLL_MS) {
        if (answersHttp(io, port)) return true;
        sleepMillis(io, READY_POLL_MS);
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
        .pid_file = "/tmp/pabrik/never.pid",
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
        .pid_file = "/tmp/pabrik/never.pid",
        .port = 1,
        .access_key = "a",
        .secret_key = "s",
        .environment = &env,
    }));
}

test "stopStale: a pid file naming a process that is not rustfs is left alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);

    const pid_file = try std.fs.path.join(testing.allocator, &.{ dir, PID_FILE });
    defer testing.allocator.free(pid_file);

    // Our own pid: alive, but not a rustfs, so nothing may be signalled.
    const body = try std.fmt.allocPrint(testing.allocator, "{d}\n", .{currentPid()});
    defer testing.allocator.free(body);
    const file = try tmp.dir.createFile(testing.io, PID_FILE, .{});
    try file.writeStreamingAll(testing.io, body);
    file.close(testing.io);

    stopStale(testing.io, testing.allocator, pid_file);
    // Reaching here means the test process was not killed.
    try testing.expect(true);
}

test "stopStale: a pid file naming a dead process is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);

    const pid_file = try std.fs.path.join(testing.allocator, &.{ dir, PID_FILE });
    defer testing.allocator.free(pid_file);

    const file = try tmp.dir.createFile(testing.io, PID_FILE, .{});
    try file.writeStreamingAll(testing.io, "999999\n");
    file.close(testing.io);

    stopStale(testing.io, testing.allocator, pid_file);
    try testing.expect(true);
}

test "stopStale: a missing pid file is a no-op" {
    stopStale(testing.io, testing.allocator, "/tmp/pabrik/definitely-not-here.pid");
    try testing.expect(true);
}

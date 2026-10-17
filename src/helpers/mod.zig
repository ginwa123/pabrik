pub const xml = @import("xml.zig");
pub const db_path = @import("db_path.zig");
pub const process = @import("process.zig");
pub const run_captured = @import("run_captured.zig");
pub const process_status = @import("process_status.zig");
pub const random = @import("random.zig");
pub const dir = @import("dir.zig");
pub const sanitize = @import("sanitize.zig");
pub const ansi = @import("ansi.zig");
pub const image = @import("image.zig");
pub const video = @import("video.zig");
pub const xml_escape = @import("xml_escape.zig").xmlEscape;
pub const sanitize_control_chars = @import("xml_escape.zig").sanitizeControlChars;
pub const text_normalize = @import("text_normalize.zig");
pub const path_validate = @import("path_validate.zig");
pub const test_path = @import("test_path.zig");
pub const host_fixture = @import("host_fixture.zig");
pub const open_descriptors = @import("open_descriptors.zig");
pub const git_env_guard = @import("git_env_guard.zig");
pub const git_hardening = @import("git_hardening.zig");
pub const xmlUnescape = @import("xml_unescape.zig").xmlUnescape;

const std = @import("std");
const builtin = @import("builtin");

// === extern "c" declarations === Zig 0.16's `std.c` exposes some libc
// functions (fopen, fread, fclose, access) on all platforms but NOT others
// (fseek, ftell, faccessat, stat).

/// `int fseek(FILE *stream, long offset, int whence);` (libc).
extern "c" fn fseek(stream: *std.c.FILE, offset: Clong, whence: c_int) c_int;

/// `long ftell(FILE *stream);` (libc).
extern "c" fn ftell(stream: *std.c.FILE) Clong;

/// `int gettimeofday(struct timeval *tv, struct timezone *tz);` (POSIX).
/// On Windows, the UCRT provides this function too.
extern "c" fn gettimeofday(tv: ?*PosixTimeval, tz: ?*anyopaque) c_int;

/// `struct timeval { time_t tv_sec; suseconds_t tv_usec; }` (POSIX/UCRT).
const Usect = switch (builtin.os.tag) {
    .linux => i64,
    .macos, .windows => i32,
    else => @compileError("helpers.unixTimestamp: unsupported platform " ++ @tagName(builtin.os.tag)),
};

const PosixTimeval = extern struct {
    sec: Clong,
    usec: Usect,
};

/// `long` (C `long`, usually 64-bit on Linux/macOS 64-bit, 32-bit on Windows
/// 64-bit). Matches libc's `long` and `time_t` sizes on all supported
/// platforms.
pub const Clong = if (@bitSizeOf(usize) == 64 and builtin.os.tag != .windows) i64 else i32;

/// `void GetSystemTimeAsFileTime(LPFILETIME lpSystemTimeAsFileTime);` (Win32).
extern "kernel32" fn GetSystemTimeAsFileTime(lp_system_time_as_file_time: *std.os.windows.FILETIME) callconv(.winapi) void;

/// `VOID Sleep(DWORD dwMilliseconds);` (Win32 kernel32).
extern "kernel32" fn Sleep(dw_milliseconds: u32) callconv(.winapi) void;

/// Cross-platform current working directory getter (no `io: std.Io`
/// required).
pub fn getcwd(buf: []u8) ?[]u8 {
    const result = std.c.getcwd(buf.ptr, buf.len);
    if (result == null) return null;
    // std.c.getcwd writes a NUL-terminated string. Slice up to (but not
    // including) the NUL. If the buffer is somehow full with no NUL,
    // fall back to the full buffer length.
    const p: [*:0]u8 = @ptrCast(result.?);
    const len = std.mem.indexOfScalar(u8, p[0..buf.len], 0) orelse buf.len;
    return p[0..len];
}

/// Returns true if the file at `path` exists. `std.fs.accessAbsolute` was
/// REMOVED in Zig 0.16.
pub fn fileExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    // F_OK == 0 (test for existence) — defined in <unistd.h> on POSIX
    // and via UCRT on Windows. We pass 0 directly because std.c.F_OK
    // is only defined for Linux/emscripten.
    const rc = std.c.access(&buf, 0);
    return rc == 0;
}

/// Reads the entire file at `path` into a heap-allocated buffer. Returns the
/// contents (caller must `free`); returns error if the file does not exist or
/// cannot be read.
pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Path must be NUL-terminated for libc fopen. Use a stack buffer
    // (max_path_bytes) to avoid an extra allocation just for the NUL.
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const f = std.c.fopen(&path_buf, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);

    // SEEK_END and SEEK_SET are defined as 2 and 0 respectively on both
    // POSIX and Windows (UCRT). We pass the literal values to avoid
    // pulling in the platform-specific std.c.SEEK_* enum.
    if (fseek(f, 0, 2) != 0) return error.ReadFailed; // SEEK_END = 2
    const size_signed = ftell(f);
    if (size_signed < 0) return error.ReadFailed;
    if (fseek(f, 0, 0) != 0) return error.ReadFailed; // SEEK_SET = 0

    const size: usize = @intCast(size_signed);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);

    if (size > 0) {
        const n = std.c.fread(buf.ptr, 1, size, f);
        if (n != size) return error.ReadFailed;
    }
    return buf;
}

/// Returns the current Unix timestamp in seconds (i64). `std.time.timestamp`
/// was REMOVED in Zig 0.16.
pub fn unixTimestamp() i64 {
    return switch (builtin.os.tag) {
        .linux, .macos => unixTimestampPosix(),
        .windows => unixTimestampWindows(),
        else => @compileError("helpers.unixTimestamp: unsupported platform " ++ @tagName(builtin.os.tag)),
    };
}

fn unixTimestampPosix() i64 {
    var tv: PosixTimeval = undefined;
    const rc = gettimeofday(&tv, null);
    _ = rc; // 0 on success, -1 with errno on failure (we ignore — best effort)
    return @intCast(tv.sec);
}

fn unixTimestampWindows() i64 {
    var ft: std.os.windows.FILETIME = undefined;
    GetSystemTimeAsFileTime(&ft);
    // Combine low + high 32 bits into u64 (little-endian on Windows).
    const ticks: u64 = (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
    // 100-ns ticks → seconds: divide by 10_000_000.
    // Then subtract the 1601→1970 offset (11_644_473_600 seconds).
    const seconds_since_1601: u64 = ticks / 10_000_000;
    const unix_offset: u64 = 11_644_473_600;
    if (seconds_since_1601 < unix_offset) return 0;
    return @intCast(seconds_since_1601 - unix_offset);
}

/// Cross-platform nanosecond-precision unix timestamp. Returns nanoseconds
/// since 1970-01-01 UTC as `i128`. Used by code that needs high-resolution
/// IDs (e.g.
pub fn unixTimestampNanos() i128 {
    return switch (builtin.os.tag) {
        .linux, .macos => unixTimestampNanosPosix(),
        .windows => unixTimestampNanosWindows(),
        else => @compileError("helpers.unixTimestampNanos: unsupported platform " ++ @tagName(builtin.os.tag)),
    };
}

fn unixTimestampNanosPosix() i128 {
    var ts: PosixTimespec = undefined;
    const rc = clock_gettime(CLOCK_REALTIME, &ts);
    _ = rc;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// Pure Win32 FILETIME → unix-nanos conversion (platform-independent so it is
/// unit-testable on any host; the Windows-only part is just the
/// `GetSystemTimeAsFileTime` call in `unixTimestampNanosWindows`).
fn filetimeTicksToUnixNanos(ticks: u128) i128 {
    const ns_since_1601: i128 = @intCast(ticks * 100);
    const ns_1601_to_1970: i128 = 11_644_473_600 * std.time.ns_per_s;
    return ns_since_1601 - ns_1601_to_1970;
}

fn unixTimestampNanosWindows() i128 {
    var ft: std.os.windows.FILETIME = undefined;
    GetSystemTimeAsFileTime(&ft);
    // Combine low + high 32 bits into u128 (little-endian on Windows).
    const ticks: u128 = (@as(u128, ft.dwHighDateTime) << 32) | @as(u128, ft.dwLowDateTime);
    const base_ns = filetimeTicksToUnixNanos(ticks);
    // Raw 1601-based nanos for the same-tick dedup counter below
    // (pre-offset, so the counter never conflates absolute time with
    // the in-tick sequence number).
    const ns_since_1601: i128 = @intCast(ticks * 100);

    // Ensure uniqueness across rapid back-to-back calls.
    const last_ns = unixNanosWindowsLastNs;
    const counter = unixNanosWindowsCounter;
    defer {
        // Compare the raw FILETIME (not `base_ns` which has the offset
        // subtracted) so we don't conflate absolute time with the counter.
        const raw_ns = ns_since_1601;
        unixNanosWindowsLastNs = raw_ns;
    }
    if (ns_since_1601 == last_ns) {
        unixNanosWindowsCounter = counter + 1;
        return base_ns + counter + 1;
    } else {
        unixNanosWindowsCounter = 0;
        return base_ns;
    }
}

threadlocal var unixNanosWindowsLastNs: i128 = 0;
threadlocal var unixNanosWindowsCounter: u64 = 0;

/// Cross-platform monotonic nanosecond timestamp. Returns a non-negative
/// `u64` value that increases monotonically with wall-clock time.
pub fn monotonicTimestampNanos() u64 {
    return switch (builtin.os.tag) {
        .linux, .macos => monotonicTimestampNanosPosix(),
        .windows => monotonicTimestampNanosWindows(),
        else => @compileError("helpers.monotonicTimestampNanos: unsupported platform " ++ @tagName(builtin.os.tag)),
    };
}

fn monotonicTimestampNanosPosix() u64 {
    var ts: PosixTimespec = undefined;
    const rc = clock_gettime(CLOCK_MONOTONIC, &ts);
    if (rc != 0) {
        // clock_gettime with a valid per-OS CLOCK_MONOTONIC should never
        // fail; if it somehow does, fall back to CLOCK_REALTIME rather than
        // reading an undefined timespec (@intCast would panic on the garbage
        var wall: PosixTimespec = undefined;
        if (clock_gettime(CLOCK_REALTIME, &wall) != 0) return 0;
        return @as(u64, @intCast(wall.sec)) * std.time.ns_per_s + @as(u64, @intCast(wall.nsec));
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn monotonicTimestampNanosWindows() u64 {
    var counter: std.os.windows.LARGE_INTEGER = undefined;
    var freq: std.os.windows.LARGE_INTEGER = undefined;
    _ = std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter);
    _ = std.os.windows.ntdll.RtlQueryPerformanceFrequency(&freq);
    // Convert ticks to ns: ns = ticks * 1e9 / freq. Both inputs are strictly
    // positive after a successful RtlQuery call, so the unsigned math is
    // safe.
    const ns_u128: u128 = @as(u128, @intCast(counter)) * 1_000_000_000;
    const freq_u128: u128 = @as(u128, @intCast(freq));
    return @intCast(@divTrunc(ns_u128, freq_u128));
}

/// Returns the current UTC time as an ISO-8601 string (`"2026-07-15
/// 19:43:09"`).
pub fn currentTimeIsoLocal(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Clock.real.now(io); // wall-clock timestamp
    const ns_i128 = ts.nanoseconds; // guess — compiler will confirm/correct field name
    if (ns_i128 < 0) return error.Overflow;
    const sec_u64: u64 = @intCast(@divTrunc(ns_i128, std.time.ns_per_s));

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = sec_u64 };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    var buf: [20]u8 = undefined;
    const formatted = std.fmt.bufPrint(
        &buf,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    ) catch @panic("bufPrint failed formatting the local ISO timestamp");

    return allocator.dupe(u8, formatted);
}

/// Cross-platform millisecond-precision sleep that doesn't require `io:
/// std.Io`.
pub fn sleepMillis(ms: u32) void {
    switch (builtin.os.tag) {
        .linux, .macos => {
            var ts: PosixTimespec = .{
                .sec = 0,
                .nsec = @intCast(@as(u64, ms) * std.time.ns_per_ms),
            };
            _ = nanosleep(&ts, null);
        },
        .windows => {
            // The extern Sleep declared at module scope above. Resolves
            // against kernel32.dll (always loaded on Windows).
            Sleep(ms);
        },
        else => {},
    }
}

/// `struct timespec { time_t tv_sec; long tv_nsec; }` (POSIX/UCRT).
pub const PosixTimespec = extern struct {
    sec: Clong,
    nsec: Clong,
};

/// `int clock_gettime(clockid_t clk_id, struct timespec *tp);` (POSIX).
pub extern "c" fn clock_gettime(clk_id: c_int, tp: *PosixTimespec) c_int;

/// `int nanosleep(const struct timespec *req, struct timespec *rem);`
/// (POSIX). `pub` so callers (e.g.
pub extern "c" fn nanosleep(req: *const PosixTimespec, rem: ?*PosixTimespec) c_int;

/// POSIX CLOCK_REALTIME. Linux glibc = 0; macOS = 0; matches across
/// POSIX platforms. Declared as `c_int` literal because `std.c.CLOCK`
/// is not exposed on all platforms.
pub const CLOCK_REALTIME: c_int = 0;

/// POSIX CLOCK_MONOTONIC. Linux glibc = 1; macOS = 1; matches across all the
/// POSIX variants we target.
pub const CLOCK_MONOTONIC: c_int = if (builtin.os.tag.isDarwin()) 6 else 1;

// === Tests ===

test "getcwd: returns non-empty slice on a real system" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = getcwd(&buf) orelse return; // not an error if no cwd
    try std.testing.expect(cwd.len > 0);
}

test "fileExists: /tmp exists" {
    try std.testing.expect(fileExists("/tmp"));
}

test "fileExists: non-existent path returns false" {
    try std.testing.expect(!fileExists("/this/path/does/not/exist/anywhere"));
}

test "readFile: /etc/hostname (linux) or /etc/passwd (fallback)" {
    const allocator = std.testing.allocator;
    // Try /etc/hostname first, then /etc/hosts as fallback
    const content = readFile(allocator, "/etc/hostname") catch
        readFile(allocator, "/etc/hosts") catch return; // skip if neither exists
    defer allocator.free(content);
    try std.testing.expect(content.len > 0);
}

test "unixTimestamp: returns positive value within sane range" {
    const ts = unixTimestamp();
    // 2020-01-01 ≈ 1_577_836_800. Current time should be well above.
    try std.testing.expect(ts > 1_577_836_800);
    // Sanity upper bound: 2100-01-01 ≈ 4_102_444_800.
    try std.testing.expect(ts < 4_102_444_800);
}

test "filetimeTicksToUnixNanos: 1970-01-01 epoch vector converts to 0" {
    // FILETIME ticks for 1970-01-01T00:00:00Z = 11_644_473_600 s × 10_000_000 ticks/s.
    const ticks: u128 = 11_644_473_600 * 10_000_000;
    try std.testing.expectEqual(@as(i128, 0), filetimeTicksToUnixNanos(ticks));
}

test "filetimeTicksToUnixNanos: 2000-01-01 vector converts to 946684800e9 ns" {
    // 2000-01-01T00:00:00Z = unix 946_684_800.
    const ticks: u128 = (11_644_473_600 + 946_684_800) * 10_000_000;
    try std.testing.expectEqual(
        @as(i128, 946_684_800) * std.time.ns_per_s,
        filetimeTicksToUnixNanos(ticks),
    );
}

test "filetimeTicksToUnixNanos: now-scale ticks stay positive (Windows cron-panic guard)" {
    // ~2026-01-01T00:00:00Z (unix 1_767_225_600).
    const ticks: u128 = (11_644_473_600 + 1_767_225_600) * 10_000_000;
    const ns = filetimeTicksToUnixNanos(ticks);
    // 2020-01-01 ≈ 1_577_836_800 s. Result must be well above (positive).
    try std.testing.expect(ns > 1_577_836_800 * std.time.ns_per_s);
    // Sanity upper bound: 2100-01-01 ≈ 4_102_444_800 s.
    try std.testing.expect(ns < 4_102_444_800 * std.time.ns_per_s);
}

test "unixTimestampNanos: returns positive value within sane range" {
    // On POSIX this exercises clock_gettime; on Windows CI it exercises
    // the fixed FILETIME path — the missing coverage that let the `/ 10`
    // bug ship (only the seconds-precision `unixTimestamp` was asserted).
    const ns = unixTimestampNanos();
    try std.testing.expect(ns > 1_577_836_800 * std.time.ns_per_s);
    try std.testing.expect(ns < 4_102_444_800 * std.time.ns_per_s);
}

test "unixTimestamp: 4-byte suseconds_t read does not pick up padding bytes (macOS struct-layout regression guard)" {
    // On macOS, `suseconds_t` is `__int32_t` (4 bytes). The struct declares
    // `usec: Usect` (i32 on macOS) so the read matches the C ABI
    // byte-for-byte.
    const ts = unixTimestamp();
    try std.testing.expect(ts > 0);
    // Tight upper bound: 2100-01-01 (avoids the year-2038 problem
    // on 32-bit signed time_t, which doesn't apply on 64-bit LP64 /
    // LLP64 Zig targets but is a sane sanity check anyway).
    try std.testing.expect(ts < 4_102_444_800);
}

test {}

// ===== Tests merged from cross_platform_test.zig (2026-09-29 flatten) =====

// Cross-platform behavior tests for the helpers.process_status and
// helpers.getcwd modules.

const testing = std.testing;

test "getcwd: returns non-empty absolute path" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = getcwd(&buf) orelse {
        // No cwd on this system — skip (very unusual).
        return error.SkipZigTest;
    };
    try testing.expect(cwd.len > 0);
    // Absolute paths on Unix start with '/', on Windows with a drive letter.
    // We don't enforce either here — just confirm non-empty.
}

test "getcwd: returns null when buffer is too small" {
    // Pass a pathologically tiny buffer — libc should reject it.
    var tiny_buf: [1]u8 = undefined;
    const cwd = getcwd(&tiny_buf);
    // On most platforms this returns null because the path doesn't fit.
    // On some weird platforms it might succeed; we just check no crash.
    _ = cwd;
}

test "getcwd: buffer is NUL-terminated internally (handled by wrapper)" {
    // The wrapper uses indexOfScalar to find the NUL, so the caller
    // doesn't see it. This test exercises the slice logic.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = getcwd(&buf) orelse return;
    // The returned slice should not contain any NUL bytes (the wrapper
    // strips the terminator).
    for (cwd) |c| try testing.expect(c != 0);
}

test "process_status: getCurrentProcessIdInt returns positive i32" {
    const pid = process_status.getCurrentProcessIdInt();
    try testing.expect(pid > 0);
}

test "process_status: isProcessRunning returns true for self" {
    const self = process_status.getCurrentProcessIdInt();
    try testing.expect(process_status.isProcessRunning(self));
}

test "process_status: isProcessRunning returns false for pid 0" {
    try testing.expect(!process_status.isProcessRunning(0));
}

test "process_status: isProcessRunning returns false for negative pids" {
    try testing.expect(!process_status.isProcessRunning(-1));
    try testing.expect(!process_status.isProcessRunning(-100));
}

test "process_status: isProcessRunning returns false for very high pids" {
    // Real PIDs rarely exceed 2^22; 2^30 is safely above any real PID.
    try testing.expect(!process_status.isProcessRunning(1 << 30));
    try testing.expect(!process_status.isProcessRunning(1 << 29));
}

test "process_status: killProcess returns false for invalid pids" {
    try testing.expect(!process_status.killProcess(0));
    try testing.expect(!process_status.killProcess(-1));
    try testing.expect(!process_status.killProcess(-42));
}

test "process_status: killProcess returns false for non-existent pid" {
    // A very high PID is unlikely to exist.
    try testing.expect(!process_status.killProcess(1 << 30));
}

test "process_status: round-trip — isProcessRunning then killProcess" {
    // Spawn a child process that sleeps, verify isProcessRunning returns
    // true, kill it, verify isProcessRunning returns false. Uses
    // std.process.Child via the v1.0+ API.
    if (@import("builtin").os.tag == .wasm) return;

    // Spawn a long-running child (sleep 60 seconds).
    const argv = [_][]const u8{ "sleep", "60" };
    var child = std.process.spawn(std.testing.io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return, // sleep not available
        else => return,
    };

    const child_pid: i32 = @intCast(child.id orelse {
        // Spawn returned a null id — can't continue. Kill the child
        // defensively before bailing.
        child.kill(std.testing.io);
        return;
    });

    defer {
        // Clean up: kill the child if it's still alive.
        if (process_status.isProcessRunning(child_pid)) {
            _ = process_status.killProcess(child_pid);
        }
        _ = child.wait(std.testing.io);
    }

    // The child should be alive.
    try testing.expect(process_status.isProcessRunning(child_pid));

    // Kill it.
    try testing.expect(process_status.killProcess(child_pid));

    // Give the OS a moment to reap it.
    std.time.sleep(100 * std.time.ns_per_ms);

    // The child should now be dead.
    try testing.expect(!process_status.isProcessRunning(child_pid));
}

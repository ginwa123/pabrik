const std = @import("std");
const builtin = @import("builtin");
const process = @import("process.zig");

/// Hex digits for ID generation
pub const hex_digits = "0123456789abcdef";

pub fn generateSessionId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Clock.now(.real, io);
    const timestamp: i64 = ts.toSeconds();
    // `process.getCurrentProcessId()` returns `i32` on all platforms
    // (POSIX and Windows). It used to return `std.c.pid_t` which is
    // `*anyopaque` on Windows — comparing that to an `i32` parsed from a
    // shell command would fail to compile cross-platform.
    const pid = process.getCurrentProcessId();
    // Use timestamp + PID + pointer for pseudo-random entropy
    const entropy: u64 = (@as(u64, @intCast(pid)) << 32) ^ @as(u64, @intCast(timestamp));
    var random_bytes: [8]u8 = undefined;
    // std.mem.writeInt handles alignment internally — safe on any
    // stack-allocated buffer. Avoids Zig 0.16's strict `@alignCast`
    // panic when the buffer happens to land on a non-8-byte boundary.
    std.mem.writeInt(u64, &random_bytes, entropy, .little);

    // Convert random bytes to hex string
    var hex_chars: [16]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        hex_chars[i * 2] = hex_digits[b >> 4];
        hex_chars[i * 2 + 1] = hex_digits[b & 0xF];
    }

    return std.fmt.allocPrint(allocator, "sess_{d}_{s}", .{ timestamp, hex_chars });
}

/// Windows bcrypt.dll bindings. Declared locally because `std.c` covers libc
/// only and bcrypt is a separate system DLL that the `databases` package links
/// via `linkSystemLibrary("bcrypt")`. Referenced only from the `.windows` arm
/// of `fillRandom`, so the compiler prunes the extern on POSIX — the same
/// arrangement `agent_memories.generateMemoryId` uses.
const bcrypt = struct {
    extern "bcrypt" fn BCryptGenRandom(
        hAlgorithm: ?*const anyopaque,
        pbBuffer: [*]u8,
        cbBuffer: c_ulong,
        dwFlags: c_ulong,
    ) callconv(.c) c_long;
};

pub const RandomError = error{ RandomFailed, UnsupportedPlatform };

/// Fill `buf` from the operating system's CSPRNG.
///
/// This is the ONLY source of unpredictable bytes in the tree, and it exists
/// because `std.crypto.random` was removed in Zig 0.16 (`Config.zig` says so
/// outright). `generateSessionId` above is deliberately NOT this function: it
/// derives an id from the clock and the pid, which is fine for uniqueness and
/// fatal for a key. Anything an attacker could guess must come from here —
/// today the AES-GCM nonce and the workspace-secrets master key.
///
/// Per platform: Linux `getrandom(2)` (loops on partial reads), Apple
/// `arc4random_buf`, Windows `BCryptGenRandom`. It reports
/// `error.RandomFailed` rather than returning short or zero-filled: a caller
/// that gets predictable bytes must not silently encrypt under them.
pub fn fillRandom(buf: []u8) RandomError!void {
    switch (builtin.os.tag) {
        .linux => {
            var filled: usize = 0;
            while (filled < buf.len) {
                const slice = buf[filled..];
                const got = std.os.linux.getrandom(slice.ptr, slice.len, 0);
                if (got <= 0) return error.RandomFailed;
                filled += @intCast(got);
            }
        },
        .macos, .ios, .tvos, .watchos => {
            // No loop needed — arc4random_buf always fills in one call. The
            // "arc4" in the name is stale: it is SecRandomCopyBytes internally.
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .windows => {
            // BCRYPT_USE_SYSTEM_PREFERRED_RNG (0x00000002).
            const status = bcrypt.BCryptGenRandom(null, buf.ptr, @intCast(buf.len), 0x00000002);
            if (status != 0) return error.RandomFailed;
        },
        else => return error.UnsupportedPlatform,
    }
}

test "fillRandom fills the buffer and does not repeat" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    try fillRandom(&a);
    try fillRandom(&b);

    // Not a randomness test — a "did the OS path run at all" test. Two 32-byte
    // reads colliding is 2^-256, so equality means the buffer was never
    // written (an early-returning switch arm), and a zero buffer is what a
    // silently-failed fill looks like.
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expect(!std.mem.eql(u8, &a, &([_]u8{0} ** 32)));
}

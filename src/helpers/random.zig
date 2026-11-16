const std = @import("std");
const builtin = @import("builtin");

/// Hex digits for ID generation
pub const hex_digits = "0123456789abcdef";

pub fn generateSessionId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Clock.now(.real, io);
    const timestamp: i64 = ts.toSeconds();
    // Cryptographically random entropy (SEC-11): the previous pid^timestamp scheme collided for two sessions created in the same second.
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);

    // Convert random bytes to hex string
    var hex_chars: [16]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        hex_chars[i * 2] = hex_digits[b >> 4];
        hex_chars[i * 2 + 1] = hex_digits[b & 0xF];
    }

    return std.fmt.allocPrint(allocator, "sess_{d}_{s}", .{ timestamp, hex_chars });
}

/// Windows bcrypt.dll bindings.
const bcrypt = struct {
    extern "bcrypt" fn BCryptGenRandom(
        hAlgorithm: ?*const anyopaque,
        pbBuffer: [*]u8,
        cbBuffer: c_ulong,
        dwFlags: c_ulong,
    ) callconv(.c) c_long;
};

pub const RandomError = error{ RandomFailed, UnsupportedPlatform };

/// Fill `buf` from the OS CSPRNG — the one source the AES-GCM nonce and the secrets master key use.
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
            // No loop needed — arc4random_buf always fills in one call.
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

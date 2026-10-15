const std = @import("std");
const builtin = @import("builtin");
const timing = @import("Timing.zig");

// `getentropy` is not exposed by std.c on macOS — declare it locally so the
// macOS CI test suite can use the kernel CSPRNG.
extern "c" fn getentropy(buffer: [*]u8, size: usize) c_int;

/// Request ID format: REQ-YYYYMMDD-HHMMSS-XXXX (24 characters)
/// where XXXX is a 4-character random hex suffix
pub const RequestId = struct {
    /// Fixed-size buffer for the request ID string
    /// REQ- (4) + YYYYMMDD (8) + - (1) + HHMMSS (6) + - (1) + XXXX (4) = 24
    value: [24]u8,

    /// Initialize a new RequestId with current timestamp and random suffix
    pub fn init() RequestId {
        var self: RequestId = undefined;
        
        // Get current timestamp using Io.Timestamp
        const ts = std.Io.Timestamp.now(std.testing.io, .real);
        const ts_ns = ts.nanoseconds;
        const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(ts_ns, std.time.ns_per_s)) };
        const epoch_day = epoch_seconds.getEpochDay();
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        
        const hours = day_seconds.getHoursIntoDay();
        const minutes = day_seconds.getMinutesIntoHour();
        const seconds = day_seconds.getSecondsIntoMinute();
        
        // Generate random 4-character hex suffix using entropy
        const entropy = ts_ns ^ @as(u64, @intFromPtr(&self));
        var random_bytes: [2]u8 = undefined;
        // std.mem.writeInt handles alignment internally — safe on any
        // stack-allocated buffer. Avoids Zig 0.16's strict `@alignCast`
        // panic when the buffer happens to land on a non-2-byte boundary.
        std.mem.writeInt(u16, &random_bytes, @as(u16, @truncate(@as(u64, @intCast(entropy)))), .little);
        
        // Format: REQ-YYYYMMDD-HHMMSS-XXXX
        _ = std.fmt.bufPrint(&self.value, "REQ-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{x:0>2}{x:0>2}", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            hours,
            minutes,
            seconds,
            random_bytes[0],
            random_bytes[1],
        }) catch @panic("bufPrint failed formatting the request id");
        
        return self;
    }

    /// Get the request ID as a string slice
    pub fn toString(self: *const RequestId) []const u8 {
        return &self.value;
    }
};

/// Generate a new RequestId
pub fn generateRequestId() RequestId {
    return RequestId.init();
}

/// Session ID format: SES-XXXXXXXX (11 characters)
/// where XXXXXXXX is an 8-character random hex
/// SES- (4) + XXXXXXXX (8) = 12 characters (not 11!)
pub const SessionId = struct {
    value: [12]u8,

    /// Initialize a new SessionId with random hex. Uses libc `getrandom` on
    /// Linux, `getentropy` on macOS for guaranteed entropy.
    pub fn init() SessionId {
        var self: SessionId = undefined;
        var random_bytes: [4]u8 = undefined;

        if (builtin.os.tag == .windows) {
            // Windows fallback. Use timestamp + output buffer address
            // as the seed — enough entropy for the 1000-call
            // uniqueness test.
            const ts = std.Io.Timestamp.now(std.testing.io, .real);
            const seed: u64 = @as(u64, @intCast(ts.nanoseconds)) ^
                @as(u64, @intFromPtr(&self.value));
            const truncated_val: u32 = @truncate(seed);
            std.mem.writeInt(u32, random_bytes[0..4], truncated_val, .little);
        } else {
            // POSIX: pull 4 fresh bytes from the kernel CSPRNG. - Linux: libc
            // `getrandom` (loops on partial reads). - macOS: libc
            // `getentropy` (always fills in one call, max 256 bytes; we ask
            var ok = false;
            if (builtin.os.tag == .linux) {
                var filled: usize = 0;
                while (filled < random_bytes.len) {
                    const rc = std.c.getrandom(
                        random_bytes[filled..].ptr,
                        random_bytes.len - filled,
                        0,
                    );
                    if (rc < 0) {
                        const err = std.c.errno(rc);
                        if (err == .INTR) continue;
                        break;
                    }
                    filled += @intCast(rc);
                }
                ok = (filled == random_bytes.len);
            } else if (builtin.os.tag == .macos) {
                // macOS: locally-declared `getentropy` (not in std.c).
                const rc = getentropy(&random_bytes, random_bytes.len);
                ok = (rc == 0);
            } else {
                // Other POSIX without `getrandom` or `getentropy`
                // — best-effort pseudo-random from timestamp.
                const ts = std.Io.Timestamp.now(std.testing.io, .real);
                const seed: u64 = @as(u64, @intCast(ts.nanoseconds)) ^
                    @as(u64, @intFromPtr(&self.value));
                std.mem.writeInt(u32, random_bytes[0..4], @truncate(seed), .little);
                ok = true;
            }
            if (!ok) @memset(&random_bytes, 0);
        }

        _ = std.fmt.bufPrint(&self.value, "SES-{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            random_bytes[0],
            random_bytes[1],
            random_bytes[2],
            random_bytes[3],
        }) catch @panic("bufPrint failed formatting the session id");

        return self;
    }

    /// Get the session ID as a string slice
    pub fn toString(self: *const SessionId) []const u8 {
        return &self.value;
    }
};

/// Generate a new SessionId
pub fn generateSessionId() SessionId {
    return SessionId.init();
}

// Tests

// The request-id tests that used to live in request_id_test.zig are now
// inline at the bottom of this file (2026-09-29 flatten);
// logger/test_runner.zig imports this file directly.

// ===== Tests merged from request_id_test.zig (2026-09-29 flatten) =====
test "RequestId has correct format" {
    const id = generateRequestId();
    const str = id.toString();
    
    // Check length
    try std.testing.expectEqual(@as(usize, 24), str.len);
    
    // Check prefix
    try std.testing.expectEqualStrings("REQ-", str[0..4]);
    
    // Check dash at position 12 (after YYYYMMDD)
    try std.testing.expectEqual('-', str[12]);
    
    // Check dash at position 19 (before random suffix)
    try std.testing.expectEqual('-', str[19]);
    
    // Check that random suffix is hex
    for (str[20..24]) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(is_hex);
    }
}

test "RequestIds are unique" {
    const id1 = generateRequestId();
    const id2 = generateRequestId();
    
    // IDs should differ (either time or random component)
    try std.testing.expect(!std.mem.eql(u8, id1.toString(), id2.toString()));
}

test "SessionId has correct format" {
    const id = generateSessionId();
    const str = id.toString();
    
    // Check length (SES- + 8 hex chars = 12)
    try std.testing.expectEqual(@as(usize, 12), str.len);
    
    // Check prefix
    try std.testing.expectEqualStrings("SES-", str[0..4]);
    
    // Check that suffix is hex
    for (str[4..12]) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(is_hex);
    }
}

test "SessionIds are unique" {
    const id1 = generateSessionId();
    const id2 = generateSessionId();

    // IDs should differ due to random component
    try std.testing.expect(!std.mem.eql(u8, id1.toString(), id2.toString()));
}

test "SessionIds are unique across 1000 back-to-back calls" {
    // Regression for the macOS CI failure where two back-to-back calls in the
    // same nanosecond produced identical SessionIds (CI run 28568881975). Now
    // uses libc `getrandom` for guaranteed entropy.
    const N: usize = 1000;
    var seen: [N][12]u8 = undefined;
    var unique_count: usize = 0;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const id = generateSessionId();
        var dup = false;
        for (seen[0..unique_count]) |existing| {
            if (std.mem.eql(u8, &existing, &id.value)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        seen[unique_count] = id.value;
        unique_count += 1;
    }
    try std.testing.expectEqual(@as(usize, N), unique_count);
}

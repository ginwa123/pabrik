//! 5-field cron parser + `nextFireTime` (Task 1.3 of the Add Task Routines
//! plan).

const std = @import("std");

pub const Error = error{
    InvalidCron,
};

/// A single field of a cron expression (e.g. "minute"). Stores a set of
/// allowed values; membership test is the `match` function. Sized at 64 so
/// any field range fits (the largest is day-of-month up to 31).
pub const Field = struct {
    values: [64]bool = .{false} ** 64,

    pub fn match(self: *const Field, value: u8) bool {
        if (value >= self.values.len) return false;
        return self.values[value];
    }
};

/// A fully-parsed 5-field cron expression. The five fields are
/// minute / hour / day-of-month / month / day-of-week, in that order.
pub const Expression = struct {
    minute: Field,
    hour: Field,
    day_of_month: Field,
    month: Field,
    day_of_week: Field, // 0 = Sunday, 6 = Saturday
};

/// Validate that `expr` is a well-formed 5-field cron expression.
/// Returns `error.InvalidCron` on any syntax, range, or field-count error.
pub fn validate(expr: []const u8) Error!void {
    var e: Expression = undefined;
    try parse(expr, &e);
}

/// Parse a 5-field cron expression into `out`. Caller owns `out`. On
/// success, every field has at least one allowed value; on failure the
/// contents of `out` are unspecified.
pub fn parse(expr: []const u8, out: *Expression) Error!void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, expr, &[_]u8{' '}), ' ');
    var i: u8 = 0;
    while (it.next()) |tok| {
        const field_ptr: *Field = switch (i) {
            0 => &out.minute,
            1 => &out.hour,
            2 => &out.day_of_month,
            3 => &out.month,
            4 => &out.day_of_week,
            else => return Error.InvalidCron,
        };
        try parseField(tok, field_ptr, fieldMax(i));
        i += 1;
    }
    if (i != 5) return Error.InvalidCron;
}

fn fieldMax(field_index: u8) u8 {
    return switch (field_index) {
        0 => 59, // minute
        1 => 23, // hour
        2 => 31, // day of month
        3 => 12, // month
        4 => 6, // day of week (0-6, Sunday = 0)
        else => 0,
    };
}

fn parseField(tok: []const u8, f: *Field, max: u8) Error!void {
    f.* = .{};
    // Comma-separated values: "1,5,10" parses as three parts.
    var parts = std.mem.splitScalar(u8, tok, ',');
    var any = false;
    while (parts.next()) |part| {
        if (part.len == 0) return Error.InvalidCron;
        try parseOnePart(part, f, max);
        any = true;
    }
    if (!any) return Error.InvalidCron;
}

fn parseOnePart(part: []const u8, f: *Field, max: u8) Error!void {
    // Supports: "*", "N", "N-M", "*/S", "N-M/S"
    var step: u8 = 1;
    var range_str: []const u8 = part;
    if (std.mem.indexOfScalar(u8, part, '/')) |slash| {
        if (slash + 1 >= part.len) return Error.InvalidCron;
        step = std.fmt.parseInt(u8, part[slash + 1 ..], 10) catch return Error.InvalidCron;
        if (step == 0) return Error.InvalidCron;
        range_str = part[0..slash];
    }

    var lo: u8 = 0;
    var hi: u8 = max;
    if (std.mem.eql(u8, range_str, "*")) {
        // lo = 0, hi = max (all values)
    } else if (std.mem.indexOfScalar(u8, range_str, '-')) |dash| {
        if (dash == 0 or dash + 1 >= range_str.len) return Error.InvalidCron;
        lo = std.fmt.parseInt(u8, range_str[0..dash], 10) catch return Error.InvalidCron;
        hi = std.fmt.parseInt(u8, range_str[dash + 1 ..], 10) catch return Error.InvalidCron;
    } else {
        const v = std.fmt.parseInt(u8, range_str, 10) catch return Error.InvalidCron;
        if (v > max) return Error.InvalidCron;
        f.values[v] = true;
        return;
    }

    if (lo > hi or hi > max) return Error.InvalidCron;
    var v = lo;
    while (v <= hi) : (v += step) {
        f.values[v] = true;
    }
}

/// Compute the next unix-nanos at which `expr` would fire, strictly after
/// `after_unix_nanos`.
pub fn nextFireTime(expr: []const u8, after_unix_nanos: i128) Error!i128 {
    var e: Expression = undefined;
    try parse(expr, &e);

    // Round down to the minute boundary, then add one minute to be
    // strictly after `after_unix_nanos`.
    const min_ns: i128 = 60 * std.time.ns_per_s;
    var t = @divTrunc(after_unix_nanos, min_ns) * min_ns;
    t += min_ns;

    const cap: u32 = 366 * 24 * 60;
    var iterations: u32 = 0;
    while (iterations < cap) : (iterations += 1) {
        const bd = fromUnixNanos(t);
        if (e.month.match(bd.month) and
            e.day_of_month.match(bd.day) and
            e.day_of_week.match(dayOfWeek(bd.year, bd.month, bd.day)) and
            e.hour.match(bd.hour) and
            e.minute.match(bd.minute))
        {
            return t;
        }
        t += min_ns;
    }
    return Error.InvalidCron;
}

const BrokenDownTime = struct {
    year: i32,
    month: u4,
    day: u5,
    hour: u5,
    minute: u6,
};

/// Decompose unix nanos into a UTC broken-down time.
fn fromUnixNanos(ns: i128) BrokenDownTime {
    const secs: i64 = @intCast(@divTrunc(ns, std.time.ns_per_s));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .hour = @intCast(day_seconds.getHoursIntoDay()),
        .minute = @intCast(day_seconds.getMinutesIntoHour()),
    };
}

/// Zeller's congruence: 0 = Sunday, 1 = Monday, ..., 6 = Saturday.
fn dayOfWeek(year: i32, month: u4, day: u5) u8 {
    var m: i32 = month;
    var y: i32 = year;
    if (m < 3) {
        m += 12;
        y -= 1;
    }
    const K: i32 = @mod(y, 100);
    const J: i32 = @divTrunc(y, 100);
    // h = 0 Saturday, 1 Sunday, ..., 6 Friday (Zeller's "h" output)
    const h_raw: i32 = @mod(
        @as(i32, day) +
            @divTrunc(13 * (m + 1), 5) +
            K + @divTrunc(K, 4) + @divTrunc(J, 4) + 5 * J,
        7,
    );
    // Remap to 0 = Sunday, 1 = Monday, ..., 6 = Saturday
    return @intCast(@mod(h_raw + 6, 7));
}

// ===== Tests merged from cron_test.zig (2026-09-29 flatten) ===== Behavioral
// tests for the 5-field cron parser + `nextFireTime` (Task 1.3 of the Add
// Task Routines plan).

const testing = std.testing;

// ─── Time helper ──────────────────────────────────────────────────────────

/// Compose a UTC unix-nanos value from broken-down date + time fields.
fn tsUtc(year: i32, month: u4, day: u5, hour: u5, minute: u6) i128 {
    // Howard Hinnant days_from_civil, adapted to Zig signed-int arithmetic.
    const y: i32 = if (month <= 2) year - 1 else year;
    // Note: the original C++ is `(y >= 0 ? y : y - 399) / 400` — the
    // division is part of the expression. Don't drop the `/ 400` or
    // `era` becomes the year itself and the whole formula diverges.
    const era: i32 = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe: u32 = @intCast(@mod(y - era * 400, 400)); // [0, 399]
    const doy: u32 = (153 * @as(u32, @intCast((if (month > 2) month - 3 else month + 9))) + 2) / 5 + day - 1; // [0, 365]
    const doe: u32 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    const days: i64 = @as(i64, era) * 146097 + @as(i64, @intCast(doe)) - 719468;

    const secs_in_day: i64 = @as(i64, hour) * std.time.s_per_hour +
        @as(i64, minute) * std.time.s_per_min;
    return @as(i128, days * std.time.s_per_day + secs_in_day) * std.time.ns_per_s;
}

// ─── Tests ────────────────────────────────────────────────────────────────

// Sanity check the time helper itself — if these are wrong, every other test
// fails for a confusing reason.
test "tsUtc: known unix seconds" {
    try testing.expectEqual(@as(i128, 1749790620) * std.time.ns_per_s, tsUtc(2025, 6, 13, 4, 57));
    try testing.expectEqual(@as(i128, 1749790680) * std.time.ns_per_s, tsUtc(2025, 6, 13, 4, 58));
    try testing.expectEqual(@as(i128, 1709164800) * std.time.ns_per_s, tsUtc(2024, 2, 29, 0, 0));
    try testing.expectEqual(@as(i128, 0), tsUtc(1970, 1, 1, 0, 0));
    try testing.expectEqual(@as(i128, 946684800) * std.time.ns_per_s, tsUtc(2000, 1, 1, 0, 0));
}

test "validate: accepts a simple expression" {
    try validate("*/5 * * * *");
    try validate("0 9 * * 1-5");
    try validate("0 0 1 * *");
    try validate("30 14 1 1 *");
}

test "validate: rejects garbage" {
    try testing.expectError(error.InvalidCron, validate("not a cron"));
    try testing.expectError(error.InvalidCron, validate("60 * * * *")); // minute out of range
    try testing.expectError(error.InvalidCron, validate("* * *")); // too few fields
    try testing.expectError(error.InvalidCron, validate("a b c d e")); // non-numeric
}

test "nextFireTime: every 5 minutes lands on next /5 minute" {
    // 2025-06-13 04:57 UTC -> next /5 minute is 05:00 (00, 05, 10, ...).
    // The plan originally said "04:58" but 04:58 is not divisible by 5;
    // the correct next /5 boundary after 04:57 is 05:00.
    const after = tsUtc(2025, 6, 13, 4, 57);
    const next = try nextFireTime("*/5 * * * *", after);
    const expected = tsUtc(2025, 6, 13, 5, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: hourly on the hour" {
    const after = tsUtc(2025, 6, 13, 4, 32);
    const next = try nextFireTime("0 * * * *", after);
    const expected = tsUtc(2025, 6, 13, 5, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: daily at 09:00" {
    const after = tsUtc(2025, 6, 13, 10, 0);
    const next = try nextFireTime("0 9 * * *", after);
    const expected = tsUtc(2025, 6, 14, 9, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: weekdays at 09:00 (Sat -> Mon)" {
    // 2025-06-14 is a Saturday; 2025-06-16 is the next Monday
    const after = tsUtc(2025, 6, 14, 10, 0);
    const next = try nextFireTime("0 9 * * 1-5", after);
    const expected = tsUtc(2025, 6, 16, 9, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: monthly on the 1st" {
    const after = tsUtc(2025, 6, 15, 12, 0);
    const next = try nextFireTime("0 0 1 * *", after);
    const expected = tsUtc(2025, 7, 1, 0, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: leap year Feb 29" {
    // 2024 is a leap year. From 2024-02-28 12:00, the 29th at 00:00 should be next.
    const after = tsUtc(2024, 2, 28, 12, 0);
    const next = try nextFireTime("0 0 29 2 *", after);
    const expected = tsUtc(2024, 2, 29, 0, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: result is always strictly after `after`" {
    const expressions = [_][]const u8{
        "*/5 * * * *",
        "0 * * * *",
        "0 9 * * *",
        "0 9 * * 1-5",
        "0 0 1 * *",
    };
    const after = tsUtc(2025, 6, 13, 4, 57);
    for (expressions) |expr| {
        const next = try nextFireTime(expr, after);
        try testing.expect(next > after);
    }
}

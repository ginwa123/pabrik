const std = @import("std");

pub const Error = error{
    InvalidCron,
};

pub const minute_max: u8 = 59;
pub const hour_max: u8 = 23;
pub const day_of_month_max: u8 = 31;
pub const month_max: u8 = 12;
pub const day_of_week_max: u8 = 7;

const minute_ns: i128 = 60 * std.time.ns_per_s;
const hour_ns: i128 = 60 * minute_ns;
const day_ns: i128 = 24 * hour_ns;
const search_horizon_steps: u32 = 8 * 366 * (1 + 24 + 60);

pub const Field = struct {
    values: [64]bool = .{false} ** 64,
    star: bool = false,

    pub fn match(self: *const Field, value: u8) bool {
        if (value >= self.values.len) return false;
        return self.values[value];
    }
};

pub const Expression = struct {
    minute: Field,
    hour: Field,
    day_of_month: Field,
    month: Field,
    day_of_week: Field,
};

pub fn validate(expr: []const u8) Error!void {
    var e: Expression = undefined;
    try parse(expr, &e);
}

pub fn parse(expr: []const u8, out: *Expression) Error!void {
    var it = std.mem.tokenizeAny(u8, expr, " \t\r\n");
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

    if (out.day_of_week.values[7]) {
        out.day_of_week.values[7] = false;
        out.day_of_week.values[0] = true;
    }
}

fn fieldMax(field_index: u8) u8 {
    return switch (field_index) {
        0 => minute_max,
        1 => hour_max,
        2 => day_of_month_max,
        3 => month_max,
        4 => day_of_week_max,
        else => 0,
    };
}

fn parseField(tok: []const u8, f: *Field, max: u8) Error!void {
    f.* = .{ .star = tok.len > 0 and tok[0] == '*' };
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
    var step: u8 = 1;
    var has_step = false;
    var range_str: []const u8 = part;
    if (std.mem.indexOfScalar(u8, part, '/')) |slash| {
        if (slash + 1 >= part.len) return Error.InvalidCron;
        step = std.fmt.parseInt(u8, part[slash + 1 ..], 10) catch return Error.InvalidCron;
        if (step == 0) return Error.InvalidCron;
        has_step = true;
        range_str = part[0..slash];
        if (range_str.len == 0) return Error.InvalidCron;
    }

    var lo: u8 = 0;
    var hi: u8 = max;
    if (std.mem.eql(u8, range_str, "*")) {} else if (std.mem.indexOfScalar(u8, range_str, '-')) |dash| {
        if (dash == 0 or dash + 1 >= range_str.len) return Error.InvalidCron;
        lo = std.fmt.parseInt(u8, range_str[0..dash], 10) catch return Error.InvalidCron;
        hi = std.fmt.parseInt(u8, range_str[dash + 1 ..], 10) catch return Error.InvalidCron;
    } else {
        const v = std.fmt.parseInt(u8, range_str, 10) catch return Error.InvalidCron;
        if (v > max) return Error.InvalidCron;
        if (!has_step) {
            f.values[v] = true;
            return;
        }
        lo = v;
        hi = max;
    }

    if (lo > hi or hi > max) return Error.InvalidCron;
    var v: u16 = lo;
    while (v <= hi) : (v += step) {
        f.values[v] = true;
    }
}

pub fn nextFireTime(expr: []const u8, after_unix_nanos: i128) Error!i128 {
    var e: Expression = undefined;
    try parse(expr, &e);

    var t = @divTrunc(after_unix_nanos, minute_ns) * minute_ns;
    t += minute_ns;

    var steps: u32 = 0;
    while (steps < search_horizon_steps) : (steps += 1) {
        const bd = fromUnixNanos(t);
        if (!dayMatches(&e, bd)) {
            t = @divTrunc(t, day_ns) * day_ns + day_ns;
            continue;
        }
        if (!e.hour.match(bd.hour)) {
            t = @divTrunc(t, hour_ns) * hour_ns + hour_ns;
            continue;
        }
        if (!e.minute.match(bd.minute)) {
            t += minute_ns;
            continue;
        }
        return t;
    }
    return Error.InvalidCron;
}

fn dayMatches(e: *const Expression, bd: BrokenDownTime) bool {
    if (!e.month.match(bd.month)) return false;

    const dom_ok = e.day_of_month.match(bd.day);
    const dow_ok = e.day_of_week.match(dayOfWeek(bd.year, bd.month, bd.day));
    if (e.day_of_month.star or e.day_of_week.star) return dom_ok and dow_ok;
    return dom_ok or dow_ok;
}

const BrokenDownTime = struct {
    year: i32,
    month: u4,
    day: u5,
    hour: u5,
    minute: u6,
};

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

fn dayOfWeek(year: i32, month: u4, day: u5) u8 {
    var m: i32 = month;
    var y: i32 = year;
    if (m < 3) {
        m += 12;
        y -= 1;
    }
    const k: i32 = @mod(y, 100);
    const j: i32 = @divTrunc(y, 100);
    const h_raw: i32 = @mod(
        @as(i32, day) + @divTrunc(13 * (m + 1), 5) + k + @divTrunc(k, 4) + @divTrunc(j, 4) + 5 * j,
        7,
    );
    return @intCast(@mod(h_raw + 6, 7));
}

const testing = std.testing;

fn tsUtc(year: i32, month: u4, day: u5, hour: u5, minute: u6) i128 {
    const y: i32 = if (month <= 2) year - 1 else year;
    const era: i32 = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe: u32 = @intCast(@mod(y - era * 400, 400));
    const doy: u32 = (153 * @as(u32, @intCast((if (month > 2) month - 3 else month + 9))) + 2) / 5 + day - 1;
    const doe: u32 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const days: i64 = @as(i64, era) * 146097 + @as(i64, @intCast(doe)) - 719468;

    const secs_in_day: i64 = @as(i64, hour) * std.time.s_per_hour +
        @as(i64, minute) * std.time.s_per_min;
    return @as(i128, days * std.time.s_per_day + secs_in_day) * std.time.ns_per_s;
}

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
    try testing.expectError(error.InvalidCron, validate("60 * * * *"));
    try testing.expectError(error.InvalidCron, validate("* * *"));
    try testing.expectError(error.InvalidCron, validate("a b c d e"));
    try testing.expectError(error.InvalidCron, validate(""));
    try testing.expectError(error.InvalidCron, validate("*/0 * * * *"));
}

test "validate: accepts runs of spaces and tabs between fields" {
    try validate("0  9 * * *");
    try validate("0\t9\t*\t*\t*");
    try validate("  */5   * * * *  ");
}

test "parse: N/step expands from N to the field maximum" {
    var e: Expression = undefined;
    try parse("5/10 * * * *", &e);
    try testing.expect(e.minute.match(5));
    try testing.expect(e.minute.match(15));
    try testing.expect(e.minute.match(55));
    try testing.expect(!e.minute.match(0));
    try testing.expect(!e.minute.match(10));

    const after = tsUtc(2025, 6, 13, 4, 6);
    try testing.expectEqual(tsUtc(2025, 6, 13, 4, 15), try nextFireTime("5/10 * * * *", after));
}

test "parse: comma lists, ranges and stepped ranges" {
    var e: Expression = undefined;
    try parse("1,5,10 * * * 1-5", &e);
    try testing.expect(e.minute.match(1));
    try testing.expect(e.minute.match(5));
    try testing.expect(e.minute.match(10));
    try testing.expect(!e.minute.match(2));
    try testing.expect(e.day_of_week.match(1));
    try testing.expect(e.day_of_week.match(5));
    try testing.expect(!e.day_of_week.match(0));
    try testing.expect(!e.day_of_week.match(6));

    try parse("0-30/15 * * * *", &e);
    try testing.expect(e.minute.match(0));
    try testing.expect(e.minute.match(15));
    try testing.expect(e.minute.match(30));
    try testing.expect(!e.minute.match(45));
}

test "parse: day-of-week 7 is an alias for Sunday" {
    const after = tsUtc(2025, 6, 13, 4, 57);
    const expected = tsUtc(2025, 6, 15, 9, 0);
    try testing.expectEqual(expected, try nextFireTime("0 9 * * 7", after));
    try testing.expectEqual(expected, try nextFireTime("0 9 * * 0", after));
    try testing.expectEqual(
        tsUtc(2025, 6, 15, 9, 0),
        try nextFireTime("0 9 * * 5-7", tsUtc(2025, 6, 14, 10, 0)),
    );
}

test "nextFireTime: every 5 minutes lands on next /5 minute" {
    const after = tsUtc(2025, 6, 13, 4, 57);
    try testing.expectEqual(tsUtc(2025, 6, 13, 5, 0), try nextFireTime("*/5 * * * *", after));
}

test "nextFireTime: hourly on the hour" {
    const after = tsUtc(2025, 6, 13, 4, 32);
    try testing.expectEqual(tsUtc(2025, 6, 13, 5, 0), try nextFireTime("0 * * * *", after));
}

test "nextFireTime: daily at 09:00" {
    const after = tsUtc(2025, 6, 13, 10, 0);
    try testing.expectEqual(tsUtc(2025, 6, 14, 9, 0), try nextFireTime("0 9 * * *", after));
}

test "nextFireTime: weekdays at 09:00 (Sat -> Mon)" {
    const after = tsUtc(2025, 6, 14, 10, 0);
    try testing.expectEqual(tsUtc(2025, 6, 16, 9, 0), try nextFireTime("0 9 * * 1-5", after));
}

test "nextFireTime: monthly on the 1st" {
    const after = tsUtc(2025, 6, 15, 12, 0);
    try testing.expectEqual(tsUtc(2025, 7, 1, 0, 0), try nextFireTime("0 0 1 * *", after));
}

test "nextFireTime: leap year Feb 29" {
    const after = tsUtc(2024, 2, 28, 12, 0);
    try testing.expectEqual(tsUtc(2024, 2, 29, 0, 0), try nextFireTime("0 0 29 2 *", after));
}

test "nextFireTime: Feb 29 reaches the next leap year instead of failing" {
    const after = tsUtc(2025, 3, 1, 0, 0);
    try testing.expectEqual(tsUtc(2028, 2, 29, 0, 0), try nextFireTime("0 0 29 2 *", after));
}

test "nextFireTime: a day-of-month and day-of-week pair fires on either match" {
    const after = tsUtc(2025, 6, 1, 0, 0);
    const next = try nextFireTime("0 0 1 * 1", after);
    try testing.expectEqual(tsUtc(2025, 6, 2, 0, 0), next);

    const weekly = try nextFireTime("0 0 1 * 1", tsUtc(2025, 6, 20, 0, 0));
    try testing.expectEqual(tsUtc(2025, 6, 23, 0, 0), weekly);

    const monthly = try nextFireTime("0 0 1 * 1", tsUtc(2025, 6, 30, 0, 1));
    try testing.expectEqual(tsUtc(2025, 7, 1, 0, 0), monthly);
}

test "nextFireTime: a star field keeps day-of-month and day-of-week ANDed" {
    const after = tsUtc(2025, 6, 12, 0, 0);
    try testing.expectEqual(
        tsUtc(2025, 6, 16, 0, 0),
        try nextFireTime("0 0 * * 1", after),
    );
    try testing.expectEqual(
        tsUtc(2025, 7, 1, 0, 0),
        try nextFireTime("0 0 1 * *", after),
    );
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
        try testing.expect(try nextFireTime(expr, after) > after);
    }
}

const std = @import("std");
const route_index = @import("route_index.zig");

pub const Pattern = route_index.Pattern;
pub const RouteIndex = route_index.RouteIndex;

const Bucket = struct {
    upper_ns: u64,
    le: []const u8,
};

const buckets = [_]Bucket{
    .{ .upper_ns = 5_000_000, .le = "0.005" },
    .{ .upper_ns = 10_000_000, .le = "0.01" },
    .{ .upper_ns = 25_000_000, .le = "0.025" },
    .{ .upper_ns = 50_000_000, .le = "0.05" },
    .{ .upper_ns = 100_000_000, .le = "0.1" },
    .{ .upper_ns = 250_000_000, .le = "0.25" },
    .{ .upper_ns = 500_000_000, .le = "0.5" },
    .{ .upper_ns = 1_000_000_000, .le = "1" },
    .{ .upper_ns = 2_500_000_000, .le = "2.5" },
    .{ .upper_ns = 5_000_000_000, .le = "5" },
    .{ .upper_ns = 10_000_000_000, .le = "10" },
};

pub const SeriesKey = struct {
    method: []const u8,
    route: []const u8,
};

const SeriesKeyContext = struct {
    pub fn hash(_: SeriesKeyContext, key: SeriesKey) u32 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.method);
        hasher.update("\x00");
        hasher.update(key.route);
        return @truncate(hasher.final());
    }

    pub fn eql(_: SeriesKeyContext, a: SeriesKey, b: SeriesKey, _: usize) bool {
        return std.mem.eql(u8, a.method, b.method) and std.mem.eql(u8, a.route, b.route);
    }
};

const StatusContext = struct {
    pub fn hash(_: StatusContext, status: u16) u32 {
        return status;
    }

    pub fn eql(_: StatusContext, a: u16, b: u16, _: usize) bool {
        return a == b;
    }
};

const StatusCounts = std.array_hash_map.Custom(u16, u64, StatusContext, false);

const Series = struct {
    method: []const u8,
    route: []const u8,
    bucket_counts: [buckets.len]u64 = [_]u64{0} ** buckets.len,
    sum_ns: u64 = 0,
    max_ns: u64 = 0,
    count: u64 = 0,
    statuses: StatusCounts = .empty,
};

pub const StatusStat = struct {
    status: u16,
    count: u64,
};

pub const RouteStat = struct {
    method: []const u8,
    route: []const u8,
    count: u64,
    errors: u64,
    avg_ms: f64,
    p95_ms: f64,
    max_ms: f64,
    statuses: []const StatusStat,
};

fn writeSeconds(out: *std.ArrayList(u8), allocator: std.mem.Allocator, ns: u64) !void {
    try out.print(allocator, "{d}.{d:0>9}", .{ ns / std.time.ns_per_s, ns % std.time.ns_per_s });
}

fn p95UpperBound(series: Series) u64 {
    if (series.count == 0) return 0;
    const target = (series.count * 95 + 99) / 100;
    for (buckets, 0..) |bucket, bucket_index| {
        if (series.bucket_counts[bucket_index] >= target) return bucket.upper_ns;
    }
    return buckets[buckets.len - 1].upper_ns;
}

pub const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    index: RouteIndex,
    by_key: std.array_hash_map.Custom(SeriesKey, usize, SeriesKeyContext, false) = .empty,
    series: std.ArrayListUnmanaged(Series) = .empty,
    in_flight: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, patterns: []const Pattern) !Registry {
        return .{
            .allocator = allocator,
            .io = io,
            .index = try RouteIndex.init(allocator, patterns),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.series.items) |*series| {
            self.allocator.free(series.method);
            self.allocator.free(series.route);
            series.statuses.deinit(self.allocator);
        }
        self.series.deinit(self.allocator);
        self.by_key.deinit(self.allocator);
        self.index.deinit();
    }

    pub fn enter(self: *Registry) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.in_flight += 1;
    }

    pub fn inFlight(self: *Registry) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.in_flight;
    }

    pub fn record(
        self: *Registry,
        method: []const u8,
        path: []const u8,
        status: u16,
        duration_ns: u64,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.in_flight > 0) self.in_flight -= 1;

        const route = self.index.resolve(method, path);
        const series = if (self.by_key.get(.{ .method = method, .route = route })) |index|
            &self.series.items[index]
        else blk: {
            const owned_method = try self.allocator.dupe(u8, method);
            errdefer self.allocator.free(owned_method);
            const owned_route = try self.allocator.dupe(u8, route);
            errdefer self.allocator.free(owned_route);
            try self.series.append(self.allocator, .{ .method = owned_method, .route = owned_route });
            errdefer _ = self.series.pop();
            try self.by_key.put(
                self.allocator,
                .{ .method = owned_method, .route = owned_route },
                self.series.items.len - 1,
            );
            break :blk &self.series.items[self.series.items.len - 1];
        };

        const status_entry = try series.statuses.getOrPut(self.allocator, status);
        if (!status_entry.found_existing) status_entry.value_ptr.* = 0;
        status_entry.value_ptr.* += 1;

        series.count += 1;
        series.sum_ns += duration_ns;
        series.max_ns = @max(series.max_ns, duration_ns);
        for (buckets, 0..) |bucket, bucket_index| {
            if (duration_ns <= bucket.upper_ns) series.bucket_counts[bucket_index] += 1;
        }
    }

    pub fn render(self: *Registry, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "# HELP http_requests_total Requests by method, route and status.\n");
        try out.appendSlice(allocator, "# TYPE http_requests_total counter\n");
        for (self.series.items) |series| {
            var statuses = series.statuses.iterator();
            while (statuses.next()) |status| {
                try out.print(allocator, "http_requests_total{{method=\"{s}\",route=\"{s}\",status=\"{d}\"}} {d}\n", .{
                    series.method,
                    series.route,
                    status.key_ptr.*,
                    status.value_ptr.*,
                });
            }
        }

        try out.appendSlice(allocator, "# HELP http_request_duration_seconds Request duration by method and route.\n");
        try out.appendSlice(allocator, "# TYPE http_request_duration_seconds histogram\n");
        for (self.series.items) |series| {
            for (buckets, 0..) |bucket, bucket_index| {
                try out.print(allocator, "http_request_duration_seconds_bucket{{method=\"{s}\",route=\"{s}\",le=\"{s}\"}} {d}\n", .{
                    series.method,
                    series.route,
                    bucket.le,
                    series.bucket_counts[bucket_index],
                });
            }
            try out.print(allocator, "http_request_duration_seconds_bucket{{method=\"{s}\",route=\"{s}\",le=\"+Inf\"}} {d}\n", .{
                series.method,
                series.route,
                series.count,
            });
            try out.print(allocator, "http_request_duration_seconds_sum{{method=\"{s}\",route=\"{s}\"}} {d}.{d:0>9}\n", .{
                series.method,
                series.route,
                series.sum_ns / std.time.ns_per_s,
                series.sum_ns % std.time.ns_per_s,
            });
            try out.print(allocator, "http_request_duration_seconds_count{{method=\"{s}\",route=\"{s}\"}} {d}\n", .{
                series.method,
                series.route,
                series.count,
            });
        }

        try out.appendSlice(allocator, "# HELP http_request_duration_seconds_avg Mean request duration since process start.\n");
        try out.appendSlice(allocator, "# TYPE http_request_duration_seconds_avg gauge\n");
        for (self.series.items) |series| {
            try out.print(allocator, "http_request_duration_seconds_avg{{method=\"{s}\",route=\"{s}\"}} ", .{
                series.method,
                series.route,
            });
            try writeSeconds(&out, allocator, if (series.count == 0) 0 else series.sum_ns / series.count);
            try out.append(allocator, '\n');
        }

        try out.appendSlice(allocator, "# HELP http_request_duration_seconds_max Slowest request since process start.\n");
        try out.appendSlice(allocator, "# TYPE http_request_duration_seconds_max gauge\n");
        for (self.series.items) |series| {
            try out.print(allocator, "http_request_duration_seconds_max{{method=\"{s}\",route=\"{s}\"}} ", .{
                series.method,
                series.route,
            });
            try writeSeconds(&out, allocator, series.max_ns);
            try out.append(allocator, '\n');
        }

        try out.appendSlice(allocator, "# HELP http_requests_in_flight Requests being served right now.\n");
        try out.appendSlice(allocator, "# TYPE http_requests_in_flight gauge\n");
        try out.print(allocator, "http_requests_in_flight {d}\n", .{self.in_flight});

        return out.toOwnedSlice(allocator);
    }

    pub fn summary(self: *Registry, allocator: std.mem.Allocator) ![]RouteStat {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const out = try allocator.alloc(RouteStat, self.series.items.len);
        for (self.series.items, out) |series, *stat| {
            const statuses = try allocator.alloc(StatusStat, series.statuses.count());
            var errors: u64 = 0;
            var filled: usize = 0;
            var iterator = series.statuses.iterator();
            while (iterator.next()) |status| {
                const count = status.value_ptr.*;
                if (status.key_ptr.* >= 400) errors += count;
                statuses[filled] = .{ .status = status.key_ptr.*, .count = count };
                filled += 1;
            }
            stat.* = .{
                .method = series.method,
                .route = series.route,
                .count = series.count,
                .errors = errors,
                .avg_ms = if (series.count == 0)
                    0
                else
                    @as(f64, @floatFromInt(series.sum_ns)) / (@as(f64, @floatFromInt(series.count)) * std.time.ns_per_ms),
                .p95_ms = @as(f64, @floatFromInt(p95UpperBound(series))) / std.time.ns_per_ms,
                .max_ms = @as(f64, @floatFromInt(series.max_ns)) / std.time.ns_per_ms,
                .statuses = statuses,
            };
        }
        return out;
    }
};

var global_registry: ?*Registry = null;
var global_mutex: std.Io.Mutex = .init;

pub fn install(allocator: std.mem.Allocator, io: std.Io, patterns: []const Pattern) !*Registry {
    const registry = try allocator.create(Registry);
    errdefer allocator.destroy(registry);
    registry.* = try Registry.init(allocator, io, patterns);
    global_mutex.lockUncancelable(io);
    defer global_mutex.unlock(io);
    global_registry = registry;
    return registry;
}

pub fn getGlobal() ?*Registry {
    return global_registry;
}

pub fn uninstall(io: std.Io) void {
    global_mutex.lockUncancelable(io);
    const detached = global_registry;
    global_registry = null;
    global_mutex.unlock(io);
    const registry = detached orelse return;
    registry.deinit();
    registry.allocator.destroy(registry);
}

test "record counts one request under its route template and status" {
    var registry = try Registry.init(std.testing.allocator, std.testing.io, &.{
        .{ .method = "GET", .path = "/api/session/:session_id" },
    });
    defer registry.deinit();

    try registry.record("GET", "/api/session/sess_1", 200, 0);

    const body = try registry.render(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "http_requests_total{method=\"GET\",route=\"/api/session/:session_id\",status=\"200\"} 1\n",
    ) != null);
}

test "record keeps one series per route and status across many requests" {
    var registry = try Registry.init(std.testing.allocator, std.testing.io, &.{
        .{ .method = "GET", .path = "/api/session/:session_id" },
    });
    defer registry.deinit();

    for (0..3) |_| try registry.record("GET", "/api/session/sess_1", 200, 0);
    for (0..2) |_| try registry.record("GET", "/api/session/sess_2", 500, 0);

    const body = try registry.render(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "http_requests_total{"));
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "http_requests_total{method=\"GET\",route=\"/api/session/:session_id\",status=\"500\"} 2\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "http_requests_total{method=\"GET\",route=\"/api/session/:session_id\",status=\"200\"} 3\n",
    ) != null);
}

test "record lands an unclaimed path under the unmatched route" {
    var registry = try Registry.init(std.testing.allocator, std.testing.io, &.{
        .{ .method = "GET", .path = "/health" },
    });
    defer registry.deinit();

    try registry.record("GET", "/leftover", 404, 0);

    const body = try registry.render(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "route=\"unmatched\",status=\"404\"} 1\n",
    ) != null);
}

test "render buckets a duration cumulatively and sums it in seconds" {
    var registry = try Registry.init(std.testing.allocator, std.testing.io, &.{
        .{ .method = "POST", .path = "/api/send" },
    });
    defer registry.deinit();

    try registry.record("POST", "/api/send", 200, 7 * std.time.ns_per_ms);
    try registry.record("POST", "/api/send", 200, 4 * std.time.ns_per_ms);

    const body = try registry.render(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "_bucket{method=\"POST\",route=\"/api/send\",le=\"0.005\"} 1\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "_bucket{method=\"POST\",route=\"/api/send\",le=\"0.01\"} 2\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "_bucket{method=\"POST\",route=\"/api/send\",le=\"0.5\"} 2\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "_bucket{method=\"POST\",route=\"/api/send\",le=\"+Inf\"} 2\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "_sum{method=\"POST\",route=\"/api/send\"} 0.011000000\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "_count{method=\"POST\",route=\"/api/send\"} 2\n",
    ) != null);
}

test "render reports the requests still in flight" {
    var registry = try Registry.init(std.testing.allocator, std.testing.io, &.{});
    defer registry.deinit();

    registry.enter();
    registry.enter();
    const during = try registry.render(std.testing.allocator);
    defer std.testing.allocator.free(during);
    try std.testing.expect(std.mem.endsWith(u8, during, "http_requests_in_flight 2\n"));

    try registry.record("GET", "/anything", 200, 0);
    try registry.record("GET", "/anything", 200, 0);
    const after = try registry.render(std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expect(std.mem.endsWith(u8, after, "http_requests_in_flight 0\n"));
}

test "render reports the mean and the slowest duration of a route" {
    var registry = try Registry.init(std.testing.allocator, std.testing.io, &.{
        .{ .method = "GET", .path = "/api/slow" },
    });
    defer registry.deinit();

    try registry.record("GET", "/api/slow", 200, 100 * std.time.ns_per_ms);
    try registry.record("GET", "/api/slow", 200, 300 * std.time.ns_per_ms);

    const body = try registry.render(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "http_request_duration_seconds_avg{method=\"GET\",route=\"/api/slow\"} 0.200000000\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "http_request_duration_seconds_max{method=\"GET\",route=\"/api/slow\"} 0.300000000\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "# HELP http_request_duration_seconds_avg Mean request duration since process start.",
    ) != null);
}

test "record keeps counting after a series is established" {
    var registry = try Registry.init(std.testing.allocator, std.testing.io, &.{
        .{ .method = "GET", .path = "/api/session" },
    });
    defer registry.deinit();

    for (0..1000) |_| try registry.record("GET", "/api/session", 200, 1_000_000);

    const body = try registry.render(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "_count{method=\"GET\",route=\"/api/session\"} 1000\n",
    ) != null);
}

test "summary reports the average, the p95 bucket and the error count of a route" {
    var registry = try Registry.init(std.testing.allocator, std.testing.io, &.{
        .{ .method = "GET", .path = "/api/slow" },
        .{ .method = "GET", .path = "/api/fast" },
    });
    defer registry.deinit();

    try registry.record("GET", "/api/slow", 200, 100 * std.time.ns_per_ms);
    try registry.record("GET", "/api/slow", 500, 100 * std.time.ns_per_ms);
    try registry.record("GET", "/api/fast", 200, std.time.ns_per_ms);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stats = try registry.summary(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), stats.len);

    var slow: ?RouteStat = null;
    var fast: ?RouteStat = null;
    for (stats) |stat| {
        if (std.mem.eql(u8, stat.route, "/api/slow")) slow = stat;
        if (std.mem.eql(u8, stat.route, "/api/fast")) fast = stat;
    }
    try std.testing.expectApproxEqAbs(@as(f64, 100), slow.?.avg_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), slow.?.p95_ms, 0.001);
    try std.testing.expectEqual(@as(u64, 2), slow.?.count);
    try std.testing.expectEqual(@as(u64, 1), slow.?.errors);
    try std.testing.expectEqual(@as(usize, 2), slow.?.statuses.len);
    try std.testing.expectEqual(@as(u64, 0), fast.?.errors);
}

test "render counts a sample slower than the top bucket only in the +Inf bucket" {
    var registry = try Registry.init(std.testing.allocator, std.testing.io, &.{
        .{ .method = "GET", .path = "/api/hang" },
    });
    defer registry.deinit();

    try registry.record("GET", "/api/hang", 200, 30 * std.time.ns_per_s);

    const body = try registry.render(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "_bucket{method=\"GET\",route=\"/api/hang\",le=\"10\"} 0\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "_bucket{method=\"GET\",route=\"/api/hang\",le=\"+Inf\"} 1\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "_sum{method=\"GET\",route=\"/api/hang\"} 30.000000000\n",
    ) != null);
}

test "summary reports the slowest sample when the buckets cannot place it" {
    var registry = try Registry.init(std.testing.allocator, std.testing.io, &.{
        .{ .method = "GET", .path = "/api/hang" },
    });
    defer registry.deinit();

    try registry.record("GET", "/api/hang", 200, 30 * std.time.ns_per_s);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stats = try registry.summary(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), stats.len);
    try std.testing.expectApproxEqAbs(@as(f64, 30000), stats[0].max_ms, 0.001);
}

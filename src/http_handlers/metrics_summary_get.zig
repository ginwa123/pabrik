const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const metrics_mod = pabrikcore.metrics_mod;

pub const MetricsSummary = struct {
    in_flight: u64,
    total_requests: u64,
    routes: []const metrics_mod.RouteStat,
};

fn slowerFirst(_: void, a: metrics_mod.RouteStat, b: metrics_mod.RouteStat) bool {
    if (a.avg_ms != b.avg_ms) return a.avg_ms > b.avg_ms;
    return std.mem.order(u8, a.route, b.route) == .lt;
}

pub fn metricsSummaryHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;
    const registry = metrics_mod.getGlobal() orelse {
        return gserverz.HttpResponse.init(503, "Service Unavailable", ctx.allocator)
            .withBody("metrics are not installed on this process\n")
            .setContentType("text/plain; charset=utf-8");
    };

    const routes = try registry.summary(ctx.allocator);
    std.mem.sort(metrics_mod.RouteStat, routes, {}, slowerFirst);
    var total_requests: u64 = 0;
    for (routes) |route| total_requests += route.count;

    const body = try std.json.Stringify.valueAlloc(ctx.allocator, MetricsSummary{
        .in_flight = registry.inFlight(),
        .total_requests = total_requests,
        .routes = routes,
    }, .{});
    return res.withBody(body).setContentType("application/json");
}

const testing = std.testing;

fn request(arena: std.mem.Allocator) gserverz.HttpRequest {
    return .{
        .method = "GET",
        .path = "/api/metrics/summary",
        .version = "HTTP/1.1",
        .headers = std.StringHashMap([]const u8).init(arena),
        .body = "",
        .raw = "",
        .params = std.StringHashMap([]const u8).init(arena),
        .query = std.StringHashMap([]const u8).init(arena),
        ._client_fd = -1,
    };
}

test "metrics summary lists the slowest route first with its error count" {
    _ = try metrics_mod.install(testing.allocator, testing.io, &.{
        .{ .method = "GET", .path = "/api/slow" },
        .{ .method = "GET", .path = "/api/fast" },
    });
    defer metrics_mod.uninstall(testing.io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const registry = metrics_mod.getGlobal().?;
    try registry.record("GET", "/api/fast", 200, std.time.ns_per_ms);
    try registry.record("GET", "/api/slow", 200, 100 * std.time.ns_per_ms);
    try registry.record("GET", "/api/slow", 500, 100 * std.time.ns_per_ms);

    const response = try metricsSummaryHandler(
        .{ .allocator = allocator, .io = testing.io },
        request(allocator),
        gserverz.HttpResponse.init(200, "OK", allocator),
    );

    try testing.expectEqual(@as(u16, 200), response.status_code);
    try testing.expectEqualStrings("application/json", response.headers.get("Content-Type").?);
    try testing.expect(std.mem.indexOf(u8, response.body, "\"total_requests\":3") != null);
    const slow_at = std.mem.indexOf(u8, response.body, "\"/api/slow\"").?;
    const fast_at = std.mem.indexOf(u8, response.body, "\"/api/fast\"").?;
    try testing.expect(slow_at < fast_at);
    try testing.expect(std.mem.indexOf(u8, response.body, "\"errors\":1") != null);
}

test "metrics summary refuses to answer when the process has no registry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const response = try metricsSummaryHandler(
        .{ .allocator = allocator, .io = testing.io },
        request(allocator),
        gserverz.HttpResponse.init(200, "OK", allocator),
    );

    try testing.expectEqual(@as(u16, 503), response.status_code);
}

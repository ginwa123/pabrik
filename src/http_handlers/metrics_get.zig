const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const metrics_mod = pabrikcore.metrics_mod;

pub fn metricsGetHandler(
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
    return res
        .withBody(try registry.render(ctx.allocator))
        .setContentType("text/plain; version=0.0.4; charset=utf-8");
}

const testing = std.testing;

fn request(arena: std.mem.Allocator, method: []const u8, path: []const u8) gserverz.HttpRequest {
    return .{
        .method = method,
        .path = path,
        .version = "HTTP/1.1",
        .headers = std.StringHashMap([]const u8).init(arena),
        .body = "",
        .raw = "",
        .params = std.StringHashMap([]const u8).init(arena),
        .query = std.StringHashMap([]const u8).init(arena),
        ._client_fd = -1,
    };
}

test "metrics endpoint serves the counters of requests already served" {
    _ = try metrics_mod.install(testing.allocator, testing.io, &.{
        .{ .method = "GET", .path = "/api/session/:session_id" },
    });
    defer metrics_mod.uninstall(testing.io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try metrics_mod.getGlobal().?.record("GET", "/api/session/sess_1", 200, 0);

    const response = try metricsGetHandler(
        .{ .allocator = allocator, .io = testing.io },
        request(allocator, "GET", "/metrics"),
        gserverz.HttpResponse.init(200, "OK", allocator),
    );

    try testing.expectEqual(@as(u16, 200), response.status_code);
    try testing.expectEqualStrings("text/plain; version=0.0.4; charset=utf-8", response.headers.get("Content-Type").?);
    try testing.expect(std.mem.indexOf(
        u8,
        response.body,
        "http_requests_total{method=\"GET\",route=\"/api/session/:session_id\",status=\"200\"} 1\n",
    ) != null);
}

test "metrics endpoint refuses to answer when the process has no registry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const response = try metricsGetHandler(
        .{ .allocator = allocator, .io = testing.io },
        request(allocator, "GET", "/metrics"),
        gserverz.HttpResponse.init(200, "OK", allocator),
    );

    try testing.expectEqual(@as(u16, 503), response.status_code);
}

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const metrics_mod = pabrikcore.metrics_mod;

pub fn metricsMiddleware(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
    chain: *gserverz.Router.MiddlewareChain,
) !gserverz.HttpResponse {
    const registry = metrics_mod.getGlobal() orelse return chain.next(ctx, req, res);
    registry.enter();
    const started = std.Io.Clock.now(.awake, ctx.io).nanoseconds;
    const result = chain.next(ctx, req, res);
    const elapsed = std.Io.Clock.now(.awake, ctx.io).nanoseconds - started;
    const status: u16 = if (result) |response| response.status_code else |_| 500;
    registry.record(req.method, req.path, status, @intCast(@max(elapsed, 0))) catch {};
    return result;
}

const testing = std.testing;

const patterns = [_]metrics_mod.Pattern{
    .{ .method = "GET", .path = "/api/llm/session/:session_id" },
};

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

fn answeredNotFound(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) anyerror!gserverz.HttpResponse {
    _ = ctx;
    _ = req;
    return gserverz.HttpResponse.init(404, "Not Found", res.allocator);
}

fn failedUpstream(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) anyerror!gserverz.HttpResponse {
    _ = ctx;
    _ = req;
    _ = res;
    return error.UpstreamDown;
}

test "middleware records the status its handler answered with" {
    _ = try metrics_mod.install(testing.allocator, testing.io, &patterns);
    defer metrics_mod.uninstall(testing.io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var chain: gserverz.Router.MiddlewareChain = .{ .middlewares = &.{}, .final_handler = answeredNotFound };

    _ = try metricsMiddleware(
        .{ .allocator = allocator, .io = testing.io },
        request(allocator, "GET", "/api/llm/session/sess_1"),
        gserverz.HttpResponse.init(200, "OK", allocator),
        &chain,
    );

    const body = try metrics_mod.getGlobal().?.render(allocator);
    try testing.expect(std.mem.indexOf(
        u8,
        body,
        "http_requests_total{method=\"GET\",route=\"/api/llm/session/:session_id\",status=\"404\"} 1\n",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        body,
        "_count{method=\"GET\",route=\"/api/llm/session/:session_id\"} 1\n",
    ) != null);
}

test "middleware records a failing handler as a 500 and re-raises the error" {
    _ = try metrics_mod.install(testing.allocator, testing.io, &patterns);
    defer metrics_mod.uninstall(testing.io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var chain: gserverz.Router.MiddlewareChain = .{ .middlewares = &.{}, .final_handler = failedUpstream };

    const outcome = metricsMiddleware(
        .{ .allocator = allocator, .io = testing.io },
        request(allocator, "GET", "/api/llm/session/sess_1"),
        gserverz.HttpResponse.init(200, "OK", allocator),
        &chain,
    );
    try testing.expectError(error.UpstreamDown, outcome);

    const body = try metrics_mod.getGlobal().?.render(allocator);
    try testing.expect(std.mem.indexOf(
        u8,
        body,
        "http_requests_total{method=\"GET\",route=\"/api/llm/session/:session_id\",status=\"500\"} 1\n",
    ) != null);
}

test "middleware passes the request through untouched when nothing is installed" {
    try testing.expect(metrics_mod.getGlobal() == null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var chain: gserverz.Router.MiddlewareChain = .{ .middlewares = &.{}, .final_handler = answeredNotFound };

    const response = try metricsMiddleware(
        .{ .allocator = allocator, .io = testing.io },
        request(allocator, "GET", "/api/llm/session/sess_1"),
        gserverz.HttpResponse.init(200, "OK", allocator),
        &chain,
    );
    try testing.expectEqual(@as(u16, 404), response.status_code);
    try testing.expect(metrics_mod.getGlobal() == null);
}

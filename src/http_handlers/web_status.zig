//! `GET /api/web/status` — browser-mode (web launch) status.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const auth_common = @import("auth_common.zig");
const gserverz = pabrikcore.gserverz;

/// Build the browser-mode URL for `port`. Pure (no singleton) so it is
/// unit-testable without a live server.
pub fn buildWebUrl(allocator: std.mem.Allocator, port: u16) ![]u8 {
    return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
}

pub fn webStatusHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    // `web_launch_enabled` is a per-user setting under `--auth`; resolve it
    // through the one config-resolution module and fall back to the
    // singleton when the database is not authoritative.
    const cfg = auth_common.requestUserConfig(allocator, di.db, di.auth_enabled, req.headers) orelse
        pabrikcore.getLlmConfig(di);
    const port: u16 = di.server.address.port;

    const url = try buildWebUrl(allocator, port);
    const data = try std.fmt.allocPrint(
        allocator,
        "{{\"enabled\":{s},\"running\":true,\"url\":\"{s}\",\"port\":{d}}}",
        .{ if (cfg.web_launch_enabled) "true" else "false", url, port },
    );
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

test "web_status: buildWebUrl formats the loopback URL" {
    const allocator = std.testing.allocator;
    const url = try buildWebUrl(allocator, 8081);
    defer allocator.free(url);
    try std.testing.expectEqualStrings("http://127.0.0.1:8081/", url);
}

test "web_status: buildWebUrl works for a random-range port" {
    const allocator = std.testing.allocator;
    const url = try buildWebUrl(allocator, 51234);
    defer allocator.free(url);
    try std.testing.expectEqualStrings("http://127.0.0.1:51234/", url);
}

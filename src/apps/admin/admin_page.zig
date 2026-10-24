//! The admin console's HTTP face: who is asking, which section they asked for,
//! and the stylesheet and script that go with it. The page itself is rendered by
//! `admin_views.zig`.

const std = @import("std");
const gserverz = @import("kabelweb").server;

const admin_api = @import("admin_api.zig");
const admin_common = @import("admin_common.zig");
const admin_views = @import("admin_views.zig");
const runtime = @import("runtime.zig");

const page_css = @embedFile("admin.css");
const page_js = @embedFile("admin.js");

/// One file the console serves as-is. The page is not one of these: it is
/// rendered per request, because it carries the data.
pub const Asset = struct {
    body: []const u8,
    content_type: []const u8,
};

/// The static files, or null when a path is not one of them.
pub fn assetFor(path: []const u8) ?Asset {
    if (std.mem.eql(u8, path, "/admin/admin.css")) {
        return .{ .body = page_css, .content_type = "text/css; charset=utf-8" };
    }
    if (std.mem.eql(u8, path, "/admin/admin.js")) {
        return .{ .body = page_js, .content_type = "application/javascript; charset=utf-8" };
    }
    return null;
}

fn serve(allocator: std.mem.Allocator, asset: Asset) gserverz.HttpResponse {
    return gserverz.HttpResponse.init(200, "OK", allocator)
        .withBody(asset.body)
        .setContentType(asset.content_type)
        .withHeader("Cache-Control", "no-store")
        .withHeader("X-Content-Type-Options", "nosniff");
}

/// Render one section. The page loads without a session — it has to, to say
/// anything at all — but a visitor who is not the owner gets the frame and the
/// reason, never the data.
fn page(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
    section: admin_views.Section,
) !gserverz.HttpResponse {
    const db = runtime.db() orelse
        return admin_api.errorResponse(ctx.allocator, res, 503, "AdminConsoleNotInstalled");

    const access = admin_common.resolveAccess(ctx.allocator, db, runtime.authEnabled(), req.headers);
    const html = admin_views.renderPage(ctx.allocator, db, section, access == .owner) catch |err| {
        std.debug.print("admin: the page could not be rendered: {s}\n", .{@errorName(err)});
        return admin_api.errorResponse(ctx.allocator, res, 500, "PageNotRendered");
    };

    return gserverz.HttpResponse.init(200, "OK", ctx.allocator)
        .withBody(html)
        .setContentType("text/html; charset=utf-8")
        .withHeader("Cache-Control", "no-store")
        .withHeader("X-Content-Type-Options", "nosniff");
}

/// `GET /admin` and `GET /admin/` — the front door, which is Accounts.
pub fn adminPageHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    return page(ctx, req, res, .accounts);
}

/// `GET /admin/accounts` — the accounts section.
pub fn adminAccountsHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    return page(ctx, req, res, .accounts);
}

/// `GET /admin/machines` — the machines section.
pub fn adminMachinesHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    return page(ctx, req, res, .machines);
}

/// `GET /admin/admin.css` — the console's stylesheet.
pub fn adminCssHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;
    _ = res;
    const asset = assetFor("/admin/admin.css") orelse return gserverz.HttpResponse.init(404, "Not Found", ctx.allocator);
    return serve(ctx.allocator, asset);
}

/// `GET /admin/admin.js` — the console's script.
pub fn adminJsHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;
    _ = res;
    const asset = assetFor("/admin/admin.js") orelse return gserverz.HttpResponse.init(404, "Not Found", ctx.allocator);
    return serve(ctx.allocator, asset);
}

const testing = std.testing;

test "the console answers the stylesheet and the script, and nothing else" {
    const css = assetFor("/admin/admin.css").?;
    try testing.expectEqualStrings("text/css; charset=utf-8", css.content_type);
    try testing.expect(css.body.len > 0);

    const js = assetFor("/admin/admin.js").?;
    try testing.expectEqualStrings("application/javascript; charset=utf-8", js.content_type);
    try testing.expect(js.body.len > 0);

    // The page is rendered, not an asset, and nothing else is ours.
    try testing.expect(assetFor("/admin") == null);
    try testing.expect(assetFor("/admin/accounts") == null);
    try testing.expect(assetFor("/admin/other") == null);
    try testing.expect(assetFor("/api/admin/users") == null);
}

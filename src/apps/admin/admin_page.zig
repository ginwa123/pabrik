//! The admin console page: three static files, embedded in the binary.
//! No build step, no bundler, no framework.

const std = @import("std");
const gserverz = @import("kabelweb").server;

const page_html = @embedFile("index.html");
const page_css = @embedFile("admin.css");
const page_js = @embedFile("admin.js");

/// One file the console serves.
pub const Asset = struct {
    body: []const u8,
    content_type: []const u8,
};

/// The file a request path maps to, or null when it is not one of ours.
pub fn assetFor(path: []const u8) ?Asset {
    if (std.mem.eql(u8, path, "/admin") or std.mem.eql(u8, path, "/admin/")) {
        return .{ .body = page_html, .content_type = "text/html; charset=utf-8" };
    }
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

/// `GET /admin` — the console itself.
pub fn adminPageHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;
    _ = res;
    const asset = assetFor("/admin") orelse return gserverz.HttpResponse.init(404, "Not Found", ctx.allocator);
    return serve(ctx.allocator, asset);
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

test "the console answers the page, the stylesheet and the script, and nothing else" {
    const page = assetFor("/admin").?;
    try testing.expectEqualStrings("text/html; charset=utf-8", page.content_type);
    try testing.expect(page.body.len > 0);

    const css = assetFor("/admin/admin.css").?;
    try testing.expectEqualStrings("text/css; charset=utf-8", css.content_type);
    try testing.expect(css.body.len > 0);

    const js = assetFor("/admin/admin.js").?;
    try testing.expectEqualStrings("application/javascript; charset=utf-8", js.content_type);
    try testing.expect(js.body.len > 0);

    // The trailing slash is the same page, and nothing else is ours.
    try testing.expectEqualStrings(page.body, assetFor("/admin/").?.body);
    try testing.expect(assetFor("/admin/other") == null);
    try testing.expect(assetFor("/api/admin/users") == null);
}

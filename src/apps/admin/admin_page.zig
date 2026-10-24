//! The admin console page: static files, embedded in the binary. No build step,
//! no bundler, no framework.
//!
//! The page itself is five parts under `page/`, joined here at comptime. That
//! keeps one HTTP response — nothing is fetched or templated at runtime — while
//! each part stays small enough to read on its own.

const std = @import("std");
const gserverz = @import("kabelweb").server;

const part_shell = @embedFile("page/shell.html");
const part_accounts = @embedFile("page/accounts.html");
const part_machines = @embedFile("page/machines.html");
const part_dialogs = @embedFile("page/dialogs.html");
const part_foot = @embedFile("page/foot.html");

const page_css = @embedFile("admin.css");
const page_js = @embedFile("admin.js");

/// The document, in the order the parts appear in it. `++` is a comptime
/// concatenation, so the parts are joined when the binary is built.
const page_html = part_shell ++ part_accounts ++ part_machines ++ part_dialogs ++ part_foot;

/// Every path that serves that one document: the front door, and each section
/// as a real path rather than a `#fragment`. The trailing slash is the same
/// page, the way `/admin/` already was.
const page_paths = [_][]const u8{
    "/admin",
    "/admin/",
    "/admin/accounts",
    "/admin/accounts/",
    "/admin/machines",
    "/admin/machines/",
};

fn isPage(path: []const u8) bool {
    for (page_paths) |candidate| {
        if (std.mem.eql(u8, path, candidate)) return true;
    }
    return false;
}

/// One file the console serves.
pub const Asset = struct {
    body: []const u8,
    content_type: []const u8,
};

/// The file a request path maps to, or null when it is not one of ours.
pub fn assetFor(path: []const u8) ?Asset {
    if (isPage(path)) {
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

/// `GET /admin` and `GET /admin/:section` — the console itself.
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

test "each section is a path of its own, served the same document" {
    const page = assetFor("/admin").?;
    for ([_][]const u8{
        "/admin/",
        "/admin/accounts",
        "/admin/accounts/",
        "/admin/machines",
        "/admin/machines/",
    }) |path| {
        const asset = assetFor(path) orelse {
            std.debug.print("no page at {s}\n", .{path});
            return error.NotServed;
        };
        try testing.expectEqualStrings("text/html; charset=utf-8", asset.content_type);
        try testing.expectEqualStrings(page.body, asset.body);
    }
    // A section that does not exist is not a page, and neither is a path that
    // walks past one.
    try testing.expect(assetFor("/admin/overview") == null);
    try testing.expect(assetFor("/admin/accounts/extra") == null);
    try testing.expect(assetFor("/admin/machines/x") == null);
}

test "the document is the five parts, in order, and it closes" {
    const page = assetFor("/admin").?;
    const shell = std.mem.indexOf(u8, page.body, "<nav data-ui=\"sections\"") orelse return error.MissingShell;
    const accounts = std.mem.indexOf(u8, page.body, "id=\"section-accounts\"") orelse return error.MissingAccounts;
    const machines = std.mem.indexOf(u8, page.body, "id=\"section-machines\"") orelse return error.MissingMachines;
    const dialogs = std.mem.indexOf(u8, page.body, "id=\"resize-dialog\"") orelse return error.MissingDialogs;
    const script = std.mem.indexOf(u8, page.body, "<script src=\"/admin/admin.js\">") orelse return error.MissingScript;

    try testing.expect(shell < accounts);
    try testing.expect(accounts < machines);
    try testing.expect(machines < dialogs);
    try testing.expect(dialogs < script);

    // Every part made it in whole: the first line of each, and the last of the
    // document.
    try testing.expect(std.mem.startsWith(u8, page.body, "<!doctype html>\n"));
    try testing.expect(std.mem.endsWith(u8, page.body, "</html>\n"));
    try testing.expect(std.mem.indexOf(u8, page.body, "id=\"new-account-form\"") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "id=\"machines-search\"") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "id=\"credential-panel\"") != null);
}

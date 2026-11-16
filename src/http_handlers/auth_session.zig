//! `POST /api/auth/logout` — delete the session row + clear the cookie.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const auth_common = @import("auth_common.zig");

pub fn authLogoutHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();
    if (auth_common.parseSessionToken(req.headers)) |tok| {
        if (tok.len > 0) {
            var hash_hex: [64]u8 = undefined;
            auth_common.sha256Hex(tok, &hash_hex);
            di.db.exec(allocator, "DELETE FROM auth_sessions WHERE token_hash = ?", &[_][]const u8{hash_hex[0..]}) catch {};
        }
    }
    const data = try std.json.Stringify.valueAlloc(allocator, .{ .ok = true }, .{});
    const cleared = try auth_common.clearCookieValue(allocator);
    // NOTE: `jsonResponse` drops prior headers — `withHeader` goes after.
    return res.jsonResponse(.{ .status_code = 200, .data = data }).withHeader("Set-Cookie", cleared);
}

pub fn authMeHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();
    // When auth is off, report anonymous but 200 so the frontend can boot without a redirect.
    if (!di.auth_enabled) {
        const data = try std.json.Stringify.valueAlloc(allocator, .{ .authenticated = false, .auth_enabled = false }, .{});
        return res.jsonResponse(.{ .status_code = 200, .data = data });
    }
    const tok = auth_common.parseSessionToken(req.headers) orelse {
        return res.jsonResponse(.{
            .status_code = 401,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Unauthenticated" }),
        });
    };
    const sess = auth_common.lookupSession(allocator, di.db, tok) orelse {
        return res.jsonResponse(.{
            .status_code = 401,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Unauthenticated" }),
        });
    };
    defer auth_common.freeSessionLookup(allocator, sess);
    const MeOk = struct {
        authenticated: bool,
        auth_enabled: bool,
        user: struct {
            id: []const u8,
            email: []const u8,
            name: []const u8,
            role: []const u8,
        },
    };
    const data = try std.json.Stringify.valueAlloc(allocator, MeOk{
        .authenticated = true,
        .auth_enabled = true,
        .user = .{ .id = sess.user_id, .email = sess.email, .name = sess.name, .role = sess.role },
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

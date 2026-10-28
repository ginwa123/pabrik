//! `POST /api/auth/login` — verify email+password, mint a session cookie.
//! Always registered (even when `--auth` is off) so the frontend can probe
//! auth state uniformly.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const auth_common = @import("auth_common.zig");
const provisioning = @import("workspace_provisioning.zig");
const workspace_vm = @import("../agentic_loop/workspace_vm.zig");
const runtime_mode = @import("../runtime_mode.zig");

pub const LoginBody = struct {
    email: []const u8 = "",
    password: []const u8 = "",
};

const LoginOk = struct {
    user: struct {
        id: []const u8,
        email: []const u8,
        name: []const u8,
        role: []const u8,
    },
};

pub fn authLoginHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const di = try pabrikcore.getSingleton();
    const db = di.db;

    const parsed = std.json.parseFromSliceLeaky(LoginBody, allocator, req.body, .{ .ignore_unknown_fields = true }) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "InvalidBody" }),
        });
    };
    const email = std.mem.trim(u8, parsed.email, " \t");
    if (email.len == 0 or parsed.password.len == 0) {
        // Generic message: no user-enumeration via distinct errors.
        return res.jsonResponse(.{
            .status_code = 401,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "InvalidCredentials" }),
        });
    }

    // Look up active user by email.
    var q = db.query(allocator,
        "SELECT id, email, COALESCE(CAST(name AS TEXT), ''), password_hash, role FROM users WHERE email = ? AND is_active = 1",
        &[_][]const u8{email},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "DatabaseError" }),
        });
    };
    defer q.deinit();
    const row = q.next() catch {
        return res.jsonResponse(.{
            .status_code = 401,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "InvalidCredentials" }),
        });
    };
    const r = row orelse {
        return res.jsonResponse(.{
            .status_code = 401,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "InvalidCredentials" }),
        });
    };
    defer r.deinit(allocator);
    if (r.values.len < 5) {
        return res.jsonResponse(.{
            .status_code = 401,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "InvalidCredentials" }),
        });
    }
    const user_id = r.values[0];
    const user_email = r.values[1];
    const user_name = r.values[2];
    const stored_hash = r.values[3];
    const user_role = r.values[4];

    if (!auth_common.verifyPassword(stored_hash, parsed.password)) {
        return res.jsonResponse(.{
            .status_code = 401,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "InvalidCredentials" }),
        });
    }

    // Mint opaque token: 32 random bytes -> 64 hex chars.
    var rand: [32]u8 = undefined;
    io.random(&rand);
    var raw_token: [64]u8 = undefined;
    const hex = "0123456789abcdef";
    for (rand, 0..) |b, i| {
        raw_token[i * 2] = hex[b >> 4];
        raw_token[i * 2 + 1] = hex[b & 0x0f];
    }
    var hash_hex: [64]u8 = undefined;
    auth_common.sha256Hex(raw_token[0..], &hash_hex);

    db.exec(allocator,
        "INSERT INTO auth_sessions (token_hash, user_id, expires_at) VALUES (?, ?, datetime('now', '+30 days'))",
        &[_][]const u8{ hash_hex[0..], user_id },
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "SessionCreateFailed" }),
        });
    };
    // Best-effort last_login stamp; login already succeeded.
    db.exec(allocator, "UPDATE users SET last_login_at = datetime('now') WHERE id = ?", &[_][]const u8{user_id}) catch {};

    // An account with no workspaces lands on "No workspace selected" — an
    // empty sidebar behind a single "+ New workspace" button. Provision one
    // named "Default" now that the account is usable.
    const provisioned = provisioning.ensureDefaultWorkspace(
        allocator,
        db,
        io,
        user_id,
        di.environment,
        workspace_vm.creationIsVm(runtime_mode.currentMode()),
    ) catch |err| blk: {
        std.log.warn("auth_login: default workspace provisioning failed for {s} (non-fatal, the sidebar will show none): {s}", .{ user_email, @errorName(err) });
        break :blk null;
    };
    // `null` means the user already had workspaces — nothing to clean up.
    if (provisioned) |workspace| {
        defer workspace.deinit(allocator);
    }

    const data = try std.json.Stringify.valueAlloc(allocator, LoginOk{
        .user = .{ .id = user_id, .email = user_email, .name = user_name, .role = user_role },
    }, .{});
    const cookie = try auth_common.setCookieValue(allocator, raw_token[0..]);
    // NOTE: `jsonResponse` builds a FRESH response (drops prior headers),
    // so `withHeader` must come AFTER it, not before.
    return res.jsonResponse(.{ .status_code = 200, .data = data }).withHeader("Set-Cookie", cookie);
}

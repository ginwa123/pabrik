//! The admin console's HTTP surface: `/api/admin/*`. Every endpoint answers
//! 401 without a usable session and 403 for a session that is not the owner.

const std = @import("std");
const database = @import("databases").database;
const gserverz = @import("kabelweb").server;
const auth_core = @import("auth_core");
const admin_common = @import("admin_common.zig");
const admin_store = @import("admin_store.zig");
const runtime = @import("runtime.zig");

/// One account as it goes on the wire.
const UserJson = struct {
    id: []const u8,
    email: []const u8,
    name: []const u8,
    role: []const u8,
    is_active: bool,
    created_at: []const u8,
    last_login_at: ?[]const u8 = null,
};

const UsersListResponse = struct {
    users: []const UserJson,
    count: u32,
};

const OverviewResponse = struct {
    total_users: u32,
    active_users: u32,
    admin_users: u32,
    bot_users: u32,
    active_sessions: u32,
};

const CreatedUserResponse = struct {
    user: UserJson,
    temporary_password: ?[]const u8 = null,
};

const UpdatedUserResponse = struct {
    user: UserJson,
};

const PasswordResponse = struct {
    user_id: []const u8,
    temporary_password: ?[]const u8 = null,
};

const CreateUserBody = struct {
    email: []const u8 = "",
    name: []const u8 = "",
    role: []const u8 = "",
    password: []const u8 = "",
};

const UpdateUserBody = struct {
    role: ?[]const u8 = null,
    is_active: ?bool = null,
};

const PasswordBody = struct {
    password: []const u8 = "",
};

fn toJson(row: admin_store.UserRow) UserJson {
    return .{
        .id = row.id,
        .email = row.email,
        .name = row.name,
        .role = row.role,
        .is_active = row.is_active,
        .created_at = row.created_at,
        .last_login_at = if (row.last_login_at.len == 0) null else row.last_login_at,
    };
}

const ErrorBody = struct { @"error": []const u8 };

pub fn errorResponse(allocator: std.mem.Allocator, res: gserverz.HttpResponse, status: u16, message: []const u8) !gserverz.HttpResponse {
    return res.jsonResponse(.{
        .status_code = status,
        .data = try std.json.Stringify.valueAlloc(allocator, ErrorBody{ .@"error" = message }, .{}),
    });
}

/// The owner gate every admin endpoint opens with. A refusal is a real
/// answer, so the error path may not be swallowed: an allocation failure
/// must not turn into "allowed".
pub fn ownerOnly(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
    db: *database.Db,
    auth_enabled: bool,
) !?gserverz.HttpResponse {
    const access = admin_common.resolveAccess(ctx.allocator, db, auth_enabled, req.headers);
    if (access == .owner) return null;
    return try errorResponse(ctx.allocator, res, admin_common.accessStatus(access), admin_common.accessMessage(access));
}

/// `GET /api/admin/overview` — the counts the console opens with.
pub fn adminOverviewHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const db = runtime.db() orelse return errorResponse(ctx.allocator, res, 503, "AdminConsoleNotInstalled");
    if (try ownerOnly(ctx, req, res, db, runtime.authEnabled())) |denied| return denied;

    const counts = try admin_store.overview(ctx.allocator, db);
    const data = try std.json.Stringify.valueAlloc(ctx.allocator, OverviewResponse{
        .total_users = counts.total_users,
        .active_users = counts.active_users,
        .admin_users = counts.admin_users,
        .bot_users = counts.bot_users,
        .active_sessions = counts.active_sessions,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

/// `GET /api/admin/users` — every real account.
pub fn adminUsersListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const db = runtime.db() orelse return errorResponse(ctx.allocator, res, 503, "AdminConsoleNotInstalled");
    if (try ownerOnly(ctx, req, res, db, runtime.authEnabled())) |denied| return denied;

    const rows = try admin_store.listUsers(ctx.allocator, db);
    defer admin_store.freeUsers(ctx.allocator, rows);

    const mapped = try ctx.allocator.alloc(UserJson, rows.len);
    defer ctx.allocator.free(mapped);
    for (rows, 0..) |row, i| mapped[i] = toJson(row);

    const data = try std.json.Stringify.valueAlloc(ctx.allocator, UsersListResponse{
        .users = mapped,
        .count = @intCast(rows.len),
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

/// `POST /api/admin/users` — create an account. Without a password the
/// console mints a temporary one and hands it back once, so the owner can
/// pass it on.
pub fn adminUserCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const db = runtime.db() orelse return errorResponse(ctx.allocator, res, 503, "AdminConsoleNotInstalled");
    if (try ownerOnly(ctx, req, res, db, runtime.authEnabled())) |denied| return denied;

    const body = std.json.parseFromSliceLeaky(CreateUserBody, ctx.allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errorResponse(ctx.allocator, res, 400, "InvalidBody");
    };

    const email = try admin_common.normaliseEmail(ctx.allocator, body.email);
    if (!admin_common.isValidEmail(email)) {
        return errorResponse(ctx.allocator, res, 400, "InvalidEmail");
    }
    const role: admin_common.Role = if (body.role.len == 0)
        .user
    else
        admin_common.parseRole(body.role) orelse
            return errorResponse(ctx.allocator, res, 400, "InvalidRole");

    var id_bytes: [8]u8 = undefined;
    ctx.io.random(&id_bytes);
    const id = try admin_common.newUserId(ctx.allocator, &id_bytes);

    var password = body.password;
    var generated: ?[]const u8 = null;
    if (password.len == 0) {
        var pw_bytes: [admin_common.temporary_password_len]u8 = undefined;
        ctx.io.random(&pw_bytes);
        generated = try admin_common.temporaryPassword(ctx.allocator, &pw_bytes);
        password = generated.?;
    }

    const hash = try auth_core.hashPassword(ctx.allocator, ctx.io, password);
    const now = try admin_common.sqliteNow(ctx.allocator, ctx.io);
    const row = admin_store.insertUser(ctx.allocator, db, id, email, body.name, role, hash, now) catch |err| switch (err) {
        error.EmailTaken => return try errorResponse(ctx.allocator, res, 409, "EmailTaken"),
        else => return err,
    };
    defer admin_store.freeUser(ctx.allocator, row);

    const data = try std.json.Stringify.valueAlloc(ctx.allocator, CreatedUserResponse{
        .user = toJson(row),
        .temporary_password = generated,
    }, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = data });
}

/// `PATCH /api/admin/users/:id` — change the role or whether it may sign in.
pub fn adminUserUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const db = runtime.db() orelse return errorResponse(ctx.allocator, res, 503, "AdminConsoleNotInstalled");
    if (try ownerOnly(ctx, req, res, db, runtime.authEnabled())) |denied| return denied;

    const id = req.params.get("id") orelse {
        return errorResponse(ctx.allocator, res, 400, "MissingUserId");
    };
    if (std.mem.eql(u8, id, admin_common.system_user_id)) {
        return errorResponse(ctx.allocator, res, 400, "SystemAccountIsNotEditable");
    }

    const body = std.json.parseFromSliceLeaky(UpdateUserBody, ctx.allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errorResponse(ctx.allocator, res, 400, "InvalidBody");
    };
    const role: ?admin_common.Role = if (body.role) |raw|
        admin_common.parseRole(raw) orelse return errorResponse(ctx.allocator, res, 400, "InvalidRole")
    else
        null;

    const row = admin_store.updateUser(ctx.allocator, db, id, role, body.is_active) catch |err| switch (err) {
        error.UserNotFound => return try errorResponse(ctx.allocator, res, 404, "UserNotFound"),
        error.LastAdmin => return try errorResponse(ctx.allocator, res, 409, "LastAdminCannotBeChanged"),
        else => return err,
    };
    defer admin_store.freeUser(ctx.allocator, row);

    const data = try std.json.Stringify.valueAlloc(ctx.allocator, UpdatedUserResponse{ .user = toJson(row) }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

/// `POST /api/admin/users/:id/password` — reset a password. The "forgot
/// password" case: the owner sets a new one and the sessions opened with the
/// old one stop working.
pub fn adminUserPasswordHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const db = runtime.db() orelse return errorResponse(ctx.allocator, res, 503, "AdminConsoleNotInstalled");
    if (try ownerOnly(ctx, req, res, db, runtime.authEnabled())) |denied| return denied;

    const id = req.params.get("id") orelse {
        return errorResponse(ctx.allocator, res, 400, "MissingUserId");
    };
    if (std.mem.eql(u8, id, admin_common.system_user_id)) {
        return errorResponse(ctx.allocator, res, 400, "SystemAccountIsNotEditable");
    }

    const body = std.json.parseFromSliceLeaky(PasswordBody, ctx.allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errorResponse(ctx.allocator, res, 400, "InvalidBody");
    };

    var password = body.password;
    var generated: ?[]const u8 = null;
    if (password.len == 0) {
        var pw_bytes: [admin_common.temporary_password_len]u8 = undefined;
        ctx.io.random(&pw_bytes);
        generated = try admin_common.temporaryPassword(ctx.allocator, &pw_bytes);
        password = generated.?;
    }

    const hash = try auth_core.hashPassword(ctx.allocator, ctx.io, password);
    admin_store.setPasswordHash(ctx.allocator, db, id, hash) catch |err| switch (err) {
        error.UserNotFound => return try errorResponse(ctx.allocator, res, 404, "UserNotFound"),
        else => return err,
    };
    try admin_common.revokeSessions(ctx.allocator, db, id);

    const data = try std.json.Stringify.valueAlloc(ctx.allocator, PasswordResponse{
        .user_id = id,
        .temporary_password = generated,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}


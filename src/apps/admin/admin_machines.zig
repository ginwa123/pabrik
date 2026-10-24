//! The machines section: what this console knows about a workspace's machine and
//! the one thing it can do about it. The manager is another process
//! (`pabrik-vmd`); without its socket the section says why and offers nothing.

const std = @import("std");
const gserverz = @import("kabelweb").server;

const admin_api = @import("admin_api.zig");
const admin_store = @import("admin_store.zig");
const runtime = @import("runtime.zig");
const vmd = @import("vmd_manager");

/// Where the manager listens. The host program installs it once, or leaves it
/// null and the section explains itself.
var socket_path: ?[]const u8 = null;

pub fn installSocket(path: ?[]const u8) void {
    socket_path = path;
}

/// Why this console cannot reach a manager, in the words the page shows.
fn refusal() []const u8 {
    if (!vmd.supported) return "this console was built for another platform; the manager is Linux-only";
    if (socket_path == null) return "no manager socket was given (--vmd-socket, or PABRIK_VMD_SOCKET)";
    return "no pabrik-vmd answers on that socket";
}

/// One workspace's machine, as the panel draws it.
const MachineJson = struct {
    workspace_id: []const u8,
    workspace_name: []const u8,
    state: []const u8,
    pid: i64 = 0,
    vcpus: u32 = 0,
    mem_mib: u32 = 0,
    disk_mib: u32 = 0,
    last_error: []const u8 = "",
};

const LimitsJson = struct {
    min_vcpus: u32 = vmd.limits.min_vcpus,
    max_vcpus: u32 = vmd.limits.max_vcpus,
    min_mem_mib: u32 = vmd.limits.min_mem_mib,
    max_mem_mib: u32 = vmd.limits.max_mem_mib,
    mem_step_mib: u32 = vmd.limits.mem_step_mib,
    min_disk_mib: u32 = vmd.limits.min_disk_mib,
    max_disk_mib: u32 = vmd.limits.max_disk_mib,
};

const MachinesResponse = struct {
    /// False means "do not offer a resize": the page reads this flag first.
    manager: bool,
    vms: []const MachineJson = &.{},
    count: u32 = 0,
    limits: LimitsJson = .{},
    /// Why `manager` is false. Null when it is true.
    manager_reason: ?[]const u8 = null,
};

const ResizeBody = struct {
    vcpus: u32 = 0,
    mem_mib: u32 = 0,
    disk_mib: u32 = 0,
};

const ResizeResponse = struct {
    workspace_id: []const u8,
    state: []const u8,
    pid: i64 = 0,
    vcpus: u32 = 0,
    mem_mib: u32 = 0,
    disk_mib: u32 = 0,
    last_error: []const u8 = "",
};

/// A client that has answered `ping`, or null. A socket nobody listens on is
/// not an error here: it is the difference between "no machines" and "the
/// manager is down", and the page says which.
fn liveClient(allocator: std.mem.Allocator) ?vmd.Client {
    const path = socket_path orelse return null;
    var client = vmd.Client.init(allocator, path);
    const version = client.ping() catch return null;
    allocator.free(version);
    return client;
}

/// `GET /api/admin/vms` — every workspace, each with the state its machine is
/// in. Without a manager the list is empty and `manager_reason` says why, so the
/// page never draws a machine it cannot see.
pub fn listHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const db = runtime.db() orelse return admin_api.errorResponse(ctx.allocator, res, 503, "AdminConsoleNotInstalled");
    if (try admin_api.ownerOnly(ctx, req, res, db, runtime.authEnabled())) |denied| return denied;

    if (comptime !vmd.supported) {
        return respond(ctx, res, .{ .manager = false, .manager_reason = refusal() });
    }

    var client = liveClient(ctx.allocator) orelse {
        return respond(ctx, res, .{ .manager = false, .manager_reason = refusal() });
    };

    const rows = try admin_store.listWorkspaces(ctx.allocator, db);
    defer admin_store.freeWorkspaces(ctx.allocator, rows);

    var machines: std.ArrayList(MachineJson) = .empty;
    defer machines.deinit(ctx.allocator);
    for (rows) |row| {
        const state = client.status(row.id) catch {
            try machines.append(ctx.allocator, .{
                .workspace_id = row.id,
                .workspace_name = row.name,
                .state = "unavailable",
            });
            continue;
        };
        defer state.deinit(ctx.allocator);
        try machines.append(ctx.allocator, .{
            .workspace_id = row.id,
            .workspace_name = row.name,
            .state = try ctx.allocator.dupe(u8, state.state),
            .pid = state.pid,
            .vcpus = state.vcpus,
            .mem_mib = state.mem_mib,
            .disk_mib = state.disk_mib,
            .last_error = try ctx.allocator.dupe(u8, state.last_error),
        });
    }

    return respond(ctx, res, .{
        .manager = true,
        .vms = machines.items,
        .count = @intCast(machines.items.len),
    });
}

/// `POST /api/admin/vms/:workspace/resize` — stop that machine, apply the size,
/// start it again. The guest comes back; the processes inside it do not.
pub fn resizeHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const db = runtime.db() orelse return admin_api.errorResponse(ctx.allocator, res, 503, "AdminConsoleNotInstalled");
    if (try admin_api.ownerOnly(ctx, req, res, db, runtime.authEnabled())) |denied| return denied;

    if (comptime !vmd.supported) {
        return admin_api.errorResponse(ctx.allocator, res, 503, refusal());
    }

    const workspace_id = req.params.get("workspace") orelse {
        return admin_api.errorResponse(ctx.allocator, res, 400, "MissingWorkspaceId");
    };
    const body = std.json.parseFromSliceLeaky(ResizeBody, ctx.allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return admin_api.errorResponse(ctx.allocator, res, 400, "InvalidBody");
    };
    if (vmd.limits.check(workspace_id, body.vcpus, body.mem_mib)) |refused| {
        return admin_api.errorResponse(ctx.allocator, res, 400, refused.message());
    }
    if (body.disk_mib != 0) {
        if (vmd.limits.checkDisk(body.disk_mib, 0)) |refused| {
            return admin_api.errorResponse(ctx.allocator, res, 400, refused.message());
        }
    }

    var client = liveClient(ctx.allocator) orelse {
        return admin_api.errorResponse(ctx.allocator, res, 503, refusal());
    };
    const state = client.resize(workspace_id, body.vcpus, body.mem_mib, body.disk_mib) catch |err| {
        if (err == vmd.Error.ServerFailure) {
            if (client.lastFailure()) |failure| {
                return admin_api.errorResponse(ctx.allocator, res, 502, failure.text());
            }
        }
        return admin_api.errorResponse(ctx.allocator, res, 502, @errorName(err));
    };
    defer state.deinit(ctx.allocator);

    const data = try std.json.Stringify.valueAlloc(ctx.allocator, ResizeResponse{
        .workspace_id = workspace_id,
        .state = state.state,
        .pid = state.pid,
        .vcpus = state.vcpus,
        .mem_mib = state.mem_mib,
        .disk_mib = state.disk_mib,
        .last_error = state.last_error,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

fn respond(ctx: gserverz.HttpContext, res: gserverz.HttpResponse, body: MachinesResponse) !gserverz.HttpResponse {
    const data = try std.json.Stringify.valueAlloc(ctx.allocator, body, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

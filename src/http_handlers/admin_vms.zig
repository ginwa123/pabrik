//! `GET /api/admin/vms` and `POST /api/admin/vms/:workspace/resize` — the
//! console's VM panel. A resize is a short restart: `pabrik-vmd` stops the
//! workspace's VM, records its new size, and starts it again.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const vmd = @import("../vmd/vmd_client.zig");
const vm_limits = @import("../vmd/vm_limits.zig");
const runtime_mode = @import("../runtime_mode.zig");
const admin_common = @import("../apps/admin/admin_common.zig");
const http_response = @import("http_response.zig");

/// One workspace's VM as the panel shows it.
const VmRow = struct {
    workspace_id: []const u8,
    workspace_name: []const u8,
    state: []const u8,
    pid: i64 = 0,
    vcpus: u32 = 0,
    mem_mib: u32 = 0,
    last_error: []const u8 = "",
};

/// What a resize may ask for, echoed so the form cannot offer an impossible
/// value.
const Limits = struct {
    min_vcpus: u32 = vm_limits.min_vcpus,
    max_vcpus: u32 = vm_limits.max_vcpus,
    min_mem_mib: u32 = vm_limits.min_mem_mib,
    max_mem_mib: u32 = vm_limits.max_mem_mib,
};

const VmsResponse = struct {
    /// False when no `pabrik-vmd` answers: this installation runs no VMs, or
    /// the local runtime is the one that serves it.
    manager: bool = false,
    vms: []const VmRow = &.{},
    count: u32 = 0,
    limits: Limits = .{},
};

const ResizeResponse = struct {
    workspace_id: []const u8,
    state: []const u8,
    pid: i64 = 0,
    vcpus: u32 = 0,
    mem_mib: u32 = 0,
    last_error: []const u8 = "",
};

const ResizeBody = struct {
    vcpus: u32 = 0,
    mem_mib: u32 = 0,
};

fn errorResponse(allocator: std.mem.Allocator, res: gserverz.HttpResponse, status: u16, message: []const u8) !gserverz.HttpResponse {
    return res.jsonResponse(.{
        .status_code = status,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
    });
}

/// The owner gate, the one the console's own endpoints apply.
fn ownerOnly(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
    di: *pabrikcore.App,
) !?gserverz.HttpResponse {
    const access = admin_common.resolveAccess(ctx.allocator, di.db, di.auth_enabled, req.headers);
    if (access == .owner) return null;
    return try errorResponse(ctx.allocator, res, admin_common.accessStatus(access), admin_common.accessMessage(access));
}

/// The manager, when one answers on the socket this process knows.
fn liveManager(allocator: std.mem.Allocator, di: *pabrikcore.App) ?vmd.Client {
    // `--saas` names the manager it started; anything else runs no VMs.
    _ = di;
    const socket = runtime_mode.socketPath() orelse return null;
    var client = vmd.Client.init(allocator, socket);
    const version = client.ping() catch return null;
    allocator.free(version);
    return client;
}

/// `GET /api/admin/vms` — every workspace's VM with the size it runs as.
pub fn adminVmsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const di = try pabrikcore.getSingleton();
    if (try ownerOnly(ctx, req, res, di)) |denied| return denied;

    var client = liveManager(ctx.allocator, di);
    const manager = client != null;

    var rows: std.ArrayList(VmRow) = .empty;
    defer rows.deinit(ctx.allocator);

    var q = di.db.query(
        ctx.allocator,
        "SELECT id, COALESCE(name, '') FROM workspaces ORDER BY name, id",
        &.{},
    ) catch return errorResponse(ctx.allocator, res, 500, "DatabaseError");
    defer q.deinit();

    while (q.next() catch null) |row| {
        defer row.deinit(ctx.allocator);
        if (row.values.len < 2) continue;
        // The row's bytes die with the row, and the response outlives it, so
        // every string the answer carries is a copy (the request arena owns
        // them).
        const workspace_id = try ctx.allocator.dupe(u8, row.values[0]);
        const workspace_name = try ctx.allocator.dupe(u8, row.values[1]);

        var state_text: []const u8 = "no manager";
        var pid: i64 = 0;
        var vcpus: u32 = 0;
        var mem: u32 = 0;
        var err_text: []const u8 = "";
        if (manager) {
            if (client.?.status(workspace_id)) |st| {
                defer st.deinit(ctx.allocator);
                state_text = try ctx.allocator.dupe(u8, st.state);
                pid = st.pid;
                vcpus = st.vcpus;
                mem = st.mem_mib;
                err_text = try ctx.allocator.dupe(u8, st.last_error);
            } else |err| {
                state_text = "unavailable";
                err_text = @errorName(err);
            }
        }
        try rows.append(ctx.allocator, .{
            .workspace_id = workspace_id,
            .workspace_name = workspace_name,
            .state = state_text,
            .pid = pid,
            .vcpus = vcpus,
            .mem_mib = mem,
            .last_error = err_text,
        });
    }

    const data = try std.json.Stringify.valueAlloc(ctx.allocator, VmsResponse{
        .manager = manager,
        .vms = rows.items,
        .count = @intCast(rows.items.len),
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

/// `POST /api/admin/vms/:workspace/resize` — restart that workspace's VM with
/// a new size. The guest comes back; the processes inside it do not.
pub fn adminVmResizeHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const di = try pabrikcore.getSingleton();
    if (try ownerOnly(ctx, req, res, di)) |denied| return denied;

    const workspace_id = req.params.get("workspace") orelse {
        return errorResponse(ctx.allocator, res, 400, "MissingWorkspaceId");
    };

    const body = std.json.parseFromSliceLeaky(ResizeBody, ctx.allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errorResponse(ctx.allocator, res, 400, "InvalidBody");
    };
    if (vm_limits.check(workspace_id, body.vcpus, body.mem_mib)) |refusal| {
        return errorResponse(ctx.allocator, res, 400, refusal.message());
    }

    var client = liveManager(ctx.allocator, di) orelse
        return errorResponse(ctx.allocator, res, 503, "NoVmManager");

    const state = client.resize(workspace_id, body.vcpus, body.mem_mib) catch |err| {
        if (err == vmd.Error.ServerFailure) {
            if (client.lastFailure()) |failure| {
                return errorResponse(ctx.allocator, res, 502, failure.text());
            }
        }
        return errorResponse(ctx.allocator, res, 502, @errorName(err));
    };
    defer state.deinit(ctx.allocator);

    const data = try std.json.Stringify.valueAlloc(ctx.allocator, ResizeResponse{
        .workspace_id = workspace_id,
        .state = state.state,
        .pid = state.pid,
        .vcpus = state.vcpus,
        .mem_mib = state.mem_mib,
        .last_error = state.last_error,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

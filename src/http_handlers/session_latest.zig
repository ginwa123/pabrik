//! `GET /api/sessions/latest?cwd=...` — fetch the latest session for a cwd.
//! Layered as `useCase` (resolve singleton + DB query) and a thin handler
//! that maps the outcome + errors to status codes / JSON.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const session_helpers = pabrikcore.session_helpers;

pub const SessionLatestError = error{
    MissingCwd,
    ServerNotInitialized,
    QueryFailed,
};

/// Tagged outcome of the session-latest use-case.
pub const SessionLatestResult = union(enum) {
    found: SessionLatestData,
    not_found,
};

pub const SessionLatestData = struct {
    session_id: []const u8,
    cwd: []const u8,
    created_at: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    cwd: []const u8,
) SessionLatestError!SessionLatestResult {
    // Local arena isolates allocations to this use-case so the
    // returned data can outlive the function scope cleanly.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const latest_session = session_helpers.getLatestSessionByDir(
        arena.allocator(),
        db,
        cwd,
    ) catch return error.QueryFailed;

    if (latest_session) |session| {
        // Copy out of the local arena so the returned data
        // outlives the useCase (the caller's per-request arena
        // will reap it at request end).
        return .{
            .found = .{
                .session_id = try allocator.dupe(u8, session.session_id),
                .cwd = try allocator.dupe(u8, session.cwd),
                .created_at = try allocator.dupe(u8, session.created_at),
            },
        };
    }
    return .not_found;
}

// =====================================================================
// Handler
// =====================================================================

pub fn sessionLatestHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
    _: *anyopaque,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const cwd = req.query.get("cwd") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try pabrikcore.http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing cwd parameter" }),
        });
    };

    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try pabrikcore.http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }),
        });
    };
    const sqlite_db = di.db;

    const outcome = useCase(allocator, sqlite_db, cwd) catch |err| {
        const status: u16 = switch (err) {
            error.MissingCwd => 400,
            error.ServerNotInitialized => 500,
            error.QueryFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.MissingCwd => "Missing cwd parameter",
            error.ServerNotInitialized => "Server not initialized",
            error.QueryFailed => "Database query failed",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try pabrikcore.http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    switch (outcome) {
        .found => |data| {
            return res.jsonResponse(.{
                .status_code = 200,
                .data = try std.fmt.allocPrint(
                    allocator,
                    "{{\"session_id\":\"{s}\",\"cwd\":\"{s}\",\"created_at\":\"{s}\",\"found\":true}}",
                    .{ data.session_id, data.cwd, data.created_at },
                ),
            });
        },
        .not_found => {
            return res.jsonResponse(.{
                .status_code = 200,
                .data = "{\"found\":false}",
            });
        },
    }
}
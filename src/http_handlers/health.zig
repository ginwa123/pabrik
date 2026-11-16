//! `GET /health` — connection-health probe.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;

/// Domain-level error set for `useCase`.
pub const HealthError = error{};

/// Health-probe data returned by the use-case.
pub const HealthData = http_response.HealthResponse;

// Use case

/// Read the current real-clock timestamp and produce the health payload.
fn useCase(io: std.Io) HealthError!HealthData {
    const ts = std.Io.Clock.now(.real, io);
    return .{
        .status = "ok",
        .timestamp = ts.toSeconds(),
    };
}

// Handler

pub fn healthHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;
    const allocator = ctx.allocator;

    const data = useCase(ctx.io) catch |err| {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = @errorName(err),
            }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeHealthResponse(allocator, data),
    });
}
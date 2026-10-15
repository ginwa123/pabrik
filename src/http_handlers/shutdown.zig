//! `POST /test/shutdown` — gracefully shut the server down. Triggers
//! `di.server.shutdown()` and returns 200 with a status message.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = pabrikcore.http_response;

pub const ShutdownError = error{
    GlobalContextNotInitialized,
};

pub const ShutdownResponse = struct {
    message: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase() ShutdownError!ShutdownResponse {
    _ = pabrikcore.getSingleton() catch return error.GlobalContextNotInitialized;
    // Deferred shutdown: do NOT call di.server.shutdown() synchronously.
    const helpers = @import("helpers");
    const spawn_fn = struct {
        fn run() void {
            helpers.sleepMillis(250);
            if (pabrikcore.getSingleton()) |di| {
                di.server.shutdown();
            } else |_| {}
            helpers.sleepMillis(50);
            std.process.exit(0);
        }
    }.run;
    if (std.Thread.spawn(.{}, spawn_fn, .{})) |t| {
        t.detach();
    } else |_| {
        const di = pabrikcore.getSingleton() catch return error.GlobalContextNotInitialized;
        di.server.shutdown();
        std.process.exit(0);
    }
    return .{ .message = "Server shutdown initiated" };
}

// =====================================================================
// Handler
// =====================================================================

pub fn shutdownHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;
    const allocator = ctx.allocator;

    const response = useCase() catch |err| {
        const status: u16 = switch (err) {
            error.GlobalContextNotInitialized => 500,
        };
        const message: []const u8 = switch (err) {
            error.GlobalContextNotInitialized => "Global context not initialized",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const json_str = try std.json.Stringify.valueAlloc(allocator, response, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}
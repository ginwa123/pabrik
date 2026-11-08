const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;

/// Handle OPTIONS preflight requests for CORS
pub fn corsPreflightHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = ctx;
    _ = req;
    return res.rawResponse(.{
        .status_code = 204,
        .headers = &.{
            .{ .key = "Access-Control-Allow-Origin", .value = "*" },
            .{ .key = "Access-Control-Allow-Methods", .value = "GET, POST, PUT, PATCH, DELETE, OPTIONS" },
            .{ .key = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization, Accept, Origin" },
            .{ .key = "Access-Control-Max-Age", .value = "86400" },
        },
        .body = "",
    });
}

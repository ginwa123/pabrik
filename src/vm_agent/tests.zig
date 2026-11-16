//! The guest side's unit-test root.

test {
    _ = @import("backoff.zig");
    _ = @import("egress_env.zig");
    _ = @import("main.zig");
    _ = @import("netd.zig");
    _ = @import("vsock.zig");
}

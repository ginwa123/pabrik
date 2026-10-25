//! The guest side's unit-test root. The guest binaries are compiled for the
//! musl guest target and cannot run here, so `zig build test:vm` builds this
//! root for the HOST and these imports are what pull each file's tests in.

test {
    _ = @import("backoff.zig");
    _ = @import("egress_env.zig");
    _ = @import("main.zig");
    _ = @import("netd.zig");
}

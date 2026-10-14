test {
    // 2026-09-29 flatten: formatter_test / logger_test / memory_leak_test /
    // request_id_test / timing_test were merged inline into the modules they
    // cover.
    _ = @import("Formatter.zig");
    _ = @import("Logger.zig");
    _ = @import("RequestId.zig");
    _ = @import("Timing.zig");
}

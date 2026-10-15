//! Aggregates the comprehensive edge-case test suite for `EventBus`. This
//! file is the test registration point for the event_bus module.

test {
    // 2026-09-29 flatten: event_test.zig was merged inline into event.zig.
    _ = @import("event.zig");
}

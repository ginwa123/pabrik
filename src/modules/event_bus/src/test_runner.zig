//! Aggregates the comprehensive edge-case test suite for `EventBus`.

test {
    // 2026-09-29 flatten: event_test.zig was merged inline into event.zig.
    _ = @import("event.zig");
}

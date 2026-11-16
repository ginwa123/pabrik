//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
pub const EventBus = @import("event.zig").EventBus;

test {
    // Pull in the event_bus test suite via its dedicated runner so `cd src/modules/event_bus && zig build test` runs the same 44 tests as the main project's `zig …
    _ = @import("test_runner.zig");
}

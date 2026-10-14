//! The test root for the zginlint module, which is not in the pabrikcore
//! module graph. `zig build test:zginlint` runs it, and each import below is
//! what makes that file's own `test` blocks reachable to the compiler.

test {
    _ = @import("comment_scan.zig");
    _ = @import("diagnostic.zig");
    _ = @import("io_util.zig");
    _ = @import("options.zig");
    _ = @import("rule.zig");
    _ = @import("rules/max_comment_lines.zig");
    _ = @import("rules/no_catch_unreachable.zig");
    _ = @import("zginlint.zig");
    _ = @import("cli.zig");
}

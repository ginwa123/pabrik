const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

/// Migration 121 — install postgres' spellings of sqlite's `datetime(...)` and
/// `strftime(...)`. The DDL lives in `dialect.sqlite_time_functions` because the
/// test harness installs it too; on sqlite this migration is a no-op.
pub const Migration121AddSqliteTimeFunctions = struct {
    pub const version: u32 = 121;
    pub const name = "add_sqlite_time_functions";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        for (dialect.sqlite_time_functions) |sql| try db.exec(allocator, sql, &[_][]const u8{});
    }
};

//! Process-startup wiring for the TUI module.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const Scheduler = @import("../ai_workflow/tui/routines/Scheduler.zig");

/// Submit the routine scheduler as a concurrent task on the Io
/// runtime. The task runs forever; on the same Io group as
/// session-create tasks. No thread is spawned.
pub fn start(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    di: *pabrikcore.App,
    io: std.Io,
) !void {
    try di.group_emit_session_create.concurrent(
        io,
        struct {
            fn run(
                alloc: std.mem.Allocator,
                database: *pabrikcore.database.Db,
                di_inner: *pabrikcore.App,
                io_inner: std.Io,
            ) void {
                Scheduler.start(alloc, database, di_inner, io_inner) catch |err| {
                    std.log.err("scheduler crashed: {s}", .{@errorName(err)});
                };
            }
        }.run,
        .{ allocator, db, di, io },
    );
}

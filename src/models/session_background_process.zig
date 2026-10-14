//! Data model for the `session_background_process` entity table. Tracks
//! long-lived background processes (dev servers, file watchers, build
//! daemons) spawned by the bash tool.

const std = @import("std");

pub const EntityId = struct {
    session_id: []const u8,
    pid: i64,
};

session_id: []u8,
pid: i64,
/// The full command string the bash tool spawned.
command: []u8,
/// Absolute path to the log file the bash tool redirected stdout
/// + stderr into. Read by the chat header's "view output" link.
log_path: []u8,
/// Unix-seconds timestamp of the spawn event.
started_at: i64,
/// One of `"running"` | `"stopped"` | `"failed"`. The DB column
/// has no CHECK constraint.
status: []u8,

const Self = @This();

pub const InitArgs = struct {
    session_id: []const u8,
    pid: i64,
    command: []const u8,
    log_path: []const u8,
    started_at: i64,
    status: []const u8 = "running",
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .session_id = try allocator.dupe(u8, args.session_id),
        .pid = args.pid,
        .command = try allocator.dupe(u8, args.command),
        .log_path = try allocator.dupe(u8, args.log_path),
        .started_at = args.started_at,
        .status = try allocator.dupe(u8, args.status),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.session_id);
    allocator.free(self.command);
    allocator.free(self.log_path);
    allocator.free(self.status);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .session_id = self.session_id,
        .pid = self.pid,
        .command = self.command,
        .log_path = self.log_path,
        .started_at = self.started_at,
        .status = self.status,
    });
}

// ===== Tests merged from models_test.zig (2026-09-29 flatten) =====

// Sanity tests for the `src/models/` entity models.

const testing = std.testing;

test "session_background_process: init + deinit" {
    var p = try init(testing.allocator, .{
        .session_id = "session_1",
        .pid = 12345,
        .command = "npm run dev",
        .log_path = "/tmp/dev.log",
        .started_at = 1786000000,
        .status = "running",
    });
    defer deinit(&p, testing.allocator);

    try testing.expectEqual(@as(i64, 12345), p.pid);
    try testing.expectEqualStrings("npm run dev", p.command);
    try testing.expectEqualStrings("/tmp/dev.log", p.log_path);
    try testing.expectEqualStrings("running", p.status);
}
//! Data model for the `workspace_routines` entity table. One row per Routine
//! workspace item (`item_type='routine'`).

const std = @import("std");

pub const EntityId = []u8;

id: EntityId,
/// The workspace_item this routine belongs to. Same string as `id` per
/// the 1-1 invariant.
workspace_item_id: EntityId,
/// Free-form description. Empty slice is the canonical "no description"
/// sentinel (matches `agents.description`).
description: []u8 = &.{},
/// The agent prompt fired on each run. Empty = manual-run only
/// (same as empty schedule).
instruction: []u8 = &.{},
/// Standard 5-field cron expression (e.g. `"0 9 * * *"` for daily
/// 09:00). Empty string = manual-run only (no auto-fire).
/// Validated by `routines/cron.zig`.
schedule: []u8 = &.{},
enabled: bool = true,
last_run_at: ?[]u8 = null,
/// Next scheduled fire time (`YYYY-MM-DD HH:MM:SS`). NULL on disk
/// (empty slice on the wire) when `schedule` is empty or the routine
/// is disabled.
next_run_at: ?[]u8 = null,
/// One of `"idle"` | `"firing"` | `"running"` | `"failed"`.
/// The DB column has no CHECK constraint.
last_status: []u8 = &.{},
last_error: ?[]u8 = null,
created_at: ?[]u8 = null,
updated_at: ?[]u8 = null,

const Self = @This();

pub const InitArgs = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    description: []const u8 = "",
    instruction: []const u8 = "",
    schedule: []const u8 = "",
    enabled: bool = true,
    last_run_at: ?[]const u8 = null,
    next_run_at: ?[]const u8 = null,
    last_status: []const u8 = "idle",
    last_error: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

pub fn init(allocator: std.mem.Allocator, args: InitArgs) !Self {
    return .{
        .id = try allocator.dupe(u8, args.id),
        .workspace_item_id = try allocator.dupe(u8, args.workspace_item_id),
        .description = try allocator.dupe(u8, args.description),
        .instruction = try allocator.dupe(u8, args.instruction),
        .schedule = try allocator.dupe(u8, args.schedule),
        .enabled = args.enabled,
        .last_run_at = if (args.last_run_at) |lr|
            try allocator.dupe(u8, lr)
        else
            null,
        .next_run_at = if (args.next_run_at) |nr|
            try allocator.dupe(u8, nr)
        else
            null,
        .last_status = try allocator.dupe(u8, args.last_status),
        .last_error = if (args.last_error) |le| try allocator.dupe(u8, le) else null,
        .created_at = if (args.created_at) |ca| try allocator.dupe(u8, ca) else null,
        .updated_at = if (args.updated_at) |ua| try allocator.dupe(u8, ua) else null,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.id);
    allocator.free(self.workspace_item_id);
    if (self.description.len > 0) allocator.free(self.description);
    if (self.instruction.len > 0) allocator.free(self.instruction);
    if (self.schedule.len > 0) allocator.free(self.schedule);
    if (self.last_run_at) |lr| allocator.free(lr);
    if (self.next_run_at) |nr| allocator.free(nr);
    if (self.last_status.len > 0) allocator.free(self.last_status);
    if (self.last_error) |le| allocator.free(le);
    if (self.created_at) |ca| allocator.free(ca);
    if (self.updated_at) |ua| allocator.free(ua);
}

pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
    return .init(allocator, .{
        .id = self.id,
        .workspace_item_id = self.workspace_item_id,
        .description = self.description,
        .instruction = self.instruction,
        .schedule = self.schedule,
        .enabled = self.enabled,
        .last_run_at = if (self.last_run_at) |lr| lr else null,
        .next_run_at = if (self.next_run_at) |nr| nr else null,
        .last_status = self.last_status,
        .last_error = if (self.last_error) |le| le else null,
        .created_at = if (self.created_at) |ca| ca else null,
        .updated_at = if (self.updated_at) |ua| ua else null,
    });
}

// ===== Tests merged from models_test.zig (2026-09-29 flatten) =====

// Sanity tests for the `src/models/` entity models.

const testing = std.testing;

test "workspace_routine: init + deinit" {
    var r = try init(testing.allocator, .{
        .id = "wr_1",
        .workspace_item_id = "item_1",
        .instruction = "Check the build status",
        .schedule = "*/5 * * * *",
        .next_run_at = "2026-08-15 12:00:00",
        .enabled = true,
    });
    defer deinit(&r, testing.allocator);

    try testing.expectEqualStrings("wr_1", r.id);
    try testing.expectEqualStrings("item_1", r.workspace_item_id);
    try testing.expectEqualStrings("*/5 * * * *", r.schedule);
    try testing.expect(r.enabled);
    try testing.expectEqualStrings("idle", r.last_status);
    try testing.expect(r.next_run_at != null);
}

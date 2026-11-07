//! SSE events for kanban mutations.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const on_event_sent = pabrikcore.ai_mod.on_event_sent;
const SseEvent = on_event_sent.SseEvent;

/// Action discriminator for `kanban_column` events.
pub const KanbanColumnAction = enum {
    created,
    updated,
    deleted,
    reordered,
};

/// JSON payload for a `kanban_column` SSE event. Field names match the
/// frontend's `KanbanColumnEvent` interface (camelCase for the action,
/// snake_case for the ids — see `src/apps/desktop/src/api/index.ts`).
pub const KanbanColumnEventPayload = struct {
    /// "created" | "updated" | "deleted" | "reordered"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    column_id: []const u8,
    /// New column name (only set for "updated"; null otherwise).
    new_name: ?[]const u8 = null,
    /// New column description (only set for "updated"; null otherwise).
    new_description: ?[]const u8 = null,
    /// New position (only set for "updated" / "reordered"; null otherwise).
    new_position: ?i64 = null,
};

/// Emit a `kanban_column` SSE event. Called from every kanban column HTTP
/// handler on success.
pub fn onEventSendKanbanColumn(
    allocator: std.mem.Allocator,
    payload: KanbanColumnEventPayload,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    // Build the SSE event.
    const event = SseEvent{
        .session_id = "kanban_column",
        .data = json_payload,
        .event_type = "kanban_column",
    };

    // event_bus.emit returns void and silently no-ops when no
    // subscriber is registered — so tests that don't stand up an SSE
    // server still pass.
    const di = pabrikcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "kanban_column", event);
}

/// Action discriminator for `kanban_task` events.
pub const KanbanTaskAction = enum {
    assigned,
    moved,
    unassigned,
    /// Human interaction stamp — fired by the new `PUT
    /// /api/.../tasks/:id/touched` endpoint and by every existing
    /// task-mutating handler (`task_update`, `task_create`, `tasks_move`,
    human_touched,
};

/// JSON payload for a `kanban_task` SSE event. Field names match
/// the frontend's `KanbanTaskEvent` interface.
pub const KanbanTaskEventPayload = struct {
    /// "assigned" | "moved" | "unassigned" | "human_touched"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    task_id: []const u8,
    /// New kanban_column_id (null for "unassigned" / "human_touched").
    new_column_id: ?[]const u8 = null,
    /// New kanban_position (null for "unassigned" / "human_touched").
    new_position: ?i64 = null,
    /// After-action `needs_human_review` state.
    needs_human_review: ?bool = null,
};

/// Emit a `kanban_task` SSE event. Called from `tasks_move.zig` on
/// every successful move and from `task_create.zig` when the new
/// task is auto-assigned to a kanban column.
pub fn onEventSendKanbanTask(
    allocator: std.mem.Allocator,
    payload: KanbanTaskEventPayload,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .session_id = "kanban_task",
        .data = json_payload,
        .event_type = "kanban_task",
    };

    const di = pabrikcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "kanban_task", event);
}

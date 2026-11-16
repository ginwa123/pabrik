//! SSE events for design-mode mutations.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const on_event_sent = pabrikcore.ai_mod.on_event_sent;
const on_event_design = @import("on_event_design.zig");

const SseEvent = on_event_sent.SseEvent;

/// Emit a `design_element_created` SSE event.
pub fn onEventSendDesignElementCreated(
    allocator: std.mem.Allocator,
    payload: on_event_design.DesignElementCreatedData,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    // Build the SSE event.
    const event = SseEvent{
        .session_id = "design_element",
        .data = json_payload,
        .event_type = "design_element_created",
    };

    // event_bus.emit returns void and silently no-ops when no subscriber is registered — so tests that don't stand up an SSE server still pass.
    const di = pabrikcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_element", event);
}

/// Emit a `design_element_updated` SSE event.
pub fn onEventSendDesignElementUpdated(
    allocator: std.mem.Allocator,
    payload: on_event_design.DesignElementUpdatedData,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .session_id = "design_element",
        .data = json_payload,
        .event_type = "design_element_updated",
    };

    const di = pabrikcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_element", event);
}

/// Emit a `design_elements_geometry_batch_updated` SSE event.
pub fn onEventSendDesignElementsGeometryBatchUpdated(
    allocator: std.mem.Allocator,
    payload: on_event_design.DesignElementsGeometryBatchUpdatedData,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .session_id = "design_element",
        .data = json_payload,
        .event_type = "design_elements_geometry_batch_updated",
    };

    const di = pabrikcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_element", event);
}

/// Emit a `design_element_deleted` SSE event.
pub fn onEventSendDesignElementDeleted(
    allocator: std.mem.Allocator,
    payload: on_event_design.DesignElementDeletedData,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .session_id = "design_element",
        .data = json_payload,
        .event_type = "design_element_deleted",
    };

    const di = pabrikcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_element", event);
}

/// Emit a `design_page_deleted` SSE event.
pub fn onEventSendDesignPageDeleted(
    allocator: std.mem.Allocator,
    payload: on_event_design.DesignPageDeletedData,
) !void {
    const json_payload = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{},
    );
    defer allocator.free(json_payload);

    const event = SseEvent{
        .session_id = "design_page",
        .data = json_payload,
        .event_type = "design_page_deleted",
    };

    const di = pabrikcore.getSingleton() catch return;
    di.event_bus.emit(SseEvent, "design_page", event);
}

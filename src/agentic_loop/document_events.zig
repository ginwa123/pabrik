//! The `documents` SSE channel: the backend telling the UI that the agent
//! created, rewrote or removed a document, so the sidebar's Documents list
//! (and an editor open on that document) refresh without polling.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const SseEvent = @import("sse.zig").SseEvent;

const event_bus_mod = pabrikcore.event_bus;

/// The central routing key. The frontend subscribes with the `documents`
/// channel token, which `parseChannels` maps to this key.
pub const RoutingKey = "documents";

pub const EventCreated = "document_created";
pub const EventUpdated = "document_updated";
pub const EventDeleted = "document_deleted";

/// One document mutation. `workspace_id` is what the frontend filters on: the
/// backend fans these out to every connected client, and only a tab showing
/// THAT workspace may react.
pub const DocumentEventInput = struct {
    /// `created` | `updated` | `deleted`.
    action: []const u8,
    workspace_id: []const u8,
    document_id: []const u8,
    /// The document's title AFTER the mutation. Empty when the mutation did
    /// not read the row back — the frontend uses it for the row label only.
    title: []const u8 = "",
};

/// Emit one document mutation. No-op when `event_bus` is null (unit tests, and
/// any caller that has no bus). The caller keeps owning `input`'s slices.
pub fn emitDocumentEvent(
    allocator: std.mem.Allocator,
    event_bus: ?*event_bus_mod.EventBus,
    input: DocumentEventInput,
) void {
    const bus = event_bus orelse return;

    const data = std.json.Stringify.valueAlloc(allocator, input, .{}) catch return;
    // `EventBus.emit` dispatches synchronously, so every subscriber has copied
    // what it needs before this runs.
    defer allocator.free(data);

    const event_type_name: []const u8 = if (std.mem.eql(u8, input.action, "created"))
        EventCreated
    else if (std.mem.eql(u8, input.action, "updated"))
        EventUpdated
    else if (std.mem.eql(u8, input.action, "deleted"))
        EventDeleted
    else
        "document_unknown";

    bus.emit(SseEvent, RoutingKey, .{
        .session_id = RoutingKey,
        .data = data,
        .event_type = event_type_name,
    });
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

var captured: ?SseEvent = null;
var captured_payload: []u8 = &.{};

/// The emit frees the JSON buffer it built, so keeping `ev.data` would dangle
/// — copy it here, while the emit is still on the stack.
fn capture(ev: SseEvent) void {
    captured = ev;
    captured_payload = testing.allocator.dupe(u8, ev.data) catch return;
}

fn releaseCapture() void {
    if (captured_payload.len > 0) testing.allocator.free(captured_payload);
    captured_payload = &.{};
    captured = null;
}

test "each document action maps to its own granular wire name" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var bus = event_bus_mod.EventBus.init("test", alloc, threaded.io());
    defer bus.deinit();

    const cases = [_]struct { action: []const u8, want: []const u8 }{
        .{ .action = "created", .want = EventCreated },
        .{ .action = "updated", .want = EventUpdated },
        .{ .action = "deleted", .want = EventDeleted },
        // An unrecognised action must NOT silently become a registered name.
        .{ .action = "something_new", .want = "document_unknown" },
    };

    try bus.subscribe(SseEvent, RoutingKey, capture);
    for (cases) |c| {
        releaseCapture();
        emitDocumentEvent(alloc, &bus, .{
            .action = c.action,
            .workspace_id = "ws_1",
            .document_id = "doc_1",
            .title = "Notes",
        });
        const ev = captured orelse return error.NoEvent;
        try testing.expectEqualStrings(c.want, ev.event_type orelse "");
        // The envelope id is the routing-key literal, not a session id: this
        // channel is workspace-scoped, and the frontend filters on the
        // payload's `workspace_id`.
        try testing.expectEqualStrings(RoutingKey, ev.session_id);
        releaseCapture();
    }
}

test "the payload carries the action, workspace, document and title" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var bus = event_bus_mod.EventBus.init("test", alloc, threaded.io());
    defer bus.deinit();

    releaseCapture();
    try bus.subscribe(SseEvent, RoutingKey, capture);
    emitDocumentEvent(alloc, &bus, .{
        .action = "updated",
        .workspace_id = "ws_9",
        .document_id = "doc_9",
        .title = "Release notes",
    });

    try testing.expect(captured != null);
    // `parsed` borrows slices into the buffer, so it must be deinit'd BEFORE
    // the buffer is freed — the other order is a use-after-free.
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, captured_payload, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("updated", parsed.value.object.get("action").?.string);
        try testing.expectEqualStrings("ws_9", parsed.value.object.get("workspace_id").?.string);
        try testing.expectEqualStrings("doc_9", parsed.value.object.get("document_id").?.string);
        try testing.expectEqualStrings("Release notes", parsed.value.object.get("title").?.string);
    }
    releaseCapture();
}

test "an omitted title still reaches the wire as an empty string" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var bus = event_bus_mod.EventBus.init("test", alloc, threaded.io());
    defer bus.deinit();

    releaseCapture();
    try bus.subscribe(SseEvent, RoutingKey, capture);
    emitDocumentEvent(alloc, &bus, .{
        .action = "deleted",
        .workspace_id = "ws_1",
        .document_id = "doc_1",
    });

    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, captured_payload, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("", parsed.value.object.get("title").?.string);
    }
    releaseCapture();
}

test "a null event_bus makes the emit a no-op" {
    emitDocumentEvent(testing.allocator, null, .{
        .action = "created",
        .workspace_id = "ws_1",
        .document_id = "doc_1",
        .title = "Notes",
    });
    try testing.expect(captured == null);
}

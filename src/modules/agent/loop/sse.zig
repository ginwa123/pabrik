
pub const SseEvent = struct {
    session_id: []const u8,
    data: []const u8,
    event_type: ?[]const u8 = null,
};

const testing = @import("std").testing;

test "SseEvent event_type defaults to null" {
    const e = SseEvent{
        .session_id = "s",
        .data = "d",
    };
    try testing.expect(e.event_type == null);
}

test "SseEvent accepts an explicit event_type" {
    const e = SseEvent{
        .session_id = "s",
        .data = "d",
        .event_type = "queue_queued",
    };
    try testing.expectEqualStrings("queue_queued", e.event_type.?);
}

test "SseEvent fields preserve byte-exact slice headers" {
    const sid: []const u8 = "session_xyz";
    const data: []const u8 = "{\"action\":\"queued\"}";
    const e = SseEvent{
        .session_id = sid,
        .data = data,
    };
    try testing.expectEqualStrings(sid, e.session_id);
    try testing.expectEqualStrings(data, e.data);
}

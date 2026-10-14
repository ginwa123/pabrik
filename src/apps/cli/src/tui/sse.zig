//! Minimal SSE frame parser for the pabrik event stream.

const std = @import("std");

pub const Event = struct {
    /// `event:` line value (borrowed from the input buffer).
    name: []const u8,
    /// Concatenated `data:` lines (borrowed from the input buffer).
    data: []const u8,
};

/// Parse ALL complete SSE events in `buf`. Returns how many bytes were
/// consumed (events are complete only when terminated by a blank line —
/// either `\n\n` or `\r\n\r\n`).
pub fn parse(buf: []const u8, out: *std.ArrayList(Event), allocator: std.mem.Allocator) !usize {
    var consumed: usize = 0;
    var rest = buf;
    while (rest.len > 0) {
        const lf_lf = std.mem.indexOf(u8, rest, "\n\n");
        const crlf = std.mem.indexOf(u8, rest, "\r\n\r\n");
        const frame_end, const sep_len = chooseFrameEnd(lf_lf, crlf) orelse break;
        const frame = rest[0..frame_end];
        consumed += frame_end + sep_len;
        rest = rest[frame_end + sep_len ..];

        var name: []const u8 = "";
        var data_pieces: std.ArrayList([]const u8) = .empty;
        defer data_pieces.deinit(allocator);

        var it = std.mem.splitScalar(u8, frame, '\n');
        while (it.next()) |raw_line| {
            const line = if (std.mem.endsWith(u8, raw_line, "\r"))
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;
            if (std.mem.startsWith(u8, line, "event:")) {
                name = std.mem.trim(u8, line["event:".len..], " ");
            } else if (std.mem.startsWith(u8, line, "data:")) {
                var payload = line["data:".len..];
                while (payload.len > 0 and payload[0] == ' ') payload = payload[1..];
                try data_pieces.append(allocator, payload);
            }
        }
        if (data_pieces.items.len == 0) continue;

        const data: []const u8 = if (data_pieces.items.len == 1)
            data_pieces.items[0]
        else
            try joinDataLines(allocator, data_pieces.items);

        try out.append(allocator, .{ .name = name, .data = data });
    }
    return consumed;
}

/// Choose the nearer frame separator. Returns null if neither exists.
fn chooseFrameEnd(lf_lf: ?usize, crlf: ?usize) ?struct { usize, usize } {
    if (lf_lf == null and crlf == null) return null;
    if (lf_lf == null) return .{ crlf.?, 4 };
    if (crlf == null) return .{ lf_lf.?, 2 };
    if (lf_lf.? <= crlf.?) return .{ lf_lf.?, 2 };
    return .{ crlf.?, 4 };
}

/// Join multiple `data:` payload pieces with newlines, per the SSE
/// spec ("If the line starts with a colon, ... If the line is empty,
/// ... Otherwise concatenate the lines with newlines"). Caller owns.
fn joinDataLines(allocator: std.mem.Allocator, pieces: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (pieces) |p| total += p.len;
    total += pieces.len - 1; // separating newlines
    const out = try allocator.alloc(u8, total);
    var cursor: usize = 0;
    for (pieces, 0..) |p, i| {
        if (i > 0) {
            out[cursor] = '\n';
            cursor += 1;
        }
        @memcpy(out[cursor..][0..p.len], p);
        cursor += p.len;
    }
    return out;
}

/// Extract `"action"` from an SSE data payload (JSON). Returns null if
/// absent.
pub fn actionOf(data: []const u8) ?[]const u8 {
    return stringField(data, "action");
}

/// Extract `"session_id"` from an SSE data payload (JSON).
pub fn sessionIdOf(data: []const u8) ?[]const u8 {
    return stringField(data, "session_id");
}

fn stringField(data: []const u8, field: []const u8) ?[]const u8 {
    // Cheap scan for "\"field\":\"value\"" without a full JSON parse —
    // the payloads are small and this avoids arena churn per event.
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":\"", .{field}) catch return null;
    const start = std.mem.indexOf(u8, data, pat) orelse return null;
    const vstart = start + pat.len;
    const vend = std.mem.indexOfScalarPos(u8, data, vstart, '"') orelse return null;
    return data[vstart..vend];
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "parse: single event with name and data" {
    var events = std.ArrayList(Event).empty;
    defer events.deinit(testing.allocator);
    const input = "event: llm_history\ndata: {\"action\":\"updated\"}\n\n";
    const consumed = try parse(input, &events, testing.allocator);
    try testing.expectEqual(input.len, consumed);
    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqualStrings("llm_history", events.items[0].name);
    try testing.expectEqualStrings("{\"action\":\"updated\"}", events.items[0].data);
}

test "parse: multiple events" {
    var events = std.ArrayList(Event).empty;
    defer events.deinit(testing.allocator);
    const input = "event: a\ndata: 1\n\nevent: b\ndata: 2\n\n";
    _ = try parse(input, &events, testing.allocator);
    try testing.expectEqual(@as(usize, 2), events.items.len);
    try testing.expectEqualStrings("b", events.items[1].name);
}

test "parse: incomplete frame consumes nothing" {
    var events = std.ArrayList(Event).empty;
    defer events.deinit(testing.allocator);
    const input = "event: a\ndata: 1\n"; // no blank-line terminator
    const consumed = try parse(input, &events, testing.allocator);
    try testing.expectEqual(@as(usize, 0), consumed);
    try testing.expectEqual(@as(usize, 0), events.items.len);
}

test "actionOf: extracts action" {
    try testing.expectEqualStrings("updated", actionOf("{\"action\":\"updated\",\"x\":1}").?);
    try testing.expect(actionOf("{\"nope\":1}") == null);
}

test "sessionIdOf: extracts session_id" {
    try testing.expectEqualStrings("session-42", sessionIdOf("{\"session_id\":\"session-42\"}").?);
}

// ===== Tests merged from tdd_round2_test.zig (2026-09-29 flatten) =====
// Section 2 of tdd_round2_test.zig: the `sse.parse` regression tests
// (CRLF-terminated frames + multi-line data).

// ============================================================================
// 2. sse.parse — CRLF frames + multi-line data
// ============================================================================

test "sse parse: CRLF-terminated frame yields one event" {
    var events = std.ArrayList(Event).empty;
    defer events.deinit(testing.allocator);
    const input = "event: llm_history\r\ndata: {\"a\":1}\r\n\r\n";
    const consumed = try parse(input, &events, testing.allocator);
    try testing.expectEqual(input.len, consumed);
    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqualStrings("llm_history", events.items[0].name);
    try testing.expectEqualStrings("{\"a\":1}", events.items[0].data);
}

test "sse parse: multi-line data lines are joined with newline" {
    var events = std.ArrayList(Event).empty;
    defer {
        for (events.items) |ev| testing.allocator.free(@constCast(ev.data));
        events.deinit(testing.allocator);
    }
    const input = "event: x\ndata: line1\ndata: line2\n\n";
    _ = try parse(input, &events, testing.allocator);
    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqualStrings("line1\nline2", events.items[0].data);
}

test "sse parse: single-line data still borrows into input" {
    var events = std.ArrayList(Event).empty;
    defer events.deinit(testing.allocator);
    const input = "event: x\ndata: one\n\n";
    _ = try parse(input, &events, testing.allocator);
    // Borrowed slice points inside `input` — no allocation needed.
    try testing.expect(events.items[0].data.ptr == input.ptr + "event: x\ndata: ".len);
}

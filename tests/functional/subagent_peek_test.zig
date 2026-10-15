// Functional wire tests for sub-agent peek fetches. Zig port of
// `tests/functional/subagent_peek_test.py`. Task: task_1788551671819_5
// (sub-agent peek always empty).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// `POST /api/llm/session` with `name`, returning an OWNED session id. The
/// caller frees the returned slice.
fn createSession(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/llm/session", .{
        .json_body = body,
        .expect = &.{201},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const id = doc.str("id") orelse {
        std.debug.print("no id in session-create body: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// Python's `s.replace(needle, replacement, 1)` — replace only the FIRST
/// occurrence, and return an owned slice.
fn replaceFirstOwned(haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, haystack, needle) orelse
        return gpa.dupe(u8, haystack);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(haystack[0..at]);
    try w.writeAll(replacement);
    try w.writeAll(haystack[at + needle.len ..]);
    return out.toOwnedSlice();
}

/// Deep-equality for two parsed JSON values. Python wrote
/// `decoded["messages"] == plain["messages"]`, which is a structural
/// comparison of arbitrarily nested lists/dicts.
fn jsonValueEql(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .string => std.mem.eql(u8, a.string, b.string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |x, y| {
                if (!jsonValueEql(x, y)) break :blk false;
            }
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValueEql(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

// The eye panel fetches `GET .../messages` for the child sid. A sid
// with no rows (wrong id, pre-first-row live open) must be 200 empty,
// not an error — the panel shows `No messages yet.` + live SSE.
test "peek_unknown_subagent_sid_returns_empty_200" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/llm/session/subagent_1_never_existed/messages?limit=100", .{
        .expect = &.{200},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const messages = doc.array("messages") orelse {
        std.debug.print("no messages array in: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(usize, 0), messages.items.len);
}

// `%5F` (`_`) in the path must decode before router matching, so the
// frontend's new `encodeURIComponent(sid)` fetch hits the same rows as the
// raw fetch.
test "peek_percent_encoded_sid_decodes_to_same_session" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = try createSession(&h, "peek-probe");
    defer gpa.free(session_id);

    // Generated ids are `sess_<ts>_<hex>` — the `_` is the whole point
    // of this probe.
    try testing.expect(std.mem.indexOf(u8, session_id, "_") != null);

    const plain_path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages?limit=10", .{session_id});
    defer gpa.free(plain_path);
    var plain_r = try h.http(io, .GET, plain_path, .{ .expect = &.{200} });
    defer plain_r.deinit();
    var plain = try plain_r.json();
    defer plain.deinit();

    const encoded_id = try std.mem.replaceOwned(u8, gpa, session_id, "_", "%5F");
    defer gpa.free(encoded_id);
    try testing.expect(!std.mem.eql(u8, encoded_id, session_id));

    const encoded_path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages?limit=10", .{encoded_id});
    defer gpa.free(encoded_path);
    var decoded_r = try h.http(io, .GET, encoded_path, .{ .expect = &.{200} });
    defer decoded_r.deinit();
    var decoded = try decoded_r.json();
    defer decoded.deinit();

    const plain_messages = plain.array("messages") orelse {
        std.debug.print("no messages array in: {s}\n", .{plain_r.body});
        return error.TestUnexpectedResult;
    };
    const decoded_messages = decoded.array("messages") orelse {
        std.debug.print("no messages array in: {s}\n", .{decoded_r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expect(jsonValueEql(
        .{ .array = plain_messages },
        .{ .array = decoded_messages },
    ));

    // Python: `decoded.get("has_more", False) == plain.get("has_more", False)`.
    try testing.expectEqual(
        plain.boolean("has_more") orelse false,
        decoded.boolean("has_more") orelse false,
    );
}

// `%2F` decodes to `/` BEFORE the router splits on `/`, so the path gains a
// segment and matches no route → 404.
test "peek_encoded_slash_does_not_match_session_route" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = try createSession(&h, "peek-probe");
    defer gpa.free(session_id);

    const bad_id = try replaceFirstOwned(session_id, "_", "%2F");
    defer gpa.free(bad_id);
    try testing.expect(!std.mem.eql(u8, bad_id, session_id));

    const bad_path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages?limit=10", .{bad_id});
    defer gpa.free(bad_path);

    var r = try h.http(io, .GET, bad_path, .{ .expect = &.{404} });
    defer r.deinit();
}
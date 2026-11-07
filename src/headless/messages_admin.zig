//! `pabrik headless message <op>` — delete, restore or drop ONE `llm_history`
//! row. Same use-cases the HTTP routes call, so the CLI cannot drift.

const std = @import("std");
const pabrikcore = @import("pabrikcore");

const args = @import("args.zig");
const boot_mod = @import("boot.zig");

const llm_history = pabrikcore.llm_history;

/// Run one message-admin op and return the JSON object to print on stdout.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    backend: *boot_mod.Backend,
    a: args.MessageArgs,
) ![]u8 {
    const db = backend.ctx.db;
    switch (a.op) {
        .delete => {
            const row = try llm_history.deleteMessageById(allocator, db, a.message_id);
            defer llm_history.freeMessageRow(allocator, &row);
            return std.json.Stringify.valueAlloc(allocator, .{ .deleted = .{ .row = row } }, .{});
        },
        .restore => {
            const body = try std.Io.Dir.cwd().readFileAlloc(io, a.row_file, allocator, .limited(4 * 1024 * 1024));
            defer allocator.free(body);
            const Body = struct { row: llm_history.MessageRow };
            const parsed = try std.json.parseFromSliceLeaky(Body, allocator, body, .{});
            try llm_history.restoreMessage(allocator, db, parsed.row);
            return std.json.Stringify.valueAlloc(allocator, .{ .restored = .{ .id = parsed.row.id } }, .{});
        },
        .feed => {
            const feed = a.feed orelse return error.FeedRequired;
            try llm_history.setMessageFeedToLlm(allocator, db, a.message_id, feed);
            return std.json.Stringify.valueAlloc(allocator, .{
                .id = a.message_id,
                .is_feed_to_llm = feed,
            }, .{});
        },
    }
}

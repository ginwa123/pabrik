//! `pr-status` command — GET /api/git/pr/status?path=<repo>[&pr=<n|url>].
//! Shows a pull request's open/merged/closed status via the backend's `gh pr
//! view` wrapper.

const std = @import("std");
const config = @import("../config.zig");
const client_mod = @import("../client.zig");

pub const Args = struct {
    /// PR number, URL, or branch name. Empty = current branch's PR.
    pr: []const u8 = "",
    /// Repo path on the server. Defaults to the server's cwd.
    path: []const u8 = ".",
    provider: ?[]const u8 = null,
    /// Print the raw backend JSON instead of the human-readable summary.
    json: bool = false,
};

/// Percent-encode a query value (unreserved set left as-is per RFC 3986).
fn encodeInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or c == '~';
        if (unreserved) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0xF]);
        }
    }
}

pub fn buildPath(allocator: std.mem.Allocator, args: Args) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "/api/git/pr/status?path=");
    try encodeInto(&buf, allocator, args.path);
    if (args.pr.len > 0) {
        try buf.appendSlice(allocator, "&pr=");
        try encodeInto(&buf, allocator, args.pr);
    }
    if (args.provider) |p| {
        if (p.len > 0) {
            try buf.appendSlice(allocator, "&provider=");
            try encodeInto(&buf, allocator, p);
        }
    }
    return buf.toOwnedSlice(allocator);
}

const PrStatusView = struct {
    pr_url: []const u8 = "",
    number: i64 = 0,
    title: []const u8 = "",
    state: []const u8 = "",
    status: []const u8 = "",
    mergeable: []const u8 = "",
    merge_state: []const u8 = "",
    head_ref: []const u8 = "",
    base_ref: []const u8 = "",
    author: []const u8 = "",
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
    merged_at: []const u8 = "",
    closed_at: []const u8 = "",
    additions: i64 = 0,
    deletions: i64 = 0,
    changed_files: i64 = 0,
};

fn printHuman(writer: *std.Io.Writer, v: PrStatusView) !void {
    // #42 Title (STATE / status)
    try writer.print("#{d} {s} ({s} / {s})\n", .{ v.number, v.title, v.state, v.status });
    if (v.pr_url.len > 0) try writer.print("URL: {s}\n", .{v.pr_url});
    if (v.head_ref.len > 0 or v.base_ref.len > 0) {
        if (v.author.len > 0) {
            try writer.print("Branch: {s} -> {s} by {s}\n", .{ v.head_ref, v.base_ref, v.author });
        } else {
            try writer.print("Branch: {s} -> {s}\n", .{ v.head_ref, v.base_ref });
        }
    }
    if (v.mergeable.len > 0 or v.merge_state.len > 0) {
        try writer.print("Mergeable: {s} (merge_state: {s})\n", .{ v.mergeable, v.merge_state });
    }
    if (v.created_at.len > 0) try writer.print("Created: {s}\n", .{v.created_at});
    if (v.updated_at.len > 0) try writer.print("Updated: {s}\n", .{v.updated_at});
    if (v.merged_at.len > 0) try writer.print("Merged: {s}\n", .{v.merged_at});
    if (v.closed_at.len > 0) try writer.print("Closed: {s}\n", .{v.closed_at});
    try writer.print("Changes: +{d} -{d} in {d} files\n", .{ v.additions, v.deletions, v.changed_files });
}

pub fn run(args: Args, cfg: config.Config, io: std.Io) @import("root.zig").DispatchResult {
    const allocator = std.heap.page_allocator;
    var http_client = @import("kabelweb").client.Client.init(allocator);
    defer http_client.deinit();

    const path = buildPath(allocator, args) catch return .err;
    defer allocator.free(path);

    const response_body = client_mod.getJson(allocator, &http_client, cfg.server, path) catch {
        return .err;
    };
    defer allocator.free(response_body);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);

    if (args.json) {
        stdout_writer.interface.writeAll(response_body) catch return .err;
        stdout_writer.interface.writeByte('\n') catch return .err;
        stdout_writer.interface.flush() catch return .err;
        return .ok;
    }

    const parsed = std.json.parseFromSliceLeaky(PrStatusView, allocator, response_body, .{ .ignore_unknown_fields = true }) catch {
        // Fall back to raw output when the shape is unexpected.
        stdout_writer.interface.writeAll(response_body) catch return .err;
        stdout_writer.interface.writeByte('\n') catch return .err;
        stdout_writer.interface.flush() catch return .err;
        return .ok;
    };
    printHuman(&stdout_writer.interface, parsed) catch return .err;
    stdout_writer.interface.flush() catch return .err;
    return .ok;
}

// ===== Tests merged from pr_status_test.zig (2026-09-29 flatten) ===== Tests
// for src/commands/pr_status.zig (GET /api/git/pr/status).

const testing = std.testing;

test "pr_status buildPath: defaults omit empty pr/provider" {
    const p = try buildPath(testing.allocator, .{});
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/api/git/pr/status?path=.", p);
}

test "pr_status buildPath: encodes pr URL and provider" {
    const p = try buildPath(testing.allocator, .{
        .pr = "https://github.com/acme/app/pull/42",
        .path = "/tmp/repo",
        .provider = "github",
    });
    defer testing.allocator.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "/api/git/pr/status?path=") != null);
    try testing.expect(std.mem.indexOf(u8, p, "%3A%2F%2F") != null);
    try testing.expect(std.mem.indexOf(u8, p, "&provider=github") != null);
}

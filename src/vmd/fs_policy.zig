//! The rules a guest file RPC obeys: the caller names a path RELATIVE to the
//! workspace root — never absolute, never with a `.`/`..` segment — and every
//! reply is bounded. Pure, so the rules are tested on every host.

const std = @import("std");
const policy = @import("policy.zig");

pub const max_path_rel_len = 1024;
pub const max_segment_len = 255;
/// The most one whole file may add up to across a read's replies. The agent's
/// per-reply chunk is smaller; this is the caller's total.
pub const max_read_bytes: usize = 4 * 1024 * 1024;

/// A path a file RPC may name. `policy.cwdRelValid` already refuses the absolute
/// form, the trailing `/`, the empty segment, NUL and the backslash; this adds
/// the length ceilings and the non-empty rule a file (not a directory) needs.
pub fn pathRelValid(rel: []const u8) bool {
    if (rel.len == 0 or rel.len > max_path_rel_len) return false;
    if (!policy.cwdRelValid(rel)) return false;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |segment| {
        if (segment.len > max_segment_len) return false;
    }
    return true;
}

/// A directory a LIST may name: the workspace root itself is legal.
pub fn dirRelValid(rel: []const u8) bool {
    if (rel.len == 0) return true;
    return pathRelValid(rel);
}

/// `<root>/<rel>`, or the root itself when `rel` is empty.
pub fn guestPath(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    if (!dirRelValid(rel)) return error.InvalidPathRel;
    if (rel.len == 0) return allocator.dupe(u8, root);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, rel });
}

const testing = std.testing;

test "pathRelValid: a relative file path passes, every escape shape fails" {
    try testing.expect(pathRelValid("a.txt"));
    try testing.expect(pathRelValid("src/main.zig"));
    try testing.expect(pathRelValid("a/b/c/d.txt"));

    try testing.expect(!pathRelValid(""));
    try testing.expect(!pathRelValid("/etc/passwd"));
    try testing.expect(!pathRelValid("../etc/passwd"));
    try testing.expect(!pathRelValid("src/../../etc/passwd"));
    try testing.expect(!pathRelValid("src/./main.zig"));
    try testing.expect(!pathRelValid("src//main.zig"));
    try testing.expect(!pathRelValid("src/"));
    try testing.expect(!pathRelValid("a\\b"));
    try testing.expect(!pathRelValid(&[_]u8{'a'} ** (max_path_rel_len + 1)));
    try testing.expect(!pathRelValid(&[_]u8{'a'} ** (max_segment_len + 1)));
}

test "dirRelValid: the workspace root itself is a legal directory" {
    try testing.expect(dirRelValid(""));
    try testing.expect(dirRelValid("src"));
    try testing.expect(!dirRelValid("/"));
    try testing.expect(!dirRelValid(".."));
}

test "guestPath: the root joins, and nothing else is accepted" {
    const allocator = testing.allocator;
    const at_root = try guestPath(allocator, "/workspace", "");
    defer allocator.free(at_root);
    try testing.expectEqualStrings("/workspace", at_root);

    const nested = try guestPath(allocator, "/workspace", "src/main.zig");
    defer allocator.free(nested);
    try testing.expectEqualStrings("/workspace/src/main.zig", nested);

    try testing.expectError(error.InvalidPathRel, guestPath(allocator, "/workspace", "../../etc/shadow"));
    try testing.expectError(error.InvalidPathRel, guestPath(allocator, "/workspace", "/etc/shadow"));
}


//! The rules a guest file RPC obeys: the caller names a path RELATIVE to the workspace root — never absolute, never with a `.`/`..` segment — and every reply is …

const std = @import("std");
const policy = @import("policy.zig");

pub const max_path_rel_len = 1024;
pub const max_segment_len = 255;
/// The most one whole file may add up to across a read's replies.
pub const max_read_bytes: usize = 4 * 1024 * 1024;
/// The most one write RPC may carry.
pub const max_write_bytes: usize = 1024 * 1024;
/// A walk's two ceilings: how deep it descends, and how many entries it will report.
pub const max_walk_depth: u32 = 32;
pub const max_walk_entries: usize = 20_000;

/// A path a file RPC may name.
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

test "a write names a file and a walk may name the root" {
    // The two ops take the same field and want different answers from it: a write has no file to create at "", a walk starts there.
    try testing.expect(pathRelValid("src/main.zig"));
    try testing.expect(!pathRelValid(""));
    try testing.expect(dirRelValid(""));
    try testing.expect(dirRelValid("src"));
    try testing.expect(!dirRelValid("/workspace"));
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


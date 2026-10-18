//! The rules a guest file RPC obeys: the caller names a path RELATIVE to the
//! workspace root — never absolute, never with a `.`/`..` segment — and every
//! reply is bounded. Pure, so the rules are tested on every host.

const std = @import("std");
const policy = @import("policy.zig");

pub const max_path_rel_len = 1024;
pub const max_segment_len = 255;
pub const max_read_bytes: usize = 4 * 1024 * 1024;
pub const max_write_bytes: usize = 4 * 1024 * 1024;
pub const max_list_entries: usize = 4096;

/// `RESOLVE_BENEATH`: the path is resolved under the directory fd the agent
/// opened, and any component that would leave it — a `..` or an absolute
/// symlink target — is `EXDEV` rather than a read of something else.
pub const resolve_beneath: u64 = 0x08;

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

/// A name a LIST may report or a caller may join: one path component, no
/// separator, and never the two names that mean "this directory" and "its
/// parent".
pub fn entryNameValid(name: []const u8) bool {
    if (name.len == 0 or name.len > max_segment_len) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        if (c == 0 or c == '/') return false;
    }
    return true;
}

/// The read ceiling. A caller asking for more gets the cap, not an error: the
/// reply frame cannot hold an unbounded file either way.
pub fn readSizeValid(size: usize) bool {
    return size > 0 and size <= max_read_bytes;
}

/// The write ceiling, checked before the bytes are decoded so a large frame is
/// refused rather than base64-decoded into memory.
pub fn writeSizeValid(size: usize) bool {
    return size <= max_write_bytes;
}

/// The entry ceiling for one LIST reply.
pub fn listLimitValid(limit: usize) bool {
    return limit > 0 and limit <= max_list_entries;
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

test "entryNameValid: a directory entry is one component and never a dot name" {
    try testing.expect(entryNameValid("main.zig"));
    try testing.expect(entryNameValid("a b.txt"));

    try testing.expect(!entryNameValid(""));
    try testing.expect(!entryNameValid("."));
    try testing.expect(!entryNameValid(".."));
    try testing.expect(!entryNameValid("a/b"));
    try testing.expect(!entryNameValid("a\u{0000}b"));
    try testing.expect(!entryNameValid(&[_]u8{'a'} ** (max_segment_len + 1)));
}

test "the size ceilings bound a reply before anything is decoded" {
    try testing.expect(readSizeValid(1));
    try testing.expect(readSizeValid(max_read_bytes));
    try testing.expect(!readSizeValid(0));
    try testing.expect(!readSizeValid(max_read_bytes + 1));

    try testing.expect(writeSizeValid(0));
    try testing.expect(writeSizeValid(max_write_bytes));
    try testing.expect(!writeSizeValid(max_write_bytes + 1));

    try testing.expect(listLimitValid(1));
    try testing.expect(listLimitValid(max_list_entries));
    try testing.expect(!listLimitValid(0));
    try testing.expect(!listLimitValid(max_list_entries + 1));
}

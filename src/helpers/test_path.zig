//! Test-only helper that turns a bare file NAME into a path the agent
//! tools accept on every platform.

const std = @import("std");

/// `<cwd>/<name>`, written into `buf`; the result borrows `buf`. ## Why this
/// exists The agent tools reject a relative `path` on Windows.
pub fn absPath(buf: []u8, name: []const u8) ![]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    // libc `getcwd` needs no `std.Io` handle, which is what keeps the
    // call site to two lines. Same call `helpers.getcwd` makes in
    // mod.zig; it resolves against the UCRT on Windows.
    const raw = std.c.getcwd(cwd_buf[0..].ptr, cwd_buf.len) orelse
        return error.CwdUnavailable;
    const cwd = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(raw)), 0);
    // `fmtJoin` is the buffer-writing form of `std.fs.path.join` (whose Zig
    // 0.16 signature takes an Allocator, not a buffer): it inserts the native
    // separator and collapses a duplicated one, so a cwd that already ends in
    return std.fmt.bufPrint(buf, "{f}", .{std.fs.path.fmtJoin(&.{ cwd, name })});
}

/// Both path separators, on every platform — mirrors `isSep` in
/// `path_validate.zig`. Duplicated rather than imported so this file stays
/// std-only and therefore compiles standalone for a cross-target check.
fn isSep(c: u8) bool {
    return c == '\\' or c == '/';
}

/// The subset of `invalidPathReason`'s Windows branch that a produced test
/// path can plausibly violate, evaluated with the `builtin.os.tag !=
/// .windows` gate REMOVED so the assertions below run on every host.
fn reasonWindowsWouldReject(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "path cannot be empty";
    if (path.len > 32767) return "path too long";
    for (path) |c| {
        if (c == 0) return "path contains NUL byte";
        if (c < 0x20) return "path contains control character";
    }
    if (!std.fs.path.isAbsoluteWindows(path)) return "path must be an absolute Windows path";
    for (path) |c| {
        switch (c) {
            '*', '?', '<', '>', '|', '"' => return "path contains invalid character",
            else => {},
        }
    }
    // Colon is only legal as a drive prefix (`X:`); anything else is an
    // ADS suffix (`file:stream`) or garbage.
    for (path, 0..) |c, i| {
        if (c != ':') continue;
        if (!(i == 1 and std.ascii.isAlphabetic(path[0]))) return "path contains invalid character";
    }
    // Per-segment: no empty segments (`C:\foo\\bar`), no `..`, no trailing
    // dot or space. The leading root separator and a trailing separator
    // both yield an empty first/last segment and are legal.
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        const at_end = i == path.len;
        if (!at_end and !isSep(path[i])) continue;
        const seg = path[seg_start..i];
        const is_first = seg_start == 0;
        if (seg.len == 0) {
            if (!is_first and !at_end) return "path contains empty segment";
        } else {
            if (std.mem.eql(u8, seg, "..")) return "path must not contain ..";
            if (at_end and std.mem.eql(u8, seg, ".")) return "path must not end with .";
            if (seg[seg.len - 1] == '.' or seg[seg.len - 1] == ' ') return "path segment ends with dot or space";
        }
        seg_start = i + 1;
    }
    return null;
}

/// Assert `path` clears every rule the Windows branch of
/// `invalidPathReason` enforces. Prints the offending path and the
/// reason on failure so the fix is obvious from the log alone.
fn expectAcceptedByWindowsRule(path: []const u8) !void {
    // The single check the whole Windows branch is gated on. Asserted on
    // its own so the most likely regression reads clearly.
    if (!std.fs.path.isAbsoluteWindows(path)) {
        std.debug.print("absPath produced {s}, which is not an absolute Windows path\n", .{path});
        return error.TestUnexpectedResult;
    }
    if (reasonWindowsWouldReject(path)) |reason| {
        std.debug.print("absPath produced {s}, which invalidPathReason would reject: {s}\n", .{ path, reason });
        return error.TestUnexpectedResult;
    }
}

// ===========================================================================
// Tests — every one of these runs on EVERY platform (no os.tag gate).

test "absPath: produces a path the Windows branch of invalidPathReason accepts" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try absPath(&buf, "test_wf_basic.txt");
    try std.testing.expect(std.fs.path.isAbsoluteWindows(p));
    try expectAcceptedByWindowsRule(p);
}

test "absPath: a nested name also satisfies every Windows-branch rule" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try absPath(&buf, "docs/a/b.txt");
    try std.testing.expect(std.fs.path.isAbsoluteWindows(p));
    try expectAcceptedByWindowsRule(p);
}

test "absPath: a name with spaces, a leading dot and a single char are all accepted" {
    // The shapes the tool tests actually use (write_file.zig has a
    // "dir with spaces" case, a dotfile case and a one-character case).
    const names = [_][]const u8{
        "test_wf dir with spaces/file.txt",
        ".test_wf_hidden",
        "x",
    };
    for (names) |name| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = try absPath(&buf, name);
        try expectAcceptedByWindowsRule(p);
        // The name is preserved verbatim as the tail of the path.
        try std.testing.expect(std.mem.endsWith(u8, p, name));
    }
}

test "absPath: the bare name it replaces is exactly what a Windows runner refuses" {
    // Guards the reason this helper exists. Without it, a future edit
    // could "simplify" the call sites back to bare names and the Linux
    // suite would keep passing while Windows went red again.
    try std.testing.expect(!std.fs.path.isAbsoluteWindows("test_wf_basic.txt"));
    try std.testing.expect(reasonWindowsWouldReject("test_wf_basic.txt") != null);
    // A POSIX-shaped name is rooted, so isAbsoluteWindows accepts it —
    // which is why "make the test absolute" had to mean a REAL absolute
    // path, not just one that starts with a separator.
    try std.testing.expect(std.fs.path.isAbsoluteWindows("/tmp/x.txt"));
    // ...but a drive-RELATIVE name is still not absolute. Tests must not
    // "fix" this by using `C:foo.txt`, which is not a valid absolute path.
    try std.testing.expect(!std.fs.path.isAbsoluteWindows("C:foo.txt"));
}

test "absPath: result is <cwd>/<name>, not a rewrite of the name" {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const raw = std.c.getcwd(cwd_buf[0..].ptr, cwd_buf.len) orelse
        return error.SkipZigTest;
    const cwd = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(raw)), 0);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try absPath(&buf, "test_wf_basic.txt");
    // The cwd is the prefix (up to the separator the join inserts) and the
    // name is the untouched tail.
    try std.testing.expectEqualStrings(cwd, p[0..cwd.len]);
    try std.testing.expectEqualStrings("test_wf_basic.txt", std.mem.trimStart(u8, p[cwd.len..], "/\\"));
    try std.testing.expectEqual(cwd.len + 1 + "test_wf_basic.txt".len, p.len);

    // Two calls into the same buffer must agree — the helper never
    // allocates, so nothing else can move.
    const again = try absPath(&buf, "test_wf_basic.txt");
    try std.testing.expectEqualStrings(p, again);
}

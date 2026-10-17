//! The rules that make `pabrik-vmd`'s RPC safe: the request names a workspace
//! id and an action, and every path is derived from that id by these functions.
//! Pure and platform-free, so the policy is tested on every host.

const std = @import("std");

pub const max_workspace_id_len = 64;
pub const max_cwd_rel_len = 1024;
pub const guest_root = "/workspace";
pub const guest_shell = "/bin/sh";

/// The id arrives from outside and is the ONLY input that reaches a path, so it
/// must be inert: letters, digits, `_` and `-`, and never `.` or `..`.
pub fn workspaceIdValid(id: []const u8) bool {
    if (id.len == 0 or id.len > max_workspace_id_len) return false;
    for (id) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// A guest working directory, relative to the workspace root. Absolute paths
/// and any `.`/`..` segment are refused: the caller may only name a place
/// *inside* the workspace it already owns.
pub fn cwdRelValid(rel: []const u8) bool {
    if (rel.len > max_cwd_rel_len) return false;
    if (rel.len == 0) return true;
    if (rel[0] == '/' or rel[rel.len - 1] == '/') return false;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |c| {
            if (c == 0 or c == '\\') return false;
        }
    }
    return true;
}

/// `<root>` for the workspace root itself, `<root>/<rel>` below it. Errors
/// rather than guessing when `rel` is not a legal relative path.
pub fn guestCwd(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    if (!cwdRelValid(rel)) return error.InvalidCwdRel;
    if (rel.len == 0) return allocator.dupe(u8, root);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, rel });
}

/// The guest directory detached jobs log into. Outside `/workspace`, because a
/// job's log is not part of the tenant's tree.
pub const guest_job_log_dir = "/tmp/pabrik";
pub const max_log_name_len = 64;

/// A job's log NAME, not its path: the daemon derives the directory, so the
/// caller can only name a file inside `guestJobLogDir`.
pub fn logNameValid(name: []const u8) bool {
    if (name.len == 0 or name.len > max_log_name_len) return false;
    if (!std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
        if (!ok) return false;
    }
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    return true;
}

/// `<dir>/<name>` in the guest. Errors rather than guessing when `name` is not
/// a legal log name.
pub fn guestJobLogPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (!logNameValid(name)) return error.InvalidLogName;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ guest_job_log_dir, name });
}

/// The name half of a guest log path a previous `spawn` reported, or null when
/// the path is not one this daemon could have minted.
pub fn logNameFromPath(path: []const u8) ?[]const u8 {
    const prefix = guest_job_log_dir ++ "/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const name = path[prefix.len..];
    if (!logNameValid(name)) return null;
    return name;
}

/// The host-side half of the same rule: `cwd` must sit at or under the
/// workspace's root, and the result is what crosses the RPC. A `cwd` outside it
/// is refused rather than silently rewritten to the root.
pub fn relativeToRoot(root: []const u8, cwd: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, root, "/");
    if (trimmed.len == 0) return null;
    if (std.mem.eql(u8, cwd, trimmed)) return cwd[trimmed.len..];
    if (!std.mem.startsWith(u8, cwd, trimmed)) return null;
    if (cwd.len <= trimmed.len or cwd[trimmed.len] != '/') return null;
    const rel = cwd[trimmed.len + 1 ..];
    if (!cwdRelValid(rel)) return null;
    return rel;
}

/// The credential the kernel reports for a unix-socket peer. Only the uid is
/// load-bearing; the pid is carried so a refusal can name who was refused.
pub const Peer = struct {
    pid: i32,
    uid: u32,
    gid: u32,
};

pub fn peerAllowed(peer: Peer, expected_uid: u32) bool {
    return peer.uid == expected_uid;
}

/// The argv a shell command becomes in the guest. Built here so the daemon and
/// its tests agree on exactly one spelling.
pub fn shellArgv(allocator: std.mem.Allocator, command: []const u8) ![]const []const u8 {
    const argv = try allocator.alloc([]const u8, 3);
    errdefer allocator.free(argv);
    argv[0] = guest_shell;
    argv[1] = "-c";
    argv[2] = command;
    return argv;
}

const testing = std.testing;

test "logNameValid: a minted name passes, a path or a traversal fails" {
    try testing.expect(logNameValid("bg_1712345678901.log"));
    try testing.expect(logNameValid("a"));
    try testing.expect(logNameValid("job-1.log"));

    try testing.expect(!logNameValid(""));
    try testing.expect(!logNameValid("."));
    try testing.expect(!logNameValid(".."));
    try testing.expect(!logNameValid("../../etc/shadow"));
    try testing.expect(!logNameValid("sub/bg.log"));
    try testing.expect(!logNameValid(".hidden"));
    try testing.expect(!logNameValid("bg..log"));
    try testing.expect(!logNameValid("bg log"));
    try testing.expect(!logNameValid(&[_]u8{'a'} ** (max_log_name_len + 1)));
}

test "guestJobLogPath: the name alone places the file, and nothing escapes the dir" {
    const allocator = testing.allocator;
    const path = try guestJobLogPath(allocator, "bg_7.log");
    defer allocator.free(path);
    try testing.expectEqualStrings("/tmp/pabrik/bg_7.log", path);

    try testing.expectError(error.InvalidLogName, guestJobLogPath(allocator, "../../etc/passwd"));
    try testing.expectError(error.InvalidLogName, guestJobLogPath(allocator, "/etc/shadow"));
}

test "logNameFromPath: only a path this daemon could have minted yields a name" {
    try testing.expectEqualStrings("bg_7.log", logNameFromPath("/tmp/pabrik/bg_7.log").?);
    try testing.expect(logNameFromPath("/tmp/pabrik") == null);
    try testing.expect(logNameFromPath("/tmp/pabrik/sub/bg.log") == null);
    try testing.expect(logNameFromPath("/tmp/pabrik/../etc/shadow") == null);
    try testing.expect(logNameFromPath("/workspace/bg_7.log") == null);
    try testing.expect(logNameFromPath("/tmp/pabrik/") == null);
}

test "workspaceIdValid: real ids pass, anything path-shaped fails" {
    try testing.expect(workspaceIdValid("demo"));
    try testing.expect(workspaceIdValid("ws_1785055733544_28e79c9db8950100"));
    try testing.expect(workspaceIdValid("ws-1"));

    try testing.expect(!workspaceIdValid(""));
    try testing.expect(!workspaceIdValid(".."));
    try testing.expect(!workspaceIdValid("../ws"));
    try testing.expect(!workspaceIdValid("ws/1"));
    try testing.expect(!workspaceIdValid("/etc/passwd"));
    try testing.expect(!workspaceIdValid("ws 1"));
    try testing.expect(!workspaceIdValid("ws\u{0000}"));
    try testing.expect(!workspaceIdValid(&[_]u8{'a'} ** (max_workspace_id_len + 1)));
}

test "cwdRelValid: only a relative path inside the workspace is accepted" {
    try testing.expect(cwdRelValid(""));
    try testing.expect(cwdRelValid("src"));
    try testing.expect(cwdRelValid("src/modules/agent"));

    try testing.expect(!cwdRelValid("/etc"));
    try testing.expect(!cwdRelValid(".."));
    try testing.expect(!cwdRelValid("../etc"));
    try testing.expect(!cwdRelValid("src/../../etc"));
    try testing.expect(!cwdRelValid("src/./x"));
    try testing.expect(!cwdRelValid("src//x"));
    try testing.expect(!cwdRelValid("src/"));
    try testing.expect(!cwdRelValid("a\\b"));
}

test "guestCwd joins under the root and never escapes it" {
    const allocator = testing.allocator;
    const at_root = try guestCwd(allocator, guest_root, "");
    defer allocator.free(at_root);
    try testing.expectEqualStrings("/workspace", at_root);

    const nested = try guestCwd(allocator, guest_root, "src/agent");
    defer allocator.free(nested);
    try testing.expectEqualStrings("/workspace/src/agent", nested);

    try testing.expectError(error.InvalidCwdRel, guestCwd(allocator, guest_root, "../../etc"));
    try testing.expectError(error.InvalidCwdRel, guestCwd(allocator, guest_root, "/etc"));
}

test "relativeToRoot maps a host cwd into the guest, refusing anything outside" {
    const root = "/home/you/proj";
    try testing.expectEqualStrings("", relativeToRoot(root, "/home/you/proj").?);
    try testing.expectEqualStrings("src", relativeToRoot(root, "/home/you/proj/src").?);
    try testing.expectEqualStrings("a/b", relativeToRoot(root, "/home/you/proj/a/b").?);
    try testing.expectEqualStrings("", relativeToRoot("/home/you/proj/", "/home/you/proj").?);

    try testing.expect(relativeToRoot(root, "/home/you") == null);
    try testing.expect(relativeToRoot(root, "/home/you/proj-other") == null);
    try testing.expect(relativeToRoot(root, "/etc") == null);
    try testing.expect(relativeToRoot("", "/etc") == null);
}

test "peerAllowed: only the expected uid is allowed through" {
    const mine = Peer{ .pid = 4242, .uid = 1000, .gid = 1000 };
    try testing.expect(peerAllowed(mine, 1000));

    const other = Peer{ .pid = 4243, .uid = 0, .gid = 0 };
    try testing.expect(!peerAllowed(other, 1000));
    try testing.expect(!peerAllowed(mine, 0));
}

test "shellArgv runs the command through the guest shell" {
    const allocator = testing.allocator;
    const argv = try shellArgv(allocator, "echo hi");
    defer allocator.free(argv);
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings("/bin/sh", argv[0]);
    try testing.expectEqualStrings("-c", argv[1]);
    try testing.expectEqualStrings("echo hi", argv[2]);
}

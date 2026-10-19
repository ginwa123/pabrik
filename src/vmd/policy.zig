//! The rules that make `pabrik-vmd`'s RPC safe: the request names a workspace
//! id and an action, and every path is derived from that id by these functions.
//! Pure and platform-free, so the policy is tested on every host.

const std = @import("std");

pub const max_workspace_id_len = 64;
pub const max_cwd_rel_len = 1024;
pub const guest_root = "/workspace";
pub const guest_shell = "/bin/sh";
/// The git and ripgrep the sealed image ships. `execve` searches no PATH, so
/// a guest program is named by its absolute path or not at all.
pub const guest_git = "/usr/bin/git";
pub const guest_rg = "/usr/bin/rg";

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

/// A cwd in EITHER vocabulary: the guest's own root (`/workspace…`) or a host
/// path under `root`. Anything else is refused, never rewritten.
pub fn relativeWorkspace(root: []const u8, cwd: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, cwd, guest_root)) return "";
    const prefix = guest_root ++ "/";
    if (std.mem.startsWith(u8, cwd, prefix)) {
        const rel = cwd[prefix.len..];
        return if (cwdRelValid(rel)) rel else null;
    }
    return relativeToRoot(root, cwd);
}

// ─── interactive terminals ───────────────────────────────────────────────

/// A tty gets its OWN vsock port (`tty_port_base + tty_id`): the agent serves one
/// connection at a time, so a terminal sharing it would freeze behind any `exec`.
pub const tty_port_base: u32 = 5100;
/// Concurrent terminals per VM. Each one is a guest process plus a vsock
/// listener, so the ceiling is about fds, not taste.
pub const max_ttys: u32 = 8;
/// One read or write piece. The guest's frame cap is 64 KiB and base64 costs
/// four bytes per three, so a piece this size always fits.
pub const max_tty_chunk: usize = 32 * 1024;
pub const min_tty_dim: u16 = 2;
pub const max_tty_dim: u16 = 1000;

pub fn ttyIdValid(id: i64) bool {
    return id >= 0 and id < @as(i64, @intCast(max_ttys));
}

/// The guest port a tty id listens on, or null when the id is not one this
/// daemon could have handed out.
pub fn ttyPort(id: i64) ?u32 {
    if (!ttyIdValid(id)) return null;
    return tty_port_base + @as(u32, @intCast(id));
}

pub fn ttyDimValid(cols: u16, rows: u16) bool {
    return cols >= min_tty_dim and cols <= max_tty_dim and
        rows >= min_tty_dim and rows <= max_tty_dim;
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

test "relativeWorkspace: the guest root and a host path both resolve, escape does not" {
    const root = "/home/you/proj";
    try testing.expectEqualStrings("", relativeWorkspace(root, "/workspace").?);
    try testing.expectEqualStrings("src", relativeWorkspace(root, "/workspace/src").?);
    try testing.expectEqualStrings("a/b", relativeWorkspace(root, "/workspace/a/b").?);

    try testing.expectEqualStrings("", relativeWorkspace(root, "/home/you/proj").?);
    try testing.expectEqualStrings("src", relativeWorkspace(root, "/home/you/proj/src").?);

    try testing.expect(relativeWorkspace(root, "/workspaces") == null);
    try testing.expect(relativeWorkspace(root, "/workspace/../etc") == null);
    try testing.expect(relativeWorkspace(root, "/etc") == null);
}

test "ttyPort: every legal id maps to its own port and nothing else does" {
    try testing.expectEqual(@as(?u32, 5100), ttyPort(0));
    try testing.expectEqual(@as(?u32, 5107), ttyPort(7));
    try testing.expect(ttyPort(-1) == null);
    try testing.expect(ttyPort(@intCast(max_ttys)) == null);
    try testing.expect(ttyIdValid(0));
    try testing.expect(!ttyIdValid(-1));
}

test "ttyDimValid: the window size bounds are inclusive and symmetric" {
    try testing.expect(ttyDimValid(80, 24));
    try testing.expect(ttyDimValid(min_tty_dim, max_tty_dim));
    try testing.expect(!ttyDimValid(min_tty_dim - 1, 24));
    try testing.expect(!ttyDimValid(80, max_tty_dim + 1));
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

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Resolve `~/.config/pabrik/agent.db`, creating the directory tree with
/// `mkdir -p` semantics if it does not yet exist.
///
/// On a fresh `$HOME` (a brand-new user's first run, or a CI runner with
/// an isolated tempdir as `$HOME`), neither `.config` nor `pabrik` exists.
/// The previous implementation called `Dir.createDirAbsolute` which only
/// creates the FINAL path component — `mkdir(/$HOME/.config/pabrik)` returns
/// ENOENT if `/$HOME/.config` does not yet exist. The fix is to open
/// `$HOME` as a `Dir` and call `Dir.createDirPath` which walks the
/// components and creates each one (true `mkdir -p` semantics).
///
/// Cross-platform note: the `~/.config/pabrik/` path is what the rest of
/// the pabrik codebase already uses for `agent.db`. On macOS, `Config.zig`
/// stores `config.json` under `$HOME/Library/Application Support/pabrik/`
/// per platform convention, but the DB lives in `~/.config/pabrik/` on ALL
/// platforms (this is the project's established convention — see
/// `helpers.db_path.getDbPath` callers in `main.zig:60`).
pub fn getDbPath(allocator: std.mem.Allocator, io: std.Io, environment: *std.process.Environ.Map) ![:0]const u8 {
    // On POSIX systems, the canonical user-home env var is `HOME`. On
    // Windows, Git Bash sets `HOME` (typically to %USERPROFILE%), so
    // the POSIX path covers most cases — including the CI smoke test,
    // which runs inside Git Bash on windows-latest runners. As a
    // safety net for native-Windows invocations (where `HOME` may
    // not be set), fall back to `USERPROFILE` (Windows' canonical
    // user-home variable). Only used if HOME is missing or empty.
    const home = blk: {
        if (environment.get("HOME")) |h| {
            if (h.len > 0) break :blk h;
        }
        if (environment.get("USERPROFILE")) |u| {
            if (u.len > 0) break :blk u;
        }
        std.log.err("Failed to get HOME/USERPROFILE environment variable", .{});
        return error.FailedToGetHome;
    };

    // `home` is fed to `openDirAbsolute` below, which ASSERTS the path is
    // absolute and ABORTS the whole process (Debug/ReleaseSafe) instead of
    // returning an error — a relative HOME/USERPROFILE would make pabrik
    // un-startable with no actionable message.
    if (!std.fs.path.isAbsolute(home)) {
        std.log.err("HOME/USERPROFILE is not an absolute path: {s}", .{home});
        return error.FailedToGetHome;
    }

    const config_dir = try std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".config",
        "pabrik",
    });
    defer allocator.free(config_dir);

    // mkdir -p semantics: open HOME as a Dir and createDirPath the rest.
    // If the directory already exists (e.g. when LlmConfig.init's
    // `writeDefaultConfig` ran first and created `$HOME/.config/pabrik`
    // via `createDirPath`), this is a no-op — `createDirPath`
    // returns Ok when the leaf already exists.
    var home_dir = Io.Dir.openDirAbsolute(io, home, .{}) catch |err| {
        std.log.err("Failed to open HOME directory {s}: {s}", .{ home, @errorName(err) });
        return err;
    };
    defer home_dir.close(io);
    home_dir.createDirPath(io, ".config/pabrik") catch |err| {
        std.log.err("Failed to create config directory {s}: {s}", .{ config_dir, @errorName(err) });
        return err;
    };

    const db_path = try std.fs.path.join(allocator, &[_][]const u8{
        config_dir,
        "agent.db",
    });
    defer allocator.free(db_path);

    // Whoever resolves the path is what registers it as protected. The agent's
    // command guard and read guard ask the registry below about THIS string,
    // so the two can never disagree about which file is the credential store.
    setProtectedPaths(db_path);

    return try allocator.dupeZ(u8, db_path);
}

// ============================================================================
// File modes
// ============================================================================

/// The database file names inside the config dir, including the two SQLite
/// sidecars. `-wal` and `-shm` hold the same pages as `agent.db` until a
/// checkpoint, so they need the same mode — protecting the main file alone
/// would leave the newest writes world-readable.
pub const db_file_names = [_][]const u8{ "agent.db", "agent.db-wal", "agent.db-shm" };

/// Narrow the config directory to `0700` and the database files to `0600`.
///
/// WHY. `createDirPath` above creates `~/.config/pabrik` with the process
/// umask (`0755` on a default Linux host) and SQLite creates `agent.db` with
/// `0644`. That file holds the LLM `api_key`, the MCP header values and every
/// workspace secret, so on any shared host — a build box, a dev VM, a
/// container with a mounted home — every local account can read them with one
/// `sqlite3` call. The mode bits are the complete fix for that reader and cost
/// nothing; encryption (the next phase) is what covers the *other* readers.
///
/// BEST-EFFORT and never fatal: a filesystem without POSIX modes must still
/// boot, and failing to narrow a mode is not a reason to refuse to serve. Every
/// failure is logged, so a silent no-op stays visible.
///
/// `db_path` is the absolute path from `getDbPath`; the directory and the three
/// names are derived from it so there is no second copy of the layout to drift.
pub fn restrictDbPermissions(io: Io, db_path: []const u8) void {
    switch (builtin.os.tag) {
        // No mode bits exist to set: `%APPDATA%` inherits the user's ACL,
        // which is already the right answer there.
        .windows => {},
        else => restrictDbPermissionsPosix(io, db_path),
    }
}

fn restrictDbPermissionsPosix(io: Io, db_path: []const u8) void {
    const config_dir = std.fs.path.dirname(db_path) orelse {
        std.log.warn("db_path: cannot derive a directory from {s}; modes left unchanged", .{db_path});
        return;
    };

    var dir = Io.Dir.openDirAbsolute(io, config_dir, .{ .iterate = true }) catch |err| {
        std.log.warn("db_path: cannot open {s} to narrow its mode: {s}", .{ config_dir, @errorName(err) });
        return;
    };
    defer dir.close(io);

    dir.setPermissions(io, Io.File.Permissions.fromMode(0o700)) catch |err| {
        std.log.warn("db_path: cannot set 0700 on {s}: {s}", .{ config_dir, @errorName(err) });
    };

    for (db_file_names) |name| {
        dir.setFilePermissions(io, name, Io.File.Permissions.fromMode(0o600), .{}) catch |err| switch (err) {
            // The two sidecars exist only while a connection has WAL open, so
            // FileNotFound is the ordinary case for them, not a fault.
            error.FileNotFound => {},
            else => std.log.warn("db_path: cannot set 0600 on {s}/{s}: {s}", .{ config_dir, name, @errorName(err) }),
        };
    }
}

// ============================================================================
// The protected-path registry
// ============================================================================

/// The absolute config directory and database path the running process must
/// not let the agent read. Registered once by `getDbPath`; read by the
/// `command` and `read_file` guards.
///
/// WHY A RESOLVED PATH AND NOT A PATTERN. The obvious guard — refuse any
/// command containing "agent.db" or "workspace_secrets" — also refuses
/// `rg agent.db src/`, which is a legitimate thing for an agent to do in this
/// repository, where both strings appear all over the source and the docs. A
/// guard that breaks real work gets deleted, so it is worse than none. Matching
/// the RESOLVED absolute path has no such false positive: nothing legitimate
/// names `/home/<user>/.config/pabrik/agent.db` on a command line.
///
/// THE HONEST LIMITATION, so this is not mistaken for a sandbox: a command that
/// assembles the path at runtime (`cd ~/.config/pabrik && …`), or reads the
/// file through another process, is not caught. It raises the cost of the
/// one-liner; it does not close the door. At-rest encryption is the control
/// that does.
///
/// Written once during boot, before any agent runs, and read afterwards — so
/// the unsynchronised read has no writer left to race with.
var protected_dir: [std.fs.max_path_bytes]u8 = undefined;
var protected_dir_len: usize = 0;
var protected_file: [std.fs.max_path_bytes]u8 = undefined;
var protected_file_len: usize = 0;

/// Record the paths to protect. Called from `getDbPath`.
pub fn setProtectedPaths(db_path: []const u8) void {
    const dir = std.fs.path.dirname(db_path) orelse return;
    if (dir.len > protected_dir.len or db_path.len > protected_file.len) return;
    @memcpy(protected_dir[0..dir.len], dir);
    protected_dir_len = dir.len;
    @memcpy(protected_file[0..db_path.len], db_path);
    protected_file_len = db_path.len;
}

/// Forget the registered paths. For tests: the registry is process-global, and
/// a test that set it would otherwise leak into every later test in the same
/// binary (the suite runs thousands of them in one process).
pub fn clearProtectedPaths() void {
    protected_dir_len = 0;
    protected_file_len = 0;
}

/// Whether `text` names the protected config directory or database file.
/// False when nothing has been registered, which is the case in any context
/// that never resolved a database path.
pub fn mentionsProtectedPath(text: []const u8) bool {
    if (protected_dir_len == 0) return false;
    if (std.mem.indexOf(u8, text, protected_dir[0..protected_dir_len]) != null) return true;
    return std.mem.indexOf(u8, text, protected_file[0..protected_file_len]) != null;
}

/// Whether `path` IS the protected database file, IS the config directory, or
/// lies inside it. Used by the `read_file` guard, where the argument is a path
/// rather than a shell string.
pub fn isProtectedPath(path: []const u8) bool {
    if (protected_dir_len == 0) return false;

    const dir = protected_dir[0..protected_dir_len];
    if (std.mem.eql(u8, path, dir)) return true;
    if (std.mem.eql(u8, path, protected_file[0..protected_file_len])) return true;

    // Containment, with the separator required — otherwise a sibling directory
    // whose name merely starts the same way (`…/pabrik-backup`) would be caught.
    if (path.len > dir.len and std.mem.startsWith(u8, path, dir)) {
        const next = path[dir.len];
        if (next == '/' or next == '\\') return true;
    }
    return false;
}

test "the protected-path registry matches the resolved dir and file, and nothing else" {
    defer clearProtectedPaths();
    setProtectedPaths("/home/u/.config/pabrik/agent.db");

    // The registry is about the RESOLVED path, so both the directory and the
    // file are protected, however the caller spells them.
    try std.testing.expect(mentionsProtectedPath("sqlite3 /home/u/.config/pabrik/agent.db 'select 1'"));
    try std.testing.expect(mentionsProtectedPath("ls -la /home/u/.config/pabrik"));
    try std.testing.expect(isProtectedPath("/home/u/.config/pabrik/agent.db"));
    try std.testing.expect(isProtectedPath("/home/u/.config/pabrik/agent.db-wal"));
    try std.testing.expect(isProtectedPath("/home/u/.config/pabrik"));

    // The false positives that would get this guard deleted: naming the file,
    // the table or a sibling directory in ordinary work.
    try std.testing.expect(!mentionsProtectedPath("rg -n 'agent.db' src/"));
    try std.testing.expect(!mentionsProtectedPath("grep -rn workspace_secrets src/"));
    try std.testing.expect(!mentionsProtectedPath("sqlite3 /tmp/other.db 'select 1'"));
    try std.testing.expect(!isProtectedPath("/home/u/.config/pabrik-backup/agent.db"));
    try std.testing.expect(!isProtectedPath("/home/u/.config/other/agent.db"));

    // Unregistered means unguarded, which is what keeps unit tests and any
    // path-less context from suddenly refusing commands.
    clearProtectedPaths();
    try std.testing.expect(!mentionsProtectedPath("/home/u/.config/pabrik/agent.db"));
    try std.testing.expect(!isProtectedPath("/home/u/.config/pabrik/agent.db"));
}

test "setProtectedPaths ignores a path it cannot hold" {
    defer clearProtectedPaths();
    setProtectedPaths("/home/u/.config/pabrik/agent.db");
    // A path longer than the buffer must leave the registry as it was rather
    // than truncating it into a string that protects the wrong directory.
    const huge = "a" ** (std.fs.max_path_bytes + 1);
    setProtectedPaths(huge);
    try std.testing.expect(mentionsProtectedPath("/home/u/.config/pabrik/agent.db"));
}

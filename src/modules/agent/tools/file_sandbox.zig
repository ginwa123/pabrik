//! `file_sandbox` — ONE rule for "may this file be shown to the browser?".
//!
//! Two callers must agree, and they used to disagree:
//!
//!   1. `present_files` (agent tool, `present_files.zig`) — builds the card.
//!   2. `GET /api/files/download` (`http_handlers/files_download.zig`) —
//!      serves the bytes the card's preview / download link fetches.
//!
//! Before this module the tool accepted any absolute path while the handler
//! 403'd anything that did not canonicalize inside the session working
//! directory, so the tool could emit a card whose every fetch failed with
//! `{"error":"Path escapes the session working directory"}` (reproduced on
//! Windows with an agent-written report under `C:\Users\<user>\Downloads\`).
//! Both sides now import these helpers, so a card the tool accepts is a card
//! the endpoint serves.
//!
//! Path style is an explicit `PathStyle` parameter, never `builtin.os.tag`
//! read inside a function: a native-only branch would be dead code that CI on
//! Linux never analyses, and the Windows half of this module is exactly where
//! the bug lived. Call sites pass `nativeStyle()`, tests pass `.windows` on any
//! host. Plan: docs/plans/2026-09-29-present-files-sandbox-parity.md

const std = @import("std");
const builtin = @import("builtin");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;

const testing = std.testing;

// ─── Implementation ─────────────────────────────────────────────────────

/// Which path grammar the two compared paths are written in. Passed in
/// explicitly (call sites use `nativeStyle()`) rather than read from
/// `builtin.os.tag` inside the helpers, so the Windows rules are analysed
/// and unit-tested by the Linux/macOS CI that has the most runs.
pub const PathStyle = enum { posix, windows };

pub fn nativeStyle() PathStyle {
    return if (builtin.os.tag == .windows) .windows else .posix;
}

fn isSep(c: u8, style: PathStyle) bool {
    return switch (style) {
        .posix => c == '/',
        .windows => c == '/' or c == '\\',
    };
}

/// Drop the Win32 "extended-length" prefix that
/// `GetFinalPathNameByHandle` (i.e. `realPathFileAbsolute`) returns, so a
/// canonicalized path compares equal to the same path as the session row
/// spells it: `\\?\C:\work` ≡ `C:\work`, `\\?\UNC\srv\share` ≡ `\\srv\share`.
/// Strip the leading path-form markers so two spellings of the same Windows
/// location compare equal:
///
///   `\\?\C:\work`       → `C:\work`
///   `\\?\UNC\srv\share` → `srv\share`
///   `\\srv\share`       → `srv\share`   (windows style only)
///
/// A plain `\\` is stripped only under the windows style — on posix a
/// leading backslash is an ordinary filename character.
///
/// `realPathFileAbsolute` returns the `\\?\` form on Windows (it is
/// `GetFinalPathNameByHandle` output) while the session row spells the
/// directory the plain way, so the two sides of the containment check
/// routinely differ by exactly this prefix.
fn stripLeadingMarkers(path: []const u8, style: PathStyle) []const u8 {
    if (std.mem.startsWith(u8, path, "\\\\?\\UNC\\")) return path["\\\\?\\UNC\\".len..];
    if (std.mem.startsWith(u8, path, "\\\\?\\")) return path["\\\\?\\".len..];
    if (style == .windows and std.mem.startsWith(u8, path, "\\\\")) return path[2..];
    return path;
}

/// Trailing separators carry no meaning for a containment check, but a
/// drive root does: `C:\` must not degrade to the drive-relative `C:`.
fn trimTrailingSeparators(path: []const u8, style: PathStyle) []const u8 {
    var end = path.len;
    while (end > 1 and isSep(path[end - 1], style)) {
        if (path[end - 2] == ':') break;
        end -= 1;
    }
    return path[0..end];
}

/// Byte-for-byte prefix comparison with the two Windows relaxations folded
/// in: case-insensitivity, and `/` ≡ `\` (a session row may spell the root
/// `C:/Users/...` while the canonicalized target is `C:\Users\...`).
fn prefixMatches(a: []const u8, b: []const u8, style: PathStyle) bool {
    for (a, b) |ca, cb| {
        const same = switch (style) {
            .posix => ca == cb,
            .windows => std.ascii.toLower(ca) == std.ascii.toLower(cb) or (isSep(ca, style) and isSep(cb, style)),
        };
        if (!same) return false;
    }
    return true;
}

/// True when `resolved` is `root` itself or lives under it.
///
/// Two rules beyond a byte prefix, both of which have bitten this codebase:
///   * the next character after the root must be a separator, so `/tmp/abc`
///     never matches `/tmp/abcd/secret.txt`;
///   * on Windows the comparison is case-insensitive (paths are), because
///     the root comes from the DB and the target from the filesystem
///     canonicalizer, and the two disagree on the on-disk casing.
pub fn isInsideRoot(root: []const u8, resolved: []const u8, style: PathStyle) bool {
    const r = trimTrailingSeparators(stripLeadingMarkers(root, style), style);
    if (r.len == 0) return false;
    const t = trimTrailingSeparators(stripLeadingMarkers(resolved, style), style);
    if (t.len == 0) return false;

    const n = @min(r.len, t.len);
    if (!prefixMatches(r[0..n], t[0..n], style)) return false;
    // A root that already ends in a separator is a filesystem root (`/`),
    // a drive root (`C:\`) or a UNC share root — everything below matches.
    if (isSep(r[r.len - 1], style)) return true;
    if (t.len == r.len) return true;
    if (t.len < r.len) return false;
    return isSep(t[r.len], style);
}

/// True when any path segment is exactly `..`. Both separators are split
/// on, so a Windows path is not judged by posix rules. `..` inside a
/// filename (`report..html`, `..hidden`) is NOT a traversal.
pub fn hasParentSegment(path: []const u8) bool {
    var outer = std.mem.splitScalar(u8, path, '/');
    while (outer.next()) |segment| {
        var inner = std.mem.splitScalar(u8, segment, '\\');
        while (inner.next()) |part| {
            if (std.mem.eql(u8, part, "..")) return true;
        }
    }
    return false;
}

/// `std.fs.path.isAbsolute` for an explicit style, so the Windows rules are
/// reachable from a posix test run. Note the drive-relative form `C:x` is
/// NOT absolute — it resolves against the process's per-drive current
/// directory, and passing it to `realPathFileAbsolute` (whose assert aborts
/// the process) is exactly what must never happen.
pub fn isAbsoluteFor(path: []const u8, style: PathStyle) bool {
    return switch (style) {
        .posix => std.fs.path.isAbsolutePosix(path),
        .windows => std.fs.path.isAbsoluteWindows(path),
    };
}

pub const ResolveError = error{
    /// The requested path is not absolute in this path style.
    NotAbsolute,
    /// The requested path contains a `..` segment.
    PathTraversal,
    /// The sandbox root is not absolute — feeding it to realPath would abort.
    RootNotAbsolute,
    /// The sandbox root does not exist / is not reachable.
    RootUnreachable,
    /// The target file does not exist / is not reachable.
    TargetUnreachable,
    /// The target canonicalizes outside the sandbox root.
    OutsideRoot,
    OutOfMemory,
};

/// Canonicalize `path` and return it only if it lands inside `root`.
///
/// Order matters and is pinned by the tests below: shape errors (`..`,
/// non-absolute) are reported BEFORE any filesystem call, then the target is
/// canonicalized, then the root — so a missing file and a missing root stay
/// distinguishable, and a symlink pointing outside the root is caught
/// (canonical-vs-canonical is the only comparison that sees through it).
///
/// Returns an owned `[]u8` the caller frees.
pub fn resolveInsideRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    path: []const u8,
    style: PathStyle,
) ResolveError![]u8 {
    if (!isAbsoluteFor(path, style)) return error.NotAbsolute;
    if (hasParentSegment(path)) return error.PathTraversal;
    if (!isAbsoluteFor(root, native)) return error.RootNotAbsolute;

    const target_z = std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator) catch return error.TargetUnreachable;
    defer allocator.free(target_z);
    const root_z = std.Io.Dir.realPathFileAbsoluteAlloc(io, root, allocator) catch return error.RootUnreachable;
    defer allocator.free(root_z);

    if (!isInsideRoot(root_z, target_z, style)) return error.OutsideRoot;
    return allocator.dupe(u8, target_z) catch return error.OutOfMemory;
}

pub const SessionRootError = error{
    SessionNotFound,
    NoWorkingDirectory,
    OutOfMemory,
    QueryFailed,
};

/// Resolve the session's sandbox root: `git_worktree_cwd` when set, else
/// `cwd`. Shared by the download handler and the `present_files` tool so
/// the two agree on what "inside the session working directory" means — the
/// disagreement is what produced cards that 403 on every fetch.
///
/// Returns an owned dupe the caller frees. Unknown session →
/// `SessionNotFound` (the handler maps it to 404); neither column set, or a
/// non-absolute value → `NoWorkingDirectory` (403 — fail closed rather than
/// serving unconstrained).
pub fn resolveSessionRoot(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) SessionRootError![]u8 {
    var rows = db.query(
        allocator,
        "SELECT COALESCE(git_worktree_cwd, ''), COALESCE(cwd, '') FROM sessions WHERE id = ?",
        &.{session_id},
    ) catch return error.QueryFailed;
    defer rows.deinit();

    const row_opt = rows.next() catch return error.QueryFailed;
    const row = row_opt orelse return error.SessionNotFound;
    defer row.deinit(allocator);

    const worktree_cwd = row.values[0];
    const cwd = row.values[1];
    const root = if (worktree_cwd.len > 0) worktree_cwd else cwd;
    if (root.len == 0) return error.NoWorkingDirectory;
    // `root` is later handed to `std.Io.Dir.realPathFileAbsoluteAlloc`, which
    // asserts `path.isAbsolute(...)`. That assertion ABORTS the whole process
    // (Debug/ReleaseSafe) rather than returning an error, and `sessions.cwd` is
    // NOT validated as absolute at every write path (e.g. a session created
    // with a relative `cwd_session`) — so refuse a non-absolute root here.
    if (!isAbsoluteFor(root, nativeStyle())) return error.NoWorkingDirectory;
    return allocator.dupe(u8, root) catch return error.OutOfMemory;
}

// ─── Tests ──────────────────────────────────────────────────────────────
//
// Written before the implementation. The FS-touching cases use
// `std.testing.tmpDir` (not a hardcoded `/tmp/...`, which is not absolute on
// Windows) plus `realPath`, so the same test runs on every CI OS.

/// Two sibling temp dirs, each with its realpath, plus a scratch file
/// writer. Used to express "inside" vs "outside" without assuming a
/// particular temp layout.
const Sandbox = struct {
    inside: std.testing.TmpDir,
    outside: std.testing.TmpDir,
    inside_abs: []const u8,
    outside_abs: []const u8,
    io: std.Io,

    fn deinit(self: *Sandbox, allocator: std.mem.Allocator) void {
        allocator.free(self.inside_abs);
        allocator.free(self.outside_abs);
        self.inside.cleanup();
        self.outside.cleanup();
    }

    /// Absolute path of `rel` under the "inside" dir.
    fn inPath(self: *const Sandbox, allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.inside_abs, rel });
    }

    /// Absolute path of `rel` under the sibling "outside" dir.
    fn outPath(self: *const Sandbox, allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.outside_abs, rel });
    }
};

fn realPathOf(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(testing.io, &buf);
    return allocator.dupe(u8, buf[0..n]);
}

fn setupSandbox(allocator: std.mem.Allocator) !Sandbox {
    var inside = testing.tmpDir(.{});
    errdefer inside.cleanup();
    var outside = testing.tmpDir(.{});
    errdefer outside.cleanup();
    const inside_abs = try realPathOf(allocator, inside.dir);
    errdefer allocator.free(inside_abs);
    const outside_abs = try realPathOf(allocator, outside.dir);
    return .{
        .inside = inside,
        .outside = outside,
        .inside_abs = inside_abs,
        .outside_abs = outside_abs,
        .io = testing.io,
    };
}

fn writeFileAt(dir: std.Io.Dir, io: std.Io, rel: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(rel)) |parent| try dir.createDirPath(io, parent);
    var file = try dir.createFile(io, rel, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

/// The style of the host running these tests, for the FS-touching cases
/// (the pure string cases below pin both styles explicitly).
const native = nativeStyle();

// ── isInsideRoot: posix ────────────────────────────────────────────────

test "isInsideRoot: posix accepts the root itself and any child" {
    try testing.expect(isInsideRoot("/tmp/abc", "/tmp/abc", .posix));
    try testing.expect(isInsideRoot("/tmp/abc", "/tmp/abc/file.txt", .posix));
    try testing.expect(isInsideRoot("/tmp/abc", "/tmp/abc/nested/deep/file.txt", .posix));
}

test "isInsideRoot: a sibling that shares the root's prefix is OUTSIDE" {
    // The reason for the boundary check: a bare `startsWith` would serve
    // /tmp/abcd/secret.txt as if it were /tmp/abc/secret.txt.
    try testing.expect(!isInsideRoot("/tmp/abc", "/tmp/abcd/secret.txt", .posix));
    try testing.expect(!isInsideRoot("/tmp/abc", "/tmp/abc-backup.tar", .posix));
}

test "isInsideRoot: an unrelated or parent path is outside" {
    try testing.expect(!isInsideRoot("/tmp/abc", "/etc/passwd", .posix));
    try testing.expect(!isInsideRoot("/tmp/abc", "/tmp", .posix));
    try testing.expect(!isInsideRoot("/tmp/abc/sub", "/tmp/abc", .posix));
    try testing.expect(!isInsideRoot("/tmp/abc", "tmp/abc/file.txt", .posix));
}

test "isInsideRoot: a root with a trailing separator still matches its children" {
    try testing.expect(isInsideRoot("/tmp/abc/", "/tmp/abc/file.txt", .posix));
    try testing.expect(isInsideRoot("/tmp/abc///", "/tmp/abc/", .posix));
}

test "isInsideRoot: the filesystem root contains everything under it" {
    try testing.expect(isInsideRoot("/", "/etc/passwd", .posix));
    try testing.expect(isInsideRoot("/", "/", .posix));
}

test "isInsideRoot: posix treats a backslash as an ordinary filename character" {
    // Pins that the Windows separator normalization is NOT applied to posix
    // paths — `a\b` is a single filename on Linux, and widening the
    // separator set here would let `root` match a sibling it does not own.
    try testing.expect(isInsideRoot("/tmp/abc", "/tmp/abc/we\\ird.txt", .posix));
    try testing.expect(!isInsideRoot("/tmp/abc", "/tmp/abc\\evil/file.txt", .posix));
}

test "isInsideRoot: posix is case-sensitive" {
    try testing.expect(!isInsideRoot("/tmp/ABC", "/tmp/abc/file.txt", .posix));
}

// ── isInsideRoot: windows ──────────────────────────────────────────────

test "isInsideRoot: windows accepts backslash and forward-slash children" {
    try testing.expect(isInsideRoot("C:\\work", "C:\\work", .windows));
    try testing.expect(isInsideRoot("C:\\work", "C:\\work\\report.html", .windows));
    try testing.expect(isInsideRoot("C:\\work", "C:/work/report.html", .windows));
    try testing.expect(isInsideRoot("C:\\work", "C:\\work\\sub\\report.html", .windows));
}

test "isInsideRoot: windows compares case-insensitively" {
    // Windows paths are case-insensitive, and the two sides of the
    // comparison are canonicalized by different code paths (the session row
    // vs GetFinalPathNameByHandle), so the on-disk casing can differ.
    try testing.expect(isInsideRoot("C:\\Users\\Gilang\\work", "c:\\users\\gilang\\work\\a.txt", .windows));
    try testing.expect(isInsideRoot("c:\\USERS\\gilang", "C:\\Users\\Gilang\\a.txt", .windows));
}

test "isInsideRoot: posix style is case-sensitive for the same pair" {
    try testing.expect(!isInsideRoot("/tmp/ABC", "/tmp/abc/file.txt", .posix));
}

test "isInsideRoot: windows strips the \\\\?\\ verbatim prefix on either side" {
    // realPathFileAbsolute on Windows returns GetFinalPathNameByHandle output
    // (`\\?\C:\...`); a root taken from the DB may not carry the prefix.
    try testing.expect(isInsideRoot("\\\\?\\C:\\work", "C:\\work\\a.txt", .windows));
    try testing.expect(isInsideRoot("C:\\work", "\\\\?\\C:\\work\\a.txt", .windows));
    try testing.expect(isInsideRoot("\\\\?\\C:\\work", "\\\\?\\C:\\work\\a.txt", .windows));
    try testing.expect(isInsideRoot("\\\\?\\c:\\WORK", "\\\\?\\C:\\work\\a.txt", .windows));
}

test "isInsideRoot: windows maps a verbatim UNC prefix back to the UNC form" {
    try testing.expect(isInsideRoot("\\\\?\\UNC\\server\\share", "\\\\server\\share\\a.txt", .windows));
    try testing.expect(isInsideRoot("\\\\server\\share", "\\\\?\\UNC\\server\\share\\a.txt", .windows));
    try testing.expect(!isInsideRoot("\\\\server\\share", "\\\\server\\share-other\\a.txt", .windows));
}

test "isInsideRoot: windows rejects another drive, a sibling prefix, and the parent" {
    try testing.expect(!isInsideRoot("C:\\work", "D:\\work\\a.txt", .windows));
    try testing.expect(!isInsideRoot("C:\\work", "C:\\workspace\\a.txt", .windows));
    try testing.expect(!isInsideRoot("C:\\work\\sub", "C:\\work", .windows));
    try testing.expect(!isInsideRoot("C:\\work", "C:\\work-backup\\a.txt", .windows));
}

test "isInsideRoot: windows drive root contains the whole drive" {
    try testing.expect(isInsideRoot("C:\\", "C:\\work\\a.txt", .windows));
    try testing.expect(isInsideRoot("C:\\", "C:\\", .windows));
    try testing.expect(!isInsideRoot("C:\\", "D:\\work\\a.txt", .windows));
}

// ── hasParentSegment ───────────────────────────────────────────────────

test "hasParentSegment: finds a parent segment behind either separator" {
    try testing.expect(hasParentSegment("/a/../b"));
    try testing.expect(hasParentSegment("/a/b/.."));
    try testing.expect(hasParentSegment("C:\\a\\..\\b"));
    try testing.expect(hasParentSegment("C:/a/../b"));
    try testing.expect(hasParentSegment(".."));
    try testing.expect(hasParentSegment("../a"));
}

test "hasParentSegment: a dot-dot inside a filename is not a traversal" {
    try testing.expect(!hasParentSegment("/tmp/report..html"));
    try testing.expect(!hasParentSegment("C:\\tmp\\..hidden"));
    try testing.expect(!hasParentSegment("C:\\tmp\\a..b..c.txt"));
    try testing.expect(!hasParentSegment("/tmp/plain.txt"));
    try testing.expect(!hasParentSegment(""));
}

// ── isAbsoluteFor ──────────────────────────────────────────────────────

test "isAbsoluteFor: posix accepts /x and rejects x" {
    try testing.expect(isAbsoluteFor("/x", .posix));
    try testing.expect(isAbsoluteFor("/x/y.txt", .posix));
    try testing.expect(!isAbsoluteFor("x", .posix));
    try testing.expect(!isAbsoluteFor("x/y.txt", .posix));
    try testing.expect(!isAbsoluteFor("", .posix));
}

test "isAbsoluteFor: posix rejects a Windows drive path" {
    // A `C:\...` path handed to a Linux pabrik is not a path on this host —
    // treating it as absolute is how a "present" card becomes a 404.
    try testing.expect(!isAbsoluteFor("C:\\Users\\gilang\\Downloads\\r.html", .posix));
    try testing.expect(!isAbsoluteFor("\\\\?\\C:\\work", .posix));
}

test "isAbsoluteFor: windows accepts drive, UNC and rooted forms" {
    try testing.expect(isAbsoluteFor("C:\\work\\a.txt", .windows));
    try testing.expect(isAbsoluteFor("c:/work/a.txt", .windows));
    try testing.expect(isAbsoluteFor("\\\\server\\share\\a.txt", .windows));
    try testing.expect(isAbsoluteFor("\\\\?\\C:\\work", .windows));
    try testing.expect(isAbsoluteFor("\\work\\a.txt", .windows));
}

test "isAbsoluteFor: windows rejects drive-relative and plain relative paths" {
    // `C:x` resolves against the process's per-drive current directory, so
    // it is NOT absolute and must not be handed to realPath (whose assert
    // aborts the process rather than returning an error).
    try testing.expect(!isAbsoluteFor("C:x", .windows));
    try testing.expect(!isAbsoluteFor("x", .windows));
    try testing.expect(!isAbsoluteFor("", .windows));
}

// ── resolveInsideRoot (real filesystem) ─────────────────────────────────

test "resolveInsideRoot: a file inside the root resolves to its canonical path" {
    const alloc = testing.allocator;
    var sb = try setupSandbox(alloc);
    defer sb.deinit(alloc);
    try writeFileAt(sb.inside.dir, sb.io, "report.html", "<h1>hi</h1>");

    const path = try sb.inPath(alloc, "report.html");
    defer alloc.free(path);

    const canon = try resolveInsideRoot(sb.io, alloc, sb.inside_abs, path, native);
    defer alloc.free(canon);
    try testing.expect(std.mem.endsWith(u8, canon, "report.html"));
}

test "resolveInsideRoot: a nested file inside the root is allowed" {
    const alloc = testing.allocator;
    var sb = try setupSandbox(alloc);
    defer sb.deinit(alloc);
    try writeFileAt(sb.inside.dir, sb.io, "sub/deep/data.json", "{}");

    const path = try sb.inPath(alloc, "sub/deep/data.json");
    defer alloc.free(path);
    const canon = try resolveInsideRoot(sb.io, alloc, sb.inside_abs, path, native);
    defer alloc.free(canon);
    try testing.expect(std.mem.endsWith(u8, canon, "data.json"));
}

test "resolveInsideRoot: a sibling dir outside the root is rejected" {
    // The reported Windows failure, expressed portably: the agent wrote
    // (or found) a file outside the session working directory.
    const alloc = testing.allocator;
    var sb = try setupSandbox(alloc);
    defer sb.deinit(alloc);
    try writeFileAt(sb.outside.dir, sb.io, "Downloads/report.html", "<h1>x</h1>");

    const path = try sb.outPath(alloc, "Downloads/report.html");
    defer alloc.free(path);

    try testing.expectError(error.OutsideRoot, resolveInsideRoot(sb.io, alloc, sb.inside_abs, path, native));
}

test "resolveInsideRoot: a parent segment is rejected even when it lands back inside" {
    const alloc = testing.allocator;
    var sb = try setupSandbox(alloc);
    defer sb.deinit(alloc);
    try writeFileAt(sb.outside.dir, sb.io, "elsewhere.txt", "x");
    const escaped = try std.fs.path.join(alloc, &.{ sb.inside_abs, "..", "escaped.txt" });
    defer alloc.free(escaped);

    try testing.expectError(error.PathTraversal, resolveInsideRoot(sb.io, alloc, sb.inside_abs, escaped, native));
}

test "resolveInsideRoot: a relative path is rejected before any fs call" {
    const alloc = testing.allocator;
    var sb = try setupSandbox(alloc);
    defer sb.deinit(alloc);
    try testing.expectError(error.NotAbsolute, resolveInsideRoot(sb.io, alloc, sb.inside_abs, "report.html", native));
}

test "resolveInsideRoot: a missing file is reported as unreachable, not as outside" {
    const alloc = testing.allocator;
    var sb = try setupSandbox(alloc);
    defer sb.deinit(alloc);
    const path = try sb.inPath(alloc, "nope.txt");
    defer alloc.free(path);
    try testing.expectError(error.TargetUnreachable, resolveInsideRoot(sb.io, alloc, sb.inside_abs, path, native));
}

test "resolveInsideRoot: a root that does not exist is reported separately" {
    const alloc = testing.allocator;
    var sb = try setupSandbox(alloc);
    defer sb.deinit(alloc);
    try writeFileAt(sb.inside.dir, sb.io, "a.txt", "x");
    const path = try sb.inPath(alloc, "a.txt");
    defer alloc.free(path);
    const missing_root = try std.fs.path.join(alloc, &.{ sb.inside_abs, "does-not-exist" });
    defer alloc.free(missing_root);

    try testing.expectError(error.RootUnreachable, resolveInsideRoot(sb.io, alloc, missing_root, path, native));
}

test "resolveInsideRoot: a relative root is rejected" {
    const alloc = testing.allocator;
    var sb = try setupSandbox(alloc);
    defer sb.deinit(alloc);
    try writeFileAt(sb.inside.dir, sb.io, "a.txt", "x");
    const path = try sb.inPath(alloc, "a.txt");
    defer alloc.free(path);

    try testing.expectError(error.RootNotAbsolute, resolveInsideRoot(sb.io, alloc, "relative/root", path, native));
}

test "resolveInsideRoot: a symlink pointing outside the root is rejected" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // symlinks need a privilege
    const alloc = testing.allocator;
    var sb = try setupSandbox(alloc);
    defer sb.deinit(alloc);
    try writeFileAt(sb.outside.dir, sb.io, "secret.txt", "s3cret");
    const secret = try sb.outPath(alloc, "secret.txt");
    defer alloc.free(secret);
    const link = try sb.inPath(alloc, "link.txt");
    defer alloc.free(link);
    try std.Io.Dir.symLinkAbsolute(sb.io, secret, link, .{});

    try testing.expectError(error.OutsideRoot, resolveInsideRoot(sb.io, alloc, sb.inside_abs, link, native));
}

test "resolveInsideRoot: a symlink that stays inside the root is allowed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var sb = try setupSandbox(alloc);
    defer sb.deinit(alloc);
    try writeFileAt(sb.inside.dir, sb.io, "real.txt", "ok");
    const real = try sb.inPath(alloc, "real.txt");
    defer alloc.free(real);
    const link = try sb.inPath(alloc, "link.txt");
    defer alloc.free(link);
    try std.Io.Dir.symLinkAbsolute(sb.io, real, link, .{});

    const canon = try resolveInsideRoot(sb.io, alloc, sb.inside_abs, link, native);
    defer alloc.free(canon);
    try testing.expect(std.mem.endsWith(u8, canon, "real.txt"));
}

// ── resolveSessionRoot (in-memory sqlite) ──────────────────────────────

const TestDb = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,

    fn deinit(self: *TestDb) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

fn setupDb() !TestDb {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // Column nullability matches production (Migration 046): both columns
    // are nullable, which is why the resolver COALESCEs them. Seeding `""`
    // through `db.exec` binds SQL NULL, so these tests also cover the
    // unbound-worktree shape a real row has.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  status TEXT NOT NULL DEFAULT 'active',
        \\  cwd TEXT,
        \\  git_worktree_cwd TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn seedSession(db: *sqlite.SqliteBackend, id: []const u8, cwd: []const u8, worktree: []const u8) !void {
    try db.exec(testing.allocator, "INSERT INTO sessions (id, name, cwd, git_worktree_cwd) VALUES (?, ?, ?, ?)", &.{ id, id, cwd, worktree });
}

test "resolveSessionRoot: prefers git_worktree_cwd over cwd" {
    var ctx = try setupDb();
    defer ctx.deinit();
    try seedSession(&ctx.db, "task_a", "/home/me/project", "/home/me/.worktrees/wt-a");

    const root = try resolveSessionRoot(testing.allocator, &ctx.db, "task_a");
    defer testing.allocator.free(root);
    try testing.expectEqualStrings("/home/me/.worktrees/wt-a", root);
}

test "resolveSessionRoot: falls back to cwd when no worktree is bound" {
    var ctx = try setupDb();
    defer ctx.deinit();
    try seedSession(&ctx.db, "task_b", "/home/me/project", "");

    const root = try resolveSessionRoot(testing.allocator, &ctx.db, "task_b");
    defer testing.allocator.free(root);
    try testing.expectEqualStrings("/home/me/project", root);
}

test "resolveSessionRoot: an unknown session is its own error (handler maps it to 404)" {
    var ctx = try setupDb();
    defer ctx.deinit();
    try testing.expectError(error.SessionNotFound, resolveSessionRoot(testing.allocator, &ctx.db, "task_missing"));
}

test "resolveSessionRoot: a session with no working directory fails closed" {
    var ctx = try setupDb();
    defer ctx.deinit();
    try seedSession(&ctx.db, "task_c", "", "");

    try testing.expectError(error.NoWorkingDirectory, resolveSessionRoot(testing.allocator, &ctx.db, "task_c"));
}

test "resolveSessionRoot: a relative cwd is refused, never handed to realPath" {
    // `realPathFileAbsolute` ASSERTS isAbsolute — in a safe build that
    // aborts the whole server instead of returning an error, so the guard
    // has to live here.
    var ctx = try setupDb();
    defer ctx.deinit();
    try seedSession(&ctx.db, "task_d", "relative/cwd", "");

    try testing.expectError(error.NoWorkingDirectory, resolveSessionRoot(testing.allocator, &ctx.db, "task_d"));
}

test "resolveSessionRoot: a Windows cwd is judged by the native path style" {
    // One body, every host. `resolveSessionRoot` reads the host's own
    // grammar (`nativeStyle()`) and hands the result to
    // `realPathFileAbsolute`, whose `isAbsolute` assert is a process abort
    // rather than an error — so a root the native grammar rejects has to be
    // refused here, and one it accepts has to come back unchanged.
    //
    // The switch is over `PathStyle`, the enum the SUT itself switches on,
    // so there is no "some other host" arm that could pass vacuously: a
    // third style would not compile until someone wrote its expectation
    // down. A `builtin.os.tag == .windows` early return would have been the
    // other shape — green on the host it did not name, having checked
    // nothing there.
    var ctx = try setupDb();
    defer ctx.deinit();
    try seedSession(&ctx.db, "task_e", "C:\\Users\\gilang\\project", "");

    switch (nativeStyle()) {
        .windows => {
            const root = try resolveSessionRoot(testing.allocator, &ctx.db, "task_e");
            defer testing.allocator.free(root);
            try testing.expectEqualStrings("C:\\Users\\gilang\\project", root);
        },
        .posix => {
            try testing.expectError(error.NoWorkingDirectory, resolveSessionRoot(testing.allocator, &ctx.db, "task_e"));
        },
    }
}

test "resolveSessionRoot: the resolved root is absolute for the native style" {
    // Whatever the host, the two callers must agree: the handler feeds this
    // string to realPathFileAbsolute, whose assert is a process abort.
    const alloc = testing.allocator;
    var sb = try setupSandbox(alloc);
    defer sb.deinit(alloc);
    var ctx = try setupDb();
    defer ctx.deinit();
    try seedSession(&ctx.db, "task_f", sb.inside_abs, "");

    const root = try resolveSessionRoot(alloc, &ctx.db, "task_f");
    defer alloc.free(root);
    try testing.expect(isAbsoluteFor(root, native));
}

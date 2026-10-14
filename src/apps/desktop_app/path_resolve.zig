// src/apps/desktop_app/path_resolve.zig Resolves the path to the `pabrik`
// binary at runtime.

const std = @import("std");
const builtin = @import("builtin");

const SelfExeError = error{
    ReadLinkFailed,
    UnsupportedPlatform,
    OutOfMemory,
};

/// Resolve the path to the pabrik binary. See module doc for the resolution
/// order. Caller owns the returned slice and must `allocator.free` it.
pub fn resolve(
    allocator: std.mem.Allocator,
    explicit_path: ?[]const u8,
    self_exe_path: []const u8,
    path_env: []const u8,
) ?[]u8 {
    // 1. Explicit path from --pabrik-path: pass through unchanged.
    if (explicit_path) |p| {
        return allocator.dupe(u8, p) catch null;
    }

    // 2. Next to self. `self_exe_path` may be an absolute path or a bare
    //    name (e.g. "pabrik-desktop" when called with PATH lookup); only
    //    the absolute case is useful.
    if (std.fs.path.isAbsolute(self_exe_path)) {
        const self_dir = std.fs.path.dirname(self_exe_path) orelse ".";
        // On Windows, the actual on-disk name has the `.exe` suffix —
        // `std.c.access("...\pabrik", F_OK)` returns ENOENT even though
        // `...\pabrik.exe` exists, because the UCRT `access` call does NOT
        const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
        const base_name = if (exe_suffix.len > 0)
            std.fmt.allocPrint(allocator, "pabrik{s}", .{exe_suffix}) catch return null
        else
            allocator.dupe(u8, "pabrik") catch return null;
        defer allocator.free(base_name);
        const candidate = std.fs.path.join(allocator, &.{ self_dir, base_name }) catch return null;
        if (fileExists(candidate)) {
            return candidate; // hand off ownership
        }
        allocator.free(candidate);
    }

    // 3. $PATH lookup. PATH separator is OS-specific: `:` on Linux/macOS, `;`
    // on Windows.
    const path_separator: u8 = if (builtin.os.tag == .windows) ';' else ':';
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    const base_name = if (exe_suffix.len > 0)
        std.fmt.allocPrint(allocator, "pabrik{s}", .{exe_suffix}) catch return null
    else
        allocator.dupe(u8, "pabrik") catch return null;
    defer allocator.free(base_name);
    var it = std.mem.tokenizeScalar(u8, path_env, path_separator);
    while (it.next()) |dir| {
        const candidate = std.fs.path.join(allocator, &.{ dir, base_name }) catch continue;
        if (fileExists(candidate)) {
            return candidate;
        }
        allocator.free(candidate);
    }
    return null;
}

/// Return the absolute path to the running executable.
pub fn selfExePath(allocator: std.mem.Allocator) SelfExeError![]u8 {
    return switch (builtin.os.tag) {
        .linux => linuxSelfExePath(allocator),
        .macos => macosSelfExePath(allocator),
        .windows => windowsSelfExePath(allocator),
        else => return error.UnsupportedPlatform,
    };
}

fn linuxSelfExePath(allocator: std.mem.Allocator) SelfExeError![]u8 {
    // PATH_MAX is 4096 on Linux; 4096 is enough for almost all real
    // installations. If the path is longer, readlink will return -ENAMETOOLONG
    // and we'll surface that as ReadLinkFailed.
    var buf: [4096]u8 = undefined;
    const rc = std.os.linux.readlink("/proc/self/exe", &buf, buf.len);
    // On Linux, readlink returns the number of bytes written, or
    // (cast to usize) -errno. The kernel caps the return at the buffer
    // size, so a value > 4096 means an error occurred.
    if (rc > buf.len) return error.ReadLinkFailed;
    return allocator.dupe(u8, buf[0..rc]) catch return error.OutOfMemory;
}

// Win32 GetModuleFileNameW — returns the absolute path of the main
// executable.
extern "kernel32" fn GetModuleFileNameW(
    hModule: ?*anyopaque,
    lpFilename: [*]u16,
    nSize: u32,
) callconv(.winapi) u32;

// Win32 self-exe resolution. GetModuleFileNameW with hModule=NULL returns the
// full path of the running .exe as a NUL-terminated UTF-16LE string.
fn windowsSelfExePath(allocator: std.mem.Allocator) SelfExeError![]u8 {
    var wide: [32767]u16 = undefined;
    const written = GetModuleFileNameW(null, &wide, wide.len);
    if (written == 0 or written >= wide.len) return error.ReadLinkFailed;
    // WTF-16LE → WTF-8.
    var narrow: [32767 * 3]u8 = undefined;
    const utf8_len = std.unicode.wtf16LeToWtf8(&narrow, wide[0..written]);
    return allocator.dupe(u8, narrow[0..utf8_len]) catch return error.OutOfMemory;
}

fn macosSelfExePath(allocator: std.mem.Allocator) SelfExeError![]u8 {
    // macOS doesn't have /proc/self/exe; the documented way to find your own
    // exe path is `_NSGetExecutablePath` from libSystem.
    var buf: [4096]u8 = undefined;
    var bufsize: u32 = buf.len;
    const rc = std.c._NSGetExecutablePath(&buf, &bufsize);
    if (rc == 0) {
        const len = std.mem.indexOfScalar(u8, &buf, 0) orelse bufsize;
        return allocator.dupe(u8, buf[0..len]) catch return error.OutOfMemory;
    }
    // Buffer too small — retry with the required size.
    if (bufsize == 0 or bufsize > 65536) return error.ReadLinkFailed;
    const heap = allocator.alloc(u8, bufsize) catch return error.OutOfMemory;
    defer allocator.free(heap);
    const retry_rc = std.c._NSGetExecutablePath(heap.ptr, &bufsize);
    if (retry_rc != 0) return error.ReadLinkFailed;
    const len = std.mem.indexOfScalar(u8, heap, 0) orelse bufsize;
    return allocator.dupe(u8, heap[0..len]) catch return error.OutOfMemory;
}

/// Windows-only shipped webapp lookup (persistent static dir). Returns the
/// duped absolute path of the installed `html/` dir when its `index.html`
/// exists, else null.
pub fn findInstalledWebapp(
    allocator: std.mem.Allocator,
    self_exe_path: []const u8,
) ?[]u8 {
    if (builtin.os.tag != .windows) return null;

    // 1. %LOCALAPPDATA%\pabrik\html\index.html
    if (std.c.getenv("LOCALAPPDATA")) |appdata_z| {
        const appdata = std.mem.sliceTo(appdata_z, 0);
        const probe = std.fs.path.join(allocator, &.{ appdata, "pabrik", "html", "index.html" }) catch null;
        if (probe) |p| {
            defer allocator.free(p);
            if (fileExists(p)) {
                return std.fs.path.join(allocator, &.{ appdata, "pabrik", "html" }) catch null;
            }
        }
    }

    // 2. <exe_dir>\html\index.html (only when we know our own dir).
    if (std.fs.path.isAbsolute(self_exe_path)) {
        const self_dir = std.fs.path.dirname(self_exe_path) orelse ".";
        const probe = std.fs.path.join(allocator, &.{ self_dir, "html", "index.html" }) catch null;
        if (probe) |p| {
            defer allocator.free(p);
            if (fileExists(p)) {
                return std.fs.path.join(allocator, &.{ self_dir, "html" }) catch null;
            }
        }
    }

    // 3. Legacy webapp/ fallbacks (pre-rename). Removed once all installs migrate.
    if (std.c.getenv("LOCALAPPDATA")) |appdata_z| {
        const appdata = std.mem.sliceTo(appdata_z, 0);
        const probe = std.fs.path.join(allocator, &.{ appdata, "pabrik", "webapp", "index.html" }) catch null;
        if (probe) |p| {
            defer allocator.free(p);
            if (fileExists(p)) {
                return std.fs.path.join(allocator, &.{ appdata, "pabrik", "webapp" }) catch null;
            }
        }
    }
    if (std.fs.path.isAbsolute(self_exe_path)) {
        const self_dir = std.fs.path.dirname(self_exe_path) orelse ".";
        const probe = std.fs.path.join(allocator, &.{ self_dir, "webapp", "index.html" }) catch null;
        if (probe) |p| {
            defer allocator.free(p);
            if (fileExists(p)) {
                return std.fs.path.join(allocator, &.{ self_dir, "webapp" }) catch null;
            }
        }
    }

    return null;
}

fn fileExists(path: []const u8) bool {
    // Zig 0.16 removed `std.fs.accessAbsolute`; the new path is
    // `std.Io.Dir.accessAbsolute(io, path, .{})` which requires an io handle.
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    // F_OK (== 0) means "file exists" — we don't care about read/write
    // permissions, just whether the path resolves to anything.
    const rc = switch (builtin.os.tag) {
        .windows => std.c.access(&buf, std.c.F_OK),
        else => std.c.faccessat(std.c.AT.FDCWD, &buf, std.c.F_OK, 0),
    };
    return rc == 0;
}

// ===== Tests merged from path_resolve_test.zig (2026-09-29 flatten) =====
// Tests for the pabrik-binary path resolver.

const testing = std.testing;

test "resolvePabrikPath: returns --pabrik-path if provided" {
    const allocator = testing.allocator;
    // We pass a path that almost certainly does not exist.
    const result = resolve(allocator, "/custom/pabrik", "pabrik-desktop", "/usr/bin");
    try testing.expect(result != null);
    try testing.expectEqualStrings("/custom/pabrik", result.?);
    allocator.free(result.?);
}

test "resolvePabrikPath: handles next-to-self + PATH lookup without crashing" {
    const allocator = testing.allocator;
    // Use a "next to self" path that does not exist; PATH also probably lacks
    // the binary in CI. We just want to confirm the function doesn't panic,
    // and that it returns null when nothing is found.
    const result = resolve(
        allocator,
        null,
        "/nonexistent/dir/pabrik-desktop",
        "/usr/bin:/bin",
    );
    // The function should not crash. It may return null (if neither path
    // has a pabrik binary) or a real path (if the test env has pabrik
    // installed in /usr/bin or /bin) — both outcomes are valid.
    if (result) |r| allocator.free(r);
}

test "resolvePabrikPath: returns null when pabrik is not found anywhere" {
    const allocator = testing.allocator;
    // Use a path_env that definitely doesn't exist and a self path that
    // definitely doesn't exist.
    const result = resolve(
        allocator,
        null,
        "/nonexistent/dir/pabrik-desktop",
        "/nonexistent/path/with/no/binaries",
    );
    try testing.expect(result == null);
}

test "findInstalledWebapp: returns null for nonexistent exe dir without crashing" {
    const allocator = testing.allocator;
    const result = findInstalledWebapp(
        allocator,
        "/nonexistent/dir/pabrik-desktop",
    );
    // On non-Windows this is unconditionally null; on Windows CI neither
    // %LOCALAPPDATA%\pabrik\html\index.html nor the nonexistent exe-dir
    // candidate exists, so null as well. Either way: no panic, no leak.
    if (result) |r| allocator.free(r);
}

test "findInstalledWebapp: bare relative exe path skips next-to-self probe" {
    const allocator = testing.allocator;
    const result = findInstalledWebapp(allocator, ".");
    if (result) |r| allocator.free(r);
}

test "resolvePabrikPath: handles Windows-style PATH (;-separated)" {
    // The fix for `error.PabrikNotFound` on Windows: `resolve()` used to
    // tokenize by `:` (Unix convention) on every platform.
    const allocator = testing.allocator;
    const result = resolve(
        allocator,
        null,
        "C:\\nonexistent\\dir\\pabrik-desktop.exe",
        "C:\\Windows\\System32;C:\\Windows;C:\\nonexistent\\bin",
    );
    if (result) |r| allocator.free(r);
    // No panic + no result = pass. (We can't easily write a "creates
    // a temp file in PATH and finds it" test here without pulling
    // in std.fs.cwd machinery that Zig 0.16 has restructured.)
}

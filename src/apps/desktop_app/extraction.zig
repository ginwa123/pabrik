// src/apps/desktop_app/extraction.zig Runtime asset extraction: write a flat
// list of `AssetEntry` records (the source: webapp_assets.assets — see
// tools/codegen_webapp_assets.zig) to a fresh per-user temp dir.

const std = @import("std");
const builtin = @import("builtin");

/// A flat asset entry. Source: the generated webapp_assets.zig at comptime
/// (one `pub const assets: []const Asset` slice for the whole app).
pub const AssetEntry = struct {
    /// Path as served by the webserver, e.g. "/index.html" or
    /// "/assets/app.js". Must start with "/"; the leading slash is
    /// stripped before writing to disk.
    path: []const u8,
    /// File contents (use as-is; do not modify).
    content: []const u8,
    /// Inferred MIME type with charset for text/* types.
    mime: []const u8,
};

/// Extract the given assets to a fresh per-pid temp subdir. Returns the
/// absolute path of the temp dir. The caller MUST call `cleanup(allocator,
/// dir)` on shutdown.
pub fn extract(allocator: std.mem.Allocator, assets: anytype) ![]u8 {
    const tmp_base = tmpDirBase(allocator);
    defer allocator.free(tmp_base);

    // Make a per-pid subdir so concurrent runs don't collide.
    const pid_for_subdir: u64 = switch (builtin.os.tag) {
        .windows => @intFromPtr(std.c.getpid()),
        else => @intCast(std.c.getpid()),
    };
    const subdir = try std.fmt.allocPrint(
        allocator,
        "pabrik-desktop-webapp-{d}",
        .{pid_for_subdir},
    );
    defer allocator.free(subdir);

    const full_path = try std.fs.path.join(allocator, &.{ tmp_base, subdir });
    errdefer {
        deleteTreeBestEffort(full_path);
        allocator.free(full_path);
    }

    try makePathAbsolute(full_path);

    // Write each asset.
    for (assets) |asset| {
        try writeAssetInto(allocator, full_path, asset);
    }

    return full_path;
}

/// Recursively remove the temp dir and free the path slice. Best-effort:
/// any deleteTree error is logged but not propagated (the caller is
/// shutting down; there's nothing useful they can do with the error).
pub fn cleanup(allocator: std.mem.Allocator, dir: []const u8) void {
    deleteTreeBestEffort(dir);
    allocator.free(dir);
}

/// Name of the marker file written LAST inside a persistent webapp dir.
/// Its presence is what `dirIsComplete` checks before reusing a dir, so a
/// run killed mid-extraction can never be mistaken for a complete one.
pub const complete_marker_name = ".pabrik-webapp-complete";

/// Materialise the webapp into a **persistent, content-addressed** dir and
/// return its absolute path.
pub fn ensurePersistent(allocator: std.mem.Allocator, assets: anytype) ![]u8 {
    const base = persistentBaseDir(allocator);
    defer allocator.free(base);
    return ensurePersistentIn(allocator, base, assets);
}

/// `ensurePersistent` with an explicit base dir. Split out so tests can
/// point it at a tmpDir instead of the user's real data dir.
pub fn ensurePersistentIn(
    allocator: std.mem.Allocator,
    base: []const u8,
    assets: anytype,
) ![]u8 {
    const hash = try assetSetHashHex(allocator, assets);
    defer allocator.free(hash);

    const final_dir = try std.fs.path.join(allocator, &.{ base, hash });
    errdefer allocator.free(final_dir);

    // Fast path: a complete dir from an earlier run of the same build.
    // This is the property that keeps a long-lived daemon's --static-dir
    // valid, so it is deliberately checked before anything else.
    if (dirIsComplete(final_dir)) return final_dir;

    try makePathAbsolute(base);

    // Stage in a sibling dir so a crash mid-write can never leave a
    // partial tree under the final name.
    const pid: u64 = switch (builtin.os.tag) {
        .windows => @intFromPtr(std.c.getpid()),
        else => @intCast(std.c.getpid()),
    };
    const staging = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}", .{ final_dir, pid });
    defer allocator.free(staging);

    // A leftover staging dir from a previous crash: clear it.
    if (pathExistsAbs(staging)) deleteTreeBestEffort(staging);
    try makePathAbsolute(staging);

    for (assets) |asset| {
        try writeAssetInto(allocator, staging, asset);
    }

    // Marker LAST: its presence is the "this dir is complete" signal.
    const marker_path = try std.fs.path.join(allocator, &.{ staging, complete_marker_name });
    defer allocator.free(marker_path);
    try writeFileAbsolute(marker_path, hash);

    // Publish. An incomplete leftover under the final name (a torn write
    // from an earlier crash, or a dir left by the old per-pid layout)
    // must go first — rename(2) refuses to replace a non-empty directory.
    if (pathExistsAbs(final_dir) and !dirIsComplete(final_dir)) {
        deleteTreeBestEffort(final_dir);
    }

    renameAbsolute(staging, final_dir) catch |err| switch (err) {
        // Another process published between our check and the rename.
        // Its dir was built from the same content hash, so it is
        // byte-identical — keep theirs and drop our staging copy.
        error.TargetExists => deleteTreeBestEffort(staging),
        else => return err,
    };

    if (!dirIsComplete(final_dir)) return error.WebappDirIncomplete;
    return final_dir;
}

/// Name of the stable symlink inside the persistent base dir.
pub const stable_link_name = "current";

/// `ensurePersistent` with a stable return path: materialise the assets into
/// `<base>/<hash>` as usual, then atomically point `<base>/current` at it and
/// return the `<base>/current` path.
pub fn ensurePersistentStable(allocator: std.mem.Allocator, assets: anytype) ![]u8 {
    const base = persistentBaseDir(allocator);
    defer allocator.free(base);
    return ensurePersistentStableIn(allocator, base, assets);
}

/// `ensurePersistentStable` with an explicit base dir. Split out so tests
/// can point it at a tmpDir instead of the user's real data dir.
pub fn ensurePersistentStableIn(
    allocator: std.mem.Allocator,
    base: []const u8,
    assets: anytype,
) ![]u8 {
    if (builtin.os.tag == .windows) return ensurePersistentIn(allocator, base, assets);

    const hash_dir = try ensurePersistentIn(allocator, base, assets);
    defer allocator.free(hash_dir);

    const stable = try std.fs.path.join(allocator, &.{ base, stable_link_name });
    errdefer allocator.free(stable);

    // Relative target (the hash basename) keeps the link relocatable and
    // `readlink` output short.
    const target = std.fs.path.basename(hash_dir);
    pointSymlinkAt(allocator, stable, target) catch |err| {
        std.log.warn("stable webapp link {s} -> {s} failed ({s}); using versioned dir", .{
            stable, target, @errorName(err),
        });
        return try allocator.dupe(u8, hash_dir);
    };
    return stable;
}

/// Atomically point `link_path` at `target` via a temp symlink + rename.
/// `target` is stored as given (callers pass the hash basename, making the
/// link relative).
fn pointSymlinkAt(allocator: std.mem.Allocator, link_path: []const u8, target: []const u8) !void {
    const pid: u64 = switch (builtin.os.tag) {
        .windows => @intFromPtr(std.c.getpid()),
        else => @intCast(std.c.getpid()),
    };
    const tmp_link = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}", .{ link_path, pid });
    defer allocator.free(tmp_link);

    if (pathExistsAbs(tmp_link)) unlinkAbsolute(tmp_link);
    try symlinkAbsolute(target, tmp_link);
    errdefer unlinkAbsolute(tmp_link);

    renameAbsolute(tmp_link, link_path) catch |err| switch (err) {
        // `link_path` is a real dir, not a symlink — refuse to clobber
        // user data; the caller falls back to the versioned dir.
        error.TargetExists => return error.LinkTargetIsDir,
        else => return err,
    };
}

/// `symlink(2)` via libc. Both paths must be NUL-terminated scratch copies.
fn symlinkAbsolute(target: []const u8, link_path: []const u8) !void {
    var target_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const target_z = copyToNull(&target_buf, target);
    const link_z = copyToNull(&link_buf, link_path);
    const rc = std.c.symlink(target_z, link_z);
    if (rc == 0) return;
    return error.SymlinkFailed;
}

/// Best-effort `unlink(2)` for a symlink path. Never follows the link.
fn unlinkAbsolute(path: []const u8) void {
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = copyToNull(&path_buf, path);
    _ = std.c.unlink(path_z);
}

/// Per-user base dir for the persistent webapp copies.
fn persistentBaseDir(allocator: std.mem.Allocator) []u8 {
    switch (builtin.os.tag) {
        .linux => {
            if (getenvNonEmpty("XDG_DATA_HOME")) |v| {
                return std.fs.path.join(allocator, &.{ v, "pabrik", "desktop-webapp" }) catch
                    persistentBaseFallback(allocator);
            }
            if (getenvNonEmpty("HOME")) |v| {
                return std.fs.path.join(allocator, &.{ v, ".local", "share", "pabrik", "desktop-webapp" }) catch
                    persistentBaseFallback(allocator);
            }
        },
        .macos => {
            if (getenvNonEmpty("HOME")) |v| {
                return std.fs.path.join(allocator, &.{ v, "Library", "Application Support", "pabrik", "desktop-webapp" }) catch
                    persistentBaseFallback(allocator);
            }
        },
        .windows => {
            if (getenvNonEmpty("LOCALAPPDATA")) |v| {
                return std.fs.path.join(allocator, &.{ v, "pabrik", "desktop-webapp" }) catch
                    persistentBaseFallback(allocator);
            }
        },
        else => {},
    }
    return persistentBaseFallback(allocator);
}

/// Last resort when no per-user data dir can be resolved. Still a shared,
/// stable location (not per-pid), so daemons started by earlier launches
/// keep working within the session.
fn persistentBaseFallback(allocator: std.mem.Allocator) []u8 {
    const tmp = tmpDirBase(allocator);
    defer allocator.free(tmp);
    return std.fs.path.join(allocator, &.{ tmp, "pabrik-desktop-webapp" }) catch
        allocator.dupe(u8, "/tmp/pabrik-desktop-webapp") catch @panic("out of memory resolving webapp data dir");
}

fn getenvNonEmpty(name: [*:0]const u8) ?[]const u8 {
    const z = std.c.getenv(name) orelse return null;
    const v = std.mem.span(z);
    if (v.len == 0) return null;
    return v;
}

/// Hex digest over the asset set.
fn assetSetHashHex(allocator: std.mem.Allocator, assets: anytype) ![]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    for (assets) |asset| {
        hasher.update(asset.path);
        hasher.update(&[_]u8{0});
        hasher.update(asset.mime);
        hasher.update(&[_]u8{0});
        hasher.update(asset.content);
        hasher.update(&[_]u8{0});
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex_buf: [32]u8 = undefined;
    // Dupe the slice `bufPrint` actually wrote — not the whole buffer.
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{digest[0..16]}) catch @panic("bufPrint failed formatting the asset-set hash");
    return allocator.dupe(u8, hex);
}

/// True when `dir` holds a completed extraction. Only the marker is checked:
/// it is written after every asset, so its presence implies the whole tree
/// landed.
fn dirIsComplete(dir: []const u8) bool {
    if (!pathExistsAbs(dir)) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, complete_marker_name }) catch return false;
    return pathExistsAbs(marker);
}

/// Write one asset into `dir`, creating parent dirs as needed.
fn writeAssetInto(allocator: std.mem.Allocator, dir: []const u8, asset: anytype) !void {
    // Strip the leading "/" from the path; everything else is relative to the
    // webapp root.
    const rel = if (asset.path.len > 0 and asset.path[0] == '/')
        asset.path[1..]
    else
        asset.path;

    const abs_path = try std.fs.path.join(allocator, &.{ dir, rel });
    defer allocator.free(abs_path);

    // Make parent dirs as needed (e.g. "/assets/app.js" needs
    // "<dir>/assets" to exist before the file create).
    if (std.fs.path.dirname(abs_path)) |parent| {
        try makePathAbsolute(parent);
    }

    try writeFileAbsolute(abs_path, asset.content);
}

/// Pick a base temp dir for this platform. The returned slice is freshly
/// allocated; the caller owns it.
fn tmpDirBase(allocator: std.mem.Allocator) []u8 {
    const builtin_os = builtin.os.tag;
    return switch (builtin_os) {
        .linux => blk: {
            if (std.c.getenv("XDG_RUNTIME_DIR")) |xdg_z| {
                const xdg = std.mem.span(xdg_z);
                break :blk allocator.dupe(u8, xdg) catch fallbackTmp(allocator);
            }
            break :blk fallbackTmp(allocator);
        },
        .macos => blk: {
            if (std.c.getenv("TMPDIR")) |tmpdir_z| {
                break :blk allocator.dupe(u8, std.mem.span(tmpdir_z)) catch fallbackTmp(allocator);
            }
            break :blk fallbackTmp(allocator);
        },
        .windows => blk: {
            if (std.c.getenv("TEMP")) |t_z| {
                break :blk allocator.dupe(u8, std.mem.span(t_z)) catch fallbackTmp(allocator);
            }
            if (std.c.getenv("TMP")) |t_z| {
                break :blk allocator.dupe(u8, std.mem.span(t_z)) catch fallbackTmp(allocator);
            }
            break :blk allocator.dupe(u8, "C:\\Windows\\Temp") catch @panic("dupe failed for the Windows temp dir fallback");
        },
        else => fallbackTmp(allocator),
    };
}

/// Last-resort fallback for tmpDirBase. A dupe failure here would
/// mean we're out of memory before the app even started, so we
/// panic — there's nothing useful the caller can do.
fn fallbackTmp(allocator: std.mem.Allocator) []u8 {
    return allocator.dupe(u8, "/tmp") catch @panic("out of memory resolving temp dir");
}

// ===================================================================== Raw
// syscall helpers
// ===================================================================== Zig

fn copyToNull(buf: *[std.fs.max_path_bytes:0]u8, path: []const u8) [*:0]const u8 {
    if (path.len >= buf.len) @panic("path too long for null-terminated buffer");
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf;
}

/// `mkdir -p` for an absolute path. Walks the path component by component,
/// calling `mkdir(2)` for each missing segment.
fn makePathAbsolute(path: []const u8) !void {
    if (path.len == 0 or (path.len == 1 and path[0] == '.')) return;

    // If the path already exists, we're done.
    if (pathExistsAbs(path)) return;

    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = copyToNull(&path_buf, path);

    // Recurse on the parent first.
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len < path.len) try makePathAbsolute(parent);
    }

    // Now mkdir this path. EEXIST is fine (a concurrent creator).
    const mkdir_rc = std.c.mkdir(path_z, 0o755);
    if (mkdir_rc == 0) return;
    if (std.c.errno(mkdir_rc) == std.c.E.EXIST) return;
    return error.MkdirFailed;
}

/// Does this absolute path exist?
fn pathExistsAbs(path: []const u8) bool {
    switch (builtin.os.tag) {
        .windows => {
            var path_w: [std.fs.max_path_bytes:0]u16 = undefined;
            const written = std.unicode.wtf8ToWtf16Le(&path_w, path) catch return false;
            path_w[written] = 0;
            // INVALID_FILE_ATTRIBUTES (0xFFFFFFFF) = "not found / error".
            // Any other value = file/dir exists.
            return GetFileAttributesW(@ptrCast(&path_w)) != 0xFFFFFFFF;
        },
        else => {
            var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
            if (path.len >= path_buf.len) return false;
            const path_z = copyToNull(&path_buf, path);
            return std.c.faccessat(std.c.AT.FDCWD, path_z, std.c.F_OK, 0) == 0;
        },
    }
}

/// `rename(2)` with the "target already exists" case (a concurrent
/// publisher won the race) split out as `error.TargetExists` so callers
/// can treat it as "someone else did the work" rather than a failure.
fn renameAbsolute(from: []const u8, to: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => {
            var from_w: [std.fs.max_path_bytes:0]u16 = undefined;
            var to_w: [std.fs.max_path_bytes:0]u16 = undefined;
            const from_len = std.unicode.wtf8ToWtf16Le(&from_w, from) catch return error.RenameFailed;
            from_w[from_len] = 0;
            const to_len = std.unicode.wtf8ToWtf16Le(&to_w, to) catch return error.RenameFailed;
            to_w[to_len] = 0;
            // Win32 `BOOL` is a typed enum in Zig 0.16 (not a raw integer),
            // so compare against `.FALSE` — `!= 0` is a compile error for
            // the Windows target. Same pattern as FindNextFileW below.
            if (win32_dir_apis.MoveFileW(@ptrCast(&from_w), @ptrCast(&to_w)) != .FALSE) return;
            const last_err = win32_dir_apis.GetLastError();
            if (last_err == win32_dir_apis.ERROR_ALREADY_EXISTS or
                last_err == win32_dir_apis.ERROR_FILE_EXISTS or
                last_err == win32_dir_apis.ERROR_ACCESS_DENIED)
            {
                return error.TargetExists;
            }
            return error.RenameFailed;
        },
        else => {
            var from_buf: [std.fs.max_path_bytes:0]u8 = undefined;
            var to_buf: [std.fs.max_path_bytes:0]u8 = undefined;
            const from_z = copyToNull(&from_buf, from);
            const to_z = copyToNull(&to_buf, to);
            const rc = std.c.rename(from_z, to_z);
            if (rc == 0) return;
            switch (std.c.errno(rc)) {
                // EEXIST (target dir non-empty / existing file),
                // ENOTEMPTY (target dir non-empty), ENOTDIR (target is a
                // non-dir) all mean "something is already published there".
                .EXIST, .NOTEMPTY, .NOTDIR => return error.TargetExists,
                else => return error.RenameFailed,
            }
        },
    }
}

// Local extern decls + scratch buffer for the Win32 `stat` path above.
extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) std.os.windows.DWORD;

/// Create (or truncate) a file at an absolute path and write the given bytes.
/// Returns nothing on success; on write error the partial file is left on
/// disk (the caller can `deleteTree` to clean up).
fn writeFileAbsolute(path: []const u8, content: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = copyToNull(&path_buf, path);

    switch (builtin.os.tag) {
        .windows => return writeFileAbsoluteWindows(path, content),
        else => return writeFileAbsolutePosix(path_z, content),
    }
}

fn writeFileAbsolutePosix(path_z: [*:0]const u8, content: []const u8) !void {
    // `std.c.O` is a Zig packed struct mirroring the kernel's open-flag
    // bits for the target platform. The struct layout differs across
    // platforms but the field names are portable.
    const flags: std.c.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    };
    // `std.c.open` returns -1 on failure (with errno set) or the new fd.
    const fd = std.c.open(path_z, @bitCast(flags), @as(c_int, 0o644));
    if (fd == -1) return error.OpenOutFailed;
    defer _ = std.c.close(fd);

    var written: usize = 0;
    while (written < content.len) {
        // `std.c.write` returns `isize` (bytes written) or -1 on error.
        const n: isize = std.c.write(fd, content[written..].ptr, content.len - written);
        if (n == -1) return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

fn writeFileAbsoluteWindows(path: []const u8, content: []const u8) !void {
    var path_w: [std.fs.max_path_bytes:0]u16 = undefined;
    const written = std.unicode.wtf8ToWtf16Le(&path_w, path) catch
        return error.PathTooLong;
    path_w[written] = 0;

    // CreateFileW flags: GENERIC_WRITE | OPEN_ALWAYS (truncate if exists).
    const h_opt = CreateFileW(
        @ptrCast(&path_w),
        0x40000000, // GENERIC_WRITE
        0x1, // FILE_SHARE_READ
        null,
        4, // OPEN_ALWAYS
        0x80, // FILE_ATTRIBUTE_NORMAL
        null,
    );
    const h = h_opt orelse return error.OpenOutFailed;
    defer _ = CloseHandle(h);

    // Truncate to 0 (OPEN_ALWAYS preserves existing content; we want
    // truncation for the "overwrite" semantic).
    const set_rc = SetFilePointerEx(h, 0, null, 2); // FILE_END = 2
    _ = set_rc; // best-effort; if it fails the write below will surface it

    var total_written: usize = 0;
    while (total_written < content.len) {
        var chunk_written: std.os.windows.DWORD = 0;
        const ok = WriteFile(
            h,
            content[total_written..].ptr,
            @intCast(content.len - total_written),
            &chunk_written,
            null,
        );
        if (@intFromEnum(ok) == 0) return error.WriteFailed;
        if (chunk_written == 0) return error.WriteFailed;
        total_written += @intCast(chunk_written);
    }
}

// Local Win32 externs for the file-write path above.
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: std.os.windows.DWORD,
    dwShareMode: std.os.windows.DWORD,
    lpSecurityAttributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
    dwCreationDisposition: std.os.windows.DWORD,
    dwFlagsAndAttributes: std.os.windows.DWORD,
    hTemplateFile: ?std.os.windows.HANDLE,
) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn WriteFile(
    hFile: std.os.windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: std.os.windows.DWORD,
    lpNumberOfBytesWritten: *std.os.windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn CloseHandle(hObject: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn SetFilePointerEx(
    hFile: std.os.windows.HANDLE,
    liDistanceToMove: i64,
    lpNewFilePointer: ?*i64,
    dwMoveMethod: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

// Win32 FindFirstFileW / FindNextFileW bindings for the Windows-only
// deleteTree path.
const win32_dir_apis = if (builtin.os.tag == .windows) struct {
    /// `WIN32_FIND_DATAW` per Win32 SDK. Layout MUST match the OS struct —
    /// the kernel writes directly into this buffer via FindFirstFileW.
    const WIN32_FIND_DATAW = extern struct {
        dwFileAttributes: std.os.windows.DWORD,
        ftCreationTime: std.os.windows.FILETIME,
        ftLastAccessTime: std.os.windows.FILETIME,
        ftLastWriteTime: std.os.windows.FILETIME,
        nFileSizeHigh: std.os.windows.DWORD,
        nFileSizeLow: std.os.windows.DWORD,
        dwReserved0: std.os.windows.DWORD,
        dwReserved1: std.os.windows.DWORD,
        cFileName: [std.fs.max_path_bytes]u16,
        cAlternateFileName: [14]u16,
    };

    const INVALID_HANDLE_VALUE: std.os.windows.HANDLE = @ptrFromInt(std.math.maxInt(usize));
    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
    const ERROR_FILE_NOT_FOUND: u32 = 2;
    const ERROR_ACCESS_DENIED: u32 = 5;
    const ERROR_NO_MORE_FILES: u32 = 18;
    const ERROR_FILE_EXISTS: u32 = 80;
    const ERROR_ALREADY_EXISTS: u32 = 183;

    /// Directory rename (the publishing step of `ensurePersistentIn`).
    extern "kernel32" fn MoveFileW(
        lpExistingFileName: [*:0]const u16,
        lpNewFileName: [*:0]const u16,
    ) callconv(.winapi) std.os.windows.BOOL;

    extern "kernel32" fn FindFirstFileW(
        lpFileName: [*:0]const u16,
        lpFindFileData: *WIN32_FIND_DATAW,
    ) callconv(.winapi) std.os.windows.HANDLE;

    extern "kernel32" fn FindNextFileW(
        hFindFile: std.os.windows.HANDLE,
        lpFindFileData: *WIN32_FIND_DATAW,
    ) callconv(.winapi) std.os.windows.BOOL;

    extern "kernel32" fn FindClose(hFindFile: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;

    extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) std.os.windows.BOOL;

    extern "kernel32" fn RemoveDirectoryW(lpFileName: [*:0]const u16) callconv(.winapi) std.os.windows.BOOL;

    extern "kernel32" fn GetLastError() callconv(.winapi) std.os.windows.DWORD;
} else struct {};

/// Windows-only recursive-delete implementation, mirrors the POSIX path's
/// semantics (best-effort, errors swallowed at the top-level caller) but uses
/// Win32 `FindFirstFileW` / `FindNextFileW` because `std.c.readdir` is `{}`
fn deleteTreeRecursiveWindows(path: []const u8) !void {
    // Build "<path>\*" in a WTF-16 buffer. FindFirstFileW needs the wildcard
    // suffix to enumerate children.
    var pattern_buf: [std.fs.max_path_bytes:0]u16 = undefined;
    if (path.len + 3 > std.fs.max_path_bytes) return error.NameTooLong;
    const sep_index = std.unicode.wtf8ToWtf16Le(pattern_buf[0 .. pattern_buf.len - 1], path) catch
        return error.PathTooLong;
    pattern_buf[sep_index] = '\\';
    pattern_buf[sep_index + 1] = '*';
    pattern_buf[sep_index + 2] = 0;

    var find_data: win32_dir_apis.WIN32_FIND_DATAW = undefined;
    const find_handle = win32_dir_apis.FindFirstFileW(&pattern_buf, &find_data);
    if (find_handle == win32_dir_apis.INVALID_HANDLE_VALUE) {
        // ERROR_FILE_NOT_FOUND here just means the dir is empty — that's fine,
        // we can still RemoveDirectoryW below.
        const err = win32_dir_apis.GetLastError();
        if (err != win32_dir_apis.ERROR_FILE_NOT_FOUND) return error.OpenDirFailed;
    } else {
        defer _ = win32_dir_apis.FindClose(find_handle);

        // First entry was already returned by FindFirstFileW; process it, then
        // loop over FindNextFileW until it returns 0 (no more entries).
        var child_path_buf: [std.fs.max_path_bytes:0]u16 = undefined;
        while (true) {
            // Copy cFileName into a temp slice up to the first NUL.
            const name_len = std.mem.indexOfScalar(u16, &find_data.cFileName, 0) orelse
                find_data.cFileName.len;
            const name_w = find_data.cFileName[0..name_len];

            // Skip "." and ".." the same way the POSIX path does.
            const is_dot = name_len == 1 and name_w[0] == '.';
            const is_dotdot = name_len == 2 and name_w[0] == '.' and name_w[1] == '.';
            if (!is_dot and !is_dotdot) {
                // Build "<path>\\<name>" into the WTF-16 child buffer.
                if (sep_index + 1 + name_len >= child_path_buf.len) return error.NameTooLong;
                @memcpy(child_path_buf[0..sep_index], pattern_buf[0..sep_index]);
                child_path_buf[sep_index] = '\\';
                @memcpy(child_path_buf[sep_index + 1 ..][0..name_len], name_w);
                child_path_buf[sep_index + 1 + name_len] = 0;

                if ((find_data.dwFileAttributes & win32_dir_apis.FILE_ATTRIBUTE_DIRECTORY) != 0) {
                    // Convert the WTF-16 child path back to WTF-8 so we can
                    // recurse — the helper functions take `[]const u8`.
                    var child_utf8: [std.fs.max_path_bytes]u8 = undefined;
                    const written = std.unicode.wtf16LeToWtf8(&child_utf8, child_path_buf[0 .. sep_index + 1 + name_len]);
                    try deleteTreeRecursiveWindows(child_utf8[0..written]);
                    _ = win32_dir_apis.RemoveDirectoryW(&child_path_buf);
                } else {
                    _ = win32_dir_apis.DeleteFileW(&child_path_buf);
                }
            }

            // Advance to the next entry. FindNextFileW returns FALSE when
            // there are no more entries (sets GetLastError to
            // ERROR_NO_MORE_FILES).
            const more = win32_dir_apis.FindNextFileW(find_handle, &find_data);
            if (more == .FALSE) break;
        }
    }

    // Finally, remove the (now-empty) directory itself.
    var path_w_buf: [std.fs.max_path_bytes:0]u16 = undefined;
    const path_w_len = std.unicode.wtf8ToWtf16Le(path_w_buf[0 .. path_w_buf.len - 1], path) catch
        return error.PathTooLong;
    path_w_buf[path_w_len] = 0;
    _ = win32_dir_apis.RemoveDirectoryW(&path_w_buf);
}

/// `rm -rf` via libc `opendir` / `readdir` / `closedir` + `unlink` / `rmdir`.
/// Best-effort: errors are logged but not propagated.
fn deleteTreeBestEffort(path: []const u8) void {
    switch (builtin.os.tag) {
        .windows => deleteTreeRecursiveWindows(path) catch |err| {
            std.log.warn("Failed to clean up temp dir {s}: {s}", .{ path, @errorName(err) });
        },
        else => deleteTreeRecursive(path) catch |err| {
            std.log.warn("Failed to clean up temp dir {s}: {s}", .{ path, @errorName(err) });
        },
    }
}

fn deleteTreeRecursive(path: []const u8) !void {
    var dir_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const dir_path_z = copyToNull(&dir_path_buf, path);

    // `opendir` returns null on failure (with errno set) or a `*DIR`.
    const dir = std.c.opendir(dir_path_z) orelse return error.OpenDirFailed;
    defer _ = std.c.closedir(dir);

    // Iterate entries. `std.c.readdir` returns `?*dirent`; null = end of
    // stream (errno unchanged) or error (errno set).
    var child_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;

    while (std.c.readdir(dir)) |entry| {
        // The libc `dirent` struct uses the field name `name` (NOT `d_name`,
        // which is a glibc extension we don't have here) on both Linux and
        // macOS.
        const name = switch (builtin.os.tag) {
            .macos => entry.name[0..entry.namlen],
            else => blk: {
                // Linux / *BSD: kernel guarantees NUL termination in the
                // fixed-size `name` array.
                var end: usize = 0;
                while (end < entry.name.len and entry.name[end] != 0) : (end += 1) {}
                break :blk entry.name[0..end];
            },
        };

        // Skip "." and "..".
        if (name.len == 0) continue;
        if (name.len == 1 and name[0] == '.') continue;
        if (name.len == 2 and name[0] == '.' and name[1] == '.') continue;

        // Build "<path>/<name>" into a stack buffer.
        if (path.len + 1 + name.len >= child_path_buf.len) return error.NameTooLong;
        @memcpy(child_path_buf[0..path.len], path);
        child_path_buf[path.len] = '/';
        @memcpy(child_path_buf[path.len + 1 ..][0..name.len], name);
        const child_path = child_path_buf[0 .. path.len + 1 + name.len];

        var child_z: [std.fs.max_path_bytes:0]u8 = undefined;
        const child_z_ptr = copyToNull(&child_z, child_path);

        // `entry.type` is the libc dirent's `d_type` field — the
        // file-type discriminator (DT_DIR=4, DT_REG=8, etc.). Same
        // values on Linux + macOS via `std.c.DT`.
        if (entry.type == std.c.DT.DIR) {
            // Recurse, then rmdir.
            try deleteTreeRecursive(child_path);
            _ = std.c.rmdir(child_z_ptr);
        } else {
            // unlink relative to the (now-recursively-emptied) parent dir.
            _ = std.c.unlink(child_z_ptr);
        }
    }

    // Finally rmdir the now-empty directory itself. Best-effort: a non-zero
    // return (e.g. ENOTEMPTY because of a race) is swallowed by the caller
    // via deleteTreeBestEffort.
    _ = std.c.rmdir(dir_path_z);
}

// ===== Tests merged from extraction_test.zig (2026-09-29 flatten) =====
// Tests for the runtime extraction module.

const testing = std.testing;

test "extract: writes all assets to a temp dir, returns absolute path" {
    const allocator = testing.allocator;

    // Use a tiny in-memory asset list. The "/assets/app.js" path tests
    // that extract() handles the parent-dir creation for nested files.
    const assets = [_]AssetEntry{
        .{ .path = "/index.html", .content = "<html>hi</html>", .mime = "text/html" },
        .{ .path = "/assets/app.js", .content = "console.log('x')", .mime = "application/javascript" },
    };

    const dir = try extract(allocator, &assets);
    defer cleanup(allocator, dir);

    // Returned path must be absolute so the webview can resolve it
    // regardless of cwd.
    try testing.expect(std.fs.path.isAbsolute(dir));

    // Verify both files exist with the right content. Read the files
    // back via raw open(2) + read(2) since std.fs.cwd() is gone in 0.16.
    try readBackAndExpect(dir, "index.html", "<html>hi</html>");
    try readBackAndExpect(dir, "assets/app.js", "console.log('x')");
}

test "extract: cleanup removes the dir" {
    const allocator = testing.allocator;

    const assets = [_]AssetEntry{
        .{ .path = "/index.html", .content = "x", .mime = "text/html" },
    };
    const dir = try extract(allocator, &assets);
    try testing.expect(std.fs.path.isAbsolute(dir));

    // Sanity: the dir exists right after extract.
    try testing.expect(dirExists(dir));

    // `cleanup` frees the `dir` slice (it owns the path), so copy it
    // first if we want to inspect the on-disk state after.
    const dir_copy = try allocator.dupe(u8, dir);
    defer allocator.free(dir_copy);

    cleanup(allocator, dir);

    // After cleanup, the dir should not exist. Read via the copy
    // (the original `dir` is now freed).
    try testing.expect(!dirExists(dir_copy));
}

/// Read `subpath` (relative to `dir`) and assert its content equals
/// `expected`. Uses raw syscalls because `std.fs.cwd()` is gone in 0.16.
fn readBackAndExpect(dir: []const u8, subpath: []const u8, expected: []const u8) !void {    const allocator = testing.allocator;
    const full = try std.fs.path.join(allocator, &.{ dir, subpath });
    defer allocator.free(full);

    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = testCopyToNull(&path_buf, full);

    const fd_rc = std.os.linux.open(
        path_z,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    );
    try testing.expect(fd_rc <= std.math.maxInt(i32));
    const fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);

    // statx to size the read.
    var statbuf: std.os.linux.Statx = undefined;
    const stat_rc = std.os.linux.statx(
        std.os.linux.AT.FDCWD,
        path_z,
        0,
        .{ .SIZE = true },
        &statbuf,
    );
    try testing.expect(stat_rc == 0);
    const size: usize = @intCast(statbuf.size);
    const content = try readAll(allocator, fd, size);
    defer allocator.free(content);
    try testing.expectEqualStrings(expected, content);
}

fn readAll(allocator: std.mem.Allocator, fd: i32, size: usize) ![]u8 {
    const buf = try allocator.alloc(u8, size);
    var total: usize = 0;
    while (total < size) {
        const n_rc = std.os.linux.read(fd, buf[total..].ptr, size - total);
        try testing.expect(n_rc <= std.math.maxInt(usize));
        const n: usize = @intCast(n_rc);
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

fn dirExists(path: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = testCopyToNull(&path_buf, path);
    const rc = std.os.linux.faccessat(std.os.linux.AT.FDCWD, path_z, 0, 0);
    return rc == 0;
}

// Distinct from the module's own `copyToNull` above: this copy panics on
// overflow instead of returning a "too long" sentinel, which is what the
// test's read-back path wants.
fn testCopyToNull(buf: *[std.fs.max_path_bytes:0]u8, path: []const u8) [*:0]const u8 {
    if (path.len >= buf.len) @panic("path too long for null-terminated buffer");
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf;
}

// =====================================================================
// ensurePersistentIn — the persistent, content-addressed webapp dir
// ===================================================================== Why

/// Return a tmpDir's real absolute path into `buf`.
fn tmpBase(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const len = try tmp.dir.realPath(testing.io, buf);
    return buf[0..len];
}

test "ensurePersistentIn: materialises assets, marks the dir complete, and reuses it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // helpers use raw linux syscalls
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpBase(&tmp, &path_buf);

    const assets = [_]AssetEntry{
        .{ .path = "/index.html", .content = "<html>one</html>", .mime = "text/html" },
        .{ .path = "/assets/app.js", .content = "console.log(1)", .mime = "application/javascript" },
    };

    const dir1 = try ensurePersistentIn(allocator, base, &assets);
    defer allocator.free(dir1);

    // The path the spawned daemon is handed must be absolute and must live
    // under the persistent base (never a per-pid temp dir).
    try testing.expect(std.fs.path.isAbsolute(dir1));
    try testing.expect(std.mem.startsWith(u8, dir1, base));

    try readBackAndExpect(dir1, "index.html", "<html>one</html>");
    try readBackAndExpect(dir1, "assets/app.js", "console.log(1)");

    // The completion marker is what makes the dir reusable — and, for the
    // caller, what makes it safe to hand to a daemon that will outlive us.
    const marker = try std.fs.path.join(allocator, &.{ dir1, complete_marker_name });
    defer allocator.free(marker);
    try testing.expect(dirExists(marker));

    // Second call with the same assets: identical path, and it must NOT be
    // re-extracted. A sentinel dropped in between proves the difference —
    // a re-extract would wipe this directory and take the sentinel with it.
    const sentinel = try std.fs.path.join(allocator, &.{ dir1, "sentinel.txt" });
    defer allocator.free(sentinel);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = sentinel, .data = "keep me" });

    const dir2 = try ensurePersistentIn(allocator, base, &assets);
    defer allocator.free(dir2);
    try testing.expectEqualStrings(dir1, dir2);
    try testing.expect(dirExists(sentinel));
    try readBackAndExpect(dir1, "index.html", "<html>one</html>");
}

test "ensurePersistentIn: changed asset bytes land in a different dir" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpBase(&tmp, &path_buf);

    const v1 = [_]AssetEntry{
        .{ .path = "/index.html", .content = "<html>v1</html>", .mime = "text/html" },
    };
    const v2 = [_]AssetEntry{
        .{ .path = "/index.html", .content = "<html>v2</html>", .mime = "text/html" },
    };

    const dir1 = try ensurePersistentIn(allocator, base, &v1);
    defer allocator.free(dir1);
    const dir2 = try ensurePersistentIn(allocator, base, &v2);
    defer allocator.free(dir2);

    // A new build must never be served out of the old dir: an old daemon
    // still pointing at `dir1` keeps serving v1, while the new desktop
    // hands `dir2` to anything it spawns.
    try testing.expect(!std.mem.eql(u8, dir1, dir2));
    try readBackAndExpect(dir1, "index.html", "<html>v1</html>");
    try readBackAndExpect(dir2, "index.html", "<html>v2</html>");
}

test "ensurePersistentIn: republishes a torn (marker-less) dir" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpBase(&tmp, &path_buf);

    const assets = [_]AssetEntry{
        .{ .path = "/index.html", .content = "<html>good</html>", .mime = "text/html" },
    };

    const dir1 = try ensurePersistentIn(allocator, base, &assets);
    defer allocator.free(dir1);

    // Simulate a run killed between "assets written" and "marker written"
    // (or a future process wiping the marker): drop the marker so the dir
    // looks incomplete, then truncate a file to make the corruption real.
    const marker = try std.fs.path.join(allocator, &.{ dir1, complete_marker_name });
    defer allocator.free(marker);
    try std.Io.Dir.cwd().deleteFile(testing.io, marker);
    const index = try std.fs.path.join(allocator, &.{ dir1, "index.html" });
    defer allocator.free(index);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = index, .data = "garbage" });

    const dir2 = try ensurePersistentIn(allocator, base, &assets);
    defer allocator.free(dir2);

    try testing.expectEqualStrings(dir1, dir2);
    try testing.expect(dirExists(marker));
    try readBackAndExpect(dir2, "index.html", "<html>good</html>");
}

test "ensurePersistentIn: zero assets still publishes a reusable dir" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // The CI stub build (-Dno-webapp-rebuild) embeds zero assets. It must
    // not error, and it must not rewrite the dir on every launch either —
    // otherwise the path handed to a long-lived daemon keeps changing.
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpBase(&tmp, &path_buf);

    const assets = [_]AssetEntry{};

    const dir1 = try ensurePersistentIn(allocator, base, &assets);
    defer allocator.free(dir1);
    const dir2 = try ensurePersistentIn(allocator, base, &assets);
    defer allocator.free(dir2);

    try testing.expectEqualStrings(dir1, dir2);
    try testing.expect(dirExists(dir1));
}

test "ensurePersistentStableIn: one stable path across versions, versioned dirs intact" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpBase(&tmp, &path_buf);

    const v1 = [_]AssetEntry{
        .{ .path = "/index.html", .content = "<html>v1</html>", .mime = "text/html" },
    };
    const v2 = [_]AssetEntry{
        .{ .path = "/index.html", .content = "<html>v2</html>", .mime = "text/html" },
    };

    const s1 = try ensurePersistentStableIn(allocator, base, &v1);
    defer allocator.free(s1);

    // The handed-out path is the stable link, not a versioned hash dir.
    try testing.expectEqualStrings("current", std.fs.path.basename(s1));
    try readBackAndExpect(s1, "index.html", "<html>v1</html>");

    const s2 = try ensurePersistentStableIn(allocator, base, &v2);
    defer allocator.free(s2);

    // Same stable string after an upgrade; it now serves the new version.
    try testing.expectEqualStrings(s1, s2);
    try readBackAndExpect(s2, "index.html", "<html>v2</html>");

    // The link really is a symlink pointing at the v2 versioned dir.
    const hash2 = try ensurePersistentIn(allocator, base, &v2);
    defer allocator.free(hash2);
    const link_target = try readLinkTarget(s2);
    defer allocator.free(link_target);
    try testing.expectEqualStrings(std.fs.path.basename(hash2), link_target);

    // The old versioned dir is untouched behind the link.
    const hash1 = try ensurePersistentIn(allocator, base, &v1);
    defer allocator.free(hash1);
    try readBackAndExpect(hash1, "index.html", "<html>v1</html>");

    // Same assets again: stable path unchanged, still serving.
    const s3 = try ensurePersistentStableIn(allocator, base, &v2);
    defer allocator.free(s3);
    try testing.expectEqualStrings(s1, s3);
    try readBackAndExpect(s3, "index.html", "<html>v2</html>");
}

/// Read a symlink's target into a caller-owned slice via libc readlink.
fn readLinkTarget(link_path: []const u8) ![]const u8 {
    const allocator = testing.allocator;
    var link_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const link_z = testCopyToNull(&link_buf, link_path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.c.readlink(link_z, &buf, buf.len);
    if (n <= 0) return error.ReadlinkFailed;
    return try allocator.dupe(u8, buf[0..@intCast(n)]);
}

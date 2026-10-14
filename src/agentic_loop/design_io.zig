/// File IO utilities for design-mode (v6).

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

/// Win32 API externs for cross-platform atomic-write/delete support. Loaded
/// at module scope only when `builtin.os.tag == .windows`.
const win32_apis = if (builtin.os.tag == .windows) struct {
    // HANDLE on Windows is `*anyopaque` (per `std.os.windows.HANDLE`).
    // CreateFileW returns INVALID_HANDLE_VALUE (a sentinel pointer) on
    // failure — it does NOT return NULL.
    const HANDLE = *anyopaque;
    const INVALID_HANDLE_VALUE_PTR: usize = std.math.maxInt(usize);
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(INVALID_HANDLE_VALUE_PTR);

    const GENERIC_WRITE: u32 = 0x40000000;
    const FILE_SHARE_NONE: u32 = 0;
    // Win32 share-mode bit flags (see Win32 CreateFileW docs).
    const FILE_SHARE_READ: u32 = 0x01;
    const FILE_SHARE_WRITE: u32 = 0x02;
    const FILE_SHARE_DELETE: u32 = 0x04;
    const CREATE_NEW: u32 = 1;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
    const MOVEFILE_REPLACE_EXISTING: u32 = 1;

    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: u32,
        lpNumberOfBytesWritten: ?*u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) u32;

    extern "kernel32" fn FlushFileBuffers(hFile: HANDLE) callconv(.winapi) u32;

    extern "kernel32" fn MoveFileExW(
        lpExistingFileName: [*:0]const u16,
        lpNewFileName: [*:0]const u16,
        dwFlags: u32,
    ) callconv(.winapi) u32;

    extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) u32;

    extern "kernel32" fn RemoveDirectoryW(lpFileName: [*:0]const u16) callconv(.winapi) u32;

    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) u32;

    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
} else struct {};

/// Convert a UTF-8 path slice to a NUL-terminated UTF-16 LE slice for Win32
/// APIs. Caller owns the returned slice.
fn pathToWideZ(path: []const u8, buf: []u16) ![:0]u16 {
    if (builtin.os.tag != .windows) unreachable;
    const needed = std.unicode.calcUtf16LeLen(path) catch return error.PathTooLong;
    // +1 for the NUL terminator.
    if (needed + 1 > buf.len) return error.PathTooLong;
    _ = std.unicode.utf8ToUtf16Le(buf[0..needed], path) catch
        return error.PathTooLong;
    buf[needed] = 0;
    return buf[0..needed :0];
}

/// Strip path-traversal characters from a user-provided name.
pub fn sanitizeFilename(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // Pass 1: replace unsafe chars with '_'.
    for (name) |ch| {
        switch (ch) {
            '/', '\\', 0 => try out.append(allocator, '_'),
            else => try out.append(allocator, ch),
        }
    }
    // Strip leading dots (hidden-file convention). Use orderedRemove
    // so each strip is O(n); the prefix is typically short so this is
    // fine in practice.
    while (out.items.len > 0 and out.items[0] == '.') {
        _ = out.orderedRemove(0);
    }
    // If everything was stripped, fall back to "untitled".
    if (out.items.len == 0) try out.appendSlice(allocator, "untitled");
    return out.toOwnedSlice(allocator);
}

/// Atomically write `content` to `path`: 1. Write content to `<path>.tmp` via
/// `c.open(O_WRONLY|O_CREAT|O_EXCL)` 2. `fsync(2)` the tmp file 3.
pub fn atomicWriteFile(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    _ = allocator;

    switch (builtin.os.tag) {
        .linux, .macos => return atomicWriteFilePosix(path, content),
        .windows => return atomicWriteFileWindows(path, content),
        else => @compileError("design_io.atomicWriteFile: unsupported platform " ++ @tagName(builtin.os.tag)),
    }
}

fn atomicWriteFilePosix(path: []const u8, content: []const u8) !void {
    // Build the `.tmp` path. We use std.fmt.bufPrint into a stack buffer and
    // then NUL-terminate the result.
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z_len = std.fmt.bufPrint(path_buf[0..path_buf.len - 1], "{s}", .{path}) catch
        return error.PathTooLong;
    path_buf[path_z_len.len] = 0;

    var tmp_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const tmp_z_len = std.fmt.bufPrint(
        tmp_buf[0..tmp_buf.len - 1],
        "{s}.tmp",
        .{path_z_len},
    ) catch return error.PathTooLong;
    tmp_buf[tmp_z_len.len] = 0;

    // 1. Open (or fail if .tmp already exists from a crashed prior run).
    const fd: c.fd_t = c.open(
        &tmp_buf,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true },
        @as(c.mode_t, 0o644),
    );
    if (fd < 0) return error.WriteTmpFailed;
    defer _ = c.close(fd);

    // 2. Write the entire content (loop on partial writes).
    var written: usize = 0;
    while (written < content.len) {
        const n = c.write(fd, content[written..].ptr, content[written..].len);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }

    // 3. fsync — guarantees the data is on stable storage before the rename
    // atomically swaps it into place. Without fsync, a power loss between
    // write and rename could surface as a .tmp file at the target.
    _ = c.fsync(fd);

    // 4. Atomic rename. POSIX guarantees that concurrent readers see
    // either the old or the new file, never a half-written one.
    if (c.rename(&tmp_buf, &path_buf) != 0) return error.RenameFailed;
}

fn atomicWriteFileWindows(path: []const u8, content: []const u8) !void {
    // Build wide-string versions of the target path and the `.tmp` path on a
    // stack buffer large enough for any realistic path. std.fs.max_path_bytes
    // is the POSIX max path length; Win32 paths can be longer (32767 wide
    var path_w_buf: [std.fs.max_path_bytes]u16 = undefined;
    const path_w = try pathToWideZ(path, &path_w_buf);

    // Append ".tmp" to path_w in-place. Sized at compile time so no
    // alloc; if path is near max_path_bytes the .tmp suffix won't fit
    // and we error out.
    var tmp_w_buf: [std.fs.max_path_bytes]u16 = undefined;
    if (path_w.len + 5 > tmp_w_buf.len) return error.PathTooLong;
    @memcpy(tmp_w_buf[0..path_w.len], path_w);
    tmp_w_buf[path_w.len] = '.';
    tmp_w_buf[path_w.len + 1] = 't';
    tmp_w_buf[path_w.len + 2] = 'm';
    tmp_w_buf[path_w.len + 3] = 'p';
    tmp_w_buf[path_w.len + 4] = 0;
    const tmp_w: [:0]u16 = tmp_w_buf[0..path_w.len + 4 :0];

    // 1. CreateFileW with CREATE_NEW (equivalent to O_CREAT|O_EXCL).
    const handle: win32_apis.HANDLE = win32_apis.CreateFileW(
        tmp_w.ptr,
        win32_apis.GENERIC_WRITE,
        win32_apis.FILE_SHARE_READ | win32_apis.FILE_SHARE_WRITE | win32_apis.FILE_SHARE_DELETE,
        null,
        win32_apis.CREATE_NEW,
        win32_apis.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    // Win32 NULL handle is rare for CreateFileW (it returns the sentinel)
    // but safe to check — both are failure indicators.
    const handle_addr: usize = @intFromPtr(handle);
    if (handle_addr == 0 or handle_addr == win32_apis.INVALID_HANDLE_VALUE_PTR) {
        return error.WriteTmpFailed;
    }

    // 2. Write the entire content (loop on partial writes). WriteFile
    // takes a u32 byte count per call — chunk to ~4 MB to stay under
    // the u32 limit for large content.
    var written_total: usize = 0;
    while (written_total < content.len) {
        const chunk_len: u32 = @intCast(@min(content.len - written_total, std.math.maxInt(u32)));
        var written_chunk: u32 = 0;
        const ok = win32_apis.WriteFile(
            handle,
            content[written_total..].ptr,
            chunk_len,
            &written_chunk,
            null,
        );
        if (ok == 0) {
            _ = win32_apis.CloseHandle(handle);
            return error.WriteFailed;
        }
        written_total += written_chunk;
        // WriteFile can return success with written_chunk=0 (broken
        // handle, disk full, etc.). Treat as failure to avoid an
        // infinite loop.
        if (written_chunk == 0) {
            _ = win32_apis.CloseHandle(handle);
            return error.WriteFailed;
        }
    }

    // 3. FlushFileBuffers — equivalent to fsync(2). Ensures the data
    // is on stable storage before the rename atomically swaps it in.
    _ = win32_apis.FlushFileBuffers(handle);

    // 4. Close the handle BEFORE MoveFileExW.
    _ = win32_apis.CloseHandle(handle);

    // 5. Atomic rename via MoveFileExW with MOVEFILE_REPLACE_EXISTING.
    if (win32_apis.MoveFileExW(tmp_w.ptr, path_w.ptr, win32_apis.MOVEFILE_REPLACE_EXISTING) == 0) {
        // Best-effort cleanup of the orphan .tmp so the next call doesn't
        // get ERROR_FILE_EXISTS from CREATE_NEW.
        _ = win32_apis.DeleteFileW(tmp_w.ptr);
        return error.RenameFailed;
    }
}

/// Unlink `path` if it exists. Does NOT error when the file is missing.
pub fn deleteFileIfExists(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    switch (builtin.os.tag) {
        .linux, .macos => return deleteFileIfExistsPosix(path),
        .windows => return deleteFileIfExistsWindows(path),
        else => @compileError("design_io.deleteFileIfExists: unsupported platform " ++ @tagName(builtin.os.tag)),
    }
}

/// Remove `path` if it is an EMPTY directory.
pub fn deleteDirectoryIfEmpty(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    switch (builtin.os.tag) {
        .linux, .macos => return deleteDirectoryIfEmptyPosix(path),
        .windows => return deleteDirectoryIfEmptyWindows(path),
        else => @compileError("design_io.deleteDirectoryIfEmpty: unsupported platform " ++ @tagName(builtin.os.tag)),
    }
}

fn deleteDirectoryIfEmptyPosix(path: []const u8) !void {
    // NUL-terminate into a stack buffer.
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z_len = std.fmt.bufPrint(path_buf[0..path_buf.len - 1], "{s}", .{path}) catch
        return error.PathTooLong;
    path_buf[path_z_len.len] = 0;

    const rc = c.rmdir(&path_buf);
    if (rc == 0) return; // success — directory was empty and is now gone
    const err = c.errno(rc);
    switch (err) {
        .NOENT => return, // missing → no-op
        .NOTEMPTY, .EXIST => return error.DirNotEmpty, // preserve user files
        .NOTDIR => return error.NotADirectory,
        else => return error.RmdirFailed,
    }
}

fn deleteDirectoryIfEmptyWindows(path: []const u8) !void {
    var path_w_buf: [std.fs.max_path_bytes]u16 = undefined;
    const path_w = try pathToWideZ(path, &path_w_buf);

    // RemoveDirectoryW returns nonzero on success, 0 on failure.
    const ok = win32_apis.RemoveDirectoryW(path_w.ptr);
    if (ok != 0) return;
    const err = win32_apis.GetLastError();
    switch (err) {
        2 => return,
        145 => return error.DirNotEmpty,
        267 => return error.NotADirectory,
        else => return error.RmdirFailed,
    }
}

fn deleteFileIfExistsPosix(path: []const u8) !void {
    // NUL-terminate into a stack buffer.
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z_len = std.fmt.bufPrint(path_buf[0..path_buf.len - 1], "{s}", .{path}) catch
        return error.PathTooLong;
    path_buf[path_z_len.len] = 0;

    const rc = c.unlink(&path_buf);
    if (rc == 0) return; // success
    const err = c.errno(rc);
    if (err == .NOENT) return; // missing → no-op
    return error.UnlinkFailed;
}

fn deleteFileIfExistsWindows(path: []const u8) !void {
    var path_w_buf: [std.fs.max_path_bytes]u16 = undefined;
    const path_w = try pathToWideZ(path, &path_w_buf);

    // DeleteFileW returns nonzero on success, 0 on failure. ERROR_FILE_NOT_FOUND
    // (2) means the file doesn't exist; we treat that as a no-op like
    // POSIX ENOENT. Any other error becomes error.UnlinkFailed.
    const ok = win32_apis.DeleteFileW(path_w.ptr);
    if (ok != 0) return;
    const err = win32_apis.GetLastError();
    if (err == 2) return; // ERROR_FILE_NOT_FOUND
    return error.UnlinkFailed;
}

/// Recursively delete a directory and all its contents. Walks the directory
/// tree depth-first, unlinks files, recurses into subdirectories, then rmdirs
/// the emptied directory.
pub fn deleteDirectoryRecursively(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !void {
    // `path` is the recursive-delete root.
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.RmdirFailed;

    // 1. Open the directory for iteration.
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return, // missing → no-op
        else => return err,
    };
    defer dir.close(io);

    // 2. Walk the entries; unlink files, recurse into directories.
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const entry_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(entry_path);
        switch (entry.kind) {
            .directory => try deleteDirectoryRecursively(allocator, io, entry_path),
            .file, .sym_link, .named_pipe, .unix_domain_socket, .event_port, .unknown => {
                try deleteFileIfExists(allocator, entry_path);
            },
            else => {}, // skip device files etc.
        }
    }

    // 3. rmdir the (now-empty) directory itself.
    switch (builtin.os.tag) {
        .linux, .macos => {
            var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
            const path_z_len = std.fmt.bufPrint(path_buf[0..path_buf.len - 1], "{s}", .{path}) catch
                return error.PathTooLong;
            path_buf[path_z_len.len] = 0;
            if (c.rmdir(&path_buf) != 0) return error.RmdirFailed;
        },
        .windows => {
            var path_w_buf: [std.fs.max_path_bytes]u16 = undefined;
            const path_w = try pathToWideZ(path, &path_w_buf);
            if (win32_apis.RemoveDirectoryW(path_w.ptr) == 0) return error.RmdirFailed;
        },
        else => @compileError("design_io.deleteDirectoryRecursively: unsupported platform " ++ @tagName(builtin.os.tag)),
    }
}


// ─── Inline tests (formerly design_io_test.zig) ──────────────────────────
// Tests for sanitizeFilename, atomicWriteFile, deleteFileIfExists,
// deleteDirectoryRecursively. Inlined here per the agentic_loop/ convention.

const testing = std.testing;

// ─── sanitizeFilename ─────────────────────────────────────────────────────

test "sanitizeFilename replaces /, \\, NUL with _" {
    {
        const result = try sanitizeFilename(testing.allocator, "login/card");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("login_card", result);
    }
    {
        const result = try sanitizeFilename(testing.allocator, "win\\card");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("win_card", result);
    }
    // NUL gets replaced with '_' — the binary buffer can't contain
    // a literal NUL in a Zig slice but a 1-char input gets the
    // single NUL replaced.
    var buf: [1]u8 = .{0};
    const result = try sanitizeFilename(testing.allocator, &buf);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("_", result);
}

test "sanitizeFilename strips leading dots" {
    {
        const result = try sanitizeFilename(testing.allocator, ".hidden");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("hidden", result);
    }
    {
        const result = try sanitizeFilename(testing.allocator, "..card");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("card", result);
    }
    // "../foo" → pass 1: ".._foo" → leading-dot strip: "_foo".
    // (Both dots are at the start, so the second pass strips them
    // away, leaving only the substituted underscore.)
    {
        const result = try sanitizeFilename(testing.allocator, "../foo");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("_foo", result);
    }
}

test "sanitizeFilename returns untitled for empty input (no fallback on slashes/dots)" {
    // Empty input → untitled.
    {
        const result = try sanitizeFilename(testing.allocator, "");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("untitled", result);
    }
    // "..." → pass 1 keeps the dots → leading-dot strip removes
    // them all → empty → "untitled".
    {
        const result = try sanitizeFilename(testing.allocator, "...");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("untitled", result);
    }
    // "////" → pass 1 replaces each / with _ → "____" — no leading
    // dots, no empty result, so the literal "____" is returned.
    {
        const result = try sanitizeFilename(testing.allocator, "////");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("____", result);
    }
}

// ─── atomicWriteFile ──────────────────────────────────────────────────────

test "atomicWriteFile writes content that can be read back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the tmpdir's absolute directory path first (dir.realPath,
    // not file.realPathFile which requires the file to exist).
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmpdir_path: []const u8 = dir_buf[0..dir_len];
    const path = try std.fs.path.join(testing.allocator, &.{ tmpdir_path, "test.html" });
    defer testing.allocator.free(path);

    try atomicWriteFile(testing.allocator, path, "<div>hello</div>");

    // Read back. Uses Dir.readFileAlloc per project memory
    // `zig-0.16-stdfs-cwd-removed.md` (std.fs.cwd() is gone in 0.16).
    const content = try tmp.dir.readFileAlloc(testing.io, "test.html", testing.allocator, .limited(1024));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("<div>hello</div>", content);
}

test "atomicWriteFile overwrites an existing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmpdir_path: []const u8 = dir_buf[0..dir_len];
    const path = try std.fs.path.join(testing.allocator, &.{ tmpdir_path, "test.html" });
    defer testing.allocator.free(path);

    try atomicWriteFile(testing.allocator, path, "first");
    try atomicWriteFile(testing.allocator, path, "second");

    const content = try tmp.dir.readFileAlloc(testing.io, "test.html", testing.allocator, .limited(1024));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("second", content);
}

// ─── deleteFileIfExists ──────────────────────────────────────────────────

test "deleteDirectoryRecursively refuses a relative path instead of aborting" {
    // The first thing the helper does is `openDirAbsolute`, which asserts
    // `path.isAbsolute(...)`; in Debug/ReleaseSafe that assertion ABORTS the
    // whole process instead of returning an error.
    const result = deleteDirectoryRecursively(testing.allocator, testing.io, "relative/design");
    try testing.expectError(error.RmdirFailed, result);
}

test "deleteFileIfExists succeeds when the file is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmpdir_path: []const u8 = dir_buf[0..dir_len];
    const path = try std.fs.path.join(testing.allocator, &.{ tmpdir_path, "never-existed.html" });
    defer testing.allocator.free(path);

    // No file at `path` — should NOT error, just return successfully.
    try deleteFileIfExists(testing.allocator, path);
}

test "deleteFileIfExists removes an existing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmpdir_path: []const u8 = dir_buf[0..dir_len];
    const path = try std.fs.path.join(testing.allocator, &.{ tmpdir_path, "to-delete.html" });
    defer testing.allocator.free(path);

    try atomicWriteFile(testing.allocator, path, "delete me");

    // Sanity: the file exists.
    const stat_before = try tmp.dir.statFile(testing.io, "to-delete.html", .{});
    try testing.expect(stat_before.kind == .file);

    // Delete it.
    try deleteFileIfExists(testing.allocator, path);

    // After delete, file is gone.
    const stat_after_result = tmp.dir.statFile(testing.io, "to-delete.html", .{});
    try testing.expectError(error.FileNotFound, stat_after_result);
}

// ─── deleteDirectoryIfEmpty ───────────────────────────────────────────────

test "deleteDirectoryIfEmpty removes an empty directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmpdir_path: []const u8 = dir_buf[0..dir_len];
    const empty_path = try std.fs.path.join(testing.allocator, &.{ tmpdir_path, "empty" });
    defer testing.allocator.free(empty_path);

    // Create the empty directory inside the test tmpdir. Uses
    // Io.Dir.cwd().createDirPath which is the Io-native mkdir-p
    // (per project memory zig-0.16-stdfs-cwd-removed.md).
    try std.Io.Dir.cwd().createDirPath(testing.io, empty_path);

    // Sanity: it exists.
    const stat_before = try tmp.dir.statFile(testing.io, "empty", .{});
    try testing.expect(stat_before.kind == .directory);

    // deleteDirectoryIfEmpty should succeed.
    try deleteDirectoryIfEmpty(testing.allocator, empty_path);

    // After: directory is gone.
    const stat_after_result = tmp.dir.statFile(testing.io, "empty", .{});
    try testing.expectError(error.FileNotFound, stat_after_result);
}

test "deleteDirectoryIfEmpty succeeds when the path does not exist (no-op)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmpdir_path: []const u8 = dir_buf[0..dir_len];
    const never_existed = try std.fs.path.join(testing.allocator, &.{ tmpdir_path, "never-existed" });
    defer testing.allocator.free(never_existed);

    // Should NOT error — ENOENT is swallowed.
    try deleteDirectoryIfEmpty(testing.allocator, never_existed);
}

test "deleteDirectoryIfEmpty returns DirNotEmpty when a file remains inside" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmpdir_path: []const u8 = dir_buf[0..dir_len];
    const non_empty_path = try std.fs.path.join(testing.allocator, &.{ tmpdir_path, "non-empty" });
    defer testing.allocator.free(non_empty_path);
    const user_note_path = try std.fs.path.join(testing.allocator, &.{ non_empty_path, "user-note.txt" });
    defer testing.allocator.free(user_note_path);

    // Create a directory that contains a user file.
    try std.Io.Dir.cwd().createDirPath(testing.io, non_empty_path);
    try atomicWriteFile(testing.allocator, user_note_path, "user file");

    // deleteDirectoryIfEmpty should refuse (DirNotEmpty) — protecting
    // the user's file from being swept away with the page.
    try testing.expectError(error.DirNotEmpty, deleteDirectoryIfEmpty(testing.allocator, non_empty_path));

    // The user's file MUST still exist.
    const stat_after = try tmp.dir.statFile(testing.io, "non-empty/user-note.txt", .{});
    try testing.expect(stat_after.kind == .file);
}

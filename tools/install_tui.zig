// tools/install_tui.zig Cross-platform installer for the `pabrik-tui` binary.
// Usage (invoked by `zig build install-tui`): install_tui <source-path> Where
// <source-path> is the built binary (e.g. zig-out/bin/pabrik-tui).

const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    _ = args_iter.next() orelse return error.MissingExeName;
    const src_path = args_iter.next() orelse {
        std.debug.print("Usage: install_tui <source-path>\n", .{});
        return error.MissingSourcePath;
    };

    const dest_path = try resolveDestPath(allocator, init);
    defer allocator.free(dest_path);

    // Ensure parent directory exists.
    if (std.fs.path.dirname(dest_path)) |dir| {
        try mkdirsRecursive(dir);
    }

    // Copy file.
    try copyFile(src_path, dest_path);

    // chmod 0755 on Unix so the binary is executable.
    if (builtin.os.tag != .windows) {
        try chmodExecutable(dest_path);
    }

    std.debug.print("Installed pabrik-tui → {s}\n", .{dest_path});

    // Hint about PATH if the dest dir is not on PATH.
    if (builtin.os.tag != .windows) {
        const bin_dir = std.fs.path.dirname(dest_path) orelse dest_path;
        if (!isOnPath(bin_dir, init)) {
            std.debug.print(
                "NOTE: {s} is not on your PATH. Add it with:\n  export PATH=\"$HOME/.local/bin:$PATH\"\n  (add to ~/.bashrc or ~/.zshrc to persist)\n",
                .{bin_dir},
            );
        }
    } else {
        const bin_dir = std.fs.path.dirname(dest_path) orelse dest_path;
        std.debug.print(
            "NOTE: ensure {s} is on your PATH (System Properties → Environment Variables → Path).\n",
            .{bin_dir},
        );
    }
}

/// Resolve the destination path for the current host OS.
fn resolveDestPath(allocator: std.mem.Allocator, init: std.process.Init) ![]const u8 {
    return switch (builtin.os.tag) {
        .windows => resolveDestWindows(allocator, init),
        .macos => resolveDestMacos(allocator, init),
        .linux => resolveDestLinux(allocator, init),
        else => resolveDestLinux(allocator, init),
    };
}

fn resolveDestLinux(allocator: std.mem.Allocator, init: std.process.Init) ![]const u8 {
    const home = getEnv(init, "HOME") orelse {
        std.debug.print("ERROR: $HOME is not set — cannot determine install destination.\n", .{});
        return error.HomeNotSet;
    };
    return std.fs.path.join(allocator, &.{ home, ".local", "bin", "pabrik-tui" });
}

fn resolveDestMacos(allocator: std.mem.Allocator, init: std.process.Init) ![]const u8 {
    // macOS: same as Linux — $HOME/.local/bin is the standard user bin
    // for CLI tools (used by pip, cargo, etc.). We also ensure the dir
    // exists even if the user has never used it before.
    const home = getEnv(init, "HOME") orelse {
        std.debug.print("ERROR: $HOME is not set — cannot determine install destination.\n", .{});
        return error.HomeNotSet;
    };
    return std.fs.path.join(allocator, &.{ home, ".local", "bin", "pabrik-tui" });
}

fn resolveDestWindows(allocator: std.mem.Allocator, init: std.process.Init) ![]const u8 {
    // Priority: 1. %LOCALAPPDATA%\pabrik\bin\pabrik-tui.exe (e.g.
    // C:\Users\you\AppData\Local) 2. %APPDATA%\pabrik\bin\pabrik-tui.exe
    // (e.g.
    if (getEnv(init, "LOCALAPPDATA")) |local_app_data| {
        return std.fs.path.join(allocator, &.{ local_app_data, "pabrik", "bin", "pabrik-tui.exe" });
    }
    if (getEnv(init, "APPDATA")) |app_data| {
        return std.fs.path.join(allocator, &.{ app_data, "pabrik", "bin", "pabrik-tui.exe" });
    }
    if (getEnv(init, "USERPROFILE")) |user_profile| {
        return std.fs.path.join(allocator, &.{ user_profile, ".local", "bin", "pabrik-tui.exe" });
    }
    if (getEnv(init, "HOME")) |home| {
        return std.fs.path.join(allocator, &.{ home, ".local", "bin", "pabrik-tui.exe" });
    }
    std.debug.print("ERROR: cannot determine Windows install destination — none of LOCALAPPDATA, APPDATA, USERPROFILE, HOME is set.\n", .{});
    return error.HomeNotSet;
}

/// Get env var value from init.environ_map. Returns null if not set or empty.
/// The returned slice is valid for the lifetime of `init` (no allocation needed).
fn getEnv(init: std.process.Init, key: []const u8) ?[]const u8 {
    const val = init.environ_map.get(key) orelse return null;
    if (val.len == 0) return null;
    return val;
}

/// Recursively create directories (mkdir -p).
fn mkdirsRecursive(path: []const u8) !void {
    if (path.len == 0 or (path.len == 1 and path[0] == '.')) return;

    // Check if already exists.
    var path_buf: [8192:0]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    if (std.c.access(@ptrCast(&path_buf), 0) == 0) return;

    // Recurse on parent.
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len < path.len) try mkdirsRecursive(parent);
    }

    if (std.c.mkdir(@ptrCast(&path_buf), @as(std.c.mode_t, 0o755)) != 0) {
        const errno_val = std.c.errno(-1);
        if (errno_val != .EXIST) return error.MkdirFailed;
    }
}

/// Copy file from src to dest (binary-safe, handles large files).
fn copyFile(src: []const u8, dest: []const u8) !void {
    var src_buf: [8192:0]u8 = undefined;
    if (src.len >= src_buf.len) return error.PathTooLong;
    @memcpy(src_buf[0..src.len], src);
    src_buf[src.len] = 0;

    var dest_buf: [8192:0]u8 = undefined;
    if (dest.len >= dest_buf.len) return error.PathTooLong;
    @memcpy(dest_buf[0..dest.len], dest);
    dest_buf[dest.len] = 0;

    const src_fd = std.c.open(@ptrCast(&src_buf), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
    if (src_fd < 0) {
        std.debug.print("ERROR: cannot open source file {s}\n", .{src});
        return error.OpenSourceFailed;
    }
    defer _ = std.c.close(src_fd);

    const dest_fd = std.c.open(@ptrCast(&dest_buf), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o755));
    if (dest_fd < 0) {
        std.debug.print("ERROR: cannot create destination file {s}\n", .{dest});
        return error.OpenDestFailed;
    }
    defer _ = std.c.close(dest_fd);

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n_read = std.c.read(src_fd, &buf, buf.len);
        if (n_read < 0) return error.ReadFailed;
        if (n_read == 0) break;
        const n: usize = @intCast(n_read);
        var written: usize = 0;
        while (written < n) {
            const n_written = std.c.write(dest_fd, buf[written..n].ptr, n - written);
            if (n_written < 0) return error.WriteFailed;
            const w: usize = @intCast(n_written);
            if (w == 0) return error.WriteFailed;
            written += w;
        }
    }
}

fn chmodExecutable(path: []const u8) !void {
    var buf: [8192:0]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = std.c.chmod(@ptrCast(&buf), @as(std.c.mode_t, 0o755));
    if (rc != 0) {
        // Non-fatal — the file was copied, just warn.
        std.debug.print("warning: chmod 0755 failed for {s} (errno={d})\n", .{ path, @intFromEnum(std.c.errno(rc)) });
    }
}

/// Check if dir is on PATH (simple substring check).
fn isOnPath(dir: []const u8, init: std.process.Init) bool {
    const path_val = init.environ_map.get("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_val, ':');
    while (it.next()) |entry| {
        if (std.mem.eql(u8, std.mem.trim(u8, entry, " "), dir)) return true;
    }
    return false;
}

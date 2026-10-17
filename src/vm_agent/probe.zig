//! Static multicall fixture for the guest image: the protocol tests need
//! *something* to exec, and the product image ships a busybox instead (see
//! docs/plans/2026-10-17-workspace-is-a-microvm.md §20).

const std = @import("std");
const linux = std.os.linux;

const max_args = 32;
const max_text = 4096;

fn write(fd: linux.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return;
        off += rc;
    }
}

fn slurp(path: [*:0]const u8, buf: []u8) usize {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return 0;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS) return 0;
    return n;
}

/// NUL-separated words out of a kernel-provided text blob.
fn splitNul(text: []u8, out: *[max_args][]const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, 0);
    while (it.next()) |word| {
        if (word.len == 0) continue;
        if (count == max_args) break;
        out[count] = word;
        count += 1;
    }
    return count;
}

/// cmdline words are NUL-terminated in place, so the sentinel is already there.
fn cpath(word: []const u8) [*:0]const u8 {
    return @ptrCast(word.ptr);
}

fn envValue(blob: []const u8, name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, blob, 0);
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], name)) return entry[eq + 1 ..];
    }
    return "";
}

pub fn main() u8 {
    var text: [max_text]u8 = undefined;
    var argv: [max_args][]const u8 = undefined;
    const argv_len = splitNul(text[0..slurp("/proc/self/cmdline", &text)], &argv);
    if (argv_len < 2) {
        write(2, "usage: probe <echo|id|write|read|sleep|fail|env> [args...]\n");
        return 2;
    }
    const command = argv[1];
    const rest = argv[2..argv_len];

    if (std.mem.eql(u8, command, "echo")) {
        for (rest, 0..) |arg, i| {
            if (i != 0) write(1, " ");
            write(1, arg);
        }
        write(1, "\n");
        return 0;
    }
    if (std.mem.eql(u8, command, "id")) {
        var buf: [64]u8 = undefined;
        write(1, std.fmt.bufPrint(&buf, "uid={d} gid={d}\n", .{ linux.getuid(), linux.getgid() }) catch "uid=?\n");
        return 0;
    }
    if (std.mem.eql(u8, command, "env")) {
        var env_blob: [max_text]u8 = undefined;
        const blob = env_blob[0..slurp("/proc/self/environ", &env_blob)];
        var buf: [256]u8 = undefined;
        for ([_][]const u8{ "HOME", "PATH", "LANG", "TERM" }) |name| {
            const line = std.fmt.bufPrint(&buf, "{s}={s}\n", .{ name, envValue(blob, name) }) catch continue;
            write(1, line);
        }
        return 0;
    }
    if (std.mem.eql(u8, command, "write")) {
        if (rest.len < 2) {
            write(2, "usage: probe write <path> <text>\n");
            return 2;
        }
        const rc = linux.open(cpath(rest[0]), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        if (linux.errno(rc) != .SUCCESS) {
            write(2, "probe: write failed\n");
            return 1;
        }
        const fd: linux.fd_t = @intCast(rc);
        defer _ = linux.close(fd);
        write(fd, rest[1]);
        write(fd, "\n");
        // Without this the guest's writeback can still be in VM page cache when
        // the VM is stopped, and the image on the host would not have the file.
        _ = linux.fsync(fd);
        var buf: [256]u8 = undefined;
        write(1, std.fmt.bufPrint(&buf, "wrote {s}\n", .{rest[0]}) catch "wrote\n");
        return 0;
    }
    if (std.mem.eql(u8, command, "read")) {
        if (rest.len < 1) {
            write(2, "usage: probe read <path>\n");
            return 2;
        }
        var buf: [max_text]u8 = undefined;
        const n = slurp(cpath(rest[0]), &buf);
        if (n == 0) {
            write(2, "probe: read failed\n");
            return 1;
        }
        write(1, buf[0..n]);
        return 0;
    }
    if (std.mem.eql(u8, command, "sleep")) {
        const ms = if (rest.len > 0) (std.fmt.parseInt(u64, rest[0], 10) catch 0) else 0;
        const ts = linux.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        _ = linux.nanosleep(&ts, null);
        write(1, "slept\n");
        return 0;
    }
    if (std.mem.eql(u8, command, "fail")) {
        const code = if (rest.len > 0) (std.fmt.parseInt(u8, rest[0], 10) catch 1) else 1;
        write(2, "probe: failing on purpose\n");
        return code;
    }
    write(2, "usage: probe <echo|id|write|read|sleep|fail|env> [args...]\n");
    return 2;
}

//! The size a workspace's VM boots with, recorded beside the VM's own state.
//! A missing or unreadable record means "the manager's defaults", never a
//! failure to boot.

const std = @import("std");
const linux = std.os.linux;
const vm_client = @import("vm_client.zig");
const vm_limits = @import("vm_limits.zig");

pub const min_vcpus = vm_limits.min_vcpus;
pub const max_vcpus = vm_limits.max_vcpus;
pub const min_mem_mib = vm_limits.min_mem_mib;
pub const max_mem_mib = vm_limits.max_mem_mib;

/// A workspace's own size. Null means "use the manager's default".
pub const Override = struct {
    vcpus: ?u32 = null,
    mem_mib: ?u32 = null,
};

/// `<root>/workspaces/<id>/vm.spec`.
pub fn pathFor(buf: []u8, root: []const u8, workspace_id: []const u8) ?[]const u8 {
    if (!vm_limits.validWorkspaceId(workspace_id)) return null;
    return std.fmt.bufPrint(buf, "{s}/workspaces/{s}/vm.spec", .{ root, workspace_id }) catch null;
}

/// Parse the `key=value` record. Unknown keys, bad numbers and out-of-range
/// values are ignored one by one.
pub fn parse(text: []const u8) Override {
    var out: Override = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "vcpus")) {
            const n = std.fmt.parseInt(u32, value, 10) catch continue;
            if (n >= min_vcpus and n <= max_vcpus) out.vcpus = n;
        } else if (std.mem.eql(u8, key, "mem_mib")) {
            const n = std.fmt.parseInt(u32, value, 10) catch continue;
            if (n >= min_mem_mib and n <= max_mem_mib) out.mem_mib = n;
        }
    }
    return out;
}

pub fn render(allocator: std.mem.Allocator, override: Override) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    if (override.vcpus) |v| try out.writer.print("vcpus={d}\n", .{v});
    if (override.mem_mib) |m| try out.writer.print("mem_mib={d}\n", .{m});
    return out.toOwnedSlice();
}

/// The workspace's record, or an empty override when there is none to read.
pub fn read(root: []const u8, workspace_id: []const u8) Override {
    var path_buf: [4096]u8 = undefined;
    const path = pathFor(&path_buf, root, workspace_id) orelse return .{};
    var text_buf: [512]u8 = undefined;
    const n = readFile(path, &text_buf) orelse return .{};
    return parse(text_buf[0..n]);
}

/// Record the workspace's size. The caller has already ensured the VM
/// directory exists (a stop creates it).
pub fn write(allocator: std.mem.Allocator, root: []const u8, workspace_id: []const u8, override: Override) !void {
    var path_buf: [4096]u8 = undefined;
    const path = pathFor(&path_buf, root, workspace_id) orelse return error.BadWorkspaceId;
    const text = try render(allocator, override);
    defer allocator.free(text);
    var staged_buf: [4096]u8 = undefined;
    const staged = std.fmt.bufPrint(&staged_buf, "{s}.tmp", .{path}) catch return error.PathTooLong;
    if (!writeFile(staged, text)) return error.WriteFailed;
    if (!renameFile(staged, path)) return error.WriteFailed;
}

/// Forget the record: the workspace goes back to the manager's defaults.
pub fn clear(root: []const u8, workspace_id: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    const path = pathFor(&path_buf, root, workspace_id) orelse return;
    remove(path);
}

fn readFile(path: []const u8, buf: []u8) ?usize {
    var path_buf: [4096]u8 = undefined;
    const z = vm_client.cstr(path, &path_buf) orelse return null;
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < buf.len) {
        const n = linux.read(fd, buf.ptr + off, buf.len - off);
        if (linux.errno(n) != .SUCCESS) return null;
        if (n == 0) break;
        off += n;
    }
    return off;
}

fn writeFile(path: []const u8, bytes: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const z = vm_client.cstr(path, &path_buf) orelse return false;
    const rc = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return false;
        off += n;
    }
    return true;
}

fn renameFile(from: []const u8, to: []const u8) bool {
    var from_buf: [4096]u8 = undefined;
    var to_buf: [4096]u8 = undefined;
    const a = vm_client.cstr(from, &from_buf) orelse return false;
    const b = vm_client.cstr(to, &to_buf) orelse return false;
    return linux.errno(linux.rename(a, b)) == .SUCCESS;
}

fn remove(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    const z = vm_client.cstr(path, &buf) orelse return;
    _ = linux.unlink(z);
}

const testing = std.testing;

test "a recorded size reads back as it was written" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root = path_buf[0..n];
    try tmp.dir.createDirPath(testing.io, "workspaces/ws_1");

    try write(alloc, root, "ws_1", .{ .vcpus = 4, .mem_mib = 2048 });
    const back = read(root, "ws_1");
    try testing.expectEqual(@as(?u32, 4), back.vcpus);
    try testing.expectEqual(@as(?u32, 2048), back.mem_mib);

    clear(root, "ws_1");
    const gone = read(root, "ws_1");
    try testing.expect(gone.vcpus == null);
    try testing.expect(gone.mem_mib == null);
}

test "a workspace with no record has no override" {
    const override = read("/nonexistent-root", "ws_missing");
    try testing.expect(override.vcpus == null);
    try testing.expect(override.mem_mib == null);
}

test "the record parser ignores unknown keys, bad numbers and out-of-range values" {
    const override = parse(
        \\# a comment
        \\vcpus=2
        \\mem_mib=nope
        \\something=else
        \\vcpus=99
    );
    // `vcpus=99` is out of range, so the earlier `vcpus=2` stands.
    try testing.expectEqual(@as(?u32, 2), override.vcpus);
    try testing.expect(override.mem_mib == null);
}

test "an id that could escape a path never becomes one" {
    var buf: [4096]u8 = undefined;
    try testing.expect(pathFor(&buf, "/root", "../escape") == null);
    try testing.expect(pathFor(&buf, "/root", "ws_1") != null);
}

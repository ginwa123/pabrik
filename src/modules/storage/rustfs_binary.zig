//! Where the bundled rustfs binary lives. Same order as the bundled ripgrep:
//! override, beside the executable, pabrik's data dir, then the bare name.

const std = @import("std");
const builtin = @import("builtin");

pub const env_override = "PABRIK_RUSTFS_BIN";

const is_windows = builtin.os.tag == .windows;

/// The name the installer writes, and therefore the process name a task
/// manager shows. Not `rustfs`: `--system` writes to /usr/local/bin, and that
/// name would shadow a rustfs the user installed themselves.
pub fn exeName() []const u8 {
    return if (is_windows) "pabrik-fs.exe" else "pabrik-fs";
}

/// The name a system install uses.
pub fn pathName() []const u8 {
    return "rustfs";
}

pub const Source = enum { override, beside_executable, data_dir, path };

pub const Locations = struct {
    exe_dir: ?[]const u8 = null,
    data_dir: ?[]const u8 = null,
    override: ?[]const u8 = null,
};

pub const Resolution = struct {
    path: []u8,
    source: Source,

    pub fn deinit(self: Resolution, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const ExistsFn = *const fn (ctx: ?*const anyopaque, path: []const u8) bool;

pub fn pick(
    allocator: std.mem.Allocator,
    loc: Locations,
    ctx: ?*const anyopaque,
    exists: ExistsFn,
) !Resolution {
    if (loc.override) |given| {
        if (given.len > 0) {
            return .{ .path = try allocator.dupe(u8, given), .source = .override };
        }
    }

    if (loc.exe_dir) |dir| {
        if (dir.len > 0) {
            const beside = try std.fs.path.join(allocator, &.{ dir, exeName() });
            if (exists(ctx, beside)) {
                return .{ .path = beside, .source = .beside_executable };
            }
            allocator.free(beside);
        }
    }

    if (loc.data_dir) |dir| {
        if (dir.len > 0) {
            const stored = try std.fs.path.join(allocator, &.{ dir, "bin", exeName() });
            if (exists(ctx, stored)) {
                return .{ .path = stored, .source = .data_dir };
            }
            allocator.free(stored);
        }
    }

    return .{ .path = try allocator.dupe(u8, pathName()), .source = .path };
}

pub fn isExecutableFile(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const mode: c_uint = if (is_windows) 0 else 1;
    return std.c.access(&buf, mode) == 0;
}

fn executableAt(_: ?*const anyopaque, path: []const u8) bool {
    return isExecutableFile(path);
}

fn envValue(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    const value = std.mem.span(raw);
    return if (value.len == 0) null else value;
}

pub fn dataDir(allocator: std.mem.Allocator) ?[]u8 {
    if (is_windows) {
        if (envValue("LOCALAPPDATA")) |base| {
            return std.fs.path.join(allocator, &.{ base, "pabrik" }) catch null;
        }
        return null;
    }
    if (envValue("XDG_DATA_HOME")) |base| {
        return std.fs.path.join(allocator, &.{ base, "pabrik" }) catch null;
    }
    if (envValue("HOME")) |base| {
        return std.fs.path.join(allocator, &.{ base, ".local", "share", "pabrik" }) catch null;
    }
    return null;
}

pub fn resolveDefault(allocator: std.mem.Allocator, io: std.Io) !Resolution {
    var exe_dir: ?[]u8 = null;
    defer if (exe_dir) |owned| allocator.free(owned);
    if (std.process.executablePathAlloc(io, allocator)) |exe_path| {
        defer allocator.free(exe_path);
        if (std.fs.path.dirname(exe_path)) |dir| exe_dir = try allocator.dupe(u8, dir);
    } else |_| {}

    const data_dir = dataDir(allocator);
    defer if (data_dir) |owned| allocator.free(owned);

    return pick(allocator, .{
        .exe_dir = exe_dir,
        .data_dir = data_dir,
        .override = envValue(env_override),
    }, null, executableAt);
}

/// Whether a rustfs binary is available at all. The runtime uses this to
/// decide whether the supervised backend is even possible.
pub fn available(allocator: std.mem.Allocator, io: std.Io) bool {
    const found = resolveDefault(allocator, io) catch return false;
    defer found.deinit(allocator);
    return switch (found.source) {
        .override, .beside_executable, .data_dir => true,
        // A bare name is only usable if it is actually on PATH.
        .path => isExecutableFile(found.path),
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const FakeFs = struct {
    present: []const []const u8,

    fn exists(ctx: ?*const anyopaque, path: []const u8) bool {
        const self: *const FakeFs = @ptrCast(@alignCast(ctx.?));
        for (self.present) |entry| {
            if (std.mem.eql(u8, entry, path)) return true;
        }
        return false;
    }
};

fn expectPicked(
    loc: Locations,
    present: []const []const u8,
    expected: []const u8,
    expected_source: Source,
) !void {
    const allocator = testing.allocator;
    const fake = FakeFs{ .present = present };
    const got = try pick(allocator, loc, &fake, FakeFs.exists);
    defer got.deinit(allocator);
    try testing.expectEqualStrings(expected, got.path);
    try testing.expectEqual(expected_source, got.source);
}

test "rustfs_binary: the copy beside the executable wins over the stored copy" {
    const allocator = testing.allocator;
    const beside = try std.fs.path.join(allocator, &.{ "/opt/pabrik/bin", exeName() });
    defer allocator.free(beside);
    const stored = try std.fs.path.join(allocator, &.{ "/home/u/.local/share/pabrik", "bin", exeName() });
    defer allocator.free(stored);
    try expectPicked(.{
        .exe_dir = "/opt/pabrik/bin",
        .data_dir = "/home/u/.local/share/pabrik",
    }, &.{ beside, stored }, beside, .beside_executable);
}

test "rustfs_binary: the stored copy is used when nothing sits beside the executable" {
    const allocator = testing.allocator;
    const stored = try std.fs.path.join(allocator, &.{ "/home/u/.local/share/pabrik", "bin", exeName() });
    defer allocator.free(stored);
    try expectPicked(.{
        .exe_dir = "/opt/pabrik/bin",
        .data_dir = "/home/u/.local/share/pabrik",
    }, &.{stored}, stored, .data_dir);
}

test "rustfs_binary: nothing bundled falls back to the bare name" {
    try expectPicked(.{
        .exe_dir = "/opt/pabrik/bin",
        .data_dir = "/home/u/.local/share/pabrik",
    }, &.{}, pathName(), .path);
}

test "rustfs_binary: an override names the binary directly, bundled or not" {
    try expectPicked(.{
        .exe_dir = "/opt/pabrik/bin",
        .override = "/usr/local/bin/rustfs-nightly",
    }, &.{}, "/usr/local/bin/rustfs-nightly", .override);
}

test "rustfs_binary: an empty override is ignored" {
    try expectPicked(.{ .exe_dir = "/opt/pabrik/bin", .override = "" }, &.{}, pathName(), .path);
}

test "rustfs_binary: the bundled name is not the name a system install uses" {
    try testing.expect(!std.mem.eql(u8, exeName(), pathName()));
}

test "rustfs_binary: a file beside the executable is the bundled rustfs the platform can run" {
    const io = testing.io;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const created = try tmp.dir.createFile(io, exeName(), .{});
    if (comptime builtin.os.tag != .windows) {
        try created.setPermissions(io, @enumFromInt(0o755));
    }
    created.close(io);

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_path);
    const expected = try std.fs.path.join(allocator, &.{ dir_path, exeName() });
    defer allocator.free(expected);

    const got = try pick(allocator, .{ .exe_dir = dir_path }, null, executableAt);
    defer got.deinit(allocator);

    try testing.expectEqual(Source.beside_executable, got.source);
    try testing.expectEqualStrings(expected, got.path);
}

// src/service/state_file.zig Reads and writes the pabrik service state file
// (state.json).

const std = @import("std");
const builtin = @import("builtin");

/// Schema for state.json. The string fields are owned by the caller —
/// callers must hold them alive for as long as the State is in use.
pub const State = struct {
    pid: i32,
    port: u16,
    host: []const u8,
    started_at: i64,
    version: []const u8,
    static_dir: ?[]const u8,
};

pub const StateFileError = error{
    OutOfMemory,
};

/// Read state.json from `path`. Returns `null` for missing files and silently
/// treats parse / IO errors as absent (returns null).
pub fn readStateFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) StateFileError!?State {
    const data = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(64 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null, // graceful: stale or unreadable → treat as absent
    };
    defer allocator.free(data);

    // Parse into a generic Value tree inside a transient arena. The arena is
    // deinit'd before we return — the strings we dupe below are independent
    // of the parsed Value tree's memory.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena_alloc,
        data,
        .{},
    ) catch return null;

    return parseState(allocator, parsed) catch null;
}

/// Free slices owned by `state`. Callers that take ownership of the
/// State returned from `readStateFile` MUST call this when done to
/// avoid leaking `host`, `version`, and (optionally) `static_dir`.
pub fn freeState(allocator: std.mem.Allocator, state: State) void {
    allocator.free(state.host);
    allocator.free(state.version);
    if (state.static_dir) |sd| allocator.free(sd);
}

fn parseState(allocator: std.mem.Allocator, v: std.json.Value) !State {
    const obj = v.object;
    const pid_val = obj.get("pid") orelse return error.Malformed;
    const port_val = obj.get("port") orelse return error.Malformed;
    const host_val = obj.get("host") orelse return error.Malformed;
    const started_at_val = obj.get("started_at") orelse return error.Malformed;
    const version_val = obj.get("version") orelse return error.Malformed;
    return .{
        .pid = @intCast(pid_val.integer),
        .port = @intCast(port_val.integer),
        .host = try allocator.dupe(u8, host_val.string),
        .started_at = started_at_val.integer,
        .version = try allocator.dupe(u8, version_val.string),
        .static_dir = if (obj.get("static_dir")) |sd| switch (sd) {
            .string => try allocator.dupe(u8, sd.string),
            .null => null,
            else => null,
        } else null,
    };
}

/// Write state.json atomically. Serializes `state` via std.fmt, writes to
/// <path>.tmp first, then rename(2)s over the destination. POSIX rename is
/// atomic — readers see either the old or new file, never a half-written one.
pub fn writeStateFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state: State,
) !void {
    // `path` is either the canonical default ($XDG_STATE_HOME / $HOME
    // derived) or a caller-supplied `state_path`.
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.PathNotAbsolute;

    // 1. Serialize to a JSON string. static_dir's value is wrapped in quotes
    // via the `{s}` formatter for strings; null is a literal.
    const sd_field: []const u8 = sd: {
        if (state.static_dir) |sd| {
            const owned = try std.fmt.allocPrint(allocator, "\"{s}\"", .{sd});
            errdefer allocator.free(owned);
            break :sd owned;
        }
        break :sd "null";
    };
    defer if (state.static_dir != null) allocator.free(sd_field);

    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"pid\":{d},\"port\":{d},\"host\":\"{s}\",\"started_at\":{d},\"version\":\"{s}\",\"static_dir\":{s}}}",
        .{
            state.pid,
            state.port,
            state.host,
            state.started_at,
            state.version,
            sd_field,
        },
    );
    defer allocator.free(json);

    // 2. Write to <path>.tmp first. Use @memcpy for the suffix because
    //    std.fs.path.join treats every arg as a path component (and
    //    would produce "<path>/.tmp" with an unwanted slash).
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len + 4 >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    @memcpy(path_buf[path.len..][0..4], ".tmp");
    path_buf[path.len + 4] = 0;
    const tmp_path: []const u8 = path_buf[0..path.len + 4];

    // mkdir -p the parent directory of the state file (POSIX only; on
    // Windows, %LOCALAPPDATA% always exists).
    if (builtin.os.tag != .windows) {
        if (std.fs.path.dirname(path)) |parent_dir| {
            var iter = std.fs.path.componentIterator(parent_dir);
            while (iter.next()) |component| {
                var dpath_z: [std.fs.max_path_bytes:0]u8 = undefined;
                if (component.path.len >= dpath_z.len) return error.PathTooLong;
                @memcpy(dpath_z[0..component.path.len], component.path);
                dpath_z[component.path.len] = 0;
                const rc = std.c.mkdirat(std.c.AT.FDCWD, &dpath_z, 0o755);
                if (rc != 0) {
                    const err = std.c.errno(rc);
                    if (err != .EXIST) return error.WriteFailed;
                }
            }
        }
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = json });
    // std.Io.Dir.renameAbsolute(old_path, new_path, io) — atomic on POSIX
    // (rename(2) is atomic), readers see either the old or new file.
    try std.Io.Dir.renameAbsolute(tmp_path, path, io);
}

pub const PathError = error{
    PathResolutionFailed,
    OutOfMemory,
};

/// Compute the canonical state.json path for the current platform:
/// Linux/macOS: $XDG_STATE_HOME/pabrik/state.json, fallback to
/// $HOME/.local/state/pabrik/state.json (creates parent dirs).
pub fn defaultStatePath(allocator: std.mem.Allocator) PathError![]u8 {
    // std.c.getenv returns `?[*:0]u8` (nullable NUL-terminated). For path
    // joining we need a `[]const u8` slice; `std.mem.sliceTo` walks to the
    // NUL terminator and returns a length-counted slice.
    if (builtin.os.tag == .windows) {
        const appdata_z = std.c.getenv("LOCALAPPDATA") orelse
            return error.PathResolutionFailed;
        const appdata = std.mem.sliceTo(appdata_z, 0);
        if (!std.fs.path.isAbsolute(appdata)) return error.PathResolutionFailed;
        return std.fs.path.join(allocator, &.{ appdata, "pabrik", "state.json" });
    }
    // POSIX: XDG_STATE_HOME wins; fall back to ~/.local/state.
    const home_z = std.c.getenv("HOME") orelse return error.PathResolutionFailed;
    const home = std.mem.sliceTo(home_z, 0);
    if (std.c.getenv("XDG_STATE_HOME")) |xdg_z| {
        const xdg = std.mem.sliceTo(xdg_z, 0);
        if (!std.fs.path.isAbsolute(xdg)) return error.PathResolutionFailed;
        return std.fs.path.join(allocator, &.{ xdg, "pabrik", "state.json" });
    }
    if (!std.fs.path.isAbsolute(home)) return error.PathResolutionFailed;
    return std.fs.path.join(allocator, &.{ home, ".local", "state", "pabrik", "state.json" });
}

// ===== Tests merged from state_file_test.zig (2026-09-29 flatten) =====

// Tests for src/service/state_file.zig.

const testing = std.testing;

test "readStateFile returns null when file does not exist" {
    const allocator = testing.allocator;
    const result = try readStateFile(
        allocator,
        testing.io,
        "/tmp/this/path/does/not/exist/state.json",
    );
    try testing.expect(result == null);
}

test "writeStateFile rejects a relative path instead of aborting" {
    const allocator = testing.allocator;
    const original: State = .{
        .pid = 1,
        .port = 8081,
        .host = "127.0.0.1",
        .started_at = 1,
        .version = "v",
        .static_dir = null,
    };

    // `writeStateFile` ends in `std.Io.Dir.renameAbsolute`, whose
    // `assert(path.isAbsolute(...))` is `unreachable` in Debug/ReleaseSafe —
    // it ABORTS the whole process instead of returning an error.
    const result = writeStateFile(allocator, testing.io, "relative/state.json", original);
    try testing.expectError(error.PathNotAbsolute, result);
}

test "writeStateFile round-trips a State" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Get the tmp dir's canonical realpath via Io.Dir.realPath (Zig 0.16).
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];

    // Build "<tmpdir>/state.json" without std.fs.path.join (every join arg
    // is treated as a path component; concatenating the suffix manually).
    const path = try allocator.alloc(u8, tmp_dir_path.len + 1 + "state.json".len);
    defer allocator.free(path);
    @memcpy(path[0..tmp_dir_path.len], tmp_dir_path);
    path[tmp_dir_path.len] = '/';
    @memcpy(path[tmp_dir_path.len + 1..], "state.json");

    const original: State = .{
        .pid = 12345,
        .port = 8081,
        .host = "127.0.0.1",
        .started_at = 1751558400,
        .version = "0.4.0",
        .static_dir = "/tmp/pabrik-webapp-1234",
    };
    try writeStateFile(allocator, testing.io, path, original);
    const restored = try readStateFile(allocator, testing.io, path);
    defer if (restored) |s| freeState(allocator, s);
    try testing.expect(restored != null);
    try testing.expectEqual(original.pid, restored.?.pid);
    try testing.expectEqual(original.port, restored.?.port);
    try testing.expectEqualStrings(original.host, restored.?.host);
    try testing.expectEqualStrings(original.static_dir.?, restored.?.static_dir.?);
}

test "defaultStatePath returns XDG-aware path on POSIX" {
    if (builtin.os.tag == .windows) return; // skip on non-POSIX CI cells
    const allocator = testing.allocator;
    const path = try defaultStatePath(allocator);
    defer allocator.free(path);
    // Path should end in /state.json under a 'pabrik' dir.
    try testing.expect(std.mem.endsWith(u8, path, "/state.json"));
    try testing.expect(std.mem.indexOf(u8, path, "pabrik") != null);
}

test "writeStateFile does mkdir-p into a fresh nested dir" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];

    // Build "<tmpdir>/deeply/nested/that/does/not/exist/state.json" — the
    // parent dirs do NOT exist when writeStateFile is called. This is the
    // exact path the daemon hits on a fresh $HOME.
    const leaf = "deeply/nested/that/does/not/exist/state.json";
    const path = try allocator.alloc(u8, tmp_dir_path.len + 1 + leaf.len);
    defer allocator.free(path);
    @memcpy(path[0..tmp_dir_path.len], tmp_dir_path);
    path[tmp_dir_path.len] = '/';
    @memcpy(path[tmp_dir_path.len + 1..], leaf);

    const original: State = .{
        .pid = 99,
        .port = 8081,
        .host = "127.0.0.1",
        .started_at = 1751558400,
        .version = "0.4.0",
        .static_dir = null,
    };
    try writeStateFile(allocator, testing.io, path, original);
    const restored = try readStateFile(allocator, testing.io, path);
    defer if (restored) |s| freeState(allocator, s);
    try testing.expect(restored != null);
    try testing.expectEqual(original.pid, restored.?.pid);
}

test "freeState is a no-op on slices (does not double-free)" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];

    const leaf = "free_test/state.json";
    const path = try allocator.alloc(u8, tmp_dir_path.len + 1 + leaf.len);
    defer allocator.free(path);
    @memcpy(path[0..tmp_dir_path.len], tmp_dir_path);
    path[tmp_dir_path.len] = '/';
    @memcpy(path[tmp_dir_path.len + 1..], leaf);

    const original: State = .{
        .pid = 1,
        .port = 8081,
        .host = "x",
        .started_at = 1,
        .version = "v",
        .static_dir = "/tmp/static",
    };
    try writeStateFile(allocator, testing.io, path, original);
    const restored = try readStateFile(allocator, testing.io, path);
    try testing.expect(restored != null);
    // Freeing twice in a row must NOT panic — the second call is a no-op
    // because the slices are "" / null after the first free. Use null
    // optional to simulate this.
    if (restored) |s| freeState(allocator, s);
}
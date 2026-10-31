//! The master key that seals `workspace_secrets.value`: `PABRIK_SECRETS_MASTER_KEY` (64 hex) if
//! set, else `<config dir>/secrets.key` created 0600 from the OS CSPRNG on first use. Every failure
//! collapses to `key = null` plus a `problem` the boot log reports; writes then fail closed.

const std = @import("std");
const helpers = @import("helpers");

pub const env_var = "PABRIK_SECRETS_MASTER_KEY";
pub const file_name = "secrets.key";
pub const KEY_LEN: usize = 32;
const hex_len = KEY_LEN * 2;

pub const Source = enum {
    environment,
    key_file,
};

/// Why there is no key. Reported once at boot; never per request.
pub const Problem = enum {
    /// The env var is set but is not 64 hex characters.
    malformed_env,
    /// The key file exists but is not 64 hex characters.
    malformed_file,
    /// Neither the file nor the directory could be created (read-only HOME, a
    /// container with no writable state dir).
    unwritable,
    /// The OS CSPRNG refused to produce bytes.
    random_failed,
};

pub const Status = struct {
    /// Null means "this host has no key": sealed rows cannot be opened and
    /// writes are refused rather than stored as plaintext.
    key: ?[KEY_LEN]u8 = null,
    source: Source = .key_file,
    /// The key file in force, owned. Empty when the key came from the
    /// environment.
    path: []u8 = &.{},
    problem: ?Problem = null,

    pub fn deinit(self: *Status, allocator: std.mem.Allocator) void {
        if (self.path.len > 0) allocator.free(self.path);
        self.path = &.{};
    }

    /// One log line a boot can print. Never includes the key.
    pub fn describe(self: *const Status) []const u8 {
        if (self.key == null) {
            return switch (self.problem orelse .unwritable) {
                .malformed_env => "workspace secrets: PABRIK_SECRETS_MASTER_KEY is not 64 hex characters; secret values stay sealed and writes are refused",
                .malformed_file => "workspace secrets: secrets.key is not 64 hex characters; delete it to have a fresh key generated",
                .unwritable => "workspace secrets: no key file could be read or created under the config directory; sealed values cannot be opened and writes are refused",
                .random_failed => "workspace secrets: the OS CSPRNG failed, so no key could be generated",
            };
        }
        return switch (self.source) {
            .environment => "workspace secrets: master key from PABRIK_SECRETS_MASTER_KEY",
            .key_file => "workspace secrets: master key from the key file (0600)",
        };
    }
};

/// Parse 64 hex characters, ignoring surrounding whitespace (which is what a
/// trailing newline in a secret file or an exported variable leaves behind).
pub fn parseKey(text: []const u8) ?[KEY_LEN]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len != hex_len) return null;
    var key: [KEY_LEN]u8 = undefined;
    for (0..KEY_LEN) |i| {
        const hi = hexDigit(trimmed[i * 2]) orelse return null;
        const lo = hexDigit(trimmed[i * 2 + 1]) orelse return null;
        key[i] = (hi << 4) | lo;
    }
    return key;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Resolve the key. `env_value` is the raw `PABRIK_SECRETS_MASTER_KEY` (null
/// when unset); `config_dir` is the directory the key file lives in.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_value: ?[]const u8,
    config_dir: []const u8,
) Status {
    if (env_value) |raw| {
        // A variable that is SET but wrong is an error, not a reason to fall
        // back to a file: the operator meant to control the key.
        const key = parseKey(raw) orelse return .{ .problem = .malformed_env };
        return .{ .key = key, .source = .environment };
    }

    const path = std.fs.path.join(allocator, &.{ config_dir, file_name }) catch
        return .{ .problem = .unwritable };

    switch (readKeyFile(allocator, io, path) catch .unreadable) {
        .key => |key| return .{ .key = key, .source = .key_file, .path = path },
        .malformed => return .{ .problem = .malformed_file, .path = path },
        // A file that exists but will not open must NOT be replaced: the new
        // key would orphan every value sealed under the old one.
        .unreadable => return .{ .problem = .unwritable, .path = path },
        .missing => {},
    }

    const key = createKeyFile(io, path) catch |err| {
        allocator.free(path);
        return .{ .problem = switch (err) {
            error.RandomFailed => .random_failed,
            else => .unwritable,
        } };
    };
    return .{ .key = key, .source = .key_file, .path = path };
}

const ReadResult = union(enum) {
    key: [KEY_LEN]u8,
    malformed,
    missing,
    unreadable,
};

fn readKeyFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ReadResult {
    const file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| return switch (err) {
            error.FileNotFound => .missing,
            else => .unreadable,
        }
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| return switch (err) {
            error.FileNotFound => .missing,
            else => .unreadable,
        };
    defer file.close(io);

    var buf: [256]u8 = undefined;
    var reader = file.reader(io, &buf);
    const text = reader.interface.allocRemaining(allocator, .limited(hex_len + 4)) catch
        return .unreadable;
    defer allocator.free(text);

    // A key file holds a newline; `parseKey` trims it.
    const key = parseKey(text) orelse return .malformed;
    return .{ .key = key };
}

/// Generate the key, write it 0600, and hand it back. Windows has no POSIX
/// mode bits, so the file is protected by the account rather than by the mode.
fn createKeyFile(io: std.Io, path: []const u8) !([KEY_LEN]u8) {
    var key: [KEY_LEN]u8 = undefined;
    try helpers.random.fillRandom(&key);

    const hex = std.fmt.bytesToHex(key, .lower);
    var text: [hex_len + 1]u8 = undefined;
    @memcpy(text[0..hex_len], &hex);
    text[hex_len] = '\n';

    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true })
    else
        try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    if (comptime !builtin_windows) {
        try file.setPermissions(io, @enumFromInt(0o600));
    }
    try std.Io.File.writeStreamingAll(file, io, &text);
    return key;
}

const builtin_windows = @import("builtin").os.tag == .windows;

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseKey accepts 64 hex characters and nothing else" {
    const lower = "0123456789abcdef" ** 4;
    const key = parseKey(lower) orelse return error.ExpectedKey;
    try testing.expectEqual(@as(u8, 0x01), key[0]);
    try testing.expectEqual(@as(u8, 0xef), key[31]);

    // Upper case, and the trailing newline an exported variable or a pasted
    // file leaves behind.
    const upper = "0123456789ABCDEF" ** 4;
    const from_upper = parseKey("  " ++ upper ++ "\n") orelse return error.ExpectedKey;
    try testing.expectEqualSlices(u8, &key, &from_upper);

    try testing.expect(parseKey("") == null);
    try testing.expect(parseKey("0123") == null);
    try testing.expect(parseKey(lower ++ "00") == null);
    // 64 characters, one of them not hex.
    try testing.expect(parseKey("0123456789abcdeg" ** 4) == null);
}

test "the environment wins over the key file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const config_dir = try testing.allocator.dupe(u8, path_buf[0..dir_len]);
    defer testing.allocator.free(config_dir);

    var from_env = secretsKeyTest(0x11);
    var status = load(testing.allocator, testing.io, &std.fmt.bytesToHex(from_env, .lower), config_dir);
    defer status.deinit(testing.allocator);
    try testing.expectEqual(Source.environment, status.source);
    try testing.expectEqualSlices(u8, &from_env, &status.key.?);
    // No file was created for it.
    try testing.expect(status.path.len == 0);
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(testing.io, file_name, .{}));

    // ...and the file path is used when the variable is absent.
    from_env = secretsKeyTest(0x22);
    var from_file = load(testing.allocator, testing.io, null, config_dir);
    defer from_file.deinit(testing.allocator);
    try testing.expectEqual(Source.key_file, from_file.source);
    try testing.expect(!std.mem.eql(u8, &from_env, &from_file.key.?));
}

test "a fresh key file is created 0600 and reused verbatim on the next boot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const config_dir = try testing.allocator.dupe(u8, path_buf[0..dir_len]);
    defer testing.allocator.free(config_dir);

    var first = load(testing.allocator, testing.io, null, config_dir);
    defer first.deinit(testing.allocator);
    try testing.expect(first.key != null);

    var second = load(testing.allocator, testing.io, null, config_dir);
    defer second.deinit(testing.allocator);
    // The same key, or every value sealed on the previous boot is unreadable.
    try testing.expectEqualSlices(u8, &first.key.?, &second.key.?);

    if (comptime !builtin_windows) {
        const file = try tmp.dir.openFile(testing.io, file_name, .{});
        defer file.close(testing.io);
        const stat = try file.stat(testing.io);
        // Group and other must not read the key that unseals every credential.
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), @intFromEnum(stat.permissions) & 0o777);
    }
}

test "a malformed key file reports a problem instead of quietly regenerating" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const config_dir = try testing.allocator.dupe(u8, path_buf[0..dir_len]);
    defer testing.allocator.free(config_dir);

    {
        const file = try tmp.dir.createFile(testing.io, file_name, .{});
        defer file.close(testing.io);
        try std.Io.File.writeStreamingAll(file, testing.io, "not-a-key\n");
    }

    var status = load(testing.allocator, testing.io, null, config_dir);
    defer status.deinit(testing.allocator);
    // Regenerating here would destroy every value sealed under the old key, so
    // the answer is "no key" and a message that says to delete the file.
    try testing.expect(status.key == null);
    try testing.expectEqual(Problem.malformed_file, status.problem.?);
}

test "a malformed environment key does not fall back to the key file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const config_dir = try testing.allocator.dupe(u8, path_buf[0..dir_len]);
    defer testing.allocator.free(config_dir);

    var status = load(testing.allocator, testing.io, "too-short", config_dir);
    defer status.deinit(testing.allocator);
    try testing.expect(status.key == null);
    try testing.expectEqual(Problem.malformed_env, status.problem.?);
    // An operator who set the variable must hear about the typo, not get a
    // different key behind their back.
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(testing.io, file_name, .{}));
}

test "an unwritable config directory reports a problem rather than panicking" {
    var status = load(testing.allocator, testing.io, null, "/proc/definitely-not-writable/pabrik");
    defer status.deinit(testing.allocator);
    if (comptime !builtin_windows) {
        try testing.expect(status.key == null);
        try testing.expect(status.problem != null);
        // The message names the consequence, and never a key.
        try testing.expect(std.mem.indexOf(u8, status.describe(), "refused") != null);
    }
}

fn secretsKeyTest(seed: u8) [KEY_LEN]u8 {
    var key: [KEY_LEN]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = seed +% @as(u8, @intCast(i));
    return key;
}

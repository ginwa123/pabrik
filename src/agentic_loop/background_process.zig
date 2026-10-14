const std = @import("std");
const root_mod = @import("pabrikcore");
const sqlite = root_mod.sqlite;
// NOTE: NOT `root_mod.helpers.process_status`.
const process_status = @import("helpers").process_status;
const shell_tool = root_mod.shell_tool;
const testing = std.testing;

pub const ProcessInfo = struct {
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
    started_at: i64,
    status: []const u8,
    /// `job` | `service` (migration 107). `service` is `mode =
    /// "background_persistence"`: a process the agent is deliberately NOT
    /// notified about, which it polls or stops itself.
    kind: []const u8,
    /// How many bytes of the log `process read` has already returned
    /// (migration 108). Without it every read would hand the model the same
    /// head of the file again.
    last_read_offset: i64 = 0,
};

/// The two `kind` values, as constants so no call site spells them inline.
pub const KIND_JOB = "job";
pub const KIND_SERVICE = "service";

/// Release a `ProcessInfo` slice and every string in it.
pub fn freeProcessInfos(allocator: std.mem.Allocator, infos: []ProcessInfo) void {
    freeProcessInfoStrings(allocator, infos);
    allocator.free(infos);
}

/// Release each entry's strings but NOT the slice — for the partially-built
/// list an `errdefer` sees, where the slice belongs to the ArrayList.
pub fn freeProcessInfoStrings(allocator: std.mem.Allocator, infos: []ProcessInfo) void {
    for (infos) |p| freeProcessInfo(allocator, p);
}

/// One entry's strings — for the single-row reads (`getByPid`) that own no slice.
pub fn freeProcessInfo(allocator: std.mem.Allocator, p: ProcessInfo) void {
    allocator.free(p.session_id);
    allocator.free(p.command);
    allocator.free(p.log_path);
    allocator.free(p.status);
    allocator.free(p.kind);
}

const SqliteBackend = sqlite.SqliteBackend;

/// Save a new background process to the database. `kind` is `KIND_JOB` or
/// `KIND_SERVICE` — see migration 107.
pub fn save(db: *SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8, pid: u32, command: []const u8, log_path: []const u8, started_at: i64, kind: []const u8) !void {
    const pid_str = try std.fmt.allocPrint(allocator, "{}", .{pid});
    defer allocator.free(pid_str);

    const started_at_str = try std.fmt.allocPrint(allocator, "{}", .{started_at});
    defer allocator.free(started_at_str);

    const kind_value: []const u8 = if (kind.len == 0) KIND_JOB else kind;

    try db.exec(allocator,
        \\INSERT OR REPLACE INTO session_background_process (session_id, pid, command, log_path, started_at, status, kind)
        \\VALUES (?, ?, ?, ?, ?, 'running', ?)
    , &.{ session_id, pid_str, command, log_path, started_at_str, kind_value });
}

/// Get all background processes for a session
pub fn getBySession(db: *SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8) ![]ProcessInfo {
    var rows = try db.query(allocator, "SELECT pid, command, log_path, started_at, status, COALESCE(kind, 'job'), COALESCE(last_read_offset, 0) FROM session_background_process WHERE session_id = ?", &.{session_id});
    defer rows.deinit();

    var processes = std.ArrayList(ProcessInfo).empty;
    errdefer {
        freeProcessInfoStrings(allocator, processes.items);
        processes.deinit(allocator);
    }

    while (try rows.next()) |row| {
        // The reader hands back a buffer of its own (`readRowPacked`); the
        // caller owns it.
        defer row.deinit(allocator);
        const pid_str = row.values[0];
        const command = row.values[1];
        const log_path = row.values[2];
        const started_at_str = row.values[3];
        const status = row.values[4];

        const pid = try std.fmt.parseInt(u32, pid_str, 10);
        const started_at = try std.fmt.parseInt(i64, started_at_str, 10);

        try processes.append(allocator, .{
            // DUPED, like every other field.
            .session_id = try allocator.dupe(u8, session_id),
            .pid = pid,
            .command = try allocator.dupe(u8, command),
            .log_path = try allocator.dupe(u8, log_path),
            .started_at = started_at,
            .status = try allocator.dupe(u8, status),
            .kind = try allocator.dupe(u8, row.values[5]),
            .last_read_offset = std.fmt.parseInt(i64, row.values[6], 10) catch 0,
        });
    }

    return processes.toOwnedSlice(allocator);
}

/// Update the status of a background process
pub fn updateStatus(db: *SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8, pid: u32, new_status: []const u8) !void {
    const pid_str = try std.fmt.allocPrint(allocator, "{}", .{pid});
    defer allocator.free(pid_str);

    try db.exec(allocator,
        \\UPDATE session_background_process SET status = ? WHERE session_id = ? AND pid = ?
    , &.{ new_status, session_id, pid_str });
}

/// Delete a background process from the database
pub fn delete(db: *SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8, pid: u32) !void {
    const pid_str = try std.fmt.allocPrint(allocator, "{}", .{pid});
    defer allocator.free(pid_str);

    try db.exec(allocator, "DELETE FROM session_background_process WHERE session_id = ? AND pid = ?", &.{ session_id, pid_str });
}

/// Every `kind='service'` row, with `session_id` — the rows that
/// `mode="background_persistence"` created.
pub fn getServices(db: *SqliteBackend, allocator: std.mem.Allocator) ![]ProcessInfo {
    var rows = try db.query(allocator,
        \\SELECT session_id, pid, command, log_path, started_at, status, COALESCE(kind, 'job'), COALESCE(last_read_offset, 0)
        \\FROM session_background_process
        \\WHERE kind = 'service'
    , &[_][]const u8{});
    defer rows.deinit();

    var processes = std.ArrayList(ProcessInfo).empty;
    errdefer {
        freeProcessInfoStrings(allocator, processes.items);
        processes.deinit(allocator);
    }

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const session_id = row.values[0];
        const pid_str = row.values[1];
        const command = row.values[2];
        const log_path = row.values[3];
        const started_at_str = row.values[4];
        const status = row.values[5];

        const pid = try std.fmt.parseInt(u32, pid_str, 10);
        const started_at = try std.fmt.parseInt(i64, started_at_str, 10);

        try processes.append(allocator, .{
            .session_id = try allocator.dupe(u8, session_id),
            .pid = pid,
            .command = try allocator.dupe(u8, command),
            .log_path = try allocator.dupe(u8, log_path),
            .started_at = started_at,
            .status = try allocator.dupe(u8, status),
            .kind = try allocator.dupe(u8, row.values[6]),
            .last_read_offset = std.fmt.parseInt(i64, row.values[7], 10) catch 0,
        });
    }

    return processes.toOwnedSlice(allocator);
}

/// Is this pid alive — asked in the way that also REAPS.
pub fn isAlive(pid: u32) bool {
    return switch (shell_tool.reap_pid_nohang(pid)) {
        .exited => false,
        .running => true,
        .not_our_child => isProcessRunning(pid),
    };
}

/// Check if a process with the given PID is still running
/// Returns true if process exists, false otherwise
pub fn isProcessRunning(pid: u32) bool {
    // Cross-platform: kill(pid, 0) on POSIX, OpenProcess(QUERY_LIMITED) on
    // Windows. See src/helpers/process_status.zig for the platform switch.
    return process_status.isProcessRunning(@intCast(pid));
}

/// Kill a background process by PID
/// Returns true if killed successfully, false if process doesn't exist or error
pub fn killProcess(pid: u32) bool {
    // The previous implementation tried SIGTERM (15) first and fell back to
    // SIGKILL (9).
    return process_status.killProcess(@intCast(pid));
}

/// Stop every live `kind='service'` process, TREE included.
pub fn killServicesForShutdown(db: *SqliteBackend, io: std.Io, allocator: std.mem.Allocator) !usize {
    const services = try getServices(db, allocator);
    defer freeProcessInfos(allocator, services);

    var killed: usize = 0;
    for (services) |p| {
        // The process GROUP, not the PID: a service that forked (vite →
        // esbuild) survives a single-PID kill and keeps its port.
        if (shell_tool.stopDetachedProcess(allocator, io, p.pid)) killed += 1;
        try updateStatus(db, allocator, p.session_id, p.pid, "killed");
    }
    return killed;
}

/// One process row by pid, or null when this session has no such process.
pub fn getByPid(db: *SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8, pid: u32) !?ProcessInfo {
    const pid_str = try std.fmt.allocPrint(allocator, "{d}", .{pid});
    defer allocator.free(pid_str);

    var rows = try db.query(allocator,
        \\SELECT pid, command, log_path, started_at, status, COALESCE(kind, 'job'), COALESCE(last_read_offset, 0)
        \\FROM session_background_process
        \\WHERE session_id = ? AND pid = ?
    , &.{ session_id, pid_str });
    defer rows.deinit();

    const row = (try rows.next()) orelse return null;
    defer row.deinit(allocator);

    return ProcessInfo{
        .session_id = try allocator.dupe(u8, session_id),
        .pid = try std.fmt.parseInt(u32, row.values[0], 10),
        .command = try allocator.dupe(u8, row.values[1]),
        .log_path = try allocator.dupe(u8, row.values[2]),
        .started_at = try std.fmt.parseInt(i64, row.values[3], 10),
        .status = try allocator.dupe(u8, row.values[4]),
        .kind = try allocator.dupe(u8, row.values[5]),
        .last_read_offset = std.fmt.parseInt(i64, row.values[6], 10) catch 0,
    };
}

/// Persist the read cursor. The caller passes the offset it actually RETURNED,
/// so a failed persist can only cause a repeat (harmless) and never a gap — a
/// silently skipped line is the failure that would matter.
pub fn setLastReadOffset(db: *SqliteBackend, allocator: std.mem.Allocator, session_id: []const u8, pid: u32, offset: i64) !void {
    const pid_str = try std.fmt.allocPrint(allocator, "{d}", .{pid});
    defer allocator.free(pid_str);
    const offset_str = try std.fmt.allocPrint(allocator, "{d}", .{offset});
    defer allocator.free(offset_str);

    try db.exec(allocator,
        \\UPDATE session_background_process SET last_read_offset = ?
        \\WHERE session_id = ? AND pid = ?
    , &.{ offset_str, session_id, pid_str });
}

/// What one `process read` returns.
pub const DeltaRead = struct {
    /// Bytes after the stored cursor, NUL-stripped. Caller-owned.
    bytes: []u8,
    /// The cursor to persist, and to report back to the model.
    next_offset: i64,
    /// Full on-disk size.
    total_bytes: i64,
    /// The cap cut this read short — more is waiting past `next_offset`.
    more_pending: bool,
    /// NOTHING NEW. Distinct from a read that failed: this is an ANSWER ("it has
    /// said nothing since you last looked"), and it is the answer that makes
    /// polling cheap enough to be worth doing at all.
    empty: bool,
    /// The log file does not exist — a `nohup` job whose command never started
    /// produces this, and it is not the same as "no output".
    missing: bool,

    pub fn free(self: DeltaRead, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

/// Read the part of `log_path` the caller has NOT been shown yet. Positional
/// (`pread`-style) from the stored offset, so it neither depends on a file
/// handle's own cursor nor reads the head it exists to avoid.
pub fn readDelta(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *SqliteBackend,
    session_id: []const u8,
    pid: u32,
    log_path: []const u8,
    stored_offset: i64,
    cap_bytes: usize,
) !DeltaRead {
    const stat = std.Io.Dir.cwd().statFile(io, log_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{
            .bytes = try allocator.alloc(u8, 0),
            .next_offset = stored_offset,
            .total_bytes = 0,
            .more_pending = false,
            .empty = true,
            .missing = true,
        },
        else => return err,
    };
    const total: i64 = @intCast(stat.size);

    // Clamp: a TRUNCATED log (recreated, or re-opened with `>`) leaves a cursor
    // past EOF, and without this the read would return nothing for ever — the
    // model would conclude the process had gone silent.
    const offset: i64 = if (stored_offset > total) 0 else @max(stored_offset, 0);

    if (total <= offset) {
        return .{
            .bytes = try allocator.alloc(u8, 0),
            .next_offset = total,
            .total_bytes = total,
            .more_pending = false,
            .empty = true,
            .missing = false,
        };
    }

    const available: usize = @intCast(total - offset);
    const to_read: usize = @min(available, cap_bytes);

    const file = if (std.fs.path.isAbsolute(log_path))
        try std.Io.Dir.openFileAbsolute(io, log_path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, log_path, .{});
    defer file.close(io);

    const raw = try allocator.alloc(u8, to_read);
    defer allocator.free(raw);
    var filled: usize = 0;
    while (filled < raw.len) {
        // `readPositionalAll` takes a u64 offset; `offset` is clamped >= 0 above,
        // so the widening is lossless.
        const at: u64 = @intCast(offset + @as(i64, @intCast(filled)));
        const n = try file.readPositionalAll(io, raw[filled..], at);
        if (n == 0) break; // EOF: the file shrank under us.
        filled += n;
    }
    const head = raw[0..filled];

    // Compact out NUL bytes, for the same reason `readLogTruncated` does: a
    // control byte inside a JSON string is not representable.
    var kept: usize = 0;
    for (head) |b| {
        if (b != 0) kept += 1;
    }
    const out = try allocator.alloc(u8, kept);
    var i: usize = 0;
    for (head) |b| {
        if (b == 0) continue;
        out[i] = b;
        i += 1;
    }

    const next_offset = offset + @as(i64, @intCast(filled));

    // Persist BEFORE returning: the caller is handed the bytes and the offset
    // together, so "what have I already shown you" is answered by the same read
    // that produced them.
    setLastReadOffset(db, allocator, session_id, pid, next_offset) catch {};

    return .{
        .bytes = out,
        .next_offset = next_offset,
        .total_bytes = total,
        .more_pending = next_offset < total,
        .empty = kept == 0,
        .missing = false,
    };
}

/// What one boot pass over the service rows did.
pub const ServiceSweepResult = struct {
    checked: usize = 0,
    killed: usize = 0,
    marked_orphaned: usize = 0,
};

/// Boot pass over every `kind='service'` row.
pub fn sweepServicesOnBoot(db: *SqliteBackend, io: std.Io, allocator: std.mem.Allocator) !ServiceSweepResult {
    const services = try getServices(db, allocator);
    defer freeProcessInfos(allocator, services);

    var result: ServiceSweepResult = .{ .checked = services.len };
    for (services) |p| {
        // `reap_pid_nohang` FIRST: a service we spawned in a PREVIOUS pabrik
        // process is not our child any more, so this answers `.not_our_child`
        // and the signal probe below decides.
        const alive = switch (shell_tool.reap_pid_nohang(p.pid)) {
            .exited => false,
            .running => true,
            .not_our_child => isProcessRunning(p.pid),
        };

        if (alive) {
            if (shell_tool.stopDetachedProcess(allocator, io, p.pid)) result.killed += 1;
        }
        try updateStatus(db, allocator, p.session_id, p.pid, "orphaned");
        result.marked_orphaned += 1;
    }
    return result;
}

// ─── Background completion message helpers (Task 1)
// ───────────────────────── Pure helpers (no DB) used by the Task 2
// completion queue: read a finished background command's log file with a byte

/// Byte cap callers use when reading a background command's log file.
pub const completion_log_cap_bytes: usize = 20 * 1024;

/// Result of `readLogTruncated`.
pub const TruncatedLog = struct {
    content: []u8,
    total_bytes: usize,
    truncated: bool,

    pub fn free(self: TruncatedLog, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

/// Read up to `cap_bytes` bytes (HEAD — the first bytes of the file) from the
/// log at `log_path`, strip NUL bytes so the content can never break SSE JSON
/// framing, and report the full file size for the truncation suffix.
pub fn readLogTruncated(
    allocator: std.mem.Allocator,
    io: std.Io,
    log_path: []const u8,
    cap_bytes: usize,
) !TruncatedLog {
    const cwd = std.Io.Dir.cwd();

    // Stat first: yields the total size AND surfaces FileNotFound for a
    // missing log in one syscall. Absolute paths work through cwd()
    // (same as Dir.readFileAlloc / writeFile elsewhere in the codebase).
    const stat = try cwd.statFile(io, log_path, .{});
    const total: usize = stat.size;

    if (total == 0) {
        return .{
            .content = try allocator.alloc(u8, 0),
            .total_bytes = 0,
            .truncated = false,
        };
    }

    const truncated = total > cap_bytes;
    const to_read: usize = @min(total, cap_bytes);

    // Absolute log paths (the production `/tmp/bg_*.log` shape) go
    // through openFileAbsolute; relative paths resolve against cwd().
    const file = if (std.fs.path.isAbsolute(log_path))
        try std.Io.Dir.openFileAbsolute(io, log_path, .{})
    else
        try cwd.openFile(io, log_path, .{});
    defer file.close(io);

    const raw = try allocator.alloc(u8, to_read);
    errdefer allocator.free(raw);
    var filled: usize = 0;
    while (filled < raw.len) {
        const n = try file.readPositionalAll(io, raw[filled..], filled);
        if (n == 0) break; // EOF — file shrank between stat and read.
        filled += n;
    }
    const head = raw[0..filled];
    defer allocator.free(raw);

    // Compact out NUL bytes into an exactly-sized owned slice. The raw
    // buffer is freed via defer; `out` is the caller's to free.
    var kept: usize = 0;
    for (head) |b| {
        if (b != 0) kept += 1;
    }
    const out = try allocator.alloc(u8, kept);
    var i: usize = 0;
    for (head) |b| {
        if (b == 0) continue;
        out[i] = b;
        i += 1;
    }

    return .{
        .content = out,
        .total_bytes = total,
        .truncated = truncated,
    };
}

/// Build the queue message payload for a finished background command.
pub fn buildCompletionMessage(
    allocator: std.mem.Allocator,
    command: []const u8,
    pid: u32,
    log_content_truncated: []const u8,
    was_truncated: bool,
    total_bytes: usize,
    log_path: []const u8,
) ![]u8 {
    const sanitize = @import("helpers").sanitize_control_chars;
    const inner: []const u8 = if (log_content_truncated.len == 0) "(empty output)" else log_content_truncated;

    const clean_command = try sanitize(allocator, command);
    defer allocator.free(clean_command);
    const clean_stdout = try sanitize(allocator, inner);
    defer allocator.free(clean_stdout);

    if (!was_truncated) {
        return std.json.Stringify.valueAlloc(allocator, .{
            .pid = pid,
            .command = clean_command,
            .stdout = clean_stdout,
            .truncated = false,
            .total_bytes = @as(?usize, null),
            .log_path = @as(?[]const u8, null),
        }, .{});
    }

    const clean_log_path = try sanitize(allocator, log_path);
    defer allocator.free(clean_log_path);
    return std.json.Stringify.valueAlloc(allocator, .{
        .pid = pid,
        .command = clean_command,
        .stdout = clean_stdout,
        .truncated = true,
        .total_bytes = total_bytes,
        .log_path = clean_log_path,
    }, .{});
}

test "buildCompletionMessage renders the JSON payload" {
    const msg = try buildCompletionMessage(testing.allocator, "sleep 10", 1234, "hello\nworld", false, 11, "/tmp/x.log");
    defer testing.allocator.free(msg);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, msg, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 1234), obj.get("pid").?.integer);
    try testing.expectEqualStrings("sleep 10", obj.get("command").?.string);
    try testing.expectEqualStrings("hello\nworld", obj.get("stdout").?.string);
    try testing.expect(!obj.get("truncated").?.bool);
    try testing.expect(obj.get("total_bytes").? == .null);
    try testing.expect(obj.get("log_path").? == .null);
}

test "buildCompletionMessage maps empty log content to (empty output)" {
    const msg = try buildCompletionMessage(testing.allocator, "true", 42, "", false, 0, "/tmp/x.log");
    defer testing.allocator.free(msg);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, msg, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("(empty output)", parsed.value.object.get("stdout").?.string);
}

test "buildCompletionMessage carries truncation fields when truncated" {
    const msg = try buildCompletionMessage(testing.allocator, "make", 7, "partial", true, 99999, "/tmp/full.log");
    defer testing.allocator.free(msg);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, msg, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("truncated").?.bool);
    try testing.expectEqual(@as(i64, 99999), obj.get("total_bytes").?.integer);
    try testing.expectEqualStrings("/tmp/full.log", obj.get("log_path").?.string);
}

test "buildCompletionMessage preserves metacharacters verbatim in JSON strings" {
    const msg = try buildCompletionMessage(testing.allocator, "echo <a>&", 9, "it's \"done\"", false, 12, "/tmp/x.log");
    defer testing.allocator.free(msg);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, msg, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("echo <a>&", obj.get("command").?.string);
    try testing.expectEqualStrings("it's \"done\"", obj.get("stdout").?.string);
}

test "readLogTruncated returns FileNotFound for a missing file" {
    const result = readLogTruncated(testing.allocator, testing.io, "/tmp/pabrik-bg-test-never-exists-12345.log", 100);
    try testing.expectError(error.FileNotFound, result);
}

test "readLogTruncated roundtrips a small file under cap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "small.log", .data = "hello log" });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "small.log" });
    defer testing.allocator.free(path);

    const got = try readLogTruncated(testing.allocator, testing.io, path, 100);
    defer got.free(testing.allocator);
    try testing.expectEqualStrings("hello log", got.content);
    try testing.expectEqual(@as(usize, 9), got.total_bytes);
    try testing.expectEqual(false, got.truncated);
}

test "readLogTruncated truncates a large file at cap (head semantics)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // 300 bytes of 'A' with a distinct head marker.
    var payload: [300]u8 = undefined;
    @memset(&payload, 'A');
    @memcpy(payload[0..4], "HEAD");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.log", .data = &payload });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "big.log" });
    defer testing.allocator.free(path);

    const got = try readLogTruncated(testing.allocator, testing.io, path, 100);
    defer got.free(testing.allocator);
    try testing.expectEqual(@as(usize, 100), got.content.len);
    try testing.expectEqual(@as(usize, 300), got.total_bytes);
    try testing.expectEqual(true, got.truncated);
    // Head: the first bytes are kept.
    try testing.expectEqualStrings("HEAD", got.content[0..4]);
}

test "readLogTruncated strips NUL bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // "nul" is a reserved DOS device name on Windows — `nul.log` makes
    // NtOpenFile return STATUS_OBJECT_NAME_INVALID, which Zig surfaces as
    // error.BadPathName (not FileNotFound) on `statFile`. Use a plain name.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "with_nuls.log", .data = "a\x00b\x00c" });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "with_nuls.log" });
    defer testing.allocator.free(path);

    const got = try readLogTruncated(testing.allocator, testing.io, path, 100);
    defer got.free(testing.allocator);
    try testing.expectEqualStrings("abc", got.content);
    // Total reflects the on-disk size (5), truncation flag is size-based.
    try testing.expectEqual(@as(usize, 5), got.total_bytes);
    try testing.expectEqual(false, got.truncated);
}

test "readLogTruncated handles an empty file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty.log", .data = "" });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "empty.log" });
    defer testing.allocator.free(path);

    const got = try readLogTruncated(testing.allocator, testing.io, path, 100);
    defer got.free(testing.allocator);
    try testing.expectEqual(@as(usize, 0), got.content.len);
    try testing.expectEqual(@as(usize, 0), got.total_bytes);
    try testing.expectEqual(false, got.truncated);
}

// ============================================================================
// Tests — the read cursor, and the service-only sweep
// ============================================================================

const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: SqliteBackend,
    threaded: std.Io.Threaded,

    fn deinit(self: *TestCtx) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

/// In-memory DB through the REAL migration chain — never a hand-rolled schema,
/// so `kind` and `last_read_offset` are whatever production actually has.
fn setupCtx() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(testing.allocator, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

/// Write `data` to a fresh file and return its absolute path (caller frees).
fn tmpLog(tmp: *testing.TmpDir, name: []const u8, data: []const u8, io: std.Io) ![]u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = data });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    return std.fs.path.join(testing.allocator, &.{ buf[0..n], name });
}

test "readDelta returns the whole log once, then only what is new" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const io = ctx.threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try tmpLog(&tmp, "svc.log", "first line\n", io);
    defer testing.allocator.free(log_path);

    const pid: u32 = 4242;
    try save(&ctx.db, testing.allocator, "s1", pid, "pnpm run dev", log_path, 1, KIND_SERVICE);

    // First read: the stored cursor is 0, so everything is new.
    const first = try readDelta(testing.allocator, io, &ctx.db, "s1", pid, log_path, 0, 4096);
    defer first.free(testing.allocator);
    try testing.expectEqualStrings("first line\n", first.bytes);
    try testing.expect(!first.empty);
    try testing.expect(!first.more_pending);
    try testing.expect(!first.missing);

    // NOTHING NEW is an answer, not an error — this is what makes polling a
    // long-running service cheap.
    const second = try readDelta(testing.allocator, io, &ctx.db, "s1", pid, log_path, first.next_offset, 4096);
    defer second.free(testing.allocator);
    try testing.expectEqualStrings("", second.bytes);
    try testing.expect(second.empty);

    // The process appends; the next read returns ONLY the new bytes — the whole
    // point of the cursor.
    {
        const f = try tmp.dir.openFile(io, "svc.log", .{ .mode = .write_only });
        defer f.close(io);
        try f.writePositionalAll(io, "second line\n", "first line\n".len);
    }
    const third = try readDelta(testing.allocator, io, &ctx.db, "s1", pid, log_path, second.next_offset, 4096);
    defer third.free(testing.allocator);
    try testing.expectEqualStrings("second line\n", third.bytes);
    try testing.expect(!third.empty);
    try testing.expectEqual(@as(i64, 23), third.total_bytes);

    // And the cursor was PERSISTED — the next caller sees the same position
    // without having to pass it, which is what lets the tool be stateless.
    var q = try ctx.db.query(testing.allocator, "SELECT last_read_offset FROM session_background_process WHERE session_id = ? AND pid = ?", &.{ "s1", "4242" });
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("23", row.values[0]);
}

test "readDelta caps one read and says more is waiting" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const io = ctx.threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try tmpLog(&tmp, "big.log", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", io);
    defer testing.allocator.free(log_path);

    const pid: u32 = 7;
    try save(&ctx.db, testing.allocator, "s2", pid, "build", log_path, 1, KIND_JOB);

    const first = try readDelta(testing.allocator, io, &ctx.db, "s2", pid, log_path, 0, 10);
    defer first.free(testing.allocator);
    try testing.expectEqual(@as(usize, 10), first.bytes.len);
    try testing.expect(first.more_pending);

    // The next read continues from where it stopped rather than repeating.
    const second = try readDelta(testing.allocator, io, &ctx.db, "s2", pid, log_path, first.next_offset, 10);
    defer second.free(testing.allocator);
    try testing.expectEqualStrings("AAAAAAAAAA", second.bytes);
    try testing.expect(second.more_pending);
}

test "readDelta recovers from a cursor past EOF instead of going silent for ever" {
    // A log can be TRUNCATED under a running cursor: the file is recreated,
    // or opened with `>`.
    var ctx = try setupCtx();
    defer ctx.deinit();
    const io = ctx.threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try tmpLog(&tmp, "shrink.log", "short\n", io);
    defer testing.allocator.free(log_path);

    const pid: u32 = 11;
    try save(&ctx.db, testing.allocator, "s3", pid, "watch", log_path, 1, KIND_SERVICE);

    const read = try readDelta(testing.allocator, io, &ctx.db, "s3", pid, log_path, 9999, 4096);
    defer read.free(testing.allocator);
    // The clamp restarts from the beginning, so the file is re-reported.
    try testing.expectEqualStrings("short\n", read.bytes);
    try testing.expectEqual(@as(i64, 6), read.total_bytes);
}

test "readDelta reports a missing log as `missing`, not as empty output" {
    // "The command never started" and "the command said nothing" need different
    // responses from the model, so they must not arrive as the same value.
    var ctx = try setupCtx();
    defer ctx.deinit();
    const io = ctx.threaded.io();

    const pid: u32 = 12;
    try save(&ctx.db, testing.allocator, "s4", pid, "gone", "/tmp/pabrik-process-never-created.log", 1, KIND_JOB);

    const read = try readDelta(testing.allocator, io, &ctx.db, "s4", pid, "/tmp/pabrik-process-never-created.log", 0, 4096);
    defer read.free(testing.allocator);
    try testing.expect(read.missing);
    try testing.expectEqual(@as(usize, 0), read.bytes.len);
}

test "getByPid refuses a pid that belongs to another session" {
    // The pid is the model's argument, so it is untrusted input: without the
    // session filter a session could read — or stop — another session's
    // process, and pids are small enough to guess.
    var ctx = try setupCtx();
    defer ctx.deinit();

    try save(&ctx.db, testing.allocator, "owner", 99, "pnpm run dev", "/tmp/x.log", 1, KIND_SERVICE);
    // A second session that "knows" the pid.
    try save(&ctx.db, testing.allocator, "intruder", 100, "other", "/tmp/y.log", 1, KIND_JOB);

    // Every non-null answer owns its strings — free them, or the DebugAllocator
    // reports this test as a leak (which is how CI caught it).
    if (try getByPid(&ctx.db, testing.allocator, "owner", 99)) |owned| {
        freeProcessInfo(testing.allocator, owned);
    } else return error.TestUnexpectedResult;

    try testing.expect((try getByPid(&ctx.db, testing.allocator, "intruder", 99)) == null);

    // The positive control for the line above: the intruder CAN see its own.
    if (try getByPid(&ctx.db, testing.allocator, "intruder", 100)) |owned| {
        freeProcessInfo(testing.allocator, owned);
    } else return error.TestUnexpectedResult;
}

test "killServicesForShutdown touches services only, never a job" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const io = ctx.threaded.io();

    // Both PIDs are dead, so nothing is actually signalled and the test asserts
    // the SELECTION — which is the part that decides whether a user's build is
    // killed.
    try save(&ctx.db, testing.allocator, "s_svc", 999_999_901, "pnpm run dev", "/tmp/a.log", 1, KIND_SERVICE);
    try save(&ctx.db, testing.allocator, "s_job", 999_999_902, "zig build", "/tmp/b.log", 2, KIND_JOB);

    _ = try killServicesForShutdown(&ctx.db, io, testing.allocator);

    var svc = try ctx.db.query(testing.allocator, "SELECT status FROM session_background_process WHERE session_id = ?", &.{"s_svc"});
    defer svc.deinit();
    const svc_row = (try svc.next()) orelse return error.RowMissing;
    defer svc_row.deinit(testing.allocator);
    try testing.expectEqualStrings("killed", svc_row.values[0]);

    // The JOB is untouched: `killServicesForShutdown` runs at shutdown and at
    // boot, and a bounded build is not a service that outlived its owner.
    var job = try ctx.db.query(testing.allocator, "SELECT status FROM session_background_process WHERE session_id = ?", &.{"s_job"});
    defer job.deinit();
    const job_row = (try job.next()) orelse return error.RowMissing;
    defer job_row.deinit(testing.allocator);
    try testing.expectEqualStrings("running", job_row.values[0]);
}

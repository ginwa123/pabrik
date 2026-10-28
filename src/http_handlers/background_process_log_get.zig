//! `GET
//! /api/llm/session/:session_id/background_processes/:pid/log?max_bytes=20480`
//! — read the TAIL of one background process's log file.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;

pub const BackgroundProcessLogError = error{
    MissingSessionId,
    MissingPid,
    InvalidPid,
    /// No row for (session_id, pid) — the handler maps this to 404.
    ProcessNotFound,
    QueryFailed,
    /// The log file exists but could not be read (permissions, I/O
    /// error — anything other than FileNotFound, which yields the
    /// 200 not-found marker instead).
    LogReadFailed,
    /// `allocator.dupe` / `allocPrint` returned no memory. In
    /// production the per-request arena makes this unreachable but
    /// the type system requires the variant.
    OutOfMemory,
};

pub const BackgroundProcessLogResponse = struct {
    pid: u32,
    log_path: []const u8,
    total_bytes: usize,
    truncated: bool,
    content: []const u8,
};

pub const BackgroundProcessLogResult = []const u8; // pre-serialized JSON

/// Default + bounds for the `?max_bytes=` query param.
pub const default_max_bytes: usize = 20480;
pub const min_max_bytes: usize = 1;
pub const max_max_bytes: usize = 1048576;

/// Clamp a raw `max_bytes` value into [1, 1048576].
pub fn clampMaxBytes(raw: usize) usize {
    return @min(@max(raw, min_max_bytes), max_max_bytes);
}

/// Parse the raw `?max_bytes=` query value: unparseable/empty falls
/// back to the default; parseable values are clamped.
pub fn parseMaxBytes(raw: ?[]const u8) usize {
    const s = raw orelse return default_max_bytes;
    const parsed = std.fmt.parseInt(usize, s, 10) catch return default_max_bytes;
    return clampMaxBytes(parsed);
}

// =====================================================================
// Use case
// =====================================================================

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    io: std.Io,
    session_id: []const u8,
    pid: u32,
    max_bytes: usize,
) BackgroundProcessLogError!BackgroundProcessLogResult {
    if (session_id.len == 0) return error.MissingSessionId;

    const cap = clampMaxBytes(max_bytes);

    const pid_str = std.fmt.allocPrint(allocator, "{d}", .{pid}) catch return error.OutOfMemory;
    defer allocator.free(pid_str);

    // Resolve log_path ONLY from the DB row — never from client input.
    var rows = db.query(
        allocator,
        "SELECT log_path FROM session_background_process WHERE session_id = ? AND pid = ?",
        &.{ session_id, pid_str },
    ) catch return error.QueryFailed;
    defer rows.deinit();

    const row_opt = rows.next() catch return error.QueryFailed;
    const row = row_opt orelse return error.ProcessNotFound;
    defer row.deinit(allocator);

    const log_path = allocator.dupe(u8, row.values[0]) catch return error.OutOfMemory;
    // The JSON body deep-copies the path, so the dupe is freed here — it must
    // NOT outlive the call (under testing.allocator it would report as a
    // leak; under the per-request arena the free is a harmless no-op).
    defer allocator.free(log_path);

    // Missing file -> 200 not-found marker (documented above), NOT 404.
    const tail = readLogTail(allocator, io, log_path, cap) catch |err| {
        if (err == error.FileNotFound) {
            const resp = BackgroundProcessLogResponse{
                .pid = pid,
                .log_path = log_path,
                .total_bytes = 0,
                .truncated = false,
                .content = "(log file not found)",
            };
            return try std.json.Stringify.valueAlloc(allocator, resp, .{});
        }
        return error.LogReadFailed;
    };
    defer allocator.free(tail.content);

    const resp = BackgroundProcessLogResponse{
        .pid = pid,
        .log_path = log_path,
        .total_bytes = tail.total_bytes,
        .truncated = tail.truncated,
        .content = tail.content,
    };
    return try std.json.Stringify.valueAlloc(allocator, resp, .{});
}

const TailLog = struct {
    content: []u8,
    total_bytes: usize,
    truncated: bool,
};

/// Read the LAST `cap_bytes` bytes of the file at `log_path`, strip NUL bytes
/// (SSE/JSON safety), and report the full size.
fn readLogTail(
    allocator: std.mem.Allocator,
    io: std.Io,
    log_path: []const u8,
    cap_bytes: usize,
) !TailLog {
    const cwd = std.Io.Dir.cwd();

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
    const start: usize = total - to_read;

    const file = if (std.fs.path.isAbsolute(log_path))
        try std.Io.Dir.openFileAbsolute(io, log_path, .{})
    else
        try cwd.openFile(io, log_path, .{});
    defer file.close(io);

    const raw = try allocator.alloc(u8, to_read);
    errdefer allocator.free(raw);
    var filled: usize = 0;
    while (filled < raw.len) {
        const n = try file.readPositionalAll(io, raw[filled..], start + filled);
        if (n == 0) break; // EOF — file shrank between stat and read.
        filled += n;
    }
    const window = raw[0..filled];
    defer allocator.free(raw);

    // Compact out NUL bytes into an exactly-sized owned slice.
    var kept: usize = 0;
    for (window) |b| {
        if (b != 0) kept += 1;
    }
    const out = try allocator.alloc(u8, kept);
    var i: usize = 0;
    for (window) |b| {
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

// =====================================================================
// Handler
// =====================================================================

pub fn backgroundProcessLogGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }),
        });
    };
    if (session_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }),
        });
    }

    const pid_str = req.params.get("pid") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing pid" }),
        });
    };
    const pid = std.fmt.parseInt(u32, pid_str, 10) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid pid" }),
        });
    };

    const max_bytes = parseMaxBytes(req.query.get("max_bytes"));

    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }),
        });
    };

    const json_str = useCase(allocator, di.db, io, session_id, pid, max_bytes) catch |err| {
        const status: u16 = switch (err) {
            error.MissingSessionId => 400,
            error.MissingPid => 400,
            error.InvalidPid => 400,
            error.ProcessNotFound => 404,
            error.QueryFailed => 500,
            error.LogReadFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.MissingSessionId => "Missing session_id",
            error.MissingPid => "Missing pid",
            error.InvalidPid => "Invalid pid",
            error.ProcessNotFound => "background process not found",
            error.QueryFailed => "Database query failed",
            error.LogReadFailed => "Failed to read log file",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}

// =====================================================================
// Inline tests (project convention — useCase directly against an in-memory DB
// walked through ALL migrations, never hand-rolled CREATE TABLE bodies; log

const testing = std.testing;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: pabrikcore.database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: pabrikcore.database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    var manager = migration.MigrationManager.init(testing.allocator, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn insertBgRow(
    db: *pabrikcore.database.Db,
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
) !void {
    const alloc = testing.allocator;
    const pid_str = try std.fmt.allocPrint(alloc, "{d}", .{pid});
    defer alloc.free(pid_str);
    try db.exec(alloc,
        \\INSERT INTO session_background_process (session_id, pid, command, log_path, started_at, status)
        \\VALUES (?, ?, ?, ?, 1700000000, 'running')
    , &.{ session_id, pid_str, command, log_path });
}

/// Write `data` to `<tmpdir>/t.log` and return the absolute path
/// (caller-owned). The tmpDir cleanup is the caller's job — the path
/// stays valid until then.
fn writeTmpLog(tmp: *std.testing.TmpDir, data: []const u8) ![]u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "t.log", .data = data });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    return try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "t.log" });
}

test "useCase returns the full content with truncated=false when under cap" {
    var ctx = try setupDb();
    defer teardownDb(&ctx);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const log_path = try writeTmpLog(&tmp, "hello log");
    defer testing.allocator.free(log_path);
    try insertBgRow(&ctx.db, "sess_log_001", 4242, "sleep 10", log_path);

    const json = try useCase(testing.allocator, &ctx.db, testing.io, "sess_log_001", 4242, 20480);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(BackgroundProcessLogResponse, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 4242), parsed.value.pid);
    try testing.expectEqualStrings(log_path, parsed.value.log_path);
    try testing.expectEqual(@as(usize, 9), parsed.value.total_bytes);
    try testing.expectEqual(false, parsed.value.truncated);
    try testing.expectEqualStrings("hello log", parsed.value.content);
}

test "useCase returns the TAIL (last bytes) when the file exceeds cap" {
    var ctx = try setupDb();
    defer teardownDb(&ctx);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // 300 bytes: distinct HEAD + TAIL markers so head-vs-tail is visible.
    var payload: [300]u8 = undefined;
    @memset(&payload, 'A');
    @memcpy(payload[0..4], "HEAD");
    @memcpy(payload[296..300], "TAIL");
    const log_path = try writeTmpLog(&tmp, &payload);
    defer testing.allocator.free(log_path);
    try insertBgRow(&ctx.db, "sess_log_002", 4243, "make", log_path);

    const json = try useCase(testing.allocator, &ctx.db, testing.io, "sess_log_002", 4243, 100);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(BackgroundProcessLogResponse, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 300), parsed.value.total_bytes);
    try testing.expectEqual(true, parsed.value.truncated);
    try testing.expectEqual(@as(usize, 100), parsed.value.content.len);
    try testing.expectEqualStrings("TAIL", parsed.value.content[96..100]);
}

test "useCase returns 200 not-found marker for a missing log file" {
    var ctx = try setupDb();
    defer teardownDb(&ctx);

    try insertBgRow(&ctx.db, "sess_log_003", 4244, "sleep 5", "/tmp/pabrik-bg-test-never-exists-4244.log");

    const json = try useCase(testing.allocator, &ctx.db, testing.io, "sess_log_003", 4244, 20480);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(BackgroundProcessLogResponse, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.total_bytes);
    try testing.expectEqual(false, parsed.value.truncated);
    try testing.expectEqualStrings("(log file not found)", parsed.value.content);
}

test "useCase returns ProcessNotFound for an unknown (session, pid)" {
    var ctx = try setupDb();
    defer teardownDb(&ctx);

    const result = useCase(testing.allocator, &ctx.db, testing.io, "sess_log_004", 9999, 20480);
    try testing.expectError(error.ProcessNotFound, result);
}

test "useCase rejects an empty session_id" {
    var ctx = try setupDb();
    defer teardownDb(&ctx);

    const result = useCase(testing.allocator, &ctx.db, testing.io, "", 4242, 20480);
    try testing.expectError(error.MissingSessionId, result);
}

test "useCase strips NUL bytes from tail content" {
    var ctx = try setupDb();
    defer teardownDb(&ctx);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const log_path = try writeTmpLog(&tmp, "a\x00b\x00c");
    defer testing.allocator.free(log_path);
    try insertBgRow(&ctx.db, "sess_log_005", 4245, "nul-cmd", log_path);

    const json = try useCase(testing.allocator, &ctx.db, testing.io, "sess_log_005", 4245, 20480);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(BackgroundProcessLogResponse, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("abc", parsed.value.content);
}

test "clampMaxBytes enforces [1, 1048576]" {
    try testing.expectEqual(@as(usize, 1), clampMaxBytes(0));
    try testing.expectEqual(@as(usize, 1), clampMaxBytes(1));
    try testing.expectEqual(@as(usize, 20480), clampMaxBytes(20480));
    try testing.expectEqual(@as(usize, 1048576), clampMaxBytes(1048576));
    try testing.expectEqual(@as(usize, 1048576), clampMaxBytes(10 * 1024 * 1024));
}

test "parseMaxBytes defaults on missing/garbage and clamps the rest" {
    try testing.expectEqual(default_max_bytes, parseMaxBytes(null));
    try testing.expectEqual(default_max_bytes, parseMaxBytes(""));
    try testing.expectEqual(default_max_bytes, parseMaxBytes("not-a-number"));
    try testing.expectEqual(@as(usize, 100), parseMaxBytes("100"));
    try testing.expectEqual(@as(usize, 1), parseMaxBytes("0"));
    try testing.expectEqual(@as(usize, 1048576), parseMaxBytes("99999999"));
}

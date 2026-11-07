const std = @import("std");
const builtin = @import("builtin");
const timing = @import("Timing.zig");
const request_id = @import("RequestId.zig");
const formatter = @import("Formatter.zig");

/// Re-export types from formatter module
pub const LogLevel = formatter.LogLevel;
pub const LogEntry = formatter.LogEntry;
pub const Formatter = formatter.Formatter;
pub const TextFormatter = formatter.TextFormatter;
pub const JsonFormatter = formatter.JsonFormatter;
pub const ColorFormatter = formatter.ColorFormatter;
pub const AnsiColors = formatter.AnsiColors;
pub const getAgentColor = formatter.getAgentColor;

/// Re-export types from request_id module
pub const RequestId = request_id.RequestId;
pub const SessionId = request_id.SessionId;
pub const generateRequestId = request_id.generateRequestId;
pub const generateSessionId = request_id.generateSessionId;

/// Re-export timing functions
pub const timestampMs = timing.timestampMs;
pub const elapsedMs = timing.elapsedMs;
pub const formatDuration = timing.formatDuration;
pub const timestampIso = timing.timestampIso;
pub const timestampCompact = timing.timestampCompact;

/// Output mode for logger
pub const OutputMode = enum {
    stdout,
    file,
    both,
};

/// Configuration for Logger
pub const LoggerConfig = struct {
    /// Minimum log level to output (messages below this level are filtered)
    min_level: LogLevel = .info,
    /// Include timestamp in output
    include_timestamp: bool = true,
    /// Include request ID in output
    include_request_id: bool = true,
    /// Output writer (defaults to stdout)
    output: ?std.Io.Writer = null,
    /// Include file:line location in output
    include_location: bool = true,
    /// Path to log file (null means no file output)
    log_file_path: ?[]const u8 = null,
    /// Maximum file size before rotation (default 10MB)
    max_file_size_bytes: usize = 10 * 1024 * 1024,
    /// Enable automatic file rotation at size limit
    enable_auto_rotation: bool = true,
    /// Output mode: stdout, file, or both
    output_mode: OutputMode = .stdout,
};

/// Timber-style console debug print without per-site `if`s.
pub fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print(fmt, args);
}

/// Thread-safe logger with pluggable formatters
pub const Logger = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: LoggerConfig,
    mutex: std.Io.Mutex,
    formatter_ctx: FormatterContext,
    request_id: ?RequestId,
    log_file: ?std.Io.File = null,
    current_file_size: usize = 0,

    const FormatterContext = union(enum) {
        text: TextFormatter,
        json: JsonFormatter,
        color: ColorFormatter,
    };

    /// Initialize a new Logger with text formatter
    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: LoggerConfig) Logger {
        return .{
            .allocator = allocator,
            .config = config,
            .mutex = std.Io.Mutex.init,
            .formatter_ctx = .{ .text = TextFormatter{
                .include_timestamp = config.include_timestamp,
                .include_request_id = config.include_request_id,
                .include_location = config.include_location,
                .io = io,
            } },
            .request_id = null,
            .io = io,
        };
    }

    /// Initialize a new Logger with JSON formatter
    pub fn initJson(allocator: std.mem.Allocator, io: std.Io, config: LoggerConfig) Logger {
        return .{ .allocator = allocator, .config = config, .mutex = std.Io.Mutex.init, .formatter_ctx = .{ .json = JsonFormatter{ .pretty = false } }, .request_id = null, .io = io };
    }

    /// Initialize a new Logger with color formatter (for TUI)
    pub fn initColor(allocator: std.mem.Allocator, io: std.Io, config: LoggerConfig) Logger {
        return .{
            .allocator = allocator,
            .config = config,
            .mutex = std.Io.Mutex.init,
            .formatter_ctx = .{ .color = ColorFormatter{
                .include_timestamp = config.include_timestamp,
                .include_request_id = config.include_request_id,
                .color_by_level = true,
                .include_location = config.include_location,
                .io = io,
            } },
            .request_id = null,
            .io = io,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Logger) void {
        // Close log file if open
        if (self.log_file) |file| {
            file.close(self.io);
            self.log_file = null;
        }
    }

    /// Ensure log file is open, creating parent directories if needed.
    fn ensureLogFileOpen(self: *Logger) !void {
        if (self.log_file != null) return;

        const path = self.config.log_file_path orelse return;

        // Create parent directories if they don't exist
        const dir_path = std.fs.path.dirname(path) orelse ".";
        try std.Io.Dir.cwd().createDirPath(self.io, dir_path);

        // Open or create the log file. `.truncate = false` preserves any
        // existing content; the new file's position is 0 (kernel default).
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = false });
        errdefer file.close(self.io);

        // Record the current end-of-file offset; this is where the next write
        // will land (via writePositionalAll in writeEntry).
        const file_size: u64 = stat: {
            const s = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch break :stat 0;
            break :stat s.size;
        };
        self.current_file_size = file_size;
        self.log_file = file;
    }

    /// Rotate log file when it exceeds max size (delete and recreate)
    fn rotateLogFile(self: *Logger) !void {
        if (self.log_file) |file| {
            file.close(self.io);
            self.log_file = null;
        }

        const path = self.config.log_file_path orelse return;

        // Delete the old file
        std.Io.Dir.cwd().deleteFile(self.io, path) catch {};

        // Create a new empty file
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        self.log_file = file;
        self.current_file_size = 0;
    }

    /// Set a new request ID for subsequent log messages
    pub fn setRequestId(self: *Logger, id: RequestId) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.request_id = id;
    }

    /// Generate and set a new request ID
    pub fn generateAndSetRequestId(self: *Logger) RequestId {
        const id = generateRequestId();
        self.setRequestId(id);
        return id;
    }

    /// Clear the current request ID
    pub fn clearRequestId(self: *Logger) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.request_id = null;
    }

    /// Get the current request ID as a string (if set)
    pub fn getRequestIdString(self: *const Logger) ?[]const u8 {
        if (self.request_id) |*id| {
            return id.toString();
        }
        return null;
    }

    /// Log a message at the specified level
    pub fn log(self: *Logger, level: LogLevel, message: []const u8) !void {
        // Filter by minimum level
        if (@intFromEnum(level) < @intFromEnum(self.config.min_level)) {
            return;
        }

        const entry = LogEntry{
            .level = level,
            .timestamp = timestampMs(self.io),
            .request_id = self.getRequestIdString(),
            .message = message,
            .file = null,
            .line = null,
        };

        try self.writeEntry(entry);
    }

    /// Log a message at the specified level with context
    pub fn logWithContext(self: *Logger, level: LogLevel, message: []const u8, context: []const u8) !void {
        // Filter by minimum level
        if (@intFromEnum(level) < @intFromEnum(self.config.min_level)) {
            return;
        }

        const entry = LogEntry{
            .level = level,
            .timestamp = timestampMs(self.io),
            .request_id = self.getRequestIdString(),
            .message = message,
            .context = context,
            .file = null,
            .line = null,
        };

        try self.writeEntry(entry);
    }

    /// Log a formatted message at the specified level
    pub fn logFmt(self: *Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(message);
        try self.log(level, message);
    }

    /// Log formatted at TRACE level
    pub fn traceFmt(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.logFmt(.trace, fmt, args) catch {
            std.debug.print("[LOGGER] Error in traceFmt: \n", .{});
        };
    }

    /// Log formatted at DEBUG level
    pub fn debugFmt(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.logFmt(.debug, fmt, args) catch {
            std.debug.print("[LOGGER] Error in debugFmt: \n", .{});
        };
    }

    /// Log formatted at INFO level
    pub fn infoFmt(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.logFmt(.info, fmt, args) catch {
            std.debug.print("[LOGGER] Error in infoFmt: \n", .{});
        };
    }

    /// Log formatted at WARN level
    pub fn warnFmt(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.logFmt(.warn, fmt, args) catch {
            std.debug.print("[LOGGER] Error in warnFmt: \n", .{});
        };
    }

    /// Log formatted at ERROR level
    pub fn errFmt(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.logFmt(.err, fmt, args) catch {
            std.debug.print("[LOGGER] Error in errFmt: \n", .{});
        };
    }

    /// Write a log entry using the configured formatter
    fn writeEntry(self: *Logger, entry: LogEntry) !void {
        // Format the entry
        const output: []const u8 = switch (self.formatter_ctx) {
            .text => |*f| try f.formatter().format(self.allocator, entry),
            .json => |*f| try f.formatter().format(self.allocator, entry),
            .color => |*f| try f.formatter().format(self.allocator, entry),
        };
        defer self.allocator.free(output);

        // Thread-safe write to output
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Handle file output if configured
        if (self.config.log_file_path != null and
            (self.config.output_mode == .file or self.config.output_mode == .both))
        {
            // Ensure file is open
            try self.ensureLogFileOpen();

            // Check if rotation is needed
            if (self.config.enable_auto_rotation and
                self.current_file_size >= self.config.max_file_size_bytes)
            {
                try self.rotateLogFile();
            }

            // Write to file
            if (self.log_file) |log_file| {
                // Use writePositionalAll (pwrite) at the tracked end-of-file
                // offset.
                try std.Io.File.writePositionalAll(log_file, self.io, output, self.current_file_size);
                self.current_file_size += output.len;
            }
        }

        // Handle stdout output if configured.
        if (!builtin.is_test and (self.config.output_mode == .stdout or self.config.output_mode == .both)) {
            try std.Io.File.writeStreamingAll(std.Io.File.stderr(), self.io, output);
        }
    }

    /// Set the minimum log level
    pub fn setMinLevel(self: *Logger, level: LogLevel) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.config.min_level = level;
    }

    /// Get the current minimum log level
    pub fn getMinLevel(self: *const Logger) LogLevel {
        return self.config.min_level;
    }
};

/// Global logger instance (optional convenience)
var global_logger: ?Logger = null;
var global_mutex: std.Io.Mutex = std.Io.Mutex.init;

/// Initialize the global logger
pub fn initGlobal(allocator: std.mem.Allocator, io: std.Io, config: LoggerConfig) void {
    global_mutex.lockUncancelable(io);
    defer global_mutex.unlock(io);

    if (global_logger) |*logger| {
        logger.deinit();
    }
    global_logger = Logger.init(allocator, io, config);
}

/// Initialize the global logger with color formatter
pub fn initGlobalColor(allocator: std.mem.Allocator, io: std.Io, config: LoggerConfig) void {
    global_mutex.lockUncancelable(io);
    defer global_mutex.unlock(io);

    if (global_logger) |*logger| {
        logger.deinit();
    }
    global_logger = Logger.initColor(allocator, io, config);
}

/// Deinitialize the global logger
pub fn deinitGlobal(io: std.Io) void {
    global_mutex.lockUncancelable(io);
    defer global_mutex.unlock(io);

    if (global_logger) |*logger| {
        logger.deinit();
        global_logger = null;
    }
}

/// Get the global logger (returns null if not initialized)
pub fn getGlobal() ?*Logger {
    if (global_logger) |*logger| {
        return logger;
    }
    return null;
}

const CountingAllocator = struct {
    parent: std.mem.Allocator,
    live_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const out = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live_bytes += len;
        return out;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const out = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return out;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret_addr);
        self.live_bytes -= memory.len;
    }
};

fn tmpLogPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

fn readLog(io: std.Io, path: []const u8, buf: []u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const n = try std.Io.File.readStreaming(file, io, &.{buf});
    return buf[0..n];
}

fn expectNoFile(io: std.Io, path: []const u8) !void {
    const opened = std.Io.Dir.cwd().openFile(io, path, .{});
    if (opened) |file| {
        file.close(io);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    }
}

test "a message below the minimum level never reaches the file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpLogPath(allocator, &tmp, "filtered.log");
    defer allocator.free(path);

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .warn,
        .log_file_path = path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.debug, "dropped");
    try logger_inst.log(.info, "dropped too");

    try expectNoFile(std.testing.io, path);
}

test "a message at the minimum level reaches the file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpLogPath(allocator, &tmp, "kept.log");
    defer allocator.free(path);

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .warn,
        .log_file_path = path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.warn, "kept");

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("[WARN] kept\n", try readLog(std.testing.io, path, &buf));
}

test "setMinLevel changes which messages reach the file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpLogPath(allocator, &tmp, "level.log");
    defer allocator.free(path);

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .err,
        .log_file_path = path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "before");
    logger_inst.setMinLevel(.debug);
    try logger_inst.log(.info, "after");

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("[INFO] after\n", try readLog(std.testing.io, path, &buf));
}

test "the request id is written with each line while it is set" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpLogPath(allocator, &tmp, "request_id.log");
    defer allocator.free(path);

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = true,
    });
    defer logger_inst.deinit();

    const id = logger_inst.generateAndSetRequestId();
    try logger_inst.log(.info, "with id");
    logger_inst.clearRequestId();
    try logger_inst.log(.info, "without id");

    const expected = try std.fmt.allocPrint(allocator, "[INFO] [{s}] with id\n[INFO] without id\n", .{id.toString()});
    defer allocator.free(expected);

    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try readLog(std.testing.io, path, &buf));
}

test "logWithContext appends the context to the line" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpLogPath(allocator, &tmp, "context.log");
    defer allocator.free(path);

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.logWithContext(.info, "User action", "user_id=123");

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("[INFO] User action (user_id=123)\n", try readLog(std.testing.io, path, &buf));
}

test "logFmt formats its arguments into the line" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpLogPath(allocator, &tmp, "fmt.log");
    defer allocator.free(path);

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.logFmt(.info, "processed {d} items for {s}", .{ 42, "alice" });

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("[INFO] processed 42 items for alice\n", try readLog(std.testing.io, path, &buf));
}

test "file output creates the missing parent directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpLogPath(allocator, &tmp, "nested/deeper/app.log");
    defer allocator.free(path);

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "nested");

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("[INFO] nested\n", try readLog(std.testing.io, path, &buf));
}

test "a second logger appends to the file instead of overwriting it" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpLogPath(allocator, &tmp, "append.log");
    defer allocator.free(path);

    {
        var first = Logger.init(allocator, std.testing.io, .{
            .min_level = .info,
            .log_file_path = path,
            .output_mode = .file,
            .include_timestamp = false,
            .include_request_id = false,
        });
        defer first.deinit();
        try first.log(.info, "FIRST_RUN_MESSAGE");
    }

    {
        var second = Logger.init(allocator, std.testing.io, .{
            .min_level = .info,
            .log_file_path = path,
            .output_mode = .file,
            .include_timestamp = false,
            .include_request_id = false,
        });
        defer second.deinit();
        try second.log(.info, "SECOND_RUN_MESSAGE");
    }

    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "[INFO] FIRST_RUN_MESSAGE\n[INFO] SECOND_RUN_MESSAGE\n",
        try readLog(std.testing.io, path, &buf),
    );
}

test "rotation keeps the newest messages and never writes a partial line" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpLogPath(allocator, &tmp, "rotation.log");
    defer allocator.free(path);

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = path,
        .output_mode = .file,
        .max_file_size_bytes = 50,
        .enable_auto_rotation = true,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    for ([_][]const u8{ "AAA", "BBB", "CCC", "DDD", "EEE", "FFF", "GGG", "HHH", "III", "JJJ" }) |message| {
        try logger_inst.log(.info, message);
    }

    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(
        "[INFO] FFF\n[INFO] GGG\n[INFO] HHH\n[INFO] III\n[INFO] JJJ\n",
        try readLog(std.testing.io, path, &buf),
    );
}

test "the json formatter writes one parseable object per line" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpLogPath(allocator, &tmp, "json.log");
    defer allocator.free(path);

    var logger_inst = Logger.initJson(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = path,
        .output_mode = .file,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.warn, "structured");

    var buf: [512]u8 = undefined;
    const content = try readLog(std.testing.io, path, &buf);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trimEnd(u8, content, "\n"), .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("WARN", parsed.value.object.get("level").?.string);
    try std.testing.expectEqualStrings("structured", parsed.value.object.get("message").?.string);
}

test "the color formatter marks an error line with the red ansi code" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpLogPath(allocator, &tmp, "color.log");
    defer allocator.free(path);

    var logger_inst = Logger.initColor(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = path,
        .output_mode = .file,
        .include_timestamp = false,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.err, "boom");

    var buf: [512]u8 = undefined;
    const content = try readLog(std.testing.io, path, &buf);
    try std.testing.expect(std.mem.indexOf(u8, content, AnsiColors.red) != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "boom") != null);
}

test "repeated logging does not grow live heap bytes" {
    var counting = CountingAllocator{ .parent = std.testing.allocator };
    const allocator = counting.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpLogPath(allocator, &tmp, "heap.log");
    defer allocator.free(path);

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "warm up");
    const baseline = counting.live_bytes;

    for (0..16) |_| {
        try logger_inst.log(.info, "steady state");
    }

    try std.testing.expectEqual(baseline, counting.live_bytes);
}

test "getGlobal is null until initGlobal and the same logger afterwards" {
    try std.testing.expectEqual(@as(?*Logger, null), getGlobal());

    initGlobal(std.testing.allocator, std.testing.io, .{ .min_level = .debug });
    defer deinitGlobal(std.testing.io);

    const global = getGlobal() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(LogLevel.debug, global.getMinLevel());

    deinitGlobal(std.testing.io);
    try std.testing.expectEqual(@as(?*Logger, null), getGlobal());
}

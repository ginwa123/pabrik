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

// ===== Tests merged from logger_test.zig (2026-09-29 flatten) =====
test "Logger init and deinit" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{});
    defer logger_inst.deinit();

    try std.testing.expectEqual(LogLevel.info, logger_inst.getMinLevel());
}

test "Logger with custom config" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .debug,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try std.testing.expectEqual(LogLevel.debug, logger_inst.getMinLevel());
}

test "Logger setMinLevel" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{ .min_level = .info });
    defer logger_inst.deinit();

    try std.testing.expectEqual(LogLevel.info, logger_inst.getMinLevel());

    logger_inst.setMinLevel(.debug);
    try std.testing.expectEqual(LogLevel.debug, logger_inst.getMinLevel());
}

test "Logger request ID management" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{});
    defer logger_inst.deinit();

    // Initially no request ID
    try std.testing.expectEqual(@as(?[]const u8, null), logger_inst.getRequestIdString());

    // Set a request ID
    const id = generateRequestId();
    logger_inst.setRequestId(id);

    const id_str = logger_inst.getRequestIdString();
    try std.testing.expect(id_str != null);
    try std.testing.expect(std.mem.startsWith(u8, id_str.?, "REQ-"));

    // Clear request ID
    logger_inst.clearRequestId();
    try std.testing.expectEqual(@as(?[]const u8, null), logger_inst.getRequestIdString());
}

test "Logger generateAndSetRequestId" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{});
    defer logger_inst.deinit();

    const id = logger_inst.generateAndSetRequestId();
    const id_str = id.toString();

    try std.testing.expect(std.mem.startsWith(u8, id_str, "REQ-"));
    try std.testing.expectEqual(id_str.len, 24);
}

test "Logger with JSON formatter" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.initJson(allocator, std.testing.io, .{ .min_level = .info });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "Test JSON message");
}

test "Logger with color formatter" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.initColor(allocator, std.testing.io, .{ .min_level = .info });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "Test color message");
    try logger_inst.log(.err, "Test error message");
}

test "Logger formatted messages" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{ .min_level = .debug });
    defer logger_inst.deinit();

    // All formatted log methods return void (not error union)
    logger_inst.debugFmt("User {s} logged in", .{"alice"});
    logger_inst.infoFmt("Processing {d} items", .{42});
    logger_inst.warnFmt("Low memory: {d}MB remaining", .{128});
    logger_inst.errFmt("Failed to connect to {s}:{d}", .{ "localhost", 8080 });
}

test "Logger logWithContext" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{ .min_level = .info });
    defer logger_inst.deinit();

    try logger_inst.logWithContext(.info, "User action", "user_id=123&action=login");
}

test "LogLevel ordering" {
    // Verify log levels are ordered correctly for filtering
    try std.testing.expect(@intFromEnum(LogLevel.trace) < @intFromEnum(LogLevel.debug));
    try std.testing.expect(@intFromEnum(LogLevel.debug) < @intFromEnum(LogLevel.info));
    try std.testing.expect(@intFromEnum(LogLevel.info) < @intFromEnum(LogLevel.warn));
    try std.testing.expect(@intFromEnum(LogLevel.warn) < @intFromEnum(LogLevel.err));
}

// New tests for file output, rotation, and location features

test "Logger file output creates file and writes logs" {
    const allocator = std.testing.allocator;
    const test_log_path = "./test_logger_output.log";

    // Clean up any existing file
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer {
        logger_inst.deinit();
        std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};
    }

    // Log a message
    try logger_inst.log(.info, "Test file output message");

    // Verify file was created by opening it successfully
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, test_log_path, .{});
    file.close(std.testing.io);
}

test "Logger file rotation at size limit" {
    const allocator = std.testing.allocator;
    const test_log_path = "./test_logger_rotation.log";

    // Clean up any existing file
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .file,
        .max_file_size_bytes = 100, // Small limit for testing
        .enable_auto_rotation = true,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer {
        logger_inst.deinit();
        std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};
    }

    // Write multiple messages to exceed size limit
    try logger_inst.log(.info, "First message that is long enough to trigger rotation soon");
    try logger_inst.log(.info, "Second message that should cause rotation");
    try logger_inst.log(.info, "Third message after rotation");

    // File should exist after rotation
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, test_log_path, .{});
    file.close(std.testing.io);
}

test "Logger both output mode writes to stdout and file" {
    const allocator = std.testing.allocator;
    const test_log_path = "./test_logger_both.log";

    // Clean up any existing file
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .both,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer {
        logger_inst.deinit();
        std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};
    }

    // Log a message (goes to both stdout and file)
    try logger_inst.log(.info, "Test both output mode");

    // Verify file was created by opening it
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, test_log_path, .{});
    file.close(std.testing.io);
}

test "Logger directory creation for log file" {
    const allocator = std.testing.allocator;
    const test_dir = "./test_logger_nested_dir";
    const test_log_path = test_dir ++ "/nested/log.txt";

    // Clean up any existing directory
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer {
        logger_inst.deinit();
        std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    }

    // Log a message - this should create the nested directories
    try logger_inst.log(.info, "Test directory creation");

    // Verify file was created by opening it
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, test_log_path, .{});
    file.close(std.testing.io);
}

test "Logger backward compatibility - default config works" {
    const allocator = std.testing.allocator;

    // Test that old-style config without new fields still works
    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .debug,
        .include_timestamp = true,
        .include_request_id = true,
    });
    defer logger_inst.deinit();

    try std.testing.expectEqual(LogLevel.debug, logger_inst.getMinLevel());
    try logger_inst.log(.info, "Backward compatibility test");
}

// Helper: read entire log file into a buffer. Returns number of bytes read.
fn readEntireFile(io: std.Io, path: []const u8, buf: []u8) !usize {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return try std.Io.File.readStreaming(file, io, &.{buf});
}

test "Logger file rotation keeps recent messages and writes cleanly" {
    const allocator = std.testing.allocator;
    const test_log_path = "./test_logger_rotation_content.log";

    std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .file,
        .max_file_size_bytes = 50, // Small limit; forces multiple rotations
        .enable_auto_rotation = true,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer {
        logger_inst.deinit();
        std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};
    }

    // Each "[INFO] XXX\n" line is 11 bytes. Write 10 to trigger ~3 rotations.
    try logger_inst.log(.info, "AAA");
    try logger_inst.log(.info, "BBB");
    try logger_inst.log(.info, "CCC");
    try logger_inst.log(.info, "DDD");
    try logger_inst.log(.info, "EEE");
    try logger_inst.log(.info, "FFF");
    try logger_inst.log(.info, "GGG");
    try logger_inst.log(.info, "HHH");
    try logger_inst.log(.info, "III");
    try logger_inst.log(.info, "JJJ");

    var buf: [4096]u8 = undefined;
    const n = try readEntireFile(std.testing.io, test_log_path, &buf);
    const content = buf[0..n];

    // File must contain ONLY valid "[INFO] XXX\n" lines — no binary garbage.
    var i: usize = 0;
    var msg_count: usize = 0;
    while (i < n) {
        const prefix = "[INFO] ";
        if (i + prefix.len + 3 + 1 > n) {
            std.debug.print("FAIL: truncated line at offset {d}\n", .{i});
            return error.FileCorrupted;
        }
        if (!std.mem.eql(u8, content[i..i + prefix.len], prefix)) {
            std.debug.print("FAIL: garbage at offset {d} (byte=0x{x:0>2})\n", .{ i, content[i] });
            return error.FileCorrupted;
        }
        i += prefix.len + 3; // skip "[INFO] " and the 3-char message body
        if (content[i] != '\n') {
            std.debug.print("FAIL: missing newline at offset {d} (byte=0x{x:0>2})\n", .{ i, content[i] });
            return error.FileCorrupted;
        }
        i += 1;
        msg_count += 1;
    }

    try std.testing.expect(msg_count > 0);
    try std.testing.expect(msg_count <= 10);

    // The most recent message ("JJJ") must always survive — never rotated away
    // while the process is still running.
    if (std.mem.indexOf(u8, content, "JJJ") == null) {
        std.debug.print("FAIL: most-recent message 'JJJ' missing after rotation\n", .{});
        return error.LastMessageMissing;
    }
}

test "Logger appends to existing file across process restarts" {
    const allocator = std.testing.allocator;
    const test_log_path = "./test_logger_append_restart.log";

    std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};

    // First "process" (Logger instance) — writes FIRST_RUN_MESSAGE, then closes.
    {
        var lgr1 = Logger.init(allocator, std.testing.io, .{
            .min_level = .info,
            .log_file_path = test_log_path,
            .output_mode = .file,
            .include_timestamp = false,
            .include_request_id = false,
        });
        try lgr1.log(.info, "FIRST_RUN_MESSAGE");
        lgr1.deinit();
    }

    // Second "process" — opens the same file (position is 0 after open) and
    // writes SECOND_RUN_MESSAGE. With the bug, this overwrites the first
    // message. With the fix, it appends.
    {
        var lgr2 = Logger.init(allocator, std.testing.io, .{
            .min_level = .info,
            .log_file_path = test_log_path,
            .output_mode = .file,
            .include_timestamp = false,
            .include_request_id = false,
        });
        defer lgr2.deinit();
        try lgr2.log(.info, "SECOND_RUN_MESSAGE");
    }

    var buf: [4096]u8 = undefined;
    const n = try readEntireFile(std.testing.io, test_log_path, &buf);
    const content = buf[0..n];

    // Both messages must be present (the original "FIRST_RUN_MESSAGE" must NOT
    // have been overwritten by the second process's write at position 0).
    if (std.mem.indexOf(u8, content, "FIRST_RUN_MESSAGE") == null) {
        std.debug.print("FAIL: FIRST_RUN_MESSAGE was overwritten by second process (n={d})\n{s}\n", .{ n, content });
        return error.AppendBug;
    }
    if (std.mem.indexOf(u8, content, "SECOND_RUN_MESSAGE") == null) {
        std.debug.print("FAIL: SECOND_RUN_MESSAGE missing from file (n={d})\n{s}\n", .{ n, content });
        return error.SecondMessageMissing;
    }

    // File size must equal the sum of the two formatted lines (no overwrites,
    // no padding, no missing data).
    const expected_size = "[INFO] FIRST_RUN_MESSAGE\n".len + "[INFO] SECOND_RUN_MESSAGE\n".len;
    try std.testing.expectEqual(expected_size, n);

    std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};
}

// ===== Tests merged from memory_leak_test.zig (2026-09-29 flatten) =====
test "Logger init and deinit - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{});
    defer logger_inst.deinit();

    try std.testing.expectEqual(LogLevel.info, logger_inst.getMinLevel());
}

test "Logger custom config - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .debug,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try std.testing.expectEqual(LogLevel.debug, logger_inst.getMinLevel());
}

test "Logger setMinLevel - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{ .min_level = .info });
    defer logger_inst.deinit();

    try std.testing.expectEqual(LogLevel.info, logger_inst.getMinLevel());

    logger_inst.setMinLevel(.debug);
    try std.testing.expectEqual(LogLevel.debug, logger_inst.getMinLevel());
}

test "Logger basic logging - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{ .min_level = .debug });
    defer logger_inst.deinit();

    try logger_inst.log(.debug, "Debug message");
    try logger_inst.log(.info, "Info message");
    try logger_inst.log(.warn, "Warning message");
    try logger_inst.log(.err, "Error message");
}

test "Logger with request ID - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{});
    defer logger_inst.deinit();

    const id = logger_inst.generateAndSetRequestId();
    const id_str = id.toString();
    try std.testing.expect(std.mem.startsWith(u8, id_str, "REQ-"));

    try logger_inst.log(.info, "With request ID");
    try std.testing.expect(logger_inst.getRequestIdString() != null);
}

test "Logger log with context - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{});
    defer logger_inst.deinit();

    try logger_inst.logWithContext(.info, "User action", "user_id=123&action=login");
}

test "Logger JSON formatter - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.initJson(allocator, std.testing.io, .{ .min_level = .info });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "JSON test message");
}

test "Logger color formatter - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.initColor(allocator, std.testing.io, .{ .min_level = .info });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "Color test message");
    try logger_inst.log(.err, "Color error message");
}

test "Logger file output - no memory leak" {
    const allocator = std.testing.allocator;
    const test_log_path = "./test_logger_output.log";

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "Test file output message");
}

test "Logger file rotation - no memory leak" {
    const allocator = std.testing.allocator;
    const test_log_path = "./test_logger_rotation.log";

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .file,
        .max_file_size_bytes = 100,
        .enable_auto_rotation = true,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "First message that is long enough to trigger rotation soon");
    try logger_inst.log(.info, "Second message that should cause rotation");
    try logger_inst.log(.info, "Third message after rotation");
}

test "Logger both output mode - no memory leak" {
    const allocator = std.testing.allocator;
    const test_log_path = "./test_logger_both.log";

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .both,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "Test both output mode");
}

test "Logger directory creation - no memory leak" {
    const allocator = std.testing.allocator;
    const test_dir = "./test_logger_nested_dir";
    const test_log_path = test_dir ++ "/nested/log.txt";

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "Test directory creation");
}

test "Logger appends across restarts - no memory leak" {
    const allocator = std.testing.allocator;
    const test_log_path = "./test_logger_append_leak.log";

    std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};

    // First process
    {
        var lgr1 = Logger.init(allocator, std.testing.io, .{
            .min_level = .info,
            .log_file_path = test_log_path,
            .output_mode = .file,
            .include_timestamp = false,
            .include_request_id = false,
        });
        try lgr1.log(.info, "first batch");
        lgr1.deinit();
    }

    // Second process — appends to the same file
    {
        var lgr2 = Logger.init(allocator, std.testing.io, .{
            .min_level = .info,
            .log_file_path = test_log_path,
            .output_mode = .file,
            .include_timestamp = false,
            .include_request_id = false,
        });
        defer lgr2.deinit();
        try lgr2.log(.info, "second batch");
    }

    std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};
}

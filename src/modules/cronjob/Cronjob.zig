const std = @import("std");
const process_checker = @import("ProcessChecker.zig");
// `databases` is the self-contained sqlite3 package — propagated to
// this module via mod.addImport("databases", ...) in build.zig.
const sqlite = @import("databases").sqlite;

/// Cronjob configuration
pub const CronjobConfig = struct {
    /// Check interval in milliseconds (default: 30 seconds)
    check_interval_ms: u64 = 30_000,
    /// Database path for storing process status
    db_path: []const u8 = ".pabrik/pabrikcore.db",
};

/// Background process record from database
const BackgroundProcess = struct {
    session_id: []const u8,
    pid: i32,
    command: []const u8,
    log_path: []const u8,
    started_at: i64,
    status: []const u8,
};

/// Cronjob scheduler for checking background process status
pub const Cronjob = struct {
    const Self = @This();

    thread: std.Thread,
    running: std.atomic.Value(bool),
    config: CronjobConfig,
    allocator: std.mem.Allocator,
    io: std.Io,

    /// Initialize and spawn the cronjob
    pub fn spawn(allocator: std.mem.Allocator, io: std.Io, config: CronjobConfig) !Self {
        var self = Self{
            .thread = undefined,
            .running = std.atomic.Value(bool).init(true),
            .config = config,
            .allocator = allocator,
            .io = io,
        };
        self.thread = try std.Thread.spawn(.{}, cronjobLoop, .{ &self.running, allocator, io, config });
        return self;
    }

    /// Stop the cronjob gracefully
    pub fn stop(self: *Self) void {
        self.running.store(false, .seq_cst);
        self.thread.join();
    }

    /// Main cronjob loop that periodically checks process status
    fn cronjobLoop(running: *std.atomic.Value(bool), allocator: std.mem.Allocator, io: std.Io, config: CronjobConfig) void {
        std.log.info("Cronjob: Started with interval {d}ms", .{config.check_interval_ms});

        while (running.load(.seq_cst)) {
            // Sleep for the configured interval
            std.Io.sleep(io, .{ .nanoseconds = config.check_interval_ms * std.time.ns_per_ms }, .real) catch {};

            // Check if we should still be running
            if (!running.load(.seq_cst)) break;

            // Check and update process statuses
            checkAndUpdateProcesses(allocator, io, config.db_path) catch |err| {
                std.log.err("Cronjob: Error checking processes: {s}", .{@errorName(err)});
            };
        }

        std.log.info("Cronjob: Stopped", .{});
    }
};

/// Check all running background processes and update their status in the database
fn checkAndUpdateProcesses(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !void {
    // Open database connection
    var db: sqlite.SqliteBackend = .{};
    
    // Convert db_path to null-terminated string
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    
    try db.init(io, db_path_z);
    defer db.deinit();

    // Query all processes with 'running' status
    const query_sql = "SELECT session_id, pid, command, log_path, started_at, status FROM session_background_process WHERE status = 'running'";
    
    var rows = try db.query(allocator, query_sql, &[_][]const u8{});
    defer rows.deinit();

    var updated_count: usize = 0;
    var checked_count: usize = 0;

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        
        checked_count += 1;
        
        // Parse row data
        if (row.values.len < 6) continue;
        
        const session_id = row.values[0];
        const pid_str = row.values[1];
        const command = row.values[2];
        // row.values[3] is log_path - not needed for status check
        // row.values[4] is started_at - not needed for status check
        const current_status = row.values[5];
        
        // Parse PID
        const pid = std.fmt.parseInt(i32, pid_str, 10) catch continue;
        
        // Check current process status
        const process_status = process_checker.checkProcessStatus(pid);
        
        // If status changed from running, update the database
        if (process_status != .running) {
            const new_status = process_checker.statusToString(process_status);
            
            // Update status in database
            const update_sql = "UPDATE session_background_process SET status = ? WHERE session_id = ? AND pid = ?";
            
            const pid_str_update = try std.fmt.allocPrint(allocator, "{d}", .{pid});
            defer allocator.free(pid_str_update);
            
            db.exec(allocator, update_sql, &[_][]const u8{ new_status, session_id, pid_str_update }) catch |err| {
                std.log.err("Cronjob: Failed to update status for PID {d}: {s}", .{ pid, @errorName(err) });
                continue;
            };
            
            updated_count += 1;
            
            std.log.info("Cronjob: Process {d} ({s}) changed from '{s}' to '{s}'", .{
                pid, command, current_status, new_status,
            });
        }
    }

    if (checked_count > 0) {
        std.log.debug("Cronjob: Checked {d} processes, updated {d}", .{ checked_count, updated_count });
    }
}

/// Get the status of a specific background process
pub fn getProcessStatus(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, session_id: []const u8, pid: i32) !?[]const u8 {
    var db: sqlite.SqliteBackend = .{};
    
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    
    try db.init(io, db_path_z);
    defer db.deinit();

    const query_sql = "SELECT status FROM session_background_process WHERE session_id = ? AND pid = ?";
    const pid_str = try std.fmt.allocPrint(allocator, "{d}", .{pid});
    defer allocator.free(pid_str);
    
    const row = try db.queryRow(allocator, query_sql, &[_][]const u8{ session_id, pid_str });
    defer row.deinit(allocator);
    
    if (row.values.len > 0) {
        return try allocator.dupe(u8, row.values[0]);
    }
    
    return null;
}

/// Get all background processes for a session
pub fn getSessionProcesses(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, session_id: []const u8) !std.ArrayList(ProcessRecord) {
    var db: sqlite.SqliteBackend = .{};
    
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    
    try db.init(io, db_path_z);
    defer db.deinit();

    const query_sql = "SELECT pid, command, log_path, started_at, status FROM session_background_process WHERE session_id = ?";
    
    var rows = try db.query(allocator, query_sql, &[_][]const u8{session_id});
    defer rows.deinit();

    var processes = std.ArrayList(ProcessRecord).init(allocator);
    errdefer {
        for (processes.items) |*p| {
            p.deinit(allocator);
        }
        processes.deinit();
    }

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        
        if (row.values.len < 5) continue;
        
        const process = ProcessRecord{
            .session_id = try allocator.dupe(u8, session_id),
            .pid = std.fmt.parseInt(i32, row.values[0], 10) catch continue,
            .command = try allocator.dupe(u8, row.values[1]),
            .log_path = try allocator.dupe(u8, row.values[2]),
            .started_at = std.fmt.parseInt(i64, row.values[3], 10) catch 0,
            .status = try allocator.dupe(u8, row.values[4]),
        };
        
        try processes.append(process);
    }

    return processes;
}

/// Process record structure
pub const ProcessRecord = struct {
    session_id: []const u8,
    pid: i32,
    command: []const u8,
    log_path: []const u8,
    started_at: i64,
    status: []const u8,

    pub fn deinit(self: *ProcessRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.command);
        allocator.free(self.log_path);
        allocator.free(self.status);
    }
};

/// Clean up completed/stopped processes older than a certain time
pub fn cleanupOldProcesses(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, older_than_seconds: i64) !usize {
    var db: sqlite.SqliteBackend = .{};
    
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    
    try db.init(io, db_path_z);
    defer db.deinit();

    // `std.time.timestamp` was removed in Zig 0.16. Use the Io runtime
    // (we have `io: std.Io` in this function's signature) for the
    // portable replacement.
    const now = std.Io.Clock.now(.real, io).toSeconds();
    const cutoff_time = now - older_than_seconds;
    const cutoff_str = try std.fmt.allocPrint(allocator, "{d}", .{cutoff_time});
    defer allocator.free(cutoff_str);

    const delete_sql = "DELETE FROM session_background_process WHERE status != 'running' AND started_at < ?";
    
    try db.exec(allocator, delete_sql, &[_][]const u8{cutoff_str});
    
    // Note: SQLite doesn't return affected rows count easily without additional query
    // For now, we return 0 and the caller can query if needed
    return 0;
}

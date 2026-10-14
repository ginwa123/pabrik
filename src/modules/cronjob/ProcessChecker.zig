const std = @import("std");
const pabrikcore = @import("pabrikcore");
const process_status = @import("helpers").process_status;

/// Process status enumeration
pub const ProcessStatus = enum {
    running,
    completed,
    failed,
    stopped,
    unknown,
};

/// Process information structure
pub const ProcessInfo = struct {
    pid: i32,
    status: ProcessStatus,
    exit_code: ?i32,
};

/// Check if a process is still running by its PID
/// Returns the current status of the process
pub fn checkProcessStatus(pid: i32) ProcessStatus {
    // Uses the cross-platform process_status.isProcessRunning helper
    // (kill(pid, 0) on POSIX, OpenProcess(QUERY_LIMITED) on Windows).
    if (pid <= 0) return .unknown;
    if (process_status.isProcessRunning(pid)) {
        return .running;
    }
    return .completed;
}

/// Check process status and get exit code if available
/// This reads from /proc/PID/stat or uses waitpid if it's a child process
/// For non-child processes, we can only determine if they're running or not
pub fn getProcessInfo(pid: i32) ProcessInfo {
    const status = checkProcessStatus(pid);
    
    return ProcessInfo{
        .pid = pid,
        .status = status,
        .exit_code = null, // Can only get exit code for child processes via waitpid
    };
}

/// Convert ProcessStatus to database string representation
pub fn statusToString(status: ProcessStatus) []const u8 {
    return switch (status) {
        .running => "running",
        .completed => "completed",
        .failed => "failed",
        .stopped => "stopped",
        .unknown => "unknown",
    };
}

/// Parse status string from database to ProcessStatus
pub fn stringToStatus(str: []const u8) ProcessStatus {
    if (std.mem.eql(u8, str, "running")) return .running;
    if (std.mem.eql(u8, str, "completed")) return .completed;
    if (std.mem.eql(u8, str, "failed")) return .failed;
    if (std.mem.eql(u8, str, "stopped")) return .stopped;
    return .unknown;
}

test "process status conversion" {
    // Test status to string
    try std.testing.expectEqualStrings("running", statusToString(.running));
    try std.testing.expectEqualStrings("completed", statusToString(.completed));
    try std.testing.expectEqualStrings("failed", statusToString(.failed));
    try std.testing.expectEqualStrings("stopped", statusToString(.stopped));
    try std.testing.expectEqualStrings("unknown", statusToString(.unknown));
    
    // Test string to status
    try std.testing.expectEqual(ProcessStatus.running, stringToStatus("running"));
    try std.testing.expectEqual(ProcessStatus.completed, stringToStatus("completed"));
    try std.testing.expectEqual(ProcessStatus.failed, stringToStatus("failed"));
    try std.testing.expectEqual(ProcessStatus.stopped, stringToStatus("stopped"));
    try std.testing.expectEqual(ProcessStatus.unknown, stringToStatus("unknown"));
    try std.testing.expectEqual(ProcessStatus.unknown, stringToStatus("invalid"));
}

test "check process status for init" {
    // PID 1 (init/systemd) should always be running on Linux
    const status = checkProcessStatus(1);
    try std.testing.expect(status == .running);
}

test "check process status for non-existent process" {
    // A very high PID is unlikely to exist
    const status = checkProcessStatus(999999);
    try std.testing.expect(status == .completed);
}

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const Adoption = enum { kill_on_close, already, unsupported };

var job: ?windows.HANDLE = null;

pub fn adopt() Adoption {
    if (builtin.os.tag == .windows) {
        return adoptWindows();
    } else {
        return .unsupported;
    }
}

fn adoptWindows() Adoption {
    if (job != null) return .already;

    const handle = CreateJobObjectW(null, null) orelse return .unsupported;
    var info = std.mem.zeroes(ExtendedLimitInformation);
    info.BasicLimitInformation.LimitFlags = KILL_ON_JOB_CLOSE;

    if (SetInformationJobObject(handle, EXTENDED_LIMIT_INFORMATION, &info, @sizeOf(ExtendedLimitInformation)) == .FALSE or
        AssignProcessToJobObject(handle, windows.GetCurrentProcess()) == .FALSE)
    {
        _ = CloseHandle(handle);
        std.log.warn("process job unavailable: a child process will outlive this one", .{});
        return .unsupported;
    }

    job = handle;
    return .kill_on_close;
}

const KILL_ON_JOB_CLOSE: u32 = 0x2000;
const EXTENDED_LIMIT_INFORMATION: u32 = 9;

const BasicLimitInformation = extern struct {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: u32,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: u32,
    Affinity: usize,
    PriorityClass: u32,
    SchedulingClass: u32,
};

const IoCounters = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

const ExtendedLimitInformation = extern struct {
    BasicLimitInformation: BasicLimitInformation,
    IoInfo: IoCounters,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(job_handle: windows.HANDLE, info_class: u32, info: *const anyopaque, len: u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn AssignProcessToJobObject(job_handle: windows.HANDLE, process: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn IsProcessInJob(process: windows.HANDLE, job_handle: ?windows.HANDLE, result: *windows.BOOL) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;

test "adoption is idempotent and reports a job only when the OS granted one" {
    const first = adopt();
    const second = adopt();

    if (first == .kill_on_close) {
        try std.testing.expectEqual(Adoption.already, second);
    } else {
        try std.testing.expectEqual(first, second);
    }

    if (builtin.os.tag == .windows) {
        if (first != .kill_on_close) return;
        var in_job: windows.BOOL = .FALSE;
        if (IsProcessInJob(windows.GetCurrentProcess(), job, &in_job) == .FALSE) return error.IsProcessInJobFailed;
        try std.testing.expectEqual(windows.BOOL.TRUE, in_job);
    } else {
        try std.testing.expectEqual(Adoption.unsupported, first);
    }
}

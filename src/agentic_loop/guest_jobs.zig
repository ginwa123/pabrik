//! A detached command that belongs to a workspace VM: its pid and its log are
//! the GUEST's, so everything about it is asked of the manager that owns that
//! VM. Nothing here runs a host process or opens a host file.

const std = @import("std");
const runtime_mode = @import("../runtime_mode.zig");
const policy = @import("../vmd/policy.zig");
const vmd = @import("../vmd/vmd_client.zig");

pub const Error = error{
    OutOfMemory,
    GuestManagerUnavailable,
    GuestLogUnknown,
    GuestLogUnreadable,
};

/// A detached job as the accounting row records it: the workspace whose VM ran
/// it (the VM is per-workspace, so the workspace id IS the VM id) and the pid
/// inside that VM.
pub const GuestJob = struct {
    vm_id: []const u8,
    guest_pid: u32,
};

pub const Verdict = enum {
    /// The VM that ran the job answered that its pid is still there.
    alive,
    /// The same VM answered that the pid is gone: the command finished.
    exited,
    /// The manager says the VM is not running. Its jobs ended with it.
    vm_stopped,
    /// Nobody can say: the manager is unreachable, or the VM is still coming
    /// up. NOT a death — a job nobody can observe is not a job that ended, and
    /// a manager that restarts adopts the VM it was asked about.
    unknown,
};

/// The manager's answer to a `probe`, as plain data so the decision below is a
/// pure function of it.
pub const Answer = struct {
    alive: bool,
    state: []const u8,
    boot_pid: i64,
};

pub const Reading = struct {
    verdict: Verdict,
    /// The boot that answered. A caller watching one job remembers the first
    /// and passes it back, so a RESTARTED VM cannot report a recycled pid as
    /// the same job.
    boot_pid: i64,
};

/// `VM stopped — job ended` is the visible sentence §10.5 promises, so it is
/// one constant, not three spellings.
pub const vm_stopped_note = "VM stopped - job ended";

/// The states in which the manager is saying, authoritatively, that the VM a
/// job belonged to is gone.
fn vmIsGone(state: []const u8) bool {
    return std.mem.eql(u8, state, "absent") or std.mem.eql(u8, state, "failed");
}

/// The whole liveness decision, as a pure function of the manager's answer.
/// Only a state that means "the VM is gone" may end a job; everything else that
/// is not `ready` is `unknown`.
pub fn classify(answer: Answer, known_boot: ?i64) Verdict {
    if (vmIsGone(answer.state)) return .vm_stopped;
    if (!std.mem.eql(u8, answer.state, "ready")) return .unknown;
    if (answer.boot_pid <= 0) return .unknown;
    if (known_boot) |boot| {
        if (answer.boot_pid != boot) return .vm_stopped;
    }
    return if (answer.alive) .alive else .exited;
}

/// The sentence a completion message carries, or null when there is nothing to
/// explain beyond "the command finished".
pub fn noteFor(verdict: Verdict) ?[]const u8 {
    return switch (verdict) {
        .alive, .exited, .unknown => null,
        .vm_stopped => vm_stopped_note,
    };
}

/// True when the job is over, however it ended. `unknown` is deliberately NOT
/// an ending: the row stays, and the caller keeps watching.
pub fn isFinished(verdict: Verdict) bool {
    return verdict == .exited or verdict == .vm_stopped;
}

/// Ask the manager about one job. A manager that cannot be reached is reported
/// as `vm_stopped`, never as "still running": a job nobody can observe must not
/// be presented as alive.
pub fn probe(allocator: std.mem.Allocator, job: GuestJob, known_boot: ?i64) Reading {
    const socket = runtime_mode.socketPath() orelse return .{ .verdict = .unknown, .boot_pid = 0 };
    var client = vmd.Client.init(allocator, socket);
    const answer = client.probe(job.vm_id, @intCast(job.guest_pid)) catch
        return .{ .verdict = .unknown, .boot_pid = 0 };
    defer answer.deinit(allocator);
    const plain = Answer{ .alive = answer.alive, .state = answer.state, .boot_pid = answer.boot_pid };
    return .{ .verdict = classify(plain, known_boot), .boot_pid = answer.boot_pid };
}

/// Stop the job and everything it forked. The guest's own tree kill does the
/// work; `false` means the signal reached nothing, which is what an already
/// exited job reports.
pub fn stop(allocator: std.mem.Allocator, job: GuestJob) bool {
    const socket = runtime_mode.socketPath() orelse return false;
    var client = vmd.Client.init(allocator, socket);
    client.signal(job.vm_id, @intCast(job.guest_pid), kill_signal) catch return false;
    return true;
}

pub const kill_signal: i64 = 9;

/// What one `process read` of a guest log returns — the guest-side counterpart
/// of `background_process.DeltaRead`, with the same answers.
pub const Delta = struct {
    bytes: []u8,
    next_offset: i64,
    total_bytes: i64,
    more_pending: bool,
    empty: bool,
    missing: bool,

    pub fn free(self: Delta, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

fn emptyDelta(allocator: std.mem.Allocator, offset: i64, missing: bool) !Delta {
    return .{
        .bytes = try allocator.alloc(u8, 0),
        .next_offset = offset,
        .total_bytes = 0,
        .more_pending = false,
        .empty = true,
        .missing = missing,
    };
}

/// The part of a job's log the caller has not been shown yet, read THROUGH the
/// guest: the host has no path to a tenant file.
pub fn readDelta(
    allocator: std.mem.Allocator,
    job: GuestJob,
    log_path: []const u8,
    stored_offset: i64,
    cap_bytes: usize,
) Error!Delta {
    const name = policy.logNameFromPath(log_path) orelse return Error.GuestLogUnknown;
    const socket = runtime_mode.socketPath() orelse return Error.GuestManagerUnavailable;
    var client = vmd.Client.init(allocator, socket);

    var from: i64 = @max(stored_offset, 0);
    var chunk = client.readLog(job.vm_id, name, from, cap_bytes) catch return Error.GuestLogUnreadable;
    if (chunk.missing) {
        chunk.deinit(allocator);
        return emptyDelta(allocator, from, true);
    }
    // A cursor past EOF means the log was recreated under it; restart from the
    // beginning rather than reporting silence for ever.
    if (chunk.bytes.len == 0 and from > 0 and chunk.size < from) {
        chunk.deinit(allocator);
        from = 0;
        chunk = client.readLog(job.vm_id, name, 0, cap_bytes) catch return Error.GuestLogUnreadable;
        if (chunk.missing) {
            chunk.deinit(allocator);
            return emptyDelta(allocator, from, true);
        }
    }

    const bytes = chunk.bytes;
    const size = chunk.size;
    const eof = chunk.eof;
    return .{
        .bytes = bytes,
        .next_offset = from + @as(i64, @intCast(bytes.len)),
        .total_bytes = size,
        .more_pending = !eof,
        .empty = bytes.len == 0,
        .missing = false,
    };
}

const testing = std.testing;

test "classify: a ready VM with the pid there is alive" {
    const answer = Answer{ .alive = true, .state = "ready", .boot_pid = 908967 };
    try testing.expectEqual(Verdict.alive, classify(answer, null));
    try testing.expectEqual(Verdict.alive, classify(answer, 908967));
}

test "classify: the same ready VM reporting no such pid means the job finished" {
    const answer = Answer{ .alive = false, .state = "ready", .boot_pid = 908967 };
    try testing.expectEqual(Verdict.exited, classify(answer, 908967));
}

test "classify: a VM the manager reports gone ended its jobs, whatever the pid says" {
    for ([_][]const u8{ "absent", "failed" }) |state| {
        const answer = Answer{ .alive = true, .state = state, .boot_pid = 908967 };
        try testing.expectEqual(Verdict.vm_stopped, classify(answer, 908967));
    }
}

test "classify: a VM still coming up, or a wedged guest, is unknown — never a death" {
    for ([_][]const u8{ "starting", "unresponsive", "unavailable" }) |state| {
        const answer = Answer{ .alive = false, .state = state, .boot_pid = 908967 };
        try testing.expectEqual(Verdict.unknown, classify(answer, 908967));
    }
}

test "classify: a job from an earlier boot is stopped, even when the pid is reused" {
    // The guest recycles pids quickly (it is PID 1 plus a handful of jobs), so
    // a restarted VM WILL hand out a pid an old row already holds.
    const answer = Answer{ .alive = true, .state = "ready", .boot_pid = 909074 };
    try testing.expectEqual(Verdict.vm_stopped, classify(answer, 908967));
}

test "classify: a ready VM that cannot name its boot cannot vouch for a pid" {
    const answer = Answer{ .alive = true, .state = "ready", .boot_pid = 0 };
    try testing.expectEqual(Verdict.unknown, classify(answer, null));
}

test "noteFor: only a stopped VM needs explaining" {
    try testing.expect(noteFor(.alive) == null);
    try testing.expect(noteFor(.exited) == null);
    try testing.expect(noteFor(.unknown) == null);
    try testing.expectEqualStrings("VM stopped - job ended", noteFor(.vm_stopped).?);
    try testing.expect(std.mem.indexOf(u8, noteFor(.vm_stopped).?, "VM stopped") != null);
}

test "isFinished: a job nobody can observe is not a job that ended" {
    try testing.expect(isFinished(.exited));
    try testing.expect(isFinished(.vm_stopped));
    try testing.expect(!isFinished(.alive));
    try testing.expect(!isFinished(.unknown));
}

test "probe: with no manager reachable the verdict is unknown, not stopped" {
    try testing.expect(runtime_mode.socketPath() == null);
    const job = GuestJob{ .vm_id = "ws_1", .guest_pid = 42 };
    try testing.expectEqual(Verdict.unknown, probe(testing.allocator, job, null).verdict);
}

test "readDelta: a log path this daemon could not have minted is refused" {
    const job = GuestJob{ .vm_id = "ws_1", .guest_pid = 42 };
    try testing.expectError(
        Error.GuestLogUnknown,
        readDelta(testing.allocator, job, "/workspace/tenant.log", 0, 4096),
    );
    try testing.expectError(
        Error.GuestLogUnknown,
        readDelta(testing.allocator, job, "/tmp/pabrik/../etc/shadow", 0, 4096),
    );
}

test "readDelta: with no manager on this process there is no log to read" {
    try testing.expect(runtime_mode.socketPath() == null);
    const job = GuestJob{ .vm_id = "ws_1", .guest_pid = 42 };
    try testing.expectError(
        Error.GuestManagerUnavailable,
        readDelta(testing.allocator, job, "/tmp/pabrik/bg_1.log", 0, 4096),
    );
}

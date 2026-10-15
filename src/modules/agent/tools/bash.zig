// RETIRED: `bash` is no longer a tool name.
const std = @import("std");
const command = @import("command.zig");
const schemas = @import("schemas.zig");

const BashInput = schemas.BashInput;
const BashOutput = schemas.BashOutput;
const AgentTool = schemas.AgentTool;

pub const CommandForbidden = error{
    /// Command contains forbidden patterns that produce unbounded output
    CommandForbidden,
};

/// Returned by `execute_bash` when the caller omits `timeout`.
pub const TimeoutMissing = error{TimeoutMissing};

/// Wall-clock grace period after SIGKILL during which we wait for the
/// kernel to reap the bash process group. (Moved to shell.zig.)
const KILL_GRACE_PERIOD_NS: u64 = 2 * std.time.ns_per_s;

/// Run a bash command. Deprecated shim over `command.execute_command`
/// (which dispatches to `bash -c` off-Windows, `pwsh` on Windows).
pub fn execute_bash(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: BashInput,
) !BashOutput {
    return command.execute_command(allocator, io, input);
}

/// JSON serialiser — re-export from the unified command module under the
/// bash name for ergonomic callers.
pub const bash_result_to_json = command.command_result_to_json;

pub const bash_tool_system_prompt = command.command_tool_system_prompt;

pub const bash_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "bash",
        .description = command.command_tool.function.description,
        .parameters = command.command_tool.function.parameters,
        .system_prompt = bash_tool_system_prompt,
    },
};

// ===== Tests merged from bash_test.zig (2026-09-29 flatten) =====
const builtin = @import("builtin");
const testing = std.testing;

test "bash_tool: foreground echo command runs on host OS" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try execute_bash(allocator, io, .{
        .command = "echo hello-cross-platform",
        .cwd = if (builtin.os.tag == .linux) "/" else "/tmp",
        .max_output = 1024,
        .max_lines = 10,
        .timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "hello-cross-platform") != null);
}

test "bash_tool: large output is truncated by byte count" {
    // Verifies byte-based truncation caps a single huge line of generated
    // code (no newlines) — the failure mode that motivated moving the
    // post-read truncation from line-count to byte-count.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    // Produce 5000 bytes on a SINGLE line (no newlines). max_output=256
    // forces byte truncation; max_lines=999_999 disables line truncation
    // so we are testing the byte path in isolation.
    const result = try execute_bash(allocator, io, .{
        .command = "head -c 5000 < /dev/zero | tr '\\0' 'x'",
        .cwd = "/tmp",
        .max_output = 256,
        .max_lines = 999_999,
        .timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.exit_code == 0);
    try testing.expect(result.truncated == true);
    // The duplicated output must be capped at max_output bytes (not the
    // full 5000-byte single line).
    try testing.expect(result.stdout.len <= 256);
    try testing.expect(result.stdout.len > 0);
}

test "bash_tool: many long lines (head -n 30) byte-truncated to max_output" {
    // Regression test for the user report "bash tool truncated still too
    // long": The agent ran `grep -rn 'invalid_id\|InvalidId\|invalid id'
    // /home/.../src/ \ 2>&1 | head -n 30`.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const fd_count_before = try countOpenFds();

    // Reproduce the user's pattern: 30 lines × ~200 bytes = ~6 KB output.
    const long_line = "xxxxxxxxxx" ** 20;
    const result = try execute_bash(allocator, io, .{
        .command = "yes '" ++ long_line ++ "' | head -n 30",
        .cwd = "/tmp",
        .max_output = 2048,
        // Disable line-cap interference so we are testing the byte path
        // in isolation (mirrors the single-line test above).
        .max_lines = 999_999,
        .timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const fd_count_after = try countOpenFds();

    // 1. truncation flag fired
    try testing.expect(result.truncated == true);
    // 2. output capped at max_output bytes (not the full ~6 KB)
    try testing.expect(result.stdout.len <= 2048);
    try testing.expect(result.stdout.len > 0);
    // 3. stdout_lines reports the TRUE count (>= 30) so the LLM knows
    //    that 30 lines were produced and the visible output is only a slice
    try testing.expect(result.stdout_lines >= 30);
    // stderr empty
    try testing.expect(std.mem.eql(u8, result.stderr, "No errors."));
    // 4. NO FD leak — the byte-truncation path must close reader pipes
    //    even though `head -n 30` produced clean EOF before truncation fired
    const fd_diff: usize = if (fd_count_after > fd_count_before)
        fd_count_after - fd_count_before
    else
        0;
    try testing.expect(fd_diff == 0);
}

test "bash_tool: default max_output is the safety cap, not 1 MiB" {
    // Regression test for the user report "fix bash tool truncated"
    // (2026-08-14): The agent ran `grep -rn
    // 'kanban/copy_spec\|kanban/columns\|kanban_columns_create' \
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    // 1. Schema default is 20 KiB. Verify by parsing a JSON args string
    //    that omits max_output — std.json.parseFromSlice fills it in.
    {
        const args_json =
            \\{"command":"echo hi","cwd":"/tmp","timeout":5}
        ;
        const parsed = try std.json.parseFromSlice(
            BashInput,
            allocator,
            args_json,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();
        try testing.expectEqual(@as(usize, 20 * 1024), parsed.value.max_output.?);
    }

    // 2.
    {
        const fd_count_before = try countOpenFds();

        // 80 KiB per line × 30 lines = ~2.4 MiB raw. head -n 30 caps the
        // LINE count, not the BYTE count.
        const long_line = "A" ** (80 * 1024);
        const result = try execute_bash(allocator, io, .{
            .command = "yes '" ++ long_line ++ "' | head -n 30",
            .cwd = "/tmp",
            // Deliberately omit max_output — the schema default of 20 KiB
            // must take effect. We also raise max_lines so the line cap
            // doesn't fire first (we want the BYTE cap under test).
            .max_lines = 999_999,
            .timeout = 5,
        });
        defer {
            allocator.free(result.command);
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        const fd_count_after = try countOpenFds();

        // 1. The truncation flag MUST fire — 2.4 MiB was definitely
        //    capped at 20 KiB.
        try testing.expect(result.truncated == true);
        // 2. Hard cap at the schema default (20 KiB).
        try testing.expect(result.stdout.len <= 22 * 1024);
        try testing.expect(result.stdout.len > 0);
        // 3. Line count reflects what head -n 30 actually produced, not
        //    what survived truncation. LLM needs this to know the output
        //    was cut.
        try testing.expect(result.stdout_lines >= 30);
        // 4. NO FD leak.
        const fd_diff: usize = if (fd_count_after > fd_count_before)
            fd_count_after - fd_count_before
        else
            0;
        try testing.expect(fd_diff == 0);
    }
}

test "bash_tool: timeout fires on long-running command" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try execute_bash(allocator, io, .{
        .command = "sleep 5",
        .cwd = "/tmp",
        .timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0); // killed by signal
}

test "bash_tool: timeout kills subshell descendants (no pipe-leak hang)" {
    // Regression test for the macOS hang.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    // `( sleep 5 ) | cat` — bash spawns a subshell for `( )` that
    // inherits the pipe FDs to us. The pre-fix code killed bash but
    // not the subshell, so the reader thread waited forever for EOF.
    const result = try execute_bash(allocator, io, .{
        .command = "( sleep 5 ) | cat",
        .cwd = "/tmp",
        .timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: timeout kills descendants across all common subshell shapes" {
    // Each of these exercises a distinct descendant topology that bash spawns
    // before exec'ing into the long-running command.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const cases = [_][]const u8{
        "( sleep 5 )", // bare subshell group
        "sleep 5 | head", // pipe (no subshell, but reader FDs shared)
        "sleep 5 & wait", // backgrounded job + wait
        "{ sleep 5; }", // brace group
        "( ( sleep 5 ) )", // nested subshells
        "bash -c 'sleep 5'", // inner bash inherits our pgid
        // The exact shape the AI hit in production (session-1783866771666):
        // outer `timeout` + nested `bash -c` + subshell-in-pipe.
        "timeout 3 bash -c '( sleep 10 ) | head -n 5'",
    };

    for (cases) |cmd| {
        const result = try execute_bash(allocator, io, .{
            .command = cmd,
            .cwd = "/tmp",
            .timeout = 3,
        });
        defer {
            allocator.free(result.command);
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        // Verify the process tree died correctly: either OUR 3s deadline
        // killed the bash process (result.timeout == true), or — for the one
        // case with an inner `timeout 3 …` — the inner `timeout` command
        const inner_timeout_killed_it = result.exit_code == 124 and !result.timeout;
        try testing.expect(result.timeout == true or inner_timeout_killed_it);
        try testing.expect(result.exit_code != 0);
    }
}

test "bash_tool: missing timeout returns TimeoutMissing" {
    // Runs on ALL platforms (no shell required) — the validation fires before
    // we ever spawn a child.
    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = execute_bash(allocator, io, .{
        .command = "echo should-never-run",
        .cwd = "/tmp",
        // timeout intentionally omitted → null
    });
    try testing.expectError(error.TimeoutMissing, result);
}

test "bash_tool: timeout = 0 returns TimeoutMissing" {
    // Zero is not a meaningful deadline; treat it the same as missing.
    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = execute_bash(allocator, io, .{
        .command = "echo should-never-run",
        .cwd = "/tmp",
        .timeout = 0,
    });
    try testing.expectError(error.TimeoutMissing, result);
}

test "bash_tool: background mode ignores missing timeout" {
    // Background runs detach via nohup and have no deadline enforced by this
    // tool, so omitting timeout must NOT return TimeoutMissing.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = execute_bash(allocator, io, .{
        .command = "true",
        .cwd = "/tmp",
        .background = true,
        // timeout intentionally null
    });
    // Only TimeoutMissing is a contract violation. Any other
    // error means the background path is broken for unrelated reasons;
    // surface it as a test failure rather than masking it.
    if (result) |r| {
        defer allocator.free(r.command);
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
    } else |err| {
        try testing.expect(err != error.TimeoutMissing);
    }
}

// =========================================================================
// Hang-prevention regression tests (2026-07-15 —
// worktree/bash-hang-d-state-fix) These tests cover the scenarios that the

/// Returns the count of open FDs in the TEST PROCESS (not the bash subshell).
/// Linux/macOS only.
fn countOpenFds() !usize {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return 0;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try execute_bash(allocator, io, .{
        // $PPID = bash's parent PID = the test process.
        .command = "ls -1 /proc/$PPID/fd 2>/dev/null | wc -l",
        .cwd = "/tmp",
        .timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.exit_code != 0) return 0;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    return std.fmt.parseInt(usize, trimmed, 10) catch 0;
}

test "bash_tool: returns within bounded wall-clock time even when child hangs" {
    // A bash command that runs forever, forcing the timeout path. The pre-fix
    // code (child.wait(io) blocking forever) would hang this test until the
    // Zig test runner's per-test timeout fires.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try execute_bash(allocator, io, .{
        .command = "sleep 30", // longer than the 1s timeout
        .cwd = "/tmp",
        .timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    // Hard wall-clock upper bound: timeout (1s) + grace (2s) + 2s slack = 5s.
    // Pre-fix code blocks indefinitely on child.wait(io); this test would
    // time out at the test-runner level (typically 60s).
    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: pipe-FD-holding subshell does not hang (force-kill cleanup works)" {
    // Simulates the D-state condition by spawning a subshell that holds the
    // pipe FD open indefinitely via an `exec`-ed command that reads from a
    // never-closing source.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try execute_bash(allocator, io, .{
        .command = "tail -f /dev/null",
        .cwd = "/tmp",
        .timeout = 1,
        .max_output = 256,
        .max_lines = 10,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    // Must return within timeout + grace + 2s slack.
    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: subshell holding pipe FD open after parent death" {
    // The closest reliable simulation of a "D-state-like" hang: bash spawns a
    // subshell that takes the pipe FD via inheritance and runs forever (sleep
    // 60).
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try execute_bash(allocator, io, .{
        // `( sleep 60 )` — bare subshell group, holds pipe FD
        .command = "( sleep 60 )",
        .cwd = "/tmp",
        .timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: complex pipeline with multiple descendants is killed cleanly" {
    // Multi-stage pipeline: `sleep 30 | sleep 30 | sleep 30`. Each `sleep` is
    // a separate process in bash's pgid. The pgid kill must reach all three,
    // and the cleanup must complete within bounded time.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try execute_bash(allocator, io, .{
        .command = "sleep 30 | sleep 30 | sleep 30",
        .cwd = "/tmp",
        .timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: long-running inner command killed by outer bash timeout" {
    // The exact shape from production failure (session-1783866771666):
    // `timeout 30 bash -c 'sleep 60'`.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try execute_bash(allocator, io, .{
        .command = "timeout 30 bash -c 'sleep 60'",
        .cwd = "/tmp",
        .timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.timeout == true or result.exit_code != 0);
}

test "bash_tool: no FD leak after single call" {
    // Verify that execute_bash closes all pipe FDs by the time it returns.
    // The pre-fix code leaked pipe FDs because std.posix.kill didn't touch
    // the Child struct (memory: process-fd-quota-exceed).
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const fd_count_before = try countOpenFds();

    const result = try execute_bash(allocator, io, .{
        .command = "echo hello",
        .cwd = "/tmp",
        .timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const fd_count_after = try countOpenFds();

    // After the call returns, zero extra FDs should remain.
    const diff: usize = if (fd_count_after > fd_count_before)
        fd_count_after - fd_count_before
    else
        0;
    try testing.expect(diff == 0);
}

test "bash_tool: no FD leak after timeout-forced kill" {
    // Same as above but for the timeout/force-kill path. This is the
    // path that pre-fix leaked the most FDs (the kill itself doesn't
    // close pipe FDs).
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const fd_count_before = try countOpenFds();

    const result = try execute_bash(allocator, io, .{
        .command = "sleep 10",
        .cwd = "/tmp",
        .timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const fd_count_after = try countOpenFds();

    const diff: usize = if (fd_count_after > fd_count_before)
        fd_count_after - fd_count_before
    else
        0;
    try testing.expect(diff == 0);
}

test "bash_tool: no FD accumulation across 20 sequential calls" {
    // Long-running agent scenario: the LLM calls bash 20 times in succession.
    // Each call must release all FDs from the previous call.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const fd_count_before = try countOpenFds();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const result = try execute_bash(allocator, io, .{
            .command = if (i % 2 == 0) "echo hello" else "sleep 0.3", // alternates success/timeout
            .cwd = "/tmp",
            .timeout = 1,
        });
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const fd_count_after = try countOpenFds();

    const diff: usize = if (fd_count_after > fd_count_before)
        fd_count_after - fd_count_before
    else
        0;
    // Tightened from `diff <= 2` to `diff == 0` after the foreground
    // pipe-leak fix. Pre-fix: 20 calls × 2 leaked FDs/call = 40 FDs.
    try testing.expect(diff == 0);
}

test "bash_tool: 100 sequential calls do not grow the open-fd count" {
    // Stress regression test for the foreground pipe-leak fix. Calls
    // execute_bash 100 times (the long-running-agent scenario) and asserts
    // zero FD growth.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const fd_count_before = try countOpenFds();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const result = try execute_bash(allocator, io, .{
            .command = "echo hello",
            .cwd = "/tmp",
            .timeout = 5,
        });
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const fd_count_after = try countOpenFds();

    const diff: usize = if (fd_count_after > fd_count_before)
        fd_count_after - fd_count_before
    else
        0;
    try testing.expect(diff == 0);
}

test "bash_tool: no memory leak after single call" {
    // testing.allocator will report leaks on scope exit if anything
    // was allocated without being freed.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try execute_bash(allocator, io, .{
        .command = "echo hello",
        .cwd = "/tmp",
        .timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // The defer above frees the output. If execute_bash allocated
    // anything else internally that's leaked, testing.allocator
    // will report it when the test scope ends.
}

test "bash_tool: no memory leak after timeout-forced kill" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try execute_bash(allocator, io, .{
        .command = "sleep 10",
        .cwd = "/tmp",
        .timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // testing.allocator will report any leak on scope exit.
}

test "bash_tool: output is captured even when command is killed by timeout" {
    // The fix must NOT lose the partial output that bash wrote before
    // being killed. The reader threads must flush whatever was buffered
    // before the kill.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try execute_bash(allocator, io, .{
        // Write a marker before sleeping — that marker must be in stdout
        .command = "echo 'PARTIAL-OUTPUT-BEFORE-TIMEOUT'; sleep 10",
        .cwd = "/tmp",
        .timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.timeout == true);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "PARTIAL-OUTPUT-BEFORE-TIMEOUT") != null);
}

test "bash_tool: background mode returns quickly even for hanging command" {
    // Background mode detaches via nohup. The function returns the PID and
    // log path. It must NOT wait for the detached command.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try execute_bash(allocator, io, .{
        .command = "sleep 60", // hangs forever, but detached
        .cwd = "/tmp",
        .background = true,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    // Background spawn should complete in <2s (just spawn + read PID + log path).
    try testing.expect(elapsed_ms < 2000);
    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "PID:") != null);
}

test "bash_tool: stdin_data command completes cleanly" {
    // A command that reads stdin and exits.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const fd_count_before = try countOpenFds();

    const result = try execute_bash(allocator, io, .{
        .command = "cat",
        .cwd = "/tmp",
        .timeout = 5,
        .stdin_data = "hello via stdin\n",
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.exit_code == 0);
    try testing.expect(result.stdout.len > 0);

    const fd_count_after = try countOpenFds();
    const diff: usize = if (fd_count_after > fd_count_before)
        fd_count_after - fd_count_before
    else
        0;
    // Tightened from `diff <= 2` to `diff == 0` after the foreground
    // pipe-leak fix.
    try testing.expect(diff == 0);
}

test "bash_tool: command that produces lots of output is truncated without hanging" {
    // Verifies the truncation logic works under timeout pressure.
    // The producer (`yes`) would produce infinite output; the reader
    // thread must truncate at max_output without hanging.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try execute_bash(allocator, io, .{
        .command = "yes hello | head -n 100000",
        .cwd = "/tmp",
        .timeout = 3,
        .max_output = 1024, // tight byte limit to force truncation
        .max_lines = 50, // tight line limit
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.truncated == true);
    try testing.expect(result.stdout.len <= 1024);
}

test "bash_tool: very short timeout (1 second) does not deadlock" {
    // The shortest reasonable timeout. Verifies that even with
    // minimal grace period, the function returns cleanly.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try execute_bash(allocator, io, .{
        .command = "sleep 5",
        .cwd = "/tmp",
        .timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: command exits normally before timeout fires" {
    // The "happy path" — make sure the fix didn't break the normal case.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try execute_bash(allocator, io, .{
        .command = "echo happy-path",
        .cwd = "/tmp",
        .timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    try testing.expect(elapsed_ms < 2000);
    try testing.expect(result.timeout == false);
    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "happy-path") != null);
}

test "bash_tool: nested bash -c with stuck sleep is killed cleanly" {
    // `bash -c 'sleep 60'` — inner bash. The outer pgid kill should
    // reach the inner bash too. Pre-fix code's `child.wait(io)` could
    // hang here because the inner bash was waiting for sleep.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try execute_bash(allocator, io, .{
        .command = "bash -c 'sleep 60'",
        .cwd = "/tmp",
        .timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: exit code is set even when force-killed" {
    // After a forced kill, exit_code must be set to a non-zero value
    // (typically negative for signal-killed). It must NOT be 0.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try execute_bash(allocator, io, .{
        .command = "sleep 10",
        .cwd = "/tmp",
        .timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.timeout == true);
    // exit_code is -signal_number for SIGKILL on POSIX, or -1 for unknown.
    try testing.expect(result.exit_code != 0);
}

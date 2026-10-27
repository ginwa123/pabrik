// zig — unified shell-exec tool, merged from bash.zig + pwsh.zig.
const std = @import("std");
const builtin = @import("builtin");
const shell = @import("shell.zig");
const schemas = @import("schemas.zig");

const AgentTool = schemas.AgentTool;

/// Canonical input type — alias so the wire schema is identical to the
/// old `bash` / `pwsh` tools.
pub const CommandInput = shell.ShellInput;

/// Canonical output type — alias so the JSON payload is identical to the
/// old `bash` / `pwsh` tools.
pub const CommandOutput = shell.ShellOutput;

/// argv-prefix for the POSIX shell: `bash -c <command>`.
pub const COMMAND_BASH_PREFIX: []const []const u8 = &.{ "bash", "-c" };

/// argv-prefix for PowerShell Core: `pwsh -NoProfile -NonInteractive -Command
/// <script>`. `-NoProfile` skips profile loading (faster, no startup hooks).
pub const COMMAND_PWSH_PREFIX: []const []const u8 = &.{
    "pwsh", "-NoProfile", "-NonInteractive", "-Command",
};

/// argv-prefix for the Windows fallback shell: `cmd.exe /c <command>`.
pub const COMMAND_CMD_PREFIX: []const []const u8 = &.{
    "cmd.exe", "/c",
};

/// Run a shell command on the host-appropriate shell: `pwsh` on Windows (with
/// a `cmd.exe` retry when pwsh is missing), `bash` everywhere else.
pub fn execute_command(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: CommandInput,
) !CommandOutput {
    return execute_command_with(allocator, io, input, null);
}

/// `execute_command` with the execution substrate made explicit. `executor`
/// replaces the host shell spawn; null keeps the host path byte-identical.
pub fn execute_command_with(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: CommandInput,
    executor: ?shell.Executor,
) !CommandOutput {
    if (builtin.os.tag == .windows) {
        // Phase 1 (cmd fallback) is foreground-only: background keeps the
        // historical pwsh path (spawn_background's nohup idiom + the D8
        // Start-Process TODO in shell.zig).
        if (input.background) {
            return shell.execute_shell_with(allocator, io, COMMAND_PWSH_PREFIX, input, executor);
        }
        const pwsh_out = shell.execute_shell_with(allocator, io, COMMAND_PWSH_PREFIX, input, executor) catch |err| {
            // Retry ONLY on a missing binary. Any other error (timeout,
            // forbidden, spawn permission, …) propagates unchanged so real
            // failures are never masked as "try the other shell".
            if (err != error.FileNotFound) return err;
            return try shell.execute_shell_with(allocator, io, COMMAND_CMD_PREFIX, input, executor);
        };
        return pwsh_out;
    } else {
        return shell.execute_shell_with(allocator, io, COMMAND_BASH_PREFIX, input, executor);
    }
}

/// JSON payload formatter — same 8-field shape as the old
/// `bash_result_to_string` / `pwsh_result_to_string`.
pub const command_result_to_json = shell.result_to_json;

pub const command_tool_system_prompt =
    \\## Command Tool — Behavior
    \\Host picks the shell: `bash` on Linux/macOS, `pwsh` on Windows (silent `cmd.exe /c` fallback when pwsh is missing).
    \\Do NOT prefix commands with a shell `timeout` utility — `timeout` (required, max 600) is the only deadline. Bound output with `| head -n <N>` / `| tail -n <N>` (bash) or `| Select-Object -First <N>` (pwsh).
    \\Pick `mode` deliberately — it is the difference between blocking your turn and not: `foreground` (default, returns the output inline), `background` (detaches AND queues you a message when it exits — use it for a long build, a test run, a migration), `background_persistence` (detaches and stays SILENT — use it for a server, an API, a dev server or a watcher, then read and stop it with `process`). A long-running process is ONE `background_persistence` call plus one `foreground` call per request; never a hand-rolled detach inside `command` (`&`, `nohup`, `setsid`, `disown`, `Start-Process`, `-RedirectStandardOutput`) and never start + request + query bundled into a single call — `process` cannot see such a process, and a `foreground` call would block until the deadline kills the server. Under cmd.exe: no `| head -n`, use cmd syntax (dir / where / type / %VAR% / && / double-quoted URLs).
    \\Set `is_stop=true` to end YOUR turn after this call: the command still runs and any `background=true` process keeps running, but the loop returns to the user instead of calling the model again. Put your final answer in the message content — a `tool_calls` turn normally carries none, so without it the turn ends on a bare tool card.
    \\
;

pub const command_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "command",
        .description =
        \\Run one shell command; return stdout, stderr, exit_code, truncated, timeout.
        \\Host picks the shell: `bash -c` on Linux/macOS, `pwsh -NoProfile -NonInteractive -Command` on Windows (silent `cmd.exe /c` fallback when pwsh is missing; background=true fails there instead of detaching).
        \\
        \\## Rules (enforced in code — violations return errors)
        \\- `timeout`: REQUIRED, the ONLY deadline. No shell `timeout` prefix — do not add one.
        \\- Bound output: `| head -n <N>` / `| tail -n <N>` (bash) or `| Select-Object -First <N>` (pwsh); under cmd.exe use max_lines / findstr / more.
        \\- Prefer `search` / `read_file` / `glob` over shell rg/grep/find; inside a shell use `rg` / `fd` / `tree`.
        \\- No unbounded output, no destructive commands. Long work goes in `mode` (see below).
        \\- Web fetch: use the `agent-browser` CLI.
        \\- End your turn with `is_stop=true`; kills nothing.
        \\
        \\## Servers and other long-running processes
        \\Anything that does not exit on its own (API, dev server, worker): ONE `mode="background_persistence"` call with the plain start command (`go run ./cmd/api`) — it returns a PID + log path and frees your turn — then ONE `foreground` call per thing you do to it (`curl` the endpoint, the query, reading the log), and `process` to read or stop it.
        \\Never detach by hand in `command` (`&`, `nohup`, `setsid`, `disown`, `Start-Process`, `-RedirectStandardOutput`): `process` cannot see such a process, so you can neither read nor stop it, and `foreground` kills it at the deadline anyway. Never bundle start + request + query into one call — when it fails you cannot tell which step broke.
        \\
        \\## Platform notes
        \\Install pwsh via `winget install Microsoft.PowerShell` (Windows) or brew/snap (macOS/Linux); without it, spawning a command fails with `FileNotFound`. Under cmd.exe: double-quote URLs, `%NAME%` env vars, `&&` chaining, `dir` / `where` / `type`.
        \\
        \\## Lenient types
        \\Numbers (`timeout`, `max_output`, `max_lines`) accept JSON numbers or numeric strings; a stray trailing `</fieldname>` is auto-stripped. Booleans accept a JSON bool or `"true"` / `"false"`. A real mismatch returns an `invalid field` error naming the field.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "command",
                    .type = "string",
                    .description =
                    \\Command to execute. Do NOT prefix it with a shell `timeout N` — the `timeout` field is the deadline.
                    ,
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description =
                    \\REQUIRED. Absolute working directory — the directory the command runs IN, e.g. "/home/you/project".
                    \\Omitting it returns `MandatoryCwdMissing`; a relative one returns `CwdNotAbsolute`. Without one the shell inherits the SERVER's directory and the command silently acts on the wrong tree.
                    ,
                },
                .{
                    .name = "timeout",
                    .type = "number",
                    .description =
                    \\REQUIRED. Wall-clock seconds before the process is killed (SIGKILL / TerminateProcess). 1–600 only: omitted or 0 returns `TimeoutMissing`, above 600 returns `TimeoutTooLarge`.
                    \\This is a FIELD, not a command prefix: the shell `timeout` utility inside `command` does nothing useful — it is not the deadline this field is, and the field already does the job.
                    \\Seconds for `ls` / `cat` / `git status`; minutes for a build or a test suite. A foreground command holds your turn exactly that long — use a detached `mode` for longer work.
                    ,
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description =
                    \\Maximum stdout+stderr bytes per stream. Default: 20480 (20 KiB). Output over the limit is truncated at read-time to protect the LLM context window. Raise it for `cat` of a large file or `head -n 1` of a minified one — a single line can exceed 20 KiB.
                    ,
                },
                .{
                    .name = "stdin_data",
                    .type = "string",
                    .description = "Optional stdin input for the ",
                },
                .{
                    .name = "mode",
                    .type = "string",
                    .description =
                    \\How this command relates to your turn. Default: "foreground".
                    \\- "foreground": runs now, output inline; REQUIRES timeout (1-600). Short work only (ls, cat, git status, rg, a quick build) — a server here is killed at the deadline.
                    \\- "background": detaches and QUEUES you a message when it exits. Bounded work you must be told about: a long build, a test run, a migration. A server reports only its death.
                    \\- "background_persistence": detaches and stays SILENT. A server, API, dev server or watcher — read it and stop it with `process`. A bounded job here is never reported as finished.
                    \\Both detached modes ignore `timeout` and return a PID + log path; they are the ONLY correct way to start a server — never hand-roll a detach (`&`, `nohup`, `Start-Process`).
                    ,
                },
                .{
                    .name = "background",
                    .type = "boolean",
                    .description =
                    \\LEGACY alias for mode="background" (true) / mode="foreground" (false). Prefer `mode`, which also expresses "detach and stay silent". Passing it with mode="foreground" is rejected.
                    ,
                },
                .{
                    .name = "is_stop",
                    .type = "boolean",
                    .description =
                    \\End YOUR turn after this call. This is not a cancel: nothing is killed, and a `background=true` process from the same call keeps running.
                    \\Put your final answer in the message content of this same message — a `tool_calls` turn carries no prose, so the turn would otherwise end on a bare tool card.
                    \\Set it for "start the dev server, then stop" or when the work is finished; leave it false to keep going.
                    ,
                },
                .{
                    .name = "max_lines",
                    .type = "number",
                    .description = "Maximum lines captured from stdout/stderr. Default: 1000; beyond it output is truncated and stdout_lines/stderr_lines give the true total.",
                },
                .{
                    .name = "do_encoding",
                    .type = "boolean",
                    .description =
                    \\Encode URLs in double quotes by converting them to single quotes — for curl/wget URLs containing ? and &.
                    \\Example: curl -sI "https://host/p?q=1&s=2" becomes curl -sI 'https://host/p?q=1&s=2'.
                    \\Skipped under the cmd.exe fallback (single quotes are literal).
                    ,
                },
            },
            .required = &.{ "command", "cwd", "timeout" },
        },
        .system_prompt = command_tool_system_prompt,
    },
};

// ============================================================================
// Inline tests — schema shape (existing bash/pwsh tests are NOT duplicated
// here; bash_test.zig + the pwsh.zig inline tests keep covering the shim

const testing = std.testing;

test "command_tool schema: no `timeout` prefix rule in the LLM-facing text" {
    // The tool description and system prompt used to instruct the model to
    // write `timeout <seconds> <cmd>`.
    const desc = command_tool.function.description;
    const prompt = command_tool_system_prompt;

    const banned = [_][]const u8{
        "start with `timeout",
        "Every command MUST start with `timeout",
        "timeout <seconds>",
        "- start with `timeout",
        "timeout 10 ",
    };
    for ([_][]const u8{ desc, prompt }) |text| {
        for (banned) |needle| {
            if (std.mem.indexOf(u8, text, needle) != null) {
                std.debug.print(
                    "\n!! command tool text still tells the model to use a `timeout` prefix: {s}\n",
                    .{needle},
                );
                return error.TimeoutPrefixRuleStillPresent;
            }
        }
    }
    // ...and the replacement guidance is actually there in both places: the
    // Command Rules bullet in the description, and the opening line of the
    // system prompt.
    try testing.expect(std.mem.indexOf(u8, desc, "do not add one") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Do NOT prefix commands") != null);
    // The `command` param's own examples must not open with a timeout either.
    for (command_tool.function.parameters.properties) |prop| {
        if (!std.mem.eql(u8, prop.name, "command")) continue;
        try testing.expect(std.mem.indexOf(u8, prop.description, "timeout 10 ") == null);
        try testing.expect(std.mem.indexOf(u8, prop.description, "Do NOT prefix") != null);
    }
}

test "command_tool schema: exactly ONE deadline param, and it is required" {
    // This test used to read "a `timeout` param must NOT exist" — it was the
    // guard against the tool growing a second way to bound a
    const params = command_tool.function.parameters;

    var deadline_count: usize = 0;
    var found: []const u8 = "";
    for (params.properties) |prop| {
        if (std.mem.indexOf(u8, prop.name, "timeout") != null) {
            deadline_count += 1;
            found = prop.name;
        }
    }
    if (deadline_count != 1) {
        std.debug.print(
            "\n!! command tool has {d} timeout-ish params (last: {s}) — exactly one deadline is allowed\n",
            .{ deadline_count, found },
        );
        return error.StrayTimeoutParam;
    }
    try testing.expectEqualStrings("timeout", found);

    var required_mt = false;
    for (params.required) |name| {
        if (std.mem.eql(u8, name, "timeout")) required_mt = true;
    }
    try testing.expect(required_mt);
}

test "command_tool schema: the field named `timeout` is NOT the shell timeout utility" {
    // The rename put the model's word for the FIELD and its word for the
    // banned UTILITY on the same string.
    var timeout_desc: ?[]const u8 = null;
    for (command_tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "timeout")) timeout_desc = prop.description;
    }
    try testing.expect(timeout_desc != null);
    try testing.expect(std.mem.indexOf(u8, timeout_desc.?, "FIELD, not a command prefix") != null);
    try testing.expect(std.mem.indexOf(u8, timeout_desc.?, "shell `timeout` utility") != null);

    // ...and the tool-level prose still names the utility as forbidden, so a
    // model that reads only the Rules block sees it too.
    try testing.expect(std.mem.indexOf(u8, command_tool.function.description, "shell `timeout`") != null);

    // ...and the utility is still not RECOMMENDED anywhere, which is what the
    // banned-substring test above enforces.
    try testing.expect(std.mem.indexOf(u8, command_tool_system_prompt, "Do NOT prefix commands") != null);
}

test "execute_command still enforces timeout at runtime" {
    // The prompt-text change is cosmetic; the CODE enforcement is the
    // contract.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    try testing.expectError(
        error.TimeoutMissing,
        execute_command(testing.allocator, std.testing.io, .{
            .command = "echo hi",
            .cwd = "/tmp",
            .timeout = null,
        }),
    );
    try testing.expectError(
        error.TimeoutMissing,
        execute_command(testing.allocator, std.testing.io, .{
            .command = "echo hi",
            .cwd = "/tmp",
            .timeout = 0,
        }),
    );
}

test "command_tool schema: tool name is 'command'" {
    try testing.expectEqualStrings("command", command_tool.function.name);
}

test "command_tool schema: required fields are (command, cwd, timeout)" {
    const params = command_tool.function.parameters;
    try testing.expectEqualStrings("object", params.type);
    try testing.expectEqual(@as(usize, 3), params.required.len);

    var found_command = false;
    var found_cwd = false;
    var found_mt = false;
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "command")) found_command = true;
        if (std.mem.eql(u8, prop.name, "cwd")) found_cwd = true;
        if (std.mem.eql(u8, prop.name, "timeout")) found_mt = true;
    }
    try testing.expect(found_command);
    try testing.expect(found_cwd);
    try testing.expect(found_mt);
}

test "command_tool schema: is_stop is optional boolean and states its whole contract" {
    // `is_stop` is the model's own "I am done" signal: it ends the TURN, it
    // kills NOTHING, and a `background=true` process in the same call keeps
    // running.
    const params = command_tool.function.parameters;

    var is_stop: ?@TypeOf(params.properties[0]) = null;
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "is_stop")) is_stop = prop;
    }
    try testing.expect(is_stop != null);
    try testing.expectEqualStrings("boolean", is_stop.?.type);

    for (params.required) |name| {
        try testing.expect(!std.mem.eql(u8, name, "is_stop"));
    }

    const d = is_stop.?.description;
    // Ends the turn (not the process)…
    try testing.expect(std.mem.indexOf(u8, d, "End YOUR turn") != null);
    // …is not a cancel…
    try testing.expect(std.mem.indexOf(u8, d, "not a cancel") != null);
    // …leaves a background process alone…
    try testing.expect(std.mem.indexOf(u8, d, "keeps running") != null);
    // …and the final answer has to come from the message body, because a
    // `tool_calls` turn carries no prose. Without this the turn ends on a
    // bare tool card and the user reads silence.
    try testing.expect(std.mem.indexOf(u8, d, "final answer in the message content") != null);
}

test "command_tool schema: the is_stop rule reaches the description AND the system prompt" {
    // The description is what the provider embeds in the tool schema; the
    // system prompt is the prose reminder.
    try testing.expect(std.mem.indexOf(u8, command_tool.function.description, "is_stop=true") != null);
    try testing.expect(std.mem.indexOf(u8, command_tool_system_prompt, "is_stop=true") != null);
}

test "CommandInput is the same type as ShellInput (alias liveness check)" {
    const command_input = CommandInput{ .command = "" };
    const shell_input = shell.ShellInput{ .command = "" };
    try testing.expectEqualStrings(@typeName(@TypeOf(command_input)), @typeName(@TypeOf(shell_input)));

    const json =
        \\{"command":"x","cwd":"/tmp","timeout":3,"max_output":10,
        \\"stdin_data":"y","background":true,"max_lines":20,"do_encoding":true}
    ;
    const a = try std.json.parseFromSlice(@TypeOf(command_input), testing.allocator, json, .{});
    defer a.deinit();
    const b = try std.json.parseFromSlice(@TypeOf(shell_input), testing.allocator, json, .{});
    defer b.deinit();
    try testing.expectEqualStrings(a.value.command, b.value.command);
    try testing.expect(a.value.timeout.? == b.value.timeout.?);
}

test "command argv prefixes have the expected shape" {
    try testing.expectEqual(@as(usize, 2), COMMAND_BASH_PREFIX.len);
    try testing.expectEqualStrings("bash", COMMAND_BASH_PREFIX[0]);
    try testing.expectEqualStrings("-c", COMMAND_BASH_PREFIX[1]);
    try testing.expectEqual(@as(usize, 4), COMMAND_PWSH_PREFIX.len);
    try testing.expectEqualStrings("pwsh", COMMAND_PWSH_PREFIX[0]);
    try testing.expectEqualStrings("-NoProfile", COMMAND_PWSH_PREFIX[1]);
    try testing.expectEqualStrings("-NonInteractive", COMMAND_PWSH_PREFIX[2]);
    try testing.expectEqualStrings("-Command", COMMAND_PWSH_PREFIX[3]);
    // T1 RED (cmd.exe fallback): the Windows branch retries with cmd when
    // pwsh is missing — the prefix const must exist with this exact shape.
    try testing.expectEqual(@as(usize, 2), COMMAND_CMD_PREFIX.len);
    try testing.expectEqualStrings("cmd.exe", COMMAND_CMD_PREFIX[0]);
    try testing.expectEqualStrings("/c", COMMAND_CMD_PREFIX[1]);
}

test "execute_command runs on the host shell (bash off-Windows)" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const out = try execute_command(testing.allocator, std.testing.io, .{
        .command = "echo hello-command",
        .cwd = "/tmp",
        .timeout = 5,
    });
    defer {
        testing.allocator.free(out.command);
        testing.allocator.free(out.stdout);
        testing.allocator.free(out.stderr);
    }
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "hello-command") != null);
}

// T1 RED (cmd.exe fallback): availability probe.

/// Probe whether `cmd.exe` is on $PATH. Windows-only: returns false
/// everywhere else so Linux CI passes. Mirrors pwsh.zig's pwsh_available().
fn cmd_available() bool {
    if (builtin.os.tag != .windows) return false;
    var child = std.process.spawn(std.testing.io, .{
        .argv = &.{ "cmd.exe", "/c", "exit 0" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return false;
    defer child.kill(std.testing.io);

    const term = child.wait(std.testing.io) catch return false;
    return term == .exited;
}

test "cmd_available probe does not crash" {
    // Runs regardless of platform — exercises the boolean probe. On
    // non-Windows it returns false; on a Windows box with cmd.exe it
    // returns true. Either way the assertion is "doesn't crash".
    const available = cmd_available();
    _ = available;
    try testing.expect(true);
}

// Exec adapter — merged from `zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const exec_builtin = @import("builtin");
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const tool_models = pabrikcore.tool_models;
const command_tool_mod = pabrikcore.command_tool;
const background_process = @import("../../../agentic_loop/background_process.zig");
const background_process_events = @import("../../../agentic_loop/background_process_events.zig");
const background_watcher = @import("../../../agentic_loop/background_watcher.zig");
const wrapToolOutput = tools.wrapToolOutput;
const bash_args = @import("exec_bash_args.zig");
const vm_runtime = @import("../../../agentic_loop/vm_runtime.zig");
const error_explain = @import("tools_error_explain.zig");
/// What `runWithContext` hands back: the LLM-facing payload, plus the
/// loop-control request parsed out of the same arguments.
pub const RunResult = struct {
    payload: []const u8,
    /// `is_stop` from the arguments. False on the parse-failure path: the
    /// field could not be read, so nothing may be assumed about it.
    stop_loop: bool = false,
};

/// Merged exec body for the unified `command` tool (Phase A+B of the unify
/// plan — shared logic moved here from `zig` /
/// `zig`, which are now thin shims over this module).
pub fn runWithContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    tool_call: agent.ToolCall,
    db: ?*database.Db,
    session_id: ?[]const u8,
) !RunResult {
    const input = switch (bash_args.parseShellArgs(allocator, tool_call.function.arguments)) {
        .success => |in| in,
        .failure => |info| {
            // Both the rendered message and the `got` slice it interpolates
            // are allocated by the parser; free them once the envelope has
            // copied the text. The exec_testing allocator catches this path.
            const err_msg = try bash_args.formatInvalidField(allocator, info);
            defer allocator.free(err_msg);
            defer allocator.free(info.got);
            const output = try wrapToolOutput(allocator, "command", tool_call.function.arguments, false, err_msg, "");
            // `.stop_loop` stays false: the arguments did not parse, so
            // `is_stop` was never read. Ending a turn on a malformed call
            // would hide the error the envelope exists to report.
            return .{ .payload = output };
        },
    };
    // parseShellArgs dups every string field it produces (command / cwd /
    // stdin_data) so the caller can hold the slice past the JSON value's
    // lifetime. Free them once execute_command returns.
    defer {
        allocator.free(input.command);
        if (input.cwd) |c| allocator.free(c);
        if (input.stdin_data) |s| allocator.free(s);
    }

    // The RESOLVED mode: `background=true` and `mode="background"` are the same
    // thing by the time they get here (the parser folds them).
    const mode = pabrikcore.shell_tool.resolvedMode(input);

    // The substrate decision: under `--saas` the executor runs this command in
    // the session's workspace VM, and no host shell is ever spawned for it.
    var guest = vm_runtime.GuestContext{ .db = db, .session_id = session_id };
    const executor = vm_runtime.executorFor(&guest);
    const command_output = try command_tool_mod.execute_command_with(
        allocator,
        io,
        input,
        executor,
    );
    // A detached command that ran in a guest leaves a GUEST pid behind, and the
    // accounting row has to say which VM it belongs to.
    const ran_in_guest = executor != null;

    // Record a detached process so it can be listed, read, and stopped later.
    // `kind` decides whether it is ever NOTIFIED about — see migration 107.
    if (mode.isDetached() and db != null and session_id != null) {
        const db_ptr = db.?;
        const sess_id = session_id.?;

        // The VM is per-workspace, so its identity is the workspace id the
        // executor resolved. Null means the row cannot be written honestly, so
        // nothing is recorded.
        const vm_id: ?[]u8 = if (ran_in_guest)
            try vm_runtime.workspaceIdFor(allocator, db_ptr, sess_id)
        else
            null;
        defer if (vm_id) |id| allocator.free(id);
        const accountable = !ran_in_guest or vm_id != null;

        // Parse PID from command output (format: "PID: {pid}\nLog: {path}")
        const stdout = command_output.stdout;
        if (stdout.len > 5) {
            // Skip "PID: " prefix
            const pid_start = 5;
            var pid_end: usize = 4;
            while (pid_end < stdout.len and stdout[pid_end] != '\n') : (pid_end += 1) {}

            if (pid_end > pid_start) {
                const pid_str = stdout[pid_start..pid_end];
                const pid = std.fmt.parseInt(u32, pid_str, 10) catch 0;

                if (pid > 0) {
                    // Extract log path from "Log: {path}" part
                    var log_start: usize = 0;
                    while (log_start < stdout.len and stdout[log_start] != '\n') : (log_start += 1) {}
                    log_start += 1; // skip newline

                    // Find "Log: " prefix
                    var log_path_start = log_start;
                    while (log_path_start < stdout.len and log_path_start < log_start + 5) : (log_path_start += 1) {}

                    if (log_path_start < stdout.len) {
                        const log_path = stdout[log_path_start..];

                        // Save to database
                        const ts = std.Io.Clock.now(.real, io);
                        const started_at: i64 = ts.toSeconds();
                        const home: background_process.JobHome = if (vm_id) |id|
                            background_process.JobHome.guest(id, pid)
                        else
                            background_process.JobHome.host();
                        if (accountable) {
                            background_process.save(db_ptr, allocator, sess_id, pid, input.command, log_path, started_at, mode.kindFor(), home) catch {
                                // Log error but don't fail the tool execution
                            };
                        }
                        // Immediate watcher: poll the PID every 2s and queue
                        // the completion the moment it exits (no cron wait).
                        if (pabrikcore.getSingleton() catch null) |di| {
                            background_process_events.emitCreated(allocator, di.event_bus, sess_id, pid, input.command);
                            // The two detached modes differ in ONE
                            // obligation: whether the agent is told when the
                            // process exits.
                            const notify = mode == .background;
                            if (vm_id) |id| {
                                background_watcher.spawnGuestWatcher(di, sess_id, .{
                                    .vm_id = id,
                                    .guest_pid = pid,
                                }, input.command, log_path, notify);
                            } else if (notify) {
                                background_watcher.spawnCompletionWatcher(di, sess_id, pid, input.command, log_path);
                            } else {
                                background_watcher.spawnServiceReaper(di, sess_id, pid, input.command, log_path);
                            }
                        }
                    }
                }
            }
        }
    }

    const res_command = try command_tool_mod.command_result_to_json(allocator, command_output);

    return .{ .payload = res_command, .stop_loop = input.is_stop };
}

pub fn execCommand(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Catch ANY remaining error from the run path (e.g. from
    // `execute_command` itself — fork failures, permission errors, etc.) and
    // wrap it in the standard tool-error envelope, matching execReadFile /
    const inner = runWithContext(ctx.allocator, ctx.io, tc, ctx.db, ctx.session_id) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "command", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    // `runWithContext` returns an ALREADY-WRAPPED envelope on its
    // parse-failure path (it has no other way to report a structured field
    // error), and a bare payload on the success path.
    if (looksWrapped(inner.payload)) {
        return ToolExecResult{ .output = inner.payload, .output_allocated = true };
    }
    defer ctx.allocator.free(inner.payload);
    const output = try wrapToolOutput(ctx.allocator, "command", tc.function.arguments, true, null, inner.payload);
    return ToolExecResult{
        .output = output,
        .output_allocated = true,
        .stop_loop = inner.stop_loop,
    };
}

/// True when `s` is already a tool envelope rather than a bare payload.
fn looksWrapped(s: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, s, " \t\r\n"), "{\"tool\":");
}

// ============================================================================
// Error-envelope tests — the message must let the model repair its own call.
// ============================================================================

const exec_testing = std.testing;

var test_temperature: f32 = 0.0;
var test_thinking: bool = false;

fn commandTestCtx(allocator: std.mem.Allocator, io: std.Io) ToolExecContext {
    return ToolExecContext{
        .allocator = allocator,
        .io = io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test-session",
        .model = "test-model",
        .cwd = "/tmp",
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &test_temperature,
        .is_thinking = &test_thinking,
        .environment = null,
    };
}

fn envelopeError(allocator: std.mem.Allocator, output: []const u8) !?[]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();
    const err_value = parsed.value.object.get("error") orelse return null;
    if (err_value != .string) return null;
    return try allocator.dupe(u8, err_value.string);
}

test "execCommand: a missing timeout explains the field and the fix" {
    if (exec_builtin.os.tag != .linux and exec_builtin.os.tag != .macos) return;

    const allocator = exec_testing.allocator;
    const ctx = commandTestCtx(allocator, exec_testing.io);
    const tc = agent.ToolCall{
        .id = "call-no-timeout",
        .type = "function",
        .function = .{
            .name = "command",
            .arguments = "{\"command\":\"ls -la\",\"cwd\":\"/tmp\"}",
        },
    };

    var result = try execCommand(ctx, tc);
    defer result.deinit(allocator);

    const err_msg = try envelopeError(allocator, result.output);
    defer if (err_msg) |m| allocator.free(m);
    try exec_testing.expect(err_msg != null);
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "timeout") != null);
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "required") != null);
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "TimeoutMissing") == null);
}

test "execCommand: timeout = 0 gets the same explanation as a missing one" {
    if (exec_builtin.os.tag != .linux and exec_builtin.os.tag != .macos) return;

    const allocator = exec_testing.allocator;
    const ctx = commandTestCtx(allocator, exec_testing.io);
    const tc = agent.ToolCall{
        .id = "call-zero-timeout",
        .type = "function",
        .function = .{
            .name = "command",
            .arguments = "{\"command\":\"ls\",\"cwd\":\"/tmp\",\"timeout\":0}",
        },
    };

    var result = try execCommand(ctx, tc);
    defer result.deinit(allocator);

    const err_msg = try envelopeError(allocator, result.output);
    defer if (err_msg) |m| allocator.free(m);
    try exec_testing.expect(err_msg != null);
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "timeout") != null);
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "TimeoutMissing") == null);
}

test "execCommand: a missing cwd explains the field, the wrong-tree risk and the fix" {
    // `cwd` is required. Without it the shell inherits the SERVER's working
    // directory, so the command acts on the wrong tree and the caller never
    // learns that it did.
    if (exec_builtin.os.tag != .linux and exec_builtin.os.tag != .macos) return;

    const allocator = exec_testing.allocator;
    const ctx = commandTestCtx(allocator, exec_testing.io);
    const tc = agent.ToolCall{
        .id = "call-no-cwd",
        .type = "function",
        .function = .{
            .name = "command",
            .arguments = "{\"command\":\"ls -la\",\"timeout\":30}",
        },
    };

    var result = try execCommand(ctx, tc);
    defer result.deinit(allocator);

    const err_msg = try envelopeError(allocator, result.output);
    defer if (err_msg) |m| allocator.free(m);
    try exec_testing.expect(err_msg != null);
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "cwd") != null);
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "required") != null);
    // "the SERVER's working directory" is the fact that makes the omission
    // dangerous — without it the correction reads as arbitrary pedantry.
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "SERVER") != null);
    // The error NAME never leaks into the envelope; the model gets prose.
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "MandatoryCwdMissing") == null);
}

test "execCommand: a relative cwd is refused with the absolute-path rule" {
    if (exec_builtin.os.tag != .linux and exec_builtin.os.tag != .macos) return;

    const allocator = exec_testing.allocator;
    const ctx = commandTestCtx(allocator, exec_testing.io);
    const tc = agent.ToolCall{
        .id = "call-relative-cwd",
        .type = "function",
        .function = .{
            .name = "command",
            .arguments = "{\"command\":\"ls\",\"cwd\":\"src/modules\",\"timeout\":5}",
        },
    };

    var result = try execCommand(ctx, tc);
    defer result.deinit(allocator);

    const err_msg = try envelopeError(allocator, result.output);
    defer if (err_msg) |m| allocator.free(m);
    try exec_testing.expect(err_msg != null);
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "ABSOLUTE") != null);
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "CwdNotAbsolute") == null);
}

test "execCommand: a malformed-arguments failure names the offending field" {
    const allocator = exec_testing.allocator;
    const ctx = commandTestCtx(allocator, exec_testing.io);
    const tc = agent.ToolCall{
        .id = "call-bad-args",
        .type = "function",
        .function = .{
            .name = "command",
            .arguments = "{\"command\":\"ls\",\"timeout\":\"not-a-number\"}",
        },
    };

    var result = try execCommand(ctx, tc);
    defer result.deinit(allocator);

    const err_msg = try envelopeError(allocator, result.output);
    defer if (err_msg) |m| allocator.free(m);
    try exec_testing.expect(err_msg != null);
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "timeout") != null);
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "not-a-number") != null);
}

test "execCommand: an over-max timeout states the ceiling and the alternative" {
    if (exec_builtin.os.tag != .linux and exec_builtin.os.tag != .macos) return;

    const allocator = exec_testing.allocator;
    const ctx = commandTestCtx(allocator, exec_testing.io);
    const tc = agent.ToolCall{
        .id = "call-huge-timeout",
        .type = "function",
        .function = .{
            .name = "command",
            .arguments = "{\"command\":\"ls\",\"cwd\":\"/tmp\",\"timeout\":99999}",
        },
    };

    var result = try execCommand(ctx, tc);
    defer result.deinit(allocator);

    const err_msg = try envelopeError(allocator, result.output);
    defer if (err_msg) |m| allocator.free(m);
    try exec_testing.expect(err_msg != null);
    // The ceiling, and the way out that is not "retry the same call".
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "600 seconds or fewer") != null);
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "mode=\"background\"") != null);
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "TimeoutTooLarge") == null);
}

test "execCommand: a well-formed call is not refused by the argument validator" {
    // Positive control for the four tests above. They all assert on the ERROR
    // envelope, so without this one they could pass vacuously on a tool that
    // refuses every call.
    if (exec_builtin.os.tag != .linux and exec_builtin.os.tag != .macos) return;

    const allocator = exec_testing.allocator;
    const ctx = commandTestCtx(allocator, exec_testing.io);
    const tc = agent.ToolCall{
        .id = "call-bad-cwd",
        .type = "function",
        .function = .{
            .name = "command",
            .arguments = "{\"command\":\"echo hi\",\"cwd\":\"/no/such/dir/pabrik-test\",\"timeout\":5}",
        },
    };

    var result = try execCommand(ctx, tc);
    defer result.deinit(allocator);

    const err_msg = try envelopeError(allocator, result.output);
    defer if (err_msg) |m| allocator.free(m);
    try exec_testing.expect(err_msg != null);
    // Not the argument-validation messages the four tests above assert on.
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "timeout") == null);
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "not-a-number") == null);
    // And not a bare Zig error name either — whatever the shell layer
    // reported, it arrived as a sentence.
    try exec_testing.expect(std.mem.indexOf(u8, err_msg.?, "command failed:") == null);
    try exec_testing.expect(err_msg.?.len > 20);
}

// ============================================================================
// Substrate seam — the P2c behaviour: an executor replaces the host spawn.
// ============================================================================

/// Stands in for the guest executor so the seam is proven without a VM.
const FakeGuest = struct {
    fn run(
        ctx: *const anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        argv_prefix: []const []const u8,
        input: shell.ShellInput,
    ) anyerror!shell.ShellOutput {
        _ = ctx;
        _ = io;
        _ = argv_prefix;
        return .{
            .command = try allocator.dupe(u8, input.command),
            .stdout = try std.fmt.allocPrint(allocator, "guest ran: {s}", .{input.command}),
            .stderr = try allocator.dupe(u8, ""),
            .exit_code = 0,
            .truncated = false,
            .timeout = false,
        };
    }
};

test "execute_command_with: an installed executor runs the command instead of the host shell" {
    const allocator = testing.allocator;
    var marker: u8 = 0;
    const out = try execute_command_with(
        allocator,
        testing.io,
        .{ .command = "echo hi", .cwd = "/tmp", .timeout = 5 },
        .{ .ctx = @ptrCast(&marker), .run = FakeGuest.run },
    );
    defer {
        allocator.free(out.command);
        allocator.free(out.stdout);
        allocator.free(out.stderr);
    }

    // The command reached the executor, and its answer is what the tool
    // returned — not a host process's output.
    try testing.expectEqualStrings("guest ran: echo hi", out.stdout);
    try testing.expectEqualStrings("echo hi", out.command);
    try testing.expectEqual(@as(i32, 0), out.exit_code);
}

test "execute_command: with no executor the host shell runs it, unchanged" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;
    const allocator = testing.allocator;
    const out = try execute_command(allocator, testing.io, .{
        .command = "echo local-substrate",
        .cwd = "/tmp",
        .timeout = 5,
    });
    defer {
        allocator.free(out.command);
        allocator.free(out.stdout);
        allocator.free(out.stderr);
    }
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "local-substrate") != null);
    // A host run, not a guest one.
    try testing.expect(std.mem.indexOf(u8, out.stdout, "guest ran:") == null);
}

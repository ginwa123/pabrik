// command.zig — unified shell-exec tool, merged from bash.zig + pwsh.zig.
//
// Phase A+B of the unify plan: `bash` and `pwsh` were thin wrappers over
// `shell.zig` differing ONLY in the argv-prefix (plus per-shell description
// text). This module MERGES that shared structure (moved, not duplicated):
//
//   * `CommandInput` / `CommandOutput` — aliases for `shell.ShellInput` /
//     `shell.ShellOutput`, so the LLM-facing JSON schema cannot drift.
//   * `COMMAND_BASH_PREFIX` + `COMMAND_PWSH_PREFIX` + `COMMAND_CMD_PREFIX`
//     — the three argv-prefix consts, moved here from bash.zig / pwsh.zig
//     (cmd.exe is the Windows fallback when pwsh is not installed).
//   * `execute_command` — dispatches per-OS (`pwsh` on Windows with a
//     `cmd.exe` retry on `error.FileNotFound`, `bash` elsewhere) via
//     `shell.execute_shell`.
//   * `command_result_to_json` — the shared 8-field JSON payload.
//   * `command_tool` — the merged `AgentTool` (name "command").
//
// `bash.zig` / `pwsh.zig` are now deprecated shims over this module.
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

/// argv-prefix for PowerShell Core:
/// `pwsh -NoProfile -NonInteractive -Command <script>`.
/// `-NoProfile` skips profile loading (faster, no startup hooks).
/// `-NonInteractive` prevents prompting for input (would hang the agent
/// loop waiting for a TTY that doesn't exist).
pub const COMMAND_PWSH_PREFIX: []const []const u8 = &.{
    "pwsh", "-NoProfile", "-NonInteractive", "-Command",
};

/// argv-prefix for the Windows fallback shell: `cmd.exe /c <command>`.
/// Used ONLY when `pwsh` is not installed (`error.FileNotFound` on spawn)
/// — cmd.exe ships with every Windows, so this keeps the `command` tool
/// usable on stock boxes. Phase 1 = foreground only (see execute_command).
pub const COMMAND_CMD_PREFIX: []const []const u8 = &.{
    "cmd.exe", "/c",
};

/// Run a shell command on the host-appropriate shell: `pwsh` on Windows
/// (with a `cmd.exe` retry when pwsh is missing), `bash` everywhere else.
/// Same semantics as the old `execute_bash` / `execute_pwsh`: mandatory
/// timeout (returns `error.MandatoryTimeoutMissing` if null), byte + line
/// truncation, foreground / background dispatch, URL-encoding (skipped
/// under cmd — see shell.run_shell_command).
pub fn execute_command(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: CommandInput,
) !CommandOutput {
    if (builtin.os.tag == .windows) {
        // Phase 1 (cmd fallback) is foreground-only: background keeps the
        // historical pwsh path (spawn_background's nohup idiom + the D8
        // Start-Process TODO in shell.zig). A background call on a
        // pwsh-less box fails with FileNotFound exactly as before — no
        // silent behavior change, and no nohup string is ever passed to
        // cmd (which would not understand it).
        if (input.background) {
            return shell.execute_shell(allocator, io, COMMAND_PWSH_PREFIX, input);
        }
        const pwsh_out = shell.execute_shell(allocator, io, COMMAND_PWSH_PREFIX, input) catch |err| {
            // Retry ONLY on a missing binary. Any other error (timeout,
            // forbidden, spawn permission, …) propagates unchanged so real
            // failures are never masked as "try the other shell".
            if (err != error.FileNotFound) return err;
            return try shell.execute_shell(allocator, io, COMMAND_CMD_PREFIX, input);
        };
        return pwsh_out;
    } else {
        return shell.execute_shell(allocator, io, COMMAND_BASH_PREFIX, input);
    }
}

/// JSON payload formatter — same 8-field shape as the old
/// `bash_result_to_string` / `pwsh_result_to_string`.
pub const command_result_to_json = shell.result_to_json;

pub const command_tool_system_prompt =
    \\## Command Tool — Behavior
    \\Host picks the shell: `bash` on Linux/macOS, `pwsh` on Windows (silent `cmd.exe /c` fallback when pwsh is missing).
    \\Do NOT prefix commands with a shell `timeout` utility — `mandatory_timeout` (required, max 60) is the only deadline. Bound output with `| head -n <N>` / `| tail -n <N>` (bash) or `| Select-Object -First <N>` (pwsh).
    \\Prefer `search` / `read_file` / `glob` over shell search; always set `cwd` explicitly; use `background=true` (returns PID + log path) for long-running processes — never start dev servers. Under cmd.exe: no `| head -n`, use cmd syntax (dir / where / type / %VAR% / && / double-quoted URLs).
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
        \\- `mandatory_timeout`: REQUIRED, the ONLY deadline (max 60). No shell `timeout` prefix — do not add one.
        \\- `cwd`: REQUIRED absolute path — the directory the command runs in. Never omit it: without it the shell starts in the SERVER's directory, not your worktree, so the command silently acts on the wrong tree.
        \\- Bound output: `| head -n <N>` / `| tail -n <N>` (bash) or `| Select-Object -First <N>` (pwsh); under cmd.exe use max_lines / findstr / more.
        \\- Prefer `search` / `read_file` / `glob` over shell rg/grep/find; use `rg` over grep, `fd` over find, `tree` for directory structure.
        \\- No unbounded output, no destructive commands, no dev servers (`vite`, `http.server`, `nohup ... &`) — use `background=true` (PID + log path) or the functional harness instead.
        \\- Web fetch: use the `agent-browser` CLI.
        \\
        \\## Platform notes
        \\Install pwsh via `winget install Microsoft.PowerShell` (Windows) or brew/snap (macOS/Linux); missing binary fails with `FileNotFound` at spawn (Windows retries under cmd.exe). Under cmd.exe: double-quote URLs, `%NAME%` env vars, `&&` chaining, `dir` / `where` / `type`.
        \\
        \\## Lenient types
        \\Numbers (`mandatory_timeout`, `max_output`, `max_lines`) accept JSON numbers or numeric strings; a stray trailing `</fieldname>` is auto-stripped. Booleans accept JSON bool or `"true"` / `"false"`. Real mismatches return an `invalid field` error naming the field so you can self-correct.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "command",
                    .type = "string",
                    .description =
                    \\Command to execute. Do NOT prefix it with a shell `timeout N` — mandatory_timeout is the deadline.
                    \\Bound output (`| head -n 50`, `| Select-Object -First 30`); prefer `rg` / `fd` over grep/find.
                    ,
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description =
                    \\REQUIRED. Absolute working directory — the directory the command runs IN.
                    \\Omitting it returns `MandatoryCwdMissing` and a relative path returns `CwdNotAbsolute`, because without an absolute `cwd` the shell inherits the SERVER's working directory instead of the one you are working in — the command then silently acts on the wrong tree (a `background=true` build compiled the wrong checkout that way). Send the full path, e.g. "/home/you/project".
                    ,
                },
                .{
                    .name = "mandatory_timeout",
                    .type = "number",
                    .description =
                    \\REQUIRED. Wall-clock seconds before the process is killed (SIGKILL / TerminateProcess). 1–60 only — no default (omitted or 0 returns `MandatoryTimeoutMissing`), and above 60 returns `MandatoryTimeoutTooLarge`.
                    \\Match the value to the job: a few seconds for `ls` / `cat` / `git status`, up to 60 for a build or test run. Work that legitimately needs longer than a minute must NOT run in the foreground — pass `background=true` (returns a PID + log path), then poll the log.
                    \\It is the ONLY timeout — never prefix the command with a shell `timeout N`.
                    ,
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description =
                    \\Maximum stdout+stderr bytes per stream. Default: 20480 (20 KiB).
                    \\Output exceeding this limit is truncated at read-time
                    \\to keep a single tool call from blowing up the LLM
                    \\context window. Set this explicitly when you need more
                    \\(e.g. when running `cat` on a large file or `head -n 1`
                    \\of a minified file where each line can exceed 20 KiB).
                    ,
                },
                .{
                    .name = "stdin_data",
                    .type = "string",
                    .description = "Optional stdin input for the command.",
                },
                .{
                    .name = "background",
                    .type = "boolean",
                    .description =
                    \\Run command in background using nohup.
                    \\Returns PID and log path in stdout.
                    \\Example stdout: "PID: 12345\nLog: /tmp/bg_1234567890.log"
                    \\Use PID to check status (ps -p <PID>) or kill (kill <PID>).
                    \\Note: when background=true the mandatory_timeout field is
                    \\ignored (the detached process has no deadline enforced by
                    \\this tool — the caller is responsible for killing it later).
                    ,
                },
                .{
                    .name = "max_lines",
                    .type = "number",
                    .description = "Maximum number of lines to capture from stdout/stderr. Default: 1000. Output exceeding this limit is truncated and stdout_lines/stderr_lines will report the true total.",
                },
                .{
                    .name = "do_encoding",
                    .type = "boolean",
                    .description =
                    \\Encode URLs in double quotes by converting to single quotes.
                    \\Use this for curl/wget commands with URLs containing ? and & characters.
                    \\Example: curl -sI "https://host/path?query=val&sig=xyz" will become curl -sI 'https://host/path?query=val&sig=xyz'
                    \\Skipped under the cmd.exe fallback (single quotes are literal there).
                    ,
                },
            },
            .required = &.{ "command", "cwd", "mandatory_timeout" },
        },
        .system_prompt = command_tool_system_prompt,
    },
};

// ============================================================================
// Inline tests — schema shape (existing bash/pwsh tests are NOT duplicated
// here; bash_test.zig + the pwsh.zig inline tests keep covering the shim
// path).
// ============================================================================

const testing = std.testing;
const command = @import("command.zig");

test "command_tool schema: no `timeout` prefix rule in the LLM-facing text" {
    // The tool description and system prompt used to instruct the model to
    // write `timeout <seconds> <cmd>`. That rule is gone — the only deadline
    // is the `mandatory_timeout` field, enforced in shell.execute_shell.
    // The negative "do NOT prefix" wording is still allowed; what must not
    // come back is a rule that tells the model to START with one.
    const desc = command.command_tool.function.description;
    const prompt = command.command_tool_system_prompt;

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
    for (command.command_tool.function.parameters.properties) |prop| {
        if (!std.mem.eql(u8, prop.name, "command")) continue;
        try testing.expect(std.mem.indexOf(u8, prop.description, "timeout 10 ") == null);
        try testing.expect(std.mem.indexOf(u8, prop.description, "Do NOT prefix") != null);
    }
}

test "command_tool schema: mandatory_timeout stays required and is the only timeout param" {
    // Param audit: `mandatory_timeout` is still in `.required`, and the
    // prompt-text removal did not leave a stray `timeout` sibling behind.
    const params = command.command_tool.function.parameters;

    var found_mt = false;
    var forbidden_param: ?[]const u8 = null;
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "mandatory_timeout")) found_mt = true;
        if (std.mem.eql(u8, prop.name, "timeout")) forbidden_param = prop.name;
    }
    if (forbidden_param != null) {
        std.debug.print(
            "\n!! command tool grew a `timeout` param ({s}) — mandatory_timeout is the only deadline\n",
            .{forbidden_param.?},
        );
        return error.StrayTimeoutParam;
    }
    try testing.expect(found_mt);

    var required_mt = false;
    for (params.required) |name| {
        if (std.mem.eql(u8, name, "mandatory_timeout")) required_mt = true;
    }
    try testing.expect(required_mt);
}

test "command.execute_command still enforces mandatory_timeout at runtime" {
    // The prompt-text change is cosmetic; the CODE enforcement is the
    // contract. A call with mandatory_timeout = null must still fail with
    // MandatoryTimeoutMissing (and 0 must too) — otherwise removing the
    // `timeout N` prefix rule would silently leave commands unbounded.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    try testing.expectError(
        error.MandatoryTimeoutMissing,
        command.execute_command(testing.allocator, std.testing.io, .{
            .command = "echo hi",
            .cwd = "/tmp",
            .mandatory_timeout = null,
        }),
    );
    try testing.expectError(
        error.MandatoryTimeoutMissing,
        command.execute_command(testing.allocator, std.testing.io, .{
            .command = "echo hi",
            .cwd = "/tmp",
            .mandatory_timeout = 0,
        }),
    );
}

test "command_tool schema: tool name is 'command'" {
    try testing.expectEqualStrings("command", command.command_tool.function.name);
}

test "command_tool schema: required fields are (command, cwd, mandatory_timeout)" {
    const params = command.command_tool.function.parameters;
    try testing.expectEqualStrings("object", params.type);
    try testing.expectEqual(@as(usize, 3), params.required.len);

    var found_command = false;
    var found_cwd = false;
    var found_mt = false;
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "command")) found_command = true;
        if (std.mem.eql(u8, prop.name, "cwd")) found_cwd = true;
        if (std.mem.eql(u8, prop.name, "mandatory_timeout")) found_mt = true;
    }
    try testing.expect(found_command);
    try testing.expect(found_cwd);
    try testing.expect(found_mt);
}

test "CommandInput is the same type as ShellInput (alias liveness check)" {
    const command_input = command.CommandInput{ .command = "" };
    const shell_input = shell.ShellInput{ .command = "" };
    try testing.expectEqualStrings(@typeName(@TypeOf(command_input)), @typeName(@TypeOf(shell_input)));

    const json =
        \\{"command":"x","cwd":"/tmp","mandatory_timeout":3,"max_output":10,
        \\"stdin_data":"y","background":true,"max_lines":20,"do_encoding":true}
    ;
    const a = try std.json.parseFromSlice(@TypeOf(command_input), testing.allocator, json, .{});
    defer a.deinit();
    const b = try std.json.parseFromSlice(@TypeOf(shell_input), testing.allocator, json, .{});
    defer b.deinit();
    try testing.expectEqualStrings(a.value.command, b.value.command);
    try testing.expect(a.value.mandatory_timeout.? == b.value.mandatory_timeout.?);
}

test "command argv prefixes have the expected shape" {
    try testing.expectEqual(@as(usize, 2), command.COMMAND_BASH_PREFIX.len);
    try testing.expectEqualStrings("bash", command.COMMAND_BASH_PREFIX[0]);
    try testing.expectEqualStrings("-c", command.COMMAND_BASH_PREFIX[1]);
    try testing.expectEqual(@as(usize, 4), command.COMMAND_PWSH_PREFIX.len);
    try testing.expectEqualStrings("pwsh", command.COMMAND_PWSH_PREFIX[0]);
    try testing.expectEqualStrings("-NoProfile", command.COMMAND_PWSH_PREFIX[1]);
    try testing.expectEqualStrings("-NonInteractive", command.COMMAND_PWSH_PREFIX[2]);
    try testing.expectEqualStrings("-Command", command.COMMAND_PWSH_PREFIX[3]);
    // T1 RED (cmd.exe fallback): the Windows branch retries with cmd when
    // pwsh is missing — the prefix const must exist with this exact shape.
    try testing.expectEqual(@as(usize, 2), command.COMMAND_CMD_PREFIX.len);
    try testing.expectEqualStrings("cmd.exe", command.COMMAND_CMD_PREFIX[0]);
    try testing.expectEqualStrings("/c", command.COMMAND_CMD_PREFIX[1]);
}

test "command.execute_command runs on the host shell (bash off-Windows)" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const out = try command.execute_command(testing.allocator, std.testing.io, .{
        .command = "echo hello-command",
        .cwd = "/tmp",
        .mandatory_timeout = 5,
    });
    defer {
        testing.allocator.free(out.command);
        testing.allocator.free(out.stdout);
        testing.allocator.free(out.stderr);
    }
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "hello-command") != null);
}

// T1 RED (cmd.exe fallback): availability probe. The prefix the retry
// uses is pinned by `command argv prefixes have the expected shape` above;
// the retry itself is a Windows-only branch of `execute_command` and cannot be
// driven from a Linux host.

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

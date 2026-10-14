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
/// timeout (returns `error.TimeoutMissing` if null), byte + line
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
    \\Do NOT prefix commands with a shell `timeout` utility — `timeout` (required, max 600) is the only deadline. Bound output with `| head -n <N>` / `| tail -n <N>` (bash) or `| Select-Object -First <N>` (pwsh).
    \\Pick `mode` deliberately — it is the difference between blocking your turn and not: `foreground` (default, returns the output inline), `background` (detaches AND queues you a message when it exits — use it for a long build, a test run, a migration), `background_persistence` (detaches and stays SILENT — use it for a dev server or a long-lived watcher, then read its log yourself). Never start a dev server in `foreground` or `background`: a server does not exit, so the only thing `background` would ever queue you is its death, and `foreground` would block until the deadline kills it. Under cmd.exe: no `| head -n`, use cmd syntax (dir / where / type / %VAR% / && / double-quoted URLs).
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
        \\- `timeout`: REQUIRED, the ONLY deadline (max 600). No shell `timeout` prefix — do not add one.
        \\- `cwd`: REQUIRED absolute path — the directory the command runs in. Never omit it: without it the shell starts in the SERVER's directory, not your worktree, so the command silently acts on the wrong tree.
        \\- Bound output: `| head -n <N>` / `| tail -n <N>` (bash) or `| Select-Object -First <N>` (pwsh); under cmd.exe use max_lines / findstr / more.
        \\- Prefer `search` / `read_file` / `glob` over shell rg/grep/find; use `rg` over grep, `fd` over find, `tree` for directory structure.
        \\- No unbounded output, no destructive commands. Long work goes in `mode`: `background` when you need to be told it finished (build, test, migration), `background_persistence` when it does not finish (dev server, watcher) and you will read its log yourself. A server in any other mode is a mistake: `foreground` blocks and then kills it, and `background` would queue you its death rather than its output.
        \\- Web fetch: use the `agent-browser` CLI.
        \\- End your turn: pass `is_stop=true`. It ends YOUR turn after this batch (`background` processes keep running) and is NOT a cancel — nothing is killed. Put your final answer in the message content, because a `tool_calls` turn normally has none.
        \\
        \\## Platform notes
        \\Install pwsh via `winget install Microsoft.PowerShell` (Windows) or brew/snap (macOS/Linux); missing binary fails with `FileNotFound` at spawn (Windows retries under cmd.exe). Under cmd.exe: double-quote URLs, `%NAME%` env vars, `&&` chaining, `dir` / `where` / `type`.
        \\
        \\## Lenient types
        \\Numbers (`timeout`, `max_output`, `max_lines`) accept JSON numbers or numeric strings; a stray trailing `</fieldname>` is auto-stripped. Booleans accept JSON bool or `"true"` / `"false"`. Real mismatches return an `invalid field` error naming the field so you can self-correct.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "command",
                    .type = "string",
                    .description =
                    \\Command to execute. Do NOT prefix it with a shell `timeout N` — timeout is the deadline.
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
                    .name = "timeout",
                    .type = "number",
                    .description =
                    \\REQUIRED. Wall-clock seconds before the process is killed (SIGKILL / TerminateProcess). 1–600 only — no default (omitted or 0 returns `TimeoutMissing`), and above 600 returns `TimeoutTooLarge`.
                    \\This is a FIELD, not a command prefix. The shell `timeout` utility does nothing useful here: putting it inside `command` (as in `timeout <N> ls`) is wrong twice over — it is not the deadline this field is, and the field already does the job. Send the seconds here.
                    \\Match the value to the job: a few seconds for `ls` / `cat` / `git status`, a few minutes for a build or a test suite. Ten minutes is the ceiling, and reaching for it is usually a sign the work belongs in a detached `mode` instead — a foreground command holds your turn for exactly as long as this value, so prefer `mode="background"` for anything you would rather be told about when it finishes.
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
                    .name = "mode",
                    .type = "string",
                    .description =
                    \\How this command relates to your turn. Default: "foreground".
                    \\  "foreground"              — runs now, output comes back inline. REQUIRES
                    \\                              timeout (1-600). For ls, cat, git status,
                    \\                              rg — and any build that finishes inside a minute.
                    \\  "background"              — detaches, and a message is QUEUED to you the
                    \\                              moment it exits. For bounded work you must be told
                    \\                              about: a long build, a test run, a migration.
                    \\                              timeout is ignored. Returns PID + log path.
                    \\  "background_persistence"  — detaches and stays SILENT: no message, ever. For a
                    \\                              dev server (`pnpm run dev`, `vite`) or a watcher that
                    \\                              runs until you or the user stop it. Read its output with
                    \\                              a separate foreground `tail -n 50 <log path>` call.
                    \\                              timeout is ignored. Returns PID + log path.
                    \\Choosing wrong is expensive: a server in "foreground" blocks until the deadline
                    \\kills it, and a server in "background" notifies you only when it dies — the one
                    \\event you never wanted. A bounded job in "background_persistence" means you are
                    \\never told it finished; you would have to poll.
                    ,
                },
                .{
                    .name = "background",
                    .type = "boolean",
                    .description =
                    \\LEGACY alias for mode="background" (true) / mode="foreground" (false).
                    \\Prefer `mode`: it can also express "detach and stay silent", which this
                    \\boolean cannot. Passing this together with mode="foreground" is rejected —
                    \\say one thing or the other.
                    \\Note: when detached, the timeout field is ignored (the process
                    \\outlives the call — you are responsible for stopping it).
                    ,
                },
                .{
                    .name = "is_stop",
                    .type = "boolean",
                    .description =
                    \\End YOUR turn after this call. The command still runs — and a
                    \\`background=true` process started by the same call keeps running.
                    \\This is not a cancel: nothing is killed. The agent loop stops
                    \\calling the model and hands control back to the user.
                    \\Put your final answer in the message content of this same
                    \\message: a `tool_calls` turn normally carries no prose, so
                    \\without it the turn ends on a bare tool card.
                    \\Use it for "start the dev server, then stop" or when the work is
                    \\genuinely finished. Leave it false when you intend to keep going.
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
            .required = &.{ "command", "cwd", "timeout" },
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
    // is the `timeout` field, enforced in shell.execute_shell.
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

test "command_tool schema: exactly ONE deadline param, and it is required" {
    // This test used to read "a `timeout` param must NOT exist" — it was the
    // guard against the tool growing a second way to bound a command. The
    // FIELD IS NOW CALLED `timeout`, so the literal assertion had to change;
    // what it must keep asserting is the INVARIANT, which is unchanged:
    //
    //   * exactly one property is a deadline;
    //   * it is required (no silent 30 s default — the bug that made the
    //     original field mandatory in the first place);
    //   * the shell `timeout` UTILITY is still forbidden inside `command`,
    //     which is the confusion this name creates and the next test pins.
    //
    // A second property whose name merely mentions a timeout (`timeout_ms`,
    // `timeout_seconds`) is exactly how a model starts believing it can bound
    // one command two ways, so the count is the assertion.
    const params = command.command_tool.function.parameters;

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
    // banned UTILITY on the same string. Without an explicit note, `timeout`
    // reading as "the thing I can prefix" is the natural mistake — and the
    // tool text is where it has to be pre-empted.
    // The warning belongs on the PROPERTY (that is the text the model reads
    // when deciding what to put in the field), so this asserts where it
    // actually has to be — asserting it on the top-level description would pass
    // on a tool whose field-level help says nothing.
    var timeout_desc: ?[]const u8 = null;
    for (command.command_tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "timeout")) timeout_desc = prop.description;
    }
    try testing.expect(timeout_desc != null);
    try testing.expect(std.mem.indexOf(u8, timeout_desc.?, "FIELD, not a command prefix") != null);
    try testing.expect(std.mem.indexOf(u8, timeout_desc.?, "shell `timeout` utility") != null);

    // ...and the tool-level prose still names the utility as forbidden, so a
    // model that reads only the Rules block sees it too.
    try testing.expect(std.mem.indexOf(u8, command.command_tool.function.description, "shell `timeout`") != null);

    // ...and the utility is still not RECOMMENDED anywhere, which is what the
    // banned-substring test above enforces.
    try testing.expect(std.mem.indexOf(u8, command.command_tool_system_prompt, "Do NOT prefix commands") != null);
}

test "command.execute_command still enforces timeout at runtime" {
    // The prompt-text change is cosmetic; the CODE enforcement is the
    // contract. A call with timeout = null must still fail with
    // TimeoutMissing (and 0 must too) — otherwise removing the
    // `timeout N` prefix rule would silently leave commands unbounded.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    try testing.expectError(
        error.TimeoutMissing,
        command.execute_command(testing.allocator, std.testing.io, .{
            .command = "echo hi",
            .cwd = "/tmp",
            .timeout = null,
        }),
    );
    try testing.expectError(
        error.TimeoutMissing,
        command.execute_command(testing.allocator, std.testing.io, .{
            .command = "echo hi",
            .cwd = "/tmp",
            .timeout = 0,
        }),
    );
}

test "command_tool schema: tool name is 'command'" {
    try testing.expectEqualStrings("command", command.command_tool.function.name);
}

test "command_tool schema: required fields are (command, cwd, timeout)" {
    const params = command.command_tool.function.parameters;
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
    // running. Each of those three is a way the model can be wrong in a way
    // the human then has to clean up, so the description has to carry all
    // three — a bare "stop the agent" would read as a cancel.
    //
    // Optional on purpose: defaulting to true would end every turn on the
    // first tool call, and requiring it would make every existing call site
    // (and every transcript) invalid.
    const params = command.command_tool.function.parameters;

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
    // system prompt is the prose reminder. The `timeout`-prefix regression
    // taught that a rule stated in only one of the two gets dropped from the
    // model's behaviour as soon as one of them is edited.
    try testing.expect(std.mem.indexOf(u8, command.command_tool.function.description, "is_stop=true") != null);
    try testing.expect(std.mem.indexOf(u8, command.command_tool_system_prompt, "is_stop=true") != null);
}

test "CommandInput is the same type as ShellInput (alias liveness check)" {
    const command_input = command.CommandInput{ .command = "" };
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

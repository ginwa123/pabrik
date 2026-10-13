const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const builtin = @import("builtin");

const sqlite = pabrikcore.sqlite;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const tool_models = pabrikcore.tool_models;
const command_tool_mod = pabrikcore.command_tool;
const background_process = @import("background_process.zig");
const background_process_events = @import("background_process_events.zig");
const background_watcher = @import("background_watcher.zig");
const wrapToolOutput = tools.wrapToolOutput;
const bash_args = @import("tools_exec_bash_args.zig");
const error_explain = @import("tools_error_explain.zig");

/// Merged exec body for the unified `command` tool (Phase A+B of the unify
/// plan — shared logic moved here from `tools_exec_bash.zig` /
/// `tools_exec_pwsh.zig`, which are now thin shims over this module).
///
/// Argument parsing uses `tools_exec_bash_args.parseShellArgs` (lenient:
/// recovers LLM-hallucinated XML fragments like
/// `mandatory_timeout: "5</mandatory_timeout>"` → 5, surfaces structured
/// InvalidField info on real coercion failures).
pub fn runWithContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    tool_call: agent.ToolCall,
    db: ?*sqlite.SqliteBackend,
    session_id: ?[]const u8,
) ![]const u8 {
    const input = switch (bash_args.parseShellArgs(allocator, tool_call.function.arguments)) {
        .success => |in| in,
        .failure => |info| {
            // Both the rendered message and the `got` slice it interpolates
            // are allocated by the parser; free them once the envelope has
            // copied the text. The testing allocator catches this path.
            const err_msg = try bash_args.formatInvalidField(allocator, info);
            defer allocator.free(err_msg);
            defer allocator.free(info.got);
            const output = try wrapToolOutput(allocator, "command", tool_call.function.arguments, false, err_msg, "");
            return output;
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

    const is_background = input.background;

    const command_output = try command_tool_mod.execute_command(allocator, io, input);

    // If background mode and DB is available, save the process info
    if (is_background and db != null and session_id != null) {
        const db_ptr = db.?;
        const sess_id = session_id.?;

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
                        background_process.save(db_ptr, allocator, sess_id, pid, input.command, log_path, started_at) catch {
                            // Log error but don't fail the tool execution
                        };
                        // Immediate watcher: poll the PID every 2s and queue
                        // the completion the moment it exits (no cron wait).
                        // Singleton is absent in unit tests → skip silently
                        // (cron fallback covers production; the watcher core
                        // is covered directly in background_watcher tests).
                        // Dupes into di.allocator (process lifetime) inside.
                        if (pabrikcore.getSingleton() catch null) |di| {
                            background_process_events.emitCreated(allocator, di.event_bus, sess_id, pid, input.command);
                            background_watcher.spawnCompletionWatcher(di, sess_id, pid, input.command, log_path);
                        }
                    }
                }
            }
        }
    }

    const res_command = try command_tool_mod.command_result_to_json(allocator, command_output);

    return res_command;
}

pub fn execCommand(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Catch ANY remaining error from the run path (e.g. from
    // `execute_command` itself — fork failures, permission errors, etc.)
    // and wrap it in the standard tool-error envelope, matching
    // execReadFile / execWriteFile / etc.
    //
    // The message goes through `error_explain.explain` rather than a bare
    // `@errorName`. `command failed: MandatoryTimeoutMissing` names no
    // field, no value and no fix, so the model retries the identical call
    // — the reported bug was four identical retries and then the stream
    // dying. The explanation names the field, the constraint and what to
    // send instead.
    const inner = runWithContext(ctx.allocator, ctx.io, tc, ctx.db, ctx.session_id) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "command", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    // `runWithContext` returns an ALREADY-WRAPPED envelope on its
    // parse-failure path (it has no other way to report a structured
    // field error), and a bare payload on the success path. Re-wrapping
    // the former would double-encode it, so pass it through untouched and
    // free the payload only on the success path.
    if (looksWrapped(inner)) {
        return ToolExecResult{ .output = inner, .output_allocated = true };
    }
    defer ctx.allocator.free(inner);
    const output = try wrapToolOutput(ctx.allocator, "command", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

/// True when `s` is already a tool envelope rather than a bare payload.
/// `runWithContext` is the only producer here and it always emits the
/// `{"tool":…,"v":1}` shape, so a prefix check is unambiguous — a shell
/// payload is a `ShellOutput` object, which has neither key.
fn looksWrapped(s: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, s, " \t\r\n"), "{\"tool\":");
}

// ============================================================================
// Error-envelope tests — the message must let the model repair its own call.
// ============================================================================

const testing = std.testing;

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

test "execCommand: a missing mandatory_timeout explains the field and the fix" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const ctx = commandTestCtx(allocator, testing.io);
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
    try testing.expect(err_msg != null);
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "mandatory_timeout") != null);
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "required") != null);
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "MandatoryTimeoutMissing") == null);
}

test "execCommand: mandatory_timeout = 0 gets the same explanation as a missing one" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const ctx = commandTestCtx(allocator, testing.io);
    const tc = agent.ToolCall{
        .id = "call-zero-timeout",
        .type = "function",
        .function = .{
            .name = "command",
            .arguments = "{\"command\":\"ls\",\"cwd\":\"/tmp\",\"mandatory_timeout\":0}",
        },
    };

    var result = try execCommand(ctx, tc);
    defer result.deinit(allocator);

    const err_msg = try envelopeError(allocator, result.output);
    defer if (err_msg) |m| allocator.free(m);
    try testing.expect(err_msg != null);
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "mandatory_timeout") != null);
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "MandatoryTimeoutMissing") == null);
}

test "execCommand: a missing cwd explains the field, the wrong-tree risk and the fix" {
    // `cwd` is required. Without it the shell inherits the SERVER's working
    // directory, so the command acts on the wrong tree and the caller never
    // learns that it did. The prose has to name the field, WHY the omission is
    // dangerous, and the shape of the value to send.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const ctx = commandTestCtx(allocator, testing.io);
    const tc = agent.ToolCall{
        .id = "call-no-cwd",
        .type = "function",
        .function = .{
            .name = "command",
            .arguments = "{\"command\":\"ls -la\",\"mandatory_timeout\":30}",
        },
    };

    var result = try execCommand(ctx, tc);
    defer result.deinit(allocator);

    const err_msg = try envelopeError(allocator, result.output);
    defer if (err_msg) |m| allocator.free(m);
    try testing.expect(err_msg != null);
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "cwd") != null);
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "required") != null);
    // "the SERVER's working directory" is the fact that makes the omission
    // dangerous — without it the correction reads as arbitrary pedantry.
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "SERVER") != null);
    // The error NAME never leaks into the envelope; the model gets prose.
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "MandatoryCwdMissing") == null);
}

test "execCommand: a relative cwd is refused with the absolute-path rule" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const ctx = commandTestCtx(allocator, testing.io);
    const tc = agent.ToolCall{
        .id = "call-relative-cwd",
        .type = "function",
        .function = .{
            .name = "command",
            .arguments = "{\"command\":\"ls\",\"cwd\":\"src/modules\",\"mandatory_timeout\":5}",
        },
    };

    var result = try execCommand(ctx, tc);
    defer result.deinit(allocator);

    const err_msg = try envelopeError(allocator, result.output);
    defer if (err_msg) |m| allocator.free(m);
    try testing.expect(err_msg != null);
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "ABSOLUTE") != null);
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "CwdNotAbsolute") == null);
}

test "execCommand: a malformed-arguments failure names the offending field" {
    const allocator = testing.allocator;
    const ctx = commandTestCtx(allocator, testing.io);
    const tc = agent.ToolCall{
        .id = "call-bad-args",
        .type = "function",
        .function = .{
            .name = "command",
            .arguments = "{\"command\":\"ls\",\"mandatory_timeout\":\"not-a-number\"}",
        },
    };

    var result = try execCommand(ctx, tc);
    defer result.deinit(allocator);

    const err_msg = try envelopeError(allocator, result.output);
    defer if (err_msg) |m| allocator.free(m);
    try testing.expect(err_msg != null);
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "mandatory_timeout") != null);
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "not-a-number") != null);
}

test "execCommand: an over-max mandatory_timeout states the ceiling and the alternative" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const ctx = commandTestCtx(allocator, testing.io);
    const tc = agent.ToolCall{
        .id = "call-huge-timeout",
        .type = "function",
        .function = .{
            .name = "command",
            .arguments = "{\"command\":\"ls\",\"cwd\":\"/tmp\",\"mandatory_timeout\":99999}",
        },
    };

    var result = try execCommand(ctx, tc);
    defer result.deinit(allocator);

    const err_msg = try envelopeError(allocator, result.output);
    defer if (err_msg) |m| allocator.free(m);
    try testing.expect(err_msg != null);
    // The ceiling, and the way out that is not "retry the same call".
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "60 seconds or fewer") != null);
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "background=true") != null);
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "MandatoryTimeoutTooLarge") == null);
}

test "execCommand: a well-formed call is not refused by the argument validator" {
    // Positive control for the four tests above. They all assert on the
    // ERROR envelope, so without this one they could pass vacuously on a
    // tool that refuses every call. A call whose arguments are well-formed
    // must get past `parseShellArgs` and reach `execute_command` — proven
    // here by a `cwd` that does not exist, which fails INSIDE the shell
    // spawn rather than in argument validation.
    //
    // Deliberately does not spawn a real command: `std.testing.io` is a
    // single-threaded `Io.Threaded`, and `run_shell_command`'s reader
    // threads need that runtime pumped. A foreground spawn from a test
    // that runs after other tests have already used the singleton
    // deadlocks in `anon_pipe_read`. The foreground happy path is covered
    // at the `execute_command` level by
    // `command.execute_command runs on the host shell` in command.zig.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const ctx = commandTestCtx(allocator, testing.io);
    const tc = agent.ToolCall{
        .id = "call-bad-cwd",
        .type = "function",
        .function = .{
            .name = "command",
            .arguments = "{\"command\":\"echo hi\",\"cwd\":\"/no/such/dir/pabrik-test\",\"mandatory_timeout\":5}",
        },
    };

    var result = try execCommand(ctx, tc);
    defer result.deinit(allocator);

    const err_msg = try envelopeError(allocator, result.output);
    defer if (err_msg) |m| allocator.free(m);
    try testing.expect(err_msg != null);
    // Not the argument-validation messages the four tests above assert on.
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "mandatory_timeout") == null);
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "not-a-number") == null);
    // And not a bare Zig error name either — whatever the shell layer
    // reported, it arrived as a sentence.
    try testing.expect(std.mem.indexOf(u8, err_msg.?, "command failed:") == null);
    try testing.expect(err_msg.?.len > 20);
}

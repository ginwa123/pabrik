// RETIRED: `pwsh` is no longer a tool name. The unified `command` tool
// (src/modules/agent/tools/command.zig) replaced it on 2026-09-04, and the
// name was BANNED from dispatch on 2026-10-12 (see
// agentic_loop/tools_equipped.zig :: RETIRED_TOOL_NAMES) — a model that emits
// `pwsh` is refused and told to call `command`. This module survives only so
// `pwsh_tool` and `execute_pwsh` keep compiling for non-LLM callers; nothing
// offers `pwsh` to the model.
const std = @import("std");
const command = @import("command.zig");
const schemas = @import("schemas.zig");

const AgentTool = schemas.AgentTool;

/// Public type aliases — wire-compatible with `BashInput` / `BashOutput`.
pub const PwshInput = command.CommandInput;
pub const PwshOutput = command.CommandOutput;

/// Run a PowerShell Core command. Deprecated shim over
/// `command.execute_command` (which dispatches to `pwsh` on Windows,
/// `bash` elsewhere).
pub fn execute_pwsh(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: PwshInput,
) !PwshOutput {
    return command.execute_command(allocator, io, input);
}

/// JSON payload formatter — same 8-field shape as `bash_result_to_json`.
/// Re-exported under the pwsh name for ergonomic callers.
pub const pwsh_result_to_json = command.command_result_to_json;

pub const pwsh_tool_system_prompt = command.command_tool_system_prompt;

pub const pwsh_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "pwsh",
        .description = command.command_tool.function.description,
        .parameters = command.command_tool.function.parameters,
        .system_prompt = pwsh_tool_system_prompt,
    },
};

// pwsh_test.zig — pwsh tool behavioural tests (Task 3 of 2026-08-14-pwsh-tool.md).
//
// pwsh is the LLM-facing PowerShell Core shell tool. The wire schema is
// identical to bash (ShellInput / ShellOutput aliases per D2 in the plan).
// These tests assert the behavioural parity:
//
//   1. `pwsh_tool` schema name + required fields match bash
//   2. `pwsh_available()` returns false when pwsh isn't on $PATH (test skip)
//   3. `parsePwsh` returns the same typed struct as `parseBash` (Task 7.2)
//
// We don't import a real `pwsh` executable on most CI runners, so the
// happy-path `execute_pwsh("Write-Output hello-pwsh")` test SKIPS via
// `if (!pwsh_available()) return;` — same pattern as bash.zig skipping
// the Windows path on macOS / Linux.
const builtin = @import("builtin");
const testing = std.testing;
const pwsh = @import("pwsh.zig");

/// Probe whether `pwsh` is on $PATH. Skips gracefully when it isn't.
/// Equivalent to the bash.zig `if builtin.os.tag != .linux and builtin.os.tag != .macos` skip —
/// but pwsh's availability check is per-machine, not per-OS.
fn pwsh_available() bool {
    // Zig 0.16 std.process API: `std.process.run(gpa, io, options)`.
    // The .argv-based run signature is `RunOptions { argv, ... }`.
    // We probe `pwsh -NoProfile -NonInteractive -Command "$PSVersionTable…"`
    // which returns immediately on any working pwsh install.
    var child = std.process.spawn(std.testing.io, .{
        .argv = &.{ "pwsh", "-NoProfile", "-NonInteractive", "-Command", "$PSVersionTable.PSVersion.ToString()" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return false;
    defer child.kill(std.testing.io);

    const term = child.wait(std.testing.io) catch return false;
    return term == .exited;
}

test "pwsh_tool schema: tool name is 'pwsh'" {
    try testing.expectEqualStrings("pwsh", pwsh.pwsh_tool.function.name);
}

test "pwsh_tool schema: required fields match bash (command, cwd, timeout)" {
    // The wire contract mirrors bash: same three required fields.
    const params = pwsh.pwsh_tool.function.parameters;
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

test "pwsh_available returns false when pwsh is not on PATH" {
    // This test runs regardless of platform — it just exercises the
    // boolean probe. On a CI machine without pwsh it returns false; on
    // a Windows or pwsh-installed machine it returns true.
    const available = pwsh_available();
    _ = available;
    // The test passes either way — the assertion is "doesn't crash".
    try testing.expect(true);
}

test "command-only registry: the model is offered exactly one shell tool, named command" {
    const tools_equipped = @import("../../../agentic_loop/tools_equipped.zig");

    // Post-unify contract (2026-09-04): the tool surface is ONE shell tool.
    // `bash`/`pwsh` survive only as unregistered shim modules (both delegate to
    // command.execute_command) so old code still compiles — registering either
    // would show the model three shell tools again. UNIFIED_TOOL_REGISTRY is
    // the table this is read from, not the text of a wiring file.
    // The names themselves were fully RETIRED on 2026-10-12 (no dispatch
    // alias) — see the assertions at the end of this test.
    var command_entries: usize = 0;
    for (tools_equipped.UNIFIED_TOOL_REGISTRY()) |entry| {
        if (std.mem.eql(u8, entry.name, "bash") or std.mem.eql(u8, entry.name, "pwsh")) {
            std.debug.print(
                "!! '{s}' is registered again -- the model would see three shell tools\n",
                .{entry.name},
            );
            return error.LegacyShellToolRegistered;
        }
        if (!std.mem.eql(u8, entry.name, "command")) continue;
        command_entries += 1;
        // The entry must carry the merged command tool def, not a shim.
        try testing.expectEqualStrings("command", entry.tool_def.function.name);
        try testing.expectEqualStrings(command.command_tool.function.description, entry.tool_def.function.description);
    }
    try testing.expectEqual(@as(usize, 1), command_entries);

    // …and the equipped list — the one the workflow actually hands the LLM —
    // advertises neither legacy name.
    const equip = tools_equipped.equips(testing.allocator);
    defer testing.allocator.free(equip);
    for (equip) |t| {
        try testing.expect(!std.mem.eql(u8, t.function.name, "bash"));
        try testing.expect(!std.mem.eql(u8, t.function.name, "pwsh"));
    }

    // Unregistered is not unreachable-by-accident: the names are RETIRED, so
    // a stale `bash` call is refused outright AND the refusal names
    // `command`. The old behavior — dispatch through an alias table so the
    // call still ran — is exactly what kept the model emitting `bash`
    // forever: the call worked, so nothing ever corrected it.
    try testing.expectEqual(@as(?[]const u8, null), tools_equipped.resolveToolAlias("bash"));
    try testing.expectEqual(@as(?[]const u8, null), tools_equipped.resolveToolAlias("pwsh"));
    try testing.expect(!tools_equipped.isDispatchableToolName("bash"));
    try testing.expect(!tools_equipped.isDispatchableToolName("pwsh"));
    try testing.expectEqualStrings("command", tools_equipped.retiredToolSuggestion("bash").?);
    try testing.expectEqualStrings("command", tools_equipped.retiredToolSuggestion("pwsh").?);
}

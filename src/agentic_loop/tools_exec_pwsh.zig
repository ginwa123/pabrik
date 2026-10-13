// RETIRED: the `"pwsh"` exec path. `execPwsh` delegates to
// tools_exec_command.execCommand; the name itself is no longer dispatchable
// (see tools_equipped.zig :: RETIRED_TOOL_NAMES).
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const command_exec = @import("tools_exec_command.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;

pub const runWithContext = command_exec.runWithContext;

pub fn execPwsh(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    return command_exec.execCommand(ctx, tc);
}

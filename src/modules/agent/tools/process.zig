//! Agent-callable tool: `process` — look at, or stop, the processes this
//! session started with the `command` tool's detached modes.
//!
//! ## Why this is a separate tool and not more `command` params
//!
//! `command` requires `command`, `cwd` and `timeout`. A "read my dev server's
//! log" call would have to invent a dummy command and a dummy deadline on every
//! poll — and the model would have to remember a `pid` AND a `log_path` across
//! turns, which compaction is exactly the wrong thing for. Here the session is
//! resolved server-side, `list` answers "what am I running" instead of
//! "remember a path", and the pid is the only thing the model carries.
//!
//! ## The three actions
//!
//!   * `read`  — the log output since the LAST read, and nothing before it.
//!               This is what makes polling a `background_persistence` service
//!               affordable: a poll with no news costs a few tokens instead of
//!               re-sending the head of a file that has only grown.
//!   * `stop`  — kill it, tree included, and mark the row.
//!   * `list`  — every process this session started, with live liveness and
//!               each one's `kind`.
//!
//! `kind` is the thing the model needs to act sensibly: `job` means it WILL be
//! told when the process exits (so reading is optional), `service` means it
//! never will (so reading is the only way to find out anything, and stopping is
//! the only way to end it).

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

/// The three actions, as a closed set. Kept as a constant so the schema text and
/// the exec's parse cannot disagree about what is legal.
pub const ACTIONS: []const []const u8 = &.{ "read", "stop", "list" };

pub const ReadAction = "read";
pub const StopAction = "stop";
pub const ListAction = "list";

/// Default cap for one `read`, in bytes. 16 KiB is roughly 200 lines of a dev
/// server's chatter — enough to see a compile error and its stack, small enough
/// that a chatty process cannot blow up the context window in one call.
pub const DEFAULT_MAX_BYTES: usize = 16 * 1024;

pub const process_tool_system_prompt =
    \\## Process Tool — reading and stopping what `command` detached
    \\
    \\A `command` call with `mode="background"` or `mode="background_persistence"` returns a PID and a
    \\log path. This tool is how you look at it or end it, without shelling out.
    \\
    \\- `action="list"` — what this session is running. Start here when you are unsure what you
    \\  started, or after a long gap. `kind` tells you what you owe each one: `job` = you WILL be
    \\  messaged when it exits; `service` = SILENT, you will never be messaged.
    \\- `action="read"` with `pid` — ONLY the output since your last read of that process. An empty
    \\  result is an answer ("nothing new"), not an error. Reading does not disturb the process.
    \\- `action="stop"` with `pid` — kills the process AND everything it forked, so a dev server's
    \\  port is actually released. Marks the row so `list` stops showing it as running.
    \\
    \\A `service` is never going to tell you it crashed: read it when you doubt it, and stop it when
    \\you are done with it — nothing else will.
    \\
;

pub const process_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "process",
        .description =
        \\Look at, or stop, a process this session started with the `command` tool's detached modes.
        \\
        \\## Actions
        \\- `list` — every process this session started: pid, command, kind, status, live liveness. Takes no `pid`.
        \\- `read` — the log output since your LAST read of that pid (not the whole log). Needs `pid`.
        \\- `stop` — kill that pid and everything it forked. Needs `pid`.
        \\
        \\## Reading is incremental, on purpose
        \\`read` returns only what is new since the previous read of that pid, so polling a running
        \\process is cheap: a poll with no news returns nothing and costs almost nothing. The first
        \\read of a process returns its log from the start (capped at `max_bytes`, default 16384);
        \\if the output was longer, `more_pending` is true and the next read continues from there.
        \\
        \\An empty `read` means "nothing new since last time" — it is NOT an error and NOT a sign the
        \\process died. Use `list` (or the `running` field a `read` also reports) for liveness.
        \\
        \\## kind: what you owe each process
        \\- `job` (`mode="background"`) — a bounded command. You ARE messaged when it exits, so you
        \\  rarely need to read it; do not poll a build you will be told about.
        \\- `service` (`mode="background_persistence"`) — a dev server or watcher. It is SILENT: no
        \\  message will ever arrive, so nothing but this tool will tell you it crashed, and nothing
        \\  but `stop` (or pabrik shutting down) will end it.
        \\
        \\`stop` is a tree kill — the whole process group — because a dev server forks its workers and
        \\killing only the pid leaves them holding the port.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "action",
                    .type = "string",
                    .description =
                    \\REQUIRED. One of "read", "stop", "list".
                    \\"list" takes no other argument. "read" and "stop" both need a `pid`.
                    ,
                },
                .{
                    .name = "pid",
                    .type = "number",
                    .description =
                    \\The process to act on, as returned by the `command` call that started it (or by
                    \\this tool's own `list`). Required for "read" and "stop"; ignored by "list".
                    \\A pid this session did not start is refused — you cannot read or kill another
                    \\session's process.
                    ,
                },
                .{
                    .name = "max_bytes",
                    .type = "number",
                    .description =
                    \\Cap on the bytes "read" returns in this call. Default 16384. Output beyond it is
                    \\NOT lost: the response reports `more_pending` and the next read continues from
                    \\where this one stopped.
                    ,
                },
            },
            .required = &.{"action"},
        },
        .system_prompt = process_tool_system_prompt,
    },
};

// ============================================================================
// Inline tests — schema shape
// ============================================================================

const testing = std.testing;
const process = @import("process.zig");

test "process_tool schema: name and the one required param" {
    try testing.expectEqualStrings("process", process.process_tool.function.name);
    const params = process.process_tool.function.parameters;
    try testing.expectEqualStrings("object", params.type);
    // `action` alone: a `pid` required here would break `list`, and every other
    // field is action-specific. One required field is the whole contract.
    try testing.expectEqual(@as(usize, 1), params.required.len);
    try testing.expectEqualStrings("action", params.required[0]);
}

test "process_tool schema: exactly the three documented actions, and pid/max_bytes optional" {
    var found_action = false;
    var found_pid = false;
    var found_max = false;
    for (process.process_tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "action")) {
            found_action = true;
            // Each action must be named in the description, or the model is
            // guessing at a string enum the schema cannot express.
            for (process.ACTIONS) |a| {
                try testing.expect(std.mem.indexOf(u8, prop.description, a) != null);
            }
        }
        if (std.mem.eql(u8, prop.name, "pid")) found_pid = true;
        if (std.mem.eql(u8, prop.name, "max_bytes")) found_max = true;
    }
    try testing.expect(found_action and found_pid and found_max);
}

test "process_tool schema: the description states the two facts the model will get wrong" {
    // 1. An empty read is an ANSWER. Without this, a model reads nothing, assumes
    //    the worst, and restarts a healthy dev server.
    try testing.expect(std.mem.indexOf(u8, process.process_tool.function.description, "nothing new") != null);
    // 2. `service` is silent. This is the load-bearing difference between the two
    //    detached modes, and the only reason `kind` is on the wire at all.
    try testing.expect(std.mem.indexOf(u8, process.process_tool.function.description, "SILENT") != null);
    try testing.expect(std.mem.indexOf(u8, process.process_tool.function.description, "tree kill") != null);
}

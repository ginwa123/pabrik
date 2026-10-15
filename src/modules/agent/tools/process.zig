//! Agent-callable tool: `process` — look at, or stop, the processes this
//! session started with the `command` tool's detached modes. `command`
//! requires `command`, `cwd` and `timeout`.

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
    \\- `action="read"` with `pid` — ONLY the output since your last read of that  An empty
    \\  result is an answer ("nothing new"), not an error. Reading does not disturb the 
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
        \\Look at, or stop, a process this session started with the `command` tool's detached modes (`mode="background"`, `mode="background_persistence"`).
        \\
        \\## Actions
        \\- `list` — every process this session started: pid, command, kind, status, liveness. Needs no `pid`.
        \\- `read` (needs `pid`) — only the output since your LAST read of that pid, so polling is cheap. The first read starts at the beginning; an empty read means "nothing new" — an answer, not an error, and not a sign the process died.
        \\- `stop` (needs `pid`) — a tree kill of the whole process group: a dev server forks workers, so killing the pid alone leaves them holding the port.
        \\
        \\## kind
        \\- `job` — a bounded command; you ARE messaged when it exits, so do not poll it.
        \\- `service` — a dev server or watcher, SILENT: no message will ever arrive, so nothing but this tool will tell you it crashed, and nothing but `stop` (or pabrik shutting down) will end it.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "action",
                    .type = "string",
                    .description =
                    \\REQUIRED. One of "read", "stop", "list". "read" and "stop" need a `pid`.
                    ,
                },
                .{
                    .name = "pid",
                    .type = "number",
                    .description =
                    \\The process to act on, as returned by the `command` call that started it (or by
                    \\`list`). Required for "read" and "stop"; ignored by "list". A pid this
                    \\session did not start is refused.
                    ,
                },
                .{
                    .name = "max_bytes",
                    .type = "number",
                    .description =
                    \\Cap on the bytes "read" returns. Default 16384. Output beyond it is
                    \\NOT lost: the response reports `more_pending` and the next read continues there.
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

test "process_tool schema: name and the one required param" {
    try testing.expectEqualStrings("process", process_tool.function.name);
    const params = process_tool.function.parameters;
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
    for (process_tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "action")) {
            found_action = true;
            // Each action must be named in the description, or the model is
            // guessing at a string enum the schema cannot express.
            for (ACTIONS) |a| {
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
    try testing.expect(std.mem.indexOf(u8, process_tool.function.description, "nothing new") != null);
    // 2. `service` is silent. This is the load-bearing difference between the two
    //    detached modes, and the only reason `kind` is on the wire at all.
    try testing.expect(std.mem.indexOf(u8, process_tool.function.description, "SILENT") != null);
    try testing.expect(std.mem.indexOf(u8, process_tool.function.description, "tree kill") != null);
}

// Exec adapter — merged from `zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const sqlite = pabrikcore.sqlite;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const process_tool_mod = pabrikcore.process_tool;
const background_process = @import("../../../agentic_loop/background_process.zig");
const shell_tool = pabrikcore.shell_tool;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
/// Cap on ONE `read`. Matches the tool schema's documented default.
pub const default_max_bytes: usize = process_tool_mod.DEFAULT_MAX_BYTES;

/// Parsed `process` arguments. Every field optional: which ones are required
/// depends on `action`, so the check belongs with the action, not here.
const Args = struct {
    action: []const u8 = "",
    pid: ?u32 = null,
    max_bytes: ?usize = null,
};

/// Lenient parse — same posture as the `command` tool's: the model's JSON is
/// coerced per field where that is unambiguous (a numeric string, a trailing
/// XML close tag), and a real mismatch is reported as a field error rather
fn parseArgs(allocator: std.mem.Allocator, arguments: []const u8) !union(enum) {
    ok: struct { args: Args, owned_action: ?[]u8 },
    bad: []const u8, // error prose, caller-owned
} {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments, .{}) catch {
        return .{ .bad = try std.fmt.allocPrint(
            allocator,
            "arguments were not valid JSON ({s}) — send {{\"action\": \"list\"}} and nothing else to see what this session is running.",
            .{arguments},
        ) };
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return .{ .bad = try std.fmt.allocPrint(
            allocator,
            "arguments must be a JSON object with an \"action\" field.",
            .{},
        ) },
    };

    var out: Args = .{};
    var owned_action: ?[]u8 = null;

    if (obj.get("action")) |v| {
        switch (v) {
            .string => |s| owned_action = try allocator.dupe(u8, std.mem.trim(u8, s, " \t\"")),
            else => return .{ .bad = try std.fmt.allocPrint(allocator, "\"action\" must be a string, one of \"read\", \"stop\", \"list\".", .{}) },
        }
        if (owned_action) |a| out.action = a;
    }

    if (obj.get("pid")) |v| {
        out.pid = switch (v) {
            .integer => |i| if (i > 0) @as(u32, @intCast(i)) else null,
            .float => |f| if (f > 0) @as(u32, @intFromFloat(f)) else null,
            // A numeric string is the shape the model most often sends; a
            // trailing `</pid>` is the XML leakage the `command` parser also
            // cleans up.
            .string => |s| blk: {
                const cleaned = std.mem.trim(u8, s, " \t\"");
                const tag = std.mem.indexOf(u8, cleaned, "</") orelse cleaned.len;
                break :blk std.fmt.parseInt(u32, std.mem.trim(u8, cleaned[0..tag], " \t"), 10) catch null;
            },
            else => null,
        };
    }

    if (obj.get("max_bytes")) |v| {
        out.max_bytes = switch (v) {
            .integer => |i| if (i > 0) @as(usize, @intCast(i)) else null,
            .string => |s| std.fmt.parseInt(usize, std.mem.trim(u8, s, " \t\""), 10) catch null,
            else => null,
        };
    }

    return .{ .ok = .{ .args = out, .owned_action = owned_action } };
}

/// Run one `process` call and return the INNER JSON payload (the caller wraps
/// it in the tool envelope).
pub fn executeProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    arguments: []const u8,
) ![]const u8 {
    const parsed = try parseArgs(allocator, arguments);
    const action: []const u8 = switch (parsed) {
        .bad => |msg| {
            defer allocator.free(msg);
            return buildError(allocator, msg);
        },
        .ok => |ok| blk: {
            if (ok.owned_action) |a| {
                // The action slice is handed to every branch below; freeing it
                // is the caller's job at the one return point.
                break :blk a;
            }
            break :blk "";
        },
    };
    // `owned_action` may be null when `action` was absent; `defer` handles both.
    defer {
        switch (parsed) {
            .ok => |ok| if (ok.owned_action) |a| allocator.free(a),
            .bad => {},
        }
    }
    const args: Args = switch (parsed) {
        .ok => |ok| ok.args,
        .bad => unreachable,
    };

    if (action.len == 0) {
        return buildError(allocator, "\"action\" is required — one of \"read\", \"stop\", \"list\".");
    }

    if (std.mem.eql(u8, action, process_tool_mod.ListAction)) {
        return listProcesses(allocator, io, db, session_id);
    }
    if (std.mem.eql(u8, action, process_tool_mod.ReadAction)) {
        return readProcess(allocator, io, db, session_id, args);
    }
    if (std.mem.eql(u8, action, process_tool_mod.StopAction)) {
        return stopProcess(allocator, io, db, session_id, args);
    }

    return buildError(allocator, "unknown action — use \"read\", \"stop\" or \"list\".");
}

fn buildError(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    // `error` is a keyword, so the field needs the quoted form. The JSON key
    // and the envelope's own `error` field then read the same to the model.
    return std.json.Stringify.valueAlloc(allocator, .{
        .ok = false,
        .@"error" = message,
    }, .{});
}

/// The one-row wire shape. Field names are the model's vocabulary, not the
/// internal ones: `running` is liveness as of THIS call, `status` is the stored
/// value, which can lag (the docs say so).
const Entry = struct {
    pid: u32,
    command: []const u8,
    kind: []const u8,
    status: []const u8,
    running: bool,
    log_path: []const u8,
};

fn entryFor(allocator: std.mem.Allocator, p: background_process.ProcessInfo) !Entry {
    _ = allocator;
    return .{
        .pid = p.pid,
        .command = p.command,
        .kind = p.kind,
        .status = p.status,
        // `isAlive`, not a plain probe: it reaps first, so a process that just
        // exited is not reported as running.
        .running = background_process.isAlive(p.pid),
        .log_path = p.log_path,
    };
}

fn listProcesses(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    _ = io;
    const rows = try background_process.getBySession(db, allocator, session_id);
    defer background_process.freeProcessInfos(allocator, rows);

    var entries = std.ArrayList(Entry).empty;
    defer entries.deinit(allocator);
    for (rows) |p| try entries.append(allocator, try entryFor(allocator, p));

    return std.json.Stringify.valueAlloc(allocator, .{
        .ok = true,
        .count = entries.items.len,
        .processes = entries.items,
    }, .{});
}

fn readProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    args: Args,
) ![]const u8 {
    const pid = args.pid orelse return buildError(
        allocator,
        "\"read\" needs a \"pid\" — the one the `command` call returned (or a pid from action=\"list\").",
    );

    const row = (try background_process.getByPid(db, allocator, session_id, pid)) orelse return buildError(
        allocator,
        "\"pid\" is not a process this session started — use action=\"list\" to see the ones you did. (A pid from another session cannot be read here.)",
    );
    defer background_process.freeProcessInfo(allocator, row);

    const cap: usize = if (args.max_bytes) |m| @min(m, 1 << 20) else default_max_bytes;
    const delta = try background_process.readDelta(allocator, io, db, session_id, pid, row.log_path, row.last_read_offset, cap);
    defer delta.free(allocator);

    // A log with control bytes in it is not representable in a JSON string, and
    // a dev server's colour codes are exactly that. Same sanitizer the `command`
    // tool's payload goes through.
    const clean = try @import("helpers").sanitize_control_chars(allocator, delta.bytes);
    defer allocator.free(clean);

    return std.json.Stringify.valueAlloc(allocator, .{
        .ok = true,
        .pid = pid,
        .command = row.command,
        .kind = row.kind,
        .status = row.status,
        .running = background_process.isAlive(pid),
        // The delta, verbatim. Empty when nothing is new — which is an answer,
        // not a failure, and the schema says so.
        .output = clean,
        .new_bytes = clean.len,
        .total_bytes = delta.total_bytes,
        .more_pending = delta.more_pending,
        .log_missing = delta.missing,
    }, .{});
}

fn stopProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    args: Args,
) ![]const u8 {
    const pid = args.pid orelse return buildError(
        allocator,
        "\"stop\" needs a \"pid\" — use action=\"list\" to see the processes this session started.",
    );

    const row = (try background_process.getByPid(db, allocator, session_id, pid)) orelse return buildError(
        allocator,
        "\"pid\" is not a process this session started — use action=\"list\" to see the ones you did.",
    );
    defer background_process.freeProcessInfo(allocator, row);

    const was_alive = background_process.isAlive(pid);
    // The TREE, not the pid: a dev server forks its workers, and killing only
    // the parent leaves them holding the port — which is precisely how "stop
    // the dev server" used to fail.
    const signalled = shell_tool.stopDetachedProcess(allocator, io, pid);
    background_process.updateStatus(db, allocator, session_id, pid, "killed") catch {};

    return std.json.Stringify.valueAlloc(allocator, .{
        .ok = true,
        .pid = pid,
        .command = row.command,
        .kind = row.kind,
        .signalled = signalled,
        // Reported so the model can tell "I stopped it" from "it was already
        // gone", which are different situations for a `service` it expected to
        // be running.
        .was_running = was_alive,
    }, .{});
}

pub fn execProcess(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const inner = executeProcess(ctx.allocator, ctx.io, ctx.db, ctx.session_id, tc.function.arguments) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "process", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);
    const output = try wrapToolOutput(ctx.allocator, "process", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}


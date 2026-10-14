//! subagent_progress.zig — live progress emitter for `spawn_sub_agent`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tree1_mod = pabrikcore;
const on_event_sent = @import("on_event_sent.zig");
const loggermod = pabrikcore.loggermod;
const helpers = @import("helpers");

/// Lifecycle stage of one sub-agent within a spawn batch. Wire values are
/// snake_case strings to match the existing JSON convention
/// (status="created|updated|deleted" on workers, etc.).
pub const ProgressStatus = enum {
    launched,
    completed,
    failed,

    pub fn toStr(self: @This()) []const u8 {
        return switch (self) {
            .launched => "launched",
            .completed => "completed",
            .failed => "failed",
        };
    }
};

/// Everything the emitter needs to render one progress event.
pub const ProgressEventInput = struct {
    parent_session_id: []const u8,
    tool_call_id: []const u8,
    agent_name: []const u8,
    status: ProgressStatus,
    agent_index: usize,
    total_agents: usize,
    session_id: []const u8 = "",
    elapsed_ms: i64 = 0,
};

/// Builds the JSON event payload (caller owns, free with the same allocator).
/// Pure — no DI / no side effects — so the unit tests can stay hermetic.
pub fn buildProgressEventJson(allocator: std.mem.Allocator, input: ProgressEventInput) ![]u8 {
    // Sanitise agent_name (LLM-supplied).
    const safe_name = try helpers.sanitize.sanitizeUtf8(allocator, input.agent_name);
    defer allocator.free(safe_name);

    // Build the payload as an anonymous struct; std.json.fmt emits it
    // deterministically.
    const payload = .{
        .type = "full",
        .role = "subagent_progress",
        .session_id = input.parent_session_id,
        .tool_call_id = input.tool_call_id,
        .agent_name = safe_name,
        .status = input.status.toStr(),
        .agent_index = input.agent_index,
        .total_agents = input.total_agents,
        .elapsed_ms = input.elapsed_ms,
        // Model/cwd/loop_index/temperature/is_thinking/is_input/is_output/
        // finish_reason/etc. are REQUIRED non-null strings in
        // OnEventInputLLMHistory.
        .model = "",
        .cwd = "",
        .finish_reason = null,
        .reasoning_content = null,
        .content = "",
        .parent_session_id = null,
        .parent_id = null,
        .total_tokens = null,
        .diffview_before = null,
        .diffview_after = null,
        .image_url = null,
        .tool_name = null,
        .loop_index = @as(u32, 0),
        .temperature = @as(f32, 0.0),
        .is_thinking = false,
        .is_input = false,
        .is_output = false,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    // Compact whitespace (no spaces around `:`) — the SSE channel is parsed
    // on the JS side via `JSON.parse(raw)`, so both indent_4 and compact are
    // wire-valid; compact keeps the wire smaller (we emit one per sub-agent
    try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{ .whitespace = .minified })});

    // Conditional field: append `"subagent_session_id":"<value>",`
    // immediately after the opening `{` if session_id is non-empty.
    if (input.session_id.len > 0) {
        const safe_sid = try helpers.sanitize.sanitizeUtf8(allocator, input.session_id);
        defer allocator.free(safe_sid);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        // buf looks like: {\n "type": "full",\n "role":
        // "subagent_progress",\n Locate the closing `}` of the opening brace
        // chunk.
        try out.append(allocator, '{');
        try out.print(allocator, "\"subagent_session_id\":\"{s}\",", .{safe_sid});

        // Copy everything after the opening `{` (skip byte 0 which is `{`).
        try out.appendSlice(allocator, buf.items[1..]);

        return out.toOwnedSlice(allocator);
    }

    return buf.toOwnedSlice(allocator);
}

/// One-shot emitter used by `runSubAgent` inside
/// tools_exec_spawn_sub_agent.zig.
pub fn emitProgressEvent(input: ProgressEventInput) void {
    emitProgressEventWith(.{ .allocator = null, .logger = null }, input);
}

/// Same as `emitProgressEvent` but lets the caller pass an arena/logger
/// (used by the threading tests + the production call site, which has
/// both handy inside the per-thread arena).
pub fn emitProgressEventWith(
    ctx: struct { allocator: ?std.mem.Allocator = null, logger: ?*loggermod.Logger = null },
    input: ProgressEventInput,
) void {
    // Resolve allocator + logger from ctx or from getSingleton.
    const resolved_alloc: std.mem.Allocator = ctx.allocator orelse blk: {
        const di = tree1_mod.getSingleton() catch return;
        break :blk di.allocator;
    };
    const resolved_logger: ?*loggermod.Logger = ctx.logger orelse blk: {
        const di = tree1_mod.getSingleton() catch return;
        break :blk di.logger;
    };

    var arena = std.heap.ArenaAllocator.init(resolved_alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const data = buildProgressEventJson(aa, input) catch |err| {
        if (resolved_logger) |l| l.warnFmt(
            "subagent_progress: buildProgressEventJson failed: {s}",
            .{@errorName(err)},
        );
        return;
    };

    // Duplicate `data` into a stable buffer the event_bus owns until all
    // listeners have consumed it.
    const data_copy = resolved_alloc.dupe(u8, data) catch |err| {
        if (resolved_logger) |l| l.warnFmt(
            "subagent_progress: dupe failed: {s}",
            .{@errorName(err)},
        );
        return;
    };

    // Push on the central "llm" broadcast channel — the frontend's
    // `bus.on('llm', ...)` listener picks it up alongside regular llm_full
    // events and routes by `role`.
    const di = tree1_mod.getSingleton() catch return;
    const bus = di.event_bus;

    // Mirror the on_event_sent.zig:341-352 dual emit (per-session +
    // central "llm" broadcast). The event_bus API is generic over the
    // SseEvent type from on_event_sent.zig.
    const event = on_event_sent.SseEvent{
        .session_id = input.parent_session_id,
        .data = data_copy,
        .event_type = "llm_full",
    };

    bus.emit(on_event_sent.SseEvent, input.parent_session_id, event);
    bus.emit(on_event_sent.SseEvent, "llm", event);

    // 2026-09-04 refresh fix (task_1788505292766_1): mirror every progress
    // event into the snapshot registry below so a mid-run page refresh can
    // rehydrate via GET /api/subagent/progress.
    upsertSnapshot(input);
}

// =====================================================================
// Snapshot registry (2026-09-04 refresh fix, task_1788505292766_1). Problem:
// progress events are SSE-ephemeral.

/// One row of a spawn batch's live state. Strings are owned by the
/// registry (page_allocator); `getSnapshot` dupes them into the
/// caller's allocator.
pub const SnapshotRow = struct {
    agent_name: []const u8,
    status: ProgressStatus,
    agent_index: usize,
    total_agents: usize,
    subagent_session_id: []const u8,
    elapsed_ms: i64,
};

var snapshot_mutex: std.atomic.Mutex = .unlocked;
var snapshot_registry: ?std.StringHashMap(std.ArrayList(SnapshotRow)) = null;

fn snapshotLock() void {
    while (!snapshot_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn ensureSnapshotInit() void {
    if (snapshot_registry == null) {
        snapshot_registry = std.StringHashMap(std.ArrayList(SnapshotRow)).init(std.heap.page_allocator);
    }
}

/// Mirror one progress event into the snapshot registry. Fire-and-forget: all
/// errors are swallowed — the SSE path already logs build failures; a
/// snapshot miss only costs a refresh rehydrate, never a sub-agent.
pub fn upsertSnapshot(input: ProgressEventInput) void {
    // Empty tool_call_id would collide every batch onto one key
    // (empty-slice-as-NULL rule) — skip, same guard as the
    // frontend clearProgressFor call sites.
    if (input.tool_call_id.len == 0) return;
    snapshotLock();
    defer snapshot_mutex.unlock();
    ensureSnapshotInit();

    const gop = snapshot_registry.?.getOrPut(input.tool_call_id) catch return;
    if (!gop.found_existing) {
        const key = std.heap.page_allocator.dupe(u8, input.tool_call_id) catch return;
        gop.key_ptr.* = key;
        gop.value_ptr.* = .empty;
    }
    const rows = gop.value_ptr;

    // Upsert by agent_index: launched → completed/failed overwrites.
    for (rows.items) |*row| {
        if (row.agent_index == input.agent_index) {
            const new_name = std.heap.page_allocator.dupe(u8, input.agent_name) catch return;
            const new_sid = std.heap.page_allocator.dupe(u8, input.session_id) catch {
                std.heap.page_allocator.free(new_name);
                return;
            };
            std.heap.page_allocator.free(row.agent_name);
            std.heap.page_allocator.free(row.subagent_session_id);
            row.agent_name = new_name;
            row.subagent_session_id = new_sid;
            row.status = input.status;
            row.total_agents = input.total_agents;
            row.elapsed_ms = input.elapsed_ms;
            return;
        }
    }
    const new_name = std.heap.page_allocator.dupe(u8, input.agent_name) catch return;
    const new_sid = std.heap.page_allocator.dupe(u8, input.session_id) catch {
        std.heap.page_allocator.free(new_name);
        return;
    };
    rows.append(std.heap.page_allocator, .{
        .agent_name = new_name,
        .status = input.status,
        .agent_index = input.agent_index,
        .total_agents = input.total_agents,
        .subagent_session_id = new_sid,
        .elapsed_ms = input.elapsed_ms,
    }) catch {
        std.heap.page_allocator.free(new_name);
        std.heap.page_allocator.free(new_sid);
    };
}

/// Drop a batch's snapshot. Idempotent; runs when the final
/// `<results>` envelope is built (the DB row takes over as truth).
pub fn clearSnapshot(tool_call_id: []const u8) void {
    if (tool_call_id.len == 0) return;
    snapshotLock();
    defer snapshot_mutex.unlock();
    if (snapshot_registry) |*reg| {
        if (reg.getPtr(tool_call_id)) |rows_ptr| {
            for (rows_ptr.items) |row| {
                std.heap.page_allocator.free(row.agent_name);
                std.heap.page_allocator.free(row.subagent_session_id);
            }
            rows_ptr.deinit(std.heap.page_allocator);
            // Copy the stored key header BEFORE remove: remove() looks
            // the entry up by comparing keys, so the stored key must
            // still be alive during the call. Free only afterwards.
            const stored_key = reg.getKey(tool_call_id);
            _ = reg.remove(tool_call_id);
            if (stored_key) |k| {
                std.heap.page_allocator.free(k);
            }
        }
    }
}

/// Read a batch's snapshot. Rows + strings are duped into `allocator`
/// (the caller's arena); the registry keeps its own copies. Returns
/// an empty slice when unknown/cleared.
pub fn getSnapshot(allocator: std.mem.Allocator, tool_call_id: []const u8) ![]SnapshotRow {
    snapshotLock();
    defer snapshot_mutex.unlock();
    if (snapshot_registry) |*reg| {
        if (reg.getPtr(tool_call_id)) |rows_ptr| {
            const out = try allocator.alloc(SnapshotRow, rows_ptr.items.len);
            for (rows_ptr.items, 0..) |row, i| {
                out[i] = .{
                    .agent_name = try allocator.dupe(u8, row.agent_name),
                    .status = row.status,
                    .agent_index = row.agent_index,
                    .total_agents = row.total_agents,
                    .subagent_session_id = try allocator.dupe(u8, row.subagent_session_id),
                    .elapsed_ms = row.elapsed_ms,
                };
            }
            return out;
        }
    }
    return try allocator.alloc(SnapshotRow, 0);
}

// =====================================================================
// Inline tests for the wire-shape contract.

const testing = std.testing;

test "buildProgressEventJson: launched includes role, status, names, no subagent_session_id when empty" {
    const allocator = testing.allocator;
    const out = try buildProgressEventJson(allocator, .{
        .parent_session_id = "sess_parent_123",
        .tool_call_id = "toolcall_abc",
        .agent_name = "research-frontend",
        .status = .launched,
        .agent_index = 0,
        .total_agents = 3,
        .session_id = "", // not yet created
        .elapsed_ms = 0,
    });
    defer allocator.free(out);

    // Must carry the new role so the frontend router picks it up.
    try testing.expect(std.mem.indexOf(u8, out, "\"role\":\"subagent_progress\"") != null);
    // Status must be the first-class enum wire value.
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"launched\"") != null);
    // Indices must be present and intact (frontend uses them to key the per-tool map).
    try testing.expect(std.mem.indexOf(u8, out, "\"agent_index\":0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"total_agents\":3") != null);
    // session_id (parent) is the llm channel's routing key.
    try testing.expect(std.mem.indexOf(u8, out, "\"session_id\":\"sess_parent_123\"") != null);
    // tool_call_id keys the per-spawn progression map in ChatView.
    try testing.expect(std.mem.indexOf(u8, out, "\"tool_call_id\":\"toolcall_abc\"") != null);
    // agent_name surfaces the LLM-provided name (frontend row title + peek label).
    try testing.expect(std.mem.indexOf(u8, out, "\"agent_name\":\"research-frontend\"") != null);
    // When sub-agent session_id is "" (not yet created at launched time),
    // the field MUST be omitted entirely — never an empty string. The
    // frontend reducer skips storing subagent_session_id when undefined.
    try testing.expect(std.mem.indexOf(u8, out, "subagent_session_id") == null);
}

test "buildProgressEventJson: completed includes subagent_session_id when set" {
    const allocator = testing.allocator;
    const out = try buildProgressEventJson(allocator, .{
        .parent_session_id = "sess_parent_123",
        .tool_call_id = "toolcall_abc",
        .agent_name = "research-frontend",
        .status = .completed,
        .agent_index = 1,
        .total_agents = 3,
        .session_id = "subagent_1787_research-frontend",
        .elapsed_ms = 12345,
    });
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"subagent_session_id\":\"subagent_1787_research-frontend\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"elapsed_ms\":12345") != null);
}

test "buildProgressEventJson: failed status serialises correctly" {
    const allocator = testing.allocator;
    const out = try buildProgressEventJson(allocator, .{
        .parent_session_id = "sess_parent_456",
        .tool_call_id = "toolcall_xyz",
        .agent_name = "broken-agent",
        .status = .failed,
        .agent_index = 2,
        .total_agents = 3,
        .session_id = "",
        .elapsed_ms = 500,
    });
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"failed\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"agent_index\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "subagent_session_id") == null);
}

test "buildProgressEventJson: sanitises invalid UTF-8 in agent_name" {
    // A raw 0xE4 byte alone is invalid UTF-8 (no continuation bytes) —
    // std.json.fmt would otherwise emit it as a BYTE ARRAY instead of a JSON
    // string (Zig 0.16).
    const allocator = testing.allocator;
    const bad_name = "broken\xE4agent";
    const out = try buildProgressEventJson(allocator, .{
        .parent_session_id = "sess_x",
        .tool_call_id = "toolcall_q",
        .agent_name = bad_name,
        .status = .launched,
        .agent_index = 0,
        .total_agents = 1,
        .session_id = "",
        .elapsed_ms = 0,
    });
    defer allocator.free(out);

    // Must contain the sanitised U+FFFD replacement (EF BF BD UTF-8).
    try testing.expect(std.mem.indexOf(u8, out, "\xEF\xBF\xBD") != null);
    // Must NOT contain the raw invalid 0xE4 byte.
    try testing.expect(std.mem.indexOf(u8, out, "\xE4") == null or
        std.mem.indexOf(u8, out, "\xE4\x80") != null or
        std.mem.indexOf(u8, out, "\xE4\x90") != null); // some valid E4 start OK; raw lone bad byte replaced
}

test "buildProgressEventJson: produces parseable JSON (round-trip)" {
    const allocator = testing.allocator;
    const out = try buildProgressEventJson(allocator, .{
        .parent_session_id = "sess_p",
        .tool_call_id = "tc_1",
        .agent_name = "alpha",
        .status = .completed,
        .agent_index = 0,
        .total_agents = 1,
        .session_id = "subagent_x_alpha",
        .elapsed_ms = 999,
    });
    defer allocator.free(out);

    // Parse with std.json.parseFromSlice — should succeed without errors
    // and yield the same status/agent_index/total_agents values.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("subagent_progress", parsed.value.object.get("role").?.string);
    try testing.expectEqualStrings("completed", parsed.value.object.get("status").?.string);
    try testing.expectEqual(@as(i64, 0), parsed.value.object.get("agent_index").?.integer);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("total_agents").?.integer);
    try testing.expectEqualStrings("subagent_x_alpha", parsed.value.object.get("subagent_session_id").?.string);
    try testing.expectEqual(@as(i64, 999), parsed.value.object.get("elapsed_ms").?.integer);
}

test "buildProgressEventJson: type field stays llm_full wire shape" {
    // Sanity: the wire `type` field must remain `"full"` so the SSE
    // dispatcher treats it as an llm_full payload. Only `role` differs.
    const allocator = testing.allocator;
    const out = try buildProgressEventJson(allocator, .{
        .parent_session_id = "s",
        .tool_call_id = "t",
        .agent_name = "a",
        .status = .launched,
        .agent_index = 0,
        .total_agents = 1,
        .session_id = "",
        .elapsed_ms = 0,
    });
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"type\":\"full\"") != null);
}

test "snapshot upsert + get round-trips rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer clearSnapshot("snap-tc-roundtrip");

    upsertSnapshot(.{
        .parent_session_id = "sess_p",
        .tool_call_id = "snap-tc-roundtrip",
        .agent_name = "agent-a",
        .status = .launched,
        .agent_index = 0,
        .total_agents = 2,
        .session_id = "subagent_1_agent-a",
        .elapsed_ms = 100,
    });
    upsertSnapshot(.{
        .parent_session_id = "sess_p",
        .tool_call_id = "snap-tc-roundtrip",
        .agent_name = "agent-b",
        .status = .launched,
        .agent_index = 1,
        .total_agents = 2,
        .session_id = "",
        .elapsed_ms = 50,
    });

    const rows = try getSnapshot(a, "snap-tc-roundtrip");
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("agent-a", rows[0].agent_name);
    try testing.expectEqual(ProgressStatus.launched, rows[0].status);
    try testing.expectEqualStrings("subagent_1_agent-a", rows[0].subagent_session_id);
    try testing.expectEqual(@as(i64, 100), rows[0].elapsed_ms);
    try testing.expectEqualStrings("agent-b", rows[1].agent_name);
    try testing.expectEqualStrings("", rows[1].subagent_session_id);
}

test "snapshot upsert same index overwrites (launched to completed)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer clearSnapshot("snap-tc-overwrite");

    upsertSnapshot(.{
        .parent_session_id = "sess_p",
        .tool_call_id = "snap-tc-overwrite",
        .agent_name = "agent-a",
        .status = .launched,
        .agent_index = 0,
        .total_agents = 1,
        .session_id = "subagent_1_agent-a",
        .elapsed_ms = 10,
    });
    upsertSnapshot(.{
        .parent_session_id = "sess_p",
        .tool_call_id = "snap-tc-overwrite",
        .agent_name = "agent-a",
        .status = .completed,
        .agent_index = 0,
        .total_agents = 1,
        .session_id = "subagent_1_agent-a",
        .elapsed_ms = 999,
    });

    const rows = try getSnapshot(a, "snap-tc-overwrite");
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(ProgressStatus.completed, rows[0].status);
    try testing.expectEqual(@as(i64, 999), rows[0].elapsed_ms);
}

test "snapshot clear removes batch, get returns empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    upsertSnapshot(.{
        .parent_session_id = "sess_p",
        .tool_call_id = "snap-tc-clear",
        .agent_name = "agent-a",
        .status = .launched,
        .agent_index = 0,
        .total_agents = 1,
        .session_id = "",
        .elapsed_ms = 0,
    });
    clearSnapshot("snap-tc-clear");

    const rows = try getSnapshot(a, "snap-tc-clear");
    try testing.expectEqual(@as(usize, 0), rows.len);

    // Idempotent: clearing twice must not crash.
    clearSnapshot("snap-tc-clear");
}

test "snapshot empty tool_call_id is a no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    upsertSnapshot(.{
        .parent_session_id = "sess_p",
        .tool_call_id = "",
        .agent_name = "agent-a",
        .status = .launched,
        .agent_index = 0,
        .total_agents = 1,
        .session_id = "",
        .elapsed_ms = 0,
    });

    const rows = try getSnapshot(a, "");
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "snapshot batches are isolated by tool_call_id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer clearSnapshot("snap-tc-iso-a");
    defer clearSnapshot("snap-tc-iso-b");

    upsertSnapshot(.{
        .parent_session_id = "sess_p",
        .tool_call_id = "snap-tc-iso-a",
        .agent_name = "AAA",
        .status = .launched,
        .agent_index = 0,
        .total_agents = 1,
        .session_id = "",
        .elapsed_ms = 0,
    });
    upsertSnapshot(.{
        .parent_session_id = "sess_p",
        .tool_call_id = "snap-tc-iso-b",
        .agent_name = "BBB",
        .status = .failed,
        .agent_index = 0,
        .total_agents = 1,
        .session_id = "",
        .elapsed_ms = 5,
    });

    const rows_a = try getSnapshot(a, "snap-tc-iso-a");
    const rows_b = try getSnapshot(a, "snap-tc-iso-b");
    try testing.expectEqualStrings("AAA", rows_a[0].agent_name);
    try testing.expectEqualStrings("BBB", rows_b[0].agent_name);
    try testing.expectEqual(ProgressStatus.failed, rows_b[0].status);
}

// Exec wrapper for the `get_plan` agent tool. `get_plan` declares zero
// required parameters — session_id is implicit (D3) and pulled from
// `ctx.session_id` here.

const std = @import("std");
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const migration = @import("../migrations/migration.zig");

const sqlite = pabrikcore.sqlite;
const update_plan_mod = pabrikcore.update_plan;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const get_plan_mod = pabrikcore.get_plan;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

pub fn execGetPlan(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // No input to parse — the schema declares zero required params.
    // Use `tc.function.arguments` for the envelope's `<parameters>`
    // block verbatim (the LLM is expected to send `{}`).
    const inner = get_plan_mod.executeGetPlan(ctx.allocator, ctx.db, ctx.session_id) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "get_plan", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, "get_plan", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

/// Build a `ToolExecContext` that the exec wrapper can use.
fn makeTestCtx(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .db = db,
        .logger = undefined,
        .session_id = session_id,
        .model = "test-model",
        .cwd = "/tmp",
        .api_key = "test-key",
        .base_url = "http://test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
    };
}

fn fakeToolCall(name: []const u8) agent.ToolCall {
    // get_plan takes no params — `{}` is the canonical empty-args input.
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = name, .arguments = "{}" },
    };
}

// ─── Test 1: absent plan returns wrapped `<empty/>` (D6) ───────────────────

test "execGetPlan: absent plan returns wrapped envelope with empty:true" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db, "sess_no_plan");
    const tc = fakeToolCall("get_plan");

    const result = try execGetPlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    const env_parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env_parsed.deinit();
    const env = env_parsed.value.object;
    try testing.expectEqualStrings("get_plan", env.get("tool").?.string);
    try testing.expect(env.get("success").?.bool);
    try testing.expect(env.get("error").? == .null);

    // The inner payload is the `empty` absent signal — no `plan` field.
    const data = env.get("data").?.object;
    try testing.expect(data.get("empty").?.bool);
    try testing.expect(data.get("plan") == null);
}

// ─── Test 2: present plan returns wrapped plan field ────────────────

test "execGetPlan: present plan returns wrapped envelope with plan field" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed the plan via the pure-fn layer (mirrors production wiring: an
    // earlier update_plan call already populated the row).
    {
        const seed_envelope = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, "sess_with_plan", .{
            .content = "# Goal\n\n- [x] done\n- [ ] pending\n",
        });
        defer alloc.free(seed_envelope);
    }

    const tcx = makeTestCtx(alloc, &ctx.db, "sess_with_plan");
    const tc = fakeToolCall("get_plan");

    const result = try execGetPlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    const env2 = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env2.deinit();
    const env = env2.value.object;
    try testing.expectEqualStrings("get_plan", env.get("tool").?.string);
    try testing.expect(env.get("success").?.bool);
    try testing.expect(env.get("error").? == .null);

    // The inner payload carries the plan body in the `plan` field.
    const data = env.get("data").?.object;
    const plan = data.get("plan").?.string;
    try testing.expect(std.mem.indexOf(u8, plan, "# Goal") != null);
    try testing.expect(std.mem.indexOf(u8, plan, "[x] done") != null);
    try testing.expect(std.mem.indexOf(u8, plan, "[ ] pending") != null);

    // No `empty` marker on the present branch.
    try testing.expect(data.get("empty") == null);
}

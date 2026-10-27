//! Agent-callable tool: `get_plan` — fetch the agent's current task plan for
//! the current session as markdown.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;

// Import the storage layer directly (the `pabrikcore.session_plan`
// alias is wired up in src/root.zig by Task 4; for the pure-fn layer
// we just need the module itself). Same pattern as update_plan.zig.
const session_plan = @import("../../../agentic_loop/session_plan.zig");

/// Input for `get_plan`. Empty struct — no params, session_id is implicit.
pub const GetPlanInput = struct {};

/// Top-level tool definition for the LLM.
pub const get_plan_tool_system_prompt =
    \\## Get Plan Tool — Behavior
    \\Use `get_plan` to read the current session plan.
    \\- No parameters. Use to verify progress before updating, or after compaction to confirm the injected copy.
    \\- Returns `plan` text or `{"empty":true}` if no plan exists.
    \\
;

pub const get_plan_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "get_plan",
        .description =
        \\Fetch the agent's current task plan for this session. Returns the markdown body in the `plan` field, or `{"empty":true}` when no plan has been set yet (lay one out with `update_plan`).
        \\
        \\The plan is also re-injected into your system prompt every iteration, so calling `get_plan` is mostly for explicit verification: before flipping a `- [ ]` to `- [x]`, before your first `update_plan` after a session handoff, or after a compaction to check the injected copy.
        \\
        \\Read it before `update_plan`'s text-replace mode so the `old_text` you pass matches the plan exactly.
        \\
        \\The output is JSON, so the raw `<`, `>`, `&` inside the markdown body are preserved verbatim — the LLM sees its own plan back byte-for-byte.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
        .system_prompt = get_plan_tool_system_prompt,
    },
};

/// Execute get_plan. Returns a JSON string for the LLM. Caller owns the
/// returned slice and must free it with `allocator.free()`.
pub fn executeGetPlan(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) ![]const u8 {
    const helpers = @import("helpers");
    const sanitize = helpers.sanitize_control_chars;

    // session_plan.getPlan returns an allocated copy of the markdown body,
    // or an allocated "" when absent (canonical "no plan" sentinel).
    const plan = try session_plan.getPlan(allocator, db, session_id);
    defer allocator.free(plan);

    if (plan.len == 0) {
        return std.json.Stringify.valueAlloc(allocator, .{ .empty = true }, .{});
    }

    const clean = try sanitize(allocator, plan);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, .{ .plan = clean }, .{});
}

const testing = std.testing;
const migration = @import("../../../migrations/migration.zig");

const update_plan_mod = @import("update_plan.zig");

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn parseTestJson(alloc: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, out, .{});
}

// ─── Test 1: present — returns the plan in the `plan` field ─────────────────

test "executeGetPlan: returns the plan when present, in the plan field" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed a plan via update_plan (the same wire the agent will use).
    const session_id = "test_session_present";
    const seed_result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, session_id, .{
        .content = "# Plan\n- [x] done\n- [ ] pending\n",
    });
    defer alloc.free(seed_result);

    const result = try executeGetPlan(alloc, &ctx.db, session_id);
    defer alloc.free(result);

    // Payload shape: {"plan":"<markdown body>"}.
    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const plan = parsed.value.object.get("plan").?.string;
    // No `empty` marker when present.
    try testing.expect(parsed.value.object.get("empty") == null);

    // Markdown body parts (JSON preserves raw chars verbatim).
    try testing.expect(std.mem.indexOf(u8, plan, "# Plan") != null);
    try testing.expect(std.mem.indexOf(u8, plan, "[x] done") != null);
    try testing.expect(std.mem.indexOf(u8, plan, "[ ] pending") != null);
}

// ─── Test 2: absent — returns <empty/> per D6 ───────────────────────────────

test "executeGetPlan: returns empty:true when no plan exists (D6)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // No prior update_plan call — session has no row in session_plan.
    const result = try executeGetPlan(alloc, &ctx.db, "nonexistent");
    defer alloc.free(result);

    // Payload shape: {"empty":true} — the agent uses the absence
    // signal as a "use update_plan to lay out a plan" cue.
    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("empty").?.bool);
    // No `plan` field when absent.
    try testing.expect(parsed.value.object.get("plan") == null);
}

// ─── Test 3: JSON preserves raw chars verbatim ─────────────────────────────

test "executeGetPlan: JSON preserves raw special chars verbatim (no XML escape)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Write a plan containing `<hello>` and `&` — these MUST survive
    // verbatim in the JSON string (no &lt; / &amp; substitution).
    const session_id = "test_session_escape";
    const seed_result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, session_id, .{
        .content = "Note: <hello> & 'world'",
    });
    defer alloc.free(seed_result);

    const result = try executeGetPlan(alloc, &ctx.db, session_id);
    defer alloc.free(result);

    // Raw `<hello>` and `&` MUST appear in the payload verbatim —
    // that's the point of plain JSON strings for free-form content.
    try testing.expect(std.mem.indexOf(u8, result, "<hello>") != null);
    try testing.expect(std.mem.indexOf(u8, result, " & ") != null);
    // The XML-escaped forms MUST NOT appear.
    try testing.expect(std.mem.indexOf(u8, result, "&lt;hello&gt;") == null);
    try testing.expect(std.mem.indexOf(u8, result, "&amp;") == null);
    // And the parsed field round-trips byte-for-byte.
    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expectEqualStrings("Note: <hello> & 'world'", parsed.value.object.get("plan").?.string);
}

// ─── Test 4: `]]>` inside the body round-trips through JSON
// ───────────────── The literal `]]>` sequence needed CDATA splitting under
// the old XML envelope.

test "executeGetPlan: ]]> inside plan body round-trips verbatim" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const session_id = "test_session_cdata";
    const seed_result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, session_id, .{
        .content = "before ]]> middle ]]> after",
    });
    defer alloc.free(seed_result);

    const result = try executeGetPlan(alloc, &ctx.db, session_id);
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expectEqualStrings("before ]]> middle ]]> after", parsed.value.object.get("plan").?.string);
}

// ─── Test 5: JSON schema shape (name / required / properties) ───────────────

test "get_plan_tool JSON schema: name='get_plan', no required params, no properties" {
    const tool = get_plan_tool;

    // Top-level type must be 'function' (OpenAI conventions).
    try testing.expectEqualStrings("function", tool.type);

    // Function name.
    try testing.expectEqualStrings("get_plan", tool.function.name);

    // Description must mention the tool name AND the <empty/> absent
    // signal — the description is the agent's primary "when to call
    // this" signal.
    const description = tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "get_plan") != null);
    try testing.expect(std.mem.indexOf(u8, description, "empty") != null);

    // Required: empty slice — get_plan needs no input (D3 — session_id
    // is implicit).
    try testing.expectEqual(@as(usize, 0), tool.function.parameters.required.len);

    // Properties: empty slice — no input parameters at all.
    try testing.expectEqual(@as(usize, 0), tool.function.parameters.properties.len);
}

// Exec adapter — merged from `get_plan.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_testing = std.testing;
const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const exec_migration = @import("../../../migrations/migration.zig");
const exec_sqlite = exec_pabrikcore.sqlite;
const database = exec_pabrikcore.database;
const exec_update_plan_mod = exec_pabrikcore.update_plan;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
pub fn execGetPlan(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // No input to parse — the schema declares zero required params.
    // Use `tc.function.arguments` for the envelope's `<parameters>`
    // block verbatim (the LLM is expected to send `{}`).
    const inner = executeGetPlan(ctx.allocator, ctx.db, ctx.session_id) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "get_plan", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, "get_plan", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

const exec_TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn exec_setupDb() !exec_TestCtx {
    const alloc = exec_testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = exec_migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try exec_migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

/// Build a `ToolExecContext` that the exec wrapper can use.
fn makeTestCtx(allocator: std.mem.Allocator, db: *database.Db, session_id: []const u8) ToolExecContext {
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
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db, "sess_no_plan");
    const tc = fakeToolCall("get_plan");

    const result = try execGetPlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try exec_testing.expect(result.output_allocated);
    const env_parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env_parsed.deinit();
    const env = env_parsed.value.object;
    try exec_testing.expectEqualStrings("get_plan", env.get("tool").?.string);
    try exec_testing.expect(env.get("success").?.bool);
    try exec_testing.expect(env.get("error").? == .null);

    // The inner payload is the `empty` absent signal — no `plan` field.
    const data = env.get("data").?.object;
    try exec_testing.expect(data.get("empty").?.bool);
    try exec_testing.expect(data.get("plan") == null);
}

// ─── Test 2: present plan returns wrapped plan field ────────────────

test "execGetPlan: present plan returns wrapped envelope with plan field" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed the plan via the pure-fn layer (mirrors production wiring: an
    // earlier update_plan call already populated the row).
    {
        const seed_envelope = try exec_update_plan_mod.executeUpdatePlan(alloc, &ctx.db, "sess_with_plan", .{
            .content = "# Goal\n\n- [x] done\n- [ ] pending\n",
        });
        defer alloc.free(seed_envelope);
    }

    const tcx = makeTestCtx(alloc, &ctx.db, "sess_with_plan");
    const tc = fakeToolCall("get_plan");

    const result = try execGetPlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try exec_testing.expect(result.output_allocated);
    const env2 = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env2.deinit();
    const env = env2.value.object;
    try exec_testing.expectEqualStrings("get_plan", env.get("tool").?.string);
    try exec_testing.expect(env.get("success").?.bool);
    try exec_testing.expect(env.get("error").? == .null);

    // The inner payload carries the plan body in the `plan` field.
    const data = env.get("data").?.object;
    const plan = data.get("plan").?.string;
    try exec_testing.expect(std.mem.indexOf(u8, plan, "# Goal") != null);
    try exec_testing.expect(std.mem.indexOf(u8, plan, "[x] done") != null);
    try exec_testing.expect(std.mem.indexOf(u8, plan, "[ ] pending") != null);

    // No `empty` marker on the present branch.
    try exec_testing.expect(data.get("empty") == null);
}


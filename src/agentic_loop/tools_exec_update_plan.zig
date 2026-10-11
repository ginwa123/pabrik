// Exec wrapper for the `update_plan` agent tool.
//
// The wrapper parses the JSON arguments emitted by the LLM, threads
// `ctx.session_id` into the pure-fn layer (D3 — session_id is implicit
// in the tool's input schema, never accepted as an argument), and wraps
// the result in the standard `<tool>...</tool>` envelope via
// `wrapToolOutput`.
//
// The inner success JSON (in `data`) carries the just-written plan
// body as the `plan` field so the LLM AND the frontend
// UI see the canonical plan back without depending on `parameters`
// (the agent's input args). Mirrors `executeGetPlan`'s shape.
//
// Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
// Task: task_1787073929852_8 (Task 4 of 9)

const std = @import("std");
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const migration = @import("../migrations/migration.zig");

const sqlite = pabrikcore.sqlite;
const session_plan = @import("session_plan.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const update_plan_mod = pabrikcore.update_plan;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

pub fn execUpdatePlan(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        update_plan_mod.UpdatePlanInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = update_plan_mod.executeUpdatePlan(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the `{"error":...}` shape and surface it as a tool failure
    // (so the LLM sees success=false rather than a successful wrapper
    // around an error body). The inner JSON is still surfaced in `data`
    // so the LLM can see the per-tool detail (e.g. "content must be
    // non-empty (1 byte minimum)").
    //
    // NOTE: parsed-field match, NOT a substring search — the success shape
    // echoes user plan markdown in the `plan` field, so a plan containing
    // the literal text "error" (e.g. "handle <error> case") must NOT
    // false-trigger the error branch.
    var inner_parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch null;
    defer if (inner_parsed) |*par| par.deinit();
    if (inner_parsed) |par| {
        if (par.value == .object) {
            if (par.value.object.get("error")) |e| {
                if (e == .string and e.string.len > 0) {
                    const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, false, e.string, inner);
                    return ToolExecResult{ .output = output, .output_allocated = true };
                }
            }
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, true, null, inner);
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

/// Build a `ToolExecContext` that the exec wrapper can use. The exec
/// wrapper only reads `allocator`, `db`, and `session_id`; the other
/// fields (`logger`, `config`, etc.) are left
/// `undefined` because the wrapper never dereferences them.
fn makeTestCtx(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .db = db,
        .logger = undefined,
        .session_id = "sess_exec",
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

fn fakeToolCall(name: []const u8, args: []const u8) agent.ToolCall {
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = name, .arguments = args },
    };
}

// ─── Test 1: success path ──────────────────────────────────────────────────

test "execUpdatePlan: writes to session_plan and returns wrapped success" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("update_plan", "{\"content\":\"# Plan\\n- [ ] step\"}");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    // The wrapped envelope carries success=true with the inner payload
    // in `data`.
    try testing.expect(result.output_allocated);
    const env_parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env_parsed.deinit();
    const env = env_parsed.value.object;
    try testing.expectEqualStrings("update_plan", env.get("tool").?.string);
    try testing.expect(env.get("success").?.bool);
    try testing.expect(env.get("error").? == .null);
    const data = env.get("data").?.object;
    try testing.expectEqualStrings("sess_exec", data.get("session_id").?.string);
    try testing.expect(data.get("updated_at").?.string.len > 0);

    // The inner payload MUST echo the just-written plan body via the
    // `plan` field — the frontend renders the checklist from this
    // field, NOT from the tool's input arguments.
    try testing.expectEqualStrings("# Plan\n- [ ] step", data.get("plan").?.string);

    // Verify the row landed in session_plan.
    const stored = try session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try testing.expectEqualStrings("# Plan\n- [ ] step", stored);
}

// ─── Test 2: empty content returns wrapped error with success=false ────────

test "execUpdatePlan: empty content returns wrapped error envelope" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("update_plan", "{\"content\":\"\"}");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    // Error path: success=false, `error` message, `data` null.
    // (wrapToolOutput deliberately nulls `data` on the error branch —
    // the inner pure-fn JSON is intentionally not surfaced. The LLM only
    // sees the human-readable error message.)
    const env2 = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env2.deinit();
    try testing.expect(!env2.value.object.get("success").?.bool);
    try testing.expect(std.mem.indexOf(u8, env2.value.object.get("error").?.string, "non-empty") != null);
    try testing.expect(env2.value.object.get("data").? == .null);

    // DB has no row for "sess_exec" — empty content is rejected.
    const stored = try session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try testing.expectEqualStrings("", stored);
}

// ─── Test 3: malformed JSON returns wrapped parse error ─────────────────────

test "execUpdatePlan: malformed JSON returns wrapped parse error" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    // Garbage JSON — not parseable as UpdatePlanInput.
    const tc = fakeToolCall("update_plan", "{not json at all");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    const env3 = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env3.deinit();
    try testing.expect(!env3.value.object.get("success").?.bool);
    // The message must tell the model WHAT was wrong with its JSON, not
    // just name the Zig error. `{not json at all` is a syntax error, so
    // the explanation names JSON and the usual causes.
    const plan_err = env3.value.object.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, plan_err, "JSON") != null);
    try testing.expect(std.mem.indexOf(u8, plan_err, "SyntaxError") == null);

    // No DB write happened.
    const stored = try session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try testing.expectEqualStrings("", stored);
}

// ─── Test 4 (regression): plan mentioning "error" text still succeeds ─────
// The success payload echoes plan markdown in the `plan` field. Error
// detection is a parsed-field match on `{"error":...}`, so plan text like
// "handle <error> case" must NOT false-trigger the error branch.
test "execUpdatePlan: plan containing error-like text does not misfire" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("update_plan", "{\"content\":\"# Plan\\nHandle <error> case\\n- [ ] step\"}");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    const env4 = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env4.deinit();
    try testing.expect(env4.value.object.get("success").?.bool);
    try testing.expectEqualStrings("# Plan\nHandle <error> case\n- [ ] step", env4.value.object.get("data").?.object.get("plan").?.string);

    const stored = try session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try testing.expectEqualStrings("# Plan\nHandle <error> case\n- [ ] step", stored);
}

// ─── Test 5 (regression): plan with error-like JSON text still succeeds ───
// Even when the plan text contains an `"error":...`-looking fragment, the
// payload is a success object without a top-level `error` string field,
// so this must NOT be misclassified as a tool failure.
test "execUpdatePlan: plan containing error-like JSON text still succeeds" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("update_plan", "{\"content\":\"# Plan\\n<error>oops</error>\\n- [ ] step\"}");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    const env5 = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env5.deinit();
    try testing.expect(env5.value.object.get("success").?.bool);
}

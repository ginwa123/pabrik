//! Agent-callable tool: `update_plan` — UPSERT the agent's task plan for the
//! current session as markdown with a `- [ ]` / `- [x]` checklist.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;

const helpers = @import("helpers");
const sanitize = helpers.sanitize_control_chars;

// Import the storage layer directly (the `pabrikcore.session_plan`
// alias is wired up in src/root.zig by Task 4; for the pure-fn layer
// we just need the module itself).
const session_plan = @import("../../../agentic_loop/session_plan.zig");

/// Re-export the storage-layer cap so callers/tests don't have to
/// reach into the storage module. Same value (256 KiB).
pub const MAX_PLAN_BYTES: usize = session_plan.MAX_PLAN_BYTES;

/// Input for `update_plan`.
pub const UpdatePlanInput = struct {
    /// The markdown plan body. 1 byte – 256 KiB. Empty content is rejected
    /// (use a final marker like `# Plan complete` to "close" a plan instead
    /// of calling with empty).
    content: []const u8 = "",
};

/// Top-level tool definition for the LLM.
pub const update_plan_tool_system_prompt =
    \\## Update Plan Tool — Behavior
    \\Use `update_plan` to create or overwrite the session's markdown plan (checklist with `- [ ]` / `- [x]`).
    \\- Call early for multi-step work and after each step to flip the checkbox. The plan is re-injected into your prompt every iteration.
    \\- Content must be 1 byte–256 KiB. Empty content is rejected.
    \\
;

pub const update_plan_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "update_plan",
        .description =
        \\`update_plan` overwrites (UPSERT) this session's structured task plan — plain markdown with a `- [ ]` (todo) / `- [x]` (done) checklist.
        \\
        \\- Lay out your plan BEFORE you start work, then overwrite it after each checklist item, flipping `- [ ]` to `- [x]`.
        \\- The plan is re-injected into your system prompt every iteration, so the next agent (after compaction, restart, or sub-agent handoff) sees the same progress.
        \\- `content` must be 1 byte – 256 KiB; empty content is rejected. Every call overwrites the prior plan (UPSERT) — there is no merge. `session_id` is implicit (the current session).
        \\- To close out a finished plan, call with a final marker like `# Plan complete` — never with empty content.
        \\- To read the current plan, use `get_plan`.
        \\
        \\Format suggestion (adapt freely): `## Goal`, then a `## Steps` checklist of `- [x]` done / `- [ ]` pending items, then optional `## Notes`.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "content",
                    .type = "string",
                    .description = "The full markdown plan body. 1 byte – 256 KiB. Replaces any existing plan. Required.",
                },
            },
            .required = &.{"content"},
        },
        .system_prompt = update_plan_tool_system_prompt,
    },
};

/// Execute update_plan. Returns a JSON string for the LLM. Caller owns the
/// returned slice and must free it with `allocator.free()`.
pub fn executeUpdatePlan(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    input: UpdatePlanInput,
) ![]const u8 {
    const updated_at = session_plan.savePlan(allocator, db, .{
        .session_id = session_id,
        .content = input.content,
    }) catch |err| {
        const msg = switch (err) {
            error.InvalidContent => "content must be non-empty (1 byte minimum)",
            error.ContentTooLarge => "content exceeds the 256 KiB per-plan cap",
            error.InvalidSessionId => "session_id is required (this is a bug — exec adapter should pass ctx.session_id)",
            error.RowNotFoundAfterInsert => "row missing after UPSERT (DB inconsistency)",
            else => @errorName(err),
        };
        return jsonError(allocator, msg);
    };
    defer allocator.free(updated_at);

    return successJSON(allocator, session_id, updated_at, input.content);
}

fn successJSON(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    updated_at: []const u8,
    content: []const u8,
) ![]u8 {
    const clean_sid = try sanitize(allocator, session_id);
    defer allocator.free(clean_sid);
    const clean_ts = try sanitize(allocator, updated_at);
    defer allocator.free(clean_ts);
    const clean_plan = try sanitize(allocator, content);
    defer allocator.free(clean_plan);

    return std.json.Stringify.valueAlloc(allocator, .{
        .session_id = clean_sid,
        .updated_at = clean_ts,
        .plan = clean_plan,
    }, .{});
}

fn jsonError(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const clean = try sanitize(allocator, msg);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

const testing = std.testing;
const migration = @import("../../../migrations/migration.zig");


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

fn parseTestJson(alloc: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, out, .{});
}

// ─── Test 1: success path returns the success payload ──────────────────────

test "executeUpdatePlan: success returns payload with session_id + updated_at + plan" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const session_id = "test_session_success";
    const content = "# My Plan\n\n- [ ] step 1\n- [x] step 2\n";
    const result = try executeUpdatePlan(alloc, &ctx.db, session_id, .{
        .content = content,
    });
    defer alloc.free(result);

    // Payload shape: {"session_id":...,"updated_at":...,"plan":...}.
    // The frontend reads the `plan` field back to render the checklist.
    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings(session_id, obj.get("session_id").?.string);
    try testing.expect(obj.get("updated_at").?.string.len > 0);
    try testing.expectEqualStrings(content, obj.get("plan").?.string);
    // No `error` field on success.
    try testing.expect(obj.get("error") == null);

    // DB read-back — verify the row actually landed with the right content.
    const stored = try session_plan.getPlan(alloc, &ctx.db, session_id);
    defer alloc.free(stored);
    try testing.expectEqualStrings(content, stored);
}

// ─── Test 1b: JSON preserves raw special chars verbatim ───────────────────
// The agent may write `<`, `>`, `&` in their plan markdown (e.g. for
// comparison prose like `arr[i] > 0`).

test "executeUpdatePlan: JSON preserves raw <, >, & inside plan body" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const content = "## Notes\nIf arr[i] > 0 && x < 10, then... & done.";
    const result = try executeUpdatePlan(alloc, &ctx.db, "cd_session", .{
        .content = content,
    });
    defer alloc.free(result);

    // The raw bytes must appear verbatim — NOT escaped to &lt; / &gt; / &amp;.
    try testing.expect(std.mem.indexOf(u8, result, "arr[i] > 0") != null);
    try testing.expect(std.mem.indexOf(u8, result, "x < 10") != null);
    try testing.expect(std.mem.indexOf(u8, result, "&& x") != null);
    // None of the escape substitutions should appear.
    try testing.expect(std.mem.indexOf(u8, result, "&lt;") == null);
    try testing.expect(std.mem.indexOf(u8, result, "&gt;") == null);
    try testing.expect(std.mem.indexOf(u8, result, "&amp;") == null);
    // And the parsed field round-trips byte-for-byte.
    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expectEqualStrings(content, parsed.value.object.get("plan").?.string);
}

// ─── Test 1c: literal "]]>" inside the body round-trips through JSON ─────
// The literal `]]>` sequence needed CDATA splitting under the old XML
// envelope.

test "executeUpdatePlan: ]]> inside plan body round-trips verbatim" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const content = "before ]]> middle ]]> after";
    const result = try executeUpdatePlan(alloc, &ctx.db, "cdata_split_session", .{
        .content = content,
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expectEqualStrings(content, parsed.value.object.get("plan").?.string);
}

// ─── Test 2: empty content is rejected with a "non-empty" error ────────────

test "executeUpdatePlan: empty content returns error payload mentioning 'non-empty'" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try executeUpdatePlan(alloc, &ctx.db, "any_session", .{
        .content = "",
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("error").?.string, "non-empty") != null);
    // No `session_id` or `updated_at` on error.
    try testing.expect(parsed.value.object.get("updated_at") == null);

    // DB has no row for "any_session".
    const stored = try session_plan.getPlan(alloc, &ctx.db, "any_session");
    defer alloc.free(stored);
    try testing.expectEqualStrings("", stored);
}

// ─── Test 3: oversized content is rejected with a "256 KiB" error ──────────

test "executeUpdatePlan: oversized content (> MAX_PLAN_BYTES) returns error payload mentioning '256 KiB'" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Allocate MAX_PLAN_BYTES + 1 byte of garbage.
    const big = try alloc.alloc(u8, MAX_PLAN_BYTES + 1);
    defer alloc.free(big);
    @memset(big, 'x');

    const result = try executeUpdatePlan(alloc, &ctx.db, "big_session", .{
        .content = big,
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    // Exact phrasing is '256 KiB' (per the plan's error mapping).
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("error").?.string, "256 KiB") != null);
}

// ─── Test 4: JSON schema shape (name / required / properties) ──────────────

test "update_plan_tool JSON schema: name='update_plan', required=['content'], properties=[content]" {
    const tool = update_plan_tool;

    // Top-level type must be 'function' (OpenAI conventions).
    try testing.expectEqualStrings("function", tool.type);

    // Function name.
    try testing.expectEqualStrings("update_plan", tool.function.name);

    // Description must mention both the tool name and the checklist pattern
    // — the description is the agent's primary "when to call this" signal.
    const description = tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "update_plan") != null);
    try testing.expect(std.mem.indexOf(u8, description, "checklist") != null);

    // Required: exactly ["content"] — session_id is implicit (D3).
    try testing.expectEqual(@as(usize, 1), tool.function.parameters.required.len);
    try testing.expectEqualStrings("content", tool.function.parameters.required[0]);

    // Properties: exactly one (content) — no session_id parameter.
    try testing.expectEqual(@as(usize, 1), tool.function.parameters.properties.len);
    try testing.expectEqualStrings("content", tool.function.parameters.properties[0].name);
    try testing.expectEqualStrings("string", tool.function.parameters.properties[0].type);
}

// Exec adapter — merged from `update_plan.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_testing = std.testing;
const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const exec_migration = @import("../../../migrations/migration.zig");
const exec_sqlite = exec_pabrikcore.sqlite;
const exec_session_plan = @import("../../../agentic_loop/session_plan.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
pub fn execUpdatePlan(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        UpdatePlanInput,
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

    const inner = executeUpdatePlan(
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

    // Detect the `{"error":...}` shape and surface it as a tool failure (so
    // the LLM sees success=false rather than a successful wrapper around an
    // error body).
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

const exec_TestCtx = struct {
    db: exec_sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn exec_setupDb() !exec_TestCtx {
    const alloc = exec_testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: exec_sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = exec_migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try exec_migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

/// Build a `ToolExecContext` that the exec wrapper can use.
fn makeTestCtx(allocator: std.mem.Allocator, db: *exec_sqlite.SqliteBackend) ToolExecContext {
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
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("update_plan", "{\"content\":\"# Plan\\n- [ ] step\"}");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    // The wrapped envelope carries success=true with the inner payload
    // in `data`.
    try exec_testing.expect(result.output_allocated);
    const env_parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env_parsed.deinit();
    const env = env_parsed.value.object;
    try exec_testing.expectEqualStrings("update_plan", env.get("tool").?.string);
    try exec_testing.expect(env.get("success").?.bool);
    try exec_testing.expect(env.get("error").? == .null);
    const data = env.get("data").?.object;
    try exec_testing.expectEqualStrings("sess_exec", data.get("session_id").?.string);
    try exec_testing.expect(data.get("updated_at").?.string.len > 0);

    // The inner payload MUST echo the just-written plan body via the
    // `plan` field — the frontend renders the checklist from this
    // field, NOT from the tool's input arguments.
    try exec_testing.expectEqualStrings("# Plan\n- [ ] step", data.get("plan").?.string);

    // Verify the row landed in exec_session_plan.
    const stored = try exec_session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try exec_testing.expectEqualStrings("# Plan\n- [ ] step", stored);
}

// ─── Test 2: empty content returns wrapped error with success=false ────────

test "execUpdatePlan: empty content returns wrapped error envelope" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("update_plan", "{\"content\":\"\"}");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try exec_testing.expect(result.output_allocated);
    // Error path: success=false, `error` message, `data` null.
    // (wrapToolOutput deliberately nulls `data` on the error branch — the
    // inner pure-fn JSON is intentionally not surfaced.
    const env2 = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env2.deinit();
    try exec_testing.expect(!env2.value.object.get("success").?.bool);
    try exec_testing.expect(std.mem.indexOf(u8, env2.value.object.get("error").?.string, "non-empty") != null);
    try exec_testing.expect(env2.value.object.get("data").? == .null);

    // DB has no row for "sess_exec" — empty content is rejected.
    const stored = try exec_session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try exec_testing.expectEqualStrings("", stored);
}

// ─── Test 3: malformed JSON returns wrapped parse error ─────────────────────

test "execUpdatePlan: malformed JSON returns wrapped parse error" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    // Garbage JSON — not parseable as UpdatePlanInput.
    const tc = fakeToolCall("update_plan", "{not json at all");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try exec_testing.expect(result.output_allocated);
    const env3 = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env3.deinit();
    try exec_testing.expect(!env3.value.object.get("success").?.bool);
    // The message must tell the model WHAT was wrong with its JSON, not
    // just name the Zig error. `{not json at all` is a syntax error, so
    // the explanation names JSON and the usual causes.
    const plan_err = env3.value.object.get("error").?.string;
    try exec_testing.expect(std.mem.indexOf(u8, plan_err, "JSON") != null);
    try exec_testing.expect(std.mem.indexOf(u8, plan_err, "SyntaxError") == null);

    // No DB write happened.
    const stored = try exec_session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try exec_testing.expectEqualStrings("", stored);
}

// ─── Test 4 (regression): plan mentioning "error" text still succeeds ─────
// The success payload echoes plan markdown in the `plan` field.
test "execUpdatePlan: plan containing error-like text does not misfire" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("update_plan", "{\"content\":\"# Plan\\nHandle <error> case\\n- [ ] step\"}");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try exec_testing.expect(result.output_allocated);
    const env4 = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env4.deinit();
    try exec_testing.expect(env4.value.object.get("success").?.bool);
    try exec_testing.expectEqualStrings("# Plan\nHandle <error> case\n- [ ] step", env4.value.object.get("data").?.object.get("plan").?.string);

    const stored = try exec_session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try exec_testing.expectEqualStrings("# Plan\nHandle <error> case\n- [ ] step", stored);
}

// ─── Test 5 (regression): plan with error-like JSON text still succeeds ───
// Even when the plan text contains an `"error":...`-looking fragment, the
// payload is a success object without a top-level `error` string field, so
test "execUpdatePlan: plan containing error-like JSON text still succeeds" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("update_plan", "{\"content\":\"# Plan\\n<error>oops</error>\\n- [ ] step\"}");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try exec_testing.expect(result.output_allocated);
    const env5 = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env5.deinit();
    try exec_testing.expect(env5.value.object.get("success").?.bool);
}


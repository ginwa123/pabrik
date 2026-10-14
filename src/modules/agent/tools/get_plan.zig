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
    db: *sqlite.SqliteBackend,
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

const get_plan_mod = @import("get_plan.zig");
const update_plan_mod = @import("update_plan.zig");

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

    const result = try get_plan_mod.executeGetPlan(alloc, &ctx.db, session_id);
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
    const result = try get_plan_mod.executeGetPlan(alloc, &ctx.db, "nonexistent");
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

    const result = try get_plan_mod.executeGetPlan(alloc, &ctx.db, session_id);
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

    const result = try get_plan_mod.executeGetPlan(alloc, &ctx.db, session_id);
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expectEqualStrings("before ]]> middle ]]> after", parsed.value.object.get("plan").?.string);
}

// ─── Test 5: JSON schema shape (name / required / properties) ───────────────

test "get_plan_tool JSON schema: name='get_plan', no required params, no properties" {
    const tool = get_plan_mod.get_plan_tool;

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

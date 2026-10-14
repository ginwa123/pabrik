//! Agent-callable tool: `update_plan` — UPSERT the agent's task plan for
//! the current session as markdown with a `- [ ]` / `- [x]` checklist.
//!
//! Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
//! Task: task_1787073929852_8 (Task 2 of 9)
//!
//! Wire shape:
//!   input:  { content: string }
//!   output: {"session_id":...,"updated_at":...,"plan":"...markdown body..."}
//!   or:     {"error":...}
//!
//! The `plan` field carries the just-written content so the LLM AND the
//! frontend UI see the same canonical body back without depending on
//! `parameters` (the agent's input args). Mirrors `get_plan`'s `plan`
//! field exactly so the frontend can reuse the same parser.
//!
//! The actual UPSERT lives in `session_plan.savePlan`. This file is a
//! thin JSON wrapper (mirrors the `memory.zig` save_memory pattern — same
//! success/error shape, sanitized user-trusted content).
//!
//! Design choices:
//!   - `session_id` is NOT in the input (D3 — implicit from
//!     `ToolExecContext.session_id` in the exec adapter). The pure-fn
//!     API takes `session_id` as an explicit parameter so the exec
//!     adapter in Task 4 can wire `ctx.session_id` through.
//!   - Hard cap is 256 KiB (`session_plan.MAX_PLAN_BYTES`) — see D7.
//!   - Empty content is rejected (InvalidContent) — distinguishes
//!     "no plan" (use `get_plan`, see `{"empty":true}`) from "explicitly
//!     clear" (caller should not call update_plan with empty; use a final
//!     marker like `# Plan complete\nAll steps done.` instead).
//!   - Plain JSON strings (vs. CDATA) carry the user's markdown; the LLM
//!     sees its own plan back with only JSON string escaping. Same
//!     trade-off as `get_plan`.

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
    /// The markdown plan body. 1 byte – 256 KiB. Empty content is
    /// rejected (use a final marker like `# Plan complete` to "close"
    /// a plan instead of calling with empty). The plan body is plain
    /// markdown with `- [ ]` for todo items and `- [x]` for done.
    content: []const u8 = "",
};

/// Top-level tool definition for the LLM. The description is the
/// agent's primary signal for WHEN to use this tool — it explicitly
/// tells the agent to overwrite the plan after every checklist item,
/// flipping `- [ ]` to `- [x]`.
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

/// Execute update_plan. Returns a JSON string for the LLM.
///
/// Caller owns the returned slice and must free it with `allocator.free()`.
///
/// `session_id` is passed explicitly (NOT via `ToolExecContext`) so this
/// pure fn is testable in isolation. The exec adapter in Task 4 will pull
/// `session_id` from `ctx.session_id` and forward it here.
///
/// The success payload echoes the just-written `content` as the `plan`
/// field so the LLM AND the frontend UI see the canonical body back.
/// Mirrors `executeGetPlan`'s `plan` field.
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

// ─── Test 1: success path returns the success payload ──────────────────────

test "executeUpdatePlan: success returns payload with session_id + updated_at + plan" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const session_id = "test_session_success";
    const content = "# My Plan\n\n- [ ] step 1\n- [x] step 2\n";
    const result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, session_id, .{
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
//
// The agent may write `<`, `>`, `&` in their plan markdown (e.g. for
// comparison prose like `arr[i] > 0`). JSON string encoding leaves these
// untouched — no escape substitutions that would complicate the LLM's
// regex/checklist matching.

test "executeUpdatePlan: JSON preserves raw <, >, & inside plan body" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const content = "## Notes\nIf arr[i] > 0 && x < 10, then... & done.";
    const result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, "cd_session", .{
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
//
// The literal `]]>` sequence needed CDATA splitting under the old XML
// envelope. JSON strings have no such hazard — the content round-trips
// byte-for-byte with no transformation.

test "executeUpdatePlan: ]]> inside plan body round-trips verbatim" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const content = "before ]]> middle ]]> after";
    const result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, "cdata_split_session", .{
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

    const result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, "any_session", .{
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
    const big = try alloc.alloc(u8, update_plan_mod.MAX_PLAN_BYTES + 1);
    defer alloc.free(big);
    @memset(big, 'x');

    const result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, "big_session", .{
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
    const tool = update_plan_mod.update_plan_tool;

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

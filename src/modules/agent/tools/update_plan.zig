//! Agent-callable tool: `update_plan` — write the agent's task plan for the
//! current session as markdown with a `- [ ]` / `- [x]` checklist. Either a
//! full rewrite (UPSERT) or a text replace of ONE snippet of the current plan.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
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

/// Input for `update_plan`. Two modes, one tool:
/// - FULL REWRITE: `content` carries the COMPLETE plan body (1 byte – 256 KiB).
/// - TEXT REPLACE: `old_text` + `new_text` edit ONE snippet of the plan.
pub const UpdatePlanInput = struct {
    /// The markdown plan body. 1 byte – 256 KiB. Empty content is rejected
    /// (use a final marker like `# Plan complete` to "close" a plan instead
    /// of calling with empty). Empty when the text-replace mode is used.
    content: []const u8 = "",
    /// The exact text to find in the current plan (text-replace mode).
    /// Must match exactly once unless `replace_all` is true.
    old_text: []const u8 = "",
    /// The replacement text (text-replace mode). Empty deletes the match.
    new_text: []const u8 = "",
    /// Replace every occurrence of `old_text` (text-replace mode).
    replace_all: bool = false,
};

/// Top-level tool definition for the LLM.
pub const update_plan_tool_system_prompt =
    \\## Update Plan Tool — Behavior
    \\Use `update_plan` to write the session's markdown plan (checklist with `- [ ]` / `- [x]`). TWO modes:
    \\- FULL REWRITE: pass `content` — the COMPLETE plan body. It REPLACES the whole plan.
    \\- TEXT REPLACE: pass `old_text` + `new_text` — only that text changes, the rest of the plan stays as it is.
    \\- Call early for multi-step work and after each step to flip the checkbox (text-replace mode). The plan is re-injected into your prompt every iteration.
    \\- `content` must be 1 byte–256 KiB. Empty content is rejected.
    \\
;

pub const update_plan_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "update_plan",
        .description =
        \\`update_plan` writes this session's structured task plan — a plain-markdown document with a `- [ ]` (todo) / `- [x]` (done) checklist. It has TWO modes; use ONE per call.
        \\
        \\## Mode 1 — full rewrite (UPSERT): pass `content`
        \\`content` is the COMPLETE plan body. It REPLACES the whole plan — there is no merge or append. Always send the complete plan including all previously completed items, otherwise that progress is lost.
        \\
        \\## Mode 2 — text replace: pass `old_text` + `new_text`
        \\`old_text` is the exact text to find in the CURRENT plan; `new_text` is what replaces it. ONLY that text changes — every other line of the plan stays exactly as it was. `old_text` must match exactly once; when it matches several times the call is refused (add surrounding context, or pass `replace_all: true` to replace them all). `new_text` may be empty to delete the matched text. Read the plan with `get_plan` when you need the exact text.
        \\Use this mode for SMALL changes: flip one checkbox, reword one step, correct one finding, update "Current Focus". A full rewrite of a long plan means resending the whole document, and anything you forget to resend is lost.
        \\
        \\## Why this exists (READ THIS)
        \\The plan is the SOURCE OF TRUTH for this session's progress. It is re-injected into your system prompt on every iteration and survives context compaction, restarts, and sub-agent handoffs. After compaction your conversation history is summarized or dropped, but the plan is kept verbatim. If the plan and your memory of the conversation disagree, TRUST THE PLAN. Write it as if the next reader is an agent with ZERO memory of this conversation who must continue the work using only this document.
        \\
        \\## When to call
        \\1. BEFORE starting any non-trivial work (3+ steps, multiple files, or anything that may outlast one context window): write the full plan first (Mode 1).
        \\2. IMMEDIATELY after finishing each checklist item: flip `- [ ]` to `- [x]` and update "Current Focus" — Mode 2 touches just that line. Do not batch several completions into one update, and do not wait until the end.
        \\3. When you learn something that changes the approach (a discovery, a failed attempt, a changed requirement, a new constraint): record it in the plan right away.
        \\4. Before any long-running or risky operation (large refactor, migration, delegating to a sub-agent): checkpoint the plan first.
        \\5. When the user changes or adds requirements: update the Goal, Constraints, and Steps to match.
        \\Skip the plan only for trivial single-step requests.
        \\
        \\## What a good plan contains
        \\- Goal: what "done" means, in 1-3 sentences, including the user's original intent and acceptance criteria. Quote critical user requirements verbatim.
        \\- Constraints and decisions: user preferences, rules to follow, design choices already made and WHY (so they are not re-litigated after compaction).
        \\- Steps: an ordered checklist. Make each step concrete, verifiable, and specific, naming exact file paths, function names, commands, or endpoints. Avoid vague items like "fix bugs" or "clean up".
        \\- Current Focus / Next Action: the single step being worked on and the exact next concrete action (e.g. "edit src/foo.zig `parseHeader`, then run `zig build test`"). This is the first thing a resumed agent reads.
        \\- Findings and state: facts discovered that you would otherwise lose, such as file locations, root causes, commands that work, values and IDs, what was already tried and failed, and why.
        \\- Blockers and open questions: anything unresolved or needing user input.
        \\- Files touched: paths created, modified, or deleted so far, with a one-line note each.
        \\
        \\## Rules
        \\- Mode 1 is an UPSERT: every call REPLACES the entire plan. There is no merge or append. Always send the COMPLETE plan including all previously completed items, otherwise that progress is lost. Mode 2 edits the named snippet in place and never touches the rest of the plan.
        \\- Never remove or rewrite `- [x]` items; they are the record of what is already done. Keep step order stable and add new steps instead of renumbering.
        \\- If a step turns out to be wrong or unnecessary, keep it and mark it as skipped with the reason (e.g. `- [x] ~~Step~~ (skipped: reason)`) rather than deleting it silently.
        \\- Only mark `- [x]` when the work is actually done and verified (build, tests, or output checked). If it is partially done, keep `- [ ]` and describe the remaining part in Current Focus.
        \\- Keep it dense and factual, with no filler or conversational text. Prefer exact paths, names, and commands over prose. Do not paste large code or logs; reference where they live instead.
        \\- `content` must be 1 byte – 256 KiB; empty content is rejected. `session_id` is implicit (the current session).
        \\- To close out a finished plan, call with a final marker such as `# Plan complete` followed by a short summary of the outcome. Never call with empty content.
        \\- To read the current plan, use `get_plan`. After compaction or a restart, read the injected plan first and resume from "Current Focus" rather than redoing finished steps.
        \\
        \\## Recommended format (adapt freely, but keep these sections)
        \\```
        \\## Goal
        \\<what done means + acceptance criteria>
        \\
        \\## Constraints & Decisions
        \\- <user rule / design decision — why>
        \\
        \\## Steps
        \\- [x] 1. <completed step — result>
        \\- [ ] 2. <pending step — exact files/commands>
        \\- [ ] 3. <pending step>
        \\
        \\## Current Focus
        \\Step 2 — next action: <exact concrete action>
        \\
        \\## Findings & State
        \\- <fact / path / command / failed attempt + reason>
        \\
        \\## Files Touched
        \\- <path> — <what changed>
        \\
        \\## Blockers / Open Questions
        \\- <none | item>
        \\```
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "content",
                    .type = "string",
                    .description = "Mode 1 (full rewrite): the COMPLETE markdown plan body. 1 byte – 256 KiB. It replaces any existing plan, so include all prior completed items, the current focus, constraints, findings and next action. Leave it out when you use the text-replace mode.",
                },
                .{
                    .name = "old_text",
                    .type = "string",
                    .description = "Mode 2 (text replace): the exact text to find in the current plan. Must appear exactly once unless `replace_all` is true. Copy it verbatim from the plan (use `get_plan` to read it).",
                },
                .{
                    .name = "new_text",
                    .type = "string",
                    .description = "Mode 2 (text replace): the replacement text. An empty string deletes the matched text.",
                },
                .{
                    .name = "replace_all",
                    .type = "boolean",
                    .description = "Mode 2 only: when true, replace EVERY occurrence of `old_text`. When false (default), an `old_text` that matches more than once is refused.",
                },
            },
            .required = &.{},
        },
        .system_prompt = update_plan_tool_system_prompt,
    },
};

/// Execute update_plan. Returns a JSON string for the LLM. Caller owns the
/// returned slice and must free it with `allocator.free()`. Two modes:
/// `old_text` set → TEXT REPLACE of one snippet; otherwise → FULL REWRITE.
pub fn executeUpdatePlan(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    input: UpdatePlanInput,
) ![]const u8 {
    if (input.old_text.len > 0) {
        return executeTextReplace(allocator, db, session_id, input);
    }

    if (input.content.len == 0) {
        return jsonError(allocator, "content must be non-empty (1 byte minimum) — pass `content` for a full rewrite, or `old_text` + `new_text` to edit one snippet of the current plan");
    }

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

    return successJSON(allocator, session_id, updated_at, input.content, 0);
}

/// The TEXT REPLACE mode: swap `old_text` for `new_text` inside the CURRENT
/// plan. Every other line of the plan is left exactly as it was.
fn executeTextReplace(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
    input: UpdatePlanInput,
) ![]const u8 {
    const current = session_plan.getPlan(allocator, db, session_id) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "could not read the current plan: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return jsonError(allocator, msg);
    };
    defer allocator.free(current);

    if (current.len == 0) {
        return jsonError(allocator, "this session has no plan yet — write one with `content` first");
    }

    const occurrences = countOccurrences(current, input.old_text);
    if (occurrences == 0) {
        return jsonError(allocator, "old_text was not found in the current plan — read it with get_plan and copy the text exactly");
    }
    if (occurrences > 1 and !input.replace_all) {
        var msg_buf: [160]u8 = undefined;
        const msg = try std.fmt.bufPrint(
            &msg_buf,
            "old_text matches {d} times — include more surrounding context to make it unique, or set replace_all to true",
            .{occurrences},
        );
        return jsonError(allocator, msg);
    }

    const new_plan = try replaceOccurrences(
        allocator,
        current,
        input.old_text,
        input.new_text,
        input.replace_all,
    );
    defer allocator.free(new_plan);

    if (new_plan.len == 0) {
        return jsonError(allocator, "the replacement would empty the plan — a plan must stay non-empty");
    }
    if (new_plan.len > MAX_PLAN_BYTES) {
        return jsonError(allocator, "the replacement would exceed the 256 KiB per-plan cap");
    }

    const updated_at = session_plan.savePlan(allocator, db, .{
        .session_id = session_id,
        .content = new_plan,
    }) catch |err| {
        const msg = switch (err) {
            error.InvalidContent => "the replacement would empty the plan — a plan must stay non-empty",
            error.ContentTooLarge => "the replacement would exceed the 256 KiB per-plan cap",
            error.InvalidSessionId => "session_id is required (this is a bug — exec adapter should pass ctx.session_id)",
            error.RowNotFoundAfterInsert => "row missing after UPSERT (DB inconsistency)",
            else => @errorName(err),
        };
        return jsonError(allocator, msg);
    };
    defer allocator.free(updated_at);

    const replacements: usize = if (input.replace_all) occurrences else 1;
    return successJSON(allocator, session_id, updated_at, new_plan, replacements);
}

/// How many times `needle` appears in `haystack` (non-overlapping).
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, idx, needle)) |pos| {
        count += 1;
        idx = pos + needle.len;
    }
    return count;
}

/// Build the plan body with `needle` replaced by `replacement`. When `all`
/// is false only the FIRST occurrence is replaced.
fn replaceOccurrences(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
    all: bool,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, idx, needle)) |pos| {
        try out.appendSlice(allocator, haystack[idx..pos]);
        try out.appendSlice(allocator, replacement);
        idx = pos + needle.len;
        if (!all) break;
    }
    try out.appendSlice(allocator, haystack[idx..]);

    return out.toOwnedSlice(allocator);
}

fn successJSON(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    updated_at: []const u8,
    content: []const u8,
    replacements: usize,
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
        .replacements = replacements,
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
    try test_db.openMemory(&db, io);

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

test "update_plan_tool JSON schema: the description names BOTH modes" {
    const tool = update_plan_tool;

    // Top-level type must be 'function' (OpenAI conventions).
    try testing.expectEqualStrings("function", tool.type);

    // Function name.
    try testing.expectEqualStrings("update_plan", tool.function.name);

    // The description is the agent's primary "when to call this" signal, and
    // the tool has TWO modes now — the model can only pick the right one if
    // the description names both the full-rewrite and the text-replace half.
    const description = tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "update_plan") != null);
    try testing.expect(std.mem.indexOf(u8, description, "checklist") != null);
    try testing.expect(std.mem.indexOf(u8, description, "content") != null);
    try testing.expect(std.mem.indexOf(u8, description, "old_text") != null);
    try testing.expect(std.mem.indexOf(u8, description, "new_text") != null);
}

// ─── Text-replace mode ────────────────────────────────────────────────────
// Mode 2: `old_text` → `new_text` inside the CURRENT plan. Only the named
// text changes; every other line of the plan stays byte-for-byte.

test "update_plan: the text-replace mode flips one checklist item and leaves the rest of the plan untouched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const original = "## Steps\n- [ ] 1. write the tool\n- [ ] 2. register it\n";
    {
        const ts = try session_plan.savePlan(alloc, &ctx.db, .{
            .session_id = "s_one",
            .content = original,
        });
        defer alloc.free(ts);
    }

    const result = try executeUpdatePlan(alloc, &ctx.db, "s_one", .{
        .old_text = "- [ ] 1. write the tool",
        .new_text = "- [x] 1. write the tool",
    });
    defer alloc.free(result);

    // The stored plan changed ONLY at the matched line.
    const stored = try session_plan.getPlan(alloc, &ctx.db, "s_one");
    defer alloc.free(stored);
    try testing.expectEqualStrings(
        "## Steps\n- [x] 1. write the tool\n- [ ] 2. register it\n",
        stored,
    );

    // The payload echoes the new plan and reports one replacement.
    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings(
        "## Steps\n- [x] 1. write the tool\n- [ ] 2. register it\n",
        obj.get("plan").?.string,
    );
    try testing.expectEqual(@as(i64, 1), obj.get("replacements").?.integer);
    try testing.expect(obj.get("error") == null);
}

test "update_plan: a text-replace whose old_text matches twice is refused and the plan is not touched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const original = "- [ ] step\n- [ ] step\n";
    {
        const ts = try session_plan.savePlan(alloc, &ctx.db, .{
            .session_id = "s_ambiguous",
            .content = original,
        });
        defer alloc.free(ts);
    }

    const result = try executeUpdatePlan(alloc, &ctx.db, "s_ambiguous", .{
        .old_text = "- [ ] step",
        .new_text = "- [x] step",
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, err, "2 times") != null);

    // The plan row is unchanged — an ambiguous edit writes nothing.
    const stored = try session_plan.getPlan(alloc, &ctx.db, "s_ambiguous");
    defer alloc.free(stored);
    try testing.expectEqualStrings(original, stored);
}

test "update_plan: replace_all rewrites every occurrence" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    {
        const ts = try session_plan.savePlan(alloc, &ctx.db, .{
            .session_id = "s_all",
            .content = "- [ ] step\n- [ ] step\n- [ ] other\n",
        });
        defer alloc.free(ts);
    }

    const result = try executeUpdatePlan(alloc, &ctx.db, "s_all", .{
        .old_text = "- [ ] step",
        .new_text = "- [x] step",
        .replace_all = true,
    });
    defer alloc.free(result);

    const stored = try session_plan.getPlan(alloc, &ctx.db, "s_all");
    defer alloc.free(stored);
    try testing.expectEqualStrings("- [x] step\n- [x] step\n- [ ] other\n", stored);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 2), parsed.value.object.get("replacements").?.integer);
}

test "update_plan: a text-replace whose old_text is not in the plan leaves the plan alone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const original = "- [ ] only step\n";
    {
        const ts = try session_plan.savePlan(alloc, &ctx.db, .{
            .session_id = "s_missing",
            .content = original,
        });
        defer alloc.free(ts);
    }

    const result = try executeUpdatePlan(alloc, &ctx.db, "s_missing", .{
        .old_text = "- [ ] a step that never existed",
        .new_text = "- [x] a step that never existed",
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("error").?.string, "not found") != null);

    const stored = try session_plan.getPlan(alloc, &ctx.db, "s_missing");
    defer alloc.free(stored);
    try testing.expectEqualStrings(original, stored);
}

test "update_plan: a text-replace with no plan yet is refused instead of creating one" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try executeUpdatePlan(alloc, &ctx.db, "s_noplan", .{
        .old_text = "- [ ] step",
        .new_text = "- [x] step",
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("error").?.string, "no plan") != null);

    // No row was created.
    const stored = try session_plan.getPlan(alloc, &ctx.db, "s_noplan");
    defer alloc.free(stored);
    try testing.expectEqualStrings("", stored);
}

test "update_plan: a text-replace with an empty new_text deletes the matched text" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    {
        const ts = try session_plan.savePlan(alloc, &ctx.db, .{
            .session_id = "s_delete",
            .content = "## Steps\n- [ ] step\n## Notes\n",
        });
        defer alloc.free(ts);
    }

    const result = try executeUpdatePlan(alloc, &ctx.db, "s_delete", .{
        .old_text = "- [ ] step\n",
        .new_text = "",
    });
    defer alloc.free(result);

    const stored = try session_plan.getPlan(alloc, &ctx.db, "s_delete");
    defer alloc.free(stored);
    try testing.expectEqualStrings("## Steps\n## Notes\n", stored);
}

test "update_plan: a call with neither content nor old_text writes nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try executeUpdatePlan(alloc, &ctx.db, "s_empty_call", .{});
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, err, "non-empty") != null);
    // The message must name BOTH ways to write a plan.
    try testing.expect(std.mem.indexOf(u8, err, "old_text") != null);

    const stored = try session_plan.getPlan(alloc, &ctx.db, "s_empty_call");
    defer alloc.free(stored);
    try testing.expectEqualStrings("", stored);
}

// Exec adapter — merged from `update_plan.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_testing = std.testing;
const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const exec_migration = @import("../../../migrations/migration.zig");
const exec_sqlite = exec_pabrikcore.sqlite;
const database = exec_pabrikcore.database;
const exec_session_plan = @import("../../../agentic_loop/session_plan.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
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
    try test_db.openMemory(&db, io);

    var manager = exec_migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try exec_migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

/// Build a `ToolExecContext` that the exec wrapper can use.
fn makeTestCtx(allocator: std.mem.Allocator, db: *database.Db) ToolExecContext {
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

test "execUpdatePlan: the text-replace mode edits the stored plan and reports success" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    {
        const ts = try exec_session_plan.savePlan(alloc, &ctx.db, .{
            .session_id = "sess_exec",
            .content = "- [ ] step one\n- [ ] step two\n",
        });
        defer alloc.free(ts);
    }

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall(
        "update_plan",
        "{\"old_text\":\"- [ ] step two\",\"new_text\":\"- [x] step two\"}",
    );

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    const env = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env.deinit();
    const obj = env.value.object;
    try exec_testing.expectEqualStrings("update_plan", obj.get("tool").?.string);
    try exec_testing.expect(obj.get("success").?.bool);
    const data = obj.get("data").?.object;
    try exec_testing.expectEqualStrings(
        "- [ ] step one\n- [x] step two\n",
        data.get("plan").?.string,
    );

    const stored = try exec_session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try exec_testing.expectEqualStrings("- [ ] step one\n- [x] step two\n", stored);
}

test "execUpdatePlan: a text-replace that matches nothing comes back as a failed call and writes nothing" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    {
        const ts = try exec_session_plan.savePlan(alloc, &ctx.db, .{
            .session_id = "sess_exec",
            .content = "- [ ] step one\n",
        });
        defer alloc.free(ts);
    }

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall(
        "update_plan",
        "{\"old_text\":\"- [ ] nope\",\"new_text\":\"- [x] nope\"}",
    );

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    const env = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env.deinit();
    const obj = env.value.object;
    try exec_testing.expect(!obj.get("success").?.bool);
    try exec_testing.expect(std.mem.indexOf(u8, obj.get("error").?.string, "not found") != null);
    try exec_testing.expect(obj.get("data").? == .null);

    const stored = try exec_session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try exec_testing.expectEqualStrings("- [ ] step one\n", stored);
}

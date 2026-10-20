//! Agent-callable tool: `update_plan_text_replace` — a surgical EDIT of the
//! session's task plan: it replaces one snippet (`old_text`) with another
//! (`new_text`) and leaves every other line of the plan untouched.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;

const helpers = @import("helpers");
const sanitize = helpers.sanitize_control_chars;

// The storage layer is imported directly (same pattern as `update_plan.zig`)
// so the tool does not depend on the `pabrikcore` alias for it.
const session_plan = @import("../../../agentic_loop/session_plan.zig");

/// Re-export the storage-layer cap so callers/tests don't have to reach into
/// the storage module. Same value (256 KiB).
pub const MAX_PLAN_BYTES: usize = session_plan.MAX_PLAN_BYTES;

/// Input for `update_plan_text_replace`.
pub const UpdatePlanTextReplaceInput = struct {
    /// The exact text to find in the current plan. Must match exactly once
    /// unless `replace_all` is true. Empty is rejected.
    old_text: []const u8 = "",
    /// The replacement text. An empty string deletes the matched text.
    new_text: []const u8 = "",
    /// When true, every occurrence of `old_text` is replaced. When false
    /// (the default) an ambiguous `old_text` is refused instead of
    /// silently editing the wrong line.
    replace_all: bool = false,
};

/// Top-level tool definition for the LLM.
pub const update_plan_text_replace_tool_system_prompt =
    \\## Update Plan Text Replace Tool — Behavior
    \\Use `update_plan_text_replace` for a surgical edit of the session's plan: it replaces
    \\ONE specific snippet (`old_text`) with `new_text` and leaves every other line alone.
    \\Use it instead of `update_plan` when only a small part changes (flip one checkbox,
    \\reword one step, correct one finding) — the rest of the plan cannot be lost.
    \\`old_text` must match the plan EXACTLY once; if it matches more than once, add
    \\surrounding context to make it unique, or pass `replace_all: true` to replace them all.
    \\`get_plan` reads the current plan; `update_plan` still owns full rewrites.
    \\
;

pub const update_plan_text_replace_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "update_plan_text_replace",
        .description =
        \\Edit this session's task plan with a surgical text replacement — `old_text` → `new_text` — instead of rewriting the whole plan.
        \\
        \\Use it when only a SMALL part of the plan changes: flip one checkbox (`- [ ]` → `- [x]`), reword one step, correct one finding, or update "Current Focus". Every line you do not mention stays exactly as it was.
        \\
        \\Prefer this over `update_plan` for small edits: `update_plan` REPLACES the entire plan, so anything you forget to resend is lost. Use `update_plan` for the first plan and for large restructures.
        \\
        \\`old_text` must match the current plan EXACTLY once. If it matches several times, the tool refuses — add surrounding context to make it unique, or set `replace_all: true` to replace all of them.
        \\`new_text` may be an empty string to delete the matched text.
        \\Read the current plan with `get_plan` if you need the exact text to match.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "old_text",
                    .type = "string",
                    .description = "The exact text to replace in the current plan. Must appear exactly once unless `replace_all` is true. Copy it verbatim from the plan (use `get_plan` to read it).",
                },
                .{
                    .name = "new_text",
                    .type = "string",
                    .description = "The replacement text. An empty string deletes the matched text.",
                },
                .{
                    .name = "replace_all",
                    .type = "boolean",
                    .description = "When true, replace EVERY occurrence of `old_text`. When false (default), an `old_text` that matches more than once is refused.",
                },
            },
            .required = &.{ "old_text", "new_text" },
        },
        .system_prompt = update_plan_text_replace_tool_system_prompt,
    },
};

/// Execute update_plan_text_replace. Returns a JSON string for the LLM.
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn executeUpdatePlanTextReplace(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    input: UpdatePlanTextReplaceInput,
) ![]const u8 {
    if (input.old_text.len == 0) {
        return jsonError(allocator, "old_text must not be empty — quote the exact text to replace");
    }

    const current = session_plan.getPlan(allocator, db, session_id) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "could not read the current plan: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return jsonError(allocator, msg);
    };
    defer allocator.free(current);

    if (current.len == 0) {
        return jsonError(allocator, "this session has no plan yet — create one with update_plan first");
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

// ─── Tests ─────────────────────────────────────────────────────────────────
// Behaviour only: what the plan row and the tool payload look like AFTER a
// call. No schema/static assertions, no clock, no sleeps.

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

/// Seed a plan through the same storage the tool writes to.
fn seedPlan(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8, content: []const u8) !void {
    const ts = try session_plan.savePlan(alloc, db, .{ .session_id = session_id, .content = content });
    alloc.free(ts);
}

test "update_plan_text_replace: flips one checklist item and leaves the rest of the plan untouched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const original = "## Steps\n- [ ] 1. write the tool\n- [ ] 2. register it\n";
    try seedPlan(alloc, &ctx.db, "s_one", original);

    const result = try executeUpdatePlanTextReplace(alloc, &ctx.db, "s_one", .{
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

test "update_plan_text_replace: an old_text that matches twice is refused and the plan is not touched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const original = "- [ ] step\n- [ ] step\n";
    try seedPlan(alloc, &ctx.db, "s_ambiguous", original);

    const result = try executeUpdatePlanTextReplace(alloc, &ctx.db, "s_ambiguous", .{
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

test "update_plan_text_replace: replace_all rewrites every occurrence" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedPlan(alloc, &ctx.db, "s_all", "- [ ] step\n- [ ] step\n- [ ] other\n");

    const result = try executeUpdatePlanTextReplace(alloc, &ctx.db, "s_all", .{
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

test "update_plan_text_replace: an old_text that is not in the plan leaves the plan alone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const original = "- [ ] only step\n";
    try seedPlan(alloc, &ctx.db, "s_missing", original);

    const result = try executeUpdatePlanTextReplace(alloc, &ctx.db, "s_missing", .{
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

test "update_plan_text_replace: with no plan yet the tool refuses instead of creating one" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try executeUpdatePlanTextReplace(alloc, &ctx.db, "s_noplan", .{
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

test "update_plan_text_replace: an empty new_text deletes the matched text" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedPlan(alloc, &ctx.db, "s_delete", "## Steps\n- [ ] step\n## Notes\n");

    const result = try executeUpdatePlanTextReplace(alloc, &ctx.db, "s_delete", .{
        .old_text = "- [ ] step\n",
        .new_text = "",
    });
    defer alloc.free(result);

    const stored = try session_plan.getPlan(alloc, &ctx.db, "s_delete");
    defer alloc.free(stored);
    try testing.expectEqualStrings("## Steps\n## Notes\n", stored);
}

// ─── Exec adapter ─────────────────────────────────────────────────────────

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

pub fn execUpdatePlanTextReplace(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        UpdatePlanTextReplaceInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "update_plan_text_replace", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = executeUpdatePlanTextReplace(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "update_plan_text_replace", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // The inner payload carries `{"error": ...}` on failure — surface it as
    // a tool failure (success=false) instead of a successful wrapper around
    // an error body.
    var inner_parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch null;
    defer if (inner_parsed) |*par| par.deinit();
    if (inner_parsed) |par| {
        if (par.value == .object) {
            if (par.value.object.get("error")) |e| {
                if (e == .string and e.string.len > 0) {
                    const output = try wrapToolOutput(ctx.allocator, "update_plan_text_replace", tc.function.arguments, false, e.string, inner);
                    return ToolExecResult{ .output = output, .output_allocated = true };
                }
            }
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "update_plan_text_replace", tc.function.arguments, true, null, inner);
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

test "execUpdatePlanTextReplace: the tool call edits the stored plan and reports success" {
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
        "update_plan_text_replace",
        "{\"old_text\":\"- [ ] step two\",\"new_text\":\"- [x] step two\"}",
    );

    const result = try execUpdatePlanTextReplace(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    const env = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env.deinit();
    const obj = env.value.object;
    try exec_testing.expectEqualStrings("update_plan_text_replace", obj.get("tool").?.string);
    try exec_testing.expect(obj.get("success").?.bool);
    try exec_testing.expect(obj.get("error").? == .null);
    const data = obj.get("data").?.object;
    try exec_testing.expectEqualStrings(
        "- [ ] step one\n- [x] step two\n",
        data.get("plan").?.string,
    );

    const stored = try exec_session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try exec_testing.expectEqualStrings("- [ ] step one\n- [x] step two\n", stored);
}

test "execUpdatePlanTextReplace: a text that is not in the plan comes back as a failed call and writes nothing" {
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
        "update_plan_text_replace",
        "{\"old_text\":\"- [ ] nope\",\"new_text\":\"- [x] nope\"}",
    );

    const result = try execUpdatePlanTextReplace(tcx, tc);
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

test "execUpdatePlanTextReplace: malformed arguments come back as a failed call" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("update_plan_text_replace", "{not json at all");

    const result = try execUpdatePlanTextReplace(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    const env = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env.deinit();
    try exec_testing.expect(!env.value.object.get("success").?.bool);
    try exec_testing.expect(std.mem.indexOf(u8, env.value.object.get("error").?.string, "JSON") != null);
}

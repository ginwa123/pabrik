//! Render the "## Current Plan" markdown block for the LLM's system prompt.
//! Reads the session's `session_plan` row (Migration 076) and emits a fenced
//! markdown block plus the timestamp footer.

const std = @import("std");
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const session_plan = pabrikcore.session_plan;
const migration = @import("../migrations/migration.zig");
const update_plan_mod = @import("../modules/agent/tools/update_plan.zig");

/// Build a "## Current Plan" section for the system prompt.
pub fn makePlanContext(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");

    // 1. Read the plan row (graceful-skip on DB error so the system
    //    prompt never breaks because of a plan lookup failure —
    //    mirrors `makeKanbanContext`'s pattern).
    const row = session_plan.getPlanOpt(allocator, db, session_id) catch |err| {
        std.log.warn("BuildPlanContext: getPlanOpt failed: {}", .{err});
        return allocator.dupe(u8, "");
    };
    defer if (row) |r| r.deinit(allocator);

    const plan_row = row orelse return allocator.dupe(u8, "");

    // 2. Render the markdown block.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\n\n## Current Plan\n\n");
    try out.appendSlice(allocator,
        \\This session has an active task plan. **You MUST keep it in sync** by
        \\calling the `update_plan` tool after every checklist item (flip
        \\`- [ ]` → `- [x]`). The plan is automatically re-injected into your
        \\system prompt on every iteration, so you always see the current state.
        \\
        \\`update_plan` has two modes: `content` rewrites the whole plan, while
        \\`old_text` + `new_text` replace ONE snippet and leave the rest of the plan
        \\untouched. For a small change (flip one checkbox, reword one step) use the
        \\text-replace mode — a full rewrite means resending the whole document.
        \\
    );

    // Wrap the raw plan body in a markdown fence so the agent's parser treats
    // it as a code block rather than as top-level instructions.
    try out.appendSlice(allocator, "```markdown\n");
    try out.appendSlice(allocator, plan_row.plan_md);
    // Ensure the plan body ends with a newline so the closing fence
    // can never fuse with the trailing lines of the plan body.
    if (plan_row.plan_md.len == 0 or plan_row.plan_md[plan_row.plan_md.len - 1] != '\n') {
        try out.appendSlice(allocator, "\n");
    }
    try out.appendSlice(allocator, "```\n");

    if (plan_row.updated_at.len > 0) {
        try out.appendSlice(allocator, "\n_Last updated: ");
        try out.appendSlice(allocator, plan_row.updated_at);
        try out.appendSlice(allocator, "_\n");
    }

    return out.toOwnedSlice(allocator);
}

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

// ─── Test 1: empty plan returns "" (silently omitted from system prompt) ──

test "makePlanContext: empty plan returns empty string (silently omitted)" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // No plan row exists for "no_plan_session" — the helper must
    // gracefully return a 0-byte slice so the caller omits the
    // section from the final system prompt.
    const got = try makePlanContext(allocator, &ctx.db, "no_plan_session");
    defer allocator.free(got);
    try testing.expectEqualStrings("", got);
}

// ─── Test 2: present plan renders a ## Current Plan markdown block ─────────

test "makePlanContext: present plan renders ## Current Plan markdown block" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed a plan via the same fn the LLM tool calls. We discard
    // the returned XML envelope — we just need the row to exist.
    {
        const xml = try update_plan_mod.executeUpdatePlan(allocator, &ctx.db, "s_present", .{
            .content = "# Goal\n\n- [x] first done\n- [ ] second pending\n- [ ] third pending\n",
        });
        defer allocator.free(xml);
    }

    const got = try makePlanContext(allocator, &ctx.db, "s_present");
    defer allocator.free(got);

    // Block header
    try testing.expect(std.mem.indexOf(u8, got, "## Current Plan") != null);

    // The LLM-facing hint that names the tool (`update_plan`) and the
    // "every checklist item" call-to-action.
    try testing.expect(std.mem.indexOf(u8, got, "update_plan") != null);
    try testing.expect(std.mem.indexOf(u8, got, "checklist item") != null);

    // The plan content is wrapped in a ```markdown fence so the
    // agent's parser sees it as code, not as instructions
    try testing.expect(std.mem.indexOf(u8, got, "```markdown\n# Goal") != null);
    try testing.expect(std.mem.indexOf(u8, got, "- [x] first done") != null);
    try testing.expect(std.mem.indexOf(u8, got, "- [ ] second pending") != null);

    // Timestamp footer line (Migration 076 populates CURRENT_TIMESTAMP
    // on every UPSERT).
    try testing.expect(std.mem.indexOf(u8, got, "Last updated:") != null);
}

// ─── Test 3: UPSERT consistency — every read sees the latest version ──────

test "makePlanContext: plan survives DB read across calls (UPSERT consistency)" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Write v1, read
    {
        const xml1 = try update_plan_mod.executeUpdatePlan(allocator, &ctx.db, "s_upsert", .{
            .content = "v1 content",
        });
        defer allocator.free(xml1);
    }
    const got1 = try makePlanContext(allocator, &ctx.db, "s_upsert");
    defer allocator.free(got1);
    try testing.expect(std.mem.indexOf(u8, got1, "v1 content") != null);
    try testing.expect(std.mem.indexOf(u8, got1, "v2 content") == null);

    // Overwrite with v2 (UPSERT — must NOT leave v1 + v2 lying around).
    const test_sleep = @import("test_sleep.zig");
    test_sleep.sleep(1, 0);
    {
        const xml2 = try update_plan_mod.executeUpdatePlan(allocator, &ctx.db, "s_upsert", .{
            .content = "v2 content longer and distinct",
        });
        defer allocator.free(xml2);
    }

    // Read again — must see v2, NOT v1.
    const got2 = try makePlanContext(allocator, &ctx.db, "s_upsert");
    defer allocator.free(got2);
    try testing.expect(std.mem.indexOf(u8, got2, "v2 content longer") != null);
    try testing.expect(std.mem.indexOf(u8, got2, "v1 content") == null);
}

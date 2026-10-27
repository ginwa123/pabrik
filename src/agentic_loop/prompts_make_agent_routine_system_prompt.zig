//! Builds the `## Routine System Prompt` system-prompt section for sessions
//! bound to a routine workspace-item WITH an `agent_routines` row (Migration
//! 081).

const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;
const agent_routine_db = @import("../models/agent_routine.db.zig");

/// Resolve the workspace_item_id for a session. Two paths (in order): 1.
fn resolveWorkspaceItemId(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) ![]u8 {
    var q = db.query(allocator,
        "SELECT workspace_item_id FROM workspace_item_tasks WHERE id = ?",
        &[_][]const u8{session_id},
    ) catch return try allocator.dupe(u8, "");
    defer q.deinit();
    if (q.next() catch null) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    var q2 = db.query(allocator,
        "SELECT workspace_item_id FROM workspace_routines WHERE id = ?",
        &[_][]const u8{session_id},
    ) catch return try allocator.dupe(u8, "");
    defer q2.deinit();
    if (q2.next() catch null) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return try allocator.dupe(u8, "");
}

/// Resolve `workspace_item_id` → is-it-a-configured-routine check.
/// True only when item_type == 'routine' AND an agent_routines row exists.
fn isConfiguredRoutineItem(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
) !bool {
    if (workspace_item_id.len == 0) return false;
    var q = db.query(allocator,
        \\SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'routine'
        \\AND EXISTS (SELECT 1 FROM agent_configs WHERE id = ? AND item_type = 'routine')
    , &[_][]const u8{ workspace_item_id, workspace_item_id }) catch return false;
    defer q.deinit();
    if (q.next() catch null) |row| {
        defer row.deinit(allocator);
        return true;
    }
    return false;
}

/// Build the `## Routine System Prompt` system-prompt section. Returns an
/// owned slice (empty for non-configured-routine sessions). Caller frees.
pub fn makeAgentRoutineSystemPrompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    session_id: []const u8,
) ![]const u8 {
    _ = io; // no file reads — prompt rows are inline content only
    if (session_id.len == 0) return try allocator.dupe(u8, "");

    const workspace_item_id = try resolveWorkspaceItemId(allocator, db, session_id);
    defer allocator.free(workspace_item_id);

    if (!try isConfiguredRoutineItem(allocator, db, workspace_item_id)) {
        return try allocator.dupe(u8, "");
    }

    // Fetch the prompt rows (position DESC — same ordering convention as
    // agent_routine_knowledges).
    const prompts = agent_routine_db.listSystemPrompts(allocator, .{ .db = db }, workspace_item_id) catch
        return try allocator.dupe(u8, "");
    defer {
        for (prompts) |pr| agent_routine_db.freeSystemPromptRow(allocator, pr);
        allocator.free(prompts);
    }

    // Collect rows first so the query is closed before we build output.
    var rows: std.ArrayList(struct {
        title: []const u8,
        content: []const u8,
    }) = .empty;
    defer rows.deinit(allocator);

    for (prompts) |pr| {
        try rows.append(allocator, .{
            .title = pr.title,
            .content = pr.content,
        });
    }
    if (rows.items.len == 0) return try allocator.dupe(u8, "");

    // Build the section.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator,
        \\n## Routine System Prompt
        \\
        \\The following instructions define this routine's persona and behaviour.
        \\Follow them throughout this session; they take precedence over generic
        \\defaults but not over the user's explicit requests.
        \\
        \\
    );

    for (rows.items) |row| {
        // Skip whitespace-only rows — nothing meaningful to inject.
        const trimmed = std.mem.trim(u8, row.content, " \t\r\n");
        if (trimmed.len == 0) continue;

        try out.appendSlice(allocator, "\n### ");
        if (row.title.len > 0) {
            try out.appendSlice(allocator, row.title);
        } else {
            try out.appendSlice(allocator, "Untitled prompt");
        }
        try out.appendSlice(allocator, "\n\n");
        try out.appendSlice(allocator, row.content);
        try out.appendSlice(allocator, "\n");
    }

    // Every row was whitespace-only → emit nothing (matches the
    // "no rows" contract instead of a bare header).
    if (std.mem.indexOf(u8, out.items, "### ") == null) {
        out.deinit(allocator);
        return try allocator.dupe(u8, "");
    }

    return try out.toOwnedSlice(allocator);
}
// ─── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;
// Use a fresh alias for the test section to avoid duplicate-struct-
// member shadowing (file-level `const sqlite` already exists).
const test_sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;
const Migration116 = @import("../migrations/migration.zig").Migration116UnifyAgentConfigTables;

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
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT,
        \\    item_type TEXT,
        \\    name TEXT,
        \\    path TEXT,
        \\    position INTEGER,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    workspace_item_id TEXT,
        \\    created_at DATETIME,
        \\    updated_at DATETIME,
        \\    task_type TEXT DEFAULT 'standard'
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_routines (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL
        \\)
    , &[_][]const u8{});
    try Migration116.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

fn insertWorkspaceItem(ctx: *TestCtx, id: []const u8, item_type: []const u8) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES (?, 'ws_1', ?, 'Test', '/tmp', 0)",
        &[_][]const u8{ id, item_type },
    );
}

fn insertSession(ctx: *TestCtx, session_id: []const u8, workspace_item_id: []const u8) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, created_at, updated_at, task_type) VALUES (?, 'Test Task', ?, datetime('now'), datetime('now'), 'standard')",
        &[_][]const u8{ session_id, workspace_item_id },
    );
}

fn insertRoutine(ctx: *TestCtx, id: []const u8, workspace_item_id: []const u8) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_routines (id, workspace_item_id) VALUES (?, ?)",
        &[_][]const u8{ id, workspace_item_id },
    );
}

fn insertConfig(ctx: *TestCtx, config_id: []const u8, workspace_item_id: []const u8) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type) VALUES (?, ?, 'routine')",
        &[_][]const u8{ config_id, workspace_item_id },
    );
}

fn insertPrompt(ctx: *TestCtx, id: []const u8, routine_id: []const u8, title: []const u8, content: []const u8, position: i64) !void {
    const alloc = testing.allocator;
    const pos_str = try std.fmt.allocPrint(alloc, "{d}", .{position});
    defer alloc.free(pos_str);
    try ctx.db.exec(alloc,
        "INSERT INTO agent_config_system_prompt (id, config_id, title, content, position) VALUES (?, ?, ?, ?, ?)",
        &[_][]const u8{ id, routine_id, title, content, pos_str },
    );
}

test "makeAgentRoutineSystemPrompt: returns empty slice when session_id is empty" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try makeAgentRoutineSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentRoutineSystemPrompt: returns empty slice when session doesn't exist" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try makeAgentRoutineSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "non_existent_session");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentRoutineSystemPrompt: returns empty slice when workspace_item is not a routine" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try makeAgentRoutineSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentRoutineSystemPrompt: returns empty slice when routine has no agent_routines row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "routine");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try makeAgentRoutineSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentRoutineSystemPrompt: returns empty slice when configured but no prompt rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "routine");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try makeAgentRoutineSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentRoutineSystemPrompt: renders ## Routine System Prompt section with row contents" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "routine");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    try insertPrompt(&ctx, "aksp_1", "ws_item_1", "Persona", "You are a routine wrangler.", 0);

    const result = try makeAgentRoutineSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## Routine System Prompt") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### Persona") != null);
    try testing.expect(std.mem.indexOf(u8, result, "You are a routine wrangler.") != null);
}

test "makeAgentRoutineSystemPrompt: respects position DESC ordering" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "routine");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    try insertPrompt(&ctx, "aksp_low", "ws_item_1", "Low", "content_low_marker", 0);
    try insertPrompt(&ctx, "aksp_high", "ws_item_1", "High", "content_high_marker", 100);

    const result = try makeAgentRoutineSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    const high_idx = std.mem.indexOf(u8, result, "content_high_marker") orelse return error.MarkerNotFound;
    const low_idx = std.mem.indexOf(u8, result, "content_low_marker") orelse return error.MarkerNotFound;
    try testing.expect(high_idx < low_idx);
}

test "makeAgentRoutineSystemPrompt: skips rows whose content is whitespace-only" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "routine");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    try insertPrompt(&ctx, "aksp_empty", "ws_item_1", "Empty", "   \n\t  ", 0);

    const result = try makeAgentRoutineSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentRoutineSystemPrompt: resolves routine-fire sessions via workspace_routines" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Fire path: session id IS the routine id (fire.zig sid = routine.id),
    // with NO workspace_item_tasks row.
    try insertWorkspaceItem(&ctx, "ws_item_1", "routine");
    try insertRoutine(&ctx, "ws_item_1", "ws_item_1");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");

    try insertPrompt(&ctx, "arsp_fire", "ws_item_1", "Fire", "fire prompt marker", 0);

    const result = try makeAgentRoutineSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "ws_item_1");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## Routine System Prompt") != null);
    try testing.expect(std.mem.indexOf(u8, result, "fire prompt marker") != null);
}

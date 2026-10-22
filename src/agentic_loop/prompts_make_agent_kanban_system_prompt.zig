//! Builds the `## Kanban System Prompt` system-prompt section for sessions
//! bound to a kanban workspace-item WITH an `agent_kanbans` row (Migration
//! 081).

const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;
const agent_kanban_db = @import("../models/agent_kanban.db.zig");

/// Resolve the workspace_item_id for a session. Returns "" when the
/// session doesn't exist (no workspace_item_tasks row).
fn resolveWorkspaceItemId(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
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
    return try allocator.dupe(u8, "");
}

/// Resolve `workspace_item_id` → is-it-a-configured-kanban check.
/// True only when item_type == 'kanban' AND an agent_kanbans row exists.
fn isConfiguredKanbanItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) !bool {
    if (workspace_item_id.len == 0) return false;
    var q = db.query(allocator,
        \\SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'kanban'
        \\AND EXISTS (SELECT 1 FROM agent_configs WHERE id = ? AND item_type = 'kanban')
    , &[_][]const u8{ workspace_item_id, workspace_item_id }) catch return false;
    defer q.deinit();
    if (q.next() catch null) |row| {
        defer row.deinit(allocator);
        return true;
    }
    return false;
}

/// Build the `## Kanban System Prompt` system-prompt section. Returns an
/// owned slice (empty for non-configured-kanban sessions). Caller frees.
pub fn makeAgentKanbanSystemPrompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    _ = io; // no file reads — prompt rows are inline content only
    if (session_id.len == 0) return try allocator.dupe(u8, "");

    const workspace_item_id = try resolveWorkspaceItemId(allocator, db, session_id);
    defer allocator.free(workspace_item_id);

    if (!try isConfiguredKanbanItem(allocator, db, workspace_item_id)) {
        return try allocator.dupe(u8, "");
    }

    // Fetch the prompt rows (position DESC — same ordering convention as
    // agent_kanban_knowledges).
    const prompts = agent_kanban_db.listSystemPrompts(allocator, .{ .db = db }, workspace_item_id) catch
        return try allocator.dupe(u8, "");
    defer {
        for (prompts) |pr| agent_kanban_db.freeSystemPromptRow(allocator, pr);
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
        \\n## Kanban System Prompt
        \\
        \\The following instructions define this board's persona and behaviour.
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
const Migration116 = @import("../migrations/migration.zig").Migration116UnifyAgentConfigTables;

const TestCtx = struct {
    db: test_sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: test_sqlite.SqliteBackend = .{};
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

fn insertConfig(ctx: *TestCtx, config_id: []const u8, workspace_item_id: []const u8) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type) VALUES (?, ?, 'kanban')",
        &[_][]const u8{ config_id, workspace_item_id },
    );
}

fn insertPrompt(ctx: *TestCtx, id: []const u8, kanban_id: []const u8, title: []const u8, content: []const u8, position: i64) !void {
    const alloc = testing.allocator;
    const pos_str = try std.fmt.allocPrint(alloc, "{d}", .{position});
    defer alloc.free(pos_str);
    try ctx.db.exec(alloc,
        "INSERT INTO agent_config_system_prompt (id, config_id, title, content, position) VALUES (?, ?, ?, ?, ?)",
        &[_][]const u8{ id, kanban_id, title, content, pos_str },
    );
}

test "makeAgentKanbanSystemPrompt: returns empty slice when session_id is empty" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try makeAgentKanbanSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKanbanSystemPrompt: returns empty slice when session doesn't exist" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try makeAgentKanbanSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "non_existent_session");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKanbanSystemPrompt: returns empty slice when workspace_item is not a kanban" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try makeAgentKanbanSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKanbanSystemPrompt: returns empty slice when kanban has no agent_kanbans row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try makeAgentKanbanSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKanbanSystemPrompt: returns empty slice when configured but no prompt rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try makeAgentKanbanSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKanbanSystemPrompt: renders ## Kanban System Prompt section with row contents" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    try insertPrompt(&ctx, "aksp_1", "ws_item_1", "Persona", "You are a board wrangler.", 0);

    const result = try makeAgentKanbanSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## Kanban System Prompt") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### Persona") != null);
    try testing.expect(std.mem.indexOf(u8, result, "You are a board wrangler.") != null);
}

test "makeAgentKanbanSystemPrompt: respects position DESC ordering" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    try insertPrompt(&ctx, "aksp_low", "ws_item_1", "Low", "content_low_marker", 0);
    try insertPrompt(&ctx, "aksp_high", "ws_item_1", "High", "content_high_marker", 100);

    const result = try makeAgentKanbanSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    const high_idx = std.mem.indexOf(u8, result, "content_high_marker") orelse return error.MarkerNotFound;
    const low_idx = std.mem.indexOf(u8, result, "content_low_marker") orelse return error.MarkerNotFound;
    try testing.expect(high_idx < low_idx);
}

test "makeAgentKanbanSystemPrompt: skips rows whose content is whitespace-only" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    try insertPrompt(&ctx, "aksp_empty", "ws_item_1", "Empty", "   \n\t  ", 0);

    const result = try makeAgentKanbanSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

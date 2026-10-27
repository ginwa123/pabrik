//! Builds the `## Agent System Prompt` system-prompt section for sessions
//! bound to an Agent workspace-item.

const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;
const agent_db = @import("../models/agent.db.zig");

/// Resolve the workspace_item_id for a session. Returns "" when the
/// session doesn't exist (no workspace_item_tasks row).
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
    return try allocator.dupe(u8, "");
}

/// Resolve `workspace_item_id` → is-it-an-agent check. Returns false when
/// the workspace_item doesn't exist OR isn't an agent.
fn isAgentItem(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
) !bool {
    if (workspace_item_id.len == 0) return false;
    var q = db.query(allocator,
        "SELECT item_type FROM workspace_items WHERE id = ?",
        &[_][]const u8{workspace_item_id},
    ) catch return false;
    defer q.deinit();
    if (q.next() catch null) |row| {
        defer row.deinit(allocator);
        return std.mem.eql(u8, row.values[0], "agent");
    }
    return false;
}

/// Build the `## Agent System Prompt` system-prompt section. Returns an
/// owned slice (empty for non-agent sessions). Caller frees.
pub fn makeAgentSystemPrompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    session_id: []const u8,
) ![]const u8 {
    _ = io; // no file reads — prompt rows are inline content only
    if (session_id.len == 0) return try allocator.dupe(u8, "");

    const workspace_item_id = try resolveWorkspaceItemId(allocator, db, session_id);
    defer allocator.free(workspace_item_id);

    if (!try isAgentItem(allocator, db, workspace_item_id)) {
        return try allocator.dupe(u8, "");
    }

    // Fetch the prompt rows (position DESC — same ordering convention as
    // agent_knowledge).
    const prompts = agent_db.listSystemPrompts(allocator, .{ .db = db }, workspace_item_id) catch
        return try allocator.dupe(u8, "");
    defer {
        for (prompts) |pr| agent_db.freeSystemPromptRow(allocator, pr);
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
        \\n## Agent System Prompt
        \\
        \\The following instructions define this Agent's persona and behaviour.
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
    // "no rows" contract instead of a bare header). Free the partial
    // buffer before returning the empty slice.
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
    try Migration116.up(&db, alloc);
    // mirror that, or the agent_system_prompt table (Migration 080) is
    // missing and prompt-row INSERTs fail.
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

fn insertPrompt(ctx: *TestCtx, id: []const u8, agent_id: []const u8, title: []const u8, content: []const u8, position: i64) !void {
    const alloc = testing.allocator;
    const pos_str = try std.fmt.allocPrint(alloc, "{d}", .{position});
    defer alloc.free(pos_str);
    try ctx.db.exec(alloc,
        "INSERT INTO agent_config_system_prompt (id, config_id, title, content, position) VALUES (?, ?, ?, ?, ?)",
        &[_][]const u8{ id, agent_id, title, content, pos_str },
    );
}

test "makeAgentSystemPrompt: returns empty slice when session_id is empty" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try makeAgentSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentSystemPrompt: returns empty slice when session doesn't exist" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try makeAgentSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "non_existent_session");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentSystemPrompt: returns empty slice when workspace_item is not an agent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try makeAgentSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentSystemPrompt: returns empty slice when agent has no prompt rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try makeAgentSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentSystemPrompt: returns ## Agent System Prompt section with row contents" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    try insertPrompt(&ctx, "asp_1", "ws_item_1", "Persona", "You are a pirate captain.", 0);

    const result = try makeAgentSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## Agent System Prompt") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### Persona") != null);
    try testing.expect(std.mem.indexOf(u8, result, "You are a pirate captain.") != null);
}

test "makeAgentSystemPrompt: respects position DESC ordering" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    try insertPrompt(&ctx, "asp_low", "ws_item_1", "Low", "content_low_marker", 0);
    try insertPrompt(&ctx, "asp_high", "ws_item_1", "High", "content_high_marker", 100);

    const result = try makeAgentSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    const high_idx = std.mem.indexOf(u8, result, "content_high_marker") orelse return error.MarkerNotFound;
    const low_idx = std.mem.indexOf(u8, result, "content_low_marker") orelse return error.MarkerNotFound;
    try testing.expect(high_idx < low_idx);
}

test "makeAgentSystemPrompt: skips rows whose content is whitespace-only" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    try insertPrompt(&ctx, "asp_empty", "ws_item_1", "Empty", "   \n\t  ", 0);

    const result = try makeAgentSystemPrompt(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

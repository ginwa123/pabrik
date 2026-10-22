//! Builds the `## Kanban Knowledge` system-prompt section for sessions bound
//! to a kanban workspace-item WITH an `agent_kanbans` row (Migration 081).

const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;
const agent_kanban_db = @import("../models/agent_kanban.db.zig");

/// 100 MiB per-file OOM safety. NOT a content budget — purely to prevent
/// the server from OOM-ing on a misconfigured path like `/dev/zero`.
pub const MAX_FILE_BYTES_OOM_SAFETY: usize = 100 * 1024 * 1024;

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

/// Read a single file's full contents. Caller owns the returned slice.
/// Returns `null` (logged + skipped by caller) on failure.
fn readFileContents(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !?[]u8 {
    if (file_path.len == 0 or !std.fs.path.isAbsolute(file_path)) {
        std.log.info("makeAgentKanbanKnowledge: skipping knowledge entry with a non-absolute file_path: {s}", .{file_path});
        return null;
    }

    const contents = std.Io.Dir.cwd().readFileAlloc(
        io,
        file_path,
        allocator,
        std.Io.Limit.limited(MAX_FILE_BYTES_OOM_SAFETY),
    ) catch |err| {
        std.log.info("makeAgentKanbanKnowledge: failed to read {s}: {}", .{ file_path, err });
        return null;
    };
    return contents;
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

/// Build the `## Kanban Knowledge` system-prompt section. Returns an
/// owned slice (empty for non-configured-kanban sessions). Caller frees.
pub fn makeAgentKanbanKnowledge(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return try allocator.dupe(u8, "");

    const workspace_item_id = try resolveWorkspaceItemId(allocator, db, session_id);
    defer allocator.free(workspace_item_id);

    if (!try isConfiguredKanbanItem(allocator, db, workspace_item_id)) {
        return try allocator.dupe(u8, "");
    }

    // Fetch the knowledge rows (spec D3: kanban_id == workspace_item_id).
    const knowledge = agent_kanban_db.listKnowledge(allocator, .{ .db = db }, workspace_item_id) catch
        return try allocator.dupe(u8, "");
    defer {
        for (knowledge) |k| agent_kanban_db.freeKnowledgeRow(allocator, k);
        allocator.free(knowledge);
    }

    // Collect rows first so the query is closed before we read files.
    var rows: std.ArrayList(struct {
        file_path: []const u8,
        label: []const u8,
        content: []const u8,
    }) = .empty;
    defer rows.deinit(allocator);

    for (knowledge) |k| {
        try rows.append(allocator, .{
            .file_path = k.file_path,
            .label = k.label,
            .content = k.content,
        });
    }
    if (rows.items.len == 0) return try allocator.dupe(u8, "");

    // Build the section.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator,
        \\n## Kanban Knowledge
        \\
        \\The following markdown files are part of this board's knowledge. Treat
        \\them as authoritative reference for any user question that touches
        \\their topics; do not invent details that contradict them.
        \\
        \\
    );

    for (rows.items) |row| {
        // Inline text entry — no <file: ...> marker.
        if (row.content.len > 0) {
            try out.appendSlice(allocator, "\n### ");
            if (row.label.len > 0) {
                try out.appendSlice(allocator, row.label);
            } else {
                try out.appendSlice(allocator, "Inline knowledge");
            }
            try out.appendSlice(allocator, "\n\n");
            try out.appendSlice(allocator, row.content);
            try out.appendSlice(allocator, "\n");
            continue;
        }

        // File-backed entry — read FIRST so an unreadable file is
        // skipped without leaking its header into the section.
        const contents = readFileContents(io, allocator, row.file_path) catch continue;
        const owned = contents orelse continue;
        defer allocator.free(owned);

        try out.appendSlice(allocator, "\n### ");
        if (row.label.len > 0) {
            try out.appendSlice(allocator, row.label);
        } else {
            try out.appendSlice(allocator, std.fs.path.basename(row.file_path));
        }
        try out.appendSlice(allocator, "\n<file: ");
        try out.appendSlice(allocator, row.file_path);
        try out.appendSlice(allocator, ">\n\n");
        try out.appendSlice(allocator, owned);
        try out.appendSlice(allocator, "\n");
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

var test_file_counter: std.atomic.Value(u64) = .init(0);

/// Writes `contents` to a uniquely-named file inside `tmp` and returns its
/// ABSOLUTE path (caller-owned: `alloc.free` it).
fn writeTestFile(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator, io: std.Io, contents: []const u8) ![]u8 {
    const n = test_file_counter.fetchAdd(1, .seq_cst);
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "test_agent_kanban_knowledge_{d}.md", .{n});
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = contents });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    return std.fs.path.join(allocator, &.{ dir_buf[0..dir_len], name });
}

test "makeAgentKanbanKnowledge: returns empty slice when session_id is empty" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try makeAgentKanbanKnowledge(alloc, ctx.threaded.io(), &ctx.db, "");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKanbanKnowledge: returns empty slice when session doesn't exist" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try makeAgentKanbanKnowledge(alloc, ctx.threaded.io(), &ctx.db, "non_existent_session");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKanbanKnowledge: returns empty slice when workspace_item is not a kanban" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try makeAgentKanbanKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKanbanKnowledge: returns empty slice when kanban has no agent_kanbans row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try makeAgentKanbanKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKanbanKnowledge: returns empty slice when configured but no knowledge rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try makeAgentKanbanKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKanbanKnowledge: renders ## Kanban Knowledge section with file contents" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try writeTestFile(&tmp, alloc, ctx.threaded.io(), "# Board Knowledge\n\nThis file contains board instructions.\n");
    defer alloc.free(tmp_path);

    try ctx.db.exec(alloc,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, position) VALUES ('kn_1', 'ws_item_1', ?, '', 0)",
        &[_][]const u8{tmp_path},
    );

    const result = try makeAgentKanbanKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## Kanban Knowledge") != null);
    try testing.expect(std.mem.indexOf(u8, result, "# Board Knowledge") != null);
    try testing.expect(std.mem.indexOf(u8, result, "board instructions") != null);
}

test "makeAgentKanbanKnowledge: respects position DESC ordering" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_low = try writeTestFile(&tmp, alloc, ctx.threaded.io(), "content_low_marker\n");
    defer alloc.free(path_low);
    const path_high = try writeTestFile(&tmp, alloc, ctx.threaded.io(), "content_high_marker\n");
    defer alloc.free(path_high);

    try ctx.db.exec(alloc,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, position) VALUES ('kn_low', 'ws_item_1', ?, '', 0)",
        &[_][]const u8{path_low},
    );
    try ctx.db.exec(alloc,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, position) VALUES ('kn_high', 'ws_item_1', ?, '', 100)",
        &[_][]const u8{path_high},
    );

    const result = try makeAgentKanbanKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    const high_idx = std.mem.indexOf(u8, result, "content_high_marker") orelse return error.MarkerNotFound;
    const low_idx = std.mem.indexOf(u8, result, "content_low_marker") orelse return error.MarkerNotFound;
    try testing.expect(high_idx < low_idx);
}

test "makeAgentKanbanKnowledge: skips unreadable file paths without leaking header" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    try ctx.db.exec(alloc,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, position) VALUES ('kn_bad', 'ws_item_1', '/tmp/non_existent_kanban_xyz_12345.md', '', 0)",
        &[_][]const u8{},
    );

    const result = try makeAgentKanbanKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## Kanban Knowledge") != null);
    try testing.expect(std.mem.indexOf(u8, result, "non_existent_kanban_xyz_12345") == null);
}

test "makeAgentKanbanKnowledge: inlines content rows without <file:> marker" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    try ctx.db.exec(alloc,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, content, position) VALUES ('kn_inline', 'ws_item_1', '', 'Board rules', 'Always keep the todo column under 10 cards.', 0)",
        &[_][]const u8{},
    );

    const result = try makeAgentKanbanKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## Kanban Knowledge") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### Board rules") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Always keep the todo column under 10 cards.") != null);
    // Inline rows must NOT carry a <file: ...> marker.
    try testing.expect(std.mem.indexOf(u8, result, "<file: ") == null);
}

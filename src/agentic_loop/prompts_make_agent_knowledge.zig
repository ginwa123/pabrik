//! Builds the `## Agent Knowledge` system-prompt section for sessions bound
//! to an Agent workspace-item.

const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;
const agent_db = @import("../models/agent.db.zig");

/// 100 MiB per-file OOM safety. NOT a content budget — the user
/// explicitly removed the content cap. This is purely to prevent the
/// server from OOM-ing on a misconfigured path like `/dev/zero`.
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
        std.log.info("makeAgentKnowledge: skipping knowledge entry with a non-absolute file_path: {s}", .{file_path});
        return null;
    }

    const contents = std.Io.Dir.cwd().readFileAlloc(
        io,
        file_path,
        allocator,
        std.Io.Limit.limited(MAX_FILE_BYTES_OOM_SAFETY),
    ) catch |err| {
        std.log.info("makeAgentKnowledge: failed to read {s}: {}", .{ file_path, err });
        return null;
    };
    return contents;
}

/// Resolve `workspace_item_id` → `agent_id` (= workspace_item_id per
/// spec D3). Returns empty slice when the workspace_item doesn't exist
/// OR isn't an agent.
fn isAgentItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
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

/// Build the `## Agent Knowledge` system-prompt section. Returns an
/// owned slice (empty for non-agent sessions). Caller frees.
pub fn makeAgentKnowledge(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return try allocator.dupe(u8, "");

    const workspace_item_id = try resolveWorkspaceItemId(allocator, db, session_id);
    defer allocator.free(workspace_item_id);

    if (!try isAgentItem(allocator, db, workspace_item_id)) {
        return try allocator.dupe(u8, "");
    }

    // Fetch the knowledge rows (position DESC).
    const knowledge = agent_db.listKnowledge(allocator, .{ .db = db }, workspace_item_id) catch
        return try allocator.dupe(u8, "");
    defer {
        for (knowledge) |k| agent_db.freeKnowledgeRow(allocator, k);
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
        \\n## Agent Knowledge
        \\
        \\The following markdown files are part of this Agent's knowledge. Treat
        \\them as authoritative reference for any user question that touches
        \\their topics; do not invent details that contradict them.
        \\
        \\
    );

    for (rows.items) |row| {
        // Inline text entry — no <file: ...> marker (the path is empty
        // and the marker would be meaningless to the model).
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

        // File-backed entry — existing read-from-disk path. Read FIRST
        // so an unreadable file is skipped without leaking its header
        // into the section (pre-existing test contract).
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
    // mirror that, or the `content` column (Migration 079) is missing
    // and content-row INSERTs fail.
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

fn insertKnowledge(ctx: *TestCtx, id: []const u8, agent_id: []const u8, file_path: []const u8, position: i64) !void {
    const alloc = testing.allocator;
    var sql_buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrint(
        &sql_buf,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, position) VALUES ('{s}', '{s}', '{s}', {d})",
        .{ id, agent_id, file_path, position },
    );
    try ctx.db.exec(alloc, sql, &[_][]const u8{});
}

var test_file_counter: std.atomic.Value(u64) = .init(0);

/// Writes `contents` to a uniquely-named file inside `tmp` and returns its
/// ABSOLUTE path (caller-owned: `alloc.free` it).
fn writeTestFile(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator, io: std.Io, contents: []const u8) ![]u8 {
    const n = test_file_counter.fetchAdd(1, .seq_cst);
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "test_agent_knowledge_{d}.md", .{n});
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = contents });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    return std.fs.path.join(allocator, &.{ dir_buf[0..dir_len], name });
}

test "makeAgentKnowledge: returns empty slice when session_id is empty" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKnowledge: returns empty slice when session doesn't exist" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "non_existent_session");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKnowledge: returns empty slice when workspace_item is not an agent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKnowledge: returns empty slice when agent has no knowledge rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    const result = try makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "makeAgentKnowledge: returns ## Agent Knowledge section with file contents for valid entries" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try writeTestFile(&tmp, alloc, ctx.threaded.io(), "# Test Knowledge\n\nThis file contains agent instructions.\n");
    defer alloc.free(tmp_path);

    try insertKnowledge(&ctx, "know_1", "ws_item_1", tmp_path, 0);

    const result = try makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## Agent Knowledge") != null);
    try testing.expect(std.mem.indexOf(u8, result, "# Test Knowledge") != null);
    try testing.expect(std.mem.indexOf(u8, result, "agent instructions") != null);
}

test "makeAgentKnowledge: respects position DESC ordering" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_low = try writeTestFile(&tmp, alloc, ctx.threaded.io(), "content_low_marker\n");
    defer alloc.free(path_low);
    const path_high = try writeTestFile(&tmp, alloc, ctx.threaded.io(), "content_high_marker\n");
    defer alloc.free(path_high);

    try insertKnowledge(&ctx, "know_low", "ws_item_1", path_low, 0);
    try insertKnowledge(&ctx, "know_high", "ws_item_1", path_high, 100);

    const result = try makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    const high_idx = std.mem.indexOf(u8, result, "content_high_marker") orelse return error.MarkerNotFound;
    const low_idx = std.mem.indexOf(u8, result, "content_low_marker") orelse return error.MarkerNotFound;
    try testing.expect(high_idx < low_idx);
}

test "makeAgentKnowledge: skips empty/relative file paths instead of aborting" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    // Two reachable bad states, both of which used to reach
    // `openFileAbsolute`'s `assert(path.isAbsolute(...))` — an ABORT of the
    // whole process (Debug/ReleaseSafe) — on EVERY turn, because this runs
    try insertKnowledge(&ctx, "know_empty", "ws_item_1", "", 0);
    try insertKnowledge(&ctx, "know_relative", "ws_item_1", "relative/knowledge.md", 1);

    const result = try makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    // No abort — and neither unusable entry leaks a (missing) body into the prompt.
    try testing.expect(std.mem.indexOf(u8, result, "## Agent Knowledge") != null);
    try testing.expect(std.mem.indexOf(u8, result, "relative/knowledge.md") == null);
}

test "makeAgentKnowledge: skips unreadable file paths with logged warning" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    try insertKnowledge(&ctx, "know_1", "ws_item_1", "/tmp/non_existent_path_xyz_12345.md", 0);

    const result = try makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## Agent Knowledge") != null);
    try testing.expect(std.mem.indexOf(u8, result, "non_existent_path_xyz_12345") == null);
}

// ─── content (manual text) tests — plan 2026-08-21-agent-knowledge-manual-text ──

test "makeAgentKnowledge: inlines content rows without <file:> marker" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    // Insert an inline-content row directly (content non-empty, path
    // empty). Parameter binding via db.exec argv (NOT bufPrint) so the
    // text can contain quotes safely.
    try ctx.db.exec(alloc,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, content, position) VALUES ('know_inline', 'ws_item_1', '', 'Deploy notes', 'Always deploy with the canary flag enabled.', 0)",
        &[_][]const u8{},
    );

    const result = try makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "## Agent Knowledge") != null);
    try testing.expect(std.mem.indexOf(u8, result, "### Deploy notes") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Always deploy with the canary flag enabled.") != null);
    // Inline rows must NOT carry a <file: ...> marker.
    try testing.expect(std.mem.indexOf(u8, result, "<file: ") == null);
}

test "makeAgentKnowledge: mixed file + content rows both render" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "agent");
    try insertSession(&ctx, "sess_1", "ws_item_1");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try writeTestFile(&tmp, alloc, ctx.threaded.io(), "file marker content\n");
    defer alloc.free(tmp_path);

    try insertKnowledge(&ctx, "know_file", "ws_item_1", tmp_path, 0);
    try ctx.db.exec(alloc,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, content, position) VALUES ('know_inline', 'ws_item_1', '', 'Notes', 'inline marker content', 1)",
        &[_][]const u8{},
    );

    const result = try makeAgentKnowledge(alloc, ctx.threaded.io(), &ctx.db, "sess_1");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "file marker content") != null);
    try testing.expect(std.mem.indexOf(u8, result, "inline marker content") != null);
}

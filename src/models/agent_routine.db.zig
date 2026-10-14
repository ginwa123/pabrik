//! SQL layer for the `agent_routines` entity family. Every statement that
//! touches `agent_routines`, `agent_routine_knowledges`,
//! `agent_routine_tools` or `agent_routine_system_prompt` lives here.

const std = @import("std");
const database = @import("databases").database;
const helpers = @import("helpers");

pub const DbOrTx = database.DbOrTx;
pub const Error = database.Error;

// ─── Row types ─────────────────────────────────────────────────────────

/// A row of `agent_routines` — the config row for a kanban item.
pub const AgentRoutineRow = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    description: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// A row of `agent_routine_knowledges`.
pub const KnowledgeRow = struct {
    id: []const u8,
    routine_id: []const u8,
    file_path: []const u8,
    label: []const u8,
    /// Inline manual text ('' = file-backed row).
    content: []const u8,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

/// A row of `agent_routine_tools`.
pub const ToolRow = struct {
    id: []const u8,
    routine_id: []const u8,
    tool_name: []const u8,
    enabled: u8,
};

/// A row of `agent_routine_system_prompt`.
pub const SystemPromptRow = struct {
    id: []const u8,
    routine_id: []const u8,
    title: []const u8,
    content: []const u8,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

// ─── Free helpers ──────────────────────────────────────────────────────

pub fn freeAgentRoutineRow(allocator: std.mem.Allocator, row: AgentRoutineRow) void {
    allocator.free(row.id);
    allocator.free(row.workspace_item_id);
    allocator.free(row.description);
    allocator.free(row.created_at);
    allocator.free(row.updated_at);
}

pub fn freeKnowledgeRow(allocator: std.mem.Allocator, row: KnowledgeRow) void {
    allocator.free(row.id);
    allocator.free(row.routine_id);
    allocator.free(row.file_path);
    allocator.free(row.label);
    allocator.free(row.content);
    allocator.free(row.created_at);
    allocator.free(row.updated_at);
}

pub fn freeToolRow(allocator: std.mem.Allocator, row: ToolRow) void {
    allocator.free(row.id);
    allocator.free(row.routine_id);
    allocator.free(row.tool_name);
}

pub fn freeSystemPromptRow(allocator: std.mem.Allocator, row: SystemPromptRow) void {
    allocator.free(row.id);
    allocator.free(row.routine_id);
    allocator.free(row.title);
    allocator.free(row.content);
    allocator.free(row.created_at);
    allocator.free(row.updated_at);
}

// ─── Internal row readers ──────────────────────────────────────────────

fn readAgentRoutineRow(allocator: std.mem.Allocator, r: anytype) !AgentRoutineRow {
    return .{
        .id = try allocator.dupe(u8, r.values[0]),
        .workspace_item_id = try allocator.dupe(u8, r.values[1]),
        .description = try allocator.dupe(u8, r.values[2]),
        .created_at = try allocator.dupe(u8, r.values[3]),
        .updated_at = try allocator.dupe(u8, r.values[4]),
    };
}

fn readKnowledgeRow(allocator: std.mem.Allocator, r: anytype) !KnowledgeRow {
    return .{
        .id = try allocator.dupe(u8, r.values[0]),
        .routine_id = try allocator.dupe(u8, r.values[1]),
        .file_path = try allocator.dupe(u8, r.values[2]),
        .label = try allocator.dupe(u8, r.values[3]),
        .content = try allocator.dupe(u8, r.values[4]),
        .position = std.fmt.parseInt(i64, r.values[5], 10) catch 0,
        .created_at = try allocator.dupe(u8, r.values[6]),
        .updated_at = try allocator.dupe(u8, r.values[7]),
    };
}

fn readToolRow(allocator: std.mem.Allocator, r: anytype) !ToolRow {
    return .{
        .id = try allocator.dupe(u8, r.values[0]),
        .routine_id = try allocator.dupe(u8, r.values[1]),
        .tool_name = try allocator.dupe(u8, r.values[2]),
        .enabled = std.fmt.parseInt(u8, r.values[3], 10) catch 1,
    };
}

fn readSystemPromptRow(allocator: std.mem.Allocator, r: anytype) !SystemPromptRow {
    return .{
        .id = try allocator.dupe(u8, r.values[0]),
        .routine_id = try allocator.dupe(u8, r.values[1]),
        .title = try allocator.dupe(u8, r.values[2]),
        .content = try allocator.dupe(u8, r.values[3]),
        .position = std.fmt.parseInt(i64, r.values[4], 10) catch 0,
        .created_at = try allocator.dupe(u8, r.values[5]),
        .updated_at = try allocator.dupe(u8, r.values[6]),
    };
}

// ─── agent_routines ─────────────────────────────────────────────────────

/// Is there an `agent_routines` row with this workspace_item_id?
/// (spec D3: agent_routines.id == workspace_item_id.)
pub fn exists(allocator: std.mem.Allocator, db: DbOrTx, workspace_item_id: []const u8) bool {
    var q = db.query(allocator, "SELECT 1 FROM agent_routines WHERE workspace_item_id = ?", &.{workspace_item_id}) catch return false;
    defer q.deinit();
    // The row owns its values[] buffer — release it, or the caller's
    // allocator leaks one allocation per exists() call.
    if (q.next() catch null) |row| {
        row.deinit(allocator);
        return true;
    }
    return false;
}

/// Fetch the config row by workspace_item_id. Returns null when absent.
pub fn getByWorkspaceItemId(allocator: std.mem.Allocator, db: DbOrTx, workspace_item_id: []const u8) !?AgentRoutineRow {
    var q = db.query(allocator,
        "SELECT id, workspace_item_id, description, IFNULL(created_at, ''), IFNULL(updated_at, '') FROM agent_routines WHERE workspace_item_id = ?",
        &.{workspace_item_id},
    ) catch return null;
    defer q.deinit();
    const r = (q.next() catch null) orelse return null;
    defer r.deinit(allocator);
    return try readAgentRoutineRow(allocator, r);
}

/// Update `description` and stamp `updated_at`. Returns the refetched row.
pub fn updateDescription(allocator: std.mem.Allocator, db: DbOrTx, workspace_item_id: []const u8, description: []const u8) !?AgentRoutineRow {
    db.exec(allocator,
        "UPDATE agent_routines SET description = COALESCE(?, ''), updated_at = datetime('now') WHERE workspace_item_id = ?",
        &.{ description, workspace_item_id },
    ) catch return null;
    return getByWorkspaceItemId(allocator, db, workspace_item_id);
}

/// Insert the config row, ignoring a UNIQUE conflict. Used by the
/// auto-seed path: enabling a tool on an unconfigured kanban implies
/// "configured", and re-enabling must not trip UNIQUE(workspace_item_id).
pub fn insertIgnoreDuplicate(allocator: std.mem.Allocator, db: DbOrTx, id: []const u8, workspace_item_id: []const u8) !void {
    try db.exec(allocator,
        "INSERT OR IGNORE INTO agent_routines (id, workspace_item_id) VALUES (?, ?)",
        &.{ id, workspace_item_id },
    );
}

// ─── agent_routine_knowledges ───────────────────────────────────────────

/// All knowledge rows for a kanban, `position DESC`.
pub fn listKnowledge(allocator: std.mem.Allocator, db: DbOrTx, routine_id: []const u8) ![]KnowledgeRow {
    var q = db.query(allocator,
        \\SELECT id, routine_id, file_path, label, content, position,
        \\       IFNULL(created_at, ''), IFNULL(updated_at, '')
        \\FROM agent_routine_knowledges WHERE routine_id = ?
        \\ORDER BY position DESC
    , &.{routine_id}) catch return &.{};
    defer q.deinit();

    var list: std.ArrayList(KnowledgeRow) = .empty;
    errdefer {
        for (list.items) |k| freeKnowledgeRow(allocator, k);
        list.deinit(allocator);
    }
    while ((q.next() catch null)) |r| {
        defer r.deinit(allocator);
        try list.append(allocator, try readKnowledgeRow(allocator, r));
    }
    return try list.toOwnedSlice(allocator);
}

/// Insert a knowledge row at `MAX(position) + 1` and return it.
pub fn insertKnowledge(
    allocator: std.mem.Allocator,
    db: DbOrTx,
    routine_id: []const u8,
    file_path: []const u8,
    label: []const u8,
    content: []const u8,
) !?KnowledgeRow {
    const ts = helpers.unixTimestampNanos();
    const id = try std.fmt.allocPrint(allocator, "arn_{d}", .{ts});
    defer allocator.free(id);

    db.exec(allocator,
        "INSERT INTO agent_routine_knowledges (id, routine_id, file_path, label, content, position, created_at, updated_at) VALUES (?, ?, COALESCE(?, ''), COALESCE(?, ''), COALESCE(?, ''), COALESCE((SELECT MAX(position) FROM agent_routine_knowledges WHERE routine_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ id, routine_id, file_path, label, content, routine_id },
    ) catch return null;
    return getKnowledgeById(allocator, db, id);
}

/// Fetch one knowledge row by id. Returns null when absent.
pub fn getKnowledgeById(allocator: std.mem.Allocator, db: DbOrTx, knowledge_id: []const u8) !?KnowledgeRow {
    var q = db.query(allocator,
        \\SELECT id, routine_id, file_path, label, content, position,
        \\       IFNULL(created_at, ''), IFNULL(updated_at, '')
        \\FROM agent_routine_knowledges WHERE id = ?
    , &.{knowledge_id}) catch return null;
    defer q.deinit();
    const r = (q.next() catch null) orelse return null;
    defer r.deinit(allocator);
    return try readKnowledgeRow(allocator, r);
}

/// Patch the provided fields of a knowledge row and return the refetched row.
pub fn updateKnowledge(
    allocator: std.mem.Allocator,
    db: DbOrTx,
    knowledge_id: []const u8,
    routine_id: []const u8,
    file_path: ?[]const u8,
    label: ?[]const u8,
    content: ?[]const u8,
) !?KnowledgeRow {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "UPDATE agent_routine_knowledges SET updated_at = datetime('now')");
    if (file_path != null) try sql.appendSlice(allocator, ", file_path = COALESCE(?, '')");
    if (label != null) try sql.appendSlice(allocator, ", label = ?");
    if (content != null) try sql.appendSlice(allocator, ", content = COALESCE(?, '')");
    try sql.appendSlice(allocator, " WHERE id = ? AND routine_id = ?");

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    if (file_path) |fp| try args.append(allocator, fp);
    if (label) |lb| try args.append(allocator, lb);
    if (content) |ct| try args.append(allocator, ct);
    try args.append(allocator, knowledge_id);
    try args.append(allocator, routine_id);

    db.exec(allocator, sql.items, args.items) catch return null;
    return getKnowledgeById(allocator, db, knowledge_id);
}

/// Delete one knowledge row scoped to its kanban.
pub fn deleteKnowledge(allocator: std.mem.Allocator, db: DbOrTx, knowledge_id: []const u8, routine_id: []const u8) !void {
    try db.exec(allocator,
        "DELETE FROM agent_routine_knowledges WHERE id = ? AND routine_id = ?",
        &.{ knowledge_id, routine_id },
    );
}

/// Rewrite every knowledge row's position inside one transaction.
/// `ordered_ids[0]` becomes the highest position (`len - 1`), the last
/// id becomes 0 — so a 1-row ordering lands at 0, not 1.
pub fn reorderKnowledge(allocator: std.mem.Allocator, db: *database.Db, routine_id: []const u8, ordered_ids: []const []const u8) !void {
    var tx = db.begin() catch return error.TransactionFailed;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    for (ordered_ids, 0..) |id, i| {
        const position: i64 = @intCast(ordered_ids.len - 1 - @as(usize, @intCast(i)));
        var pos_buf: [32]u8 = undefined;
        const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{position}) catch "0";
        tx.exec(allocator,
            "UPDATE agent_routine_knowledges SET position = ?, updated_at = datetime('now') WHERE id = ? AND routine_id = ?",
            &.{ pos_str, id, routine_id },
        ) catch return error.UpdateFailed;
    }
    try tx.commit();
}

// ─── agent_routine_tools ────────────────────────────────────────────────

/// Enabled tool names for a kanban, `tool_name ASC`.
pub fn listEnabledToolNames(allocator: std.mem.Allocator, db: DbOrTx, routine_id: []const u8) ![]const []const u8 {
    var q = db.query(allocator,
        \\SELECT tool_name FROM agent_routine_tools
        \\WHERE routine_id = ? AND enabled = 1
        \\ORDER BY tool_name ASC
    , &.{routine_id}) catch return &.{};
    defer q.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |n| allocator.free(n);
        list.deinit(allocator);
    }
    while ((q.next() catch null)) |r| {
        defer r.deinit(allocator);
        try list.append(allocator, try allocator.dupe(u8, r.values[0]));
    }
    return try list.toOwnedSlice(allocator);
}

/// Insert a tool row. Returns null on a UNIQUE violation (the kanban
/// already has this tool) so the caller can answer 409.
pub fn insertTool(allocator: std.mem.Allocator, db: DbOrTx, routine_id: []const u8, tool_name: []const u8) !?ToolRow {
    const ts = helpers.unixTimestampNanos();
    const id = try std.fmt.allocPrint(allocator, "art_{d}", .{ts});
    defer allocator.free(id);

    db.exec(allocator,
        "INSERT INTO agent_routine_tools (id, routine_id, tool_name, enabled, created_at) VALUES (?, ?, ?, 1, datetime('now'))",
        &.{ id, routine_id, tool_name },
    ) catch return null;
    return getToolById(allocator, db, id);
}

/// Fetch one tool row by id. Returns null when absent.
pub fn getToolById(allocator: std.mem.Allocator, db: DbOrTx, tool_id: []const u8) !?ToolRow {
    var q = db.query(allocator,
        "SELECT id, routine_id, tool_name, enabled FROM agent_routine_tools WHERE id = ?",
        &.{tool_id},
    ) catch return null;
    defer q.deinit();
    const r = (q.next() catch null) orelse return null;
    defer r.deinit(allocator);
    return try readToolRow(allocator, r);
}

/// Delete one tool row scoped to its kanban.
pub fn deleteTool(allocator: std.mem.Allocator, db: DbOrTx, routine_id: []const u8, tool_name: []const u8) !void {
    try db.exec(allocator,
        "DELETE FROM agent_routine_tools WHERE tool_name = ? AND routine_id = ?",
        &.{ tool_name, routine_id },
    );
}

// ─── agent_routine_system_prompt ────────────────────────────────────────

/// All system-prompt rows for a kanban, `position DESC`.
pub fn listSystemPrompts(allocator: std.mem.Allocator, db: DbOrTx, routine_id: []const u8) ![]SystemPromptRow {
    var q = db.query(allocator,
        \\SELECT id, routine_id, title, content, position,
        \\       IFNULL(created_at, ''), IFNULL(updated_at, '')
        \\FROM agent_routine_system_prompt WHERE routine_id = ?
        \\ORDER BY position DESC
    , &.{routine_id}) catch return &.{};
    defer q.deinit();

    var list: std.ArrayList(SystemPromptRow) = .empty;
    errdefer {
        for (list.items) |p| freeSystemPromptRow(allocator, p);
        list.deinit(allocator);
    }
    while ((q.next() catch null)) |r| {
        defer r.deinit(allocator);
        try list.append(allocator, try readSystemPromptRow(allocator, r));
    }
    return try list.toOwnedSlice(allocator);
}

/// Insert a system-prompt row at `MAX(position) + 1` and return it.
pub fn insertSystemPrompt(allocator: std.mem.Allocator, db: DbOrTx, routine_id: []const u8, title: []const u8, content: []const u8) !?SystemPromptRow {
    const ts = helpers.unixTimestampNanos();
    const id = try std.fmt.allocPrint(allocator, "arsp_{d}", .{ts});
    defer allocator.free(id);

    db.exec(allocator,
        "INSERT INTO agent_routine_system_prompt (id, routine_id, title, content, position, created_at, updated_at) VALUES (?, ?, COALESCE(?, ''), COALESCE(?, ''), COALESCE((SELECT MAX(position) FROM agent_routine_system_prompt WHERE routine_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ id, routine_id, title, content, routine_id },
    ) catch return null;
    return getSystemPromptById(allocator, db, id);
}

/// Fetch one system-prompt row by id. Returns null when absent.
pub fn getSystemPromptById(allocator: std.mem.Allocator, db: DbOrTx, prompt_id: []const u8) !?SystemPromptRow {
    var q = db.query(allocator,
        \\SELECT id, routine_id, title, content, position,
        \\       IFNULL(created_at, ''), IFNULL(updated_at, '')
        \\FROM agent_routine_system_prompt WHERE id = ?
    , &.{prompt_id}) catch return null;
    defer q.deinit();
    const r = (q.next() catch null) orelse return null;
    defer r.deinit(allocator);
    return try readSystemPromptRow(allocator, r);
}

/// Patch the provided fields of a system-prompt row and return the
/// refetched row. Both text columns use COALESCE so an empty string
/// clears the column instead of binding NULL.
pub fn updateSystemPrompt(
    allocator: std.mem.Allocator,
    db: DbOrTx,
    prompt_id: []const u8,
    routine_id: []const u8,
    title: ?[]const u8,
    content: ?[]const u8,
) !?SystemPromptRow {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "UPDATE agent_routine_system_prompt SET updated_at = datetime('now')");
    if (title != null) try sql.appendSlice(allocator, ", title = COALESCE(?, '')");
    if (content != null) try sql.appendSlice(allocator, ", content = COALESCE(?, '')");
    try sql.appendSlice(allocator, " WHERE id = ? AND routine_id = ?");

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    if (title) |t| try args.append(allocator, t);
    if (content) |c| try args.append(allocator, c);
    try args.append(allocator, prompt_id);
    try args.append(allocator, routine_id);

    db.exec(allocator, sql.items, args.items) catch return null;
    return getSystemPromptById(allocator, db, prompt_id);
}

/// Delete one system-prompt row scoped to its kanban.
pub fn deleteSystemPrompt(allocator: std.mem.Allocator, db: DbOrTx, prompt_id: []const u8, routine_id: []const u8) !void {
    try db.exec(allocator,
        "DELETE FROM agent_routine_system_prompt WHERE id = ? AND routine_id = ?",
        &.{ prompt_id, routine_id },
    );
}

/// Rewrite every system-prompt row's position inside one transaction.
/// Same ordering contract as `reorderKnowledge`.
pub fn reorderSystemPrompts(allocator: std.mem.Allocator, db: *database.Db, routine_id: []const u8, ordered_ids: []const []const u8) !void {
    var tx = db.begin() catch return error.TransactionFailed;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    for (ordered_ids, 0..) |id, i| {
        const position: i64 = @intCast(ordered_ids.len - 1 - @as(usize, @intCast(i)));
        var pos_buf: [32]u8 = undefined;
        const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{position}) catch "0";
        tx.exec(allocator,
            "UPDATE agent_routine_system_prompt SET position = ?, updated_at = datetime('now') WHERE id = ? AND routine_id = ?",
            &.{ pos_str, id, routine_id },
        ) catch return error.UpdateFailed;
    }
    try tx.commit();
}

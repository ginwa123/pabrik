//! SQL layer for the `agents` entity family. Every statement that touches
//! `agents`, `agent_knowledge`, `agent_tools` or `agent_system_prompt` lives
//! here.

const std = @import("std");
const database = @import("databases").database;
const helpers = @import("helpers");

pub const DbOrTx = database.DbOrTx;
pub const Error = database.Error;

// ─── Row types ─────────────────────────────────────────────────────────

/// A row of `agents`. Mirrors `agent.zig`'s field set.
pub const AgentRow = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    description: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// A row of `agent_knowledge`.
pub const KnowledgeRow = struct {
    id: []const u8,
    agent_id: []const u8,
    file_path: []const u8,
    label: []const u8,
    /// Inline manual text ('' = file-backed row).
    content: []const u8,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

/// A row of `agent_tools`.
pub const ToolRow = struct {
    id: []const u8,
    agent_id: []const u8,
    tool_name: []const u8,
    enabled: u8,
};

/// A row of `agent_system_prompt`.
pub const SystemPromptRow = struct {
    id: []const u8,
    agent_id: []const u8,
    title: []const u8,
    content: []const u8,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

// ─── Free helpers ──────────────────────────────────────────────────────

pub fn freeAgentRow(allocator: std.mem.Allocator, row: AgentRow) void {
    allocator.free(row.id);
    allocator.free(row.workspace_item_id);
    allocator.free(row.description);
    allocator.free(row.created_at);
    allocator.free(row.updated_at);
}

pub fn freeKnowledgeRow(allocator: std.mem.Allocator, row: KnowledgeRow) void {
    allocator.free(row.id);
    allocator.free(row.agent_id);
    allocator.free(row.file_path);
    allocator.free(row.label);
    allocator.free(row.content);
    allocator.free(row.created_at);
    allocator.free(row.updated_at);
}

pub fn freeToolRow(allocator: std.mem.Allocator, row: ToolRow) void {
    allocator.free(row.id);
    allocator.free(row.agent_id);
    allocator.free(row.tool_name);
}

pub fn freeSystemPromptRow(allocator: std.mem.Allocator, row: SystemPromptRow) void {
    allocator.free(row.id);
    allocator.free(row.agent_id);
    allocator.free(row.title);
    allocator.free(row.content);
    allocator.free(row.created_at);
    allocator.free(row.updated_at);
}

// ─── Internal row readers ──────────────────────────────────────────────

fn readAgentRow(allocator: std.mem.Allocator, r: anytype) !AgentRow {
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
        .agent_id = try allocator.dupe(u8, r.values[1]),
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
        .agent_id = try allocator.dupe(u8, r.values[1]),
        .tool_name = try allocator.dupe(u8, r.values[2]),
        .enabled = std.fmt.parseInt(u8, r.values[3], 10) catch 1,
    };
}

fn readSystemPromptRow(allocator: std.mem.Allocator, r: anytype) !SystemPromptRow {
    return .{
        .id = try allocator.dupe(u8, r.values[0]),
        .agent_id = try allocator.dupe(u8, r.values[1]),
        .title = try allocator.dupe(u8, r.values[2]),
        .content = try allocator.dupe(u8, r.values[3]),
        .position = std.fmt.parseInt(i64, r.values[4], 10) catch 0,
        .created_at = try allocator.dupe(u8, r.values[5]),
        .updated_at = try allocator.dupe(u8, r.values[6]),
    };
}

// ─── agents ────────────────────────────────────────────────────────────

/// Is there an `agents` row with this id?
pub fn exists(allocator: std.mem.Allocator, db: DbOrTx, agent_id: []const u8) bool {
    var q = db.query(allocator, "SELECT 1 FROM agent_configs WHERE id = ? AND item_type = 'agent'", &.{agent_id}) catch return false;
    defer q.deinit();
    // The row owns its values[] buffer — release it, or the caller's
    // allocator leaks one allocation per exists() call.
    if (q.next() catch null) |row| {
        row.deinit(allocator);
        return true;
    }
    return false;
}

/// Fetch one `agents` row by id. Returns null when absent.
pub fn getById(allocator: std.mem.Allocator, db: DbOrTx, agent_id: []const u8) !?AgentRow {
    var q = db.query(allocator,
        "SELECT id, workspace_item_id, description, COALESCE(CAST(created_at AS TEXT), ''), COALESCE(CAST(updated_at AS TEXT), '') FROM agent_configs WHERE id = ? AND item_type = 'agent'",
        &.{agent_id},
    ) catch return null;
    defer q.deinit();
    const r = (q.next() catch null) orelse return null;
    defer r.deinit(allocator);
    return try readAgentRow(allocator, r);
}

/// Update `description` and stamp `updated_at`. Returns the refetched row.
pub fn updateDescription(allocator: std.mem.Allocator, db: DbOrTx, agent_id: []const u8, description: []const u8) !?AgentRow {
    db.exec(allocator,
        "UPDATE agent_configs SET description = ?, updated_at = datetime('now') WHERE id = ? AND item_type = 'agent'",
        &.{ description, agent_id },
    ) catch return null;
    return getById(allocator, db, agent_id);
}

/// Insert an `agents` row. `id` and `workspace_item_id` are the same
/// string per spec D3 (1-1 enforced by `UNIQUE(workspace_item_id)`).
pub fn insert(allocator: std.mem.Allocator, db: DbOrTx, id: []const u8, workspace_item_id: []const u8) !void {
    try db.exec(allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type) VALUES (?, ?, 'agent')",
        &.{ id, workspace_item_id },
    );
}

// ─── agent_knowledge ───────────────────────────────────────────────────

/// All knowledge rows for an agent, `position DESC`.
pub fn listKnowledge(allocator: std.mem.Allocator, db: DbOrTx, agent_id: []const u8) ![]KnowledgeRow {
    var q = db.query(allocator,
        \\SELECT id, config_id AS agent_id, file_path, label, content, position,
        \\       COALESCE(CAST(created_at AS TEXT), ''), COALESCE(CAST(updated_at AS TEXT), '')
        \\FROM agent_config_knowledge WHERE config_id = ?
        \\ORDER BY position DESC
    , &.{agent_id}) catch return &.{};
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
/// `file_path` / `label` / `content` may be empty — the COALESCE
/// wrappers keep the empty-slice-as-NULL bind from tripping NOT NULL.
pub fn insertKnowledge(
    allocator: std.mem.Allocator,
    db: DbOrTx,
    agent_id: []const u8,
    file_path: []const u8,
    label: []const u8,
    content: []const u8,
) !?KnowledgeRow {
    const ts = helpers.unixTimestampNanos();
    const id = try std.fmt.allocPrint(allocator, "know_{d}", .{ts});
    defer allocator.free(id);

    db.exec(allocator,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, content, position, created_at, updated_at) VALUES (?, ?, COALESCE(?, ''), COALESCE(?, ''), COALESCE(?, ''), COALESCE((SELECT MAX(position) FROM agent_config_knowledge WHERE config_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ id, agent_id, file_path, label, content, agent_id },
    ) catch return null;
    return getKnowledgeById(allocator, db, id);
}

/// Fetch one knowledge row by id. Returns null when absent.
pub fn getKnowledgeById(allocator: std.mem.Allocator, db: DbOrTx, knowledge_id: []const u8) !?KnowledgeRow {
    var q = db.query(allocator,
        \\SELECT id, config_id AS agent_id, file_path, label, content, position,
        \\       COALESCE(CAST(created_at AS TEXT), ''), COALESCE(CAST(updated_at AS TEXT), '')
        \\FROM agent_config_knowledge WHERE id = ?
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
    agent_id: []const u8,
    file_path: ?[]const u8,
    label: ?[]const u8,
    content: ?[]const u8,
) !?KnowledgeRow {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "UPDATE agent_config_knowledge SET updated_at = datetime('now')");
    if (file_path != null) try sql.appendSlice(allocator, ", file_path = COALESCE(?, '')");
    if (label != null) try sql.appendSlice(allocator, ", label = ?");
    if (content != null) try sql.appendSlice(allocator, ", content = COALESCE(?, '')");
    try sql.appendSlice(allocator, " WHERE id = ? AND config_id = ?");

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    if (file_path) |fp| try args.append(allocator, fp);
    if (label) |lb| try args.append(allocator, lb);
    if (content) |ct| try args.append(allocator, ct);
    try args.append(allocator, knowledge_id);
    try args.append(allocator, agent_id);

    db.exec(allocator, sql.items, args.items) catch return null;
    return getKnowledgeById(allocator, db, knowledge_id);
}

/// Delete one knowledge row scoped to its agent.
pub fn deleteKnowledge(allocator: std.mem.Allocator, db: DbOrTx, knowledge_id: []const u8, agent_id: []const u8) !void {
    try db.exec(allocator,
        "DELETE FROM agent_config_knowledge WHERE id = ? AND config_id = ?",
        &.{ knowledge_id, agent_id },
    );
}

/// Rewrite every knowledge row's position inside one transaction.
/// `ordered_ids[0]` becomes the highest position (`len - 1`), the last
/// id becomes 0 — so a 1-row ordering lands at 0, not 1.
pub fn reorderKnowledge(allocator: std.mem.Allocator, db: *database.Db, agent_id: []const u8, ordered_ids: []const []const u8) !void {
    var tx = db.begin() catch return error.TransactionFailed;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    for (ordered_ids, 0..) |id, i| {
        const position: i64 = @intCast(ordered_ids.len - 1 - @as(usize, @intCast(i)));
        var pos_buf: [32]u8 = undefined;
        const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{position}) catch "0";
        tx.exec(allocator,
            "UPDATE agent_config_knowledge SET position = ?, updated_at = datetime('now') WHERE id = ? AND config_id = ?",
            &.{ pos_str, id, agent_id },
        ) catch return error.UpdateFailed;
    }
    try tx.commit();
}

// ─── agent_tools ───────────────────────────────────────────────────────

/// Enabled tool names for an agent, `tool_name ASC`.
pub fn listEnabledToolNames(allocator: std.mem.Allocator, db: DbOrTx, agent_id: []const u8) ![]const []const u8 {
    var q = db.query(allocator,
        \\SELECT tool_name FROM agent_config_tools
        \\WHERE config_id = ? AND enabled = 1
        \\ORDER BY tool_name ASC
    , &.{agent_id}) catch return &.{};
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

/// Every tool row for an agent (enabled and disabled), `tool_name ASC`.
pub fn listTools(allocator: std.mem.Allocator, db: DbOrTx, agent_id: []const u8) ![]ToolRow {
    var q = db.query(allocator,
        "SELECT id, config_id AS agent_id, tool_name, enabled FROM agent_config_tools WHERE config_id = ? ORDER BY tool_name ASC",
        &.{agent_id},
    ) catch return &.{};
    defer q.deinit();

    var list: std.ArrayList(ToolRow) = .empty;
    errdefer {
        for (list.items) |t| freeToolRow(allocator, t);
        list.deinit(allocator);
    }
    while ((q.next() catch null)) |r| {
        defer r.deinit(allocator);
        try list.append(allocator, try readToolRow(allocator, r));
    }
    return try list.toOwnedSlice(allocator);
}

/// Insert a tool row. Returns null on a UNIQUE violation (the agent
/// already has this tool) so the caller can answer 409.
pub fn insertTool(allocator: std.mem.Allocator, db: DbOrTx, agent_id: []const u8, tool_name: []const u8) !?ToolRow {
    const ts = helpers.unixTimestampNanos();
    const id = try std.fmt.allocPrint(allocator, "at_{d}", .{ts});
    defer allocator.free(id);

    db.exec(allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled, created_at) VALUES (?, ?, ?, 1, datetime('now'))",
        &.{ id, agent_id, tool_name },
    ) catch return null;
    return getToolById(allocator, db, id);
}

/// Insert a tool row, ignoring a UNIQUE conflict. Used by the default
/// seeding path, which is idempotent by design.
pub fn insertToolIgnoreDuplicate(allocator: std.mem.Allocator, db: DbOrTx, id: []const u8, agent_id: []const u8, tool_name: []const u8) !void {
    try db.exec(allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled, created_at) VALUES (?, ?, ?, 1, datetime('now')) ON CONFLICT DO NOTHING",
        &.{ id, agent_id, tool_name },
    );
}

/// Fetch one tool row by id. Returns null when absent.
pub fn getToolById(allocator: std.mem.Allocator, db: DbOrTx, tool_id: []const u8) !?ToolRow {
    var q = db.query(allocator,
        "SELECT id, config_id AS agent_id, tool_name, enabled FROM agent_config_tools WHERE id = ?",
        &.{tool_id},
    ) catch return null;
    defer q.deinit();
    const r = (q.next() catch null) orelse return null;
    defer r.deinit(allocator);
    return try readToolRow(allocator, r);
}

/// Delete one tool row scoped to its agent.
pub fn deleteTool(allocator: std.mem.Allocator, db: DbOrTx, agent_id: []const u8, tool_name: []const u8) !void {
    try db.exec(allocator,
        "DELETE FROM agent_config_tools WHERE tool_name = ? AND config_id = ?",
        &.{ tool_name, agent_id },
    );
}

// ─── agent_system_prompt ───────────────────────────────────────────────

/// All system-prompt rows for an agent, `position DESC`.
pub fn listSystemPrompts(allocator: std.mem.Allocator, db: DbOrTx, agent_id: []const u8) ![]SystemPromptRow {
    var q = db.query(allocator,
        \\SELECT id, config_id AS agent_id, title, content, position,
        \\       COALESCE(CAST(created_at AS TEXT), ''), COALESCE(CAST(updated_at AS TEXT), '')
        \\FROM agent_config_system_prompt WHERE config_id = ?
        \\ORDER BY position DESC
    , &.{agent_id}) catch return &.{};
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
pub fn insertSystemPrompt(allocator: std.mem.Allocator, db: DbOrTx, agent_id: []const u8, title: []const u8, content: []const u8) !?SystemPromptRow {
    const ts = helpers.unixTimestampNanos();
    const id = try std.fmt.allocPrint(allocator, "asp_{d}", .{ts});
    defer allocator.free(id);

    db.exec(allocator,
        "INSERT INTO agent_config_system_prompt (id, config_id, title, content, position, created_at, updated_at) VALUES (?, ?, COALESCE(?, ''), COALESCE(?, ''), COALESCE((SELECT MAX(position) FROM agent_config_system_prompt WHERE config_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ id, agent_id, title, content, agent_id },
    ) catch return null;
    return getSystemPromptById(allocator, db, id);
}

/// Fetch one system-prompt row by id. Returns null when absent.
pub fn getSystemPromptById(allocator: std.mem.Allocator, db: DbOrTx, prompt_id: []const u8) !?SystemPromptRow {
    var q = db.query(allocator,
        \\SELECT id, config_id AS agent_id, title, content, position,
        \\       COALESCE(CAST(created_at AS TEXT), ''), COALESCE(CAST(updated_at AS TEXT), '')
        \\FROM agent_config_system_prompt WHERE id = ?
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
    agent_id: []const u8,
    title: ?[]const u8,
    content: ?[]const u8,
) !?SystemPromptRow {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "UPDATE agent_config_system_prompt SET updated_at = datetime('now')");
    if (title != null) try sql.appendSlice(allocator, ", title = COALESCE(?, '')");
    if (content != null) try sql.appendSlice(allocator, ", content = COALESCE(?, '')");
    try sql.appendSlice(allocator, " WHERE id = ? AND config_id = ?");

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    if (title) |t| try args.append(allocator, t);
    if (content) |c| try args.append(allocator, c);
    try args.append(allocator, prompt_id);
    try args.append(allocator, agent_id);

    db.exec(allocator, sql.items, args.items) catch return null;
    return getSystemPromptById(allocator, db, prompt_id);
}

/// Delete one system-prompt row scoped to its agent.
pub fn deleteSystemPrompt(allocator: std.mem.Allocator, db: DbOrTx, prompt_id: []const u8, agent_id: []const u8) !void {
    try db.exec(allocator,
        "DELETE FROM agent_config_system_prompt WHERE id = ? AND config_id = ?",
        &.{ prompt_id, agent_id },
    );
}

/// Rewrite every system-prompt row's position inside one transaction.
/// Same ordering contract as `reorderKnowledge`.
pub fn reorderSystemPrompts(allocator: std.mem.Allocator, db: *database.Db, agent_id: []const u8, ordered_ids: []const []const u8) !void {
    var tx = db.begin() catch return error.TransactionFailed;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    for (ordered_ids, 0..) |id, i| {
        const position: i64 = @intCast(ordered_ids.len - 1 - @as(usize, @intCast(i)));
        var pos_buf: [32]u8 = undefined;
        const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{position}) catch "0";
        tx.exec(allocator,
            "UPDATE agent_config_system_prompt SET position = ?, updated_at = datetime('now') WHERE id = ? AND config_id = ?",
            &.{ pos_str, id, agent_id },
        ) catch return error.UpdateFailed;
    }
    try tx.commit();
}

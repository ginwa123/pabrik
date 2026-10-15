const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;

/// One column found by name in the local kanban.
pub const ColumnMatch = struct {
    id: []u8,
    name: []u8,
    position: i64,
};

pub fn freeColumnMatches(allocator: std.mem.Allocator, matches: []ColumnMatch) void {
    for (matches) |m| {
        allocator.free(m.id);
        allocator.free(m.name);
    }
    allocator.free(matches);
}

/// Input structure for kanban_move_task tool. The agent should pass
/// `workspace_id` + `item_id` from the active chat context (injected by the
/// frontend — see Sub-task 5 of the task plan).
pub const KanbanMoveTaskInput = struct {
    /// The workspace that owns the kanban item. From chat context.
    workspace_id: []const u8 = "",
    /// The kanban workspace item id. From chat context.
    item_id: []const u8 = "",
    /// The task to move. Found via `kanban_list` (returns each
    /// task's `<id>`).
    task_id: []const u8 = "",
    /// Target column — exact id (preferred when known). The agent
    /// gets this from `kanban_list` output.
    target_column_id: ?[]const u8 = null,
    /// Target column — human-readable name (e.g. "done"). Matched
    /// case-insensitively after trim against the board's columns.
    target_column_name: ?[]const u8 = null,
    /// 0-based position within the target column. When null, the
    /// task is appended to the end (server picks a high position
    /// that the renumber will compact to last).
    position: ?i64 = null,
};

/// Top-level tool definition for the LLM.
pub const kanban_move_task_tool_system_prompt =
    \\## Kanban Move Task Tool — MANDATORY for kanban tasks
    \\You are on a kanban board. Moving the card IS part of the job — not optional.
    \\- **START (MANDATORY, FIRST CALL):** Before any other work, move `todo` → `in progress` (second column).
    \\- **COMPLETE (MANDATORY, LAST CALL):** Before your final reply, move to `done` (last column). Skipping this = task failure.
    \\- Pass `workspace_id` + `item_id` from `## Workspace Context` and `task_id` = your `session_id`. Use `target_column_id` from `## Kanban Status Tracking — MANDATORY` (no need for `kanban_list`).
    \\
;

pub const kanban_move_task_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "kanban_move_task",
        .description =
        \\MANDATORY for kanban tasks: move a card to a different column/position. Call it at START (`todo` → `in progress`, first tool call) and at COMPLETE (→ `done`, last call before the final reply) — skipping either is a task failure. It also serves "move the auth task to done".
        \\
        \\The `target_column_id` values are already in `## Kanban Status Tracking — MANDATORY`, so call directly in ONE call; `kanban_list` is only for discovering other tasks. Given only a column name, pass `target_column_name` — a case-insensitive trimmed match resolves it.
        \\
        \\`workspace_id`/`item_id` come from `## Workspace Context` — the backtick-quoted id after `id: `, never the name. `task_id` is your `session_id` (kanban_list's `<id>`), not the task name.
        \\
        \\On error: re-call `kanban_list` for fresh ids (a column may have been renamed); an ambiguous `target_column_name` fails with the candidates — pass `target_column_id`; "TaskNotFound" means the task is not on this board.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "workspace_id",
                    .type = "string",
                    .description = "The workspace that owns the kanban, from `## Workspace Context`.",
                },
                .{
                    .name = "item_id",
                    .type = "string",
                    .description = "The kanban workspace item id (NOT the name): the backtick-quoted value after `id: ` in `## Workspace Context` (e.g. item_1782313125507292140).",
                },
                .{
                    .name = "task_id",
                    .type = "string",
                    .description = "The task to move (id, NOT name). Found via kanban_list's `<id>` field.",
                },
                .{
                    .name = "target_column_id",
                    .type = "string",
                    .description = "Exact id of the target column. Preferred when known. From kanban_list's column `<id>` field.",
                },
                .{
                    .name = "target_column_name",
                    .type = "string",
                    .description = "Human-readable column name (e.g. 'done'), matched case-insensitively after trim. Prefer `target_column_id` when you have it.",
                },
                .{
                    .name = "position",
                    .type = "integer",
                    .description = "0-based position within the target column; omitted/null appends to the end of the column.",
                },
            },
            .required = &.{ "workspace_id", "item_id", "task_id" },
        },
        .system_prompt = kanban_move_task_tool_system_prompt,
    },
};

/// Resolve a column name to an id via a case-insensitive trimmed match
/// against the board's columns. Returns the FIRST match (or an empty slice
/// when no match).
pub fn findColumnsByName(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    name_query: []const u8,
) ![]ColumnMatch {
    const cols = pabrikcore.ai_mod.kanban_model.listColumns(allocator, db, workspace_item_id) catch {
        return &[_]ColumnMatch{};
    };
    defer pabrikcore.ai_mod.kanban_model.freeColumns(allocator, cols);

    const query_trimmed = std.mem.trim(u8, name_query, " \t\r\n");
    var lower_buf: [256]u8 = undefined;
    const query_lower = toLowerInto(allocator, query_trimmed, &lower_buf) catch
        return &[_]ColumnMatch{};
    defer if (query_lower.ptr != lower_buf[0..].ptr) allocator.free(query_lower);

    var matches = std.ArrayList(ColumnMatch).empty;
    errdefer {
        for (matches.items) |m| {
            allocator.free(m.id);
            allocator.free(m.name);
        }
        matches.deinit(allocator);
    }

    for (cols) |c| {
        var col_buf: [256]u8 = undefined;
        const col_lower = toLowerInto(allocator, c.name, &col_buf) catch continue;
        defer if (col_lower.ptr != col_buf[0..].ptr) allocator.free(col_lower);
        if (std.mem.eql(u8, query_lower, col_lower)) {
            try matches.append(allocator, .{
                .id = try allocator.dupe(u8, c.id),
                .name = try allocator.dupe(u8, c.name),
                .position = c.position,
            });
        }
    }
    return try matches.toOwnedSlice(allocator);
}

/// Lowercase a string into a stack buffer when it fits, else heap. The
/// pointer-equality on the returned slice tells the caller whether to free
/// it. Trims nothing — the caller should trim first.
fn toLowerInto(allocator: std.mem.Allocator, s: []const u8, buf: []u8) ![]const u8 {
    if (s.len > buf.len) {
        const out = try allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| {
            out[i] = std.ascii.toLower(c);
        }
        return out;
    }
    for (s, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..s.len];
}

/// Read a task's current column id + name from the DB. Used to
/// enrich the success response (so the LLM can confirm "the task
/// moved to column X").
fn readTaskCurrentColumn(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    task_id: []const u8,
) !struct { column_id: []u8, column_name: []u8 } {
    // After Migration 072, the task's current kanban column lives in the
    // `kanban` join table. LEFT JOIN kanban so unassigned tasks (no kanban
    // row) return column_id = '' + column_name = '' (the COALESCE fallback).
    var q = try db.query(allocator,
        \\SELECT COALESCE(k.kanban_column_id, ''), COALESCE(kc.name, '')
        \\FROM workspace_item_tasks t
        \\LEFT JOIN kanban k ON k.workspace_item_task_id = t.id
        \\LEFT JOIN kanban_columns kc ON kc.id = k.kanban_column_id
        \\WHERE t.id = ?
    , &.{task_id});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        return .{
            .column_id = try allocator.dupe(u8, row.values[0]),
            .column_name = try allocator.dupe(u8, row.values[1]),
        };
    }
    return error.TaskNotFound;
}

/// Execute the kanban_move_task tool. Returns a JSON string for the LLM.
pub fn executeKanbanMoveTaskToJSON(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: KanbanMoveTaskInput,
) ![]u8 {
    if (input.workspace_id.len == 0) return errorJSON(allocator, "Missing required field: workspace_id");
    if (input.item_id.len == 0) return errorJSON(allocator, "Missing required field: item_id");
    if (input.task_id.len == 0) return errorJSON(allocator, "Missing required field: task_id");

    // Matches array (for target_column_name resolution) must outlive the use
    // of `target_column_id` (which borrows from matches[0].id).
    var name_matches: ?[]ColumnMatch = null;
    defer if (name_matches) |m| freeColumnMatches(allocator, m);

    const target_column_id: []const u8 = if (input.target_column_id) |cid| cid else blk: {
        const name = input.target_column_name orelse {
            return errorJSON(allocator, "Need at least one of target_column_id or target_column_name");
        };
        if (name.len == 0) {
            return errorJSON(allocator, "Need at least one of target_column_id or target_column_name");
        }
        const matches = findColumnsByName(allocator, db, input.item_id, name) catch |err| {
            return errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: findColumnsByName failed: {s}", .{@errorName(err)}));
        };

        if (matches.len == 0) {
            freeColumnMatches(allocator, matches);
            return errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "Column not found: {s}", .{name}));
        }
        if (matches.len > 1) {
            freeColumnMatches(allocator, matches);
            return errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "Ambiguous column name: '{s}' matches {d} columns - pass target_column_id", .{ name, matches.len }));
        }
        name_matches = matches;
        break :blk matches[0].id;
    };

    // 1. Look up the task to get its name (for the success response).
    var task_name_buf: [256]u8 = undefined;
    const task_name_slice: []const u8 = blk: {
        var q = try db.query(allocator, "SELECT COALESCE(t.name, '') FROM workspace_item_tasks t WHERE t.id = ?", &.{input.task_id});
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(allocator);
            const name = row.values[0];
            if (name.len <= task_name_buf.len) {
                @memcpy(task_name_buf[0..name.len], name);
                break :blk task_name_buf[0..name.len];
            }
            break :blk try allocator.dupe(u8, name);
        }
        return errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "TaskNotFound: {s}", .{input.task_id}));
    };
    defer if (task_name_slice.ptr != task_name_buf[0..].ptr) allocator.free(task_name_slice);

    // 2. Compute the target position.
    const position: i64 = input.position orelse blk: {
        var q = try db.query(
            allocator,
            "SELECT COALESCE(MAX(k.kanban_position), -1) + 1 FROM kanban k WHERE k.kanban_column_id = ?",
            &.{target_column_id},
        );
        defer q.deinit();
        const row = (try q.next()) orelse break :blk @as(i64, 0);
        defer row.deinit(allocator);
        break :blk try std.fmt.parseInt(i64, row.values[0], 10);
    };
    const position_str = try std.fmt.allocPrint(allocator, "{d}", .{position});
    defer allocator.free(position_str);

    // 3. Call kanban_model.moveTask — this handles the sibling
    //    renumber atomically.
    pabrikcore.ai_mod.kanban_model.moveTask(
        allocator,
        db,
        input.item_id,
        input.task_id,
        target_column_id,
        position,
    ) catch |err| {
        return errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: moveTask failed: {s}", .{@errorName(err)}));
    };

    // 3a. Emit the `kanban_task` SSE event so connected KanbanView clients
    // refresh their board.
    pabrikcore.ai_mod.on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
        .action = "moved",
        .workspace_id = input.workspace_id,
        .item_id = input.item_id,
        .task_id = input.task_id,
        .new_column_id = target_column_id,
        .new_position = position,
    }) catch |err| {
        // Non-fatal: the LLM still gets the success XML; the
        // card auto-refresh just won't fire on sibling tabs.
        // The next kanban mutation will re-emit and catch up.
        std.log.warn("kanban_move_task: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
    };

    // 4. Read the post-move state (column name) for the success
    //    response. The task was just moved to target_column_id, so
    //    we know its new column id — just look up the name.
    const post = readTaskCurrentColumn(allocator, db, input.task_id) catch |err| {
        return errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: readTaskCurrentColumn failed: {s}", .{@errorName(err)}));
    };
    defer allocator.free(post.column_id);
    defer allocator.free(post.column_name);

    return successJSON(allocator, input.task_id, task_name_slice, post.column_id, post.column_name, position);
}

/// Success payload for `kanban_move_task`. Keys mirror the old
/// `<kanban_move>` child tags 1:1.
pub const KanbanMoveSuccess = struct {
    success: bool,
    task_id: []const u8,
    task_name: []const u8,
    column_id: []const u8,
    column_name: []const u8,
    position: i64,
};

/// Error payload for `kanban_move_task`.
pub const KanbanMoveError = struct {
    success: bool,
    @"error": []const u8,
};

/// Generate the success JSON payload.
pub fn successJSON(
    allocator: std.mem.Allocator,
    task_id: []const u8,
    task_name: []const u8,
    column_id: []const u8,
    column_name: []const u8,
    position: i64,
) ![]u8 {
    const clean_name = try sanitizeControlChars(allocator, task_name);
    defer allocator.free(clean_name);
    const clean_col = try sanitizeControlChars(allocator, column_name);
    defer allocator.free(clean_col);
    return std.json.Stringify.valueAlloc(allocator, KanbanMoveSuccess{
        .success = true,
        .task_id = task_id,
        .task_name = clean_name,
        .column_id = column_id,
        .column_name = clean_col,
        .position = position,
    }, .{});
}

/// Generate the error JSON payload. Mirrors the pattern in
/// `set_git_worktree.zig` / `add_skill.zig`.
pub fn errorJSON(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    const clean = try sanitizeControlChars(allocator, error_msg);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, KanbanMoveError{
        .success = false,
        .@"error" = clean,
    }, .{});
}

/// Same as `errorJSON` but TAKES OWNERSHIP of `error_msg` and frees it after
/// use.
pub fn errorJSONOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);
    return errorJSON(allocator, error_msg);
}

/// Parsed shape of `executeKanbanMoveTaskToJSON` output, for tests.
pub const KanbanMoveOutput = struct {
    success: bool,
    task_id: ?[]const u8 = null,
    task_name: ?[]const u8 = null,
    column_id: ?[]const u8 = null,
    column_name: ?[]const u8 = null,
    position: ?i64 = null,
    @"error": ?[]const u8 = null,
};

const testing = std.testing;
const kanban_move_task = @import("kanban_move_task.zig");
const kanban_model = pabrikcore.ai_mod.kanban_model;
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── JSON serialization behavioral tests (no DB required) ───────────────

test "errorJSON on missing field returns parsed error payload" {
    const alloc = testing.allocator;
    const json = try kanban_move_task.errorJSON(alloc, "Missing required field: workspace_id");
    defer alloc.free(json);
    const parsed = try std.json.parseFromSlice(kanban_move_task.KanbanMoveOutput, alloc, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.success);
    try std.testing.expectEqualStrings("Missing required field: workspace_id", parsed.value.@"error" orelse "");
}

test "successJSON renders all fields, parsed" {
    const alloc = testing.allocator;
    const json = try kanban_move_task.successJSON(
        alloc,
        "task_123",
        "My task",
        "col_done",
        "done",
        2,
    );
    defer alloc.free(json);
    const parsed = try std.json.parseFromSlice(kanban_move_task.KanbanMoveOutput, alloc, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.success);
    try std.testing.expectEqualStrings("task_123", parsed.value.task_id orelse "");
    try std.testing.expectEqualStrings("My task", parsed.value.task_name orelse "");
    try std.testing.expectEqualStrings("col_done", parsed.value.column_id orelse "");
    try std.testing.expectEqualStrings("done", parsed.value.column_name orelse "");
    try std.testing.expectEqual(@as(i64, 2), parsed.value.position orelse -1);
    try std.testing.expect(parsed.value.@"error" == null);
}

test "successJSON keeps raw characters, parsed" {
    const alloc = testing.allocator;
    const json = try kanban_move_task.successJSON(
        alloc,
        "task_&x",
        "<fancy>",
        "col_x",
        "in <review>",
        0,
    );
    defer alloc.free(json);
    // Raw text needs no escaping in JSON — parse and compare verbatim.
    const parsed = try std.json.parseFromSlice(kanban_move_task.KanbanMoveOutput, alloc, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("task_&x", parsed.value.task_id orelse "");
    try std.testing.expectEqualStrings("<fancy>", parsed.value.task_name orelse "");
    try std.testing.expectEqualStrings("in <review>", parsed.value.column_name orelse "");
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  name TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  description TEXT NOT NULL DEFAULT '',
        \\  position INTEGER,
        \\  created_at TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  task_type TEXT
        \\)
    , &.{});
    // Post-Migration-072 schema: the task→column mapping lives in the
    // `kanban` join table, not on workspace_item_tasks directly.
    try db.exec(alloc,
        \\CREATE TABLE kanban (
        \\  workspace_item_task_id TEXT PRIMARY KEY,
        \\  kanban_column_id TEXT NOT NULL,
        \\  kanban_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});

    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Test')", &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('item_1', 'ws_1', 'kanban', 'Sprint')", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_todo', 'item_1', 'todo', 0)", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_ip', 'item_1', 'in progress', 1)", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_done', 'item_1', 'done', 2)", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t1', 'item_1', 'Auth task', 'standard')", &.{});
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t2', 'item_1', 'Other task', 'standard')", &.{});
    try db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'col_todo', 0)", &.{});
    try db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t2', 'col_todo', 1)", &.{});

    return .{ .db = db, .threaded = threaded };
}

test "findColumnsByName case-insensitive match" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const matches = try kanban_move_task.findColumnsByName(alloc, &s.db, "item_1", "DONE");
    defer kanban_move_task.freeColumnMatches(alloc, matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("col_done", matches[0].id);
    try testing.expectEqualStrings("done", matches[0].name);
}

test "findColumnsByName returns empty when no match" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const matches = try kanban_move_task.findColumnsByName(alloc, &s.db, "item_1", "nonexistent");
    defer kanban_move_task.freeColumnMatches(alloc, matches);
    try testing.expectEqual(@as(usize, 0), matches.len);
}

test "findColumnsByName trims whitespace" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const matches = try kanban_move_task.findColumnsByName(alloc, &s.db, "item_1", "  done  ");
    defer kanban_move_task.freeColumnMatches(alloc, matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("done", matches[0].name);
}

test "findColumnsByName matches 'in progress' with space" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const matches = try kanban_move_task.findColumnsByName(alloc, &s.db, "item_1", "In Progress");
    defer kanban_move_task.freeColumnMatches(alloc, matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("col_ip", matches[0].id);
}

test "executeKanbanMoveTaskToJSON returns success JSON on valid move" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_move_task.KanbanMoveTaskInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .task_id = "t1",
        .target_column_id = "col_done",
        .position = 0,
    };
    const json = try kanban_move_task.executeKanbanMoveTaskToJSON(alloc, &s.db, input);
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(kanban_move_task.KanbanMoveOutput, alloc, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.success);
    try std.testing.expectEqualStrings("t1", parsed.value.task_id orelse "");
    try std.testing.expectEqualStrings("Auth task", parsed.value.task_name orelse "");
    try std.testing.expectEqualStrings("col_done", parsed.value.column_id orelse "");
    try std.testing.expectEqualStrings("done", parsed.value.column_name orelse "");
}

test "executeKanbanMoveTaskToJSON resolves column name to id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_move_task.KanbanMoveTaskInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .task_id = "t1",
        .target_column_id = null,
        .target_column_name = "DONE", // case-insensitive match against "done"
        .position = 0,
    };
    const json = try kanban_move_task.executeKanbanMoveTaskToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    try testing.expect(contains(json, "\"success\":true"));
    try testing.expect(contains(json, "\"column_id\":\"col_done\""));
}

test "executeKanbanMoveTaskToJSON returns Column not found error" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_move_task.KanbanMoveTaskInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .task_id = "t1",
        .target_column_name = "nonexistent",
    };
    const json = try kanban_move_task.executeKanbanMoveTaskToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "Column not found"));
}

test "executeKanbanMoveTaskToJSON returns Need target_column_id/name error" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_move_task.KanbanMoveTaskInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .task_id = "t1",
        // Both target_column_id and target_column_name are null.
    };
    const json = try kanban_move_task.executeKanbanMoveTaskToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "target_column_id or target_column_name"));
}

test "executeKanbanMoveTaskToJSON returns TaskNotFound error" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_move_task.KanbanMoveTaskInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .task_id = "nonexistent_task",
        .target_column_id = "col_done",
    };
    const json = try kanban_move_task.executeKanbanMoveTaskToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "TaskNotFound"));
}

test "executeKanbanMoveTaskToJSON returns Missing required field for empty workspace_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_move_task.KanbanMoveTaskInput{
        .workspace_id = "",
        .item_id = "item_1",
        .task_id = "t1",
        .target_column_id = "col_done",
    };
    const json = try kanban_move_task.executeKanbanMoveTaskToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "workspace_id"));
}

test "executeKanbanMoveTaskToJSON without position appends to end of column" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Insert one task in done column to set the max position.
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t_done', 'item_1', 'Already done', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t_done', 'col_done', 0)", &.{});

    // Move t1 to col_done with no position.
    const input = kanban_move_task.KanbanMoveTaskInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .task_id = "t1",
        .target_column_id = "col_done",
        // position = null → end-of-column
    };
    const json = try kanban_move_task.executeKanbanMoveTaskToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    try testing.expect(contains(json, "\"success\":true"));
    // The position should be MAX(0) + 1 = 1
    try testing.expect(contains(json, "\"position\":1"));
}

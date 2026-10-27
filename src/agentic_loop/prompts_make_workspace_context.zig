const std = @import("std");
const pabrikcore = @import("pabrikcore");

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;

pub const MAX_SIBLING_ITEMS: u32 = 20;
pub const MAX_TASKS_PER_ITEM: u32 = 5;


pub fn makeWorkspaceContext(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");

    const ctx = (getWorkspaceContext(allocator, db, session_id) catch |err| {
        std.log.warn("BuildWorkspaceContext: lookup failed: {}", .{err});
        return allocator.dupe(u8, "");
    }) orelse return allocator.dupe(u8, "");
    defer ctx.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\n\n## Workspace Context\n\n");
    try out.appendSlice(allocator, "This task is part of workspace `");
    try out.appendSlice(allocator, ctx.workspace_id);
    try out.appendSlice(allocator,
        \\`. The other items in this workspace are listed below for
        \\discovery — you can read or reference their files via `bash`,
        \\`read_file`, etc. by using the `path` shown for each item.
        \\
        \\The item marked *(this task)* is the one your session is bound
        \\to. Sibling items may be running other conversations; treat
        \\their files as a shared workspace, not as something to modify
        \\without the user asking.
        \\
    );

    if (ctx.self_path) |p| {
        try out.appendSlice(allocator, "**Your task's working directory (cwd hint):** `");
        try out.appendSlice(allocator, p);
        try out.appendSlice(allocator, "`\n\n");
    } else {
        try out.appendSlice(allocator,
            \\**Your task's working directory:** (none recorded)
            \\
        );
    }

    for (ctx.siblings) |sib| {
        try out.appendSlice(allocator, "- **");
        if (sib.name) |n| {
            try out.appendSlice(allocator, n);
        } else {
            try out.appendSlice(allocator, sib.id);
        }
        try out.appendSlice(allocator, "** (item_id: `");
        try out.appendSlice(allocator, sib.id);
        try out.appendSlice(allocator, "`, item_type: `");
        try out.appendSlice(allocator, sib.item_type);
        try out.appendSlice(allocator, "`, path: `");
        if (sib.path) |p| {
            try out.appendSlice(allocator, p);
        } else {
            try out.appendSlice(allocator, "(none)");
        }
        try out.appendSlice(allocator, "`)");
        // Cache-friendly: no "*(this task)*" marker — that would make the prompt per-task dynamic.
        // The agent can find its own item_id via the task's workspace_item_id in the anchor,
        // but we don't mark it here to keep the prompt workspace-static (same for all tasks in workspace).
        try out.appendSlice(allocator, "\n");
        // Cache-friendly: no per-item tasks listing — tasks are highly dynamic (change on every create)
        // and break prefix cache. The agent should use kanban_list / search to discover tasks.
    }

    if (ctx.truncated_items_count > 0) {
        const footer = try std.fmt.allocPrint(
            allocator,
            "\n… and {d} more item{s} in this workspace (cap: {d} shown).\n",
            .{ ctx.truncated_items_count, if (ctx.truncated_items_count == 1) "" else "s", MAX_SIBLING_ITEMS },
        );
        defer allocator.free(footer);
        try out.appendSlice(allocator, footer);
    }

    // Per-task dynamic tail — small, at the end so prefix cache for the workspace-static
    // siblings list above stays hot. This is the ONLY per-task dynamic part.
    try out.appendSlice(allocator, "\n**Your current task:** `");
    try out.appendSlice(allocator, ctx.self_task_id);
    try out.appendSlice(allocator, "` is bound to item `");
    try out.appendSlice(allocator, ctx.self_item_id);
    try out.appendSlice(allocator, "` (item_type: `");
    try out.appendSlice(allocator, ctx.self_item_type);
    try out.appendSlice(allocator, "`)\n");

    return out.toOwnedSlice(allocator);
}

fn getWorkspaceContext(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) !?WorkspaceContext {
    if (session_id.len == 0) return null;
    const anchor_sql =
        \\SELECT t.id, t.workspace_item_id, wi.workspace_id, wi.path, wi.item_type
        \\FROM workspace_item_tasks t
        \\JOIN workspace_items wi ON wi.id = t.workspace_item_id
        \\WHERE t.id = ?
    ;
    var anchor_q = try db.query(allocator, anchor_sql, &.{session_id});
    defer anchor_q.deinit();
    const anchor_row = (try anchor_q.next()) orelse return null;
    const self_task_id = try allocator.dupe(u8, anchor_row.values[0]);
    const self_item_id = try allocator.dupe(u8, anchor_row.values[1]);
    const workspace_id = try allocator.dupe(u8, anchor_row.values[2]);
    const self_path: ?[]u8 = if (anchor_row.values[3].len > 0)
        try allocator.dupe(u8, anchor_row.values[3])
    else
        null;
    const self_item_type = try allocator.dupe(u8, anchor_row.values[4]);
    anchor_row.deinit(allocator); // Pitfall 1: pass allocator explicitly, NOT `anchor_row.allocator`

    // 2. Total item count for the "and N more" footer.
    var count_q = try db.query(
        allocator,
        "SELECT COUNT(*) FROM workspace_items wi WHERE wi.workspace_id = ?",
        &.{workspace_id},
    );
    defer count_q.deinit();
    const count_row = (try count_q.next()) orelse {
        return WorkspaceContext{
            .workspace_id = workspace_id,
            .self_item_id = self_item_id,
            .self_task_id = self_task_id,
            .self_item_type = self_item_type,
            .self_path = self_path,
            .siblings = &.{},
            .truncated_items_count = 0,
            .total_item_count = 0,
        };
    };
    const total_item_count = try std.fmt.parseInt(u32, count_row.values[0], 10);
    count_row.deinit(allocator);

    // Cache-friendly: workspace-static ordering (no is_self). Same prompt for all tasks in workspace.
    const items_sql = try std.fmt.allocPrint(allocator,
        \\SELECT wi.id, wi.item_type, wi.name, wi.path
        \\FROM workspace_items wi
        \\WHERE wi.workspace_id = ?
        \\ORDER BY wi.position DESC, wi.id ASC
        \\LIMIT {d}
    , .{MAX_SIBLING_ITEMS});
    defer allocator.free(items_sql);

    var items_q = try db.query(allocator, items_sql, &.{workspace_id});
    defer items_q.deinit();

    var siblings: std.ArrayList(WorkspaceContext.SiblingItem) = .empty;
    errdefer {
        for (siblings.items) |s| s.deinit(allocator);
        siblings.deinit(allocator);
    }

    while (try items_q.next()) |row| {
        const item_id_owned = try allocator.dupe(u8, row.values[0]);
        errdefer allocator.free(item_id_owned);
        const item_type_owned = try allocator.dupe(u8, row.values[1]);
        const name_owned: ?[]u8 = if (row.values[2].len > 0) try allocator.dupe(u8, row.values[2]) else null;
        const path_owned: ?[]u8 = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null;
        row.deinit(allocator);

        // Cache-friendly: no per-item tasks — workspace-static only
        try siblings.append(allocator, .{
            .id = item_id_owned,
            .item_type = item_type_owned,
            .name = name_owned,
            .path = path_owned,
            .is_self = false, // not used for rendering anymore, kept for struct compat
            .tasks = &.{},
            .truncated_tasks_count = 0,
        });
    }

    const truncated_items_count: u32 = if (total_item_count > MAX_SIBLING_ITEMS)
        total_item_count - MAX_SIBLING_ITEMS
    else
        0;

    return WorkspaceContext{
        .workspace_id = workspace_id,
        .self_item_id = self_item_id,
        .self_task_id = self_task_id,
        .self_item_type = self_item_type,
        .self_path = self_path,
        .siblings = try siblings.toOwnedSlice(allocator),
        .truncated_items_count = truncated_items_count,
        .total_item_count = total_item_count,
    };
}

const WorkspaceContext = struct {
    workspace_id: []u8,
    self_item_id: []u8, // task's own item id
    self_task_id: []u8, // task's own id
    self_item_type: []u8, // parent's workspace_items.item_type ('kanban', 'chat', 'folder', ...)
    self_path: ?[]u8, // task's own item path (cwd hint)
    siblings: []SiblingItem, // all items in the same workspace, self first
    truncated_items_count: u32, // > 0 when 20-item cap hit
    total_item_count: u32, // for diagnostic footer

    pub const SiblingItem = struct {
        id: []u8,
        item_type: []u8,
        name: ?[]u8,
        path: ?[]u8,
        is_self: bool,
        tasks: []SiblingTask, // ≤ MAX_TASKS_PER_ITEM
        truncated_tasks_count: u32, // > 0 when 5-task cap hit

        pub const SiblingTask = struct {
            id: []u8,
            name: []u8,
            task_type: []u8,
        };

        pub fn deinit(self: SiblingItem, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.item_type);
            if (self.name) |n| allocator.free(n);
            if (self.path) |p| allocator.free(p);
            for (self.tasks) |t| {
                allocator.free(t.id);
                allocator.free(t.name);
                allocator.free(t.task_type);
            }
            allocator.free(self.tasks);
        }
    };

    pub fn deinit(self: WorkspaceContext, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.self_item_id);
        allocator.free(self.self_task_id);
        allocator.free(self.self_item_type);
        if (self.self_path) |p| allocator.free(p);
        for (self.siblings) |sib| sib.deinit(allocator);
        allocator.free(self.siblings);
    }
};

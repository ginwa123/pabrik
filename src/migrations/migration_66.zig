const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 066 — Add `design_pages.workspace_item_task_id` foreign key to
/// bind each design page 1:1 to its `workspace_item_tasks` chat-session row.
/// ## Why this migration exists Today, the per-page chat lookup in
pub const Migration066AddDesignPageTaskFk = struct {
    pub const version: u32 = 66;
    pub const name = "add_design_page_task_fk";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // 1. Add the column. Nullable — backfilled below; new
        //    INSERTs from `design_model.setDesignPage` populate it
        //    at create time.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "design_pages",
            "workspace_item_task_id",
            // name + type — `addColumnIfMissing` uses this verbatim as `ALTER
            // TABLE {table} ADD COLUMN {definition}`, so omitting the column
            // name would create a column literally named "TEXT".
            "workspace_item_task_id TEXT",
        );

        // 2. UNIQUE index for the 1:1 invariant. `IF NOT EXISTS`
        //    keeps the migration idempotent on re-run.
        try db.exec(
            allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_design_pages_workspace_item_task_id " ++
                "ON design_pages(workspace_item_task_id)",
            &[_][]const u8{},
        );

        // 3. Backfill existing pages.
        var q = try db.query(
            allocator,
            \\SELECT dp.id, dp.workspace_item_id,
            \\       COALESCE(dp.name, '') AS name
            \\FROM design_pages dp
            \\WHERE dp.workspace_item_task_id IS NULL
        , &[_][]const u8{});
        defer q.deinit();

        // Last task id's nanosecond value — used to guarantee strictly
        // increasing ids across the batch (Windows FILETIME granularity can
        // repeat back-to-back ticks).
        var last_task_ns: i128 = 0;

        while (try q.next()) |row| {
            defer row.deinit(allocator);
            const page_id = row.values[0];
            const item_id = row.values[1];
            // Defensive normalization: empty page name → "untitled" (we never
            // want a literal "Design Chat: " with trailing space). COALESCEd
            // above means empty here == the row had no name.
            const page_name_raw = row.values[2];
            const full_task_name = if (std.mem.eql(u8, page_name_raw, ""))
                "Design Chat: untitled"
            else
                try std.fmt.allocPrint(
                    allocator,
                    "Design Chat: {s}",
                    .{page_name_raw},
                );
            defer if (!std.mem.eql(u8, page_name_raw, "")) allocator.free(full_task_name);

            // Generate a unique `task_<unix_nanoseconds>` id.
            var task_id_buf: [64]u8 = undefined;
            const now_ns = helpers.unixTimestampNanos();
            const unique_ns: i128 = if (now_ns <= last_task_ns) last_task_ns + 1 else now_ns;
            last_task_ns = unique_ns;
            const task_id = std.fmt.bufPrint(
                task_id_buf[0..],
                "task_{d}",
                .{unique_ns},
            ) catch return error.BufferTooSmall;

            // Dynamic INSERT + UPDATE per page.
            const insert_sql = try std.fmt.allocPrint(
                allocator,
                "INSERT INTO workspace_item_tasks " ++
                    "(id, name, workspace_item_id, task_type, description) " ++
                    "VALUES ('{s}', '{s}', '{s}', 'standard', '')",
                .{ task_id, full_task_name, item_id },
            );
            defer allocator.free(insert_sql);
            try db.exec(allocator, insert_sql, &[_][]const u8{});

            const update_sql = try std.fmt.allocPrint(
                allocator,
                "UPDATE design_pages SET workspace_item_task_id = '{s}' " ++
                    "WHERE id = '{s}'",
                .{ task_id, page_id },
            );
            defer allocator.free(update_sql);
            try db.exec(allocator, update_sql, &[_][]const u8{});
        }
    }
};

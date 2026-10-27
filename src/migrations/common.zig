const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite_mod = pabrikcore.sqlite;

pub const Backend = pabrikcore.database.Db;

pub const Migration = struct {
    version: u32,
    name: []const u8,
    up: *const fn (db: *Backend, allocator: std.mem.Allocator) anyerror!void,
};

pub const MigrationManager = struct {
    allocator: std.mem.Allocator,
    db: *Backend,
    migrations: std.ArrayList(Migration),

    pub fn init(allocator: std.mem.Allocator, db: *Backend) MigrationManager {
        return .{
            .allocator = allocator,
            .db = db,
            .migrations = .empty,
        };
    }

    pub fn registerMigration(self: *MigrationManager, migration: Migration) !void {
        try self.migrations.append(self.allocator, migration);
    }

    pub fn runMigrations(self: *MigrationManager) !void {
        try self.db.exec(self.allocator, "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL)", &[_][]const u8{});

        const currentVersion = self.getCurrentVersion();

        for (self.migrations.items) |migration| {
            if (migration.version > currentVersion) {
                try migration.up(self.db, self.allocator);
                const versionStr = try std.fmt.allocPrint(self.allocator, "{}", .{migration.version});
                defer self.allocator.free(versionStr);
                try self.db.exec(self.allocator, "INSERT INTO schema_migrations (version, name) VALUES (?, ?)", &.{ versionStr, migration.name });
            }
        }
    }

    fn getCurrentVersion(self: *MigrationManager) u32 {
        var rows = self.db.query(self.allocator, "SELECT MAX(version) FROM schema_migrations", &[_][]const u8{}) catch return 0;
        defer rows.deinit();
        if (rows.next() catch return 0) |row| {
            defer row.deinit(self.allocator);
            if (row.values[0].len > 0) {
                return std.fmt.parseInt(u32, row.values[0], 10) catch 0;
            }
        }
        return 0;
    }

    pub fn deinit(self: *MigrationManager) void {
        self.migrations.deinit(self.allocator);
    }
};

/// Add a column to a table if it doesn't already exist. SQLite's `ALTER TABLE
/// ...
pub fn addColumnIfMissing(
    db: pabrikcore.database.DbOrTx,
    allocator: std.mem.Allocator,
    table: []const u8,
    column: []const u8,
    definition: []const u8,
) !void {
    // Stack-buffer the two SQL strings. Both are tiny — a few dozen
    // bytes each. Avoiding the heap keeps the helper zero-alloc and
    // safe to call from any migration.
    var check_buf: [256]u8 = undefined;
    const check_sql = std.fmt.bufPrint(
        &check_buf,
        "SELECT 1 FROM pragma_table_info('{s}') WHERE name = '{s}'",
        .{ table, column },
    ) catch return error.BufferTooSmall;
    var q = try db.query(allocator, check_sql, &.{});
    defer q.deinit();
    if ((try q.next())) |row| {
        // Row returned (column exists) — free the row's values (allocated via
        // `allocator` per Sqlite.zig:267) before returning.
        row.deinit(allocator);
        return;
    }
    // column does not exist — fall through to ALTER below.

    var ddl_buf: [256]u8 = undefined;
    const ddl = std.fmt.bufPrint(
        &ddl_buf,
        "ALTER TABLE {s} ADD COLUMN {s}",
        .{ table, definition },
    ) catch return error.BufferTooSmall;
    try db.exec(allocator, ddl, &.{});
}

/// Drop a column from a table if it exists. SQLite's `ALTER TABLE ...
pub fn dropColumnIfExists(
    db: pabrikcore.database.DbOrTx,
    allocator: std.mem.Allocator,
    table: []const u8,
    column: []const u8,
) !void {
    var check_buf: [256]u8 = undefined;
    const check_sql = std.fmt.bufPrint(
        &check_buf,
        "SELECT 1 FROM pragma_table_info('{s}') WHERE name = '{s}'",
        .{ table, column },
    ) catch return error.BufferTooSmall;
    var q = try db.query(allocator, check_sql, &.{});
    defer q.deinit();
    const row = (try q.next()) orelse {
        // Column doesn't exist — no-op.
        return;
    };
    // Column exists — free the row's values before issuing the
    // DROP statement (see addColumnIfMissing for the rationale).
    row.deinit(allocator);

    var ddl_buf: [256]u8 = undefined;
    const ddl = std.fmt.bufPrint(
        &ddl_buf,
        "ALTER TABLE {s} DROP COLUMN {s}",
        .{ table, column },
    ) catch return error.BufferTooSmall;
    try db.exec(allocator, ddl, &.{});
}

/// Rename a column on a table if the old column exists and the new column
/// does NOT exist.
pub fn renameColumnIfExists(
    db: pabrikcore.database.DbOrTx,
    allocator: std.mem.Allocator,
    table: []const u8,
    old_column: []const u8,
    new_column: []const u8,
) !void {
    // Probe: does the OLD column exist?
    var old_buf: [256]u8 = undefined;
    const old_check = std.fmt.bufPrint(
        &old_buf,
        "SELECT 1 FROM pragma_table_info('{s}') WHERE name = '{s}'",
        .{ table, old_column },
    ) catch return error.BufferTooSmall;
    var q_old = try db.query(allocator, old_check, &.{});
    defer q_old.deinit();
    const old_row = (try q_old.next()) orelse {
        // OLD column doesn't exist — no-op (fresh-DB already has
        // the new name, or a re-run after the rename succeeded).
        return;
    };
    // OLD column exists — free the row's values before the next probe.
    old_row.deinit(allocator);

    // Probe: does the NEW column already exist?
    var new_buf: [256]u8 = undefined;
    const new_check = std.fmt.bufPrint(
        &new_buf,
        "SELECT 1 FROM pragma_table_info('{s}') WHERE name = '{s}'",
        .{ table, new_column },
    ) catch return error.BufferTooSmall;
    var q_new = try db.query(allocator, new_check, &.{});
    defer q_new.deinit();
    const new_row = (try q_new.next()) orelse {
        // NEW column does NOT exist — proceed with the RENAME below.
        // Fall through.
        var ddl_buf: [256]u8 = undefined;
        const ddl = std.fmt.bufPrint(
            &ddl_buf,
            "ALTER TABLE {s} RENAME COLUMN {s} TO {s}",
            .{ table, old_column, new_column },
        ) catch return error.BufferTooSmall;
        try db.exec(allocator, ddl, &.{});
        return;
    };
    // NEW column already exists — defensive no-op.
    new_row.deinit(allocator);
}

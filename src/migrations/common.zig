const std = @import("std");
const pabrikcore = @import("pabrikcore");

pub const Backend = pabrikcore.database.Db;
pub const is_postgres = dialect.is_postgres;
pub const dialect = pabrikcore.dialect;

pub const Migration = struct {
    version: u32,
    name: []const u8,
    up: *const fn (db: *Backend, allocator: std.mem.Allocator) anyerror!void,
};

pub const MigrationManager = struct {
    allocator: std.mem.Allocator,
    db: *Backend,
    migrations: std.ArrayList(Migration),
    /// The migration `runMigrations` is applying, or 0. Set BEFORE `up`, because
    /// the `schema_migrations` row lands only after it succeeds: a caller that
    /// catches the error is the only thing that can name the migration.
    running_version: u32 = 0,
    running_name: []const u8 = "",

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
        try self.db.exec(self.allocator, "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TIMESTAMP)", &[_][]const u8{});

        const currentVersion = self.getCurrentVersion();

        for (self.migrations.items) |migration| {
            if (migration.version > currentVersion) {
                self.running_version = migration.version;
                self.running_name = migration.name;
                try migration.up(self.db, self.allocator);
                const versionStr = try std.fmt.allocPrint(self.allocator, "{}", .{migration.version});
                defer self.allocator.free(versionStr);
                try self.recordApplied(versionStr, migration.name);
                self.running_version = 0;
                self.running_name = "";
            }
        }
    }

    fn recordApplied(self: *MigrationManager, versionStr: []const u8, name: []const u8) !void {
        const has_applied_at = dialect.columnExists(.{ .db = self.db }, self.allocator, "schema_migrations", "applied_at") catch false;
        if (has_applied_at) {
            try self.db.exec(self.allocator, "INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, CURRENT_TIMESTAMP)", &.{ versionStr, name });
            return;
        }
        try self.db.exec(self.allocator, "INSERT INTO schema_migrations (version, name) VALUES (?, ?)", &.{ versionStr, name });
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

/// Add `column` with `definition` unless the table already has it.
pub fn addColumnIfMissing(
    db: pabrikcore.database.DbOrTx,
    allocator: std.mem.Allocator,
    table: []const u8,
    column: []const u8,
    definition: []const u8,
) !void {
    if (try dialect.columnExists(db, allocator, table, column)) return;

    var ddl_buf: [256]u8 = undefined;
    const ddl = std.fmt.bufPrint(&ddl_buf, "ALTER TABLE {s} ADD COLUMN {s}", .{ table, definition }) catch
        return error.BufferTooSmall;
    try db.exec(allocator, ddl, &.{});
}

/// Drop `column` if the table still has it.
pub fn dropColumnIfExists(
    db: pabrikcore.database.DbOrTx,
    allocator: std.mem.Allocator,
    table: []const u8,
    column: []const u8,
) !void {
    if (!try dialect.columnExists(db, allocator, table, column)) return;

    var ddl_buf: [256]u8 = undefined;
    const ddl = std.fmt.bufPrint(&ddl_buf, "ALTER TABLE {s} DROP COLUMN {s}", .{ table, column }) catch
        return error.BufferTooSmall;
    try db.exec(allocator, ddl, &.{});
}

/// Rename `old_column` to `new_column`, unless the old name is gone or the
/// new one already exists — either way the migration has nothing left to do.
pub fn renameColumnIfExists(
    db: pabrikcore.database.DbOrTx,
    allocator: std.mem.Allocator,
    table: []const u8,
    old_column: []const u8,
    new_column: []const u8,
) !void {
    if (!try dialect.columnExists(db, allocator, table, old_column)) return;
    if (try dialect.columnExists(db, allocator, table, new_column)) return;

    var ddl_buf: [256]u8 = undefined;
    const ddl = std.fmt.bufPrint(&ddl_buf, "ALTER TABLE {s} RENAME COLUMN {s} TO {s}", .{ table, old_column, new_column }) catch
        return error.BufferTooSmall;
    try db.exec(allocator, ddl, &.{});
}

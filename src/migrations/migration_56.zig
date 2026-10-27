const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration056UpgradeDesignPagesToFileModel = struct {
    pub const version: u32 = 56;
    pub const name = "upgrade_design_pages_to_file_model";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // CREATE design_pages (fresh-DB path). On a legacy DB that
        // already has the v1 table, this is a no-op (CREATE TABLE IF
        // NOT EXISTS).
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS design_pages (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL,
            \\    name TEXT NOT NULL DEFAULT '',
            \\    width INTEGER NOT NULL DEFAULT 1440,
            \\    height INTEGER NOT NULL DEFAULT 1024,
            \\    x INTEGER NOT NULL DEFAULT 0,
            \\    y INTEGER NOT NULL DEFAULT 0,
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});

        // Upgrade path: drop legacy `html` column from Migration 055
        // if present. SQLite 3.35+ supports DROP COLUMN. No-op on
        // fresh DBs.
        try dropColumnIfExists(.{ .db = db }, allocator, "design_pages", "html");

        // Ensure the 4 new position columns exist.
        try addColumnIfMissing(.{ .db = db }, allocator, "design_pages", "width", "width INTEGER NOT NULL DEFAULT 1440");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_pages", "height", "height INTEGER NOT NULL DEFAULT 1024");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_pages", "x", "x INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_pages", "y", "y INTEGER NOT NULL DEFAULT 0");

        // CREATE design_page_elements (new in v5/v6). Always new —
        // no upgrade path needed.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS design_page_elements (
            \\    id TEXT PRIMARY KEY,
            \\    page_id TEXT NOT NULL,
            \\    name TEXT NOT NULL DEFAULT '',
            \\    file_path TEXT NOT NULL DEFAULT '',
            \\    x INTEGER NOT NULL DEFAULT 0,
            \\    y INTEGER NOT NULL DEFAULT 0,
            \\    width INTEGER NOT NULL DEFAULT 375,
            \\    height INTEGER NOT NULL DEFAULT 667,
            \\    z_index INTEGER NOT NULL DEFAULT 0,
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});

        // Indexes. CREATE [UNIQUE] INDEX IF NOT EXISTS — all safe
        // to re-run.
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_design_pages_item_name " ++
            "ON design_pages(workspace_item_id, name)",
            &[_][]const u8{},
        );
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_design_pages_item_position " ++
            "ON design_pages(workspace_item_id, position)",
            &[_][]const u8{},
        );
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_design_page_elements_page_z_pos " ++
            "ON design_page_elements(page_id, z_index, position)",
            &[_][]const u8{},
        );

        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

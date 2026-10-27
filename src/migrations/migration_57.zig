const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration057AddDesignElementProperties = struct {
    pub const version: u32 = 57;
    pub const name = "add_design_element_properties";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Visual property columns.
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "type",
            "type TEXT NOT NULL DEFAULT 'rectangle'");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "rotation",
            "rotation REAL NOT NULL DEFAULT 0");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "fill",
            "fill TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "stroke",
            "stroke TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "stroke_width",
            "stroke_width INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "corner_radius",
            "corner_radius INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "opacity",
            "opacity REAL NOT NULL DEFAULT 1.0");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "text_content",
            "text_content TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "text_style",
            "text_style TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "image_url",
            "image_url TEXT NOT NULL DEFAULT ''");
        try addColumnIfMissing(.{ .db = db }, allocator, "design_page_elements", "parent_id",
            "parent_id TEXT");

        // Analyze so the query planner sees the new columns on
        // legacy DBs.
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};

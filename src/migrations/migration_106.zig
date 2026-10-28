const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

/// Migration 106 - create the models.dev model catalog cache. The catalog is
/// 227 providers / 8,562 models of pure metadata: each model's context
/// window, output cap, reasoning shape and price.
pub const Migration106CreateModelCatalog = struct {
    pub const version: u32 = 106;
    pub const name = "create_model_catalog";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS model_catalog_providers (
            \\    id TEXT NOT NULL PRIMARY KEY,
            \\    name TEXT,
            \\    base_url TEXT,
            \\    url_style TEXT,
            \\    env_json TEXT
            \\)
        , &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS model_catalog_models (
            \\    provider_id TEXT NOT NULL,
            \\    model_id TEXT NOT NULL,
            \\    name TEXT,
            \\    context_window INTEGER,
            \\    output_tokens INTEGER,
            \\    reasoning TEXT,
            \\    effort_json TEXT,
            \\    budget_min INTEGER,
            \\    temperature INTEGER,
            \\    cost_input REAL,
            \\    cost_output REAL,
            \\    PRIMARY KEY (provider_id, model_id)
            \\)
        , &[_][]const u8{});

        // A bare model name is resolved by looking up this index, so the
        // "which providers ship this model id?" question stays cheap.
        try db.exec(allocator,
            \\CREATE INDEX IF NOT EXISTS idx_model_catalog_models_model
            \\    ON model_catalog_models (model_id)
        , &[_][]const u8{});

        const ddl = try std.fmt.allocPrint(allocator,
            \\CREATE TABLE IF NOT EXISTS model_catalog_meta (
            \\    id INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
            \\    schema_version INTEGER NOT NULL,
            \\    source TEXT,
            \\    fetched_at_ms {s} NOT NULL,
            \\    provider_count INTEGER NOT NULL DEFAULT 0,
            \\    model_count INTEGER NOT NULL DEFAULT 0
            \\)
        , .{dialect.epoch_type});
        defer allocator.free(ddl);
        try db.exec(allocator, ddl, &[_][]const u8{});
    }
};

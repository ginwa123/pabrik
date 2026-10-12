const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;

/// Migration 106 - create the models.dev model catalog cache.
///
/// The catalog is 227 providers / 8,562 models of pure metadata: each model's
/// context window, output cap, reasoning shape and price. Pabrik needs the
/// context window server-side (it is what decides when a chat compacts), so the
/// catalog has to be readable without a network round-trip — it is fetched in
/// the background and read from here.
///
/// WHY THE DB AND NOT A JSON FILE
///
/// A file cache and a table are the same shape for a reader, but only one of
/// them is queryable, transactional, and already backed up with the rest of the
/// app's state. Keeping both would be two sources of truth for the same 8,562
/// rows, and the first time they disagreed nobody would be able to say which
/// one was lying. There is exactly one store.
///
/// THREE DELIBERATE CHOICES, EACH PINNED BY A TEST
///
///   1. Every TEXT column except the PRIMARY KEY parts is NULLABLE, and reads
///      use `COALESCE(col, '')`. That is not sloppiness: this backend binds an
///      EMPTY SLICE as SQL NULL, so `base_url = ''` (25 of 227 providers,
///      `anthropic` among them, have no api URL) would either trip a NOT NULL
///      constraint on insert or silently never match a `WHERE base_url = ?`.
///      NULLABLE + COALESCE is the one shape that makes "no base url" both
///      writable and readable.
///
///   2. `model_catalog_meta` is a single row (`CHECK (id = 1)`). It carries the
///      freshness facts the UI shows ("via models.dev, synced 2h ago") and the
///      schema version, so a catalog written by another pabrik build is
///      DETECTED rather than mis-read. A missing meta row means "never synced",
///      which is different from "synced zero models".
///
///   3. Models are keyed `(provider_id, model_id)`, not by model id alone.
///      `deepseek-flash` is shipped by several providers with different
///      endpoints, so a bare model id is not a key — it is a question.
pub const Migration106CreateModelCatalog = struct {
    pub const version: u32 = 106;
    pub const name = "create_model_catalog";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
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

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS model_catalog_meta (
            \\    id INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
            \\    schema_version INTEGER NOT NULL,
            \\    source TEXT,
            \\    fetched_at_ms INTEGER NOT NULL,
            \\    provider_count INTEGER NOT NULL DEFAULT 0,
            \\    model_count INTEGER NOT NULL DEFAULT 0
            \\)
        , &[_][]const u8{});
    }
};

const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

pub const Migration101GuardLlmHistoryModel = struct {
    pub const version: u32 = 101;
    pub const name = "guard_llm_history_model";

    /// The sentinel written when no model could be resolved.
    pub const sentinel: []const u8 = "unknown";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        // Backfill first so the trigger (which only fires on INSERT) does not
        // have to reason about rows that already exist.
        try tx.exec(allocator,
            \\UPDATE llm_history SET model = 'unknown'
            \\WHERE model IS NULL OR TRIM(model) = ''
        , &[_][]const u8{});

        // The backstop. Catches raw SQL (which the Zig guard cannot see) and
        // any future write site that forgets the guard. Postgres needs a
        // trigger function; sqlite inlines the body.
        if (dialect.is_postgres) {
            try tx.exec(allocator,
                \\CREATE OR REPLACE FUNCTION llm_history_guard_model() RETURNS trigger AS $guard$
                \\BEGIN
                \\  IF NEW.model IS NULL OR TRIM(NEW.model) = '' THEN
                \\    NEW.model := 'unknown';
                \\  END IF;
                \\  RETURN NEW;
                \\END
                \\$guard$ LANGUAGE plpgsql
            , &[_][]const u8{});
            try tx.exec(allocator,
                \\CREATE OR REPLACE TRIGGER llm_history_ai_model_not_empty
                \\BEFORE INSERT ON llm_history
                \\FOR EACH ROW EXECUTE FUNCTION llm_history_guard_model()
            , &[_][]const u8{});
            try tx.commit();
            return;
        }

        try tx.exec(allocator,
            \\CREATE TRIGGER IF NOT EXISTS llm_history_ai_model_not_empty
            \\AFTER INSERT ON llm_history
            \\FOR EACH ROW WHEN NEW.model IS NULL OR TRIM(NEW.model) = ''
            \\BEGIN
            \\  UPDATE llm_history SET model = 'unknown' WHERE id = NEW.id;
            \\END
        , &[_][]const u8{});

        try tx.commit();
    }
};

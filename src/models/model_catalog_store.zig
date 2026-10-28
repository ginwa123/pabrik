//! `model_catalog_store` — the durable half of the models.dev catalog.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const dialect = pabrikcore.dialect;
const catalog = @import("../agentic_loop/model_catalog.zig");

const Allocator = std.mem.Allocator;

pub const Meta = struct {
    schema_version: u32,
    source: []const u8,
    fetched_at_ms: i64,
    provider_count: u32,
    model_count: u32,
};

pub const SaveStats = struct {
    providers: usize,
    models: usize,
};

/// Replace the whole catalog in ONE transaction. Replace-not-merge is
/// deliberate: a refresh is a snapshot of an external source of truth, and a
/// model deleted upstream must disappear here too.
pub fn saveCatalog(db: *database.Db, alloc: Allocator, cat: *const catalog.Catalog) !SaveStats {
    try db.exec(alloc, dialect.begin_write, &.{});
    errdefer db.exec(alloc, "ROLLBACK", &.{}) catch {};

    try db.exec(alloc, "DELETE FROM model_catalog_models", &.{});
    try db.exec(alloc, "DELETE FROM model_catalog_providers", &.{});
    try db.exec(alloc, "DELETE FROM model_catalog_meta", &.{});

    const provider_sql =
        \\INSERT INTO model_catalog_providers (id, name, base_url, url_style, env_json)
        \\VALUES (?, ?, ?, ?, ?)
    ;
    const model_sql =
        \\INSERT INTO model_catalog_models
        \\  (provider_id, model_id, name, context_window, output_tokens, reasoning,
        \\   effort_json, budget_min, temperature, cost_input, cost_output)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ;

    var ctx_buf: [24]u8 = undefined;
    var out_buf: [24]u8 = undefined;
    var budget_buf: [24]u8 = undefined;
    var temp_buf: [8]u8 = undefined;
    var cost_in_buf: [32]u8 = undefined;
    var cost_out_buf: [32]u8 = undefined;

    var provider_count: usize = 0;
    var pit = cat.providers.iterator();
    while (pit.next()) |entry| {
        const p = entry.value_ptr.*;
        const env_json = try std.json.Stringify.valueAlloc(alloc, p.env, .{});
        defer alloc.free(env_json);
        try db.exec(alloc, provider_sql, &.{ p.id, p.name, p.base_url, p.url_style, env_json });
        provider_count += 1;
    }

    var model_count: usize = 0;
    var mit = cat.models.iterator();
    while (mit.next()) |entry| {
        const m = entry.value_ptr.*;
        const effort_json = try std.json.Stringify.valueAlloc(alloc, m.effort_values, .{});
        defer alloc.free(effort_json);
        const temp = std.fmt.bufPrint(&temp_buf, "{d}", .{@as(u8, if (m.temperature) 1 else 0)}) catch "0";
        try db.exec(alloc, model_sql, &.{
            m.provider_id,
            m.model_id,
            m.model_name,
            nullOr(&ctx_buf, m.context_window),
            nullOr(&out_buf, m.output_tokens),
            catalog.reasoningKindName(m.reasoning),
            effort_json,
            nullOr(&budget_buf, m.budget_min),
            temp,
            nullF64(&cost_in_buf, if (m.cost) |c| c.input else null),
            nullF64(&cost_out_buf, if (m.cost) |c| c.output else null),
        });
        model_count += 1;
    }

    var counts_buf: [24]u8 = undefined;
    var ms_buf: [24]u8 = undefined;
    try db.exec(alloc,
        \\INSERT INTO model_catalog_meta
        \\  (id, schema_version, source, fetched_at_ms, provider_count, model_count)
        \\VALUES (1, ?, ?, ?, ?, ?)
    , &.{
        std.fmt.bufPrint(&counts_buf, "{d}", .{catalog.SCHEMA_VERSION}) catch "0",
        cat.source,
        std.fmt.bufPrint(&ms_buf, "{d}", .{cat.fetched_at_ms}) catch "0",
        std.fmt.bufPrint(&out_buf, "{d}", .{provider_count}) catch "0",
        std.fmt.bufPrint(&budget_buf, "{d}", .{model_count}) catch "0",
    });

    try db.exec(alloc, "COMMIT", &.{});
    return .{ .providers = provider_count, .models = model_count };
}

/// The freshness row. `null` means "never synced" — which the UI must render
/// differently from "synced, zero models".
pub fn loadMeta(db: *database.Db, alloc: Allocator) !?Meta {
    var rows = try db.query(alloc,
        \\SELECT schema_version, COALESCE(source, ''), fetched_at_ms,
        \\       provider_count, model_count
        \\FROM model_catalog_meta WHERE id = 1
    , &.{});
    defer rows.deinit();

    const row = (try rows.next()) orelse return null;
    defer row.deinit(alloc);

    return .{
        .schema_version = std.fmt.parseInt(u32, row.values[0], 10) catch 0,
        .source = try alloc.dupe(u8, row.values[1]),
        .fetched_at_ms = std.fmt.parseInt(i64, row.values[2], 10) catch 0,
        .provider_count = std.fmt.parseInt(u32, row.values[3], 10) catch 0,
        .model_count = std.fmt.parseInt(u32, row.values[4], 10) catch 0,
    };
}

pub fn freeMeta(alloc: Allocator, meta: *const Meta) void {
    alloc.free(meta.source);
}

/// Load the whole catalog into an in-memory `Catalog`. `null` when there is
/// no usable catalog: no meta row (never synced), or a meta row written by
/// another schema version.
pub fn loadCatalog(db: *database.Db, alloc: Allocator) !?*catalog.Catalog {
    // `std.json.parseFromSliceLeaky` is LEAKY BY DESIGN — it wants an
    // allocator whose memory is released wholesale, not one that has to free
    // each piece.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const meta = try loadMeta(db, alloc) orelse return null;
    defer freeMeta(alloc, &meta);
    if (meta.schema_version != catalog.SCHEMA_VERSION) return null;

    const cat = try alloc.create(catalog.Catalog);
    errdefer alloc.destroy(cat);
    cat.* = catalog.Catalog.init(alloc);
    errdefer cat.deinit();
    try cat.setMeta(meta.fetched_at_ms, meta.source);

    // Provider names are needed on every model row; resolve them once.
    var names = std.StringArrayHashMapUnmanaged([]const u8){};
    defer {
        for (names.values()) |v| alloc.free(v);
        for (names.keys()) |k| alloc.free(k);
        names.deinit(alloc);
    }

    {
        var rows = try db.query(alloc,
            \\SELECT id, COALESCE(name, ''), COALESCE(base_url, ''),
            \\       COALESCE(url_style, 'openai'), COALESCE(env_json, '[]')
            \\FROM model_catalog_providers
        , &.{});
        defer rows.deinit();

        while (try rows.next()) |row| {
            defer row.deinit(alloc);
            const id = row.values[0];
            const name = row.values[1];

            const env = std.json.parseFromSliceLeaky([]const []const u8, sa, row.values[4], .{
                .ignore_unknown_fields = true,
            }) catch &[_][]const u8{};

            try cat.putProvider(.{
                .id = id,
                .name = if (name.len > 0) name else id,
                .base_url = row.values[2],
                .url_style = if (row.values[3].len > 0) row.values[3] else "openai",
                .env = env,
            });
            try names.put(alloc, try alloc.dupe(u8, id), try alloc.dupe(u8, if (name.len > 0) name else id));
        }
    }

    {
        var rows = try db.query(alloc,
            \\SELECT provider_id, model_id, COALESCE(name, ''),
            \\       context_window, output_tokens, COALESCE(reasoning, 'none'),
            \\       COALESCE(effort_json, '[]'), budget_min, temperature,
            \\       cost_input, cost_output
            \\FROM model_catalog_models ORDER BY provider_id, model_id
        , &.{});
        defer rows.deinit();

        while (try rows.next()) |row| {
            defer row.deinit(alloc);
            const provider_id = row.values[0];

            const effort = std.json.parseFromSliceLeaky([]const []const u8, sa, row.values[6], .{
                .ignore_unknown_fields = true,
            }) catch &[_][]const u8{};

            const provider_name = names.get(provider_id) orelse provider_id;
            const base_url = blk: {
                if (cat.provider(provider_id)) |p| break :blk p.base_url;
                break :blk "";
            };
            const url_style = blk: {
                if (cat.provider(provider_id)) |p| break :blk p.url_style;
                break :blk "openai";
            };

            try cat.putModel(.{
                .provider_id = provider_id,
                .provider_name = provider_name,
                .model_id = row.values[1],
                .model_name = if (row.values[2].len > 0) row.values[2] else row.values[1],
                .base_url = base_url,
                .url_style = url_style,
                .context_window = parseIntU32(row.values[3]),
                .output_tokens = parseIntU32(row.values[4]),
                .reasoning = catalog.parseReasoningKind(row.values[5]),
                .effort_values = effort,
                .budget_min = parseIntU32(row.values[7]),
                .temperature = std.mem.eql(u8, row.values[8], "1"),
                .cost = if (parseFloat(row.values[9]) orelse parseFloat(row.values[10])) |in|
                    catalog.Cost{ .input = in, .output = parseFloat(row.values[10]) orelse 0 }
                else
                    null,
            });
        }
    }

    return cat;
}

/// `""` binds as SQL NULL in this backend, which is the correct encoding of
/// "unknown context window" — not 0, which is a real (if useless) value.
fn nullOr(buf: []u8, v: ?u32) []const u8 {
    const value = v orelse return "";
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "";
}

fn nullF64(buf: []u8, v: ?f64) []const u8 {
    const value = v orelse return "";
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "";
}

fn parseIntU32(raw: []const u8) ?u32 {
    if (raw.len == 0) return null;
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn parseFloat(raw: []const u8) ?f64 {
    if (raw.len == 0) return null;
    return std.fmt.parseFloat(f64, raw) catch null;
}

// ============================================================================
// Tests — in-memory SQLite, the same TestCtx shape the other stores use.

const testing = std.testing;
const Migration106 = @import("../migrations/migration.zig").Migration106CreateModelCatalog;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,

    fn deinit(self: *TestCtx) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    try Migration106.up(&db, testing.allocator);
    return .{ .db = db, .threaded = threaded };
}

/// One provider with an endpoint and one without, plus a model whose window is
/// unknown — the same three states the real catalog contains.
fn buildFixture(alloc: Allocator) !*catalog.Catalog {
    const cat = try alloc.create(catalog.Catalog);
    errdefer alloc.destroy(cat);
    cat.* = catalog.Catalog.init(alloc);
    errdefer cat.deinit();
    try cat.setMeta(1_760_000_000_000, catalog.SOURCE_URL);

    try cat.putProvider(.{
        .id = "deepseek",
        .name = "DeepSeek",
        .base_url = "https://api.deepseek.com",
        .url_style = "openai",
        .env = &.{"DEEPSEEK_API_KEY"},
    });
    try cat.putProvider(.{
        .id = "anthropic",
        .name = "Anthropic",
        .base_url = "", // 25 of 227 providers, anthropic among them
        .url_style = "anthropic",
        .env = &.{},
    });

    try cat.putModel(.{
        .provider_id = "deepseek",
        .provider_name = "DeepSeek",
        .model_id = "deepseek-flash",
        .model_name = "DeepSeek V4.1 Flash",
        .base_url = "https://api.deepseek.com",
        .url_style = "openai",
        .context_window = 1_000_000,
        .output_tokens = 393_216,
        .reasoning = .effort,
        .effort_values = &.{ "low", "high", "max" },
        .temperature = true,
        .cost = .{ .input = 0.15, .output = 0.6 },
    });
    try cat.putModel(.{
        .provider_id = "anthropic",
        .provider_name = "Anthropic",
        .model_id = "claude-haiku-4-5",
        .model_name = "Claude Haiku 4.5",
        .base_url = "",
        .url_style = "anthropic",
        .context_window = 200_000,
        .output_tokens = 64_000,
        .reasoning = .budget_tokens,
        .budget_min = 1024,
        .temperature = false,
    });
    // No window, no cost — models.dev has 160 such models.
    try cat.putModel(.{
        .provider_id = "deepseek",
        .provider_name = "DeepSeek",
        .model_id = "mystery-model",
        .model_name = "Mystery",
        .base_url = "https://api.deepseek.com",
        .url_style = "openai",
    });

    return cat;
}

test "ModelCatalogStore: a catalog round-trips through the database" {
    var ctx = try setupDb();
    defer ctx.deinit();
    const alloc = testing.allocator;

    const before = try buildFixture(alloc);
    defer catalog.freeCatalog(alloc, before);

    const saved = try saveCatalog(&ctx.db, alloc, before);
    try testing.expectEqual(@as(usize, 2), saved.providers);
    try testing.expectEqual(@as(usize, 3), saved.models);

    const after = (try loadCatalog(&ctx.db, alloc)) orelse return error.TestUnexpectedResult;
    defer catalog.freeCatalog(alloc, after);

    try testing.expectEqual(@as(usize, 2), after.providerCount());
    try testing.expectEqual(@as(usize, 3), after.modelCount());

    const m = after.lookup("deepseek", "deepseek-flash") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1_000_000), m.context_window.?);
    try testing.expectEqual(@as(u32, 393_216), m.output_tokens.?);
    try testing.expectEqual(catalog.ReasoningKind.effort, m.reasoning);
    try testing.expect(m.temperature);
    try testing.expectEqual(@as(f64, 0.15), m.cost.?.input);

    // A model that never declared a window must come back as `null`, not 0 —
    // 0 would make the compaction threshold 80% of nothing.
    const mystery = after.lookup("deepseek", "mystery-model") orelse return error.TestUnexpectedResult;
    try testing.expect(mystery.context_window == null);
    try testing.expect(mystery.output_tokens == null);
    try testing.expect(mystery.cost == null);
    try testing.expectEqual(catalog.ReasoningKind.none, mystery.reasoning);
    try testing.expect(!mystery.temperature);
}

test "ModelCatalogStore: an empty base URL survives as empty, and a real one as itself" {
    var ctx = try setupDb();
    defer ctx.deinit();
    const alloc = testing.allocator;

    const before = try buildFixture(alloc);
    defer catalog.freeCatalog(alloc, before);
    _ = try saveCatalog(&ctx.db, alloc, before);

    const after = (try loadCatalog(&ctx.db, alloc)) orelse return error.TestUnexpectedResult;
    defer catalog.freeCatalog(alloc, after);

    // The landmine: `''` binds as SQL NULL. Reads COALESCE it back.
    const a = after.provider("anthropic") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("", a.base_url);
    try testing.expectEqualStrings("anthropic", a.url_style);

    const d = after.provider("deepseek") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("https://api.deepseek.com", d.base_url);
    try testing.expectEqual(@as(usize, 1), d.env.len);
    try testing.expectEqualStrings("DEEPSEEK_API_KEY", d.env[0]);
}

test "ModelCatalogStore: meta reports freshness and counts, and is absent before the first sync" {
    var ctx = try setupDb();
    defer ctx.deinit();
    const alloc = testing.allocator;

    // Nothing synced yet: absent, NOT an empty catalog.
    try testing.expect(try loadMeta(&ctx.db, alloc) == null);
    try testing.expect(try loadCatalog(&ctx.db, alloc) == null);

    const cat = try buildFixture(alloc);
    defer catalog.freeCatalog(alloc, cat);
    _ = try saveCatalog(&ctx.db, alloc, cat);

    const meta = (try loadMeta(&ctx.db, alloc)) orelse return error.TestUnexpectedResult;
    defer freeMeta(alloc, &meta);
    try testing.expectEqual(catalog.SCHEMA_VERSION, meta.schema_version);
    try testing.expectEqualStrings(catalog.SOURCE_URL, meta.source);
    try testing.expectEqual(@as(i64, 1_760_000_000_000), meta.fetched_at_ms);
    try testing.expectEqual(@as(u32, 2), meta.provider_count);
    try testing.expectEqual(@as(u32, 3), meta.model_count);
}

test "ModelCatalogStore: a save REPLACES the snapshot, it does not merge" {
    var ctx = try setupDb();
    defer ctx.deinit();
    const alloc = testing.allocator;

    const first = try buildFixture(alloc);
    defer catalog.freeCatalog(alloc, first);
    _ = try saveCatalog(&ctx.db, alloc, first);

    // Upstream deleted two models and added one provider. A merge would keep
    // rows nobody can explain; a snapshot must not.
    const second = try alloc.create(catalog.Catalog);
    defer catalog.freeCatalog(alloc, second);
    second.* = catalog.Catalog.init(alloc);
    try second.setMeta(1_760_000_999_999, catalog.SOURCE_URL);
    try second.putProvider(.{ .id = "opencode-go", .name = "opencode-go", .base_url = "https://opencode.ai/inference/go/v1", .url_style = "openai" });
    try second.putModel(.{
        .provider_id = "opencode-go",
        .provider_name = "opencode-go",
        .model_id = "deepseek-flash",
        .model_name = "DeepSeek V4.1 Flash (go)",
        .base_url = "https://opencode.ai/inference/go/v1",
        .url_style = "openai",
        .context_window = 1_000_000,
    });

    const saved = try saveCatalog(&ctx.db, alloc, second);
    try testing.expectEqual(@as(usize, 1), saved.providers);
    try testing.expectEqual(@as(usize, 1), saved.models);

    const after = (try loadCatalog(&ctx.db, alloc)) orelse return error.TestUnexpectedResult;
    defer catalog.freeCatalog(alloc, after);
    try testing.expectEqual(@as(usize, 1), after.providerCount());
    try testing.expect(after.provider("deepseek") == null);
    try testing.expect(after.lookup("opencode-go", "deepseek-flash") != null);
}

test "ModelCatalogStore: a catalog written by another schema version is not loaded" {
    var ctx = try setupDb();
    defer ctx.deinit();
    const alloc = testing.allocator;

    const cat = try buildFixture(alloc);
    defer catalog.freeCatalog(alloc, cat);
    _ = try saveCatalog(&ctx.db, alloc, cat);

    // Another pabrik build wrote this table.
    try ctx.db.exec(alloc, "UPDATE model_catalog_meta SET schema_version = 99 WHERE id = 1", &.{});

    try testing.expect(try loadCatalog(&ctx.db, alloc) == null);
    // The meta row is still readable — "there is a catalog, we just cannot read
    // it" is information the UI needs, not an absence.
    const meta = (try loadMeta(&ctx.db, alloc)) orelse return error.TestUnexpectedResult;
    defer freeMeta(alloc, &meta);
    try testing.expectEqual(@as(u32, 99), meta.schema_version);
}

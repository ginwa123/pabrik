//! Functional tests for the models.dev model catalog (Migration 106).
//!
//! WHY THIS SUITE EXISTS. `model_catalog.zig` and `model_catalog_store.zig`
//! already prove the parsing and the storage in isolation. What they cannot
//! prove is the WIRE: that `GET /api/models/resolve` reports the catalog's
//! window instead of pabrik's built-in guess, and — just as important — that it
//! SAYS WHICH ONE IT USED. A user looking at `200000` has to be able to tell
//! "this model really is 200k" from "we have no idea".
//!
//! Both halves matter, and the SECOND one is the one that rots silently:
//!
//!   1. a seeded snapshot  -> context_window 1_000_000, source "catalog"
//!   2. no snapshot at all -> context_window   200_000, source "builtin",
//!                            catalog "absent"
//!
//! Each test boots a real binary against an isolated tmpdir HOME (the harness
//! picks a random port in 20000..32000 and never touches 8081).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// The storage contract the resolve endpoint reads. Written out here on purpose
/// rather than reusing the migration: if someone changes the columns, this test
/// must fail LOUDLY rather than quietly agree with the new shape.
const SEED_SQL =
    \\CREATE TABLE IF NOT EXISTS model_catalog_providers (
    \\  id TEXT NOT NULL PRIMARY KEY, name TEXT, base_url TEXT, url_style TEXT, env_json TEXT);
    \\CREATE TABLE IF NOT EXISTS model_catalog_models (
    \\  provider_id TEXT NOT NULL, model_id TEXT NOT NULL, name TEXT,
    \\  context_window INTEGER, output_tokens INTEGER, reasoning TEXT,
    \\  effort_json TEXT, budget_min INTEGER, temperature INTEGER,
    \\  cost_input REAL, cost_output REAL,
    \\  PRIMARY KEY (provider_id, model_id));
    \\CREATE TABLE IF NOT EXISTS model_catalog_meta (
    \\  id INTEGER NOT NULL PRIMARY KEY CHECK (id = 1), schema_version INTEGER NOT NULL,
    \\  source TEXT, fetched_at_ms INTEGER NOT NULL,
    \\  provider_count INTEGER NOT NULL DEFAULT 0, model_count INTEGER NOT NULL DEFAULT 0);
    \\INSERT OR REPLACE INTO model_catalog_providers (id, name, base_url, url_style, env_json)
    \\  VALUES ('deepseek', 'DeepSeek', 'https://api.deepseek.com', 'openai', '["DEEPSEEK_API_KEY"]');
    \\INSERT OR REPLACE INTO model_catalog_models
    \\  (provider_id, model_id, name, context_window, output_tokens, reasoning, effort_json, temperature, cost_input, cost_output)
    \\  VALUES ('deepseek', 'deepseek-flash', 'DeepSeek V4.1 Flash', 1000000, 393216, 'effort', '["low","high","max"]', 1, 0.15, 0.6);
    \\INSERT OR REPLACE INTO model_catalog_meta (id, schema_version, source, fetched_at_ms, provider_count, model_count)
    \\  VALUES (1, 1, 'https://models.dev/api.json', 4102444800000, 1, 1);
;

/// Seed a pre-migrated catalog before the binary starts.
///
/// `fetched_at_ms` above is deliberately in the FAR FUTURE so the freshness
/// check cannot call the snapshot stale as the years roll by.
fn seedCatalog(seed_io: std.Io, allocator: std.mem.Allocator, temp_dir: []const u8) anyerror!void {
    const dir = try harness.harnessPath(allocator, temp_dir, &.{ ".config", "pabrik" });
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(seed_io, dir);

    const db_path = try std.fs.path.join(allocator, &.{ dir, "agent.db" });
    defer allocator.free(db_path);

    var child = try std.process.spawn(seed_io, .{
        .argv = &.{ "sqlite3", db_path, SEED_SQL },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(seed_io);
    switch (term) {
        .exited => |code| if (code != 0) return error.SqliteSeedFailed,
        else => return error.SqliteSeedFailed,
    }
}

test "model catalog: with no snapshot the resolve falls back to 200k AND SAYS SO" {
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch {};

    var res = try h.http(io, .GET, "/api/models/resolve?model=deepseek-flash", .{});
    defer res.deinit();
    try testing.expectEqual(@as(u16, 200), res.status);

    var doc = try res.json();
    defer doc.deinit();

    // The built-in guess, reported as a guess. n
    try testing.expectEqual(@as(i64, 200_000), doc.int("context_window").?);
    try testing.expectEqualStrings("builtin", doc.str("source").?);
    try testing.expectEqualStrings("absent", doc.str("catalog").?);
    // The reason reaches the wire, so the UI can render it instead of inventing
    // its own copy (and so a support request can quote it).
    try testing.expect(doc.str("reason") != null);
}

test "model catalog: a seeded snapshot makes the resolve answer 1,000,000" {
    var h = try Harness.boot(io, gpa, .{
        .stub_llm_profile = true,
        .pre_boot_setup = &seedCatalog,
    });
    defer h.deinit(io) catch {};

    var res = try h.http(io, .GET, "/api/models/resolve?model=deepseek-flash", .{});
    defer res.deinit();
    try testing.expectEqual(@as(u16, 200), res.status);

    var doc = try res.json();
    defer doc.deinit();

    // THE BUG THIS WHOLE CHANGE EXISTS TO FIX: before the catalog, this
    // answered 200_000 and every non-MiniMax profile compacted at 160k.
    try testing.expectEqual(@as(i64, 1_000_000), doc.int("context_window").?);
    try testing.expectEqualStrings("catalog", doc.str("source").?);
    try testing.expectEqual(@as(i64, 393_216), doc.int("output_tokens").?);
    try testing.expectEqualStrings("deepseek", doc.str("provider_id").?);
    try testing.expectEqualStrings("https://api.deepseek.com", doc.str("base_url").?);
    try testing.expectEqualStrings("openai", doc.str("url_style").?);
    try testing.expectEqualStrings("effort", doc.str("reasoning").?);
}

test "model catalog: an unknown model is 200k in a LIVE catalog, not a fabricated window" {
    var h = try Harness.boot(io, gpa, .{
        .stub_llm_profile = true,
        .pre_boot_setup = &seedCatalog,
    });
    defer h.deinit(io) catch {};

    var res = try h.http(io, .GET, "/api/models/resolve?model=some-self-hosted-thing", .{});
    defer res.deinit();
    try testing.expectEqual(@as(u16, 200), res.status);

    var doc = try res.json();
    defer doc.deinit();

    // `catalog` is fresh — the snapshot exists — but THIS model is not in it.
    // Reporting "absent" here would be a different lie.
    try testing.expectEqualStrings("fresh", doc.str("catalog").?);
    try testing.expectEqualStrings("builtin", doc.str("source").?);
    try testing.expectEqual(@as(i64, 200_000), doc.int("context_window").?);
}

test "model catalog: the picker lists what the snapshot holds, with the window on each row" {
    var h = try Harness.boot(io, gpa, .{
        .stub_llm_profile = true,
        .pre_boot_setup = &seedCatalog,
    });
    defer h.deinit(io) catch {};

    var res = try h.http(io, .GET, "/api/models/catalog?q=deepseek&limit=10", .{});
    defer res.deinit();
    try testing.expectEqual(@as(u16, 200), res.status);

    var doc = try res.json();
    defer doc.deinit();

    try testing.expectEqual(@as(i64, 1), doc.int("total").?);
    const models = doc.array("models") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), models.items.len);
    const row = models.items[0].object;
    try testing.expectEqualStrings("deepseek-flash", row.get("model_id").?.string);
    try testing.expectEqual(@as(i64, 1_000_000), row.get("context_window").?.integer);
}

test "model catalog: resolve without a model is a 400, not a 200 with a made-up number" {
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch {};

    // `expect` because the harness asserts the status for you — and the 400 IS
    // the assertion here: a missing `model` must not fall through to a 200
    // carrying a made-up window.
    var res = try h.http(io, .GET, "/api/models/resolve", .{ .expect = &.{400} });
    defer res.deinit();
    try testing.expectEqual(@as(u16, 400), res.status);

    var doc = try res.json();
    defer doc.deinit();
    try testing.expectEqualStrings("model is required", doc.str("error").?);
}

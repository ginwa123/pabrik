//! `model_catalog_refresh` — the network half of the model catalog. Three
//! jobs, and nothing else: 1. `loadAtBoot` — read the DB into the in-memory
//! index.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const catalog = @import("model_catalog.zig");
const store = @import("../models/model_catalog_store.zig");
const http_client = @import("kabelweb").client;

/// models.dev's payload was 5,451,834 bytes on 2026-10-13. 32 MiB is headroom
/// for a busy catalog, not a target.
pub const MAX_FETCH_BYTES: usize = 32 * 1024 * 1024;

/// One hour, in nanoseconds.
pub const SYNC_INTERVAL_NS: i96 = 3_600 * 1_000_000_000;

pub const Report = struct {
    providers: usize,
    models: usize,
    fetched_at_ms: i64,
    bytes_raw: usize,
    bytes_trimmed: usize,
};

pub const FetchError = error{
    /// models.dev answered, but not with a 200.
    CatalogFetchStatus,
};

/// Fetch models.dev and install the result. Every failure propagates — the
/// manual endpoint reports it, the timer logs it. Neither invents a fallback.
pub fn refresh(alloc: Allocator, io: std.Io, db: *sqlite.SqliteBackend) !Report {
    var client = http_client.Client.init(alloc);
    var resp = try http_client.get(&client, catalog.SOURCE_URL, .{
        .timeout_ms = 60_000,
        .connect_timeout_ms = 15_000,
        .follow_redirects = true,
        .max_body_bytes = MAX_FETCH_BYTES,
        .user_agent = "pabrik-model-catalog/1.0",
    });
    defer resp.deinit(alloc);

    if (resp.status_code != 200) return FetchError.CatalogFetchStatus;

    const fetched_at_ms = std.Io.Clock.now(.real, io).toMilliseconds();
    const trimmed = try catalog.trimRawPayload(alloc, resp.body, fetched_at_ms);
    defer alloc.free(trimmed);

    const cat = try alloc.create(catalog.Catalog);
    errdefer alloc.destroy(cat);
    cat.* = try catalog.Catalog.fromCacheJson(alloc, trimmed);
    errdefer cat.deinit();

    // An empty catalog is a broken fetch, not a fact. Refuse it rather than
    // trading a good snapshot for nothing.
    if (cat.providerCount() == 0 or cat.modelCount() == 0) return FetchError.CatalogFetchStatus;

    const saved = try store.saveCatalog(db, alloc, cat);

    // Only now is the new snapshot the truth.
    catalog.setSingleton(cat, alloc);

    return .{
        .providers = saved.providers,
        .models = saved.models,
        .fetched_at_ms = fetched_at_ms,
        .bytes_raw = resp.body.len,
        .bytes_trimmed = trimmed.len,
    };
}

/// Read the DB into the in-memory index. Returns whether a catalog was
/// installed. Called once, from boot, on the main thread.
pub fn loadAtBoot(alloc: Allocator, db: *sqlite.SqliteBackend) bool {
    const cat = store.loadCatalog(db, alloc) catch |err| {
        std.log.warn("model catalog: could not read the cached catalog: {s}", .{@errorName(err)});
        return false;
    };
    const loaded = cat orelse {
        std.log.info("model catalog: no cached catalog yet — the built-in 200k window applies until the first sync", .{});
        return false;
    };
    catalog.setSingleton(loaded, alloc);
    std.log.info(
        "model catalog: {d} providers / {d} models loaded from the database",
        .{ loaded.providerCount(), loaded.modelCount() },
    );
    return true;
}

/// Detached hourly sync. Nothing joins it; it dies with the process.
pub fn startBackgroundSync(alloc: Allocator, db: *sqlite.SqliteBackend) void {
    const thread = std.Thread.spawn(.{}, backgroundLoop, .{ alloc, db }) catch |err| {
        std.log.warn("model catalog: background sync not started: {s}", .{@errorName(err)});
        return;
    };
    thread.detach();
    std.log.info("model catalog: background sync every {d} minutes", .{SYNC_INTERVAL_NS / (60 * 1_000_000_000)});
}

fn backgroundLoop(alloc: Allocator, db: *sqlite.SqliteBackend) void {
    // Its OWN io instance: `std.Io.Threaded` is not shareable across threads,
    // and the timer must not borrow the server's.
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    while (true) {
        std.Io.sleep(io, .{ .nanoseconds = SYNC_INTERVAL_NS }, .awake) catch return;
        refreshOnceWithLog(alloc, io, db);
    }
}

/// The timer's refresh: same call the manual endpoint makes, with the error
/// turned into a log line instead of an HTTP body.
pub fn refreshOnceWithLog(alloc: Allocator, io: std.Io, db: *sqlite.SqliteBackend) void {
    const report = refresh(alloc, io, db) catch |err| {
        std.log.warn("model catalog: scheduled sync failed ({s}); keeping the previous snapshot", .{@errorName(err)});
        return;
    };
    std.log.info(
        "model catalog: synced {d} providers / {d} models ({d} -> {d} bytes)",
        .{ report.providers, report.models, report.bytes_raw, report.bytes_trimmed },
    );
}

//! `model_catalog_refresh` — the network half of the model catalog: read the
//! cached snapshot at boot, fetch models.dev on a timer, and RECORD what the last
//! attempt did so "why is there no catalog yet?" has an answer.

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

/// The loop's FIRST wait: a boot that read NO snapshot fetches NOW, because an
/// hour of silence leaves every profile on the built-in window (and a server
/// restarted more often than hourly would never fetch at all).
pub fn firstDelayNs(have_snapshot: bool) i96 {
    return if (have_snapshot) SYNC_INTERVAL_NS else 0;
}

/// The gate's decision, split from the environment read so a test can cover it
/// on every host. OFF only on an explicit `"0"`: a wrong default there silently
/// empties the catalog.
fn gateAllows(value: ?[]const u8) bool {
    const v = value orelse return true;
    return !std.mem.eql(u8, v, "0");
}

/// `PABRIK_MODEL_CATALOG_FETCH=0` disables the fetch. `Harness.boot` sets it,
/// since a functional-test child boots with no snapshot and would otherwise make
/// one live 5 MB request per spawned server. Production never sets it.
fn fetchingEnabled() bool {
    const value: ?[]const u8 = if (std.c.getenv("PABRIK_MODEL_CATALOG_FETCH")) |z| std.mem.span(z) else null;
    return gateAllows(value);
}

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

/// What the last `refresh` did, for the READ side to report. `error_name` is
/// `@errorName`'s static string: nothing to free, no lifetime to get wrong.
pub const LastAttempt = struct {
    /// 0 = nothing attempted in this process yet.
    at_ms: i64 = 0,
    ok: bool = false,
    /// `""` until an attempt fails.
    error_name: []const u8 = "",
    providers: usize = 0,
    models: usize = 0,
};

var last_attempt: LastAttempt = .{};

/// Zig 0.16 removed `std.Thread.Mutex`; `std.atomic.Mutex` plus a spin loop is
/// what the rest of this directory uses (see `stream_snapshot.zig`).
var last_attempt_mu: std.atomic.Mutex = .unlocked;

fn lastAttemptLock() void {
    while (!last_attempt_mu.tryLock()) std.atomic.spinLoopHint();
}

/// A COPY, taken under the lock: `refresh` runs on the timer's thread while
/// handlers read this, and a torn pair would read as a failure that succeeded.
pub fn lastAttempt() LastAttempt {
    lastAttemptLock();
    defer last_attempt_mu.unlock();
    return last_attempt;
}

fn recordAttempt(attempt: LastAttempt) void {
    lastAttemptLock();
    defer last_attempt_mu.unlock();
    last_attempt = attempt;
}

/// Fetch models.dev and install the result. Every failure propagates — the
/// endpoint reports it, the timer logs it — and BOTH record it: an empty catalog
/// whose syncs failed silently reads exactly like one that was never tried.
pub fn refresh(alloc: Allocator, io: std.Io, db: *sqlite.SqliteBackend) !Report {
    const report = fetchAndInstall(alloc, io, db) catch |err| {
        recordAttempt(.{
            .at_ms = std.Io.Clock.now(.real, io).toMilliseconds(),
            .ok = false,
            .error_name = @errorName(err),
        });
        return err;
    };
    recordAttempt(.{
        .at_ms = report.fetched_at_ms,
        .ok = true,
        .providers = report.providers,
        .models = report.models,
    });
    return report;
}

fn fetchAndInstall(alloc: Allocator, io: std.Io, db: *sqlite.SqliteBackend) !Report {
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

/// Detached sync timer. Nothing joins it; it dies with the process.
/// `loadAtBoot` runs first, so the FIRST fetch is immediate when boot had nothing
/// to read and waits the interval when it did.
pub fn startBackgroundSync(alloc: Allocator, db: *sqlite.SqliteBackend) void {
    if (!fetchingEnabled()) {
        std.log.info("model catalog: background sync disabled (PABRIK_MODEL_CATALOG_FETCH=0)", .{});
        return;
    }

    const have_snapshot = catalog.getSingleton() != null;
    const first_delay_ns = firstDelayNs(have_snapshot);
    const thread = std.Thread.spawn(.{}, backgroundLoop, .{ alloc, db, first_delay_ns }) catch |err| {
        std.log.warn("model catalog: background sync not started: {s}", .{@errorName(err)});
        return;
    };
    thread.detach();
    std.log.info("model catalog: background sync every {d} minutes", .{SYNC_INTERVAL_NS / (60 * 1_000_000_000)});
    if (!have_snapshot) {
        std.log.info("model catalog: nothing cached — fetching models.dev now", .{});
    }
}

fn backgroundLoop(alloc: Allocator, db: *sqlite.SqliteBackend, first_delay_ns: i96) void {
    // Its OWN io instance: `std.Io.Threaded` is not shareable across threads,
    // and the timer must not borrow the server's.
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var delay_ns = first_delay_ns;
    while (true) {
        if (delay_ns > 0) std.Io.sleep(io, .{ .nanoseconds = delay_ns }, .awake) catch return;
        delay_ns = SYNC_INTERVAL_NS;
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

// ============================================================================
// Behaviour tests

const testing = std.testing;

test "model catalog refresh: a boot WITH a snapshot waits an interval, one WITHOUT waits zero" {
    // The snapshot is the whole difference: boot already loaded it, so there is
    // nothing to fetch yet. With nothing loaded, the hour of silence is what
    // left the DB empty and every profile on the built-in window.
    try testing.expectEqual(SYNC_INTERVAL_NS, firstDelayNs(true));
    try testing.expectEqual(@as(i96, 0), firstDelayNs(false));
}

test "model catalog refresh: only an explicit '0' turns the background fetch off" {
    try testing.expect(gateAllows(null)); // unset = on, which is production
    try testing.expect(gateAllows("1"));
    try testing.expect(gateAllows(""));
    try testing.expect(!gateAllows("0"));
}

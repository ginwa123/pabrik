//! The models.dev catalog over HTTP.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const catalog = pabrikcore.model_catalog;
const store = pabrikcore.model_catalog_store;
const refresh_mod = pabrikcore.model_catalog_refresh;
const llm_models = pabrikcore.llm_models;
const opencode = @import("../agentic_loop/opencode.zig");
const helpers = @import("helpers");

/// The picker's page size when the caller does not say. Small on purpose: the
/// client is a combobox, and it narrows by typing.
const DEFAULT_LIMIT: u32 = 50;
const MAX_LIMIT: u32 = 500;

/// Twice the sync interval: one missed tick is normal, two means something is
/// wrong and the number in the UI may be out of date.
const STALE_AFTER_MS: i64 = 2 * 60 * 60 * 1000;

const CLI_MODELS_TIMEOUT_MS: u32 = 20_000;

const CLI_MODELS_MAX_BYTES: usize = 512 * 1024;

const CatalogState = enum {
    fresh,
    stale,
    absent,

    fn name(self: CatalogState) []const u8 {
        return @tagName(self);
    }
};

fn jsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

fn err(allocator: std.mem.Allocator, status: u16, res: gserverz.HttpResponse, msg: []const u8) !gserverz.HttpResponse {
    return res.jsonResponse(.{
        .status_code = status,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = msg }),
    });
}

/// The last sync attempt's FAILURE, when it failed — absent when it succeeded or
/// never ran, since an empty string reads as "failed for no reason". This is what
/// lets the profile editor answer "no catalog yet — why?".
fn writeLastSync(w: *std.Io.Writer, attempt: refresh_mod.LastAttempt) !void {
    if (attempt.ok or attempt.error_name.len == 0) return;
    try w.writeAll(",\"last_sync_error\":");
    try jsonStr(w, attempt.error_name);
    try w.writeAll(",\"last_sync_at_ms\":");
    try w.print("{d}", .{attempt.at_ms});
}

/// Freshness of the cached snapshot. `absent` when nothing was ever synced —
/// which is NOT the same as "synced, zero models", and the UI must not render
/// them the same way.
fn catalogState(allocator: std.mem.Allocator, io: std.Io, db: anytype) CatalogState {
    const meta = store.loadMeta(db, allocator) catch return .absent;
    const m = meta orelse return .absent;
    defer store.freeMeta(allocator, &m);

    const now_ms = std.Io.Clock.now(.real, io).toMilliseconds();
    if (now_ms - m.fetched_at_ms > STALE_AFTER_MS) return .stale;
    return .fresh;
}

// ============================================================================
// GET /api/models/catalog
// ============================================================================

const Row = struct {
    provider_id: []const u8,
    provider_name: []const u8,
    model_id: []const u8,
    model_name: []const u8,
    context_window: ?u32 = null,
    output_tokens: ?u32 = null,
    reasoning: catalog.ReasoningKind = .none,
    temperature: bool = false,
    cost: ?catalog.Cost = null,
    is_free: bool = false,
};

fn freeOf(cost: ?catalog.Cost, model_id: []const u8) bool {
    if (cost) |c| {
        if (opencode.isFreeFromCost(c.input, c.output)) |known| return known;
    }
    return opencode.isFreeModelId(model_id);
}

fn rowLessThan(_: void, a: Row, b: Row) bool {
    const by_free = opencode.freeRank(a.is_free);
    const by_free_other = opencode.freeRank(b.is_free);
    if (by_free != by_free_other) return by_free < by_free_other;
    const by_provider = std.mem.order(u8, a.provider_id, b.provider_id);
    if (by_provider != .eq) return by_provider == .lt;
    return std.mem.order(u8, a.model_id, b.model_id) == .lt;
}

fn rowMatches(row: Row, q: []const u8) bool {
    if (q.len == 0) return true;
    if (std.ascii.indexOfIgnoreCase(row.model_id, q) != null) return true;
    if (std.ascii.indexOfIgnoreCase(row.model_name, q) != null) return true;
    return std.ascii.indexOfIgnoreCase(row.provider_id, q) != null;
}

const CliListing = struct {
    rows: []Row = &.{},
    refs: []opencode.ModelRef = &.{},
    error_name: []const u8 = "",
};

fn cliCatalogRows(
    allocator: std.mem.Allocator,
    io: std.Io,
    cat: ?*const catalog.Catalog,
) !CliListing {
    const binary = opencode.resolveBinaryPath("");
    const argv = try opencode.buildModelsListArgs(allocator, binary);
    defer opencode.freeArgs(allocator, argv);

    var result = helpers.run_captured.run(allocator, io, argv, .{
        .timeout_ms = CLI_MODELS_TIMEOUT_MS,
        .max_output_bytes = CLI_MODELS_MAX_BYTES,
    }) catch |spawn_err| return .{ .error_name = @errorName(spawn_err) };
    defer result.deinit(allocator);

    switch (result.term) {
        .exited => |code| if (code != 0) return .{ .error_name = "CliExitedNonZero" },
        else => return .{ .error_name = "CliKilled" },
    }

    const refs = try opencode.parseModelsList(allocator, result.stdout);
    const rows = try allocator.alloc(Row, refs.len);
    var filled: usize = 0;
    errdefer {
        for (rows[0..filled]) |row| allocator.free(row.model_id);
        allocator.free(rows);
        opencode.freeModelsList(allocator, refs);
    }

    for (refs) |ref| {
        const qualified = try std.mem.concat(allocator, u8, &.{ ref.provider, "/", ref.model });
        const facts: ?*const catalog.ModelFacts = if (cat) |c| c.lookup(ref.provider, ref.model) else null;
        rows[filled] = .{
            .provider_id = ref.provider,
            .provider_name = if (facts) |f| f.provider_name else ref.provider,
            .model_id = qualified,
            .model_name = if (facts) |f| f.model_name else ref.model,
            .context_window = if (facts) |f| f.context_window else null,
            .output_tokens = if (facts) |f| f.output_tokens else null,
            .reasoning = if (facts) |f| f.reasoning else .none,
            .temperature = if (facts) |f| f.temperature else false,
            .cost = if (facts) |f| f.cost else null,
            .is_free = freeOf(if (facts) |f| f.cost else null, ref.model),
        };
        filled += 1;
    }

    return .{ .rows = rows, .refs = refs };
}

fn freeCliListing(allocator: std.mem.Allocator, listing: CliListing) void {
    for (listing.rows) |row| allocator.free(row.model_id);
    if (listing.rows.len > 0) allocator.free(listing.rows);
    opencode.freeModelsList(allocator, listing.refs);
}

pub fn modelsCatalogHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();

    const q = req.query.get("q") orelse "";
    const provider_filter = req.query.get("provider");
    const wants_cli = blk: {
        const backend = req.query.get("backend") orelse break :blk false;
        break :blk std.mem.eql(u8, backend, "opencode");
    };
    const limit_raw = req.query.get("limit") orelse "";
    const limit: u32 = blk: {
        if (limit_raw.len == 0) break :blk DEFAULT_LIMIT;
        const v = std.fmt.parseInt(u32, limit_raw, 10) catch break :blk DEFAULT_LIMIT;
        break :blk @min(v, MAX_LIMIT);
    };

    const cat = catalog.getSingleton();
    const state = catalogState(allocator, ctx.io, di.db);

    var cli_error: []const u8 = "";
    var cli_listing: CliListing = .{};
    defer freeCliListing(allocator, cli_listing);
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);
    var source: []const u8 = "models.dev";

    if (wants_cli) {
        cli_listing = cliCatalogRows(allocator, ctx.io, cat) catch CliListing{ .error_name = "OutOfMemory" };
        if (cli_listing.error_name.len == 0 and cli_listing.rows.len > 0) {
            source = "opencode-cli";
            for (cli_listing.rows) |row| {
                if (provider_filter) |p| {
                    if (p.len > 0 and !std.ascii.eqlIgnoreCase(p, row.provider_id)) continue;
                }
                if (!rowMatches(row, q)) continue;
                try rows.append(allocator, row);
            }
        } else {
            cli_error = if (cli_listing.error_name.len > 0) cli_listing.error_name else "CliListedNoModels";
        }
    }

    if (rows.items.len == 0) {
        if (cat) |c| {
            var it = c.models.iterator();
            while (it.next()) |entry| {
                const m = entry.value_ptr;
                if (provider_filter) |p| {
                    if (p.len > 0 and !std.ascii.eqlIgnoreCase(p, m.provider_id)) continue;
                }
                if (q.len > 0) {
                    const in_id = std.ascii.indexOfIgnoreCase(m.model_id, q) != null;
                    const in_name = std.ascii.indexOfIgnoreCase(m.model_name, q) != null;
                    if (!in_id and !in_name) continue;
                }
                try rows.append(allocator, .{
                    .provider_id = m.provider_id,
                    .provider_name = m.provider_name,
                    .model_id = m.model_id,
                    .model_name = m.model_name,
                    .context_window = m.context_window,
                    .output_tokens = m.output_tokens,
                    .reasoning = m.reasoning,
                    .temperature = m.temperature,
                    .cost = m.cost,
                    .is_free = freeOf(m.cost, m.model_id),
                });
            }
        }
    }

    std.mem.sort(Row, rows.items, {}, rowLessThan);

    const total = rows.items.len;
    const returned = @min(@as(usize, limit), total);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.print("{{\"total\":{d},\"returned\":{d},\"catalog\":", .{ total, returned });
    try jsonStr(w, state.name());
    try w.writeAll(",\"source\":");
    try jsonStr(w, source);
    if (cli_error.len > 0) {
        try w.writeAll(",\"cli_error\":");
        try jsonStr(w, cli_error);
    }
    if (cat) |c| {
        try w.writeAll(",\"fetched_at_ms\":");
        try w.print("{d}", .{c.fetched_at_ms});
    }
    try writeLastSync(w, refresh_mod.lastAttempt());
    try w.writeAll(",\"models\":[");
    for (rows.items[0..returned], 0..) |row, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"provider_id\":");
        try jsonStr(w, row.provider_id);
        try w.writeAll(",\"provider_name\":");
        try jsonStr(w, row.provider_name);
        try w.writeAll(",\"model_id\":");
        try jsonStr(w, row.model_id);
        try w.writeAll(",\"model_name\":");
        try jsonStr(w, row.model_name);
        try w.writeAll(",\"context_window\":");
        if (row.context_window) |c| try w.print("{d}", .{c}) else try w.writeAll("null");
        try w.writeAll(",\"output_tokens\":");
        if (row.output_tokens) |o| try w.print("{d}", .{o}) else try w.writeAll("null");
        try w.writeAll(",\"reasoning\":");
        try jsonStr(w, catalog.reasoningKindName(row.reasoning));
        try w.writeAll(",\"temperature\":");
        try w.writeAll(if (row.temperature) "true" else "false");
        try w.writeAll(",\"free\":");
        try w.writeAll(if (row.is_free) "true" else "false");
        if (row.cost) |c| {
            try w.writeAll(",\"cost\":{\"input\":");
            try w.print("{d}", .{c.input});
            try w.writeAll(",\"output\":");
            try w.print("{d}", .{c.output});
            try w.writeByte('}');
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");

    return res.jsonResponse(.{ .status_code = 200, .data = try aw.toOwnedSlice() });
}

// ============================================================================
// GET /api/models/resolve
// ============================================================================

pub fn modelsResolveHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();

    var model = req.query.get("model") orelse "";
    if (model.len == 0) return err(allocator, 400, res, "model is required");
    var provider = req.query.get("provider");

    if (provider == null or provider.?.len == 0) {
        if (std.mem.indexOfScalar(u8, model, '/')) |slash| {
            if (slash > 0 and slash + 1 < model.len) {
                provider = model[0..slash];
                model = model[slash + 1 ..];
            }
        }
    }

    const cat = catalog.getSingleton();
    const state = catalogState(allocator, ctx.io, di.db);

    // No catalog ⇒ say so, and hand back the built-in guess explicitly. This is
    // today's behaviour made legible instead of a confidently wrong number.
    const facts: ?*const catalog.ModelFacts = if (cat) |c| c.lookup(provider, model) else null;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"model\":");
    try jsonStr(w, model);
    try w.writeAll(",\"catalog\":");
    try jsonStr(w, state.name());

    const f = facts orelse {
        try w.writeAll(",\"source\":\"builtin\",\"context_window\":");
        try w.print("{d}", .{llm_models.getModelTokenCount(model)});
        try w.writeAll(",\"reason\":");
        try jsonStr(w, if (state == .absent)
            "no catalog yet — the built-in window applies until the first sync"
        else
            "this model is not in the catalog — the built-in window applies");
        try writeLastSync(w, refresh_mod.lastAttempt());
        try w.writeAll("}");
        return res.jsonResponse(.{ .status_code = 200, .data = try aw.toOwnedSlice() });
    };

    try w.writeAll(",\"source\":");
    try jsonStr(w, if (f.context_window != null) "catalog" else "builtin");
    try w.writeAll(",\"provider_id\":");
    try jsonStr(w, f.provider_id);
    try w.writeAll(",\"provider_name\":");
    try jsonStr(w, f.provider_name);
    try w.writeAll(",\"model_name\":");
    try jsonStr(w, f.model_name);
    try w.writeAll(",\"base_url\":");
    try jsonStr(w, f.base_url);
    try w.writeAll(",\"url_style\":");
    try jsonStr(w, f.url_style);
    try w.writeAll(",\"context_window\":");
    if (f.context_window) |c| try w.print("{d}", .{c}) else {
        try w.print("{d}", .{llm_models.getModelTokenCount(model)});
    }
    try w.writeAll(",\"output_tokens\":");
    if (f.output_tokens) |o| try w.print("{d}", .{o}) else try w.writeAll("null");
    try w.writeAll(",\"reasoning\":");
    try jsonStr(w, catalog.reasoningKindName(f.reasoning));
    try w.writeAll(",\"effort_values\":[");
    for (f.effort_values, 0..) |v, i| {
        if (i > 0) try w.writeByte(',');
        try jsonStr(w, v);
    }
    try w.writeAll("],\"effort_values_sendable\":[");
    for (f.effort_values_sendable, 0..) |v, i| {
        if (i > 0) try w.writeByte(',');
        try jsonStr(w, v);
    }
    try w.writeAll("],\"budget_min\":");
    if (f.budget_min) |b| try w.print("{d}", .{b}) else try w.writeAll("null");
    try w.writeAll(",\"temperature\":");
    try w.writeAll(if (f.temperature) "true" else "false");
    try w.writeAll(",\"cost\":");
    if (f.cost) |c| {
        try w.writeAll("{\"input\":");
        try w.print("{d}", .{c.input});
        try w.writeAll(",\"output\":");
        try w.print("{d}", .{c.output});
        try w.writeByte('}');
    } else try w.writeAll("null");
    try w.writeAll(",\"fetched_at_ms\":");
    try w.print("{d}", .{cat.?.fetched_at_ms});
    try writeLastSync(w, refresh_mod.lastAttempt());
    try w.writeByte('}');

    return res.jsonResponse(.{ .status_code = 200, .data = try aw.toOwnedSlice() });
}

// ============================================================================
// POST /api/models/refresh
// ============================================================================

pub fn modelsRefreshHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = req;
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();

    const report = refresh_mod.refresh(allocator, ctx.io, di.db) catch |e| {
        // The reason reaches the caller. A "refresh failed" that hides WHY is
        // the failure mode this endpoint exists to avoid.
        return err(allocator, 502, res, @errorName(e));
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.fmt.allocPrint(allocator, "{{\"ok\":true,\"providers\":{d},\"models\":{d},\"fetched_at_ms\":{d},\"bytes_raw\":{d},\"bytes_trimmed\":{d}}}", .{ report.providers, report.models, report.fetched_at_ms, report.bytes_raw, report.bytes_trimmed }),
    });
}

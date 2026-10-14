//! The models.dev catalog over HTTP.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const catalog = pabrikcore.model_catalog;
const store = pabrikcore.model_catalog_store;
const refresh_mod = pabrikcore.model_catalog_refresh;
const llm_models = pabrikcore.llm_models;

/// The picker's page size when the caller does not say. Small on purpose: the
/// client is a combobox, and it narrows by typing.
const DEFAULT_LIMIT: u32 = 50;
const MAX_LIMIT: u32 = 500;

/// Twice the sync interval: one missed tick is normal, two means something is
/// wrong and the number in the UI may be out of date.
const STALE_AFTER_MS: i64 = 2 * 60 * 60 * 1000;

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

pub fn modelsCatalogHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();

    const q = req.query.get("q") orelse "";
    const provider_filter = req.query.get("provider");
    const limit_raw = req.query.get("limit") orelse "";
    const limit: u32 = blk: {
        if (limit_raw.len == 0) break :blk DEFAULT_LIMIT;
        const v = std.fmt.parseInt(u32, limit_raw, 10) catch break :blk DEFAULT_LIMIT;
        break :blk @min(v, MAX_LIMIT);
    };

    // Narrow (or absent) catalog: an empty list plus the reason, never a 500.
    // "No catalog yet" is a state the picker has to be able to draw.
    const cat = catalog.getSingleton() orelse {
        return res.jsonResponse(.{
            .status_code = 200,
            .data = try std.fmt.allocPrint(allocator,
                "{{\"total\":0,\"returned\":0,\"models\":[],\"catalog\":\"{s}\"}}",
                .{(catalogState(allocator, ctx.io, di.db)).name()}),
        });
    };

    // Collect matches, then sort, then page. Sorting before paging is what
    // makes `limit=50` mean the same 50 rows on every call.
    var hits = std.ArrayList(*const catalog.ModelFacts).empty;
    defer hits.deinit(allocator);

    var it = cat.models.iterator();
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
        try hits.append(allocator, m);
    }

    std.mem.sort(*const catalog.ModelFacts, hits.items, {}, struct {
        fn lt(_: void, a: *const catalog.ModelFacts, b: *const catalog.ModelFacts) bool {
            const by_provider = std.mem.order(u8, a.provider_id, b.provider_id);
            if (by_provider != .eq) return by_provider == .lt;
            return std.mem.order(u8, a.model_id, b.model_id) == .lt;
        }
    }.lt);

    const total = hits.items.len;
    const returned = @min(@as(usize, limit), total);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.print("{{\"total\":{d},\"returned\":{d},\"catalog\":", .{ total, returned });
    try jsonStr(w, catalogState(allocator, ctx.io, di.db).name());
    try w.writeAll(",\"fetched_at_ms\":");
    try w.print("{d}", .{cat.fetched_at_ms});
    try w.writeAll(",\"models\":[");
    for (hits.items[0..returned], 0..) |m, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"provider_id\":");
        try jsonStr(w, m.provider_id);
        try w.writeAll(",\"provider_name\":");
        try jsonStr(w, m.provider_name);
        try w.writeAll(",\"model_id\":");
        try jsonStr(w, m.model_id);
        try w.writeAll(",\"model_name\":");
        try jsonStr(w, m.model_name);
        try w.writeAll(",\"context_window\":");
        if (m.context_window) |c| try w.print("{d}", .{c}) else try w.writeAll("null");
        try w.writeAll(",\"output_tokens\":");
        if (m.output_tokens) |o| try w.print("{d}", .{o}) else try w.writeAll("null");
        try w.writeAll(",\"reasoning\":");
        try jsonStr(w, catalog.reasoningKindName(m.reasoning));
        try w.writeAll(",\"temperature\":");
        try w.writeAll(if (m.temperature) "true" else "false");
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

    const model = req.query.get("model") orelse "";
    if (model.len == 0) return err(allocator, 400, res, "model is required");
    const provider = req.query.get("provider");

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
        .data = try std.fmt.allocPrint(allocator,
            "{{\"ok\":true,\"providers\":{d},\"models\":{d},\"fetched_at_ms\":{d},\"bytes_raw\":{d},\"bytes_trimmed\":{d}}}",
            .{ report.providers, report.models, report.fetched_at_ms, report.bytes_raw, report.bytes_trimmed }),
    });
}

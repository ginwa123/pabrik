// Exec wrappers for the progressive tool search agent tools
// (`search_tool` / `view_tool` / `use_tool`) — one file, three exec fns,
// mirroring `tools_exec_skills.zig`.
//
// The catalog these operate on is:
//
//     catalog = (registered built-ins − enabled built-ins − session-equipped)
//               ∪ (mcp tools − session-equipped)
//
// "enabled" comes from `tool_eligibility.allowlistFilter`, the SAME helper the
// workflow uses to build the LLM's tool list — so the catalog can never offer
// a tool the model already has, nor hide one it should be able to reach.
// The item-type policy (kanban ↔ design) is applied too, via
// `tool_eligibility.itemTypeStrip` inside `buildCatalog`.
//
// Plan: docs/superpowers/plans/2026-09-12-progressive-tool-search.md

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const tools_equipped = @import("tools_equipped.zig");
const llm_history = @import("llm_history.zig");
const progressive_catalog = @import("progressive_catalog.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const pmod = pabrikcore.progressive_tools;
const wrapToolOutput = tools.wrapToolOutput;

const MAX_DID_YOU_MEAN = 3;

/// Everything the three adapters need to resolve the catalog. Built once per
/// dispatch (all allocations land on the per-request arena).
const Inputs = struct {
    registered: []const agent.AgentTool,
    mcp: ?[]const agent.AgentTool,
    equipped_names: []const []const u8,
};

fn loadInputs(ctx: ToolExecContext) !Inputs {
    const registered = tools_equipped.equips(ctx.allocator);

    // The live fetch-once MCP cache — the same source the workflow uses and
    // the same one `handle_mcp_tool` dispatches against. Never re-fetch from
    // the servers here.
    const di = pabrikcore.getSingleton() catch null;
    const mcp: ?[]const agent.AgentTool = if (di) |d| d.getMcpToolsCached(ctx.allocator) else null;

    const equipped = try llm_history.getProgressiveTools(ctx.allocator, ctx.db, ctx.session_id);
    const names = try ctx.allocator.alloc([]const u8, equipped.len);
    for (equipped, 0..) |e, i| names[i] = e.tool_name;

    return .{ .registered = registered, .mcp = mcp, .equipped_names = names };
}

/// The workspace item type for this session, or "" when unknown. Borrowed
/// then duped because `getWorkspaceContext` owns its strings.
fn selfItemType(ctx: ToolExecContext) []const u8 {
    const wctx = (llm_history.getWorkspaceContext(ctx.allocator, ctx.db, ctx.session_id) catch return "") orelse return "";
    defer wctx.deinit(ctx.allocator);
    return ctx.allocator.dupe(u8, wctx.self_item_type) catch "";
}

fn buildCatalog(ctx: ToolExecContext, inputs: Inputs) ![]progressive_catalog.Entry {
    return progressive_catalog.buildCatalog(
        ctx.allocator,
        inputs.registered,
        ctx.allowed_tools,
        ctx.is_sub_agent,
        inputs.mcp,
        inputs.equipped_names,
        selfItemType(ctx),
    );
}

/// Mirror `add_mcp_server`'s envelope semantics: an inner `"error"` key makes
/// the wrapper report success=false and surfaces the message as the error,
/// with the full inner JSON still available in `data`.
fn wrapMaybeError(
    ctx: ToolExecContext,
    tool_name: []const u8,
    args_json: []const u8,
    inner: []const u8,
) ![]const u8 {
    if (innerErrorOf(ctx.allocator, inner)) |msg| {
        return wrapToolOutput(ctx.allocator, tool_name, args_json, false, msg, inner);
    }
    return wrapToolOutput(ctx.allocator, tool_name, args_json, true, null, inner);
}

/// The `"error"` string of an inner JSON result, or null when the result
/// carries no error key. Never fails: unparseable output is not an error.
fn innerErrorOf(allocator: std.mem.Allocator, inner: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, inner, .{}) catch return null;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const err = obj.get("error") orelse return null;
    return switch (err) {
        .string => |s| s,
        else => return null,
    };
}

fn result(ctx: ToolExecContext, output: []const u8) ToolExecResult {
    _ = ctx;
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── search_tool ───

pub fn execSearchTool(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        pmod.SearchToolInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        const output = try wrapToolOutput(
            ctx.allocator,
            "search_tool",
            tc.function.arguments,
            false,
            "search_tool failed to parse input (expected {\"query\"?: string, \"literal\"?: bool, \"limit\"?: number, \"offset\"?: number, \"server\"?: string})",
            "",
        );
        return result(ctx, output);
    };
    defer parsed.deinit();

    const query = parsed.value.query orelse "";
    const literal = parsed.value.literal orelse false;
    const server = parsed.value.server orelse "";

    // ── Paging bounds ──
    // Rejected, never silently clamped: the model pages by offset from the
    // `<total>` it was shown, so a quiet clamp would make its next call land
    // on the wrong window. The messages name the accepted range.
    const limit: usize = blk: {
        const raw = parsed.value.limit orelse @as(i64, @intCast(progressive_catalog.DEFAULT_SEARCH_LIMIT));
        if (raw < 1) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "search_tool: limit must be at least 1 (got {d})", .{raw});
            const output = try wrapToolOutput(ctx.allocator, "search_tool", tc.function.arguments, false, msg, "");
            return result(ctx, output);
        }
        if (raw > @as(i64, @intCast(progressive_catalog.MAX_SEARCH_LIMIT))) {
            const msg = try std.fmt.allocPrint(
                ctx.allocator,
                "search_tool: limit must be at most {d} (got {d})",
                .{ progressive_catalog.MAX_SEARCH_LIMIT, raw },
            );
            const output = try wrapToolOutput(ctx.allocator, "search_tool", tc.function.arguments, false, msg, "");
            return result(ctx, output);
        }
        break :blk @intCast(raw);
    };
    const offset: usize = blk: {
        const raw = parsed.value.offset orelse 0;
        if (raw < 0) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "search_tool: offset must not be negative (got {d})", .{raw});
            const output = try wrapToolOutput(ctx.allocator, "search_tool", tc.function.arguments, false, msg, "");
            return result(ctx, output);
        }
        break :blk @intCast(raw);
    };

    const inputs = try loadInputs(ctx);
    const catalog = try buildCatalog(ctx, inputs);

    // `matchQuery` returns every match (no cap); `pageSlice` + the renderer
    // apply `offset`/`limit`, and `total` is always the pre-page count so the
    // model can page deterministically. The query is a regex unless `literal`
    // says otherwise; a bad pattern degrades to a literal substring match and
    // the outcome carries the warning.
    const outcome = try progressive_catalog.matchQuery(
        ctx.allocator,
        catalog,
        query,
        server,
        .{ .literal = literal },
    );
    const page = progressive_catalog.pageSlice(outcome.entries, offset, limit);
    const inner = try progressive_catalog.renderSearchResult(ctx.allocator, page, .{
        .total = outcome.entries.len,
        .offset = offset,
        .limit = limit,
        .query = query,
        .server = server,
        .mode = outcome.mode,
        .warning = outcome.warning,
    });

    const output = try wrapToolOutput(ctx.allocator, "search_tool", tc.function.arguments, true, null, inner);
    return result(ctx, output);
}

// ─── view_tool (read-only) ───

pub fn execViewTool(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        pmod.ViewToolInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        const output = try wrapToolOutput(
            ctx.allocator,
            "view_tool",
            tc.function.arguments,
            false,
            "view_tool failed to parse input (expected {\"name\": string})",
            "",
        );
        return result(ctx, output);
    };
    defer parsed.deinit();

    const name = std.mem.trim(u8, parsed.value.name orelse "", " ");
    if (name.len == 0) {
        const inner = try progressive_catalog.renderViewToolNotFound(ctx.allocator, "", &.{});
        const output = try wrapMaybeError(ctx, "view_tool", tc.function.arguments, inner);
        return result(ctx, output);
    }

    const inputs = try loadInputs(ctx);

    // 1. Discoverable candidate.
    const catalog = try buildCatalog(ctx, inputs);
    if (progressive_catalog.findByName(catalog, name)) |entry| {
        const inner = try progressive_catalog.renderViewTool(ctx.allocator, entry);
        const output = try wrapToolOutput(ctx.allocator, "view_tool", tc.function.arguments, true, null, inner);
        return result(ctx, output);
    }

    // 2. Already equipped for this session — show it rather than claiming it
    //    is unknown. Read-only either way.
    if (progressive_catalog.findAnyByNameFiltered(inputs.registered, inputs.mcp, name, inputs.equipped_names)) |entry| {
        const inner = try progressive_catalog.renderViewTool(ctx.allocator, entry);
        const output = try wrapToolOutput(ctx.allocator, "view_tool", tc.function.arguments, true, null, inner);
        return result(ctx, output);
    }

    // 3. Unknown → did-you-mean over the catalog. Nothing is written.
    const suggestions = try progressive_catalog.didYouMean(ctx.allocator, catalog, name, MAX_DID_YOU_MEAN);
    const inner = try progressive_catalog.renderViewToolNotFound(ctx.allocator, name, suggestions);
    const output = try wrapMaybeError(ctx, "view_tool", tc.function.arguments, inner);
    return result(ctx, output);
}

// ─── use_tool (equips for the session) ───

pub fn execUseTool(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        pmod.UseToolInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        const output = try wrapToolOutput(
            ctx.allocator,
            "use_tool",
            tc.function.arguments,
            false,
            "use_tool failed to parse input (expected {\"name\": string})",
            "",
        );
        return result(ctx, output);
    };
    defer parsed.deinit();

    const name = std.mem.trim(u8, parsed.value.name orelse "", " ");
    if (name.len == 0) {
        const inner = try progressive_catalog.renderUseToolNotFound(ctx.allocator, "", &.{});
        const output = try wrapMaybeError(ctx, "use_tool", tc.function.arguments, inner);
        return result(ctx, output);
    }

    const inputs = try loadInputs(ctx);

    // ── The validation rule, checked BEFORE anything else ──
    // If it is already equipped for this session there is nothing to insert;
    // report it and write nothing. This also short-circuits the case where the
    // catalog no longer lists the name (it excludes equipped tools).
    if (progressive_catalog.findAnyByNameFiltered(inputs.registered, inputs.mcp, name, inputs.equipped_names)) |already| {
        const inner = try progressive_catalog.renderUseTool(ctx.allocator, already, false);
        const output = try wrapToolOutput(ctx.allocator, "use_tool", tc.function.arguments, true, null, inner);
        return result(ctx, output);
    }

    // Only a catalog hit may be equipped. An unknown name writes nothing.
    const catalog = try buildCatalog(ctx, inputs);
    const entry = progressive_catalog.findByName(catalog, name) orelse {
        const suggestions = try progressive_catalog.didYouMean(ctx.allocator, catalog, name, MAX_DID_YOU_MEAN);
        const inner = try progressive_catalog.renderUseToolNotFound(ctx.allocator, name, suggestions);
        const output = try wrapMaybeError(ctx, "use_tool", tc.function.arguments, inner);
        return result(ctx, output);
    };

    // `saveProgressiveTool` returns whether a row was really inserted; the
    // result's `inserted` flag is derived from that, never assumed.
    const inserted = try llm_history.saveProgressiveTool(
        ctx.allocator,
        ctx.db,
        ctx.logger,
        ctx.session_id,
        entry.name,
        entry.server,
    );

    const inner = try progressive_catalog.renderUseTool(ctx.allocator, entry, inserted);
    const output = try wrapToolOutput(ctx.allocator, "use_tool", tc.function.arguments, true, null, inner);

    var res = result(ctx, output);
    if (inserted) {
        res.progressive_tool_save = .{ .name = entry.name, .server_name = entry.server };
    }
    return res;
}

// ============================================================================
// Adapter integration: the real registry + a real (in-memory) DB
// ============================================================================

const test_sqlite = pabrikcore.sqlite;
const Migration085 = @import("../migrations/migration.zig").Migration085AddSessionProgressiveTool;

/// The `data.tools` rows of a rendered envelope result — the catalog rows
/// only, NOT the `"tool":"search_tool"` name in the `wrapToolOutput` envelope
/// around them.
fn catalogData(allocator: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    errdefer parsed.deinit();
    const data = parsed.value.object.get("data") orelse return error.NoData;
    if (data != .object) return error.NoData;
    return parsed;
}

/// Pull every tool row name out of a rendered envelope result, joined by ','.
fn namesJoined(allocator: std.mem.Allocator, out: []const u8) ![]const u8 {
    const parsed = try catalogData(allocator, out);
    defer parsed.deinit();
    const rows = parsed.value.object.get("data").?.object.get("tools").?.array.items;
    var list: std.ArrayList(u8) = .empty;
    for (rows) |t| {
        if (list.items.len > 0) try list.append(allocator, ',');
        try list.appendSlice(allocator, t.object.get("name").?.string);
    }
    return try list.toOwnedSlice(allocator);
}

fn totalOf(allocator: std.mem.Allocator, out: []const u8) !usize {
    const parsed = try catalogData(allocator, out);
    defer parsed.deinit();
    const total = parsed.value.object.get("data").?.object.get("total").?.integer;
    return std.math.cast(usize, total) orelse return error.BadTotal;
}

fn searchCall(args_json: []const u8) agent.ToolCall {
    return .{ .id = "call_regex", .type = "function", .function = .{
        .name = "search_tool",
        .arguments = args_json,
    } };
}

/// One `search_tool` dispatch against the REAL registry, with `read_file` and
/// `search_tool` enabled (so both are legitimately absent from the catalog) and
/// everything else discoverable.
fn searchToolOutput(a: std.mem.Allocator, db: *test_sqlite.SqliteBackend, io: std.Io, args_json: []const u8) ![]const u8 {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    const ctx = ToolExecContext{
        .allocator = a,
        .io = io,
        .db = db,
        .logger = undefined,
        .session_id = "sess_regex",
        .model = "test",
        .cwd = "/tmp",
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .allowed_tools = "read_file,search_tool",
        .is_sub_agent = false,
    };
    const res = try execSearchTool(ctx, searchCall(args_json));
    if (!res.output_allocated) return error.OutputNotOwned;
    return res.output;
}

test "execSearchTool: a regex finds tools a literal substring could not, end to end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var db: test_sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try Migration085.up(&db, testing.allocator);

    // The literal text "^(list|load|save|search)_" appears in no tool name or
    // description, so a substring search would return nothing. The rows below
    // can only come from the pattern language.
    const args = "{\"query\":\"^(list|load|save|search)_\"}";
    const out = try searchToolOutput(a, &db, threaded.io(), args);

    try testing.expect(std.mem.indexOf(u8, out, "\"pattern_mode\":\"regex\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"pattern_warning\":null") != null);
    const total = try totalOf(a, out);
    try testing.expect(total >= 5); // list_directory/search_skills/list_sub_agent + load_/save_memory at least
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"save_memory\"") != null);

    // Enabled tools are NOT discoverable (they are already in the tool list).
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"read_file\"") == null);
    // …nor are the browsing meta-tools themselves.
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"view_tool\"") == null);

    // `literal: true` over the same text finds nothing — the flag is honoured
    // through the adapter, not just in the pure matcher.
    const literal_out = try searchToolOutput(
        a,
        &db,
        threaded.io(),
        "{\"query\":\"^(list|load|save)_\",\"literal\":true}",
    );
    try testing.expect(std.mem.indexOf(u8, literal_out, "\"pattern_mode\":\"literal\"") != null);
    try testing.expect(std.mem.indexOf(u8, literal_out, "\"count\":0") != null);

    // A pattern the engine rejects degrades to a literal substring search and
    // says so — never a hard failure.
    const bad_out = try searchToolOutput(a, &db, threaded.io(), "{\"query\":\"^(list\"}");
    try testing.expect(std.mem.indexOf(u8, bad_out, "\"pattern_mode\":\"literal_fallback\"") != null);
    try testing.expect(std.mem.indexOf(u8, bad_out, "\"pattern_warning\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, bad_out, "not a valid regex") != null);
}

test "execSearchTool: limit/offset page the matches and report the true total" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var db: test_sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try Migration085.up(&db, testing.allocator);

    const page1 = try searchToolOutput(
        a,
        &db,
        threaded.io(),
        "{\"query\":\"^(list|load|save|search)_\",\"limit\":3,\"offset\":0}",
    );
    const total = try totalOf(a, page1);
    try testing.expect(total >= 5); // list_directory/search_skills/list_sub_agent + load_/save_memory
    try testing.expect(total > 3); // otherwise "page 2" would be empty
    try testing.expect(std.mem.indexOf(u8, page1, "\"count\":3") != null);
    try testing.expect(std.mem.indexOf(u8, page1, "\"offset\":0,\"limit\":3") != null);
    try testing.expect(std.mem.indexOf(u8, page1, "\"truncated\":true") != null);
    try testing.expect(std.mem.indexOf(u8, page1, "offset=3") != null);

    const page2 = try searchToolOutput(
        a,
        &db,
        threaded.io(),
        "{\"query\":\"^(list|load|save|search)_\",\"limit\":3,\"offset\":3}",
    );
    // Page 2 is a WINDOW of at most `limit` rows, so its count is
    // `min(limit, total - offset)` — NOT `total - offset`.
    //
    // The old assertion here was `total - 3`, which silently assumed the
    // entire remainder fit in one page, i.e. total <= 6. That was true
    // while the catalog happened to hold 6 tools matching
    // `^(list|load|save|search)_`, and went quietly false the moment a 7th
    // landed (search_documents does) — while the paging itself stayed
    // perfectly correct. Assert the windowing RULE instead: it holds for
    // every catalog size, so the next tool added cannot break it.
    const page2_expected = @min(@as(usize, 3), total - 3);
    const expect_page2_count = try std.fmt.allocPrint(a, "\"count\":{d}", .{page2_expected});
    try testing.expect(std.mem.indexOf(u8, page2, expect_page2_count) != null);
    try testing.expect(std.mem.indexOf(u8, page2, "\"offset\":3,\"limit\":3") != null);
    try testing.expectEqual(total, try totalOf(a, page2));

    // The last page proves the windowing all the way out: it is the only
    // page that is NOT truncated, and its count is whatever is left. This
    // is the assertion that was missing — without it, "page 2 holds the
    // whole remainder" went unnoticed.
    const page3 = try searchToolOutput(
        a,
        &db,
        threaded.io(),
        "{\"query\":\"^(list|load|save|search)_\",\"limit\":3,\"offset\":6}",
    );
    const page3_expected = if (total > 6) @min(@as(usize, 3), total - 6) else 0;
    const expect_page3_count = try std.fmt.allocPrint(a, "\"count\":{d}", .{page3_expected});
    try testing.expect(std.mem.indexOf(u8, page3, expect_page3_count) != null);
    try testing.expectEqual(total, try totalOf(a, page3));
    try testing.expect(std.mem.indexOf(u8, page3, "\"truncated\":false") != null);

    // The two pages are disjoint windows — not the same rows twice.
    const first = try namesJoined(a, page1);
    const second = try namesJoined(a, page2);
    try testing.expect(!std.mem.eql(u8, first, second));
    var it = std.mem.splitScalar(u8, second, ',');
    while (it.next()) |name| {
        try testing.expect(std.mem.indexOf(u8, first, name) == null);
    }
    // Sanity: the extractor is reading the row block, not the envelope name
    // (`"tool":"search_tool"` wraps every result).
    try testing.expect(std.mem.indexOf(u8, first, "search_tool") == null);

    // Out-of-range input is rejected with the accepted range, never clamped
    // (a clamp would desync the model's offset arithmetic).
    const too_big = try searchToolOutput(a, &db, threaded.io(), "{\"query\":\"a\",\"limit\":5000}");
    try testing.expect(std.mem.indexOf(u8, too_big, "\"success\":false") != null);
    try testing.expect(std.mem.indexOf(u8, too_big, "limit must be at most 200") != null);
    const zero = try searchToolOutput(a, &db, threaded.io(), "{\"query\":\"a\",\"limit\":0}");
    try testing.expect(std.mem.indexOf(u8, zero, "limit must be at least 1") != null);
    const negative = try searchToolOutput(a, &db, threaded.io(), "{\"query\":\"a\",\"offset\":-1}");
    try testing.expect(std.mem.indexOf(u8, negative, "offset must not be negative") != null);
}

const testing = std.testing;

/// One `use_tool` dispatch against the REAL registry and a real (in-memory)
/// DB, on the same allowlist `searchToolOutput` uses — so the name under
/// test is registered but not enabled, i.e. discoverable, which is the only
/// state `use_tool` acts on. A real Logger because `saveProgressiveTool`
/// logs the insert.
fn useToolResult(
    a: std.mem.Allocator,
    db: *test_sqlite.SqliteBackend,
    io: std.Io,
    logger: *pabrikcore.loggermod.Logger,
    args_json: []const u8,
) !ToolExecResult {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    const ctx = ToolExecContext{
        .allocator = a,
        .io = io,
        .db = db,
        .logger = logger,
        .session_id = "sess_regex",
        .model = "test",
        .cwd = "/tmp",
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .allowed_tools = "read_file,search_tool",
        .is_sub_agent = false,
    };
    return execUseTool(ctx, .{ .id = "call_use", .type = "function", .function = .{
        .name = "use_tool",
        .arguments = args_json,
    } });
}

test "the three progressive tools are offered to the model and resolve to dispatchable registry entries" {
    // `equips()` is the list the workflow hands the LLM;
    // UNIFIED_TOOL_REGISTRY() is the dispatcher's table. Both are required —
    // a registry entry alone is dispatchable but invisible, an equips() entry
    // alone is visible but undispatchable.
    const equip = tools_equipped.equips(testing.allocator);
    defer testing.allocator.free(equip);

    for (pmod.PROGRESSIVE_TOOL_NAMES) |name| {
        var in_equips = false;
        for (equip) |t| {
            if (std.mem.eql(u8, t.function.name, name)) in_equips = true;
        }
        try testing.expect(in_equips);

        // Exactly one dispatch entry, carrying the SAME tool def the model was
        // shown.
        var entries: usize = 0;
        for (tools_equipped.UNIFIED_TOOL_REGISTRY()) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            entries += 1;
            try testing.expectEqualStrings(name, entry.tool_def.function.name);
        }
        try testing.expectEqual(@as(usize, 1), entries);
        try testing.expect(tools_equipped.isDispatchableToolName(name));
    }
}

test "execUseTool: equipping a catalog tool persists the row and reports it back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var db: test_sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try Migration085.up(&db, testing.allocator);

    // `save_memory` is registered and not in the allowlist, so it is in the
    // discoverable catalog — proven independently by the regex search test
    // above, which finds it under `^(list|load|save|search)_`.
    var logger = pabrikcore.loggermod.Logger.init(a, threaded.io(), .{ .min_level = .err });
    const res = try useToolResult(a, &db, threaded.io(), &logger, "{\"name\":\"save_memory\"}");
    try testing.expect(res.output_allocated);
    try testing.expect(std.mem.indexOf(u8, res.output, "\"success\":true") != null);

    // The field `handle_tool` copies into its `progressive_tool_saved` event.
    try testing.expect(res.progressive_tool_save != null);
    try testing.expectEqualStrings("save_memory", res.progressive_tool_save.?.name);

    // …and the row really is in session_progressive_tool, which is what the
    // next turn's allowlist and the catalog both read back. The flag and the
    // database are asserted together because the flag exists precisely so the
    // two can never disagree (see ProgressiveToolSaveInfo).
    const rows = try llm_history.getProgressiveTools(a, &db, "sess_regex");
    defer for (rows) |r| r.deinit(a);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("save_memory", rows[0].tool_name);
}

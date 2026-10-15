//! Exec wrappers for the `add_document` / `edit_document` / `delete_document`
//! / `search_documents` agent tools (Migration 098).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const documents_search = @import("documents_search.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const document_mod = pabrikcore.document_tool;
const documents_store = pabrikcore.documents_store;
const workspace_scope = pabrikcore.workspace_scope;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

/// Probe an inner JSON payload for a top-level `"error"` key. The returned
/// slice borrows from `parsed` — keep it alive through the `wrapToolOutput`
/// call, then `deinit`.
const InnerErrorProbe = struct {
    @"error": ?[]const u8 = null,
};

pub fn execAddDocument(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        document_mod.AddDocumentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "add_document", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // Workspace scope is derived server-side from the calling session —
    // the LLM never supplies (or spoofs) a workspace id.
    const inner = document_mod.executeAddDocument(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "add_document", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // The tool module allocated `inner` from `ctx.allocator`, so the
    // wrapper owns it. `defer` fires after `wrapToolOutput` has copied
    // what it needs — the same ownership shape `execSaveMemory` uses.
    defer ctx.allocator.free(inner);

    if (std.json.parseFromSlice(InnerErrorProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "add_document", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "add_document", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execEditDocument(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        document_mod.EditDocumentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "edit_document", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = document_mod.executeEditDocument(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "edit_document", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // The tool module allocated `inner` from `ctx.allocator`, so the
    // wrapper owns it. `defer` fires after `wrapToolOutput` has copied
    // what it needs — the same ownership shape `execSaveMemory` uses.
    defer ctx.allocator.free(inner);

    if (std.json.parseFromSlice(InnerErrorProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "edit_document", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "edit_document", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execDeleteDocument(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        document_mod.DeleteDocumentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "delete_document", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = document_mod.executeDeleteDocument(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "delete_document", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    if (std.json.parseFromSlice(InnerErrorProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "delete_document", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "delete_document", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execSearchDocuments(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        document_mod.SearchDocumentsInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        const output = try wrapToolOutput(
            ctx.allocator,
            "search_documents",
            tc.function.arguments,
            false,
            "search_documents failed to parse input (expected {\"query\"?: string, \"literal\"?: bool, \"limit\"?: number, \"offset\"?: number, \"include_content\"?: bool})",
            "",
        );
        return .{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // ── Paging bounds ── Rejected, never silently clamped, for the same
    // reason `search_skills` rejects them: the model pages by offset from the
    // `total` it was shown, so a quiet clamp makes its next call land on the
    const limit: usize = blk: {
        const raw = parsed.value.limit orelse @as(i64, @intCast(documents_search.DEFAULT_SEARCH_LIMIT));
        if (raw < 1) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "search_documents: limit must be at least 1 (got {d})", .{raw});
            defer ctx.allocator.free(msg);
            const output = try wrapToolOutput(ctx.allocator, "search_documents", tc.function.arguments, false, msg, "");
            return .{ .output = output, .output_allocated = true };
        }
        if (raw > @as(i64, @intCast(documents_search.MAX_SEARCH_LIMIT))) {
            const msg = try std.fmt.allocPrint(
                ctx.allocator,
                "search_documents: limit must be at most {d} (got {d})",
                .{ documents_search.MAX_SEARCH_LIMIT, raw },
            );
            defer ctx.allocator.free(msg);
            const output = try wrapToolOutput(ctx.allocator, "search_documents", tc.function.arguments, false, msg, "");
            return .{ .output = output, .output_allocated = true };
        }
        break :blk @intCast(raw);
    };
    const offset: usize = blk: {
        const raw = parsed.value.offset orelse 0;
        if (raw < 0) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "search_documents: offset must not be negative (got {d})", .{raw});
            defer ctx.allocator.free(msg);
            const output = try wrapToolOutput(ctx.allocator, "search_documents", tc.function.arguments, false, msg, "");
            return .{ .output = output, .output_allocated = true };
        }
        break :blk @intCast(raw);
    };

    // Same fail-closed scope resolution `executeAddDocument` uses.
    if (ctx.session_id.len == 0) {
        const output = try wrapToolOutput(
            ctx.allocator,
            "search_documents",
            tc.function.arguments,
            false,
            "Missing caller session — cannot resolve which workspace to search.",
            "",
        );
        return .{ .output = output, .output_allocated = true };
    }
    const workspace_id = workspace_scope.resolveWorkspaceId(ctx.allocator, ctx.db, ctx.session_id) catch null;
    if (workspace_id == null) {
        const output = try wrapToolOutput(
            ctx.allocator,
            "search_documents",
            tc.function.arguments,
            false,
            "This session is not linked to any workspace, so there are no documents to search. " ++
                "Run from a workspace chat (a project task or a workspace-scoped chat).",
            "",
        );
        return .{ .output = output, .output_allocated = true };
    }
    defer ctx.allocator.free(workspace_id.?);

    const query = parsed.value.query orelse "";
    const literal = parsed.value.literal orelse false;

    // The SQL narrowing runs FIRST and only when it is provably a superset of
    // the regex's matches — see `documents_search.literalPrefilter`.
    const rows = documents_store.searchDocuments(
        ctx.allocator,
        ctx.db,
        workspace_id.?,
        documents_search.literalPrefilter(query, literal),
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "search_documents", tc.function.arguments, false, err_msg, "");
        return .{ .output = output, .output_allocated = true };
    };
    defer documents_store.freeDocumentRows(ctx.allocator, rows);

    const outcome = try documents_search.matchQuery(ctx.allocator, rows, query, .{ .literal = literal });
    defer ctx.allocator.free(outcome.hits);

    const page = documents_search.pageSlice(outcome.hits, offset, limit);
    const inner = try documents_search.renderSearchResult(ctx.allocator, page, .{
        .total = outcome.hits.len,
        .offset = offset,
        .limit = limit,
        .query = query,
        .mode = outcome.mode,
        .warning = outcome.warning,
        .include_content = parsed.value.include_content orelse false,
    });
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, "search_documents", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── Tests ──────────────────────────────────────────────────────────────

const sqlite = pabrikcore.sqlite;
const testing = std.testing;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(testing.allocator,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT DEFAULT 'active', cwd TEXT)
    , &.{});
    try db.exec(testing.allocator,
        \\CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER)
    , &.{});
    try db.exec(testing.allocator,
        \\CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL)
    , &.{});
    try migration.Migration098CreateDocuments.up(&db, testing.allocator);

    try db.exec(testing.allocator,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES
        \\  ('i1', 'ws_1', 'kanban', 'A', '/proj/a', 1),
        \\  ('i2', 'ws_2', 'kanban', 'B', '/proj/b', 1)
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES
        \\  ('s1', 'T1', 'i1'), ('s2', 'T2', 'i2')
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO sessions (id, name, status, cwd) VALUES
        \\  ('s1', 'One', 'active', '/proj/a'),
        \\  ('s2', 'Two', 'active', '/proj/b')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn makeTestCtx(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = testing.io,
        .db = db,
        .logger = undefined,
        .session_id = session_id,
        .model = "test-model",
        .cwd = "/tmp",
        .api_key = "test-key",
        .base_url = "http://test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
    };
}

fn fakeToolCall(name: []const u8, args: []const u8) agent.ToolCall {
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = name, .arguments = args },
    };
}

/// Flattened, OWNED view of a tool envelope. Two things this deliberately
/// does not do: - Return `p.value` after `deinit()`.
const Envelope = struct {
    allocator: std.mem.Allocator,
    raw: []const u8 = "",
    tool: []const u8 = "",
    success: bool = false,
    err: ?[]const u8 = null,
    id: []const u8 = "",
    workspace_id: []const u8 = "",
    title: []const u8 = "",
    content: []const u8 = "",

    // search_documents envelope.
    pattern_mode: []const u8 = "",
    pattern_warning: ?[]const u8 = null,
    count: usize = 0,
    total: usize = 0,
    truncated: bool = false,
    next_offset: ?usize = null,
    hint: []const u8 = "",
    ids: []const []const u8 = &.{},
    titles: []const []const u8 = &.{},
    excerpts: []const []const u8 = &.{},
    contents: []const ?[]const u8 = &.{},
    content_lengths: []const usize = &.{},

    fn deinit(self: *Envelope) void {
        const a = self.allocator;
        a.free(self.raw);
        a.free(self.tool);
        if (self.err) |e| a.free(e);
        a.free(self.id);
        a.free(self.workspace_id);
        a.free(self.title);
        a.free(self.content);
        a.free(self.pattern_mode);
        if (self.pattern_warning) |w| a.free(w);
        a.free(self.hint);
        freeSliceOfSlices(a, self.ids);
        freeSliceOfSlices(a, self.titles);
        freeSliceOfSlices(a, self.excerpts);
        freeOptSlices(a, self.contents);
        a.free(self.content_lengths);
    }
};

fn freeSliceOfSlices(a: std.mem.Allocator, items: []const []const u8) void {
    for (items) |s| a.free(s);
    a.free(items);
}

fn freeOptSlices(a: std.mem.Allocator, items: []const ?[]const u8) void {
    for (items) |maybe| if (maybe) |s| a.free(s);
    a.free(items);
}

fn parseEnvelope(allocator: std.mem.Allocator, raw: []const u8) !Envelope {
    // The envelope nests the tool payload under `data` (see
    // `wrapToolOutput`), so BOTH the write fields (add/edit/delete) and the
    // search fields (count/total/documents) live one level down.
    const DocumentRowWire = struct {
        id: []const u8 = "",
        title: []const u8 = "",
        excerpt: []const u8 = "",
        content_length: usize = 0,
        content: ?[]const u8 = null,
    };
    const DataWire = struct {
        // write tools
        id: []const u8 = "",
        workspace_id: []const u8 = "",
        title: []const u8 = "",
        content: []const u8 = "",
        // search_documents
        pattern_mode: []const u8 = "",
        pattern_warning: ?[]const u8 = null,
        count: usize = 0,
        total: usize = 0,
        truncated: bool = false,
        next_offset: ?usize = null,
        hint: []const u8 = "",
        documents: []const DocumentRowWire = &.{},
    };
    const Wire = struct {
        tool: []const u8 = "",
        success: bool = false,
        @"error": ?[]const u8 = null,
        data: ?DataWire = null,
    };
    const p = try std.json.parseFromSlice(Wire, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer p.deinit();

    const data: DataWire = p.value.data orelse .{};
    const rows = data.documents;

    // Five ArrayLists rather than five `alloc`s filled in place: on an OOM
    // halfway through the row loop, a partially-initialised slice is a `free`
    // of undefined pointers — which the testing allocator reports as a leak
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |s| allocator.free(s);
        ids.deinit(allocator);
    }
    var titles: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (titles.items) |s| allocator.free(s);
        titles.deinit(allocator);
    }
    var excerpts: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (excerpts.items) |s| allocator.free(s);
        excerpts.deinit(allocator);
    }
    var contents: std.ArrayList(?[]const u8) = .empty;
    errdefer {
        for (contents.items) |maybe| if (maybe) |s| allocator.free(s);
        contents.deinit(allocator);
    }
    var content_lengths: std.ArrayList(usize) = .empty;
    errdefer content_lengths.deinit(allocator);

    for (rows) |d| {
        // A null `content` stays null: "not requested" must not collapse
        // into "", or `include_content: false` would read as "this
        // document's body is empty" — two very different facts.
        try ids.append(allocator, try allocator.dupe(u8, d.id));
        try titles.append(allocator, try allocator.dupe(u8, d.title));
        try excerpts.append(allocator, try allocator.dupe(u8, d.excerpt));
        try contents.append(allocator, if (d.content) |c| try allocator.dupe(u8, c) else null);
        try content_lengths.append(allocator, d.content_length);
    }

    return .{
        .allocator = allocator,
        .raw = try allocator.dupe(u8, raw),
        .tool = try allocator.dupe(u8, p.value.tool),
        .success = p.value.success,
        .err = if (p.value.@"error") |e| try allocator.dupe(u8, e) else null,
        .id = try allocator.dupe(u8, data.id),
        .workspace_id = try allocator.dupe(u8, data.workspace_id),
        .title = try allocator.dupe(u8, data.title),
        .content = try allocator.dupe(u8, data.content),
        .pattern_mode = try allocator.dupe(u8, data.pattern_mode),
        .pattern_warning = if (data.pattern_warning) |w| try allocator.dupe(u8, w) else null,
        .count = data.count,
        .total = data.total,
        .truncated = data.truncated,
        .next_offset = data.next_offset,
        .hint = try allocator.dupe(u8, data.hint),
        .ids = try ids.toOwnedSlice(allocator),
        .titles = try titles.toOwnedSlice(allocator),
        .excerpts = try excerpts.toOwnedSlice(allocator),
        .contents = try contents.toOwnedSlice(allocator),
        .content_lengths = try content_lengths.toOwnedSlice(allocator),
    };
}

test "execAddDocument: success envelope carries the created document" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tc = makeTestCtx(alloc, &ctx.db, "s1");
    const result = try execAddDocument(tc, fakeToolCall("add_document", "{\"title\":\"Notes\",\"content\":\"# hi\"}"));
    defer alloc.free(result.output);

    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try testing.expectEqualStrings("add_document", env.tool);
    try testing.expect(env.success);
    try testing.expect(env.err == null);
    try testing.expectEqualStrings("ws_1", env.workspace_id);
    try testing.expectEqualStrings("Notes", env.title);
}

test "execAddDocument: a tool-level refusal surfaces as success=false" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The tool returns {"error": "..."} as its INNER payload. Without the
    // InnerErrorProbe re-parse this would be wrapped as success=true and
    // the model would read a refusal as a written document.
    const tc = makeTestCtx(alloc, &ctx.db, "");
    const result = try execAddDocument(tc, fakeToolCall("add_document", "{\"title\":\"Nowhere\"}"));
    defer alloc.free(result.output);

    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try testing.expect(!env.success);
    try testing.expect(env.err != null);
    try testing.expect(std.mem.indexOf(u8, env.err.?, "session") != null);
}

test "execAddDocument: malformed JSON arguments become a parse failure, not a crash" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tc = makeTestCtx(alloc, &ctx.db, "s1");
    const result = try execAddDocument(tc, fakeToolCall("add_document", "{not json"));
    defer alloc.free(result.output);

    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try testing.expect(!env.success);
    // The message must tell the model WHAT was wrong with its JSON, not
    // just name the Zig error. `{not json` is a syntax error, so the
    // explanation names JSON and the usual causes.
    try testing.expect(std.mem.indexOf(u8, env.err.?, "JSON") != null);
    try testing.expect(std.mem.indexOf(u8, env.err.?, "SyntaxError") == null);
}

test "execAddDocument: a hallucinated workspace_id is ignored, not honoured" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // s1 belongs to ws_1. The model asks for ws_2. The wrapper parses with
    // ignore_unknown_fields, the field is dropped, and the write lands in
    // ws_1 — the session's own workspace, never the requested one.
    const tc = makeTestCtx(alloc, &ctx.db, "s1");
    const result = try execAddDocument(tc, fakeToolCall("add_document", "{\"title\":\"Spoof attempt\",\"content\":\"x\",\"workspace_id\":\"ws_2\"}"));
    defer alloc.free(result.output);

    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expectEqualStrings("ws_1", env.workspace_id);
}

test "execEditDocument: a cross-workspace edit is refused and the row is untouched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const create = try execAddDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("add_document", "{\"title\":\"Private\",\"content\":\"TOPSECRET\"}"));
    defer alloc.free(create.output);
    var created = try parseEnvelope(alloc, create.output);
    defer created.deinit();
    const id = created.id;

    const args = try std.fmt.allocPrint(alloc, "{{\"document_id\":\"{s}\",\"content\":\"hijacked\"}}", .{id});
    defer alloc.free(args);
    const edit = try execEditDocument(makeTestCtx(alloc, &ctx.db, "s2"), fakeToolCall(
        "edit_document",
        args,
    ));
    defer alloc.free(edit.output);

    var env = try parseEnvelope(alloc, edit.output);
    defer env.deinit();
    try testing.expect(!env.success);
    try testing.expect(env.err != null);
    try testing.expect(std.mem.indexOf(u8, edit.output, "TOPSECRET") == null);
}

test "execEditDocument: success envelope echoes the new body" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const create = try execAddDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("add_document", "{\"title\":\"Plan\",\"content\":\"v1\"}"));
    defer alloc.free(create.output);
    var created2 = try parseEnvelope(alloc, create.output);
    defer created2.deinit();
    const id = created2.id;

    const args = try std.fmt.allocPrint(alloc, "{{\"document_id\":\"{s}\",\"content\":\"v2\"}}", .{id});
    defer alloc.free(args);
    const edit = try execEditDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("edit_document", args));
    defer alloc.free(edit.output);

    var env = try parseEnvelope(alloc, edit.output);
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expectEqualStrings("v2", env.content);
    // The title was omitted, so it must have survived.
    try testing.expectEqualStrings("Plan", env.title);
}

// ─── delete_document ────────────────────────────────────────────────────

test "execDeleteDocument: success envelope names the document it removed" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const create = try execAddDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("add_document", "{\"title\":\"Obsolete\",\"content\":\"gone soon\"}"));
    defer alloc.free(create.output);
    var created = try parseEnvelope(alloc, create.output);
    defer created.deinit();

    const args = try std.fmt.allocPrint(alloc, "{{\"document_id\":\"{s}\"}}", .{created.id});
    defer alloc.free(args);
    const del = try execDeleteDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("delete_document", args));
    defer alloc.free(del.output);

    var env = try parseEnvelope(alloc, del.output);
    defer env.deinit();
    try testing.expectEqualStrings("delete_document", env.tool);
    try testing.expect(env.success);
    try testing.expect(env.err == null);
    try testing.expectEqualStrings(created.id, env.id);
    try testing.expectEqualStrings("Obsolete", env.title);
    try testing.expect(std.mem.indexOf(u8, del.output, "\"deleted\":true") != null);

    // The body is gone from the table, not just from the response.
    try testing.expectError(error.NotFound, documents_store.getDocument(alloc, &ctx.db, "ws_1", created.id));
}

test "execDeleteDocument: malformed JSON arguments become a parse failure, not a crash" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const del = try execDeleteDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("delete_document", "{not json"));
    defer alloc.free(del.output);

    var env = try parseEnvelope(alloc, del.output);
    defer env.deinit();
    try testing.expect(!env.success);
    // The message must tell the model WHAT was wrong with its JSON, not
    // just name the Zig error. `{not json` is a syntax error, so the
    // explanation names JSON and the usual causes.
    try testing.expect(std.mem.indexOf(u8, env.err.?, "JSON") != null);
    try testing.expect(std.mem.indexOf(u8, env.err.?, "SyntaxError") == null);
}

test "execDeleteDocument: a hallucinated workspace_id is ignored, so the owner still deletes" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const create = try execAddDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("add_document", "{\"title\":\"Mine\",\"content\":\"x\",\"workspace_id\":\"ws_2\"}"));
    defer alloc.free(create.output);
    var created = try parseEnvelope(alloc, create.output);
    defer created.deinit();
    try testing.expectEqualStrings("ws_1", created.workspace_id);

    const args = try std.fmt.allocPrint(
        alloc,
        "{{\"document_id\":\"{s}\",\"workspace_id\":\"ws_2\"}}",
        .{created.id},
    );
    defer alloc.free(args);
    const del = try execDeleteDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("delete_document", args));
    defer alloc.free(del.output);

    var env = try parseEnvelope(alloc, del.output);
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expectError(error.NotFound, documents_store.getDocument(alloc, &ctx.db, "ws_1", created.id));
}

test "execDeleteDocument: a cross-workspace delete is refused and leaks nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const create = try execAddDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("add_document", "{\"title\":\"Private\",\"content\":\"TOPSECRETBODY\"}"));
    defer alloc.free(create.output);
    var created = try parseEnvelope(alloc, create.output);
    defer created.deinit();

    const args = try std.fmt.allocPrint(alloc, "{{\"document_id\":\"{s}\"}}", .{created.id});
    defer alloc.free(args);

    const denied = try execDeleteDocument(makeTestCtx(alloc, &ctx.db, "s2"), fakeToolCall("delete_document", args));
    defer alloc.free(denied.output);
    var d = try parseEnvelope(alloc, denied.output);
    defer d.deinit();

    const missing_args = try std.fmt.allocPrint(alloc, "{{\"document_id\":\"{s}\"}}", .{"doc_nope"});
    defer alloc.free(missing_args);
    const missing = try execDeleteDocument(makeTestCtx(alloc, &ctx.db, "s2"), fakeToolCall("delete_document", missing_args));
    defer alloc.free(missing.output);
    var m = try parseEnvelope(alloc, missing.output);
    defer m.deinit();

    try testing.expect(!d.success);
    try testing.expect(!m.success);
    // Identical messages, or the tool is an oracle for other workspaces' ids.
    try testing.expectEqualStrings(d.err.?, m.err.?);
    try testing.expect(std.mem.indexOf(u8, denied.output, "TOPSECRETBODY") == null);

    const survivor = try documents_store.getDocument(alloc, &ctx.db, "ws_1", created.id);
    defer documents_store.freeDocumentRow(alloc, survivor);
    try testing.expectEqualStrings("TOPSECRETBODY", survivor.content);
}

test "execDeleteDocument: an unresolvable session surfaces success=false" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const del = try execDeleteDocument(
        makeTestCtx(alloc, &ctx.db, "s_orphan"),
        fakeToolCall("delete_document", "{\"document_id\":\"doc_anything\"}"),
    );
    defer alloc.free(del.output);

    var env = try parseEnvelope(alloc, del.output);
    defer env.deinit();
    try testing.expect(!env.success);
    try testing.expect(env.err != null);
}

// ─── search_documents ───────────────────────────────────────────────────

/// Create a document in ws_1 through the real tool path and return its id.
fn seedDoc(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, title: []const u8, content: []const u8) ![]u8 {
    const args = try std.json.Stringify.valueAlloc(alloc, .{ .title = title, .content = content }, .{});
    defer alloc.free(args);
    const create = try execAddDocument(makeTestCtx(alloc, db, "s1"), fakeToolCall("add_document", args));
    defer alloc.free(create.output);
    var env = try parseEnvelope(alloc, create.output);
    defer env.deinit();
    if (!env.success) return error.SeedFailed;
    return alloc.dupe(u8, env.id);
}

/// Seed a document whose id the test does not need to keep.
fn seedAnon(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, title: []const u8, content: []const u8) !void {
    const id = try seedDoc(alloc, db, title, content);
    alloc.free(id);
}

fn runSearch(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, session: []const u8, args: []const u8) !Envelope {
    const res = try execSearchDocuments(makeTestCtx(alloc, db, session), fakeToolCall("search_documents", args));
    // `parseEnvelope` dupes everything it needs, so the raw output can go.
    defer alloc.free(res.output);
    return parseEnvelope(alloc, res.output);
}

test "execSearchDocuments: no arguments lists the workspace newest-first in mode=all" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const a = try seedDoc(alloc, &ctx.db, "Alpha", "first body");
    defer alloc.free(a);
    const b = try seedDoc(alloc, &ctx.db, "Beta", "second body");
    defer alloc.free(b);

    var env = try runSearch(alloc, &ctx.db, "s1", "{}");
    defer env.deinit();

    try testing.expectEqualStrings("search_documents", env.tool);
    try testing.expect(env.success);
    try testing.expectEqual(@as(usize, 2), env.total);
    try testing.expectEqual(@as(usize, 2), env.count);
    try testing.expectEqualStrings("all", env.pattern_mode);
    try testing.expect(!env.truncated);
    try testing.expect(env.next_offset == null);
    // Every row carries what the model needs to make the next call.
    try testing.expectEqual(@as(usize, 2), env.ids.len);
    try testing.expectEqualStrings("Beta", env.titles[0]); // newest first
    try testing.expect(std.mem.indexOf(u8, env.excerpts[0], "second body") != null);
}

test "execSearchDocuments: a regex query reaches title OR body" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "Release plan v2", "# plan\n\n- ship 095\n");
    try seedAnon(alloc, &ctx.db, "Meeting notes", "We agreed to LAUNCH in October.\n");

    // Title hit only.
    var by_title = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"release\"}");
    defer by_title.deinit();
    try testing.expectEqual(@as(usize, 1), by_title.total);
    try testing.expectEqualStrings("Release plan v2", by_title.titles[0]);
    try testing.expectEqualStrings("regex", by_title.pattern_mode);

    // Body hit, different case on both sides.
    var by_body = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"LAUNCH\"}");
    defer by_body.deinit();
    try testing.expectEqual(@as(usize, 1), by_body.total);
    try testing.expectEqualStrings("Meeting notes", by_body.titles[0]);
    // The excerpt is centred on the hit, so the body text is visible.
    try testing.expect(std.mem.indexOf(u8, by_body.excerpts[0], "LAUNCH") != null);

    // One alternation reaches both.
    var alt = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"release|launch\"}");
    defer alt.deinit();
    try testing.expectEqual(@as(usize, 2), alt.total);
}

test "execSearchDocuments: a metacharacter query is NOT narrowed by the SQL prefilter" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // `release.` as a regex is "release" + any one character, so "releaseX"
    // matches while the literal substring "release." does not occur.
    try seedAnon(alloc, &ctx.db, "Zebra", "releaseX the thing\n");

    var env = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"release.\"}");
    defer env.deinit();

    try testing.expectEqual(@as(usize, 1), env.total);
    try testing.expectEqualStrings("Zebra", env.titles[0]);

    // And the same query with literal:true genuinely matches nothing — the
    // flag, not the prefilter, is what makes the two answers differ.
    var lit = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"release.\",\"literal\":true}");
    defer lit.deinit();
    try testing.expectEqualStrings("literal", lit.pattern_mode);
    try testing.expectEqual(@as(usize, 0), lit.total);
}

test "execSearchDocuments: an anchored query still matches, so ^ is not prefiltered either" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "Q3 plan", "later");
    try seedAnon(alloc, &ctx.db, "Backlog Q3 items", "earlier");

    var env = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"^Q3\"}");
    defer env.deinit();
    try testing.expectEqual(@as(usize, 1), env.total);
    try testing.expectEqualStrings("Q3 plan", env.titles[0]);
}

test "execSearchDocuments: a LIKE prefilter needle containing % or _ is matched verbatim" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // SQLite's LIKE would treat `%` as "any run" and `_` as "any char".
    try seedAnon(alloc, &ctx.db, "Percent test", "100%% done\n");
    try seedAnon(alloc, &ctx.db, "Underscore test", "snake_case naming\n");
    try seedAnon(alloc, &ctx.db, "Decoy", "nothing special\n");

    var pct = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"%\",\"literal\":true}");
    defer pct.deinit();
    try testing.expectEqual(@as(usize, 1), pct.total);
    try testing.expectEqualStrings("Percent test", pct.titles[0]);

    var us = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"_\",\"literal\":true}");
    defer us.deinit();
    try testing.expectEqual(@as(usize, 1), us.total);
    try testing.expectEqualStrings("Underscore test", us.titles[0]);
}

test "execSearchDocuments: an invalid pattern is a warning, not a failed tool call" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "Notes", "release checklist\n");

    var env = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"releas(\"}");
    defer env.deinit();

    // success=true: the search RAN. It just ran in fallback mode, and said
    // so. Reporting this as an error would teach the model to give up on a
    // query that had an obvious literal reading.
    try testing.expect(env.success);
    try testing.expectEqualStrings("literal_fallback", env.pattern_mode);
    try testing.expect(env.pattern_warning != null);
    try testing.expect(std.mem.indexOf(u8, env.pattern_warning.?, "literal:true") != null);
}

test "execSearchDocuments: include_content is opt-in and off by default" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "Plan", "the FULLBODY marker text\n");

    var without = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"FULLBODY\"}");
    defer without.deinit();
    try testing.expectEqual(@as(usize, 1), without.total);
    try testing.expect(without.contents[0] == null);
    try testing.expect(std.mem.indexOf(u8, without.raw, "\"content\":\"the FULLBODY") == null);
    // The excerpt still shows the hit.
    try testing.expect(std.mem.indexOf(u8, without.excerpts[0], "FULLBODY") != null);

    var with = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"FULLBODY\",\"include_content\":true}");
    defer with.deinit();
    try testing.expectEqualStrings("the FULLBODY marker text\n", with.contents[0].?);
    try testing.expectEqual(@as(usize, 25), with.content_lengths[0]);
}

test "execSearchDocuments: paging reports total, truncated, next_offset and the offset in the hint" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    for ([_][]const u8{ "D1", "D2", "D3", "D4", "D5" }) |t| {
        try seedAnon(alloc, &ctx.db, t, "shared body");
    }

    var page1 = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"shared\",\"limit\":2}");
    defer page1.deinit();
    try testing.expectEqual(@as(usize, 5), page1.total);
    try testing.expectEqual(@as(usize, 2), page1.count);
    try testing.expect(page1.truncated);
    try testing.expectEqual(@as(usize, 2), page1.next_offset.?);
    try testing.expect(std.mem.indexOf(u8, page1.hint, "offset=2") != null);

    var page2 = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"shared\",\"limit\":2,\"offset\":2}");
    defer page2.deinit();
    try testing.expectEqual(@as(usize, 2), page2.count);
    // next_offset is offset + count, i.e. where page 3 STARTS — not the
    // offset page 2 started at.
    try testing.expectEqual(@as(usize, 4), page2.next_offset.?);
    // Page 2 must not repeat page 1's rows.
    for (page1.ids) |id| {
        for (page2.ids) |id2| try testing.expect(!std.mem.eql(u8, id, id2));
    }

    var last = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"shared\",\"limit\":2,\"offset\":4}");
    defer last.deinit();
    try testing.expectEqual(@as(usize, 1), last.count);
    try testing.expect(!last.truncated);
    try testing.expect(last.next_offset == null);
    try testing.expect(std.mem.indexOf(u8, last.hint, "edit_document") != null);
}

test "execSearchDocuments: an offset past the end is an empty page, not an error" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "Only one", "body");

    var env = try runSearch(alloc, &ctx.db, "s1", "{\"offset\":500}");
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expectEqual(@as(usize, 0), env.count);
    try testing.expectEqual(@as(usize, 1), env.total);
}

test "execSearchDocuments: out-of-range paging is rejected, never silently clamped" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var zero = try runSearch(alloc, &ctx.db, "s1", "{\"limit\":0}");
    defer zero.deinit();
    try testing.expect(!zero.success);
    try testing.expect(std.mem.indexOf(u8, zero.err.?, "at least 1") != null);

    var huge = try runSearch(alloc, &ctx.db, "s1", "{\"limit\":100000}");
    defer huge.deinit();
    try testing.expect(!huge.success);
    try testing.expect(std.mem.indexOf(u8, huge.err.?, "at most 100") != null);

    var negative = try runSearch(alloc, &ctx.db, "s1", "{\"offset\":-1}");
    defer negative.deinit();
    try testing.expect(!negative.success);
    try testing.expect(std.mem.indexOf(u8, negative.err.?, "negative") != null);
}

test "execSearchDocuments: malformed JSON arguments become a parse failure, not a crash" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var env = try runSearch(alloc, &ctx.db, "s1", "{not json");
    defer env.deinit();
    try testing.expect(!env.success);
    // `search_documents` keeps its own hand-written schema hint (it names
    // every field and its type, which the generic message cannot).
    try testing.expect(std.mem.indexOf(u8, env.err.?, "expected") != null);
    try testing.expect(std.mem.indexOf(u8, env.err.?, "query") != null);
    try testing.expect(std.mem.indexOf(u8, env.err.?, "SyntaxError") == null);
}

test "execSearchDocuments: a workspace never sees another workspace's documents" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "WS1 secret", "sharedword in ws_1\n");

    const args = try std.json.Stringify.valueAlloc(alloc, .{ .title = "WS2 note", .content = "sharedword in ws_2" }, .{});
    defer alloc.free(args);
    const create = try execAddDocument(makeTestCtx(alloc, &ctx.db, "s2"), fakeToolCall("add_document", args));
    defer alloc.free(create.output);
    var created = try parseEnvelope(alloc, create.output);
    defer created.deinit();
    try testing.expectEqualStrings("ws_2", created.workspace_id);

    // The shared query matches exactly one row per workspace, and each
    // search returns only its own — no ids, no titles, no excerpts leaking.
    var mine = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"sharedword\"}");
    defer mine.deinit();
    try testing.expectEqual(@as(usize, 1), mine.total);
    try testing.expectEqualStrings("WS1 secret", mine.titles[0]);
    try testing.expect(std.mem.indexOf(u8, mine.raw, "WS2 note") == null);
    try testing.expect(std.mem.indexOf(u8, mine.raw, created.id) == null);
    try testing.expect(std.mem.indexOf(u8, mine.raw, "ws_2") == null);

    var theirs = try runSearch(alloc, &ctx.db, "s2", "{\"query\":\"sharedword\"}");
    defer theirs.deinit();
    try testing.expectEqual(@as(usize, 1), theirs.total);
    try testing.expectEqualStrings("WS2 note", theirs.titles[0]);
    try testing.expect(std.mem.indexOf(u8, theirs.raw, "WS1 secret") == null);
}

test "execSearchDocuments: an unresolvable session is a refusal, NOT an empty result set" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // "no documents matched" and "you have no workspace" are different facts
    // and the model has to be able to tell them apart — a silent empty
    // page would read as "your notes are gone".
    var orphan = try runSearch(alloc, &ctx.db, "s_orphan", "{}");
    defer orphan.deinit();
    try testing.expect(!orphan.success);
    try testing.expect(orphan.err != null);
    try testing.expect(std.mem.indexOf(u8, orphan.err.?, "workspace") != null);

    var empty = try runSearch(alloc, &ctx.db, "s1", "{}");
    defer empty.deinit();
    try testing.expect(empty.success);
    try testing.expectEqual(@as(usize, 0), empty.total);
    try testing.expectEqualStrings("all", empty.pattern_mode);
}

test "execSearchDocuments: a hallucinated workspace_id is ignored, not honoured" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "Mine", "findme\n");

    var env = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"findme\",\"workspace_id\":\"ws_2\"}");
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expectEqual(@as(usize, 1), env.total);
    try testing.expectEqualStrings("Mine", env.titles[0]);
}

test "execSearchDocuments: an empty document body is searchable by title, not by content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "Stub", "");

    var by_title = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"Stub\"}");
    defer by_title.deinit();
    try testing.expectEqual(@as(usize, 1), by_title.total);
    try testing.expectEqual(@as(usize, 0), by_title.content_lengths[0]);
    // An empty body yields an empty excerpt, not a crash and not the title
    // silently standing in for it.
    try testing.expectEqualStrings("Stub", by_title.excerpts[0]);

    var none = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"hippopotamus\"}");
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.total);
}

test "execSearchDocuments: a body hit in a large document yields a bounded excerpt" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // 8 KiB of padding on both sides of the needle: without a window the
    // result would carry 16 KiB of markdown into the context window for
    // what should be a one-line answer.
    const filler = "y" ** 8192;
    const body = try std.fmt.allocPrint(alloc, "{s}NEEDLE{s}", .{ filler, filler });
    defer alloc.free(body);
    try seedAnon(alloc, &ctx.db, "Huge", body);

    var env = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"NEEDLE\"}");
    defer env.deinit();
    try testing.expectEqual(@as(usize, 1), env.total);
    try testing.expectEqual(@as(usize, 8192 * 2 + 6), env.content_lengths[0]);
    try testing.expect(std.mem.indexOf(u8, env.excerpts[0], "NEEDLE") != null);
    try testing.expect(env.excerpts[0].len <= documents_search.EXCERPT_MAX_BYTES + 8);
}

test "execSearchDocuments: a multi-byte body still produces valid JSON" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The excerpt window can land mid-codepoint. A split produces an invalid
    // UTF-8 sequence, which surfaces as a stringify failure — i.e. the whole
    // search tool call errors for a query that found a real match.
    const body = "日本語のテキスト" ** 400;
    try seedAnon(alloc, &ctx.db, "Ünïcödé", body);

    var env = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"テキスト\"}");
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expectEqual(@as(usize, 1), env.total);
    try testing.expect(std.unicode.utf8ValidateSlice(env.excerpts[0]));
    try testing.expect(std.mem.indexOf(u8, env.excerpts[0], "テキスト") != null);
}

test "execSearchDocuments: deleting what a search returned makes the next search stop finding it" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try seedDoc(alloc, &ctx.db, "Ephemeral", "findme marker\n");
    defer alloc.free(id);
    try seedAnon(alloc, &ctx.db, "Keep", "unrelated\n");

    var before = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"findme\"}");
    defer before.deinit();
    try testing.expectEqual(@as(usize, 1), before.total);

    // The round trip the tool is actually for: search → take the id → delete.
    const args = try std.fmt.allocPrint(alloc, "{{\"document_id\":\"{s}\"}}", .{before.ids[0]});
    defer alloc.free(args);
    const del = try execDeleteDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("delete_document", args));
    defer alloc.free(del.output);
    var env = try parseEnvelope(alloc, del.output);
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expectEqualStrings(id, env.id);

    var after = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"findme\"}");
    defer after.deinit();
    try testing.expect(after.success);
    try testing.expectEqual(@as(usize, 0), after.total);
}

// ─── Registration + default seeding ───────────────────────────────────────

/// Is `name` among the rows `seedDefaultAgentTools` wrote for `agent_id`?
fn seededFor(db: *sqlite.SqliteBackend, agent_id: []const u8, name: []const u8) !bool {
    const alloc = testing.allocator;
    var q = try db.query(alloc, "SELECT tool_name FROM agent_tools WHERE agent_id = ?", &.{agent_id});
    defer q.deinit();
    while ((q.next() catch null)) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], name)) return true;
    }
    return false;
}

test "document tools are offered to the model and resolve to dispatchable registry entries" {
    const tools_equipped = @import("tools_equipped.zig");
    const names = [_][]const u8{ "add_document", "edit_document", "delete_document", "search_documents" };

    // `equips()` is the list the workflow hands the LLM and
    // UNIFIED_TOOL_REGISTRY() is the dispatcher's table.
    const equip = tools_equipped.equips(testing.allocator);
    defer testing.allocator.free(equip);

    for (names) |name| {
        var in_equips = false;
        for (equip) |t| {
            if (std.mem.eql(u8, t.function.name, name)) in_equips = true;
        }
        try testing.expect(in_equips);

        // Exactly one dispatch entry, carrying the SAME tool def the model
        // was shown — a duplicate name would make the first match win and the
        // second unreachable.
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

test "search_documents is seeded by default but delete_document is not" {
    const tools_equipped = @import("tools_equipped.zig");

    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The creation-time seed writes `agent_tools`, which `setupDb` does not
    // build (it only stands up the document schema). Same table shape the
    // registry's own seed tests use.
    try ctx.db.exec(alloc,
        \\CREATE TABLE agent_tools (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, UNIQUE(agent_id, tool_name))
    , &.{});

    // `null` config is the legacy path a freshly created agent item takes.
    try tools_equipped.seedDefaultAgentTools(alloc, .{ .db = &ctx.db }, "ag_doc_seed", null);

    // Read-only, and a prerequisite for every edit (edit_document replaces the
    // whole body, so finding the row comes first) — an agent that cannot
    // search is crippled.
    try testing.expect(try seededFor(&ctx.db, "ag_doc_seed", "add_document"));
    try testing.expect(try seededFor(&ctx.db, "ag_doc_seed", "edit_document"));
    try testing.expect(try seededFor(&ctx.db, "ag_doc_seed", "search_documents"));

    // Irreversible, so handing every new agent a delete of the user's
    // documents is a separate decision that must be made out loud.
    try testing.expect(!try seededFor(&ctx.db, "ag_doc_seed", "delete_document"));

    // …and it stays reachable: registered means the Settings → Tools
    // checklist lists it and `search_tool` → `use_tool` can equip it for a
    // session. Registered is not the same as handed-out.
    try testing.expect(tools_equipped.isDispatchableToolName("delete_document"));
    const equip = tools_equipped.equips(alloc);
    defer alloc.free(equip);
    var delete_in_equips = false;
    for (equip) |t| {
        if (std.mem.eql(u8, t.function.name, "delete_document")) delete_in_equips = true;
    }
    try testing.expect(delete_in_equips);
}

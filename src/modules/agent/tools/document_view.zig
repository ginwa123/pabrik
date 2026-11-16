//! `document` — the read/search half of the document tools: one format-agnostic tool over the same store `document_markdown` and `document_html` write to.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const documents_store = pabrikcore.documents_store;
const document_mod = pabrikcore.document_tool;

pub const TOOL_NAME = "document";

pub const DocumentViewInput = struct {
    action: []const u8 = "",
    document_id: []const u8 = "",
    query: ?[]const u8 = null,
    literal: ?bool = null,
    /// `search`: matches per page. `read`: bytes per slice.
    limit: ?i64 = null,
    /// `search`: matches to skip. `read`: the byte position to start at.
    offset: ?i64 = null,
    include_content: ?bool = null,
};

pub const document_tool_system_prompt =
    \\## Document Tool — Behavior
    \\`document` READS documents in YOUR workspace. `action` picks the operation: `read` (one document's body) or `search` (which document, and where).
    \\- Scope is automatic. There is no `workspace_id` argument — passing one is ignored. You can only read the workspace your session belongs to; a `document_id` from another workspace reports "not found", exactly as a nonexistent id does, so you cannot probe or enumerate another workspace.
    \\- Every format reads the same way: markdown, office (a Univer snapshot) and html all come back as their raw stored text. This tool does not create, edit or delete anything — `document_markdown` and `document_html` write, this reads.
    \\- `search` FIRST when you do not have an id. It is how you get a `document_id` — never invent one, and do not ask the user to paste an id you can look up yourself. Omit `query` to list your documents, newest-updated first — the right first call when you do not know what you are looking for.
    \\- `search` takes `query`, a case-insensitive REGEX matched against each document's TITLE AND CONTENT. One pattern reaches a phrase that several words would: `release|launch`, `^Q3`, `\bTODO\b`. Set `literal: true` when the query is literal text (e.g. `*.md`, `fn(`) — otherwise its metacharacters are interpreted. An invalid pattern is not a failure: it is matched as a literal substring and the result carries `pattern_warning`. Read it instead of retrying blindly.
    \\- Search results are PAGED: `limit` (default 20, max 100) caps how many rows you get back, `total` is the real match count, `offset` continues the listing, and `hint` names the exact next offset. Every row carries a short `excerpt` around the hit plus `content_length` (bytes) — enough to tell documents apart without dumping megabytes of markdown into your context. A document whose body lives in the object store is searched through its PREVIEW (the first 512 bytes); a row whose `content_length` is much larger than its excerpt may hold the match further in, so open it with `read`.
    \\- `read` returns ONE document's body as a bounded SLICE: `limit` bytes (default 20000, max 200000) starting at `offset` (default 0). The result carries `content_bytes` (the whole body's length), `offset`, `next_offset` and `truncated` — pass `next_offset` as the next `offset` to continue, and stop when `next_offset` is null. Read a slice, not the whole document: a 4 MiB body is 200 pages, and you rarely need more than the part you are about to quote or change.
    \\- To change a document, use `document_markdown` (addressed by the id `search` gave you); for an HTML page, either tool writes and `document_html` refuses a non-HTML document.
    \\
;

pub const document_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = TOOL_NAME,
        .description =
        \\Read documents in YOUR workspace — any format (markdown, office, html). `action` selects the operation: `read` (document_id + a byte `offset` and `limit`), `search` (query, paged).
        \\
        \\- SCOPE is automatic: your session's workspace is resolved before the call, so there is no `workspace_id` argument — one supplied is ignored. A `document_id` in another workspace reports "not found", exactly as a nonexistent id does.
        \\- `search` is how you get a `document_id` — never invent one. Omit `query` to list the newest documents first.
        \\- `read` returns a SLICE, not the whole body: pass the result's `next_offset` as the next `offset` to continue, and stop when it is null.
        \\- Read-only: this tool never creates, edits or deletes. Use `document_markdown` or `document_html` for that.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "action",
                    .type = "string",
                    .description = "'read' or 'search'. Any other value is refused.",
                },
                .{
                    .name = "document_id",
                    .type = "string",
                    .description = "`read`: the id from a `create` result or a `search` row. A row in another workspace reports 'not found'.",
                },
                .{
                    .name = "query",
                    .type = "string",
                    .description = "`search`: regex, matched case-insensitively against each document's title AND content. Supported: literals, '.', '[...]', '\\d \\w \\s \\b', '*', '+', '?', '{m,n}' ranges, '( )' groups, '|', '^', '$'. A metacharacter-free query is a plain substring search. An invalid pattern is matched as a literal substring and reported in `pattern_warning`. Omit to list the newest documents first.",
                },
                .{
                    .name = "literal",
                    .type = "boolean",
                    .description = "`search`: treat `query` as a literal string — '.', '*', '[', '(' are matched verbatim. Set this for code- or glob-shaped queries ('*.md', 'fn('). Default false (regex mode).",
                },
                .{
                    .name = "limit",
                    .type = "number",
                    .description = "`search`: maximum matches in THIS response (default 20, max 100). `read`: maximum BYTES of the body to return (default 20000, max 200000). The result always reports the true `total` / `content_bytes` — page with `offset` instead of raising this.",
                },
                .{
                    .name = "offset",
                    .type = "number",
                    .description = "`search`: skip the first N matches (default 0). `read`: the BYTE position to start the slice at (default 0) — pass the previous read's `next_offset` to continue. The previous page's `hint` / `next_offset` names the value that continues it.",
                },
                .{
                    .name = "include_content",
                    .type = "boolean",
                    .description = "`search`: include each match's FULL body as `content`. Off by default — rows carry a bounded `excerpt` instead. Prefer `read` on one document over turning this on.",
                },
            },
            .required = &.{"action"},
        },
        .system_prompt = document_tool_system_prompt,
    },
};

pub const DEFAULT_READ_LIMIT: usize = 20_000;

pub const MAX_READ_LIMIT: usize = 200_000;

/// `content` is a SLICE of the body, and `next_offset` is how the caller continues — null means the end.
pub const DocumentReadSuccess = struct {
    id: []const u8,
    workspace_id: []const u8,
    title: []const u8,
    format: []const u8,
    updated_at: []const u8,
    content: []const u8,
    /// The WHOLE body's length, so the caller can size the document without reading it.
    content_bytes: usize,
    offset: usize,
    next_offset: ?usize,
    truncated: bool,
};

const BodySlice = struct {
    content: []const u8,
    offset: usize,
    next_offset: ?usize,
};

/// `body[offset..]` cut to at most `limit` bytes, on a UTF-8 boundary so a multi-byte character is never split across two pages.
pub fn sliceBody(body: []const u8, offset: usize, limit: usize) BodySlice {
    const start = @min(offset, body.len);
    var end = @min(start + limit, body.len);
    while (end > start and end < body.len and (body[end] & 0xC0) == 0x80) end -= 1;
    return .{
        .content = body[start..end],
        .offset = start,
        .next_offset = if (end < body.len) end else null,
    };
}

fn readSuccessJSON(
    allocator: std.mem.Allocator,
    row: documents_store.DocumentRow,
    offset: usize,
    limit: usize,
) ![]u8 {
    const slice = sliceBody(row.content, offset, limit);
    return std.json.Stringify.valueAlloc(allocator, DocumentReadSuccess{
        .id = row.id,
        .workspace_id = row.workspace_id,
        .title = row.title,
        .format = row.format,
        .updated_at = row.updated_at,
        .content = slice.content,
        .content_bytes = row.content.len,
        .offset = slice.offset,
        .next_offset = slice.next_offset,
        .truncated = slice.next_offset != null,
    }, .{});
}

/// Execute the `read` action: one document, body included, cut to a bounded slice.
pub fn executeReadDocument(
    allocator: std.mem.Allocator,
    store: documents_store.Store,
    caller_session_id: []const u8,
    input: DocumentViewInput,
) ![]const u8 {
    if (std.mem.trim(u8, input.document_id, " \t\n\r").len == 0) {
        return document_mod.errorJSON(allocator, "document_id is required. Use the id returned by a `create` action or a `search` row.");
    }

    const limit: usize = blk: {
        const raw = input.limit orelse @as(i64, @intCast(DEFAULT_READ_LIMIT));
        if (raw < 1) {
            const msg = try std.fmt.allocPrint(allocator, "limit must be at least 1 (got {d})", .{raw});
            defer allocator.free(msg);
            return document_mod.errorJSON(allocator, msg);
        }
        if (raw > @as(i64, @intCast(MAX_READ_LIMIT))) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "limit must be at most {d} bytes (got {d}) — page with `offset` instead",
                .{ MAX_READ_LIMIT, raw },
            );
            defer allocator.free(msg);
            return document_mod.errorJSON(allocator, msg);
        }
        break :blk @intCast(raw);
    };
    const offset: usize = blk: {
        const raw = input.offset orelse 0;
        if (raw < 0) {
            const msg = try std.fmt.allocPrint(allocator, "offset must not be negative (got {d})", .{raw});
            defer allocator.free(msg);
            return document_mod.errorJSON(allocator, msg);
        }
        break :blk @intCast(raw);
    };

    const workspace_id = (try document_mod.resolveScope(allocator, store.db, caller_session_id)) orelse
        return document_mod.scopeErrorJSON(allocator, caller_session_id);
    defer allocator.free(workspace_id);

    const row = store.getDocument(allocator, workspace_id, input.document_id) catch |err| {
        return document_mod.errorJSON(allocator, document_mod.readErrorMessage(err));
    };
    defer documents_store.freeDocumentRow(allocator, row);
    return readSuccessJSON(allocator, row, offset, limit);
}

// Exec adapter

const tools = @import("../loop/tools.zig");
const documents_search = @import("../loop/documents_search.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const exec_documents_store = pabrikcore.documents_store;
const exec_workspace_scope = pabrikcore.workspace_scope;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

const InnerResultProbe = struct {
    @"error": ?[]const u8 = null,
};

pub fn execDocumentView(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        DocumentViewInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const input = parsed.value;
    if (std.mem.eql(u8, input.action, "read")) return runRead(ctx, tc, input);
    if (std.mem.eql(u8, input.action, "search")) return runSearch(ctx, tc, input);

    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "action must be one of read, search (got \"{s}\")",
        .{input.action},
    );
    defer ctx.allocator.free(msg);
    const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, false, msg, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

fn runRead(ctx: ToolExecContext, tc: agent.ToolCall, input: DocumentViewInput) !ToolExecResult {
    const inner = executeReadDocument(
        ctx.allocator,
        .{ .db = ctx.db, .storage = ctx.storage },
        ctx.session_id,
        input,
    ) catch |err| return execFailure(ctx, tc, err);
    defer ctx.allocator.free(inner);

    if (std.json.parseFromSlice(InnerResultProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }
    const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

fn execFailure(ctx: ToolExecContext, tc: agent.ToolCall, err: anyerror) !ToolExecResult {
    const err_msg = try error_explain.explain(ctx.allocator, err, null);
    defer ctx.allocator.free(err_msg);
    const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, false, err_msg, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

fn runSearch(ctx: ToolExecContext, tc: agent.ToolCall, input: DocumentViewInput) !ToolExecResult {
    // Paging bounds are rejected, never silently clamped: the model pages by offset from the `total` it was shown, so a quiet clamp makes its next call land on the …
    const limit: usize = blk: {
        const raw = input.limit orelse @as(i64, @intCast(documents_search.DEFAULT_SEARCH_LIMIT));
        if (raw < 1) {
            const msg = try std.fmt.allocPrint(ctx.allocator, TOOL_NAME ++ ": limit must be at least 1 (got {d})", .{raw});
            defer ctx.allocator.free(msg);
            const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, false, msg, "");
            return .{ .output = output, .output_allocated = true };
        }
        if (raw > @as(i64, @intCast(documents_search.MAX_SEARCH_LIMIT))) {
            const msg = try std.fmt.allocPrint(
                ctx.allocator,
                TOOL_NAME ++ ": limit must be at most {d} (got {d})",
                .{ documents_search.MAX_SEARCH_LIMIT, raw },
            );
            defer ctx.allocator.free(msg);
            const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, false, msg, "");
            return .{ .output = output, .output_allocated = true };
        }
        break :blk @intCast(raw);
    };
    const offset: usize = blk: {
        const raw = input.offset orelse 0;
        if (raw < 0) {
            const msg = try std.fmt.allocPrint(ctx.allocator, TOOL_NAME ++ ": offset must not be negative (got {d})", .{raw});
            defer ctx.allocator.free(msg);
            const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, false, msg, "");
            return .{ .output = output, .output_allocated = true };
        }
        break :blk @intCast(raw);
    };

    // Same fail-closed scope resolution the mutations use.
    if (ctx.session_id.len == 0) {
        const output = try wrapToolOutput(
            ctx.allocator,
            TOOL_NAME,
            tc.function.arguments,
            false,
            "Missing caller session — cannot resolve which workspace to search.",
            "",
        );
        return .{ .output = output, .output_allocated = true };
    }
    const workspace_id = exec_workspace_scope.resolveWorkspaceId(ctx.allocator, ctx.db, ctx.session_id) catch null;
    if (workspace_id == null) {
        const output = try wrapToolOutput(
            ctx.allocator,
            TOOL_NAME,
            tc.function.arguments,
            false,
            "This session is not linked to any workspace, so there are no documents to search. " ++
                "Run from a workspace chat (a project task or a workspace-scoped chat).",
            "",
        );
        return .{ .output = output, .output_allocated = true };
    }
    defer ctx.allocator.free(workspace_id.?);

    const query = input.query orelse "";
    const literal = input.literal orelse false;

    // The SQL narrowing runs FIRST and only when it is provably a superset of the regex's matches — see `documents_search.literalPrefilter`.
    const rows = exec_documents_store.searchDocuments(
        ctx.allocator,
        ctx.db,
        workspace_id.?,
        documents_search.literalPrefilter(query, literal),
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, false, err_msg, "");
        return .{ .output = output, .output_allocated = true };
    };
    defer exec_documents_store.freeDocumentRows(ctx.allocator, rows);

    const outcome = try documents_search.matchQuery(ctx.allocator, rows, query, .{ .literal = literal });
    defer ctx.allocator.free(outcome.hits);

    const page = documents_search.pageSlice(outcome.hits, offset, limit);
    const include_content = input.include_content orelse false;

    // `include_content` is the "I am about to edit" path.
    var hydrated: std.ArrayList(documents_search.Hit) = .empty;
    defer hydrated.deinit(ctx.allocator);
    var bodies: std.ArrayList([]u8) = .empty;
    defer {
        for (bodies.items) |b| ctx.allocator.free(b);
        bodies.deinit(ctx.allocator);
    }
    var page_final: []const documents_search.Hit = page;
    if (include_content) {
        for (page) |hit| {
            var copy = hit;
            if (hit.content.len == 0) {
                if (ctx.storage) |s| {
                    if (contentKeyOf(rows, hit.id)) |key| {
                        if (s.get(ctx.allocator, key)) |body| {
                            if (bodies.append(ctx.allocator, body)) |_| {
                                copy.content = body;
                            } else |_| {
                                ctx.allocator.free(body);
                            }
                        } else |_| {}
                    }
                }
            }
            hydrated.append(ctx.allocator, copy) catch {};
        }
        page_final = hydrated.items;
    }

    const inner = try documents_search.renderSearchResult(ctx.allocator, page_final, .{
        .total = outcome.hits.len,
        .offset = offset,
        .limit = limit,
        .query = query,
        .mode = outcome.mode,
        .warning = outcome.warning,
        .include_content = include_content,
    });
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

/// The object key for `id`, or null when the row has none.
fn contentKeyOf(rows: []const exec_documents_store.DocumentRow, id: []const u8) ?[]const u8 {
    for (rows) |row| {
        if (std.mem.eql(u8, row.id, id)) return row.content_key;
    }
    return null;
}
// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const database = pabrikcore.database;

/// Flattened view of one `read` payload.
const ReadJson = struct {
    allocator: std.mem.Allocator,
    id: []const u8 = "",
    title: []const u8 = "",
    format: []const u8 = "",
    content: []const u8 = "",
    content_bytes: usize = 0,
    offset: usize = 0,
    next_offset: ?usize = null,
    truncated: bool = false,
    err: ?[]const u8 = null,

    fn deinit(self: *ReadJson) void {
        const a = self.allocator;
        a.free(self.id);
        a.free(self.title);
        a.free(self.format);
        a.free(self.content);
        if (self.err) |e| a.free(e);
    }
};

fn parseRead(allocator: std.mem.Allocator, raw: []const u8) !ReadJson {
    const Wire = struct {
        id: []const u8 = "",
        title: []const u8 = "",
        format: []const u8 = "",
        content: []const u8 = "",
        content_bytes: usize = 0,
        offset: usize = 0,
        next_offset: ?usize = null,
        truncated: bool = false,
        @"error": ?[]const u8 = null,
    };
    const p = try std.json.parseFromSlice(Wire, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer p.deinit();
    return .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, p.value.id),
        .title = try allocator.dupe(u8, p.value.title),
        .format = try allocator.dupe(u8, p.value.format),
        .content = try allocator.dupe(u8, p.value.content),
        .content_bytes = p.value.content_bytes,
        .offset = p.value.offset,
        .next_offset = p.value.next_offset,
        .truncated = p.value.truncated,
        .err = if (p.value.@"error") |e| try allocator.dupe(u8, e) else null,
    };
}

fn seedDoc(
    alloc: std.mem.Allocator,
    store: documents_store.Store,
    title: []const u8,
    content: []const u8,
) ![]u8 {
    const row = try store.createDocument(alloc, .{ .workspace_id = "ws_1", .title = title, .content = content });
    defer documents_store.freeDocumentRow(alloc, row);
    return alloc.dupe(u8, row.id);
}

fn seedAnon(
    alloc: std.mem.Allocator,
    store: documents_store.Store,
    title: []const u8,
    content: []const u8,
) !void {
    const id = try seedDoc(alloc, store, title, content);
    alloc.free(id);
}

fn viewTool(
    alloc: std.mem.Allocator,
    store: documents_store.Store,
    session: []const u8,
    action: []const u8,
    args: []const u8,
) !document_mod.Envelope {
    const res = try document_mod.callToolAs(
        execDocumentView,
        TOOL_NAME,
        document_mod.makeTestCtx(alloc, store.db, store.storage, session),
        action,
        args,
    );
    defer alloc.free(res.output);
    return document_mod.parseEnvelope(alloc, res.output);
}

test "document read: returns a bounded slice and the byte offset that continues it" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    const store = documents_store.Store{ .db = &ctx.db, .storage = ctx.objects.asStorage() };
    const id = try seedDoc(alloc, store, "Plan", "0123456789");
    defer alloc.free(id);

    const out = try executeReadDocument(alloc, store, "s1", .{ .document_id = id, .offset = 2, .limit = 4 });
    defer alloc.free(out);
    var p = try parseRead(alloc, out);
    defer p.deinit();

    try testing.expect(p.err == null);
    try testing.expectEqualStrings("2345", p.content);
    // The whole body's length, so the caller can size the document without reading the rest of it.
    try testing.expectEqual(@as(usize, 10), p.content_bytes);
    try testing.expectEqual(@as(usize, 2), p.offset);
    try testing.expectEqual(@as(?usize, 6), p.next_offset);
    try testing.expect(p.truncated);
}

test "document read: the last page reports no next_offset" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    const store = documents_store.Store{ .db = &ctx.db, .storage = ctx.objects.asStorage() };
    const id = try seedDoc(alloc, store, "Plan", "0123456789");
    defer alloc.free(id);

    const out = try executeReadDocument(alloc, store, "s1", .{ .document_id = id, .offset = 8, .limit = 100 });
    defer alloc.free(out);
    var p = try parseRead(alloc, out);
    defer p.deinit();

    try testing.expectEqualStrings("89", p.content);
    try testing.expectEqual(@as(?usize, null), p.next_offset);
    try testing.expect(!p.truncated);
}

test "document read: a slice never splits a multi-byte character" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    const store = documents_store.Store{ .db = &ctx.db, .storage = ctx.objects.asStorage() };
    // "a" is 1 byte, "é" is 2 — a 2-byte limit lands inside the é.
    const id = try seedDoc(alloc, store, "Plan", "aébc");
    defer alloc.free(id);

    const out = try executeReadDocument(alloc, store, "s1", .{ .document_id = id, .limit = 2 });
    defer alloc.free(out);
    var p = try parseRead(alloc, out);
    defer p.deinit();

    try testing.expectEqualStrings("a", p.content);
    try testing.expectEqual(@as(?usize, 1), p.next_offset);
}

test "document read: a limit above the cap is refused, not silently clamped" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    const store = documents_store.Store{ .db = &ctx.db, .storage = ctx.objects.asStorage() };
    const id = try seedDoc(alloc, store, "Plan", "body");
    defer alloc.free(id);

    const out = try executeReadDocument(alloc, store, "s1", .{
        .document_id = id,
        .limit = @as(i64, @intCast(MAX_READ_LIMIT)) + 1,
    });
    defer alloc.free(out);
    var p = try parseRead(alloc, out);
    defer p.deinit();

    try testing.expect(p.err != null);
    try testing.expect(std.mem.indexOf(u8, p.err.?, "offset") != null);
}

test "document read: an offset past the end is an empty final page, not an error" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    const store = documents_store.Store{ .db = &ctx.db, .storage = ctx.objects.asStorage() };
    const id = try seedDoc(alloc, store, "Plan", "short");
    defer alloc.free(id);

    const out = try executeReadDocument(alloc, store, "s1", .{ .document_id = id, .offset = 500 });
    defer alloc.free(out);
    var p = try parseRead(alloc, out);
    defer p.deinit();

    try testing.expect(p.err == null);
    try testing.expectEqualStrings("", p.content);
    try testing.expectEqual(@as(?usize, null), p.next_offset);
}

test "document read: an empty document_id is refused and reads nothing" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    const store = documents_store.Store{ .db = &ctx.db, .storage = ctx.objects.asStorage() };
    const out = try executeReadDocument(alloc, store, "s1", .{ .document_id = "  " });
    defer alloc.free(out);
    var p = try parseRead(alloc, out);
    defer p.deinit();

    try testing.expect(p.err != null);
}

test "document read: an html page and an office body read through the same tool" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    const store = documents_store.Store{ .db = &ctx.db, .storage = ctx.objects.asStorage() };
    const page = "<!doctype html><html><body><p>hi</p></body></html>";
    const html = try store.createDocument(alloc, .{ .workspace_id = "ws_1", .title = "Page", .content = page, .format = "html" });
    defer documents_store.freeDocumentRow(alloc, html);
    const sheet = try store.createDocument(alloc, .{ .workspace_id = "ws_1", .title = "Sheet", .content = "{\"sheets\":{}}", .format = "office" });
    defer documents_store.freeDocumentRow(alloc, sheet);

    const html_out = try executeReadDocument(alloc, store, "s1", .{ .document_id = html.id, .limit = 15 });
    defer alloc.free(html_out);
    var hp = try parseRead(alloc, html_out);
    defer hp.deinit();
    try testing.expectEqualStrings("<!doctype html>", hp.content);
    try testing.expectEqualStrings("html", hp.format);
    try testing.expectEqual(@as(?usize, 15), hp.next_offset);

    const sheet_out = try executeReadDocument(alloc, store, "s1", .{ .document_id = sheet.id });
    defer alloc.free(sheet_out);
    var sp = try parseRead(alloc, sheet_out);
    defer sp.deinit();
    try testing.expectEqualStrings("{\"sheets\":{}}", sp.content);
    try testing.expectEqualStrings("office", sp.format);
}

test "document read: another workspace's document reports not found and leaks no body" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    const store = documents_store.Store{ .db = &ctx.db, .storage = ctx.objects.asStorage() };
    const id = try seedDoc(alloc, store, "Private", "TOPSECRETBODY");
    defer alloc.free(id);

    const out = try executeReadDocument(alloc, store, "s2", .{ .document_id = id, .limit = 200 });
    defer alloc.free(out);
    var p = try parseRead(alloc, out);
    defer p.deinit();

    try testing.expect(p.err != null);
    try testing.expectEqualStrings("", p.content);
    try testing.expect(std.mem.indexOf(u8, out, "TOPSECRETBODY") == null);
}

test "document search: no arguments lists the workspace newest-first in mode=all" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    const a = try seedDoc(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Alpha", "first body");
    defer alloc.free(a);
    const b = try seedDoc(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Beta", "second body");
    defer alloc.free(b);

    var env = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{}");
    defer env.deinit();

    try testing.expectEqualStrings(TOOL_NAME, env.tool);
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

test "document search: a regex query reaches title OR body" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Release plan v2", "# plan\n\n- ship 095\n");
    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Meeting notes", "We agreed to LAUNCH in October.\n");

    // Title hit only.
    var by_title = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"release\"}");
    defer by_title.deinit();
    try testing.expectEqual(@as(usize, 1), by_title.total);
    try testing.expectEqualStrings("Release plan v2", by_title.titles[0]);
    try testing.expectEqualStrings("regex", by_title.pattern_mode);

    // Body hit, different case on both sides.
    var by_body = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"LAUNCH\"}");
    defer by_body.deinit();
    try testing.expectEqual(@as(usize, 1), by_body.total);
    try testing.expectEqualStrings("Meeting notes", by_body.titles[0]);
    // The excerpt is centred on the hit, so the body text is visible.
    try testing.expect(std.mem.indexOf(u8, by_body.excerpts[0], "LAUNCH") != null);

    // One alternation reaches both.
    var alt = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"release|launch\"}");
    defer alt.deinit();
    try testing.expectEqual(@as(usize, 2), alt.total);
}

test "document search: a metacharacter query is NOT narrowed by the SQL prefilter" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    // `release.` as a regex is "release" + any one character, so "releaseX" matches while the literal substring "release." does not occur.
    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Zebra", "releaseX the thing\n");

    var env = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"release.\"}");
    defer env.deinit();

    try testing.expectEqual(@as(usize, 1), env.total);
    try testing.expectEqualStrings("Zebra", env.titles[0]);

    // And the same query with literal:true genuinely matches nothing — the flag, not the prefilter, is what makes the two answers differ.
    var lit = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"release.\",\"literal\":true}");
    defer lit.deinit();
    try testing.expectEqualStrings("literal", lit.pattern_mode);
    try testing.expectEqual(@as(usize, 0), lit.total);
}

test "document search: an anchored query still matches, so ^ is not prefiltered either" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Q3 plan", "later");
    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Backlog Q3 items", "earlier");

    var env = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"^Q3\"}");
    defer env.deinit();
    try testing.expectEqual(@as(usize, 1), env.total);
    try testing.expectEqualStrings("Q3 plan", env.titles[0]);
}

test "document search: a LIKE prefilter needle containing % or _ is matched verbatim" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    // SQLite's LIKE would treat `%` as "any run" and `_` as "any char".
    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Percent test", "100%% done\n");
    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Underscore test", "snake_case naming\n");
    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Decoy", "nothing special\n");

    var pct = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"%\",\"literal\":true}");
    defer pct.deinit();
    try testing.expectEqual(@as(usize, 1), pct.total);
    try testing.expectEqualStrings("Percent test", pct.titles[0]);

    var us = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"_\",\"literal\":true}");
    defer us.deinit();
    try testing.expectEqual(@as(usize, 1), us.total);
    try testing.expectEqualStrings("Underscore test", us.titles[0]);
}

test "document search: an invalid pattern is a warning, not a failed tool call" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Notes", "release checklist\n");

    var env = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"releas(\"}");
    defer env.deinit();

    // success=true: the search RAN.
    try testing.expect(env.success);
    try testing.expectEqualStrings("literal_fallback", env.pattern_mode);
    try testing.expect(env.pattern_warning != null);
    try testing.expect(std.mem.indexOf(u8, env.pattern_warning.?, "literal:true") != null);
}

test "document search: include_content is opt-in and off by default" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Plan", "the FULLBODY marker text\n");

    var without = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"FULLBODY\"}");
    defer without.deinit();
    try testing.expectEqual(@as(usize, 1), without.total);
    try testing.expect(without.contents[0] == null);
    try testing.expect(std.mem.indexOf(u8, without.raw, "\"content\":\"the FULLBODY") == null);
    // The excerpt still shows the hit.
    try testing.expect(std.mem.indexOf(u8, without.excerpts[0], "FULLBODY") != null);

    var with = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"FULLBODY\",\"include_content\":true}");
    defer with.deinit();
    try testing.expectEqualStrings("the FULLBODY marker text\n", with.contents[0].?);
    try testing.expectEqual(@as(usize, 25), with.content_lengths[0]);
}

test "document search: paging reports total, truncated, next_offset and the offset in the hint" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    for ([_][]const u8{ "D1", "D2", "D3", "D4", "D5" }) |t| {
        try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, t, "shared body");
    }

    var page1 = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"shared\",\"limit\":2}");
    defer page1.deinit();
    try testing.expectEqual(@as(usize, 5), page1.total);
    try testing.expectEqual(@as(usize, 2), page1.count);
    try testing.expect(page1.truncated);
    try testing.expectEqual(@as(usize, 2), page1.next_offset.?);
    try testing.expect(std.mem.indexOf(u8, page1.hint, "offset=2") != null);

    var page2 = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"shared\",\"limit\":2,\"offset\":2}");
    defer page2.deinit();
    try testing.expectEqual(@as(usize, 2), page2.count);
    // next_offset is offset + count, i.e. where page 3 STARTS — not the offset page 2 started at.
    try testing.expectEqual(@as(usize, 4), page2.next_offset.?);
    // Page 2 must not repeat page 1's rows.
    for (page1.ids) |id| {
        for (page2.ids) |id2| try testing.expect(!std.mem.eql(u8, id, id2));
    }

    var last = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"shared\",\"limit\":2,\"offset\":4}");
    defer last.deinit();
    try testing.expectEqual(@as(usize, 1), last.count);
    try testing.expect(!last.truncated);
    try testing.expect(last.next_offset == null);
    try testing.expect(std.mem.indexOf(u8, last.hint, "action: \"edit\"") != null);
}

test "document search: an offset past the end is an empty page, not an error" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Only one", "body");

    var env = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"offset\":500}");
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expectEqual(@as(usize, 0), env.count);
    try testing.expectEqual(@as(usize, 1), env.total);
}

test "document search: out-of-range paging is rejected, never silently clamped" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    var zero = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"limit\":0}");
    defer zero.deinit();
    try testing.expect(!zero.success);
    try testing.expect(std.mem.indexOf(u8, zero.err.?, "at least 1") != null);

    var huge = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"limit\":100000}");
    defer huge.deinit();
    try testing.expect(!huge.success);
    try testing.expect(std.mem.indexOf(u8, huge.err.?, "at most 100") != null);

    var negative = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"offset\":-1}");
    defer negative.deinit();
    try testing.expect(!negative.success);
    try testing.expect(std.mem.indexOf(u8, negative.err.?, "negative") != null);
}

test "document search: malformed JSON arguments become a parse failure, not a crash" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    var env = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{not json");
    defer env.deinit();
    try testing.expect(!env.success);
    try testing.expect(std.mem.indexOf(u8, env.err.?, "JSON") != null);
    try testing.expect(std.mem.indexOf(u8, env.err.?, "SyntaxError") == null);
}

test "document search: a workspace never sees another workspace's documents" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "WS1 secret", "sharedword in ws_1\n");

    const args = try std.json.Stringify.valueAlloc(alloc, .{ .title = "WS2 note", .content = "sharedword in ws_2" }, .{});
    defer alloc.free(args);
    const create = try document_mod.callTool(document_mod.makeTestCtx(alloc, &ctx.db, ctx.objects.asStorage(), "s2"), "create", args);
    defer alloc.free(create.output);
    var created = try document_mod.parseEnvelope(alloc, create.output);
    defer created.deinit();
    try testing.expectEqualStrings("ws_2", created.workspace_id);

    // The shared query matches exactly one row per workspace, and each search returns only its own — no ids, no titles, no excerpts leaking.
    var mine = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"sharedword\"}");
    defer mine.deinit();
    try testing.expectEqual(@as(usize, 1), mine.total);
    try testing.expectEqualStrings("WS1 secret", mine.titles[0]);
    try testing.expect(std.mem.indexOf(u8, mine.raw, "WS2 note") == null);
    try testing.expect(std.mem.indexOf(u8, mine.raw, created.id) == null);
    try testing.expect(std.mem.indexOf(u8, mine.raw, "ws_2") == null);

    var theirs = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s2", "search", "{\"query\":\"sharedword\"}");
    defer theirs.deinit();
    try testing.expectEqual(@as(usize, 1), theirs.total);
    try testing.expectEqualStrings("WS2 note", theirs.titles[0]);
    try testing.expect(std.mem.indexOf(u8, theirs.raw, "WS1 secret") == null);
}

test "document search: an unresolvable session is a refusal, NOT an empty result set" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    // "no documents matched" and "you have no workspace" are different facts and the model has to be able to tell them apart — a silent empty page would read as …
    var orphan = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s_orphan", "search", "{}");
    defer orphan.deinit();
    try testing.expect(!orphan.success);
    try testing.expect(orphan.err != null);
    try testing.expect(std.mem.indexOf(u8, orphan.err.?, "workspace") != null);

    var empty = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{}");
    defer empty.deinit();
    try testing.expect(empty.success);
    try testing.expectEqual(@as(usize, 0), empty.total);
    try testing.expectEqualStrings("all", empty.pattern_mode);
}

test "document search: a hallucinated workspace_id is ignored, not honoured" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Mine", "findme\n");

    var env = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"findme\",\"workspace_id\":\"ws_2\"}");
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expectEqual(@as(usize, 1), env.total);
    try testing.expectEqualStrings("Mine", env.titles[0]);
}

test "document search: an empty document body is searchable by title, not by content" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Stub", "");

    var by_title = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"Stub\"}");
    defer by_title.deinit();
    try testing.expectEqual(@as(usize, 1), by_title.total);
    try testing.expectEqual(@as(usize, 0), by_title.content_lengths[0]);
    // An empty body yields an empty excerpt, not a crash and not the title silently standing in for it.
    try testing.expectEqualStrings("Stub", by_title.excerpts[0]);

    var none = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"hippopotamus\"}");
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.total);
}

test "document search: a body hit in a large document yields a bounded excerpt" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    // 8 KiB of padding AFTER the needle: without a window the result would carry 8 KiB of markdown into the context for a one-line answer.
    const filler = "y" ** 8192;
    const body = try std.fmt.allocPrint(alloc, "NEEDLE{s}", .{filler});
    defer alloc.free(body);
    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Huge", body);

    var env = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"NEEDLE\"}");
    defer env.deinit();
    try testing.expectEqual(@as(usize, 1), env.total);
    try testing.expectEqual(@as(usize, 8192 + 6), env.content_lengths[0]);
    try testing.expect(std.mem.indexOf(u8, env.excerpts[0], "NEEDLE") != null);
    try testing.expect(env.excerpts[0].len <= documents_search.EXCERPT_MAX_BYTES + 8);
}

test "document search: a multi-byte body still produces valid JSON" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    // The excerpt window can land mid-codepoint.
    const body = "日本語のテキスト" ** 400;
    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Ünïcödé", body);

    var env = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"テキスト\"}");
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expectEqual(@as(usize, 1), env.total);
    try testing.expect(std.unicode.utf8ValidateSlice(env.excerpts[0]));
    try testing.expect(std.mem.indexOf(u8, env.excerpts[0], "テキスト") != null);
}

test "document search: deleting what a search returned makes the next search stop finding it" {
    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    const id = try seedDoc(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Ephemeral", "findme marker\n");
    defer alloc.free(id);
    try seedAnon(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "Keep", "unrelated\n");

    var before = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"findme\"}");
    defer before.deinit();
    try testing.expectEqual(@as(usize, 1), before.total);

    // The round trip the reader is for: search → take the id → the writer's delete.
    const args = try std.fmt.allocPrint(alloc, "{{\"document_id\":\"{s}\"}}", .{before.ids[0]});
    defer alloc.free(args);
    const del = try document_mod.callTool(document_mod.makeTestCtx(alloc, &ctx.db, ctx.objects.asStorage(), "s1"), "delete", args);
    defer alloc.free(del.output);
    var env = try document_mod.parseEnvelope(alloc, del.output);
    defer env.deinit();
    try testing.expect(env.success);
    try testing.expectEqualStrings(id, env.id);

    var after = try viewTool(alloc, .{ .db = &ctx.db, .storage = ctx.objects.asStorage() }, "s1", "search", "{\"query\":\"findme\"}");
    defer after.deinit();
    try testing.expect(after.success);
    try testing.expectEqual(@as(usize, 0), after.total);
}

// ─── Registration + default seeding ───────────────────────────────────────

test "document ships a schema with no workspace_id, and every action is named in the prompt" {
    for (document_tool.function.parameters.properties) |prop| {
        try testing.expect(!std.mem.eql(u8, prop.name, "workspace_id"));
    }
    try testing.expectEqual(@as(usize, 1), document_tool.function.parameters.required.len);
    try testing.expectEqualStrings("action", document_tool.function.parameters.required[0]);
    try testing.expectEqualStrings(TOOL_NAME, document_tool.function.name);
    for ([_][]const u8{ "read", "search" }) |action| {
        try testing.expect(std.mem.indexOf(u8, document_tool.function.system_prompt, action) != null);
    }
}

test "document is offered to the model and resolves to exactly one dispatchable registry entry" {
    const tools_equipped = @import("tools_equipped.zig");

    const equip = tools_equipped.equips(testing.allocator);
    defer testing.allocator.free(equip);

    var in_equips = false;
    for (equip) |t| {
        if (std.mem.eql(u8, t.function.name, TOOL_NAME)) in_equips = true;
    }
    try testing.expect(in_equips);

    var entries: usize = 0;
    for (tools_equipped.UNIFIED_TOOL_REGISTRY()) |entry| {
        if (!std.mem.eql(u8, entry.name, TOOL_NAME)) continue;
        entries += 1;
        try testing.expectEqualStrings(TOOL_NAME, entry.tool_def.function.name);
    }
    try testing.expectEqual(@as(usize, 1), entries);
    try testing.expect(tools_equipped.isDispatchableToolName(TOOL_NAME));
}

test "document is seeded into every new agent, so a fresh agent can read what it writes" {
    const tools_equipped = @import("tools_equipped.zig");

    const alloc = testing.allocator;
    var ctx = try document_mod.exec_setupDb();
    defer ctx.deinit();

    try ctx.db.exec(alloc,
        \\CREATE TABLE agent_config_tools (id TEXT PRIMARY KEY, config_id TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, UNIQUE(config_id, tool_name))
    , &.{});

    try tools_equipped.seedDefaultAgentTools(alloc, .{ .db = &ctx.db }, "ag_view_seed", null);

    var found = false;
    var q = try ctx.db.query(alloc, "SELECT tool_name FROM agent_config_tools WHERE config_id = ?", &.{"ag_view_seed"});
    defer q.deinit();
    while ((q.next() catch null)) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], TOOL_NAME)) found = true;
    }
    try testing.expect(found);
}

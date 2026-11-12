//! `document_html` — the agent tool that authors HTML documents in its own
//! workspace. Three actions: `create`, `edit`, `read`.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const documents_store = pabrikcore.documents_store;
const workspace_scope = pabrikcore.workspace_scope;
const document_mod = pabrikcore.document_tool;

const testing = std.testing;

pub const TOOL_NAME = "document_html";

pub const DocumentHtmlInput = struct {
    action: []const u8 = "",
    document_id: []const u8 = "",
    title: ?[]const u8 = null,
    content: ?[]const u8 = null,
    old_text: ?[]const u8 = null,
    new_text: ?[]const u8 = null,
    replace_all: ?bool = null,
    /// `read`: byte offset to start the slice at.
    offset: ?i64 = null,
    /// `read`: maximum bytes to return.
    limit: ?i64 = null,
};

pub const document_html_tool_system_prompt =
    \\## HTML Document Tool — Behavior
    \\`document_html` authors HTML documents in YOUR workspace. `action` picks the operation: `create`, `edit`, `read`.
    \\- Scope is automatic. There is no `workspace_id` argument — passing one is ignored. A `document_id` from another workspace reports "not found", exactly as a nonexistent id does.
    \\- `create` needs `title`, which must be non-blank. It is the label shown in the sidebar's Documents list, so make it a human-readable name, not a slug. `content` is the page source and may be empty.
    \\- `content` is a COMPLETE HTML page: `<!doctype html>`, `<html>`, `<head>` and `<body>`. The page renders in a sandboxed iframe with no access to the app, so it must carry its own styles and scripts inline — a relative `<link>` or `<script src>` has nothing to resolve against.
    \\- The page is previewed at THREE preset widths plus a custom one, and the user switches between them: Desktop (the full pane), Tablet (768px), Mobile (390px), or any width they type. Write it responsively, because a page that only works at desktop width is a page the user cannot check on a phone. Concretely: include `<meta name="viewport" content="width=device-width, initial-scale=1">`; lay out with fluid units (`%`, `rem`, `clamp()`, `flex`, `grid`) rather than fixed pixel widths; and add at least one breakpoint (e.g. `@media (max-width: 640px)`) that stacks a multi-column layout and shrinks display type. Never set a `min-width` on `body` or a wrapper — that is what forces a horizontal scrollbar at 390px.
    \\- `edit` is a PATCH: an OMITTED field keeps its current value, `content: ""` genuinely clears the body, and supplying neither `title` nor `content` nor `old_text` is rejected. `content` is the WHOLE new page, not a diff.
    \\- `edit` with `old_text` + `new_text` patches the page IN PLACE — the cheap path for a large page, because you send only the changed text. `old_text` must match EXACTLY ONCE; a miss or an ambiguous match is refused and nothing is written, so include enough surrounding markup to be unique, or set `replace_all: true`. `new_text: ""` deletes the match. `content` and `old_text` are mutually exclusive.
    \\- `edit` refuses a document that is not an HTML document. A markdown or office document is `document_markdown`'s to change; this tool will not overwrite it.
    \\- `read` returns the page source as a bounded SLICE: `limit` bytes (default 20000, max 200000) starting at `offset` (default 0). The result carries `content_bytes` (the whole page's length), `offset`, `next_offset` and `truncated` — pass `next_offset` as the next `offset` to continue, and stop when `next_offset` is null. Read a slice, not the whole page: a 4 MiB page is 200 pages, and you rarely need more than the part you are about to change.
    \\- To SEARCH or DELETE documents of any format, use `document_markdown`. This tool does not duplicate those actions.
    \\- A human can also create and edit HTML documents from the UI; both paths write the same table, so a document you write appears in their sidebar immediately.
    \\
;

pub const document_html_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = TOOL_NAME,
        .description =
        \\Create, edit and read HTML documents in YOUR workspace — a landing page draft, a report, a self-contained demo, any page worth re-opening. `action` selects the operation: `create` (title + page source), `edit` (document_id + the fields to change), `read` (document_id).
        \\
        \\- SCOPE is automatic: your session's workspace is resolved before the call, so there is no `workspace_id` argument — one supplied is ignored.
        \\- `content` is a COMPLETE HTML page. It renders in a sandboxed iframe with no access to the app, so styles and scripts must be inline.
        \\- The page is previewed at Desktop, Tablet (768px), Mobile (390px) and any custom width the user types. Write it responsively: a `<meta name="viewport">` tag, fluid layout, and a breakpoint so it reads at 390px as well as at desktop width.
        \\- `edit` is a PATCH: omitted fields keep their current value, `content` is the COMPLETE new page (not a diff), and `content: ""` clears it. It refuses a document that is not HTML.
        \\- `read` returns the full page source. Use it before an `edit`.
        \\- To search or delete documents, use `document_markdown`.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "action",
                    .type = "string",
                    .description = "'create', 'edit' or 'read'. Any other value is refused.",
                },
                .{
                    .name = "document_id",
                    .type = "string",
                    .description = "`edit` and `read`: the id from a `create` result or a `document_markdown` search row. A row in another workspace reports 'not found'.",
                },
                .{
                    .name = "title",
                    .type = "string",
                    .description = "`create`: required, non-blank, human-readable — it is the sidebar label. `edit`: the new title; omit to keep the current one.",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "`create`: the page source, may be empty. `edit`: the COMPLETE new page (not a diff); omit to keep the current body, pass \"\" to clear it. Refused together with `old_text`. Capped at 4 MiB.",
                },
                .{
                    .name = "old_text",
                    .type = "string",
                    .description = "`edit`: exact text to find in the current page and replace with `new_text`. Use this instead of `content` to patch a large page without re-sending it. Must match EXACTLY ONCE unless `replace_all` is true; a miss or an ambiguous match is refused and nothing is written.",
                },
                .{
                    .name = "new_text",
                    .type = "string",
                    .description = "`edit`: the replacement for `old_text`. Pass \"\" to delete the matched text. Required whenever `old_text` is given.",
                },
                .{
                    .name = "replace_all",
                    .type = "boolean",
                    .description = "`edit`: replace EVERY occurrence of `old_text` instead of requiring exactly one. Default false.",
                },
                .{
                    .name = "offset",
                    .type = "number",
                    .description = "`read`: the BYTE offset to start the slice at (default 0). Pass the previous read's `next_offset` to continue.",
                },
                .{
                    .name = "limit",
                    .type = "number",
                    .description = "`read`: maximum BYTES of the page to return (default 20000, max 200000). The result reports the whole body's `content_bytes` and a `next_offset` — page with it instead of raising this.",
                },
            },
            .required = &.{"action"},
        },
        .system_prompt = document_html_tool_system_prompt,
    },
};

pub const DocumentHtmlSuccess = struct {
    id: []const u8,
    workspace_id: []const u8,
    title: []const u8,
    content: []const u8,
    format: []const u8,
    updated_at: []const u8,
};

pub const DocumentHtmlError = struct {
    @"error": []const u8,
};

fn errorJSON(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, DocumentHtmlError{ .@"error" = msg }, .{});
}

fn successJSON(allocator: std.mem.Allocator, row: documents_store.DocumentRow) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, DocumentHtmlSuccess{
        .id = row.id,
        .workspace_id = row.workspace_id,
        .title = row.title,
        .content = row.content,
        .format = row.format,
        .updated_at = row.updated_at,
    }, .{});
}

pub fn executeCreateHtml(
    allocator: std.mem.Allocator,
    store: documents_store.Store,
    caller_session_id: []const u8,
    input: DocumentHtmlInput,
) ![]const u8 {
    return document_mod.executeAddDocument(allocator, store, caller_session_id, .{
        .title = input.title,
        .content = input.content,
        .format = documents_store.FORMAT_HTML,
    });
}

pub fn executeEditHtml(
    allocator: std.mem.Allocator,
    store: documents_store.Store,
    caller_session_id: []const u8,
    input: DocumentHtmlInput,
) ![]const u8 {
    return document_mod.executeEditDocumentWithFormat(allocator, store, caller_session_id, .{
        .document_id = input.document_id,
        .title = input.title,
        .content = input.content,
        .old_text = input.old_text,
        .new_text = input.new_text,
        .replace_all = input.replace_all,
    }, documents_store.FORMAT_HTML);
}

pub fn executeReadHtml(
    allocator: std.mem.Allocator,
    store: documents_store.Store,
    caller_session_id: []const u8,
    input: DocumentHtmlInput,
) ![]const u8 {
    return document_mod.executeReadDocument(allocator, store, caller_session_id, .{
        .document_id = input.document_id,
        .offset = input.offset,
        .limit = input.limit,
    });
}

const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const document_events = exec_pabrikcore.document_events;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

const InnerResultProbe = struct {
    @"error": ?[]const u8 = null,
    id: []const u8 = "",
    workspace_id: []const u8 = "",
    title: []const u8 = "",
};

pub fn execDocumentHtml(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        DocumentHtmlInput,
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
    const store = documents_store.Store{ .db = ctx.db, .storage = ctx.storage };

    if (std.mem.eql(u8, input.action, "create")) {
        const inner = executeCreateHtml(ctx.allocator, store, ctx.session_id, input) catch |err| return execFailure(ctx, tc, err);
        defer ctx.allocator.free(inner);
        return finishMutation(ctx, tc, inner, "created");
    }
    if (std.mem.eql(u8, input.action, "edit")) {
        const inner = executeEditHtml(ctx.allocator, store, ctx.session_id, input) catch |err| return execFailure(ctx, tc, err);
        defer ctx.allocator.free(inner);
        return finishMutation(ctx, tc, inner, "updated");
    }
    if (std.mem.eql(u8, input.action, "read")) {
        const inner = executeReadHtml(ctx.allocator, store, ctx.session_id, input) catch |err| return execFailure(ctx, tc, err);
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

    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "action must be one of create, edit, read (got \"{s}\")",
        .{input.action},
    );
    defer ctx.allocator.free(msg);
    const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, false, msg, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

fn execFailure(ctx: ToolExecContext, tc: agent.ToolCall, err: anyerror) !ToolExecResult {
    const err_msg = try error_explain.explain(ctx.allocator, err, null);
    defer ctx.allocator.free(err_msg);
    const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, false, err_msg, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

fn finishMutation(ctx: ToolExecContext, tc: agent.ToolCall, inner: []const u8, action: []const u8) !ToolExecResult {
    if (std.json.parseFromSlice(InnerResultProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
        document_events.emitDocumentEvent(ctx.allocator, ctx.event_bus, .{
            .action = action,
            .workspace_id = probe.value.workspace_id,
            .document_id = probe.value.id,
            .title = probe.value.title,
        });
    }

    const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── Tests ──────────────────────────────────────────────────────────────

const test_db = exec_pabrikcore.test_db;
const database = exec_pabrikcore.database;
const migration = @import("../../../migrations/migration.zig");

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
    objects: @import("pabrikcore").storage.memory.MemoryStorage,

    fn deinit(self: *TestCtx) void {
        self.objects.deinit();
        self.db.deinit();
        self.threaded.deinit();
    }

    fn store(self: *TestCtx) documents_store.Store {
        return .{ .db = &self.db, .storage = self.objects.asStorage() };
    }
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

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
    try migration.Migration122AddDocumentPosition.up(&db, testing.allocator);
    try migration.Migration140AddDocumentFolders.up(&db, testing.allocator);
    try migration.Migration143AddDocumentContentKey.up(&db, testing.allocator);
    try migration.Migration144DropDocumentContent.up(&db, testing.allocator);
    try migration.Migration148AddDocumentIcon.up(&db, testing.allocator);

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
    return .{
        .db = db,
        .threaded = threaded,
        .objects = @import("pabrikcore").storage.memory.MemoryStorage.init(testing.allocator),
    };
}

const Parsed = struct {
    allocator: std.mem.Allocator,
    id: []const u8 = "",
    workspace_id: []const u8 = "",
    title: []const u8 = "",
    content: []const u8 = "",
    format: []const u8 = "",
    content_bytes: usize = 0,
    offset: usize = 0,
    next_offset: ?usize = null,
    truncated: bool = false,
    err: ?[]const u8 = null,

    fn deinit(self: *Parsed) void {
        const a = self.allocator;
        a.free(self.id);
        a.free(self.workspace_id);
        a.free(self.title);
        a.free(self.content);
        a.free(self.format);
        if (self.err) |e| a.free(e);
    }
};

fn parseJson(allocator: std.mem.Allocator, raw: []const u8) !Parsed {
    const Wire = struct {
        id: []const u8 = "",
        workspace_id: []const u8 = "",
        title: []const u8 = "",
        content: []const u8 = "",
        format: []const u8 = "",
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
        .workspace_id = try allocator.dupe(u8, p.value.workspace_id),
        .title = try allocator.dupe(u8, p.value.title),
        .content = try allocator.dupe(u8, p.value.content),
        .format = try allocator.dupe(u8, p.value.format),
        .content_bytes = p.value.content_bytes,
        .offset = p.value.offset,
        .next_offset = p.value.next_offset,
        .truncated = p.value.truncated,
        .err = if (p.value.@"error") |e| try allocator.dupe(u8, e) else null,
    };
}

test "document_html create: stores the page source as an html document in the caller's workspace" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const page = "<!doctype html><html><body><h1>Hello</h1></body></html>";
    const out = try executeCreateHtml(alloc, ctx.store(), "s1", .{
        .title = "Landing draft",
        .content = page,
    });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();

    try testing.expect(p.err == null);
    try testing.expect(p.id.len > 0);
    try testing.expectEqualStrings("ws_1", p.workspace_id);
    try testing.expectEqualStrings("Landing draft", p.title);
    try testing.expectEqualStrings(page, p.content);
    try testing.expectEqualStrings("html", p.format);
}

test "document_html create: a blank title is a tool error, not a stored row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const out = try executeCreateHtml(alloc, ctx.store(), "s1", .{ .title = "   ", .content = "<p>x</p>" });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();

    try testing.expect(p.err != null);
    try testing.expectEqualStrings("", p.id);

    const rows = try documents_store.listDocuments(alloc, &ctx.db, "ws_1");
    defer documents_store.freeDocumentRows(alloc, rows);
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "document_html edit: replaces the page source and keeps the html format" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const created = try executeCreateHtml(alloc, ctx.store(), "s1", .{ .title = "Page", .content = "<p>one</p>" });
    defer alloc.free(created);
    var c = try parseJson(alloc, created);
    defer c.deinit();

    const out = try executeEditHtml(alloc, ctx.store(), "s1", .{
        .document_id = c.id,
        .content = "<p>two</p>",
    });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();

    try testing.expect(p.err == null);
    try testing.expectEqualStrings("<p>two</p>", p.content);
    try testing.expectEqualStrings("Page", p.title);
    try testing.expectEqualStrings("html", p.format);
}

test "document_html edit: refuses a markdown document and leaves its body untouched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const created = try document_mod.executeAddDocument(alloc, ctx.store(), "s1", .{
        .title = "Notes",
        .content = "# keep me",
    });
    defer alloc.free(created);
    var c = try parseJson(alloc, created);
    defer c.deinit();

    const out = try executeEditHtml(alloc, ctx.store(), "s1", .{
        .document_id = c.id,
        .content = "<p>clobbered</p>",
    });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();

    try testing.expect(p.err != null);

    const row = try ctx.store().getDocument(alloc, "ws_1", c.id);
    defer documents_store.freeDocumentRow(alloc, row);
    try testing.expectEqualStrings("# keep me", row.content);
    try testing.expectEqualStrings("markdown", row.format);
}

test "document_html edit: old_text patches the page in place and keeps the rest" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const page = "<!doctype html><html><body><h1>Old title</h1><p>keep</p></body></html>";
    const created = try executeCreateHtml(alloc, ctx.store(), "s1", .{ .title = "Page", .content = page });
    defer alloc.free(created);
    var c = try parseJson(alloc, created);
    defer c.deinit();

    const out = try executeEditHtml(alloc, ctx.store(), "s1", .{
        .document_id = c.id,
        .old_text = "Old title",
        .new_text = "New title",
    });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();

    try testing.expect(p.err == null);
    try testing.expectEqualStrings(
        "<!doctype html><html><body><h1>New title</h1><p>keep</p></body></html>",
        p.content,
    );
    try testing.expectEqualStrings("html", p.format);
}

test "document_html edit: old_text on a markdown document is refused and leaves it untouched" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const created = try document_mod.executeAddDocument(alloc, ctx.store(), "s1", .{
        .title = "Notes",
        .content = "# keep me",
    });
    defer alloc.free(created);
    var c = try parseJson(alloc, created);
    defer c.deinit();

    const out = try executeEditHtml(alloc, ctx.store(), "s1", .{
        .document_id = c.id,
        .old_text = "keep me",
        .new_text = "clobbered",
    });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();

    try testing.expect(p.err != null);

    const row = try ctx.store().getDocument(alloc, "ws_1", c.id);
    defer documents_store.freeDocumentRow(alloc, row);
    try testing.expectEqualStrings("# keep me", row.content);
}

test "document_html read: returns the full page source" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const page = "<!doctype html><html><body><p>read me</p></body></html>";
    const created = try executeCreateHtml(alloc, ctx.store(), "s1", .{ .title = "Page", .content = page });
    defer alloc.free(created);
    var c = try parseJson(alloc, created);
    defer c.deinit();

    const out = try executeReadHtml(alloc, ctx.store(), "s1", .{ .document_id = c.id });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();

    try testing.expect(p.err == null);
    try testing.expectEqualStrings(page, p.content);
    try testing.expectEqualStrings("html", p.format);
}

test "document_html read: returns a bounded slice of the page, not the whole thing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const page = "<!doctype html><html><body><h1>Hello</h1></body></html>";
    const created = try executeCreateHtml(alloc, ctx.store(), "s1", .{ .title = "Page", .content = page });
    defer alloc.free(created);
    var c = try parseJson(alloc, created);
    defer c.deinit();

    const out = try executeReadHtml(alloc, ctx.store(), "s1", .{
        .document_id = c.id,
        .limit = 15,
    });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();

    try testing.expect(p.err == null);
    try testing.expectEqualStrings("<!doctype html>", p.content);
    try testing.expectEqual(page.len, p.content_bytes);
    try testing.expectEqual(@as(?usize, 15), p.next_offset);
    try testing.expect(p.truncated);
}

test "document_html read: another workspace's document reports not found" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.deinit();

    const created = try executeCreateHtml(alloc, ctx.store(), "s1", .{ .title = "Page", .content = "<p>secret</p>" });
    defer alloc.free(created);
    var c = try parseJson(alloc, created);
    defer c.deinit();

    const out = try executeReadHtml(alloc, ctx.store(), "s2", .{ .document_id = c.id });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();

    try testing.expect(p.err != null);
    try testing.expectEqualStrings("", p.content);
}

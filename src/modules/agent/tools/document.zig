//! `add_document` / `edit_document` / `delete_document` / `search_documents`
//! — the agent tools that let a model read and write its own workspace's
//! document store (Migration 098).

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const documents_store = pabrikcore.documents_store;
const workspace_scope = pabrikcore.workspace_scope;

const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;

const testing = std.testing;
const migration = @import("../../../migrations/migration.zig");

// =====================================================================
// Inputs
// =====================================================================

/// Args for `add_document`.
pub const AddDocumentInput = struct {
    title: []const u8 = "",
    content: []const u8 = "",
    /// Only 'markdown' is written in v1. Present so the schema is not
    /// silently markdown-shaped if a second format lands.
    format: []const u8 = "",
};

/// Args for `edit_document`.
pub const EditDocumentInput = struct {
    document_id: []const u8 = "",
    title: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

/// Args for `delete_document`. Deliberately ONE field.
pub const DeleteDocumentInput = struct {
    document_id: []const u8 = "",
};

/// Args for `search_documents`.
pub const SearchDocumentsInput = struct {
    query: ?[]const u8 = null,
    literal: ?bool = null,
    limit: ?i64 = null,
    offset: ?i64 = null,
    /// Opt-in full bodies.
    include_content: ?bool = null,
};

// =====================================================================
// Tool schemas
// =====================================================================

pub const add_document_tool_system_prompt =
    \\## Add Document Tool — Behavior
    \\Use `add_document` to create a markdown document in YOUR workspace.
    \\- Scope is automatic. There is no `workspace_id` argument — passing one is ignored. You can only write into the workspace your session belongs to.
    \\- `title` is REQUIRED and must be non-blank. It is the label shown in the sidebar's Documents list, so make it a human-readable name, not a slug.
    \\- `content` is the markdown body and may be empty (you can create a heading-only stub and fill it in with `edit_document`).
    \\- A human can also create and edit documents from the UI; both paths write the same table, so a document the agent writes appears in their sidebar immediately.
    \\
;

pub const add_document_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "add_document",
        .description =
        \\Create a markdown document in YOUR workspace — a plan, a spec, meeting notes, a research summary, any prose artifact worth re-reading later.
        \\
        \\- The document is stored in SQLite and shown in the "Documents" section of the sidebar, where the user can open and edit it.
        \\- SCOPE is automatic: your session's workspace is resolved before the write, so there is no `workspace_id` argument — one supplied is ignored.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "title", .type = "string", .description = "Human-readable document name, shown in the sidebar Documents list. Required, non-blank." },
                .{ .name = "content", .type = "string", .description = "The markdown body. May be empty. Capped at 4 MiB." },
                .{ .name = "format", .type = "string", .description = "Only 'markdown' is supported in this version; omit it." },
            },
            .required = &.{"title"},
        },
        .system_prompt = add_document_tool_system_prompt,
    },
};

pub const edit_document_tool_system_prompt =
    \\## Edit Document Tool — Behavior
    \\Use `edit_document` to change an existing document in YOUR workspace.
    \\- `document_id` comes from the id returned by `add_document`, or from a `search_documents` row. If you still have no id, run `search_documents` — do NOT guess one and do NOT ask the user to paste an id you can look up yourself.
    \\- Provide `title`, `content`, or both. An OMITTED field keeps its current value; `content: ""` genuinely clears the body. A patch with neither field is rejected.
    \\- `content` is the WHOLE new body, not a diff. Read the existing body first — `search_documents` with `include_content: true` returns it — or you will silently discard what is there.
    \\- Scope is automatic. A document belonging to another workspace reports "not found" — you cannot read it, edit it, or learn that it exists.
    \\
;

pub const edit_document_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "edit_document",
        .description =
        \\Edit an existing markdown document in YOUR workspace — append a section, correct a plan, expand a summary.
        \\
        \\- SCOPE is automatic: a `document_id` in another workspace reports "not found", exactly as a nonexistent id does — you cannot probe or enumerate another workspace.
        \\- PATCH: omitted fields keep their current value; `content` is the COMPLETE new body, not a diff (include everything the document should hold after the edit); `content: ""` clears the body, unlike omitting the field; supplying neither field is rejected.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "document_id", .type = "string", .description = "Document id from `add_document` or a `search_documents` row. A row in another workspace reports 'not found'." },
                .{ .name = "title", .type = "string", .description = "New title. Omit to keep the current one. Must be non-blank." },
                .{ .name = "content", .type = "string", .description = "The COMPLETE new body (not a diff). Omit to keep the current body; pass \"\" to clear it. Capped at 4 MiB." },
            },
            .required = &.{"document_id"},
        },
        .system_prompt = edit_document_tool_system_prompt,
    },
};

pub const delete_document_tool_system_prompt =
    \\## Delete Document Tool — Behavior
    \\Use `delete_document` to permanently remove ONE document from YOUR workspace.
    \\- This is IRREVERSIBLE. There is no trash, no undo, and no archive. Once the row is gone the body is unrecoverable — not through this tool, and not from the sidebar.
    \\- `document_id` must be an id you actually looked up with `search_documents`. Never construct one, never reuse an id from a different workspace, never delete a document just because you wrote it earlier in this session — a document the user has since revised is still their work.
    \\- Delete only what the user asked you to delete. "Find the doc about X" is not permission to remove X. If you are unsure which document they mean, ask instead of guessing.
    \\- Scope is automatic. A `document_id` from another workspace reports "not found" — identical to an id that never existed, so you cannot delete across a workspace boundary even by accident.
    \\- To revise a document instead of removing it, use `edit_document`.
    \\
;

pub const delete_document_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "delete_document",
        .description =
        \\Permanently delete ONE document from YOUR workspace by id. IRREVERSIBLE — the body is not moved to a trash and cannot be recovered.
        \\
        \\- SCOPE is automatic: a `document_id` in another workspace reports "not found", exactly as a nonexistent id does, so you cannot delete across a workspace boundary.
        \\- Use only when the user asked for the document to be REMOVED; revise with `edit_document` instead.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "document_id", .type = "string", .description = "Document id from `add_document` or a `search_documents` row. A row in another workspace reports 'not found'." },
            },
            .required = &.{"document_id"},
        },
        .system_prompt = delete_document_tool_system_prompt,
    },
};

pub const search_documents_tool_system_prompt =
    \\## Search Documents Tool — Behavior
    \\Use `search_documents` to find documents in YOUR workspace by title or body content. This is how you get a `document_id` — never invent one.
    \\- `query` is a REGEX (case-insensitive, unanchored) matched against each document's TITLE AND CONTENT. One pattern reaches a phrase that several words would: `release|launch`, `^Q3`, `\\bTODO\\b`.
    \\- Set `literal: true` when the query is literal text (e.g. `*.md`, `fn(`) — otherwise its metacharacters are interpreted.
    \\- Results are PAGED: `limit` (default 20, max 100) caps how many rows you get back, `total` is the real match count, `offset` continues the listing, and `hint` names the exact next offset.
    \\- An invalid pattern is not a failure: it is matched as a literal substring and the result carries `pattern_warning`. Read it instead of retrying blindly.
    \\- Every row carries a short `excerpt` around the hit plus `content_length` (bytes) — enough to tell documents apart without dumping megabytes of markdown into your context.
    \\- Pass `include_content: true` when the NEXT action is `edit_document`, which replaces the WHOLE body and therefore needs the current one first. Leave it off otherwise.
    \\- Omitting `query` lists your documents, newest-updated first — that is the right first call when you do not know what you are looking for.
    \\
;

pub const search_documents_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "search_documents",
        .description =
        \\Search YOUR workspace's documents by title OR body. This is how you get a `document_id` for `edit_document` / `delete_document` — never invent one. Omit `query` to list them newest-updated first.
        \\
        \\- `query` is a case-insensitive REGEX matched against title AND content. Pass `literal: true` for literal text.
        \\- An invalid pattern is matched as a literal substring and reported in `pattern_warning`, not as a failure.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "query",
                    .type = "string",
                    .description = "Regex, matched case-insensitively against each document's title AND content. Supported: literals, '.', '[...]', '\\d \\w \\s \\b', '*', '+', '?', '{m,n}' ranges, '( )' groups, '|', '^', '$'. A metacharacter-free query is a plain substring search. An invalid pattern is matched as a literal substring and reported in `pattern_warning`. Omit to list the newest documents first.",
                },
                .{
                    .name = "literal",
                    .type = "boolean",
                    .description = "Treat `query` as a literal string — '.', '*', '[', '(' are matched verbatim. Set this for code- or glob-shaped queries ('*.md', 'fn('). Default false (regex mode).",
                },
                .{
                    .name = "limit",
                    .type = "number",
                    .description = "Maximum matches in THIS response (default 20, max 100). The result always reports the true `total` — raise limit, or page with `offset`, only when you need more.",
                },
                .{
                    .name = "offset",
                    .type = "number",
                    .description = "Skip the first N matches (default 0). The previous page's `hint` names the offset that continues it.",
                },
                .{
                    .name = "include_content",
                    .type = "boolean",
                    .description = "Include each match's FULL body as `content`. Off by default — rows carry a bounded `excerpt` instead. Turn it on only when the next action is `edit_document`, which replaces the whole body.",
                },
            },
            .required = &.{},
        },
        .system_prompt = search_documents_tool_system_prompt,
    },
};

// =====================================================================
// Result payloads
// =====================================================================

/// Success payload for both tools. `content` is echoed because the model
/// often needs to confirm what landed (and `edit_document` is a whole-body
/// replace, so the echo is the only proof of what is now stored).
pub const DocumentToolSuccess = struct {
    id: []const u8,
    workspace_id: []const u8,
    title: []const u8,
    content: []const u8,
    format: []const u8,
    updated_at: []const u8,
};

/// Error payload shared by `add_document` / `edit_document` /
/// `delete_document` / `search_documents`.
pub const DocumentToolError = struct {
    @"error": []const u8,
};

/// Success payload for `delete_document`. The DELETED title is echoed, not
/// the body.
pub const DeleteDocumentSuccess = struct {
    id: []const u8,
    title: []const u8,
    deleted: bool,
};

fn successJSON(allocator: std.mem.Allocator, row: documents_store.DocumentRow) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, DocumentToolSuccess{
        .id = row.id,
        .workspace_id = row.workspace_id,
        .title = row.title,
        .content = row.content,
        .format = row.format,
        .updated_at = row.updated_at,
    }, .{});
}

fn errorJSON(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const clean = try sanitizeControlChars(allocator, msg);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, DocumentToolError{
        .@"error" = clean,
    }, .{});
}

/// Resolve the calling session's workspace.
fn resolveScope(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
) !?[]u8 {
    // Rejected BEFORE any DB access: `SqliteBackend.exec` binds a
    // zero-length slice as SQL NULL, so querying with "" would not be a
    // harmless no-op.
    if (caller_session_id.len == 0) return null;
    return workspace_scope.resolveWorkspaceId(allocator, db, caller_session_id) catch null;
}

/// The tool-level refusal for an unresolvable scope.
fn scopeErrorJSON(allocator: std.mem.Allocator, caller_session_id: []const u8) ![]u8 {
    if (caller_session_id.len == 0) {
        return errorJSON(
            allocator,
            "Missing caller session — cannot resolve which workspace to write to.",
        );
    }
    return errorJSON(
        allocator,
        "This session is not linked to any workspace, so there is nowhere to store a document. " ++
            "Run from a workspace chat (a project task or a workspace-scoped chat).",
    );
}

// =====================================================================
// Executors
// =====================================================================

/// Execute `add_document`. Returns an inner JSON string the exec wrapper
/// embeds. Caller owns the returned slice and must free it.
pub fn executeAddDocument(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    input: AddDocumentInput,
) ![]const u8 {
    const workspace_id = (try resolveScope(allocator, db, caller_session_id)) orelse
        return scopeErrorJSON(allocator, caller_session_id);
    defer allocator.free(workspace_id);

    const row = documents_store.createDocument(allocator, db, .{
        .workspace_id = workspace_id,
        .title = input.title,
        .content = input.content,
        .format = input.format,
    }) catch |err| {
        const msg = switch (err) {
            error.WorkspaceIdRequired => "Could not resolve this session's workspace.",
            error.TitleRequired => "title is required and must contain at least one non-whitespace character",
            error.ContentTooLarge => "content exceeds the 4 MiB per-document cap",
            error.InsertFailed => "Could not store the document (database error).",
            error.RowNotFoundAfterInsert => "The document was written but could not be read back — the row is inconsistent, please retry.",
            error.OutOfMemory => "Out of memory",
        };
        return errorJSON(allocator, msg);
    };
    defer documents_store.freeDocumentRow(allocator, row);
    return successJSON(allocator, row);
}

/// Execute `edit_document`. Returns an inner JSON string the exec wrapper
/// embeds. Caller owns the returned slice and must free it.
pub fn executeEditDocument(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    input: EditDocumentInput,
) ![]const u8 {
    if (std.mem.trim(u8, input.document_id, " \t\n\r").len == 0) {
        return errorJSON(allocator, "document_id is required. Use the id returned by add_document.");
    }
    if (input.title == null and input.content == null) {
        // Silently succeeding here would teach the model that an empty
        // patch is a valid edit, which is how a document gets "updated"
        // without any change ever being made.
        return errorJSON(allocator, "Nothing to change: supply `title`, `content`, or both. Omitted fields keep their current value.");
    }

    const workspace_id = (try resolveScope(allocator, db, caller_session_id)) orelse
        return scopeErrorJSON(allocator, caller_session_id);
    defer allocator.free(workspace_id);

    const row = documents_store.updateDocument(allocator, db, workspace_id, input.document_id, .{
        .title = input.title,
        .content = input.content,
    }) catch |err| {
        const msg = switch (err) {
            error.IdsRequired => "workspace_id and document_id required",
            // One message for "no such id", "another workspace's id" and "you
            // blanked the title" — the first two must be indistinguishable or
            // the tool becomes an oracle for other workspaces' row ids.
            error.NotFound => "No document with that id in your workspace. It may not exist, or it may belong to another workspace.",
            error.ContentTooLarge => "content exceeds the 4 MiB per-document cap",
            error.UpdateFailed => "Could not save the document (database error).",
            error.QueryFailed => "Could not read the document (database error).",
            error.OutOfMemory => "Out of memory",
        };
        return errorJSON(allocator, msg);
    };
    defer documents_store.freeDocumentRow(allocator, row);
    return successJSON(allocator, row);
}

/// Execute `delete_document`. Returns an inner JSON string the exec wrapper
/// embeds. Caller owns the returned slice and must free it.
pub fn executeDeleteDocument(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    caller_session_id: []const u8,
    input: DeleteDocumentInput,
) ![]const u8 {
    if (std.mem.trim(u8, input.document_id, " \t\n\r").len == 0) {
        return errorJSON(allocator, "document_id is required. Look the id up with search_documents.");
    }

    const workspace_id = (try resolveScope(allocator, db, caller_session_id)) orelse
        return scopeErrorJSON(allocator, caller_session_id);
    defer allocator.free(workspace_id);

    const existing = documents_store.getDocument(allocator, db, workspace_id, input.document_id) catch |err| {
        const msg = switch (err) {
            error.IdsRequired => "workspace_id and document_id required",
            // One message for "no such id" and "another workspace's id" —
            // see the note on edit_document's NotFound arm.
            error.NotFound => "No document with that id in your workspace. It may not exist, or it may belong to another workspace.",
            error.QueryFailed => "Could not read the document (database error).",
            error.OutOfMemory => "Out of memory",
        };
        return errorJSON(allocator, msg);
    };
    defer documents_store.freeDocumentRow(allocator, existing);

    documents_store.deleteDocument(allocator, db, workspace_id, input.document_id) catch |err| {
        const msg = switch (err) {
            error.IdsRequired => "workspace_id and document_id required",
            // Unreachable in practice: we just read the row through the
            // same scope guard. It is still mapped rather than leaked, so a
            // future change cannot turn a race into an unhandled error.
            error.NotFound => "No document with that id in your workspace. It may not exist, or it may belong to another workspace.",
            error.DeleteFailed => "Could not delete the document (database error).",
        };
        return errorJSON(allocator, msg);
    };

    return std.json.Stringify.valueAlloc(allocator, DeleteDocumentSuccess{
        .id = existing.id,
        .title = existing.title,
        .deleted = true,
    }, .{});
}

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Two workspaces, one session each, so a cross-workspace leak has somewhere
/// to show up.
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

    // ws_1 owns item i1; ws_2 owns item i2. s1 is task-linked to i1, s2
    // to i2 — the exact-task-link branch of resolveWorkspaceId.
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

/// Owned, deinit-able view of a tool result. `std.json.parseFromSlice`
/// allocates every string into an arena owned by the `Parsed` value, and
/// `deinit` frees that arena.
const Parsed = struct {
    allocator: std.mem.Allocator,
    id: []const u8 = "",
    workspace_id: []const u8 = "",
    title: []const u8 = "",
    content: []const u8 = "",
    format: []const u8 = "",
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
        .err = if (p.value.@"error") |e| try allocator.dupe(u8, e) else null,
    };
}

// ─── add_document ───────────────────────────────────────────────────────

test "add_document: creates a markdown document in the caller's own workspace" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try executeAddDocument(alloc, &ctx.db, "s1", .{
        .title = "Release plan",
        .content = "# v1\n\nship it",
    });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();

    try testing.expect(p.err == null);
    try testing.expect(p.id.len > 0);
    try testing.expectEqualStrings("ws_1", p.workspace_id);
    try testing.expectEqualStrings("Release plan", p.title);
    try testing.expectEqualStrings("# v1\n\nship it", p.content);
    try testing.expectEqualStrings("markdown", p.format);
}

test "add_document: a blank title is a tool error, not a Zig error" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try executeAddDocument(alloc, &ctx.db, "s1", .{ .title = "   \n " });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();
    try testing.expect(p.err != null);
    try testing.expect(std.mem.indexOf(u8, p.err.?, "title") != null);
}

test "add_document: an empty body round-trips as \"\" rather than blowing up on NOT NULL" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try executeAddDocument(alloc, &ctx.db, "s1", .{ .title = "Blank", .content = "" });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();
    try testing.expect(p.err == null);
    try testing.expectEqualStrings("", p.content);
}

test "add_document: an empty caller session fails closed instead of picking a workspace" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try executeAddDocument(alloc, &ctx.db, "", .{ .title = "Nowhere" });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();
    try testing.expect(p.err != null);

    // And nothing was written anywhere — "no scope" must not degrade into
    // "some scope".
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM documents", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "add_document: a session with no resolvable workspace fails closed" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try executeAddDocument(alloc, &ctx.db, "s_orphan", .{ .title = "Nowhere" });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();
    try testing.expect(p.err != null);
    try testing.expect(std.mem.indexOf(u8, p.err.?, "workspace") != null);
}

test "add_document: two workspaces writing the same title never collide or leak" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const a = try executeAddDocument(alloc, &ctx.db, "s1", .{ .title = "Shared title", .content = "from A" });
    defer alloc.free(a);
    const b = try executeAddDocument(alloc, &ctx.db, "s2", .{ .title = "Shared title", .content = "from B" });
    defer alloc.free(b);

    var pa = try parseJson(alloc, a);
    defer pa.deinit();
    var pb = try parseJson(alloc, b);
    defer pb.deinit();
    try testing.expectEqualStrings("ws_1", pa.workspace_id);
    try testing.expectEqualStrings("ws_2", pb.workspace_id);
    // Same title, different rows — the id is nano-timestamp based and the
    // two calls are separate statements, so they must differ.
    try testing.expect(!std.mem.eql(u8, pa.id, pb.id));
}

// ─── edit_document ──────────────────────────────────────────────────────

/// Create a document in ws_1 and return its id (caller frees).
fn seedDoc(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, title: []const u8, content: []const u8) ![]u8 {
    const out = try executeAddDocument(alloc, db, "s1", .{ .title = title, .content = content });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();
    if (p.err != null) return error.SeedDocumentFailed;
    return alloc.dupe(u8, p.id);
}

test "edit_document: replaces the body and keeps the title when only content is given" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try seedDoc(alloc, &ctx.db, "Plan", "old body");
    defer alloc.free(id);

    const out = try executeEditDocument(alloc, &ctx.db, "s1", .{ .document_id = id, .content = "new body" });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();
    try testing.expect(p.err == null);
    try testing.expectEqualStrings("Plan", p.title);
    try testing.expectEqualStrings("new body", p.content);
}

test "edit_document: an omitted field is a no-op, an explicit empty string is a clear" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try seedDoc(alloc, &ctx.db, "Plan", "body to keep");
    defer alloc.free(id);

    // title-only patch: the body must survive.
    const renamed = try executeEditDocument(alloc, &ctx.db, "s1", .{ .document_id = id, .title = "Renamed" });
    defer alloc.free(renamed);
    var pr = try parseJson(alloc, renamed);
    defer pr.deinit();
    try testing.expectEqualStrings("Renamed", pr.title);
    try testing.expectEqualStrings("body to keep", pr.content);

    // explicit "" clears the body — different from omitting the field.
    const cleared = try executeEditDocument(alloc, &ctx.db, "s1", .{ .document_id = id, .content = "" });
    defer alloc.free(cleared);
    var pc = try parseJson(alloc, cleared);
    defer pc.deinit();
    try testing.expectEqualStrings("", pc.content);
    try testing.expectEqualStrings("Renamed", pc.title);
}

test "edit_document: a patch with neither field is rejected, not silently accepted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try seedDoc(alloc, &ctx.db, "Plan", "unchanged");
    defer alloc.free(id);

    const out = try executeEditDocument(alloc, &ctx.db, "s1", .{ .document_id = id });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();
    try testing.expect(p.err != null);
    try testing.expect(std.mem.indexOf(u8, p.err.?, "title") != null);
}

test "edit_document: a missing document_id is rejected before any DB work" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try executeEditDocument(alloc, &ctx.db, "s1", .{ .content = "x" });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();
    try testing.expect(p.err != null);
    try testing.expect(std.mem.indexOf(u8, p.err.?, "document_id") != null);
}

test "edit_document: workspace B cannot edit workspace A's document, and the error is identical to a missing one" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try seedDoc(alloc, &ctx.db, "Private", "ws_1 only");
    defer alloc.free(id);

    // Same session, real foreign id.
    const denied = try executeEditDocument(alloc, &ctx.db, "s2", .{ .document_id = id, .content = "hijacked" });
    defer alloc.free(denied);
    var d = try parseJson(alloc, denied);
    defer d.deinit();

    // Different session, nonexistent id. If these two messages differ,
    // the tool is an oracle for other workspaces' row ids.
    const missing = try executeEditDocument(alloc, &ctx.db, "s2", .{ .document_id = "doc_does_not_exist", .content = "x" });
    defer alloc.free(missing);
    var m = try parseJson(alloc, missing);
    defer m.deinit();

    try testing.expect(d.err != null);
    try testing.expectEqualStrings(d.err.?, m.err.?);

    // And the owner's copy is untouched — a rejected cross-workspace edit
    // must not half-apply.
    const read_back = try documents_store.getDocument(alloc, &ctx.db, "ws_1", id);
    defer documents_store.freeDocumentRow(alloc, read_back);
    try testing.expectEqualStrings("ws_1 only", read_back.content);
}

test "edit_document: no content leaks through the cross-workspace denial" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try seedDoc(alloc, &ctx.db, "Private", "TOPSECRETBODY");
    defer alloc.free(id);

    const denied = try executeEditDocument(alloc, &ctx.db, "s2", .{ .document_id = id, .content = "x" });
    defer alloc.free(denied);
    try testing.expect(std.mem.indexOf(u8, denied, "TOPSECRETBODY") == null);
}

// ─── delete_document ────────────────────────────────────────────────────

test "delete_document: removes the row and names what it removed" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try seedDoc(alloc, &ctx.db, "Obsolete plan", "no longer needed");
    defer alloc.free(id);

    const out = try executeDeleteDocument(alloc, &ctx.db, "s1", .{ .document_id = id });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();

    try testing.expect(p.err == null);
    try testing.expectEqualStrings(id, p.id);
    try testing.expectEqualStrings("Obsolete plan", p.title);
    try testing.expect(std.mem.indexOf(u8, out, "\"deleted\":true") != null);

    // And the row is actually gone from the table, not merely reported gone.
    const after = documents_store.getDocument(alloc, &ctx.db, "ws_1", id);
    try testing.expectError(error.NotFound, after);
}

test "delete_document: an empty document_id is rejected before any DB work" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try executeDeleteDocument(alloc, &ctx.db, "s1", .{ .document_id = "   " });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();
    try testing.expect(p.err != null);
    try testing.expect(std.mem.indexOf(u8, p.err.?, "document_id") != null);
}

test "delete_document: an unresolvable session deletes nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try seedDoc(alloc, &ctx.db, "Survivor", "still here");
    defer alloc.free(id);

    const out = try executeDeleteDocument(alloc, &ctx.db, "s_orphan", .{ .document_id = id });
    defer alloc.free(out);
    var p = try parseJson(alloc, out);
    defer p.deinit();
    try testing.expect(p.err != null);

    const still = try documents_store.getDocument(alloc, &ctx.db, "ws_1", id);
    defer documents_store.freeDocumentRow(alloc, still);
    try testing.expectEqualStrings("still here", still.content);
}

test "delete_document: workspace B cannot delete workspace A's document, and the error is identical to a missing one" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try seedDoc(alloc, &ctx.db, "Private", "TOPSECRETBODY");
    defer alloc.free(id);

    const denied = try executeDeleteDocument(alloc, &ctx.db, "s2", .{ .document_id = id });
    defer alloc.free(denied);
    var d = try parseJson(alloc, denied);
    defer d.deinit();

    const missing = try executeDeleteDocument(alloc, &ctx.db, "s2", .{
        .document_id = "doc_nope",
    });
    defer alloc.free(missing);
    var m = try parseJson(alloc, missing);
    defer m.deinit();

    try testing.expect(d.err != null);
    try testing.expectEqualStrings(d.err.?, m.err.?);
    try testing.expect(std.mem.indexOf(u8, denied, "TOPSECRETBODY") == null);

    // A refused cross-workspace delete must not half-apply.
    const read_back = try documents_store.getDocument(alloc, &ctx.db, "ws_1", id);
    defer documents_store.freeDocumentRow(alloc, read_back);
    try testing.expectEqualStrings("TOPSECRETBODY", read_back.content);
}

// ─── Schema contracts ───────────────────────────────────────────────────

test "schema contract: no tool the model sees takes a workspace_id" {
    // The whole isolation argument rests on the model never being able to
    // choose its own workspace.
    for ([_]AgentTool{ add_document_tool, edit_document_tool, delete_document_tool, search_documents_tool }) |tool| {
        for (tool.function.parameters.properties) |prop| {
            try testing.expect(!std.mem.eql(u8, prop.name, "workspace_id"));
        }
        for (tool.function.parameters.required) |req| {
            try testing.expect(!std.mem.eql(u8, req, "workspace_id"));
        }
    }
}

test "schema contract: no input struct has a workspace_id slot to fill" {
    // Belt to the schema braces: even if the schema is left clean, a struct
    // field would be a slot for `ignore_unknown_fields` to fill.
    inline for (.{ AddDocumentInput, EditDocumentInput }) |T| {
        const fields = @typeInfo(T).@"struct".fields;
        try testing.expectEqual(@as(usize, 3), fields.len);
        inline for (fields, 0..) |f, i| {
            // `fields` values hold a `type`, so they must be indexed at
            // comptime — hence inline for, not a runtime loop.
            _ = i;
            try testing.expect(!std.mem.eql(u8, f.name, "workspace_id"));
        }
    }

    // `DeleteDocumentInput` and `SearchDocumentsInput` carry their own
    // counts: one field, and five. An extra field on either is how a
    // "just one knob more" scope or delete mode sneaks in.
    try testing.expectEqual(@as(usize, 1), @typeInfo(DeleteDocumentInput).@"struct".fields.len);
    const search_fields = @typeInfo(SearchDocumentsInput).@"struct".fields;
    try testing.expectEqual(@as(usize, 5), search_fields.len);
    inline for (search_fields) |f| {
        try testing.expect(!std.mem.eql(u8, f.name, "workspace_id"));
    }
}

test "schema contract: all four tools ship a behavioral system prompt" {
    // The aggregator in prompts_build_messages_for_agent_prompt.zig reads
    // `system_prompt` straight off the schema.
    try testing.expect(add_document_tool.function.system_prompt.len > 0);
    try testing.expect(edit_document_tool.function.system_prompt.len > 0);
    try testing.expect(delete_document_tool.function.system_prompt.len > 0);
    try testing.expect(search_documents_tool.function.system_prompt.len > 0);
    try testing.expectEqualStrings("add_document", add_document_tool.function.name);
    try testing.expectEqualStrings("edit_document", edit_document_tool.function.name);
    try testing.expectEqualStrings("delete_document", delete_document_tool.function.name);
    try testing.expectEqualStrings("search_documents", search_documents_tool.function.name);
}

test "schema contract: no prompt tells the model a search tool does not exist" {
    // The `edit_document` prompt once said "There is no list/search tool in
    // v1" — and `search_documents` now exists.
    try testing.expect(std.mem.indexOf(u8, edit_document_tool.function.system_prompt, "no list/search tool") == null);
    try testing.expect(std.mem.indexOf(u8, edit_document_tool.function.system_prompt, "search_documents") != null);
}

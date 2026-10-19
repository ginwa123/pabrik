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
    workspace_id: []const u8,
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
        .workspace_id = workspace_id,
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

// Exec adapter — merged from `document.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const documents_search = @import("../../../agentic_loop/documents_search.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const document_mod = exec_pabrikcore.document_tool;
const exec_documents_store = exec_pabrikcore.documents_store;
const exec_workspace_scope = exec_pabrikcore.workspace_scope;
const document_events = exec_pabrikcore.document_events;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
/// The inner tool payload read back at the exec wrapper: a refusal in `"error"`, or the row a
/// mutation touched (which the `documents` SSE channel needs). Slices borrow from `parsed` — free
/// it only after `wrapToolOutput`.
const InnerResultProbe = struct {
    @"error": ?[]const u8 = null,
    id: []const u8 = "",
    workspace_id: []const u8 = "",
    title: []const u8 = "",
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

    if (std.json.parseFromSlice(InnerResultProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "add_document", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
        // Only a real write reaches here: every refusal above returned.
        document_events.emitDocumentEvent(ctx.allocator, ctx.event_bus, .{
            .action = "created",
            .workspace_id = probe.value.workspace_id,
            .document_id = probe.value.id,
            .title = probe.value.title,
        });
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

    if (std.json.parseFromSlice(InnerResultProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "edit_document", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
        // Only a real write reaches here: every refusal above returned.
        document_events.emitDocumentEvent(ctx.allocator, ctx.event_bus, .{
            .action = "updated",
            .workspace_id = probe.value.workspace_id,
            .document_id = probe.value.id,
            .title = probe.value.title,
        });
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

    if (std.json.parseFromSlice(InnerResultProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "delete_document", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
        // Only a real removal reaches here: every refusal above returned.
        document_events.emitDocumentEvent(ctx.allocator, ctx.event_bus, .{
            .action = "deleted",
            .workspace_id = probe.value.workspace_id,
            .document_id = probe.value.id,
            .title = probe.value.title,
        });
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
    const workspace_id = exec_workspace_scope.resolveWorkspaceId(ctx.allocator, ctx.db, ctx.session_id) catch null;
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
    const rows = exec_documents_store.searchDocuments(
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
    defer exec_documents_store.freeDocumentRows(ctx.allocator, rows);

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

const exec_sqlite = exec_pabrikcore.sqlite;
const exec_testing = std.testing;
const exec_migration = @import("../../../migrations/migration.zig");

const exec_TestCtx = struct {
    db: exec_sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn exec_setupDb() !exec_TestCtx {
    var threaded = std.Io.Threaded.init(exec_testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: exec_sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(exec_testing.allocator,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT DEFAULT 'active', cwd TEXT)
    , &.{});
    try db.exec(exec_testing.allocator,
        \\CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER)
    , &.{});
    try db.exec(exec_testing.allocator,
        \\CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL)
    , &.{});
    try exec_migration.Migration098CreateDocuments.up(&db, exec_testing.allocator);

    try db.exec(exec_testing.allocator,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES
        \\  ('i1', 'ws_1', 'kanban', 'A', '/proj/a', 1),
        \\  ('i2', 'ws_2', 'kanban', 'B', '/proj/b', 1)
    , &.{});
    try db.exec(exec_testing.allocator,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES
        \\  ('s1', 'T1', 'i1'), ('s2', 'T2', 'i2')
    , &.{});
    try db.exec(exec_testing.allocator,
        \\INSERT INTO sessions (id, name, status, cwd) VALUES
        \\  ('s1', 'One', 'active', '/proj/a'),
        \\  ('s2', 'Two', 'active', '/proj/b')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn makeTestCtx(allocator: std.mem.Allocator, db: *exec_sqlite.SqliteBackend, session_id: []const u8) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = exec_testing.io,
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
    // of undefined pointers — which the exec_testing allocator reports as a leak
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
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tc = makeTestCtx(alloc, &ctx.db, "s1");
    const result = try execAddDocument(tc, fakeToolCall("add_document", "{\"title\":\"Notes\",\"content\":\"# hi\"}"));
    defer alloc.free(result.output);

    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try exec_testing.expectEqualStrings("add_document", env.tool);
    try exec_testing.expect(env.success);
    try exec_testing.expect(env.err == null);
    try exec_testing.expectEqualStrings("ws_1", env.workspace_id);
    try exec_testing.expectEqualStrings("Notes", env.title);
}

test "execAddDocument: a tool-level refusal surfaces as success=false" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
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
    try exec_testing.expect(!env.success);
    try exec_testing.expect(env.err != null);
    try exec_testing.expect(std.mem.indexOf(u8, env.err.?, "session") != null);
}

test "execAddDocument: malformed JSON arguments become a parse failure, not a crash" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tc = makeTestCtx(alloc, &ctx.db, "s1");
    const result = try execAddDocument(tc, fakeToolCall("add_document", "{not json"));
    defer alloc.free(result.output);

    var env = try parseEnvelope(alloc, result.output);
    defer env.deinit();
    try exec_testing.expect(!env.success);
    // The message must tell the model WHAT was wrong with its JSON, not
    // just name the Zig error. `{not json` is a syntax error, so the
    // explanation names JSON and the usual causes.
    try exec_testing.expect(std.mem.indexOf(u8, env.err.?, "JSON") != null);
    try exec_testing.expect(std.mem.indexOf(u8, env.err.?, "SyntaxError") == null);
}

test "execAddDocument: a hallucinated workspace_id is ignored, not honoured" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
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
    try exec_testing.expect(env.success);
    try exec_testing.expectEqualStrings("ws_1", env.workspace_id);
}

test "execEditDocument: a cross-workspace edit is refused and the row is untouched" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
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
    try exec_testing.expect(!env.success);
    try exec_testing.expect(env.err != null);
    try exec_testing.expect(std.mem.indexOf(u8, edit.output, "TOPSECRET") == null);
}

test "execEditDocument: success envelope echoes the new body" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
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
    try exec_testing.expect(env.success);
    try exec_testing.expectEqualStrings("v2", env.content);
    // The title was omitted, so it must have survived.
    try exec_testing.expectEqualStrings("Plan", env.title);
}

// ─── delete_document ────────────────────────────────────────────────────

test "execDeleteDocument: success envelope names the document it removed" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
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
    try exec_testing.expectEqualStrings("delete_document", env.tool);
    try exec_testing.expect(env.success);
    try exec_testing.expect(env.err == null);
    try exec_testing.expectEqualStrings(created.id, env.id);
    try exec_testing.expectEqualStrings("Obsolete", env.title);
    try exec_testing.expect(std.mem.indexOf(u8, del.output, "\"deleted\":true") != null);

    // The body is gone from the table, not just from the response.
    try exec_testing.expectError(error.NotFound, exec_documents_store.getDocument(alloc, &ctx.db, "ws_1", created.id));
}

test "execDeleteDocument: malformed JSON arguments become a parse failure, not a crash" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const del = try execDeleteDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("delete_document", "{not json"));
    defer alloc.free(del.output);

    var env = try parseEnvelope(alloc, del.output);
    defer env.deinit();
    try exec_testing.expect(!env.success);
    // The message must tell the model WHAT was wrong with its JSON, not
    // just name the Zig error. `{not json` is a syntax error, so the
    // explanation names JSON and the usual causes.
    try exec_testing.expect(std.mem.indexOf(u8, env.err.?, "JSON") != null);
    try exec_testing.expect(std.mem.indexOf(u8, env.err.?, "SyntaxError") == null);
}

test "execDeleteDocument: a hallucinated workspace_id is ignored, so the owner still deletes" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const create = try execAddDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("add_document", "{\"title\":\"Mine\",\"content\":\"x\",\"workspace_id\":\"ws_2\"}"));
    defer alloc.free(create.output);
    var created = try parseEnvelope(alloc, create.output);
    defer created.deinit();
    try exec_testing.expectEqualStrings("ws_1", created.workspace_id);

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
    try exec_testing.expect(env.success);
    try exec_testing.expectError(error.NotFound, exec_documents_store.getDocument(alloc, &ctx.db, "ws_1", created.id));
}

test "execDeleteDocument: a cross-workspace delete is refused and leaks nothing" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
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

    try exec_testing.expect(!d.success);
    try exec_testing.expect(!m.success);
    // Identical messages, or the tool is an oracle for other workspaces' ids.
    try exec_testing.expectEqualStrings(d.err.?, m.err.?);
    try exec_testing.expect(std.mem.indexOf(u8, denied.output, "TOPSECRETBODY") == null);

    const survivor = try exec_documents_store.getDocument(alloc, &ctx.db, "ws_1", created.id);
    defer exec_documents_store.freeDocumentRow(alloc, survivor);
    try exec_testing.expectEqualStrings("TOPSECRETBODY", survivor.content);
}

test "execDeleteDocument: an unresolvable session surfaces success=false" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const del = try execDeleteDocument(
        makeTestCtx(alloc, &ctx.db, "s_orphan"),
        fakeToolCall("delete_document", "{\"document_id\":\"doc_anything\"}"),
    );
    defer alloc.free(del.output);

    var env = try parseEnvelope(alloc, del.output);
    defer env.deinit();
    try exec_testing.expect(!env.success);
    try exec_testing.expect(env.err != null);
}

// ─── search_documents ───────────────────────────────────────────────────

/// Create a document in ws_1 through the real tool path and return its id.
fn exec_seedDoc(alloc: std.mem.Allocator, db: *exec_sqlite.SqliteBackend, title: []const u8, content: []const u8) ![]u8 {
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
fn seedAnon(alloc: std.mem.Allocator, db: *exec_sqlite.SqliteBackend, title: []const u8, content: []const u8) !void {
    const id = try exec_seedDoc(alloc, db, title, content);
    alloc.free(id);
}

fn runSearch(alloc: std.mem.Allocator, db: *exec_sqlite.SqliteBackend, session: []const u8, args: []const u8) !Envelope {
    const res = try execSearchDocuments(makeTestCtx(alloc, db, session), fakeToolCall("search_documents", args));
    // `parseEnvelope` dupes everything it needs, so the raw output can go.
    defer alloc.free(res.output);
    return parseEnvelope(alloc, res.output);
}

test "execSearchDocuments: no arguments lists the workspace newest-first in mode=all" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const a = try exec_seedDoc(alloc, &ctx.db, "Alpha", "first body");
    defer alloc.free(a);
    const b = try exec_seedDoc(alloc, &ctx.db, "Beta", "second body");
    defer alloc.free(b);

    var env = try runSearch(alloc, &ctx.db, "s1", "{}");
    defer env.deinit();

    try exec_testing.expectEqualStrings("search_documents", env.tool);
    try exec_testing.expect(env.success);
    try exec_testing.expectEqual(@as(usize, 2), env.total);
    try exec_testing.expectEqual(@as(usize, 2), env.count);
    try exec_testing.expectEqualStrings("all", env.pattern_mode);
    try exec_testing.expect(!env.truncated);
    try exec_testing.expect(env.next_offset == null);
    // Every row carries what the model needs to make the next call.
    try exec_testing.expectEqual(@as(usize, 2), env.ids.len);
    try exec_testing.expectEqualStrings("Beta", env.titles[0]); // newest first
    try exec_testing.expect(std.mem.indexOf(u8, env.excerpts[0], "second body") != null);
}

test "execSearchDocuments: a regex query reaches title OR body" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "Release plan v2", "# plan\n\n- ship 095\n");
    try seedAnon(alloc, &ctx.db, "Meeting notes", "We agreed to LAUNCH in October.\n");

    // Title hit only.
    var by_title = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"release\"}");
    defer by_title.deinit();
    try exec_testing.expectEqual(@as(usize, 1), by_title.total);
    try exec_testing.expectEqualStrings("Release plan v2", by_title.titles[0]);
    try exec_testing.expectEqualStrings("regex", by_title.pattern_mode);

    // Body hit, different case on both sides.
    var by_body = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"LAUNCH\"}");
    defer by_body.deinit();
    try exec_testing.expectEqual(@as(usize, 1), by_body.total);
    try exec_testing.expectEqualStrings("Meeting notes", by_body.titles[0]);
    // The excerpt is centred on the hit, so the body text is visible.
    try exec_testing.expect(std.mem.indexOf(u8, by_body.excerpts[0], "LAUNCH") != null);

    // One alternation reaches both.
    var alt = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"release|launch\"}");
    defer alt.deinit();
    try exec_testing.expectEqual(@as(usize, 2), alt.total);
}

test "execSearchDocuments: a metacharacter query is NOT narrowed by the SQL prefilter" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // `release.` as a regex is "release" + any one character, so "releaseX"
    // matches while the literal substring "release." does not occur.
    try seedAnon(alloc, &ctx.db, "Zebra", "releaseX the thing\n");

    var env = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"release.\"}");
    defer env.deinit();

    try exec_testing.expectEqual(@as(usize, 1), env.total);
    try exec_testing.expectEqualStrings("Zebra", env.titles[0]);

    // And the same query with literal:true genuinely matches nothing — the
    // flag, not the prefilter, is what makes the two answers differ.
    var lit = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"release.\",\"literal\":true}");
    defer lit.deinit();
    try exec_testing.expectEqualStrings("literal", lit.pattern_mode);
    try exec_testing.expectEqual(@as(usize, 0), lit.total);
}

test "execSearchDocuments: an anchored query still matches, so ^ is not prefiltered either" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "Q3 plan", "later");
    try seedAnon(alloc, &ctx.db, "Backlog Q3 items", "earlier");

    var env = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"^Q3\"}");
    defer env.deinit();
    try exec_testing.expectEqual(@as(usize, 1), env.total);
    try exec_testing.expectEqualStrings("Q3 plan", env.titles[0]);
}

test "execSearchDocuments: a LIKE prefilter needle containing % or _ is matched verbatim" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // SQLite's LIKE would treat `%` as "any run" and `_` as "any char".
    try seedAnon(alloc, &ctx.db, "Percent test", "100%% done\n");
    try seedAnon(alloc, &ctx.db, "Underscore test", "snake_case naming\n");
    try seedAnon(alloc, &ctx.db, "Decoy", "nothing special\n");

    var pct = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"%\",\"literal\":true}");
    defer pct.deinit();
    try exec_testing.expectEqual(@as(usize, 1), pct.total);
    try exec_testing.expectEqualStrings("Percent test", pct.titles[0]);

    var us = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"_\",\"literal\":true}");
    defer us.deinit();
    try exec_testing.expectEqual(@as(usize, 1), us.total);
    try exec_testing.expectEqualStrings("Underscore test", us.titles[0]);
}

test "execSearchDocuments: an invalid pattern is a warning, not a failed tool call" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "Notes", "release checklist\n");

    var env = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"releas(\"}");
    defer env.deinit();

    // success=true: the search RAN. It just ran in fallback mode, and said
    // so. Reporting this as an error would teach the model to give up on a
    // query that had an obvious literal reading.
    try exec_testing.expect(env.success);
    try exec_testing.expectEqualStrings("literal_fallback", env.pattern_mode);
    try exec_testing.expect(env.pattern_warning != null);
    try exec_testing.expect(std.mem.indexOf(u8, env.pattern_warning.?, "literal:true") != null);
}

test "execSearchDocuments: include_content is opt-in and off by default" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "Plan", "the FULLBODY marker text\n");

    var without = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"FULLBODY\"}");
    defer without.deinit();
    try exec_testing.expectEqual(@as(usize, 1), without.total);
    try exec_testing.expect(without.contents[0] == null);
    try exec_testing.expect(std.mem.indexOf(u8, without.raw, "\"content\":\"the FULLBODY") == null);
    // The excerpt still shows the hit.
    try exec_testing.expect(std.mem.indexOf(u8, without.excerpts[0], "FULLBODY") != null);

    var with = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"FULLBODY\",\"include_content\":true}");
    defer with.deinit();
    try exec_testing.expectEqualStrings("the FULLBODY marker text\n", with.contents[0].?);
    try exec_testing.expectEqual(@as(usize, 25), with.content_lengths[0]);
}

test "execSearchDocuments: paging reports total, truncated, next_offset and the offset in the hint" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    for ([_][]const u8{ "D1", "D2", "D3", "D4", "D5" }) |t| {
        try seedAnon(alloc, &ctx.db, t, "shared body");
    }

    var page1 = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"shared\",\"limit\":2}");
    defer page1.deinit();
    try exec_testing.expectEqual(@as(usize, 5), page1.total);
    try exec_testing.expectEqual(@as(usize, 2), page1.count);
    try exec_testing.expect(page1.truncated);
    try exec_testing.expectEqual(@as(usize, 2), page1.next_offset.?);
    try exec_testing.expect(std.mem.indexOf(u8, page1.hint, "offset=2") != null);

    var page2 = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"shared\",\"limit\":2,\"offset\":2}");
    defer page2.deinit();
    try exec_testing.expectEqual(@as(usize, 2), page2.count);
    // next_offset is offset + count, i.e. where page 3 STARTS — not the
    // offset page 2 started at.
    try exec_testing.expectEqual(@as(usize, 4), page2.next_offset.?);
    // Page 2 must not repeat page 1's rows.
    for (page1.ids) |id| {
        for (page2.ids) |id2| try exec_testing.expect(!std.mem.eql(u8, id, id2));
    }

    var last = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"shared\",\"limit\":2,\"offset\":4}");
    defer last.deinit();
    try exec_testing.expectEqual(@as(usize, 1), last.count);
    try exec_testing.expect(!last.truncated);
    try exec_testing.expect(last.next_offset == null);
    try exec_testing.expect(std.mem.indexOf(u8, last.hint, "edit_document") != null);
}

test "execSearchDocuments: an offset past the end is an empty page, not an error" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "Only one", "body");

    var env = try runSearch(alloc, &ctx.db, "s1", "{\"offset\":500}");
    defer env.deinit();
    try exec_testing.expect(env.success);
    try exec_testing.expectEqual(@as(usize, 0), env.count);
    try exec_testing.expectEqual(@as(usize, 1), env.total);
}

test "execSearchDocuments: out-of-range paging is rejected, never silently clamped" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var zero = try runSearch(alloc, &ctx.db, "s1", "{\"limit\":0}");
    defer zero.deinit();
    try exec_testing.expect(!zero.success);
    try exec_testing.expect(std.mem.indexOf(u8, zero.err.?, "at least 1") != null);

    var huge = try runSearch(alloc, &ctx.db, "s1", "{\"limit\":100000}");
    defer huge.deinit();
    try exec_testing.expect(!huge.success);
    try exec_testing.expect(std.mem.indexOf(u8, huge.err.?, "at most 100") != null);

    var negative = try runSearch(alloc, &ctx.db, "s1", "{\"offset\":-1}");
    defer negative.deinit();
    try exec_testing.expect(!negative.success);
    try exec_testing.expect(std.mem.indexOf(u8, negative.err.?, "negative") != null);
}

test "execSearchDocuments: malformed JSON arguments become a parse failure, not a crash" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var env = try runSearch(alloc, &ctx.db, "s1", "{not json");
    defer env.deinit();
    try exec_testing.expect(!env.success);
    // `search_documents` keeps its own hand-written schema hint (it names
    // every field and its type, which the generic message cannot).
    try exec_testing.expect(std.mem.indexOf(u8, env.err.?, "expected") != null);
    try exec_testing.expect(std.mem.indexOf(u8, env.err.?, "query") != null);
    try exec_testing.expect(std.mem.indexOf(u8, env.err.?, "SyntaxError") == null);
}

test "execSearchDocuments: a workspace never sees another workspace's documents" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "WS1 secret", "sharedword in ws_1\n");

    const args = try std.json.Stringify.valueAlloc(alloc, .{ .title = "WS2 note", .content = "sharedword in ws_2" }, .{});
    defer alloc.free(args);
    const create = try execAddDocument(makeTestCtx(alloc, &ctx.db, "s2"), fakeToolCall("add_document", args));
    defer alloc.free(create.output);
    var created = try parseEnvelope(alloc, create.output);
    defer created.deinit();
    try exec_testing.expectEqualStrings("ws_2", created.workspace_id);

    // The shared query matches exactly one row per workspace, and each
    // search returns only its own — no ids, no titles, no excerpts leaking.
    var mine = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"sharedword\"}");
    defer mine.deinit();
    try exec_testing.expectEqual(@as(usize, 1), mine.total);
    try exec_testing.expectEqualStrings("WS1 secret", mine.titles[0]);
    try exec_testing.expect(std.mem.indexOf(u8, mine.raw, "WS2 note") == null);
    try exec_testing.expect(std.mem.indexOf(u8, mine.raw, created.id) == null);
    try exec_testing.expect(std.mem.indexOf(u8, mine.raw, "ws_2") == null);

    var theirs = try runSearch(alloc, &ctx.db, "s2", "{\"query\":\"sharedword\"}");
    defer theirs.deinit();
    try exec_testing.expectEqual(@as(usize, 1), theirs.total);
    try exec_testing.expectEqualStrings("WS2 note", theirs.titles[0]);
    try exec_testing.expect(std.mem.indexOf(u8, theirs.raw, "WS1 secret") == null);
}

test "execSearchDocuments: an unresolvable session is a refusal, NOT an empty result set" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // "no documents matched" and "you have no workspace" are different facts
    // and the model has to be able to tell them apart — a silent empty
    // page would read as "your notes are gone".
    var orphan = try runSearch(alloc, &ctx.db, "s_orphan", "{}");
    defer orphan.deinit();
    try exec_testing.expect(!orphan.success);
    try exec_testing.expect(orphan.err != null);
    try exec_testing.expect(std.mem.indexOf(u8, orphan.err.?, "workspace") != null);

    var empty = try runSearch(alloc, &ctx.db, "s1", "{}");
    defer empty.deinit();
    try exec_testing.expect(empty.success);
    try exec_testing.expectEqual(@as(usize, 0), empty.total);
    try exec_testing.expectEqualStrings("all", empty.pattern_mode);
}

test "execSearchDocuments: a hallucinated workspace_id is ignored, not honoured" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "Mine", "findme\n");

    var env = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"findme\",\"workspace_id\":\"ws_2\"}");
    defer env.deinit();
    try exec_testing.expect(env.success);
    try exec_testing.expectEqual(@as(usize, 1), env.total);
    try exec_testing.expectEqualStrings("Mine", env.titles[0]);
}

test "execSearchDocuments: an empty document body is searchable by title, not by content" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedAnon(alloc, &ctx.db, "Stub", "");

    var by_title = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"Stub\"}");
    defer by_title.deinit();
    try exec_testing.expectEqual(@as(usize, 1), by_title.total);
    try exec_testing.expectEqual(@as(usize, 0), by_title.content_lengths[0]);
    // An empty body yields an empty excerpt, not a crash and not the title
    // silently standing in for it.
    try exec_testing.expectEqualStrings("Stub", by_title.excerpts[0]);

    var none = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"hippopotamus\"}");
    defer none.deinit();
    try exec_testing.expectEqual(@as(usize, 0), none.total);
}

test "execSearchDocuments: a body hit in a large document yields a bounded excerpt" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
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
    try exec_testing.expectEqual(@as(usize, 1), env.total);
    try exec_testing.expectEqual(@as(usize, 8192 * 2 + 6), env.content_lengths[0]);
    try exec_testing.expect(std.mem.indexOf(u8, env.excerpts[0], "NEEDLE") != null);
    try exec_testing.expect(env.excerpts[0].len <= documents_search.EXCERPT_MAX_BYTES + 8);
}

test "execSearchDocuments: a multi-byte body still produces valid JSON" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The excerpt window can land mid-codepoint. A split produces an invalid
    // UTF-8 sequence, which surfaces as a stringify failure — i.e. the whole
    // search tool call errors for a query that found a real match.
    const body = "日本語のテキスト" ** 400;
    try seedAnon(alloc, &ctx.db, "Ünïcödé", body);

    var env = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"テキスト\"}");
    defer env.deinit();
    try exec_testing.expect(env.success);
    try exec_testing.expectEqual(@as(usize, 1), env.total);
    try exec_testing.expect(std.unicode.utf8ValidateSlice(env.excerpts[0]));
    try exec_testing.expect(std.mem.indexOf(u8, env.excerpts[0], "テキスト") != null);
}

test "execSearchDocuments: deleting what a search returned makes the next search stop finding it" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try exec_seedDoc(alloc, &ctx.db, "Ephemeral", "findme marker\n");
    defer alloc.free(id);
    try seedAnon(alloc, &ctx.db, "Keep", "unrelated\n");

    var before = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"findme\"}");
    defer before.deinit();
    try exec_testing.expectEqual(@as(usize, 1), before.total);

    // The round trip the tool is actually for: search → take the id → delete.
    const args = try std.fmt.allocPrint(alloc, "{{\"document_id\":\"{s}\"}}", .{before.ids[0]});
    defer alloc.free(args);
    const del = try execDeleteDocument(makeTestCtx(alloc, &ctx.db, "s1"), fakeToolCall("delete_document", args));
    defer alloc.free(del.output);
    var env = try parseEnvelope(alloc, del.output);
    defer env.deinit();
    try exec_testing.expect(env.success);
    try exec_testing.expectEqualStrings(id, env.id);

    var after = try runSearch(alloc, &ctx.db, "s1", "{\"query\":\"findme\"}");
    defer after.deinit();
    try exec_testing.expect(after.success);
    try exec_testing.expectEqual(@as(usize, 0), after.total);
}

// ─── Registration + default seeding ───────────────────────────────────────

/// Is `name` among the rows `seedDefaultAgentTools` wrote for `agent_id`?
fn seededFor(db: *exec_sqlite.SqliteBackend, agent_id: []const u8, name: []const u8) !bool {
    const alloc = exec_testing.allocator;
    var q = try db.query(alloc, "SELECT tool_name FROM agent_tools WHERE agent_id = ?", &.{agent_id});
    defer q.deinit();
    while ((q.next() catch null)) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], name)) return true;
    }
    return false;
}

test "document tools are offered to the model and resolve to dispatchable registry entries" {
    const tools_equipped = @import("../../../agentic_loop/tools_equipped.zig");
    const names = [_][]const u8{ "add_document", "edit_document", "delete_document", "search_documents" };

    // `equips()` is the list the workflow hands the LLM and
    // UNIFIED_TOOL_REGISTRY() is the dispatcher's table.
    const equip = tools_equipped.equips(exec_testing.allocator);
    defer exec_testing.allocator.free(equip);

    for (names) |name| {
        var in_equips = false;
        for (equip) |t| {
            if (std.mem.eql(u8, t.function.name, name)) in_equips = true;
        }
        try exec_testing.expect(in_equips);

        // Exactly one dispatch entry, carrying the SAME tool def the model
        // was shown — a duplicate name would make the first match win and the
        // second unreachable.
        var entries: usize = 0;
        for (tools_equipped.UNIFIED_TOOL_REGISTRY()) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            entries += 1;
            try exec_testing.expectEqualStrings(name, entry.tool_def.function.name);
        }
        try exec_testing.expectEqual(@as(usize, 1), entries);
        try exec_testing.expect(tools_equipped.isDispatchableToolName(name));
    }
}

test "search_documents is seeded by default but delete_document is not" {
    const tools_equipped = @import("../../../agentic_loop/tools_equipped.zig");

    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The creation-time seed writes `agent_tools`, which `exec_setupDb` does not
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
    try exec_testing.expect(try seededFor(&ctx.db, "ag_doc_seed", "add_document"));
    try exec_testing.expect(try seededFor(&ctx.db, "ag_doc_seed", "edit_document"));
    try exec_testing.expect(try seededFor(&ctx.db, "ag_doc_seed", "search_documents"));

    // Irreversible, so handing every new agent a delete of the user's
    // documents is a separate decision that must be made out loud.
    try exec_testing.expect(!try seededFor(&ctx.db, "ag_doc_seed", "delete_document"));

    // …and it stays reachable: registered means the Settings → Tools
    // checklist lists it and `search_tool` → `use_tool` can equip it for a
    // session. Registered is not the same as handed-out.
    try exec_testing.expect(tools_equipped.isDispatchableToolName("delete_document"));
    const equip = tools_equipped.equips(alloc);
    defer alloc.free(equip);
    var delete_in_equips = false;
    for (equip) |t| {
        if (std.mem.eql(u8, t.function.name, "delete_document")) delete_in_equips = true;
    }
    try exec_testing.expect(delete_in_equips);
}

// ─── documents SSE channel ───────────────────────────────────────────────
// The exec wrapper is the only layer that knows a tool call SUCCEEDED: every failure path above
// returned before it, so the emit lives here and not in the executor.

const sse_event_mod = @import("../../../agentic_loop/sse.zig");
const sse_bus_mod = exec_pabrikcore.event_bus;

var sse_captured: ?sse_event_mod.SseEvent = null;
var sse_payload: []u8 = &.{};

/// The emit frees the buffer it built, so `ev.data` would dangle — copy it
/// here, while the emit is still on the stack.
fn captureDocumentSse(ev: sse_event_mod.SseEvent) void {
    sse_captured = ev;
    sse_payload = exec_testing.allocator.dupe(u8, ev.data) catch return;
}

fn releaseDocumentSse() void {
    if (sse_payload.len > 0) exec_testing.allocator.free(sse_payload);
    sse_payload = &.{};
    sse_captured = null;
}

/// One JSON field out of the captured payload. The slice is copied out before
/// the parse arena dies.
fn capturedField(field: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, exec_testing.allocator, sse_payload, .{});
    defer parsed.deinit();
    return exec_testing.allocator.dupe(u8, parsed.value.object.get(field).?.string);
}

test "a successful add_document announces document_created with the new row" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var bus_threaded = std.Io.Threaded.init(alloc, .{});
    defer bus_threaded.deinit();
    var bus = sse_bus_mod.EventBus.init("documents_test", alloc, bus_threaded.io());
    defer bus.deinit();
    releaseDocumentSse();
    try bus.subscribe(sse_event_mod.SseEvent, document_events.RoutingKey, captureDocumentSse);

    var tc_ctx = makeTestCtx(alloc, &ctx.db, "s1");
    tc_ctx.event_bus = &bus;
    const result = try execAddDocument(tc_ctx, fakeToolCall("add_document", "{\"title\":\"Notes\",\"content\":\"# hi\"}"));
    defer alloc.free(result.output);

    try exec_testing.expect(sse_captured != null);
    try exec_testing.expectEqualStrings(document_events.EventCreated, sse_captured.?.event_type orelse "");

    const action = try capturedField("action");
    defer alloc.free(action);
    const workspace_id = try capturedField("workspace_id");
    defer alloc.free(workspace_id);
    const title = try capturedField("title");
    defer alloc.free(title);
    const document_id = try capturedField("document_id");
    defer alloc.free(document_id);

    try exec_testing.expectEqualStrings("created", action);
    try exec_testing.expectEqualStrings("ws_1", workspace_id);
    try exec_testing.expectEqualStrings("Notes", title);
    try exec_testing.expect(document_id.len > 0);

    releaseDocumentSse();
}

test "a successful edit_document announces document_updated with the new title" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var bus_threaded = std.Io.Threaded.init(alloc, .{});
    defer bus_threaded.deinit();
    var bus = sse_bus_mod.EventBus.init("documents_test", alloc, bus_threaded.io());
    defer bus.deinit();

    var tc_ctx = makeTestCtx(alloc, &ctx.db, "s1");
    tc_ctx.event_bus = &bus;

    const created = try execAddDocument(tc_ctx, fakeToolCall("add_document", "{\"title\":\"Draft\"}"));
    defer alloc.free(created.output);
    var created_env = try parseEnvelope(alloc, created.output);
    defer created_env.deinit();

    releaseDocumentSse();
    try bus.subscribe(sse_event_mod.SseEvent, document_events.RoutingKey, captureDocumentSse);

    const args = try std.fmt.allocPrint(alloc, "{{\"document_id\":\"{s}\",\"title\":\"Renamed\"}}", .{created_env.id});
    defer alloc.free(args);
    const edited = try execEditDocument(tc_ctx, fakeToolCall("edit_document", args));
    defer alloc.free(edited.output);
    var edited_env = try parseEnvelope(alloc, edited.output);
    defer edited_env.deinit();
    try exec_testing.expect(edited_env.success);

    try exec_testing.expect(sse_captured != null);
    try exec_testing.expectEqualStrings(document_events.EventUpdated, sse_captured.?.event_type orelse "");

    const action = try capturedField("action");
    defer alloc.free(action);
    const title = try capturedField("title");
    defer alloc.free(title);
    const document_id = try capturedField("document_id");
    defer alloc.free(document_id);

    try exec_testing.expectEqualStrings("updated", action);
    try exec_testing.expectEqualStrings("Renamed", title);
    try exec_testing.expectEqualStrings(created_env.id, document_id);

    releaseDocumentSse();
}

test "a successful delete_document announces document_deleted for the removed id" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var bus_threaded = std.Io.Threaded.init(alloc, .{});
    defer bus_threaded.deinit();
    var bus = sse_bus_mod.EventBus.init("documents_test", alloc, bus_threaded.io());
    defer bus.deinit();

    var tc_ctx = makeTestCtx(alloc, &ctx.db, "s1");
    tc_ctx.event_bus = &bus;

    const created = try execAddDocument(tc_ctx, fakeToolCall("add_document", "{\"title\":\"Doomed\"}"));
    defer alloc.free(created.output);
    var created_env = try parseEnvelope(alloc, created.output);
    defer created_env.deinit();

    releaseDocumentSse();
    try bus.subscribe(sse_event_mod.SseEvent, document_events.RoutingKey, captureDocumentSse);

    const args = try std.fmt.allocPrint(alloc, "{{\"document_id\":\"{s}\"}}", .{created_env.id});
    defer alloc.free(args);
    const removed = try execDeleteDocument(tc_ctx, fakeToolCall("delete_document", args));
    defer alloc.free(removed.output);
    var removed_env = try parseEnvelope(alloc, removed.output);
    defer removed_env.deinit();
    try exec_testing.expect(removed_env.success);

    try exec_testing.expect(sse_captured != null);
    try exec_testing.expectEqualStrings(document_events.EventDeleted, sse_captured.?.event_type orelse "");

    const action = try capturedField("action");
    defer alloc.free(action);
    const document_id = try capturedField("document_id");
    defer alloc.free(document_id);
    const title = try capturedField("title");
    defer alloc.free(title);
    const workspace_id = try capturedField("workspace_id");
    defer alloc.free(workspace_id);

    try exec_testing.expectEqualStrings("deleted", action);
    try exec_testing.expectEqualStrings(created_env.id, document_id);
    try exec_testing.expectEqualStrings("Doomed", title);
    try exec_testing.expectEqualStrings("ws_1", workspace_id);

    releaseDocumentSse();
}

test "a refused document mutation announces nothing" {
    const alloc = exec_testing.allocator;
    var ctx = try exec_setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var bus_threaded = std.Io.Threaded.init(alloc, .{});
    defer bus_threaded.deinit();
    var bus = sse_bus_mod.EventBus.init("documents_test", alloc, bus_threaded.io());
    defer bus.deinit();
    releaseDocumentSse();
    try bus.subscribe(sse_event_mod.SseEvent, document_events.RoutingKey, captureDocumentSse);

    var tc_ctx = makeTestCtx(alloc, &ctx.db, "s1");
    tc_ctx.event_bus = &bus;

    // A blank title is refused by the store, so nothing may be announced — a listener acting on
    // `action: "created"` would invent a document that was never written.
    const blank = try execAddDocument(tc_ctx, fakeToolCall("add_document", "{\"title\":\"   \"}"));
    defer alloc.free(blank.output);
    try exec_testing.expect(sse_captured == null);

    // An id that is not in this workspace reaches neither the update nor the
    // delete, so neither may be announced.
    const edit_miss = try execEditDocument(tc_ctx, fakeToolCall("edit_document", "{\"document_id\":\"doc_missing\",\"title\":\"Renamed\"}"));
    defer alloc.free(edit_miss.output);
    try exec_testing.expect(sse_captured == null);

    const delete_miss = try execDeleteDocument(tc_ctx, fakeToolCall("delete_document", "{\"document_id\":\"doc_missing\"}"));
    defer alloc.free(delete_miss.output);
    try exec_testing.expect(sse_captured == null);

    releaseDocumentSse();
}


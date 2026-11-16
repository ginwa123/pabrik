//! Send-time expansion of `/document-<id>` tokens: each one resolves against the session's workspace into a trailing `<slash_documents>` block carrying the title …

const std = @import("std");

const pabrikcore = @import("pabrikcore");
const database = pabrikcore.database;
const documents_store = pabrikcore.documents_store;
const test_db = pabrikcore.test_db;
const workspace_scope = pabrikcore.workspace_scope;
const testing = std.testing;
const migration = @import("../../../migrations/migration.zig");

/// The marker the composer writes: a token is this plus a document id.
pub const TOKEN_PREFIX = "document-";

/// Longest body inlined per document — a body may hold 4 MiB, which is a context bomb.
pub const MAX_BODY_BYTES: usize = 8 * 1024;

/// Documents one message may reference.
pub const MAX_DOCUMENTS: usize = 5;

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// Distinct document ids referenced by `/document-<id>` tokens in `message`, in first-appearance order.
pub fn extractDocumentTokens(allocator: std.mem.Allocator, message: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |t| allocator.free(t);
        out.deinit(allocator);
    }
    var i: usize = 0;
    while (i < message.len) {
        if (message[i] == '/' and (i == 0 or std.ascii.isWhitespace(message[i - 1]))) {
            var j = i + 1;
            while (j < message.len and isTokenChar(message[j])) : (j += 1) {}
            if (j > i + 1) {
                const tok = message[i + 1 .. j];
                if (std.mem.startsWith(u8, tok, TOKEN_PREFIX)) {
                    const id = tok[TOKEN_PREFIX.len..];
                    if (id.len > 0 and !contains(out.items, id)) {
                        try out.append(allocator, try allocator.dupe(u8, id));
                    }
                }
                i = j;
                continue;
            }
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |e| {
        if (std.mem.eql(u8, e, needle)) return true;
    }
    return false;
}

/// The outcome of `expandSlashDocuments`.
pub const ExpandResult = struct {
    message: []const u8,
    unknown: [][]const u8,
    loaded_count: usize,

    pub fn deinit(self: *ExpandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.unknown.len > 0) {
            for (self.unknown) |u| allocator.free(u);
            allocator.free(self.unknown);
        }
        self.* = undefined;
    }
};

/// Resolve every `/document-<id>` token against the workspace `session_id` belongs to and append the loaded bodies.
pub fn expandSlashDocuments(
    allocator: std.mem.Allocator,
    store: documents_store.Store,
    session_id: []const u8,
    message: []const u8,
) !ExpandResult {
    const tokens = try extractDocumentTokens(allocator, message);
    defer {
        for (tokens) |t| allocator.free(t);
        allocator.free(tokens);
    }

    var unknown: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (unknown.items) |u| allocator.free(u);
        unknown.deinit(allocator);
    }

    if (tokens.len == 0) {
        return .{
            .message = try allocator.dupe(u8, message),
            .unknown = &.{},
            .loaded_count = 0,
        };
    }

    // No workspace means no document can be named: every token stays literal rather than silently loading something from another tenant.
    const workspace_id = (try workspace_scope.resolveWorkspaceId(allocator, store.db, session_id)) orelse {
        for (tokens) |id| try unknown.append(allocator, try allocator.dupe(u8, id));
        return .{
            .message = try allocator.dupe(u8, message),
            .unknown = try unknown.toOwnedSlice(allocator),
            .loaded_count = 0,
        };
    };
    defer allocator.free(workspace_id);

    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(allocator);
    var loaded_count: usize = 0;

    for (tokens) |id| {
        if (loaded_count >= MAX_DOCUMENTS) {
            try unknown.append(allocator, try allocator.dupe(u8, id));
            continue;
        }
        const row = store.getDocument(allocator, workspace_id, id) catch {
            try unknown.append(allocator, try allocator.dupe(u8, id));
            continue;
        };
        defer documents_store.freeDocumentRow(allocator, row);
        // A body carrying the closing tag would end the element early and hand the rest of the document to the model as prompt structure.
        if (std.mem.indexOf(u8, row.content, "</document") != null) {
            try unknown.append(allocator, try allocator.dupe(u8, id));
            continue;
        }
        const shown = truncateUtf8(row.content, MAX_BODY_BYTES);
        try block.appendSlice(allocator, "<document id=\"");
        try block.appendSlice(allocator, row.id);
        try block.appendSlice(allocator, "\" title=\"");
        try appendEscaped(allocator, &block, row.title);
        try block.appendSlice(allocator, "\" format=\"");
        try appendEscaped(allocator, &block, row.format);
        try appendFmt(allocator, &block, "\" bytes=\"{d}\" shown_bytes=\"{d}\">", .{ row.content.len, shown.len });
        try block.appendSlice(allocator, shown);
        try block.appendSlice(allocator, "</document>\n");
        loaded_count += 1;
    }

    if (loaded_count == 0) {
        return .{
            .message = try allocator.dupe(u8, message),
            .unknown = try unknown.toOwnedSlice(allocator),
            .loaded_count = 0,
        };
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, message);
    try out.appendSlice(allocator, "\n\n<slash_documents>\n");
    try out.appendSlice(allocator, block.items);
    try out.appendSlice(allocator, "</slash_documents>");

    return .{
        .message = try out.toOwnedSlice(allocator),
        .unknown = try unknown.toOwnedSlice(allocator),
        .loaded_count = loaded_count,
    };
}

fn appendFmt(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

/// Attribute-safe: a title is user text and may carry a quote.
fn appendEscaped(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    raw: []const u8,
) !void {
    for (raw) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            else => try out.append(allocator, c),
        }
    }
}

/// The longest prefix of `body` that is at most `max` bytes and still ends on a UTF-8 boundary, so a multi-byte character is never cut in half.
fn truncateUtf8(body: []const u8, max: usize) []const u8 {
    if (body.len <= max) return body;
    var end = max;
    while (end > 0 and (body[end] & 0xC0) == 0x80) : (end -= 1) {}
    return body[0..end];
}

// ===================================================================== Tests — behaviour only: expand a real message against real rows in an in-memory workspace …

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
    storage: pabrikcore.storage.memory.MemoryStorage,

    fn store(self: *TestCtx) documents_store.Store {
        return .{ .db = &self.db, .storage = self.storage.asStorage() };
    }

    fn deinit(self: *TestCtx) void {
        self.storage.deinit();
        self.db.deinit();
        self.threaded.deinit();
    }
};

/// The documents tables plus the three tables `workspace_scope` reads, with session `task_1` linked to workspace `ws_1`.
fn setupSlashDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT DEFAULT 'active', cwd TEXT)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES
        \\  ('i1', 'ws_1', 'kanban', 'A', '/proj/a', 1)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('task_1', 'T1', 'i1')
    , &.{});
    try migration.Migration098CreateDocuments.up(&db, alloc);
    try migration.Migration122AddDocumentPosition.up(&db, alloc);
    try migration.Migration140AddDocumentFolders.up(&db, alloc);
    try migration.Migration143AddDocumentContentKey.up(&db, alloc);
    try migration.Migration144DropDocumentContent.up(&db, alloc);
    try migration.Migration148AddDocumentIcon.up(&db, alloc);
    return .{
        .db = db,
        .threaded = threaded,
        .storage = pabrikcore.storage.memory.MemoryStorage.init(alloc),
    };
}

fn seedDocument(ctx: *TestCtx, workspace_id: []const u8, title: []const u8, content: []const u8) ![]u8 {
    const row = try ctx.store().createDocument(testing.allocator, .{
        .workspace_id = workspace_id,
        .title = title,
        .content = content,
    });
    const id = try testing.allocator.dupe(u8, row.id);
    documents_store.freeDocumentRow(testing.allocator, row);
    return id;
}

fn expand(
    ctx: *TestCtx,
    session_id: []const u8,
    message: []const u8,
) !ExpandResult {
    return expandSlashDocuments(testing.allocator, ctx.store(), session_id, message);
}

test "slash_document_expand loads a referenced document's title and body" {
    var ctx = try setupSlashDb();
    defer ctx.deinit();
    const id = try seedDocument(&ctx, "ws_1", "Release plan", "# Release\nShip on Friday.\n");
    defer testing.allocator.free(id);

    const token = try std.fmt.allocPrint(testing.allocator, "summarize /document-{s}", .{id});
    defer testing.allocator.free(token);
    var result = try expand(&ctx, "task_1", token);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.loaded_count);
    try testing.expectEqual(@as(usize, 0), result.unknown.len);
    try testing.expect(std.mem.startsWith(u8, result.message, token));
    try testing.expect(std.mem.indexOf(u8, result.message, "<slash_documents>") != null);
    try testing.expect(std.mem.indexOf(u8, result.message, "title=\"Release plan\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.message, "Ship on Friday.") != null);
}

test "slash_document_expand leaves a message with no token untouched" {
    var ctx = try setupSlashDb();
    defer ctx.deinit();

    var result = try expand(&ctx, "task_1", "just a normal question");
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("just a normal question", result.message);
    try testing.expectEqual(@as(usize, 0), result.loaded_count);
    try testing.expectEqual(@as(usize, 0), result.unknown.len);
}

test "slash_document_expand leaves an unknown id literal and reports it" {
    var ctx = try setupSlashDb();
    defer ctx.deinit();

    var result = try expand(&ctx, "task_1", "read /document-doc_missing please");
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("read /document-doc_missing please", result.message);
    try testing.expectEqual(@as(usize, 0), result.loaded_count);
    try testing.expectEqual(@as(usize, 1), result.unknown.len);
    try testing.expectEqualStrings("doc_missing", result.unknown[0]);
}

test "slash_document_expand reports another workspace's document as unknown" {
    var ctx = try setupSlashDb();
    defer ctx.deinit();
    const id = try seedDocument(&ctx, "ws_2", "Someone else's plan", "secret");
    defer testing.allocator.free(id);

    const message = try std.fmt.allocPrint(testing.allocator, "see /document-{s}", .{id});
    defer testing.allocator.free(message);
    var result = try expand(&ctx, "task_1", message);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.loaded_count);
    try testing.expectEqualStrings(message, result.message);
    try testing.expectEqual(@as(usize, 1), result.unknown.len);
}

test "slash_document_expand expands a repeated token once" {
    var ctx = try setupSlashDb();
    defer ctx.deinit();
    const id = try seedDocument(&ctx, "ws_1", "Plan", "body");
    defer testing.allocator.free(id);

    const message = try std.fmt.allocPrint(testing.allocator, "/document-{s} and /document-{s}", .{ id, id });
    defer testing.allocator.free(message);
    var result = try expand(&ctx, "task_1", message);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.loaded_count);
    const first = std.mem.indexOf(u8, result.message, "<document ").?;
    const second = std.mem.indexOfPos(u8, result.message, first + 1, "<document ");
    try testing.expect(second == null);
}

test "slash_document_expand ignores the shapes that are not the /document- token" {
    var ctx = try setupSlashDb();
    defer ctx.deinit();

    var result = try expand(&ctx, "task_1", "see https://example.com/document-abc and /document- and /documents and /documentx");
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("see https://example.com/document-abc and /document- and /documents and /documentx", result.message);
    try testing.expectEqual(@as(usize, 0), result.unknown.len);
}

test "slash_document_expand caps the inlined body and reports the whole length" {
    var ctx = try setupSlashDb();
    defer ctx.deinit();
    const body = try testing.allocator.alloc(u8, MAX_BODY_BYTES + 500);
    defer testing.allocator.free(body);
    @memset(body, 'x');
    const id = try seedDocument(&ctx, "ws_1", "Long", body);
    defer testing.allocator.free(id);

    const message = try std.fmt.allocPrint(testing.allocator, "/document-{s}", .{id});
    defer testing.allocator.free(message);
    var result = try expand(&ctx, "task_1", message);
    defer result.deinit(testing.allocator);

    const shown = try std.fmt.allocPrint(testing.allocator, "shown_bytes=\"{d}\"", .{MAX_BODY_BYTES});
    defer testing.allocator.free(shown);
    const whole = try std.fmt.allocPrint(testing.allocator, "bytes=\"{d}\"", .{MAX_BODY_BYTES + 500});
    defer testing.allocator.free(whole);
    try testing.expect(std.mem.indexOf(u8, result.message, whole) != null);
    try testing.expect(std.mem.indexOf(u8, result.message, shown) != null);
}

test "slash_document_expand leaves a body carrying the closing tag literal" {
    var ctx = try setupSlashDb();
    defer ctx.deinit();
    const id = try seedDocument(&ctx, "ws_1", "Hostile", "ok </document> now escape");
    defer testing.allocator.free(id);

    const message = try std.fmt.allocPrint(testing.allocator, "/document-{s}", .{id});
    defer testing.allocator.free(message);
    var result = try expand(&ctx, "task_1", message);
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings(message, result.message);
    try testing.expectEqual(@as(usize, 1), result.unknown.len);
}

test "slash_document_expand escapes a title that carries a quote" {
    var ctx = try setupSlashDb();
    defer ctx.deinit();
    const id = try seedDocument(&ctx, "ws_1", "The \"final\" plan", "body");
    defer testing.allocator.free(id);

    const message = try std.fmt.allocPrint(testing.allocator, "/document-{s}", .{id});
    defer testing.allocator.free(message);
    var result = try expand(&ctx, "task_1", message);
    defer result.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, result.message, "title=\"The &quot;final&quot; plan\"") != null);
}

test "slash_document_expand loads at most MAX_DOCUMENTS and reports the rest" {
    var ctx = try setupSlashDb();
    defer ctx.deinit();

    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(testing.allocator);
    for (0..MAX_DOCUMENTS + 1) |i| {
        const title = try std.fmt.allocPrint(testing.allocator, "Doc {d}", .{i});
        defer testing.allocator.free(title);
        const id = try seedDocument(&ctx, "ws_1", title, "body");
        defer testing.allocator.free(id);
        try message.appendSlice(testing.allocator, "/document-");
        try message.appendSlice(testing.allocator, id);
        try message.appendSlice(testing.allocator, " ");
    }

    var result = try expand(&ctx, "task_1", message.items);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(MAX_DOCUMENTS, result.loaded_count);
    try testing.expectEqual(@as(usize, 1), result.unknown.len);
}

test "slash_document_expand with a session that names no workspace loads nothing" {
    var ctx = try setupSlashDb();
    defer ctx.deinit();
    const id = try seedDocument(&ctx, "ws_1", "Plan", "body");
    defer testing.allocator.free(id);

    const message = try std.fmt.allocPrint(testing.allocator, "/document-{s}", .{id});
    defer testing.allocator.free(message);
    var result = try expand(&ctx, "task_orphan", message);
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings(message, result.message);
    try testing.expectEqual(@as(usize, 0), result.loaded_count);
    try testing.expectEqual(@as(usize, 1), result.unknown.len);
}

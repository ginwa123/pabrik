//! `PATCH /api/agents/:agent_id/knowledge/:knowledge_id`. Updates file_path
//! and/or label of an existing knowledge entry. Body: `{file_path?, label?}`
//! (both optional; at least one required).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const agent_db = @import("../models/agent.db.zig");

/// HTTP request body. Decoupled from the domain `KnowledgeUpdateInput`
/// so the wire format can evolve independently (e.g. adding `?`
/// optional fields) without touching the use-case.
const UpdateKnowledgeBody = struct {
    file_path: ?[]const u8 = null,
    label: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

/// Subset of the knowledge row returned by the use-case.
pub const Knowledge = agent_db.KnowledgeRow;

/// Domain-level error set for `useCase`.
pub const KnowledgeUpdateError = error{
    /// `agent_id` or `knowledge_id` path param was missing or empty.
    IdsRequired,
    /// Body had neither `file_path` nor `label` (nothing to update).
    NothingToUpdate,
    /// `file_path` provided but not absolute.
    NotAbsolutePath,
    /// `db.exec` failed on the UPDATE.
    UpdateFailed,
    /// Re-fetching the row after UPDATE failed.
    RefetchFailed,
    /// Refetched row vanished (should be impossible — surfaces as 404).
    RowNotFound,
    /// `allocator.alloc` failed while building the dynamic SQL.
    /// Unreachable under arena allocator but the type system requires
    /// the variant so `try` propagates a typed error.
    OutOfMemory,
};

/// Inputs to the knowledge-update use-case.
pub const KnowledgeUpdateInput = struct {
    agent_id: []const u8,
    knowledge_id: []const u8,
    file_path: ?[]const u8,
    label: ?[]const u8,
    /// Inline manual text. Providing it switches the row to
    /// content-backed; null leaves the column untouched.
    content: ?[]const u8 = null,
};

/// Output of the knowledge-update use-case. `knowledge` is owned by
/// the caller (lifetime = request arena).
pub const KnowledgeUpdateOutput = struct {
    knowledge: Knowledge,
};

// =====================================================================
// Use case
// =====================================================================

/// Update an existing knowledge row.
pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: KnowledgeUpdateInput,
) KnowledgeUpdateError!KnowledgeUpdateOutput {
    if (input.agent_id.len == 0 or input.knowledge_id.len == 0) {
        return error.IdsRequired;
    }
    if (input.file_path == null and input.label == null and input.content == null) {
        return error.NothingToUpdate;
    }
    if (input.file_path) |fp| {
        // Empty string = clear the column (mode switch to text-backed).
        // Only NON-empty paths must be absolute.
        if (fp.len > 0 and !std.fs.path.isAbsolute(fp)) return error.NotAbsolutePath;
    }

    const handle: agent_db.DbOrTx = .{ .db = db };

    // Patch the requested fields, then read the row back.
    const knowledge = (agent_db.updateKnowledge(
        allocator,
        handle,
        input.knowledge_id,
        input.agent_id,
        input.file_path,
        input.label,
        input.content,
    ) catch return error.UpdateFailed) orelse return error.RowNotFound;

    return .{ .knowledge = knowledge };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentKnowledgeUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";
    const knowledge_id = req.params.get("knowledge_id") orelse "";

    const parsed = std.json.parseFromSliceLeaky(UpdateKnowledgeBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .agent_id = agent_id,
        .knowledge_id = knowledge_id,
        .file_path = parsed.file_path,
        .label = parsed.label,
        .content = parsed.content,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.NothingToUpdate => 400,
            error.NotAbsolutePath => 400,
            error.UpdateFailed => 500,
            error.RefetchFailed => 500,
            error.RowNotFound => 404,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "agent_id and knowledge_id required",
            error.NothingToUpdate => "file_path or label required",
            error.NotAbsolutePath => "file_path must be absolute",
            error.UpdateFailed => "Failed to update knowledge",
            error.RefetchFailed => "Failed to read row",
            error.RowNotFound => "knowledge row not found",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, output.knowledge, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
// impl + tests in one file (project convention for Agent Mode). 5 behavioural
// tests cover the use-case: 1.

const sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;
const testing = std.testing;
const Migration116 = @import("../migrations/migration.zig").Migration116UnifyAgentConfigTables;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // See agent_knowledge_delete.zig for why we re-create
    // workspace_items with the full shape.
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration116.up(&db, testing.allocator);
    // mirror that, or the `content` column (Migration 079) is missing.

    // Seed: 1 agent + 1 knowledge row.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type, description) VALUES ('ws_item_1', 'ws_item_1', 'agent', '')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, position) VALUES ('know_1', 'ws_item_1', '/tmp/orig.md', 'Original', 0)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty agent_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{
            .agent_id = "",
            .knowledge_id = "know_1",
            .file_path = "/tmp/new.md",
            .label = null,
        }),
    );
}

test "useCase: empty knowledge_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .knowledge_id = "",
            .file_path = "/tmp/new.md",
            .label = null,
        }),
    );
}

test "useCase: neither file_path nor label returns NothingToUpdate" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NothingToUpdate,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .knowledge_id = "know_1",
            .file_path = null,
            .label = null,
        }),
    );
}

test "useCase: relative file_path returns NotAbsolutePath" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotAbsolutePath,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .knowledge_id = "know_1",
            .file_path = "relative/path.md",
            .label = null,
        }),
    );
}

test "useCase: happy path updates both file_path AND label" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .knowledge_id = "know_1",
        .file_path = "/tmp/new.md",
        .label = "New label",
    });
    defer agent_db.freeKnowledgeRow(alloc, output.knowledge);
    try testing.expectEqualStrings("know_1", output.knowledge.id);
    try testing.expectEqualStrings("/tmp/new.md", output.knowledge.file_path);
    try testing.expectEqualStrings("New label", output.knowledge.label);
}

test "useCase: label-only update keeps file_path" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .knowledge_id = "know_1",
        .file_path = null,
        .label = "Updated label only",
    });
    defer agent_db.freeKnowledgeRow(alloc, output.knowledge);
    try testing.expectEqualStrings("/tmp/orig.md", output.knowledge.file_path);
    try testing.expectEqualStrings("Updated label only", output.knowledge.label);
}

// ─── content (manual text) tests — plan 2026-08-21-agent-knowledge-manual-text ──

test "useCase: PATCH can set content on an existing row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .knowledge_id = "know_1",
        .file_path = null,
        .label = null,
        .content = "new inline text",
    });
    defer agent_db.freeKnowledgeRow(alloc, output.knowledge);
    // Content is set; file_path unchanged (row keeps its old path).
    try testing.expectEqualStrings("new inline text", output.knowledge.content);
    try testing.expectEqualStrings("/tmp/orig.md", output.knowledge.file_path);
}

// ─── Mode-switch tests (2026-08-22, PR #291 follow-up) ───────────────── The
// edit dialog's File↔Text mode switch sends BOTH source fields in one PATCH —
// the inactive one as "".

test "useCase: file_path='' clears path and sets content (file→text switch)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .knowledge_id = "know_1",
        // Exactly what the edit dialog sends for a text-mode save.
        .file_path = "",
        .label = "Switched",
        .content = "inline body after switch",
    });
    defer agent_db.freeKnowledgeRow(alloc, output.knowledge);
    // Regression: this used to 400 with "file_path must be absolute"
    // because isAbsolute("") is false.
    try testing.expectEqualStrings("", output.knowledge.file_path);
    try testing.expectEqualStrings("inline body after switch", output.knowledge.content);
    try testing.expectEqualStrings("Switched", output.knowledge.label);
}

test "useCase: content='' clears text and sets path (text→file switch)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .knowledge_id = "know_1",
        // Exactly what the edit dialog sends for a file-mode save.
        .file_path = "/tmp/switched.md",
        .label = "Switched to file",
        .content = "",
    });
    defer agent_db.freeKnowledgeRow(alloc, output.knowledge);
    // Regression: content="" used to 500 because Backend.exec
    // binds empty slices as SQL NULL → NOT NULL constraint fail.
    try testing.expectEqualStrings("", output.knowledge.content);
    try testing.expectEqualStrings("/tmp/switched.md", output.knowledge.file_path);
}

test "useCase: relative non-empty file_path still returns NotAbsolutePath" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotAbsolutePath,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .knowledge_id = "know_1",
            .file_path = "relative/path.md",
            .label = null,
        }),
    );
}

// ===== Tests merged from agent_knowledge_update_functional_test.zig
// (2026-09-11 flatten) ===== ISOLATED functional tests for the
// agent-knowledge UPDATE flow (PATCH

const update_mod = @This();

const TestCtx_merged = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb_merged() !TestCtx_merged {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Mirror the production schema exactly: workspace_items shape the
    // delete handler's harness established + migrations IN ORDER (076
    // then 079) — production runs every migration sequentially.
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration116.up(&db, testing.allocator);

    // Seed: 1 agent + 1 FILE-BACKED knowledge row (the case the edit
    // dialog opens on by default).
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type, description) VALUES ('ws_item_1', 'ws_item_1', 'agent', '')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, position) VALUES ('know_1', 'ws_item_1', '/tmp/orig.md', 'Original', 0)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

fn freeKnowledge(alloc: std.mem.Allocator, k: update_mod.Knowledge) void {
    agent_db.freeKnowledgeRow(alloc, k);
}

// ─── A. file→text switch (regression: used to 400 NotAbsolutePath) ──────

test "functional: file→text switch payload {file_path:'', content} succeeds end-to-end" {
    const alloc = testing.allocator;
    var ctx = try setupDb_merged();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // EXACT body the edit dialog sends for a Text-mode save on a
    // file-backed row (JSON round-trip so the wire shape is honest).
    const Body = struct {
        label: []const u8,
        content: []const u8,
        file_path: []const u8,
    };
    const body_json =
        \\{"label":"Switched","content":"inline body after switch","file_path":""}
    ;
    // parseFromSliceLeaky (arena-less) would leak under testing.allocator;
    // use the allocating variant and free its Parsed wrapper.
    var parsed = try std.json.parseFromSlice(Body, alloc, body_json, .{});
    defer parsed.deinit();

    const output = try update_mod.useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .knowledge_id = "know_1",
        .file_path = parsed.value.file_path,
        .label = parsed.value.label,
        .content = parsed.value.content,
    });
    defer freeKnowledge(alloc, output.knowledge);

    // Row flipped to content-backed: path cleared, content set.
    try testing.expectEqualStrings("", output.knowledge.file_path);
    try testing.expectEqualStrings("inline body after switch", output.knowledge.content);
    try testing.expectEqualStrings("Switched", output.knowledge.label);

    // And the DB row itself is consistent (refetch independently).
    var q = try ctx.db.query(alloc,
        "SELECT file_path, content FROM agent_config_knowledge WHERE id = 'know_1'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const r = (try q.next()) orelse return error.RowMissing;
    defer r.deinit(alloc);
    try testing.expectEqualStrings("", r.values[0]);
    try testing.expectEqualStrings("inline body after switch", r.values[1]);
}

// ─── B. text→file switch (regression: used to 500 NOT NULL constraint) ──

test "functional: text→file switch payload {file_path, content:''} succeeds end-to-end" {
    const alloc = testing.allocator;
    var ctx = try setupDb_merged();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed as INLINE first so we're genuinely switching text→file.
    try ctx.db.exec(alloc,
        "UPDATE agent_config_knowledge SET file_path = '', content = 'original inline' WHERE id = 'know_1'",
        &[_][]const u8{},
    );

    const Body = struct {
        label: []const u8,
        file_path: []const u8,
        content: []const u8,
    };
    const body_json =
        \\{"label":"NowAFile","file_path":"/tmp/switched.md","content":""}
    ;
    var parsed = try std.json.parseFromSlice(Body, alloc, body_json, .{});
    defer parsed.deinit();

    const output = try update_mod.useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .knowledge_id = "know_1",
        .file_path = parsed.value.file_path,
        .label = parsed.value.label,
        .content = parsed.value.content,
    });
    defer freeKnowledge(alloc, output.knowledge);

    // Row flipped to file-backed: content cleared to '' (NOT a crash),
    // path set.
    try testing.expectEqualStrings("/tmp/switched.md", output.knowledge.file_path);
    try testing.expectEqualStrings("", output.knowledge.content);

    // Independent refetch: content column must be '' not NULL.
    var q = try ctx.db.query(alloc,
        "SELECT file_path, content FROM agent_config_knowledge WHERE id = 'know_1'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const r = (try q.next()) orelse return error.RowMissing;
    defer r.deinit(alloc);
    try testing.expectEqualStrings("/tmp/switched.md", r.values[0]);
    try testing.expectEqualStrings("", r.values[1]);
}

// ─── C. guard stays: non-empty relative path still rejected ─────────────

test "functional: non-empty relative file_path still returns NotAbsolutePath" {
    const alloc = testing.allocator;
    var ctx = try setupDb_merged();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotAbsolutePath,
        update_mod.useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .knowledge_id = "know_1",
            .file_path = "rel/path.md",
            .label = null,
            .content = null,
        }),
    );
}

// ─── D. route order ─────────────────────────────────────────────────────
// The `/knowledge/reorder` literal must win over its `:knowledge_id` sibling.

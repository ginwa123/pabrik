//! `PATCH /api/agents/:agent_id/system_prompt/:prompt_id`. Updates title
//! and/or content of an existing system-prompt entry. Body: `{title?,
//! content?}` (both optional; at least one required).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const agent_db = @import("../models/agent.db.zig");

/// HTTP request body. Decoupled from the domain `SystemPromptUpdateInput`
/// so the wire format can evolve independently without touching the
/// use-case.
const UpdateSystemPromptBody = struct {
    title: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

/// Subset of the system-prompt row returned by the use-case.
pub const SystemPrompt = agent_db.SystemPromptRow;

/// Domain-level error set for `useCase`.
pub const SystemPromptUpdateError = error{
    /// `agent_id` or `prompt_id` path param was missing or empty.
    IdsRequired,
    /// Body had neither `title` nor `content` (nothing to update).
    NothingToUpdate,
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

/// Inputs to the system-prompt-update use-case.
pub const SystemPromptUpdateInput = struct {
    agent_id: []const u8,
    prompt_id: []const u8,
    title: ?[]const u8,
    content: ?[]const u8,
};

/// Output of the system-prompt-update use-case. `system_prompt` is owned by
/// the caller (lifetime = request arena).
pub const SystemPromptUpdateOutput = struct {
    system_prompt: SystemPrompt,
};

// =====================================================================
// Use case
// =====================================================================

/// Update an existing system-prompt row. Validates that at least one of
/// `title` / `content` is provided, then UPDATE-with-dynamic-SQL the
/// requested fields and SELECT-refetch the row.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: SystemPromptUpdateInput,
) SystemPromptUpdateError!SystemPromptUpdateOutput {
    if (input.agent_id.len == 0 or input.prompt_id.len == 0) {
        return error.IdsRequired;
    }
    if (input.title == null and input.content == null) {
        return error.NothingToUpdate;
    }

    const handle: agent_db.DbOrTx = .{ .db = db };

    // Patch the requested fields, then read the row back.
    const system_prompt = (agent_db.updateSystemPrompt(
        allocator,
        handle,
        input.prompt_id,
        input.agent_id,
        input.title,
        input.content,
    ) catch return error.UpdateFailed) orelse return error.RowNotFound;

    return .{ .system_prompt = system_prompt };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentSystemPromptUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";
    const prompt_id = req.params.get("prompt_id") orelse "";

    const parsed = std.json.parseFromSliceLeaky(UpdateSystemPromptBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .agent_id = agent_id,
        .prompt_id = prompt_id,
        .title = parsed.title,
        .content = parsed.content,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.NothingToUpdate => 400,
            error.UpdateFailed => 500,
            error.RefetchFailed => 500,
            error.RowNotFound => 404,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "agent_id and prompt_id required",
            error.NothingToUpdate => "title or content required",
            error.UpdateFailed => "Failed to update system prompt",
            error.RefetchFailed => "Failed to read row",
            error.RowNotFound => "system prompt row not found",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, output.system_prompt, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
// impl + tests in one file (project convention for Agent Mode). Behavioural
// tests cover the use-case: 1.

const sqlite = @import("pabrikcore").sqlite;
const testing = std.testing;
const Migration116 = @import("../migrations/migration.zig").Migration116UnifyAgentConfigTables;

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

    // See agent_knowledge_delete.zig for why we re-create
    // workspace_items with the full shape.
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration116.up(&db, testing.allocator);
    // Production DBs run every migration in order — the harness must
    // mirror that, or the agent_system_prompt table (Migration 080) is
    // missing.

    // Seed: 1 agent + 1 system-prompt row.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type, description) VALUES ('ws_item_1', 'ws_item_1', 'agent', '')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_system_prompt (id, config_id, title, content, position) VALUES ('asp_1', 'ws_item_1', 'Original Title', 'Original body', 0)",
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
            .prompt_id = "asp_1",
            .title = "New",
            .content = null,
        }),
    );
}

test "useCase: empty prompt_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .prompt_id = "",
            .title = "New",
            .content = null,
        }),
    );
}

test "useCase: neither title nor content returns NothingToUpdate" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NothingToUpdate,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .prompt_id = "asp_1",
            .title = null,
            .content = null,
        }),
    );
}

test "useCase: happy path updates both title AND content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .prompt_id = "asp_1",
        .title = "New Title",
        .content = "New body",
    });
    defer {
        agent_db.freeSystemPromptRow(alloc, output.system_prompt);
    }
    try testing.expectEqualStrings("asp_1", output.system_prompt.id);
    try testing.expectEqualStrings("New Title", output.system_prompt.title);
    try testing.expectEqualStrings("New body", output.system_prompt.content);
}

test "useCase: title-only update keeps content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .prompt_id = "asp_1",
        .title = "Renamed only",
        .content = null,
    });
    defer {
        agent_db.freeSystemPromptRow(alloc, output.system_prompt);
    }
    try testing.expectEqualStrings("Renamed only", output.system_prompt.title);
    try testing.expectEqualStrings("Original body", output.system_prompt.content);
}

test "useCase: PATCH with empty-string content is legal (COALESCE binds '' not NULL)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Regression: SqliteBackend.exec binds "" as SQL NULL, which would
    // trip content's NOT NULL constraint without the COALESCE(?, '')
    // wrapper in the UPDATE SET clause.
    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .prompt_id = "asp_1",
        .title = null,
        .content = "",
    });
    defer {
        agent_db.freeSystemPromptRow(alloc, output.system_prompt);
    }
    try testing.expectEqualStrings("", output.system_prompt.content);
    try testing.expectEqualStrings("Original Title", output.system_prompt.title);
}

// Exec wrappers for the `save_memory` / `load_memory` agent tools
// (append-only since 2026-09-12: `delete_memory` was removed per user
// decision — "memory is always add, no need edit or delete").
//
// Per-workspace scope (Migration 095)
// ─────────────────────────────────
// This file is the ONLY place that decides which workspace a memory
// operation runs against, and it decides it from `ctx.session_id` —
// never from the tool-call arguments. The `SaveMemoryInput` /
// `LoadMemoryInput` structs parsed below have no `workspace_id` field, so
// there is no JSON payload, however crafted, that can move a read or a
// write into another workspace. This mirrors how `read_workspace_session`
// scopes itself server-side.

const std = @import("std");
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const migration = @import("../migrations/migration.zig");
const workspace_scope = @import("workspace_scope.zig");

const sqlite = pabrikcore.sqlite;
const agent_memories = pabrikcore.agent_memories;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const memory_mod = pabrikcore.memory;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

/// Probe an inner JSON payload for a top-level `"error"` key. The
/// returned slice borrows from `parsed` — keep it alive through the
/// `wrapToolOutput` call, then `deinit`. A payload that fails to parse
/// is treated as success (the producers always emit valid JSON).
const InnerErrorProbe = struct {
    @"error": ?[]const u8 = null,
};

// ─── save_memory ───

/// Resolve the workspace this session's memory operations are scoped to.
/// Returns an owned slice (caller frees) or null; the caller normalises
/// null to the `''` "no workspace" bucket, which the storage layer stores
/// through the column DEFAULT.
///
/// A resolution failure is NOT an error: a bare CLI chat with no matching
/// `workspace_items.path` still gets a working (if private to other
/// workspace-less sessions) memory store. Failing the tool instead would
/// be a worse product than a scoped-narrow bucket.
fn resolveScope(ctx: ToolExecContext) !?[]u8 {
    return workspace_scope.resolveWorkspaceId(ctx.allocator, ctx.db, ctx.session_id);
}

pub fn execSaveMemory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        memory_mod.SaveMemoryInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const resolved = try resolveScope(ctx);
    defer if (resolved) |w| ctx.allocator.free(w);
    const workspace_id = resolved orelse "";

    const inner = memory_mod.executeSaveMemory(
        ctx.allocator,
        ctx.db,
        parsed.value,
        workspace_id,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the {"error":...} shape and surface it as a tool failure
    // (so the LLM sees success=false rather than a successful wrapper
    // around an error body).
    if (std.json.parseFromSlice(InnerErrorProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── load_memory ───

pub fn execLoadMemory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        memory_mod.LoadMemoryInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "load_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const resolved = try resolveScope(ctx);
    defer if (resolved) |w| ctx.allocator.free(w);
    const workspace_id = resolved orelse "";

    const inner = memory_mod.executeLoadMemory(
        ctx.allocator,
        ctx.db,
        parsed.value,
        workspace_id,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "load_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the {"error":...} shape and surface it as a tool failure
    // (so the LLM sees success=false rather than a successful wrapper
    // around an error body).
    if (std.json.parseFromSlice(InnerErrorProbe, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "load_memory", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "load_memory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── tests ───

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn makeTestCtx(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .db = db,
        .logger = undefined,
        .session_id = "sess_exec",
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

test "execSaveMemory: happy path wraps success=true and appends a new row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("save_memory", "{\"content\":\"row saved via exec wrapper\",\"tags\":\"test\"}");

    const result = try execSaveMemory(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    const env = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env.deinit();
    try testing.expectEqualStrings("save_memory", env.value.object.get("tool").?.string);
    try testing.expect(env.value.object.get("success").?.bool);
    try testing.expect(env.value.object.get("error").? == .null);
    // Inner payload rides in "data" with the saved row id.
    const data = env.value.object.get("data").?.object;
    try testing.expect(data.get("id").?.string.len > 0);

    // Saving the same payload again appends a second row (append-only).
    const result2 = try execSaveMemory(tcx, tc);
    defer if (result2.output_allocated) alloc.free(result2.output);
    const env2 = try std.json.parseFromSlice(std.json.Value, alloc, result2.output, .{});
    defer env2.deinit();
    try testing.expect(env2.value.object.get("success").?.bool);

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_memories", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}

test "execSaveMemory: empty content surfaces inner error as success=false" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("save_memory", "{\"content\":\"\"}");

    const result = try execSaveMemory(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    const env = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env.deinit();
    try testing.expect(!env.value.object.get("success").?.bool);
    try testing.expect(env.value.object.get("error").?.string.len > 0);
}

// ─── workspace scope (Migration 095) ──────────────────────────────────

/// Link a session id to a workspace the deterministic way:
/// `workspace_item_tasks.id` IS the session id, so the exact-task branch
/// of `resolveWorkspaceId` resolves without touching the cwd heuristic.
fn linkSessionToWorkspace(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8, workspace_id: []const u8, item_id: []const u8) !void {
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
            "VALUES (?, ?, 'kanban', 'test', ?)",
        &.{ item_id, workspace_id, "/tmp/does-not-match-any-workspace" },
    );
    try db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES (?, 't', ?)",
        &.{ session_id, item_id },
    );
}

fn ctxForSession(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) ToolExecContext {
    var base = makeTestCtx(allocator, db);
    base.session_id = session_id;
    return base;
}

test "execSaveMemory / execLoadMemory: a session only sees its OWN workspace's memories" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try linkSessionToWorkspace(alloc, &ctx.db, "sess_alpha", "ws_alpha", "item_alpha");
    try linkSessionToWorkspace(alloc, &ctx.db, "sess_beta", "ws_beta", "item_beta");

    const alpha_ctx = ctxForSession(alloc, &ctx.db, "sess_alpha");
    const beta_ctx = ctxForSession(alloc, &ctx.db, "sess_beta");

    // Workspace A saves a note about a term B also searches for.
    const save = fakeToolCall("save_memory", "{\"content\":\"alpha workspace: the deploy token rotates weekly\"}");
    const saved = try execSaveMemory(alpha_ctx, save);
    defer if (saved.output_allocated) alloc.free(saved.output);
    const saved_env = try std.json.parseFromSlice(std.json.Value, alloc, saved.output, .{});
    defer saved_env.deinit();
    const saved_id = try alloc.dupe(u8, saved_env.value.object.get("data").?.object.get("id").?.string);
    defer alloc.free(saved_id);
    // The payload tells the agent which workspace filed the note.
    try testing.expectEqualStrings("ws_alpha", saved_env.value.object.get("data").?.object.get("workspace_id").?.string);

    // Workspace B runs the same search and gets nothing.
    const search = fakeToolCall("load_memory", "{\"query\":\"deploy token\"}");
    const beta_out = try execLoadMemory(beta_ctx, search);
    defer if (beta_out.output_allocated) alloc.free(beta_out.output);
    const beta_env = try std.json.parseFromSlice(std.json.Value, alloc, beta_out.output, .{});
    defer beta_env.deinit();
    const beta_data = beta_env.value.object.get("data").?.object;
    try testing.expectEqual(@as(i64, 0), beta_data.get("count").?.integer);
    try testing.expectEqual(@as(i64, 0), beta_data.get("total_count").?.integer);
    try testing.expectEqualStrings("ws_beta", beta_data.get("workspace_id").?.string);

    // Workspace B cannot reach A's note by id either.
    const by_id_args = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\"}}", .{saved_id});
    defer alloc.free(by_id_args);
    const stolen = try execLoadMemory(beta_ctx, fakeToolCall("load_memory", by_id_args));
    defer if (stolen.output_allocated) alloc.free(stolen.output);
    const stolen_env = try std.json.parseFromSlice(std.json.Value, alloc, stolen.output, .{});
    defer stolen_env.deinit();
    // Reported as a plain "not found" — never as a denial, which would
    // confirm the id exists somewhere.
    try testing.expect(!stolen_env.value.object.get("success").?.bool);
    const stolen_err = stolen_env.value.object.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, stolen_err, "not found") != null);

    // Workspace A still reads its own note by id, and by search.
    const own = try execLoadMemory(alpha_ctx, fakeToolCall("load_memory", by_id_args));
    defer if (own.output_allocated) alloc.free(own.output);
    const own_env = try std.json.parseFromSlice(std.json.Value, alloc, own.output, .{});
    defer own_env.deinit();
    try testing.expect(own_env.value.object.get("success").?.bool);
    try testing.expectEqual(@as(i64, 1), own_env.value.object.get("data").?.object.get("count").?.integer);

    const alpha_search = try execLoadMemory(alpha_ctx, search);
    defer if (alpha_search.output_allocated) alloc.free(alpha_search.output);
    const alpha_env = try std.json.parseFromSlice(std.json.Value, alloc, alpha_search.output, .{});
    defer alpha_env.deinit();
    try testing.expectEqual(@as(i64, 1), alpha_env.value.object.get("data").?.object.get("count").?.integer);
}

test "execSaveMemory: a session with no resolvable workspace writes to the '' bucket" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // "sess_exec" has no workspace link and its cwd (/tmp) matches no
    // workspace_items.path → resolveWorkspaceId returns null.
    const tcx = makeTestCtx(alloc, &ctx.db);
    const result = try execSaveMemory(tcx, fakeToolCall("save_memory", "{\"content\":\"no workspace here\"}"));
    defer if (result.output_allocated) alloc.free(result.output);

    const env = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env.deinit();
    try testing.expect(env.value.object.get("success").?.bool);
    try testing.expectEqualStrings("", env.value.object.get("data").?.object.get("workspace_id").?.string);

    // Stored as '' — NOT NULL satisfied via the column DEFAULT, not a
    // NULL bind.
    var q = try ctx.db.query(alloc, "SELECT workspace_id FROM agent_memories", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "a workspace_id smuggled into the tool payload is ignored — the session still decides" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try linkSessionToWorkspace(alloc, &ctx.db, "sess_alpha", "ws_alpha", "item_alpha");
    try linkSessionToWorkspace(alloc, &ctx.db, "sess_beta", "ws_beta", "item_beta");

    const alpha_ctx = ctxForSession(alloc, &ctx.db, "sess_alpha");
    const beta_ctx = ctxForSession(alloc, &ctx.db, "sess_beta");

    // A note in beta, so alpha has something it must NOT be able to reach.
    const beta_seed = try execSaveMemory(beta_ctx, fakeToolCall("save_memory", "{\"content\":\"beta only: the vault token\"}"));
    defer if (beta_seed.output_allocated) alloc.free(beta_seed.output);
    const beta_env = try std.json.parseFromSlice(std.json.Value, alloc, beta_seed.output, .{});
    defer beta_env.deinit();
    const beta_id = try alloc.dupe(u8, beta_env.value.object.get("data").?.object.get("id").?.string);
    defer alloc.free(beta_id);

    // Alpha tries to WRITE into beta by naming it. `ignore_unknown_fields`
    // drops the key, and the row is filed under alpha's own workspace.
    const smuggle_save =
        \\{"content":"alpha tries to plant a note in beta","workspace_id":"ws_beta","workspace":"ws_beta","scope":"ws_beta"}
    ;
    const planted = try execSaveMemory(alpha_ctx, fakeToolCall("save_memory", smuggle_save));
    defer if (planted.output_allocated) alloc.free(planted.output);
    const planted_env = try std.json.parseFromSlice(std.json.Value, alloc, planted.output, .{});
    defer planted_env.deinit();
    try testing.expect(planted_env.value.object.get("success").?.bool);
    try testing.expectEqualStrings("ws_alpha", planted_env.value.object.get("data").?.object.get("workspace_id").?.string);

    var q = try ctx.db.query(alloc, "SELECT workspace_id FROM agent_memories WHERE content = ?", &.{"alpha tries to plant a note in beta"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("ws_alpha", row.values[0]);

    // Alpha tries to READ beta by naming it — both by search and by id.
    const smuggle_search =
        \\{"query":"vault token","workspace_id":"ws_beta"}
    ;
    const peek = try execLoadMemory(alpha_ctx, fakeToolCall("load_memory", smuggle_search));
    defer if (peek.output_allocated) alloc.free(peek.output);
    const peek_env = try std.json.parseFromSlice(std.json.Value, alloc, peek.output, .{});
    defer peek_env.deinit();
    try testing.expectEqual(@as(i64, 0), peek_env.value.object.get("data").?.object.get("count").?.integer);

    const smuggle_id = try std.fmt.allocPrint(
        alloc,
        "{{\"id\":\"{s}\",\"workspace_id\":\"ws_beta\"}}",
        .{beta_id},
    );
    defer alloc.free(smuggle_id);
    const peek_id = try execLoadMemory(alpha_ctx, fakeToolCall("load_memory", smuggle_id));
    defer if (peek_id.output_allocated) alloc.free(peek_id.output);
    const peek_id_env = try std.json.parseFromSlice(std.json.Value, alloc, peek_id.output, .{});
    defer peek_id_env.deinit();
    try testing.expect(!peek_id_env.value.object.get("success").?.bool);
}

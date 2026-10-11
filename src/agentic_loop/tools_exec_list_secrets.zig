// Exec adapter for `list_secrets` — the agent's discovery call for
// workspace credentials.
//
// Two properties drive the whole shape of this file:
//
//   1. The workspace comes from `ctx.session_id`, NEVER from the tool call.
//      `ToolExecContext` has no `workspace_id` field and this adapter never
//      parses `tc.function.arguments`, so a model that writes
//      `{"workspace_id": "ws_someone_else"}` into the call has it ignored
//      for the same reason a typo is ignored. Access is workspace
//      membership, enforced one level up by `auth_common.canSeeWorkspace`.
//
//   2. No value, ever. `secrets_store.listSecretNames` is the names-only
//      projection and is what decides WHICH names are disclosed; the
//      timestamps come from the row projection, and a name is emitted only
//      where the two agree. Neither SELECT mentions `value`.
//
// A session that resolves to no workspace returns an EMPTY list. It never
// falls back to "all workspaces" — the alternative to an empty answer here
// is a cross-tenant read, and a tool that can be made to give one by
// calling it from the wrong session is not a tool, it is a leak.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const secrets_store = @import("secrets_store.zig");
const workspace_scope = @import("workspace_scope.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;

/// One disclosed secret. Deliberately two fields: `name` is what the model
/// types into `{{SECRETS:NAME}}`, `updated_at` is what tells a stale
/// credential from a fresh one. Nothing else about the row is the model's
/// business — in particular not the row id.
const SecretEntry = struct {
    name: []const u8,
    updated_at: []const u8,
};

const SecretsPayload = struct {
    count: usize,
    secrets: []SecretEntry,
};

/// The fail-closed answer: a well-formed, empty payload. Used for the
/// unresolvable-workspace case AND for a database failure, because in both
/// cases "this session has no secrets it may see" is the only true thing
/// the adapter can say.
fn emptyResult(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const payload = try std.json.Stringify.valueAlloc(
        ctx.allocator,
        SecretsPayload{ .count = 0, .secrets = &.{} },
        .{},
    );
    defer ctx.allocator.free(payload);
    const output = try wrapToolOutput(ctx.allocator, "list_secrets", tc.function.arguments, true, null, payload);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execListSecrets(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const resolved = workspace_scope.resolveWorkspaceId(ctx.allocator, ctx.db, ctx.session_id) catch
        return emptyResult(ctx, tc);
    const workspace_id = resolved orelse return emptyResult(ctx, tc);
    defer ctx.allocator.free(workspace_id);

    const entries = try collectEntries(ctx.allocator, ctx.db, workspace_id);
    defer freeSecretEntries(ctx.allocator, entries);

    const payload = try std.json.Stringify.valueAlloc(
        ctx.allocator,
        SecretsPayload{ .count = entries.len, .secrets = entries },
        .{},
    );
    defer ctx.allocator.free(payload);

    const output = try wrapToolOutput(ctx.allocator, "list_secrets", tc.function.arguments, true, null, payload);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

/// The names of `workspace_id`'s secrets, each paired with the timestamp of
/// its last rotation. The returned entries own their strings — they must,
/// because the store rows they are copied out of are released before this
/// function returns.
///
/// Both queries are `ORDER BY name`, so the merge walk below is a correct
/// intersection. If that ever stops holding the result degrades to FEWER
/// entries, never to a name from another workspace — the names projection
/// stays the authority on what may be disclosed.
fn collectEntries(
    allocator: std.mem.Allocator,
    db: *@import("pabrikcore").sqlite.SqliteBackend,
    workspace_id: []const u8,
) ![]SecretEntry {
    const names = try secrets_store.listSecretNames(allocator, db, workspace_id);
    defer secrets_store.freeSecretNames(allocator, names);
    if (names.len == 0) return try allocator.alloc(SecretEntry, 0);

    const rows = try secrets_store.listSecrets(allocator, db, workspace_id);
    defer secrets_store.freeSecretRows(allocator, rows);

    var out: std.ArrayList(SecretEntry) = .empty;
    errdefer {
        for (out.items) |e| {
            allocator.free(e.name);
            allocator.free(e.updated_at);
        }
        out.deinit(allocator);
    }

    var i: usize = 0;
    for (rows) |row| {
        while (i < names.len and std.mem.order(u8, names[i], row.name) == .lt) i += 1;
        if (i >= names.len) break;
        if (!std.mem.eql(u8, names[i], row.name)) continue;
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, row.name),
            .updated_at = try allocator.dupe(u8, row.updated_at),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn freeSecretEntries(allocator: std.mem.Allocator, entries: []SecretEntry) void {
    for (entries) |e| {
        allocator.free(e.name);
        allocator.free(e.updated_at);
    }
    allocator.free(entries);
}

// ============================================================================
// Tests
//
// In-memory SQLite carrying both fixtures the adapter touches:
// `workspace_scope`'s three tables (so a session can resolve to a workspace)
// and `workspace_secrets` (so there is something to discover). The DDL is
// spelled out here rather than run through the migration chain, mirroring
// `workspace_scope.zig` and `secrets_store.zig`.
// ============================================================================

const testing = std.testing;
const sqlite = pabrikcore.sqlite;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  status TEXT DEFAULT 'active',
        \\  cwd TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  name TEXT,
        \\  path TEXT,
        \\  position INTEGER
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  workspace_item_id TEXT NOT NULL
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_secrets (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  value TEXT NOT NULL,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE UNIQUE INDEX IF NOT EXISTS uq_workspace_secrets_name
        \\ON workspace_secrets(workspace_id, name)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

/// Two workspaces, each with a kanban item; `s_a` is task-linked into
/// `ws_a`, `s_loose` is task-linked into `ws_b`, and `s_none` has a cwd
/// that matches no item at all.
fn seedWorkspaces(alloc: std.mem.Allocator, ctx: *TestCtx) !void {
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('i_a', 'ws_a', 'kanban', 'A', '/proj/a', 1),
        \\       ('i_b', 'ws_b', 'kanban', 'B', '/proj/b', 1)
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id)
        \\VALUES ('s_a', 'TA', 'i_a'), ('s_loose', 'TB', 'i_b')
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO sessions (id, name, status, cwd) VALUES
        \\  ('s_a', 'A', 'active', '/proj/a'),
        \\  ('s_loose', 'B', 'active', '/proj/b'),
        \\  ('s_none', 'Nowhere', 'active', '/elsewhere/entirely')
    , &.{});
}

fn seedSecret(alloc: std.mem.Allocator, ctx: *TestCtx, workspace_id: []const u8, name: []const u8, value: []const u8) !void {
    const id = try std.fmt.allocPrint(alloc, "sec_{s}_{s}", .{ workspace_id, name });
    defer alloc.free(id);
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value, created_at, updated_at)
        \\VALUES (?, ?, ?, ?, '2026-01-01 00:00:00', '2026-02-02 00:00:00')
    , &[_][]const u8{ id, workspace_id, name, value });
}

fn testCtx(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = alloc,
        .io = testing.io,
        .db = db,
        .logger = undefined,
        .session_id = session_id,
        .model = "test",
        .cwd = "/proj/a",
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
    };
}

fn call(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8, args: []const u8) !ToolExecResult {
    const tc = agent.ToolCall{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = "list_secrets", .arguments = args },
    };
    return execListSecrets(testCtx(alloc, db, session_id), tc);
}

/// The `data.secrets` entries as name strings, for order-sensitive asserts.
fn payloadNames(alloc: std.mem.Allocator, output: []const u8) ![][]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, output, .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?.object;
    const items = data.get("secrets").?.array.items;
    const names = try alloc.alloc([]u8, items.len);
    for (items, 0..) |item, i| names[i] = try alloc.dupe(u8, item.object.get("name").?.string);
    return names;
}

fn freeNames(alloc: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| alloc.free(n);
    alloc.free(names);
}

test "execListSecrets: a session's own workspace only — another workspace's names never appear" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);
    try seedWorkspaces(alloc, &ctx);

    try seedSecret(alloc, &ctx, "ws_a", "GH_TOKEN", "ghp_value_a");
    try seedSecret(alloc, &ctx, "ws_a", "STRIPE_KEY", "sk_value_a");
    try seedSecret(alloc, &ctx, "ws_b", "B_ONLY_TOKEN", "b_value");

    const result = try call(alloc, &ctx.db, "s_a", "{}");
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(std.mem.indexOf(u8, result.output, "\"success\":true") != null);

    const names = try payloadNames(alloc, result.output);
    defer freeNames(alloc, names);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("GH_TOKEN", names[0]);
    try testing.expectEqualStrings("STRIPE_KEY", names[1]);

    // The other workspace is invisible — not merely absent from the parsed
    // array, but absent from the whole serialized envelope.
    try testing.expect(std.mem.indexOf(u8, result.output, "B_ONLY_TOKEN") == null);
}

test "execListSecrets: the payload carries a rotation timestamp and never a stored value" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);
    try seedWorkspaces(alloc, &ctx);

    // A value distinctive enough that any leak of it — whole, masked, or
    // truncated to last-4 — shows up in the substring assertions below.
    try seedSecret(alloc, &ctx, "ws_a", "GH_TOKEN", "ghp_Zqx7LEAKCANARY99");

    const result = try call(alloc, &ctx.db, "s_a", "{}");
    defer if (result.output_allocated) alloc.free(result.output);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?.object;
    try testing.expectEqual(@as(i64, 1), data.get("count").?.integer);

    const entry = data.get("secrets").?.array.items[0].object;
    try testing.expectEqualStrings("GH_TOKEN", entry.get("name").?.string);
    // `updated_at` is what the brief asks for: enough to tell a stale
    // credential from a fresh one without disclosing anything.
    try testing.expectEqualStrings("2026-02-02 00:00:00", entry.get("updated_at").?.string);
    // Exactly two keys per entry — a `value` or a row `id` appearing here
    // would be a leak even if it were masked.
    try testing.expectEqual(@as(usize, 2), entry.count());

    // The canary, and its distinctive tail, must appear nowhere.
    try testing.expect(std.mem.indexOf(u8, result.output, "ghp_Zqx7LEAKCANARY99") == null);
    try testing.expect(std.mem.indexOf(u8, result.output, "LEAKCANARY") == null);
    try testing.expect(std.mem.indexOf(u8, result.output, "99\"") == null);
}

test "execListSecrets: a session with no workspace returns an empty list, never every workspace" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);
    try seedWorkspaces(alloc, &ctx);
    try seedSecret(alloc, &ctx, "ws_a", "GH_TOKEN", "ghp_value_a");
    try seedSecret(alloc, &ctx, "ws_b", "GH_TOKEN", "ghp_value_b");

    // s_none's cwd matches no workspace item, so `resolveWorkspaceId` returns
    // null. The tempting fallback — "no scope means no filter" — would hand
    // back every workspace's secrets.
    const result = try call(alloc, &ctx.db, "s_none", "{}");
    defer if (result.output_allocated) alloc.free(result.output);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("success").?.bool);
    const data = parsed.value.object.get("data").?.object;
    try testing.expectEqual(@as(i64, 0), data.get("count").?.integer);
    try testing.expectEqual(@as(usize, 0), data.get("secrets").?.array.items.len);
    try testing.expect(std.mem.indexOf(u8, result.output, "GH_TOKEN") == null);

    // An empty session id short-circuits before any query, and fails the
    // same way.
    const unknown = try call(alloc, &ctx.db, "no_such_session", "");
    defer if (unknown.output_allocated) alloc.free(unknown.output);
    try testing.expect(std.mem.indexOf(u8, unknown.output, "\"count\":0") != null);
    try testing.expect(std.mem.indexOf(u8, unknown.output, "GH_TOKEN") == null);
}

test "execListSecrets: a workspace_id in the arguments is ignored, not obeyed" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);
    try seedWorkspaces(alloc, &ctx);
    try seedSecret(alloc, &ctx, "ws_a", "A_TOKEN", "a_value");
    try seedSecret(alloc, &ctx, "ws_b", "B_TOKEN", "b_value");

    // The schema declares no properties, but the dispatcher parses tool-call
    // arguments with `ignore_unknown_fields` and a model can still write
    // one. It must change nothing: the scope is the SESSION's, always.
    const result = try call(
        alloc,
        &ctx.db,
        "s_a",
        "{\"workspace_id\":\"ws_b\"}",
    );
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(std.mem.indexOf(u8, result.output, "A_TOKEN") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "B_TOKEN") == null);

    // The envelope echoes what was passed, so a reader of the transcript can
    // see the attempt was discarded rather than silently honoured.
    try testing.expect(std.mem.indexOf(u8, result.output, "\"workspace_id\":\"ws_b\"") != null);
}

test "execListSecrets: a disclosed name is one the names-only projection also reports" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);
    try seedWorkspaces(alloc, &ctx);
    try seedSecret(alloc, &ctx, "ws_a", "ROTATED_TOKEN", "fresh_value");
    try seedSecret(alloc, &ctx, "ws_b", "ROTATED_TOKEN", "other_value");

    // Disclosing a name requires it to be present in BOTH projections — the
    // names projection is the authority on what may leave the store. This
    // asserts the two agree for the calling session's workspace, and that
    // the agreement survives a same-named secret living in another
    // workspace (a join bug would be invisible otherwise).
    const names_only = try secrets_store.listSecretNames(alloc, &ctx.db, "ws_a");
    defer secrets_store.freeSecretNames(alloc, names_only);
    try testing.expectEqual(@as(usize, 1), names_only.len);
    try testing.expectEqualStrings("ROTATED_TOKEN", names_only[0]);

    const result = try call(alloc, &ctx.db, "s_a", "{}");
    defer if (result.output_allocated) alloc.free(result.output);

    const names = try payloadNames(alloc, result.output);
    defer freeNames(alloc, names);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("ROTATED_TOKEN", names[0]);
    try testing.expect(std.mem.indexOf(u8, result.output, "fresh_value") == null);
    try testing.expect(std.mem.indexOf(u8, result.output, "other_value") == null);
}

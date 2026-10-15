//! Agent-callable tool: `list_secrets` — the NAMES of the secrets stored in
//! the calling session's workspace, and nothing else.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

/// Input for `list_secrets`. An empty struct — there is nothing to pass,
/// and every field here would be a chance to pass the wrong thing.
pub const ListSecretsInput = struct {};

pub const list_secrets_tool_system_prompt =
    \\## List Secrets — discover the credential names in this workspace
    \\
    \\Call `list_secrets` with no arguments to learn which secret names this workspace stores.
    \\It returns NAMES and rotation timestamps only, never the credential itself.
    \\
    \\Use a discovered name inside `{{SECRETS:NAME}}` in ANY tool parameter. The placeholder is
    \\replaced with the real credential immediately before the tool runs, and the value is
    \\redacted from whatever the tool reports back.
    \\
    \\**Never** put a secret's value into a file, a commit message, a command that captures
    \\output, or your own reply to the user — not even to show it worked. Reference it by name.
;

pub const list_secrets_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_secrets",
        .description =
        \\List this workspace's secrets — Names only, never returned — with the timestamp each was last rotated. No parameters: the workspace is the calling session's. Call this before writing a {{SECRETS:NAME}} placeholder so you use a name that exists. Read-only, no side effects.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
        .system_prompt = list_secrets_tool_system_prompt,
    },
};

const testing = std.testing;

test "list_secrets_tool JSON schema: no properties, no required, and no workspace_id key" {
    const tool = list_secrets_tool;
    try testing.expectEqualStrings("function", tool.type);
    try testing.expectEqualStrings("list_secrets", tool.function.name);
    try testing.expectEqual(@as(usize, 0), tool.function.parameters.required.len);
    try testing.expectEqual(@as(usize, 0), tool.function.parameters.properties.len);

    // Asserted on the SERIALIZED schema, not on the struct: a future edit
    // that adds a property is exactly the regression this has to catch, and
    // counting fields cannot see it.
    const json = try std.json.Stringify.valueAlloc(testing.allocator, tool, .{});
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"workspace_id\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"value\"") == null);
    // No declared property of any kind — the strongest statement available
    // is the empty one, and it is what a future `workspace_id` addition
    // would break.
    try testing.expect(std.mem.indexOf(u8, json, "\"properties\":[]") != null);
}

test "list_secrets_tool: the description teaches the placeholder and promises names only" {
    const description = list_secrets_tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "{{SECRETS:NAME}}") != null);
    try testing.expect(std.mem.indexOf(u8, description, "Names only") != null);
    // A model that thinks this tool hands back credentials will use it as a
    // way to read one out loud.
    try testing.expect(std.mem.indexOf(u8, description, "never returned") != null);

    const system_prompt = list_secrets_tool.function.system_prompt;
    try testing.expect(std.mem.indexOf(u8, system_prompt, "{{SECRETS:NAME}}") != null);
    try testing.expect(std.mem.indexOf(u8, system_prompt, "Never") != null);
}

// Exec adapter — merged from `list_secrets.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const secrets_store = @import("../../../agentic_loop/secrets_store.zig");
const workspace_scope = @import("../../../agentic_loop/workspace_scope.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
/// One disclosed secret.
const SecretEntry = struct {
    name: []const u8,
    updated_at: []const u8,
};

const SecretsPayload = struct {
    count: usize,
    secrets: []SecretEntry,
};

/// The fail-closed answer: a well-formed, empty payload.
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
/// its last rotation.
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
// Tests In-memory SQLite carrying both fixtures the adapter touches:
// `workspace_scope`'s three tables (so a session can resolve to a workspace)

const exec_testing = std.testing;
const sqlite = pabrikcore.sqlite;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = exec_testing.allocator;
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
        .io = exec_testing.io,
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
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);
    try seedWorkspaces(alloc, &ctx);

    try seedSecret(alloc, &ctx, "ws_a", "GH_TOKEN", "ghp_value_a");
    try seedSecret(alloc, &ctx, "ws_a", "STRIPE_KEY", "sk_value_a");
    try seedSecret(alloc, &ctx, "ws_b", "B_ONLY_TOKEN", "b_value");

    const result = try call(alloc, &ctx.db, "s_a", "{}");
    defer if (result.output_allocated) alloc.free(result.output);

    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"success\":true") != null);

    const names = try payloadNames(alloc, result.output);
    defer freeNames(alloc, names);
    try exec_testing.expectEqual(@as(usize, 2), names.len);
    try exec_testing.expectEqualStrings("GH_TOKEN", names[0]);
    try exec_testing.expectEqualStrings("STRIPE_KEY", names[1]);

    // The other workspace is invisible — not merely absent from the parsed
    // array, but absent from the whole serialized envelope.
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "B_ONLY_TOKEN") == null);
}

test "execListSecrets: the payload carries a rotation timestamp and never a stored value" {
    const alloc = exec_testing.allocator;
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
    try exec_testing.expectEqual(@as(i64, 1), data.get("count").?.integer);

    const entry = data.get("secrets").?.array.items[0].object;
    try exec_testing.expectEqualStrings("GH_TOKEN", entry.get("name").?.string);
    // `updated_at` is what the brief asks for: enough to tell a stale
    // credential from a fresh one without disclosing anything.
    try exec_testing.expectEqualStrings("2026-02-02 00:00:00", entry.get("updated_at").?.string);
    // Exactly two keys per entry — a `value` or a row `id` appearing here
    // would be a leak even if it were masked.
    try exec_testing.expectEqual(@as(usize, 2), entry.count());

    // The canary, and its distinctive tail, must appear nowhere.
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "ghp_Zqx7LEAKCANARY99") == null);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "LEAKCANARY") == null);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "99\"") == null);
}

test "execListSecrets: a session with no workspace returns an empty list, never every workspace" {
    const alloc = exec_testing.allocator;
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
    try exec_testing.expect(parsed.value.object.get("success").?.bool);
    const data = parsed.value.object.get("data").?.object;
    try exec_testing.expectEqual(@as(i64, 0), data.get("count").?.integer);
    try exec_testing.expectEqual(@as(usize, 0), data.get("secrets").?.array.items.len);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "GH_TOKEN") == null);

    // An empty session id short-circuits before any query, and fails the
    // same way.
    const unknown = try call(alloc, &ctx.db, "no_such_session", "");
    defer if (unknown.output_allocated) alloc.free(unknown.output);
    try exec_testing.expect(std.mem.indexOf(u8, unknown.output, "\"count\":0") != null);
    try exec_testing.expect(std.mem.indexOf(u8, unknown.output, "GH_TOKEN") == null);
}

test "execListSecrets: a workspace_id in the arguments is ignored, not obeyed" {
    const alloc = exec_testing.allocator;
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

    try exec_testing.expect(std.mem.indexOf(u8, result.output, "A_TOKEN") != null);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "B_TOKEN") == null);

    // The envelope echoes what was passed, so a reader of the transcript can
    // see the attempt was discarded rather than silently honoured.
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"workspace_id\":\"ws_b\"") != null);
}

test "execListSecrets: a disclosed name is one the names-only projection also reports" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);
    try seedWorkspaces(alloc, &ctx);
    try seedSecret(alloc, &ctx, "ws_a", "ROTATED_TOKEN", "fresh_value");
    try seedSecret(alloc, &ctx, "ws_b", "ROTATED_TOKEN", "other_value");

    // Disclosing a name requires it to be present in BOTH projections — the
    // names projection is the authority on what may leave the store.
    const names_only = try secrets_store.listSecretNames(alloc, &ctx.db, "ws_a");
    defer secrets_store.freeSecretNames(alloc, names_only);
    try exec_testing.expectEqual(@as(usize, 1), names_only.len);
    try exec_testing.expectEqualStrings("ROTATED_TOKEN", names_only[0]);

    const result = try call(alloc, &ctx.db, "s_a", "{}");
    defer if (result.output_allocated) alloc.free(result.output);

    const names = try payloadNames(alloc, result.output);
    defer freeNames(alloc, names);
    try exec_testing.expectEqual(@as(usize, 1), names.len);
    try exec_testing.expectEqualStrings("ROTATED_TOKEN", names[0]);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "fresh_value") == null);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "other_value") == null);
}


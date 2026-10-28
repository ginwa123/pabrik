//! Storage layer for workspace-scoped secrets.

const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;
const helpers = @import("helpers");

/// Longest legal secret name.
pub const MAX_NAME_LEN: usize = 64;

/// One row in `workspace_secrets`, WITHOUT the value.
pub const SecretRow = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// A name paired with its value. Produced ONLY by `loadSecretValues`. A
/// caller holding one of these holds a live credential: never log it, never
/// persist it, never put it in a tool result or an SSE frame.
pub const SecretValueRow = struct {
    name: []const u8,
    value: []const u8,
};

/// Fields for a new secret. `workspace_id` is required and has no default:
/// a secret with no owner is not a secret.
pub const CreateSecretArgs = struct {
    workspace_id: []const u8,
    name: []const u8 = "",
    value: []const u8 = "",
};

/// Rotation shape.
pub const UpdateSecretArgs = struct {
    workspace_id: []const u8,
    secret_id: []const u8,
    value: []const u8 = "",
};

pub const SecretsError = error{
    WorkspaceIdRequired,
    IdsRequired,
    NameRequired,
    ValueRequired,
    InvalidName,
    NameTaken,
    NotFound,
    QueryFailed,
    InsertFailed,
    UpdateFailed,
    DeleteFailed,
    OutOfMemory,
};

/// The read shape shared by every value-free read, so no call site can
/// accidentally return a different projection. There is deliberately no
/// `value` in this list — see the module header.
const SELECT_COLUMNS =
    "SELECT id, workspace_id, name, " ++
    "COALESCE(created_at, ''), COALESCE(updated_at, '') " ++
    "FROM workspace_secrets";

/// The agent's discovery path: NAMES ONLY, ordered so the list is stable
/// across calls.
const SELECT_NAMES =
    "SELECT name FROM workspace_secrets WHERE workspace_id = ? ORDER BY name";

/// Prefix for `loadSecretValues`, which appends the `IN (...)` list. The
/// only two functions in this file whose SQL mentions `value`.
const SELECT_NAME_VALUE_PREFIX =
    "SELECT name, value FROM workspace_secrets WHERE workspace_id = ? AND name IN (";

fn rowFromValues(allocator: std.mem.Allocator, values: []const []const u8) !SecretRow {
    return .{
        .id = try allocator.dupe(u8, values[0]),
        .workspace_id = try allocator.dupe(u8, values[1]),
        .name = try allocator.dupe(u8, values[2]),
        .created_at = try allocator.dupe(u8, values[3]),
        .updated_at = try allocator.dupe(u8, values[4]),
    };
}

/// Every secret in one workspace, ordered by name. Never selects `value`.
pub fn listSecrets(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
) SecretsError![]SecretRow {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;

    var q = db.query(
        allocator,
        SELECT_COLUMNS ++ " WHERE workspace_id = ? ORDER BY name",
        &[_][]const u8{workspace_id},
    ) catch return error.QueryFailed;
    defer q.deinit();

    var list: std.ArrayList(SecretRow) = .empty;
    // A mid-iteration failure would strand the rows already built, so
    // unwind them here rather than at each `try`.
    errdefer freeSecretRows(allocator, list.items);

    while (q.next() catch return error.QueryFailed) |r| {
        defer r.deinit(allocator);
        try list.append(allocator, try rowFromValues(allocator, r.values));
    }
    return list.toOwnedSlice(allocator);
}

/// One secret, scoped to `workspace_id`. Never selects `value`.
pub fn getSecret(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    secret_id: []const u8,
) SecretsError!SecretRow {
    if (workspace_id.len == 0 or secret_id.len == 0) return error.IdsRequired;

    var q = db.query(
        allocator,
        SELECT_COLUMNS ++ " WHERE id = ? AND workspace_id = ?",
        &[_][]const u8{ secret_id, workspace_id },
    ) catch return error.QueryFailed;
    defer q.deinit();

    const r = (q.next() catch return error.QueryFailed) orelse return error.NotFound;
    defer r.deinit(allocator);
    return rowFromValues(allocator, r.values) catch return error.OutOfMemory;
}

/// Insert a secret and return it with its canonical id and timestamps.
pub fn createSecret(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: CreateSecretArgs,
) SecretsError!SecretRow {
    if (args.workspace_id.len == 0) return error.WorkspaceIdRequired;

    const name = std.mem.trim(u8, args.name, " \t\n\r");
    if (name.len == 0) return error.NameRequired;
    // Validated here, before the INSERT, rather than left to the database:
    // the name is what a model types into a `{{SECRETS:NAME}}` placeholder,
    // so a name the grammar cannot express is rejected at the edge.
    if (!isValidName(name)) return error.InvalidName;

    // An empty value is rejected here rather than reaching the column.
    if (args.value.len == 0) return error.ValueRequired;

    // Pre-check so the ordinary duplicate is a clean NameTaken rather than a
    // constraint violation surfacing as a 500 at the HTTP layer.
    if (nameExists(db, allocator, args.workspace_id, name)) return error.NameTaken;

    // Same id shape as `documents_store`: a nanosecond wall-clock string
    // with a table prefix. `helpers.unixTimestampNanos` is cross-platform
    // (`std.c.clock_gettime` does not compile on Windows in Zig 0.16).
    const secret_id = try std.fmt.allocPrint(allocator, "sec_{d}", .{helpers.unixTimestampNanos()});
    defer allocator.free(secret_id);

    // COALESCE(NULLIF(?, ''), '') on every NOT NULL text column, for the
    // empty-slice-binds-as-NULL reason described above.
    db.exec(allocator,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value, created_at, updated_at)
        \\VALUES (?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    , &[_][]const u8{ secret_id, args.workspace_id, name, args.value }) catch |err| switch (err) {
        error.ExecuteFailed => {
            // A failed INSERT is not automatically a taken name: it is also
            // what a same-nanosecond primary-key collision looks like.
            if (nameExists(db, allocator, args.workspace_id, name)) {
                return error.NameTaken;
            }
            return error.InsertFailed;
        },
        else => return error.InsertFailed,
    };

    // The re-read reports the full error set, so map it: a row that is not
    // there after a successful INSERT is the consistency error, and anything
    // else — including the guards that cannot trigger, since both ids are
    return getSecret(allocator, db, args.workspace_id, secret_id) catch |err| switch (err) {
        error.NotFound, error.IdsRequired, error.QueryFailed => error.InsertFailed,
        error.OutOfMemory => error.InsertFailed,
        else => error.InsertFailed,
    };
}

/// Rotate a secret's value. `name` is immutable — see `UpdateSecretArgs`.
/// Scoped like every other read: a foreign id reports `error.NotFound` and
/// updates nothing.
pub fn updateSecret(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: UpdateSecretArgs,
) SecretsError!SecretRow {
    if (args.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (args.secret_id.len == 0) return error.IdsRequired;

    // Same reason as create: `value: ""` would store an empty credential
    // rather than reporting that nothing was supplied. Clearing a secret is
    // `deleteSecret`, which is an explicit act.
    if (args.value.len == 0) return error.ValueRequired;

    // `db.exec` reports no row count, so existence is checked separately.
    // Selecting `id` only keeps the current value out of memory: this
    // function replaces it wholesale and never needs to read it back.
    var q = db.query(
        allocator,
        "SELECT id FROM workspace_secrets WHERE id = ? AND workspace_id = ?",
        &[_][]const u8{ args.secret_id, args.workspace_id },
    ) catch return error.QueryFailed;
    defer q.deinit();
    if (q.next() catch return error.QueryFailed) |r| {
        r.deinit(allocator);
    } else return error.NotFound;

    db.exec(allocator,
        \\UPDATE workspace_secrets
        \\SET value = COALESCE(NULLIF(?, ''), ''), updated_at = CURRENT_TIMESTAMP
        \\WHERE id = ? AND workspace_id = ?
    , &[_][]const u8{ args.value, args.secret_id, args.workspace_id }) catch
        return error.UpdateFailed;

    return getSecret(allocator, db, args.workspace_id, args.secret_id) catch
        return error.UpdateFailed;
}

/// Delete a secret. Scoped like every other read: a foreign id reports
/// `error.NotFound` and deletes nothing.
pub fn deleteSecret(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    secret_id: []const u8,
) SecretsError!void {
    if (workspace_id.len == 0 or secret_id.len == 0) return error.IdsRequired;

    var q = db.query(
        allocator,
        "SELECT id FROM workspace_secrets WHERE id = ? AND workspace_id = ?",
        &[_][]const u8{ secret_id, workspace_id },
    ) catch return error.DeleteFailed;
    defer q.deinit();
    const r = (q.next() catch return error.DeleteFailed) orelse return error.NotFound;
    defer r.deinit(allocator);

    db.exec(
        allocator,
        "DELETE FROM workspace_secrets WHERE id = ? AND workspace_id = ?",
        &[_][]const u8{ secret_id, workspace_id },
    ) catch return error.DeleteFailed;
}

/// The NAMES in one workspace, ordered, with no values attached. This is the
/// only function the agent-facing paths may call.
pub fn listSecretNames(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
) SecretsError![][]u8 {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;

    var q = db.query(allocator, SELECT_NAMES, &[_][]const u8{workspace_id}) catch
        return error.QueryFailed;
    defer q.deinit();

    var out: std.ArrayList([]u8) = .empty;
    errdefer freeSecretNames(allocator, out.items);

    while (q.next() catch return error.QueryFailed) |r| {
        defer r.deinit(allocator);
        const name = try allocator.dupe(u8, r.values[0]);
        errdefer allocator.free(name);
        try out.append(allocator, name);
    }
    return out.toOwnedSlice(allocator);
}

/// The values of the named secrets in one workspace — the ONLY function in
/// this file that returns a value, and therefore the only one the
/// substitution path may call.
pub fn loadSecretValues(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    names: []const []const u8,
) SecretsError![]SecretValueRow {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;

    var out: std.ArrayList(SecretValueRow) = .empty;
    errdefer freeSecretValueRows(allocator, out.items);

    if (names.len == 0) return out.toOwnedSlice(allocator);

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, SELECT_NAME_VALUE_PREFIX);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, workspace_id);

    for (names, 0..) |name, i| {
        if (i > 0) try sql.append(allocator, ',');
        try sql.append(allocator, '?');
        try argv.append(allocator, name);
    }
    try sql.appendSlice(allocator, ") ORDER BY name");

    var q = db.query(allocator, sql.items, argv.items) catch return error.QueryFailed;
    defer q.deinit();

    while (q.next() catch return error.QueryFailed) |r| {
        defer r.deinit(allocator);
        const name_copy = try allocator.dupe(u8, r.values[0]);
        errdefer allocator.free(name_copy);
        const value_copy = try allocator.dupe(u8, r.values[1]);
        errdefer allocator.free(value_copy);
        try out.append(allocator, .{ .name = name_copy, .value = value_copy });
    }
    return out.toOwnedSlice(allocator);
}

/// Whether `(workspace_id, name)` is already taken. Used both as the
/// create-time pre-check and as the classifier after a failed INSERT.
fn nameExists(
    db: *database.Db,
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    name: []const u8,
) bool {
    var q = db.query(
        allocator,
        "SELECT id FROM workspace_secrets WHERE workspace_id = ? AND name = ?",
        &[_][]const u8{ workspace_id, name },
    ) catch return false;
    defer q.deinit();
    const hit = q.next() catch return false;
    if (hit) |r| {
        r.deinit(allocator);
        return true;
    }
    return false;
}

/// `[A-Za-z0-9_-]{1,64}`.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME_LEN) return false;
    for (name) |c| {
        const allowed = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!allowed) return false;
    }
    return true;
}

/// Free a single row's owned strings.
pub fn freeSecretRow(allocator: std.mem.Allocator, row: SecretRow) void {
    allocator.free(row.id);
    allocator.free(row.workspace_id);
    allocator.free(row.name);
    allocator.free(row.created_at);
    allocator.free(row.updated_at);
}

/// Free a slice of rows. The slice header is freed last.
pub fn freeSecretRows(allocator: std.mem.Allocator, rows: []SecretRow) void {
    for (rows) |row| freeSecretRow(allocator, row);
    allocator.free(rows);
}

/// Free a slice of owned names.
pub fn freeSecretNames(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

/// Free a slice of name/value pairs. Call this as soon as the substituted
/// tool call has been dispatched — it is the only thing standing between a
/// live credential and a leaking allocator's error report.
pub fn freeSecretValueRows(allocator: std.mem.Allocator, rows: []SecretValueRow) void {
    for (rows) |row| {
        allocator.free(row.name);
        allocator.free(row.value);
    }
    allocator.free(rows);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE workspace_secrets (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  value TEXT NOT NULL,
        \\  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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

/// Create one secret and free the returned row, for tests that only care
/// that the call succeeded.
fn seed(allocator: std.mem.Allocator, ctx: *TestCtx, workspace_id: []const u8, name: []const u8) !void {
    const value = try std.fmt.allocPrint(allocator, "v_{s}", .{name});
    defer allocator.free(value);
    const row = try createSecret(allocator, &ctx.db, .{
        .workspace_id = workspace_id,
        .name = name,
        .value = value,
    });
    freeSecretRow(allocator, row);
}

/// Read one stored value straight from SQL, bypassing the store, so an
/// assertion about what was actually persisted cannot be satisfied by the
/// same code path it is testing.
fn storedValue(ctx: *TestCtx, name: []const u8) ![]const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT value FROM workspace_secrets WHERE name = ?",
        &[_][]const u8{name},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.SecretMissing;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

test "createSecret rejects an empty name before it reaches the database" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    // `Backend.exec` binds "" as SQL NULL, so a name check that ran
    // after the INSERT would surface as a constraint error instead.
    try testing.expectError(error.NameRequired, createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "",
        .value = "ghp_x",
    }));
    try testing.expectError(error.NameRequired, createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "   \t\n",
        .value = "ghp_x",
    }));
    try testing.expectError(error.WorkspaceIdRequired, createSecret(alloc, &ctx.db, .{
        .workspace_id = "",
        .name = "GH",
        .value = "ghp_x",
    }));
}

test "createSecret rejects an empty value before it reaches the database" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    try testing.expectError(error.ValueRequired, createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "GH",
        .value = "",
    }));

    // Nothing was written on the way to the error.
    const names = try listSecretNames(alloc, &ctx.db, "ws_1");
    defer freeSecretNames(alloc, names);
    try testing.expectEqual(@as(usize, 0), names.len);
}

test "createSecret rejects a name the placeholder grammar cannot express" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    const bad = [_][]const u8{
        "has space", // would break `{{SECRETS:...}}` lexing
        "has.dot", // punctuation
        "quote\"", // JSON-hostile
        "brace{", // delimiter confusion
        "slash/one",
        "colon:name",
    };
    for (bad) |name| {
        try testing.expectError(error.InvalidName, createSecret(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .name = name,
            .value = "v",
        }));
    }

    // 64 is the cap; 65 is not a name. A legal-length name paired with an
    // empty value reports ValueRequired, which shows the name check passed
    // first rather than masking it behind InvalidName.
    const too_long = "a" ** (MAX_NAME_LEN + 1);
    try testing.expectError(error.InvalidName, createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = too_long,
        .value = "v",
    }));
    try testing.expectError(error.ValueRequired, createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "a" ** MAX_NAME_LEN,
        .value = "",
    }));

    const ok_name = "a" ** MAX_NAME_LEN;
    const row = try createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = ok_name,
        .value = "v",
    });
    defer freeSecretRow(alloc, row);
    try testing.expectEqualStrings(ok_name, row.name);
}

test "createSecret reports a duplicate name in the same workspace as NameTaken" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    try seed(alloc, &ctx, "ws_1", "GITHUB_TOKEN");

    // A clean, specific error — not a constraint violation the HTTP layer
    // would have to turn into a 500.
    try testing.expectError(error.NameTaken, createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "GITHUB_TOKEN",
        .value = "ghp_other",
    }));

    // The rejected insert must not have overwritten the stored value.
    const kept = try storedValue(&ctx, "GITHUB_TOKEN");
    defer alloc.free(kept);
    try testing.expectEqualStrings("v_GITHUB_TOKEN", kept);

    // The same name in a DIFFERENT workspace is not a duplicate.
    const other = try createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_2",
        .name = "GITHUB_TOKEN",
        .value = "ghp_b",
    });
    defer freeSecretRow(alloc, other);
    try testing.expectEqualStrings("ws_2", other.workspace_id);
}

test "every read is scoped: a foreign workspace_id sees nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    const row = try createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "GH",
        .value = "ghp_1",
    });
    defer freeSecretRow(alloc, row);

    // NotFound, not another workspace's row — a distinct "wrong workspace"
    // error would confirm the id exists.
    try testing.expectError(error.NotFound, getSecret(alloc, &ctx.db, "ws_2", row.id));
    try testing.expectError(error.NotFound, updateSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_2",
        .secret_id = row.id,
        .value = "stolen",
    }));
    try testing.expectError(error.NotFound, deleteSecret(alloc, &ctx.db, "ws_2", row.id));

    // ...and the rejected writes changed nothing.
    const kept = try storedValue(&ctx, "GH");
    defer alloc.free(kept);
    try testing.expectEqualStrings("ghp_1", kept);

    const ws1 = try listSecrets(alloc, &ctx.db, "ws_1");
    defer freeSecretRows(alloc, ws1);
    const ws2 = try listSecrets(alloc, &ctx.db, "ws_2");
    defer freeSecretRows(alloc, ws2);
    try testing.expectEqual(@as(usize, 1), ws1.len);
    try testing.expectEqual(@as(usize, 0), ws2.len);

    // The same guard holds on the two substitution-facing reads.
    const ws2_names = try listSecretNames(alloc, &ctx.db, "ws_2");
    defer freeSecretNames(alloc, ws2_names);
    try testing.expectEqual(@as(usize, 0), ws2_names.len);

    const ws2_values = try loadSecretValues(alloc, &ctx.db, "ws_2", &[_][]const u8{"GH"});
    defer freeSecretValueRows(alloc, ws2_values);
    try testing.expectEqual(@as(usize, 0), ws2_values.len);
}

test "listSecretNames returns names and its SQL cannot select a value" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    // Asserted on the SQL string itself, not on a result set: a result can
    // only show that the column is absent today, whereas a source change
    // that adds it is exactly the regression this has to catch.
    try testing.expect(std.mem.indexOf(u8, SELECT_NAMES, "value") == null);

    // The shared read projection has the same property, so a value-free read
    // stays value-free wherever it is reused.
    try testing.expect(std.mem.indexOf(u8, SELECT_COLUMNS, "value") == null);

    try seed(alloc, &ctx, "ws_1", "ZEBRA");
    try seed(alloc, &ctx, "ws_1", "APPLE");
    try seed(alloc, &ctx, "ws_2", "MANGO");

    const names = try listSecretNames(alloc, &ctx.db, "ws_1");
    defer freeSecretNames(alloc, names);
    try testing.expectEqual(@as(usize, 2), names.len);
    // Ordered by name so the discovery output is stable between calls.
    try testing.expectEqualStrings("APPLE", names[0]);
    try testing.expectEqualStrings("ZEBRA", names[1]);
}

test "loadSecretValues returns only the requested names, with their values" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    try seed(alloc, &ctx, "ws_1", "GH");
    try seed(alloc, &ctx, "ws_1", "STRIPE");
    try seed(alloc, &ctx, "ws_2", "GH");

    const values = try loadSecretValues(alloc, &ctx.db, "ws_1", &[_][]const u8{ "STRIPE", "GH" });
    defer freeSecretValueRows(alloc, values);

    try testing.expectEqual(@as(usize, 2), values.len);
    try testing.expectEqualStrings("GH", values[0].name);
    try testing.expectEqualStrings("v_GH", values[0].value);
    try testing.expectEqualStrings("STRIPE", values[1].name);
    try testing.expectEqualStrings("v_STRIPE", values[1].value);

    // An unknown name is absent from the result rather than an empty value:
    // only the caller knows which placeholder went missing, and reporting it
    // as "" would turn a typo into a confusing third-party 401 later.
    const partial = try loadSecretValues(alloc, &ctx.db, "ws_1", &[_][]const u8{ "GH", "NOPE" });
    defer freeSecretValueRows(alloc, partial);
    try testing.expectEqual(@as(usize, 1), partial.len);
    try testing.expectEqualStrings("GH", partial[0].name);

    // No names means no query and no rows.
    const none = try loadSecretValues(alloc, &ctx.db, "ws_1", &.{});
    defer freeSecretValueRows(alloc, none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "updateSecret rotates the value and leaves the name alone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    const created = try createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "GH",
        .value = "ghp_old",
    });
    defer freeSecretRow(alloc, created);

    const rotated = try updateSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .secret_id = created.id,
        .value = "ghp_new",
    });
    defer freeSecretRow(alloc, rotated);

    // A rename would silently break every prompt and saved tool call that
    // references {{SECRETS:GH}}, so the name is not part of the update.
    try testing.expectEqualStrings("GH", rotated.name);
    try testing.expectEqualStrings(created.id, rotated.id);

    const persisted = try storedValue(&ctx, "GH");
    defer alloc.free(persisted);
    try testing.expectEqualStrings("ghp_new", persisted);

    // Rotation is the only update there is, so an empty value is refused
    // rather than storing an empty credential. Clearing a secret is a delete.
    try testing.expectError(error.ValueRequired, updateSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .secret_id = created.id,
        .value = "",
    }));
    try testing.expectError(error.IdsRequired, updateSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .secret_id = "",
        .value = "v",
    }));
}

test "a value with quotes, a backslash and a newline round-trips byte for byte" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    // The value is stored plaintext, so the only correctness question is
    // whether the binder corrupts it.
    const gnarly = "he said \"hi\" \\ path\\to\\x\nsecond line\ttabbed";
    const row = try createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "GNARLY",
        .value = gnarly,
    });
    defer freeSecretRow(alloc, row);

    const values = try loadSecretValues(alloc, &ctx.db, "ws_1", &[_][]const u8{"GNARLY"});
    defer freeSecretValueRows(alloc, values);
    try testing.expectEqual(@as(usize, 1), values.len);
    try testing.expectEqualStrings(gnarly, values[0].value);
}

test "deleteSecret removes the row and leaves an empty list behind" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    const created = try createSecret(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .name = "GH",
        .value = "ghp_1",
    });
    defer freeSecretRow(alloc, created);
    try seed(alloc, &ctx, "ws_2", "GH");

    try deleteSecret(alloc, &ctx.db, "ws_1", created.id);

    const names = try listSecretNames(alloc, &ctx.db, "ws_1");
    defer freeSecretNames(alloc, names);
    try testing.expectEqual(@as(usize, 0), names.len);

    // The other workspace's identically named secret is untouched — the
    // DELETE was scoped, not global.
    const other = try listSecretNames(alloc, &ctx.db, "ws_2");
    defer freeSecretNames(alloc, other);
    try testing.expectEqual(@as(usize, 1), other.len);

    // Deleting again is NotFound, not a silent success.
    try testing.expectError(error.NotFound, deleteSecret(alloc, &ctx.db, "ws_1", created.id));
}

test "isValidName accepts the documented grammar and nothing else" {
    try testing.expect(isValidName("GITHUB_TOKEN"));
    try testing.expect(isValidName("gh-token-1"));
    try testing.expect(isValidName("a"));

    try testing.expect(!isValidName(""));
    try testing.expect(!isValidName("has space"));
    try testing.expect(!isValidName("emoji😀"));
    try testing.expect(!isValidName("a" ** (MAX_NAME_LEN + 1)));
}

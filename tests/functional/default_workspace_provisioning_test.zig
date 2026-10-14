// Functional tests for automatic per-user workspace provisioning. Zig port of
// `tests/functional/default_workspace_provisioning_test.py` (same test names,
// same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// Issue a request WITHOUT a status assertion — the caller asserts.
fn rawWithCookie(
    h: *Harness,
    method: harness.HttpMethod,
    path: []const u8,
    body: ?[]const u8,
    cookie: ?[]const u8,
) !harness.Response {
    var extra: [1]harness.Header = undefined;
    const n: usize = if (cookie) |c| blk: {
        extra[0] = .{ .name = "Cookie", .value = c };
        break :blk 1;
    } else 0;
    return h.http(io, method, path, .{
        .json_body = body,
        .extra_headers = extra[0..n],
        .assert_status = false,
    });
}

/// Boot a harness with `--auth` (provisioning is only visible behind the
/// gate, because the owner is resolved from the session cookie).
fn bootAuth() !Harness {
    return Harness.boot(io, gpa, .{ .extra_args = &.{"--auth"} });
}

/// Run `pabrik create-admin` against the harness HOME. `runPabrikCommand`
/// prepends the resolved binary itself, so `argv` starts at the SUBCOMMAND.
fn createAdmin(home: []const u8, email: []const u8, password: []const u8, force: bool) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "create-admin", "--email", email, "--password", password });
    if (force) try argv.append(gpa, "--force");

    var r = try harness.runPabrikCommand(io, gpa, home, argv.items, 60_000);
    defer r.deinit(gpa);
    if (r.exit_code == null or r.exit_code.? != 0) {
        std.debug.print("create-admin failed (rc={?}): {s}\n", .{ r.exit_code, r.stderr });
        return error.TestUnexpectedResult;
    }
}

/// `POST /api/auth/login` -> the raw session token (owned).
fn login(h: *Harness, email: []const u8, password: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"email\":\"{s}\",\"password\":\"{s}\"}}",
        .{ email, password },
    );
    defer gpa.free(body);

    var r = try rawWithCookie(h, .POST, "/api/auth/login", body, null);
    defer r.deinit();
    if (r.status != 200) {
        const excerpt = if (r.body.len > 500) r.body[0..500] else r.body;
        std.debug.print("login for {s} returned {d}: {s}\n", .{ email, r.status, excerpt });
        return error.TestUnexpectedResult;
    }

    const set_cookie = r.header("Set-Cookie") orelse "";
    if (std.mem.indexOf(u8, set_cookie, "pabrik_session=") == null) {
        std.debug.print("login sent no pabrik_session cookie: {s}\n", .{set_cookie});
        return error.TestUnexpectedResult;
    }
    // `set_cookie.split("pabrik_session=", 1)[1].split(";", 1)[0].strip()`:
    // the token is the text BETWEEN the name and the next `;`.
    var attrs = std.mem.splitSequence(u8, set_cookie, ";");
    const first_attr = attrs.next() orelse return error.TestUnexpectedResult;
    const token = std.mem.trim(u8, harness.afterFirst(first_attr, "pabrik_session=") orelse
        return error.TestUnexpectedResult, " \t\r\n");
    return gpa.dupe(u8, token);
}

/// `pabrik_session=<token>`. Owned.
fn cookieHeader(token: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "pabrik_session={s}", .{token});
}

/// One row of `GET /api/workspaces`, with the strings COPIED.
const WorkspaceRow = struct {
    id: []u8,
    name: []u8,

    fn deinit(self: *WorkspaceRow) void {
        gpa.free(self.id);
        gpa.free(self.name);
    }
};

/// Free a `WorkspaceRow` slice.
fn freeRows(rows: []WorkspaceRow) void {
    for (rows) |*r| r.deinit();
    gpa.free(rows);
}

/// The string at `key` of a JSON object, or a named failure.
fn strField(o: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (o.get(key) orelse {
        std.debug.print("missing `{s}` in a JSON object\n", .{key});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("`{s}` is not a string\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
}

/// `GET /api/workspaces` as owned rows. Python's `_workspaces`.
fn listWorkspaces(h: *Harness, token: []const u8) ![]WorkspaceRow {
    const cookie = try cookieHeader(token);
    defer gpa.free(cookie);

    var r = try rawWithCookie(h, .GET, "/api/workspaces", null, cookie);
    defer r.deinit();
    if (r.status != 200) {
        const excerpt = if (r.body.len > 500) r.body[0..500] else r.body;
        std.debug.print("GET /api/workspaces returned {d}: {s}\n", .{ r.status, excerpt });
        return error.TestUnexpectedResult;
    }
    var doc = try r.json();
    defer doc.deinit();

    const arr = doc.array("workspaces") orelse {
        std.debug.print("workspaces list has no `workspaces` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const rows = try gpa.alloc(WorkspaceRow, arr.items.len);
    errdefer freeRows(rows);
    for (arr.items, 0..) |item, i| {
        const o = switch (item) {
            .object => |m| m,
            else => {
                std.debug.print("workspace row {d} is not an object\n", .{i});
                return error.TestUnexpectedResult;
            },
        };
        rows[i] = .{
            .id = try gpa.dupe(u8, try strField(o, "id")),
            .name = try gpa.dupe(u8, try strField(o, "name")),
        };
    }
    return rows;
}

/// Render rows for a failure message without needing a `std.debug.print`
/// per row.
fn describeRows(rows: []const WorkspaceRow) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (rows, 0..) |r, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.print("{s}({s})", .{ r.name, r.id }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

// ─── sqlite3 CLI helpers ───────────────────────────────────────────────────

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// Skip unless a `sqlite3` CLI is present and speaks `-json`. `-json` landed
/// in SQLite 3.33 (2020).
fn requireSqlite3Cli() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-json", ":memory:", "SELECT 1 AS probe;" },
    }) catch |err| {
        std.debug.print("sqlite3 CLI unavailable ({s}); skipping DB assertions\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    if (code == null or code.? != 0 or std.mem.indexOf(u8, res.stdout, "\"probe\"") == null) {
        std.debug.print(
            "sqlite3 CLI lacks -json support (rc={?}, out={s}); skipping DB assertions\n",
            .{ code, res.stdout },
        );
        return error.SkipZigTest;
    }
}

/// `sqlite3 -json` prints ZERO BYTES for an empty result set, not `[]`.
fn parseSqliteJson(out: []const u8) !std.json.Parsed(std.json.Value) {
    if (std.mem.trim(u8, out, " \t\r\n").len == 0) {
        return std.json.parseFromSlice(std.json.Value, gpa, "[]", .{});
    }
    return std.json.parseFromSlice(std.json.Value, gpa, out, .{});
}

/// Single-quote `s` as an SQL literal, doubling embedded quotes. Owned.
fn sqlLit(s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    out.writer.writeByte('\'') catch return error.OutOfMemory;
    for (s) |c| {
        if (c == '\'') out.writer.writeByte('\'') catch return error.OutOfMemory;
        out.writer.writeByte(c) catch return error.OutOfMemory;
    }
    out.writer.writeByte('\'') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Run one statement against `db_path`, return the CLI's stdout (owned).
/// `.timeout 5000` is the `busy_timeout` the server's WAL connection needs; a
/// bare CLI invocation would otherwise fail with SQLITE_BUSY.
fn sqliteRun(db_path: []const u8, sql: []const u8) ![]u8 {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-cmd", ".timeout 5000", "-json", db_path, sql },
    }) catch |err| {
        std.debug.print("sqlite3 did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer gpa.free(res.stderr);

    const code = exitCode(res.term) orelse {
        gpa.free(res.stdout);
        std.debug.print("sqlite3 was killed by a signal: {any}\n", .{res.term});
        return error.TestUnexpectedResult;
    };
    if (code != 0) {
        const msg = res.stderr;
        defer gpa.free(res.stdout);
        std.debug.print("sqlite3 exited {d}: {s}\nsql: {s}\n", .{ code, msg, sql });
        return error.TestUnexpectedResult;
    }
    return res.stdout;
}

/// The agent DB inside the isolated tmpdir HOME (Linux/macOS layout).
fn dbPath(temp_dir: []const u8) ![]u8 {
    return harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
}

/// `SELECT id FROM users WHERE email = <lit>` -> owned id, or null.
fn userIdSql(temp_dir: []const u8, email: []const u8) !?[]u8 {
    const db = try dbPath(temp_dir);
    defer gpa.free(db);
    std.Io.Dir.cwd().access(io, db, .{}) catch {
        std.debug.print("db not found at {s}\n", .{db});
        return error.TestUnexpectedResult;
    };
    const lit = try sqlLit(email);
    defer gpa.free(lit);
    const sql = try std.fmt.allocPrint(gpa, "SELECT id FROM users WHERE email = {s}", .{lit});
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    defer gpa.free(out);
    var parsed = try parseSqliteJson(out);
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    if (arr.items.len == 0) return null;
    const o = switch (arr.items[0]) {
        .object => |m| m,
        else => return error.TestUnexpectedResult,
    };
    const id = switch (o.get("id") orelse return error.TestUnexpectedResult) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    return try gpa.dupe(u8, id);
}

/// One `workspace_members` row as `sqlite3 -json` spells it.
const Membership = struct {
    workspace_id: []u8,
    role: []u8,

    fn deinit(self: *Membership) void {
        gpa.free(self.workspace_id);
        gpa.free(self.role);
    }
};

/// `SELECT workspace_id, role FROM workspace_members WHERE user_id = ?`.
fn membersSql(temp_dir: []const u8, user_id: []const u8) ![]Membership {
    const db = try dbPath(temp_dir);
    defer gpa.free(db);
    const lit = try sqlLit(user_id);
    defer gpa.free(lit);
    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT workspace_id, role FROM workspace_members WHERE user_id = {s}",
        .{lit},
    );
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    defer gpa.free(out);
    var parsed = try parseSqliteJson(out);
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    const rows = try gpa.alloc(Membership, arr.items.len);
    errdefer {
        for (rows) |*r| r.deinit();
        gpa.free(rows);
    }
    for (arr.items, 0..) |item, i| {
        const o = switch (item) {
            .object => |m| m,
            else => return error.TestUnexpectedResult,
        };
        rows[i] = .{
            .workspace_id = try gpa.dupe(u8, switch (o.get("workspace_id") orelse
                return error.TestUnexpectedResult) {
                .string => |s| s,
                else => return error.TestUnexpectedResult,
            }),
            .role = try gpa.dupe(u8, switch (o.get("role") orelse
                return error.TestUnexpectedResult) {
                .string => |s| s,
                else => return error.TestUnexpectedResult,
            }),
        };
    }
    return rows;
}

fn freeMemberships(rows: []Membership) void {
    for (rows) |*r| r.deinit();
    gpa.free(rows);
}

// ============================================================================
// tests
// ============================================================================

// PROVISION — first login gives exactly one workspace named "Default",
// and it is a REAL row the owner is a member of (not a synthetic list
// entry the UI would 404 on when the user clicks it).
test "a_fresh_user_is_given_a_workspace_named_default" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "fresh@example.com", "supersecret123", false);

    const token = try login(&h, "fresh@example.com", "supersecret123");
    defer gpa.free(token);

    const rows = try listWorkspaces(&h, token);
    defer freeRows(rows);
    if (rows.len != 1) {
        const desc = try describeRows(rows);
        defer gpa.free(desc);
        std.debug.print("expected exactly one provisioned workspace, got: {s}\n", .{desc});
        return error.TestUnexpectedResult;
    }
    if (!std.mem.eql(u8, rows[0].name, "Default")) {
        std.debug.print("provisioned workspace is named \"{s}\", expected \"Default\"\n", .{rows[0].name});
        return error.TestUnexpectedResult;
    }

    const user_id = (try userIdSql(h.temp_dir, "fresh@example.com")) orelse {
        std.debug.print("no users row for fresh@example.com\n", .{});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(user_id);

    const members = try membersSql(h.temp_dir, user_id);
    defer freeMemberships(members);
    if (members.len != 1) {
        std.debug.print("expected exactly one workspace_members row, got {d}\n", .{members.len});
        return error.TestUnexpectedResult;
    }
    if (!std.mem.eql(u8, members[0].workspace_id, rows[0].id)) {
        std.debug.print(
            "membership is on {s}, not the provisioned workspace {s}\n",
            .{ members[0].workspace_id, rows[0].id },
        );
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("owner", members[0].role);
}

// WITH-PROJECT — an empty Projects list inside the new workspace is the
// same dead end one level down, so it ships with its default.
test "the_provisioned_workspace_already_has_a_default_project" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "proj@example.com", "supersecret123", false);

    const token = try login(&h, "proj@example.com", "supersecret123");
    defer gpa.free(token);

    const rows = try listWorkspaces(&h, token);
    defer freeRows(rows);
    if (rows.len == 0) {
        std.debug.print("no workspace was provisioned for proj@example.com\n", .{});
        return error.TestUnexpectedResult;
    }
    const ws_id = rows[0].id;

    const cookie = try cookieHeader(token);
    defer gpa.free(cookie);
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items", .{ws_id});
    defer gpa.free(path);

    var r = try rawWithCookie(&h, .GET, path, null, cookie);
    defer r.deinit();
    if (r.status != 200) {
        const excerpt = if (r.body.len > 500) r.body[0..500] else r.body;
        std.debug.print("GET items returned {d}: {s}\n", .{ r.status, excerpt });
        return error.TestUnexpectedResult;
    }
    var doc = try r.json();
    defer doc.deinit();

    const items = doc.array("items") orelse {
        std.debug.print("items list has no `items` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (items.items.len != 1) {
        std.debug.print("expected exactly one default project, got {d}\n", .{items.items.len});
        return error.TestUnexpectedResult;
    }
    const item = switch (items.items[0]) {
        .object => |m| m,
        else => return error.TestUnexpectedResult,
    };
    // `is_default` is 0/1 on the wire, not a JSON boolean — the same
    // contract sidebar_new_chat_default_project_test.py pins.
    const is_default = switch (item.get("is_default") orelse {
        std.debug.print("default project has no `is_default`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .integer => |i| i,
        else => {
            std.debug.print("`is_default` is not an integer: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expect(is_default == 0 or is_default == 1);
    try testing.expectEqual(@as(i64, 1), is_default);

    // Its path is the server user's home, which is what makes a chat
    // started here resolve a cwd instead of failing.
    const path_value = switch (item.get("path") orelse {
        std.debug.print("default project has no `path`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("`path` is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    if (path_value.len == 0) {
        std.debug.print("default project has an empty `path`\n", .{});
        return error.TestUnexpectedResult;
    }
}

// IDEMPOTENT — a login that re-provisions is a workspace that multiplies
// on every page refresh.
test "logging_in_again_adds_nothing" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "again@example.com", "supersecret123", false);

    const token = try login(&h, "again@example.com", "supersecret123");
    defer gpa.free(token);

    const first = try listWorkspaces(&h, token);
    defer freeRows(first);
    try testing.expectEqual(@as(usize, 1), first.len);

    // Second and third login must be no-ops.
    {
        const again = try login(&h, "again@example.com", "supersecret123");
        gpa.free(again);
    }
    {
        const again = try login(&h, "again@example.com", "supersecret123");
        gpa.free(again);
    }

    const after = try listWorkspaces(&h, token);
    defer freeRows(after);
    try testing.expectEqual(@as(usize, 1), after.len);
    if (!std.mem.eql(u8, after[0].id, first[0].id)) {
        std.debug.print(
            "re-login changed the workspace id: {s} -> {s}\n",
            .{ first[0].id, after[0].id },
        );
        return error.TestUnexpectedResult;
    }
}

// A user who already made a workspace keeps exactly what they made —
// provisioning does not add a second "Default".
test "a_user_who_created_a_workspace_keeps_exactly_what_they_made" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "maker@example.com", "supersecret123", false);

    const token = try login(&h, "maker@example.com", "supersecret123");
    defer gpa.free(token);

    {
        const before = try listWorkspaces(&h, token);
        defer freeRows(before);
        try testing.expectEqual(@as(usize, 1), before.len);
    }

    // Create a second workspace.
    const mine_id = blk: {
        const cookie = try cookieHeader(token);
        defer gpa.free(cookie);
        var r = try rawWithCookie(&h, .POST, "/api/workspaces", "{\"name\":\"Client Project\"}", cookie);
        defer r.deinit();
        if (r.status != 201) {
            const excerpt = if (r.body.len > 500) r.body[0..500] else r.body;
            std.debug.print("POST /api/workspaces returned {d}: {s}\n", .{ r.status, excerpt });
            return error.TestUnexpectedResult;
        }
        var doc = try r.json();
        defer doc.deinit();
        break :blk try gpa.dupe(u8, doc.str("id") orelse {
            std.debug.print("workspace create returned no id: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
    };
    defer gpa.free(mine_id);

    {
        const again = try login(&h, "maker@example.com", "supersecret123");
        gpa.free(again);
    }

    const rows = try listWorkspaces(&h, token);
    defer freeRows(rows);

    // sorted(names) == ["Client Project", "Default"]
    var has_default = false;
    var has_client = false;
    for (rows) |row| {
        if (std.mem.eql(u8, row.name, "Default")) has_default = true;
        if (std.mem.eql(u8, row.name, "Client Project")) has_client = true;
    }
    if (!has_default or !has_client or rows.len != 2) {
        const desc = try describeRows(rows);
        defer gpa.free(desc);
        std.debug.print("expected exactly [Client Project, Default], got: {s}\n", .{desc});
        return error.TestUnexpectedResult;
    }

    var found_mine = false;
    for (rows) |row| {
        if (std.mem.eql(u8, row.id, mine_id)) found_mine = true;
    }
    if (!found_mine) {
        std.debug.print("the created workspace {s} is missing from the list\n", .{mine_id});
        return error.TestUnexpectedResult;
    }
}

// PER-USER — a second admin gets their OWN Default, and Bob's list is
// his alone.
test "a_second_admin_gets_their_own_default_not_the_first_ones" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "alice@example.com", "supersecret123", false);
    try createAdmin(h.temp_dir, "bob@example.com", "supersecret123", true);

    const alice = try login(&h, "alice@example.com", "supersecret123");
    defer gpa.free(alice);
    const bob = try login(&h, "bob@example.com", "supersecret123");
    defer gpa.free(bob);

    const alice_ws = try listWorkspaces(&h, alice);
    defer freeRows(alice_ws);
    const bob_ws = try listWorkspaces(&h, bob);
    defer freeRows(bob_ws);

    if (alice_ws.len != 1 or !std.mem.eql(u8, alice_ws[0].name, "Default")) {
        const desc = try describeRows(alice_ws);
        defer gpa.free(desc);
        std.debug.print("alice should see exactly [Default], got: {s}\n", .{desc});
        return error.TestUnexpectedResult;
    }
    if (bob_ws.len != 1 or !std.mem.eql(u8, bob_ws[0].name, "Default")) {
        const desc = try describeRows(bob_ws);
        defer gpa.free(desc);
        std.debug.print("bob should see exactly [Default], got: {s}\n", .{desc});
        return error.TestUnexpectedResult;
    }

    // Bob's list is his alone: Alice's row is not in it.
    if (std.mem.eql(u8, alice_ws[0].id, bob_ws[0].id)) {
        std.debug.print(
            "bob was handed alice's workspace {s} — per-user provisioning leaked\n",
            .{alice_ws[0].id},
        );
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = rawWithCookie;
    _ = bootAuth;
    _ = createAdmin;
    _ = login;
    _ = cookieHeader;
    _ = WorkspaceRow.deinit;
    _ = freeRows;
    _ = strField;
    _ = listWorkspaces;
    _ = describeRows;
    _ = exitCode;
    _ = requireSqlite3Cli;
    _ = parseSqliteJson;
    _ = sqlLit;
    _ = sqliteRun;
    _ = dbPath;
    _ = userIdSql;
    _ = Membership.deinit;
    _ = membersSql;
    _ = freeMemberships;
}

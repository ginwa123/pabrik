// Wire-level proof that workspace visibility is driven by
// `workspace_members`.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Wire helpers
// ============================================================================

/// Issue a request WITHOUT a status assertion — the caller asserts. Python's
/// `_raw` was the suite's private HTTP client.
fn rawHttp(
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

/// `POST /api/auth/login` -> the raw session token (owned).
fn login(h: *Harness, email: []const u8, password: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"email\":\"{s}\",\"password\":\"{s}\"}}",
        .{ email, password },
    );
    defer gpa.free(body);

    var r = try rawHttp(h, .POST, "/api/auth/login", body, null);
    defer r.deinit();
    if (r.status != 200) {
        const excerpt = if (r.body.len > 500) r.body[0..500] else r.body;
        std.debug.print("login for {s} returned {d}: {s}\n", .{ email, r.status, excerpt });
        return error.TestUnexpectedResult;
    }

    const set_cookie = r.header("Set-Cookie") orelse {
        std.debug.print("login for {s} sent no Set-Cookie: {s}\n", .{ email, r.body });
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, set_cookie, "pabrik_session=") == null) {
        std.debug.print("login cookie carries no session: {s}\n", .{set_cookie});
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

/// `POST /api/workspaces` with `name`; returns the new id (owned).
fn createWorkspace(h: *Harness, name: []const u8, cookie: ?[]const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);

    var r = try rawHttp(h, .POST, "/api/workspaces", body, cookie);
    defer r.deinit();
    if (r.status != 201) {
        const excerpt = if (r.body.len > 500) r.body[0..500] else r.body;
        std.debug.print("POST /api/workspaces returned {d}: {s}\n", .{ r.status, excerpt });
        return error.TestUnexpectedResult;
    }
    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `GET /api/workspaces?is_include_items=false` -> every visible id. Owned
/// slices: a `harness.Json` borrows its `Response` body, so the ids are duped
/// before the response is released.
fn listWorkspaceIds(h: *Harness, cookie: ?[]const u8) ![][]u8 {
    var r = try rawHttp(h, .GET, "/api/workspaces", null, cookie);
    defer r.deinit();
    if (r.status != 200) {
        const excerpt = if (r.body.len > 500) r.body[0..500] else r.body;
        std.debug.print("GET /api/workspaces returned {d}: {s}\n", .{ r.status, excerpt });
        return error.TestUnexpectedResult;
    }
    {
        var doc = try r.json();
        defer doc.deinit();
        const arr = doc.array("workspaces") orelse {
            std.debug.print("workspaces list has no `workspaces` array: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        const ids = try gpa.alloc([]u8, arr.items.len);
        errdefer {
            for (ids) |id| gpa.free(id);
            gpa.free(ids);
        }
        for (arr.items, 0..) |item, i| {
            const o = switch (item) {
                .object => |m| m,
                else => {
                    std.debug.print("workspace row {d} is not an object\n", .{i});
                    return error.TestUnexpectedResult;
                },
            };
            const id = switch (o.get("id") orelse {
                std.debug.print("workspace row {d} has no id\n", .{i});
                return error.TestUnexpectedResult;
            }) {
                .string => |s| s,
                else => {
                    std.debug.print("workspace row {d} id is not a string\n", .{i});
                    return error.TestUnexpectedResult;
                },
            };
            ids[i] = try gpa.dupe(u8, id);
        }
        return ids;
    }
}

fn freeIds(ids: [][]u8) void {
    for (ids) |id| gpa.free(id);
    gpa.free(ids);
}

/// Python's `ws in _list_workspace_ids(...)`.
fn containsId(ids: []const []u8, want: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, want)) return true;
    }
    return false;
}

/// `pabrik create-admin` against the harness HOME. `runPabrikCommand`
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

/// Auth mode, two admins, ONE database — Python's `_two_users`. A STRUCT
/// rather than a function returning a tuple, because the harness must be torn
/// down by whoever owns the `defer`, and Zig has no `finally`.
const TwoUsers = struct {
    h: Harness,
    tok_a: []u8,
    tok_b: []u8,

    fn init() !TwoUsers {
        var h = try Harness.boot(io, gpa, .{ .extra_args = &.{"--auth"} });
        errdefer h.deinit(io) catch {};

        try createAdmin(h.temp_dir, "a@example.com", "supersecret123", false);
        try createAdmin(h.temp_dir, "b@example.com", "supersecret123", true);

        const tok_a = try login(&h, "a@example.com", "supersecret123");
        errdefer gpa.free(tok_a);
        const tok_b = try login(&h, "b@example.com", "supersecret123");

        return .{ .h = h, .tok_a = tok_a, .tok_b = tok_b };
    }

    /// LIFO note: the tokens are freed AFTER `h.deinit` has run, and
    /// `h.deinit` is the only thing that reads the harness — so the
    /// frees are registered first.
    fn deinit(self: *TwoUsers) void {
        self.h.deinit(io) catch |err| {
            std.debug.print("teardown: {s}\n", .{@errorName(err)});
        };
        gpa.free(self.tok_a);
        gpa.free(self.tok_b);
    }
};

// ============================================================================
// DB helpers — the membership row is the unit of sharing, so assert on it
// ============================================================================

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

/// Run statements against `db_path`, return the CLI's stdout (owned).
/// `.timeout 5000` is the `busy_timeout` the server's WAL connection needs; a
/// bare CLI invocation would otherwise fail with SQLITE_BUSY.
fn sqliteRun(db_path: []const u8, sql: []const u8) ![]u8 {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-cmd", ".timeout 10000", "-json", db_path, sql },
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

/// The agent DB inside the isolated tmpdir HOME.
///
/// Python: `Path(h.temp_dir) / ".config" / "pabrik" / "agent.db"`.
fn dbPath(temp_dir: []const u8) ![]u8 {
    return harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
}

/// Python's `_db_connect`: the CLI replaces the connection, and the
/// `p.exists()` assertion becomes an `access` check here.
fn requireDb(temp_dir: []const u8) ![]u8 {
    const db = try dbPath(temp_dir);
    errdefer gpa.free(db);
    std.Io.Dir.cwd().access(io, db, .{}) catch {
        std.debug.print("database not found at {s}\n", .{db});
        return error.TestUnexpectedResult;
    };
    return db;
}

/// `SELECT id FROM users WHERE email = <lit>` -> owned id, or null.
fn userIdSql(temp_dir: []const u8, email: []const u8) !?[]u8 {
    const db = try requireDb(temp_dir);
    defer gpa.free(db);
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
    user_id: []u8,
    role: []u8,

    fn deinit(self: *Membership) void {
        gpa.free(self.user_id);
        gpa.free(self.role);
    }
};

fn freeMemberships(rows: []Membership) void {
    for (rows) |*r| r.deinit();
    gpa.free(rows);
}

/// `SELECT user_id, role FROM workspace_members WHERE workspace_id = ?
/// ORDER BY user_id` — Python's `_members_of`.
fn membersOf(temp_dir: []const u8, workspace_id: []const u8) ![]Membership {
    const db = try requireDb(temp_dir);
    defer gpa.free(db);
    const lit = try sqlLit(workspace_id);
    defer gpa.free(lit);
    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT user_id, role FROM workspace_members WHERE workspace_id = {s} ORDER BY user_id",
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
            else => {
                std.debug.print("membership row {d} is not an object\n", .{i});
                return error.TestUnexpectedResult;
            },
        };
        rows[i] = .{
            .user_id = try gpa.dupe(u8, switch (o.get("user_id") orelse
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

/// Render `[(uid, role), ...]` for a failure message.
fn describeMembers(rows: []const Membership) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (rows, 0..) |m, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.print("({s}, {s})", .{ m.user_id, m.role }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

/// The membership list equals exactly one row: `(user_id, role)`.
fn expectMembers(rows: []const Membership, want_user: []const u8, want_role: []const u8) !void {
    if (rows.len != 1 or
        !std.mem.eql(u8, rows[0].user_id, want_user) or
        !std.mem.eql(u8, rows[0].role, want_role))
    {
        const desc = try describeMembers(rows);
        defer gpa.free(desc);
        std.debug.print(
            "expected exactly one membership ({s}, {s}), got {d}: [{s}]\n",
            .{ want_user, want_role, rows.len, desc },
        );
        return error.TestUnexpectedResult;
    }
}

/// Python's `_add_member`: a direct INSERT, because the
/// `/api/workspaces/:id/members` endpoints are out of scope for this
/// change (they were a follow-up in the plan).
fn addMember(temp_dir: []const u8, workspace_id: []const u8, user_id: []const u8, role: []const u8) !void {
    const db = try requireDb(temp_dir);
    defer gpa.free(db);
    const w = try sqlLit(workspace_id);
    defer gpa.free(w);
    const u = try sqlLit(user_id);
    defer gpa.free(u);
    const r = try sqlLit(role);
    defer gpa.free(r);
    const sql = try std.fmt.allocPrint(
        gpa,
        "INSERT OR IGNORE INTO workspace_members (workspace_id, user_id, role) VALUES ({s}, {s}, {s})",
        .{ w, u, r },
    );
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    gpa.free(out);
}

/// Assert that `id` IS (or is NOT) in a cookie-scoped workspace list.
fn expectListed(
    h: *Harness,
    cookie: ?[]const u8,
    id: []const u8,
    listed: bool,
) !void {
    const ids = try listWorkspaceIds(h, cookie);
    defer freeIds(ids);
    const got = containsId(ids, id);
    if (got != listed) {
        std.debug.print(
            "workspace {s} listed = {any}, expected {any}\n",
            .{ id, got, listed },
        );
        return error.TestUnexpectedResult;
    }
}

/// Assert the status of `GET /api/workspaces/<id>` without asserting on
/// the body (Python's `(status, _, _)` reads).
fn expectGetStatus(h: *Harness, cookie: ?[]const u8, id: []const u8, want: u16) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}", .{id});
    defer gpa.free(path);
    var r = try rawHttp(h, .GET, path, null, cookie);
    defer r.deinit();
    if (r.status != want) {
        const excerpt = if (r.body.len > 500) r.body[0..500] else r.body;
        std.debug.print(
            "GET {s} returned {d}, expected {d}: {s}\n",
            .{ path, r.status, want, excerpt },
        );
        return error.TestUnexpectedResult;
    }
}

/// `GET /api/workspaces/<id>` must answer 200 AND carry the expected
/// name — Python read the body and asserted `name`.
fn expectGetNamed(h: *Harness, cookie: ?[]const u8, id: []const u8, want_name: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}", .{id});
    defer gpa.free(path);
    var r = try rawHttp(h, .GET, path, null, cookie);
    defer r.deinit();
    if (r.status != 200) {
        const excerpt = if (r.body.len > 500) r.body[0..300] else r.body;
        std.debug.print("GET {s} returned {d}: {s}\n", .{ path, r.status, excerpt });
        return error.TestUnexpectedResult;
    }
    var doc = try r.json();
    defer doc.deinit();
    const name = doc.str("name") orelse {
        std.debug.print("GET {s} returned no `name`: {s}\n", .{ path, r.body });
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, name, want_name)) {
        std.debug.print(
            "GET {s} name = \"{s}\", expected \"{s}\"\n",
            .{ path, name, want_name },
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 1: the create transaction writes the membership row
// ============================================================================

// The create tx must commit the membership row too, or nobody sees it.
test "create_writes_a_membership_row_for_the_real_user" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var t = try TwoUsers.init();
    defer t.deinit();

    const cookie_a = try cookieHeader(t.tok_a);
    defer gpa.free(cookie_a);

    const ws = try createWorkspace(&t.h, "A private", cookie_a);
    defer gpa.free(ws);

    const uid_a = (try userIdSql(t.h.temp_dir, "a@example.com")) orelse {
        std.debug.print("no users row for a@example.com\n", .{});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(uid_a);

    const members = try membersOf(t.h.temp_dir, ws);
    defer freeMemberships(members);
    try expectMembers(members, uid_a, "owner");

    // And the wire agrees: the creator still sees it.
    try expectListed(&t.h, cookie_a, ws, true);
}

// ============================================================================
// Test 2: auth-off create stores the sentinel membership
// ============================================================================

// Auth off -> owner resolves to the sentinel, and the row must land anyway.
test "auth_off_create_stores_the_sentinel_membership" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    // Python passed `""` as the cookie for the auth-off case; here
    // `null` is passed so NO cookie header is sent at all, which is
    // what the server actually sees with `--auth` off.
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "No-auth workspace", null);
    defer gpa.free(ws);
    try expectListed(&h, null, ws, true);

    const members = try membersOf(h.temp_dir, ws);
    defer freeMemberships(members);
    try expectMembers(members, "user_system", "owner");
}

// ============================================================================
// Test 3: one membership row is the entire difference
// ============================================================================

// The feature: one membership row is the entire difference. A's workspace is
// private, so B gets a 404 and never sees it in the list.
test "shared_workspace_becomes_visible_to_the_second_user" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var t = try TwoUsers.init();
    defer t.deinit();

    const cookie_a = try cookieHeader(t.tok_a);
    defer gpa.free(cookie_a);
    const cookie_b = try cookieHeader(t.tok_b);
    defer gpa.free(cookie_b);

    const ws = try createWorkspace(&t.h, "A shares this", cookie_a);
    defer gpa.free(ws);
    const uid_b = (try userIdSql(t.h.temp_dir, "b@example.com")) orelse {
        std.debug.print("no users row for b@example.com\n", .{});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(uid_b);

    // Before: private.
    try expectListed(&t.h, cookie_b, ws, false);
    try expectGetStatus(&t.h, cookie_b, ws, 404);

    try addMember(t.h.temp_dir, ws, uid_b, "editor");

    // After: visible, on every read path.
    try expectListed(&t.h, cookie_b, ws, true);
    try expectGetNamed(&t.h, cookie_b, ws, "A shares this");

    // The child routes are gated by the middleware choke point, so they
    // must open up too — otherwise sharing half-works.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items", .{ws});
        defer gpa.free(path);
        var r = try rawHttp(&t.h, .GET, path, null, cookie_b);
        defer r.deinit();
        if (r.status != 200) {
            const excerpt = if (r.body.len > 500) r.body[0..300] else r.body;
            std.debug.print(
                "a member must reach the workspace's items, got {d}: {s}\n",
                .{ r.status, excerpt },
            );
            return error.TestUnexpectedResult;
        }
    }

    // And the owner is unaffected by B being added.
    try expectListed(&t.h, cookie_a, ws, true);
}

// ============================================================================
// Test 4: sharing is not a one-way door
// ============================================================================

test "removing_a_membership_revokes_access" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var t = try TwoUsers.init();
    defer t.deinit();

    const cookie_a = try cookieHeader(t.tok_a);
    defer gpa.free(cookie_a);
    const cookie_b = try cookieHeader(t.tok_b);
    defer gpa.free(cookie_b);

    const ws = try createWorkspace(&t.h, "Temporary share", cookie_a);
    defer gpa.free(ws);
    const uid_b = (try userIdSql(t.h.temp_dir, "b@example.com")) orelse {
        std.debug.print("no users row for b@example.com\n", .{});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(uid_b);

    try addMember(t.h.temp_dir, ws, uid_b, "viewer");
    try expectListed(&t.h, cookie_b, ws, true);

    // Python's direct DELETE through the connection.
    {
        const db = try requireDb(t.h.temp_dir);
        defer gpa.free(db);
        const w = try sqlLit(ws);
        defer gpa.free(w);
        const u = try sqlLit(uid_b);
        defer gpa.free(u);
        const sql = try std.fmt.allocPrint(
            gpa,
            "DELETE FROM workspace_members WHERE workspace_id = {s} AND user_id = {s}",
            .{ w, u },
        );
        defer gpa.free(sql);
        const out = try sqliteRun(db, sql);
        gpa.free(out);
    }

    try expectListed(&t.h, cookie_b, ws, false);
    try expectGetStatus(&t.h, cookie_b, ws, 404);

    // The workspace itself is untouched — nothing was left behind on the
    // workspaces row that would keep re-granting access.
    try expectListed(&t.h, cookie_a, ws, true);
}

// ============================================================================
// Test 5: the upgrade regression
// ============================================================================

// The sentinel membership keeps a legacy workspace visible to everyone. The
// upgrade regression: an operator must not lose their sidebar. A workspace
// created before `--auth` was switched on carries no real owner.
test "the_sentinel_membership_keeps_a_legacy_workspace_visible_to_everyone" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var t = try TwoUsers.init();
    defer t.deinit();

    const cookie_a = try cookieHeader(t.tok_a);
    defer gpa.free(cookie_a);
    const cookie_b = try cookieHeader(t.tok_b);
    defer gpa.free(cookie_b);

    const ws = try createWorkspace(&t.h, "Pre-auth legacy", cookie_a);
    defer gpa.free(ws);
    const uid_a = (try userIdSql(t.h.temp_dir, "a@example.com")) orelse {
        std.debug.print("no users row for a@example.com\n", .{});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(uid_a);

    // Rewrite A's membership to exactly what the backfill emits for a
    // user_system-owned workspace: one sentinel row, owner role.
    {
        const db = try requireDb(t.h.temp_dir);
        defer gpa.free(db);
        const w = try sqlLit(ws);
        defer gpa.free(w);
        const sql = try std.fmt.allocPrint(
            gpa,
            \\DELETE FROM workspace_members WHERE workspace_id = {s};
            \\INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ({s}, 'user_system', 'owner');
        ,
            .{ w, w },
        );
        defer gpa.free(sql);
        const out = try sqliteRun(db, sql);
        gpa.free(out);
    }
    {
        const members = try membersOf(t.h.temp_dir, ws);
        defer freeMemberships(members);
        try expectMembers(members, "user_system", "owner");
    }

    // A real, unrelated user now sees it.
    try expectListed(&t.h, cookie_b, ws, true);
    try expectGetStatus(&t.h, cookie_b, ws, 200);

    // The original owner keeps access too.
    try expectListed(&t.h, cookie_a, ws, true);
    // Python kept `uid_a` alive with a bare `assert uid_a`; here the
    // lookup above already proved it is non-empty, and the `defer`
    // above is what keeps the port leak-free.
}

// ============================================================================
// Test 6: delete cleans up the membership rows
// ============================================================================

// No orphans: `PRAGMA foreign_keys` is OFF, so delete must clean up.
test "delete_removes_the_membership_rows" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var t = try TwoUsers.init();
    defer t.deinit();

    const cookie_a = try cookieHeader(t.tok_a);
    defer gpa.free(cookie_a);

    const ws = try createWorkspace(&t.h, "Doomed", cookie_a);
    defer gpa.free(ws);
    const uid_b = (try userIdSql(t.h.temp_dir, "b@example.com")) orelse {
        std.debug.print("no users row for b@example.com\n", .{});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(uid_b);

    try addMember(t.h.temp_dir, ws, uid_b, "viewer");
    {
        const before = try membersOf(t.h.temp_dir, ws);
        defer freeMemberships(before);
        if (before.len != 2) {
            const desc = try describeMembers(before);
            defer gpa.free(desc);
            std.debug.print("expected two membership rows before the delete, got: [{s}]\n", .{desc});
            return error.TestUnexpectedResult;
        }
    }

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}", .{ws});
    defer gpa.free(path);
    {
        var r = try rawHttp(&t.h, .DELETE, path, null, cookie_a);
        defer r.deinit();
        if (r.status != 200) {
            const excerpt = if (r.body.len > 500) r.body[0..500] else r.body;
            std.debug.print("owner must be able to delete, got {d}: {s}\n", .{ r.status, excerpt });
            return error.TestUnexpectedResult;
        }
    }

    const after = try membersOf(t.h.temp_dir, ws);
    defer freeMemberships(after);
    if (after.len != 0) {
        const desc = try describeMembers(after);
        defer gpa.free(desc);
        std.debug.print("member rows survived the delete: [{s}]\n", .{desc});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 7: Migration 100 is WIRED, not merely callable
// ============================================================================

// Prove Migration 100 is WIRED, not merely callable.
test "migration_100_actually_runs_on_a_real_boot" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const db = try requireDb(h.temp_dir);
    defer gpa.free(db);

    // 1. The table exists, with the composite primary key.
    {
        const sql =
            \\SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'workspace_members'
        ;
        const out = try sqliteRun(db, sql);
        defer gpa.free(out);
        var parsed = try parseSqliteJson(out);
        defer parsed.deinit();
        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return error.TestUnexpectedResult,
        };
        if (arr.items.len == 0) {
            std.debug.print("workspace_members does not exist after a real boot\n", .{});
            return error.TestUnexpectedResult;
        }
        const o = switch (arr.items[0]) {
            .object => |m| m,
            else => return error.TestUnexpectedResult,
        };
        const ddl = switch (o.get("sql") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (std.mem.indexOf(u8, ddl, "PRIMARY KEY (workspace_id, user_id)") == null) {
            std.debug.print("workspace_members has no composite primary key: {s}\n", .{ddl});
            return error.TestUnexpectedResult;
        }
    }

    // 2. The user_id direction index is present exactly once.
    {
        const sql =
            \\SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'index' AND name = 'idx_workspace_members_user'
        ;
        const out = try sqliteRun(db, sql);
        defer gpa.free(out);
        var parsed = try parseSqliteJson(out);
        defer parsed.deinit();
        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return error.TestUnexpectedResult,
        };
        const o = switch (arr.items[0]) {
            .object => |m| m,
            else => return error.TestUnexpectedResult,
        };
        const n = switch (o.get("n") orelse return error.TestUnexpectedResult) {
            .integer => |i| i,
            else => return error.TestUnexpectedResult,
        };
        if (n != 1) {
            std.debug.print("the user_id direction index count = {d}, expected 1\n", .{n});
            return error.TestUnexpectedResult;
        }
    }

    // 3. And recorded in the ledger, not merely applied — this is the
    // table the migration runner uses to skip work on the next boot.
    {
        const sql = "SELECT name FROM schema_migrations WHERE version = 100";
        const out = try sqliteRun(db, sql);
        defer gpa.free(out);
        var parsed = try parseSqliteJson(out);
        defer parsed.deinit();
        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return error.TestUnexpectedResult,
        };
        if (arr.items.len == 0) {
            std.debug.print("migration 100 is not recorded in schema_migrations\n", .{});
            return error.TestUnexpectedResult;
        }
        const o = switch (arr.items[0]) {
            .object => |m| m,
            else => return error.TestUnexpectedResult,
        };
        const name = switch (o.get("name") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (!std.mem.eql(u8, name, "add_workspace_members")) {
            std.debug.print("unexpected ledger name: \"{s}\"\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = rawHttp;
    _ = login;
    _ = cookieHeader;
    _ = createWorkspace;
    _ = listWorkspaceIds;
    _ = freeIds;
    _ = containsId;
    _ = createAdmin;
    _ = TwoUsers.init;
    _ = TwoUsers.deinit;
    _ = exitCode;
    _ = requireSqlite3Cli;
    _ = parseSqliteJson;
    _ = sqlLit;
    _ = sqliteRun;
    _ = dbPath;
    _ = requireDb;
    _ = userIdSql;
    _ = Membership.deinit;
    _ = freeMemberships;
    _ = membersOf;
    _ = describeMembers;
    _ = expectMembers;
    _ = addMember;
    _ = expectListed;
    _ = expectGetStatus;
    _ = expectGetNamed;
}

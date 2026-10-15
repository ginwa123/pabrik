// Functional tests for per-user workspace isolation (plan 2026-09-25, W1 +
// W2.1).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// The session cookie's name, as `Set-Cookie` spells it.
const COOKIE_NAME = "pabrik_session=";

/// Every user in this suite shares one password, exactly as in the
/// Python original — the variable under test is the IDENTITY, not the
/// secret.
const PASSWORD = "supersecret123";

// ============================================================================
// Helpers
// ============================================================================

/// Issue a request WITHOUT a status assertion — the caller asserts. `cookie`
/// is the raw `Cookie:` header value (`pabrik_session=<tok>`), or null for no
/// cookie at all.
fn rawHttp(
    h: *Harness,
    method: harness.HttpMethod,
    path: []const u8,
    body: ?[]const u8,
    cookie: ?[]const u8,
) !harness.Response {
    var extra: [1]harness.Header = undefined;
    const n: usize = if (cookie) |c| blk: {
        if (c.len == 0) break :blk 0;
        extra[0] = .{ .name = "Cookie", .value = c };
        break :blk 1;
    } else 0;
    return h.http(io, method, path, .{
        .json_body = body,
        .extra_headers = extra[0..n],
        .assert_status = false,
    });
}

/// Boot a harness with `--auth` (the gate is opt-in).
fn bootAuth() !Harness {
    return Harness.boot(io, gpa, .{ .extra_args = &.{"--auth"} });
}

/// Run `pabrik create-admin` against the harness HOME. `runPabrikCommand`
/// prepends the resolved binary itself, so `argv` starts at the SUBCOMMAND.
fn createAdmin(home: []const u8, email: []const u8, force: bool) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "create-admin", "--email", email, "--password", PASSWORD });
    if (force) try argv.append(gpa, "--force");

    var r = try harness.runPabrikCommand(io, gpa, home, argv.items, 30_000);
    defer r.deinit(gpa);
    if (r.exit_code == null or r.exit_code.? != 0) {
        std.debug.print("create-admin {s} failed (rc={?}): {s}\n", .{ email, r.exit_code, r.stderr });
        return error.TestUnexpectedResult;
    }
}

/// `POST /api/auth/login` -> the raw session token (owned).
fn login(h: *Harness, email: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"email\":\"{s}\",\"password\":\"{s}\"}}",
        .{ email, PASSWORD },
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
        std.debug.print("login for {s} sent no Set-Cookie\n", .{email});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, set_cookie, COOKIE_NAME) == null) {
        std.debug.print("Set-Cookie does not carry {s}: {s}\n", .{ COOKIE_NAME, set_cookie });
        return error.TestUnexpectedResult;
    }

    // The token is the SEGMENT between `pabrik_session=` and the next `;` —
    // Python's `set_cookie.split("pabrik_session=", 1)[1].split(";",
    // 1)[0].strip()`.
    var attrs = std.mem.splitSequence(u8, set_cookie, ";");
    const first_attr = attrs.next() orelse return error.TestUnexpectedResult;
    const token = std.mem.trim(
        u8,
        harness.afterFirst(first_attr, COOKIE_NAME) orelse return error.TestUnexpectedResult,
        " \t\r\n",
    );
    return gpa.dupe(u8, token);
}

/// The two tokens for the two admins, as raw `Cookie:` header values.
const TwoTokens = struct {
    a: []u8,
    b: []u8,

    fn deinit(self: *TwoTokens) void {
        gpa.free(self.a);
        gpa.free(self.b);
        self.* = undefined;
    }
};

/// Boot auth mode with two admins in the SAME server process and log
/// both in. Python's `_two_users`, minus the returned harness.
fn twoUsers(h: *Harness) !TwoTokens {
    try createAdmin(h.temp_dir, "a@example.com", false);
    try createAdmin(h.temp_dir, "b@example.com", true);

    const a = try login(h, "a@example.com");
    errdefer gpa.free(a);
    const b = try login(h, "b@example.com");
    errdefer gpa.free(b);
    return .{ .a = a, .b = b };
}

/// `POST /api/workspaces {"name": ...}` → the new workspace's id. Owned.
///
/// `cookie` null means "no cookie at all", which is the auth-off case.
fn createWorkspace(h: *Harness, name: []const u8, cookie: ?[]const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
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
    return gpa.dupe(u8, doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    });
}

/// `GET /api/workspaces?is_include_items=false` → the visible workspace ids,
/// as OWNED strings.
fn listWorkspaceIds(h: *Harness, cookie: ?[]const u8) ![][]u8 {
    var r = try rawHttp(h, .GET, "/api/workspaces", null, cookie);
    defer r.deinit();
    if (r.status != 200) {
        const excerpt = if (r.body.len > 500) r.body[0..500] else r.body;
        std.debug.print("GET /api/workspaces returned {d}: {s}\n", .{ r.status, excerpt });
        return error.TestUnexpectedResult;
    }
    var doc = try r.json();
    defer doc.deinit();

    const arr = doc.array("workspaces") orelse {
        std.debug.print("workspace list has no `workspaces` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |id| gpa.free(id);
        out.deinit(gpa);
    }
    for (arr.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => continue,
        };
        const id = switch (o.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        try out.append(gpa, try gpa.dupe(u8, id));
    }
    return out.toOwnedSlice(gpa);
}

fn freeIds(ids: [][]u8) void {
    for (ids) |id| gpa.free(id);
    gpa.free(ids);
}

/// Render ids for a failure message (Python's `{sorted(ids)!r}`).
fn renderIds(ids: []const []u8) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    for (ids, 0..) |id, i| {
        if (i > 0) buf.writer.writeAll(", ") catch return error.OutOfMemory;
        buf.writer.print("\"{s}\"", .{id}) catch return error.OutOfMemory;
    }
    return buf.toOwnedSlice();
}

fn hasId(ids: []const []u8, id: []const u8) bool {
    for (ids) |got| {
        if (std.mem.eql(u8, got, id)) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

// LIST-ISOLATION — A's workspace must not appear in B's list, and vice
// versa.
test "workspaces_list_is_per_user" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var toks = try twoUsers(&h);
    defer toks.deinit();
    const cookie_a = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COOKIE_NAME, toks.a });
    defer gpa.free(cookie_a);
    const cookie_b = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COOKIE_NAME, toks.b });
    defer gpa.free(cookie_b);

    const ws_a = try createWorkspace(&h, "A private", cookie_a);
    defer gpa.free(ws_a);
    const ws_b = try createWorkspace(&h, "B private", cookie_b);
    defer gpa.free(ws_b);

    const ids_a = try listWorkspaceIds(&h, cookie_a);
    defer freeIds(ids_a);
    const ids_b = try listWorkspaceIds(&h, cookie_b);
    defer freeIds(ids_b);

    if (!hasId(ids_a, ws_a)) {
        const seen = try renderIds(ids_a);
        defer gpa.free(seen);
        std.debug.print("A must see the workspace A created; A saw [{s}]\n", .{seen});
        return error.TestUnexpectedResult;
    }
    if (!hasId(ids_b, ws_b)) {
        const seen = try renderIds(ids_b);
        defer gpa.free(seen);
        std.debug.print("B must see the workspace B created; B saw [{s}]\n", .{seen});
        return error.TestUnexpectedResult;
    }
    if (hasId(ids_a, ws_b)) {
        const seen = try renderIds(ids_a);
        defer gpa.free(seen);
        std.debug.print("A must NOT see B's workspace {s}; A saw [{s}]\n", .{ ws_b, seen });
        return error.TestUnexpectedResult;
    }
    if (hasId(ids_b, ws_a)) {
        const seen = try renderIds(ids_b);
        defer gpa.free(seen);
        std.debug.print("B must NOT see A's workspace {s}; B saw [{s}]\n", .{ ws_a, seen });
        return error.TestUnexpectedResult;
    }
}

// GET-ISOLATION — 404 rather than 403: B must not learn that A's id
// exists.
test "workspace_get_by_foreign_id_is_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var toks = try twoUsers(&h);
    defer toks.deinit();
    const cookie_a = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COOKIE_NAME, toks.a });
    defer gpa.free(cookie_a);
    const cookie_b = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COOKIE_NAME, toks.b });
    defer gpa.free(cookie_b);

    const ws_a = try createWorkspace(&h, "A only", cookie_a);
    defer gpa.free(ws_a);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}", .{ws_a});
    defer gpa.free(path);

    // OWN-READ: the owner still sees it (guards an "everyone gets 404"
    // false pass).
    {
        var r = try rawHttp(&h, .GET, path, null, cookie_a);
        defer r.deinit();
        if (r.status != 200) {
            const excerpt = if (r.body.len > 300) r.body[0..300] else r.body;
            std.debug.print("owner GET returned {d}: {s}\n", .{ r.status, excerpt });
            return error.TestUnexpectedResult;
        }
    }
    {
        var r = try rawHttp(&h, .GET, path, null, cookie_b);
        defer r.deinit();
        if (r.status != 404) {
            std.debug.print(
                "expected 404 for a foreign workspace, got {d}: {s}\n",
                .{ r.status, r.body },
            );
            return error.TestUnexpectedResult;
        }
    }
}

// AUTH-OFF-REGRESS: without `--auth` the create + list round-trip still
// works. No identity means the shared sentinel owns the row, so the same
// request that created it still sees it — the pre-isolation behaviour.
test "auth_off_is_unchanged" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "No-auth workspace", null);
    defer gpa.free(ws);

    const ids = try listWorkspaceIds(&h, null);
    defer freeIds(ids);
    if (!hasId(ids, ws)) {
        const seen = try renderIds(ids);
        defer gpa.free(seen);
        std.debug.print(
            "auth-off create+list regressed: {s} missing from [{s}]\n",
            .{ ws, seen },
        );
        return error.TestUnexpectedResult;
    }
}

// The DESTRUCTIVE half of "A must not interfere with B": a scoped list
// alone is not enough if DELETE still acts on a raw id.
test "foreign_delete_and_rename_are_refused" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var toks = try twoUsers(&h);
    defer toks.deinit();
    const cookie_a = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COOKIE_NAME, toks.a });
    defer gpa.free(cookie_a);
    const cookie_b = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COOKIE_NAME, toks.b });
    defer gpa.free(cookie_b);

    const ws_a = try createWorkspace(&h, "A do not touch", cookie_a);
    defer gpa.free(ws_a);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}", .{ws_a});
    defer gpa.free(path);

    // B cannot rename it.
    {
        var r = try rawHttp(&h, .PUT, path, "{\"name\":\"hijacked\"}", cookie_b);
        defer r.deinit();
        if (r.status != 404) {
            std.debug.print("expected 404 on a foreign rename, got {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }
    // B cannot destroy it.
    {
        var r = try rawHttp(&h, .DELETE, path, null, cookie_b);
        defer r.deinit();
        if (r.status != 404) {
            std.debug.print("expected 404 on a foreign delete, got {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }

    // A's workspace survived both attempts, with its original name.
    {
        var r = try rawHttp(&h, .GET, path, null, cookie_a);
        defer r.deinit();
        if (r.status != 200) {
            const excerpt = if (r.body.len > 300) r.body[0..300] else r.body;
            std.debug.print("A's workspace GET returned {d}: {s}\n", .{ r.status, excerpt });
            return error.TestUnexpectedResult;
        }
        var doc = try r.json();
        defer doc.deinit();
        const name = doc.str("name") orelse {
            std.debug.print("workspace detail has no `name`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, name, "A do not touch")) {
            std.debug.print(
                "A's workspace was renamed to \"{s}\" by B's rejected PUT\n",
                .{name},
            );
            return error.TestUnexpectedResult;
        }
    }

    // And A can still delete its own workspace.
    {
        var r = try rawHttp(&h, .DELETE, path, null, cookie_a);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print(
                "A must still be able to delete its own workspace; got {d}: {s}\n",
                .{ r.status, r.body },
            );
            return error.TestUnexpectedResult;
        }
    }
}

// Session ownership end to end: stamp, read-by-id, and the LIST filter.
test "sessions_are_owned_by_their_creator" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var toks = try twoUsers(&h);
    defer toks.deinit();
    const cookie_a = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COOKIE_NAME, toks.a });
    defer gpa.free(cookie_a);
    const cookie_b = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COOKIE_NAME, toks.b });
    defer gpa.free(cookie_b);

    const sess = blk: {
        var r = try rawHttp(&h, .POST, "/api/session", "{}", cookie_a);
        defer r.deinit();
        if (r.status != 201) {
            const excerpt = if (r.body.len > 500) r.body[0..500] else r.body;
            std.debug.print("POST /api/session returned {d}: {s}\n", .{ r.status, excerpt });
            return error.TestUnexpectedResult;
        }
        var doc = try r.json();
        defer doc.deinit();
        const id = doc.str("id") orelse {
            std.debug.print("session create returned no id: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (id.len == 0) {
            std.debug.print("create must return a non-empty session id\n", .{});
            return error.TestUnexpectedResult;
        }
        break :blk try gpa.dupe(u8, id);
    };
    defer gpa.free(sess);

    const detail = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{sess});
    defer gpa.free(detail);

    // The creator can read its own session.
    {
        var r = try rawHttp(&h, .GET, detail, null, cookie_a);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print("creator must read its own session, got {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }
    // The other user is refused with 404, not 403.
    {
        var r = try rawHttp(&h, .GET, detail, null, cookie_b);
        defer r.deinit();
        if (r.status != 404) {
            std.debug.print("expected 404 for a foreign session, got {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }

    // The LIST: compared on the RAW BODY so the test does not depend on
    // the JSON envelope's shape (Python: `assert sess in a_body.decode()`).
    {
        var r = try rawHttp(&h, .GET, "/api/session", null, cookie_a);
        defer r.deinit();
        if (r.status != 200) {
            const excerpt = if (r.body.len > 300) r.body[0..300] else r.body;
            std.debug.print("A's session list returned {d}: {s}\n", .{ r.status, excerpt });
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, r.body, sess) == null) {
            std.debug.print("own session {s} must appear in own list\n", .{sess});
            return error.TestUnexpectedResult;
        }
    }
    {
        var r = try rawHttp(&h, .GET, "/api/session", null, cookie_b);
        defer r.deinit();
        if (r.status != 200) {
            const excerpt = if (r.body.len > 300) r.body[0..300] else r.body;
            std.debug.print("B's session list returned {d}: {s}\n", .{ r.status, excerpt });
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, r.body, sess) != null) {
            std.debug.print("A's session {s} appeared in B's list\n", .{sess});
            return error.TestUnexpectedResult;
        }
    }
}

// B cannot list, create in, or delete inside A's workspace.
test "items_of_a_foreign_workspace_are_refused" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var toks = try twoUsers(&h);
    defer toks.deinit();
    const cookie_a = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COOKIE_NAME, toks.a });
    defer gpa.free(cookie_a);
    const cookie_b = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COOKIE_NAME, toks.b });
    defer gpa.free(cookie_b);

    const ws_a = try createWorkspace(&h, "A items", cookie_a);
    defer gpa.free(ws_a);
    const items_url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items", .{ws_a});
    defer gpa.free(items_url);

    // A can list its own items — proves the gate is not a blanket 404.
    // The BEFORE body is kept (owned) because the AFTER read must be
    // compared byte-for-byte.
    const before = blk: {
        var r = try rawHttp(&h, .GET, items_url, null, cookie_a);
        defer r.deinit();
        if (r.status != 200) {
            const excerpt = if (r.body.len > 300) r.body[0..300] else r.body;
            std.debug.print("owner items list returned {d}: {s}\n", .{ r.status, excerpt });
            return error.TestUnexpectedResult;
        }
        break :blk try gpa.dupe(u8, r.body);
    };
    defer gpa.free(before);

    // B cannot list them.
    {
        var r = try rawHttp(&h, .GET, items_url, null, cookie_b);
        defer r.deinit();
        if (r.status != 404) {
            std.debug.print(
                "expected 404 listing a foreign workspace's items, got {d}: {s}\n",
                .{ r.status, r.body },
            );
            return error.TestUnexpectedResult;
        }
    }

    // B cannot add an item (the middleware rejects before the body is
    // parsed).
    {
        var r = try rawHttp(&h, .POST, items_url, "{\"name\":\"intruder\"}", cookie_b);
        defer r.deinit();
        if (r.status != 404) {
            std.debug.print(
                "expected 404 adding to a foreign workspace, got {d}: {s}\n",
                .{ r.status, r.body },
            );
            return error.TestUnexpectedResult;
        }
    }

    // B cannot act on an item id inside A's workspace either.
    {
        const sub = try std.fmt.allocPrint(gpa, "{s}/whatever", .{items_url});
        defer gpa.free(sub);
        var r = try rawHttp(&h, .DELETE, sub, null, cookie_b);
        defer r.deinit();
        if (r.status != 404) {
            std.debug.print(
                "expected 404 deleting inside a foreign workspace, got {d}: {s}\n",
                .{ r.status, r.body },
            );
            return error.TestUnexpectedResult;
        }
    }

    // A's items are byte-identical before and after B's attempts.
    {
        var r = try rawHttp(&h, .GET, items_url, null, cookie_a);
        defer r.deinit();
        if (r.status != 200) {
            const excerpt = if (r.body.len > 300) r.body[0..300] else r.body;
            std.debug.print("owner items list returned {d}: {s}\n", .{ r.status, excerpt });
            return error.TestUnexpectedResult;
        }
        if (!std.mem.eql(u8, before, r.body)) {
            std.debug.print(
                "A's items changed after B's attempts\nbefore: {s}\nafter:  {s}\n",
                .{ before, r.body },
            );
            return error.TestUnexpectedResult;
        }
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = rawHttp;
    _ = bootAuth;
    _ = createAdmin;
    _ = login;
    _ = TwoTokens.deinit;
    _ = twoUsers;
    _ = createWorkspace;
    _ = listWorkspaceIds;
    _ = freeIds;
    _ = renderIds;
    _ = hasId;
}

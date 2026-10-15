// Functional tests for opt-in `--auth` mode. Zig port of
// `tests/functional/auth_test.py` (same test names).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// Issue a request WITHOUT a status assertion — the caller asserts.
/// `Harness.http` asserts on `expect` by default, which is the wrong tool
/// where the STATUS ITSELF is the assertion under test.
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

/// Boot a harness with `--auth` (the gate is opt-in).
fn bootAuth() !Harness {
    return Harness.boot(io, gpa, .{ .extra_args = &.{"--auth"} });
}

/// Run `pabrik create-admin` against the harness HOME. `runPabrikCommand`
/// prepends the resolved binary itself, so `argv` starts at the SUBCOMMAND.
fn createAdmin(home: []const u8, email: []const u8, password: []const u8) !void {
    var r = try harness.runPabrikCommand(io, gpa, home, &.{
        "create-admin", "--email", email, "--password", password,
    }, 30_000);
    defer r.deinit(gpa);
    if (r.exit_code == null or r.exit_code.? != 0) {
        std.debug.print("create-admin failed (rc={?}): {s}\n", .{ r.exit_code, r.stderr });
        return error.TestUnexpectedResult;
    }
}

// OPEN-BY-DEFAULT — no `--auth` flag: the API answers.
test "open_by_default" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/workspaces", .{});
    defer r.deinit();

    // Python asserted `isinstance(r.json(), (list, dict))` — the wire
    // shape is "some JSON value"; the contract under test is that the
    // route is NOT gated without the flag.
    var doc = try r.json();
    defer doc.deinit();
    switch (doc.value().*) {
        .array, .object => {},
        else => return error.TestUnexpectedResult,
    }
}

// GATE — with `--auth`, an unauthenticated API call is 401.
test "gate_without_cookie" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var raw = try rawHttp(&h, .GET, "/api/workspaces", null, null);
    defer raw.deinit();
    try testing.expectEqual(@as(u16, 401), raw.status);
}

// EXEMPT — /health and the login route stay reachable without a cookie.
test "exempt_routes_without_cookie" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var raw = try rawHttp(&h, .GET, "/health", null, null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 200), raw.status);
    }
    {
        const body =
            \\{"email":"x@y.z","password":"nope"}
        ;
        var raw = try rawHttp(&h, .POST, "/api/auth/login", body, null);
        defer raw.deinit();
        // Python: `status in (401, 400)`.
        try testing.expect(raw.status == 401 or raw.status == 400);
    }
}

// EMPTY-COOKIE — `Cookie:EOabrik_session=` must be 401, not 500.
test "empty_cookie_is_401" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var raw = try rawHttp(&h, .GET, "/api/workspaces", null, "pabrik_session=");
    defer raw.deinit();
    try testing.expectEqual(@as(u16, 401), raw.status);
}

// LOGIN-FLOW — the whole cookie round-trip.
test "login_flow" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "admin@example.com", "supersecret123");

    // 1. Login returns 200 + a Set-Cookie carrying an HttpOnly token.
    const login_body =
        \\{"email":"admin@example.com","password":"supersecret123"}
    ;
    var login = try rawHttp(&h, .POST, "/api/auth/login", login_body, null);
    defer login.deinit();
    try testing.expectEqual(@as(u16, 200), login.status);

    const set_cookie = login.header("Set-Cookie") orelse {
        std.debug.print("no Set-Cookie; body={s}\n", .{login.body});
        return error.TestUnexpectedResult;
    };
    try testing.expect(std.mem.indexOf(u8, set_cookie, "pabrik_session=") != null);
    try testing.expect(std.mem.indexOf(u8, set_cookie, "HttpOnly") != null);

    // 2. Extract the raw token for the subsequent requests. The token is the
    // SEGMENT between `pabrik_session=` and the next `;`.
    var attrs = std.mem.splitSequence(u8, set_cookie, ";");
    const first_attr = attrs.next() orelse return error.TestUnexpectedResult;
    const token = std.mem.trim(u8, harness.afterFirst(first_attr, "pabrik_session=") orelse
        return error.TestUnexpectedResult, " \t\r\n");
    try testing.expect(token.len > 16);

    const cookie_hdr = try std.fmt.allocPrint(gpa, "pabrik_session={s}", .{token});
    defer gpa.free(cookie_hdr);

    // 3. The authed GET works.
    {
        var raw = try rawHttp(&h, .GET, "/api/workspaces", null, cookie_hdr);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 200), raw.status);
    }

    // 4. /api/auth/me reports the authenticated user.
    {
        var raw = try rawHttp(&h, .GET, "/api/auth/me", null, cookie_hdr);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 200), raw.status);

        var me = try raw.json();
        defer me.deinit();
        try testing.expectEqual(true, me.boolean("authenticated").?);
        const user = me.object("user").?;
        try testing.expectEqualStrings("admin@example.com", user.get("email").?.string);
    }

    // 5. Wrong password stays 401 — no user enumeration.
    {
        const wrong =
            \\{"email":"admin@example.com","password":"wrongpass1"}
        ;
        var raw = try rawHttp(&h, .POST, "/api/auth/login", wrong, null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 401), raw.status);
    }

    // 6. Logout clears the session server-side.
    {
        var raw = try rawHttp(&h, .POST, "/api/auth/logout", null, cookie_hdr);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 200), raw.status);
        const logout_cookie = raw.header("Set-Cookie") orelse "";
        try testing.expect(std.mem.indexOf(u8, logout_cookie, "Max-Age=0") != null);
    }
    {
        var raw = try rawHttp(&h, .GET, "/api/workspaces", null, cookie_hdr);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 401), raw.status);
    }
}

// CREATE-ADMIN refuses a second admin without --force.
test "create_admin_refuses_second_without_force" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "one@example.com", "supersecret123");

    var r = try harness.runPabrikCommand(io, gpa, h.temp_dir, &.{
        "create-admin", "--email", "two@example.com", "--password", "supersecret123",
    }, 30_000);
    defer r.deinit(gpa);
    try testing.expect(r.exit_code == null or r.exit_code.? != 0);
}

// Refreshing at /login?redirect=/app must serve the SPA shell, not 404.
test "login_refresh_serves_spa_shell" {
    try harness.requirePabrikBin(io, gpa);

    // The Python test used pytest's `tmp_path`; the Zig analogue is a
    // scratch dir under the OS temp, removed on the way out.
    var scratch: std.testing.TmpDir = std.testing.tmpDir(.{});
    defer scratch.cleanup();

    var seed: [std.fs.max_path_bytes]u8 = undefined;
    const seed_len = try scratch.dir.realPath(io, &seed);
    const scratch_path = seed[0..seed_len];

    const static_dir = try std.fs.path.join(gpa, &.{ scratch_path, "webapp" });
    defer gpa.free(static_dir);
    try scratch.dir.createDirPath(io, "webapp");
    {
        var f = try scratch.dir.createFile(io, "webapp/index.html", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "<!doctype html><title>SPA</title>");
    }

    var h = try Harness.boot(io, gpa, .{
        .extra_args = &.{ "--auth", "--static-dir", static_dir },
    });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var raw = try rawHttp(&h, .GET, "/login?redirect=/app", null, null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 200), raw.status);
        try testing.expect(std.mem.indexOf(u8, raw.body, "SPA") != null);
    }
    {
        var raw = try rawHttp(&h, .GET, "/login", null, null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 200), raw.status);
    }
    // /app fallback still works alongside /login.
    {
        var raw = try rawHttp(&h, .GET, "/app/settings", null, null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 200), raw.status);
    }
    // Unrelated paths still 404 — no silent catch-all.
    {
        var raw = try rawHttp(&h, .GET, "/something-else", null, null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 404), raw.status);
    }
}
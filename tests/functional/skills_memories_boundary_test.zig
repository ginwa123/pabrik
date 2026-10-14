// Functional tests for the skills/memories filesystem boundary (plan
// 2026-09-25, W2.6).

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

/// Boot a harness with `--auth`.
fn bootAuth() !Harness {
    return Harness.boot(io, gpa, .{ .extra_args = &.{"--auth"} });
}

/// Run `pabrik create-admin` against the harness HOME.
fn createAdmin(home: []const u8, email: []const u8, password: []const u8, force: bool) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "create-admin", "--email", email, "--password", password });
    if (force) try argv.append(gpa, "--force");

    var r = try harness.runPabrikCommand(io, gpa, home, argv.items, 30_000);
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
    // `set_cookie.split("pabrik_session=", 1)[1].split(";", 1)[0].strip()`.
    // `harness.afterFirst` returns the text AFTER the delimiter, which
    // here would be the attribute list — wrong direction, hence the split.
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

/// Two admins on one server. Python's `_two_users`. Returned BY VALUE so the
/// caller owns the harness and must `deinit` it; a helper that only handed
/// back tokens would leak the server.
const TwoUsers = struct {
    h: Harness,
    tok_a: []u8,
    tok_b: []u8,

    fn freeTokens(self: *TwoUsers) void {
        gpa.free(self.tok_a);
        gpa.free(self.tok_b);
    }
};

fn twoUsers() !TwoUsers {
    var h = try bootAuth();
    errdefer h.deinit(io) catch {};
    try createAdmin(h.temp_dir, "a@example.com", "supersecret123", false);
    try createAdmin(h.temp_dir, "b@example.com", "supersecret123", true);
    const tok_a = try login(&h, "a@example.com", "supersecret123");
    errdefer gpa.free(tok_a);
    const tok_b = try login(&h, "b@example.com", "supersecret123");
    return .{ .h = h, .tok_a = tok_a, .tok_b = tok_b };
}

/// Write `<cwd>/.pabrik/memories/<name>.md`. Python's `_write_local_memory`.
fn writeLocalMemory(cwd: []const u8, name: []const u8, body: []const u8) !void {
    const dir = try harness.harnessPath(gpa, cwd, &.{ ".pabrik", "memories" });
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const file = try std.fmt.allocPrint(gpa, "{s}.md", .{name});
    defer gpa.free(file);
    const full = try std.fs.path.join(gpa, &.{ dir, file });
    defer gpa.free(full);

    var f = try std.Io.Dir.cwd().createFile(io, full, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

/// Assert `body` contains `needle`, printing the first 300 bytes when it
/// does not (Python's `body[:300]` in the failure message).
fn expectContains(body: []const u8, needle: []const u8, what: []const u8) !void {
    if (std.mem.indexOf(u8, body, needle) != null) return;
    const excerpt = if (body.len > 300) body[0..300] else body;
    std.debug.print("{s}: expected {s} in response, got: {s}\n", .{ what, needle, excerpt });
    return error.TestUnexpectedResult;
}

/// Assert a status, printing the first 300 bytes of the body otherwise.
fn expectStatus(r: *const harness.Response, accepted: []const u16, what: []const u8) !void {
    for (accepted) |code| {
        if (r.status == code) return;
    }
    var want_buf: [64]u8 = undefined;
    var want_w: std.Io.Writer = .fixed(&want_buf);
    for (accepted, 0..) |code, i| {
        want_w.print("{d}", .{code}) catch break;
        if (i + 1 < accepted.len) want_w.writeAll(", ") catch break;
    }
    const excerpt = if (r.body.len > 300) r.body[0..300] else r.body;
    std.debug.print(
        "{s}: expected status [{s}], got {d}: {s}\n",
        .{ what, want_w.buffered(), r.status, excerpt },
    );
    return error.TestUnexpectedResult;
}

// ============================================================================
// tests
// ============================================================================

// GLOBAL-SHARED — the global dir is one per OS account, so both users see the
// same entries.
test "global_skills_and_memories_are_shared_across_users" {
    try harness.requirePabrikBin(io, gpa);

    var tu = try twoUsers();
    defer tu.h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };
    defer tu.freeTokens();

    const cookie_a = try cookieHeader(tu.tok_a);
    defer gpa.free(cookie_a);
    const cookie_b = try cookieHeader(tu.tok_b);
    defer gpa.free(cookie_b);

    // A creates a global memory via the API. (`\\n` are literal
    // backslash-n in the JSON body: markdown newlines inside a JSON
    // string.)
    {
        var r = try rawWithCookie(
            &tu.h,
            .POST,
            "/api/memories",
            "{\"name\":\"shared-note.md\",\"content\":\"# shared\\n\\nbody\"}",
            cookie_a,
        );
        defer r.deinit();
        try expectStatus(&r, &.{ 200, 201 }, "POST /api/memories");
    }

    // B sees it in the global list — same OS-account directory.
    {
        var r = try rawWithCookie(&tu.h, .GET, "/api/memories", null, cookie_b);
        defer r.deinit();
        try expectStatus(&r, &.{200}, "GET /api/memories as B");
        try expectContains(r.body, "shared-note", "global memories are one directory per OS account; B must see A's " ++
            "entry (D9 boundary). If this now fails, the boundary was closed — " ++
            "update this test and the plan's D9 section.");
    }

    // The directory-tier skills route is gone for BOTH users.
    for ([_]struct { who: []const u8, cookie: []const u8 }{
        .{ .who = "A", .cookie = cookie_a },
        .{ .who = "B", .cookie = cookie_b },
    }) |who| {
        var r = try rawWithCookie(&tu.h, .GET, "/api/skills", null, who.cookie);
        defer r.deinit();
        try expectStatus(&r, &.{404}, "directory-scoped /api/skills");
        _ = who.who;
    }
}

// LOCAL-CWD — `?cwd=` is caller-supplied, so B can read A's workspace
// `.pabrik/` files.
test "local_memories_follow_the_caller_supplied_cwd" {
    try harness.requirePabrikBin(io, gpa);

    // pytest's `tmp_path` was a SIBLING of the harness tempdir, never a child
    // of it — `makeScratchDir` gives the suite its own `pabrik-fix-`
    // namespace that the orphan reaper (which only matches `pabrik-func-`)
    const scratch = try harness.makeScratchDir(gpa);
    // DEFER ORDER IS LIFO: `free` is registered FIRST so it runs LAST —
    // `cleanupExtraDir` reads `scratch` to delete it.
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    var tu = try twoUsers();
    defer tu.h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };
    defer tu.freeTokens();

    const a_dir = try harness.harnessPath(gpa, scratch, &.{"a-workspace"});
    defer gpa.free(a_dir);
    try std.Io.Dir.cwd().createDirPath(io, a_dir);
    try writeLocalMemory(a_dir, "a-secret", "# A's local memory\n\nprivate-ish");

    const cookie_a = try cookieHeader(tu.tok_a);
    defer gpa.free(cookie_a);
    const cookie_b = try cookieHeader(tu.tok_b);
    defer gpa.free(cookie_b);

    // A reads its own local memories.
    {
        var r = try tu.h.http(io, .GET, "/api/local-memories", .{
            .params = &.{.{ .name = "cwd", .value = a_dir }},
            .extra_headers = &.{.{ .name = "Cookie", .value = cookie_a }},
            .assert_status = false,
        });
        defer r.deinit();
        try expectStatus(&r, &.{200}, "GET /api/local-memories as A");
        try expectContains(r.body, "a-secret", "A's own local memory list");
    }

    // B points at A's directory and reads the same file — the boundary.
    {
        var r = try tu.h.http(io, .GET, "/api/local-memories", .{
            .params = &.{.{ .name = "cwd", .value = a_dir }},
            .extra_headers = &.{.{ .name = "Cookie", .value = cookie_b }},
            .assert_status = false,
        });
        defer r.deinit();
        try expectStatus(&r, &.{200}, "GET /api/local-memories as B");
        try expectContains(r.body, "a-secret", "local memories are path-scoped and `cwd` is caller-supplied; B " ++
            "reading A's directory is the D9 boundary. If this now fails, the " ++
            "boundary was closed — update this test and the plan's D9 section.");
    }
}

// AUTH-OFF — regression: without `--auth` the endpoints still answer.
test "skills_and_memories_auth_off_is_unchanged" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    {
        var r = try rawWithCookie(&h, .GET, "/api/skills", null, null);
        defer r.deinit();
        try expectStatus(&r, &.{404}, "auth-off directory-scoped /api/skills");
    }

    const ws_id = blk: {
        var r = try rawWithCookie(
            &h,
            .POST,
            "/api/workspaces",
            "{\"name\":\"auth-off-skills\"}",
            null,
        );
        defer r.deinit();
        try expectStatus(&r, &.{ 200, 201 }, "auth-off POST /api/workspaces");
        var doc = try r.json();
        defer doc.deinit();
        break :blk try gpa.dupe(u8, doc.str("id") orelse {
            std.debug.print("workspace create returned no id: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
    };
    defer gpa.free(ws_id);

    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/skills", .{ws_id});
        defer gpa.free(path);
        var r = try rawWithCookie(&h, .GET, path, null, null);
        defer r.deinit();
        try expectStatus(&r, &.{200}, "auth-off workspace-scoped skills");

        // Python: `json.loads(body) == {"skills": []}` — an exact dict
        // equality, so the object must carry the ONE key and the array
        // must be empty.
        var doc = try r.json();
        defer doc.deinit();
        const obj = doc.object("") orelse doc.value().object;
        if (obj.count() != 1) {
            std.debug.print("expected exactly one key in the skills response, got {d}\n", .{obj.count()});
            return error.TestUnexpectedResult;
        }
        const skills = obj.get("skills") orelse {
            std.debug.print("skills response has no `skills` key: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        const arr = switch (skills) {
            .array => |a| a,
            else => {
                std.debug.print("`skills` is not an array: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            },
        };
        try testing.expectEqual(@as(usize, 0), arr.items.len);
    }

    {
        var r = try rawWithCookie(&h, .GET, "/api/memories", null, null);
        defer r.deinit();
        try expectStatus(&r, &.{200}, "auth-off GET /api/memories");
    }

    // `/api/local-memories` needs a cwd (query or server cwd); pass one.
    {
        var r = try h.http(io, .GET, "/api/local-memories", .{
            .params = &.{.{ .name = "cwd", .value = h.temp_dir }},
            .assert_status = false,
        });
        defer r.deinit();
        try expectStatus(&r, &.{200}, "auth-off GET /api/local-memories");
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
    _ = TwoUsers.freeTokens;
    _ = twoUsers;
    _ = writeLocalMemory;
    _ = expectContains;
    _ = expectStatus;
}

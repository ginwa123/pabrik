// Functional tests for `--auth` per-user config (users.config_json). Zig port
// of `tests/functional/user_config_test.py` (same test names, same order).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// Issue a request WITHOUT a status assertion — the caller asserts.
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

/// Boot a harness with `--auth` (the per-user config gate is opt-in).
fn bootAuth() !Harness {
    return Harness.boot(io, gpa, .{ .extra_args = &.{"--auth"} });
}

/// `pabrik create-admin` against the harness HOME.
fn createAdmin(
    home: []const u8,
    email: []const u8,
    password: []const u8,
    force: bool,
) !void {
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

/// POST /api/auth/login and return the session token. Caller frees.
fn login(h: *Harness, email: []const u8, password: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"email\":\"{s}\",\"password\":\"{s}\"}}", .{
        email, password,
    });
    defer gpa.free(body);

    var r = try rawHttp(h, .POST, "/api/auth/login", body, null);
    defer r.deinit();
    if (r.status != 200) {
        std.debug.print("login failed: {d} {s}\n", .{ r.status, r.body[0..@min(r.body.len, 500)] });
        return error.TestUnexpectedResult;
    }
    const set_cookie = r.header("Set-Cookie") orelse {
        std.debug.print("login returned no Set-Cookie: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, set_cookie, "pabrik_session=") == null) {
        std.debug.print("Set-Cookie carries no session: {s}\n", .{set_cookie});
        return error.TestUnexpectedResult;
    }
    var attrs = std.mem.splitSequence(u8, set_cookie, ";");
    const first_attr = attrs.next() orelse return error.TestUnexpectedResult;
    const token = std.mem.trim(u8, harness.afterFirst(first_attr, "pabrik_session=") orelse
        return error.TestUnexpectedResult, " \t\r\n");
    if (token.len == 0) return error.TestUnexpectedResult;
    return gpa.dupe(u8, token);
}

/// The `_profile_body` helper: one named profile + `active_profile`.
fn profileBody(name: []const u8, model: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"profiles\":{{\"{s}\":{{\"model\":\"{s}\",\"base_url\":\"https://api.example.com\"," ++
            "\"thinking\":\"auto\",\"temperature\":\"auto\",\"url_style\":\"openai\"," ++
            "\"api_key\":\"k\"}}}},\"active_profile\":\"{s}\"}}",
        .{ name, model, name },
    );
}

/// Where `getDefaultConfigDir` (Config.zig) actually writes config.json.
/// Mirrors that function's platform switch: * macOS — `~/Library/Application
/// Support/pabrik`.
fn configFilePath(home: []const u8) ![]u8 {
    return switch (builtin.os.tag) {
        .macos => harness.harnessPath(gpa, home, &.{ "Library", "Application Support", "pabrik", "config.json" }),
        .windows => harness.harnessPath(gpa, home, &.{ "AppData", "Roaming", "pabrik", "config.json" }),
        else => harness.harnessPath(gpa, home, &.{ ".config", "pabrik", "config.json" }),
    };
}

/// The raw bytes of `config.json` under `home`, or `null` when it does
/// not exist. Caller owns a non-null result.
fn readConfigBytes(home: []const u8) !?[]u8 {
    const path = try configFilePath(home);
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

/// `cfg["profiles"]["<name>"]["model"]`, or null. Borrowed from `doc`.
fn profileModel(doc: *const harness.Json, name: []const u8) ?[]const u8 {
    const profiles = doc.object("profiles") orelse return null;
    const entry = switch (profiles.get(name) orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return switch (entry.get("model") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Does `profiles` carry a key named `name`?
fn hasProfile(doc: *const harness.Json, name: []const u8) bool {
    const profiles = doc.object("profiles") orelse return false;
    return profiles.contains(name);
}

// ============================================================================
// Test 1: AUTH-GET-DEFAULTS
// ============================================================================

// A fresh admin GETs defaults (no config_json yet).
test "auth_get_defaults" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "admin@example.com", "supersecret123", false);
    const token = try login(&h, "admin@example.com", "supersecret123");
    defer gpa.free(token);

    const cookie = try std.fmt.allocPrint(gpa, "pabrik_session={s}", .{token});
    defer gpa.free(cookie);

    var r = try rawHttp(&h, .GET, "/api/config/pabrik", null, cookie);
    defer r.deinit();
    if (r.status != 200) {
        std.debug.print("GET /api/config/pabrik: {d} {s}\n", .{ r.status, r.body[0..@min(r.body.len, 500)] });
        return error.TestUnexpectedResult;
    }

    var doc = try r.json();
    defer doc.deinit();

    // Python: `cfg.get("profiles") in (None, {})` — absent, null, or an
    // empty object are all "the user has no profiles yet". A populated
    // map fails.
    if (doc.get("profiles")) |v| switch (v) {
        .null => {},
        .object => |o| {
            if (o.count() != 0) {
                std.debug.print("expected no profiles, got {d}: {s}\n", .{ o.count(), r.body });
                return error.TestUnexpectedResult;
            }
        },
        else => {
            std.debug.print("`profiles` is neither null, absent, nor an object: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
}

// ============================================================================
// Test 2: AUTH-PUT-ISOLATION
// ============================================================================

// User A and B have independent configs.
test "auth_put_isolation" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "a@example.com", "supersecret123", false);
    try createAdmin(h.temp_dir, "b@example.com", "supersecret123", true);

    const tok_a = try login(&h, "a@example.com", "supersecret123");
    defer gpa.free(tok_a);
    const tok_b = try login(&h, "b@example.com", "supersecret123");
    defer gpa.free(tok_b);

    const cookie_a = try std.fmt.allocPrint(gpa, "pabrik_session={s}", .{tok_a});
    defer gpa.free(cookie_a);
    const cookie_b = try std.fmt.allocPrint(gpa, "pabrik_session={s}", .{tok_b});
    defer gpa.free(cookie_b);

    {
        const body = try profileBody("alpha", "model-a");
        defer gpa.free(body);
        var r = try rawHttp(&h, .PUT, "/api/config/pabrik", body, cookie_a);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print("PUT as A: {d} {s}\n", .{ r.status, r.body[0..@min(r.body.len, 500)] });
            return error.TestUnexpectedResult;
        }
    }
    {
        const body = try profileBody("beta", "model-b");
        defer gpa.free(body);
        var r = try rawHttp(&h, .PUT, "/api/config/pabrik", body, cookie_b);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print("PUT as B: {d} {s}\n", .{ r.status, r.body[0..@min(r.body.len, 500)] });
            return error.TestUnexpectedResult;
        }
    }

    {
        var r = try rawHttp(&h, .GET, "/api/config/pabrik", null, cookie_a);
        defer r.deinit();
        if (r.status != 200) return error.TestUnexpectedResult;
        var doc = try r.json();
        defer doc.deinit();
        const model = profileModel(&doc, "alpha") orelse {
            std.debug.print("A lost its `alpha` profile: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings("model-a", model);
        if (hasProfile(&doc, "beta")) {
            std.debug.print("A sees B's `beta` profile: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    {
        var r = try rawHttp(&h, .GET, "/api/config/pabrik", null, cookie_b);
        defer r.deinit();
        if (r.status != 200) return error.TestUnexpectedResult;
        var doc = try r.json();
        defer doc.deinit();
        const model = profileModel(&doc, "beta") orelse {
            std.debug.print("B lost its `beta` profile: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings("model-b", model);
        if (hasProfile(&doc, "alpha")) {
            std.debug.print("B sees A's `alpha` profile: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 3: AUTH-FILE-UNTOUCHED
// ============================================================================

// PUT in auth mode never writes config.json — but the DB-backed GET does
// reflect the save.
test "auth_put_leaves_config_file_untouched" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "admin@example.com", "supersecret123", false);
    const token = try login(&h, "admin@example.com", "supersecret123");
    defer gpa.free(token);
    const cookie = try std.fmt.allocPrint(gpa, "pabrik_session={s}", .{token});
    defer gpa.free(cookie);

    const before = try readConfigBytes(h.temp_dir);
    defer if (before) |b| gpa.free(b);

    {
        const body = try profileBody("alpha", "model-a");
        defer gpa.free(body);
        var r = try rawHttp(&h, .PUT, "/api/config/pabrik", body, cookie);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print("PUT: {d} {s}\n", .{ r.status, r.body[0..@min(r.body.len, 500)] });
            return error.TestUnexpectedResult;
        }
    }

    const after = try readConfigBytes(h.temp_dir);
    defer if (after) |a| gpa.free(a);

    // Both absent, or byte-identical: PUT in --auth mode must not touch
    // config.json.
    if ((before == null) != (after == null)) {
        std.debug.print("PUT in --auth mode created/destroyed config.json\n", .{});
        return error.TestUnexpectedResult;
    }
    if (before != null and after != null and !std.mem.eql(u8, before.?, after.?)) {
        std.debug.print("PUT in --auth mode rewrote config.json\n", .{});
        return error.TestUnexpectedResult;
    }

    // But the DB-backed GET reflects the save.
    {
        var r = try rawHttp(&h, .GET, "/api/config/pabrik", null, cookie);
        defer r.deinit();
        if (r.status != 200) return error.TestUnexpectedResult;
        var doc = try r.json();
        defer doc.deinit();
        const model = profileModel(&doc, "alpha") orelse {
            std.debug.print("GET after PUT has no `alpha` profile: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings("model-a", model);
    }
}

// ============================================================================
// Test 4: AUTH-UNAUTH
// ============================================================================

// GET/PUT/DELETE without cookie -> 401.
test "auth_unauth_config_endpoints_are_401" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var r = try rawHttp(&h, .GET, "/api/config/pabrik", null, null);
        defer r.deinit();
        if (r.status != 401) {
            std.debug.print("GET /api/config/pabrik should be 401 without cookie, got {d}\n", .{r.status});
            return error.TestUnexpectedResult;
        }
    }
    {
        const body = try std.fmt.allocPrint(gpa, "{{\"active_profile\":null}}", .{});
        defer gpa.free(body);
        var r = try rawHttp(&h, .PUT, "/api/config/pabrik", body, null);
        defer r.deinit();
        if (r.status != 401) {
            std.debug.print("PUT /api/config/pabrik should be 401 without cookie, got {d}\n", .{r.status});
            return error.TestUnexpectedResult;
        }
    }
    {
        var r = try rawHttp(&h, .DELETE, "/api/config/pabrik/profiles/x", null, null);
        defer r.deinit();
        if (r.status != 401) {
            std.debug.print("DELETE /api/config/pabrik/profiles/x should be 401 without cookie, got {d}\n", .{r.status});
            return error.TestUnexpectedResult;
        }
    }
    {
        var r = try rawHttp(&h, .GET, "/api/config/pabrik", null, "pabrik_session=");
        defer r.deinit();
        if (r.status != 401) {
            std.debug.print("an empty session cookie should be 401, got {d}\n", .{r.status});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 5: AUTH-DELETE
// ============================================================================

// DELETE removes the profile from the user's column.
test "auth_delete_profile" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "admin@example.com", "supersecret123", false);
    const token = try login(&h, "admin@example.com", "supersecret123");
    defer gpa.free(token);
    const cookie = try std.fmt.allocPrint(gpa, "pabrik_session={s}", .{token});
    defer gpa.free(cookie);

    {
        const body = try profileBody("todelete", "m");
        defer gpa.free(body);
        var r = try rawHttp(&h, .PUT, "/api/config/pabrik", body, cookie);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print("PUT: {d} {s}\n", .{ r.status, r.body[0..@min(r.body.len, 500)] });
            return error.TestUnexpectedResult;
        }
    }
    {
        var r = try rawHttp(&h, .DELETE, "/api/config/pabrik/profiles/todelete", null, cookie);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print("DELETE profile: {d} {s}\n", .{ r.status, r.body[0..@min(r.body.len, 500)] });
            return error.TestUnexpectedResult;
        }
    }
    {
        var r = try rawHttp(&h, .GET, "/api/config/pabrik", null, cookie);
        defer r.deinit();
        if (r.status != 200) return error.TestUnexpectedResult;
        var doc = try r.json();
        defer doc.deinit();
        if (hasProfile(&doc, "todelete")) {
            std.debug.print("`todelete` survived the DELETE: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 6: OFF-MODE-REGRESSION
// ============================================================================

// Without --auth, PUT still writes config.json.
test "off_mode_put_still_writes_file" {
    try harness.requirePabrikBin(io, gpa);

    // The Python `harness` fixture booted WITHOUT --auth.
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const before = try readConfigBytes(h.temp_dir);
    defer if (before) |b| gpa.free(b);

    {
        const body = try profileBody("filemode", "mf");
        defer gpa.free(body);
        var r = try h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
    }

    const after = try readConfigBytes(h.temp_dir);
    defer if (after) |a| gpa.free(a);

    const bytes = after orelse {
        std.debug.print("off-mode PUT must write config.json, but no file appeared\n", .{});
        return error.TestUnexpectedResult;
    };
    if (before != null and std.mem.eql(u8, before.?, bytes)) {
        std.debug.print("off-mode PUT must CHANGE config.json\n", .{});
        return error.TestUnexpectedResult;
    }

    // On disk the profile lives under `profiles_models`, not `profiles`.
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| {
        std.debug.print("config.json is not JSON: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            std.debug.print("config.json root is not an object: {s}\n", .{bytes});
            return error.TestUnexpectedResult;
        },
    };
    const models = switch (root.get("profiles_models") orelse {
        std.debug.print("config.json has no `profiles_models`: {s}\n", .{bytes});
        return error.TestUnexpectedResult;
    }) {
        .object => |o| o,
        else => {
            std.debug.print("`profiles_models` is not an object: {s}\n", .{bytes});
            return error.TestUnexpectedResult;
        },
    };
    const entry = switch (models.get("filemode") orelse {
        std.debug.print("config.json has no `filemode` profile: {s}\n", .{bytes});
        return error.TestUnexpectedResult;
    }) {
        .object => |o| o,
        else => {
            std.debug.print("`filemode` is not an object: {s}\n", .{bytes});
            return error.TestUnexpectedResult;
        },
    };
    const model = switch (entry.get("model") orelse {
        std.debug.print("`filemode` has no `model`: {s}\n", .{bytes});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("`filemode.model` is not a string: {s}\n", .{bytes});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqualStrings("mf", model);
}

// Functional tests for the admin console: the page it serves, the owner
// gate, and the password reset that is the "forgot password" case.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

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

/// Boot a harness with `--auth` (the gate is opt-in).
fn bootAuth() !Harness {
    return Harness.boot(io, gpa, .{ .extra_args = &.{"--auth"} });
}

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

/// Sign in and return the `Cookie` header value the next calls carry.
fn login(h: *Harness, email: []const u8, password: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"email\":\"{s}\",\"password\":\"{s}\"}}", .{ email, password });
    defer gpa.free(body);
    var raw = try rawHttp(h, .POST, "/api/auth/login", body, null);
    defer raw.deinit();
    if (raw.status != 200) {
        std.debug.print("login failed ({d}): {s}\n", .{ raw.status, raw.body });
        return error.TestUnexpectedResult;
    }
    const set_cookie = raw.header("Set-Cookie") orelse return error.TestUnexpectedResult;
    var attrs = std.mem.splitSequence(u8, set_cookie, ";");
    const first_attr = attrs.next() orelse return error.TestUnexpectedResult;
    const token = std.mem.trim(u8, harness.afterFirst(first_attr, "pabrik_session=") orelse
        return error.TestUnexpectedResult, " \t\r\n");
    return std.fmt.allocPrint(gpa, "pabrik_session={s}", .{token});
}

// The console page and its two assets are served without a session.
test "admin_page_is_served" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var raw = try rawHttp(&h, .GET, "/admin", null, null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 200), raw.status);
        try testing.expect(std.mem.indexOf(u8, raw.body, "Admin console") != null);
        // The page is useless without its two assets, so it names them.
        try testing.expect(std.mem.indexOf(u8, raw.body, "/admin/admin.css") != null);
        try testing.expect(std.mem.indexOf(u8, raw.body, "/admin/admin.js") != null);
    }
    {
        var raw = try rawHttp(&h, .GET, "/admin/admin.css", null, null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 200), raw.status);
        try testing.expect(raw.body.len > 0);
    }
    {
        var raw = try rawHttp(&h, .GET, "/admin/admin.js", null, null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 200), raw.status);
        try testing.expect(std.mem.indexOf(u8, raw.body, "/api/admin/users") != null);
    }
}

// An installation without `--auth` is owned by the operator, so the console
// answers.
test "admin_api_is_open_without_auth" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var raw = try rawHttp(&h, .GET, "/api/admin/users", null, null);
    defer raw.deinit();
    try testing.expectEqual(@as(u16, 200), raw.status);

    var doc = try raw.json();
    defer doc.deinit();
    const users = doc.array("users").?;
    try testing.expectEqual(@as(usize, 0), users.items.len);
}

// With `--auth` an anonymous caller is 401, never 200.
test "admin_api_refuses_anonymous_when_auth_is_on" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var raw = try rawHttp(&h, .GET, "/api/admin/users", null, null);
    defer raw.deinit();
    try testing.expectEqual(@as(u16, 401), raw.status);
}

// A session that is not the owner is 403: signed in, but not allowed.
test "admin_api_refuses_a_session_that_is_not_the_owner" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "owner@example.com", "supersecret123");
    const owner_cookie = try login(&h, "owner@example.com", "supersecret123");
    defer gpa.free(owner_cookie);

    // The owner makes an ordinary account.
    var created = try rawHttp(&h, .POST, "/api/admin/users",
        \\{"email":"plain@example.com","name":"Plain","role":"user"}
    , owner_cookie);
    defer created.deinit();
    try testing.expectEqual(@as(u16, 201), created.status);

    var created_doc = try created.json();
    defer created_doc.deinit();
    const temporary = created_doc.str("temporary_password").?;
    const user_id = created_doc.object("user").?.get("id").?.string;

    // That account signs in and is refused by the console.
    const plain_cookie = try login(&h, "plain@example.com", temporary);
    defer gpa.free(plain_cookie);

    var raw = try rawHttp(&h, .GET, "/api/admin/users", null, plain_cookie);
    defer raw.deinit();
    try testing.expectEqual(@as(u16, 403), raw.status);

    // And it may not change anybody, including itself.
    const promote_path = try std.fmt.allocPrint(gpa, "/api/admin/users/{s}", .{user_id});
    defer gpa.free(promote_path);
    var patch = try rawHttp(&h, .PATCH, promote_path, "{\"role\":\"admin\"}", plain_cookie);
    defer patch.deinit();
    try testing.expectEqual(@as(u16, 403), patch.status);
}

// A new account comes with a temporary password that signs in.
test "new_account_gets_a_temporary_password_that_signs_in" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "owner@example.com", "supersecret123");
    const owner_cookie = try login(&h, "owner@example.com", "supersecret123");
    defer gpa.free(owner_cookie);

    var created = try rawHttp(&h, .POST, "/api/admin/users",
        \\{"email":"fresh@example.com","name":"Fresh","role":"user"}
    , owner_cookie);
    defer created.deinit();
    try testing.expectEqual(@as(u16, 201), created.status);

    var doc = try created.json();
    defer doc.deinit();
    const temporary = doc.str("temporary_password").?;
    try testing.expect(temporary.len >= 8);

    // The account is in the list the owner sees.
    var list = try rawHttp(&h, .GET, "/api/admin/users", null, owner_cookie);
    defer list.deinit();
    try testing.expectEqual(@as(u16, 200), list.status);
    var list_doc = try list.json();
    defer list_doc.deinit();
    const listed = list_doc.array("users").?.items;
    var listed_new = false;
    for (listed) |item| {
        if (std.mem.eql(u8, item.object.get("email").?.string, "fresh@example.com")) listed_new = true;
    }
    try testing.expect(listed_new);

    // And it can sign in with the password the console handed out.
    const fresh_cookie = try login(&h, "fresh@example.com", temporary);
    defer gpa.free(fresh_cookie);
    var me = try rawHttp(&h, .GET, "/api/auth/me", null, fresh_cookie);
    defer me.deinit();
    try testing.expectEqual(@as(u16, 200), me.status);
}

// The "forgot password" case: the owner resets it, the old session dies and
// the new password signs in.
test "reset_password_revokes_the_old_session_and_opens_the_new_one" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "owner@example.com", "supersecret123");
    const owner_cookie = try login(&h, "owner@example.com", "supersecret123");
    defer gpa.free(owner_cookie);

    var created = try rawHttp(&h, .POST, "/api/admin/users",
        \\{"email":"lost@example.com","name":"Lost","role":"user"}
    , owner_cookie);
    defer created.deinit();
    try testing.expectEqual(@as(u16, 201), created.status);
    var created_doc = try created.json();
    defer created_doc.deinit();
    const first_password = created_doc.str("temporary_password").?;
    const user_id = created_doc.object("user").?.get("id").?.string;

    // The account signs in with the first password.
    const lost_cookie = try login(&h, "lost@example.com", first_password);
    defer gpa.free(lost_cookie);
    {
        var me = try rawHttp(&h, .GET, "/api/auth/me", null, lost_cookie);
        defer me.deinit();
        try testing.expectEqual(@as(u16, 200), me.status);
    }

    // The owner resets the password.
    const path = try std.fmt.allocPrint(gpa, "/api/admin/users/{s}/password", .{user_id});
    defer gpa.free(path);
    var reset = try rawHttp(&h, .POST, path, "{}", owner_cookie);
    defer reset.deinit();
    try testing.expectEqual(@as(u16, 200), reset.status);
    var reset_doc = try reset.json();
    defer reset_doc.deinit();
    const second_password = reset_doc.str("temporary_password").?;
    try testing.expect(second_password.len >= 8);
    try testing.expect(!std.mem.eql(u8, first_password, second_password));

    // The session opened with the old password stops working.
    {
        var me = try rawHttp(&h, .GET, "/api/auth/me", null, lost_cookie);
        defer me.deinit();
        try testing.expectEqual(@as(u16, 401), me.status);
    }

    // The new password signs in.
    const new_cookie = try login(&h, "lost@example.com", second_password);
    defer gpa.free(new_cookie);
    {
        var me = try rawHttp(&h, .GET, "/api/auth/me", null, new_cookie);
        defer me.deinit();
        try testing.expectEqual(@as(u16, 200), me.status);
    }
}

// The last owner cannot be switched off: the console refuses.
test "the_last_owner_cannot_be_switched_off" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "owner@example.com", "supersecret123");
    const owner_cookie = try login(&h, "owner@example.com", "supersecret123");
    defer gpa.free(owner_cookie);

    var list = try rawHttp(&h, .GET, "/api/admin/users", null, owner_cookie);
    defer list.deinit();
    var doc = try list.json();
    defer doc.deinit();
    const users = doc.array("users").?;
    try testing.expectEqual(@as(usize, 1), users.items.len);
    const owner_id = users.items[0].object.get("id").?.string;

    const owner_path = try std.fmt.allocPrint(gpa, "/api/admin/users/{s}", .{owner_id});
    defer gpa.free(owner_path);
    var patch = try rawHttp(&h, .PATCH, owner_path, "{\"is_active\":false}", owner_cookie);
    defer patch.deinit();
    try testing.expectEqual(@as(u16, 409), patch.status);
}

// The VM panel answers on a host that runs no VMs: it says so rather than
// failing, and it refuses a size outside the limits.
test "vm_panel_reports_no_manager_and_refuses_a_bad_size" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var raw = try rawHttp(&h, .GET, "/api/admin/vms", null, null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 200), raw.status);
        var doc = try raw.json();
        defer doc.deinit();
        try testing.expectEqual(false, doc.boolean("manager").?);
        try testing.expectEqual(@as(i64, 0), doc.int("count").?);
        // The form is told what it may ask for.
        const limits = doc.object("limits").?;
        try testing.expectEqual(@as(i64, 1), limits.get("min_vcpus").?.integer);
        try testing.expectEqual(@as(i64, 8), limits.get("max_vcpus").?.integer);
        try testing.expectEqual(@as(i64, 128), limits.get("min_disk_mib").?.integer);
        try testing.expectEqual(@as(i64, 65536), limits.get("max_disk_mib").?.integer);
    }
    {
        // A workspace the console lists comes back as TEXT, not as the row's
        // bytes: the answer outlives the row it was read from.
        var created = try rawHttp(&h, .POST, "/api/workspaces", "{\"name\":\"VM test\"}", null);
        defer created.deinit();
        try testing.expectEqual(@as(u16, 201), created.status);

        var raw = try rawHttp(&h, .GET, "/api/admin/vms", null, null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 200), raw.status);
        var doc = try raw.json();
        defer doc.deinit();
        const listed = doc.array("vms").?.items;
        try testing.expectEqual(@as(usize, 1), listed.len);
        const name = listed[0].object.get("workspace_name").?;
        switch (name) {
            .string => |text| try testing.expectEqualStrings("VM test", text),
            else => return error.WorkspaceNameIsNotAString,
        }
        // A machine that never booted has an account of its storage, and that
        // account is zero, not a missing field.
        try testing.expectEqual(@as(i64, 0), listed[0].object.get("disk_mib").?.integer);
    }
    {
        // A size in range on a host with no manager: 503, not a silent no-op.
        var raw = try rawHttp(&h, .POST, "/api/admin/vms/ws_1/resize", "{\"vcpus\":2,\"mem_mib\":1024}", null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 503), raw.status);
    }
    {
        // A storage target below the floor never reaches the manager.
        var raw = try rawHttp(&h, .POST, "/api/admin/vms/ws_1/resize", "{\"vcpus\":2,\"mem_mib\":1024,\"disk_mib\":64}", null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 400), raw.status);
        var doc = try raw.json();
        defer doc.deinit();
        try testing.expectEqualStrings("disk_mib must be 128..65536", doc.str("error").?);
    }
    {
        // A size outside the limits is refused before the manager is asked.
        var raw = try rawHttp(&h, .POST, "/api/admin/vms/ws_1/resize", "{\"vcpus\":99,\"mem_mib\":1024}", null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 400), raw.status);
        var doc = try raw.json();
        defer doc.deinit();
        try testing.expectEqualStrings("vcpus must be 1..8", doc.str("error").?);
    }
}

// The VM panel is the owner's: 401 without a session, 403 for a non-owner.
test "vm_panel_refuses_anonymous_and_non_owners" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var raw = try rawHttp(&h, .GET, "/api/admin/vms", null, null);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 401), raw.status);
    }

    try createAdmin(h.temp_dir, "owner@example.com", "supersecret123");
    const owner_cookie = try login(&h, "owner@example.com", "supersecret123");
    defer gpa.free(owner_cookie);

    var created = try rawHttp(&h, .POST, "/api/admin/users",
        \\{"email":"plain@example.com","name":"Plain","role":"user"}
    , owner_cookie);
    defer created.deinit();
    try testing.expectEqual(@as(u16, 201), created.status);
    var created_doc = try created.json();
    defer created_doc.deinit();
    const temporary = created_doc.str("temporary_password").?;

    const plain_cookie = try login(&h, "plain@example.com", temporary);
    defer gpa.free(plain_cookie);

    {
        var raw = try rawHttp(&h, .GET, "/api/admin/vms", null, plain_cookie);
        defer raw.deinit();
        try testing.expectEqual(@as(u16, 403), raw.status);
    }
}

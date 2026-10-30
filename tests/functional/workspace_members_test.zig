const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

const admin_a = "owner@example.com";
const admin_b = "teammate@example.com";
const password = "supersecret123";

/// Issue a request WITHOUT a status assertion — the caller asserts, because
/// the status IS the behaviour under test.
fn send(
    h: *Harness,
    method: harness.HttpMethod,
    path: []const u8,
    body: ?[]const u8,
    cookie: []const u8,
) !harness.Response {
    return h.http(io, method, path, .{
        .json_body = body,
        .extra_headers = &.{.{ .name = "Cookie", .value = cookie }},
        .assert_status = false,
    });
}

fn bootAuth() !Harness {
    return Harness.boot(io, gpa, .{ .extra_args = &.{"--auth"} });
}

fn createAdmin(home: []const u8, email: []const u8, force: bool) !void {
    var argv: [8][]const u8 = undefined;
    var n: usize = 0;
    argv[n] = "create-admin";
    n += 1;
    argv[n] = "--email";
    n += 1;
    argv[n] = email;
    n += 1;
    argv[n] = "--password";
    n += 1;
    argv[n] = password;
    n += 1;
    if (force) {
        argv[n] = "--force";
        n += 1;
    }

    var r = try harness.runPabrikCommand(io, gpa, home, argv[0..n], 30_000);
    defer r.deinit(gpa);
    if (r.exit_code == null or r.exit_code.? != 0) {
        std.debug.print("create-admin failed (rc={?}): {s}\n", .{ r.exit_code, r.stderr });
        return error.TestUnexpectedResult;
    }
}

/// Log in and return the `pabrik_session=…` header value, owned by the caller.
fn login(h: *Harness, email: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"email\":\"{s}\",\"password\":\"{s}\"}}", .{ email, password });
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/auth/login", .{
        .json_body = body,
        .assert_status = false,
    });
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);

    const set_cookie = r.header("Set-Cookie") orelse return error.TestUnexpectedResult;
    const token = harness.afterFirst(set_cookie, "pabrik_session=") orelse return error.TestUnexpectedResult;
    var it = std.mem.splitSequence(u8, token, ";");
    const first = it.next() orelse return error.TestUnexpectedResult;
    return std.fmt.allocPrint(gpa, "pabrik_session={s}", .{std.mem.trim(u8, first, " \t\r\n")});
}

/// The workspace the caller owns. Each `create-admin` provisions one Default
/// workspace, and nobody else is a member of it yet.
fn ownedWorkspaceId(h: *Harness, cookie: []const u8) ![]u8 {
    var r = try send(h, .GET, "/api/workspaces", null, cookie);
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);

    var doc = try r.json();
    defer doc.deinit();
    const arr = doc.array("workspaces") orelse return error.TestUnexpectedResult;
    if (arr.items.len == 0) return error.TestUnexpectedResult;
    const id = arr.items[0].object.get("id") orelse return error.TestUnexpectedResult;
    return gpa.dupe(u8, id.string);
}

fn membersJson(h: *Harness, workspace_id: []const u8, cookie: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/members", .{workspace_id});
    defer gpa.free(path);
    var r = try send(h, .GET, path, null, cookie);
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);
    return gpa.dupe(u8, r.body);
}

const World = struct {
    h: Harness,
    cookie_a: []u8,
    cookie_b: []u8,
    ws_a: []u8,

    fn boot() !World {
        var h = try bootAuth();
        errdefer h.deinit(io) catch {};
        try createAdmin(h.temp_dir, admin_a, false);
        try createAdmin(h.temp_dir, admin_b, true);

        const cookie_a = try login(&h, admin_a);
        errdefer gpa.free(cookie_a);
        const cookie_b = try login(&h, admin_b);
        errdefer gpa.free(cookie_b);
        const ws_a = try ownedWorkspaceId(&h, cookie_a);
        return .{ .h = h, .cookie_a = cookie_a, .cookie_b = cookie_b, .ws_a = ws_a };
    }

    fn deinit(self: *World) void {
        gpa.free(self.cookie_a);
        gpa.free(self.cookie_b);
        gpa.free(self.ws_a);
        self.h.deinit(io) catch |err| {
            std.debug.print("teardown: {s}\n", .{@errorName(err)});
        };
    }
};

test "invite by email adds the account, and the member list shows both sides" {
    try harness.requirePabrikBin(io, gpa);
    var world = try World.boot();
    defer world.deinit();

    {
        const json = try membersJson(&world.h, world.ws_a, world.cookie_a);
        defer gpa.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"count\":1") != null);
        try testing.expect(std.mem.indexOf(u8, json, admin_a) != null);
        try testing.expect(std.mem.indexOf(u8, json, admin_b) == null);
    }

    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/members", .{world.ws_a});
        defer gpa.free(path);
        var r = try send(&world.h, .POST, path, "{\"email\":\"ghost@example.com\",\"role\":\"viewer\"}", world.cookie_a);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 404), r.status);
        try testing.expect(std.mem.indexOf(u8, r.body, "ghost@example.com") != null);
    }

    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/members", .{world.ws_a});
        defer gpa.free(path);
        var r = try send(&world.h, .POST, path, "{\"email\":\"teammate@example.com\",\"role\":\"editor\"}", world.cookie_a);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 201), r.status);
        try testing.expect(std.mem.indexOf(u8, r.body, admin_b) != null);
        try testing.expect(std.mem.indexOf(u8, r.body, "\"role\":\"editor\"") != null);
    }

    // Read back through the LIST, not the invite's own echo.
    {
        const json = try membersJson(&world.h, world.ws_a, world.cookie_a);
        defer gpa.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"count\":2") != null);
        try testing.expect(std.mem.indexOf(u8, json, admin_b) != null);
        // Owners sort first, so the first row is still the owner, not the invitee.
        const owner_at = std.mem.indexOf(u8, json, "\"role\":\"owner\"").?;
        const editor_at = std.mem.indexOf(u8, json, "\"role\":\"editor\"").?;
        try testing.expect(owner_at < editor_at);
    }

    // The invited account can now see the workspace it was invited to.
    {
        const json = try membersJson(&world.h, world.ws_a, world.cookie_b);
        defer gpa.free(json);
        try testing.expect(std.mem.indexOf(u8, json, admin_a) != null);
    }

    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/members", .{world.ws_a});
        defer gpa.free(path);
        var r = try send(&world.h, .POST, path, "{\"email\":\"teammate@example.com\"}", world.cookie_a);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 409), r.status);
    }
}

test "an editor may read the member list but may not change it" {
    try harness.requirePabrikBin(io, gpa);
    var world = try World.boot();
    defer world.deinit();

    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/members", .{world.ws_a});
        defer gpa.free(path);
        var r = try send(&world.h, .POST, path, "{\"email\":\"teammate@example.com\",\"role\":\"editor\"}", world.cookie_a);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 201), r.status);
    }

    const members_path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/members", .{world.ws_a});
    defer gpa.free(members_path);

    {
        var r = try send(&world.h, .GET, members_path, null, world.cookie_b);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
    }

    // Write: refused with 403 — the workspace is visible, the action is not.
    {
        var r = try send(&world.h, .POST, members_path, "{\"email\":\"owner@example.com\",\"role\":\"viewer\"}", world.cookie_b);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 403), r.status);
        try testing.expect(std.mem.indexOf(u8, r.body, "owner or admin") != null);
    }

    // Promote the editor to admin, then the same call succeeds. The invitee's
    // id is not known up front, so read it from the list.
    {
        const json = try membersJson(&world.h, world.ws_a, world.cookie_a);
        defer gpa.free(json);
        var doc = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
        defer doc.deinit();
        const members = doc.value.object.get("members").?.array;
        var teammate_id: ?[]const u8 = null;
        for (members.items) |m| {
            const obj = m.object;
            if (std.mem.eql(u8, obj.get("email").?.string, admin_b)) {
                teammate_id = obj.get("user_id").?.string;
            }
        }
        const id = teammate_id orelse return error.TestUnexpectedResult;

        const promote = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/members/{s}", .{ world.ws_a, id });
        defer gpa.free(promote);
        var r = try send(&world.h, .PATCH, promote, "{\"role\":\"admin\"}", world.cookie_a);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
        try testing.expect(std.mem.indexOf(u8, r.body, "\"role\":\"admin\"") != null);
    }

    {
        var r = try send(&world.h, .POST, members_path, "{\"email\":\"owner@example.com\",\"role\":\"viewer\"}", world.cookie_b);
        defer r.deinit();
        // Already a member → 409 rather than 403: the gate let the call through.
        try testing.expectEqual(@as(u16, 409), r.status);
    }
}

test "a workspace cannot be left without an owner" {
    try harness.requirePabrikBin(io, gpa);
    var world = try World.boot();
    defer world.deinit();

    {
        const list = try membersJson(&world.h, world.ws_a, world.cookie_a);
        defer gpa.free(list);
        var doc = try std.json.parseFromSlice(std.json.Value, gpa, list, .{});
        defer doc.deinit();
        const self_id = doc.value.object.get("members").?.array.items[0].object.get("user_id").?.string;

        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/members/{s}", .{ world.ws_a, self_id });
        defer gpa.free(path);

        var patch = try send(&world.h, .PATCH, path, "{\"role\":\"viewer\"}", world.cookie_a);
        defer patch.deinit();
        try testing.expectEqual(@as(u16, 409), patch.status);
        try testing.expect(std.mem.indexOf(u8, patch.body, "at least one owner") != null);

        var del = try send(&world.h, .DELETE, path, null, world.cookie_a);
        defer del.deinit();
        try testing.expectEqual(@as(u16, 409), del.status);

        const after = try membersJson(&world.h, world.ws_a, world.cookie_a);
        defer gpa.free(after);
        try testing.expect(std.mem.indexOf(u8, after, "\"count\":1") != null);
        try testing.expect(std.mem.indexOf(u8, after, "\"role\":\"owner\"") != null);
    }

    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/members", .{world.ws_a});
        defer gpa.free(path);
        var r = try send(&world.h, .POST, path, "{\"email\":\"teammate@example.com\",\"role\":\"owner\"}", world.cookie_a);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 201), r.status);

        const list = try membersJson(&world.h, world.ws_a, world.cookie_a);
        defer gpa.free(list);
        var doc = try std.json.parseFromSlice(std.json.Value, gpa, list, .{});
        defer doc.deinit();
        var a_id: ?[]const u8 = null;
        for (doc.value.object.get("members").?.array.items) |m| {
            if (std.mem.eql(u8, m.object.get("email").?.string, admin_a)) a_id = m.object.get("user_id").?.string;
        }
        const id = a_id orelse return error.TestUnexpectedResult;

        const member_path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/members/{s}", .{ world.ws_a, id });
        defer gpa.free(member_path);
        var patch = try send(&world.h, .PATCH, member_path, "{\"role\":\"viewer\"}", world.cookie_a);
        defer patch.deinit();
        try testing.expectEqual(@as(u16, 200), patch.status);
        try testing.expect(std.mem.indexOf(u8, patch.body, "\"role\":\"viewer\"") != null);
    }
}

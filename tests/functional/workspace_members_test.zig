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

fn inboxJson(h: *Harness, cookie: []const u8) ![]u8 {
    var r = try send(h, .GET, "/api/invitations", null, cookie);
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);
    return gpa.dupe(u8, r.body);
}

/// Invite `email` into `workspace_id` and return the invitation id (owned).
fn invite(h: *Harness, workspace_id: []const u8, cookie: []const u8, email: []const u8, role: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/invitations", .{workspace_id});
    defer gpa.free(path);
    const body = try std.fmt.allocPrint(gpa, "{{\"email\":\"{s}\",\"role\":\"{s}\"}}", .{ email, role });
    defer gpa.free(body);

    var r = try send(h, .POST, path, body, cookie);
    defer r.deinit();
    if (r.status != 201) {
        std.debug.print("invite failed {d}: {s}\n", .{ r.status, r.body });
        return error.TestUnexpectedResult;
    }
    var doc = try std.json.parseFromSlice(std.json.Value, gpa, r.body, .{});
    defer doc.deinit();
    const id = doc.value.object.get("invitation").?.object.get("id").?.string;
    return gpa.dupe(u8, id);
}

fn countIn(json: []const u8) !i64 {
    var doc = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer doc.deinit();
    return doc.value.object.get("count").?.integer;
}

/// One harness with two accounts, each owning its own workspace.
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

test "an invite is a pending request: the invitee gains NO access until it is accepted" {
    try harness.requirePabrikBin(io, gpa);
    var world = try World.boot();
    defer world.deinit();

    const invitation_id = try invite(&world.h, world.ws_a, world.cookie_a, admin_b, "editor");
    defer gpa.free(invitation_id);

    // The inviter's member list still has ONE row: an invitation is not a member.
    {
        const json = try membersJson(&world.h, world.ws_a, world.cookie_a);
        defer gpa.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"count\":1") != null);
        try testing.expect(std.mem.indexOf(u8, json, admin_b) == null);
    }

    // And the workspace is still invisible to the person who was asked.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/members", .{world.ws_a});
        defer gpa.free(path);
        var r = try send(&world.h, .GET, path, null, world.cookie_b);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 404), r.status);
    }

    // The ask IS visible in the invitee's own inbox, naming the workspace.
    {
        const json = try inboxJson(&world.h, world.cookie_b);
        defer gpa.free(json);
        try testing.expectEqual(@as(i64, 1), try countIn(json));
        try testing.expect(std.mem.indexOf(u8, json, "\"workspace_id\":\"ws_") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"role\":\"editor\"") != null);
    }

    // The inviter sees it waiting, and can revoke it.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/invitations", .{world.ws_a});
        defer gpa.free(path);
        var r = try send(&world.h, .GET, path, null, world.cookie_a);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
        try testing.expect(std.mem.indexOf(u8, r.body, admin_b) != null);
    }
}

test "accepting the invitation is what creates the membership" {
    try harness.requirePabrikBin(io, gpa);
    var world = try World.boot();
    defer world.deinit();

    const invitation_id = try invite(&world.h, world.ws_a, world.cookie_a, admin_b, "editor");
    defer gpa.free(invitation_id);

    // A third party cannot answer someone else's invitation: 404, never 403.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/invitations/{s}/accept", .{invitation_id});
        defer gpa.free(path);
        var r = try send(&world.h, .POST, path, null, world.cookie_a);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 404), r.status);
        // …and it is still pending afterwards.
        const json = try inboxJson(&world.h, world.cookie_b);
        defer gpa.free(json);
        try testing.expectEqual(@as(i64, 1), try countIn(json));
    }

    {
        const path = try std.fmt.allocPrint(gpa, "/api/invitations/{s}/accept", .{invitation_id});
        defer gpa.free(path);
        var r = try send(&world.h, .POST, path, null, world.cookie_b);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
        try testing.expect(std.mem.indexOf(u8, r.body, "\"role\":\"editor\"") != null);
        try testing.expect(std.mem.indexOf(u8, r.body, admin_b) != null);
    }

    // Now — and only now — the workspace is readable by the invitee.
    {
        const json = try membersJson(&world.h, world.ws_a, world.cookie_b);
        defer gpa.free(json);
        try testing.expectEqual(@as(i64, 2), try countIn(json));
    }

    // The ask is consumed, and the workspace appears in the invitee's own list.
    {
        const json = try inboxJson(&world.h, world.cookie_b);
        defer gpa.free(json);
        try testing.expectEqual(@as(i64, 0), try countIn(json));
    }
    {
        var r = try send(&world.h, .GET, "/api/workspaces", null, world.cookie_b);
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, r.body, world.ws_a) != null);
    }
}

test "declining and revoking both remove the request and grant nothing" {
    try harness.requirePabrikBin(io, gpa);
    var world = try World.boot();
    defer world.deinit();

    // Decline.
    {
        const invitation_id = try invite(&world.h, world.ws_a, world.cookie_a, admin_b, "viewer");
        defer gpa.free(invitation_id);
        const path = try std.fmt.allocPrint(gpa, "/api/invitations/{s}/decline", .{invitation_id});
        defer gpa.free(path);
        var r = try send(&world.h, .POST, path, null, world.cookie_b);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
    }
    {
        const json = try inboxJson(&world.h, world.cookie_b);
        defer gpa.free(json);
        try testing.expectEqual(@as(i64, 0), try countIn(json));
    }
    {
        const json = try membersJson(&world.h, world.ws_a, world.cookie_a);
        defer gpa.free(json);
        try testing.expectEqual(@as(i64, 1), try countIn(json));
    }

    // Re-invite, then the inviter revokes it.
    const revoked_id = try invite(&world.h, world.ws_a, world.cookie_a, admin_b, "viewer");
    defer gpa.free(revoked_id);
    {
        const path = try std.fmt.allocPrint(
            gpa,
            "/api/workspaces/{s}/invitations/{s}",
            .{ world.ws_a, revoked_id },
        );
        defer gpa.free(path);
        var r = try send(&world.h, .DELETE, path, null, world.cookie_a);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
    }
    {
        const json = try inboxJson(&world.h, world.cookie_b);
        defer gpa.free(json);
        try testing.expectEqual(@as(i64, 0), try countIn(json));
    }
    {
        // A revoked invitation cannot be accepted afterwards.
        const path = try std.fmt.allocPrint(gpa, "/api/invitations/{s}/accept", .{revoked_id});
        defer gpa.free(path);
        var r = try send(&world.h, .POST, path, null, world.cookie_b);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 404), r.status);
    }
}

test "inviting needs owner or admin; an invited editor may read but not invite" {
    try harness.requirePabrikBin(io, gpa);
    var world = try World.boot();
    defer world.deinit();

    const invitation_id = try invite(&world.h, world.ws_a, world.cookie_a, admin_b, "editor");
    defer gpa.free(invitation_id);
    {
        const path = try std.fmt.allocPrint(gpa, "/api/invitations/{s}/accept", .{invitation_id});
        defer gpa.free(path);
        var r = try send(&world.h, .POST, path, null, world.cookie_b);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
    }

    // Read: allowed now that they are a member.
    {
        const json = try membersJson(&world.h, world.ws_a, world.cookie_b);
        defer gpa.free(json);
        try testing.expect(std.mem.indexOf(u8, json, admin_a) != null);
    }

    // Invite: refused — a member, but an editor.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/invitations", .{world.ws_a});
        defer gpa.free(path);
        var r = try send(&world.h, .POST, path, "{\"email\":\"owner@example.com\",\"role\":\"viewer\"}", world.cookie_b);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 403), r.status);
        try testing.expect(std.mem.indexOf(u8, r.body, "owner or admin") != null);
    }
}

test "invite answers 404 for an unknown address and 409 for a duplicate ask" {
    try harness.requirePabrikBin(io, gpa);
    var world = try World.boot();
    defer world.deinit();

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/invitations", .{world.ws_a});
    defer gpa.free(path);

    {
        var r = try send(&world.h, .POST, path, "{\"email\":\"ghost@example.com\",\"role\":\"viewer\"}", world.cookie_a);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 404), r.status);
        try testing.expect(std.mem.indexOf(u8, r.body, "ghost@example.com") != null);
    }

    const invitation_id = try invite(&world.h, world.ws_a, world.cookie_a, admin_b, "viewer");
    defer gpa.free(invitation_id);
    {
        var r = try send(&world.h, .POST, path, "{\"email\":\"teammate@example.com\",\"role\":\"admin\"}", world.cookie_a);
        defer r.deinit();
        try testing.expectEqual(@as(u16, 409), r.status);
        try testing.expect(std.mem.indexOf(u8, r.body, "pending invitation") != null);
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
        try testing.expectEqual(@as(i64, 1), try countIn(after));
    }
}

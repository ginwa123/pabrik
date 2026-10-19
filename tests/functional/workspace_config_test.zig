//! Functional tests for the per-workspace config overlay (Migration 105) over
//! the wire.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// A user-level config with BOTH kinds of key: the ones that move to a
/// workspace (profiles, tools) and the ones that must keep applying
/// everywhere (notify_on_complete, retry_delay_ms).
const USER_CONFIG =
    \\{"profiles":{"stub":{"model":"stub-model","base_url":"http://127.0.0.1:1","api_key":"stub-key-not-real"},
    \\ "extra":{"model":"extra-model","base_url":"http://127.0.0.1:1","api_key":"extra-key-not-real"}},
    \\ "active_profile":"extra",
    \\ "tools":["command","glob"],
    \\ "notify_on_complete":true,
    \\ "notify_on_error":true,
    \\ "retry_delay_ms":1234,
    \\ "web_search":{"brave":{"url":"https://api.search.brave.com",
    \\  "key":"SENTINEL_SEARCH_KEY",
    \\  "curl":"https://api.search.brave.com/res/v1/web/search?q=PLACEHOLDER -H \"X-Subscription-Token: {key}\""}}}
;

const SENTINEL = "SENTINEL_SEARCH_KEY";

fn boot() !Harness {
    try harness.requirePabrikBin(io, gpa);
    // The stub profile makes the binary boot without a real API key; the tests
    // then PUT their own user config over it.
    return Harness.boot(io, gpa, .{ .stub_llm_profile = true });
}

/// POST /api/workspaces and return the new id (owned).
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);
    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse return error.NoWorkspaceId;
    return gpa.dupe(u8, id);
}

/// PUT the whole user config (the same body the Settings page sends).
fn putUserConfig(h: *Harness) !void {
    try putUserConfigBody(h, USER_CONFIG);
}

fn putUserConfigBody(h: *Harness, body: []const u8) !void {
    var r = try h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
}

fn wsPath(allocator: std.mem.Allocator, workspace_id: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "/api/workspaces/{s}/config{s}", .{ workspace_id, suffix });
}

/// `DELETE /api/workspaces/<ws>/config/profiles/<name>`. Caller `deinit`s.
fn deleteWorkspaceProfile(
    h: *Harness,
    workspace_id: []const u8,
    name: []const u8,
    expect: []const u16,
) !harness.Response {
    const suffix = try std.fmt.allocPrint(gpa, "/profiles/{s}", .{name});
    defer gpa.free(suffix);
    const path = try wsPath(gpa, workspace_id, suffix);
    defer gpa.free(path);
    return h.http(io, .DELETE, path, .{ .expect = expect });
}

/// The user-level `config.json` as stored (file mode: `--auth` off). The GET
/// response masks the web_search key, so only the file proves it survived.
fn readUserConfigFile(h: *Harness) ![]u8 {
    const parts = [_][]const u8{ h.temp_dir, ".config", "pabrik", "config.json" };
    const path = try std.fs.path.join(gpa, &parts);
    defer gpa.free(path);
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return try reader.interface.allocRemaining(gpa, .limited(1024 * 1024));
}

/// GET a workspace's effective config. `profiles` being PRESENT is also the
/// route-order probe: a request captured by another `/api/workspaces/:id/...`
/// route would not answer with the config shape at all.
fn getWorkspaceConfig(h: *Harness, workspace_id: []const u8) !struct { r: harness.Response, doc: harness.Json } {
    const path = try wsPath(gpa, workspace_id, "");
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    errdefer r.deinit();
    var doc = try r.json();
    if (doc.object("profiles") == null) {
        doc.deinit();
        r.deinit();
        return error.NotTheConfigShape;
    }
    return .{ .r = r, .doc = doc };
}

fn toolNames(doc: *const harness.Json) ![]const []const u8 {
    const arr = doc.array("tools") orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    for (arr.items) |item| {
        switch (item) {
            .string => |s| try out.append(gpa, s),
            else => return error.NotAString,
        }
    }
    return out.toOwnedSlice(gpa);
}

// ============================================================================
// The route answers as the config handler, not as a sibling workspace route
// ============================================================================

test "workspace_config_route_answers_the_config_handler" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const id = try createWorkspace(&h, "Route Probe");
    defer gpa.free(id);

    // A 200 whose body carries `profiles` is the config handler's shape (the
    // helper asserts it).
    var got = try getWorkspaceConfig(&h, id);
    defer got.doc.deinit();
    defer got.r.deinit();
    // The stub profile the harness booted with is what this fresh workspace
    // resolves to - the point here is the SHAPE, which the helper asserts.
    const profiles = got.doc.object("profiles") orelse return error.NoProfiles;
    try testing.expect(profiles.get("stub") != null);
}

// ============================================================================
// Creation: a new workspace takes its OWN copy of the scoped settings
// ============================================================================

test "workspace_config_copies_the_user_config_at_creation" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const id = try createWorkspace(&h, "Copied");
    defer gpa.free(id);

    var got = try getWorkspaceConfig(&h, id);
    defer got.doc.deinit();
    defer got.r.deinit();

    // The profiles this workspace owns, copied from the user config when it
    // was created - they are what a run here uses.
    const profiles = got.doc.object("profiles") orelse return error.NoProfiles;
    try testing.expect(profiles.get("stub") != null);
    try testing.expect(profiles.get("extra") != null);
    try testing.expectEqualStrings("extra", got.doc.str("active_profile").?);
    // The General keys stay shared with the user config.
    try testing.expectEqual(true, got.doc.boolean("notify_on_complete").?);
    try testing.expectEqual(@as(i64, 1234), got.doc.int("retry_delay_ms").?);
}

test "workspace_config_does_not_follow_a_later_user_config_change" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const id = try createWorkspace(&h, "Frozen");
    defer gpa.free(id);

    // The user edits their own settings afterwards: a new profile, and a
    // different active one.
    try putUserConfigBody(&h,
        \\{"profiles":{"stub":{"model":"stub-model","base_url":"http://127.0.0.1:1","api_key":"stub-key-not-real"},
        \\ "added":{"model":"added-model","base_url":"http://127.0.0.1:1","api_key":"added-key-not-real"}},
        \\ "active_profile":"stub",
        \\ "tools":["command","glob"],
        \\ "notify_on_complete":true,
        \\ "retry_delay_ms":4321}
    );

    var got = try getWorkspaceConfig(&h, id);
    defer got.doc.deinit();
    defer got.r.deinit();
    const profiles = got.doc.object("profiles") orelse return error.NoProfiles;
    // The workspace kept its own copy...
    try testing.expect(profiles.get("stub") != null);
    try testing.expect(profiles.get("extra") != null);
    // ...the profile added afterwards is NOT inherited...
    try testing.expect(profiles.get("added") == null);
    try testing.expectEqualStrings("extra", got.doc.str("active_profile").?);
    // ...and General still tracks the user config.
    try testing.expectEqual(@as(i64, 4321), got.doc.int("retry_delay_ms").?);
}

// ============================================================================
// PUT: only the workspace-scoped keys move; the user config is untouched
// ============================================================================

test "workspace_config_put_overrides_only_the_workspace_scoped_keys" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const id = try createWorkspace(&h, "Overrides");
    defer gpa.free(id);

    // The SAME body shape the settings page PUTs: scoped keys AND General
    // keys. Only the scoped ones may be stored.
    const body =
        \\{"profiles":{"extra":{"model":"sonnet","base_url":"http://127.0.0.1:1","api_key":"extra-key-not-real"}},
        \\ "tools":["command"],
        \\ "notify_on_complete":false,
        \\ "retry_delay_ms":9}
    ;
    {
        const path = try wsPath(gpa, id, "");
        defer gpa.free(path);
        var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
    }

    {
        var got = try getWorkspaceConfig(&h, id);
        defer got.doc.deinit();
        defer got.r.deinit();

        // The workspace's own values won...
        const tools = try toolNames(&got.doc);
        defer gpa.free(tools);
        try testing.expectEqual(@as(usize, 1), tools.len);
        try testing.expectEqualStrings("command", tools[0]);
        const profiles = got.doc.object("profiles") orelse return error.NoProfiles;
        try testing.expectEqualStrings(
            "sonnet",
            profiles.get("extra").?.object.get("model").?.string,
        );
        // ...and the user's own profile is NOT part of this scope: the
        // workspace owns the list it just PUT.
        try testing.expect(profiles.get("stub") == null);
        // The General keys are the USER's, not the body's: they were sliced
        // out, so a change to them here cannot silently freeze them.
        try testing.expectEqual(true, got.doc.boolean("notify_on_complete").?);
        try testing.expectEqual(@as(i64, 1234), got.doc.int("retry_delay_ms").?);
    }

    // THE ISOLATION PROOF: the user-scope config did not move at all.
    {
        var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const tools = try toolNames(&doc);
        defer gpa.free(tools);
        try testing.expectEqual(@as(usize, 2), tools.len);
        try testing.expectEqualStrings("command", tools[0]);
        try testing.expectEqualStrings("glob", tools[1]);
        try testing.expectEqualStrings("extra", doc.str("active_profile").?);
    }
}

// ============================================================================
// PUT refusals: nothing scoped, and malformed JSON
// ============================================================================

test "workspace_config_put_refuses_a_body_with_nothing_workspace_scoped" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const id = try createWorkspace(&h, "NothingScoped");
    defer gpa.free(id);

    const path = try wsPath(gpa, id, "");
    defer gpa.free(path);

    {
        // Storing this would look like a successful save while every setting
        // the user typed stayed at user level - so it is a 400 instead.
        var r = try h.http(io, .PUT, path, .{
            .json_body = "{\"retry_delay_ms\":9,\"notify_on_complete\":false}",
            .expect = &.{400},
        });
        defer r.deinit();
    }
    {
        // The refusal changed nothing: the workspace still resolves to the
        // user's own list.
        var got = try getWorkspaceConfig(&h, id);
        defer got.doc.deinit();
        defer got.r.deinit();
        const tools = try toolNames(&got.doc);
        defer gpa.free(tools);
        try testing.expectEqual(@as(usize, 2), tools.len);
        try testing.expectEqualStrings("command", tools[0]);
        try testing.expectEqualStrings("glob", tools[1]);
    }
    {
        var r = try h.http(io, .PUT, path, .{ .json_body = "{\"tools\":", .expect = &.{400} });
        defer r.deinit();
    }
}

// ============================================================================
// An empty PUT body: the workspace drops its own copy
// ============================================================================

test "workspace_config_put_with_an_empty_body_leaves_no_scoped_settings" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const id = try createWorkspace(&h, "InheritAgain");
    defer gpa.free(id);

    const path = try wsPath(gpa, id, "");
    defer gpa.free(path);

    {
        var r = try h.http(io, .PUT, path, .{ .json_body = "{\"tools\":[\"command\"]}", .expect = &.{200} });
        defer r.deinit();
    }
    {
        var got = try getWorkspaceConfig(&h, id);
        defer got.doc.deinit();
        defer got.r.deinit();
        const tools = try toolNames(&got.doc);
        defer gpa.free(tools);
        try testing.expectEqual(@as(usize, 1), tools.len);
    }
    {
        // An EMPTY body means "inherit nothing", not "store an empty object" —
        // the documented sentinel the settings page sends when it resets a
        // workspace.
        var r = try h.http(io, .PUT, path, .{ .json_body = "", .expect = &.{200} });
        defer r.deinit();
    }
    {
        var got = try getWorkspaceConfig(&h, id);
        defer got.doc.deinit();
        defer got.r.deinit();
        // Nothing scoped comes back: the user config is no longer a source for
        // these keys, so a reset workspace has no tools and no profiles.
        const tools = try toolNames(&got.doc);
        defer gpa.free(tools);
        try testing.expectEqual(@as(usize, 0), tools.len);
        try testing.expectEqual(@as(usize, 0), got.doc.object("profiles").?.count());
        // General is still the user's.
        try testing.expectEqual(@as(i64, 1234), got.doc.int("retry_delay_ms").?);
    }
}

// ============================================================================
// Isolation between two workspaces
// ============================================================================

test "workspace_config_is_isolated_per_workspace" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const ws_a = try createWorkspace(&h, "Alpha");
    defer gpa.free(ws_a);
    const ws_b = try createWorkspace(&h, "Beta");
    defer gpa.free(ws_b);

    {
        const path = try wsPath(gpa, ws_a, "");
        defer gpa.free(path);
        var r = try h.http(io, .PUT, path, .{ .json_body = "{\"active_profile\":\"stub\"}", .expect = &.{200} });
        defer r.deinit();
    }

    {
        var a = try getWorkspaceConfig(&h, ws_a);
        defer a.doc.deinit();
        defer a.r.deinit();
        try testing.expectEqualStrings("stub", a.doc.str("active_profile").?);
    }
    {
        // Beta was never touched: it must still be inheriting, not borrowing
        // Alpha's override.
        var b = try getWorkspaceConfig(&h, ws_b);
        defer b.doc.deinit();
        defer b.r.deinit();
        try testing.expectEqualStrings("extra", b.doc.str("active_profile").?);
    }
}

// ============================================================================
// Masking: a provider key never reaches the browser on EITHER surface
// ============================================================================

test "workspace_config_masks_the_web_search_key" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const id = try createWorkspace(&h, "Masking");
    defer gpa.free(id);

    // The workspace inherits the user's providers, so this is the surface the
    // key would leak through if the response builder were forked.
    var got = try getWorkspaceConfig(&h, id);
    defer got.doc.deinit();
    defer got.r.deinit();

    try testing.expect(std.mem.indexOf(u8, got.r.body, SENTINEL) == null);
    // Positive control: the provider block IS on the wire, so the absence
    // above is masking and not a dropped section.
    try testing.expect(std.mem.indexOf(u8, got.r.body, "\"web_search\":{") != null);
    try testing.expect(std.mem.indexOf(u8, got.r.body, "\"key\":") != null);

    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.body, SENTINEL) == null);
}

// ============================================================================
// The profile picker's premise: a workspace-only profile is in the WORKSPACE
// config and NOT in the user config

test "a profile added to a workspace overlay is absent from the user-scope config" {
    // Why this is a wire fact and not a unit test: the two endpoints are the
    // two possible sources for ChatView's profile picker, and the bug was
    // asking the WRONG one.
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const id = try createWorkspace(&h, "Overlay Only Profile");
    defer gpa.free(id);

    const body =
        \\{"profiles":{"kilo":{"model":"nvidia/nemotron-3-super-120b-a12b:free",
        \\ "base_url":"https://api.kilo.ai/api/gateway/chat/completions",
        \\ "api_key":"kilo-key-not-real"}}}
    ;
    {
        const path = try wsPath(gpa, id, "");
        defer gpa.free(path);
        var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
    }

    // Workspace scope: the new profile AND the user's own, because the overlay
    // is layered over the user config rather than swapped in. This is what the
    // picker must offer.
    {
        var got = try getWorkspaceConfig(&h, id);
        defer got.doc.deinit();
        defer got.r.deinit();

        const profiles = got.doc.object("profiles") orelse return error.NoProfiles;
        try testing.expect(profiles.get("kilo") != null);
        try testing.expectEqualStrings(
            "nvidia/nemotron-3-super-120b-a12b:free",
            profiles.get("kilo").?.object.get("model").?.string,
        );
        // Positive control for the user half of the merge.
        try testing.expect(profiles.get("stub") != null);
    }

    // User scope: the picker's OLD source. The user's profiles are here (the
    // positive control), and the overlay-only profile is not.
    {
        var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        const profiles = doc.object("profiles") orelse return error.NoProfiles;
        try testing.expect(profiles.get("stub") != null);
        try testing.expect(profiles.get("extra") != null);
        try testing.expect(profiles.get("kilo") == null);
    }
}

// ============================================================================
// DELETE /api/workspaces/:id/config/profiles/:name
// ============================================================================

test "workspace_profile_delete_removes_it_from_this_workspace_only" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const id = try createWorkspace(&h, "DeleteProfile");
    defer gpa.free(id);

    // The workspace's own copy of both profiles - the state every seeded
    // workspace is in, and the copy the old flow left behind.
    const overlay_body =
        \\{"profiles":{"stub":{"model":"stub-model","base_url":"http://127.0.0.1:1","api_key":"stub-key-not-real"},
        \\ "extra":{"model":"extra-model","base_url":"http://127.0.0.1:1","api_key":"extra-key-not-real"}},
        \\ "tools":["command"]}
    ;
    {
        const path = try wsPath(gpa, id, "");
        defer gpa.free(path);
        var r = try h.http(io, .PUT, path, .{ .json_body = overlay_body, .expect = &.{200} });
        defer r.deinit();
    }

    {
        var r = try deleteWorkspaceProfile(&h, id, "extra", &.{200});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqual(true, doc.boolean("success") orelse return error.NoSuccess);
        try testing.expectEqualStrings("extra", doc.str("profile_name") orelse return error.NoName);
    }

    // The workspace's list: the deleted profile is gone, the other stays.
    {
        var got = try getWorkspaceConfig(&h, id);
        defer got.doc.deinit();
        defer got.r.deinit();
        const profiles = got.doc.object("profiles") orelse return error.NoProfiles;
        try testing.expect(profiles.get("extra") == null);
        try testing.expect(profiles.get("stub") != null);
    }

    // The user config is NOT the workspace's to edit: both profiles, every
    // other key and the search credential are exactly as they were.
    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    {
        const profiles = doc.object("profiles") orelse return error.NoProfiles;
        try testing.expect(profiles.get("extra") != null);
        try testing.expect(profiles.get("stub") != null);
        const tools = try toolNames(&doc);
        defer gpa.free(tools);
        try testing.expectEqual(@as(usize, 2), tools.len);
        try testing.expectEqualStrings("command", tools[0]);
        try testing.expectEqualStrings("glob", tools[1]);
        try testing.expectEqual(true, doc.boolean("notify_on_complete") orelse return error.NoNotify);
        try testing.expectEqual(@as(i64, 1234), doc.int("retry_delay_ms") orelse return error.NoRetry);
        try testing.expect(std.mem.indexOf(u8, r.body, "\"web_search\":{") != null);
    }

    // The stored document - the GET above masks the search key, so only the
    // file proves the credential survived the delete.
    const stored = try readUserConfigFile(&h);
    defer gpa.free(stored);
    try testing.expect(std.mem.indexOf(u8, stored, SENTINEL) != null);
    try testing.expect(std.mem.indexOf(u8, stored, "retry_delay_ms") != null);
    try testing.expect(std.mem.indexOf(u8, stored, "extra-key-not-real") != null);
    try testing.expect(std.mem.indexOf(u8, stored, "stub-key-not-real") != null);
}

test "workspace_profile_delete_is_404_for_a_name_that_is_nowhere" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const id = try createWorkspace(&h, "DeleteGhost");
    defer gpa.free(id);

    {
        var r = try deleteWorkspaceProfile(&h, id, "ghost", &.{404});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqual(false, doc.boolean("success") orelse return error.NoSuccess);
        try testing.expectEqualStrings("ghost", doc.str("profile_name") orelse return error.NoName);
    }

    // Nothing moved: both profiles are still there, on both surfaces.
    var got = try getWorkspaceConfig(&h, id);
    defer got.doc.deinit();
    defer got.r.deinit();
    const profiles = got.doc.object("profiles") orelse return error.NoProfiles;
    try testing.expect(profiles.get("stub") != null);
    try testing.expect(profiles.get("extra") != null);
}

test "workspace_profile_delete_clears_the_active_profile_it_named" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const id = try createWorkspace(&h, "DeleteActive");
    defer gpa.free(id);

    {
        var r = try deleteWorkspaceProfile(&h, id, "extra", &.{200});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        // `extra` IS the user config's active profile.
        try testing.expectEqual(true, doc.boolean("active_profile_was_cleared") orelse return error.NoFlag);
    }

    var got = try getWorkspaceConfig(&h, id);
    defer got.doc.deinit();
    defer got.r.deinit();
    const active = got.doc.get("active_profile") orelse return error.NoActiveField;
    try testing.expect(active == .null);
}

test "workspace_profile_delete_leaves_another_workspaces_own_profile_alone" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const ws_a = try createWorkspace(&h, "DeleteAlpha");
    defer gpa.free(ws_a);
    const ws_b = try createWorkspace(&h, "DeleteBeta");
    defer gpa.free(ws_b);

    const body =
        \\{"profiles":{"mine":{"model":"mine-model","base_url":"http://127.0.0.1:1","api_key":"k"}}}
    ;
    for ([_][]const u8{ ws_a, ws_b }) |ws| {
        const path = try wsPath(gpa, ws, "");
        defer gpa.free(path);
        var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
    }

    {
        var r = try deleteWorkspaceProfile(&h, ws_a, "mine", &.{200});
        defer r.deinit();
    }

    {
        var b = try getWorkspaceConfig(&h, ws_b);
        defer b.doc.deinit();
        defer b.r.deinit();
        const profiles = b.doc.object("profiles") orelse return error.NoProfiles;
        try testing.expect(profiles.get("mine") != null);
    }
}

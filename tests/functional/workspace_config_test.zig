//! Functional tests for the per-workspace config overlay
//! (Migration 105) over the wire.
//!
//! What these cover, and why they have to be functional: the overlay's four
//! routes, the EFFECTIVE-config response, the isolation between a workspace
//! overlay and the user-level config, and the masking of provider keys. None
//! of that is visible from the use-case unit tests — route ORDER, the exact
//! wire shape and "did the user config change?" are wire facts.
//!
//!   GET    /api/workspaces/:id/config        effective config + has_overlay
//!   PUT    /api/workspaces/:id/config        store the workspace-scoped slice
//!   DELETE /api/workspaces/:id/config        back to inheriting
//!   POST   /api/workspaces/:id/config/copy   copy the user config in
//!
//! NOT covered here: the boot-time seeding of existing workspaces
//! (`server_boot.seedWorkspaceSettingsFromUserConfig`). Its loop is unit
//! tested (`workspace_config.seedWorkspaces`, 8 tests) and its boot wiring is
//! proven by a manual probe, but a committed test needs a seam this harness
//! does not have: `Harness.boot` ALLOCATES its tmpdir, so there is no way to
//! (a) plant a config.json before the spawn and (b) boot a SECOND time against
//! the same HOME after creating a workspace — and the seeding only ever runs at
//! boot, with a workspace already present. The seam to add is the one already
//! noted in `harness.zig`: `BootOptions.config_json` (pre-spawn seed) plus a
//! `home_dir` reuse option. See the plan doc, Phase 1d.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// A user-level config with BOTH kinds of key: the ones that move to a
/// workspace (profiles, tools) and the ones that must keep applying everywhere
/// (notify_on_complete, retry_delay_ms). The distinction is the whole point of
/// the overlay, so every test needs a config where it is observable.
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
    var r = try h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = USER_CONFIG, .expect = &.{200} });
    defer r.deinit();
}

fn wsPath(allocator: std.mem.Allocator, workspace_id: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "/api/workspaces/{s}/config{s}", .{ workspace_id, suffix });
}

/// GET a workspace's effective config, with the response body asserted to carry
/// the workspace-scope marker. `has_overlay` being PRESENT is also the
/// route-order probe: a request captured by another `/api/workspaces/:id/...`
/// route would not answer with this shape at all.
fn getWorkspaceConfig(h: *Harness, workspace_id: []const u8) !struct { r: harness.Response, doc: harness.Json, has_overlay: bool } {
    const path = try wsPath(gpa, workspace_id, "");
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    errdefer r.deinit();
    var doc = try r.json();
    const has_overlay = doc.boolean("has_overlay") orelse {
        doc.deinit();
        r.deinit();
        return error.HasOverlayMissing;
    };
    return .{ .r = r, .doc = doc, .has_overlay = has_overlay };
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

    // A 200 whose body carries `has_overlay` is the config handler's shape.
    // `matchRoute` walks routes in registration order and returns the first
    // hit, so a `/config` captured by a `:param` sibling would answer
    // differently (or 404) — and only a wire test can see that.
    var got = try getWorkspaceConfig(&h, id);
    defer got.doc.deinit();
    defer got.r.deinit();
    try testing.expect(!got.has_overlay);
}

// ============================================================================
// Inheritance: a workspace with no overlay shows the USER's config
// ============================================================================

test "workspace_config_inherits_the_user_config_by_default" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const id = try createWorkspace(&h, "Inherits");
    defer gpa.free(id);

    var got = try getWorkspaceConfig(&h, id);
    defer got.doc.deinit();
    defer got.r.deinit();

    try testing.expect(!got.has_overlay);
    // The user's profiles are what a run here would use.
    const profiles = got.doc.object("profiles") orelse return error.NoProfiles;
    try testing.expect(profiles.get("stub") != null);
    try testing.expect(profiles.get("extra") != null);
    try testing.expectEqualStrings("extra", got.doc.str("active_profile").?);
    // And the General keys too - an inheriting workspace is the user config.
    try testing.expectEqual(true, got.doc.boolean("notify_on_complete").?);
    try testing.expectEqual(@as(i64, 1234), got.doc.int("retry_delay_ms").?);
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

        try testing.expect(got.has_overlay);
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
        // ...and the profile the overlay never mentioned is STILL the user's,
        // credential included. A "last write wins" merge would have dropped it.
        try testing.expect(profiles.get("stub") != null);
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
        // And the user-scope response carries no workspace marker.
        try testing.expect(doc.boolean("has_overlay") == null);
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
        // Still inheriting: the refusal changed nothing.
        var got = try getWorkspaceConfig(&h, id);
        defer got.doc.deinit();
        defer got.r.deinit();
        try testing.expect(!got.has_overlay);
    }
    {
        var r = try h.http(io, .PUT, path, .{ .json_body = "{\"tools\":", .expect = &.{400} });
        defer r.deinit();
    }
}

// ============================================================================
// DELETE: back to inheriting, and the decision is remembered
// ============================================================================

test "workspace_config_delete_returns_to_inheriting" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const id = try createWorkspace(&h, "Reset");
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
        try testing.expect(got.has_overlay);
    }
    {
        var r = try h.http(io, .DELETE, path, .{ .expect = &.{200} });
        defer r.deinit();
    }
    {
        var got = try getWorkspaceConfig(&h, id);
        defer got.doc.deinit();
        defer got.r.deinit();
        try testing.expect(!got.has_overlay);
        const tools = try toolNames(&got.doc);
        defer gpa.free(tools);
        try testing.expectEqual(@as(usize, 2), tools.len);
    }
}

// ============================================================================
// POST copy
// ============================================================================

test "workspace_config_copy_takes_the_user_config" {
    var h = try boot();
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
    try putUserConfig(&h);

    const id = try createWorkspace(&h, "Copy");
    defer gpa.free(id);

    const path = try wsPath(gpa, id, "/copy");
    defer gpa.free(path);

    {
        var r = try h.http(io, .POST, path, .{ .expect = &.{200} });
        defer r.deinit();
    }
    var got = try getWorkspaceConfig(&h, id);
    defer got.doc.deinit();
    defer got.r.deinit();

    try testing.expect(got.has_overlay);
    const tools = try toolNames(&got.doc);
    defer gpa.free(tools);
    try testing.expectEqual(@as(usize, 2), tools.len);
    const profiles = got.doc.object("profiles") orelse return error.NoProfiles;
    try testing.expect(profiles.get("stub") != null);
    try testing.expect(profiles.get("extra") != null);
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
        try testing.expect(a.has_overlay);
        try testing.expectEqualStrings("stub", a.doc.str("active_profile").?);
    }
    {
        // Beta was never touched: it must still be inheriting, not borrowing
        // Alpha's override.
        var b = try getWorkspaceConfig(&h, ws_b);
        defer b.doc.deinit();
        defer b.r.deinit();
        try testing.expect(!b.has_overlay);
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

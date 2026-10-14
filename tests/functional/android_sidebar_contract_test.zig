// Wire-contract test for the native Android sidebar. Zig port of
// `tests/functional/android_sidebar_contract_test.py` (same test names, same
// order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// The exact shape `RecentsApi.parseTimestampEpochMillis` accepts.
const SQLITE_UTC = "____-__-__ __:__:__";

/// True iff `value` matches `^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$`.
fn isSqliteUtc(value: []const u8) bool {
    if (value.len != SQLITE_UTC.len) return false;
    for (value, 0..) |c, i| {
        switch (i) {
            4, 7 => if (c != '-') return false,
            10 => if (c != ' ') return false,
            13, 16 => if (c != ':') return false,
            else => if (c < '0' or c > '9') return false,
        }
    }
    return true;
}

/// `POST /api/workspaces` → the new workspace's id (owned).
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    // Creating a workspace is a 201; the harness' default `expect` is
    // 200, so this must be spelled out.
    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// The `workspaces` array from `GET /api/workspaces?is_include_items=false`.
fn workspacesNoItems(h: *Harness) !harness.Json {
    const params = [_]Harness.Param{.{ .name = "is_include_items", .value = "false" }};
    var r = try h.http(io, .GET, "/api/workspaces", .{ .params = &params, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    errdefer doc.deinit();
    if (doc.array("workspaces") == null) {
        std.debug.print("workspaces response has no `workspaces` array: {s}\n", .{r.body});
        doc.deinit();
        return error.TestUnexpectedResult;
    }
    return doc;
}

// `is_include_items=false` must still carry id + name per row. The Android
// dropdown is a two-field view. If either is dropped, the sidebar renders an
// unnamed, unselectable row.
test "workspaces_list_keeps_the_fields_the_android_client_reads" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // The id is owned and unused here — free it rather than dropping it
    // on the floor, which `testing.allocator` reports as a leak.
    const created = try createWorkspace(&h, "Android contract workspace");
    defer gpa.free(created);

    var doc = try workspacesNoItems(&h);
    defer doc.deinit();

    const rows = doc.array("workspaces").?;
    if (rows.items.len == 0) {
        std.debug.print("expected at least the workspace just created\n", .{});
        return error.TestUnexpectedResult;
    }

    var saw_name = false;
    for (rows.items) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => {
                std.debug.print("workspace row is not an object\n", .{});
                return error.TestUnexpectedResult;
            },
        };
        const id = obj.get("id") orelse {
            std.debug.print("workspace row has no `id`\n", .{});
            return error.TestUnexpectedResult;
        };
        if (id != .string or id.string.len == 0) {
            std.debug.print("workspace row `id` must be a non-empty string\n", .{});
            return error.TestUnexpectedResult;
        }
        const name = obj.get("name") orelse {
            std.debug.print("workspace row has no `name`\n", .{});
            return error.TestUnexpectedResult;
        };
        if (name != .string) {
            std.debug.print("workspace row `name` must be a string\n", .{});
            return error.TestUnexpectedResult;
        }
        if (std.mem.eql(u8, name.string, "Android contract workspace")) saw_name = true;
    }
    if (!saw_name) {
        std.debug.print("'Android contract workspace' missing from the list\n", .{});
        return error.TestUnexpectedResult;
    }
}

// `is_include_items=false` is an optimisation, not a licence to drop the
// array. The Kotlin parser tolerates a missing `items` key, but the desktop
// store does not — so the contract holds both ways.
test "workspaces_list_omits_items_when_asked" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // The Python file got its row from the previous test's module-scoped
    // harness.
    const created = try createWorkspace(&h, "Items-omitted workspace");
    defer gpa.free(created);

    var doc = try workspacesNoItems(&h);
    defer doc.deinit();

    const rows = doc.array("workspaces").?;
    if (rows.items.len == 0) {
        std.debug.print("no workspaces to check; the loop would be vacuous\n", .{});
        return error.TestUnexpectedResult;
    }

    for (rows.items) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const items = obj.get("items") orelse {
            std.debug.print("workspace row has no `items` key at all\n", .{});
            return error.TestUnexpectedResult;
        };
        if (items != .array or items.array.items.len != 0) {
            std.debug.print("`is_include_items=false` must still carry an empty `items` array\n", .{});
            return error.TestUnexpectedResult;
        }
        const count = obj.get("items_count") orelse {
            std.debug.print("workspace row has no `items_count`\n", .{});
            return error.TestUnexpectedResult;
        };
        if (count != .integer) {
            std.debug.print("`items_count` must be an integer, got {t}\n", .{count});
            return error.TestUnexpectedResult;
        }
    }
}

// The recents list must expose session_id, session_name and the two stamps.
// `session_id` is the row key, `session_name` is the sidebar title, and the
// timestamps drive the relative-time pill.
test "session_list_keeps_the_fields_the_android_client_reads" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // One session so the per-row loop is not vacuous. The Python file relied
    // on the module-scoped harness; a fresh boot has an empty list.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{"sess_android_contract_001"});
        defer gpa.free(path);
        var r = try h.http(io, .PUT, path, .{
            .json_body = "{\"name\":\"Android recents row\"}",
            .expect = &.{200},
        });
        defer r.deinit();
    }

    const params = [_]Harness.Param{
        .{ .name = "sort_by", .value = "updated_at" },
        .{ .name = "direction", .value = "desc" },
        .{ .name = "limit", .value = "30" },
    };
    var r = try h.http(io, .GET, "/api/session", .{ .params = &params, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const sessions = doc.array("sessions") orelse {
        std.debug.print("session list response has no `sessions` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    // The Kotlin client reads `total`/`has_more` off the same envelope.
    if (doc.int("total") == null) {
        std.debug.print("session list envelope has no integer `total`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (doc.boolean("has_more") == null) {
        std.debug.print("session list envelope has no boolean `has_more`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (sessions.items.len == 0) {
        std.debug.print("expected the session just created; the loop would be vacuous\n", .{});
        return error.TestUnexpectedResult;
    }

    for (sessions.items) |s| {
        const obj = switch (s) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const sid = obj.get("session_id") orelse {
            std.debug.print("session row has no `session_id`\n", .{});
            return error.TestUnexpectedResult;
        };
        if (sid != .string or sid.string.len == 0) {
            std.debug.print("`session_id` must be a non-empty string\n", .{});
            return error.TestUnexpectedResult;
        }
        const name = obj.get("session_name") orelse {
            std.debug.print("session row has no `session_name`\n", .{});
            return error.TestUnexpectedResult;
        };
        if (name != .string) {
            std.debug.print("`session_name` must be a string\n", .{});
            return error.TestUnexpectedResult;
        }
        // Migration 082: the human-touched stamp is "" for legacy rows, never
        // null — the client's `optString` fallback chain depends on that.
        const touched = obj.get("last_human_touched_at") orelse {
            std.debug.print("session row has no `last_human_touched_at`\n", .{});
            return error.TestUnexpectedResult;
        };
        if (touched == .null) {
            std.debug.print("`last_human_touched_at` must be \"\" for legacy rows, never null\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

// Timestamps must be `YYYY-MM-DD HH:MM:SS` UTC, not local time or epoch. This
// is the single highest-risk assumption in the Android client: the Kotlin
// parser builds a `LocalDateTime` and pins it to `ZoneOffset.UTC`.
test "session_timestamps_are_sqlite_utc_strings" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{"sess_android_contract_002"});
        defer gpa.free(path);
        var r = try h.http(io, .PUT, path, .{
            .json_body = "{\"name\":\"timestamp shape\"}",
            .expect = &.{200},
        });
        defer r.deinit();
    }

    const params = [_]Harness.Param{.{ .name = "limit", .value = "30" }};
    var r = try h.http(io, .GET, "/api/session", .{ .params = &params, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const sessions = doc.array("sessions") orelse return error.TestUnexpectedResult;

    var checked: usize = 0;
    for (sessions.items) |s| {
        const obj = switch (s) {
            .object => |o| o,
            else => continue,
        };
        const sid = switch (obj.get("session_id") orelse continue) {
            .string => |x| x,
            else => continue,
        };
        for ([_][]const u8{ "created_at", "updated_at", "last_human_touched_at" }) |field| {
            // `session.get(field, "")`: a missing key is the same as an
            // empty string for this check.
            var value: []const u8 = "";
            if (obj.get(field)) |v| {
                value = switch (v) {
                    .string => |x| x,
                    else => "",
                };
            }
            // Empty is a documented legacy shape; the client falls back.
            if (value.len == 0) continue;
            if (!isSqliteUtc(value)) {
                std.debug.print(
                    "{s} is not a SQLite UTC datetime: '{s}' (session {s})\n",
                    .{ field, value, sid },
                );
                return error.TestUnexpectedResult;
            }
            checked += 1;
        }
    }

    // Guard against the assertion loop silently passing on an empty list.
    if (checked == 0) {
        std.debug.print("no timestamp was checked; the loop would be vacuous\n", .{});
        return error.TestUnexpectedResult;
    }
}

// A known workspace returns its sessions; an unknown one returns none. The
// Android client always sends a real `workspace_id`. It must never fall back
// to the global list, so the fail-closed behaviour is load-bearing.
test "session_list_scopes_to_a_workspace_and_fails_closed" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const workspace_id = try createWorkspace(&h, "Scoped contract workspace");
    defer gpa.free(workspace_id);

    {
        const params = [_]Harness.Param{
            .{ .name = "workspace_id", .value = workspace_id },
            .{ .name = "limit", .value = "30" },
        };
        var r = try h.http(io, .GET, "/api/session", .{ .params = &params, .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const sessions = doc.array("sessions") orelse return error.TestUnexpectedResult;
        if (sessions.items.len != 0) {
            std.debug.print("a fresh workspace must scope to zero sessions, got {d}\n", .{sessions.items.len});
            return error.TestUnexpectedResult;
        }
    }

    {
        const params = [_]Harness.Param{
            .{ .name = "workspace_id", .value = "ws_does_not_exist" },
            .{ .name = "limit", .value = "30" },
        };
        var r = try h.http(io, .GET, "/api/session", .{ .params = &params, .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const sessions = doc.array("sessions") orelse return error.TestUnexpectedResult;
        // Fail-closed: an unknown id must not leak the global session
        // list.
        if (sessions.items.len != 0) {
            std.debug.print(
                "an unknown workspace_id must return zero sessions, got {d}\n",
                .{sessions.items.len},
            );
            return error.TestUnexpectedResult;
        }
    }
}

// `/api/session` and `/api/llm/session` are the same handler. The Android
// client calls `/api/session`; the desktop store calls the `/api/llm/session`
// alias. They must not drift apart.
test "session_list_is_reachable_under_the_aliased_path" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // One session, or both lists are empty and the comparison is
    // trivially true. See test 3's header for the same reasoning.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{"sess_android_contract_003"});
        defer gpa.free(path);
        var r = try h.http(io, .PUT, path, .{
            .json_body = "{\"name\":\"alias parity\"}",
            .expect = &.{200},
        });
        defer r.deinit();
    }

    const params = [_]Harness.Param{.{ .name = "limit", .value = "5" }};

    var direct = try h.http(io, .GET, "/api/session", .{ .params = &params, .expect = &.{200} });
    defer direct.deinit();
    var direct_doc = try direct.json();
    defer direct_doc.deinit();

    var aliased = try h.http(io, .GET, "/api/llm/session", .{ .params = &params, .expect = &.{200} });
    defer aliased.deinit();
    var aliased_doc = try aliased.json();
    defer aliased_doc.deinit();

    const a = direct_doc.array("sessions") orelse return error.TestUnexpectedResult;
    const b = aliased_doc.array("sessions") orelse return error.TestUnexpectedResult;

    if (a.items.len != b.items.len) {
        std.debug.print(
            "the two session-list paths disagree: {d} vs {d} rows\n",
            .{ a.items.len, b.items.len },
        );
        return error.TestUnexpectedResult;
    }
    for (a.items, b.items) |ra, rb| {
        const oa = ra.object;
        const ob = rb.object;
        const ida = switch (oa.get("session_id") orelse continue) {
            .string => |x| x,
            else => continue,
        };
        const idb = switch (ob.get("session_id") orelse continue) {
            .string => |x| x,
            else => continue,
        };
        if (!std.mem.eql(u8, ida, idb)) {
            std.debug.print("the two session-list paths disagree: '{s}' vs '{s}'\n", .{ ida, idb });
            return error.TestUnexpectedResult;
        }
    }
}

// Body-analysis barrier. An unreferenced function is never type-checked,
// so a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = isSqliteUtc;
    _ = createWorkspace;
    _ = workspacesNoItems;
}

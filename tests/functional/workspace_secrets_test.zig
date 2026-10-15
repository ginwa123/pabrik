// Functional wire tests for workspace-scoped secrets (Migration 103). Zig
// port of `tests/functional/workspace_secrets_test.py` (same test names minus
// the `test_` prefix, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const Io = std.Io;

// ─── Canaries ──────────────────────────────────────────────────────────────
// Distinctive, JSON-safe, and different from every secret NAME used below — a
// name is not a secret and is echoed by the 409 conflict message, so reusing
const FIRST_VALUE = "sk_live_CANARY_4f1c9a_Zx7Q_DO_NOT_LEAK";
const SECOND_VALUE = "sk_live_CANARY_be02d8_Mm4R_ROTATED_DO_NOT_LEAK";

// What a wire body would look like if the write-only guarantee regressed.
const VALUE_KEY_NEEDLES = [_][]const u8{ "\"value\"", "\"value\":", "value\":" };

// ─── Helpers ───────────────────────────────────────────────────────────────

fn assertValueAbsent(body: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, body, needle) != null) {
            std.debug.print("PLAINTEXT LEAK: `{s}` appears in the body.\n--- raw body ---\n{s}\n", .{ needle, body });
            return error.TestUnexpectedResult;
        }
    }
}

fn assertNoValueKey(body: []const u8) !void {
    for (VALUE_KEY_NEEDLES) |needle| {
        if (std.mem.indexOf(u8, body, needle) != null) {
            std.debug.print("RESPONSE-SHAPE LEAK: `{s}` appears in the body — SecretResponse must carry id/name/created_at/updated_at and nothing else.\n--- raw body ---\n{s}\n", .{ needle, body });
            return error.TestUnexpectedResult;
        }
    }
}

fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

/// `POST /api/workspaces {"name": ...}` → the new workspace's id. Owned.
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);
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

fn secretsUrl(ws: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "/api/workspaces/{s}/secrets", .{ws});
}

fn secretUrl(ws: []const u8, sid: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "/api/workspaces/{s}/secrets/{s}", .{ ws, sid });
}

/// POST a secret → OWNED raw body. Caller parses.
fn createSecretRaw(h: *Harness, ws: []const u8, name: []const u8, value: []const u8, expect: []const u16) ![]u8 {
    const path = try secretsUrl(ws);
    defer gpa.free(path);
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name, .value = value }, .{});
    defer gpa.free(body);
    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// POST a secret → its id. Owned. Expects 201.
fn createSecret(h: *Harness, ws: []const u8, name: []const u8, value: []const u8) ![]u8 {
    const raw = try createSecretRaw(h, ws, name, value, &.{201});
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();
    const obj = doc.object("secret") orelse {
        std.debug.print("secret create returned no `secret`: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    const id = switch (obj.get("id") orelse {
        std.debug.print("secret has no id: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("secret id is not a string: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// GET the collection → OWNED raw body.
fn listSecretsRaw(h: *Harness, ws: []const u8, expect: []const u16) ![]u8 {
    const path = try secretsUrl(ws);
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// PATCH a secret → OWNED raw body.
fn patchSecretRaw(h: *Harness, ws: []const u8, sid: []const u8, json_body: ?[]const u8, expect: []const u16) ![]u8 {
    const path = try secretUrl(ws, sid);
    defer gpa.free(path);
    var r = try h.http(io, .PATCH, path, .{ .json_body = json_body, .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// DELETE a secret → OWNED raw body.
fn deleteSecretRaw(h: *Harness, ws: []const u8, sid: []const u8, expect: []const u16) ![]u8 {
    const path = try secretUrl(ws, sid);
    defer gpa.free(path);
    var r = try h.http(io, .DELETE, path, .{ .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

fn patchValueBody(value: ?[]const u8) ![]u8 {
    if (value) |v| {
        return std.json.Stringify.valueAlloc(gpa, .{ .value = v }, .{});
    }
    return gpa.dupe(u8, "{}");
}

fn patchNameValueBody(name: ?[]const u8, value: ?[]const u8) ![]u8 {
    if (name) |n| {
        if (value) |v| {
            return std.json.Stringify.valueAlloc(gpa, .{ .name = n, .value = v }, .{});
        }
        return std.json.Stringify.valueAlloc(gpa, .{ .name = n }, .{});
    }
    return patchValueBody(value);
}

/// The single list row called `name`: its id + updated_at + the full
/// list body (for leak checks). All owned.
const RowInfo = struct {
    id: []u8,
    updated_at: []u8,
    raw: []u8,

    fn deinit(self: *RowInfo) void {
        gpa.free(self.id);
        gpa.free(self.updated_at);
        gpa.free(self.raw);
    }
};

fn oneNamed(h: *Harness, ws: []const u8, name: []const u8) !RowInfo {
    const raw = try listSecretsRaw(h, ws, &.{200});
    errdefer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();
    const arr = doc.array("secrets") orelse {
        std.debug.print("list has no `secrets` array: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    var found: ?std.json.ObjectMap = null;
    var count: usize = 0;
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const n = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, n, name)) {
            count += 1;
            found = obj;
        }
    }
    if (count != 1 or found == null) {
        std.debug.print("expected exactly one row named `{s}` (found {d}): {s}\n", .{ name, count, raw });
        return error.TestUnexpectedResult;
    }
    const id = switch (found.?.get("id") orelse return error.TestUnexpectedResult) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    const updated = switch (found.?.get("updated_at") orelse return error.TestUnexpectedResult) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    return .{
        .id = try gpa.dupe(u8, id),
        .updated_at = try gpa.dupe(u8, updated),
        .raw = raw,
    };
}

fn listCount(h: *Harness, ws: []const u8) !i64 {
    const raw = try listSecretsRaw(h, ws, &.{200});
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();
    const v = doc.get("count") orelse {
        std.debug.print("list has no `count`: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .integer => |i| i,
        else => {
            std.debug.print("`count` is not an integer: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        },
    };
}

/// `SecretResponse` is exactly {id, name, created_at, updated_at}.
fn assertWireShape(obj: std.json.ObjectMap, body: []const u8) !void {
    const want = [_][]const u8{ "created_at", "id", "name", "updated_at" };
    if (obj.count() != want.len) {
        std.debug.print("unexpected SecretResponse key count {d}: {s}\n", .{ obj.count(), body });
        return error.TestUnexpectedResult;
    }
    for (want) |k| {
        const v = obj.get(k) orelse {
            std.debug.print("SecretResponse missing key `{s}`: {s}\n", .{ k, body });
            return error.TestUnexpectedResult;
        };
        switch (v) {
            .string => |s| if (s.len == 0) {
                std.debug.print("SecretResponse `{s}` is empty: {s}\n", .{ k, body });
                return error.TestUnexpectedResult;
            },
            else => {
                std.debug.print("SecretResponse `{s}` is not a string: {s}\n", .{ k, body });
                return error.TestUnexpectedResult;
            },
        }
    }
}

fn secretObj(doc: *const harness.Json, body: []const u8) !std.json.ObjectMap {
    return doc.object("secret") orelse {
        std.debug.print("response has no `secret` object: {s}\n", .{body});
        return error.TestUnexpectedResult;
    };
}

fn expectErrorStr(raw: []const u8, want: []const u8) !void {
    var doc = try parseJson(raw);
    defer doc.deinit();
    const got = doc.str("error") orelse {
        std.debug.print("response has no string `error`: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("error = `{s}`, expected `{s}`\nbody: {s}\n", .{ got, want, raw });
        return error.TestUnexpectedResult;
    }
}

fn expectErrorContains(raw: []const u8, needle: []const u8) !void {
    var doc = try parseJson(raw);
    defer doc.deinit();
    const got = doc.str("error") orelse {
        std.debug.print("response has no string `error`: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, got, needle) == null) {
        std.debug.print("error `{s}` does not contain `{s}`\nbody: {s}\n", .{ got, needle, raw });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// 1. Full CRUD round-trip
// ============================================================================

test "full_crud_round_trip" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "secrets-crud-ws");
    defer gpa.free(ws);

    // ── CREATE ──
    const created_raw = try createSecretRaw(&h, ws, "GITHUB_TOKEN", FIRST_VALUE, &.{201});
    defer gpa.free(created_raw);
    const secret_id: []u8 = blk: {
        var doc = try parseJson(created_raw);
        defer doc.deinit();
        const obj = try secretObj(&doc, created_raw);
        try assertWireShape(obj, created_raw);
        const name = switch (obj.get("name").?) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (!std.mem.eql(u8, name, "GITHUB_TOKEN")) {
            std.debug.print("created name = `{s}`\n", .{name});
            return error.TestUnexpectedResult;
        }
        const id = switch (obj.get("id").?) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        break :blk try gpa.dupe(u8, id);
    };
    defer gpa.free(secret_id);
    try assertValueAbsent(created_raw, &.{FIRST_VALUE});
    try assertNoValueKey(created_raw);

    // ── LIST ──
    {
        const listed = try listSecretsRaw(&h, ws, &.{200});
        defer gpa.free(listed);
        var doc = try parseJson(listed);
        defer doc.deinit();
        const count = switch (doc.get("count") orelse return error.TestUnexpectedResult) {
            .integer => |i| i,
            else => return error.TestUnexpectedResult,
        };
        if (count != 1) {
            std.debug.print("expected count 1: {s}\n", .{listed});
            return error.TestUnexpectedResult;
        }
        try assertValueAbsent(listed, &.{FIRST_VALUE});
        try assertNoValueKey(listed);
    }
    {
        var row = try oneNamed(&h, ws, "GITHUB_TOKEN");
        defer row.deinit();
        if (!std.mem.eql(u8, row.id, secret_id)) {
            std.debug.print("row id mismatch\n", .{});
            return error.TestUnexpectedResult;
        }
        try assertNoValueKey(row.raw);
    }

    // No single-secret read endpoint exists — 404.
    {
        const path = try secretUrl(ws, secret_id);
        defer gpa.free(path);
        var r = try h.http(io, .GET, path, .{ .expect = &.{404} });
        defer r.deinit();
        try assertValueAbsent(r.body, &.{FIRST_VALUE});
    }

    // ── ROTATE ──
    {
        const pb = try patchValueBody(SECOND_VALUE);
        defer gpa.free(pb);
        const raw = try patchSecretRaw(&h, ws, secret_id, pb, &.{200});
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        const obj = try secretObj(&doc, raw);
        try assertWireShape(obj, raw);
        const name = switch (obj.get("name").?) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (!std.mem.eql(u8, name, "GITHUB_TOKEN")) {
            std.debug.print("a rotation must not rename: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        }
        try assertValueAbsent(raw, &.{ FIRST_VALUE, SECOND_VALUE });
        try assertNoValueKey(raw);
    }
    {
        var row = try oneNamed(&h, ws, "GITHUB_TOKEN");
        defer row.deinit();
        if (!std.mem.eql(u8, row.id, secret_id)) {
            std.debug.print("row id changed after rotation\n", .{});
            return error.TestUnexpectedResult;
        }
        const listed = try listSecretsRaw(&h, ws, &.{200});
        defer gpa.free(listed);
        try assertNoValueKey(listed);
    }

    // ── DELETE ──
    {
        const raw = try deleteSecretRaw(&h, ws, secret_id, &.{200});
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        const id = doc.str("id") orelse {
            std.debug.print("DELETE answer has no id: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, id, secret_id)) {
            std.debug.print("DELETE id mismatch: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        }
        if (doc.boolean("success") != true) {
            std.debug.print("DELETE success != true: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        }
        try assertNoValueKey(raw);
    }

    // ── GONE ──
    {
        const raw = try listSecretsRaw(&h, ws, &.{200});
        defer gpa.free(raw);
        if (try listCount(&h, ws) != 0) {
            std.debug.print("expected empty list: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        }
        try assertNoValueKey(raw);
    }
}

// ============================================================================
// 2. The write-only guarantee, end to end (headline)
// ============================================================================

test "plaintext_never_appears_in_any_response_across_the_cycle" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "secrets-writeonly-ws");
    defer gpa.free(ws);

    var bodies: std.ArrayList([]u8) = .empty;
    defer {
        for (bodies.items) |b| gpa.free(b);
        bodies.deinit(gpa);
    }
    var statuses: std.ArrayList(u16) = .empty;
    defer statuses.deinit(gpa);

    const secret_id: []u8 = blk: {
        const raw = try createSecretRaw(&h, ws, "STRIPE_KEY", FIRST_VALUE, &.{201});
        const sid = sid_blk: {
            var doc = try parseJson(raw);
            defer doc.deinit();
            const obj = try secretObj(&doc, raw);
            const id = switch (obj.get("id").?) {
                .string => |s| s,
                else => return error.TestUnexpectedResult,
            };
            break :sid_blk try gpa.dupe(u8, id);
        };
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 201);
        break :blk sid;
    };
    defer gpa.free(secret_id);

    const canaries = [_][]const u8{ FIRST_VALUE, SECOND_VALUE };

    {
        const raw = try listSecretsRaw(&h, ws, &.{200});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 200);
    }
    {
        const pb = try patchValueBody(SECOND_VALUE);
        defer gpa.free(pb);
        const raw = try patchSecretRaw(&h, ws, secret_id, pb, &.{200});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 200);
    }
    {
        const raw = try listSecretsRaw(&h, ws, &.{200});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 200);
    }
    // PATCH `{}` — the "keep the stored value" path.
    {
        const raw = try patchSecretRaw(&h, ws, secret_id, "{}", &.{200});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 200);
    }
    // Refusal paths.
    {
        const raw = try createSecretRaw(&h, ws, "STRIPE_KEY", FIRST_VALUE, &.{409});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 409);
    }
    {
        const raw = try createSecretRaw(&h, ws, "", FIRST_VALUE, &.{400});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 400);
    }
    {
        const raw = try createSecretRaw(&h, ws, "has space", FIRST_VALUE, &.{400});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 400);
    }
    {
        const pb = try patchValueBody("");
        defer gpa.free(pb);
        const raw = try patchSecretRaw(&h, ws, secret_id, pb, &.{400});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 400);
    }
    {
        const pb = try patchNameValueBody("STRIPE_KEY", "");
        defer gpa.free(pb);
        const raw = try patchSecretRaw(&h, ws, secret_id, pb, &.{400});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 400);
    }
    {
        const pb = try patchNameValueBody("RENAMED", null);
        defer gpa.free(pb);
        const raw = try patchSecretRaw(&h, ws, secret_id, pb, &.{404});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 404);
    }
    // Cross-workspace refusals.
    const other = try createWorkspace(&h, "secrets-writeonly-other-ws");
    defer gpa.free(other);
    {
        const raw = try listSecretsRaw(&h, other, &.{200});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 200);
    }
    {
        const pb = try patchValueBody(FIRST_VALUE);
        defer gpa.free(pb);
        const raw = try patchSecretRaw(&h, other, secret_id, pb, &.{404});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 404);
    }
    {
        const raw = try deleteSecretRaw(&h, other, secret_id, &.{404});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 404);
    }
    // Teardown.
    {
        const raw = try deleteSecretRaw(&h, ws, secret_id, &.{200});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 200);
    }
    {
        const raw = try listSecretsRaw(&h, ws, &.{200});
        try bodies.append(gpa, raw);
        try statuses.append(gpa, 200);
    }

    if (bodies.items.len < 14) {
        std.debug.print("the sweep shrank: only {d} responses\n", .{bodies.items.len});
        return error.TestUnexpectedResult;
    }
    for (bodies.items) |body| try assertValueAbsent(body, &canaries);
    for (bodies.items, statuses.items) |body, st| {
        if (200 <= st and st < 300) try assertNoValueKey(body);
    }
    var seen_201 = false;
    var seen_200 = false;
    var seen_409 = false;
    var seen_404 = false;
    for (statuses.items) |st| {
        if (st == 201) seen_201 = true;
        if (st == 200) seen_200 = true;
        if (st == 409) seen_409 = true;
        if (st == 404) seen_404 = true;
    }
    if (!seen_201 or !seen_200 or !seen_409 or !seen_404) {
        std.debug.print("sweep did not exercise rotation+refusal\n", .{});
        return error.TestUnexpectedResult;
    }
    if (std.mem.eql(u8, FIRST_VALUE, SECOND_VALUE)) return error.TestUnexpectedResult;
}

// ============================================================================
// 3. Cross-workspace isolation
// ============================================================================

test "cross_workspace_isolation_is_404_never_403" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_a = try createWorkspace(&h, "secrets-iso-a");
    defer gpa.free(ws_a);
    const ws_b = try createWorkspace(&h, "secrets-iso-b");
    defer gpa.free(ws_b);

    const foreign_id = try createSecret(&h, ws_a, "OPENAI_KEY", FIRST_VALUE);
    defer gpa.free(foreign_id);

    // B lists nothing; A really has one.
    {
        const raw = try listSecretsRaw(&h, ws_b, &.{200});
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        const count = switch (doc.get("count") orelse return error.TestUnexpectedResult) {
            .integer => |i| i,
            else => return error.TestUnexpectedResult,
        };
        if (count != 0) {
            std.debug.print("B must see no secrets: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        }
    }
    if (try listCount(&h, ws_a) != 1) {
        std.debug.print("A should have exactly one secret\n", .{});
        return error.TestUnexpectedResult;
    }

    // B cannot GET A's row by id.
    {
        const path = try secretUrl(ws_b, foreign_id);
        defer gpa.free(path);
        var r = try h.http(io, .GET, path, .{ .expect = &.{404} });
        defer r.deinit();
        try assertValueAbsent(r.body, &.{FIRST_VALUE});
    }
    // B cannot rotate it.
    {
        const pb = try patchValueBody(SECOND_VALUE);
        defer gpa.free(pb);
        const raw = try patchSecretRaw(&h, ws_b, foreign_id, pb, &.{404});
        defer gpa.free(raw);
        try assertValueAbsent(raw, &.{ FIRST_VALUE, SECOND_VALUE });
    }
    // B cannot delete it.
    {
        const raw = try deleteSecretRaw(&h, ws_b, foreign_id, &.{404});
        defer gpa.free(raw);
        try assertValueAbsent(raw, &.{FIRST_VALUE});
    }
    // A's row survived.
    {
        var row = try oneNamed(&h, ws_a, "OPENAI_KEY");
        defer row.deinit();
        if (!std.mem.eql(u8, row.id, foreign_id)) return error.TestUnexpectedResult;
    }
    if (try listCount(&h, ws_b) != 0) return error.TestUnexpectedResult;
    if (try listCount(&h, ws_a) != 1) return error.TestUnexpectedResult;

    // A can still rotate its own row.
    {
        const pb = try patchValueBody(SECOND_VALUE);
        defer gpa.free(pb);
        const raw = try patchSecretRaw(&h, ws_a, foreign_id, pb, &.{200});
        defer gpa.free(raw);
        try assertNoValueKey(raw);
    }
    // No oracle: foreign id and fabricated id answer identically.
    {
        const pb = try patchValueBody("x");
        defer gpa.free(pb);
        const real_raw = try patchSecretRaw(&h, ws_b, "sec_definitely_not_real", pb, &.{404});
        defer gpa.free(real_raw);
        const foreign_raw = try patchSecretRaw(&h, ws_b, foreign_id, pb, &.{404});
        defer gpa.free(foreign_raw);
        if (!std.mem.eql(u8, real_raw, foreign_raw)) {
            std.debug.print("PATCH oracle: fabricated vs foreign differ:\n{s}\n{s}\n", .{ real_raw, foreign_raw });
            return error.TestUnexpectedResult;
        }
    }
    {
        const real_raw = try deleteSecretRaw(&h, ws_b, "sec_definitely_not_real", &.{404});
        defer gpa.free(real_raw);
        const foreign_raw = try deleteSecretRaw(&h, ws_b, foreign_id, &.{404});
        defer gpa.free(foreign_raw);
        if (!std.mem.eql(u8, real_raw, foreign_raw)) {
            std.debug.print("DELETE oracle: fabricated vs foreign differ:\n{s}\n{s}\n", .{ real_raw, foreign_raw });
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// 4. Empty value is a 400, not a 500
// ============================================================================

test "empty_value_is_400_not_a_500_null_constraint_violation" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "secrets-empty-value-ws");
    defer gpa.free(ws);

    {
        const raw = try createSecretRaw(&h, ws, "BLANK_VALUE", "", &.{400});
        defer gpa.free(raw);
        try expectErrorStr(raw, "value is required");
    }
    if (try listCount(&h, ws) != 0) {
        std.debug.print("a 400 must not have written a row\n", .{});
        return error.TestUnexpectedResult;
    }
    const sid = try createSecret(&h, ws, "ROTATING", FIRST_VALUE);
    defer gpa.free(sid);
    {
        const pb = try patchValueBody("");
        defer gpa.free(pb);
        const raw = try patchSecretRaw(&h, ws, sid, pb, &.{400});
        defer gpa.free(raw);
        try expectErrorStr(raw, "value is required");
    }
    {
        const pb = try patchValueBody(SECOND_VALUE);
        defer gpa.free(pb);
        const raw = try patchSecretRaw(&h, ws, sid, pb, &.{200});
        defer gpa.free(raw);
    }
    if (try listCount(&h, ws) != 1) return error.TestUnexpectedResult;
}

// ============================================================================
// 5. Duplicate name
// ============================================================================

test "duplicate_name_is_409_in_one_workspace_201_in_another" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_a = try createWorkspace(&h, "secrets-dup-a");
    defer gpa.free(ws_a);
    const ws_b = try createWorkspace(&h, "secrets-dup-b");
    defer gpa.free(ws_b);

    const first_id = try createSecret(&h, ws_a, "GITHUB_TOKEN", FIRST_VALUE);
    defer gpa.free(first_id);

    {
        const raw = try createSecretRaw(&h, ws_a, "GITHUB_TOKEN", SECOND_VALUE, &.{409});
        defer gpa.free(raw);
        try expectErrorContains(raw, "GITHUB_TOKEN");
        try assertValueAbsent(raw, &.{ FIRST_VALUE, SECOND_VALUE });
    }
    if (try listCount(&h, ws_a) != 1) return error.TestUnexpectedResult;
    {
        var row = try oneNamed(&h, ws_a, "GITHUB_TOKEN");
        defer row.deinit();
        if (!std.mem.eql(u8, row.id, first_id)) {
            std.debug.print("the loser half-applied\n", .{});
            return error.TestUnexpectedResult;
        }
    }
    {
        const second_id = try createSecret(&h, ws_b, "GITHUB_TOKEN", SECOND_VALUE);
        defer gpa.free(second_id);
        if (std.mem.eql(u8, second_id, first_id)) {
            std.debug.print("cross-workspace ids must differ\n", .{});
            return error.TestUnexpectedResult;
        }
    }
    if (try listCount(&h, ws_b) != 1) return error.TestUnexpectedResult;
    // Padded spelling still conflicts.
    {
        const raw = try createSecretRaw(&h, ws_a, "  GITHUB_TOKEN  ", SECOND_VALUE, &.{409});
        defer gpa.free(raw);
    }
    if (try listCount(&h, ws_a) != 1) return error.TestUnexpectedResult;
}

// ============================================================================
// 6. Invalid name
// ============================================================================

test "name_outside_the_placeholder_grammar_is_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "secrets-name-grammar-ws");
    defer gpa.free(ws);

    const bad_65 = try gpa.dupe(u8, "a" ** 65);
    defer gpa.free(bad_65);
    const bad_64dash = try std.fmt.allocPrint(gpa, "{s}-", .{"A" ** 64});
    defer gpa.free(bad_64dash);
    const bad_names = [_][]const u8{
        "has space", "has.dot",               "brace{", "slash/one",
        "col:on",    "emoji\xf0\x9f\x90\x8d", bad_65,   bad_64dash,
    };
    for (bad_names) |bad| {
        const raw = try createSecretRaw(&h, ws, bad, FIRST_VALUE, &.{400});
        defer gpa.free(raw);
        try expectErrorStr(raw, "name must match [A-Za-z0-9_-]{1,64}");
    }
    if (try listCount(&h, ws) != 0) {
        std.debug.print("a rejected name must not have been stored\n", .{});
        return error.TestUnexpectedResult;
    }
    const good_64 = try gpa.dupe(u8, "a" ** 64);
    defer gpa.free(good_64);
    const good_names = [_][]const u8{
        "A", good_64, "GITHUB_TOKEN", "token-with_underscores-and-dashes123",
    };
    for (good_names) |good| {
        const raw = try createSecretRaw(&h, ws, good, FIRST_VALUE, &.{201});
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        const obj = try secretObj(&doc, raw);
        const name = switch (obj.get("name").?) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (!std.mem.eql(u8, name, good)) {
            std.debug.print("good name `{s}` came back as `{s}`\n", .{ good, name });
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// 7. Missing ids / missing fields
// ============================================================================

test "missing_name_and_missing_value_are_both_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "secrets-missing-fields-ws");
    defer gpa.free(ws);
    const url = try secretsUrl(ws);
    defer gpa.free(url);

    {
        var r = try h.http(io, .POST, url, .{ .json_body = "{}", .expect = &.{400} });
        defer r.deinit();
        try expectErrorStr(r.body, "name is required");
        try assertValueAbsent(r.body, &.{FIRST_VALUE});
    }
    const blanks = [_][]const u8{ "", "   ", "\t\n" };
    for (blanks) |blank| {
        const raw = try createSecretRaw(&h, ws, blank, FIRST_VALUE, &.{400});
        defer gpa.free(raw);
        try expectErrorStr(raw, "name is required");
    }
    {
        const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = "ONLY_A_NAME" }, .{});
        defer gpa.free(body);
        var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{400} });
        defer r.deinit();
        try expectErrorStr(r.body, "value is required");
    }
    {
        const body = try std.json.Stringify.valueAlloc(gpa, .{ .value = FIRST_VALUE }, .{});
        defer gpa.free(body);
        var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{400} });
        defer r.deinit();
        try expectErrorStr(r.body, "name is required");
        try assertValueAbsent(r.body, &.{FIRST_VALUE});
    }
    // Unparseable JSON is also a 400 rather than a 500.
    {
        var r = try h.http(io, .POST, url, .{ .json_body = "[\"not\",\"an\",\"object\"]", .expect = &.{400} });
        defer r.deinit();
    }
    if (try listCount(&h, ws) != 0) {
        std.debug.print("no refused request may have written a row\n", .{});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// 7b. A PATCH `name` is a claim, not a rename
// ============================================================================

test "patch_name_is_a_claim_not_a_rename" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "secrets-immutable-name-ws");
    defer gpa.free(ws);
    const sid = try createSecret(&h, ws, "ORIGINAL_NAME", FIRST_VALUE);
    defer gpa.free(sid);

    // Matching claim plus a new value: a rotation.
    {
        const pb = try patchNameValueBody("ORIGINAL_NAME", SECOND_VALUE);
        defer gpa.free(pb);
        const raw = try patchSecretRaw(&h, ws, sid, pb, &.{200});
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        const obj = try secretObj(&doc, raw);
        const name = switch (obj.get("name").?) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (!std.mem.eql(u8, name, "ORIGINAL_NAME")) return error.TestUnexpectedResult;
        try assertNoValueKey(raw);
    }
    // Non-matching claim: 404, value untouched.
    {
        const pb = try patchNameValueBody("RENAMED", FIRST_VALUE);
        defer gpa.free(pb);
        const raw = try patchSecretRaw(&h, ws, sid, pb, &.{404});
        defer gpa.free(raw);
        try expectErrorStr(raw, "secret not found");
    }
    {
        var row = try oneNamed(&h, ws, "ORIGINAL_NAME");
        defer row.deinit();
        if (!std.mem.eql(u8, row.id, sid)) return error.TestUnexpectedResult;
    }
    if (try listCount(&h, ws) != 1) return error.TestUnexpectedResult;
    // Invalid name in PATCH is refused on the NAME (400) before the read.
    {
        const pb = try patchNameValueBody("has space", null);
        defer gpa.free(pb);
        const raw = try patchSecretRaw(&h, ws, sid, pb, &.{400});
        defer gpa.free(raw);
        try expectErrorStr(raw, "name must match [A-Za-z0-9_-]{1,64}");
    }
    // `{}` returns the row untouched and does not advance updated_at.
    {
        var before = try oneNamed(&h, ws, "ORIGINAL_NAME");
        defer before.deinit();
        const before_ts = try gpa.dupe(u8, before.updated_at);
        defer gpa.free(before_ts);
        const raw = try patchSecretRaw(&h, ws, sid, "{}", &.{200});
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        const obj = try secretObj(&doc, raw);
        const id = switch (obj.get("id").?) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (!std.mem.eql(u8, id, sid)) return error.TestUnexpectedResult;
        var after = try oneNamed(&h, ws, "ORIGINAL_NAME");
        defer after.deinit();
        if (!std.mem.eql(u8, after.updated_at, before_ts)) {
            std.debug.print("noop PATCH advanced updated_at\n", .{});
            return error.TestUnexpectedResult;
        }
    }
    // Empty PATCH body (no JSON at all) is a 400, not a crash.
    {
        const path = try secretUrl(ws, sid);
        defer gpa.free(path);
        var r = try h.http(io, .PATCH, path, .{ .json_body = null, .expect = &.{400} });
        defer r.deinit();
    }
}

// ============================================================================
// 8.

const UNKNOWN_NAME = "UNKNOWN";
const PRESENT_NAME = "PRESENT_KEY";
const UNKNOWN_CALL_ID = "call_secrets_unknown_1";
const PRESENT_CALL_ID = "call_secrets_present_1";
const NEVER_WRITTEN_FILENAME = "never-created-because-the-placeholder-did-not-resolve.txt";
const CONTROL_FILENAME = "control-written-from-a-placeholder-that-did-resolve.txt";

const MAX_HEAD_BYTES = 1 << 18;
const POLL_BUDGET_MS: i64 = 60_000;
const POLL_INTERVAL_MS: i64 = 500;

/// Build the placeholder string for `name` at runtime (open-brace,
/// close-brace, and the SECRETS marker joined here, so no literal
/// marker sits in this source).
fn placeholderFor(name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}:{s}{s}", .{ "{{", "SECRETS", name, "}}" });
}

/// A stateful stub LLM upstream serving a fixed queue of tool calls, one per
/// agentic turn — the Zig analogue of the Python stub state + handler pair.
const Stub = struct {
    port: u16,
    server: Io.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    pending: std.ArrayList(PendingCall) = .empty,
    served: std.ArrayList([]const u8) = .empty,

    const PendingCall = struct {
        id: []const u8,
        tool: []const u8,
        arguments: []u8, // owned JSON string
    };

    fn start(stub: *Stub, calls: []PendingCall) !void {
        stub.* = .{ .port = 0, .server = undefined, .thread = undefined };
        for (calls) |c| try stub.pending.append(gpa, c);
        stub.port = try harness.findFreePortRandom(gpa);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
        stub.server = try addr.listen(io, .{ .reuse_address = true });
        errdefer stub.server.deinit(io);
        stub.thread = try std.Thread.spawn(.{}, serve, .{stub});
    }

    fn deinit(stub: *Stub) void {
        stub.stop.store(true, .release);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(stub.port) };
        if (addr.connect(io, .{ .mode = .stream })) |conn| {
            var c = conn;
            c.close(io);
        } else |_| {}
        stub.thread.join();
        stub.server.deinit(io);
        for (stub.pending.items) |c| gpa.free(c.arguments);
        stub.pending.deinit(gpa);
        for (stub.served.items) |s| gpa.free(s);
        stub.served.deinit(gpa);
    }

    fn servedContains(stub: *Stub, id: []const u8) !bool {
        stub.mutex.lockUncancelable(io);
        defer stub.mutex.unlock(io);
        for (stub.served.items) |s| {
            if (std.mem.eql(u8, s, id)) return true;
        }
        return false;
    }
};

fn serve(stub: *Stub) void {
    while (!stub.stop.load(.acquire)) {
        var stream = stub.server.accept(io) catch break;
        defer stream.close(io);
        if (stub.stop.load(.acquire)) break;
        handleStubRequest(stub, stream) catch {};
    }
}

/// A request is a FOLLOW-UP turn (plain stop reply) as soon as it carries an
/// already-served call id; anything else carrying a `tools` array consumes
/// the next queued call.
fn handleStubRequest(stub: *Stub, stream: Io.net.Stream) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const r = &sr.interface;

    var acc: Io.Writer.Allocating = .init(gpa);
    defer acc.deinit();
    var head_len: usize = 0;
    while (head_len == 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        acc.writer.writeAll(b) catch break;
        r.toss(b.len);
        if (acc.written().len > MAX_HEAD_BYTES) break;
        if (std.mem.indexOf(u8, acc.written(), "\r\n\r\n")) |i| head_len = i + 4;
    }
    if (head_len == 0) return;
    const head = acc.written()[0..head_len];
    var remaining = stubContentLength(head);
    if (acc.written().len > head_len) remaining -|= acc.written().len - head_len;
    while (remaining > 0) {
        r.fill(1) catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        const take = @min(b.len, remaining);
        acc.writer.writeAll(b[0..take]) catch break;
        remaining -= take;
        r.toss(take);
    }
    const req_body = acc.written()[head_len..];

    // Decide the reply under the lock; build the SSE after unlocking.
    var reply_tool = false;
    var tool_args: []u8 = &.{};
    var tool_id: []const u8 = "";
    var tool_name: []const u8 = "";
    stub.mutex.lockUncancelable(io);
    {
        var is_followup = false;
        for (stub.served.items) |s| {
            if (std.mem.indexOf(u8, req_body, s) != null) {
                is_followup = true;
                break;
            }
        }
        if (!is_followup and stub.pending.items.len > 0 and std.mem.indexOf(u8, req_body, "\"tools\"") != null) {
            const call = stub.pending.orderedRemove(0);
            stub.served.append(gpa, gpa.dupe(u8, call.id) catch "") catch {};
            reply_tool = true;
            tool_args = call.arguments;
            tool_id = call.id;
            tool_name = call.tool;
        }
    }
    stub.mutex.unlock(io);

    const sse: []u8 = if (reply_tool) blk: {
        defer gpa.free(tool_args);
        break :blk try toolCallSse(tool_id, tool_name, tool_args);
    } else try textSse("stopping");
    defer gpa.free(sse);

    const response = try std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ sse.len, sse },
    );
    defer gpa.free(response);
    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    try sw.interface.writeAll(response);
    try sw.interface.flush();
}

fn toolCallSse(call_id: []const u8, tool_name: []const u8, arguments: []const u8) ![]u8 {
    // `arguments` is a JSON string inside the chunk; Stringify escapes it.
    const first = try std.json.Stringify.valueAlloc(gpa, .{
        .id = "chatcmpl-stub-toolcall",
        .object = "chat.completion.chunk",
        .model = "stub-model",
        .choices = [_]struct {
            index: u8,
            delta: struct {
                role: []const u8,
                content: ?[]const u8,
                tool_calls: [1]struct {
                    index: u8,
                    id: []const u8,
                    type: []const u8,
                    function: struct {
                        name: []const u8,
                        arguments: []const u8,
                    },
                },
            },
            finish_reason: ?[]const u8,
        }{.{
            .index = 0,
            .delta = .{
                .role = "assistant",
                .content = null,
                .tool_calls = .{.{
                    .index = 0,
                    .id = call_id,
                    .type = "function",
                    .function = .{ .name = tool_name, .arguments = arguments },
                }},
            },
            .finish_reason = null,
        }},
    }, .{});
    defer gpa.free(first);
    const final = try std.json.Stringify.valueAlloc(gpa, .{
        .id = "chatcmpl-stub-toolcall",
        .object = "chat.completion.chunk",
        .model = "stub-model",
        .choices = [_]struct {
            index: u8,
            delta: struct {},
            finish_reason: []const u8,
        }{.{ .index = 0, .delta = .{}, .finish_reason = "tool_calls" }},
    }, .{});
    defer gpa.free(final);
    return std.fmt.allocPrint(gpa, "data: {s}\n\ndata: {s}\n\ndata: [DONE]\n\n", .{ first, final });
}

fn textSse(text: []const u8) ![]u8 {
    const first = try std.json.Stringify.valueAlloc(gpa, .{
        .id = "chatcmpl-stub-text",
        .object = "chat.completion.chunk",
        .model = "stub-model",
        .choices = [_]struct {
            index: u8,
            delta: struct { role: []const u8, content: []const u8 },
            finish_reason: ?[]const u8,
        }{.{ .index = 0, .delta = .{ .role = "assistant", .content = text }, .finish_reason = null }},
    }, .{});
    defer gpa.free(first);
    const final = try std.json.Stringify.valueAlloc(gpa, .{
        .id = "chatcmpl-stub-text",
        .object = "chat.completion.chunk",
        .model = "stub-model",
        .choices = [_]struct {
            index: u8,
            delta: struct {},
            finish_reason: []const u8,
        }{.{ .index = 0, .delta = .{}, .finish_reason = "stop" }},
    }, .{});
    defer gpa.free(final);
    return std.fmt.allocPrint(gpa, "data: {s}\n\ndata: {s}\n\ndata: [DONE]\n\n", .{ first, final });
}

fn stubHeaderValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn stubContentLength(head: []const u8) usize {
    const v = stubHeaderValue(head, "content-length") orelse return 0;
    return std.fmt.parseInt(usize, v, 10) catch 0;
}

/// Poll until a `write_file` row for this session carries content.
/// Returns an OWNED copy of the row's `content`, or null on timeout.
fn waitForWriteFileRow(h: *Harness, session_id: []const u8) !?[]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages", .{session_id});
    defer gpa.free(path);
    const params = [_]Harness.Param{
        .{ .name = "sort_by", .value = "created_at" },
        .{ .name = "direction", .value = "asc" },
        .{ .name = "limit", .value = "100" },
    };
    const deadline = Io.Timestamp.now(io, .awake).toMilliseconds() + POLL_BUDGET_MS;
    while (Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        var r = h.http(io, .GET, path, .{ .params = &params, .expect = &.{200} }) catch return null;
        defer r.deinit();
        var doc = r.json() catch return null;
        defer doc.deinit();
        const list = doc.array("messages");
        const messages: []const std.json.Value = if (list) |a| a.items else &.{};
        for (messages) |m| {
            const obj = switch (m) {
                .object => |o| o,
                else => continue,
            };
            const tool_name = switch (obj.get("tool_name") orelse .null) {
                .string => |s| s,
                else => continue,
            };
            if (!std.mem.eql(u8, tool_name, "write_file")) continue;
            const content = switch (obj.get("content") orelse std.json.Value{ .string = "" }) {
                .string => |s| s,
                else => "",
            };
            if (std.mem.trim(u8, content, " \t\r\n").len == 0) continue;
            return try gpa.dupe(u8, content);
        }
        if (!h.health(io)) return null;
        const remaining = deadline - Io.Timestamp.now(io, .awake).toMilliseconds();
        if (remaining > 0) {
            Io.sleep(io, .fromMilliseconds(@min(remaining, POLL_INTERVAL_MS)), .awake) catch {};
        }
    }
    return null;
}

fn runTurn(h: *Harness, ws_path: []const u8, tag: []const u8, prompt: []const u8) !?[]u8 {
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    const session_id = try std.fmt.allocPrint(gpa, "sess_secrets_{s}_{d}", .{ tag, now_ms });
    defer gpa.free(session_id);
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .session_id = session_id,
        .queue_message = prompt,
        .cwd_session = ws_path,
        .allowed_tools = "write_file",
        .image_urls = "",
        .selected_profile_model = "secrets-stub",
        .is_auto_retry_until_stop = "",
    }, .{});
    defer gpa.free(body);
    {
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = body,
            .expect = &.{ 200, 201, 500 },
        });
        defer r.deinit();
    }
    return waitForWriteFileRow(h, session_id);
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

test "unknown_placeholder_names_the_missing_key_and_dispatches_nothing" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // A workspace whose item path IS the session cwd, so workspace
    // resolution finds it by path.
    const ws = try createWorkspace(&h, "secrets-placeholder-ws");
    defer gpa.free(ws);
    const ws_path = try harness.harnessPath(gpa, h.temp_dir, &.{"secrets-placeholder-ws"});
    defer gpa.free(ws_path);
    try std.Io.Dir.cwd().createDirPath(io, ws_path);
    {
        const body = try std.json.Stringify.valueAlloc(gpa, .{
            .name = "placeholder-agent",
            .path = ws_path,
        }, .{});
        defer gpa.free(body);
        const item_path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/agent", .{ws});
        defer gpa.free(item_path);
        var r = try h.http(io, .POST, item_path, .{ .json_body = body, .expect = &.{201} });
        defer r.deinit();
    }

    const present_id = try createSecret(&h, ws, PRESENT_NAME, FIRST_VALUE);
    defer gpa.free(present_id);

    const never_written = try std.fs.path.join(gpa, &.{ ws_path, NEVER_WRITTEN_FILENAME });
    defer gpa.free(never_written);
    const control_written = try std.fs.path.join(gpa, &.{ ws_path, CONTROL_FILENAME });
    defer gpa.free(control_written);
    if (pathExists(never_written)) {
        std.debug.print("never-written file already exists\n", .{});
        return error.TestUnexpectedResult;
    }

    const unknown_placeholder = try placeholderFor(UNKNOWN_NAME);
    defer gpa.free(unknown_placeholder);
    const present_placeholder = try placeholderFor(PRESENT_NAME);
    defer gpa.free(present_placeholder);
    const unknown_args = try std.json.Stringify.valueAlloc(gpa, .{
        .path = never_written,
        .content = unknown_placeholder,
        .create_with_dir = false,
    }, .{});
    errdefer gpa.free(unknown_args);
    const present_args = try std.json.Stringify.valueAlloc(gpa, .{
        .path = control_written,
        .content = present_placeholder,
        .create_with_dir = false,
    }, .{});
    errdefer gpa.free(present_args);

    var stub: Stub = undefined;
    var pending = [_]Stub.PendingCall{
        .{ .id = UNKNOWN_CALL_ID, .tool = "write_file", .arguments = unknown_args },
        .{ .id = PRESENT_CALL_ID, .tool = "write_file", .arguments = present_args },
    };
    try stub.start(pending[0..]);
    defer stub.deinit();

    const stub_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1/chat/completions", .{stub.port});
    defer gpa.free(stub_url);
    {
        const cfg = try std.fmt.allocPrint(gpa,
            \\{{"api_endpoint":"{s}","api_key":"sk-stub-test","model":"stub-model","url_style":"openai","profiles":{{"secrets-stub":{{"model":"stub-model","base_url":"{s}","api_key":"sk-stub-test","url_style":"openai"}}}},"active_profile":"secrets-stub"}}
        , .{ stub_url, stub_url });
        defer gpa.free(cfg);
        var r = try h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = cfg, .expect = &.{200} });
        defer r.deinit();
    }

    const unknown_row = try runTurn(&h, ws_path, "unknown", "write the file using the placeholder");
    defer if (unknown_row) |row| gpa.free(row);
    const present_row = try runTurn(&h, ws_path, "present", "write the file using the other placeholder");
    defer if (present_row) |row| gpa.free(row);

    const log_tail = try h.tailLog(io, gpa, 4000);
    defer gpa.free(log_tail);
    const clipped: []const u8 = if (log_tail.len > 4000) log_tail[log_tail.len - 4000 ..] else log_tail;

    if (!h.health(io)) {
        std.debug.print("pabrik died during the turn.\n--- log tail ---\n{s}\n", .{clipped});
        return error.TestUnexpectedResult;
    }
    if (!try stub.servedContains(UNKNOWN_CALL_ID)) {
        std.debug.print("the stub never served the unknown-placeholder call.\n--- log tail ---\n{s}\n", .{clipped});
        return error.TestUnexpectedResult;
    }
    if (!try stub.servedContains(PRESENT_CALL_ID)) {
        std.debug.print("the stub never served the control call.\n--- log tail ---\n{s}\n", .{clipped});
        return error.TestUnexpectedResult;
    }
    const unknown_content_row = unknown_row orelse {
        std.debug.print("no write_file tool result row for the unknown placeholder.\n--- log tail ---\n{s}\n", .{clipped});
        return error.TestUnexpectedResult;
    };
    const present_content_row = present_row orelse {
        std.debug.print("no write_file tool result row for the control placeholder.\n--- log tail ---\n{s}\n", .{clipped});
        return error.TestUnexpectedResult;
    };

    // ── Control first: the resolver really works over this wire. ──
    {
        var doc = try parseJson(present_content_row);
        defer doc.deinit();
        const tool = doc.str("tool") orelse {
            std.debug.print("control row has no `tool`: {s}\n", .{present_content_row});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, tool, "write_file")) return error.TestUnexpectedResult;
        if (doc.boolean("success") != true) {
            std.debug.print("a resolvable placeholder must dispatch and succeed: {s}\n", .{present_content_row});
            return error.TestUnexpectedResult;
        }
        if (!pathExists(control_written)) {
            std.debug.print("the control turn did not write its file\n", .{});
            return error.TestUnexpectedResult;
        }
        const got = try std.Io.Dir.cwd().readFileAlloc(io, control_written, gpa, .limited(1 << 20));
        defer gpa.free(got);
        if (!std.mem.eql(u8, got, FIRST_VALUE)) {
            std.debug.print("the executor should have received the real value\n", .{});
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, present_content_row, FIRST_VALUE) != null) {
            std.debug.print("the resolved value leaked into the persisted tool result\n", .{});
            return error.TestUnexpectedResult;
        }
    }

    // ── The required case. ──
    {
        var doc = try parseJson(unknown_content_row);
        defer doc.deinit();
        const tool = doc.str("tool") orelse return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, tool, "write_file")) {
            std.debug.print("envelope tool != write_file: {s}\n", .{unknown_content_row});
            return error.TestUnexpectedResult;
        }
        if (doc.boolean("success") != false) {
            std.debug.print("an unresolvable placeholder must not report success: {s}\n", .{unknown_content_row});
            return error.TestUnexpectedResult;
        }
        const data = doc.get("data") orelse return error.TestUnexpectedResult;
        if (data != .null) {
            std.debug.print("a refused call carries no data: {s}\n", .{unknown_content_row});
            return error.TestUnexpectedResult;
        }
        const err_str = doc.str("error") orelse {
            std.debug.print("envelope has no `error`: {s}\n", .{unknown_content_row});
            return error.TestUnexpectedResult;
        };
        if (std.mem.indexOf(u8, err_str, UNKNOWN_NAME) == null) {
            std.debug.print("the envelope must name the missing key: {s}\n", .{unknown_content_row});
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, err_str, "Nothing was run") == null) {
            std.debug.print("the envelope must say the call did not execute: {s}\n", .{unknown_content_row});
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, unknown_content_row, unknown_placeholder) == null) {
            std.debug.print("`parameters` must echo the unsubstituted arguments: {s}\n", .{unknown_content_row});
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, unknown_content_row, FIRST_VALUE) != null) {
            std.debug.print("the unrelated workspace secret leaked into a tool result\n", .{});
            return error.TestUnexpectedResult;
        }
    }

    if (pathExists(never_written)) {
        std.debug.print("the tool RAN despite the unresolvable placeholder\n", .{});
        return error.TestUnexpectedResult;
    }

    // The workspace's real secret is untouched by the failed turn.
    {
        var row = try oneNamed(&h, ws, PRESENT_NAME);
        defer row.deinit();
        if (!std.mem.eql(u8, row.id, present_id)) return error.TestUnexpectedResult;
    }
    if (try listCount(&h, ws) != 1) return error.TestUnexpectedResult;
    {
        const raw = try listSecretsRaw(&h, ws, &.{200});
        defer gpa.free(raw);
        try assertValueAbsent(raw, &.{FIRST_VALUE});
    }
}

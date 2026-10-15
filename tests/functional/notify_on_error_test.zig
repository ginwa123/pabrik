// Functional tests for the Pabrik General settings (notify_on_error /
// notify_on_complete / retry_delay_ms).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Fixtures / helpers
// ============================================================================

/// Where `getDefaultConfigDir` writes config.json. * macOS —
/// `~/Library/Application Support/pabrik`; `XDG_CONFIG_HOME` is NOT consulted
/// on that branch.
fn platformConfigDir(home: []const u8) ![]u8 {
    return switch (builtin.os.tag) {
        .macos => harness.harnessPath(gpa, home, &.{ "Library", "Application Support", "pabrik" }),
        .windows => harness.harnessPath(gpa, home, &.{ "AppData", "Roaming", "pabrik" }),
        else => harness.harnessPath(gpa, home, &.{ ".config", "pabrik" }),
    };
}

fn platformConfigPath(home: []const u8) ![]u8 {
    const dir = try platformConfigDir(home);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, "config.json" });
}

/// Boot the harness the way Python's `config_harness` fixture did.
fn bootConfigHarness() !Harness {
    return Harness.boot(io, gpa, .{ .stub_llm_profile = true });
}

/// The on-disk `config.json` the running server loaded at boot.
/// `.alloc_always` — the returned document must outlive the bytes buffer this
/// helper frees.
fn onDiskConfig(h: *Harness) !std.json.Parsed(std.json.Value) {
    const path = try platformConfigPath(h.temp_dir);
    defer gpa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    return std.json.parseFromSlice(std.json.Value, gpa, bytes, .{ .allocate = .alloc_always });
}

/// One `PUT /api/config/pabrik` body. A `null` setting is OMITTED from the
/// wire, which is exactly the `?bool = null` / `?u32 = null` "don't touch"
/// sentinel these tests are about.
const GeneralSettings = struct {
    notify_on_complete: ?bool = null,
    notify_on_error: ?bool = null,
    retry_delay_ms: ?u32 = null,
};

/// The bare-minimum profile payload every PUT carries — the same `stub`
/// profile the harness installer writes, which keeps the live-reload
/// validator happy (it refuses an empty `profiles` map).
const STUB_PROFILE_JSON =
    \\{"stub":{"model":"stub-model","base_url":"http://127.0.0.1:1","api_key":"stub-key-not-real"}}
;

fn putGeneralSettings(h: *Harness, s: GeneralSettings) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.print("{{\"profiles\":{s},\"active_profile\":\"stub\"", .{STUB_PROFILE_JSON});
    if (s.notify_on_complete) |v| {
        try out.writer.print(",\"notify_on_complete\":{}", .{v});
    }
    if (s.notify_on_error) |v| {
        try out.writer.print(",\"notify_on_error\":{}", .{v});
    }
    if (s.retry_delay_ms) |v| {
        try out.writer.print(",\"retry_delay_ms\":{d}", .{v});
    }
    try out.writer.writeAll("}");
    const body = try out.toOwnedSlice();
    defer gpa.free(body);

    var r = try h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = &.{200} });
    r.deinit();
}

fn getConfig(h: *Harness) !std.json.Parsed(std.json.Value) {
    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    return std.json.parseFromSlice(std.json.Value, gpa, r.body, .{ .allocate = .alloc_always });
}

/// `true` iff `key` is present on `doc` AND is exactly the boolean
/// `want`. Python's `doc.get(key) is True` rejects both a missing key
/// and a non-bool, and so does this.
fn expectBool(doc: *const std.json.Parsed(std.json.Value), key: []const u8, want: bool) !void {
    const obj = switch (doc.value) {
        .object => |o| o,
        else => {
            std.debug.print("config document is not a JSON object\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    const v = obj.get(key) orelse {
        std.debug.print("config document has no `{s}` key\n", .{key});
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .bool => |b| b,
        else => {
            std.debug.print("config `{s}` is not a boolean\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
    if (got != want) {
        std.debug.print("config `{s}` = {}, expected {}\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

fn expectInt(doc: *const std.json.Parsed(std.json.Value), key: []const u8, want: i64) !void {
    const obj = switch (doc.value) {
        .object => |o| o,
        else => {
            std.debug.print("config document is not a JSON object\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    const v = obj.get(key) orelse {
        std.debug.print("config document has no `{s}` key\n", .{key});
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .integer => |i| i,
        else => {
            std.debug.print("config `{s}` is not an integer\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
    if (got != want) {
        std.debug.print("config `{s}` = {d}, expected {d}\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 1: defaults are seeded when the on-disk config is missing
// ============================================================================

// A fresh harness has the on-disk config seeded by the stub installer
// (only `profiles_models` + `selected_profile_model`). GET must default
// the new fields to safe zero values: false / false / 0.
test "get_returns_default_values_for_new_install" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try getConfig(&h);
    defer r.deinit();
    try expectBool(&r, "notify_on_complete", false);
    try expectBool(&r, "notify_on_error", false);
    try expectInt(&r, "retry_delay_ms", 0);
}

// ============================================================================
// Test 2: PUT notify_on_error: true round-trips through GET + on-disk
// ============================================================================

// This is the EXACT wire body the General tab sends when the user
// toggles "Notify when agent fails" on and clicks Save.
test "put_notify_on_error_true_round_trips_through_get_and_disk" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try putGeneralSettings(&h, .{
        .notify_on_complete = false,
        .notify_on_error = true,
        .retry_delay_ms = 0,
    });

    // GET → field is true.
    {
        var r = try getConfig(&h);
        defer r.deinit();
        try expectBool(&r, "notify_on_error", true);
    }

    // On-disk JSON → field is true (NOT just the in-memory reload).
    {
        var d = try onDiskConfig(&h);
        defer d.deinit();
        try expectBool(&d, "notify_on_error", true);
    }
}

// ============================================================================
// Test 3: explicit false flips an existing true
// ============================================================================

// Locks in the `if (input.notify_on_error) |n| { config_json.notify_on_error
// = n; }` apply block — a refactor that only writes `true`, or that
// treats an absent key as `false`, surfaces here.
test "put_notify_on_error_false_flips_an_existing_true" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Seed: ON first.
    try putGeneralSettings(&h, .{ .notify_on_error = true });
    {
        var r1 = try getConfig(&h);
        defer r1.deinit();
        try expectBool(&r1, "notify_on_error", true);
    }

    // Now toggle OFF.
    try putGeneralSettings(&h, .{ .notify_on_error = false });

    // GET shows false; on-disk shows false.
    {
        var r2 = try getConfig(&h);
        defer r2.deinit();
        try expectBool(&r2, "notify_on_error", false);
    }
    {
        var d = try onDiskConfig(&h);
        defer d.deinit();
        try expectBool(&d, "notify_on_error", false);
    }
}

// ============================================================================
// Test 4: omitting notify_on_error preserves the on-disk value
// ============================================================================

// A PUT body that omits `notify_on_error` leaves the on-disk value untouched
// (`?bool = null` semantics).
test "omitting_notify_on_error_does_not_reset_it" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Seed: ON with a non-default retry delay.
    try putGeneralSettings(&h, .{
        .notify_on_complete = false,
        .notify_on_error = true,
        .retry_delay_ms = 10_000,
    });
    {
        var before = try onDiskConfig(&h);
        defer before.deinit();
        try expectBool(&before, "notify_on_error", true);
        try expectInt(&before, "retry_delay_ms", 10_000);
    }

    // PUT a body that ONLY carries `profiles` + `active_profile` — no
    // notify_on_error, no notify_on_complete, no retry_delay_ms.
    try putGeneralSettings(&h, .{});

    // GET shows the field is STILL true (untouched).
    {
        var r = try getConfig(&h);
        defer r.deinit();
        try expectBool(&r, "notify_on_error", true);
    }

    // On-disk check — exact values persisted.
    {
        var after = try onDiskConfig(&h);
        defer after.deinit();
        try expectBool(&after, "notify_on_error", true);
        try expectInt(&after, "retry_delay_ms", 10_000);
    }
}

// ============================================================================
// Test 5: notify_on_error + notify_on_complete are independent
// ============================================================================

// Both flags are plain booleans on the wire. A PUT that sets BOTH must
// round-trip BOTH, and flipping one must not reset the other — a refactor
// that collapses them into a tri-state `notif` enum surfaces here.
test "notify_on_error_and_notify_on_complete_are_independent" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try putGeneralSettings(&h, .{
        .notify_on_complete = true,
        .notify_on_error = false,
    });

    {
        var r1 = try getConfig(&h);
        defer r1.deinit();
        try expectBool(&r1, "notify_on_complete", true);
        try expectBool(&r1, "notify_on_error", false);
    }

    // Flip ONLY notify_on_error; complete stays true. `notify_on_complete`
    // is sent AGAIN to model the frontend's unconditional write-through.
    try putGeneralSettings(&h, .{
        .notify_on_complete = true,
        .notify_on_error = true,
    });

    {
        var r2 = try getConfig(&h);
        defer r2.deinit();
        try expectBool(&r2, "notify_on_complete", true);
        try expectBool(&r2, "notify_on_error", true);
    }

    // Disk check.
    {
        var d = try onDiskConfig(&h);
        defer d.deinit();
        try expectBool(&d, "notify_on_complete", true);
        try expectBool(&d, "notify_on_error", true);
    }
}

// ============================================================================
// Test 6: retry_delay_ms clamps to [0, 60_000] on PUT
// ============================================================================

// The backend's apply block clamps `retry_delay_ms` to 60 000: a larger value
// would lock the user out of cancelable recovery.
test "retry_delay_ms_clamps_to_60_000_on_put" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // In-range → unchanged.
    try putGeneralSettings(&h, .{ .retry_delay_ms = 30_000 });
    {
        var r = try getConfig(&h);
        defer r.deinit();
        try expectInt(&r, "retry_delay_ms", 30_000);
    }

    // At the boundary → unchanged.
    try putGeneralSettings(&h, .{ .retry_delay_ms = 60_000 });
    {
        var r = try getConfig(&h);
        defer r.deinit();
        try expectInt(&r, "retry_delay_ms", 60_000);
    }

    // Just above the boundary → clamps to 60_000.
    try putGeneralSettings(&h, .{ .retry_delay_ms = 60_001 });
    {
        var r = try getConfig(&h);
        defer r.deinit();
        try expectInt(&r, "retry_delay_ms", 60_000);
    }

    // Way above → clamps to 60_000. Also on-disk.
    try putGeneralSettings(&h, .{ .retry_delay_ms = 999_999 });
    {
        var r = try getConfig(&h);
        defer r.deinit();
        try expectInt(&r, "retry_delay_ms", 60_000);
    }
    {
        var d = try onDiskConfig(&h);
        defer d.deinit();
        try expectInt(&d, "retry_delay_ms", 60_000);
    }
}

// ============================================================================
// Test 7: on-disk JSON shape preserves all three operational fields
// ============================================================================

// After a SET-all-three PUT the on-disk config.json must literally
// contain all three keys with the expected values — it is the artifact
// every reload (server restart, settings re-fetch) reads.
test "on_disk_json_shape_preserves_all_three_operational_fields" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try putGeneralSettings(&h, .{
        .notify_on_complete = true,
        .notify_on_error = true,
        .retry_delay_ms = 15_000,
    });

    var d = try onDiskConfig(&h);
    defer d.deinit();

    // `expectBool`/`expectInt` reject an ABSENT key as well as a wrong
    // value, which is what the Python `assert key in on_disk` lines did.
    try expectBool(&d, "notify_on_complete", true);
    try expectBool(&d, "notify_on_error", true);
    try expectInt(&d, "retry_delay_ms", 15_000);
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = platformConfigDir;
    _ = platformConfigPath;
    _ = bootConfigHarness;
    _ = onDiskConfig;
    _ = putGeneralSettings;
    _ = getConfig;
    _ = expectBool;
    _ = expectInt;
    _ = Harness.boot;
}

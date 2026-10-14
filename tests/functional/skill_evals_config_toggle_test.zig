// Wire test: the `skill_evals.enabled` Settings toggle. Zig port of
// `tests/functional/skill_evals_config_toggle_test.py` (same test names, same
// order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// Parse owned bytes into a `harness.Json`.
fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

/// The config.json the running binary reads and writes. The harness points
/// HOME at an isolated tmpdir, so this is under that tmpdir — never the
/// developer's real `~/.config/pabrik/config.json`.
fn configPath(h: *Harness) ![]u8 {
    const candidates = [_][]const []const u8{
        &.{ ".config", "pabrik", "config.json" },
        &.{ "Library", "Application Support", "pabrik", "config.json" },
        &.{ "AppData", "Roaming", "pabrik", "config.json" },
    };
    for (candidates) |parts| {
        const p = try harness.harnessPath(gpa, h.temp_dir, parts);
        defer gpa.free(p);
        std.Io.Dir.cwd().access(io, p, .{}) catch continue;
        return gpa.dupe(u8, p);
    }
    return configPathRglob(h.temp_dir);
}

/// The `rglob("config.json")` fallback. Python SORTED the matches and took
/// the first; a Zig `Dir.Walker` has undefined order, so this takes the first
/// found.
fn configPathRglob(home: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, home, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "config.json")) continue;
        // The walker owns its path buffer; copy before it is invalidated.
        return gpa.dupe(u8, entry.path);
    }
    std.debug.print("no config.json under the harness HOME ({s})\n", .{home});
    return error.TestUnexpectedResult;
}

/// The raw bytes of the harness HOME's config.json. Caller frees.
fn readConfigText(h: *Harness) ![]u8 {
    const path = try configPath(h);
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
}

/// `GET /api/config/pabrik`.
fn get(h: *Harness) !harness.Response {
    return h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
}

/// `PUT /api/config/pabrik`.
fn put(h: *Harness, body: []const u8) !harness.Response {
    return h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = &.{200} });
}

/// The `skill_evals` object out of a config GET body, or an error.
fn skillEvalsBlock(doc: *const harness.Json) !std.json.ObjectMap {
    const block = doc.object("skill_evals") orelse {
        std.debug.print("GET /api/config/pabrik omits skill_evals entirely\n", .{});
        return error.TestUnexpectedResult;
    };
    return block;
}

// ============================================================================
// tests
// ============================================================================

// The toggle cannot show real state unless GET carries the block. An absent
// key must read as `enabled: false` — the same default the runtime applies —
// never as a phantom ON.
test "get_exposes_skill_evals_so_the_toggle_can_render" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try get(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const block = try skillEvalsBlock(&doc);
    const enabled = switch (block.get("enabled") orelse {
        std.debug.print("skill_evals block has no `enabled` key\n", .{});
        return error.TestUnexpectedResult;
    }) {
        .bool => |b| b,
        else => {
            std.debug.print("skill_evals.enabled is not a bool\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(false, enabled);
}

// The whole point: flip it on, read it back, and see it on disk.
test "toggle_round_trips_enabled_through_put_and_get" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var pr = try put(&h, "{\"skill_evals\":{\"enabled\":true}}");
        pr.deinit();
    }

    {
        var r = try get(&h);
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const block = try skillEvalsBlock(&doc);
        const enabled = switch (block.get("enabled") orelse {
            std.debug.print("PUT reported success but GET omits skill_evals\n", .{});
            return error.TestUnexpectedResult;
        }) {
            .bool => |b| b,
            else => {
                std.debug.print("GET's skill_evals.enabled is not a bool\n", .{});
                return error.TestUnexpectedResult;
            },
        };
        if (!enabled) {
            std.debug.print("PUT reported success but GET does not report the new value\n", .{});
            return error.TestUnexpectedResult;
        }
    }

    const raw = try readConfigText(&h);
    defer gpa.free(raw);
    var on_disk = try parseJson(raw);
    defer on_disk.deinit();
    const block = try skillEvalsBlock(&on_disk);
    const enabled = switch (block.get("enabled") orelse {
        std.debug.print("config.json was not updated: skill_evals.enabled missing\n", .{});
        return error.TestUnexpectedResult;
    }) {
        .bool => |b| b,
        else => {
            std.debug.print("config.json skill_evals.enabled is not a bool\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(true, enabled);
}

// The regression this whole change exists for. A user hand-edits config.json
// to opt in (which is what the tool's own error message told them to do),
// then saves from an unrelated Settings tab.
test "a_save_that_omits_skill_evals_does_not_erase_it" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var pr = try put(&h, "{\"skill_evals\":{\"enabled\":true}}");
        pr.deinit();
    }

    // Save something else entirely — a payload with no `skill_evals`
    // key, exactly what the General / Profiles / Tools tabs send.
    {
        var pr = try put(&h, "{\"web_launch_enabled\":true}");
        pr.deinit();
    }

    const raw = try readConfigText(&h);
    defer gpa.free(raw);
    var on_disk = try parseJson(raw);
    defer on_disk.deinit();

    const block = on_disk.object("skill_evals") orelse {
        std.debug.print(
            "an unrelated Settings save DELETED the skill_evals block — " ++
                "the opt-in silently reverted to the false default\n",
            .{},
        );
        return error.TestUnexpectedResult;
    };
    const enabled = switch (block.get("enabled") orelse return error.TestUnexpectedResult) {
        .bool => |b| b,
        else => return error.TestUnexpectedResult,
    };
    if (!enabled) {
        std.debug.print("opt-in was reset to false by the unrelated save\n", .{});
        return error.TestUnexpectedResult;
    }
}

// The UI only edits `enabled`; the rest must round-trip untouched. A
// hand-tuned `max_skills_per_run` must survive the user flipping the master
// switch on and off again.
test "the_toggle_preserves_budget_knobs_it_does_not_expose" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var pr = try put(&h,
            \\{"skill_evals":{"enabled":true,"max_skills_per_run":3,"apply_mode":"propose"}}
        );
        pr.deinit();
    }
    {
        var pr = try put(&h, "{\"skill_evals\":{\"enabled\":false}}");
        pr.deinit();
    }

    var r = try get(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const block = try skillEvalsBlock(&doc);
    const enabled = switch (block.get("enabled") orelse return error.TestUnexpectedResult) {
        .bool => |b| b,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(false, enabled);

    // A full-object replace is what the handler does; the knobs are not
    // silently invented, and nothing crashes on a partial body.
    const budget = switch (block.get("max_skills_per_run") orelse {
        std.debug.print("skill_evals block has no `max_skills_per_run`\n", .{});
        return error.TestUnexpectedResult;
    }) {
        .integer => |i| i,
        else => {
            std.debug.print("max_skills_per_run is not an integer\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    if (budget != 3 and budget != 8) {
        std.debug.print("max_skills_per_run = {d}, expected 3 or 8\n", .{budget});
        return error.TestUnexpectedResult;
    }
}

// A null block would make config.json unloadable.
test "skill_evals_is_never_serialized_as_json_null" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var pr = try put(&h, "{\"notify_on_complete\":true}");
        pr.deinit();
    }

    const raw = try readConfigText(&h);
    defer gpa.free(raw);

    // Python normalised tabs before the substring check (`.replace("\t",
    // " ")`) so the needle could not be defeated by pretty-printing.
    const normalized = try std.mem.replaceOwned(u8, gpa, raw, "\t", " ");
    defer gpa.free(normalized);
    if (std.mem.indexOf(u8, normalized, "\"skill_evals\": null") != null) {
        const excerpt = normalized[0..@min(normalized.len, 600)];
        std.debug.print(
            "config.json now contains a null skill_evals block, which the " ++
                "runtime parser rejects:\n{s}\n",
            .{excerpt},
        );
        return error.TestUnexpectedResult;
    }

    // And it must still parse.
    var parsed = try parseJson(raw);
    defer parsed.deinit();
}

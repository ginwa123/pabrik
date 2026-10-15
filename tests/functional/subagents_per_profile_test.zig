// Subagents are per-profile only (plan 2026-09-04-subagents-per-profile). Zig
// port of `tests/functional/subagents_per_profile_test.py` (same test names,
// same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Fixtures / shared shapes
// ============================================================================

/// The module-level `SA` sub-agent. Field names and values are the
/// Python dict's, verbatim.
const SubAgent = struct {
    name: []const u8,
    model: []const u8,
    base_url: []const u8,
    thinking: []const u8,
    temperature: []const u8,
    url_style: []const u8,
    api_key: []const u8,
    system_prompt: []const u8,
};

const SA = SubAgent{
    .name = "reviewer",
    .model = "gpt-4o",
    .base_url = "https://api.openai.com/v1",
    .thinking = "true",
    .temperature = "0.3",
    .url_style = "openai",
    .api_key = "reviewer-key",
    .system_prompt = "You are a strict code reviewer.",
};

/// `dict(SA, name="helper", system_prompt="You help.")` — the REPLACEMENT
/// list the third test pushes through a granular update.
const SA2 = SubAgent{
    .name = "helper",
    .model = "gpt-4o",
    .base_url = "https://api.openai.com/v1",
    .thinking = "true",
    .temperature = "0.3",
    .url_style = "openai",
    .api_key = "reviewer-key",
    .system_prompt = "You help.",
};

/// `bootConfig()` — the `config_harness` fixture.
fn bootConfig() !Harness {
    return Harness.boot(io, gpa, .{ .stub_llm_profile = true });
}

/// `GET /api/config/pabrik`.
fn getConfig(h: *Harness) !harness.Response {
    return h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
}

/// `PUT /api/config/pabrik` with the EXACT wire body a caller built.
fn putConfig(h: *Harness, body: []const u8) !harness.Response {
    return h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = &.{200} });
}

/// `_profiles(h)` — assert the top-level `sub_agents` is null/absent, then
/// return the `profiles` map of a GET body.
fn expectTopLevelSubAgentsNull(doc: *const harness.Json) !void {
    const v = doc.get("sub_agents") orelse return;
    if (v != .null) {
        std.debug.print(
            "top-level sub_agents must be null on the wire, got {any}\n",
            .{v},
        );
        return error.TestUnexpectedResult;
    }
}

/// The `profiles.<name>` object out of a GET body.
fn profileObject(doc: *const harness.Json, name: []const u8) !std.json.ObjectMap {
    const profiles = doc.object("profiles") orelse {
        std.debug.print("GET /api/config/pabrik has no `profiles` object\n", .{});
        return error.TestUnexpectedResult;
    };
    const v = profiles.get(name) orelse {
        std.debug.print("no profile named '{s}' on the wire\n", .{name});
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .object => |o| o,
        else => {
            std.debug.print("profile '{s}' is not an object\n", .{name});
            return error.TestUnexpectedResult;
        },
    };
}

/// One string field of a profile, or a test failure.
fn expectProfileStr(profile: std.json.ObjectMap, key: []const u8, want: []const u8) !void {
    const v = profile.get(key) orelse {
        std.debug.print("profile has no `{s}` field (wanted {s})\n", .{ key, want });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .string => |sv| sv,
        else => {
            std.debug.print("profile `{s}` is not a string\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqualStrings(want, got);
}

/// Assert `profile.sub_agents == [want]`.
fn expectSubAgentsEq(profile: std.json.ObjectMap, want: SubAgent) !void {
    const v = profile.get("sub_agents") orelse {
        std.debug.print("profile has no `sub_agents` list\n", .{});
        return error.TestUnexpectedResult;
    };
    const arr = switch (v) {
        .array => |a| a,
        else => {
            std.debug.print("profile `sub_agents` is not an array\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    if (arr.items.len != 1) {
        std.debug.print("expected exactly 1 sub-agent, got {d}\n", .{arr.items.len});
        return error.TestUnexpectedResult;
    }
    const entry = switch (arr.items[0]) {
        .object => |o| o,
        else => {
            std.debug.print("sub_agents[0] is not an object\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    try expectSubAgentStr(entry, "name", want.name);
    try expectSubAgentStr(entry, "model", want.model);
    try expectSubAgentStr(entry, "base_url", want.base_url);
    try expectSubAgentStr(entry, "thinking", want.thinking);
    try expectSubAgentStr(entry, "temperature", want.temperature);
    try expectSubAgentStr(entry, "url_style", want.url_style);
    try expectSubAgentStr(entry, "api_key", want.api_key);
    try expectSubAgentStr(entry, "system_prompt", want.system_prompt);
}

fn expectSubAgentStr(entry: std.json.ObjectMap, key: []const u8, want: []const u8) !void {
    const v = entry.get(key) orelse {
        std.debug.print("sub_agents[0] has no `{s}` field (wanted {s})\n", .{ key, want });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .string => |sv| sv,
        else => {
            std.debug.print("sub_agents[0].`{s}` is not a string\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqualStrings(want, got);
}

/// The `PUT` body that seeds the `stub` profile carrying `sub_agents` — the
/// OBJECT-MAP shape (`{"profiles": {"stub": {...}}}`).
fn objectMapBody(sub_agents: []const SubAgent) ![]u8 {
    // Anonymous struct literals: Zig infers the shape, and
    // `Stringify` emits exactly the JSON the Python dict produced —
    // nested object for the map, nested array for the list.
    const Entry = struct {
        model: []const u8,
        base_url: []const u8,
        api_key: []const u8,
        url_style: []const u8,
        sub_agents: []const SubAgent,
    };
    return std.json.Stringify.valueAlloc(gpa, .{
        .profiles = .{
            .stub = Entry{
                .model = "stub-model",
                .base_url = "http://127.0.0.1:1",
                .api_key = "stub-key-not-real",
                .url_style = "openai",
                .sub_agents = sub_agents,
            },
        },
    }, .{});
}

/// The GRANULAR shape (`{"profiles": [ {..., "action": "update"} ]}`).
fn granularUpdateBody(
    model: []const u8,
    sub_agents: ?[]const SubAgent,
) ![]u8 {
    const Entry = struct {
        name: []const u8,
        action: []const u8,
        model: []const u8,
        base_url: []const u8,
        thinking: []const u8,
        temperature: []const u8,
        url_style: []const u8,
        api_key: []const u8,
        sub_agents: ?[]const SubAgent = null,
    };
    return std.json.Stringify.valueAlloc(gpa, .{
        .profiles = &[_]Entry{
            .{
                .name = "stub",
                .action = "update",
                .model = model,
                .base_url = "http://127.0.0.1:1",
                .thinking = "auto",
                .temperature = "auto",
                .url_style = "openai",
                .api_key = "stub-key-not-real",
                .sub_agents = sub_agents,
            },
        },
    }, .{});
}

// ============================================================================
// Tests
// ============================================================================

// `PUT` object-map shape with a profile carrying `sub_agents` → `GET`
// shows the list under that profile and null at the top level.
test "per_profile_subagents_round_trip_via_object_map" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfig();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    {
        const body = try objectMapBody(&[_]SubAgent{SA});
        defer gpa.free(body);
        var r = try putConfig(&h, body);
        defer r.deinit();
    }

    var r = try getConfig(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectTopLevelSubAgentsNull(&doc);
    const stub = try profileObject(&doc, "stub");
    try expectSubAgentsEq(stub, SA);
}

// A granular `update` that omits `sub_agents` must NOT wipe the
// profile's existing list (the clobber regression).
test "granular_update_without_subagents_preserves_list" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfig();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    {
        const body = try objectMapBody(&[_]SubAgent{SA});
        defer gpa.free(body);
        var r = try putConfig(&h, body);
        defer r.deinit();
    }

    // Granular update touches only the model; sub_agents omitted.
    {
        const body = try granularUpdateBody("stub-model-v2", null);
        defer gpa.free(body);
        var r = try putConfig(&h, body);
        defer r.deinit();
    }

    var r = try getConfig(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectTopLevelSubAgentsNull(&doc);
    const stub = try profileObject(&doc, "stub");
    try expectProfileStr(stub, "model", "stub-model-v2");
    // The whole point of this test.
    try expectSubAgentsEq(stub, SA);
}

// A granular `update` WITH `sub_agents` replaces the profile's list.
test "granular_update_with_subagents_replaces_list" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfig();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    {
        const body = try objectMapBody(&[_]SubAgent{SA});
        defer gpa.free(body);
        var r = try putConfig(&h, body);
        defer r.deinit();
    }

    {
        const body = try granularUpdateBody("stub-model", &[_]SubAgent{SA2});
        defer gpa.free(body);
        var r = try putConfig(&h, body);
        defer r.deinit();
    }

    var r = try getConfig(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectTopLevelSubAgentsNull(&doc);
    const stub = try profileObject(&doc, "stub");
    // Wholesale, not merged: SA2 replaces SA.
    try expectSubAgentsEq(stub, SA2);
}

// ─── `_candidate_config_paths` ─────────────────────────────────────────────

/// Every config.json location the server might read on this box.
const CANDIDATE_CONFIG_PARTS = [_][]const []const u8{
    &.{ ".config", "pabrik", "config.json" },
    &.{ "Library", "Application Support", "pabrik", "config.json" },
    &.{ "AppData", "Roaming", "pabrik", "config.json" },
};

fn candidateConfigPath(h: *Harness, index: usize) ![]u8 {
    return harness.harnessPath(gpa, h.temp_dir, CANDIDATE_CONFIG_PARTS[index]);
}

/// `SA` as a standalone `std.json.Value`, for writing the LEGACY on-disk
/// shape. `.allocate = .alloc_always` IS LOAD-BEARING.
fn parseSaValue() !std.json.Parsed(std.json.Value) {
    // ONE ELEMENT WRAPPER. Python wrote `disk["sub_agents"] = [SA]` — a LIST
    // of one entry — and `std.json.Stringify.valueAlloc(gpa, SA, .{})`
    // produces the bare OBJECT.
    const sa_obj = try std.json.Stringify.valueAlloc(gpa, SA, .{});
    defer gpa.free(sa_obj);

    const wrapped = try std.fmt.allocPrint(gpa, "[{s}]", .{sa_obj});
    defer gpa.free(wrapped);

    return std.json.parseFromSlice(std.json.Value, gpa, wrapped, .{ .allocate = .alloc_always });
}

// A `PUT` save migrates a legacy on-disk top-level `sub_agents` array
// into profiles missing their own list, then strips the key.
test "put_strips_deprecated_top_level_key_from_disk" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfig();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    var sa_parsed = try parseSaValue();
    defer sa_parsed.deinit();

    // Seed the legacy shape into EVERY candidate path so the migration
    // triggers no matter which path the server reads on this platform.
    var seeded: usize = 0;
    for (CANDIDATE_CONFIG_PARTS, 0..) |_, index| {
        const path = try candidateConfigPath(&h, index);
        defer gpa.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(bytes);

        // `.alloc_always` for the same reason as `parseSaValue` — the tree
        // outlives nothing here, but the `sub_agents` value INSERTED into it
        // does, and a tree whose own strings borrow from `bytes` is only safe
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{ .allocate = .alloc_always }) catch continue;
        defer parsed.deinit();

        // `if not isinstance(disk.get("profiles_models"), dict): continue`
        const profiles_ptr = blk: {
            const v = parsed.value.object.getPtr("profiles_models") orelse break :blk null;
            break :blk switch (v.*) {
                .object => |*o| o,
                else => null,
            };
        };
        const profiles = profiles_ptr orelse continue;

        // `disk["sub_agents"] = [SA]`
        parsed.value.object.put(gpa, "sub_agents", sa_parsed.value) catch continue;

        // `for prof in disk["profiles_models"].values(): prof.pop("sub_agents", None)`
        var it = profiles.iterator();
        while (it.next()) |entry| {
            const prof_ptr = switch (entry.value_ptr.*) {
                .object => |*o| o,
                else => continue,
            };
            _ = prof_ptr.orderedRemove("sub_agents");
        }

        // `cfg_path.write_text(json.dumps(disk))`
        const out = std.json.Stringify.valueAlloc(gpa, parsed.value, .{}) catch continue;
        defer gpa.free(out);
        {
            var f = std.Io.Dir.cwd().createFile(io, path, .{}) catch continue;
            defer f.close(io);
            f.writeStreamingAll(io, out) catch continue;
        }
        seeded += 1;
    }
    if (seeded == 0) {
        std.debug.print("harness stub config missing at every candidate path\n", .{});
        return error.TestUnexpectedResult;
    }

    {
        var r = try putConfig(&h, "{}");
        defer r.deinit();
    }

    // Wire contract first (platform-independent): the stub profile must show
    // the migrated list and the top level must read null.
    {
        var r = try getConfig(&h);
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        try expectTopLevelSubAgentsNull(&doc);
        const stub = try profileObject(&doc, "stub");
        try expectSubAgentsEq(stub, SA);
    }

    // Disk contract: whichever candidate path(s) the server actually wrote
    // show the migrated stub AND a stripped top-level key (Zig Stringify
    // emits `"sub_agents": null` for the stripped key rather than omitting it
    var migrated_paths: usize = 0;
    for (CANDIDATE_CONFIG_PARTS, 0..) |_, index| {
        const path = try candidateConfigPath(&h, index);
        defer gpa.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(bytes);

        var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{ .allocate = .alloc_always }) catch continue;
        defer parsed.deinit();

        // `stub = (disk_after.get("profiles_models") or {}).get("stub") or {}`
        const stub = blk: {
            const pm = parsed.value.object.get("profiles_models") orelse break :blk null;
            const pmo = switch (pm) {
                .object => |o| o,
                else => break :blk null,
            };
            const stub_v = pmo.get("stub") orelse break :blk null;
            break :blk switch (stub_v) {
                .object => |o| o,
                else => null,
            };
        };
        const stub_obj = stub orelse continue;

        // `if [s.get("name") for s in (stub.get("sub_agents") or [])] != ["reviewer"]: continue`
        const stub_sas = blk: {
            const v = stub_obj.get("sub_agents") orelse break :blk null;
            break :blk switch (v) {
                .array => |a| a,
                else => null,
            };
        };
        if (stub_sas == null) continue;
        if (stub_sas.?.items.len != 1) continue;
        const first_name = switch (stub_sas.?.items[0]) {
            .object => |o| blk: {
                const nv = o.get("name") orelse break :blk null;
                break :blk switch (nv) {
                    .string => |sv| sv,
                    else => null,
                };
            },
            else => null,
        };
        const first_name_str = first_name orelse continue;
        if (!std.mem.eql(u8, first_name_str, "reviewer")) continue;

        migrated_paths += 1;

        // `assert disk_after.get("sub_agents") is None`
        const top = parsed.value.object.get("sub_agents") orelse continue;
        if (top != .null) {
            std.debug.print(
                "deprecated top-level key must be stripped to null on {s}, got {any}\n",
                .{ path, top },
            );
            return error.TestUnexpectedResult;
        }
    }
    if (migrated_paths == 0) {
        std.debug.print(
            "PUT migrated via GET but no candidate disk path shows the migrated stub " ++
                "— server wrote outside the isolated HOME?\n",
            .{},
        );
        return error.TestUnexpectedResult;
    }
}

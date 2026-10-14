// Functional test for the `add_mcp_server` agent tool. Zig port of
// `tests/functional/agent_add_mcp_server_test.py` (same test names, same
// order).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// On-disk config directory for `home`, per `LlmConfig.getDefaultConfigDir`
/// (Config.zig). Python `_platform_config_dir`; the harness shadows HOME (and
/// APPDATA on Windows), so the tree below is always the one the binary wrote.
fn platformConfigDir(home: []const u8) ![]u8 {
    const parts: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "Library", "Application Support", "pabrik" },
        .windows => &.{ "AppData", "Roaming", "pabrik" },
        else => &.{ ".config", "pabrik" },
    };
    return harness.harnessPath(gpa, home, parts);
}

/// One stdio MCP server entry, the shape `rebuildMcpServersParsed`
/// (Config.zig) emits and the agent tool writes.
const StdioServer = struct {
    command: []const u8,
    args: []const []const u8,
    /// Absent on the second server in step 5 — mirrors the Python, which
    /// omitted `cwd` there.
    cwd: ?[]const u8 = null,
};

/// Parse `body` into an arena-backed document the caller owns. `leaky` into
/// `gpa` on purpose: the returned arena is freed by the single `deinit()`
/// below, so nothing escapes the tree.
fn parseDoc(body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, body, .{});
}

/// Mutable view of the parsed document's top-level object.
fn objPtr(doc: *std.json.Parsed(std.json.Value)) *std.json.ObjectMap {
    return switch (doc.value) {
        .object => |*o| o,
        else => unreachable, // callers check via parseDoc's contract
    };
}

/// Insert `entry` into `doc`'s `mcp_servers` object, creating the object when
/// the document has none.
fn upsertMcpServer(doc: *std.json.Parsed(std.json.Value), name: []const u8, entry: StdioServer) !void {
    const a = doc.arena.allocator();

    // Serialise through std.json so the binary path / args are escaped
    // exactly as the server's own writer would escape them.
    const entry_json = try std.json.Stringify.valueAlloc(gpa, entry, .{});
    defer gpa.free(entry_json);
    const entry_value = try std.json.parseFromSliceLeaky(std.json.Value, a, entry_json, .{});

    // `getPtr` (not `get`) because the map that comes back has to be MUTABLE
    // to accept the new server — `get` hands out a const copy, and inserting
    // into that copy would leave the document untouched.
    if (objPtr(doc).getPtr("mcp_servers")) |slot| {
        switch (slot.*) {
            .object => {
                // `slot.*` is an lvalue (through a mutable pointer), so the
                // capture has to be by POINTER: an unmanaged ObjectMap's
                // `put` replaces the map's own buffer, so mutating a by-value
                switch (slot.*) {
                    .object => |*servers| servers.put(a, name, entry_value) catch return error.OutOfMemory,
                    else => unreachable,
                }
                return;
            },
            .null => {},
            else => {
                std.debug.print("`mcp_servers` is present but is neither an object nor null\n", .{});
                return error.TestUnexpectedResult;
            },
        }
    }

    var fresh: std.json.ObjectMap = .empty;
    fresh.put(a, name, entry_value) catch return error.OutOfMemory;
    objPtr(doc).put(a, "mcp_servers", .{ .object = fresh }) catch return error.OutOfMemory;
}

/// Read `key` → sub-object → `leaf` out of `obj`, as a string slice borrowed
/// from the (still alive) parsed document.
fn nestedStr(obj: std.json.ObjectMap, key: []const u8, leaf: []const u8, ctx: []const u8) ![]const u8 {
    const sub = obj.get(key) orelse {
        std.debug.print("{s}: no `{s}` entry\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const so = switch (sub) {
        .object => |o| o,
        else => {
            std.debug.print("{s}: `{s}` is not an object\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    const v = so.get(leaf) orelse {
        std.debug.print("{s}: `{s}` has no `{s}`\n", .{ ctx, key, leaf });
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .string => |s| s,
        else => {
            std.debug.print("{s}: `{s}.{s}` is not a string\n", .{ ctx, key, leaf });
            return error.TestUnexpectedResult;
        },
    };
}

/// Read `key` → `leaf` as a string array. The Python asserted
/// `hello.get("args") == ["--flag"]`.
fn nestedStrArray(obj: std.json.ObjectMap, key: []const u8, leaf: []const u8, ctx: []const u8) ![][]const u8 {
    const sub = obj.get(key) orelse {
        std.debug.print("{s}: no `{s}` entry\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const so = switch (sub) {
        .object => |o| o,
        else => {
            std.debug.print("{s}: `{s}` is not an object\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    const v = so.get(leaf) orelse {
        std.debug.print("{s}: `{s}` has no `{s}`\n", .{ ctx, key, leaf });
        return error.TestUnexpectedResult;
    };
    const arr = switch (v) {
        .array => |av| av,
        else => {
            std.debug.print("{s}: `{s}.{s}` is not an array\n", .{ ctx, key, leaf });
            return error.TestUnexpectedResult;
        },
    };
    var out = try gpa.alloc([]const u8, arr.items.len);
    errdefer gpa.free(out);
    for (arr.items, 0..) |item, i| {
        out[i] = switch (item) {
            .string => |s| s,
            else => {
                std.debug.print("{s}: `{s}.{s}` holds a non-string\n", .{ ctx, key, leaf });
                gpa.free(out);
                return error.TestUnexpectedResult;
            },
        };
    }
    return out;
}

// The persistence + live-reload path that `add_mcp_server` reuses.
test "add_mcp_server_persists_stdio_server_via_put_round_trip" {
    try harness.requirePabrikBin(io, gpa);

    // Python `_mcp_hello_world_bin_or_skip`: the binary is produced by
    // `zig build mcp-hello-world` alongside `zig build`, and CI runs that
    // chain. Skip (not fail) when it is absent, exactly as Python did.
    const binary = harness.mcpHelloWorldBin(io, gpa) catch |err| switch (err) {
        error.BinaryNotFound => {
            std.debug.print(
                "mcp-hello-world binary not built; run `zig build mcp-hello-world` first.\n",
                .{},
            );
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer gpa.free(binary);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // 1. Read the existing config so we can preserve the stub profile.
    var initial_resp = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer initial_resp.deinit();
    var initial = try parseDoc(initial_resp.body);
    defer initial.deinit();

    // 2. PUT a config with a stdio MCP server — exactly the shape the
    // agent tool emits internally. The write succeeds even though the
    // LLM is a stub because the config endpoint never calls the LLM.
    try upsertMcpServer(&initial, "hello_world", .{
        .command = binary,
        .args = &.{"--flag"},
        .cwd = "/tmp",
    });

    const put1 = try std.json.Stringify.valueAlloc(gpa, initial.value, .{});
    defer gpa.free(put1);
    {
        var put_resp = try h.http(io, .PUT, "/api/config/pabrik", .{
            .json_body = put1,
            .expect = &.{200},
        });
        defer put_resp.deinit();
    }

    // 3. GET back — proves the live-reload picked up the new entry.
    var got_resp = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer got_resp.deinit();
    var got = try parseDoc(got_resp.body);
    defer got.deinit();

    const live_obj = switch (got.value) {
        .object => |o| o,
        else => {
            std.debug.print("GET config is not an object: {s}\n", .{got_resp.body});
            return error.TestUnexpectedResult;
        },
    };
    // Python: `servers = got.get("mcp_servers") or {}` then `assert
    // "hello_world" in servers`.
    const live_servers_val = live_obj.get("mcp_servers") orelse {
        std.debug.print("live config has no `mcp_servers`: {s}\n", .{got_resp.body});
        return error.TestUnexpectedResult;
    };
    const live_servers = switch (live_servers_val) {
        .object => |o| o,
        else => {
            std.debug.print("live `mcp_servers` is not an object: {s}\n", .{got_resp.body});
            return error.TestUnexpectedResult;
        },
    };
    if (live_servers.get("hello_world") == null) {
        std.debug.print("stdio MCP server missing from live config after PUT: {s}\n", .{got_resp.body});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings(binary, try nestedStr(live_servers, "hello_world", "command", "live config"));

    const live_args = try nestedStrArray(live_servers, "hello_world", "args", "live config");
    defer gpa.free(live_args);
    try testing.expectEqual(@as(usize, 1), live_args.len);
    try testing.expectEqualStrings("--flag", live_args[0]);

    try testing.expectEqualStrings("/tmp", try nestedStr(live_servers, "hello_world", "cwd", "live config"));

    // 4. Verify the on-disk file matches — this is the bit that proves the
    // disk-write half of the persistence helper ran.
    const cfg_dir = try platformConfigDir(h.temp_dir);
    defer gpa.free(cfg_dir);
    const cfg_path = try std.fs.path.join(gpa, &.{ cfg_dir, "config.json" });
    defer gpa.free(cfg_path);

    const on_disk_raw = try std.Io.Dir.cwd().readFileAlloc(io, cfg_path, gpa, .limited(1 << 20));
    defer gpa.free(on_disk_raw);
    var on_disk = try std.json.parseFromSlice(std.json.Value, gpa, on_disk_raw, .{});
    defer on_disk.deinit();

    const disk_obj = switch (on_disk.value) {
        .object => |o| o,
        else => {
            std.debug.print("on-disk config.json is not an object\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    const disk_servers_val = disk_obj.get("mcp_servers") orelse {
        std.debug.print("on-disk config has no `mcp_servers`\n", .{});
        return error.TestUnexpectedResult;
    };
    const disk_servers = switch (disk_servers_val) {
        .object => |o| o,
        else => {
            std.debug.print("on-disk `mcp_servers` is not an object\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    if (disk_servers.get("hello_world") == null) {
        std.debug.print("stdio MCP server missing from on-disk config\n", .{});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings(binary, try nestedStr(disk_servers, "hello_world", "command", "on-disk config"));

    const disk_args = try nestedStrArray(disk_servers, "hello_world", "args", "on-disk config");
    defer gpa.free(disk_args);
    try testing.expectEqual(@as(usize, 1), disk_args.len);
    try testing.expectEqualStrings("--flag", disk_args[0]);

    try testing.expectEqualStrings("/tmp", try nestedStr(disk_servers, "hello_world", "cwd", "on-disk config"));

    // The stub profile (preserved by the PUT handler) is still there —
    // proves the write didn't clobber sibling fields.
    if (disk_obj.get("profiles_models") == null) {
        std.debug.print("profiles_models missing from on-disk config after PUT\n", .{});
        return error.TestUnexpectedResult;
    }

    // 5.
    try upsertMcpServer(&got, "second_server", .{
        .command = binary,
        .args = &.{ "--name", "second" },
    });

    const put2 = try std.json.Stringify.valueAlloc(gpa, got.value, .{});
    defer gpa.free(put2);
    {
        var put_resp = try h.http(io, .PUT, "/api/config/pabrik", .{
            .json_body = put2,
            .expect = &.{200},
        });
        defer put_resp.deinit();
    }

    var got2_resp = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer got2_resp.deinit();
    var got2 = try parseDoc(got2_resp.body);
    defer got2.deinit();

    const obj2 = switch (got2.value) {
        .object => |o| o,
        else => {
            std.debug.print("second GET config is not an object: {s}\n", .{got2_resp.body});
            return error.TestUnexpectedResult;
        },
    };
    const servers2_val = obj2.get("mcp_servers") orelse {
        std.debug.print("live config lost `mcp_servers` on the second PUT\n", .{});
        return error.TestUnexpectedResult;
    };
    const servers2 = switch (servers2_val) {
        .object => |o| o,
        else => {
            std.debug.print("live `mcp_servers` is not an object after the second PUT\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    if (servers2.get("hello_world") == null) {
        std.debug.print("first stdio server dropped when adding a second\n", .{});
        return error.TestUnexpectedResult;
    }
    if (servers2.get("second_server") == null) {
        std.debug.print("second stdio server missing after the second PUT\n", .{});
        return error.TestUnexpectedResult;
    }
}

// Functional toggle test for the MCP server `enabled` flag (Task 5). Zig port
// of `tests/functional/mcp_server_toggle_test.py` (same test names, same
// order).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// An owned `mcp_servers` block for a PUT body. WHY A STRUCT AND NOT A LOCAL
/// MAP: `ObjectMap.put` stores the value BY VALUE, and a `Value.object` copy
/// shares the inner map's backing array.
const McpServers = struct {
    outer: std.json.ObjectMap,
    entries: std.ArrayList(std.json.ObjectMap) = .empty,

    fn init() McpServers {
        return .{ .outer = .{} };
    }

    fn deinit(self: *McpServers) void {
        for (self.entries.items) |*e| e.deinit(gpa);
        self.entries.deinit(gpa);
        self.outer.deinit(gpa);
    }

    /// Add one stdio server. `enabled = null` OMITS the key — which is
    /// exactly what the frontend serializer sends for an enabled server,
    /// and what the backend reads back as "enabled".
    fn put(self: *McpServers, name: []const u8, command: []const u8, enabled: ?bool) !void {
        // No `errdefer entry.deinit()`: on any failure below the (partial)
        // map is simply leaked, which reports as a leak on an already-failing
        // test.
        var entry: std.json.ObjectMap = .{};
        try entry.put(gpa, "command", .{ .string = command });
        if (enabled) |e| try entry.put(gpa, "enabled", .{ .bool = e });
        try self.entries.append(gpa, entry);
        try self.outer.put(gpa, name, .{ .object = entry });
    }

    fn value(self: *const McpServers) std.json.Value {
        return .{ .object = self.outer };
    }
};

/// `GET /api/config/pabrik`, re-parsed into an OWNED `std.json.Parsed` the
/// caller can MUTATE and re-serialize.
fn fetchConfig(h: *Harness) !std.json.Parsed(std.json.Value) {
    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    return std.json.parseFromSlice(std.json.Value, gpa, r.body, .{});
}

/// `PUT /api/config/pabrik` with a whole config document as the body.
fn putConfig(h: *Harness, cfg: *const std.json.Parsed(std.json.Value)) !void {
    const body = try std.json.Stringify.valueAlloc(gpa, cfg.value, .{});
    defer gpa.free(body);
    var r = try h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = &.{200} });
    r.deinit();
}

/// Mirror `LlmConfig.getDefaultConfigDir` (Config.zig) per-OS layout. The
/// Python helper had a Windows branch that consulted `$APPDATA` when it
/// pointed inside the harness HOME.
fn platformConfigDir(home: []const u8) ![]u8 {
    return switch (builtin.os.tag) {
        .macos => harness.harnessPath(gpa, home, &.{ "Library", "Application Support", "pabrik" }),
        .windows => harness.harnessPath(gpa, home, &.{ "AppData", "Roaming", "pabrik" }),
        else => harness.harnessPath(gpa, home, &.{ ".config", "pabrik" }),
    };
}

/// The `mcp_servers` object of a parsed config, or an error.
fn serversOf(doc: *const harness.Json) !std.json.ObjectMap {
    return doc.object("mcp_servers") orelse {
        std.debug.print("config has no `mcp_servers` block: {s}\n", .{""});
        return error.TestUnexpectedResult;
    };
}

/// The `mcp_servers.<name>` object, or an error.
fn serverEntry(servers: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    const entry = servers.get(name) orelse {
        std.debug.print("server `{s}` missing after PUT (have {d} entries)\n", .{ name, servers.count() });
        return error.TestUnexpectedResult;
    };
    return switch (entry) {
        .object => |o| o,
        else => {
            std.debug.print("mcp_servers.{s} is not an object\n", .{name});
            return error.TestUnexpectedResult;
        },
    };
}

/// The `command` of `mcp_servers.<name>`, or null.
fn serverCommand(servers: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const entry = serverEntry(servers, name) catch return null;
    const cmd = entry.get("command") orelse return null;
    return switch (cmd) {
        .string => |s| s,
        else => null,
    };
}

/// The `enabled` flag of `mcp_servers.<name>`, or null.
fn serverEnabled(servers: std.json.ObjectMap, name: []const u8) ?bool {
    const entry = serverEntry(servers, name) catch return null;
    const flag = entry.get("enabled") orelse return null;
    return switch (flag) {
        .bool => |b| b,
        else => null,
    };
}

/// Assert the flag is neither absent nor explicitly `false`, i.e. the
/// server is ENABLED (Python: `in (None, True)`).
fn expectEnabled(servers: std.json.ObjectMap, name: []const u8, ctx: []const u8) !void {
    const flag = serverEnabled(servers, name);
    if (flag != null and flag.? == false) {
        std.debug.print(
            "{s}: `mcp_servers.{s}` is explicitly enabled:false — the server " ++
                "would stay excluded from enumeration\n",
            .{ ctx, name },
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// tests
// ============================================================================

// PUT disabled stdio server -> GET returns enabled:false (wire + disk).
test "disabled_stdio_server_round_trips_enabled_false" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    {
        var cfg = try fetchConfig(&h);
        defer cfg.deinit();
        var servers = McpServers.init();
        defer servers.deinit();
        // EXACT frontend serializer shape for a disabled stdio server:
        // {command, ...} + enabled:false only when disabled. `/bin/true`
        // is inert because we assert exclusion, never tool output.
        try servers.put("toggled_off", "/bin/true", false);
        switch (cfg.value) {
            .object => |*o| try o.put(gpa, "mcp_servers", servers.value()),
            else => {
                std.debug.print("GET /api/config/pabrik did not return a JSON object\n", .{});
                return error.TestUnexpectedResult;
            },
        }
        try putConfig(&h, &cfg);
    }

    {
        var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        const got = try serversOf(&doc);
        const cmd = serverCommand(got, "toggled_off");
        if (cmd == null or !std.mem.eql(u8, cmd.?, "/bin/true")) {
            std.debug.print("command lost: expected /bin/true, got {?s}\n", .{cmd});
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(false, serverEnabled(got, "toggled_off") orelse {
            std.debug.print(
                "expected enabled:false to round-trip; the key is absent " ++
                    "(absent parses as ENABLED — a disabled server would be enumerated)\n",
                .{},
            );
            return error.TestUnexpectedResult;
        });
    }

    // On-disk shape matches (proves the generic json.Value deep-copy in
    // PUT preserved `enabled` through the disk write).
    const dir = try platformConfigDir(h.temp_dir);
    defer gpa.free(dir);
    const cfg_path = try std.fs.path.join(gpa, &.{ dir, "config.json" });
    defer gpa.free(cfg_path);

    std.Io.Dir.cwd().access(io, cfg_path, .{}) catch {
        std.debug.print("config.json not written at {s}\n", .{cfg_path});
        return error.TestUnexpectedResult;
    };
    const raw = std.Io.Dir.cwd().readFileAlloc(io, cfg_path, gpa, .limited(1 << 20)) catch |err| {
        std.debug.print("could not read {s}: {s}\n", .{ cfg_path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer gpa.free(raw);

    var on_disk = harness.Json{ .parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch |err| {
        std.debug.print("config.json at {s} is not JSON: {s}\n", .{ cfg_path, @errorName(err) });
        return error.TestUnexpectedResult;
    } };
    defer on_disk.deinit();

    const disk_servers = try serversOf(&on_disk);
    try testing.expectEqual(false, serverEnabled(disk_servers, "toggled_off") orelse {
        std.debug.print("on-disk enabled flag lost for `toggled_off`\n", .{});
        return error.TestUnexpectedResult;
    });
}

// Disabled -> enabled flip (omit key) -> GET shows absent (== enabled).
test "flip_disabled_to_enabled_omits_key" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    // 1. Disable.
    {
        var cfg = try fetchConfig(&h);
        defer cfg.deinit();
        var servers = McpServers.init();
        defer servers.deinit();
        try servers.put("flip", "/bin/true", false);
        switch (cfg.value) {
            .object => |*o| try o.put(gpa, "mcp_servers", servers.value()),
            else => return error.TestUnexpectedResult,
        }
        try putConfig(&h, &cfg);
    }
    {
        var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const got = try serversOf(&doc);
        try testing.expectEqual(false, serverEnabled(got, "flip") orelse {
            std.debug.print("the disable PUT did not land: `flip` is not enabled:false\n", .{});
            return error.TestUnexpectedResult;
        });
    }

    // 2. Re-enable with the EXACT frontend shape (omit `enabled`).
    {
        var cfg = try fetchConfig(&h);
        defer cfg.deinit();
        var servers = McpServers.init();
        defer servers.deinit();
        try servers.put("flip", "/bin/true", null);
        switch (cfg.value) {
            .object => |*o| try o.put(gpa, "mcp_servers", servers.value()),
            else => return error.TestUnexpectedResult,
        }
        try putConfig(&h, &cfg);
    }

    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const got = try serversOf(&doc);
    // `server dropped by enable-flip PUT`
    _ = try serverEntry(got, "flip");
    const cmd = serverCommand(got, "flip");
    if (cmd == null or !std.mem.eql(u8, cmd.?, "/bin/true")) {
        std.debug.print("command lost on the enable flip: {?s}\n", .{cmd});
        return error.TestUnexpectedResult;
    }
    // Omit-when-true: enabled servers serialize WITHOUT the key (absent
    // parses as enabled -> server is enumerated again).
    try expectEnabled(got, "flip", "after the enable flip");
}

// Disabled + enabled siblings coexist; explicit true parses as enabled.
test "disabled_sibling_preserved_and_explicit_true_tolerated" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    // First PUT: one explicitly disabled, one explicitly enabled.
    {
        var cfg = try fetchConfig(&h);
        defer cfg.deinit();
        var servers = McpServers.init();
        defer servers.deinit();
        try servers.put("off", "/bin/true", false);
        try servers.put("on", "/bin/true", true);
        switch (cfg.value) {
            .object => |*o| try o.put(gpa, "mcp_servers", servers.value()),
            else => return error.TestUnexpectedResult,
        }
        try putConfig(&h, &cfg);
    }

    {
        var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const got = try serversOf(&doc);

        if (got.count() != 2 or got.get("off") == null or got.get("on") == null) {
            std.debug.print("sibling servers not preserved: {d} entries\n", .{got.count()});
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(false, serverEnabled(got, "off") orelse return error.TestUnexpectedResult);
        // Explicit true must NOT disable (backend: only `.bool false`
        // disables; missing/non-bool/true all mean enabled).
        try expectEnabled(got, "on", "explicit true");
    }

    // Toggle only "off" -> "on" must not clobber the sibling.
    {
        var cfg = try fetchConfig(&h);
        defer cfg.deinit();
        var servers = McpServers.init();
        defer servers.deinit();
        try servers.put("off", "/bin/true", null);
        try servers.put("on", "/bin/true", true);
        switch (cfg.value) {
            .object => |*o| try o.put(gpa, "mcp_servers", servers.value()),
            else => return error.TestUnexpectedResult,
        }
        try putConfig(&h, &cfg);
    }

    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const got = try serversOf(&doc);
    if (got.count() != 2 or got.get("off") == null or got.get("on") == null) {
        std.debug.print("sibling dropped by the toggle PUT: {d} entries\n", .{got.count()});
        return error.TestUnexpectedResult;
    }
    try expectEnabled(got, "off", "after toggling `off` on");
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = McpServers.init;
    _ = McpServers.deinit;
    _ = McpServers.put;
    _ = McpServers.value;
    _ = fetchConfig;
    _ = putConfig;
    _ = platformConfigDir;
    _ = serversOf;
    _ = serverEntry;
    _ = serverCommand;
    _ = serverEnabled;
    _ = expectEnabled;
}

// Functional tests for `search_tool`'s regex + paging contract. Zig port of
// `tests/functional/progressive_tool_search_regex_test.py` (same test names,
// same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

const REGISTRY_ROUTE = "/api/agent-tools/registry";

/// The three progressive meta-tools that must always be listed — they
/// are ordinary tools as far as the registry is concerned.
const REQUIRED_META_TOOLS = [_][]const u8{ "search_tool", "view_tool", "use_tool" };

// ============================================================================
// Helpers
// ============================================================================

/// `GET /api/agent-tools/registry` indexed by name.
const Registry = struct {
    resp: harness.Response,
    doc: harness.Json,
    by_name: std.StringArrayHashMapUnmanaged([]const u8),

    fn load(h: *Harness) !Registry {
        var resp = try h.http(io, .GET, REGISTRY_ROUTE, .{ .expect = &.{200} });
        errdefer resp.deinit();
        var doc = try resp.json();
        errdefer doc.deinit();

        var by_name: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        errdefer by_name.deinit(gpa);

        const tools = doc.array("tools") orelse {
            std.debug.print("registry response has no `tools` array: {s}\n", .{resp.body});
            return error.TestUnexpectedResult;
        };
        if (tools.items.len == 0) {
            std.debug.print("empty registry: {s}\n", .{resp.body});
            return error.TestUnexpectedResult;
        }

        for (tools.items) |entry| {
            const obj = switch (entry) {
                .object => |o| o,
                else => {
                    std.debug.print("registry entry is not an object: {s}\n", .{resp.body});
                    return error.TestUnexpectedResult;
                },
            };
            const name = switch (obj.get("name") orelse {
                std.debug.print("registry entry missing 'name': {s}\n", .{resp.body});
                return error.TestUnexpectedResult;
            }) {
                .string => |s| s,
                else => {
                    std.debug.print("registry entry 'name' is not a string\n", .{});
                    return error.TestUnexpectedResult;
                },
            };
            const desc = switch (obj.get("description") orelse {
                std.debug.print("registry entry {s} missing 'description'\n", .{name});
                return error.TestUnexpectedResult;
            }) {
                .string => |s| s,
                else => {
                    std.debug.print("registry entry {s} 'description' is not a string\n", .{name});
                    return error.TestUnexpectedResult;
                },
            };
            try by_name.put(gpa, name, desc);
        }

        return .{ .resp = resp, .doc = doc, .by_name = by_name };
    }

    fn deinit(self: *Registry) void {
        // Map FIRST: its keys/values point into the parse arena below.
        self.by_name.deinit(gpa);
        self.doc.deinit();
        self.resp.deinit();
    }

    fn description(self: *const Registry, name: []const u8) ?[]const u8 {
        return self.by_name.get(name);
    }

    fn sortedNames(self: *const Registry) ![]const []const u8 {
        const names = try gpa.alloc([]const u8, self.by_name.count());
        errdefer gpa.free(names);
        var it = self.by_name.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) names[i] = kv.key_ptr.*;
        std.mem.sort([]const u8, names, {}, strLessThan);
        return names;
    }
};

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The description for `name`, failing with the registry's sorted name
/// list if the tool is absent.
fn requireDescription(reg: *const Registry, name: []const u8) ![]const u8 {
    if (reg.description(name)) |d| return d;
    const names = reg.sortedNames() catch return error.TestUnexpectedResult;
    defer gpa.free(names);
    std.debug.print("{s} missing from registry: [", .{name});
    for (names, 0..) |n, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{n});
    }
    std.debug.print("]\n", .{});
    return error.TestUnexpectedResult;
}

/// `needle` must occur in `desc`. Prints the whole description on
/// failure — a substring assertion is unreadable without it.
fn expectCarries(desc: []const u8, tool: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, desc, needle) != null) return;
    std.debug.print(
        "`{s}` description does not carry {s}:\n--- description ---\n{s}\n--- end ---\n",
        .{ tool, (harness.debugString(gpa, needle) catch "?"), desc },
    );
    return error.TestUnexpectedResult;
}

/// The wire `tools[].name` list, in wire order — the Python `names =
/// [t["name"] for t in parsed["tools"]]`. Owned: each name is duped out of
/// the parse arena so the caller can compare/print it after `doc.deinit()`.
fn ownedNames(doc: *const harness.Json) ![][]const u8 {
    const tools = doc.array("tools") orelse return error.TestUnexpectedResult;
    const names = try gpa.alloc([]const u8, tools.items.len);
    errdefer gpa.free(names);
    for (tools.items, 0..) |entry, i| {
        const obj = switch (entry) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const name = switch (obj.get("name") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        names[i] = try gpa.dupe(u8, name);
    }
    return names;
}

fn freeNames(names: [][]const u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

fn namesContain(names: []const []const u8, needle: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, needle)) return true;
    }
    return false;
}

/// ASCII whitespace, matching Python's `str.strip()` closely enough for
/// hand-written tool descriptions.
const ASCII_WS = " \t\n\r\x0b\x0c";

// ============================================================================
// Tests
// ============================================================================

// The model-facing description must say WHAT (regex, literal) and WHY.
test "search_tool_description_teaches_regex_with_a_reason" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var reg = try Registry.load(&h);
    defer reg.deinit();

    const desc = try requireDescription(&reg, "search_tool");

    // WHAT: regex by default, with the literal escape hatch.
    try expectCarries(desc, "search_tool", "REGEX");
    try expectCarries(desc, "search_tool", "case-insensitive");
    try expectCarries(desc, "search_tool", "literal: true");
    try expectCarries(desc, "search_tool", "view_tool"); // the existing workflow hint must survive

    // WHY: concrete patterns, one per reason the substring form cannot
    // serve.
    try expectCarries(desc, "search_tool", "^mcp_.*_create"); // the anchored/wildcard example is gone
    try expectCarries(desc, "search_tool", "doc|documentation"); // the alternation example is gone
    // The word-boundary example.
    try expectCarries(desc, "search_tool", "\\bsearch\\b"); // the word-boundary example is gone
    // The reason itself, in words — the registry carries the tool-level
    // description (the `query` PARAM description is not exposed by any HTTP
    // route, so its wording is locked by the inline schema tests instead).
    try expectCarries(desc, "search_tool", "one pattern reaches a capability spelled several ways");
}

// A catalog full of MCP tools must not be dumped into the context window.
test "search_tool_description_documents_paging_for_big_catalogs" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var reg = try Registry.load(&h);
    defer reg.deinit();

    const desc = try requireDescription(&reg, "search_tool");

    try expectCarries(desc, "search_tool", "PAGED");
    try expectCarries(desc, "search_tool", "limit");
    try expectCarries(desc, "search_tool", "offset");
    try expectCarries(desc, "search_tool", "total"); // the true count is what makes paging navigable
}

// Guard the envelope shape the frontend/LLM consume.
test "registry_payload_is_json_clean_and_search_tool_stayed_in_it" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, REGISTRY_ROUTE, .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const names = try ownedNames(&doc);
    defer freeNames(names);

    // `names == sorted(names) or "search_tool" in names`.
    var sorted_asc = true;
    for (names, 0..) |n, i| {
        if (i == 0) continue;
        if (std.mem.order(u8, names[i - 1], n) != .lt) sorted_asc = false;
    }
    if (!sorted_asc and !namesContain(names, "search_tool")) {
        std.debug.print(
            "registry names are neither sorted nor do they contain search_tool: ",
            .{},
        );
        for (names, 0..) |n, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{n});
        }
        std.debug.print("\n", .{});
        return error.TestUnexpectedResult;
    }

    // `{"search_tool", "view_tool", "use_tool"}.issubset(set(names))`.
    for (REQUIRED_META_TOOLS) |required| {
        if (namesContain(names, required)) continue;
        std.debug.print("registry is missing the progressive meta-tool `{s}`\n", .{required});
        return error.TestUnexpectedResult;
    }

    // No raw control bytes smuggled into the JSON string fields.
    const tools = doc.array("tools") orelse return error.TestUnexpectedResult;
    for (tools.items) |entry| {
        const obj = switch (entry) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const name = switch (obj.get("name") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        const desc = switch (obj.get("description") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };

        // `t["description"].strip() == t["description"]` — a leading or
        // trailing blank is the fingerprint of a `\` continued line in
        // the hand-written description that swallowed its indent.
        const trimmed = std.mem.trim(u8, desc, ASCII_WS);
        if (!std.mem.eql(u8, trimmed, desc)) {
            std.debug.print(
                "description of {s} has leading/trailing whitespace: {s}\n",
                .{ (harness.debugString(gpa, name) catch "?"), (harness.debugString(gpa, desc) catch "?") },
            );
            return error.TestUnexpectedResult;
        }

        // `"\x08" not in t["description"]` — a stray backspace, which
        // a JSON round-trip would happily decode back out of a `\b`
        // that was meant to be a literal `\b` in a regex example.
        if (std.mem.indexOfScalar(u8, desc, 0x08) != null) {
            std.debug.print(
                "stray backspace in {s} description\n",
                .{(harness.debugString(gpa, name) catch "?")},
            );
            return error.TestUnexpectedResult;
        }
    }
}

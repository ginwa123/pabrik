//! The per-workspace config OVERLAY: how a workspace's `workspace_settings`
//! row is combined with the user-level config.
//!
//! ## Why this is a JSON-text merge and not a struct merge
//!
//! `LlmConfig` owns heap strings and maps, so overlaying two of them would
//! mean writing a deep-clone-with-override for every field, in step with
//! `Config.zig`'s parser forever. Merging the two JSON documents BEFORE
//! parsing reuses `LlmConfig.initFromJsonText` unchanged, so an overlay and a
//! `config.json` with identical bytes keep producing identical configs - the
//! same guarantee `session_llm_config.zig` relies on.
//!
//! ## The merge rule (ONE rule, stated once)
//!
//!   * OBJECT over OBJECT -> recurse (deep merge).
//!   * Everything else    -> the overlay REPLACES the base value.
//!
//! Two consequences worth naming, because both are load-bearing:
//!
//!   * `profiles` is an object, so overriding one profile's `model` keeps
//!     that profile's `api_key`, and keeps every OTHER profile. "Last write
//!     wins" would silently drop the credentials of every profile the
//!     workspace did not mention.
//!   * `tools` is an ARRAY, so a workspace's tool list REPLACES the user's
//!     list rather than unioning with it. Union would make it impossible to
//!     NARROW the tools in one workspace, which is the main reason to set
//!     them there at all.
//!
//! ## Degrading, never failing a turn
//!
//! A malformed base or overlay returns the BASE unchanged rather than an
//! error. This runs on the chat path, and a corrupt overlay must not be able
//! to break a chat - the worst acceptable outcome is "this workspace still
//! behaves like the user config".

const std = @import("std");

/// Merge `overlay_json` over `base_json`, returning a newly allocated JSON
/// object text.
///
/// An empty or `{}` overlay, an unparseable overlay, or an overlay that is
/// not a JSON object all return a copy of the base - see the module header.
/// The caller owns the returned slice.
pub fn overlayJson(
    allocator: std.mem.Allocator,
    base_json: []const u8,
    overlay_json: []const u8,
) ![]u8 {
    const base_text = if (std.mem.trim(u8, base_json, " \t\r\n").len == 0)
        "{}"
    else
        base_json;

    const overlay_text = std.mem.trim(u8, overlay_json, " \t\r\n");
    if (overlay_text.len == 0 or std.mem.eql(u8, overlay_text, "{}")) {
        return allocator.dupe(u8, base_text);
    }

    const base_parsed = std.json.parseFromSlice(std.json.Value, allocator, base_text, .{}) catch
        return allocator.dupe(u8, base_text);
    defer base_parsed.deinit();
    const overlay_parsed = std.json.parseFromSlice(std.json.Value, allocator, overlay_text, .{}) catch
        return allocator.dupe(u8, base_text);
    defer overlay_parsed.deinit();

    const base_obj = switch (base_parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, base_text),
    };
    const overlay_obj = switch (overlay_parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, base_text),
    };
    if (overlay_obj.count() == 0) return allocator.dupe(u8, base_text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendMergedObject(allocator, &out, base_obj, overlay_obj);
    return out.toOwnedSlice(allocator);
}

/// The explicit error set of the `appendMergedObject`/`appendMergedValue`
/// pair. It has to be spelled out: the two functions recurse into each other,
/// and two mutually recursive functions that both infer their error set are a
/// compile-time "dependency loop with length 2". `OutOfMemory` is the whole
/// set - every call underneath is an allocator call.
const AppendError = error{OutOfMemory};

/// Write `{ base keys (overlay-merged where present) , overlay-only keys }`.
///
/// Base key ORDER is preserved and overlay-only keys are appended, so the
/// output is deterministic for a given pair of inputs - a diff of two runs
/// shows real changes instead of hash-map shuffle.
fn appendMergedObject(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    base: std.json.ObjectMap,
    overlay: std.json.ObjectMap,
) AppendError!void {
    try out.append(allocator, '{');
    var first = true;

    var base_it = base.iterator();
    while (base_it.next()) |entry| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try appendKeyJson(allocator, out, entry.key_ptr.*);
        try out.append(allocator, ':');
        if (overlay.get(entry.key_ptr.*)) |override| {
            try appendMergedValue(allocator, out, entry.value_ptr.*, override);
        } else {
            try appendValueJson(allocator, out, entry.value_ptr.*);
        }
    }

    var overlay_it = overlay.iterator();
    while (overlay_it.next()) |entry| {
        // Already emitted above, in the base's position.
        if (base.contains(entry.key_ptr.*)) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try appendKeyJson(allocator, out, entry.key_ptr.*);
        try out.append(allocator, ':');
        try appendValueJson(allocator, out, entry.value_ptr.*);
    }

    try out.append(allocator, '}');
}

/// One value under the merge rule: objects merge, everything else is replaced.
fn appendMergedValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    base: std.json.Value,
    overlay: std.json.Value,
) AppendError!void {
    switch (base) {
        .object => |base_obj| switch (overlay) {
            .object => |overlay_obj| {
                return appendMergedObject(allocator, out, base_obj, overlay_obj);
            },
            else => {},
        },
        else => {},
    }
    try appendValueJson(allocator, out, overlay);
}

fn appendValueJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: std.json.Value,
) AppendError!void {
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

/// An object KEY needs the same escaping a string value does - a profile
/// named `my "prod" key` must not be able to produce invalid JSON.
fn appendKeyJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
) AppendError!void {
    try appendValueJson(allocator, out, .{ .string = key });
}

// =====================================================================
// Tests
// =====================================================================
//
// Every assertion re-PARSES the merged text and reads a value out of it,
// rather than comparing bytes to a hand-written expected string: the property
// under test is "the merged config says X", and a byte comparison would also
// fail on harmless key-order changes, which is not what this module promises.
// The two exceptions are the "no change" cases, where byte identity IS the
// promise (an untouched workspace must not churn the config text).

const testing = std.testing;

const Parsed = std.json.Parsed(std.json.Value);

fn parse(allocator: std.mem.Allocator, text: []const u8) !Parsed {
    return std.json.parseFromSlice(std.json.Value, allocator, text, .{});
}

test "a scalar in the overlay wins and everything else survives" {
    const alloc = testing.allocator;
    const base = "{\"retry_delay_ms\":2000,\"notify_on_complete\":false}";
    const merged = try overlayJson(alloc, base, "{\"retry_delay_ms\":500}");
    defer alloc.free(merged);

    var parsed = try parse(alloc, merged);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 500), obj.get("retry_delay_ms").?.integer);
    // Absent from the overlay -> the user's value is what a run sees.
    try testing.expectEqual(false, obj.get("notify_on_complete").?.bool);
}

test "an array is REPLACED, so a workspace can narrow the tool list" {
    const alloc = testing.allocator;
    const base = "{\"tools\":[\"read_file\",\"write_file\",\"bash\"]}";
    const merged = try overlayJson(alloc, base, "{\"tools\":[\"read_file\"]}");
    defer alloc.free(merged);

    var parsed = try parse(alloc, merged);
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array;
    // The positive control: the base list really had three entries, so a
    // length of 1 below is a replacement and not a no-op on an empty base.
    try testing.expectEqual(@as(usize, 1), tools.items.len);
    try testing.expectEqualStrings("read_file", tools.items[0].string);
}

test "objects DEEP-merge, so overriding one profile field keeps its api_key" {
    const alloc = testing.allocator;
    const base =
        "{\"active_profile\":\"claude\"," ++
        "\"profiles\":{\"claude\":{\"model\":\"opus\",\"api_key\":\"sk-secret\"}," ++
        "\"other\":{\"model\":\"gpt-4o\"}}}";
    const merged = try overlayJson(alloc, base, "{\"profiles\":{\"claude\":{\"model\":\"sonnet\"}}}");
    defer alloc.free(merged);

    var parsed = try parse(alloc, merged);
    defer parsed.deinit();
    const obj = parsed.value.object;

    const claude = obj.get("profiles").?.object.get("claude").?.object;
    try testing.expectEqualStrings("sonnet", claude.get("model").?.string);
    // The credential the workspace never mentioned. "Last write wins" would
    // have dropped it and broken every run in this workspace.
    try testing.expectEqualStrings("sk-secret", claude.get("api_key").?.string);
    // A profile the overlay never mentioned at all.
    try testing.expectEqualStrings("gpt-4o", obj.get("profiles").?.object.get("other").?.object.get("model").?.string);
    // A top-level key the overlay never mentioned.
    try testing.expectEqualStrings("claude", obj.get("active_profile").?.string);
}

test "a key that exists only in the overlay is added" {
    const alloc = testing.allocator;
    const merged = try overlayJson(alloc, "{\"retry_delay_ms\":2000}", "{\"active_profile\":\"claude\"}");
    defer alloc.free(merged);

    var parsed = try parse(alloc, merged);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("claude", obj.get("active_profile").?.string);
    try testing.expectEqual(@as(i64, 2000), obj.get("retry_delay_ms").?.integer);
}

test "an empty or `{}` overlay returns the base byte-for-byte" {
    const alloc = testing.allocator;
    const base = "{\"a\":1,\"b\":{\"c\":2}}";

    const from_empty = try overlayJson(alloc, base, "");
    defer alloc.free(from_empty);
    try testing.expectEqualStrings(base, from_empty);

    const from_braces = try overlayJson(alloc, base, "  {}  ");
    defer alloc.free(from_braces);
    try testing.expectEqualStrings(base, from_braces);

    const from_whitespace = try overlayJson(alloc, base, "\n\t ");
    defer alloc.free(from_whitespace);
    try testing.expectEqualStrings(base, from_whitespace);
}

test "a malformed overlay degrades to the base instead of breaking the turn" {
    const alloc = testing.allocator;
    const base = "{\"retry_delay_ms\":2000}";

    const merged = try overlayJson(alloc, base, "{\"retry_delay_ms\": ");
    defer alloc.free(merged);
    try testing.expectEqualStrings(base, merged);

    // A non-object overlay is equally unusable: there are no keys to merge in.
    const array_overlay = try overlayJson(alloc, base, "[1,2,3]");
    defer alloc.free(array_overlay);
    try testing.expectEqualStrings(base, array_overlay);

    const scalar_overlay = try overlayJson(alloc, base, "\"nope\"");
    defer alloc.free(scalar_overlay);
    try testing.expectEqualStrings(base, scalar_overlay);
}

test "an empty base is treated as an empty object, so the overlay still applies" {
    const alloc = testing.allocator;
    const merged = try overlayJson(alloc, "", "{\"active_profile\":\"claude\"}");
    defer alloc.free(merged);

    var parsed = try parse(alloc, merged);
    defer parsed.deinit();
    try testing.expectEqualStrings("claude", parsed.value.object.get("active_profile").?.string);
}

test "a malformed BASE degrades to the malformed text rather than to invalid JSON" {
    const alloc = testing.allocator;
    // Nothing sensible can be merged into a broken base; handing the caller a
    // copy of what it passed is the only honest answer, and it keeps this
    // function's "never fails a turn" contract.
    const merged = try overlayJson(alloc, "{oops", "{\"active_profile\":\"claude\"}");
    defer alloc.free(merged);
    try testing.expectEqualStrings("{oops", merged);
}

test "keys needing JSON escaping survive the round trip" {
    const alloc = testing.allocator;
    // Profile names are user input, and a quote in one must not be able to
    // produce text that fails to parse.
    const merged = try overlayJson(alloc, "{}", "{\"a\\\"b\":1}");
    defer alloc.free(merged);

    var parsed = try parse(alloc, merged);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("a\"b").?.integer);
}

//! Workspace-secret placeholders: `{{SECRETS:NAME}}` in tool arguments, and
//! the redaction that keeps a resolved value out of a tool's own output. The
//! model writes `{{SECRETS:NAME}}` into any tool-call argument.

const std = @import("std");

/// One placeholder that was resolved, so the caller can redact it back out of
/// the tool's output.
pub const ResolvedSecret = struct { name: []const u8, value: []const u8 };

pub const SubstitutionResult = struct {
    /// Re-serialized arguments with every resolvable placeholder replaced.
    /// Owned by the caller's allocator.
    substituted_args: []const u8,
    /// One entry per distinct name that resolved; empty when nothing matched.
    /// Owned by the caller's allocator.
    resolved: []const ResolvedSecret,
};

/// Maps a name to its value, or null when the workspace has no such secret.
/// Injected as a function pointer so this file needs no database.
pub const Resolver = *const fn (ctx: ?*const anyopaque, name: []const u8) ?[]const u8;

pub const SubstError = error{ UnknownSecretName, InvalidArguments, OutOfMemory };

const placeholder_prefix = "{{SECRETS:";
const placeholder_suffix = "}}";
const max_name_len = 64;

/// Replace every resolvable `{{SECRETS:NAME}}` inside the JSON string leaves
/// of `args_json` and re-serialize the result.
pub fn substituteToolArguments(
    allocator: std.mem.Allocator,
    args_json: []const u8,
    resolver: Resolver,
    ctx: ?*const anyopaque,
    out: *SubstitutionResult,
) SubstError!void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArguments,
    };
    defer parsed.deinit();

    var resolved: std.ArrayList(ResolvedSecret) = .empty;
    errdefer {
        for (resolved.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        resolved.deinit(allocator);
    }

    // Replacement strings live in the parse arena: they only have to survive
    // until Stringify has copied them into the caller's buffer.
    try substituteTree(parsed.arena.allocator(), allocator, &parsed.value, resolver, ctx, &resolved);

    out.* = .{
        .substituted_args = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{}),
        .resolved = try resolved.toOwnedSlice(allocator),
    };
}

/// Put every value resolved by `substituteToolArguments` back behind its
/// placeholder before the tool's output is stored or streamed.
pub fn redactOutput(
    allocator: std.mem.Allocator,
    output: []const u8,
    resolved: []const ResolvedSecret,
) ![]u8 {
    if (resolved.len == 0) return allocator.dupe(u8, output);

    var out_buf: std.ArrayList(u8) = .empty;
    errdefer out_buf.deinit(allocator);

    var i: usize = 0;
    outer: while (i < output.len) {
        for (resolved) |secret| {
            // An empty value would match at every offset and loop forever.
            if (secret.value.len == 0) continue;
            const rest = output[i..];
            if (rest.len < secret.value.len) continue;
            if (!std.mem.startsWith(u8, rest, secret.value)) continue;

            try out_buf.appendSlice(allocator, placeholder_prefix);
            try out_buf.appendSlice(allocator, secret.name);
            try out_buf.appendSlice(allocator, placeholder_suffix);
            i += secret.value.len;
            continue :outer;
        }
        try out_buf.append(allocator, output[i]);
        i += 1;
    }
    return out_buf.toOwnedSlice(allocator);
}

/// What a placeholder whose name resolves to nothing becomes.
pub const MissPolicy = enum {
    /// Fail the whole substitution. A tool call that would run with a literal
    /// placeholder is worse than one that names the secret it could not find.
    fail,
    /// Keep the placeholder as literal text. A saved config may reference a
    /// secret that is added later, and refusing the document would hide every
    /// other field in it.
    keep_literal,
};

/// Replace inside every string leaf. Numbers, bools and nulls are left alone:
/// a placeholder can only ever be text.
fn substituteTree(
    arena: std.mem.Allocator,
    alloc: std.mem.Allocator,
    value: *std.json.Value,
    resolver: Resolver,
    ctx: ?*const anyopaque,
    resolved: ?*std.ArrayList(ResolvedSecret),
) SubstError!void {
    switch (value.*) {
        .string => |text| {
            if (std.mem.indexOf(u8, text, placeholder_prefix) == null) return;
            value.* = .{ .string = try substituteInString(arena, alloc, text, resolver, ctx, resolved, .fail) };
        },
        .object => |object| {
            for (object.values()) |*entry| try substituteTree(arena, alloc, entry, resolver, ctx, resolved);
        },
        .array => |array| {
            for (array.items) |*item| try substituteTree(arena, alloc, item, resolver, ctx, resolved);
        },
        else => {},
    }
}

/// Replace placeholders in the CREDENTIAL positions of a config: the agents'
/// `api_key`, and each MCP server's `headers` values and `env` entries. Other
/// fields are untouched; an unresolved name stays literal.
pub fn substituteConfigCredentials(
    allocator: std.mem.Allocator,
    config_json: []const u8,
    resolver: Resolver,
    ctx: ?*const anyopaque,
) SubstError![]u8 {
    if (std.mem.indexOf(u8, config_json, placeholder_prefix) == null) {
        return allocator.dupe(u8, config_json);
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A document nobody can parse has no credential position to find, and
        // the parse that consumes it refuses it anyway. Pass it through.
        else => return allocator.dupe(u8, config_json),
    };
    defer parsed.deinit();

    const changed = switch (parsed.value) {
        .object => try substituteCredentialFields(parsed.arena.allocator(), resolver, ctx, &parsed.value.object),
        else => false,
    };
    if (!changed) return allocator.dupe(u8, config_json);
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

/// Walk the credential positions of a config object. `true` when at least one
/// placeholder became a value.
fn substituteCredentialFields(
    arena: std.mem.Allocator,
    resolver: Resolver,
    ctx: ?*const anyopaque,
    root: *std.json.ObjectMap,
) SubstError!bool {
    var changed = false;

    for ([_][]const u8{ "profiles_models", "profiles" }) |key| {
        const profiles = root.getPtr(key) orelse continue;
        if (profiles.* != .object) continue;
        var it = profiles.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .object) continue;
            const api_key = entry.value_ptr.object.getPtr("api_key") orelse continue;
            if (try substituteCredentialLeaf(arena, api_key, resolver, ctx)) changed = true;
        }
    }

    const servers = root.getPtr("mcp_servers") orelse return changed;
    if (servers.* != .object) return changed;
    var servers_it = servers.object.iterator();
    while (servers_it.next()) |server| {
        if (server.value_ptr.* != .object) continue;
        if (server.value_ptr.object.getPtr("headers")) |headers| {
            if (headers.* == .object) {
                var headers_it = headers.object.iterator();
                while (headers_it.next()) |header| {
                    if (try substituteCredentialLeaf(arena, header.value_ptr, resolver, ctx)) changed = true;
                }
            }
        }
        if (server.value_ptr.object.getPtr("env")) |env| {
            if (env.* == .array) {
                for (env.array.items) |*item| {
                    if (try substituteCredentialLeaf(arena, item, resolver, ctx)) changed = true;
                }
            }
        }
    }
    return changed;
}

fn substituteCredentialLeaf(
    arena: std.mem.Allocator,
    value: *std.json.Value,
    resolver: Resolver,
    ctx: ?*const anyopaque,
) SubstError!bool {
    if (value.* != .string) return false;
    const text = value.string;
    if (std.mem.indexOf(u8, text, placeholder_prefix) == null) return false;

    const substituted = try substituteInString(arena, arena, text, resolver, ctx, null, .keep_literal);
    // `Stringify` reads these bytes before the arena dies, so an in-place
    // replacement is enough.
    value.* = .{ .string = substituted };
    return !std.mem.eql(u8, text, substituted);
}

const PlaceholderMatch = struct { name: []const u8, end: usize };

fn isNameChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '_' or c == '-';
}

/// Match a syntactically valid placeholder at `start`. Matching is
/// case-sensitive, and anything that is not a well-formed placeholder is left
/// alone as literal text.
fn matchPlaceholder(text: []const u8, start: usize) ?PlaceholderMatch {
    if (!std.mem.startsWith(u8, text[start..], placeholder_prefix)) return null;

    const name_start = start + placeholder_prefix.len;
    var i = name_start;
    while (i < text.len and isNameChar(text[i])) i += 1;
    const name = text[name_start..i];
    if (name.len == 0 or name.len > max_name_len) return null;
    if (i + placeholder_suffix.len > text.len) return null;
    if (!std.mem.eql(u8, text[i..][0..placeholder_suffix.len], placeholder_suffix)) return null;

    return .{ .name = name, .end = i + placeholder_suffix.len };
}

/// Build the substituted copy of one string leaf. Scanning walks left to right
/// over the ORIGINAL text and never revisits what it wrote, so a value that
/// itself contains a placeholder cannot recurse.
fn substituteInString(
    arena: std.mem.Allocator,
    alloc: std.mem.Allocator,
    text: []const u8,
    resolver: Resolver,
    ctx: ?*const anyopaque,
    resolved: ?*std.ArrayList(ResolvedSecret),
    miss: MissPolicy,
) SubstError![]const u8 {
    // The arena frees these bytes with the parse tree, so no errdefer here.
    var out_buf: std.ArrayList(u8) = .empty;

    var i: usize = 0;
    while (i < text.len) {
        if (matchPlaceholder(text, i)) |matched| {
            // A stored secret is never empty, so an empty answer is a miss:
            // substituting it would send the request out with a blank
            // credential and surface the problem as a third-party 401.
            if (resolver(ctx, matched.name)) |value| {
                if (value.len > 0) {
                    try out_buf.appendSlice(arena, value);
                    try recordResolved(alloc, resolved, matched.name, value);
                    i = matched.end;
                    continue;
                }
            }
            switch (miss) {
                .fail => return error.UnknownSecretName,
                .keep_literal => {
                    try out_buf.appendSlice(arena, text[i..matched.end]);
                    i = matched.end;
                    continue;
                },
            }
        }
        try out_buf.append(arena, text[i]);
        i += 1;
    }
    return out_buf.items;
}

/// One entry per distinct name, so redaction does not re-walk the output for
/// every repeat of the same placeholder.
fn recordResolved(
    alloc: std.mem.Allocator,
    resolved: ?*std.ArrayList(ResolvedSecret),
    name: []const u8,
    value: []const u8,
) !void {
    const list = resolved orelse return;
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing.name, name)) return;
    }
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const owned_value = try alloc.dupe(u8, value);
    try list.append(alloc, .{ .name = owned_name, .value = owned_value });
}

const testing = std.testing;

/// A table-driven stand-in for the store-backed resolver.
const Entry = struct { name: []const u8, value: []const u8 };

/// Carries the table through the erased `ctx` pointer. The pointer carries the
/// slice rather than being widened into one: a pointer cast straight to a
/// slice type has no length to give it.
const SecretTable = struct { entries: []const Entry };

fn tableResolver(ctx: ?*const anyopaque, name: []const u8) ?[]const u8 {
    const table: *const SecretTable = @ptrCast(@alignCast(ctx orelse return null));
    for (table.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

/// Free a result and every string in it: `name` and `value` are each their own
/// allocation, not slices into one buffer.
fn freeSubstitution(allocator: std.mem.Allocator, result: *const SubstitutionResult) void {
    for (result.resolved) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.value);
    }
    allocator.free(result.resolved);
    allocator.free(result.substituted_args);
}

fn substitute(allocator: std.mem.Allocator, args_json: []const u8, entries: []const Entry) SubstError!SubstitutionResult {
    const table = SecretTable{ .entries = entries };
    var result: SubstitutionResult = undefined;
    try substituteToolArguments(allocator, args_json, tableResolver, &table, &result);
    return result;
}

test "substituteToolArguments: a placeholder inside a string leaf is replaced" {
    const allocator = testing.allocator;
    const result = try substitute(allocator, "{\"command\":\"curl -H 'Auth: {{SECRETS:GH}}'\"}", &.{
        .{ .name = "GH", .value = "abc" },
    });
    defer freeSubstitution(allocator, &result);

    try testing.expectEqualStrings("{\"command\":\"curl -H 'Auth: abc'\"}", result.substituted_args);

    // The point of parse-and-re-serialize: the result must still parse.
    const reparsed = try std.json.parseFromSlice(std.json.Value, allocator, result.substituted_args, .{});
    defer reparsed.deinit();
    try testing.expectEqualStrings(
        "curl -H 'Auth: abc'",
        reparsed.value.object.get("command").?.string,
    );

    try testing.expectEqual(@as(usize, 1), result.resolved.len);
    try testing.expectEqualStrings("GH", result.resolved[0].name);
    try testing.expectEqualStrings("abc", result.resolved[0].value);
}

test "substituteToolArguments: a value with a quote, a newline and a NUL stays parseable" {
    const allocator = testing.allocator;
    const weird = "he said \"hi\"\n\x00done";
    const result = try substitute(allocator, "{\"command\":\"echo {{SECRETS:WEIRD}}\"}", &.{
        .{ .name = "WEIRD", .value = weird },
    });
    defer freeSubstitution(allocator, &result);

    // Raw-byte replacement would have produced invalid JSON here; the
    // serializer is what makes the escapes correct.
    const reparsed = try std.json.parseFromSlice(std.json.Value, allocator, result.substituted_args, .{});
    defer reparsed.deinit();
    try testing.expectEqualStrings("echo " ++ weird, reparsed.value.object.get("command").?.string);
}

test "substituteToolArguments: a value with a backslash does not create a bad escape" {
    const allocator = testing.allocator;
    const slashed = "C:\\Users\\gh\\token";
    const result = try substitute(allocator, "{\"path\":\"{{SECRETS:WIN}}\"}", &.{
        .{ .name = "WIN", .value = slashed },
    });
    defer freeSubstitution(allocator, &result);

    // `\U` is an invalid JSON escape; re-parsing is the oracle.
    const reparsed = try std.json.parseFromSlice(std.json.Value, allocator, result.substituted_args, .{});
    defer reparsed.deinit();
    try testing.expectEqualStrings(slashed, reparsed.value.object.get("path").?.string);
}

test "substituteToolArguments: an unknown name is a named error, never an empty value" {
    const allocator = testing.allocator;
    try testing.expectError(
        error.UnknownSecretName,
        substitute(allocator, "{\"command\":\"curl {{SECRETS:NOPE}}\"}", &.{
            .{ .name = "GH", .value = "abc" },
        }),
    );
}

test "substituteToolArguments: a resolver returning an empty string counts as a miss" {
    const allocator = testing.allocator;
    try testing.expectError(
        error.UnknownSecretName,
        substitute(allocator, "{\"command\":\"curl {{SECRETS:GH}}\"}", &.{
            .{ .name = "GH", .value = "" },
        }),
    );
}

test "substituteToolArguments: a resolved value is not re-scanned" {
    const allocator = testing.allocator;
    const self_referential = "prefix-{{SECRETS:GH}}-suffix";
    const result = try substitute(allocator, "{\"command\":\"{{SECRETS:GH}}\"}", &.{
        .{ .name = "GH", .value = self_referential },
    });
    defer freeSubstitution(allocator, &result);

    const reparsed = try std.json.parseFromSlice(std.json.Value, allocator, result.substituted_args, .{});
    defer reparsed.deinit();
    try testing.expectEqualStrings(self_referential, reparsed.value.object.get("command").?.string);
    try testing.expectEqual(@as(usize, 1), result.resolved.len);
}

test "substituteToolArguments: nested objects and arrays are walked" {
    const allocator = testing.allocator;
    const result = try substitute(
        allocator,
        "{\"outer\":{\"items\":[\"a-{{SECRETS:GH}}\",{\"deep\":\"{{SECRETS:GH}}\"}]}}",
        &.{.{ .name = "GH", .value = "abc" }},
    );
    defer freeSubstitution(allocator, &result);

    const reparsed = try std.json.parseFromSlice(std.json.Value, allocator, result.substituted_args, .{});
    defer reparsed.deinit();
    const items = reparsed.value.object.get("outer").?.object.get("items").?.array.items;
    try testing.expectEqualStrings("a-abc", items[0].string);
    try testing.expectEqualStrings("abc", items[1].object.get("deep").?.string);

    // One entry per distinct name, so redaction does not rescan per use.
    try testing.expectEqual(@as(usize, 1), result.resolved.len);
}

test "substituteToolArguments: non-string leaves are left untouched" {
    const allocator = testing.allocator;
    // A bare `{{SECRETS:N}}` cannot sit in a number position and still be
    // valid JSON, so it never reaches the walker as a number leaf:
    try testing.expectError(
        error.InvalidArguments,
        substitute(allocator, "{\"n\":{{SECRETS:N}}}", &.{.{ .name = "N", .value = "7" }}),
    );

    // What the walker must therefore guarantee: numbers, bools and nulls
    // survive untouched while a sibling string leaf is substituted.
    const result = try substitute(
        allocator,
        "{\"n\":-12,\"f\":2.5,\"big\":1e999,\"b\":true,\"z\":null,\"s\":\"{{SECRETS:GH}}\"}",
        &.{.{ .name = "GH", .value = "abc" }},
    );
    defer freeSubstitution(allocator, &result);

    const reparsed = try std.json.parseFromSlice(std.json.Value, allocator, result.substituted_args, .{});
    defer reparsed.deinit();
    try testing.expectEqual(@as(i64, -12), reparsed.value.object.get("n").?.integer);
    try testing.expectEqual(@as(f64, 2.5), reparsed.value.object.get("f").?.float);
    try testing.expectEqualStrings("1e999", reparsed.value.object.get("big").?.number_string);
    try testing.expect(reparsed.value.object.get("b").?.bool);
    try testing.expect(std.meta.activeTag(reparsed.value.object.get("z").?) == .null);
    try testing.expectEqualStrings("abc", reparsed.value.object.get("s").?.string);
}

test "substituteToolArguments: malformed arguments are rejected without touching the bytes" {
    const allocator = testing.allocator;
    const malformed = "{\"command\": \"unterminated";
    try testing.expectError(
        error.InvalidArguments,
        substitute(allocator, malformed, &.{.{ .name = "GH", .value = "abc" }}),
    );
    try testing.expectEqualStrings("{\"command\": \"unterminated", malformed);
}

test "substituteToolArguments: arguments with no placeholder come back semantically equal" {
    const allocator = testing.allocator;
    const args_json = "{\"a\":1,\"b\":[\"x\",null,true],\"c\":{\"d\":2.5}}";
    const result = try substitute(allocator, args_json, &.{.{ .name = "GH", .value = "abc" }});
    defer freeSubstitution(allocator, &result);

    // Compare against the input after the same round trip, so the assertion is
    // about meaning rather than about formatting.
    const reparsed_input = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer reparsed_input.deinit();
    const canonical_input = try std.json.Stringify.valueAlloc(allocator, reparsed_input.value, .{});
    defer allocator.free(canonical_input);

    try testing.expectEqualStrings(canonical_input, result.substituted_args);
    try testing.expectEqual(@as(usize, 0), result.resolved.len);
}

test "substituteToolArguments: text that only looks like a placeholder is literal" {
    const allocator = testing.allocator;
    const args_json =
        "{\"a\":\"{{SECRETS:}}\"," ++
        "\"b\":\"{{SECRETS:bad name}}\"," ++
        "\"c\":\"{{secrets:GH}}\"," ++
        "\"d\":\"{{SECRETS:GH}\"}";
    const result = try substitute(allocator, args_json, &.{.{ .name = "GH", .value = "abc" }});
    defer freeSubstitution(allocator, &result);

    const reparsed = try std.json.parseFromSlice(std.json.Value, allocator, result.substituted_args, .{});
    defer reparsed.deinit();
    const obj = reparsed.value.object;
    try testing.expectEqualStrings("{{SECRETS:}}", obj.get("a").?.string);
    try testing.expectEqualStrings("{{SECRETS:bad name}}", obj.get("b").?.string);
    try testing.expectEqualStrings("{{secrets:GH}}", obj.get("c").?.string);
    try testing.expectEqualStrings("{{SECRETS:GH}", obj.get("d").?.string);
    try testing.expectEqual(@as(usize, 0), result.resolved.len);
}

test "redactOutput: replaces the value with the placeholder" {
    const allocator = testing.allocator;
    const resolved = [_]ResolvedSecret{.{ .name = "GH", .value = "abc" }};
    const out = try redactOutput(allocator, "curl -H 'Auth: abc' ok", &resolved);
    defer allocator.free(out);

    try testing.expectEqualStrings("curl -H 'Auth: {{SECRETS:GH}}' ok", out);
}

test "redactOutput: returns the output unchanged when the value is absent" {
    const allocator = testing.allocator;
    const resolved = [_]ResolvedSecret{.{ .name = "GH", .value = "abc" }};
    const out = try redactOutput(allocator, "{\"exit_code\":0}", &resolved);
    defer allocator.free(out);

    try testing.expectEqualStrings("{\"exit_code\":0}", out);
}

test "redactOutput: handles multiple distinct values, including repeats" {
    const allocator = testing.allocator;
    const resolved = [_]ResolvedSecret{
        .{ .name = "A", .value = "alpha" },
        .{ .name = "B", .value = "beta" },
    };
    const out = try redactOutput(allocator, "x=alpha y=beta z=alpha", &resolved);
    defer allocator.free(out);

    try testing.expectEqualStrings("x={{SECRETS:A}} y={{SECRETS:B}} z={{SECRETS:A}}", out);
}

test "redactOutput: an empty resolved list returns the output unchanged" {
    const allocator = testing.allocator;
    const out = try redactOutput(allocator, "nothing to do", &.{});
    defer allocator.free(out);

    try testing.expectEqualStrings("nothing to do", out);
}

const ph_open = "{" ++ "{SECRETS:";
const ph_close = "}" ++ "}";

fn placeholder(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ ph_open, name, ph_close });
}

fn credentialConfig(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    header_value: []const u8,
    env_value: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"profiles_models\":{{\"deepseek\":{{\"model\":\"deepseek-v4\"," ++
            "\"base_url\":\"https://api.example.com\",\"api_key\":\"{s}\"}}}}," ++
            "\"mcp_servers\":{{\"files\":{{\"url\":\"https://mcp.example.com\"," ++
            "\"headers\":{{\"Authorization\":\"Bearer {s}\"}}," ++
            "\"env\":[\"TOKEN={s}\",\"MODE=prod\"]}}}}}}",
        .{ api_key, header_value, env_value },
    );
}

test "substituteConfigCredentials: the api_key, MCP header values and env entries resolve" {
    const alloc = testing.allocator;
    const key_ph = try placeholder(alloc, "API_KEY");
    defer alloc.free(key_ph);
    const header_ph = try placeholder(alloc, "MCP_TOKEN");
    defer alloc.free(header_ph);
    const env_ph = try placeholder(alloc, "MCP_TOKEN");
    defer alloc.free(env_ph);

    const document = try credentialConfig(alloc, key_ph, header_ph, env_ph);
    defer alloc.free(document);

    const table = SecretTable{ .entries = &.{
        .{ .name = "API_KEY", .value = "sk-live-value" },
        .{ .name = "MCP_TOKEN", .value = "tok-live" },
    } };
    const out = try substituteConfigCredentials(alloc, document, tableResolver, &table);
    defer alloc.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const agent = obj.get("profiles_models").?.object.get("deepseek").?.object;
    try testing.expectEqualStrings("sk-live-value", agent.get("api_key").?.string);

    const server = obj.get("mcp_servers").?.object.get("files").?.object;
    try testing.expectEqualStrings("Bearer tok-live", server.get("headers").?.object.get("Authorization").?.string);
    try testing.expectEqualStrings("TOKEN=tok-live", server.get("env").?.array.items[0].string);

    // Positive control for the "only credential positions" rule: the fields
    // around the substituted ones are byte-identical to what was saved.
    try testing.expectEqualStrings("deepseek-v4", agent.get("model").?.string);
    try testing.expectEqualStrings("https://api.example.com", agent.get("base_url").?.string);
    try testing.expectEqualStrings("https://mcp.example.com", server.get("url").?.string);
    try testing.expectEqualStrings("MODE=prod", server.get("env").?.array.items[1].string);
}

test "substituteConfigCredentials: the wire spelling `profiles` resolves the same way" {
    const alloc = testing.allocator;
    const key_ph = try placeholder(alloc, "API_KEY");
    defer alloc.free(key_ph);
    const document = try std.fmt.allocPrint(
        alloc,
        "{{\"profiles\":{{\"claude\":{{\"model\":\"opus\",\"api_key\":\"{s}\"}}}}}}",
        .{key_ph},
    );
    defer alloc.free(document);

    const table = SecretTable{ .entries = &.{.{ .name = "API_KEY", .value = "sk-wire" }} };
    const out = try substituteConfigCredentials(alloc, document, tableResolver, &table);
    defer alloc.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "sk-wire",
        parsed.value.object.get("profiles").?.object.get("claude").?.object.get("api_key").?.string,
    );
}

test "substituteConfigCredentials: a name this workspace does not store stays literal" {
    const alloc = testing.allocator;
    const missing_ph = try placeholder(alloc, "NOT_STORED");
    defer alloc.free(missing_ph);
    const key_ph = try placeholder(alloc, "API_KEY");
    defer alloc.free(key_ph);

    const document = try credentialConfig(alloc, missing_ph, key_ph, key_ph);
    defer alloc.free(document);

    const table = SecretTable{ .entries = &.{.{ .name = "API_KEY", .value = "sk-live" }} };
    const out = try substituteConfigCredentials(alloc, document, tableResolver, &table);
    defer alloc.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const agent = obj.get("profiles_models").?.object.get("deepseek").?.object;
    // Kept, not blanked: the secret can be added later and the same saved
    // document then starts resolving. A blank key would look like a typo.
    try testing.expectEqualStrings(missing_ph, agent.get("api_key").?.string);
    // The sibling that DID resolve proves the miss did not abort the walk.
    try testing.expectEqualStrings("Bearer sk-live", obj.get("mcp_servers").?.object.get("files").?.object.get("headers").?.object.get("Authorization").?.string);
}

test "substituteConfigCredentials: a placeholder outside a credential position is left alone" {
    const alloc = testing.allocator;
    const stray_ph = try placeholder(alloc, "API_KEY");
    defer alloc.free(stray_ph);

    const document = try std.fmt.allocPrint(
        alloc,
        "{{\"profiles_models\":{{\"a\":{{\"model\":\"{s}\",\"base_url\":\"{s}\"}}}},\"tools\":[\"{s}\"]}}",
        .{ stray_ph, stray_ph, stray_ph },
    );
    defer alloc.free(document);

    const table = SecretTable{ .entries = &.{.{ .name = "API_KEY", .value = "sk-live" }} };
    const out = try substituteConfigCredentials(alloc, document, tableResolver, &table);
    defer alloc.free(out);

    // Not a credential field, so the document comes back byte-for-byte.
    try testing.expectEqualStrings(document, out);
}

test "substituteConfigCredentials: a document with no placeholder is returned unchanged" {
    const alloc = testing.allocator;
    const document = "{\"profiles_models\":{\"a\":{\"model\":\"m\",\"api_key\":\"sk-plain\"}}}";
    const table = SecretTable{ .entries = &.{.{ .name = "API_KEY", .value = "sk-live" }} };

    const out = try substituteConfigCredentials(alloc, document, tableResolver, &table);
    defer alloc.free(out);
    try testing.expectEqualStrings(document, out);
}

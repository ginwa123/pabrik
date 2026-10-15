//! Web-search provider masking for the config HTTP handlers.

const std = @import("std");
const json = std.json;
const curlmod = @import("../modules/agent/tools/web_search_curl.zig");
const reqmod = @import("../modules/agent/tools/web_search_request.zig");

/// What a short key masks to. Fixed-length so it cannot leak the length of
/// a short credential.
pub const SHORT_MASK = "••••";

/// Mask a credential for display: first 3 + last 3 when there is enough to
/// make that meaningful, otherwise a fixed-length marker.
pub fn maskKey(key: []const u8) ?[]const u8 {
    if (key.len < 10) return SHORT_MASK;
    return null;
}

/// True when `value` is what `maskKey` would have produced for the stored
/// secret — the test the PUT handler uses to decide "leave it alone".
pub fn isMaskFor(value: []const u8) bool {
    if (std.mem.eql(u8, value, SHORT_MASK)) return true;
    // Any `abc…xyz` shape is a mask.
    const dots = std.mem.indexOf(u8, value, "…") orelse return false;
    if (dots < 3) return false;
    const tail = value[dots + 3 ..];
    return tail.len == 3;
}

pub const ValidationError = error{
    /// A provider has no name, or a name that is not usable as a JSON key.
    BadProviderName,
    /// `url` missing, not https, or pointing at a private/loopback host.
    BadPinnedUrl,
    /// `curl` missing or empty.
    MissingCurl,
    /// The template has no `{key}` but the entry declares a credential —
    /// the credential would be silently dropped.
    MissingKeyPlaceholder,
    /// The template has `{key}` but the entry declares no credential.
    UnexpectedKeyPlaceholder,
    /// The template does not parse as a GET-only curl.
    UnparseableCurl,
};

/// Validate one provider entry, returning a human-readable reason on failure.
/// Called on the PUT path so a bad paste is reported WHILE THE USER IS
/// LOOKING AT IT.
pub fn validateProvider(name: []const u8, entry: json.Value) ValidationError!?[]const u8 {
    if (name.len == 0) return error.BadProviderName;
    if (entry != .object) return "must be an object";
    const obj = entry.object;

    const url = switch (obj.get("url") orelse json.Value{ .null = {} }) {
        .string => |s| s,
        else => return "`url` is required and must be a string",
    };
    // `if (err_union) |payload|` fires on SUCCESS, so the rejection lives
    // in the `else` branch.
    if (reqmod.validatePinnedUrl(url)) |_| {
        // the pin passed
    } else |_| {
        return "`url` must be https and must not be loopback, private or link-local";
    }

    const curl_text = switch (obj.get("curl") orelse json.Value{ .null = {} }) {
        .string => |s| s,
        else => return "`curl` is required and must be a string",
    };
    if (curl_text.len == 0) return "`curl` must not be empty";

    // The template must survive the same parser the tool uses, so the user
    // learns about `-X POST` or a bad header here rather than mid-chat.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = curlmod.parse(a, curl_text) catch |err| {
        return switch (err) {
            error.Empty => "the curl is empty",
            error.UnsupportedCommand => "only a `curl` request is supported",
            error.UnsupportedFlag => "only GET is supported — no -X, -d, -o or --upload-file",
            error.UnterminatedQuote => "a quoted argument was never closed",
            error.MalformedHeader => "a -H argument must look like \"Name: value\"",
            error.AmbiguousUrl => "the curl contains more than one URL",
            error.MissingUrl => "no URL found in the curl",
            error.HeaderInjection => "a header name or value contains a control character",
            error.InsecureScheme => "only https:// is allowed",
            error.InvalidUrl => "the URL could not be parsed",
            error.NonPublicHost => "that host is loopback, private or link-local",
            error.DuplicateKeyPlaceholder => "the curl contains {key} more than once",
            error.OutOfMemory => "out of memory",
        };
    };
    defer parsed.deinit(a);

    // Two-sided placeholder check, matching `validateKeySite` at dispatch.
    const has_key = switch (obj.get("key") orelse json.Value{ .null = {} }) {
        .string => |s| s.len > 0,
        else => false,
    };
    if (has_key and parsed.parsed.key_site == .none) {
        return "this provider has a key configured but its curl has no {key} — put {key} where the credential belongs";
    }
    if (!has_key and parsed.parsed.key_site != .none) {
        return "this provider has no key configured but its curl contains {key}";
    }
    return null;
}

/// Replace every provider's `key` with its mask. The result is allocated from
/// `allocator` and owned by it.
pub fn maskProviders(
    allocator: std.mem.Allocator,
    body: ?json.Value,
) ?json.Value {
    const root = body orelse return null;
    if (root != .object) return null;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var quoted: ?[]u8 = null;
    defer if (quoted) |q| allocator.free(q);

    out.append(allocator, '{') catch return null;
    var first = true;
    var it = root.object.iterator();
    while (it.next()) |entry| {
        if (!first) out.append(allocator, ',') catch return null;
        first = false;

        quoted = jsonStringify(allocator, entry.key_ptr.*) catch return null;
        if (quoted) |q| out.appendSlice(allocator, q) catch return null;

        if (entry.value_ptr.* != .object) {
            quoted = jsonStringify(allocator, entry.value_ptr.*) catch return null;
            if (quoted) |q| out.appendSlice(allocator, q) catch return null;
            continue;
        }

        out.appendSlice(allocator, ":{") catch return null;
        var inner_first = true;
        var inner = entry.value_ptr.object.iterator();
        while (inner.next()) |f| {
            if (!inner_first) out.append(allocator, ',') catch return null;
            inner_first = false;
            quoted = jsonStringify(allocator, f.key_ptr.*) catch return null;
            if (quoted) |q| out.appendSlice(allocator, q) catch return null;
            out.append(allocator, ':') catch return null;

            quoted = if (std.mem.eql(u8, f.key_ptr.*, "key")) blk: {
                const real: []const u8 = switch (f.value_ptr.*) {
                    .string => |k| k,
                    else => break :blk jsonStringify(allocator, f.value_ptr.*) catch return null,
                };
                break :blk jsonStringify(allocator, maskFor(allocator, real) catch return null) catch return null;
            } else jsonStringify(allocator, f.value_ptr.*) catch return null;
            if (quoted) |q| out.appendSlice(allocator, q) catch return null;
        }
        out.append(allocator, '}') catch return null;
    }
    out.append(allocator, '}') catch return null;

    const text = out.toOwnedSlice(allocator) catch return null;
    defer allocator.free(text);
    return json.parseFromSliceLeaky(json.Value, allocator, text, .{}) catch null;
}

fn jsonStringify(allocator: std.mem.Allocator, v: anytype) ![]u8 {
    return json.Stringify.valueAlloc(allocator, v, .{});
}

/// The mask string for `key`, allocated. Long keys become `abc…xyz`;
/// short ones become a fixed-length marker so the length does not leak.
pub fn maskFor(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    if (maskKey(key)) |short| return allocator.dupe(u8, short);
    return std.fmt.allocPrint(allocator, "{s}…{s}", .{ key[0..3], key[key.len - 3 ..] });
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "web_search_mask: a short key is masked to a fixed length, not partially revealed" {
    // A 6-character secret masked to `abc…xyz` would leak the whole thing.
    try testing.expectEqualStrings(SHORT_MASK, maskKey("sk1234").?);
    try testing.expectEqualStrings(SHORT_MASK, maskKey("").?);
    try testing.expect(maskKey("sk1234567890") == null);
}

test "web_search_mask: isMaskFor recognises both mask shapes" {
    try testing.expect(isMaskFor(SHORT_MASK));
    try testing.expect(isMaskFor("skk…7f2"));
    try testing.expect(isMaskFor("abc…xyz"));
    try testing.expect(!isMaskFor("skkkk"));
    try testing.expect(!isMaskFor("sk…toolong"));
    try testing.expect(!isMaskFor("…7f2"));
    try testing.expect(!isMaskFor("sk…ab"));
    try testing.expect(!isMaskFor(""));
}

fn reasonFor(alloc: std.mem.Allocator, body: []const u8, name: []const u8) !?[]const u8 {
    var parsed = try json.parseFromSlice(json.Value, alloc, body, .{});
    defer parsed.deinit();
    return validateProvider(name, parsed.value);
}

test "web_search_mask: a well-formed provider passes" {
    const alloc = testing.allocator;
    try testing.expect((try reasonFor(alloc,
        \\{"url":"https://api.search.tinyfish.ai","key":"skkkk",
        \\ "curl":"https://api.search.tinyfish.ai?query=X -H \"X-API-Key: {key}\""}
    , "tinyfish")) == null);

    // A no-credential provider with no placeholder is equally valid.
    try testing.expect((try reasonFor(alloc,
        \\{"url":"https://search.example.net","curl":"https://search.example.net/search?q=X"}
    , "searxng")) == null);
}

test "web_search_mask: every rejection names the fix" {
    const alloc = testing.allocator;
    const cases = [_]struct { body: []const u8, want: []const u8 }{
        .{ .body = "{\"key\":\"k\",\"curl\":\"https://e.com?q=X\"}", .want = "url" },
        .{ .body = "{\"url\":\"http://e.com\",\"curl\":\"https://e.com?q=X\"}", .want = "https" },
        .{ .body = "{\"url\":\"https://127.0.0.1\",\"curl\":\"https://127.0.0.1?q=X\"}", .want = "loopback" },
        .{ .body = "{\"url\":\"https://169.254.169.254\",\"curl\":\"https://169.254.169.254/q\"}", .want = "link-local" },
        .{ .body = "{\"url\":\"https://e.com\"}", .want = "curl" },
        .{ .body = "{\"url\":\"https://e.com\",\"key\":\"k\",\"curl\":\"https://e.com?q=X\"}", .want = "{key}" },
        .{ .body = "{\"url\":\"https://e.com\",\"curl\":\"https://e.com?q=X -H \\\"A: {key}\\\"\"}", .want = "no key configured" },
        .{ .body = "{\"url\":\"https://e.com\",\"curl\":\"curl -X POST https://e.com?q=X -H \\\"A: {key}\\\"\"}", .want = "GET" },
        .{ .body = "{\"url\":\"https://e.com\",\"curl\":\"wget https://e.com?q=X\"}", .want = "request is supported" },
    };
    for (cases) |c| {
        const reason = (try reasonFor(alloc, c.body, "p")) orelse {
            std.debug.print("accepted a provider it should have rejected (want={s})\n", .{c.want});
            return error.ExpectedRejection;
        };
        if (std.mem.indexOf(u8, reason, c.want) == null) {
            std.debug.print("reason '{s}' does not mention '{s}'\n", .{ reason, c.want });
            return error.ReasonTooVague;
        }
    }
}

test "web_search_mask: a name-less provider is rejected" {
    const alloc = testing.allocator;
    var parsed = try json.parseFromSlice(json.Value, alloc,
        \\{"url":"https://e.com","curl":"https://e.com?q=X"}
    , .{});
    defer parsed.deinit();
    try testing.expectError(error.BadProviderName, validateProvider("", parsed.value));
}


test "web_search_mask: maskProviders masks every key and leaves the rest alone" {
    // An arena, not testing.allocator: `maskProviders` parses LEAKY into the
    // allocator it is given, because production hands it the per-request
    // arena where nothing is freed by hand.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Single-line literals throughout: a multiline `\\` literal needs a
    // different escape depth for the nested quotes, and getting it wrong
    // produced malformed JSON that failed as a parse error rather than as the
    var parsed = try json.parseFromSlice(json.Value, alloc,
        "{\"tinyfish\":{\"url\":\"https://api.search.tinyfish.ai\",\"key\":\"sk-secret-1234\",\"curl\":\"https://api.search.tinyfish.ai?q=X -H \\\"X-Api-Key: {key}\\\"\",\"description\":\"Best for news\",\"enabled\":true},\"searxng\":{\"url\":\"https://search.example.net\",\"curl\":\"https://search.example.net?q=X\"}}",
        .{},
    );
    defer parsed.deinit();

    const masked = maskProviders(alloc, parsed.value) orelse return error.ExpectedMap;
    const json_str = try json.Stringify.valueAlloc(alloc, masked, .{});
    defer alloc.free(json_str);

    // The credential is gone; the mask is recognisable as one.
    try testing.expect(std.mem.indexOf(u8, json_str, "sk-secret-1234") == null);
    try testing.expect(std.mem.indexOf(u8, json_str, "sk-…234") != null);
    // Everything else round-trips, including the {key} placeholder in the
    // template — the listing stays usable.
    try testing.expect(std.mem.indexOf(u8, json_str, "https://api.search.tinyfish.ai") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "Best for news") != null);
    try testing.expect(std.mem.indexOf(u8, json_str, "{key}") != null);
    // A provider with no key is untouched.
    try testing.expect(std.mem.indexOf(u8, json_str, "searxng") != null);
}

test "web_search_mask: maskProviders returns null for an absent or non-object body" {
    const alloc = testing.allocator;
    try testing.expect(maskProviders(alloc, null) == null);

    var arr = try json.parseFromSlice(json.Value, alloc, "[1,2]", .{});
    defer arr.deinit();
    try testing.expect(maskProviders(alloc, arr.value) == null);
}

// ─── PUT-path behaviour: masked and empty keys ────────────────────────────

test "web_search_mask: a mask is distinguishable from a real short key" {
    // The whole masked-key contract rests on this: if a mask could be
    // mistaken for a credential, PUT would either wipe the secret or store
    // the mask as one.
    try testing.expect(isMaskFor(SHORT_MASK));
    try testing.expect(isMaskFor("sk-…234"));
    // A REAL key that happens to contain an ellipsis is still a key.
    try testing.expect(!isMaskFor("sk-…-real"));
}

test "web_search_mask: an empty key validates as absent, so a no-auth provider is legal" {
    const alloc = testing.allocator;
    // `"key": ""` is what a form submits for an untouched blank field.
    try testing.expect((try reasonFor(alloc,
        \\{"url":"https://search.example.net","key":"","curl":"https://search.example.net/search?q=X"}
    , "searxng")) == null);
}

//! `web_search_request` — host pinning and `{key}` substitution.

const std = @import("std");
const curl = @import("web_search_curl.zig");
const Parsed = curl.Parsed;
const KeySite = curl.KeySite;
const Header = curl.Header;

/// Why a request was refused. Every variant is a bare tag: there is no
/// payload here, because an error string that interpolated the key would
/// leak it straight into `llm_history`.
pub const RefuseError = error{
    /// The config entry declares a credential but its template has no
    /// `{key}`, so the credential would be silently dropped.
    MissingKeySite,
    /// The config entry declares no credential but its template does have a
    /// `{key}` — there is nothing to put there.
    UnexpectedKeySite,
    /// The requested host is not the host the user pinned for this provider.
    HostNotPinned,
    /// The pinned URL itself is unusable (not https, or a private host).
    UnsafePinnedUrl,
};

/// A host split into the parts the pin compares.
const HostParts = struct {
    name: []const u8,
    port: []const u8,
};

/// Split `host[:port]` into a lowercased name and a port string.
fn splitHost(hostport: []const u8) HostParts {
    var rest = hostport;

    // Strip userinfo. `https://real.host@evil.host` is a phishing shape
    // that reads as `real.host` at a glance, and the pin must not.
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];

    var name = rest;
    var port: []const u8 = "";
    if (rest.len > 0 and rest[0] == '[') {
        // Bracketed IPv6: the port, if any, follows the closing bracket.
        if (std.mem.indexOfScalar(u8, rest, ']')) |close| {
            name = rest[0 .. close + 1];
            if (close + 1 < rest.len and rest[close + 1] == ':') port = rest[close + 2 ..];
        } else {
            name = rest;
        }
    } else if (std.mem.count(u8, rest, ":") == 1) {
        if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
            name = rest[0..colon];
            port = rest[colon + 1 ..];
        }
    }

    if (name.len > 1 and name[name.len - 1] == '.') name = name[0 .. name.len - 1];

    var lowered_buf: [256]u8 = undefined;
    const lowered: []const u8 = if (name.len <= lowered_buf.len)
        std.ascii.lowerString(&lowered_buf, name)
    else
        name;

    return .{ .name = lowered, .port = port };
}

/// Default port for the scheme. Only `https` is reachable — `parse` rejects
/// anything else — so this is the only default that can be asked for.
fn effectivePort(port: []const u8) []const u8 {
    if (port.len == 0) return "443";
    return port;
}

/// True when the request's host is exactly the pinned host.
pub fn hostMatches(request_url: []const u8, pinned_url: []const u8) bool {
    const req = splitHost(curl.hostOfUrl(request_url));
    const pin = splitHost(curl.hostOfUrl(pinned_url));
    return std.mem.eql(u8, req.name, pin.name) and
        std.mem.eql(u8, effectivePort(req.port), effectivePort(pin.port));
}

/// Verify the pinned URL the user configured is itself safe to send a
/// credential to.
pub fn validatePinnedUrl(pinned_url: []const u8) RefuseError!void {
    if (!hasHttpsScheme(pinned_url)) return error.UnsafePinnedUrl;
    if (curl.isNonPublicHost(curl.hostOfUrl(pinned_url))) return error.UnsafePinnedUrl;
}

fn hasHttpsScheme(url: []const u8) bool {
    const i = std.mem.indexOf(u8, url, "://") orelse return false;
    return std.ascii.eqlIgnoreCase(url[0..i], "https");
}

/// The policy the parser cannot know: does this template match this entry?
/// `parse` accepts a template with no `{key}` because a self-hosted provider
/// genuinely has no credential.
pub fn validateKeySite(parsed: Parsed, has_configured_key: bool) RefuseError!void {
    if (has_configured_key and parsed.key_site == .none) return error.MissingKeySite;
    if (!has_configured_key and parsed.key_site != .none) return error.UnexpectedKeySite;
}

/// A fully-built request: the credential is present and the host is approved.
pub const BuiltRequest = struct {
    /// The full URL, credential included when the site was the query.
    url: []u8,
    /// Owned header copies. Exactly one of these carries the credential
    /// when the provider has one.
    headers: []Header,
    allocator: std.mem.Allocator,

    pub fn deinit(self: BuiltRequest) void {
        for (self.headers) |h| {
            self.allocator.free(@constCast(h.name));
            self.allocator.free(@constCast(h.value));
        }
        self.allocator.free(self.headers);
        self.allocator.free(self.url);
    }
};

/// Replace every occurrence of `needle` in `haystack` with `replacement`.
fn replaceAll(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
) std.mem.Allocator.Error![]u8 {
    if (needle.len == 0) return allocator.dupe(u8, haystack);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        try out.appendSlice(allocator, rest[0..at]);
        try out.appendSlice(allocator, replacement);
        rest = rest[at + needle.len ..];
    }
    try out.appendSlice(allocator, rest);
    return out.toOwnedSlice(allocator);
}

/// Substitute the credential into a parsed request, producing the URL and
/// header list to send. The caller MUST have run `checkPin` first.
pub fn substituteKey(
    allocator: std.mem.Allocator,
    parsed: Parsed,
    key: ?[]const u8,
) std.mem.Allocator.Error!BuiltRequest {
    // Accumulate in a list rather than a pre-sized array. A pre-sized array
    // of `Header` holds UNINITIALISED slots, so an errdefer that walks all of
    // them on a mid-loop failure frees garbage.
    var headers: std.ArrayList(Header) = .empty;
    errdefer {
        for (headers.items) |h| {
            allocator.free(@constCast(h.name));
            allocator.free(@constCast(h.value));
        }
        headers.deinit(allocator);
    }

    const secret = key orelse "";
    for (parsed.headers) |h| {
        const name = try allocator.dupe(u8, h.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, h.value);
        try headers.append(allocator, .{ .name = name, .value = value });
    }

    if (parsed.key_site == .header) {
        const idx = parsed.key_site.header;
        const replaced = try replaceAll(
            allocator,
            headers.items[idx].value,
            curl.key_placeholder,
            secret,
        );
        allocator.free(@constCast(headers.items[idx].value));
        headers.items[idx].value = replaced;
    }

    const url = try buildUrl(allocator, parsed, key);
    return .{
        .url = url,
        .headers = try headers.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Reassemble `base?query`, substituting into whichever part holds the
/// placeholder.
fn buildUrl(
    allocator: std.mem.Allocator,
    parsed: Parsed,
    key: ?[]const u8,
) std.mem.Allocator.Error![]u8 {
    if (parsed.url_query.len == 0) return allocator.dupe(u8, parsed.url_base);

    var query = try allocator.dupe(u8, parsed.url_query);
    errdefer allocator.free(query);

    if (parsed.key_site == .url_query) {
        const replaced = try replaceAll(
            allocator,
            query,
            curl.key_placeholder,
            key orelse "",
        );
        allocator.free(query);
        query = replaced;
    }

    defer allocator.free(query);
    return std.fmt.allocPrint(allocator, "{s}?{s}", .{ parsed.url_base, query });
}

// ─────────────────── tests: pinning matrix rows 29–38, substitution ────────

const testing = std.testing;

const PinCase = struct {
    name: []const u8,
    request: []const u8,
    pinned: []const u8,
    want_match: bool,
};

const pin_cases = [_]PinCase{
    .{ .name = "row 29: exact match", .request = "https://api.search.tinyfish.ai/search", .pinned = "https://api.search.tinyfish.ai", .want_match = true },
    .{ .name = "row 30: case-insensitive", .request = "https://API.Search.TinyFish.AI/search", .pinned = "https://api.search.tinyfish.ai", .want_match = true },
    .{ .name = "row 31: SUBDOMAIN must not inherit the pin", .request = "https://evil.api.search.tinyfish.ai/x", .pinned = "https://api.search.tinyfish.ai", .want_match = false },
    .{ .name = "row 32: suffix attack must not match", .request = "https://api.search.tinyfish.ai.evil.com/x", .pinned = "https://api.search.tinyfish.ai", .want_match = false },
    .{ .name = "row 33: a stranger host", .request = "https://attacker.example.com/collect", .pinned = "https://api.search.tinyfish.ai", .want_match = false },
    .{ .name = "row 34: implicit :443 matches explicit :443", .request = "https://api.search.tinyfish.ai:443/x", .pinned = "https://api.search.tinyfish.ai", .want_match = true },
    .{ .name = "row 34b: implicit on both sides", .request = "https://api.search.tinyfish.ai/x", .pinned = "https://api.search.tinyfish.ai:443", .want_match = true },
    .{ .name = "row 35: :8443 must NOT match a :443 pin", .request = "https://api.search.tinyfish.ai:8443/x", .pinned = "https://api.search.tinyfish.ai:443", .want_match = false },
    .{ .name = "row 35b: reverse direction", .request = "https://api.search.tinyfish.ai:443/x", .pinned = "https://api.search.tinyfish.ai:8443", .want_match = false },
    .{ .name = "row 37: a trailing dot is the DNS root form, so it matches", .request = "https://api.search.tinyfish.ai./x", .pinned = "https://api.search.tinyfish.ai", .want_match = true },
    .{ .name = "userinfo cannot smuggle a different host", .request = "https://api.search.tinyfish.ai@evil.example.com/x", .pinned = "https://api.search.tinyfish.ai", .want_match = false },
    .{ .name = "a path on the pinned url is irrelevant", .request = "https://api.search.tinyfish.ai/other/path", .pinned = "https://api.search.tinyfish.ai/v1/search", .want_match = true },
};

test "web_search_request: host pin matrix" {
    for (pin_cases) |c| {
        testing.expectEqual(c.want_match, hostMatches(c.request, c.pinned)) catch |err| {
            std.debug.print("FAIL {s}: request={s} pinned={s}\n", .{ c.name, c.request, c.pinned });
            return err;
        };
    }
}

test "web_search_request: the injected-egress attack is refused" {
    // The exact string a prompt injection would produce. This test is the
    // gate for the whole feature's security story.
    const pinned = "https://api.search.tinyfish.ai";
    const attack = "https://attacker.example.com/collect";
    try testing.expect(!hostMatches(attack, pinned));
}

test "web_search_request: validatePinnedUrl rejects http and private hosts" {
    // Row 38 — enforced on the PUT path AND the execute path.
    try validatePinnedUrl("https://api.search.tinyfish.ai");
    try validatePinnedUrl("https://search.example.net:8443");
    try testing.expectError(error.UnsafePinnedUrl, validatePinnedUrl("http://api.search.tinyfish.ai"));
    try testing.expectError(error.UnsafePinnedUrl, validatePinnedUrl("https://127.0.0.1"));
    try testing.expectError(error.UnsafePinnedUrl, validatePinnedUrl("https://169.254.169.254"));
    try testing.expectError(error.UnsafePinnedUrl, validatePinnedUrl("https://192.168.1.1"));
    try testing.expectError(error.UnsafePinnedUrl, validatePinnedUrl("api.search.tinyfish.ai"));
}

test "web_search_request: validateKeySite is two-sided" {
    const alloc = testing.allocator;

    // An entry WITH a key needs somewhere to put it. Silently dropping the
    // credential would surface as an opaque 401 from the provider.
    var with_key = try curl.parse(alloc, "https://e.com?q=X -H \"Accept: application/json\"");
    defer with_key.deinit(alloc);
    try testing.expectError(error.MissingKeySite, validateKeySite(with_key.parsed, true));
    try validateKeySite(with_key.parsed, false); // no credential configured — fine

    // An entry WITHOUT a key must not have a site, or there is nothing to
    // substitute and the user probably mis-configured something.
    var with_site = try curl.parse(alloc, "https://e.com?q=X -H \"X-Api-Key: {key}\"");
    defer with_site.deinit(alloc);
    try validateKeySite(with_site.parsed, true);
    try testing.expectError(error.UnexpectedKeySite, validateKeySite(with_site.parsed, false));
}

test "web_search_request: a header site gets the key" {
    const alloc = testing.allocator;
    var p = try curl.parse(alloc,
        \\https://api.search.tinyfish.ai?query=X -H "X-API-Key: {key}" -H "X-TF-Request-Origin: api"
    );
    defer p.deinit(alloc);

    const built = try substituteKey(alloc, p.parsed, "SENTINEL_SECRET_DO_NOT_LEAK");
    defer built.deinit();

    try testing.expectEqualStrings("https://api.search.tinyfish.ai?query=X", built.url);
    try testing.expectEqual(@as(usize, 2), built.headers.len);
    try testing.expectEqualStrings("X-API-Key", built.headers[0].name);
    try testing.expectEqualStrings("SENTINEL_SECRET_DO_NOT_LEAK", built.headers[0].value);
    // The static header is untouched.
    try testing.expectEqualStrings("api", built.headers[1].value);
    // And no placeholder survives anywhere.
    try testing.expect(std.mem.indexOf(u8, built.url, "{key}") == null);
}

test "web_search_request: a url_query site gets the key, percent-unsafe text and all" {
    const alloc = testing.allocator;
    var p = try curl.parse(alloc, "https://serpapi.com/search?engine=google&api_key={key}&num=10");
    defer p.deinit(alloc);

    const built = try substituteKey(alloc, p.parsed, "sk-123");
    defer built.deinit();

    try testing.expectEqualStrings(
        "https://serpapi.com/search?engine=google&api_key=sk-123&num=10",
        built.url,
    );
    try testing.expectEqual(@as(usize, 0), built.headers.len);
}

test "web_search_request: KeySite.none builds a request with no credential" {
    const alloc = testing.allocator;
    var p = try curl.parse(alloc, "https://search.example.net/search?q=X&format=json");
    defer p.deinit(alloc);

    const built = try substituteKey(alloc, p.parsed, null);
    defer built.deinit();
    try testing.expectEqualStrings("https://search.example.net/search?q=X&format=json", built.url);
}

test "web_search_request: substituteKey never emits a literal placeholder" {
    const alloc = testing.allocator;
    // A key that ITSELF contains the placeholder text must not confuse the
    // substitution loop — and must not produce a half-substituted URL.
    var p = try curl.parse(alloc, "https://e.com?q=X -H \"X-Api-Key: {key}\"");
    defer p.deinit(alloc);

    const built = try substituteKey(alloc, p.parsed, "a{key}b");
    defer built.deinit();
    try testing.expectEqualStrings("a{key}b", built.headers[0].value);
}

test "web_search_request: substitution copies every header, so the caller's input is untouched" {
    const alloc = testing.allocator;
    const input = "https://e.com?q=X -H \"X-Api-Key: {key}\" -H \"A: 1\"";
    var p = try curl.parse(alloc, input);
    defer p.deinit(alloc);

    const built = try substituteKey(alloc, p.parsed, "sk");
    defer built.deinit();

    // The borrowed header slices still point into `input`, unchanged.
    try testing.expectEqualStrings("{key}", p.parsed.headers[0].value);
    // …and the built copies are independent.
    try testing.expectEqualStrings("sk", built.headers[0].value);
    try testing.expect(p.parsed.headers[0].value.ptr != built.headers[0].value.ptr);
}

test "web_search_request: replaceAll handles zero, one and many occurrences" {
    const alloc = testing.allocator;
    const one = try replaceAll(alloc, "a{key}b", "{key}", "X");
    defer alloc.free(one);
    try testing.expectEqualStrings("aXb", one);

    const many = try replaceAll(alloc, "{key}-{key}-{key}", "{key}", "X");
    defer alloc.free(many);
    try testing.expectEqualStrings("X-X-X", many);

    const none = try replaceAll(alloc, "abc", "{key}", "X");
    defer alloc.free(none);
    try testing.expectEqualStrings("abc", none);

    const trailing = try replaceAll(alloc, "a{key}", "{key}", "X");
    defer alloc.free(trailing);
    try testing.expectEqualStrings("aX", trailing);
}
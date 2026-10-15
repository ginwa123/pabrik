// Functional tests for the `web_search` provider config (plan
// 2026-10-02-web-search-tool.md, matrix rows 72-73 + the mask contract).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Fixtures / helpers (mirrors config_tools_test.py's shared preamble)
// ============================================================================

/// `config_tools_test.PROFILE` — a profile-only config so the PUT
/// live-reload validates (backfill provides the credentials
/// `validate()` requires).
const PROFILE_JSON =
    \\{"model":"tools-model","base_url":"https://tools.example.com","api_key":"tools-key","url_style":"openai"}
;

/// Provider ENTRIES, not whole objects: `settingsBody` wraps them in the
/// `web_search` braces itself (see `webSearchObject`).
const TINYFISH_ENTRY =
    \\"tinyfish":{
    \\  "url": "https://api.search.tinyfish.ai",
    \\  "key": "sk-tinyfish-secret-value",
    \\  "curl": "https://api.search.tinyfish.ai?query=PLACEHOLDER&location=US -H \"X-API-Key: {key}\"",
    \\  "description": "Best for news."
    \\}
;

const BRAVE_ENTRY =
    \\"brave":{
    \\  "url": "https://api.search.brave.com",
    \\  "key": "sk-brave-secret-value",
    \\  "curl": "https://api.search.brave.com/res/v1/web/search?q=PLACEHOLDER -H \"X-Subscription-Token: {key}\""
    \\}
;

const TINYFISH_KEY = "sk-tinyfish-secret-value";
const BRAVE_KEY = "sk-brave-secret-value";

/// The EXACT whole-config shape `PabrikSettings.vue` sends on Save from any
/// tab, with the `web_search` marker included verbatim.
fn settingsBody(web_search_json: ?[]const u8) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    const w = &buf.writer;
    try writeChunk(w,
        \\{"profiles":{"p1":
    );
    try writeChunk(w, PROFILE_JSON);
    try writeChunk(w,
        \\},"active_profile":"p1","mcp_servers":null,
        \\"notify_on_complete":false,"notify_on_error":false,"web_launch_enabled":false,
        \\"model_compaction_size_kb":100,"max_capacity_token_model":null,
        \\"compaction_threshold_percent":null,"retry_delay_ms":0
    );
    if (web_search_json) |ws| {
        try w.writeAll(",\"web_search\":");
        try w.writeAll(ws);
    }
    try w.writeAll("}");
    return buf.toOwnedSlice();
}

/// `writeAll` without the trailing newline a `\\` multiline literal carries.
fn writeChunk(w: *std.Io.Writer, chunk: []const u8) !void {
    try w.writeAll(std.mem.trimEnd(u8, chunk, "\n"));
}

/// `{"<name>":{...},"<name>":{...}}` from provider ENTRIES. Owned.
fn webSearchObject(entries: []const []const u8) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    const w = &buf.writer;
    try w.writeAll("{");
    for (entries, 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try writeChunk(w, e);
    }
    try w.writeAll("}");
    return buf.toOwnedSlice();
}

/// Boot with the stub LLM profile already on disk — the Zig equivalent of
/// `preboot(_base_config(...))` (see the header note).
fn bootPrebooted() !Harness {
    return Harness.boot(io, gpa, .{ .stub_llm_profile = true });
}

/// `PUT /api/config/pabrik` with an explicit expected status.
fn putConfig(h: *Harness, body: []const u8, expect: []const u16) !harness.Response {
    return h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = expect });
}

/// `GET /api/config/pabrik`.
fn getConfig(h: *Harness) !harness.Response {
    return h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
}

/// The config.json the running binary reads and writes, plus its parsed
/// form. Both are owned so the document outlives the bytes it came from.
const DiskConfig = struct {
    bytes: []u8,
    doc: harness.Json,

    /// doc FIRST, then bytes: `doc.deinit()` reads nothing, but a future
    /// accessor might, and the free order here is the safe one either way.
    fn deinit(self: *DiskConfig) void {
        self.doc.deinit();
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Read + parse the harness HOME's config.json (Python's `_on_disk`).
fn readDiskConfig(h: *Harness) !DiskConfig {
    const candidates = [_][]const []const u8{
        &.{ ".config", "pabrik", "config.json" },
        &.{ "Library", "Application Support", "pabrik", "config.json" },
        &.{ "AppData", "Roaming", "pabrik", "config.json" },
    };
    var path: ?[]u8 = null;
    for (candidates) |parts| {
        const p = try harness.harnessPath(gpa, h.temp_dir, parts);
        defer gpa.free(p);
        std.Io.Dir.cwd().access(io, p, .{}) catch continue;
        path = try gpa.dupe(u8, p);
        break;
    }
    if (path == null) {
        std.debug.print("no config.json under the harness HOME ({s})\n", .{h.temp_dir});
        return error.TestUnexpectedResult;
    }
    defer gpa.free(path.?);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path.?, gpa, .limited(1 << 20));
    errdefer gpa.free(bytes);
    const doc: harness.Json = .{
        .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}),
    };
    return .{ .bytes = bytes, .doc = doc };
}

/// The provider map out of a config GET body, or a test failure.
fn webSearchMap(doc: *const harness.Json) !std.json.ObjectMap {
    return doc.object("web_search") orelse {
        std.debug.print("web_search missing or not an object\n", .{});
        return error.TestUnexpectedResult;
    };
}

/// One provider entry inside a `web_search` map. `std.json.ObjectMap` is an
/// ArrayHashMap: it has `get`, not the `Json`-wrapper's `object(key)` sugar,
/// so the value is unwrapped here.
fn provider(map: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    const v = map.get(name) orelse {
        std.debug.print("web_search has no provider '{s}'\n", .{name});
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .object => |o| o,
        else => {
            std.debug.print("web_search provider '{s}' is not an object\n", .{name});
            return error.TestUnexpectedResult;
        },
    };
}

/// A string field of a provider entry.
fn providerStr(entry: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = entry.get(key) orelse {
        std.debug.print("provider has no `{s}` field\n", .{key});
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .string => |s| s,
        else => {
            std.debug.print("provider `{s}` is not a string\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
}

/// Assert `haystack` contains `needle` (Python's `needle in haystack`).
fn expectContains(haystack: []const u8, needle: []const u8, what: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("{s}: expected to contain '{s}', got '{s}'\n", .{ what, needle, haystack });
        return error.TestUnexpectedResult;
    }
}

/// Assert `haystack` does NOT contain `needle`.
fn expectNotContains(haystack: []const u8, needle: []const u8, what: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("{s}: '{s}' leaked into '{s}'\n", .{ what, needle, haystack });
        return error.TestUnexpectedResult;
    }
}

/// The masked `key` of a provider in a GET body, owned. Python read it
/// straight out of the parsed response; a helper cannot return a `Json`,
/// so this returns the string.
fn maskedKey(h: *Harness, provider_name: []const u8) ![]u8 {
    var r = try getConfig(h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const map = try webSearchMap(&doc);
    const entry = try provider(map, provider_name);
    const key = try providerStr(entry, "key");
    return gpa.dupe(u8, key);
}

// ============================================================================
// (a) PUT persists and GET reflects
// ============================================================================

test "web_search_round_trips_through_put_and_get" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootPrebooted();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    // Two providers in one PUT.
    {
        const providers = try webSearchObject(&.{ TINYFISH_ENTRY, BRAVE_ENTRY });
        defer gpa.free(providers);

        const body = try settingsBody(providers);
        defer gpa.free(body);

        var r = try putConfig(&h, body, &.{200});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        // Python: `r.get("success") in (True, None) or "error" not in r
        // or not r.get("error")`.
        const success = doc.get("success");
        const success_ok = success == null or switch (success.?) {
            .bool => |b| b,
            .null => true,
            else => false,
        };
        const err_value = doc.get("error");
        const error_absent = err_value == null;
        const error_empty = switch (err_value orelse std.json.Value{ .null = {} }) {
            .string => |s| s.len == 0,
            else => false,
        };
        if (!(success_ok or error_absent or error_empty)) {
            std.debug.print("PUT failed: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    {
        var r = try getConfig(&h);
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        const map = try webSearchMap(&doc);
        // `set(ws) == {"tinyfish", "brave"}` — provider names round-trip.
        if (map.count() != 2 or map.get("tinyfish") == null or map.get("brave") == null) {
            std.debug.print("provider names did not round-trip: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }

        const tinyfish = try provider(map, "tinyfish");
        const url = try providerStr(tinyfish, "url");
        if (!std.mem.eql(u8, url, "https://api.search.tinyfish.ai")) {
            std.debug.print("tinyfish url = '{s}'\n", .{url});
            return error.TestUnexpectedResult;
        }
        const description = try providerStr(tinyfish, "description");
        if (!std.mem.eql(u8, description, "Best for news.")) {
            std.debug.print("tinyfish description = '{s}'\n", .{description});
            return error.TestUnexpectedResult;
        }
        // The template round-trips with its {key} placeholder intact.
        const curl = try providerStr(tinyfish, "curl");
        try expectContains(curl, "{key}", "the tinyfish curl template");
    }
}

// ============================================================================
// (b) GET MASKS the credential
// ============================================================================

// The single most important assertion in this file: the credential
// must not appear anywhere in the GET response body.
test "get_masks_the_api_key" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootPrebooted();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    // Seed both providers (Python seeded them into config.json pre-boot).
    {
        const providers = try webSearchObject(&.{ TINYFISH_ENTRY, BRAVE_ENTRY });
        defer gpa.free(providers);

        const body = try settingsBody(providers);
        defer gpa.free(body);
        var r = try putConfig(&h, body, &.{200});
        defer r.deinit();
    }

    {
        var r = try getConfig(&h);
        defer r.deinit();

        // The raw body, not a parsed field: the credential must not
        // appear ANYWHERE, including in a field the assertions below do
        // not look at.
        try expectNotContains(r.body, TINYFISH_KEY, "the real TinyFish key leaked through GET");
        try expectNotContains(r.body, BRAVE_KEY, "the real Brave key leaked through GET");

        var doc = try r.json();
        defer doc.deinit();
        const map = try webSearchMap(&doc);
        const tinyfish = try provider(map, "tinyfish");

        // Masked, but still recognisable as a mask so the Settings form
        // can round-trip it back as "unchanged".
        const key = try providerStr(tinyfish, "key");
        try expectContains(key, "\u{2026}", "the tinyfish key mask");
    }
}

// A 6-character key masked as `abc…xyz` would leak 6 of 6 characters —
// worse than leaking none. Anything under 10 chars gets a fixed-length
// marker instead.
test "get_masks_a_short_key_without_leaking_it_entirely" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootPrebooted();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const short_json =
        \\{"short":{
        \\  "url": "https://api.example.com",
        \\  "key": "sk1234",
        \\  "curl": "https://api.example.com?q=PLACEHOLDER -H \"X-Api-Key: {key}\""
        \\}}
    ;
    {
        const body = try settingsBody(short_json);
        defer gpa.free(body);
        var r = try putConfig(&h, body, &.{200});
        defer r.deinit();
    }

    {
        var r = try getConfig(&h);
        defer r.deinit();
        try expectNotContains(r.body, "sk1234", "a short key leaked in full through the mask");

        var doc = try r.json();
        defer doc.deinit();
        const map = try webSearchMap(&doc);
        const entry = try provider(map, "short");
        const key = try providerStr(entry, "key");
        if (std.mem.eql(u8, key, "sk1234")) {
            std.debug.print("the short key came back in cleartext\n", .{});
            return error.TestUnexpectedResult;
        }
        // Python's `len()` counts CODE POINTS, `key.len` counts UTF-8 BYTES —
        // and the short mask is four U+2022 BULLETs, i.e. 8 bytes.
        if (try std.unicode.utf8CountCodepoints(key) > 8) {
            std.debug.print("mask should not reveal the length: '{s}'\n", .{key});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// (c) A Settings save from ANOTHER tab must not erase the providers
// ============================================================================

// The PUT-strip footgun. If `web_search` is missing from the write
// struct, every save from another Settings tab silently deletes the
// user's API key — with no error anywhere.
test "settings_save_without_web_search_does_not_erase_it" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootPrebooted();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    // Seed one provider.
    {
        const providers = try webSearchObject(&.{TINYFISH_ENTRY});
        defer gpa.free(providers);

        const body = try settingsBody(providers);
        defer gpa.free(body);
        var r = try putConfig(&h, body, &.{200});
        defer r.deinit();
    }

    // Save from "another tab": no web_search key in the body.
    {
        const body = try settingsBody(null);
        defer gpa.free(body);
        var r = try putConfig(&h, body, &.{200});
        defer r.deinit();
    }

    var disk = try readDiskConfig(&h);
    defer disk.deinit();
    const map = try webSearchMap(&disk.doc);
    const tinyfish = try provider(map, "tinyfish");
    const key = try providerStr(tinyfish, "key");
    if (!std.mem.eql(u8, key, TINYFISH_KEY)) {
        std.debug.print("the credential was lost: '{s}'\n", .{key});
        return error.TestUnexpectedResult;
    }
}

// The Settings form echoes the MASK on save. If PUT stored that, the
// user would overwrite their own credential with four dots the first time
// they changed an unrelated setting.
test "masked_key_round_trips_back_as_unchanged" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootPrebooted();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    {
        const providers = try webSearchObject(&.{TINYFISH_ENTRY});
        defer gpa.free(providers);

        const body = try settingsBody(providers);
        defer gpa.free(body);
        var r = try putConfig(&h, body, &.{200});
        defer r.deinit();
    }

    const masked = try maskedKey(&h, "tinyfish");
    defer gpa.free(masked);
    if (std.mem.eql(u8, masked, TINYFISH_KEY)) {
        std.debug.print("the key came back unmasked: '{s}'\n", .{masked});
        return error.TestUnexpectedResult;
    }

    // Echo the mask back, as the Settings form does on an unrelated save.
    {
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        try buf.writer.writeAll("{\"tinyfish\":{\"url\":\"https://api.search.tinyfish.ai\",\"key\":\"");
        try buf.writer.writeAll(masked);
        try buf.writer.writeAll("\",\"curl\":\"https://api.search.tinyfish.ai?query=PLACEHOLDER&location=US -H \\\"X-API-Key: {key}\\\"\",\"description\":\"Best for news.\"}}");
        const echoed = try buf.toOwnedSlice();
        defer gpa.free(echoed);

        const body = try settingsBody(echoed);
        defer gpa.free(body);
        var r = try putConfig(&h, body, &.{200});
        defer r.deinit();
    }

    var disk = try readDiskConfig(&h);
    defer disk.deinit();
    const map = try webSearchMap(&disk.doc);
    const tinyfish = try provider(map, "tinyfish");
    const key = try providerStr(tinyfish, "key");
    if (!std.mem.eql(u8, key, TINYFISH_KEY)) {
        std.debug.print("PUT stored the mask over the real credential: '{s}'\n", .{key});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// (d) A malformed provider is a 400, not a silent drop
// ============================================================================

/// `PUT` a provider named `broken` whose body is `provider_json`, and assert
/// the 400 names both the provider and `expect_in_message`, and that nothing
/// reached disk.
fn expectMalformedRejected(h: *Harness, provider_json: []const u8, expect_in_message: []const u8) !void {
    const body = try settingsBody(provider_json);
    defer gpa.free(body);

    var r = try putConfig(h, body, &.{400});
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const message = doc.str("error") orelse "";
    try expectContains(message, "broken", "the 400 does not name the offending provider");
    try expectContains(message, expect_in_message, "the 400 does not say what is wrong");

    var disk = try readDiskConfig(h);
    defer disk.deinit();
    if (disk.doc.get("web_search") != null) {
        std.debug.print("a rejected provider was still written to disk: {s}\n", .{disk.bytes});
        return error.TestUnexpectedResult;
    }
}

// parametrize row 1: no `url`.
test "malformed_provider_missing_url" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootPrebooted();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try expectMalformedRejected(&h,
        \\{"broken":{"key":"k","curl":"https://e.com?q=X"}}
    , "url");
}

// parametrize row 2: an http:// url.
test "malformed_provider_http_url" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootPrebooted();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try expectMalformedRejected(&h,
        \\{"broken":{"url":"http://e.com","curl":"https://e.com?q=X"}}
    , "https");
}

// parametrize row 3: a loopback url.
test "malformed_provider_loopback_url" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootPrebooted();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try expectMalformedRejected(&h,
        \\{"broken":{"url":"https://127.0.0.1","curl":"https://127.0.0.1?q=X"}}
    , "loopback");
}

// parametrize row 4: a link-local url (the cloud metadata endpoint).
test "malformed_provider_link_local_url" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootPrebooted();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try expectMalformedRejected(&h,
        \\{"broken":{"url":"https://169.254.169.254","curl":"https://169.254.169.254/q"}}
    , "link-local");
}

// parametrize row 5: no `curl`.
test "malformed_provider_missing_curl" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootPrebooted();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try expectMalformedRejected(&h,
        \\{"broken":{"url":"https://e.com"}}
    , "curl");
}

// parametrize row 6: a key configured but no {key} in the template —
// the credential would be silently dropped.
test "malformed_provider_curl_without_key_placeholder" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootPrebooted();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try expectMalformedRejected(&h,
        \\{"broken":{"url":"https://e.com","key":"k","curl":"https://e.com?q=X"}}
    , "{key}");
}

// parametrize row 7: a template that is not a GET.
test "malformed_provider_curl_not_get" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootPrebooted();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try expectMalformedRejected(&h,
        \\{"broken":{"url":"https://e.com","curl":"curl -X POST https://e.com?q=X -H \"A: {key}\""}}
    , "GET");
}

// ============================================================================
// (e) An empty key is OMITTED, never stored as ""
// ============================================================================

// `SqliteBackend.exec` binds `""` as SQL NULL, and an empty string is
// exactly the shape that survives a JSON round-trip while meaning unset.
test "empty_key_is_omitted_not_stored_as_empty_string" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootPrebooted();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const no_auth =
        \\{"searxng":{
        \\  "url": "https://search.example.net",
        \\  "key": "",
        \\  "curl": "https://search.example.net/search?q=PLACEHOLDER"
        \\}}
    ;
    {
        const body = try settingsBody(no_auth);
        defer gpa.free(body);
        var r = try putConfig(&h, body, &.{200});
        defer r.deinit();
    }

    var disk = try readDiskConfig(&h);
    defer disk.deinit();
    const map = try webSearchMap(&disk.doc);
    const searxng = try provider(map, "searxng");
    if (searxng.get("key") != null) {
        std.debug.print("an empty credential was stored: {s}\n", .{disk.bytes});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// (f) GET reports an absent key as absent, not as an empty map
// ============================================================================

test "get_reports_web_search_null_when_absent" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootPrebooted();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    var r = try getConfig(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // The key must be PRESENT so the frontend can tell 'not configured'
    // from 'field never shipped'.
    const ws = doc.get("web_search") orelse {
        std.debug.print(
            "the key must be PRESENT so the frontend can tell 'not configured' " ++
                "from 'field never shipped': {s}\n",
            .{r.body},
        );
        return error.TestUnexpectedResult;
    };
    if (ws != .null) {
        std.debug.print("expected null, got {any}\n", .{ws});
        return error.TestUnexpectedResult;
    }
}
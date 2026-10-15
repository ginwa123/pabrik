//! `web_search_curl` — a GET-only parser for the curl string the agent sends.
//! The agent is handed a template by `list_web_search_providers` and edits
//! it: it replaces the search text and may adjust other parameters.

const std = @import("std");

/// The literal the user leaves in the template where the credential goes.
pub const key_placeholder = "{key}";

/// One request header. `name` and `value` borrow from the parsed input.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Where the credential belongs inside the parsed request.
pub const KeySite = union(enum) {
    /// A header value carries `{key}`.
    header: usize,
    /// The URL's query string carries `{key}`.
    url_query: void,
    /// The template has no `{key}` — a provider that needs no credential.
    none: void,
};

/// A parsed, not-yet-substituted request.
pub const Parsed = struct {
    /// Everything before the first `?` — scheme, host, port, path.
    url_base: []const u8,
    /// The raw query string without its leading `?`. Empty when the URL
    /// had none.
    url_query: []const u8,
    headers: []const Header,
    key_site: KeySite,

    /// Host (and optional `:port`) taken from `url_base`. IPv6 literals
    /// keep their brackets so a pin can be written the same way.
    pub fn hostOf(self: Parsed) []const u8 {
        return hostOfUrl(self.url_base);
    }
};

pub const ParseError = error{
    /// The string was empty, or contained only whitespace and flags.
    Empty,
    /// The input began with something other than `curl` or a URL — e.g.
    /// `wget …`, `sh -c …`. Only `curl` may be stripped, silently.
    UnsupportedCommand,
    /// A flag that changes the meaning of the request (or writes files).
    UnsupportedFlag,
    /// A quoted argument was never closed.
    UnterminatedQuote,
    /// `-H`/`--header` argument with no `:` separator.
    MalformedHeader,
    /// More than one bare URL in the string.
    AmbiguousUrl,
    /// No argument contained a URL at all.
    MissingUrl,
    /// A header name or value contained CR or LF.
    HeaderInjection,
    /// The scheme was not `https`.
    InsecureScheme,
    /// The URL host was absent or unparseable.
    InvalidUrl,
    /// The host is loopback / link-local / private / unspecified.
    NonPublicHost,
    /// `{key}` appeared more than once, so the intent is ambiguous.
    DuplicateKeyPlaceholder,
};

/// Extract the `host[:port]` portion of a URL that has no query.
pub fn hostOfUrl(url: []const u8) []const u8 {
    // Strip the scheme FIRST. Cutting at the first delimiter before this
    // turns "https://e.com/a" into "https:" — the very next line then
    // finds no "://" and returns the scheme as the host.
    const scheme_end = std.mem.indexOf(u8, url, "://");
    var rest = if (scheme_end) |i| url[i + 3 ..] else url;

    // Now drop the path, query and fragment: none can appear in a host.
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    rest = rest[0..end];

    // Userinfo (`user:pass@host`) is not part of the host. It is stripped
    // here and REJECTED by the caller — see `checkHostPolicy`.
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];

    // A bare `host:port/path` with no scheme: the scheme is required by
    // `parse`, so anything reaching here already has one.
    return rest;
}

/// True when `host` names a loopback, link-local, private, or otherwise
/// non-public address.
pub fn isNonPublicHost(host: []const u8) bool {
    var h = host;
    // Strip an explicit port. Bracketed IPv6 keeps its brackets until here.
    if (h.len > 0 and h[0] == '[') {
        const close = std.mem.indexOfScalar(u8, h, ']') orelse return true; // malformed
        return isNonPublicHost(h[1..close]);
    }
    if (std.mem.lastIndexOfScalar(u8, h, ':')) |colon| {
        // More than one colon and no brackets = a bare IPv6 literal, which
        // this tool never accepts (an https URL must bracket it).
        if (std.mem.count(u8, h, ":") > 1) return true;
        h = h[0..colon];
    }
    if (h.len == 0) return true;

    // "localhost" and anything ending in ".localhost" / ".local" / ".internal"
    if (std.ascii.eqlIgnoreCase(h, "localhost")) return true;
    if (endsWithIgnoreCase(h, ".localhost")) return true;
    if (endsWithIgnoreCase(h, ".local")) return true;
    if (endsWithIgnoreCase(h, ".internal")) return true;

    // IPv6 loopback / unspecified, written bare (already bracketed above).
    if (std.mem.eql(u8, h, "::1")) return true;
    if (std.mem.eql(u8, h, "::")) return true;

    // IPv4 dotted quad. Anything not four decimal octets is a hostname,
    // which is not decidable here.
    var octets: [4]u16 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, h, '.');
    while (it.next()) |part| {
        if (count == 4) return false; // not a dotted quad — treat as a hostname
        if (part.len == 0 or part.len > 3) return false;
        var n: u16 = 0;
        for (part) |c| {
            if (!std.ascii.isDigit(c)) return false;
            n = n * 10 + (c - '0');
        }
        if (n > 255) return false;
        octets[count] = n;
        count += 1;
    }
    if (count != 4) return false;

    const a = octets[0];
    if (a == 0) return true; // 0.0.0.0/8 "this host"
    if (a == 127) return true; // loopback
    if (a == 10) return true; // private
    if (a == 172 and octets[1] >= 16 and octets[1] <= 31) return true; // private
    if (a == 192 and octets[1] == 168) return true; // private
    if (a == 169 and octets[1] == 254) return true; // link-local / metadata
    if (a == 100 and octets[1] >= 64 and octets[1] <= 127) return true; // CGNAT
    if (a >= 224) return true; // multicast + reserved
    return false;
}

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

/// Validate the scheme and host of a URL that will carry a credential.
fn checkHostPolicy(url: []const u8, require_public: bool) ParseError!void {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidUrl;
    const scheme = url[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "https")) return error.InsecureScheme;

    const host = hostOfUrl(url);
    if (host.len == 0) return error.InvalidUrl;
    if (require_public and isNonPublicHost(host)) return error.NonPublicHost;
}

/// A tokenised argument: either a literal piece of text, or one that was
/// quoted (and so had its quotes stripped).
const Token = struct {
    text: []const u8,
    was_quoted: bool,
};

/// Split `input` into tokens, honouring `"…"` and `'…'` and stripping a
/// trailing `\` line continuation. All slices borrow from `input`.
fn tokenize(allocator: std.mem.Allocator, input: []const u8) (ParseError || std.mem.Allocator.Error)![]Token {
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        // Backslash-newline is a line continuation: both vanish.
        if (c == '\\' and i + 1 < input.len and input[i + 1] == '\n') {
            i += 2;
            continue;
        }
        if (c == '"' or c == '\'') {
            const quote = c;
            const start = i + 1;
            const close = std.mem.indexOfScalarPos(u8, input, start, quote) orelse
                return error.UnterminatedQuote;
            try out.append(allocator, .{ .text = input[start..close], .was_quoted = true });
            i = close + 1;
            continue;
        }
        // Bare run up to whitespace.
        const start = i;
        while (i < input.len and !std.ascii.isWhitespace(input[i])) : (i += 1) {}
        try out.append(allocator, .{ .text = input[start..i], .was_quoted = false });
    }
    return out.toOwnedSlice(allocator);
}

/// Flags that would change the request's method, body, or effect on disk.
/// Matched on the long form and on the unambiguous short forms.
const BANNED_SHORT = [_][]const u8{ "-X", "-x", "-d", "-T", "-o", "-O", "-F", "-K", "-E", "-D", "-U", "-P", "-Q", "-r" };
const BANNED_LONG = [_][]const u8{
    "--request",     "--data",       "--data-raw",     "--data-binary",
    "--data-ascii",  "--form",       "--form-string",
    "--upload-file", "--output",     "--remote-name",  "--remote-header-name",
    "--url",         "--libcurl",    "--config",       "--proxy",
    "--retry",       "--connect-timeout", "--max-time", "--cert",
    "--key",         "--cacert",     "--header-file",  "--cookie",
    "--cookie-jar",  "--dump-header", "--trace",       "--trace-ascii",
    "--verbose",     "--silent",     "--show-error",   "--insecure",
    "--resolve",     "--interface",  "--limit-rate",   "--max-filesize",
};

fn bannedFlag(token: []const u8) bool {
    for (BANNED_SHORT) |f| {
        // `-XPOST` (no space) is the same flag.
        if (std.mem.eql(u8, token, f)) return true;
        if (token.len > f.len and std.mem.startsWith(u8, token, f)) return true;
    }
    for (BANNED_LONG) |f| {
        if (std.mem.eql(u8, token, f)) return true;
        // `--flag=value`
        if (token.len > f.len and std.mem.startsWith(u8, token, f) and token[f.len] == '=') return true;
    }
    return false;
}

/// The owned result of `parse`. Exactly two allocations, both released by
/// `deinit`; `parsed` borrows from them and from `input`.
pub const Owned = struct {
    tokens: []Token,
    headers: []Header,
    /// Owns the query string ONLY when `-G`/`--data-urlencode` made us
    /// synthesise one.
    query_buf: ?[]u8,
    parsed: Parsed,

    /// Free every allocation. `parsed` is a view and owns nothing. Takes
    /// `self` by value: releasing does not mutate the owner, so a `const`
    /// binding can still `defer r.deinit(alloc)`.
    pub fn deinit(self: Owned, allocator: std.mem.Allocator) void {
        allocator.free(self.tokens);
        allocator.free(self.headers);
        if (self.query_buf) |qb| allocator.free(qb);
    }
};

/// Parse the agent's curl string into a URL + headers + the `{key}` site.
pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
) (ParseError || std.mem.Allocator.Error)!Owned {
    const tokens = try tokenize(allocator, input);
    errdefer allocator.free(tokens);

    var headers: std.ArrayList(Header) = .empty;
    // Cleared by `toOwnedSlice` on the success path, so this only ever
    // fires while `headers` still owns its buffer.
    errdefer headers.deinit(allocator);

    var url_text: ?[]const u8 = null;
    var extra_query: std.ArrayList(u8) = .empty;
    // The fold result is COPIED into `merged` below, so this list keeps
    // ownership of its own buffer for the whole function — the `defer`
    // is safe on every path, including the early error returns.
    defer extra_query.deinit(allocator);

    var key_header_index: ?usize = null;
    var key_in_query = false;
    var query_flag = false;

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const tok = tokens[i];

        // A leading bare `curl` is the program name, not a URL. Stripping it
        // is what lets the model paste a whole command from a provider's
        // docs.
        if (i == 0 and !tok.was_quoted) {
            if (std.mem.eql(u8, tok.text, "curl")) {
                // No `i += 1` here: the loop's own `: (i += 1)` runs on
                // `continue`, and incrementing twice swallowed the URL.
                continue;
            }
            if (tok.text.len > 0 and tok.text[0] != '-' and
                std.mem.indexOf(u8, tok.text, "://") == null)
            {
                std.log.info("web_search_curl: refusing non-curl command '{s}'", .{tok.text});
                return error.UnsupportedCommand;
            }
        }

        // Accepted flags are handled BEFORE the ban check. `--data-urlencode`
        // used to appear in both lists, and because the ban ran first the
        // accepted branch was unreachable dead code.
        if (std.mem.eql(u8, tok.text, "-G") or std.mem.eql(u8, tok.text, "--get")) {
            query_flag = true;
            continue;
        }

        // `-G`/`--data-urlencode` fold their argument into the query.
        if (std.mem.eql(u8, tok.text, "--data-urlencode")) {
            i += 1;
            if (i >= tokens.len) return error.MalformedHeader;
            try appendQueryParam(&extra_query, allocator, tokens[i].text);
            continue;
        }

        if (bannedFlag(tok.text)) return error.UnsupportedFlag;

        const is_header = std.mem.eql(u8, tok.text, "-H") or std.mem.eql(u8, tok.text, "--header");
        if (is_header) {
            i += 1;
            if (i >= tokens.len) return error.MalformedHeader;
            const arg = tokens[i].text;
            const colon = std.mem.indexOfScalar(u8, arg, ':') orelse return error.MalformedHeader;
            const name = arg[0..colon];
            var value = arg[colon + 1 ..];
            // Strip one leading space, the way curl does.
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            if (name.len == 0) return error.MalformedHeader;
            try checkNoControlChars(name, value);

            if (std.mem.indexOf(u8, value, key_placeholder) != null) {
                if (key_header_index != null or key_in_query) return error.DuplicateKeyPlaceholder;
                key_header_index = headers.items.len;
            }
            try headers.append(allocator, .{ .name = name, .value = value });
            continue;
        }

        if (tok.text.len > 0 and tok.text[0] == '-') {
            // An unknown-but-harmless flag (`--compressed`, `--silent` is
            // banned, `-s` is not). Ignore it rather than guessing.
            continue;
        }

        if (url_text == null) {
            url_text = tok.text;
        } else if (std.mem.indexOf(u8, tok.text, "://") != null) {
            // A second bare URL is ambiguous — we would be guessing which
            // one the model meant.
            return error.AmbiguousUrl;
        }
    }

    const raw_url = url_text orelse return error.MissingUrl;

    // `-G`/`--data-urlencode` put their arguments in the query, so a `-G`
    // run may have data but no `?` in the URL.
    var base: []const u8 = raw_url;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, raw_url, '?')) |q| {
        base = raw_url[0..q];
        query = raw_url[q + 1 ..];
    }
    var query_buf: ?[]u8 = null;
    if (extra_query.items.len > 0) {
        // curl's `-G` APPENDS its data arguments to whatever query the URL
        // already had, so `?count=10` + `--data-urlencode q=FIFA` becomes
        // `count=10&q=FIFA` — not the other way round.
        var merged: std.ArrayList(u8) = .empty;
        errdefer merged.deinit(allocator);
        try merged.appendSlice(allocator, query);
        if (query.len > 0) try merged.append(allocator, '&');
        try merged.appendSlice(allocator, extra_query.items);
        query_buf = try merged.toOwnedSlice(allocator);
        query = query_buf.?;
    }
    // `-G` means "append the data to the URL", which for us is simply that
    // the folded query is the query. Nothing else to do.

    try checkHostPolicy(base, true);

    // `{key}` in the URL query counts too — SerpApi and Google CSE take
    // the credential as a query parameter.
    if (std.mem.indexOf(u8, query, key_placeholder) != null) {
        if (key_header_index != null or key_in_query) return error.DuplicateKeyPlaceholder;
        key_in_query = true;
    }

    // No `{key}` is NOT a parse error — see `KeySite.none`. Whether it is
    // acceptable is a policy question about the config entry, and that
    // check lives in `web_search_request.validateKeySite`.
    const key_site: KeySite = if (key_header_index) |idx|
        .{ .header = idx }
    else if (key_in_query)
        .url_query
    else
        .none;

    // `toOwnedSlice`, NOT `headers.items`.
    const owned_headers = try headers.toOwnedSlice(allocator);

    return .{
        .tokens = tokens,
        .headers = owned_headers,
        .query_buf = query_buf,
        .parsed = .{
            .url_base = base,
            .url_query = query,
            .headers = owned_headers,
            .key_site = key_site,
        },
    };
}

fn checkNoControlChars(name: []const u8, value: []const u8) ParseError!void {
    for (name) |c| {
        if (c == '\r' or c == '\n') return error.HeaderInjection;
        if (c < 0x20 and c != '\t') return error.HeaderInjection;
    }
    for (value) |c| {
        if (c == '\r' or c == '\n') return error.HeaderInjection;
        if (c < 0x20 and c != '\t') return error.HeaderInjection;
    }
}

fn appendQueryParam(out: *std.ArrayList(u8), allocator: std.mem.Allocator, param: []const u8) std.mem.Allocator.Error!void {
    if (out.items.len > 0) try out.append(allocator, '&');
    try out.appendSlice(allocator, param);
}

// ─────────────────────────── tests: parser matrix rows 1–28 ─────────────────

const testing = std.testing;

const tinyfish_curl =
    "https://api.search.tinyfish.ai?query=latest+FIFA+World+Cup+news+today&location=US&language=en" ++
    " -H \"X-API-Key: {key}\" -H \"X-TF-Request-Origin: api\" -H \"X-TF-API-Source: onboarding\"";

const Expect = struct {
    name: []const u8,
    input: []const u8,
    want_err: ?ParseError = null,
    want_headers: usize = 0,
    want_url_contains: ?[]const u8 = null,
    /// Success row whose template carries no placeholder — valid only for a
    /// provider that needs no credential.
    want_no_key_site: bool = false,
};

const parse_cases = [_]Expect{
    .{ .name = "row 1: the TinyFish fragment, double quotes", .input = tinyfish_curl, .want_headers = 3 },
    .{ .name = "row 2: a leading `curl` token is stripped", .input = "curl " ++ tinyfish_curl, .want_headers = 3 },
    .{ .name = "row 3: single quotes", .input = "https://e.com?q=X -H 'X-Api-Key: {key}'", .want_headers = 1 },
    .{ .name = "row 4: backslash line continuations", .input = "https://e.com?q=X \\\n  -H \"X-Api-Key: {key}\" \\\n  -H \"Accept: application/json\"", .want_headers = 2 },
    .{ .name = "row 5: three headers keep their order", .input = "https://e.com?q=X -H \"a: 1\" -H \"b: 2\" -H \"X-Api-Key: {key}\"", .want_headers = 3 },
    .{ .name = "row 6: --header long form", .input = "https://e.com?q=X --header \"a: 1\" --header \"X-Api-Key: {key}\"", .want_headers = 2 },
    .{ .name = "row 7: -G --data-urlencode folds into the query", .input = "curl -G \"https://api.search.brave.com/res/v1/web/search\" --data-urlencode \"q=PLACEHOLDER\" -H \"X-Subscription-Token: {key}\"", .want_headers = 1, .want_url_contains = "api.search.brave.com" },
    .{ .name = "row 8: {key} in a header value", .input = "https://e.com?q=X -H \"X-Api-Key: {key}\"", .want_headers = 1 },
    .{ .name = "row 9: {key} in the URL query", .input = "https://e.com?api_key={key}", .want_headers = 0 },
    .{ .name = "row 10: no {key} anywhere is KeySite.none, not an error", .input = "https://e.com?q=X -H \"Accept: application/json\"", .want_headers = 1, .want_no_key_site = true },
    .{ .name = "row 11: two {key} occurrences", .input = "https://e.com?q={key} -H \"X-Api-Key: {key}\"", .want_err = error.DuplicateKeyPlaceholder },
    .{ .name = "row 12: wget is rejected", .input = "wget https://e.com?q=X -H \"a: {key}\"", .want_err = error.UnsupportedCommand },
    .{ .name = "row 13: sh -c is rejected", .input = "sh -c \"curl https://e.com?q=X\"", .want_err = error.UnsupportedCommand },
    .{ .name = "row 14: CRLF in a header value", .input = "https://e.com?q=X -H \"a: 1\r\nX-Evil: 2\" -H \"b: {key}\"", .want_err = error.HeaderInjection },
    .{ .name = "row 15: CRLF in a header NAME", .input = "https://e.com?q=X -H \"a\r\nb: 1\" -H \"b: {key}\"", .want_err = error.HeaderInjection },
    .{ .name = "row 16: header with no colon", .input = "https://e.com?q=X -H \"no-colon-here\" -H \"b: {key}\"", .want_err = error.MalformedHeader },
    .{ .name = "row 17: -o writes a file", .input = "curl -o out.html https://e.com?q=X -H \"a: {key}\"", .want_err = error.UnsupportedFlag },
    .{ .name = "row 18: -X POST changes the method", .input = "curl -X POST https://e.com?q=X -H \"a: {key}\"", .want_err = error.UnsupportedFlag },
    .{ .name = "row 18b: -XPOST with no space", .input = "curl -XPOST https://e.com?q=X -H \"a: {key}\"", .want_err = error.UnsupportedFlag },
    .{ .name = "row 19: -d @file reads a file", .input = "curl -d @secrets.txt https://e.com?q=X -H \"a: {key}\"", .want_err = error.UnsupportedFlag },
    .{ .name = "row 20: --upload-file", .input = "curl --upload-file x https://e.com?q=X -H \"a: {key}\"", .want_err = error.UnsupportedFlag },
    .{ .name = "row 21: empty string", .input = "", .want_err = error.MissingUrl },
    .{ .name = "row 22: flags but no URL", .input = "curl -H \"a: {key}\"", .want_err = error.MissingUrl },
    .{ .name = "row 23: two bare URLs", .input = "https://a.com?q=X https://b.com?q=X -H \"a: {key}\"", .want_err = error.AmbiguousUrl },
    .{ .name = "row 24: unterminated quote", .input = "https://e.com?q=X -H \"a: {key}", .want_err = error.UnterminatedQuote },
    .{ .name = "row 25: http:// is refused", .input = "http://e.com?q=X -H \"a: {key}\"", .want_err = error.InsecureScheme },
    .{ .name = "row 26: file:// is refused", .input = "file:///etc/passwd -H \"a: {key}\"", .want_err = error.InsecureScheme },
    .{ .name = "row 27: link-local metadata endpoint", .input = "https://169.254.169.254/latest/meta-data -H \"a: {key}\"", .want_err = error.NonPublicHost },
    .{ .name = "row 28a: 127.0.0.1", .input = "https://127.0.0.1/q -H \"a: {key}\"", .want_err = error.NonPublicHost },
    .{ .name = "row 28b: 10.0.0.1", .input = "https://10.0.0.1/q -H \"a: {key}\"", .want_err = error.NonPublicHost },
    .{ .name = "row 28c: 192.168.1.1", .input = "https://192.168.1.1/q -H \"a: {key}\"", .want_err = error.NonPublicHost },
    .{ .name = "row 28d: [::1]", .input = "https://[::1]/q -H \"a: {key}\"", .want_err = error.NonPublicHost },
    .{ .name = "row 28e: 172.16.0.1 private", .input = "https://172.16.0.1/q -H \"a: {key}\"", .want_err = error.NonPublicHost },
    .{ .name = "row 28f: 169.254.169.254 on a path", .input = "https://169.254.169.254:8443/q -H \"a: {key}\"", .want_err = error.NonPublicHost },
};

test "web_search_curl: parse matrix" {
    const alloc = testing.allocator;
    for (parse_cases) |c| {
        const result = parse(alloc, c.input);
        if (c.want_err) |want| {
            testing.expectError(want, result) catch |err| {
                std.debug.print("FAIL {s}: expected {s}, got {s}\n", .{
                    c.name,
                    @errorName(want),
                    @errorName(err),
                });
                return err;
            };
            continue;
        }
        const ok = result catch |err| {
            std.debug.print("FAIL {s}: unexpected {s}\n", .{ c.name, @errorName(err) });
            return err;
        };
        // A success row must either carry the placeholder or declare that it
        // is a no-credential fixture. Anything else is a broken test row.
        const has_placeholder = std.mem.indexOf(u8, c.input, key_placeholder) != null;
        testing.expect(has_placeholder or c.want_no_key_site) catch |err| {
            std.debug.print("BAD ROW {s}: success fixture has no key placeholder and did not declare one\n", .{c.name});
            return err;
        };
        if (c.want_no_key_site) {
            testing.expect(ok.parsed.key_site == .none) catch |err| {
                std.debug.print("BAD ROW {s}: want_no_key_site but a site was found\n", .{c.name});
                return err;
            };
        }
        testing.expectEqual(c.want_headers, ok.parsed.headers.len) catch |err| {
            std.debug.print("FAIL {s}: header count\n", .{c.name});
            return err;
        };
        if (c.want_url_contains) |needle| {
            testing.expect(std.mem.indexOf(u8, ok.parsed.url_base, needle) != null) catch |err| {
                std.debug.print("FAIL {s}: url_base missing '{s}'\n", .{ c.name, needle });
                return err;
            };
        }
        var owned = ok;
        owned.deinit(alloc);
    }
}

test "web_search_curl: a leading non-curl word is rejected BY NAME" {
    const alloc = testing.allocator;
    // `wget …` and `sh -c …` are refused as UnsupportedCommand rather than
    // as MissingUrl: the paste contained a URL, so "no URL found" would be
    // actively misleading about what went wrong.
    testing.expectError(error.UnsupportedCommand, parse(alloc, "wget -q https://e.com?q=X -H \"a: {key}\"")) catch |err| return err;
    testing.expectError(error.UnsupportedCommand, parse(alloc, "sh -c curl")) catch |err| return err;
    testing.expectError(error.UnsupportedCommand, parse(alloc, "python -c \"print(1)\" -H \"a: {key}\"")) catch |err| return err;
    // The word must be LEADING. A bare non-URL word later on lands in
    // the URL slot and fails scheme validation, which names the actual
    // problem rather than pretending there was no URL.
    testing.expectError(error.InvalidUrl, parse(alloc, "curl -H \"a: {key}\" whatever")) catch |err| return err;
}

test "web_search_curl: rows 1-4 all produce the same request" {
    // The four variants differ only in how the user (or the model) quoted
    // and wrapped them, so all four must parse to the same request.
    const alloc = testing.allocator;
    const variants = [_][]const u8{
        tinyfish_curl,
        "curl " ++ tinyfish_curl,
        "https://api.search.tinyfish.ai?query=latest+FIFA+World+Cup+news+today&location=US&language=en -H 'X-API-Key: {key}' -H 'X-TF-Request-Origin: api' -H 'X-TF-API-Source: onboarding'",
        "https://api.search.tinyfish.ai?query=latest+FIFA+World+Cup+news+today&location=US&language=en \\\n-H \"X-API-Key: {key}\" \\\n-H \"X-TF-Request-Origin: api\" \\\n-H \"X-TF-API-Source: onboarding\"",
    };

    // The baseline `Owned` is held for the WHOLE test: `Parsed` borrows
    // from its allocation, so releasing it at the end of iteration one
    // leaves `first` pointing at freed memory.
    var first = try parse(alloc, variants[0]);
    defer first.deinit(alloc);
    try testing.expectEqualStrings("https://api.search.tinyfish.ai", first.parsed.url_base);
    try testing.expectEqualStrings(
        "query=latest+FIFA+World+Cup+news+today&location=US&language=en",
        first.parsed.url_query,
    );
    try testing.expectEqual(@as(usize, 3), first.parsed.headers.len);
    try testing.expectEqual(KeySite{ .header = 0 }, first.parsed.key_site);

    for (variants[1..]) |v| {
        var got = try parse(alloc, v);
        defer got.deinit(alloc);
        try testing.expectEqualStrings(first.parsed.url_base, got.parsed.url_base);
        try testing.expectEqualStrings(first.parsed.url_query, got.parsed.url_query);
        try testing.expectEqual(first.parsed.headers.len, got.parsed.headers.len);
        for (got.parsed.headers, first.parsed.headers) |g, w| {
            try testing.expectEqualStrings(w.name, g.name);
            try testing.expectEqualStrings(w.value, g.value);
        }
        try testing.expectEqual(first.parsed.key_site, got.parsed.key_site);
    }
}

test "web_search_curl: the key site points at the right header" {
    const alloc = testing.allocator;
    const r = try parse(alloc, "https://e.com?q=X -H \"Accept: application/json\" -H \"X-Api-Key: {key}\"");
    defer r.deinit(alloc);
    try testing.expectEqual(KeySite{ .header = 1 }, r.parsed.key_site);
}

test "web_search_curl: a {key} in the query is reported as the url_query site" {
    const alloc = testing.allocator;
    const r = try parse(alloc, "https://serpapi.com/search?engine=google&api_key={key}");
    defer r.deinit(alloc);
    try testing.expectEqual(KeySite.url_query, r.parsed.key_site);
}

test "web_search_curl: a leading space after the colon is stripped, as curl does" {
    const alloc = testing.allocator;
    const r = try parse(alloc, "https://e.com?q=X -H \"X-Api-Key:    {key}\"");
    defer r.deinit(alloc);
    try testing.expectEqualStrings("   {key}", r.parsed.headers[0].value);
}

test "web_search_curl: a header value may itself contain a colon" {
    const alloc = testing.allocator;
    const r = try parse(alloc, "https://e.com?q=X -H \"Host: a: b\" -H \"X-Api-Key: {key}\"");
    defer r.deinit(alloc);
    try testing.expectEqualStrings("Host", r.parsed.headers[0].name);
    try testing.expectEqualStrings("a: b", r.parsed.headers[0].value);
}

test "web_search_curl: an unknown harmless flag is ignored, not guessed at" {
    const alloc = testing.allocator;
    const r = try parse(alloc, "curl --compressed -sSL https://e.com?q=X -H \"X-Api-Key: {key}\"");
    defer r.deinit(alloc);
    try testing.expectEqualStrings("https://e.com", r.parsed.url_base);
    try testing.expectEqual(@as(usize, 1), r.parsed.headers.len);
}

test "web_search_curl: a URL with no path keeps an empty query" {
    const alloc = testing.allocator;
    const r = try parse(alloc, "https://e.com -H \"X-Api-Key: {key}\"");
    defer r.deinit(alloc);
    try testing.expectEqualStrings("https://e.com", r.parsed.url_base);
    try testing.expectEqualStrings("", r.parsed.url_query);
}

test "web_search_curl: --data-urlencode appends to an existing query" {
    const alloc = testing.allocator;
    const r = try parse(alloc,
        \\curl -G "https://api.search.brave.com/res/v1/web/search?count=10" --data-urlencode "q=FIFA" -H "X-Subscription-Token: {key}"
    );
    defer r.deinit(alloc);
    try testing.expectEqualStrings("https://api.search.brave.com/res/v1/web/search", r.parsed.url_base);
    try testing.expectEqualStrings("count=10&q=FIFA", r.parsed.url_query);
}

test "web_search_curl: hostOfUrl returns host[:port] and drops userinfo" {
    try testing.expectEqualStrings("e.com", hostOfUrl("https://e.com/a/b?q=1"));
    try testing.expectEqualStrings("e.com:8443", hostOfUrl("https://e.com:8443/a"));
    try testing.expectEqualStrings("e.com", hostOfUrl("https://e.com"));
    try testing.expectEqualStrings("e.com", hostOfUrl("https://user:pass@e.com/a"));
    // Bracketed IPv6 keeps its brackets, and the port is part of the pin.
    try testing.expectEqualStrings("[::1]:443", hostOfUrl("https://[::1]:443/a"));
    try testing.expectEqualStrings("e.com", hostOfUrl("https://e.com#frag"));
}

test "web_search_curl: isNonPublicHost covers the literal private ranges" {
    try testing.expect(isNonPublicHost("127.0.0.1"));
    try testing.expect(isNonPublicHost("127.1.2.3"));
    try testing.expect(isNonPublicHost("10.0.0.1"));
    try testing.expect(isNonPublicHost("172.16.0.1"));
    try testing.expect(isNonPublicHost("172.31.255.255"));
    try testing.expect(isNonPublicHost("192.168.1.1"));
    try testing.expect(isNonPublicHost("169.254.169.254"));
    try testing.expect(isNonPublicHost("100.64.0.1"));
    try testing.expect(isNonPublicHost("0.0.0.0"));
    try testing.expect(isNonPublicHost("224.0.0.1"));
    try testing.expect(isNonPublicHost("localhost"));
    try testing.expect(isNonPublicHost("LOCALHOST"));
    try testing.expect(isNonPublicHost("api.localhost"));
    try testing.expect(isNonPublicHost("db.internal"));
    try testing.expect(isNonPublicHost("printer.local"));
    try testing.expect(isNonPublicHost("[::1]"));
    try testing.expect(isNonPublicHost("[fe80::1]"));

    // 172.32/12 is public, 192.169/16 is public, 169.253 is public.
    try testing.expect(!isNonPublicHost("172.32.0.1"));
    try testing.expect(!isNonPublicHost("192.169.1.1"));
    try testing.expect(!isNonPublicHost("169.253.1.1"));
    try testing.expect(!isNonPublicHost("8.8.8.8"));
    try testing.expect(!isNonPublicHost("api.search.tinyfish.ai"));
    try testing.expect(!isNonPublicHost("api.search.tinyfish.ai:443"));
    // A hostname is not decidable without DNS — it must not be false-
    // positive into "private", which would block every real provider.
    try testing.expect(!isNonPublicHost("notanip"));
    try testing.expect(!isNonPublicHost("999.1.1.1"));
}

test "web_search_curl: every emitted piece came verbatim from the input" {
    // The structural claim "this module cannot leak a credential" rests on it
    // inventing nothing: a `Parsed` holds only slices of the input plus one
    // index.
    const alloc = testing.allocator;
    const input =
        "https://api.search.tinyfish.ai?query=FIFA&location=US" ++
        " -H \"X-API-Key: {key}\" -H \"Accept: application/json\"";

    const r = try parse(alloc, input);
    defer r.deinit(alloc);

    try testing.expect(std.mem.indexOf(u8, input, r.parsed.url_base) != null);
    try testing.expect(std.mem.indexOf(u8, input, r.parsed.url_query) != null);
    for (r.parsed.headers) |h| {
        try testing.expect(std.mem.indexOf(u8, input, h.name) != null);
        try testing.expect(std.mem.indexOf(u8, input, h.value) != null);
    }
}
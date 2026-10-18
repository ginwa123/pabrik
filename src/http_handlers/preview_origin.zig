//! The preview origin's rules: a separate registrable domain, the app's
//! credentials stripped by the proxy, and a foreign `Origin` refused on a
//! mutation. Pure, so the table is testable without a proxy or a browser.

const std = @import("std");

/// The label the preview host is built from: `<id>.preview.<base>`.
pub const preview_label = "preview";

/// The preview host for a workspace. The base is the PREVIEW base domain, which
/// must not be a suffix of the app's own host — that is what makes the app's
/// cookies invisible to the tenant's dev server.
pub fn previewHost(allocator: std.mem.Allocator, workspace_id: []const u8, base: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, base, ".");
    if (trimmed.len == 0) return error.InvalidPreviewBase;
    return std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ workspace_id, preview_label, trimmed });
}

/// The last two labels. Deliberately naive: it is the *comparison* that matters
/// (two hosts are either same-site or not), and a wrong guess can only make the
/// check stricter for hosts the app never serves.
pub fn registrableDomain(host: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, host, ".");
    var labels: usize = 0;
    var i = trimmed.len;
    while (i > 0) {
        i -= 1;
        if (trimmed[i] != '.') continue;
        labels += 1;
        if (labels == 2) return trimmed[i + 1 ..];
    }
    return trimmed;
}

/// Same-site in the cookie sense: eTLD+1 equal, which is what `SameSite=Lax`
/// actually compares. Ports never enter into it.
pub fn sameSite(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(registrableDomain(a), registrableDomain(b));
}

/// True when `child` is `parent` itself or sits under it. A preview that is
/// same-site with the app defeats the whole point, so callers assert `!`.
pub fn isSubdomainOf(parent: []const u8, child: []const u8) bool {
    const p = std.mem.trim(u8, parent, ".");
    const c = std.mem.trim(u8, child, ".");
    if (p.len == 0 or c.len < p.len) return false;
    if (!std.ascii.endsWithIgnoreCase(c, p)) return false;
    if (c.len == p.len) return true;
    return c[c.len - p.len - 1] == '.';
}

/// A header the proxy never forwards INTO the guest. The tenant's dev server
/// must not see the user's session, and must not be handed a credential to
/// replay against the API.
const stripped_request_headers = [_][]const u8{
    "cookie",
    "authorization",
    "proxy-authorization",
    "x-api-key",
};

/// Hop-by-hop headers belong to one connection and must not be relayed
/// (RFC 9110 §7.6.1). `te`, `trailer` and `transfer-encoding` are handled by the
/// proxy's own framing, so they are not forwarded in either direction.
const hop_by_hop_headers = [_][]const u8{
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
};

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, name)) return true;
    }
    return false;
}

/// Whether a request header may cross into the guest.
pub fn requestHeaderForwarded(name: []const u8) bool {
    if (inList(&stripped_request_headers, name)) return false;
    if (inList(&hop_by_hop_headers, name)) return false;
    return true;
}

/// Whether a response header may cross back to the browser. A guest
/// `Set-Cookie` is allowed: the preview is its own registrable domain, so a
/// cookie it sets cannot be sent to the app.
pub fn responseHeaderForwarded(name: []const u8) bool {
    return !inList(&hop_by_hop_headers, name);
}

pub const OriginVerdict = enum {
    /// The request carried an origin this deployment serves.
    allowed,
    /// No `Origin` at all: a CLI, a test, or a same-origin form post. Allowed on
    /// a mutation only because the CSRF token is the second half of the rule.
    absent,
    /// An origin this deployment does not serve. Refused.
    foreign,

    pub fn refused(self: OriginVerdict) bool {
        return self == .foreign;
    }
};

/// The `Origin` allowlist decision for one request. `allowed` is the set of
/// origins the deployment serves, compared scheme+host+port, case-insensitively.
pub fn originVerdict(origin: ?[]const u8, allowed: []const []const u8) OriginVerdict {
    const value = origin orelse return .absent;
    const trimmed = std.mem.trim(u8, value, " ");
    if (trimmed.len == 0) return .absent;
    for (allowed) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, trimmed)) return .allowed;
    }
    return .foreign;
}

pub fn isMutatingMethod(method: []const u8) bool {
    const m = std.mem.trim(u8, method, " ");
    return std.ascii.eqlIgnoreCase(m, "POST") or
        std.ascii.eqlIgnoreCase(m, "PUT") or
        std.ascii.eqlIgnoreCase(m, "PATCH") or
        std.ascii.eqlIgnoreCase(m, "DELETE");
}

/// The policy a preview response carries: the tenant's page may not frame the
/// app, may not be framed by it, and may not phone home to the app's origin.
pub const preview_csp =
    "default-src 'self'; base-uri 'none'; form-action 'self'; " ++
    "frame-ancestors 'none'; connect-src 'self'; object-src 'none'";

/// The session cookie's attributes, so a browser only ever sends it to the app.
pub const session_cookie_attributes = "Path=/; Secure; HttpOnly; SameSite=Lax";

const testing = std.testing;

test "previewHost: the preview is not a subdomain of the app" {
    const allocator = testing.allocator;
    const app = "pabrik.example.com";
    const host = try previewHost(allocator, "ws_1", "preview.example.net");
    defer allocator.free(host);
    try testing.expectEqualStrings("ws_1.preview.preview.example.net", host);
    try testing.expect(!isSubdomainOf(app, host));
    try testing.expect(!sameSite(app, host));
}

test "previewHost: an empty base is refused rather than minted" {
    try testing.expectError(error.InvalidPreviewBase, previewHost(testing.allocator, "ws_1", ""));
    try testing.expectError(error.InvalidPreviewBase, previewHost(testing.allocator, "ws_1", "."));
}

test "registrableDomain and sameSite: eTLD+1 is what a cookie compares" {
    try testing.expectEqualStrings("example.com", registrableDomain("a.b.example.com"));
    try testing.expectEqualStrings("example.com", registrableDomain("example.com"));
    try testing.expectEqualStrings("localhost", registrableDomain("localhost"));

    try testing.expect(sameSite("app.example.com", "ws-1.example.com"));
    try testing.expect(sameSite("APP.Example.COM", "ws-1.example.com"));
    try testing.expect(!sameSite("app.example.com", "ws-1.preview.example.net"));
    try testing.expect(!sameSite("example.com", "example.org"));
}

test "isSubdomainOf: the boundary is a label, not a suffix" {
    try testing.expect(isSubdomainOf("example.com", "example.com"));
    try testing.expect(isSubdomainOf("example.com", "a.example.com"));
    try testing.expect(isSubdomainOf("example.com", "a.b.example.com"));

    try testing.expect(!isSubdomainOf("example.com", "notexample.com"));
    try testing.expect(!isSubdomainOf("example.com", "example.org"));
    try testing.expect(!isSubdomainOf("example.com", "com"));
}

test "request headers: the app's credentials never reach the guest" {
    try testing.expect(!requestHeaderForwarded("Cookie"));
    try testing.expect(!requestHeaderForwarded("cookie"));
    try testing.expect(!requestHeaderForwarded("Authorization"));
    try testing.expect(!requestHeaderForwarded("PROXY-AUTHORIZATION"));
    try testing.expect(!requestHeaderForwarded("X-Api-Key"));

    try testing.expect(requestHeaderForwarded("Accept"));
    try testing.expect(requestHeaderForwarded("Origin"));
    try testing.expect(requestHeaderForwarded("Content-Type"));
    try testing.expect(requestHeaderForwarded("X-Forwarded-For"));
}

test "hop-by-hop headers are relayed in neither direction" {
    try testing.expect(!requestHeaderForwarded("Connection"));
    try testing.expect(!requestHeaderForwarded("Upgrade"));
    try testing.expect(!responseHeaderForwarded("Transfer-Encoding"));
    try testing.expect(!responseHeaderForwarded("Keep-Alive"));
    try testing.expect(!responseHeaderForwarded("Proxy-Authenticate"));

    try testing.expect(responseHeaderForwarded("Content-Type"));
    try testing.expect(responseHeaderForwarded("Set-Cookie"));
}

test "originVerdict: a served origin passes, a foreign one is refused" {
    const allowed = [_][]const u8{ "https://pabrik.example.com", "http://127.0.0.1:8081" };
    try testing.expectEqual(OriginVerdict.allowed, originVerdict("https://pabrik.example.com", &allowed));
    try testing.expectEqual(OriginVerdict.allowed, originVerdict("HTTPS://PABRIK.EXAMPLE.COM", &allowed));
    try testing.expectEqual(OriginVerdict.absent, originVerdict(null, &allowed));
    try testing.expectEqual(OriginVerdict.absent, originVerdict("   ", &allowed));
    try testing.expectEqual(OriginVerdict.foreign, originVerdict("https://evil.example", &allowed));
    try testing.expectEqual(OriginVerdict.foreign, originVerdict("https://ws-1.preview.example.net", &allowed));
    try testing.expectEqual(OriginVerdict.foreign, originVerdict("null", &allowed));
}

test "originVerdict: only a foreign origin is refused, and only mutation consults it" {
    const allowed = [_][]const u8{"https://pabrik.example.com"};
    try testing.expect(!originVerdict("https://pabrik.example.com", &allowed).refused());
    try testing.expect(!originVerdict(null, &allowed).refused());
    try testing.expect(originVerdict("https://evil.example", &allowed).refused());

    try testing.expect(isMutatingMethod("POST"));
    try testing.expect(isMutatingMethod("delete"));
    try testing.expect(!isMutatingMethod("GET"));
    try testing.expect(!isMutatingMethod("HEAD"));
}

test "the preview policy pins framing and connection targets" {
    try testing.expect(std.mem.indexOf(u8, preview_csp, "frame-ancestors 'none'") != null);
    try testing.expect(std.mem.indexOf(u8, preview_csp, "connect-src 'self'") != null);
    try testing.expect(std.mem.indexOf(u8, session_cookie_attributes, "HttpOnly") != null);
    try testing.expect(std.mem.indexOf(u8, session_cookie_attributes, "SameSite=Lax") != null);
    try testing.expect(std.mem.indexOf(u8, session_cookie_attributes, "Domain=") == null);
}

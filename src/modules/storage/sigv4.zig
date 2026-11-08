//! AWS Signature Version 4, as S3 needs it. Pure functions only: no clock, no
//! socket, no allocator beyond the caller's. That is what makes the published
//! AWS test vectors usable as behaviour tests.

const std = @import("std");

pub const Credentials = struct {
    access_key: []const u8,
    secret_key: []const u8,
    region: []const u8,
    service: []const u8 = "s3",
};

pub const Header = struct {
    /// Lowercase. The signer does not fold case for you.
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    /// Uppercase verb: "GET", "PUT", "DELETE", "HEAD".
    method: []const u8,
    /// Host only — no scheme, no path, no port unless it is non-default.
    host: []const u8,
    /// Already URI-encoded, leading '/'.
    path: []const u8,
    /// Already sorted and encoded, no leading '?'. Empty when there is none.
    query: []const u8 = "",
    /// Headers to sign, EXCLUDING host / x-amz-date / x-amz-content-sha256,
    /// which the signer adds itself.
    headers: []const Header = &.{},
    /// Lowercase hex SHA-256 of the body. The empty body has a known digest.
    payload_sha256: []const u8,
    /// `YYYYMMDDTHHMMSSZ`.
    amz_date: []const u8,
};

/// Lowercase hex SHA-256 of the empty body. Every bodiless S3 verb signs this.
pub const EMPTY_PAYLOAD_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

pub const ALGORITHM = "AWS4-HMAC-SHA256";

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

/// URI-encode `path` for a canonical request, keeping '/' as a separator.
/// S3 wants each segment encoded exactly once — not twice, as the other AWS
/// services do.
pub fn uriEncodePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (path) |c| {
        if (c == '/' or isUnreserved(c)) {
            try out.append(allocator, c);
            continue;
        }
        try out.append(allocator, '%');
        try out.append(allocator, hex[c >> 4]);
        try out.append(allocator, hex[c & 0x0F]);
    }
    return out.toOwnedSlice(allocator);
}

fn hmac(key: []const u8, data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&out, data, key);
    return out;
}

fn sha256Hex(data: []const u8, out: *[64]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    out.* = std.fmt.bytesToHex(digest, .lower);
}

/// `YYYYMMDD` of an `YYYYMMDDTHHMMSSZ` stamp.
pub fn dateOf(amz_date: []const u8) []const u8 {
    return if (amz_date.len >= 8) amz_date[0..8] else amz_date;
}

/// `{date}/{region}/{service}/aws4_request`.
pub fn scope(
    allocator: std.mem.Allocator,
    creds: Credentials,
    amz_date: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}/aws4_request",
        .{ dateOf(amz_date), creds.region, creds.service },
    );
}

fn headerLessThan(_: void, a: Header, b: Header) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Every header the signature covers, sorted by name: the caller's extras plus
/// the three the signer owns.
fn signedHeaders(
    allocator: std.mem.Allocator,
    req: Request,
) ![]Header {
    var list: std.ArrayList(Header) = .empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, .{ .name = "host", .value = req.host });
    try list.append(allocator, .{ .name = "x-amz-content-sha256", .value = req.payload_sha256 });
    try list.append(allocator, .{ .name = "x-amz-date", .value = req.amz_date });
    for (req.headers) |h| try list.append(allocator, h);
    std.mem.sort(Header, list.items, {}, headerLessThan);
    return list.toOwnedSlice(allocator);
}

/// The canonical request: the exact bytes AWS hashes into the string to sign.
pub fn canonicalRequest(allocator: std.mem.Allocator, req: Request) ![]u8 {
    const headers = try signedHeaders(allocator, req);
    defer allocator.free(headers);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, req.method);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, req.path);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, req.query);
    try out.append(allocator, '\n');

    for (headers) |h| {
        try out.appendSlice(allocator, h.name);
        try out.append(allocator, ':');
        try out.appendSlice(allocator, h.value);
        try out.append(allocator, '\n');
    }
    try out.append(allocator, '\n');

    for (headers, 0..) |h, i| {
        if (i > 0) try out.append(allocator, ';');
        try out.appendSlice(allocator, h.name);
    }
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, req.payload_sha256);

    return out.toOwnedSlice(allocator);
}

/// The string to sign: algorithm, stamp, scope, and the canonical request's
/// digest.
pub fn stringToSign(
    allocator: std.mem.Allocator,
    creds: Credentials,
    req: Request,
    canonical_request: []const u8,
) ![]u8 {
    var digest: [64]u8 = undefined;
    sha256Hex(canonical_request, &digest);
    const request_scope = try scope(allocator, creds, req.amz_date);
    defer allocator.free(request_scope);

    return std.fmt.allocPrint(
        allocator,
        "{s}\n{s}\n{s}\n{s}",
        .{ ALGORITHM, req.amz_date, request_scope, digest },
    );
}

/// The derived signing key: HMAC chain from the secret through date, region and
/// service.
pub fn signingKey(
    secret_key: []const u8,
    date: []const u8,
    region: []const u8,
    service: []const u8,
) [32]u8 {
    var prefixed_buf: [512]u8 = undefined;
    const prefixed = std.fmt.bufPrint(&prefixed_buf, "AWS4{s}", .{secret_key}) catch
        return hmac(secret_key, date);
    const k_date = hmac(prefixed, date);
    const k_region = hmac(&k_date, region);
    const k_service = hmac(&k_region, service);
    return hmac(&k_service, "aws4_request");
}

/// Lowercase hex signature for `req`.
pub fn signature(
    allocator: std.mem.Allocator,
    creds: Credentials,
    req: Request,
) ![64]u8 {
    const canonical = try canonicalRequest(allocator, req);
    defer allocator.free(canonical);
    const to_sign = try stringToSign(allocator, creds, req, canonical);
    defer allocator.free(to_sign);

    const key = signingKey(creds.secret_key, dateOf(req.amz_date), creds.region, creds.service);
    const mac = hmac(&key, to_sign);
    return std.fmt.bytesToHex(mac, .lower);
}

/// The `Authorization` header value for `req`.
pub fn authorization(
    allocator: std.mem.Allocator,
    creds: Credentials,
    req: Request,
) ![]u8 {
    const headers = try signedHeaders(allocator, req);
    defer allocator.free(headers);

    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(allocator);
    for (headers, 0..) |h, i| {
        if (i > 0) try names.append(allocator, ';');
        try names.appendSlice(allocator, h.name);
    }

    const request_scope = try scope(allocator, creds, req.amz_date);
    defer allocator.free(request_scope);

    const sig = try signature(allocator, creds, req);

    return std.fmt.allocPrint(
        allocator,
        "{s} Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{ ALGORITHM, creds.access_key, request_scope, names.items, sig },
    );
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// The credentials AWS publishes with every S3 signing example.
const aws_example = Credentials{
    .access_key = "AKIAIOSFODNN7EXAMPLE",
    .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    .region = "us-east-1",
};

test "uriEncodePath: unreserved characters and separators pass through" {
    const alloc = testing.allocator;
    const out = try uriEncodePath(alloc, "/ws/ws_1/documents/doc_a/abc.md");
    defer alloc.free(out);
    try testing.expectEqualStrings("/ws/ws_1/documents/doc_a/abc.md", out);
}

test "uriEncodePath: a dollar sign is encoded once, not twice" {
    const alloc = testing.allocator;
    const out = try uriEncodePath(alloc, "/test$file.text");
    defer alloc.free(out);
    try testing.expectEqualStrings("/test%24file.text", out);
}

test "uriEncodePath: a space and a plus are encoded with uppercase hex" {
    const alloc = testing.allocator;
    const out = try uriEncodePath(alloc, "/a b+c");
    defer alloc.free(out);
    try testing.expectEqualStrings("/a%20b%2Bc", out);
}

test "uriEncodePath: a tilde stays literal, as the unreserved set requires" {
    const alloc = testing.allocator;
    const out = try uriEncodePath(alloc, "/a~b");
    defer alloc.free(out);
    try testing.expectEqualStrings("/a~b", out);
}

test "dateOf: the first eight characters of the stamp" {
    try testing.expectEqualStrings("20130524", dateOf("20130524T000000Z"));
    try testing.expectEqualStrings("20130524", dateOf("20130524"));
}

test "scope: date, region, service and the terminator" {
    const alloc = testing.allocator;
    const out = try scope(alloc, aws_example, "20130524T000000Z");
    defer alloc.free(out);
    try testing.expectEqualStrings("20130524/us-east-1/s3/aws4_request", out);
}

test "canonicalRequest: the AWS GET Object example matches the published bytes" {
    const alloc = testing.allocator;
    const req = Request{
        .method = "GET",
        .host = "examplebucket.s3.amazonaws.com",
        .path = "/test.txt",
        .headers = &.{.{ .name = "range", .value = "bytes=0-9" }},
        .payload_sha256 = EMPTY_PAYLOAD_SHA256,
        .amz_date = "20130524T000000Z",
    };

    const out = try canonicalRequest(alloc, req);
    defer alloc.free(out);

    const expected =
        "GET\n" ++
        "/test.txt\n" ++
        "\n" ++
        "host:examplebucket.s3.amazonaws.com\n" ++
        "range:bytes=0-9\n" ++
        "x-amz-content-sha256:" ++ EMPTY_PAYLOAD_SHA256 ++ "\n" ++
        "x-amz-date:20130524T000000Z\n" ++
        "\n" ++
        "host;range;x-amz-content-sha256;x-amz-date\n" ++
        EMPTY_PAYLOAD_SHA256;
    try testing.expectEqualStrings(expected, out);
}

test "signature: the AWS GET Object example matches the published signature" {
    const alloc = testing.allocator;
    const req = Request{
        .method = "GET",
        .host = "examplebucket.s3.amazonaws.com",
        .path = "/test.txt",
        .headers = &.{.{ .name = "range", .value = "bytes=0-9" }},
        .payload_sha256 = EMPTY_PAYLOAD_SHA256,
        .amz_date = "20130524T000000Z",
    };

    const sig = try signature(alloc, aws_example, req);
    try testing.expectEqualStrings(
        "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
        &sig,
    );
}

test "signature: the AWS PUT Object example matches the published signature" {
    const alloc = testing.allocator;
    const body = "Welcome to Amazon S3.";
    var payload: [64]u8 = undefined;
    sha256Hex(body, &payload);

    const req = Request{
        .method = "PUT",
        .host = "examplebucket.s3.amazonaws.com",
        .path = "/test%24file.text",
        .headers = &.{
            .{ .name = "date", .value = "Fri, 24 May 2013 00:00:00 GMT" },
            .{ .name = "x-amz-storage-class", .value = "REDUCED_REDUNDANCY" },
        },
        .payload_sha256 = &payload,
        .amz_date = "20130524T000000Z",
    };

    const sig = try signature(alloc, aws_example, req);
    try testing.expectEqualStrings(
        "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd",
        &sig,
    );
}

test "authorization: the header names the credential, the signed headers and the signature" {
    const alloc = testing.allocator;
    const req = Request{
        .method = "GET",
        .host = "examplebucket.s3.amazonaws.com",
        .path = "/test.txt",
        .headers = &.{.{ .name = "range", .value = "bytes=0-9" }},
        .payload_sha256 = EMPTY_PAYLOAD_SHA256,
        .amz_date = "20130524T000000Z",
    };

    const out = try authorization(alloc, aws_example, req);
    defer alloc.free(out);

    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " ++
            "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " ++
            "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
        out,
    );
}

test "canonicalRequest: headers are sorted by name regardless of input order" {
    const alloc = testing.allocator;
    const forward = Request{
        .method = "GET",
        .host = "h",
        .path = "/p",
        .headers = &.{
            .{ .name = "a-first", .value = "1" },
            .{ .name = "z-last", .value = "2" },
        },
        .payload_sha256 = EMPTY_PAYLOAD_SHA256,
        .amz_date = "20130524T000000Z",
    };
    const reversed = Request{
        .method = "GET",
        .host = "h",
        .path = "/p",
        .headers = &.{
            .{ .name = "z-last", .value = "2" },
            .{ .name = "a-first", .value = "1" },
        },
        .payload_sha256 = EMPTY_PAYLOAD_SHA256,
        .amz_date = "20130524T000000Z",
    };

    const a = try canonicalRequest(alloc, forward);
    defer alloc.free(a);
    const b = try canonicalRequest(alloc, reversed);
    defer alloc.free(b);
    try testing.expectEqualStrings(a, b);
}

test "signature: a different secret produces a different signature" {
    const alloc = testing.allocator;
    const req = Request{
        .method = "GET",
        .host = "examplebucket.s3.amazonaws.com",
        .path = "/test.txt",
        .payload_sha256 = EMPTY_PAYLOAD_SHA256,
        .amz_date = "20130524T000000Z",
    };

    const good = try signature(alloc, aws_example, req);
    const other = Credentials{
        .access_key = aws_example.access_key,
        .secret_key = "not-the-secret",
        .region = aws_example.region,
    };
    const bad = try signature(alloc, other, req);
    try testing.expect(!std.mem.eql(u8, &good, &bad));
}

test "signature: a different region produces a different signature" {
    const alloc = testing.allocator;
    const req = Request{
        .method = "GET",
        .host = "examplebucket.s3.amazonaws.com",
        .path = "/test.txt",
        .payload_sha256 = EMPTY_PAYLOAD_SHA256,
        .amz_date = "20130524T000000Z",
    };

    const east = try signature(alloc, aws_example, req);
    const west = Credentials{
        .access_key = aws_example.access_key,
        .secret_key = aws_example.secret_key,
        .region = "us-west-2",
    };
    const other = try signature(alloc, west, req);
    try testing.expect(!std.mem.eql(u8, &east, &other));
}

test "signingKey: the same inputs derive the same key, and a new date does not" {
    const a = signingKey("secret", "20130524", "us-east-1", "s3");
    const b = signingKey("secret", "20130524", "us-east-1", "s3");
    const c = signingKey("secret", "20130525", "us-east-1", "s3");
    try testing.expectEqualSlices(u8, &a, &b);
    try testing.expect(!std.mem.eql(u8, &a, &c));
}

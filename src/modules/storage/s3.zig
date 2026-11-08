//! S3 backend for the object store, aimed at rustfs (and any other
//! S3-compatible server). Path-style addressing, SigV4, four verbs.

const std = @import("std");
const storage = @import("storage.zig");
const sigv4 = @import("sigv4.zig");
const transport_mod = @import("transport.zig");

pub const Config = struct {
    /// Scheme, host and optional port. No trailing slash, no bucket.
    endpoint: []const u8,
    bucket: []const u8,
    region: []const u8 = "us-east-1",
    access_key: []const u8,
    secret_key: []const u8,
};

pub const S3Storage = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    transport: transport_mod.Transport,
    /// Fixed `YYYYMMDDTHHMMSSZ` stamp. Null reads the real clock; tests set it
    /// so a signature is reproducible.
    amz_date_override: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
        transport: transport_mod.Transport,
    ) S3Storage {
        return .{ .allocator = allocator, .io = io, .config = config, .transport = transport };
    }

    pub fn asStorage(self: *S3Storage) storage.Storage {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = storage.Storage.VTable{
        .put = put,
        .get = get,
        .delete = delete,
        .stat = stat,
    };

    fn credentials(self: *const S3Storage) sigv4.Credentials {
        return .{
            .access_key = self.config.access_key,
            .secret_key = self.config.secret_key,
            .region = self.config.region,
        };
    }

    fn amzDate(self: *const S3Storage, buf: *[16]u8) []const u8 {
        if (self.amz_date_override) |fixed| return fixed;
        return amzDateNow(self.io, buf);
    }

    /// Sign and dispatch one request. Every allocation is freed before return;
    /// the response body is the caller's.
    fn send(
        self: *S3Storage,
        allocator: std.mem.Allocator,
        method: transport_mod.Method,
        key: []const u8,
        body: []const u8,
        payload_sha256: []const u8,
    ) transport_mod.Error!transport_mod.Response {
        const raw_path = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ self.config.bucket, key });
        defer allocator.free(raw_path);
        const path = try sigv4.uriEncodePath(allocator, raw_path);
        defer allocator.free(path);

        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ endpointBase(self.config.endpoint), path });
        defer allocator.free(url);

        var date_buf: [16]u8 = undefined;
        const amz_date = self.amzDate(&date_buf);

        const auth = try sigv4.authorization(allocator, self.credentials(), .{
            .method = method.asString(),
            .host = endpointHost(self.config.endpoint),
            .path = path,
            .payload_sha256 = payload_sha256,
            .amz_date = amz_date,
        });
        defer allocator.free(auth);

        const headers = [_]transport_mod.Header{
            .{ .name = "x-amz-content-sha256", .value = payload_sha256 },
            .{ .name = "x-amz-date", .value = amz_date },
            .{ .name = "authorization", .value = auth },
        };

        return self.transport.send(allocator, .{
            .method = method,
            .url = url,
            .headers = &headers,
            .body = body,
        });
    }

    fn put(ptr: *anyopaque, key: []const u8, body: []const u8) storage.Error!void {
        const self: *S3Storage = @ptrCast(@alignCast(ptr));
        if (storage.invalidKeyReason(key) != null) return error.InvalidKey;
        if (body.len > storage.MAX_OBJECT_BYTES) return error.IoFailed;

        var digest: [64]u8 = undefined;
        storage.sha256Hex(body, &digest);

        const resp = self.send(self.allocator, .put, key, body, &digest) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NetworkFailed => return error.IoFailed,
        };
        defer resp.deinit(self.allocator);

        if (resp.status >= 200 and resp.status < 300) return;
        return error.IoFailed;
    }

    fn get(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) storage.Error![]u8 {
        const self: *S3Storage = @ptrCast(@alignCast(ptr));
        if (storage.invalidKeyReason(key) != null) return error.InvalidKey;

        const resp = self.send(allocator, .get, key, "", sigv4.EMPTY_PAYLOAD_SHA256) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NetworkFailed => return error.IoFailed,
        };

        if (resp.status == 404) {
            resp.deinit(allocator);
            return error.NotFound;
        }
        if (resp.status != 200) {
            resp.deinit(allocator);
            return error.IoFailed;
        }
        return resp.body;
    }

    fn delete(ptr: *anyopaque, key: []const u8) storage.Error!void {
        const self: *S3Storage = @ptrCast(@alignCast(ptr));
        if (storage.invalidKeyReason(key) != null) return error.InvalidKey;

        const resp = self.send(self.allocator, .delete, key, "", sigv4.EMPTY_PAYLOAD_SHA256) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NetworkFailed => return error.IoFailed,
        };
        defer resp.deinit(self.allocator);

        if (resp.status == 404) return error.NotFound;
        if (resp.status >= 200 and resp.status < 300) return;
        return error.IoFailed;
    }

    fn stat(ptr: *anyopaque, key: []const u8) storage.Error!storage.Stat {
        const self: *S3Storage = @ptrCast(@alignCast(ptr));
        if (storage.invalidKeyReason(key) != null) return error.InvalidKey;

        const resp = self.send(self.allocator, .head, key, "", sigv4.EMPTY_PAYLOAD_SHA256) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NetworkFailed => return error.IoFailed,
        };
        defer resp.deinit(self.allocator);

        if (resp.status == 404) return error.NotFound;
        if (resp.status != 200) return error.IoFailed;
        return .{ .bytes = resp.content_length orelse 0 };
    }
};

pub const EnsureBucketError = error{ ServiceNotReady, IoFailed, OutOfMemory };

/// Create the bucket if it is not there: a supervised rustfs starts empty, so
/// the first write would fail with NoSuchBucket. `409` is success, and `503`
/// means rustfs is still bringing its IAM and storage quorum up.
pub fn ensureBucket(self: *S3Storage) EnsureBucketError!void {
    const url = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
        endpointBase(self.config.endpoint),
        self.config.bucket,
    }) catch return error.OutOfMemory;
    defer self.allocator.free(url);

    var date_buf: [16]u8 = undefined;
    const amz_date = self.amzDate(&date_buf);

    const auth = sigv4.authorization(self.allocator, self.credentials(), .{
        .method = "PUT",
        .host = endpointHost(self.config.endpoint),
        .path = try bucketPath(self.allocator, self.config.bucket),
        .payload_sha256 = sigv4.EMPTY_PAYLOAD_SHA256,
        .amz_date = amz_date,
    }) catch return error.OutOfMemory;
    defer self.allocator.free(auth);

    const headers = [_]transport_mod.Header{
        .{ .name = "x-amz-content-sha256", .value = sigv4.EMPTY_PAYLOAD_SHA256 },
        .{ .name = "x-amz-date", .value = amz_date },
        .{ .name = "authorization", .value = auth },
    };

    const resp = self.transport.send(self.allocator, .{
        .method = .put,
        .url = url,
        .headers = &headers,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NetworkFailed => return error.IoFailed,
    };
    defer resp.deinit(self.allocator);

    if (resp.status >= 200 and resp.status < 300) return;
    if (resp.status == 409) return;
    if (resp.status == 503) return error.ServiceNotReady;
    return error.IoFailed;
}

/// `/{bucket}`, URI-encoded, for the canonical request.
fn bucketPath(allocator: std.mem.Allocator, bucket: []const u8) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, "/{s}", .{bucket});
    defer allocator.free(raw);
    return sigv4.uriEncodePath(allocator, raw);
}

/// `https://host:port/path` → `host:port`.
pub fn endpointHost(endpoint: []const u8) []const u8 {
    var rest = endpoint;
    if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest["https://".len..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest["http://".len..];
    }
    if (std.mem.indexOfScalar(u8, rest, '/')) |i| rest = rest[0..i];
    return rest;
}

/// The endpoint with any trailing separators removed.
pub fn endpointBase(endpoint: []const u8) []const u8 {
    var end = endpoint.len;
    while (end > 0 and endpoint[end - 1] == '/') end -= 1;
    return endpoint[0..end];
}

/// `YYYYMMDDTHHMMSSZ` for the current UTC instant.
pub fn amzDateNow(io: std.Io, buf: *[16]u8) []const u8 {
    const nanos = std.Io.Clock.real.now(io).nanoseconds;
    const secs: u64 = if (nanos <= 0) 0 else @intCast(@divTrunc(nanos, std.time.ns_per_s));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();

    writeDigits(buf[0..4], year_day.year);
    writeDigits(buf[4..6], month_day.month.numeric());
    writeDigits(buf[6..8], month_day.day_index + 1);
    buf[8] = 'T';
    writeDigits(buf[9..11], day_seconds.getHoursIntoDay());
    writeDigits(buf[11..13], day_seconds.getMinutesIntoHour());
    writeDigits(buf[13..15], day_seconds.getSecondsIntoMinute());
    buf[15] = 'Z';
    return buf;
}

/// Zero-padded decimal into `out`, right-aligned. `out.len` is the width.
fn writeDigits(out: []u8, value: anytype) void {
    var v: u32 = @intCast(value);
    var i = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const test_config = Config{
    .endpoint = "http://127.0.0.1:9000",
    .bucket = "pabrik",
    .access_key = "AKIAIOSFODNN7EXAMPLE",
    .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
};

const test_date = "20130524T000000Z";

/// One request the backend made, copied so it outlives the caller's buffers.
const Seen = struct {
    method: transport_mod.Method,
    url: []u8,
    body: []u8,
    authorization: []u8,
    amz_date: []u8,
    content_sha256: []u8,
};

/// A transport that records what it was asked to send and replies with a canned
/// status. The fake is the seam: no socket, no clock, no bucket.
const FakeTransport = struct {
    allocator: std.mem.Allocator,
    status: u16 = 200,
    body: []const u8 = "",
    content_length: ?u64 = null,
    seen: std.ArrayList(Seen) = .empty,

    fn init(allocator: std.mem.Allocator) FakeTransport {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FakeTransport) void {
        for (self.seen.items) |s| {
            self.allocator.free(s.url);
            self.allocator.free(s.body);
            self.allocator.free(s.authorization);
            self.allocator.free(s.amz_date);
            self.allocator.free(s.content_sha256);
        }
        self.seen.deinit(self.allocator);
    }

    fn asTransport(self: *FakeTransport) transport_mod.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = transport_mod.Transport.VTable{ .send = send };

    fn send(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        req: transport_mod.Request,
    ) transport_mod.Error!transport_mod.Response {
        const self: *FakeTransport = @ptrCast(@alignCast(ptr));

        var auth: []const u8 = "";
        var amz_date: []const u8 = "";
        var content_sha256: []const u8 = "";
        for (req.headers) |h| {
            if (std.mem.eql(u8, h.name, "authorization")) auth = h.value;
            if (std.mem.eql(u8, h.name, "x-amz-date")) amz_date = h.value;
            if (std.mem.eql(u8, h.name, "x-amz-content-sha256")) content_sha256 = h.value;
        }

        self.seen.append(self.allocator, .{
            .method = req.method,
            .url = self.allocator.dupe(u8, req.url) catch return error.OutOfMemory,
            .body = self.allocator.dupe(u8, req.body) catch return error.OutOfMemory,
            .authorization = self.allocator.dupe(u8, auth) catch return error.OutOfMemory,
            .amz_date = self.allocator.dupe(u8, amz_date) catch return error.OutOfMemory,
            .content_sha256 = self.allocator.dupe(u8, content_sha256) catch return error.OutOfMemory,
        }) catch return error.OutOfMemory;

        return .{
            .status = self.status,
            .body = allocator.dupe(u8, self.body) catch return error.OutOfMemory,
            .content_length = self.content_length,
        };
    }
};

/// Heap-allocated so `store.transport.ptr` can point at `fake` and stay valid:
/// a by-value fixture would leave the transport pointing at a dead stack slot.
const Fixture = struct {
    fake: FakeTransport,
    store: S3Storage,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const fx = try allocator.create(Fixture);
        fx.fake = FakeTransport.init(allocator);
        fx.store = S3Storage.init(allocator, testing.io, test_config, fx.fake.asTransport());
        return fx;
    }

    fn deinit(self: *Fixture) void {
        const allocator = self.fake.allocator;
        self.fake.deinit();
        allocator.destroy(self);
    }
};

test "endpointHost: the scheme and any path are stripped" {
    try testing.expectEqualStrings("127.0.0.1:9000", endpointHost("http://127.0.0.1:9000"));
    try testing.expectEqualStrings("s3.amazonaws.com", endpointHost("https://s3.amazonaws.com/"));
    try testing.expectEqualStrings("host", endpointHost("https://host/a/b"));
    try testing.expectEqualStrings("host", endpointHost("host"));
}

test "endpointBase: trailing separators are removed, the scheme is kept" {
    try testing.expectEqualStrings("http://h:9000", endpointBase("http://h:9000/"));
    try testing.expectEqualStrings("http://h:9000", endpointBase("http://h:9000///"));
    try testing.expectEqualStrings("http://h:9000", endpointBase("http://h:9000"));
}

test "amzDateNow: the stamp has the shape SigV4 requires" {
    var buf: [16]u8 = undefined;
    const stamp = amzDateNow(testing.io, &buf);
    try testing.expectEqual(@as(usize, 16), stamp.len);
    try testing.expectEqual(@as(u8, 'T'), stamp[8]);
    try testing.expectEqual(@as(u8, 'Z'), stamp[15]);
    for (stamp[0..8]) |c| try testing.expect(std.ascii.isDigit(c));
}

test "s3 put: sends a PUT to the path-style object URL with a signed request" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    fx.store.amz_date_override = test_date;

    try fx.store.asStorage().put("ws/ws_1/documents/doc_a/abc.md", "# Plan\n");

    try testing.expectEqual(@as(usize, 1), fx.fake.seen.items.len);
    const seen = fx.fake.seen.items[0];
    try testing.expectEqual(transport_mod.Method.put, seen.method);
    try testing.expectEqualStrings(
        "http://127.0.0.1:9000/pabrik/ws/ws_1/documents/doc_a/abc.md",
        seen.url,
    );
    try testing.expectEqualStrings("# Plan\n", seen.body);
    try testing.expectEqualStrings(test_date, seen.amz_date);
    try testing.expect(std.mem.startsWith(u8, seen.authorization, "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request"));
}

test "s3 put: the payload hash is the digest of the body, not the empty digest" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    fx.store.amz_date_override = test_date;

    try fx.store.asStorage().put("k.md", "abc");

    var expected: [64]u8 = undefined;
    storage.sha256Hex("abc", &expected);
    try testing.expectEqualStrings(&expected, fx.fake.seen.items[0].content_sha256);
}

test "s3 put: a 2xx is success and a 5xx is IoFailed" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    fx.store.amz_date_override = test_date;

    fx.fake.status = 200;
    try fx.store.asStorage().put("k.md", "body");

    fx.fake.status = 500;
    try testing.expectError(error.IoFailed, fx.store.asStorage().put("k.md", "body"));
}

test "s3 get: a 200 returns the body the server sent" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    fx.store.amz_date_override = test_date;
    fx.fake.status = 200;
    fx.fake.body = "# Release plan\n";

    const body = try fx.store.asStorage().get(alloc, "k.md");
    defer alloc.free(body);

    try testing.expectEqualStrings("# Release plan\n", body);
    try testing.expectEqual(transport_mod.Method.get, fx.fake.seen.items[0].method);
    try testing.expectEqualStrings(sigv4.EMPTY_PAYLOAD_SHA256, fx.fake.seen.items[0].content_sha256);
}

test "s3 get: a 404 is NotFound and a 500 is IoFailed" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    fx.store.amz_date_override = test_date;

    fx.fake.status = 404;
    try testing.expectError(error.NotFound, fx.store.asStorage().get(alloc, "k.md"));

    fx.fake.status = 500;
    try testing.expectError(error.IoFailed, fx.store.asStorage().get(alloc, "k.md"));
}

test "s3 delete: a 204 is success, a 404 is NotFound, a 500 is IoFailed" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    fx.store.amz_date_override = test_date;

    fx.fake.status = 204;
    try fx.store.asStorage().delete("k.md");
    try testing.expectEqual(transport_mod.Method.delete, fx.fake.seen.items[0].method);

    fx.fake.status = 404;
    try testing.expectError(error.NotFound, fx.store.asStorage().delete("k.md"));

    fx.fake.status = 500;
    try testing.expectError(error.IoFailed, fx.store.asStorage().delete("k.md"));
}

test "s3 stat: a HEAD reports the Content-Length the server sent" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    fx.store.amz_date_override = test_date;
    fx.fake.status = 200;
    fx.fake.content_length = 24;

    const info = try fx.store.asStorage().stat("k.md");
    try testing.expectEqual(@as(u64, 24), info.bytes);
    try testing.expectEqual(transport_mod.Method.head, fx.fake.seen.items[0].method);
}

test "s3 stat: a 404 is NotFound" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    fx.store.amz_date_override = test_date;
    fx.fake.status = 404;

    try testing.expectError(error.NotFound, fx.store.asStorage().stat("k.md"));
}

test "s3: a traversal key is rejected before any request is sent" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    fx.store.amz_date_override = test_date;

    try testing.expectError(error.InvalidKey, fx.store.asStorage().put("../escape.md", "x"));
    try testing.expectError(error.InvalidKey, fx.store.asStorage().get(alloc, "../escape.md"));
    try testing.expectError(error.InvalidKey, fx.store.asStorage().delete("../escape.md"));
    try testing.expectError(error.InvalidKey, fx.store.asStorage().stat("../escape.md"));
    try testing.expectEqual(@as(usize, 0), fx.fake.seen.items.len);
}

test "s3: a body over the cap is rejected before any request is sent" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    fx.store.amz_date_override = test_date;

    const big = try alloc.alloc(u8, storage.MAX_OBJECT_BYTES + 1);
    defer alloc.free(big);
    @memset(big, 'x');

    try testing.expectError(error.IoFailed, fx.store.asStorage().put("big.md", big));
    try testing.expectEqual(@as(usize, 0), fx.fake.seen.items.len);
}

test "s3: a key with a character needing encoding is encoded once in the URL" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    fx.store.amz_date_override = test_date;

    try fx.store.asStorage().put("a$b.md", "x");
    try testing.expectEqualStrings("http://127.0.0.1:9000/pabrik/a%24b.md", fx.fake.seen.items[0].url);
}

test "s3: a network failure surfaces as IoFailed, not a panic" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    fx.store.amz_date_override = test_date;

    const Failing = struct {
        fn send(_: *anyopaque, _: std.mem.Allocator, _: transport_mod.Request) transport_mod.Error!transport_mod.Response {
            return error.NetworkFailed;
        }
        const vtable = transport_mod.Transport.VTable{ .send = send };
    };
    var marker: u8 = 0;
    fx.store.transport = .{ .ptr = &marker, .vtable = &Failing.vtable };

    try testing.expectError(error.IoFailed, fx.store.asStorage().put("k.md", "body"));
    try testing.expectError(error.IoFailed, fx.store.asStorage().get(alloc, "k.md"));
    try testing.expectError(error.IoFailed, fx.store.asStorage().delete("k.md"));
    try testing.expectError(error.IoFailed, fx.store.asStorage().stat("k.md"));
}

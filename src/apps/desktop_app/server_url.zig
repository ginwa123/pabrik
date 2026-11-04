const std = @import("std");

pub const Change = union(enum) {
    applied: []const u8,
    rejected: []const u8,

    pub fn deinit(self: Change, allocator: std.mem.Allocator) void {
        switch (self) {
            .applied => |url| allocator.free(url),
            .rejected => {},
        }
    }
};

pub const message = struct {
    pub const empty = "Enter your server address.";
    pub const malformed = "That is not a server address.";
    pub const scheme = "Pabrik API must use HTTP or HTTPS.";
    pub const host = "Include the domain, for example pabrik.example.com.";
    pub const credentials = "Remove the username and password from the address.";
    pub const query = "A server address cannot have a ?query or #fragment.";
};

pub fn normalize(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!Change {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .{ .rejected = message.empty };

    var scheme: []const u8 = "https";
    var rest: []const u8 = trimmed;
    if (schemeSeparator(trimmed)) |end| {
        scheme = trimmed[0..end];
        rest = trimmed[end + 3 ..];
    }
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) {
        return .{ .rejected = message.scheme };
    }
    const lowercase_scheme: []const u8 = if (std.ascii.eqlIgnoreCase(scheme, "http")) "http" else "https";

    if (hasWhitespace(rest)) return .{ .rejected = message.malformed };

    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    const tail = rest[authority_end..];

    if (std.mem.indexOfScalar(u8, authority, '@') != null) {
        return .{ .rejected = message.credentials };
    }
    if (std.mem.indexOfAny(u8, tail, "?#") != null) {
        return .{ .rejected = message.query };
    }

    if (authority.len == 0) return .{ .rejected = message.host };
    const target = splitHostPort(authority) orelse return .{ .rejected = message.malformed };
    if (target.host.len == 0) return .{ .rejected = message.host };
    if (!hostLooksValid(target.host)) return .{ .rejected = message.malformed };

    const host = try lowercase(allocator, target.host);
    defer allocator.free(host);
    const path = std.mem.trimEnd(u8, tail, "/");

    const url = if (target.port) |port|
        try std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{ lowercase_scheme, host, port, path })
    else
        try std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ lowercase_scheme, host, path });
    return .{ .applied = url };
}

fn schemeSeparator(text: []const u8) ?usize {
    const marker = std.mem.indexOf(u8, text, "://") orelse return null;
    if (marker == 0) return null;
    if (!std.ascii.isAlphabetic(text[0])) return null;
    for (text[0..marker]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return null;
    }
    return marker;
}

fn hasWhitespace(text: []const u8) bool {
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) return true;
    }
    return false;
}

const HostPort = struct {
    host: []const u8,
    port: ?u16,
};

fn splitHostPort(authority: []const u8) ?HostPort {
    if (authority.len == 0) return null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        const host = authority[0 .. close + 1];
        const after = authority[close + 1 ..];
        if (after.len == 0) return .{ .host = host, .port = null };
        if (after[0] != ':') return null;
        const port = parsePort(after[1..]) orelse return null;
        return .{ .host = host, .port = port };
    }
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse
        return .{ .host = authority, .port = null };
    const host = authority[0..colon];
    if (host.len == 0) return null;
    if (std.mem.indexOfScalar(u8, host, ':') != null) return null;
    const port = parsePort(authority[colon + 1 ..]) orelse return null;
    return .{ .host = host, .port = port };
}

fn parsePort(text: []const u8) ?u16 {
    if (text.len == 0) return null;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const port = std.fmt.parseInt(u16, text, 10) catch return null;
    if (port == 0) return null;
    return port;
}

fn hostLooksValid(host: []const u8) bool {
    if (host.len == 0) return false;
    for (host) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '[', ']', ':' => {},
            else => return false,
        }
    }
    return true;
}

fn lowercase(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

const testing = std.testing;

fn expectApplied(expected: []const u8, raw: []const u8) !void {
    const change = try normalize(testing.allocator, raw);
    defer change.deinit(testing.allocator);
    switch (change) {
        .applied => |url| try testing.expectEqualStrings(expected, url),
        .rejected => return error.ExpectedApplied,
    }
}

fn expectRejected(expected: []const u8, raw: []const u8) !void {
    const change = try normalize(testing.allocator, raw);
    defer change.deinit(testing.allocator);
    switch (change) {
        .applied => return error.ExpectedRejected,
        .rejected => |reason| try testing.expectEqualStrings(expected, reason),
    }
}

test "a host with no scheme is reached over https" {
    try expectApplied("https://pabrik.example.com", "pabrik.example.com");
}

test "an explicit http scheme is kept for a server on the local network" {
    try expectApplied("http://192.168.1.20:8081", "http://192.168.1.20:8081");
}

test "surrounding whitespace from a paste is dropped" {
    try expectApplied("https://pabrik.example.com", "  https://pabrik.example.com\t");
}

test "the scheme and host are reported in lowercase" {
    try expectApplied("https://pabrik.example.com", "HTTPS://Pabrik.Example.COM");
}

test "a trailing slash is dropped so API paths can be appended" {
    try expectApplied("https://pabrik.example.com", "https://pabrik.example.com/");
}

test "a reverse-proxy path is kept without its trailing slash" {
    try expectApplied("https://example.com/pabrik", "https://example.com/pabrik/");
}

test "a non-default port survives normalization" {
    try expectApplied("https://pabrik.example.com:8443", "pabrik.example.com:8443/");
}

test "a bracketed IPv6 host survives normalization" {
    try expectApplied("http://[::1]:8081", "http://[::1]:8081");
}

test "an empty field is rejected with the sentence Android shows" {
    try expectRejected(message.empty, "   ");
}

test "a non-http scheme is rejected" {
    try expectRejected(message.scheme, "ftp://pabrik.example.com");
}

test "a URL without a host is rejected" {
    try expectRejected(message.host, "https://");
}

test "credentials in the address are rejected" {
    try expectRejected(message.credentials, "https://someone:secret@pabrik.example.com");
}

test "a query or fragment is rejected" {
    try expectRejected(message.query, "https://pabrik.example.com/?workspace=1");
    try expectRejected(message.query, "https://pabrik.example.com/#top");
}

test "a port that is not a number is rejected" {
    try expectRejected(message.malformed, "https://pabrik.example.com:http");
}

test "a port above the u16 range is rejected" {
    try expectRejected(message.malformed, "https://pabrik.example.com:70000");
}

test "a host with a space is rejected" {
    try expectRejected(message.malformed, "https://pabrik example.com");
}

test "an unbracketed IPv6 address is rejected" {
    try expectRejected(message.malformed, "https://::1:8081");
}

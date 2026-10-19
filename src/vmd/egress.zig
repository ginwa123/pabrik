//! The egress deny list, as one pure table: which address a workspace VM may
//! never dial, and the resolver's half of the same policy. A name is never
//! trusted — the address that is *dialled* is the address that is classified.

const std = @import("std");

/// Why an address is refused. `allow` is the only verdict that permits a dial;
/// every other tag exists so the audit log can say what was attempted.
pub const Verdict = enum {
    allow,
    loopback,
    unspecified,
    private,
    cgnat,
    link_local,
    metadata,
    multicast,
    broadcast,
    reserved,

    pub fn name(self: Verdict) []const u8 {
        return @tagName(self);
    }

    pub fn denied(self: Verdict) bool {
        return self != .allow;
    }
};

/// A dotted quad, strictly: four decimal octets, nothing else. `127.1`, `0x7f.1`
/// and `2130706433` are refused rather than folded to `127.0.0.1`, because a
/// lenient parser is how a deny list gets walked around.
pub fn parseV4(text: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var octets: usize = 0;
    var value: u32 = 0;
    var digits: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '.') {
            if (digits == 0 or octets == 3) return null;
            out[octets] = @intCast(value);
            octets += 1;
            value = 0;
            digits = 0;
            continue;
        }
        if (!std.ascii.isDigit(c)) return null;
        if (digits == 3) return null;
        value = value * 10 + (c - '0');
        if (value > 255) return null;
        digits += 1;
        if (i == text.len - 1) {
            if (octets != 3) return null;
            out[3] = @intCast(value);
            return out;
        }
    }
    return null;
}

/// `::ffff:a.b.c.d` carries an IPv4 address inside an IPv6 one, so it is
/// classified by the IPv4 table. The deprecated `::a.b.c.d` form is NOT mapped:
/// it is indistinguishable from `::`/`::1` and those have their own verdicts.
pub fn mappedV4(addr: [16]u8) ?[4]u8 {
    for (addr[0..10]) |byte| {
        if (byte != 0) return null;
    }
    if (addr[10] != 0xff or addr[11] != 0xff) return null;
    return .{ addr[12], addr[13], addr[14], addr[15] };
}

pub fn classifyV4(addr: [4]u8) Verdict {
    const a = addr[0];
    const b = addr[1];
    if (a == 127) return .loopback;
    if (a == 0) return .unspecified;
    if (a == 10) return .private;
    if (a == 172 and b >= 16 and b <= 31) return .private;
    if (a == 192 and b == 168) return .private;
    if (a == 100 and b >= 64 and b <= 127) return .cgnat;
    if (a == 169 and b == 254) {
        if (addr[2] == 169 and addr[3] == 254) return .metadata;
        return .link_local;
    }
    if (a == 255 and b == 255 and addr[2] == 255 and addr[3] == 255) return .broadcast;
    if (a >= 224 and a <= 239) return .multicast;
    if (a >= 240) return .reserved;
    return .allow;
}

/// `::a.b.c.d` with a non-zero tail: the deprecated v4-compatible form, which
/// is an IPv4 address wearing an IPv6 header. `::` and `::1` never reach here.
fn compatibleV4(addr: [16]u8) ?[4]u8 {
    for (addr[0..12]) |byte| {
        if (byte != 0) return null;
    }
    if (addr[12] == 0 and addr[13] == 0 and addr[14] == 0 and addr[15] <= 1) return null;
    return .{ addr[12], addr[13], addr[14], addr[15] };
}

/// The prefixes that embed an IPv4 address one hop away: NAT64, 6to4, Teredo.
fn isNestedV4(addr: [16]u8) bool {
    const nat64 = addr[0] == 0x00 and addr[1] == 0x64 and addr[2] == 0xff and addr[3] == 0x9b;
    const six_to_four = addr[0] == 0x20 and addr[1] == 0x02;
    const teredo = addr[0] == 0x20 and addr[1] == 0x01 and addr[2] == 0x00 and addr[3] == 0x00;
    return nat64 or six_to_four or teredo;
}

pub fn classifyV6(addr: [16]u8) Verdict {
    if (mappedV4(addr)) |v4| return classifyV4(v4);
    var all_zero = true;
    for (addr[0..15]) |byte| {
        if (byte != 0) all_zero = false;
    }
    if (all_zero and addr[15] == 1) return .loopback;
    if (all_zero and addr[15] == 0) return .unspecified;
    // `::a.b.c.d` (IPv4-compatible), NAT64, 6to4 and Teredo all carry an IPv4
    // address a routing configuration may deliver, so the table refuses them
    // rather than trusting this host's routes to keep the promise.
    if (all_zero) return .reserved;
    if (compatibleV4(addr)) |v4| return classifyV4(v4);
    if (isNestedV4(addr)) return .reserved;
    if (addr[0] == 0xfe and (addr[1] & 0xc0) == 0x80) return .link_local;
    if (addr[0] == 0xff) return .multicast;
    if (addr[0] == 0xfc or addr[0] == 0xfd) return .private;
    return .allow;
}

/// The verdict for an address in text form. Null means "not an address this
/// table understands", which callers must treat as a denial, not as a pass.
pub fn classifyText(text: []const u8) ?Verdict {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "[")) {
        const close = std.mem.lastIndexOfScalar(u8, trimmed, ']') orelse return null;
        return classifyText(trimmed[1..close]);
    }
    if (parseV4(trimmed)) |v4| return classifyV4(v4);
    const v6 = std.Io.net.IpAddress.parseIp6(trimmed, 0) catch return null;
    return classifyV6(v6.ip6.bytes);
}

/// The port half: a proxy dials the ports the tenant declared and nothing else,
/// so a workspace cannot reach a service that merely happens to be listening.
pub fn portAllowed(port: u16, declared: []const u16) bool {
    if (port == 0) return false;
    for (declared) |candidate| {
        if (candidate == port) return true;
    }
    return false;
}

/// The host's own listeners. A workspace may not dial one whatever its address
/// resolves to, because that is the control plane talking to itself.
pub fn hostListenerDenied(port: u16, listeners: []const u16) bool {
    for (listeners) |candidate| {
        if (candidate == port) return true;
    }
    return false;
}

pub const Refusal = struct {
    verdict: Verdict,
    reason: []const u8,
};

/// The whole decision, in the order the proxy applies it: a host listener port
/// is refused before any address is resolved, then the address itself.
pub fn decide(addr_text: []const u8, port: u16, host_listeners: []const u16) ?Refusal {
    if (hostListenerDenied(port, host_listeners)) {
        return .{ .verdict = .loopback, .reason = "host listener" };
    }
    const verdict = classifyText(addr_text) orelse
        return .{ .verdict = .reserved, .reason = "unparseable address" };
    if (verdict.denied()) return .{ .verdict = verdict, .reason = verdict.name() };
    return null;
}

// ─── the resolver's half ────────────────────────────────────────────────

/// A resolver answer may not be larger than this. A UDP DNS answer is 512 bytes
/// and a TCP one 64 KiB; the cap is what stops a forwarded answer from being a
/// bulk-exfiltration channel of its own.
pub const resolver_response_cap: usize = 4096;

/// The resolver refuses an answer whose address is one the proxy would refuse,
/// so a rebinding name is not a way around the proxy.
pub fn answerDenied(addr_text: []const u8) bool {
    const verdict = classifyText(addr_text) orelse return true;
    return verdict.denied();
}

/// A name worth forwarding at all: printable, bounded, no trailing dot games
/// and no embedded port. Whether it *resolves* somewhere denied is `answerDenied`.
pub fn queryNameValid(name: []const u8) bool {
    if (name.len == 0 or name.len > 253) return false;
    if (name[0] == '.' or name[name.len - 1] == '.') return false;
    var labels: usize = 1;
    for (name) |c| {
        if (c == '.') {
            labels += 1;
            continue;
        }
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
        if (!ok) return false;
    }
    return labels >= 2;
}

const testing = std.testing;

const Case = struct { text: []const u8, want: Verdict };

test "classifyText: the deny table, address by address" {
    const cases = [_]Case{
        .{ .text = "127.0.0.1", .want = .loopback },
        .{ .text = "127.255.255.254", .want = .loopback },
        .{ .text = "0.0.0.0", .want = .unspecified },
        .{ .text = "0.1.2.3", .want = .unspecified },
        .{ .text = "10.0.0.1", .want = .private },
        .{ .text = "172.16.0.1", .want = .private },
        .{ .text = "172.31.255.255", .want = .private },
        .{ .text = "192.168.1.1", .want = .private },
        .{ .text = "100.64.0.1", .want = .cgnat },
        .{ .text = "100.127.255.255", .want = .cgnat },
        .{ .text = "169.254.1.1", .want = .link_local },
        .{ .text = "169.254.169.254", .want = .metadata },
        .{ .text = "224.0.0.1", .want = .multicast },
        .{ .text = "239.255.255.255", .want = .multicast },
        .{ .text = "255.255.255.255", .want = .broadcast },
        .{ .text = "240.0.0.1", .want = .reserved },
        .{ .text = "::1", .want = .loopback },
        .{ .text = "::", .want = .unspecified },
        .{ .text = "::ffff:127.0.0.1", .want = .loopback },
        .{ .text = "::ffff:169.254.169.254", .want = .metadata },
        .{ .text = "::ffff:10.0.0.1", .want = .private },
        .{ .text = "fe80::1", .want = .link_local },
        .{ .text = "ff02::1", .want = .multicast },
        .{ .text = "fd00::1", .want = .private },
        .{ .text = "fc00::1", .want = .private },
        .{ .text = "8.8.8.8", .want = .allow },
        .{ .text = "1.1.1.1", .want = .allow },
        .{ .text = "172.32.0.1", .want = .allow },
        .{ .text = "100.128.0.1", .want = .allow },
        .{ .text = "192.169.0.1", .want = .allow },
        .{ .text = "2606:4700::1111", .want = .allow },
        .{ .text = "[::1]", .want = .loopback },
        .{ .text = "0000:0000:0000:0000:0000:0000:a9fe:a9fe", .want = .metadata },
        .{ .text = "0000:0000:0000:0000:0000:0000:7f00:0002", .want = .loopback },
        .{ .text = "0000:0000:0000:0000:0000:0000:0a00:0001", .want = .private },
        .{ .text = "0000:0000:0000:0000:0000:0000:0808:0808", .want = .allow },
        .{ .text = "0064:ff9b:0000:0000:0000:0000:7f00:0001", .want = .reserved },
        .{ .text = "2002:7f00:0001:0000:0000:0000:0000:0001", .want = .reserved },
        .{ .text = "2001:0000:1234:0000:0000:0000:0000:0001", .want = .reserved },
    };
    for (cases) |case| {
        const got = classifyText(case.text) orelse {
            std.debug.print("unparseable: {s}\n", .{case.text});
            return error.TestUnexpectedResult;
        };
        testing.expectEqual(case.want, got) catch |err| {
            std.debug.print("case {s}: want {s} got {s}\n", .{ case.text, case.want.name(), got.name() });
            return err;
        };
    }
}

test "classifyText: an ambiguous or malformed address is not an address" {
    try testing.expect(classifyText("") == null);
    try testing.expect(classifyText("127.1") == null);
    try testing.expect(classifyText("0x7f.0.0.1") == null);
    try testing.expect(classifyText("2130706433") == null);
    try testing.expect(classifyText("localhost") == null);
    try testing.expect(classifyText("127.0.0.1:8081") == null);
    try testing.expect(classifyText("1.2.3") == null);
    try testing.expect(classifyText("1.2.3.4.5") == null);
    try testing.expect(classifyText("256.0.0.1") == null);
    try testing.expect(classifyText("1.2.3.") == null);
}

test "decide: a host listener is refused whatever address carries it" {
    const listeners = [_]u16{ 8081, 443 };
    const on_listener = decide("8.8.8.8", 8081, &listeners).?;
    try testing.expectEqualStrings("host listener", on_listener.reason);
    try testing.expectEqual(Verdict.loopback, on_listener.verdict);

    const on_https = decide("8.8.8.8", 443, &listeners).?;
    try testing.expectEqualStrings("host listener", on_https.reason);

    try testing.expect(decide("8.8.8.8", 8443, &listeners) == null);
}

test "decide: the address table is applied to the address that is dialled" {
    const none = [_]u16{};
    const loopback = decide("127.0.0.1", 3000, &none).?;
    try testing.expectEqual(Verdict.loopback, loopback.verdict);
    try testing.expectEqualStrings("loopback", loopback.reason);

    const mapped = decide("::ffff:127.0.0.1", 3000, &none).?;
    try testing.expectEqual(Verdict.loopback, mapped.verdict);

    const metadata = decide("169.254.169.254", 80, &none).?;
    try testing.expectEqual(Verdict.metadata, metadata.verdict);

    try testing.expect(decide("93.184.216.34", 443, &none) == null);
}

test "decide: an address the table cannot read fails closed" {
    const none = [_]u16{};
    const refused = decide("not-an-address", 443, &none).?;
    try testing.expectEqualStrings("unparseable address", refused.reason);
    try testing.expect(refused.verdict.denied());
}

test "portAllowed: only a declared port is dialled" {
    const declared = [_]u16{ 3000, 5173 };
    try testing.expect(portAllowed(3000, &declared));
    try testing.expect(portAllowed(5173, &declared));
    try testing.expect(!portAllowed(8081, &declared));
    try testing.expect(!portAllowed(0, &declared));
    try testing.expect(!portAllowed(3000, &[_]u16{}));
}

test "the resolver refuses the answer the proxy would refuse" {
    try testing.expect(answerDenied("127.0.0.1"));
    try testing.expect(answerDenied("::ffff:10.0.0.1"));
    try testing.expect(answerDenied("169.254.169.254"));
    try testing.expect(answerDenied("localhost"));
    try testing.expect(!answerDenied("93.184.216.34"));
}

test "queryNameValid: a real name passes, a port or a shape does not" {
    try testing.expect(queryNameValid("example.com"));
    try testing.expect(queryNameValid("ws-1.preview.example.net"));
    try testing.expect(queryNameValid("a_b.example.com"));

    try testing.expect(!queryNameValid(""));
    try testing.expect(!queryNameValid("example.com:53"));
    try testing.expect(!queryNameValid(".example.com"));
    try testing.expect(!queryNameValid("example.com."));
    try testing.expect(!queryNameValid("localhost"));
    try testing.expect(!queryNameValid("a b.com"));
    try testing.expect(!queryNameValid(&[_]u8{'a'} ** 254));
}

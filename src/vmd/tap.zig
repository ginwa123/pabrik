//! `pabrik-vm-tap` — the OPT-IN privileged half of the tap-based mode. The
//! server never holds CAP_NET_ADMIN; the vsock path needs no tap, and the
//! ioctl path is UNVERIFIED.

const std = @import("std");
const linux = std.os.linux;

/// `CAP_NET_ADMIN` is bit 12 of `CapEff` in `/proc/self/status`.
pub const cap_net_admin_bit: u6 = 12;
/// `TUNSETIFF` is `_IOW('T', 202, int)`; a tap carries Ethernet frames and
/// `IFF_NO_PI` keeps the 4-byte packet-info prefix out of them.
pub const tunsetiff: u32 = 0x400454ca;
pub const iff_tap: u16 = 0x0002;
pub const iff_no_pi: u16 = 0x1000;
pub const iff_up: u16 = 0x1;
pub const iff_running: u16 = 0x40;
pub const siocsifflags: u32 = 0x8914;
pub const siocsifaddr: u32 = 0x8916;
pub const siocsifnetmask: u32 = 0x891c;
pub const tun_device = "/dev/net/tun";
pub const default_guest_ip = "172.16.0.2";
pub const default_host_ip = "172.16.0.1";
pub const default_mask = "255.255.255.0";
pub const default_mac = "06:00:AC:10:00:02";

pub const Plan = struct {
    tap: []const u8,
    guest_ip: []const u8 = default_guest_ip,
    host_ip: []const u8 = default_host_ip,
    mask: []const u8 = default_mask,
    mac: []const u8 = default_mac,
};

/// A tap name the kernel will accept and a shell will not misread: the helper
/// runs as root, so a name from an argument is validated, never trusted.
pub fn tapNameValid(name: []const u8) bool {
    if (name.len == 0 or name.len > 15) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return true;
}

/// The `CapEff:` line of `/proc/self/status`.
pub fn hexCapabilities(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "CapEff:")) continue;
        const value = std.mem.trim(u8, line["CapEff:".len..], " \t\r");
        if (value.len == 0) return null;
        return value;
    }
    return null;
}

/// Whether the helper may create a tap at all. A capability it does not have
/// is a refusal, not a fallback: the fallback is the vsock-only path.
pub fn mayCreateTap(status_text: []const u8) bool {
    const hex = hexCapabilities(status_text) orelse return false;
    const mask: u64 = @as(u64, 1) << cap_net_admin_bit;
    const value = std.fmt.parseInt(u64, hex, 16) catch return false;
    return value & mask != 0;
}

/// The `PUT /network-interfaces/tap0` body Firecracker needs, with the tap the
/// helper created and the guest's own MAC and address.
pub fn nicConfig(allocator: std.mem.Allocator, plan: Plan) ![]u8 {
    if (!tapNameValid(plan.tap)) return error.InvalidTapName;
    return std.fmt.allocPrint(
        allocator,
        "{{\"iface_id\":\"{s}\",\"host_dev_name\":\"{s}\",\"guest_mac\":\"{s}\"}}",
        .{ plan.tap, plan.tap, plan.mac },
    );
}

/// The kernel-command-line fragment that configures `eth0` without DHCP,
/// because the guest image ships no udhcpc lease and no NIC by default:
/// `ip=<guest>::<gateway>:<mask>::<iface>:off`.
pub fn bootIpHint(allocator: std.mem.Allocator, plan: Plan) ![]u8 {
    return std.fmt.allocPrint(allocator, "ip={s}::{s}:{s}::eth0:off", .{
        plan.guest_ip, plan.host_ip, plan.mask,
    });
}

/// What the operator has to run, in order. Printed instead of guessed at, so a
/// deployment can copy it and a reviewer can check it.
pub fn planText(allocator: std.mem.Allocator, plan: Plan) ![]u8 {
    const nic = try nicConfig(allocator, plan);
    defer allocator.free(nic);
    const ip = try bootIpHint(allocator, plan);
    defer allocator.free(ip);
    return std.fmt.allocPrint(allocator,
        \\pabrik-vm-tap: plan (nothing has been created)
        \\  1. host:  ip tuntap add dev {s} mode tap user <server uid>
        \\  2. host:  ip addr add {s}/24 dev {s} && ip link set {s} up
        \\  3. vmm:   PUT /network-interfaces/{s} {s}
        \\  4. guest: add to boot args: {s}
        \\  5. host:  ip link del {s}   (after the VM has stopped)
        \\  Unverified: every step above needs CAP_NET_ADMIN, which the server
        \\  must not hold. The vsock-only path needs none of it.
        \\
    , .{ plan.tap, plan.host_ip, plan.tap, plan.tap, plan.tap, nic, ip, plan.tap });
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return;
        off += rc;
    }
}

fn readStatus(allocator: std.mem.Allocator) ?[]u8 {
    const rc = linux.open("/proc/self/status", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (out.items.len < 64 * 1024) {
        const n = linux.read(fd, &chunk, chunk.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        out.appendSlice(allocator, chunk[0..n]) catch return null;
    }
    return out.toOwnedSlice(allocator) catch null;
}

/// Create the tap and print its name. Privileged: this is the only call in the
/// whole tree that needs CAP_NET_ADMIN, and it is a separate process from the
/// server on purpose.
fn createTap(plan: Plan) bool {
    var name_buf: [16]u8 = .{0} ** 16;
    @memcpy(name_buf[0..plan.tap.len], plan.tap);
    const rc = linux.open(tun_device, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var req: [40]u8 = .{0} ** 40;
    @memcpy(req[0..name_buf.len], &name_buf);
    const flags: u16 = iff_tap | iff_no_pi;
    req[16] = @truncate(flags);
    req[17] = @truncate(flags >> 8);
    return linux.errno(linux.ioctl(fd, tunsetiff, @intFromPtr(&req))) == .SUCCESS;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_iter.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    while (args_iter.next()) |arg| try argv.append(init.gpa, arg);
    const args = argv.items;

    var plan = Plan{ .tap = "" };
    var create = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--create")) {
            create = true;
        } else if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
            i += 1;
            plan.tap = args[i];
        } else if (std.mem.eql(u8, arg, "--guest-ip") and i + 1 < args.len) {
            i += 1;
            plan.guest_ip = args[i];
        } else if (std.mem.eql(u8, arg, "--host-ip") and i + 1 < args.len) {
            i += 1;
            plan.host_ip = args[i];
        } else if (std.mem.eql(u8, arg, "--mac") and i + 1 < args.len) {
            i += 1;
            plan.mac = args[i];
        }
    }
    if (!tapNameValid(plan.tap)) {
        writeAll(2, "pabrik-vm-tap: --name is required, and is a device name\n");
        std.process.exit(2);
    }
    const status = readStatus(aa) orelse {
        writeAll(2, "pabrik-vm-tap: cannot read /proc/self/status\n");
        std.process.exit(2);
    };
    if (!mayCreateTap(status)) {
        writeAll(2, "pabrik-vm-tap: CAP_NET_ADMIN is missing; the vsock-only path needs no tap\n");
        std.process.exit(1);
    }
    const text = planText(aa, plan) catch {
        writeAll(2, "pabrik-vm-tap: cannot build the plan\n");
        std.process.exit(1);
    };
    writeAll(1, text);
    if (create and !createTap(plan)) {
        writeAll(2, "pabrik-vm-tap: TUNSETIFF failed\n");
        std.process.exit(1);
    }
    if (create) {
        writeAll(1, "pabrik-vm-tap: the tap exists; remove it when the VM stops\n");
    } else {
        writeAll(1, "pabrik-vm-tap: nothing was created\n");
    }
}

const testing = std.testing;

test "a device name the kernel would accept is the only one taken" {
    try testing.expect(tapNameValid("pv-ws_1"));
    try testing.expect(tapNameValid("tap0"));
    try testing.expect(!tapNameValid(""));
    try testing.expect(!tapNameValid("a b"));
    try testing.expect(!tapNameValid("tap/0"));
    try testing.expect(!tapNameValid(".."));
    try testing.expect(!tapNameValid("0123456789abcdef"));
    try testing.expect(!tapNameValid("tap;rm -rf /"));
}

test "the helper refuses to create a tap without CAP_NET_ADMIN" {
    const without = "Name:\tpabrik-vm-tap\nCapEff:\t0000000000000000\nCapPrm:\t0000000000000000\n";
    try testing.expect(!mayCreateTap(without));
    const only_low = "CapEff:\t0000000000000fff\n";
    try testing.expect(!mayCreateTap(only_low));
    try testing.expect(!mayCreateTap("Name:\tx\n"));
    try testing.expect(!mayCreateTap("CapEff:\tnot hex\n"));
}

test "the helper proceeds only when CAP_NET_ADMIN is in CapEff" {
    const admin = "CapEff:\t0000000000001000\n";
    try testing.expect(mayCreateTap(admin));
    const several = "CapEff:\t0000003fffffffff\n";
    try testing.expect(mayCreateTap(several));
    try testing.expectEqualStrings("0000003fffffffff", hexCapabilities(several).?);
}

test "the plan names the tap, the addresses and the config Firecracker gets" {
    const allocator = testing.allocator;
    const plan = Plan{ .tap = "pv-ws1" };
    const nic = try nicConfig(allocator, plan);
    defer allocator.free(nic);
    try testing.expectEqualStrings(
        "{\"iface_id\":\"pv-ws1\",\"host_dev_name\":\"pv-ws1\",\"guest_mac\":\"06:00:AC:10:00:02\"}",
        nic,
    );
    const ip = try bootIpHint(allocator, plan);
    defer allocator.free(ip);
    try testing.expectEqualStrings("ip=172.16.0.2::172.16.0.1:255.255.255.0::eth0:off", ip);

    const text = try planText(allocator, plan);
    defer allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "nothing has been created") != null);
    try testing.expect(std.mem.indexOf(u8, text, "CAP_NET_ADMIN") != null);
    try testing.expectError(error.InvalidTapName, nicConfig(allocator, .{ .tap = "bad name" }));
}

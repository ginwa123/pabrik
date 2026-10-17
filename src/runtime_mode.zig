//! Which execution substrate this process uses. `--saas` puts every workspace
//! in a microVM and is Linux-only; without the flag the host runtime is used.
//! A SaaS process must never fall back to host execution silently.

const std = @import("std");
const builtin = @import("builtin");

pub const Mode = enum(u8) { local, saas };

/// The VM backend is compiled in on Linux only, and even there `--saas` needs a
/// reachable `pabrik-vmd`: without a manager the process could start and then
/// have to run tenant commands on the host.
pub const vm_backend_available = builtin.os.tag == .linux;

/// The mode this process booted in. Process-wide by design (§1 of the plan),
/// and `local` until the boot path decides otherwise, so anything that never
/// sets it keeps today's behaviour exactly.
var current: std.atomic.Value(Mode) = .init(.local);

pub fn setCurrent(mode: Mode) void {
    current.store(mode, .seq_cst);
}

pub fn currentMode() Mode {
    return current.load(.seq_cst);
}

/// The socket the daemon is reachable on. The boot path sets it once; null
/// means no manager was ever configured, and a SaaS process with no manager
/// cannot place a command anywhere but the host.
var manager_socket: ?[]const u8 = null;

pub fn setManagerSocket(path: ?[]const u8) void {
    manager_socket = path;
}

pub fn socketPath() ?[]const u8 {
    return manager_socket;
}

/// `/run/user/<uid>/pabrik-vmd.sock` when the session has a runtime dir, else
/// the shared `/tmp`. `PABRIK_VMD_SOCKET` overrides both.
pub fn defaultSocketPath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("PABRIK_VMD_SOCKET")) |path| return allocator.dupe(u8, path);
    if (env.get("XDG_RUNTIME_DIR")) |dir| {
        if (dir.len > 0) return std.fmt.allocPrint(allocator, "{s}/pabrik-vmd.sock", .{dir});
    }
    return allocator.dupe(u8, "/tmp/pabrik-vmd.sock");
}

/// Everything the decision depends on, injected so the tests need no /dev/kvm
/// and no daemon.
pub const Probe = struct {
    os: std.Target.Os.Tag,
    kvm_readable: bool,
    cgroup2_mounted: bool,
    vmd_reachable: bool,
};

pub const Refusal = enum {
    unsupported_platform,
    kvm_unavailable,
    cgroup2_missing,
    backend_not_implemented,
    vmd_unavailable,
};

pub const Decision = union(enum) {
    ok: Mode,
    refused: Refusal,
};

pub fn decide(saas_requested: bool, probe: Probe) Decision {
    if (!saas_requested) return .{ .ok = .local };
    if (probe.os != .linux) return .{ .refused = .unsupported_platform };
    if (!probe.kvm_readable) return .{ .refused = .kvm_unavailable };
    if (!probe.cgroup2_mounted) return .{ .refused = .cgroup2_missing };
    if (!vm_backend_available) return .{ .refused = .backend_not_implemented };
    if (!probe.vmd_reachable) return .{ .refused = .vmd_unavailable };
    return .{ .ok = .saas };
}

/// One line, naming the fix. Printed by the boot path, so it must stand alone.
pub fn message(refusal: Refusal) []const u8 {
    return switch (refusal) {
        .unsupported_platform => "--saas needs Linux with KVM; this host keeps the local runtime",
        .kvm_unavailable => "--saas needs /dev/kvm readable by this user (check the kvm group and the device mode)",
        .cgroup2_missing => "--saas needs a cgroup v2 mount at /sys/fs/cgroup to bound each workspace VM",
        .backend_not_implemented => "--saas is not wired into this build yet (VM backend lands in phase P2); run without --saas",
        .vmd_unavailable => "--saas needs a running pabrik-vmd on its socket: start `pabrik-vmd serve`, or set PABRIK_VMD_SOCKET to it",
    };
}

const testing = std.testing;

const platforms = [_]std.Target.Os.Tag{ .linux, .macos, .windows, .freebsd };

test "no flag means local mode on every platform, whatever the probe says" {
    const probes = [_]Probe{
        .{ .os = .linux, .kvm_readable = true, .cgroup2_mounted = true, .vmd_reachable = true },
        .{ .os = .linux, .kvm_readable = false, .cgroup2_mounted = false, .vmd_reachable = false },
        .{ .os = .macos, .kvm_readable = false, .cgroup2_mounted = false, .vmd_reachable = false },
        .{ .os = .windows, .kvm_readable = false, .cgroup2_mounted = false, .vmd_reachable = false },
    };
    for (probes) |probe| {
        const decision = decide(false, probe);
        try testing.expectEqual(Mode.local, decision.ok);
    }
}

test "saas refuses on every non-Linux platform even with KVM and cgroup2 present" {
    for (platforms) |os| {
        if (os == .linux) continue;
        const decision = decide(true, .{
            .os = os,
            .kvm_readable = true,
            .cgroup2_mounted = true,
            .vmd_reachable = true,
        });
        try testing.expectEqual(Refusal.unsupported_platform, decision.refused);
    }
}

test "saas refuses when /dev/kvm is unreadable, before the cgroup check" {
    const decision = decide(true, .{
        .os = .linux,
        .kvm_readable = false,
        .cgroup2_mounted = true,
        .vmd_reachable = true,
    });
    try testing.expectEqual(Refusal.kvm_unavailable, decision.refused);
}

test "saas refuses without a cgroup v2 mount" {
    const decision = decide(true, .{
        .os = .linux,
        .kvm_readable = true,
        .cgroup2_mounted = false,
        .vmd_reachable = true,
    });
    try testing.expectEqual(Refusal.cgroup2_missing, decision.refused);
}

test "saas refuses when no manager answers, rather than running tenant code on the host" {
    if (!vm_backend_available) return;
    const decision = decide(true, .{
        .os = .linux,
        .kvm_readable = true,
        .cgroup2_mounted = true,
        .vmd_reachable = false,
    });
    try testing.expectEqual(Refusal.vmd_unavailable, decision.refused);
}

test "saas answers ok exactly when the backend is compiled in and a manager answers" {
    const decision = decide(true, .{
        .os = .linux,
        .kvm_readable = true,
        .cgroup2_mounted = true,
        .vmd_reachable = true,
    });
    if (vm_backend_available) {
        try testing.expectEqual(Mode.saas, decision.ok);
    } else {
        try testing.expectEqual(Refusal.backend_not_implemented, decision.refused);
    }
}

test "every refusal names an action and no two share a message" {
    const refusals = [_]Refusal{
        .unsupported_platform,
        .kvm_unavailable,
        .cgroup2_missing,
        .backend_not_implemented,
        .vmd_unavailable,
    };
    for (refusals, 0..) |refusal, i| {
        const text = message(refusal);
        try testing.expect(text.len > 0);
        try testing.expect(std.mem.indexOf(u8, text, "--saas") != null);
        for (refusals[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, text, message(other)));
        }
    }
}

test "the process boots local and only a decision changes that" {
    try testing.expectEqual(Mode.local, currentMode());
    setCurrent(.saas);
    defer setCurrent(.local);
    try testing.expectEqual(Mode.saas, currentMode());
}

test "the manager socket is unset until the boot path sets it" {
    try testing.expect(socketPath() == null);
    setManagerSocket("/run/user/1000/pabrik-vmd.sock");
    defer setManagerSocket(null);
    try testing.expectEqualStrings("/run/user/1000/pabrik-vmd.sock", socketPath().?);
    setManagerSocket(null);
    try testing.expect(socketPath() == null);
}

test "the socket path prefers PABRIK_VMD_SOCKET, then the runtime dir, then /tmp" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    const fallback = try defaultSocketPath(allocator, &env);
    defer allocator.free(fallback);
    try testing.expectEqualStrings("/tmp/pabrik-vmd.sock", fallback);

    try env.put("XDG_RUNTIME_DIR", "/run/user/1000");
    const runtime_dir = try defaultSocketPath(allocator, &env);
    defer allocator.free(runtime_dir);
    try testing.expectEqualStrings("/run/user/1000/pabrik-vmd.sock", runtime_dir);

    try env.put("PABRIK_VMD_SOCKET", "/srv/pabrik/vmd.sock");
    const explicit = try defaultSocketPath(allocator, &env);
    defer allocator.free(explicit);
    try testing.expectEqualStrings("/srv/pabrik/vmd.sock", explicit);
}

//! Which execution substrate this process uses. `--saas` puts every workspace
//! in a microVM and is Linux-only; without the flag the host runtime is used.
//! A SaaS process must never fall back to host execution silently.

const std = @import("std");

pub const Mode = enum { local, saas };

/// The VM backend is compiled in by plan phase P2. Until then `--saas`
/// refuses to start: running tenant tools on the host while the user
/// believes they are isolated is the one failure this flag exists to stop.
pub const vm_backend_available = false;

/// Everything the decision depends on, injected so the tests need no /dev/kvm.
pub const Probe = struct {
    os: std.Target.Os.Tag,
    kvm_readable: bool,
    cgroup2_mounted: bool,
};

pub const Refusal = enum {
    unsupported_platform,
    kvm_unavailable,
    cgroup2_missing,
    backend_not_implemented,
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
    return .{ .ok = .saas };
}

/// One line, naming the fix. Printed by the boot path, so it must stand alone.
pub fn message(refusal: Refusal) []const u8 {
    return switch (refusal) {
        .unsupported_platform => "--saas needs Linux with KVM; this host keeps the local runtime",
        .kvm_unavailable => "--saas needs /dev/kvm readable by this user (check the kvm group and the device mode)",
        .cgroup2_missing => "--saas needs a cgroup v2 mount at /sys/fs/cgroup to bound each workspace VM",
        .backend_not_implemented => "--saas is not wired into this build yet (VM backend lands in phase P2); run without --saas",
    };
}

const testing = std.testing;

const platforms = [_]std.Target.Os.Tag{ .linux, .macos, .windows, .freebsd };

test "no flag means local mode on every platform, whatever the probe says" {
    const probes = [_]Probe{
        .{ .os = .linux, .kvm_readable = true, .cgroup2_mounted = true },
        .{ .os = .linux, .kvm_readable = false, .cgroup2_mounted = false },
        .{ .os = .macos, .kvm_readable = false, .cgroup2_mounted = false },
        .{ .os = .windows, .kvm_readable = false, .cgroup2_mounted = false },
    };
    for (probes) |probe| {
        const decision = decide(false, probe);
        try testing.expectEqual(Mode.local, decision.ok);
    }
}

test "saas refuses on every non-Linux platform even with KVM and cgroup2 present" {
    for (platforms) |os| {
        if (os == .linux) continue;
        const decision = decide(true, .{ .os = os, .kvm_readable = true, .cgroup2_mounted = true });
        try testing.expectEqual(Refusal.unsupported_platform, decision.refused);
    }
}

test "saas refuses when /dev/kvm is unreadable, before the cgroup check" {
    const decision = decide(true, .{ .os = .linux, .kvm_readable = false, .cgroup2_mounted = true });
    try testing.expectEqual(Refusal.kvm_unavailable, decision.refused);
}

test "saas refuses without a cgroup v2 mount" {
    const decision = decide(true, .{ .os = .linux, .kvm_readable = true, .cgroup2_mounted = false });
    try testing.expectEqual(Refusal.cgroup2_missing, decision.refused);
}

test "saas answers ok exactly when the backend is compiled in" {
    const decision = decide(true, .{ .os = .linux, .kvm_readable = true, .cgroup2_mounted = true });
    if (vm_backend_available) {
        try testing.expectEqual(Mode.saas, decision.ok);
    } else {
        try testing.expectEqual(Refusal.backend_not_implemented, decision.refused);
    }
}

test "every refusal names an action and no two share a message" {
    const refusals = [_]Refusal{ .unsupported_platform, .kvm_unavailable, .cgroup2_missing, .backend_not_implemented };
    for (refusals, 0..) |refusal, i| {
        const text = message(refusal);
        try testing.expect(text.len > 0);
        try testing.expect(std.mem.indexOf(u8, text, "--saas") != null);
        for (refusals[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, text, message(other)));
        }
    }
}

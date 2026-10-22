//! The limits a VM resize may ask for, and the one place they are checked.
//! It carries no Linux and no VM code, so it compiles wherever the console
//! does.

const std = @import("std");

pub const min_vcpus: u32 = 1;
pub const max_vcpus: u32 = 8;
pub const min_mem_mib: u32 = 128;
pub const max_mem_mib: u32 = 16 * 1024;

pub const Refusal = enum {
    vcpus_out_of_range,
    mem_mib_out_of_range,
    bad_workspace_id,

    pub fn message(self: Refusal) []const u8 {
        return switch (self) {
            .vcpus_out_of_range => "vcpus must be 1..8",
            .mem_mib_out_of_range => "mem_mib must be 128..16384",
            .bad_workspace_id => "workspace id must be letters, digits, '-' or '_'",
        };
    }
};

/// A workspace id that is safe to put in a path: no separators, no dots.
pub fn validWorkspaceId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

pub fn vcpusInRange(v: u32) bool {
    return v >= min_vcpus and v <= max_vcpus;
}

pub fn memInRange(m: u32) bool {
    return m >= min_mem_mib and m <= max_mem_mib;
}

/// The refusal a request hits, or null when it is in range.
pub fn check(id: []const u8, vcpus: u32, mem_mib: u32) ?Refusal {
    if (!validWorkspaceId(id)) return .bad_workspace_id;
    if (!vcpusInRange(vcpus)) return .vcpus_out_of_range;
    if (!memInRange(mem_mib)) return .mem_mib_out_of_range;
    return null;
}

const testing = std.testing;

test "a request inside the limits is accepted, and one outside is named" {
    try testing.expect(check("ws_1", 2, 1024) == null);
    try testing.expectEqual(Refusal.vcpus_out_of_range, check("ws_1", 0, 1024).?);
    try testing.expectEqual(Refusal.vcpus_out_of_range, check("ws_1", 9, 1024).?);
    try testing.expectEqual(Refusal.mem_mib_out_of_range, check("ws_1", 2, 64).?);
    try testing.expectEqual(Refusal.mem_mib_out_of_range, check("ws_1", 2, 32 * 1024).?);
    // The boundaries themselves are inside.
    try testing.expect(check("ws_1", min_vcpus, min_mem_mib) == null);
    try testing.expect(check("ws_1", max_vcpus, max_mem_mib) == null);
}

test "a workspace id that could escape a path is refused" {
    try testing.expect(validWorkspaceId("ws_1792_00ab"));
    try testing.expect(!validWorkspaceId("../etc"));
    try testing.expect(!validWorkspaceId("ws/1"));
    try testing.expect(!validWorkspaceId(""));
    try testing.expect(!validWorkspaceId("ws 1"));
    try testing.expectEqual(Refusal.bad_workspace_id, check("../etc", 2, 1024).?);
}

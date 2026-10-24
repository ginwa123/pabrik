//! The limits a VM resize may ask for, and the one place they are checked.
//! It carries no Linux and no VM code, so it compiles wherever the console
//! does.

const std = @import("std");

pub const min_vcpus: u32 = 1;
pub const max_vcpus: u32 = 8;
pub const min_mem_mib: u32 = 128;
pub const max_mem_mib: u32 = 16 * 1024;
/// Firecracker lays the guest's memory out in 128 MiB steps and refuses
/// anything else at boot, so a value off the grid is refused here instead.
pub const mem_step_mib: u32 = 128;
/// The guest builder's smallest image is 128 MiB; the ceiling is a sanity
/// bound on a `truncate`, not a limit anything measured.
pub const min_disk_mib: u32 = 128;
pub const max_disk_mib: u32 = 64 * 1024;

pub const Refusal = enum {
    vcpus_out_of_range,
    mem_mib_out_of_range,
    mem_mib_not_aligned,
    disk_mib_out_of_range,
    disk_mib_not_growing,
    bad_workspace_id,

    pub fn message(self: Refusal) []const u8 {
        return switch (self) {
            .vcpus_out_of_range => "vcpus must be 1..8",
            .mem_mib_out_of_range => "mem_mib must be 128..16384",
            .mem_mib_not_aligned => "mem_mib must be a multiple of 128",
            .disk_mib_out_of_range => "disk_mib must be 128..65536",
            .disk_mib_not_growing => "disk_mib must be larger than the disk already is: a workspace disk never shrinks",
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
    return m >= min_mem_mib and m <= max_mem_mib and m % mem_step_mib == 0;
}

/// The refusal a request hits, or null when it is in range.
pub fn check(id: []const u8, vcpus: u32, mem_mib: u32) ?Refusal {
    if (!validWorkspaceId(id)) return .bad_workspace_id;
    if (!vcpusInRange(vcpus)) return .vcpus_out_of_range;
    if (mem_mib < min_mem_mib or mem_mib > max_mem_mib) return .mem_mib_out_of_range;
    if (mem_mib % mem_step_mib != 0) return .mem_mib_not_aligned;
    return null;
}

/// A disk resize lands on the workspace's image, so the image's own size is the
/// rule as well as the range. `current_mib` 0 means "no image yet".
pub fn checkDisk(target_mib: u32, current_mib: u32) ?Refusal {
    if (target_mib < min_disk_mib or target_mib > max_disk_mib) return .disk_mib_out_of_range;
    if (target_mib <= current_mib) return .disk_mib_not_growing;
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
    // Firecracker takes memory in 128 MiB steps, and refuses anything else at
    // boot, so a resize off the grid is refused before the manager is asked.
    try testing.expectEqual(Refusal.mem_mib_not_aligned, check("ws_1", 2, 1000).?);
    try testing.expect(check("ws_1", 2, 1536) == null);
}

test "a workspace id that could escape a path is refused" {
    try testing.expect(validWorkspaceId("ws_1792_00ab"));
    try testing.expect(!validWorkspaceId("../etc"));
    try testing.expect(!validWorkspaceId("ws/1"));
    try testing.expect(!validWorkspaceId(""));
    try testing.expect(!validWorkspaceId("ws 1"));
    try testing.expectEqual(Refusal.bad_workspace_id, check("../etc", 2, 1024).?);
}

test "a disk resize larger than the image is accepted, and nothing else is" {
    // The base image is 128 MiB; growing it to 512 is the ordinary case.
    try testing.expect(checkDisk(512, 128) == null);
    // Growing a workspace whose image does not exist yet is allowed too.
    try testing.expect(checkDisk(1024, 0) == null);
    // The same size is not a resize, and neither is a smaller one: the
    // filesystem inside the image cannot give blocks back.
    try testing.expectEqual(Refusal.disk_mib_not_growing, checkDisk(128, 128).?);
    try testing.expectEqual(Refusal.disk_mib_not_growing, checkDisk(256, 512).?);
    // A target off the ends of the range never reaches a `truncate`.
    try testing.expectEqual(Refusal.disk_mib_out_of_range, checkDisk(64, 0).?);
    try testing.expectEqual(Refusal.disk_mib_out_of_range, checkDisk(max_disk_mib + 1, 0).?);
    try testing.expect(checkDisk(max_disk_mib, 128) == null);
}

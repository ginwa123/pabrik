const std = @import("std");

pub const min_vcpus: u32 = 1;
pub const max_vcpus: u32 = 32;
pub const min_mem_mib: u32 = 128;
pub const max_mem_mib: u32 = 1024 * 1024;
pub const mem_step_mib: u32 = 128;
pub const min_disk_mib: u32 = 128;
pub const max_disk_mib: u32 = 1024 * 1024;

pub const Refusal = enum {
    vcpus_out_of_range,
    mem_mib_out_of_range,
    mem_mib_not_aligned,
    disk_mib_out_of_range,
    disk_mib_not_growing,
    bad_workspace_id,

    pub fn message(self: Refusal) []const u8 {
        return switch (self) {
            .vcpus_out_of_range => std.fmt.comptimePrint("vcpus must be {d}..{d}", .{ min_vcpus, max_vcpus }),
            .mem_mib_out_of_range => std.fmt.comptimePrint("mem_mib must be {d}..{d}", .{ min_mem_mib, max_mem_mib }),
            .mem_mib_not_aligned => std.fmt.comptimePrint("mem_mib must be a multiple of {d}", .{mem_step_mib}),
            .disk_mib_out_of_range => std.fmt.comptimePrint("disk_mib must be {d}..{d}", .{ min_disk_mib, max_disk_mib }),
            .disk_mib_not_growing => "disk_mib must be larger than the disk already is: a workspace disk never shrinks",
            .bad_workspace_id => "workspace id must be letters, digits, '-' or '_'",
        };
    }
};

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

pub fn check(id: []const u8, vcpus: u32, mem_mib: u32) ?Refusal {
    if (!validWorkspaceId(id)) return .bad_workspace_id;
    if (!vcpusInRange(vcpus)) return .vcpus_out_of_range;
    if (mem_mib < min_mem_mib or mem_mib > max_mem_mib) return .mem_mib_out_of_range;
    if (mem_mib % mem_step_mib != 0) return .mem_mib_not_aligned;
    return null;
}

pub fn checkDisk(target_mib: u32, current_mib: u32) ?Refusal {
    if (target_mib < min_disk_mib or target_mib > max_disk_mib) return .disk_mib_out_of_range;
    if (target_mib <= current_mib) return .disk_mib_not_growing;
    return null;
}

const testing = std.testing;

test "a resize within what the VMM can hold is accepted, at every step" {
    try testing.expect(check("ws_1", 2, 1024) == null);
    try testing.expect(check("ws_1", min_vcpus, min_mem_mib) == null);
    try testing.expect(check("ws_1", max_vcpus, max_mem_mib) == null);
    try testing.expect(check("ws_1", 2, 1536) == null);
}

test "a resize past the VMM's own ceiling is refused, and the ceiling is named" {
    try testing.expectEqual(Refusal.vcpus_out_of_range, check("ws_1", 0, 1024).?);
    try testing.expectEqual(Refusal.vcpus_out_of_range, check("ws_1", max_vcpus + 1, 1024).?);
    try testing.expectEqual(Refusal.mem_mib_out_of_range, check("ws_1", 2, 64).?);
    try testing.expectEqual(Refusal.mem_mib_out_of_range, check("ws_1", 2, max_mem_mib + mem_step_mib).?);

    const vcpus = Refusal.vcpus_out_of_range.message();
    const mem = Refusal.mem_mib_out_of_range.message();
    try testing.expect(std.mem.indexOf(u8, vcpus, std.fmt.comptimePrint("{d}", .{max_vcpus})) != null);
    try testing.expect(std.mem.indexOf(u8, mem, std.fmt.comptimePrint("{d}", .{max_mem_mib})) != null);
}

test "memory off Firecracker's grid is refused before the manager is asked" {
    try testing.expectEqual(Refusal.mem_mib_not_aligned, check("ws_1", 2, 1000).?);
    try testing.expectEqual(Refusal.mem_mib_not_aligned, check("ws_1", 2, max_mem_mib - 1).?);
}

test "a workspace id that could escape a path is refused" {
    try testing.expect(validWorkspaceId("ws_1792_00ab"));
    try testing.expect(!validWorkspaceId("../etc"));
    try testing.expect(!validWorkspaceId("ws/1"));
    try testing.expect(!validWorkspaceId(""));
    try testing.expect(!validWorkspaceId("ws 1"));
    try testing.expectEqual(Refusal.bad_workspace_id, check("../etc", 2, 1024).?);
}

test "a disk may grow to the bound, never past it, and never shrink" {
    try testing.expect(checkDisk(512, 128) == null);
    try testing.expect(checkDisk(1024, 0) == null);
    try testing.expect(checkDisk(max_disk_mib, 128) == null);
    try testing.expectEqual(Refusal.disk_mib_out_of_range, checkDisk(max_disk_mib + 1, 0).?);
    try testing.expectEqual(Refusal.disk_mib_out_of_range, checkDisk(min_disk_mib - 1, 0).?);
    try testing.expectEqual(Refusal.disk_mib_not_growing, checkDisk(128, 128).?);
    try testing.expectEqual(Refusal.disk_mib_not_growing, checkDisk(256, 512).?);
}

const std = @import("std");
const testing = std.testing;

/// Skill info for session_skills table
pub const SkillInfo = struct {
    skill_name: []u8,
    content: []u8,
    loaded_at: ?i64 = null,

    pub fn deinit(self: SkillInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.skill_name);
        allocator.free(self.content);
    }
};

test "SkillInfo default loaded_at is null" {
    var s = SkillInfo{
        .skill_name = try testing.allocator.dupe(u8, "n"),
        .content = try testing.allocator.dupe(u8, "c"),
    };
    defer s.deinit(testing.allocator);
    try testing.expect(s.loaded_at == null);
}

test "SkillInfo.deinit frees skill_name and content" {
    var s = SkillInfo{
        .skill_name = try testing.allocator.dupe(u8, "test-skill"),
        .content = try testing.allocator.dupe(u8, "test-content"),
        .loaded_at = 1234567890,
    };
    s.deinit(testing.allocator);
    // No leak — testing allocator's leak detector verifies at scope exit.
}

test "SkillInfo.deinit does not free loaded_at (it is a value, not a slice)" {
    var s = SkillInfo{
        .skill_name = try testing.allocator.dupe(u8, "x"),
        .content = try testing.allocator.dupe(u8, "y"),
        .loaded_at = null,
    };
    s.deinit(testing.allocator);
}

test "SkillInfo.deinit does not free loaded_at when set" {
    // A non-null loaded_at must NOT be passed to allocator.free — it is a
    // value, not a slice. The successful return here (no crash) plus the
    // testing allocator's leak detector confirms correctness.
    var s = SkillInfo{
        .skill_name = try testing.allocator.dupe(u8, "x"),
        .content = try testing.allocator.dupe(u8, "y"),
        .loaded_at = 9999999999,
    };
    s.deinit(testing.allocator);
}

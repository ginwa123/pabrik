const std = @import("std");

pub const MAIN_AGENT_ONLY_NAMES = [_][]const u8{
    "spawn_sub_agent",
    "run_skill_eval",
    "run_session",
};

pub fn isMainAgentOnly(name: []const u8) bool {
    for (MAIN_AGENT_ONLY_NAMES) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

test "the list covers the tools that need a human or a fresh session" {
    try testing.expect(isMainAgentOnly("spawn_sub_agent"));
    try testing.expect(isMainAgentOnly("run_skill_eval"));
    try testing.expect(isMainAgentOnly("run_session"));
    try testing.expect(!isMainAgentOnly("read_file"));
    try testing.expect(!isMainAgentOnly("use_tool"));
}

const testing = std.testing;
